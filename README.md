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
- **Chat panel** — floating, resizable chat log with tabs (World, LS1/LS2, Party, Battle, Buffs, Debuffs, Mob, two user-customizable tabs, System, Gearswap), unread badges per tab, scrollback, and a built-in composer for sending say/tell/reply/shout/yell/linkshell messages without opening the game's chat field. Per-job routing rules let you decide which combat events land in which tab.
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
   Double-click `OmniWatch.exe` in the addon folder. The overlay window opens; **hold Shift and drag** to move it where you want.

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
- **Moving the window** — the OmniWatch window is borderless, so to move the whole window, **hold Shift and drag** anywhere on it. (To reposition individual panels within the window instead, use setup mode — see Edit-mode below.)
- **Per-character configs**: layouts, settings, buffs, recasts, gearswap path, and other per-character files live under `%APPDATA%\OmniWatch\<charname>\`. The character whose configs are active is shown next to the gear button in the header. Click that label to switch which character's config you're editing.

## Settings

OmniWatch settings live in two places, depending on what you want to change:

### In-game settings menu (most common)

Click the gear icon at the top of the overlay. The dropdown groups settings by panel. Most sections expose just a single **CONFIGURE** button (light blue) that opens a focused subdialog for that panel's options — this keeps the dropdown short and scannable.

- **General** — Full screen, Always on top, **Display** [CONFIGURE] (window opacity, global UI scale 0.5×–3.0×, transparent background, toggle nub visibility), Setup mode
- **Misc** — Checklist, Simulation mode
- **Header** — **Header** [CONFIGURE] (show time / weather / events / location, **Show OS clock**, **Show clock seconds**, **Clock time zone**, server choice, points tracker focus), **Currency cycler** [CONFIGURE] (per-currency toggles + cycle interval), **Inventory** [CONFIGURE] (inventory button + gearswap folder), Reset zone timer
- **Party Panel** — **Party Panel** [CONFIGURE] (show alliance, show pets, show buffs, show debuffs, compact icon grid, edit buff/debuff blacklists, edit buff aliases)
- **Equipment** — **Equipment** [CONFIGURE] (show panel, show ring cooldown, ring cycle interval 2–15s, per-ring inclusion toggles for Warp / Dem / Holla / Mea / Echad / Trizek / Reraise / Endorsement / Emporox)
- **Statistics** — **Statistics** [CONFIGURE] (show panel, gear settings wizard, edit stats layout)
- **Recast Timer** — **Recast Timer** [CONFIGURE] (show, auto-hide, edit blacklist)
- **Buff Timer** — **Buff Timer** [CONFIGURE] (show, auto-hide, edit blacklist)
- **Chat Panel** — **Chat Panel** [CONFIGURE] (show, font size, show input bar)
- **Skillchain** — **Skillchain** [CONFIGURE] (show, auto-hide, track skillchains, track magic burst)
- **Target Card** — **Target Card** [CONFIGURE] (show main / sub-target, per-card buffs/debuffs)
- **DPS Tracker** — **DPS Tracker** [CONFIGURE] (show, sparkline, track party damage, capture window, open CSV/JSON logs)
- **HotBar** — **HotBar** [CONFIGURE] (show, hotbars shown 1–3, edit hotbar)
- (bottom) — Open log folder (purple), Exit OmniWatch (red)

Header visibility toggles (show time / weather / events / location) hide whole blocks at once — when "show time" is off, the clock, day-of-week, and moon phase all disappear together with their dividers; the header collapses cleanly rather than leaving phantom gaps.

Closing a Configure subdialog automatically returns you to the settings dropdown so you can keep adjusting other panels without re-clicking the gear icon.

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

**Teleport-ring cooldown timer** in the title bar. A small inline indicator cycles through the four enchanted teleport rings + Reraise Ring + bonus rings, showing each ring's current state every N seconds:

- **Green** — ring name (e.g. `Warp Ring`) means ready to use
- **Red** — ring name + countdown (e.g. `Trizek Ring 1:23:45`) means still cooling down; format is MM:SS for cooldowns under an hour, HH:MM:SS for longer

Tracked rings (item ids in parentheses, cooldown after each):

| Ring | ID | Cooldown |
|---|---|---|
| Warp Ring | 28540 | 10 min |
| Dem Ring | 26177 | 10 min |
| Holla Ring | 26176 | 10 min |
| Mea Ring | 26178 | 10 min |
| Echad Ring | 27556 | 2 hr — instant Adoulin warp |
| Trizek Ring | 27557 | 2 hr — instant Ru'Lude warp |
| Reraise Ring | 26169 | 20 hr — single-charge reraise |
| Endorsement Ring | 28469 | 2 hr — exp/cp bonus |
| Emporox's Ring | 28470 | 2 hr — sparks bonus |

Use detection is done lua-side by deep-walking action packets for the ring's item id when the player is the actor — no inventory polling, no name lookup, no extdata parsing. State persists for the addon session (reload loses the timestamps; the next use resyncs).

Configure visibility, rotation speed (2–15s), and per-ring inclusion in the **Equipment Configure modal** (settings → Equipment → CONFIGURE). Disabled rings are skipped during cycle advance, so the rotation only shows what you actually want to see.

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

### Skillchain panel

Live skillchain helper. When a weapon skill or ability opens a skillchain, the panel shows the current resonating state — the skillchain properties available and the closing window before it expires — and suggests what to use next:

- **Skillchain suggestions** — weapon skills (and pet moves, where relevant) that would continue or close the current chain
- **Magic burst suggestions** — spells whose element matches the active skillchain, for bursting in the window
- Auto-hides when nothing is resonating (toggleable)

Tracking of skillchains and of magic-burst suggestions can each be toggled independently in the settings menu (**Skillchain → Track skillchains / Track magic burst**), so casters and melee can show only what's relevant to them.

### Chat panel

Floating chat log that sits inside the overlay. Useful when you want a second chat view that survives FFXI's own chat log resets, has independent scrollback, and can be styled / filtered separately from the in-game window.

**Tabs**:
- **Tell** — incoming and outgoing tells *only*. Sits at the front of the tab row and acts as a kind of answering machine: if someone sends you a tell while you're away, it lands here with its own unread badge instead of scrolling past in World.
- **World** — say, shout, yell, emote, NPC speech
- **LS1 / LS2** — linkshell 1 and 2
- **Party** — party chat
- **Battle** — combat actions (your hits, mob hits, weapon skills, magic)
- **Buffs** — status effects landing on you or party members
- **Debuffs** — debuffs landing on you or party members
- **Mob** — buffs and debuffs landing on mobs
- **Custom 1 / Custom 2** — user-relabeled and user-routed; pick any combination of event types to land here
- **System** — system messages
- **Gearswap** — gearswap log output (lights, set swaps, equip warnings)

Each tab tracks its own unread count and shows a red badge in the tab header when new messages arrive while you're on a different tab. Click a tab to switch; the badge clears when you read it. Scroll the body with the mouse wheel. Scrolling up **pauses autoscroll** and holds your view on the messages you're reading, so incoming events don't yank the view down mid-fight; scroll back to the bottom and live updates resume. Scroll position is tracked per tab.

**Clear buttons** (in the panel header, just after the "Chat (N events)" title):
- **Clear Tab** — removes only the events shown in the active tab, leaving the other tabs untouched
- **Clear All** — wipes the entire chat buffer across every tab

(The "(N events)" counter in the title is a lifetime total of everything received this session and keeps counting after a clear — clearing affects the displayed buffer, not the counter.)

**Composer** (optional row at the bottom of the panel — togglable via the "Show chat composer" setting):
- Channel picker: **say / tell / reply / shout / yell / ls1 / ls2** — click the channel label or use the `<` / `>` arrows to cycle
- **Tell target** field appears next to the channel when "tell" is selected
- Click the body to focus, type, **Enter** to send, **Esc** to cancel. Sends go through Windower as if you'd typed them in the game's chat field

**Routing config** (the **Filters ⚙** button in the panel header):
Opens `omniwatch_routing_gui.exe` — a standalone editor for the routing rules that decide which combat events appear on which tab. Rules are stored per-job, with a global fallback and baked-in defaults. Each event type (melee hits, weapon skills, magic, buffs, debuffs, etc.) can be:
- **Default** — emit to the canonical tab (e.g. melee → Battle)
- **Hidden** — don't show in the chat panel at all
- **Routed** — emit to one or more tabs of your choice, including the two custom tabs

Routing JSON lives in `%APPDATA%\OmniWatch\<charname>\`:
- `omniwatch_chat_routing.json` — global config (fallback)
- `omniwatch_chat_routing-<JOB>.json` — per-job override

The panel is resizable via the bottom-right corner grip (pixel-precise, not a uniform scale — you set the width and height independently). Position is draggable in setup mode.

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

**Protect (DEF) and Shell (MDT)**: the gear/trait engine doesn't include the Protect and Shell magic buffs, so OmniWatch adds them on top — Protect contributes flat Defense, Shell contributes magic-damage-taken reduction (MDT). The amount depends on the spell *tier* (Protect/Shell I–V), and OmniWatch determines the tier in this order:

1. **Witnessed cast** — if the overlay sees the Protect/Shell land on you, it reads the exact tier straight from the spell, regardless of who cast it. This is exact.
2. **Item source (Guard Drink)** — buffs applied by an item rather than a spell (e.g. the trust Monberaux's Guard Drink, which always grants Protect V + Shell V) are detected by their packet shape and treated as tier V.
3. **Job-level estimate** — if Protect/Shell is already active when the overlay starts (you zoned, logged in, or reloaded after it was cast) and there's no witnessed cast to read, the tier is estimated from the highest Protect/Shell-casting level you have (WHM / RDM / PLD / SCH / RUN, main or sub, with the standard half-level subjob cap).
4. **Unknown source fallback** — if the buff is active but none of the above can place it (e.g. you're on a non-casting job like COR/DNC and the cast wasn't witnessed), OmniWatch assumes tier V, since the realistic external source in that case is Guard Drink.

**Caveats**: because the buff itself carries no tier information, the estimate paths (3 and 4) are best-effort. If a higher-level party member casts a *higher* tier on you than your own level could produce and the overlay didn't witness the cast, the estimate can under-count; conversely, the unknown-source fallback assumes V, which can over-count if a low-tier Protect/Shell from an unwitnessed external source is the only thing up. The witnessed-cast and Guard Drink paths are exact; the level/fallback paths are approximations that resolve to the correct value the moment a cast is actually observed.

**BLU spell-trait math**: when you're on BLU, the panel resolves your equipped set spells against canonical bluguide data and computes:
- Trait points per category (DW, Fast Cast, MAB, Acc Bonus, MDB, Store TP, Conserve MP, etc.)
- Tier reached after applying JP gift bonuses. Gifts add +8 per gift to gift-eligible categories, but only once a trait is already unlocked by spell points alone (≥ its first 8-point threshold) — you can't use a gift to reach tier I from fewer than 8 spell points, matching the game.
- **Subjob trait contributions** are modeled the way bluGuide and the game handle them: a subjob granting the same trait contributes *points* (e.g. /DNC = 8 Accuracy-Bonus points, /RNG = 16), and the effective tier comes from `max(spell_points + gift, subjob_points)` — the BLU set and the subjob are the same trait, so the higher single source wins rather than the two stacking. For the four traits the stat engine also derives from the subjob (Accuracy / Attack / Evasion / Defense Bonus), the subjob's value is already in the base, so the BLU contribution is added as max-not-sum to avoid double-counting.
- Per-spell primary-stat bonuses (STR/DEX/VIT/AGI/INT/MND/CHR) summed into the primary-stat cells — and, for the attributes that feed a combat stat, converted at the game's rates on top: **DEX → accuracy** (`×0.75`), **STR → attack** (`×0.75` H2H else `×1.0`, with off-hand/ranged mirrors), **VIT → defense** (`×1.5`), **AGI → ranged accuracy** (`×0.75`) and **evasion** (`×0.5`). Magic accuracy from INT/MND/CHR is left as a raw stat only, since in-game it's the dStat (caster-vs-target) mechanic rather than a flat self-bonus.

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

**Import Set** — pull any named set out of any GearSwap gear file straight into the sim, regardless of what job you're currently on. Click **IMPORT SET**, then **Browse…** to pick a gear `.lua` file (native file picker — browse anywhere), type the set path (e.g. `sets.engaged.HighHaste`, with or without the leading `sets.`, including nested paths like `sets.engaged.DT.HighHaste`), and click **IMPORT**. OmniWatch sandbox-executes the gear file, resolves the named set to its items, and loads it into the sim equipment so you can tweak and compare. Items referenced indirectly through `gear.*` helper tables may not resolve a name (they show as unresolved); sets that name items directly resolve fully. Use **EXPORT SET** to write the current sim equipment back out as a GearSwap-style `.lua`.

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

Top of the overlay, always visible. Left to right:

- **Vana'diel game clock** — day-of-week, HH:MM time, current element of day, and moon phase. Hide the whole cluster with **Show time** in the Header Configure modal.
- **Weather** — current and next weather symbols for your zone. Hide with **Show weather**.
- **Events button** — opens the events modal (campaign / Domain Invasion phases, plus airship and ferry schedules with auto-cycling countdowns). Hide with **Show events**.
- **Points tracker** — one of EXP / CP / Exemplar at a time; pick which in the Header Configure modal.
- **Currency cycler** — auto-rotates through enabled currencies (Gil, Sparks, Accolades, Gallimaufry, Temenos, Apollyon, Beads, Tokens, Ichor). Pick which to show and the rotation interval (2–10 seconds) in the **Currency cycler** Configure modal.
- **Inventory button** — opens the inventory dropdown.
- **OS clock** — local-time HH:MM (or HH:MM:SS) clock sitting just to the left of the zone block. Driven by your computer's clock, not Vana'diel time. Click to open the **Stopwatch + Countdown** modal. Configurable in the Header Configure modal: **Show OS clock**, **Show clock seconds**, and **Clock time zone** (`Local` for your computer time, or one of `UTC / PST / MST / CST / EST / BRT / GMT / CET / EET / JST / KST / AEST` for tracking event times in other zones — `Local` is DST-aware; named zones use standard time offsets).
- **Right side** — zone timer, region, zone name, mini map, coords. Hide the entire right block with **Show location**.
- **Character switcher** — click your character name to switch which character's config files are active. Useful for pre-tweaking settings for an alt while logged in on your main.
- **Settings gear** — opens the dropdown.

The clock, zone, weather, and events data are fed from the lua side; if anything freezes, check the addon is loaded with `//lua list`.

