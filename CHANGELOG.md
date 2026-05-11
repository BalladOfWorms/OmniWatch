# Changelog

All notable changes to OmniWatch will be documented in this file.


## [1.1.0] — 2026-05-11

### Added
- **Borderless window mode**: hide the OS title bar for a cleaner look. Toggle in Settings → General → "Borderless window". With borderless on, hold Shift and drag anywhere in the window to move it. Maximize state is preserved when toggling. Setting persists across sessions.
- **Show party toggle**: hide the entire main party panel (your character + party members) for solo play. Toggle in Settings → Party → "Show party", right above the existing "Show alliance" option. Independent from the alliance toggle.

### Fixed
- **Buff timer accuracy**: timers now reflect server-truth expiry, matching Windower's built-in Timers display. Reads the 0x063 sub-9 packet directly using an empirically-verified epoch formula for current FFXI. Songs, rolls, Refresh, food, and every other buff (including ones cast on you by other players) now show the correct remaining time.
- **Buff bar "snap to 100%" on wear-off**: when a buff wore off in one slot and FFXI compacted remaining buffs into lower slots, the affected bars would visibly reset to full. Now tracks each buff's identity across slot migrations so fullness ratios stay continuous.
- **Buff timer persistence across Python reloads**: closing and reopening the OmniWatch overlay no longer loses timer fullness. Lua sends absolute Unix timestamps for buff expiry, and Python additionally saves state to `omniwatch_buff_state.json` between sessions. Bars come back correct after restart.
- **Cleaned up leftover debug chatter**: cleaned debug chatter that presents itself when casting or using ability
### Changed
- Buff timer wire format bumped to v3 with absolute timestamps (backwards compatible — older Python overlays still work with newer Lua, just without the persistence benefit).


## [1.0.0] — 2026-05-09

Initial public release.

### Added
- Party panel with HP/MP/TP, jobs, buffs/debuffs, pets, and optional alliance support
- Target & sub-target cards with mob family info, abilities, resists, BG-wiki imagery
- Player target cards with race + sex icons
- Equipment viewer for all 16 slots with extracted icons and rich tooltips
- Recast tracker (magic + abilities) with auto-hide and color-shifting bars
- Buff timer panel with wear-off flash
- DPS tracker with rolling-window display, sparklines, and CSV/JSONL logging
- Stats panel computing Acc/Att/RAcc/RAtt/Def/Eva/MAcc/MAB/etc. from gear + buffs + traits
- BLU spell-trait math with JP gift bonus handling
- Hotbar (button panel) with custom icons and right-click actions
- Inventory dropdown across all bags with GearSwap reference detection
- Header strip with Vana'diel clock, zone, and character switcher
- Sim mode for what-if calculations on jobs, gear, songs, rolls
- Server_Stats.lua passive listener for server-pushed Att/Def/Acc updates
- Setup mode (`//ow setup`) for laying out panels with mock data

### Known issues at release
- Lanun gear roll-proc accuracy may not always reflect the boosted value (server doesn't reliably push the relevant packet)
- Running multiple FFXI clients with OmniWatch on the same machine is not supported (UDP port collision). Single-client multi-character config support via the character dropdown works normally.
- Some BLU JP-category linear bonuses for MAB/MAcc are not yet wired through


---
