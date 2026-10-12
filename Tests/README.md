# Hark headless tests

Runs the real addon files on Linux against a fake WoW client, so most bugs
show up in under a second instead of after a login.

## Run

```sh
Tests/run              # whole suite; exit code 0 = all passed, 1 = something failed
Tests/run -v           # also echo every addon print and Lua error as it happens
Tests/run negative     # only tests whose name or spec file contains "negative"
```

It needs a Lua 5.1 interpreter (WoW runs 5.1). The script uses `lua5.1`, then
`luajit`; on this machine both come from the Arch packages `lua51` and
`luajit`, nothing else is installed. Set `LUA=/path/to/lua` to choose one.
To point the suite at another copy of the addon (e.g. to check a test catches a
deliberately broken build): `HARK_ADDON_DIR=/some/copy Tests/run`.

## Layout

| Path | What it is |
| --- | --- |
| `run` | Shell entry point |
| `runner.lua` | Finds `spec/*_spec.lua`, runs each test, prints PASS/FAIL/SKIP |
| `harness/world.lua` | The simulated world: players, positions, layers, zones, the addon-message bus, the voice service |
| `harness/wowapi.lua` | The global environment one client gives addon code (the mock API) |
| `harness/loader.lua` | Reads `Hark.toc` and runs each listed file with `(addonName, privateTable)` varargs, like the client |
| `harness/clock.lua` | Deterministic clock; time only moves when a test advances it |
| `harness/events.lua` | Event names the client knows (unknown ones raise, as in game) |
| `harness/sim.lua` | Scenario helpers for specs |
| `spec/` | The tests |

## How it works

Every simulated player is a separate client with its **own Lua environment**
running its own copy of the addon, exactly as in game. They share one clock,
one realm, one addon-message bus and one voice service. Alice's addon
broadcasts its position, the bus delivers it to Bob's `CHAT_MSG_ADDON`, Bob's
addon calls `C_VoiceChat.SetMemberVolume`, and the test asserts on what the
voice engine now has stored: `world:Hears("Bob", "Alice")`.

Addon code runs the way the client runs it: a Lua error in an event handler,
timer or slash command is caught and recorded, other handlers carry on. Any
Lua error recorded during a test fails that test, with the message, unless the
test calls `t:allowLuaErrors()`.

Tests are black-box where possible (slash commands in, voice volumes out), so
they survive refactors. `03_curve_spec.lua` is the exception: it calls
`Hark:GetVolumeForDistance` directly and skips if it does not exist.

## Writing a test

```lua
local T = ...
local Sim = T.helpers

T.test("near player is heard", function(t)
    local w = Sim.Scenario(t, { players = {
        { name = "Bob",   x = -100, y = -200 },        -- first is the listener
        { name = "Alice", x = -95,  y = -200 } } })    -- everyone joins voice
    t:eq(w:Hears("Bob", "Alice"), 100, "Bob hears Alice")
end)
```

Useful world calls: `AddPlayer{name, x, y, instanceID, zone, mapID, layer,
guild, group, addon=false}`, `Advance(seconds)`, `SetPosition`, `MoveTo(name,
x, y, speed)`, `ChangeZone(name, {zone=, mapID=, instanceID=})`,
`SetLayer`, `ShowCreature(name, "target"|"mouseover"|"nameplateN", npcID)`,
`SetGroup`, `SetDead`, `SetCombat`, `UserJoinsVoice`, `UserLeavesVoice(name, abrupt)`,
`InjectAddonMessage`, `Hears`, `VolumeSetting`. Per client: `c:Slash("/hark
on")` (returns printed lines), `c:Reload()`, `c:Logout()`, `c:RestartClient()` (registered CVars lost; built-in CVars, SavedVariables and macros kept), `c:NS()`,
`c.sent`, `c.received`, `c.prints`, `c.errors`. World options (passed as
`Sim.Scenario(t, { world = {...} })` or `t:world{...}`): `latency =
function(from, to, msg) return seconds or nil-to-drop end`,
`voiceMemberNames`, `senderIncludesRealm`, `channelAddonDelivery`,
`strictEvents`, `throttleBurst`, `throttleRate`, `voiceJoinDelay`.

