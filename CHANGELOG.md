# Changelog

All notable changes to OmniWatch will be documented in this file.


## [1.4.1] - 2026-05-19

### Fixed
- **Statistics panel jumped between top and bottom alignment when dragged**: dropping the panel anywhere on screen would re-anchor it to whichever corner (top or bottom) the panel's midpoint was closer to. With a bottom anchor, the panel's height varies with setup mode (tray + save-as button appear) and with hidden cells, so the visible top would shift up/down whenever the size changed. The combined effect was a panel that appeared to "snap somewhere else" after release. The stats panel now always anchors to its top-left regardless of where it's dropped, matching the recast / buff / DPS panels — visible top-left stays exactly where it was placed, and size changes grow/shrink downward from a fixed point. Existing saved layouts with the old `bl` / `br` / `tr` anchors are migrated to `tl` on first load, preserving the panel's last visual position.

### Changed
- Readme now documents the chat panel (tabs, unread badges, scrollback, composer with say/tell/reply/shout/yell/ls1/ls2 channels, and the routing-config gear button that launches `omniwatch_routing_gui.exe`). File-layout section adds the routing GUI executable alongside `OmniWatch.exe` and the `omniwatch_chat_routing.json` + per-job `omniwatch_chat_routing-<JOB>.json` files in the per-character config block.


## [1.4.0] - 2026-05-18

### Added
- **Customizable chat routing GUI**: rebuilt the chat routing editor. Each row shows an actor → event → destination tab mapping. Two **Custom** tabs (Custom 1, Custom 2) are now available between Mob and System for user-defined buckets, with rename support (per-job or global) via click-to-edit in the GUI header. Internal ids stay stable while the display label is editable.
- **Routing GUI reset**: the Reset button now writes an empty config file immediately, giving a one-click recovery from any state.
- **Routing GUI polish**: zebra-striped rows for readability when scanning long lists; the destination column shows the user's custom tab name rather than the raw internal id.
- **Verb colorization in chat events**: gaining a buff or recovering from a debuff colors the verb yellow (good outcome); losing a buff or being afflicted with a debuff colors it pink (bad outcome). Status names keep their existing buff/debuff colors.
- **0x029 wear-off events synthesized into chat**: status wear-offs that arrive via the 0x029 action-message packet are now rendered into the Buffs / Debuffs / Mob tabs with the same format as 0x028 applies. Mirrors the wear-off coverage in BattleMod's Debuffed.lua reference.
- **DREMA weapon path-augment overlay** (`gearinfo/res/DREMA_Augments.lua`): new file with max-rank Path A/B/C augments for Relic, Mythic, Empyrean, and Aeonic weapons (single Path A) plus Dynamis-Divergence Su5 weapons (three paths). Loader in OmniWatch.lua merges entries into `ow_path_augments` with per-path granularity, so file entries override the inline table on a per-path basis. Most weapons stubbed with TODO item-id placeholders; verified entries include Heishi Shorinken, Rostam, Crocea Mors, Zomorrodnegar, all 12 Relic +3 and several Mythic +3 (Yagrush, Glanzfaust, Ryunohige, Burtgang, Liberator, Murgleis, Carnwenhan, Tizona, Death Penalty). File header documents known wiki errors and a Mythic-vs-Empyrean category warning for Ukonvasara/Conqueror.
- **Ranged damage breakdown in DPS panel**: rolling-window panel now shows ranged damage as its own stat next to White. Previously ranged hits were folded silently into the Total line, so RNG/COR couldn't see at a glance how much came from shots. Wire format bumped to v3 (field 21 = ranged_total) with full backward compatibility — older Python overlays running newer Lua still parse correctly.
- **Gear parser — `R.` abbreviations**: `R. Acc.`, `R. Accuracy`, `R. Atk.`, `R. Attack` are now recognized. Used on Raetic series and other newer ilvl pieces that abbreviate Ranged as `R.`.
- **Gear parser — `M.` abbreviations**: `M. Acc.`, `M. Accuracy`, `M. Atk.`, `M. Atk. Bns.` single-letter abbreviations for Magic Accuracy and Magic Attack Bonus, parallel to the new `R.` patterns.
- **Gear parser — Citizen of <Nation>**: items like Republican Platinum Medal's `Citizen of Bastok: "Regain"+2` are evaluated against the player's actual nation. The bonus is credited only when the nation matches; the conditional clause is stripped otherwise.
- **Gear parser — Regain**: tracked as a quoted special-attribute (parallel to `"Store TP"`, `"Dual Wield"`, `"Fast Cast"`) and flows through Gear_info to the stats panel.
- **Stats panel — gear-only Ranged Accuracy/Attack fallback**: when no ranged weapon is equipped, the panel falls back to displaying the raw gear contribution from Gear_info instead of zeroing out. The panel always reflects what gear gives the player, even on melee setups — useful for verifying gear contributions on a build before committing to it.
- **Slash commands**:
  - `//ow gearcache_clear` (alias `//ow cachebust`): deletes the persisted gearinfo cache and re-runs the inventory parser. Required after parser changes for owned items to pick up new substitution rules; without it, cached items keep their previously-parsed stats.
  - `//ow geartrace`: toggles a diagnostic tracer in the description-substitution pipeline. Prints when desypher_description runs and when specific substitutions fire, so users can verify a new Gear_Processing file is actually loaded.
  - `//ow dumpgi`: prints the aggregated Gear_info table (non-zero values only). Pinpoints whether a gear stat is being lost in parse, aggregation, compute, or wire emission.

