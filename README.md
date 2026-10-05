# Hark

Proximity voice chat for World of Warcraft: Forever using Blizzard's in-game voice.

## Overview

Hark lets players in the same zone hear each other through voice chat, with volume falling off based on distance. Everyone within earshot is audible; those beyond range fade to silence.

- **Works on any ruleset** (Normal, PvP, RP, Hardcore)
- **No external programs** — uses Blizzard voice directly
- **Opt-in** — join a community once, then Hark prompts you on zone entry
- **Configurable ranges** — adjust how far you can hear and when voices fade

## Installation

1. Download or clone this repo into your WoW Forever `Interface\AddOns\` folder
2. Name the folder `Hark` (not `hark-main` or similar)
3. Restart WoW or type `/reload`
4. Type `/hark help` to see commands

## Quick Start

1. **Join or create a community** in-game (Communities tab, press **J**)
   - Name: something like "Proximity Voice" or "Earshot"
   - Invite your guildmates or friends
   - Enable voice chat for the community

2. **Configure Hark** to use that community (settings coming soon)
   - For now, see the `Core.lua` file for the default community ID

3. **Move between zones** — Hark will prompt you to join proximity voice
   - Accept the prompt, and you'll hear others in the channel
   - Leave the zone, and you'll automatically leave voice

## Commands

- `/hark` or `/ha` — show help
- `/hark on|off` — enable/disable proximity voice
- `/hark status` — show current channel and member count
- `/hark options` — open settings (not yet implemented)

## Known Limitations

- **One community per session** — you cannot hop between communities while moving
- **Everyone needs the addon** — non-addon players hear the whole channel at normal volume
- **Voice channel cap unknown** — if the community voice fills up, Hark will retry
- **No layering awareness yet** — players on different layers may be heard as if they are nearby

## Development

**Beta test checklist (by 21 October 2026):**
- [ ] Test 1: Addon messages on temporary player-made channel deliver to strangers in the same zone
- [ ] Test 2: Voice channel cap and error handling
- [ ] Test 3: Layer ID detection from NPC GUIDs

**Road map:**
1. ✅ Core position sharing and volume attenuation
2. ⏳ UI panel (members, quick mute, status)
3. ⏳ Options menu (community selection, range settings)
4. ⏳ Layer detection and handling
5. ⏳ Mumble positional audio integration (optional, separate build)

## License

MIT
