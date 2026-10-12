# Hark module contract

This is the public surface of Core.lua, Positions.lua and Voice.lua (Hark 0.2.0) that
UI.lua and Options.lua code against. Anything not listed here is private and may change.

Target client: WoW Forever, interface 16001 (Classic-era gameplay on a modern client:
Communities, Blizzard voice chat and the "secret values" system are present).

## 1. Namespace and file layout

- Exactly one intentional global: `Hark`. The same table is also `ns.Hark` in the private
  addon namespace (`local ADDON_NAME, ns = ...`).
- Framework globals that cannot be avoided, all owned by Core.lua: `HarkDB` (SavedVariables),
  `SLASH_HARK1`, `SLASH_HARK2`, `SlashCmdList.HARK`, and `Hark_OnAddonCompartmentClick`
  (named in Hark.toc; the client looks it up in `_G`).
- Load order (Hark.toc): Core.lua, Positions.lua, Voice.lua, UI.lua, Options.lua.
- Modules: `Hark.Positions`, `Hark.Voice`, `Hark.UI`, `Hark.Options`.

UI.lua and Options.lua must start like this and must not create any other globals:

```lua
local _, ns = ...
local Hark = ns.Hark
local UI = {}          -- or Options
Hark.UI = UI           -- or Hark.Options = Options
function UI:Init() end -- called once by Core at ADDON_LOADED, after Positions and Voice
```

Named frames create globals. Do not name frames (pass `nil` as the name), except where a
Blizzard API strictly requires a name, in which case prefix it `Hark` (e.g. `HarkMainFrame`)
and list it in this file.

Core calls `Init()` on Positions, Voice, UI and Options at `ADDON_LOADED`, in that order,
each protected: an error in UI:Init is reported but does not stop the addon. `Hark.db` is
ready when `Init()` runs. The game world (units, voice, positions) is not ready until
`PLAYER_LOGIN`.

Optional hooks Core uses if present:

| Function | Called by |
|---|---|
| `Hark.UI:Toggle()` | addon compartment click |
| `Hark.Options:Open()` | `/hark options`, `/hark config`, compartment click when there is no UI:Toggle |

## 2. Core (`Hark`)

| Member | Description |
|---|---|
| `Hark.version` | string, e.g. `"0.2.0"` |
| `Hark.db` | the saved-variables table (`HarkDB`). nil before ADDON_LOADED. **Read only**: write through `Hark:Set`. |
| `Hark.SETTINGS` | the schema (section 5). Read only. Options can build its controls from it. |
| `Hark.FULL_VOLUME` | `100`. The volume everyone is restored to. |
| `Hark.CURVES` | `{ linear = fn, natural = fn, smooth = fn }`, each mapping t in 0..1 to 0..1. Read only. |
| `Hark:Get(key)` | current value (default if the db is not loaded yet). |
| `Hark:Set(key, value)` | validates, clamps, stores, fires `SETTING_CHANGED`. Returns `true` or `false, errorString`. Numbers are clamped to range, not rejected. Strings are trimmed; `""` becomes nil for nilable keys. Numeric club/stream ids are accepted and stored as strings. |
| `Hark:GetDefault(key)` | default value from the schema. |
| `Hark:ResetSettings()` | every setting back to its default (fires `SETTING_CHANGED` per changed key). Re-enables if disabled. |
| `Hark:IsEnabled()` | `true` when proximity volumes are on. |
| `Hark:SetEnabled(bool)` | the only way to switch proximity on or off. Off restores every volume to 100 immediately. `Hark:Set("enabled", v)` forwards here. |
| `Hark:GetVolumeForDistance(yards)` | pure function, 0..100, using the current settings. Use it for curve previews. |
| `Hark:RegisterCallback(event, owner, fn)` | `fn(event, ...)`. One callback per owner per event; registering again replaces. |
| `Hark:UnregisterCallback(event, owner)` | |
| `Hark:Print(msg)` | chat output with the `[Hark]` prefix. |
| `Hark:Debug(msg)` | prints only when the `debug` setting is on. |
| `Hark.IsSecret(value)` | `true` for a secret value/table that addon code must not inspect. Note: a plain function, call with a dot. |

`Hark:Fire(event, ...)` exists but is for Core, Positions and Voice only. UI and Options
must not fire Hark events.

