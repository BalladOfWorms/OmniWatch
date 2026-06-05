# Changelog

All notable changes to OmniWatch are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/), with versions following [semver](https://semver.org/).

## [1.6.3] — 2026-06-05

A BLU stat-accuracy bug-fix pass. The headline is a nasty set-spell bug: removing a spell from the middle of your BLU set caused OmniWatch to silently see only **one** spell, which zeroed out Dual Wield and dropped Defense/Evasion across the board. That's fixed, along with the BLU spell-trait Defense Bonus (which had regressed to contributing nothing) and Master-Level PLD subjob Defense Bonus reaching its correct tier.

### Fixed

- **BLU set-spell list collapsed when a spell was unset from the middle of the set** — unsetting a spell (e.g. via bluGuide) leaves a gap in the game's set-spell array, and OmniWatch read that array with an iterator that stops at the first gap. The result: every spell *after* the removed one was silently dropped, so a 15-spell set could be read as a single spell — collapsing Dual Wield to 0 and dropping Defense/Evasion/Attack to whatever the subjob alone provided. The set is now read with a gap-safe walk that collects every set spell regardless of holes, so editing your set mid-list no longer breaks trait computation.
- **BLU spell-trait Defense Bonus restored** — the Defense Bonus granted by your set spells had regressed to contributing nothing (defense read ~62 low on subjobs without their own Defense Bonus, ~40 low on /WAR). The BLU spell Defense Bonus trait now feeds defense exactly the way Accuracy/Attack/Evasion Bonus already do, so total defense is `max(subjob Defense Bonus, BLU spell Defense Bonus)` as the game computes it.
- **PLD subjob Defense Bonus III for Master-Level subjobs** — a /PLD sub at level 50+ (reachable via Master Levels) now correctly grants Defense Bonus III (+35) instead of being capped at II (+22). Fixed in both the base defense (vendored GearInfo's `get_player_def_from_job`) and OmniWatch's max-not-sum subtraction so the two stay in agreement. (Mirrors the same Master-Level fix done for subjob Evasion Bonus in 1.6.2.)
- **Equipment tooltip leaking through the settings menu** — hovering over the area where the equipment panel sits while the settings menu (or any settings/config modal) was open would show the gear item's stat tooltip on top of the menu. Tooltips are now suppressed whenever the settings menu or any settings modal is open.

### Internal

- **Gap-safe set-spell read** — `ow_get_blu_set_spells()` now walks `get_mjob_data().spells` with `pairs()` instead of `ipairs()` (which halts at the first `nil`), with a de-dupe guard, so a sparse set array (the result of a mid-list unset) is fully collected.
- **PLD subjob Defense Bonus tier kept in sync** — the OmniWatch-side `_sub_def_bonus` subtraction and GearInfo's base `get_player_def_from_job` now both grant PLD sub 35 at level 50+, so the BLU defense merge subtracts the correct already-counted subjob value.
- **Two BLU spell-data files clarified** — OmniWatch loads its BLU spell trait/stat table from `data/resources/BlueMagic.lua`; the vendored GearInfo loads its own `Blu_spells` global from `Blue_Mage_Spells.lua`. Both files are required (deleting the GearInfo one breaks GearInfo's load); per-spell stat corrections that should affect the panel go in `BlueMagic.lua`.


## [1.6.2] — 2026-06-04

A correctness and polish pass. The big-ticket items: Master-Level subjob evasion now tiers correctly, the Unity Ranking gear-stat scaling formula was reverse-engineered from in-game data and fixed (it had been over-counting on every non-first-place Unity), equipment tooltips became rich FFXIAH-style stat blocks, and the linkshell message-of-the-day display was overhauled so both LS1 and LS2 show one clean, correctly-named, correctly-colored line.

### Added

- **Rich equipment tooltips** — hovering a gear slot now shows a full FFXIAH-style stat block: item name, the item's stat lines (DEF, CHR+, "Pet:" effects, Damage taken, Unity Ranking, etc.), augments (in light blue), and a footer with item level, level requirement, and jobs. Previously the tooltip showed only the item name. The stat-line text is parsed from the in-game item description on the Lua side and forwarded to the overlay; the tooltip word-wraps to a fixed width and wraps long job lists across multiple rows so it stays a tidy block. Both the live equipment panel and any future saved-set view share this one renderer.
- **`equipment/` module (scaffolding)** — the first extracted OmniWatch submodule, a foundation for a saved gear-set reference panel (named sets rendered as icon grids, FFXIAH-style). Built with dependency injection so it never imports the main module (no circular-import risk) and bundles into the .exe automatically via the normal import graph. Not yet wired into the UI — pure groundwork for now.

### Changed

- **Subjob Evasion Bonus extended to the full ladder for Master-Level subjobs** — with the Master Level system the subjob level cap rose past the old 49 (e.g. 55), so a /THF sub at level 50+ now correctly reaches Evasion Bonus III (+35) instead of being capped at II (+22). The full BG-wiki Evasion Bonus ladder is now used for THF/DNC/PUP subjobs, driven by the game-reported subjob level. Fixed in both the base evasion (vendored GearInfo's `get_player_eva_from_job`) and OmniWatch's max-not-sum subtraction via a single shared ladder so the two can never disagree. (Also corrected a stale PUP tier-I breakpoint: 25, not 20.)

### Fixed

- **Unity Ranking gear-stat scaling** — the rank-based scaling of "min~max" Unity Ranking stats (e.g. a neck's "Evasion+5~15") used a linear interpolation across all 11 ranks, which over-counted for any non-top Unity (it gave +11 for a 5~15 stat at rank 5 when the game grants +7). Reverse-engineered from two in-game data points and corrected to the real formula: `value = max − (rank − 1) × (max − min) / 5`, floored at min. So rank 1 = max, each rank below subtracts one-fifth of the range, and ranks 6–11 all sit at the minimum. This removes a per-item evasion/stat over-count on every ranked Unity piece for non-first-place Unities.
- **Linkshell MoTD — LS2 no longer missing** — the LS2 message-of-the-day was being silently dropped by the high-mode whitelist in `emit.lua` (mode 217 wasn't listed, while LS1's mode 205 was), so LS1's MoTD showed and LS2's didn't. Mode 217 is now whitelisted and routes to the LS2 tab.
- **Linkshell MoTD — correct name and no duplicate** — the LS message-of-the-day previously showed twice (the FFXI client's native line plus OmniWatch's own copy), and OmniWatch's copy could show the wrong linkshell name (the LS1 name on an LS2 message) because it read the unreliable `player.linkshell2` field. OmniWatch's duplicate emit is now suppressed; the native client line is the single canonical MoTD, which always carries the correct LS name and set-date.
- **Linkshell MoTD — consistent green coloring** — both the LS1 (mode 205) and LS2 (mode 217) message-of-the-day lines now render in the linkshell green instead of falling through to default gray/white, so the two linkshells' MoTDs look identical.
- **Tooltip glyph rendering** — Unity Ranking range separators (the wave dash / fullwidth tilde FFXI uses in "10~15") rendered as a missing-glyph box in Consolas; these are now normalized to an ASCII tilde. Assorted unicode dash/minus glyphs in stat lines are likewise normalized to a plain hyphen so "Damage taken −1%" reads cleanly.

### Internal

- **Shared subjob Evasion Bonus ladder** — the THF/DNC/PUP evasion tier tables are now expressed once (as `OW_BLU_EVA_SUB_LADDER` + `ow_sub_eva_bonus()` in OmniWatch.lua, mirrored in GearInfo) so the base computation and the trait subtraction read identical values.
- **Rich-tooltip wire protocol** — the 5007 equipment-metadata packet gained a trailing stat-lines field (description lines joined by `;;`); the Python parser is length-guarded so older/newer builds interoperate without breaking.


## [1.6.1] — 2026-06-03

A BLU stat-accuracy pass plus a few chat-color and quality-of-life fixes. The headline is a thorough reverse-engineering of the bluGuide trait model and a validation campaign against in-game `/checkparam` ground truth: the BLU stats panel now matches the game across the full set of trait categories and primary-stat conversions, with subjob trait contributions handled the way the game actually resolves them (highest single source, not a sum). Also: BLU spell primary stats (STR/DEX/VIT/AGI) now convert into their derived combat stats, several chat sender colors were corrected, and the companion bluGuide overlay can now be dragged around the screen.

### Added

- **BLU spell primary-stat conversions** — primary attributes carried by set spells now convert into the combat stats they feed, matching GearInfo's own rates (and previously missing entirely from the BLU path):
  - **DEX → accuracy** at `floor(DEX × 0.75)` (mirrored to off-hand and ranged when those weapons are equipped)
  - **STR → attack** at `floor(STR × mul)` where `mul` is 0.75 for Hand-to-Hand, 1.0 otherwise; off-hand `floor(STR × 0.5)`, ranged `floor(STR × 1.0)`
  - **VIT → defense** at `floor(VIT × 1.5)` (the game's `floor(3·VIT/2)` rate)
  - **AGI → ranged accuracy** at `floor(AGI × 0.75)` and **AGI → evasion** at `floor(AGI × 0.5)`
  - The raw attributes continue to show in their own primary-stat cells; these conversions add the derived combat contribution on top, so e.g. a set spell with VIT now raises both the VIT cell and Defense. Magic accuracy from INT/MND/CHR is intentionally **not** converted — in-game it's the dStat (caster vs. target) mechanic, not a flat self-bonus, so a fixed rate would read wrong against `/checkparam`.
- **Draggable bluGuide overlay** — the companion bluGuide spell-planner display now has a small "drag" handle; grab it to move the entire display (spell list, trait/buff/proc/damage columns, and menu buttons) together. Position persists across reloads. (Lives in bluGuide's `bluguide.lua`; the shared UI modules are untouched.)

### Changed

- **BLU subjob traits now resolve as max-not-sum** — for the four traits the gear/stat engine also derives from your subjob (Accuracy Bonus, Attack Bonus, Evasion Bonus, Defense Bonus), the subjob contribution and the BLU set-spell contribution are the **same trait** and the game takes the higher single source, not the sum. The panel now folds the subjob's value via `max(spell-pool, subjob)` for the tier and subtracts the subjob's already-counted value at merge time so it isn't double-counted. Subjob breakpoints mirror the engine's exact level tables (e.g. Evasion Bonus: THF 10/30→10/22, DNC 15/45→10/22, PUP 20/40→10/22; Defense Bonus: PLD 10/30→10/22, WAR 10/45→10/22).
- **BLU trait model rewritten to match bluGuide** — subjob trait contributions are now expressed as **points** (e.g. /DNC = 8 Accuracy-Bonus points, /RNG = 16) and folded into the trait pool via `max(spell_points + gift, subjob_points)` before a single tier lookup, exactly as the bluGuide reference addon does. This replaces the earlier hardcoded per-trait subjob value with the principled points-based model, so it generalizes correctly across traits and subjobs.

### Fixed

- **BLU gift unlock gate** — a job-point gift could previously lift a trait to tier I from fewer than the 8 points the game requires to unlock it (e.g. a single 4-point Accuracy spell + 2 gifts wrongly read as +22 accuracy). Gifts now apply only once a trait is already unlocked by spell points alone (≥ first threshold), matching the BG-wiki hotfix behavior. Validated against isolated no-subjob captures: every single sub-8-point spell now reads 0.
- **BLU evasion / defense double-count** — with an Evasion- or Defense-Bonus subjob (e.g. /DNC eva, /WAR def), the panel previously summed the subjob's bonus (already in the base) with the BLU trait, reading ~10–22 high. Now handled by the same max-not-sum subtraction as accuracy/attack.
- **BLU set-spell change detection** — swapping set spells didn't always recompute the stats panel (the change-detector watched gear and buffs but not the equipped spell set), so the same test could show different results depending on timing. A set-spell signature check now runs on both the fast (10 Hz) and slow (1 Hz) poll paths, so a spell swap reliably triggers a fresh recompute.
- **Assist channel sender color** — assist-channel messages now color the sender name teal to match the Assist tab, on both the packet path and the text path.
- **Shout sender color** — shout sender names now render in a dark orange distinct from yell's orange-yellow, so the two channels are easy to tell apart at a glance.

### Internal

- **Lua chunk-local limit relief** — the main `OmniWatch.lua` chunk hit Lua 5.1's hard cap of 200 local variables. Twelve single-value buff-id constants were converted from top-level locals to globals (same names, same read-only use), bringing the count back to 187 with headroom. No behavior change.
- **bluGuide model captured as reference** — the subjob points tables, tier values, and gift-exempt trait list were lifted from bluGuide's `res/traits.lua` and validated end-to-end against two full 21-combination `/checkparam` runs (no-subjob and /DNC), matching within ±1 (the residual is the DEX→accuracy `floor` rounding, a real game mechanic).


## [1.6.0] — 2026-05-30

A settings-menu rework plus a handful of new header features. The big behavioral change is a wholesale rework of the in-game settings dropdown: nearly every panel now exposes a single light-blue **CONFIGURE** button that opens a focused subdialog, instead of a long inline checkbox list. Same options, much shorter dropdown. Alongside the menu cleanup: a new OS clock + stopwatch/countdown in the header, an enchanted-ring cooldown tracker in the equipment panel (Warp / Dem / Holla / Mea / Echad / Trizek / Reraise / Endorsement / Emporox), an Events-modal banner row showing airship and ferry schedules, three new currencies in the header cycler, and a /say chat color fix.

### Added

- **Configure-button subdialogs** for Display, Header, Currency cycler, Inventory, Party Panel, Statistics, Recast Timer, Buff Timer, Chat Panel, Skillchain, Target Card, DPS Tracker, HotBar, and Equipment. Each one collapses 3–8 settings into a focused popup. Closing a subdialog automatically reopens the parent settings dropdown so multi-panel tweaks don't require re-clicking the gear icon every time.
- **Header visibility toggles** — `show_time`, `show_weather`, `show_events`, `show_location`. Each one hides a whole logical block (clock + day + moon as a unit; weather; Events button; right-side zone/region/map). The header collapses cleanly when any of them is off — no phantom gaps where the hidden block used to live.
- **Events modal banner row** — airship and ferry schedules now sit alongside the existing Records of Eminence / Domain Invasion banners. Each shows the next departure with a live countdown and auto-cycles through routes every 4 seconds. Schedule data is ported from the public-domain VanaTime library.
- **Three new currencies** in the header cycler: **Beads** (Escha Beads), **Tokens** (Nyzul Tokens), **Ichor**. Display labels use single-word forms to match the existing convention; storage keys keep the full names (`escha_beads`, `nyzul_tokens`, `ichor`) for clarity in logs and at the wire. The Lua side emits all nine currencies in the `CURRENCY|…` UDP payload, with multiple `fields.lua` label aliases registered for the new ones to maximize compatibility across Windower installs.
- **Display Configure modal** — window opacity, global UI scale (0.5×–3.0×), transparent background, and toggle nub visibility all consolidated into one dialog.
- **Statistics Configure modal** with a small italic helper line under "Gear settings": _Define self or ally gear that affects buffs._
- **Header OS clock** — local-time HH:MM (am/pm) clock anchored 18px left of the zone block. Renders in `font_day` (13pt bold) on the same baseline as Vana time and day name. Hidden via **Show OS clock** in the Header Configure modal.
- **Header clock — show seconds toggle** — optional HH:MM:SS format for timing-sensitive activities.
- **Header clock — time-zone selector** — pick from `Local / UTC / PST / MST / CST / EST / BRT / GMT / CET / EET / JST / KST / AEST`. "Local" uses your computer's clock (DST-aware); the named zones use their standard-time offset (no DST tracking — fine for JST/server-time coordination where DST isn't observed).
- **Stopwatch + Countdown timer modal** — click the header clock to open. Stopwatch counts up in H:MM:SS.t with Start/Pause/Reset; Countdown has `[-1m][-10s][+10s][+1m]` duration adjusters and beeps + red-flashes when it hits 0 (Windows: `winsound.Beep`; elsewhere: terminal BEL). All math runs against `os.time()` so neither timer drifts with frame rate.
- **Running-timer header takeover** — when the modal is closed but a timer is running, the header clock slot shows the running value instead of OS time: amber for stopwatch (`0:23:17`), red for countdown remaining (`4:53`). Click still reopens the modal. Countdown wins ties when both are running.
- **Teleport-ring cooldown tracker** in the equipment-panel title bar. Cycles through enabled rings every N seconds (configurable 2–15s, default 5s) showing the ring name in green when ready, name + MM:SS or HH:MM:SS in red while counting down. Tracks nine enchanted-equipment rings:
  - Warp Ring (28540, 10m), Dem Ring (26177, 10m), Holla Ring (26176, 10m), Mea Ring (26178, 10m)
  - Echad Ring (27556, 2h — instant Adoulin warp), Trizek Ring (27557, 2h — instant Ru'Lude warp)
  - Reraise Ring (26169, 20h — single-charge reraise)
  - Endorsement Ring (28469, 2h — exp/cp bonus), Emporox's Ring (28470, 2h — sparks bonus)
- **Equipment Configure modal** — equipment panel visibility + ring cooldown indicator + ring cycle interval + per-ring inclusion toggles (each ring can be independently enabled or disabled in the rotation).
- **Build stamp on startup** — every launch prints `[OmniWatch] === BUILD <version> ===` to the log and writes the stamp to `omniwatch_build_stamp.txt` next to the exe. Quick way to confirm a PyInstaller rebuild picked up the latest source.
- **Distinct button colors** for visual scanning:
  - Light blue — CONFIGURE buttons (open a subdialog)
  - Light purple — Open log folder (one-off action, useful for bug reports)
  - Red — Exit OmniWatch (destructive / one-way)
  - Amber — other actions (OPEN, RESET, EDIT, PICK)

### Changed

- **Settings dropdown layout** restructured: General now contains only the truly general toggles (full screen / always on top / display / setup mode); Misc holds Checklist and Simulation mode; an unnamed bottom section holds Open log folder and Exit OmniWatch. The Developer section has been removed.
- **Hide display eye** ("Show toggle nub") now correctly toggles the nub's own visibility rather than the display state of the panels behind it.
- **Section header convention** — section names beginning with an underscore now render an unnamed divider only (no label text). Empty underscore-prefixed sections render nothing at all. Normal-named sections still render a full header with placeholder text when empty.

### Fixed

- **Mog House moogle target card icon** — the family-icon fallback was nested inside the bestiary-database lookup, so any creature not in the bestiary (like Mog House moogles) skipped the fallback even when its icon file existed. Lookup is now ungated and will use `mobicons/<family>.png` whenever family info is set.
- **Transparent-background toggle** had no visible effect — it wasn't routing through the canonical `set_setting()` path. Fixed in all modal row dispatchers.
- **Backdrop dim** on Configure modals broke transparent-background's `LWA_COLORKEY` interaction, leaving a black square where transparency should have been. The modal renderer now skips backdrop fill when `transparent_background` is on.
- **Sim Player in character switcher** — the simulation-mode addon writes its synthetic player to a config folder, which appeared in the live character-switcher dropdown alongside real characters. `list_known_characters()` now filters out any folder whose name is `sim player` / `simplayer` / `sim_player` / `sim` (case-insensitive).
- **Day-of-week and moon phase** were not gated by `show_time` — toggling time off left them visible, which looked broken. They now share the `show_time` toggle since they're all Vana'diel-clock data.
- **Currency labels** for the three new currencies overflowed the centered header band; shortened display labels to single words (Beads / Tokens / Ichor) to match the existing convention.
- **/say chat body color** — say messages rendered in dim gray (200,200,200) because the body had no explicit color class and fell through to `default`. They now use a dedicated `body_say` class (240,240,240 / white) matching their sender-name color, so a player's say messages read as a coherent white line.
- **Header clock vertical alignment** — initial implementation built an asymmetric click rect (`cy - clk_h/2` top + `+4` height padding) that dragged the rendered text 2px below the header baseline. Rect is now symmetric around `cy` with text positioned at `cy - clk_h//2` directly, so the clock lines up exactly with Vana time, day name, weather, etc.
- **Header clock click no-op** — the click handler was placed inside `dispatch_inventory_dropdown_click`, which only runs when the inventory dropdown is open, so clicking the clock with inventory closed did nothing. Moved to the main click loop so it always fires.

### Internal

- **Generic Configure-subdialog factory** — Recast, Buff Timer, Chat, Skillchain, Target Card, DPS, HotBar, and Equipment share one `_draw_subdialog()` / `_dispatch_subdialog()` pair driven by a single `_SUBDIALOG_CONFIGS` dict. Adding a new section is now: one dict entry + one lambda in the action registry + one Configure button in the schema. No per-modal code.
- **Shared row primitives** — `_draw_modal_row()` and `_dispatch_modal_row_action()` render and route bool / int / float / enum / action rows across all modals. Enum rows render as `[<] value [>]` with prev/next arrows.
- **`set_setting()` is now the canonical save path** for all modal row dispatchers, replacing direct dict mutation and ensuring side-effect handlers fire consistently.
- **Schema hidden-section convention** — settings that used to render inline are now marked `_Hidden` and accessed only through their Configure modal. This keeps the schema authoritative without polluting the dropdown.
- **Ring detection by action-packet deep-walk** — earlier attempts to track Warp Ring cooldown via `extdata.decode()` and via `windower.res.items` name-lookups both failed on the live Windower install (the cooldown field wasn't surfaced by extdata for Enchanted Equipment, and the name lookup returned nil). The working approach is a deep-walk of every numeric field in player-actor action packets looking for the hardcoded ring ids — false-positive-resistant since ring ids (5-digit) are well outside the value range of typical damage/animation numbers. Action detection is hooked from inside `handle_incoming_action()` because the addon parses 0x028 packets directly rather than going through Windower's `'action'` event.
- **Wire format** for ring cooldowns: `RINGS|warp=N;dem=N;holla=N;mea=N;echad=N;trizek=N;reraise=N;endorsement=N;emporox=N` — single line emitted at 1Hz, each value seconds remaining (0 = ready).


## [1.5.3] - 2026-05-27

### Added
- **Stats panel: job/subjob innate traits** — Double Attack, Triple Attack, Subtle Blow, Fast Cast, auto-Regen, and auto-Refresh granted innately by your main and subjob are now added to the panel, on top of gear and buff contributions. The subjob uses the level the game reports directly (so Master-Level-raised subjobs are counted correctly, not capped at 49). Dual Wield is intentionally excluded here — it's already handled by the existing dual-wield path.
- **Stats panel: job-point gift bonuses for Double Attack, Triple Attack, Fast Cast, and Subtle Blow** — these gift bonuses were present in the data but never applied to the panel; they now stack on top of the level traits. Scoped to just those four stats (Accuracy/Attack/Store TP/Dual Wield gifts continue to flow through their own existing paths to avoid double-counting).
- **Stats panel: gear-derived Double Attack / Triple Attack / Quadruple Attack / Critical Hit Rate / Critical Hit Damage / Subtle Blow / Fast Cast** now reach the panel. GearInfo accumulated these from gear (e.g. a Unity augment's "Double Attack+5") but its compute only returned physical totals, so they never displayed; they're now copied through like the magic-accuracy values, summing correctly with roll/song contributions from a separate source.
- **Fudo Masamune: per-shadow Attack scaling** — the katana's "Attack+15 per Utsusemi shadow" now scales with your live shadow count (read from the Copy Image buff the timer panel already tracks) instead of always adding a flat +15. Zero shadows adds nothing; it climbs to +60 at four shadows and falls as shadows are consumed. Capped at the buff's "4+" readout, so a rare 5th shadow shows as 4.

### Fixed
- **Relic weapon base Attack lost (e.g. Kikoku showing 10 of 60)** — a relic's Aftermath grants "Attack+10%", which the base-stat parser misread as a flat "Attack+10" and used to overwrite the weapon's real base "Attack+60", so only 10 showed. The parser now distinguishes a percentage-suffixed Attack/Accuracy (the Aftermath multiplier) from a flat value and ignores the percentage form for those flat stats, preserving the base Attack. Empyrean/aeonic/dynamis weapons were never affected (no "Attack+%" token); other percentage stats (Haste, PDT/MDT, crit, etc.) are untouched.
- **Unity gear augment stats partly missing (e.g. Sailfi Belt +1's Double Attack)** — the augment block applied correctly (STR landed), but stats GearInfo doesn't return in its physical totals — Double Attack and the other multi-hit/extra stats — never flowed out to the panel. Covered by the gear copy-through above.
- **Dual-march timer labels showing the same song twice** — two trusts casting different marches (Advancing + Victory, both buff id 214) near-simultaneously could label both timer slots with the same song name. Each active slot is now given a distinct song name from the recorded sources when a buff id has multiple active slots and multiple distinct songs. Only the displayed name is affected; timers continue to use the server-truth expiry, so accuracy is unchanged. (Marches share a duration, so which name pairs to which slot is immaterial.)
- **Subjob level cap re-derivation** — several stat estimates (innate traits, Protect/Shell tier) re-derived the subjob cap as half the main level instead of trusting the level the game reports. At max level with Master Levels this undercut the real subjob level (e.g. forcing a level-55 sub back to 49 and dropping its higher trait tier). All now use the reported subjob level directly.


## [1.5.2] - 2026-05-25

### Added
- **Global UI scale** (General settings, 0.5×–3.0×): one multiplier that scales every panel's contents at once — shrink the whole overlay down for 4K displays or enlarge it for readability. Panel positions stay anchored (size-only scaling); re-drag once after a large change. Applies to party panels, target/equipment/recast/buff/DPS/stats/chat.
- **Chat: Clear Tab / Clear All buttons** in the panel header, next to the "Chat (N events)" title. Clear Tab removes only the events shown in the active tab; Clear All wipes the whole buffer across every tab. The "(N events)" title remains a lifetime received-counter and is unaffected by clearing.
- **Chat: AoE buff recipients now shown in full**: when one cast buffs the whole party, every recipient is listed (up to a full alliance), condensed onto a single line — e.g. "A, B, C, D, E, F gain 'March'" — instead of one line per person or only the caster. Critical for support play where you need to confirm everyone got the buff.
- **Chat: dedicated Tell tab** at the front of the tab row. All incoming and outgoing tells route here and nowhere else, so a tell received while you're away doesn't scroll past in World — it waits with its own unread badge like an answering machine. Tells no longer share the Party tab.
- **Chat: skillchain lines now shown and colored**. Skillchain results ("Fragmentation: 6345 → Apex Crab") are no longer suppressed as duplicate battle text — they route to the weaponskills channel (follow your WS routing) and render in a distinct color. The Katakana middle-dot FFXI inserts into mob names on these lines (e.g. "Apex・Crab") is cleaned to a plain space.
- **Target card: mob buffs/debuffs now tracked**. Buffs a mob applies to itself via a TP move (Metallic Body → Stoneskin, Bubble Curtain → Shell, etc.) appear on the target card, classified buff vs debuff by status id. They clear on dispel/erase, on Stoneskin breaking from damage taken, and on the mob's death.
- **Stats panel: Protect now contributes Defense and Shell now contributes MDT**. The gear engine doesn't include these magic buffs, so they're added on top. Tier (I–V) is read exactly from a witnessed cast when possible, recognized as tier V when applied by an item (Guard Drink), and otherwise estimated from your Protect/Shell-casting job level (WHM/RDM/PLD/SCH/RUN, main or sub).
- **Dual Wield source for GearSwap** — OmniWatch can now drive your GearSwap dual-wield gear tiers, replacing the HasteInfo addon. It computes the gear-target DW% (required total − DW traits − JP gift, floored at 0; −1 on non-DW jobs) and streams it as `gs c hasteinfo <N>` every stats cycle — the exact command HasteInfo used, so existing GearSwap logic needs no changes. Setup is two edits: stop loading HasteInfo, and remove the `hasteinfo report` request. The streamed value is gear-independent so it doesn't oscillate as worn gear changes; a freshly reloaded GearSwap always receives the current value. `//ow dwtest` prints the full computation. See the README's "Dual Wield for GearSwap gear swaps" section.
- **Stats panel: "DW To Cap" cell** shows the live gear-inclusive dual-wield residual (required − gear − traits − JP − buffs), unfloored and reactive to buffs: green `0` at cap, yellow `+N` when more DW is needed, red `−N` when over-capped (surplus DW you could drop for other stats). The value streamed to GearSwap is floored separately, so GearSwap never receives a negative.
- **Sim mode: Import Set** — pull any named set out of any GearSwap gear file into the sim, regardless of current job. A **Browse…** button opens the native OS file picker; type the set path (with or without a leading `sets.`, nested paths supported) and **IMPORT**. OmniWatch sandbox-executes the gear file (stubbing `set_combine`/`gear`/`empty`/Mote helpers), resolves the set to items, and loads it into the sim equipment for tweaking and comparison. Items referenced only through `gear.*` helper tables may show as unresolved; directly-named items resolve fully.
- **Chat tabs: horizontal arrow-scroll** — when unread badges widen the tabs past the panel border, the tab strip scrolls with ◀/▶ arrows at the ends instead of spilling past the edge. Full tab names are preserved (no abbreviation); arrows dim when there's nothing more to scroll and only appear on overflow.
- **All text input fields: held-key repeat** — holding a key now repeats (400 ms delay, then ~25/s), so holding Backspace deletes continuously, etc.
- **Sim Import set-path field: full cursor editing** — Left/Right move the caret, Home/End jump to the ends, Delete removes ahead of the caret, and typing/paste insert at the caret rather than only appending. Paste decodes the Windows UTF-16 clipboard correctly (fixing earlier "extra characters") and strips stray null/control characters.

### Fixed
- **AoE buffs only showed the caster gaining the effect**: FFXI sends one action packet for an AoE buff where only the primary target carries a recognized "gains the effect" message; the other recipients arrive as a continuation (message 0) with the same buff param, which the status classifier rejected — so only the caster showed in the Buffs tab while the Battle tab correctly listed all targets. The buff synthesizer now does a two-pass scan: it captures the established status from any recognized apply in the packet, then propagates it to the other recipients that share the same buff param (or carry the continuation marker), without misclassifying AoE nukes as buffs.
- **Multi-target abilities not condensing**: "Mix" (Chemist) and other party-wide abilities are action category 11 (TP-move category), which wasn't covered by the multi-target condense pre-pass — they produced one "uses X → target" line per recipient. The condense pre-pass now covers categories 4 (magic), 6 (job abilities), and 11 (TP-move abilities), so party-wide Mix/Guard Drink/etc. collapse to a single line like AoE songs and ga-spells. Single-target mob TP moves are unaffected.
- **DPS reading low and slowly climbing**: the rolling-window DPS divided total damage by the full window length (e.g. 300s) instead of by the actual elapsed combat time, so the number started tiny and crept upward as the window filled — only correct after a full window of sustained fighting. It now divides by the real span between the first and last event in the window (capped at the window length, floored at 3s so the opening hit doesn't spike). DPS is meaningful within a round or two and then fluctuates around the true rate as gear/WS/buffs change.
- **Mob actions missing from chat**: high-tier monsters (Apex, Sortie/Odyssey/Aminon NMs) share the high entity-id range with players' trusts/pets, so the classifier tagged the mob you were fighting as "other_pet" — an actor class with no routing, so its actions silently vanished. Engagement (claim) is now checked first: a claimed mob is `mob_engaged` (visible), an unclaimed high-id monster is `mob_passive`, and only genuine non-monster entities fall to `other_pet`.
- **Mob self-buff "uses" lines dropped**: a mob buffing itself targets itself, so neither side was an "ally" and the battle gate dropped the readies line — you saw the resulting buff on the card but never the "Apex Crab uses Bubble Curtain" line. The gate now also passes actions where the engaged mob is actor or target, so its TP-move use lines reach the feed. Other parties' fights stay hidden.
- **Healing/cure items shown as damage**: a trust's Mix/medicine (Max Potion restoring HP, Antidote curing poison) arrives on the TP-move category and was rendered as "→ target for N damage". HP-restore (message 238) now renders "recovers N HP" and status-cure/apply (message 159) renders with no damage trailer. Genuinely damaging items (e.g. Dark Potion) are unaffected.
- **Buff-gain line appeared before the "uses" line**: a mob TP move emits both a "uses ability" (combat) and "gains the effect" (status) line from one packet; they were emitted in the wrong order. The combat line now emits first, so chat reads "uses Bubble Curtain" then "gains the effect of Shell".
- **Stat panel color/formatting**: the always-yellow damage number and skillchain/mob colors were sorted out so each reads distinctly (see chat color notes).
- **Party-panel and timer debuff classification**: stat-down debuffs (STR/DEX/VIT/AGI/INT/MND/CHR Down, Attack/Defense/Evasion/Accuracy/Magic Def./Atk./Acc. Down) and Disease are now classified as debuffs (red, debuff column) rather than landing in the buff column.
- **Closing sim mode left stale stats on the panel**: turning sim mode off only flipped the data source but didn't force a recompute, and the live 1 Hz stats path only recomputes when a signature changes — so right after closing sim while idle (gear/buffs unchanged since before sim), the panel kept showing the sim values until something moved or you reopened the window. Closing sim now invalidates the live-stat signatures so the next tick fully recomputes and re-pushes your real stats and gear immediately.
- **Sim Import modal crash on paste**: pasting a path could crash the overlay with "A null character was found in the text" — the Windows clipboard returns UTF-16 with interleaved null bytes, and pygame's font renderer rejects any string containing a null. Paste now decodes UTF-16-LE correctly and strips null/control characters, and every dynamic string in the modal is sanitized at render time as a backstop.

### Changed
- **Chat scroll behavior**: scrolling up now pauses autoscroll and holds the view on the messages you're reading — incoming events no longer yank the view down mid-fight. Scroll back to the bottom and live updates resume. Scroll position is tracked per tab.
- **Chat: "Routing ⚙" renamed to "Filters ⚙"** in the panel header. Same function — launches `omniwatch_routing_gui.exe`.
- **Chat: target-card cast/readies flash duration**: the pulsing "Using X" indicator for a mob's TP move now fades after ~2.5s instead of lingering until the move resolves (TP moves are near-instant). Spell casts still pulse for the full cast and fade on completion.
- **Diagnostics consolidated**: the various chat/battle/buff probe commands are unified under a single `//ow chatdebug [on|off]`, and all probe output now writes to one file, `%APPDATA%/OmniWatch/chatdebug_log.txt`, instead of several separate logs.
- **Sim Import file selection moved to the native OS file picker**: the earlier in-overlay folder browser (configurable root + file list) was replaced by a single **Browse…** button using the same native picker as the hotbar icon chooser — browse anywhere on disk, no per-user root to configure.
- Readme updated for the global UI scale setting, the Clear Tab / Clear All chat buttons, the new scroll-lock behavior, the Filters rename, a note that Shift+drag moves the (borderless) overlay window, the new Tell tab, the Protect (DEF) / Shell (MDT) stat handling with its tier-detection caveats, the new "Dual Wield for GearSwap gear swaps" integration section, and the Sim mode Import Set feature.



## [1.4.1] - 2026-05-19

### Fixed
- **Statistics panel jumped between top and bottom alignment when dragged**: dropping the panel anywhere on screen would re-anchor it to whichever corner (top or bottom) the panel's midpoint was closer to. With a bottom anchor, the panel's height varies with setup mode (tray + save-as button appear) and with hidden cells, so the visible top would shift up/down whenever the size changed. The combined effect was a panel that appeared to "snap somewhere else" after release. The stats panel now always anchors to its top-left regardless of where it's dropped, matching the recast / buff / DPS panels — visible top-left stays exactly where it was placed, and size changes grow/shrink downward from a fixed point. Existing saved layouts with the old `bl` / `br` / `tr` anchors are migrated to `tl` on first load, preserving the panel's last visual position.

### Changed
- **World tab chat color differentiation**: say/shout/tell/yell/emote now render in distinct colors so a mixed stream reads at a glance. Say stays white. Shout is light yellow. Tell (received and sent) is light purple, with sent slightly dimmer to mirror the existing in/out distinction. Yell is pink. Emote is a soft blue. The orange sender name color is unchanged — channel is signaled by message-body color, speaker by sender color.
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