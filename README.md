# OmniWatch

A Final Fantasy XI overlay that surfaces party state, the target you're fighting, your equipment, recasts, buffs and debuffs, DPS, character stats, and more — all in a single resizable Pygame window driven by a Windower addon.

The Windower addon collects events from the game and sends them over local UDP to a Python overlay that draws everything. They run as a pair: the lua side has no UI, the python side has no game data. Both halves are required, but the python side ships as a self-contained `OmniWatch.exe` so you don't need to install Python yourself.

- **GitHub:** https://github.com/BalladOfWorms/OmniWatch
- **Discord:** https://discord.gg/PJjTk6qX
- **Issues / bug reports:** https://github.com/BalladOfWorms/OmniWatch/issues

OmniWatch is in active development. The core feature set is stable and usable today, but rough edges remain — please report bugs and odd behavior on Discord or via GitHub Issues. Features and accuracy will continue to be expanded over time, with help from community feedback.

## What it does

OmniWatch puts the live state of your character and party in one place:

- **Party panel** — every party member's HP/MP/TP, jobs, buffs and debuffs, pet HP/TP, with optional alliance support
- **Target / sub-target cards** — full enemy info: family, abilities used, resists, susceptibilities, element, jobs, buffs/debuffs, with art from BG-wiki when available. PCs show a race + sex icon (Hume Male, Tarutaru Female, Mithra, Galka, etc.)
- **Equipment viewer** — all 16 gear slots with extracted icons, hover tooltips with full item descriptions, augments, set bonuses, and Unity / Master Trial gear awareness
- **Recast tracker** — magic and ability recasts with timer bars, custom aliases, and auto-hide when nothing's recasting
- **Buff timer panel** — duration bars for active buffs that color-shift as they're about to wear off
- **DPS tracker** — rolling-window damage tracking with sparklines, per-encounter logging to CSV/JSONL, optional party-member damage tracking
- **Stats panel** — full /checkparam-style stat grid (Acc/Att/RAcc/RAtt/Def/Eva, MAcc/MAB, elemental affinity, fast cast, store TP, etc.) computed from skill + base stats + gear + food + buffs + traits, including BLU spell-trait math and per-spell stat bonuses
- **Hotbar** — customizable button panel for slash commands, items, gearswap calls, and macros
- **Inventory dropdown** — searchable inventory across all bags (mog wardrobes, satchel, sack, case) with GearSwap-reference detection
- **Header strip** — Vana'diel game clock with element/moon phase, current zone + region, character switcher, settings gear
- **Sim mode** — what-if calculator: change job, level, JP, ML, gear, food, BRD songs (marches/minuets/madrigals), and COR rolls (Chaos/Samurai/Tactician's with optional Crooked Cards + optimal job toggles) and see the resulting stats live without applying anything in-game

Everything is draggable and resizable. Per-character configs save layout, settings, blacklists, aliases, and hotbar bindings to `%APPDATA%\OmniWatch\<charname>\`.

## Requirements

- **Final Fantasy XI** with **Windower 4** installed
- **Windows 10 or 11**

That's it. No Python, no pip, no extra installs — the overlay ships as a self-contained executable.

## Installation

1. **Download the latest release** from https://github.com/BalladOfWorms/OmniWatch/releases/latest

2. **Drop the addon folder into Windower's addons directory:**
   ```
   <Windower install>\addons\OmniWatch\
   ```
   The folder ships with everything needed: `OmniWatch.exe`, `OmniWatch.lua`, the `data/`, `gearinfo/`, `icons/`, and `simulation/` subfolders, plus this README.

3. **In-game, load the addon:**
   ```
   //lua load OmniWatch
   ```
   Or add `lua load OmniWatch` to your auto-load list so it starts every session.

4. **Run the overlay executable:**
   Double-click `OmniWatch.exe` in the addon folder. The overlay window opens; drag/dock it where you want.

The lua addon and the overlay talk over `127.0.0.1` UDP — they don't need each other started in a particular order, but you'll only see live data once both are running and you've logged in to a character.

### Windows SmartScreen / Defender warnings

The first time you run `OmniWatch.exe`, Windows Defender may flag it as a virus or quarantine the file. **This is a known false positive with PyInstaller-built executables** — the way the .exe unpacks itself at runtime looks similar to how some malware unpacks. Defender's heuristic scanner doesn't distinguish.

The build is safe; full source is at https://github.com/BalladOfWorms/OmniWatch for review.

**To stop Defender from quarantining it**, add the OmniWatch folder to the exclusion list:

1. Open Windows Security → Virus & threat protection → Manage settings
2. Scroll to "Exclusions" → "Add or remove exclusions" → "Add an exclusion" → "Folder"
3. Pick your `<Windower>\addons\OmniWatch` folder

**If the .exe was already quarantined**, restore it:

1. Windows Security → Virus & threat protection → Protection history
2. Find the OmniWatch.exe entry
3. "Actions" → "Allow on device"

**For SmartScreen** (`Windows protected your PC`): click "More info" → "Run anyway".

## Running

- **Lua first or python first** — either works. Reload the lua addon in-game with `//lua reload OmniWatch` whenever you change lua code.
- **Per-character configs**: layouts, settings, buffs, recasts, gearswap path, and other per-character files live under `%APPDATA%\OmniWatch\<charname>\`. The character whose configs are active is shown next to the gear button in the header. Click that label to switch which character's config you're editing.

## Settings

OmniWatch settings live in two places, depending on what you want to change:

### In-game settings menu (most common)

Click the gear icon at the top of the overlay. The dropdown is grouped by panel:

- **General** — DPS sparkline, always-on-top, window opacity, transparent background, crash log access, zone-timer reset, setup mode, Vana'diel time offset
- **Party** — show alliance, show pets, show buffs, show debuffs, compact icon grid, edit buff/debuff blacklists, edit buff aliases
- **Equipment** — show equipment panel
- **Statistics** — show stats panel
- **Recast Timer** — show recast, autohide, edit blacklist, edit aliases
- **Buff Timer** — show buff timer, autohide, edit blacklist, edit aliases
- **Target Card** — show target, show sub-target, buffs/debuffs toggles per card
- **DPS Tracker** — show DPS, rolling window seconds, track party damage, open log files
- **HotBar** — show hotbar, edit hotbar
- **Inventory** — show inventory button, gearswap folder picker
- **Developer** — sim mode toggle and other dev-mode tools

Most toggles take effect immediately; a few (sim mode, gearswap folder) ask for a reload.

### `%APPDATA%\OmniWatch\` (manual config files)

For per-character configuration files (blacklists, aliases, layouts, button bindings) you can edit directly. The folder is auto-created on first run; paste the path into Explorer's address bar to open it:

```
%APPDATA%\OmniWatch\
```

Inside you'll find:

```
%APPDATA%\OmniWatch\
├── omniwatch_dps_log.jsonl       # global DPS encounter log
├── omniwatch_dps_log.csv         # global DPS summary
├── logs\                         # crash logs
└── <charname>\                   # one folder per character
    ├── omniwatch_layout.json     # panel positions & scales
    ├── omniwatch_settings.json   # toggles from settings dropdown
    ├── omniwatch_buffs.json      # buff blacklist / aliases
    ├── omniwatch_buff_timer.json # buff-duration overrides
    ├── omniwatch_recast.json     # recast tracker config
    ├── omniwatch_buttons.json    # hotbar button bindings
    ├── omniwatch_mobs.json       # learned mob abilities
    ├── omniwatch_zones.json      # zone → region mapping
    └── omniwatch_gearswap_path.json
```

The settings menu's "Edit ..." entries (e.g. "Edit buff blacklist") open the right file in your default text editor.

## Panels

Every panel is independently toggleable from the settings dropdown. Most are draggable and resizable; drag from anywhere on a panel to move, drag the bottom-right corner to resize.

### Party panel

Shows your main party (slots p0-p5) with optional alliance party 1 and 2. Per member:

- Name + main/sub job and levels
- HP / MP / TP bars (HP color-coded by %)
- Pet name, pet HP%, and pet TP — colored independently (pet HP% in HP-band color, pet TP in TP-band color). Toggle "Show pets" to control visibility.
- Buffs column on the left, debuffs column on the right, divided by a thin divider line

**Buff/debuff display modes**:
- **Text mode** (default) — vertical stack of buff name labels, scrollable when overflowing
- **Compact icon grid** — packed grid of ~16px status icons. Hover any icon for the buff name as a tooltip. Toggle via "Compact icon grid" in the settings menu under Party.

**Customization**:
- "Edit buff blacklist" / "Edit debuff blacklist" — open `omniwatch_buffs.json` to hide buffs you don't care about (per-context: a name can be hidden in the buff column but still shown in the debuff column, or vice versa)
- "Edit buff aliases" — shorten long buff names (e.g. "Tactician's Roll" → "TAC")

**Alliance**: toggle "Show alliance" to display alliance parties 1 and 2 as compact strips along the right side of the screen. Slots can be repositioned individually.

### Target & sub-target cards

The target card adapts to what you're targeting:

**Mobs** show extensive game info:
- Name, family, type, level range, ecosystem
- HP bar, color-coded by %
- **Aggro flags** as a row of icons: sight, sound, blood, magic, JA, scent, truesight
- **Element / crystal** indicator (uses real element icons from `icons/mob/<element>.png` — fire, ice, wind, earth, lightning, water, light, dark — falls back to a colored diamond if the icon file is missing)
- Main job / sub job (when known from BG-wiki Bestiary scraping)
- **Resists / susceptible / absorbs / immune** lists, color-coded
- **Abilities** — every TP move the family is known to use, with hover tooltips showing damage type, modifier, status effect inflicted, range, and notes
- **Mob image** from BG-wiki when available, falling back to a family icon (`mobicons/<family>.png`), then to a primitive shape

**Image fallback chain (mobs)**:
1. `image` field set in `mob_individuals.json` → `mobicons/<image>.png`
2. blank `image` + family set → `mobicons/<family>.png` (lowercased)
3. `icons/mob/<family>.png` (bundled family icon)
4. `icons/mob/<ecosystem>.png` (e.g. "Bee" → "Vermin")
5. primitive shape

**Players (PCs)** show:
- Name, race + sex, main/sub job and levels
- HP bar
- Buff and debuff lists (toggleable)
- A race + sex icon (Hume Male, Hume Female, Elvaan Male, Elvaan Female, Tarutaru Male, Tarutaru Female, Mithra, Galka) — drop matching PNGs into `data\mobdata\mobicons\` named e.g. `HumeMale.png`, `Mithra.png`

Sub-target card mirrors the target card with its own toggles for buffs/debuffs.

### Equipment viewer

All 16 gear slots displayed in canonical equipment-panel order. Per slot:

- Extracted item icon (BMP, auto-extracted to `icons/equipment/<item_id>.bmp` on first equip via Windower's icon-extractor library)
- Item name
- Rich tooltip on hover: full item description, augments, set bonuses, augmented stats, level/job restrictions, item ID

The viewer also shows:
- **Set bonuses** active across your gear (e.g. 2/5 Hashishin set bonus active)
- **Master Trial / Empyrean / Dynamis-D / Reforged Artifact / Relic / Mythic** awareness — items that have hidden trait bonuses (Wing Gorget regain, etc.) are recognized and contribute to the stats panel

### Recast tracker

Two columns — **magic** and **abilities** — with horizontal timer bars per recast.

- Each bar fills from 0 to 1 as the recast burns down (so a half-empty bar means halfway ready)
- Color shifts: red when first cast → yellow → green → ready
- Auto-hide option: panel collapses when nothing is recasting
- Customization: edit the recast blacklist to hide trivial recasts (cure, etc.) and edit recast aliases to shorten names

### Buff timer panel

Standalone panel showing every active buff as a horizontal bar:
- Bar starts full, empties as the buff burns down
- Color shifts green → yellow → red as expiry approaches
- Wore-off flash: brief blinking red bar when a buff drops, then it disappears
- Per-character buff alias and blacklist files for shortening / hiding entries

### DPS tracker

Rolling-window damage tracker. Per encounter:

- DPS over the last N seconds (configurable, default 5 minutes / 300s)
- Per-source breakdown if "Track party DPS" is on (lists damage by each party member)
- **Sparkline** — small per-second damage graph showing the last window
- Optional toggle to show only your damage or include party

**Logging**:
- Every encounter that lasts long enough writes to `%APPDATA%\OmniWatch\omniwatch_dps_log.jsonl` (full event log) and `omniwatch_dps_log.csv` (one row per encounter summary)
- Logs are global across characters
- Open from the settings menu via "Open DPS log (CSV)" or "(JSONL)"

Slash commands: `//ow dps`, `//ow dps reset`, `//ow dps window <seconds>`, `//ow dps party`, `//ow dps status`.

### Stats panel

Full character stat grid in `/checkparam` style. Each cell is computed from skill caps + base attributes + gear + food + buffs + merits + traits + master level bonuses, using formulas documented on BG-wiki.

**Cells**:
- Primary stats: STR / DEX / VIT / AGI / INT / MND / CHR
- Combat: Accuracy, Attack, Critical Rate, DA / TA / QA, Store TP
- Ranged: Ranged Accuracy, Ranged Attack, Snapshot
- Defenses: DT / PDT / MDT / BDT, Magic Evasion, Evasion, Defense
- Caster: Fast Cast, Quick Magic, MAcc, MAB, Regen, Refresh, Regain
- Elemental affinity: Fire, Ice, Wind, Earth, Lightning, Water, Light, Dark

**Server-pushed stat updates**: OmniWatch passively listens for server-side stat packets (0x061, 0x063) that fire on roll cast, gear change, and buff change. When captured, these refresh the Attack and Accuracy values to match what the server says they are — including most roll bonuses. **Caveat**: there's no reliable way to detect every variant of these packets, so certain proc-style effects (most notably the Lanun gear set's chance to boost a roll's accuracy bonus) may not always be reflected immediately. Att/Def usually update; Acc updates are best-effort.

**BLU spell-trait math**: when you're on BLU, the panel resolves your equipped set spells against canonical bluguide data and computes:
- Trait points per category (DW, Fast Cast, MAB, Acc Bonus, MDB, Store TP, Conserve MP, etc.)
- Tier reached after applying JP gift bonuses (+8/+16 to gift-eligible categories)
- Per-spell stat bonuses (STR/DEX/VIT/AGI/INT/MND/CHR) summed into the primary-stat cells

`//ow blu` prints the full diagnostic — equipped spells, points per category, tier reached, gift bonus applied.

### Sim mode

What-if calculator that runs alongside the overlay. Open via the settings menu or `//ow sim`. Pick:

- **Job** + level (1-99)
- **Master Level** (0-50)
- **Job Points spent** (0-2100, single total) — applies all the JP gift thresholds + linear bonuses
- **Merits** for the chosen job (per-job merit lists; e.g. BRD shows Lullaby Duration, Minne Effect, Minuet Effect, Madrigal Effect, Nightingale Recast)
- **Equipment** in all 16 slots — pick by name or item id, augments included
- **Food** — pick from a catalog
- **Active buffs** — add as many as you want from a two-stage picker:
  - **BRD songs**: Honor March, Victory March, Advancing March, Minuet I-V, Valor Madrigal, Blade Madrigal. Each with a +/- on the song-tier ("Plus" — instrument level), and side-by-side checkboxes for **Soul Voice** and **Marcato** boosts
  - **COR rolls**: Chaos Roll, Samurai Roll, Tactician's Roll. Each with a roll-value picker (1-11), and side-by-side checkboxes for **C. Cards** (Crooked Cards) and **Job present** (optimal-job bonus)

The resulting stats panel updates live as you tweak values — no in-game commitment. Useful for "do I have enough Store TP for a 5-hit build with this song setup?" or "what's my fast cast going to be after I add Erratic Flutter to my BLU set?"

### Hotbar (button panel)

Customizable row of buttons for slash commands, items, gearswap calls, or macros. Each button can have:
- A label
- An icon (from `icons/ui/`)
- A click action (a `/text` command, a `//gs` call, etc.)
- Optional right-click action

Edit via the settings menu's "Edit hotbar" option, or live by entering setup mode and clicking buttons. Multiple pages supported via a small page indicator.

### Inventory dropdown

Click the inventory button in the header for a searchable view of every bag:
- Inventory, satchel, sack, case
- Mog wardrobes 1-8 (5-8 require active subscription)
- Mog safe / safe 2 / locker / storage

Items are grouped by bag and searchable by name. **GearSwap reference detection**: if you've pointed OmniWatch at your GearSwap folder (settings → Inventory → Gearswap folder → PICK), items referenced in any of your gearswap `.lua` files get a ✓ icon — so you can tell at a glance which items in your inventory are actually being equipped by your sets.

### Header strip

Top of the overlay, always visible:
- **Vana'diel game clock** with day-of-week, time, current element-of-day, current moon phase
- **Current zone** + region (e.g. "Western Adoulin — Adoulin", "Yorcia Weald — Ulbuka")
- **Character switcher** — click your character name to switch which character's config files are active. Lets you pre-tweak settings for an alt while logged in on your main.
- **Settings gear** — opens the dropdown
- **Inventory button**
- **DPS toggle, recast toggle, sim toggle** (when enabled)
- **Crash log** access (settings menu) — opens the most recent crash log if the overlay has had a recent error

The clock and zone are fed from the lua side; if either freezes, check that the addon is loaded with `//lua list`.

## Configuration details

### Edit-mode

Run `//ow setup` in-game to drop into setup mode — every panel becomes draggable and resizable, with mock data populated so you can position things without being in a fight. Run `//ow setup` again (or click the banner at the top) to exit.

### GearSwap reference detection

Settings menu → **Inventory → Gearswap folder** → click PICK. Choose the folder containing your gearswap `.lua` files. Items referenced anywhere in those files get a ✓ in the inventory dropdown.

### User config (advanced)

`OmniWatch\data\user_config.lua` holds settings the lua side reads at addon load:
- `blu_dw_override` — pin a manual BLU dual-wield % if the spell-set scanner doesn't match what the game shows

Use `//ow config <key> <value>` in-game to write to `user_config` without editing the file by hand.

## Slash commands

`//ow help` (or `//omniwatch help`) lists all commands. Frequently-used:

- `//ow setup [on|off]` — toggle setup mode (mock data, all panels editable)
- `//ow lock [on|off]` — toggle whether panels can be dragged/resized
- `//ow dps` — toggle the DPS panel
- `//ow dps reset` — clear the DPS rolling window
- `//ow dps window <seconds>` — change DPS rolling-window length
- `//ow dps party` — toggle whether party-member damage is tracked
- `//ow dps status` — print DPS tracker diagnostics

**Diagnostic commands**:
- `//ow help` — list commands
- `//ow debug` — toggle diagnostic chat output (action packets, set scrapes, etc.)
- `//ow events` — list event-bus subscriber counts
- `//ow dumpgear [slot]` — print equipped-item details
- `//ow dumpstats` — force a stats recompute and print summary
- `//ow dumpbuffs` — print every active buff with id and name
- `//ow dumpcharstats` — print player.stats (gear+buffs delta) and totals
- `//ow dumpdesc` — print raw description text of each equipped item
- `//ow dumpduration` — print Phantom Roll / Enhancing Magic durations
- `//ow blu` — BLU set-spell diagnostic: lists equipped set spells, trait points per category, tier reached, gift bonus applied
- `//ow testcast` — emit a synthetic cast-start event on yourself for renderer testing
- `//ow serverstats [on|off|debug|status|trace]` — control passive stat packet listener

**Config**:
- `//ow config` — list current user_config values
- `//ow config <key> <value>` — set a user_config value (e.g. `blu_dw_override 8`)
- `//ow config reset` — zero everything

## File layout

```
<Windower>\addons\OmniWatch\
├── OmniWatch.exe                 # the overlay (run this)
├── OmniWatch.lua                 # the addon (Windower auto-loads)
├── OmniWatch_Sim.lua             # sim-mode buff math
├── Server_Stats.lua              # passive server-pushed stat listener
├── icon_extractor.lua            # icon extraction utility (Windower lib)
├── PythonUpdate.bat              # helper for running from source (advanced)
├── Readme.md                     # this file
├── data\                         # canonical data tables + per-mob caches
│   ├── blu_spell_traits.lua      # BLU spell → trait points
│   ├── Cor_Rolls.lua             # COR roll effects
│   ├── DW_Gear.lua               # DW gear with hidden stats
│   ├── Gifts.lua                 # job-points gifts → stats
│   ├── Martial_Arts_Gear.lua     # MA delay-reduction items
│   ├── Set_bonus_by_item_id.lua  # set-bonus tables
│   ├── Unity_Gear.lua            # Unity-shop gear
│   ├── user_config.lua           # user overrides (auto-written)
│   ├── omniwatch_stats.lua       # auto-generated for gearswap
│   ├── mob_individuals.json      # per-mob overrides (image, abilities)
│   └── mobdata\
│       └── mobicons\             # per-mob image cache + PC race icons
├── DataScrape\                   # web-scrape helpers (BG-wiki, etc.)
├── gearinfo\                     # vendored gear-stat parser
├── icons\
│   ├── equipment\                # auto-extracted on first run
│   ├── mob\                      # mob family + element icons
│   ├── status\                   # buff/debuff status icons (auto-extracted)
│   └── ui\                       # UI icons (custom hotbar buttons)
├── simulation\                   # sim-mode supporting data
└── logs\                         # auto-created per-session

%APPDATA%\OmniWatch\              # auto-created on first run
├── omniwatch_dps_log.jsonl       # DPS encounter log (global, all chars)
├── omniwatch_dps_log.csv         #   ditto, summary CSV
├── logs\                         # crash logs
└── <charname>\                   # per-character config
    ├── omniwatch_layout.json     # panel positions & scales
    ├── omniwatch_settings.json   # toggles from settings dropdown
    ├── omniwatch_buffs.json      # which buffs to track / hide / alias
    ├── omniwatch_buff_timer.json # buff-duration overrides
    ├── omniwatch_recast.json     # recast-tracker config
    ├── omniwatch_buttons.json    # user button bindings
    ├── omniwatch_mobs.json       # learned mob abilities
    ├── omniwatch_zones.json      # zone → region mapping
    └── omniwatch_gearswap_path.json
```

The `%APPDATA%\OmniWatch\` folder is created automatically the first time you run the overlay. Per-character subfolders are created the first time a given character logs in.

## How it works

The lua addon hooks Windower events (`prerender`, `incoming chunk`, `incoming text`, `addon command`, etc.) and broadcasts state over UDP to local ports:

| Port | Stream |
|------|--------|
| 5000 | Party state (HP/MP/TP/buffs/jobs/pet for each member) |
| 5001 | Equipment slot ids |
| 5002 | Target / sub-target |
| 5003 | Zone info |
| 5004 | Mob debuff state |
| 5005 | GearSwap-relayed gil / setup toggle |
| 5006 | Mob casting events |
| 5007 | Rich equipment data (full item details) |
| 5008 | Player stats |
| 5009 | Recast / buff timer config push |
| 5010 | DPS events |
| 5011 | python → lua commands (inbound to lua) |
| 5012 | Inventory snapshot |

The python overlay binds these ports, accumulates state, and renders each panel using pygame. The two halves are independent — restart either side without restarting the other.

## Known issues and limitations

- **Lanun roll-proc accuracy** — when COR's Lanun gear set procs a bonus on a Phantom Roll's accuracy effect, OmniWatch may not always reflect the boosted value. The server doesn't reliably push the relevant stat packet for this case, and there's no clean way to detect the proc client-side.
- **BLU spell-trait coverage** handles the major categories (DW, Fast Cast, MAB, Acc Bonus, Atk Bonus, Def Bonus, MDB, Store TP, Conserve MP, Counter, Auto Refresh, Auto Regen, MAcc Bonus, MEv Bonus, Magic Burst Bonus, Skillchain Bonus, Crit Atk Bonus, Inquartata, Tenacity, Max HP, Max MP, Zanshin, Resist Silence/Gravity/Sleep/Slow, Killer traits, DA/TA, Gilfinder/TH, Rapid Shot) sourced from the canonical bluguide tables. JP-category linear bonuses for MAB/MAcc are not yet wired separately.
- **Running multiple FFXI clients with OmniWatch on the same machine is not supported** (UDP port collision — only one instance per machine can bind the addon's ports). Single-client multi-character config support via the character dropdown in the header works normally — you can pre-tweak layout, settings, and blacklists for any of your characters while logged in on a different one.
- **Mog Wardrobes 5-8** require an active subscription to populate.

## Development

If you want to run from source or modify the overlay:

- **Python 3.10+** with `pygame` installed (`pip install pygame`). Tkinter is required for the GearSwap folder picker — it ships with the standard Windows Python installer.
- Run with `python OmniWatch.py` instead of the .exe.
- To rebuild the .exe: `pip install pyinstaller`, then `pyinstaller omniwatch.spec` from the addon folder. The new .exe lands in `dist\`.

Useful entry points:

- `OmniWatch.lua` — single addon file, well-commented sections
- `OmniWatch.py` — single overlay file, organized by panel
- `OmniWatch_Sim.lua` — sim-mode buff math (BUFF_DATA table for songs/rolls)
- `Server_Stats.lua` — passive 0x061 / 0x063 packet listener
- `data/` — reference tables sourced from BG-wiki / FFXIAH / windower res
- `gearinfo/` — vendored gear-stat parser

Pull requests welcome. See https://github.com/BalladOfWorms/OmniWatch for the repo, or jump in the Discord at https://discord.gg/PJjTk6qX for design discussion.

## License

[TBD]

## Credits

- BG-wiki and FFXIAH for the data tables and game mechanics references
- Windower team for the addon platform and resource libraries
- Rubenator for the icon-extractor library used to pull equipment + status icons from the FFXI DAT files
- bluguide (Anissa) for the canonical BLU spell-trait data