**Stopwatch + Countdown modal** (click the OS clock to open):

- **Stopwatch** — counts upward in `H:MM:SS.t` (tenths of a second). Buttons: Start/Pause and Reset. Pausing banks the elapsed time so Start later resumes from where it left off.
- **Countdown** — set a duration with `[-1m][-10s][+10s][+1m]` adjusters. Buttons: Start/Pause and Reset. At zero, the digits flash red briefly and the system plays a short beep (Windows: `winsound.Beep`; other platforms: terminal BEL). Starting after a finished countdown reloads the last set duration so you can restart the same length with one click.

**Running-timer header takeover**: closing the modal while a timer is running doesn't stop the timer — the header clock slot keeps showing the running value (amber for stopwatch, red for countdown remaining) so you can see progress without re-opening the modal. Click the header reopens it. If both happen to be running, countdown wins the slot. Pause or Reset returns the header to OS time.

## Configuration details

### Edit-mode

Run `//ow setup` in-game to drop into setup mode — every panel becomes draggable and resizable, with mock data populated so you can position things without being in a fight. Run `//ow setup` again (or click the banner at the top) to exit.

### GearSwap reference detection

Settings menu → **Inventory → Gearswap folder** → click PICK. Choose the folder containing your gearswap `.lua` files. Items referenced anywhere in those files get a ✓ in the inventory dropdown.