### Changed
- **Chat routing defaults**: every combat-adjacent event (battle, melee, ranged, magic, weapon-skill, buff/debuff apply/wear) now defaults to the Battle tab. The Buffs, Debuffs, and Mob tabs are empty buckets users can redirect into via the routing GUI. Mob misses are visible by default.
- **Chat routing GUI — actors flattened**: combined the previous "Monsters (engaged)" and "Enemies (passive)" sections into a single flat "Monsters" actor. The runtime classifier only outputs flat `mob` anyway. Legacy nested configurations are migrated automatically on load with a hide-wins conflict policy.
- **Chat panel header counter**: simplified from "N text / N battle" to "Chat (N events)".
- **Buff timer — cross-tick identity**: buff reconciliation now keys on `(buff_id, expires_at)` with a 2.5s tolerance window. Fixes phantom wear-off flashes on still-alive buffs and tier-name regressions (e.g. "Honor March" briefly displaying as generic "March") caused by Lua's os.time()/os.clock() drift jittering the emitted timestamps by up to 1 second across ticks.
- **Equipment panel header**: fixed bold "EQUIPMENT" label with a separator line matching the Statistics panel style. Previously showed the active gearswap set or state, which was visually noisy. Gearswap set/state values are still tracked elsewhere for other purposes.
- **Chat tabs reorganized**: Battle 2 removed; Battle 1 renamed to Battle and now actually filters combat messages via `CHAT_MODE_SET_BATTLE` (was an empty stub returning False); Custom renamed to Custom 1 to pair with the new Custom 2; tab strip uses full names ("Battle", "System", "Custom 1", "Custom 2") instead of the prior 3-4 char abbreviations.
- **Battle tab colored red** in the tab palette. Realigned `CHAT_TAB_PALETTE` indices 5-8 which had drifted out of sync with `chat_tab_names` after the rename — previously the System tab was rendering with the old "B1" purple, etc.
- **DPS panel grid expanded to 5 rows**: damage-type rows group on top now (White/Ranged auto-attack on row 1, WS/Magic active damage on row 2). Combat-quality stats fill rows 3-4 (Hits, Crit%, Acc%, Mag%). Evd% takes a half-row at the bottom alone; the empty right cell is intentional rather than padded with a contrived metric. SC row still appends as row 6 when there's been any skillchain activity.

