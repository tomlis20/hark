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
  `VOICE_CHAT_LOGIN`, `VOICE_CHAT_PENDING_CHANNEL_JOIN_STATE`, `VOICE_CHAT_CONNECTION_SUCCESS` (section 13),
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

## 13. Voice join observability (21 Oct 2026)

Live failure: `/hark join` timed out every time on the Forever client while a hand call of
`C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel("23111161", "1")` joined. Hark recorded
nothing about which step failed. This section records what the API documentation says, what Hark now
assumes, and the new evidence it keeps.

### 13.1 Sources

warcraft.wiki.gg returned HTTP 502 for most voice pages on 21 Oct 2026. These pages loaded, and each
version table lists `forever 1.60.1`: `VOICE_CHAT_CHANNEL_DEACTIVATED`, `VOICE_CHAT_LOGIN` (which
carries the full `Enum.VoiceChatStatusCode` table) and `API C_Club.GetStreams`. Everything else comes
from the wiki's own "Blizzard Docs" source for the Forever client: `Ketho/wow-ui-source-forever`, branch
`forever`, build 1.60.1 (70009), files `Blizzard_APIDocumentationGenerated/VoiceChatDocumentation.lua`
and `ClubDocumentation.lua`. The wiki generates its API pages from those same files. Blizzard's own
join code (`Blizzard_Channels/Classic/ChannelFrame.lua`, `Blizzard_ChatFrame/Mainline/VoiceChatHeadsetButton.lua`)
was read for behaviour.

### 13.2 What the documentation says

| Item | Forever 1.60.1 |
|---|---|
| `VOICE_CHAT_CHANNEL_JOINED` | `status` (VoiceChatStatusCode), `channelID` (number), `channelType` (ChatChannelType), `clubId` (ClubId, **nilable**), `streamId` (ClubStreamId, **nilable**). SynchronousEvent; no secret predicates. Matches Hark's order. |
| `VOICE_CHAT_CHANNEL_ACTIVATED`, `_DEACTIVATED`, `_REMOVED` | `channelID` (number) |
| `VOICE_CHAT_ERROR` | `platformCode` (number), `statusCode` (VoiceChatStatusCode) |
| `VOICE_CHAT_LOGIN` | `status` (VoiceChatStatusCode) |
| `VOICE_CHAT_PENDING_CHANNEL_JOIN_STATE` | `channelType`, `clubId` (nilable), `streamId` (nilable), `pendingJoin` (bool) |
| `C_VoiceChat.GetChannelForCommunityStream(clubId, streamId)` | args ClubId, ClubStreamId. `MayReturnNothing`, `SecretInChatMessagingLockdown`, `SecretArguments = AllowedWhenUntainted`. Returns `VoiceChatChannel`. |
| `C_VoiceChat.GetChannel(channelID)` | same predicates; returns `VoiceChatChannel` |
| `VoiceChatChannel` | `name` string; `channelID` number; `channelType`; `clubId` ClubId; `streamId` ClubStreamId; `volume` number; `isActive`, `isMuted`, `isTransmitting`, `isTranscribing` bool; `members` VoiceChatMember[]. Every field except `name` and `members` is `NeverSecret`. There is **no** `isLocalProcess`. |
| `VoiceChatMember` | `energy`, `memberID` number; `isActive`, `isSpeaking`, `isMutedForAll`, `isSilenced` bool. No `name`. |
| `C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel(clubId, streamId)` | ClubId, ClubStreamId; returns nothing |
| `C_VoiceChat.Login()` | returns `status` (VoiceChatStatusCode). `IsLoggedIn()` returns bool. `GetActiveChannelID()` returns number, nilable. |
| `C_Club.GetStreams(clubId)` | `SecretInChatMessagingLockdown`, `RequiresClubsInitialized`, `AllowedWhenUntainted`. Entries `ClubStreamInfo`: `streamId` ClubStreamId, `name` string, `subject` string, `leadersAndModeratorsOnly` bool, `streamType` (`NeverSecret`), `creationTime` BigUInteger. **No field says whether a stream has voice.** |
| ClubId, ClubStreamId | the wiki types both as **number** |
| `Enum.ClubStreamType` | General 0, Guild 1, Officer 2, Discord 3, Other 4 |
| `Enum.VoiceChatStatusCode` | Success 0, OperationPending 1, TooManyRequests 2, LoginProhibited 3, ClientNotInitialized 4, ClientNotLoggedIn 5, ClientAlreadyLoggedIn 6, ChannelNameTooShort 7, ChannelNameTooLong 8, ChannelAlreadyExists 9, AlreadyInChannel 10, TargetNotFound 11, Failure 12, ServiceLost 13, UnableToLaunchProxy 14, ProxyConnectionTimeOut 15, ProxyConnectionUnableToConnect 16, ProxyConnectionUnexpectedDisconnect 17, Disabled 18, UnsupportedChatChannelType 19, InvalidCommunityStream 20, PlayerSilenced 21, PlayerVoiceChatParentalDisabled 22, InvalidInputDevice 23, InvalidOutputDevice 24, PlayerVoiceChatAgeVerificationRestricted 25 |

Blizzard's UI behaviour:
- `ChannelFrame:TryExecuteCommand` sends a voice request only when `IsLoggedIn()` is true. Otherwise it calls `Login()` and, on `OperationPending`, holds the request until `VOICE_CHAT_LOGIN` reports Success.
- The headset button treats a channel as active when `GetActiveChannelID() == channel.channelID`, not when `channel.isActive` is true.