### Dual Wield for GearSwap gear swaps

OmniWatch can drive your GearSwap dual-wield gear tiers, replacing the **HasteInfo** addon as the source. It computes how much Dual Wield your *gear* needs to reach the delay cap — required DW minus your job's DW traits and JP gift — and streams that number to GearSwap as it changes. GearSwap then equips the matching haste-tier set.

Crucially, OmniWatch sends the **exact same command HasteInfo used** — `gs c hasteinfo <N>` — so if your GearSwap was already set up for HasteInfo, **you don't change any of your GearSwap logic**. You only swap the source: stop loading HasteInfo, and let OmniWatch feed the number instead.

**What OmniWatch sends.** Every stats cycle (~1 Hz, only when something relevant changed), OmniWatch streams:

```
gs c hasteinfo <N>
```

where `<N>` is the gear-target DW% — the DW your gear must supply (required total − DW traits − JP gift), floored at 0. This is gear-independent, so it doesn't oscillate as your worn gear changes. On a job that can't dual wield, it sends `-1`. This matches HasteInfo's `actual_needed` value.

**Setup (two changes, then you're done):**

1. **Stop loading HasteInfo.** In your Globals (or wherever you auto-load addons), comment out or remove the HasteInfo load line:

   ```lua
   -- send_command('lua l hasteinfo')
   ```

2. **Remove the HasteInfo report request.** If a job file asks HasteInfo to report on load (HasteInfo's own handshake), remove it — OmniWatch streams continuously, so nothing needs to request a report. In `get_sets()` (or equivalent), delete the line:

   ```lua
   send_command('hasteinfo report')
   ```

**That's it** — keep your existing `process_hasteinfo`, `determine_haste_group`, `update_combat_form`, and your haste-tier sets exactly as they were. For reference, the standard GearSwap side looks like this (unchanged from a HasteInfo setup):

```lua
-- Catches the streamed value and re-equips.
function process_hasteinfo(cmdParams, eventArgs)
    if cmdParams[1] == 'hasteinfo' then
        if type(tonumber(cmdParams[2])) == 'number' then
            DW_needed = tonumber(cmdParams[2])
            DW = DW_needed > 0
        end
        if not midaction() then
            job_update()    -- triggers determine_haste_group()
        end
    end
end

-- Picks the gear tier from how much DW the gear still needs.
function determine_haste_group()
    classes.CustomMeleeGroups:clear()
    if DW == true then
        if     DW_needed <= 1                       then classes.CustomMeleeGroups:append('MaxHaste')
        elseif DW_needed >  1 and DW_needed <= 16   then classes.CustomMeleeGroups:append('HighHaste')
        elseif DW_needed > 16 and DW_needed <= 21   then classes.CustomMeleeGroups:append('MidHaste')
        elseif DW_needed > 21 and DW_needed <= 34   then classes.CustomMeleeGroups:append('LowHaste')
        elseif DW_needed > 34                       then classes.CustomMeleeGroups:append('')
        end
    end
end
```

Your engaged sets then provide the tiers, e.g. `sets.engaged.MaxHaste`, `sets.engaged.HighHaste`, `sets.engaged.MidHaste`, `sets.engaged.LowHaste` (and any `.DT` variants). The thresholds above are an example; use whatever tiers your sets define.

**Verify it's working:** `//ow dwtest` prints the current computation — the required DW, your traits, JP gift, and the `gs c hasteinfo <N>` value being sent. The **stats panel "DW To Cap"** cell shows the live gear-inclusive residual: green `0` at cap, yellow `+N` when you still need more DW, red `−N` when you're over-capped (you have surplus DW you could drop for other stats).

**Note:** OmniWatch reads its bard-song gear data from the `gearinfo/res/BardGear.lua` file via `require`, so the **GearInfo files must remain present in your addons folder** — but GearInfo does **not** need to be *loaded/running*. In fact, if you don't want GearInfo's in-chat song-bonus announcements, leave the files on disk but don't load the addon (`//lua unload gearinfo`, and remove any `lua l gearinfo` from your init). OmniWatch keeps full song data either way.

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
├── omniwatch_routing_gui.exe     # chat routing rule editor (launched from chat panel gear)
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
    ├── omniwatch_chat_routing.json         # chat panel routing rules (global fallback)
    ├── omniwatch_chat_routing-<JOB>.json   #   per-job override (e.g. -COR.json)
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