### Volume curve

With `full = fullVoiceRange`, `silent = silentRange`, `t = (silent - d) / (silent - full)`:

- `d <= full` gives `maxVolume`
- `full < d < silent` gives `minVolume + (maxVolume - minVolume) * curve(t)`, rounded
- `d >= silent` gives `0`

`curve` comes from `fadeCurve`: linear `t`, natural `t^2`, smooth `t^2 (3 - 2t)`.
A `minVolume` above 0 makes a step from `minVolume` to silence at `silentRange`.

## 3. Positions (`Hark.Positions`)

Players are always identified by **player GUID** (`"Player-<server>-<hex>"`). Voice members
have no names on Forever, so never key anything by character name.

| Function | Returns |
|---|---|
| `Positions:GetDistance(guid)` | `distance, reason` (see table below) |
| `Positions:GetDistanceToUnit(unit)` | same as GetDistance, for a unit token |
| `Positions:Get(guid)` | copy `{ guid, name, x, y, instance, zone, layer, hidden, dead, age }` or nil. `name` is `"Name-Realm"`. |
| `Positions:GetName(guid)` | `"Name-Realm"` from received messages, or nil |
| `Positions:Count()` | number of fresh positions held |
| `Positions:GetLayer()` | `layerId or nil, confident (bool), zoneKey (uiMapID or nil)` |
| `Positions:RequestBroadcast()` | asks for a send soon. Calls in a burst collapse into one send and go through the send budget. |
| `Positions:AnyoneMovingRecently()` | bool. Used by Voice to set how often it runs a pass. |

Distance reasons:

| distance | reason | meaning | volume Voice applies |
|---|---|---|---|
| number | `"near"` | both positions known, same continent, not on another layer | curve |
| `0` | `"instance"` | both inside the same dungeon or raid map, and grouped | maxVolume |
| `math.huge` | `"elsewhere"` | other continent or instance, or their position is hidden | 0 |
| `math.huge` | `"layer"` | same zone, both layers confirmed, and they differ | 0 |
| `nil` | `"unknown"` | no fresh data: no addon, not in your guild or group, or stale (over 45 s) | `hearUnknown` ? maxVolume : 0 |
| (Voice only) | `"override"` | volume pinned by `Voice:SetOverride` | the override |

Layer rules: a player is silenced for a layer mismatch only when **both** sides have a
confirmed layer for the **same** zone. An unknown or unconfirmed layer never silences anyone.

## 4. Voice (`Hark.Voice`)

| Function | Description |
|---|---|
| `Voice:IsAvailable()` | the client has the voice API Hark needs |
| `Voice:IsActive()` | in the configured community channel, and that channel is active |
| `Voice:GetState()` | `"idle"`, `"joining"` or `"active"` |
| `Voice:GetChannelID()` | the active voice channel id, or nil |
| `Voice:Join()` | joins the configured community. Returns `true`, or `false, message`. The result is asynchronous: watch `VOICE_STATE_CHANGED`. |
| `Voice:Leave()` | restores all volumes, then leaves the channel. Also stops auto-join until the next manual Join. |
| `Voice:GetMembers()` | array of fresh copies, sorted nearest first: `{ guid, memberID, name, distance, reason, volume, target, override, isSpeaking, isActive }`. `name` may be nil (show the GUID or "Unknown"). `volume` is the last value sent to the client. `target` is what the curve wants. Excludes the local player. |
| `Voice:SetOverride(guid, volume or nil)` | pins a member to 0..100 (0 = user mute, 100 = always heard), or nil to return them to proximity. Session only, never saved. |
| `Voice:GetOverride(guid)` | the pinned volume or nil |
| `Voice:ListCommunities()` | array `{ clubId (string), name, clubType }` sorted by name, for a community picker |
| `Voice:ResolveStreamId(clubId)` | the stream Hark will use: saved `streamId`, else the club's General stream, else `"1"` |
| `Voice:RequestPass(delay)` | runs a volume pass within `delay` seconds. Calls coalesce. |
| `Voice:RestoreAllVolumes()` | everyone back to 100 |
| `Voice:PrintStatus()` | prints `/hark status` |
| `Voice:SetVolumeFor(guid, volume, memberID?)` | **internal**. The only place that calls `C_VoiceChat.SetMemberVolume`. The next pass, 0.5 to 1.5 s later, overwrites whatever it set. |

