# Hark

Proximity voice chat for **World of Warcraft: Forever**, built on Blizzard's own in-game voice.

You join one community with voice enabled. Hark then turns everyone's volume up or down by how
far away they are: full volume close by, fading with distance, silent once they are out of range.
No external programs, nothing outside the addon sandbox.

## How it works

Blizzard gives addons no way to put a stranger into a voice channel, so Hark does not try. Instead
everyone opts in once by joining a shared community, and Hark changes only the per-player volume
sliders the client already exposes. Positions are shared over hidden addon messages.

## Requirements

- World of Warcraft: Forever (interface 16001).
- A community with voice enabled that everyone has joined.
- Everyone needs Hark installed. A player without it still hears you; you cannot place them.

## Install

```bash
./install.sh
```

This links the repository into every Forever addons folder it finds, so edits are live after a
`/reload`. Use `./install.sh --copy` if your setup ignores links, and `./install.sh --status` to
see what is installed. To install by hand, copy this folder into `_classic_beta_/Interface/AddOns/`
and name it `Hark`.

## Quick start

1. Create or join a community and enable voice for it. Everyone who wants to be heard joins it.
2. In game, run `/hark communities` to list your communities and their ids.
3. Run `/hark setcommunity <id>` with the id you want.
4. Run `/hark join`. After that Hark joins on its own at login.

## Commands

| Command | What it does |
|---|---|
| `/hark` | List all commands |
| `/hark on` / `off` | Turn proximity volumes on or off |
| `/hark join` / `leave` | Join or leave the community voice channel |
| `/hark status` | Channel, members, distances and volumes |
| `/hark communities` | List your communities and their ids |
| `/hark setcommunity <id> [stream]` | Choose the community to use |
| `/hark show` / `hide` / `toggle` | Show or hide the member panel |
| `/hark options` | Open the settings panel |
| `/hark layer` | Show the detected zone-copy (layer) id |
| `/hark backup` | Where settings loaded from, and the backup state |
| `/hark debug` | Toggle debug output |
| `/hark selftest` | Probe the client and save the raw answers (then `/reload`) |
| `/hark trace on` / `off` / `clear` | Record volumes and position messages to the saved variables |

`/ha` works as a short form of `/hark`.

## Settings

Open the panel with `/hark options`. The ones that matter most:

| Setting | Default | Meaning |
|---|---|---|
| Full voice range | 15 yd | Heard at full volume within this distance |
| Silent range | 40 yd | Completely silent at or beyond this distance |
| Min volume | 30 | Volume just inside the silent range |
| Fade curve | smooth | `linear`, `natural` or `smooth` |
| Hear unknown | off | Whether to hear members whose position you cannot get |
| Layer aware | on | Silence players confirmed to be on another layer of your zone |

## Known limitations

- **Positions reach your guild and your group only.** Custom chat channels do not deliver messages
  between players on this client, so a community member who is in neither your guild nor your group
  cannot send you their position. Hark falls back to ranging anyone your client can actually see,
  through nameplates, your target or your mouseover, but whether the client allows that for players
  outside your group is still unconfirmed. Until it is, treat Hark as proximity voice for your guild
  or group.
- **Layers.** Two players in different copies of the same zone are silenced, but only when both
  layers are confirmed. Hark confirms a layer from nearby creatures, so it needs a moment after a
  zone change.
- **Saved settings on the beta.** The beta client may not read saved variables back after a relog.
  Hark keeps its own backup in client settings and one account macro named `HarkSettings`, so your
  configuration survives. Check with `/hark backup`.
- **Volumes are restored, always.** Disabling Hark, leaving voice, or logging out puts everyone
  back to full volume. Anyone left quiet by a crash is restored at the next login.

## Development

```bash
Tests/run          # the whole suite, headless, about a second
Tests/run -v       # with addon output and Lua errors
Tests/run <text>   # only tests whose name matches
lua5.1 Tests/readselftest.lua <WTF/Account/ACCOUNT/SavedVariables/Hark.lua>   # self-test, errors, trace
```

The suite runs the real addon against a fake WoW client, with several simulated players sharing a
controllable clock, a message bus and a voice service. `CONTRACT.md` is the module contract and
describes the public surface, the settings schema, the callback events and the wire format.

## License

MIT