### Fixed
- **BLU stats panel showed "like no gear is equipped"**: switching to BLU produced empty acc/att/eva/def stats because all four `get_player_*_from_job` BLU branches in Gear_Processing.lua accessed `Blu_spells[spell_id].trait` unguarded. Equipped BLU spells with IDs past 728 (anything added in patches after the local `Blue_Mage_Spells.lua` table was generated) returned nil, and `nil.trait` crashed the function. `compute_player_stats`'s pcall caught the crash silently, leaving `result.acc/att/eva/def` all nil and the panel rendering with stale/empty values. Five sites now nil-guard `Blu_spells[spell_id]`: the `get_blue_mage_stats_from_equipped_spells` helper plus the BLU-only branches inside `get_player_acc/att/eva/def_from_job`. Missing spells now contribute 0 instead of aborting the whole compute.
- **DPS panel did nothing**: Lua's DPS wire format string at OmniWatch.lua line 5529 had 17 format specifiers but was being passed 18 values; Lua's `string.format` silently dropped the trailing `dps` value, so each packet emitted only 18 fields. Python's parser requires `len(fields) < 19` and was rejecting every single DPS packet as a parse failure (logged to console, never reaching `dps_state`). Format string fixed and specifier types realigned with Python's parse expectations (was also misaligned at positions 11, 15, 17 — `%.1f` where Python read int and vice-versa).
- **Heishi Shorinken Path A augment**: the inline `ow_path_augments[20977]` entry listed `Ranged Accuracy +30` per FFXIclopedia, but the in-game item description reads `Accuracy +30` (melee). Wiki was wrong. Confirmed against in-game text and corrected in both the inline table and the new DREMA_Augments file. On a NIN equipped only with Heishi, this restores the missing +30 melee accuracy that user testing isolated as a known gap.
- **Console chatter on every reload**: high-mode chat-packet drop diagnostic was printing red `[OW] dropped chat mode=N` lines to the FFXI console on every session. Removed the print entirely. Future diagnosis uses `//ow chatpkttrace` which writes to a log file without touching chat.
- **Phantom "Wormfood gains 'Afflatus Solace'"**: msg-id 327 was producing false positives even when the player wasn't WHM and hadn't used the ability. Removed from the status-apply set until its actual trigger conditions are understood. Songs (msg-id 230) remain handled.
- **R. Accuracy gear stat dropped despite being parsed**: a chain of three separate bugs prevented Raetic bangles +1's +55 Ranged Accuracy from reaching the panel:
  1. The description's `R. Accuracy+55` shorthand wasn't covered by any existing substitution pattern (now added).
  2. Even after the new pattern was in place, the parsed values were served from the persisted gearinfo cache rather than being re-parsed (the new `//ow gearcache_clear` command nukes the cache).
  3. With a correct Gear_info value, `get_player_acc` was returning range=0 anyway because the player had no ranged weapon equipped, and the result clobbered the panel's display. The lua→python copy now falls back to the raw Gear_info value in that case.


## [1.3.0] — 2026-05-12

### Added
- **Exit OmniWatch button**: Settings → General → "Exit OmniWatch" (top of section, labelled EXIT). Saves layout and buff state snapshot, then quits cleanly. Use this instead of force-killing the process so panel positions and buff durations survive to next launch.
- **Full Screen toggle**: Settings → General → "Full screen" (directly under Exit). One click fills the monitor the window is currently on at its full native resolution — including over the taskbar — with correct DPI scaling on any monitor (the process is per-monitor DPI aware). Click again to restore the previous size and position. Button label flips between FULL and RESTORE to reflect state. Combine with Always on top for a fullscreen overlay over the game.