Assertions: `t:eq`, `t:near(v, expected, tol)`, `t:between(v, lo, hi)`,
`t:ok`, `t:require` (stops the test), `t:skip(reason)`, `t:note(text)`.

## What is simulated faithfully

- `UnitPosition` returns **`posY, posX, posZ, instanceID`** (four values,
  `posZ` always 0), negatives included; nil inside instances and for anyone
  who is not you or a group member.
- `C_Timer.After` returns **nothing**; only `NewTimer`/`NewTicker` return a
  cancellable handle. `After(0)` runs next frame, never in the same pass.
- `Frame:RegisterEvent` **raises** on an unknown event name.
- `CHAT_MSG_ADDON` sender is `"Name-Realm"` (realm normalised, no spaces),
  even on your own realm. GUILD/PARTY messages echo back to the sender.
- `SendAddonMessage` returns an `Enum.SendAddonMessageResult` code; SAY/YELL
  are rejected (4); per-prefix throttle is a burst of 10 then 1/s (3), as
  measured on the Forever beta. Messages over 255 bytes are rejected.
- Latency, loss and reordering are per message and under test control.
- Every client has a different `GetTime()` (seconds since its own boot).
- `C_VoiceChat.GetChannel().members[i].name` is **nil** (beta behaviour);
  identity comes from `GetMemberGUID(memberID, channelID)`. Channel IDs are
  per client and never equal the clubId.
- `RequestJoinAndActivateCommunityStreamChannel` returns nothing; the result
  arrives later as `VOICE_CHAT_CHANNEL_JOINED(status, channelID, type, clubId,
  streamId)` then `VOICE_CHAT_CHANNEL_ACTIVATED`. Others get
  `VOICE_CHAT_CHANNEL_MEMBER_ADDED` / `_GUID_UPDATED`. Leaving fires
  `_DEACTIVATED` (channel still queryable), then `_REMOVED`.
- `SetMemberVolume` requires a real `PlayerLocation` (raises otherwise).
- Layers are invisible to `UnitPosition`; they appear only in field 5 of the
  creature GUIDs you see (target, mouseover, nameplates).
- SavedVariables persist across `c:Reload()`; voice membership and member
  volumes belong to the client, so they survive a reload too.
- `C_CVar`: built-in CVars (`World.BUILTIN_CVARS`, e.g. `nameplateShowFriends` = "0") survive restarts; registered ones survive reload/relog only. Macros are server-side: 120 account + 18 character slots, 255-char bodies, Create/Edit/Delete raise in combat, `UPDATE_MACROS` fires next frame.
- Lua 5.1 semantics, and only the library subset WoW exposes (no `io`,
  `require`, `dofile`, `os.exit`).

## What is assumed or not simulated

These are guesses or simplifications. Each is marked `MOCK:` in the source.

- **Member volume persistence:** the mock keys `SetMemberVolume` by speaker
  GUID and keeps it after leaving the channel. That is why restore tests
  matter. Unverified on the live client.
- **Volume scale** assumed 0-100.
- **A VoiceID PlayerLocation stops resolving once its channel is gone** (it is
  silently ignored and logged in `client.voiceInvalid`). Unverified.
- One realm only; no cross-realm names. `GetPlayerInfoByGUID` knows every
  player in the world (the real one only knows players the client has seen).
- No LFG/battleground instance groups (`IsInGroup(LE_PARTY_CATEGORY_INSTANCE)`
  is always false). No raid subgroups.
- Map data is fake: zones are mapType 3 with a continent parent; map positions
  are normalised against a fixed square, not real zone rectangles.
- CHANNEL addon messages are delivered to other channel members by default;
  on the beta only the echo to the sender is confirmed (`channelAddonDelivery`).
- No secret values (`issecretvalue` does not exist in the mock).
- Widgets: common methods behave; any other widget method is accepted and does
  nothing (logged in `world.warnings`). The real client would raise. UI
  layout, textures and fonts are not checked at all. XML files are skipped.
- Frame rate is a fixed 20 fps; real frames jitter.
- Voice audio itself, speaking/energy events and push-to-talk are not modelled.

When the mock disagrees with the game, fix the mock and note the source.