## 5. Saved variables (`HarkDB`)

On load, Core validates every key, fills defaults, clamps numbers and enforces the
cross-field rules. Every key below can be written with `Hark:Set`.

| Key | Type | Default | Valid values |
|---|---|---|---|
| `enabled` | boolean | `true` | Use `Hark:SetEnabled`. |
| `autoJoin` | boolean | `true` | Join the community after login and on zone change, unless the player left by hand. |
| `communityId` | string or nil | `nil` | Club id, e.g. `"23111161"`. |
| `streamId` | string or nil | `nil` | Stream id. nil means auto (General stream, else `"1"`). |
| `fullVoiceRange` | number (yards) | `15` | 0 to 100, step 1. Always less than `silentRange`. |
| `silentRange` | number (yards) | `40` | 5 to 200, step 1. |
| `minVolume` | number | `30` | 0 to 100. Always at most `maxVolume`. The volume just inside `silentRange`. |
| `maxVolume` | number | `100` | 0 to 100. The volume within `fullVoiceRange`. |
| `fadeCurve` | string | `"smooth"` | `"linear"`, `"natural"` or `"smooth"` |
| `hearUnknown` | boolean | `false` | Volume for members with no position data: maxVolume if true, 0 if false. |
| `layerAware` | boolean | `true` | Silence players on a confirmed different layer. |
| `debug` | boolean | `false` | Debug chat output. |

Cross-field rules, applied by `Hark:Set`:

- If `fullVoiceRange >= silentRange` after a change to `fullVoiceRange`, `silentRange` is raised to `fullVoiceRange + 5`, capped at 200. If that still does not fit, `fullVoiceRange` is lowered. A change to `silentRange` lowers `fullVoiceRange` to `silentRange - 5` instead.
- If `minVolume > maxVolume`, the key that was not changed is moved to match.

The rule may change a second key. Each changed key fires its own `SETTING_CHANGED`, so
refresh every control from `Hark:Get` rather than trusting the value you just set.

Internal keys. Do not read or write these:

- `dbVersion` (number, currently 2)
- `lowered` (`[guid] = true` for every player whose volume Hark has lowered and not yet restored; this is how a crash is recovered at the next login)

Migrated from 0.1.0: `joinOnZoneChange` becomes `autoJoin`. `leaveOnZoneExit` is removed,
because community voice is world-wide and has nothing to leave per zone.

## 6. Callback events (via `Hark:RegisterCallback`)

| Event | Args | When |
|---|---|---|
| `LOADED` | none | after every module's Init |
| `SETTING_CHANGED` | `key, newValue` | any setting changed, including `enabled` |
| `ENABLED_CHANGED` | `enabled` | proximity switched on or off |
| `VOICE_STATE_CHANGED` | `state, channelID` | idle, joining or active changed |
| `MEMBERS_UPDATED` | none | after every volume pass (0.5 to 1.5 s while active) and on member removal or restore. Call `Voice:GetMembers()` here. Do not do heavy work. |
| `MEMBER_SPEAKING` | `guid, isSpeaking` | a member started or stopped talking |
| `POSITION_RECEIVED` | `guid` | a valid position message arrived. This can be frequent: do not redraw on it. Use `MEMBERS_UPDATED`. |
| `LAYER_CHANGED` | `layerId or nil, confident` | detected layer changed |

## 7. Game events Hark reacts to