### Changed
- **Window is always borderless**: OmniWatch no longer has an OS title bar at any point. Previously borderless mode was a runtime toggle (Settings → General → "Borderless window") that defaulted off and snapped fullscreen on; now the window starts borderless, stays borderless for the entire session, and the toggle is gone. Move the window by holding Shift and dragging anywhere inside it (same as 1.2.x borderless mode). Resize via Full Screen toggle (above) — there are no edge handles. Quit via the Exit button in Settings (no OS [X]).
- **Settings menu reorganization**:
  - **Inventory section renamed to Header** and moved to right under General. The settings in it (Show 'Bags' button, Gearswap folder) are header-row widgets, and grouping them with the other header items (clock offset, zone-timer reset) makes the mental model clearer.
  - **Adjust Vana'diel time** moved: General → Header.
  - **Reset zone timer** moved: General → Header.
  - **Open log folder** moved: General → Developer (it's a debugging tool, not an everyday setting).
  - New section order: General → Header → Party → Equipment → Statistics → Recast Timer → Buff Timer → Target Card → DPS Tracker → HotBar → Developer.

### Removed
- **Borderless window setting** (`borderless_window` in settings.json): made unconditional, so the toggle is gone. Stale keys in upgraded settings.json files are ignored harmlessly.
- **Per-mode panel layouts** (`window_mode_layouts` in omniwatch_layout.json): the framed-vs-borderless layout-swap mechanism is gone since there's only one window mode now. Stale keys in upgraded layout files are ignored harmlessly. Your current panel positions are preserved — only the (unused) secondary slot is dropped.


## [1.2.0] — 2026-05-12

### Added
- **Customizable stats panel layout**: hide cells you don't need and drag cells to any position. Settings stored per-character and per-job. Two scopes:
  - **Global hidden**: cells hidden everywhere, on every job. Use for stats you never want to see.
  - **Per-job hidden**: cells hidden only on that specific job, additive on top of global. Use for stats irrelevant to a specific role (e.g. MAB on COR).
- **Setup-mode stats panel UI**: enter setup mode (`//ow setup`) to edit the layout interactively.
  - Click any cell to toggle hidden (dimmed in place with a red slash)
  - Drag cells anywhere to reorder — drag freely across the entire panel
  - Hidden cells appear as clickable chips in a tray below the panel; click a chip to restore
  - "Save as ▼" dropdown commits your edits to Global, Current Job, or any specific job
  - Edits are in-memory until saved — exiting setup mode without clicking "Save as" discards changes
- **Linear-flow uniform-cell layout (v2.0)**: stats panel rebuilt around a uniform 7-column grid where any cell can occupy any slot.
- **"Empty" spacer cells**: 4 invisible spacer cells (`_empty1`–`_empty4`) that can be dragged anywhere to create deliberate gaps in the layout. Visible only in setup mode; truly invisible during normal play.
- **JSON-edit fallback**: Settings → Statistics → "Edit stats layout" opens `omniwatch_stats_layout.json` directly for power users who prefer editing config files.
- **Resist cell redesign**: now shows active elemental resists as compact color-coded text (e.g. "Fire+25" in red, "Ice+15" in blue) instead of icons. Fits in a uniform-size cell alongside other stats.

### Changed
- **Stats panel architecture (v2.0 refactor)**: the prior section-based layout (Primary, Haste, Defense, etc., each with fixed dimensions) has been replaced with a unified flat ordering. Cells are all the same width now; the previously-wider elemental cells use compact labels.
- Backward compat: existing v1.1 saved layouts (per-section dicts) are auto-flattened to the new linear order on first read. Your hides and ordering are preserved.

### Fixed
- **BLU job crash (`attempt to perform arithmetic on local 'v' (a table value)`)**: switching to BLU could crash when computing trait points. The trait-summation loop didn't account for non-trait metadata fields (`vitals`, `id`, `level`) in BlueMagic.lua entries; now those are explicitly skipped, and only numeric values are summed. Also fixes silent corruption of trait totals that may have been ongoing before the crash.
- **Trust Primer / food crash (`attempt to call global 'ow_parse_desc_line' (a nil value)`)**: using a consumable item could crash the addon due to a forward-reference issue — the function was declared `local` after the closure that referenced it, so the upvalue resolved to nil at call time. Forward-declared the local so all consumers share the same slot.
- **Stats layout not persisting between sessions**: saved layouts weren't being read on subsequent launches. The load was being skipped because of a startup shortcut that runs when the character pre-selection heuristic guesses correctly. Added a deferred load call right before the main loop so layouts always load regardless of which startup path fires.


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