### 13.3 Corrections to Hark's assumptions

1. **Login.** Hark used to call `Login()` and then send the request immediately. It now holds the request until `VOICE_CHAT_LOGIN` arrives, or for 5 s at most, as Blizzard does. A failed login status ends the join with a message.
2. **Active.** A channel counts as active when `isActive` is true **or** `GetActiveChannelID()` equals its id. This rule now applies to the join's lookup, the JOINED handler and the timeout.
3. **Activation.** After a successful JOINED for our pending request, Hark remembers that channel id. `VOICE_CHAT_CHANNEL_ACTIVATED` for that id is adopted directly, without re-reading clubId and streamId through `GetChannel`.
4. **Id forms.** Hark now passes ClubId and ClubStreamId to `C_VoiceChat` and `C_Club` as numbers when the saved string converts exactly. A lookup that returns nothing is retried with the strings. A request that raises is retried with the strings. `RequestJoinAndActivateCommunityStreamChannel` returns nothing, so a silent refusal cannot be detected. `Hark.db.communityId` and `streamId` stay strings.
5. **Status text.** Failures now print the status code with its name, e.g. `11 TargetNotFound`.
6. **Test mock.** The mock now hands out ids as numbers and uses `isTranscribing` instead of `isLocalProcess`. It has the full status and stream-type enums, and models Login/`VOICE_CHAT_LOGIN`.

Unchanged and still unproven: the secret-value guard in `Voice` OnEvent still drops any event that has a secret argument. It now logs the drop and the argument index. Stream choice is also unchanged: saved `streamId`, else the lowest General stream, else `"1"`.

### 13.4 New internal HarkDB keys

Internal, like section 12.2. Voice owns `joinlog` and Diagnostics owns `joindiag`. Core only resets either one when it is not a table.

| Key | Contents |
|---|---|
| `joinlog` | Up to 40 entries, newest kept, recorded **whether or not the trace is on**. Each entry is `{ t = GetTime(), step = name, ... }`. Steps: `join` (club, stream, saved stream, or an early `outcome`), `resolveStream` (result, source, every GetStreams attempt with the full list), `isLoggedIn`, `login`, `loginWait`, `loginFailed`, `lookup` / `timeout` (GetChannelForCommunityStream attempts per id form, channel id, active channel id, timeout decision), `request` / `activate` (call, form, typed args, ok or err), `event` (every channel-level `VOICE_CHAT_*` event, and member-level ones while a join is watched, with all args; `dropped` and `secretArg` when the secret guard discarded it), `joinedDecision`, `activatedDecision`, `adopt`. Values are typed records `{ t = luaType, v = value }`, and a secret is `{ t = "secret", v = "<secret>" }` (never raw). While `/hark trace` is on, each entry is also a trace row with `k = "join"`. |
| `joindiag` | One `/hark joindiag` run: `pre` (Voice._JoinFacts: IsEnabled, CanPlayerUseVoiceChat, IsLoggedIn, IsVoiceChatConnected, GetCurrentVoiceChatConnectionStatusCode, GetActiveChannelID/Type, active channel, GetStreams, resolved stream, lookup in both forms, GetJoinClubVoiceChannelError, IsChannelJoinPending, GetClubInfo, subscribed), `accepted` / `rejected` (which of the 47 documented `VOICE_CHAT_*` events the client let it register), `events` (each with typed args, at most 200, energy events only counted), `counts`, `join` (what Voice:Join returned), `final` (joined, Hark state, GetActiveChannelID, IsLoggedIn, facts again), `joinlog` (the joinlog entries from the window), `stringRetry` (see 13.5; absent when not needed), `complete`. |

### 13.5 Commands and output

- `/hark joindiag` records the pre-join facts and hooks every `VOICE_CHAT_*` event the client accepts for 20 s on its own unnamed frame. It calls `Voice:Join()`, and at the end prints one line: joined or not, the events in order, and the final `GetActiveChannelID`. `/reload` saves it.
  If the numeric-id request has drawn no voice event at all after 6 s, it sends one retry with the string ids (the form a hand call proved works) and records it as `stringRetry`. This settles the id-form question in the same run. It is the only request Diagnostics sends itself.
- The join timeout now prints at most three lines, built from what was observed:
  1. the club, the stream and where it came from, and the form the request used;
  2. whether voice was logged in, and how many voice events arrived in the 10 s and which;
  3. what the channel lookup returned, and the active channel.
- `Tests/readselftest.lua` prints the join log and the join diagnostic. It ends each with a verdict naming the failing step where one can be inferred: the event guard, voice login, a JOINED failure status (with a note when the stream is missing from GetStreams), event matching, activation, or a request that produced no event at all.

### 13.6 Internal hooks

`Hark._diag.Typed` and `Voice._JoinFacts` exist for diagnostics and tests only, as in section 12.5.

### 13.7 Number formatting

This client's `string.format` raises "integer overflow attempting to store <n>" for a `%d` (or `%i`)
argument outside the signed 32-bit range. Any value that can exceed it is formatted with `%.0f`: the
settings checksum and stamp in Core, and the layer (creature-GUID zone UID) in the Positions wire
message. Remaining `%d` uses are bounded: counts, schema values, yards, and `seq`, which wraps at
999999. The test harness enforces the same limit on the shared string table.