- Core: `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT` (restores all volumes).
- Positions: `CHAT_MSG_ADDON`, `GROUP_ROSTER_UPDATE`, `PLAYER_GUILD_UPDATE`, `PLAYER_ENTERING_WORLD`,
  `ZONE_CHANGED_NEW_AREA`, `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, `NAME_PLATE_UNIT_ADDED`,
  `PLAYER_DEAD`, `PLAYER_ALIVE`, `PLAYER_UNGHOST`.
- Voice: `VOICE_CHAT_CHANNEL_JOINED`, `VOICE_CHAT_CHANNEL_ACTIVATED`, `VOICE_CHAT_CHANNEL_DEACTIVATED`,
  `VOICE_CHAT_CHANNEL_REMOVED`, `VOICE_CHAT_CHANNEL_MEMBER_ADDED`, `VOICE_CHAT_CHANNEL_MEMBER_REMOVED`,
  `VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED`, `VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED`,
  `VOICE_CHAT_CHANNEL_MEMBER_SPEAKING_STATE_CHANGED`, `VOICE_CHAT_LOGOUT`, `VOICE_CHAT_ERROR`,
  `PLAYER_STARTED_MOVING`, `PLAYER_STOPPED_MOVING`, `ZONE_CHANGED_NEW_AREA`.

UI and Options may register their own game events on their own frames.

## 8. Rules

1. Never call `C_VoiceChat.SetMemberVolume`, `SetMemberMuted` or `ToggleMemberMuted` yourself.
   For a user mute or "always hear" use `Voice:SetOverride`. Blizzard's own mute is remembered by
   the client and would outlive the addon.
2. Never write to `Hark.db` directly. Use `Hark:Set` or `Hark:SetEnabled`.
3. Never send addon messages on the `"Hark"` prefix. Positions owns the prefix and its send budget.
   A second module would push it over the server throttle (burst of 10, then 1 per second per prefix).
4. No OnUpdate scripts that run every frame. Redraw on `MEMBERS_UPDATED` or other callbacks, or use a
   `C_Timer.NewTicker` of at least 0.25 s that only runs while your frame is shown.
5. `C_Timer.After` returns nothing and cannot be cancelled. Use `C_Timer.NewTimer` or `NewTicker` when you need `:Cancel()`.
6. Identify players by GUID. Show names from `Voice:GetMembers()[i].name`, and fall back to a placeholder when it is nil.
7. Treat `math.huge` distances as "out of range" in the UI. Never print them as a number.
8. Wrap any optional Blizzard API that may be missing on this client (`Settings`, `InterfaceOptions_AddCategory`,
   minimap or compartment APIs) in an existence check.
9. Do not create globals (see section 1).

## 9. Wire format (for reference; owned by Positions)

Prefix `Hark`, sent on `GUILD` and on one of `INSTANCE_CHAT`, `RAID` or `PARTY`. The group copy
is skipped when every group member is already in your guild.

```
P1,<seq>,<senderGUID>,<instanceID>,<a>,<b>,<zoneKey>,<layer>,<flags>
```

- `a,b`: rounded `UnitPosition` yards (may be negative). Empty when the position is hidden.
- `instanceID`: continent id. When hidden inside an instance, it is the instance map id.
- `zoneKey`: the zone-level uiMapID.
- `layer`: 0 unless the sender's layer is confirmed.
- `flags`: `d` dead, `h` hidden.
- `seq`: increases per send. Older or duplicate messages are dropped, because the server reorders.

Send budget: a token bucket of 4 that refills at 0.5 per second, so at most one message every
2 s on average. Moving players send every 2 s, still players every 15 s, plus coalesced sends
on zone, roster and death changes. Positions only sends while proximity is enabled and the
player is in the voice channel.

## 10. Amendments (orchestrator, 12 Oct 2026)

### 10.1 UI-owned saved state

`HarkDB.ui` is a table owned by UI.lua. It is the one exception to rule 2: UI.lua may read and
write `Hark.db.ui` directly, for frame position, scale, lock, collapsed state and visibility.
Core guarantees `Hark.db.ui` is a table after load and never validates or clears its contents.
No other module touches it. Options.lua stores nothing of its own; every option is a schema key.

### 10.2 Seen positions (Positions)

Community members outside your guild and group never send a position message. Positions may
still range them when the client can see them: if a voice member's GUID matches a visible unit
(`nameplateN`, `target`, `mouseover`, `partyN`, `raidN`), `UnitPosition(unit)` gives a live
position. `Positions:GetDistance(guid)` returns such a distance with reason `"seen"`. Voice
treats `"seen"` exactly like `"near"`. A seen position is only as fresh as the unit is visible;
once the unit is gone it expires after the same 45 s as a message.

Friendly nameplates must be enabled (CVar `nameplateShowFriends`) for `nameplateN` units to
exist for other players. Hark never changes that CVar silently. The UI may show a hint when it
is off and `hearUnknown` is false.

| distance | reason | meaning | volume Voice applies |
|---|---|---|---|
| number | `"seen"` | the member is a visible unit; live `UnitPosition` | curve |

## 11. Amendments (orchestrator, after persistence and integration)

### 11.1 Settings backup

Saved variables may not be read back after a full relog on the Forever beta, so Core keeps its
own backup of every schema key plus `Hark.db.ui`.

- Storage: CVars `HarkSave1` to `HarkSave12` (survive a relog, not a client restart), and one
  account macro named `HarkSettings` carrying a comment-only body (survives a restart, because
  macros live on the server). Both are optional and skipped when the API is missing.
- `Hark.db.loadedFrom` is an internal key: `"savedvariables"`, `"cvar"`, `"macro"` or `"defaults"`.
  Do not write it.
- `Hark._persist` is a test-only hook. Nothing else may call it.
- Command: `/hark backup` writes a backup now and reports the state of both copies.

New callback event:

| Event | Args | When |
|---|---|---|
| `SETTINGS_RESTORED` | `source` | A backup arrived after modules had started and replaced the settings. |

**UI.lua must register `SETTINGS_RESTORED`** and re-apply its frame state from `Hark.db.ui`.
A late restore rewrites that table's contents in place, so a panel that read it at Init is stale.

### 11.2 Zone borders: decided, do not change

Distance is measured continent-wide. Zone identity matters only for the layer check. Two players
a few yards apart on opposite sides of a zone border therefore hear each other, which is correct:
they can see each other. Silencing on zone change would cut people off mid-conversation while
standing next to each other. This was raised repeatedly during the build; it is settled.

### 11.3 Panel commands

`/hark show`, `/hark hide` and `/hark toggle` drive `Hark.UI:Show/Hide/Toggle`. These exist so a
panel that is hidden, or stranded off-screen after a resolution change, is always recoverable.

### 11.4 Named frames

`HarkOptionsFrame` is the one named frame, created by Options.lua for Hark's own options window so
that it can be registered with `UISpecialFrames` and closed with Escape. No other frame is named.

### 11.5 Additive UI functions

`UI:ResetPosition()` moves the member panel back to its default place. Options exposes a button for it.

## 12. Diagnostics (added after the reviews)

The addon has to be verifiable on a live client by one player with little time, so it records its
own evidence to disk. SavedVariables are written on `/reload` and at logout, which makes anything
stored in `HarkDB` readable from outside the game.

### 12.1 Load order

`Diagnostics.lua` loads last, after `Options.lua`. It owns `/hark selftest` and the probe code.
The error buffer and the trace buffer live in Core, because they must exist before anything else
can fail.

### 12.2 New internal HarkDB keys

Internal. Nothing may validate, clear or depend on their shape except Core and Diagnostics.

| Key | Contents |
|---|---|
| `errors` | Up to 50 captured Lua errors, newest kept. Repeats bump `count`. |
| `selftest` | One probe run: client facts, API presence, position, voice, layer and persistence results. |
| `trace` | Up to 600 rows, newest kept, recording volume passes, messages, layer and voice changes. |

### 12.3 Commands

`/hark selftest` runs every probe and prints a summary. `/hark trace on|off|clear` records a
timeline; it starts off each session and is never saved.

### 12.4 Exception to rule 1 and section 4

`Voice._SelfTest` calls `C_VoiceChat.SetMemberVolume` directly, which rule 1 otherwise reserves to
`Voice:SetVolumeFor`. It is allowed only there, only to write back the value it has just read, so
no member's volume changes, and only to establish whether a GUID-based `PlayerLocation` is accepted
by this client. A test asserts the heard volume is unchanged. No other diagnostic code may write
volumes.

### 12.5 Internal hooks

`Hark._RecordError`, `Hark._Trace`, `Hark._TraceWho`, `Hark._diag`, `Positions._Diag`,
`Voice._SelfTest` and `Options._DiagState` exist for diagnostics and tests only. They are not
public API and may change.

### 12.6 Reader

`Tests/readselftest.lua` reads a saved `Hark.lua` outside the game and prints the facts, a verdict
per open question, the error buffer and the trace as a per-member timeline.
`Tests/pull-selftest.sh` finds the newest such file across every install and runs the reader on it.
