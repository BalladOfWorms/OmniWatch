# Changelog

All notable changes to OmniWatch will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
-

### Changed
-

### Fixed
-

### Removed
-


## [1.0.0] — YYYY-MM-DD

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
- Multi-boxing on the same machine is not supported (UDP port collision)
- Some BLU JP-category linear bonuses for MAB/MAcc are not yet wired through


---

# How to maintain this file

When you ship a new release:

1. Move everything in **[Unreleased]** down into a new version block with today's date
2. Reset the **[Unreleased]** section to empty `Added/Changed/Fixed/Removed` headers
3. Bump the version per semver:
   - **patch** (1.0.0 → 1.0.1) — bug fixes only
   - **minor** (1.0.0 → 1.1.0) — new features, backwards compatible
   - **major** (1.0.0 → 2.0.0) — breaking changes (config format changes, removed features, etc.)

## Categories

- **Added** — new features
- **Changed** — changes to existing functionality
- **Fixed** — bug fixes
- **Removed** — features removed in this release
- **Deprecated** — features that still work but will be removed in a future release
- **Security** — vulnerabilities patched

Keep entries short. Prefer "what changed for the user" over "what changed in the code". Bad: "Refactored buff_processing.lua to use event bus". Good: "Buff timers now update faster after a song is recast".