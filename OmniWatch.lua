_addon.name     = 'OmniWatch'
_addon.author   = 'BalladOfWorms'
_addon.version  = '1.1.0'
_addon.commands = {'omniwatch', 'ow'}

local res     = require('resources')
local socket  = require('socket')
local packets = require('packets')   -- registers string:unpack(), string:pack(), etc.

-- ── Simulation module (optional) ──────────────────────────────────────────
-- Loads simulation/OmniWatch_Sim.lua at startup if present. When sim mode
-- is active, ow_compute_stats() returns synthetic zeros + buff stats from
-- the sim module instead of reading windower's live state. The module
-- exposes is_active(), set_active(on), set_value(key, value, sub),
-- list_active_buffs(), compute_active_buff_stats(). Failure to load
-- (file missing, syntax error in sim file) is non-fatal — _sim stays nil
-- and OmniWatch falls back to its normal behavior.
--
-- Path resolution: windower.addon_path normally ends with a trailing
-- slash, but we don't rely on that. loadfile is called directly (not
-- via pcall — loadfile returns nil + errmsg on failure rather than
-- throwing, so wrapping in pcall would swallow the diagnostic).
local _sim = nil
do
    local base = windower.addon_path or ''
    if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
        base = base .. '/'
    end
    local sim_path = base .. 'simulation/OmniWatch_Sim.lua'
    local chunk, load_err = loadfile(sim_path)
    if chunk then
        local ok_run, mod = pcall(chunk)
        if ok_run and type(mod) == 'table' then
            _sim = mod
            -- Silent on success: the v2.0 "loaded" line below is the
            -- single confirmation we emit on a clean startup.
        else
            windower.add_to_chat(123, string.format(
                '[OmniWatch] sim module ran but returned no table: %s',
                tostring(mod)))
        end
    else
        windower.add_to_chat(207, string.format(
            '[OmniWatch] sim module not loaded (%s)', tostring(load_err)))
    end
end

-- ── GearInfo integration (vendored copy of sebyg666/GearInfo) ─────────────
-- The GearInfo addon gets the FFXI stat formulas right; rather than
-- re-implementing them piecewise (and being subtly off), we vendor the
-- full GearInfo source under gearinfo/ and call its compute helpers.
--
-- The user MUST unload any externally-installed GearInfo addon while
-- running OmniWatch (//unload GearInfo) — both addons define the same
-- globals (Gear_info, Buffs_inform, player.equipment, _ExtraData, etc.)
-- and load the same Resources tables. Running both at once would
-- double-fire packet handlers and clobber state.
--
-- Failure is non-fatal: if any of the gearinfo/ files don't load, _gi
-- stays nil and OmniWatch's own (less accurate) compute path is used.
--
-- We use loadfile with absolute paths (rather than require) for two
-- reasons:
--   (1) require's package.path resolution is sensitive to filename case
--       on Windows when files were created from external sources; loadfile
--       takes an exact path so it always works regardless of casing.
--   (2) The sim loader already uses loadfile successfully in the same
--       directory layout — keeping the same approach avoids surprises.
local _gi = nil
do
    local base = windower.addon_path or ''
    if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
        base = base .. '/'
    end
    local loader_path = base .. 'gearinfo/_loader.lua'
    local chunk, load_err = loadfile(loader_path)
    if chunk then
        local ok_run, mod = pcall(chunk)
        if ok_run and type(mod) == 'table' then
            _gi = mod
            -- Silent on success: the v2.0 "loaded" line below is the
            -- single confirmation we emit on a clean startup.
            -- Prime inventory cache so the first stat compute doesn't have
            -- to parse 200 items synchronously. This walks all bags via
            -- find_all_values (regex over each item description); takes
            -- 50-300ms typically. Done once on load.
            if _gi.prime_inventory then
                local ok_prime, err = pcall(_gi.prime_inventory)
                if not ok_prime then
                    windower.add_to_chat(123, string.format(
                        '[OmniWatch] GearInfo prime_inventory failed: %s',
                        tostring(err)))
                end
            end
            -- Populate member_table from windower.ffxi.get_party(). The
            -- update_party() function is defined in gearinfo/Packet_parsing
            -- and would normally run on register_event('login') when
            -- GearInfo is loaded as a separate addon. With GearInfo
            -- vendored, we have to call it ourselves — otherwise
            -- member_table stays empty and GearInfo's process_action
            -- never sets Last_Spell, which means 0x063 buff entries
            -- never get full_name/Caster, which means check_buffs can't
            -- match songs to compute stat values.
            if _G.update_party then
                local ok_up, err_up = pcall(_G.update_party)
                if not ok_up then
                    windower.add_to_chat(123, string.format(
                        '[OmniWatch] update_party() failed at load: %s',
                        tostring(err_up)))
                end
            end
            -- Prime seen_0x063_type9 so the very first 0x063 packet
            -- triggers the buff matching logic (which sets
            -- full_name/Caster on bard song buffs by walking
            -- member_table.Last_Spell). Vanilla GearInfo's flag is a
            -- guard against matching off stale buff_details on a midstream
            -- reload — irrelevant for us, since our buff_details starts
            -- empty and we want every incoming 0x063 to populate fully.
            seen_0x063_type9 = true
        else
            windower.add_to_chat(123, string.format(
                '[OmniWatch] GearInfo loader ran but failed: %s',
                tostring(mod)))
        end
    else
        windower.add_to_chat(207, string.format(
            '[OmniWatch] GearInfo backend not loaded (%s)', tostring(load_err)))
    end
end

-- Foundation for OmniWatch reliability. Every windower event callback below
-- gets wrapped via ow_safe_register, which catches errors thrown from the
-- callback, logs them with traceback to logs/crash_YYYY-MM-DD.log, and
-- continues running. Without this, a single field rename in a Windower
-- update can silently break feature(s) with no diagnostic. The log file is
-- text/append; rotate by deleting old files manually.
--
-- Format per line:
--   YYYY-MM-DD HH:MM:SS [where] message
--     traceback (indented)
local function ow_log_path()
    -- windower.addon_path may not be set yet when this file is first loaded.
    local base = (windower.addon_path or '') 
    if base == '' and windower.windower_path then
        base = windower.windower_path .. 'addons/OmniWatch/'
    end
    return base .. 'logs/'
end

local function ow_ensure_log_dir()
    local dir = ow_log_path()
    if dir == 'logs/' then return dir end  -- couldn't resolve, skip
    -- Best-effort mkdir. windower has no native mkdir; we rely on os.execute
    -- with quoted Windows path. If it fails (already exists / no permission)
    -- we'll find out at file-open time and silently skip logging.
    local cmd = 'mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul'
    pcall(os.execute, cmd)
    return dir
end

local _ow_crash_log_dir_checked = false
local function ow_log_crash(where, err_text, traceback)
    -- Never throw from this function. We swallow any I/O error since
    -- logging failure must not cascade into the very crash handler itself.
    local ok = pcall(function()
        if not _ow_crash_log_dir_checked then
            ow_ensure_log_dir()
            _ow_crash_log_dir_checked = true
        end
        local now    = os.date('*t')
        local fname  = string.format('%scrash_%04d-%02d-%02d.log',
                                     ow_log_path(), now.year, now.month, now.day)
        local f = io.open(fname, 'a')
        if not f then return end
        f:write(string.format('%04d-%02d-%02d %02d:%02d:%02d [%s] %s\n',
                              now.year, now.month, now.day,
                              now.hour, now.min, now.sec,
                              tostring(where), tostring(err_text)))
        if traceback and traceback ~= '' then
            for line in tostring(traceback):gmatch('[^\n]+') do
                f:write('    ' .. line .. '\n')
            end
        end
        f:close()
        -- Also echo to chat for live awareness, throttled by rate-of-error
        -- not implemented here — just one print per crash. Use a short tag
        -- so it doesn't drown out other output.
        windower.add_to_chat(167, string.format(
            '[OW][CRASH] %s: %s (logged)', tostring(where), tostring(err_text)))
    end)
    return ok
end

-- ow_safe_register: drop-in replacement for windower.register_event that
-- wraps the callback in xpcall with our crash logger. Returns the event id
-- for symmetry with the original API.
local function ow_safe_register(event_name, fn)
    return windower.register_event(event_name, function(...)
        local args = {...}
        local function inner() return fn(table.unpack(args)) end
        local function on_err(e)
            return tostring(e) .. '\n' .. debug.traceback('', 2)
        end
        local ok, packed = xpcall(inner, on_err)
        if not ok then
            -- packed contains "error\ntraceback"
            local msg, tb = packed, ''
            local nl = packed:find('\n')
            if nl then
                msg = packed:sub(1, nl - 1)
                tb  = packed:sub(nl + 1)
            end
            ow_log_crash('event:' .. tostring(event_name), msg, tb)
        end
    end)
end

-- ── Event bus ──────────────────────────────────────────────────────────────
-- Internal pub/sub system so multiple features can react to the same data
-- (action packets, buff changes, cast events, damage, etc.) without each
-- one having to hook directly into the central handlers. Subscribers are
-- callback functions registered with on(); emit() invokes all of them with
-- the event payload, isolated by pcall — one buggy subscriber does not
-- block others or crash the addon.
--
-- Example use:
--   ow_events.on('cast_complete', function(data)
--       -- data = {actor_id=, actor_name=, spell_id=, spell_name=, target_id=}
--       my_dps_tracker:record_cast(data)
--   end)
--   ...later, from inside an action handler:
--   ow_events.emit('cast_complete', {actor_id=..., spell_id=..., ...})
--
-- Events emitted by OmniWatch core (more added as features land):
--   'action'          → raw action packet ({act, actor_id, category, ...})
--   'cast_begin'      → spell/ability cast started ({actor_id, name, kind})
--   'cast_complete'   → spell/ability cast finished
--   'cast_interrupt'  → spell/ability interrupted
--   'buff_gain'       → buff appeared on player or party member
--   'buff_loss'       → buff wore off
--   'damage_in'       → damage taken by self
--   'damage_out'      → damage dealt by self/pets
--   'ws_land'         → weapon skill landed (subset of damage_out)
--   'target_change'   → player's main target changed
--   'zone_change'     → zone transition completed
ow_events = {_subs = {}}

function ow_events.on(event, fn)
    if type(event) ~= 'string' or type(fn) ~= 'function' then return end
    local list = ow_events._subs[event]
    if not list then
        list = {}
        ow_events._subs[event] = list
    end
    list[#list + 1] = fn
end

function ow_events.off(event, fn)
    local list = ow_events._subs[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

function ow_events.emit(event, data)
    local list = ow_events._subs[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, data)
        if not ok then
            ow_log_crash('event_bus:' .. tostring(event),
                         tostring(err), debug.traceback('', 2))
        end
    end
end

-- Convenience: report subscriber counts for diagnostics. Used by //ow help
-- and any future "what's wired up" introspection.
function ow_events.subscriber_count(event)
    local list = ow_events._subs[event]
    return list and #list or 0
end

-- Optional extdata decoder for augment strings. If unavailable, we fall
-- back to item_data.augments (which works for most cases).
local _ok_extdata, extdata = pcall(require, 'extdata')
if not _ok_extdata then extdata = nil end

-- ── GearInfo resource tables (optional) ────────────────────────────────────
-- These come from Sebyg666's GearInfo addon (BSD 2-Clause). They enumerate
-- gear-side stats that FFXI's description text doesn't cover:
--   * DW_Gear: items that enhance Dual Wield via the "Enhances..." text
--   * Martial_Arts_Gear: items that grant martial arts delay reduction
--   * Gifts: job-point gift bonuses by job and JP-spent threshold
--   * Set_bonus_by_item_id: multi-piece set effects keyed by item
-- Each is loaded optionally; absence just means we fall back to the
-- description parser and miss the value for that item.
-- ow_enhanced: hidden 'enhanced' stats by item id. Forward-declared here
-- so the addon command handler (registered earlier) can read it without
-- being forced to use upvalue lookup on a not-yet-existing local.
local ow_enhanced = {}
-- ow_path_augments: Unity Concord augmented items frequently return
-- opaque "Path: A" strings via extdata with no readable stats. Maps
-- item_id → { ["path: a"] = {"STR+15", "Double Attack+5"}, ... } so
-- the parser can resolve them to real stats. Forward-declared here;
-- populated alongside ow_enhanced.
local ow_path_augments = {}
-- ow_unity_augments — JSE neck augment overlay (and other items where
-- max-rank augments aren't carried in the in-game item description text).
-- Loaded from gearinfo/res/Misc_augments.lua at addon-load time below.
-- Maps item_id → list of "Stat+N" augment strings, fed through
-- ow_parse_desc_line by the gear-walk consumer.
--
-- Note: the variable name `ow_unity_augments` is historical — when this
-- table existed only for Unity Concord items it made sense; Unity items
-- have since migrated to gearinfo/res/Unity_Gear.lua (GearInfo's
-- Unity_rank table). What remains here is JSE necks (Reisenjima/Sortie)
-- and is poised to grow with any other gear that needs hidden-augment
-- data. Rename pending — see Misc_augments.lua header for actual scope.
local ow_unity_augments = {}
-- ow_Gifts: alias for the global Gifts loaded by gearinfo/_loader.lua
-- from gearinfo/res/Gifts.lua (single source of truth). Both ow_Gifts
-- and Gifts point at the same table.
--
-- Kept as a global rather than local because earlier architectures had
-- the sim module read it via _G.ow_Gifts; the current sim module
-- (OmniWatch_Sim.lua) doesn't actually do that lookup, so this could
-- be made local in a future cleanup. Left as-is for now to keep the
-- consolidation pass minimal.
ow_Gifts = {}
local ow_user_config = {}

-- Forward declaration for _ow_refresh_unity_rank so call sites earlier
-- in the file (the CFGWIZ save handler in the addon-command closure)
-- can resolve the name. Without this, the closure would capture
-- _ow_refresh_unity_rank as a global, which is nil — and the
-- `if X then pcall(X) end` guard would silently skip the call.
--
-- The actual function body is assigned to this name later in the file
-- (search for "_ow_refresh_unity_rank = function").
local _ow_refresh_unity_rank
-- Same forward-decl pattern for the geo settings bridge — the CFGWIZ
-- save handler closure refers to this and was being parsed before the
-- definition existed, so forward-declare here.
local _ow_refresh_geo_settings

-- ── User config storage in AppData ──────────────────────────────────────
-- Windower addons traditionally store config inside the addon folder, but
-- when Windower is installed under Program Files (which it commonly is),
-- the addon folder is read-only without admin privileges. Saving the
-- config back to disk silently fails on those installs, leaving users
-- thinking the wizard "doesn't save."
--
-- Solution: store user_config.lua under %APPDATA%\OmniWatch\, which is
-- always writable for the current user. This is the same pattern Windows
-- apps use for per-user data. Trade-off: config no longer travels with
-- the Windower folder; users migrating to a new system have to copy the
-- AppData folder manually (just like they would for any Windows app).
--
-- Notes for hand-editors: file lives at
--   %APPDATA%\OmniWatch\user_config.lua
-- which is typically  C:\Users\<you>\AppData\Roaming\OmniWatch\user_config.lua
-- Press Win+R, type %APPDATA%, hit Enter to navigate there.
local function ow_user_config_dir()
    -- os.getenv('APPDATA') returns the Roaming folder path on Windows
    -- (e.g. 'C:\Users\Joe\AppData\Roaming'). Use forward slashes for
    -- consistency with windower.addon_path elsewhere; Windows io.open
    -- accepts either. Falls back to addon_path if APPDATA isn't set
    -- (non-Windows or unusual config) — better to write somewhere
    -- than nowhere.
    local appdata = os.getenv('APPDATA')
    if appdata and appdata ~= '' then
        -- Normalize backslashes to forward slashes.
        appdata = appdata:gsub('\\', '/')
        return appdata .. '/OmniWatch'
    end
    -- Fallback: legacy in-addon location.
    return windower.addon_path .. 'data'
end

local function ow_user_config_path()
    return ow_user_config_dir() .. '/user_config.lua'
end

-- Ensure the AppData/OmniWatch directory exists. Best-effort: io can't
-- mkdir directly in stock Lua 5.1, so we use os.execute with mkdir.
-- Windows mkdir is idempotent if the dir exists (returns nonzero but
-- the dir is there); silenced via '> nul 2>&1'.
local function ow_ensure_user_config_dir()
    local dir = ow_user_config_dir()
    -- Skip if it's the addon's own data/ folder — that always exists.
    if dir == windower.addon_path .. 'data' then
        return true
    end
    -- Convert forward slashes back to backslashes for Windows mkdir.
    -- mkdir on Windows requires backslashes when the path contains
    -- spaces (e.g. 'C:\Users\Joe with space'); using cmd /c with
    -- the path quoted handles both. The 2>nul suppresses the
    -- "already exists" error.
    local win_path = dir:gsub('/', '\\')
    os.execute(string.format('cmd /c mkdir "%s" 2>nul', win_path))
    return true
end

-- Song-enhancing gear: gets resolved at first use by item NAME via
-- res.items, since hardcoded IDs would be wrong/brittle. Each entry maps
-- item name → table of song-family bonuses:
--   {all=N}      generic Song+ (applies to any song)
--   {marches=N}  March-specific (Honor/Victory/Advancing)
--   {minuet=N}   Minuet-specific  /  {madrigal=N}  /  {minne=N}  etc.
-- A piece can grant multiple at once.
-- Sourced from BG-wiki / Arislan-BRD.lua / Ivaar Singer.lua.
-- Song+ gear table. ONLY items with VERIFIED Song+/specific-song+ bonuses
-- on BG-wiki are listed. Items granting only Song Duration % (Inyanga,
-- Brioso Slippers, Carnwenhan) or Song Casting Time % do NOT belong here
-- — those affect duration/cast-time, not haste potency.
-- Source: https://www.bg-wiki.com/ffxi/Category:Song instruments + armor table
local PW_SONG_GEAR_BY_NAME = nil  -- populated from gearinfo/res/BardGear at load
local PW_SONG_HASTE_BY_NAME = nil           -- derived from Bard_Songs global at load
local PW_HONOR_MARCH_STATS_BY_NAME = nil    -- derived from Bard_Songs global at load
local PW_SONG_STATS_BY_NAME = nil           -- derived from Bard_Songs global at load
-- (OW_SONG_DURATION_GEAR / OW_SONG_SPECIFIC_GEAR are GLOBALS — they
-- need no `local` since the action handler at line ~4150 reads them
-- from outer scope. The data-load block below populates both.)
-- Cache: item_id → song-bonuses table. Built lazily from PW_SONG_GEAR_BY_NAME.
local _PW_SONG_GEAR_BY_ID = nil

-- ── COR JSE roll-enhancing gear ───────────────────────────────────────
-- Each piece adds Phantom Roll+ levels TO ONE SPECIFIC ROLL (not all rolls,
-- like generic Phantom Roll+ does). Sourced from Lorand_COR_gear.lua and
-- BG-wiki Community Corsair Guide. The bonus is per-tier:
--   normal = 1, +1 = 2, +2 = 3, +3 = 4 levels (typical empyrean scaling).
-- Keys are roll names ("Caster's Roll", etc.) since that's what the
-- compute path knows. Resolved from item NAME at runtime.
local PW_ROLL_GEAR_BY_NAME = {
    -- Caster's Roll → Navarch's Culottes (legs); Chasseur older AF
    ["Navarch's Culottes"]    = {["Caster's Roll"] = 1},
    ["Navarch's Culottes +1"] = {["Caster's Roll"] = 2},
    ["Navarch's Culottes +2"] = {["Caster's Roll"] = 3},
    ["Navarch's Culottes +3"] = {["Caster's Roll"] = 4},
    ["Chasseur's Culottes"]   = {["Caster's Roll"] = 1},
    -- Courser's Roll → Navarch's Bottes (feet); Chasseur older AF
    ["Navarch's Bottes"]    = {["Courser's Roll"] = 1},
    ["Navarch's Bottes +1"] = {["Courser's Roll"] = 2},
    ["Navarch's Bottes +2"] = {["Courser's Roll"] = 3},
    ["Navarch's Bottes +3"] = {["Courser's Roll"] = 4},
    ["Chasseur's Bottes"]   = {["Courser's Roll"] = 1},
    ["Chasseur's Bottes +1"]= {["Courser's Roll"] = 2},
    -- Blitzer's Roll → Navarch's Tricorne (head); Chasseur older AF
    ["Navarch's Tricorne"]    = {["Blitzer's Roll"] = 1},
    ["Navarch's Tricorne +1"] = {["Blitzer's Roll"] = 2},
    ["Navarch's Tricorne +2"] = {["Blitzer's Roll"] = 3},
    ["Navarch's Tricorne +3"] = {["Blitzer's Roll"] = 4},
    ["Chasseur's Tricorne"]   = {["Blitzer's Roll"] = 1},
    -- Tactician's Roll → Navarch's Frac (body); Chasseur older AF
    ["Navarch's Frac"]    = {["Tactician's Roll"] = 1},
    ["Navarch's Frac +1"] = {["Tactician's Roll"] = 2},
    ["Navarch's Frac +2"] = {["Tactician's Roll"] = 3},
    ["Navarch's Frac +3"] = {["Tactician's Roll"] = 4},
    ["Chasseur's Frac"]   = {["Tactician's Roll"] = 1},
    -- Allies' Roll → Navarch's Gants (hands); Chasseur older AF
    ["Navarch's Gants"]    = {["Allies' Roll"] = 1},
    ["Navarch's Gants +1"] = {["Allies' Roll"] = 2},
    ["Navarch's Gants +2"] = {["Allies' Roll"] = 3},
    ["Navarch's Gants +3"] = {["Allies' Roll"] = 4},
    ["Chasseur's Gants"]   = {["Allies' Roll"] = 1},
}
-- Cache: item_id → roll-bonuses table. Built lazily from PW_ROLL_GEAR_BY_NAME.
local _PW_ROLL_GEAR_BY_ID = nil

-- ── COR Phantom Roll DURATION gear ────────────────────────────────────
-- Sourced from https://www.bg-wiki.com/ffxi/Category:Phantom_Roll
-- and individual Phantom Roll equipment pages.
--
-- IMPORTANT: roll duration in FFXI is ADDITIVE seconds — NOT a multiplier.
-- Final formula:
--   final_dur = 300                                    -- base 5min
--             + winning_streak_merits * 20             -- 0..100s
--             + comm_tricorne_synergy * 6 * ws_merits  -- 0..30s if Comm.Tri+2/RA+
--             + jp_phantom_roll_effect * 2             -- 0..40s (20 ranks max)
--             + sum(equipped gear additive seconds)    -- variable
-- Max with full investment: 11:00 (660s) with Divergence weapon, 10:00 without.
--
-- Values are ADDITIVE SECONDS per equipped piece.
-- Phantom Roll duration gear, in ADDITIVE seconds (NOT a multiplier).
-- Final = base 300s + sum(this table for equipped slots) + merit/JP
-- bonuses + Tricorne synergy. Per BG-wiki Category:Phantom_Roll, max
-- duration as of Nov 2022 is 660s (11:00) with all sources stacked.
--
-- VERIFIED via FFXIDB / FFXIclopedia (printed item stats):
local OW_ROLL_DURATION_GEAR = {
    -- ── Hands: Navarch's / Chasseur's Gants ───────────────────────────
    -- Navarch's NQ has NO duration bonus. Only +1 and +2 do.
    ["Navarch's Gants +1"]    = 20,
    ["Navarch's Gants +2"]    = 40,
    -- Windower abbreviates "Navarch's" → "Nvrch.":
    ["Nvrch. Gants +1"]       = 20,
    ["Nvrch. Gants +2"]       = 40,
    -- Reforged AF — values verified from FFXI Wiki "+X seconds":
    ["Chasseur's Gants"]      = 45,
    ["Chasseur's Gants +1"]   = 50,
    ["Chasseur's Gants +2"]   = 55,
    ["Chasseur's Gants +3"]   = 60,
    -- Truncated forms (rare but seen on some res versions):
    ["Chass. Gants"]          = 45,
    ["Chass. Gants +1"]       = 50,
    ["Chass. Gants +2"]       = 55,
    ["Chass. Gants +3"]       = 60,
    -- ── Range: Compensator (gun) ──────────────────────────────────────
    -- Innate stat: "Phantom Roll" effect duration +20.
    ["Compensator"]           = 20,
    -- ── Back: Camulus's Mantle ────────────────────────────────────────
    -- INNATE +30s on the base item (DEF:16 line). NOT augment-dependent
    -- — every Camulus's Mantle has it. Augments add OTHER stats (STR/
    -- AGI/Acc/Atk etc), not more duration.
    ["Camulus's Mantle"]      = 30,
    -- ── Neck: Regal Necklace ──────────────────────────────────────────
    -- Regal Necklace stats: '"Phantom Roll"+7 "Phantom Roll" effect
    -- duration +20'. The +7 is Phantom Roll potency (boost to roll
    -- effect strength), the +20 is duration.
    ["Regal Necklace"]        = 20,
    -- ── Mainhand: Rostam (Path C augment ONLY) ────────────────────────
    -- Rostam BASE has NO duration bonus — base stats are damage,
    -- accuracy, "Phantom Roll" effect: Damage taken -6%. The +60s
    -- duration is from Path C augment ONLY ("'Phantom Roll' duration
    -- +60"). Path A and Path B users get NO duration bonus.
    --
    -- We can't see the augment path from the item id, so we OPTIMISTIC-
    -- assume Path C if a Rostam is in mainhand. Users with Path A/B
    -- should use OW_ROLL_DURATION_USER_OVERRIDES["Rostam"] = 0 to clear
    -- this. Augments only apply when the dagger is in MAINHAND, never
    -- offhand — that's enforced by mainhand_only_ids in the lookup.
    ["Rostam"]                = 60,
    ["Rostam +1"]             = 60,   -- (HQ doesn't change augment line)
    -- NOTE: Lanun Knife and Commodore's Knife do NOT carry a Phantom
    -- Roll DURATION bonus. They have "Phantom Roll effect: Damage
    -- taken -X%" which is a defensive bonus, not duration. Don't add
    -- them here even though they look related.
}
local _OW_ROLL_DURATION_GEAR_BY_ID = nil

-- User-override table: hand-edit this to set YOUR specific gear values
-- when they differ from the table above. Most common cases:
--   * Rostam without Path C augment (Path A/B = no duration bonus).
--   * Custom Camulus's Mantle augment that drops the base item (rare).
-- Values are ADDITIVE SECONDS. Survives //lua r OmniWatch.
OW_ROLL_DURATION_USER_OVERRIDES = OW_ROLL_DURATION_USER_OVERRIDES or {
    -- Examples (uncomment and edit):
    -- ["Rostam"]            = 0,    -- if you have Path A or Path B (no +60s)
    -- ["Rostam +1"]         = 0,
}

-- ── Commodore Tricorne synergy with Winning Streak ───────────────────
-- When Commodore Tricorne +2 OR any Reforged Empyrean (Lanun Tricorne /
-- +1 / +2 / +3) head is equipped, EACH Winning Streak merit grants +6
-- extra seconds (on top of the base +20s/merit), per BG-wiki Category:
-- Phantom_Roll. With 5/5 Winning Streak that's an extra +30s. This
-- applies as a runtime check inside _ow_roll_duration_inputs() since
-- the bonus depends on the equipped head AND the merit count multiplied
-- together. NQ Commodore Tricorne and +1 do NOT trigger synergy — only
-- +2 and the Lanun reforges do.
local OW_TRICORNE_SYNERGY_HEADS = {
    ["Commodore Tricorne +2"] = true,
    ["Comm. Tricorne +2"]     = true,   -- Windower abbreviation
    -- Reforged Empyrean (head slot) → all tiers trigger synergy:
    ["Lanun Tricorne"]        = true,
    ["Lanun Tricorne +1"]     = true,
    ["Lanun Tricorne +2"]     = true,
    ["Lanun Tricorne +3"]     = true,
}
local _OW_TRICORNE_SYNERGY_BY_ID = nil

-- ── COR merits + JPs ──────────────────────────────────────────────────
-- Auto-detected from windower.ffxi.get_player() at each lookup.
-- These tables are MANUAL OVERRIDES used as a fallback when live detection
-- returns nothing. Most users won't need to set them — just play COR and
-- the addon reads your actual merit/JP values from the live player record.
-- Hand-edit only if your build is unusual or you're testing on a non-COR.
PW_COR_MERITS = PW_COR_MERITS or {
    -- Winning Streak: 5 levels max. Each level adds +20s to roll duration.
    -- 0 = use whatever the live merit table reports.
    winning_streak = 0,
}

PW_COR_JP_GIFTS = PW_COR_JP_GIFTS or {
    -- Phantom Roll Effect: gives +2 seconds per rank, max 20 ranks (+40s).
    -- Per BG-wiki Category:Phantom_Roll. 0 = use whatever the live
    -- job_points table reports.
    phantom_roll_duration = 0,
}

-- ── Self-Enhancing-Magic Duration gear ────────────────────────────────
-- "Enhancing Magic Duration +N%" extends the duration of enhancing-school
-- spells the user casts on themselves (Stoneskin, Phalanx, Refresh, Regen,
-- Aquaveil, Blink, Spikes-spells, Bar-spells, Embrava, Adloquium, etc.).
-- Telchine set is the iconic source; values fractional (0.10 = +10%).
local OW_ENHANCING_DURATION_GEAR = {
    ["Telchine Cap"]         = 0.10,
    ["Telchine Cap +1"]      = 0.14,
    ["Telchine Chas."]       = 0.10,
    ["Telchine Chas. +1"]    = 0.14,
    ["Telchine Gloves"]      = 0.10,
    ["Telchine Gloves +1"]   = 0.14,
    ["Telchine Braconi"]     = 0.10,
    ["Telchine Braconi +1"]  = 0.14,
    ["Telchine Pigaches"]    = 0.10,
    ["Telchine Pigaches +1"] = 0.14,
    ["Augur's Jaseran"]      = 0.05,
    ["Augur's Tonban"]       = 0.05,
    ["Augur's Bottes"]       = 0.05,
    ["Augur's Gants"]        = 0.05,
    ["Atrophy Tabard +1"]    = 0.07,
    ["Atrophy Tabard +2"]    = 0.10,
    ["Atrophy Tabard +3"]    = 0.13,
    ["Estoqueur's Sayon"]    = 0.10,
    ["Estoqueur's Sayon +1"] = 0.14,
    ["Andoaa Earring"]       = 0.05,
}
local _OW_ENHANCING_DUR_BY_ID = nil

-- User-override for augmented enhancing gear / unlisted pieces.
OW_ENHANCING_DURATION_USER_OVERRIDES = OW_ENHANCING_DURATION_USER_OVERRIDES or {
    -- Example:
    -- ["Augmented Telchine Cap +1"] = 0.18,
}

-- Spells that get the Enhancing Magic Duration multiplier on self-cast.
local OW_ENHANCING_SPELL_SET = {
    ["Stoneskin"]=true, ["Phalanx"]=true, ["Phalanx II"]=true,
    ["Aquaveil"]=true,  ["Blink"]=true,
    ["Refresh"]=true,   ["Refresh II"]=true,  ["Refresh III"]=true,
    ["Regen"]=true,     ["Regen II"]=true,    ["Regen III"]=true,
    ["Regen IV"]=true,  ["Regen V"]=true,
    ["Blaze Spikes"]=true, ["Ice Spikes"]=true,
    ["Shock Spikes"]=true, ["Dread Spikes"]=true,
    ["Barfire"]=true,    ["Barfira"]=true,
    ["Barblizzard"]=true,["Barblizzara"]=true,
    ["Barwater"]=true,   ["Barwatera"]=true,
    ["Baraero"]=true,    ["Baraera"]=true,
    ["Barstone"]=true,   ["Barstonra"]=true,
    ["Barthunder"]=true, ["Barthundra"]=true,
    ["Barsleep"]=true,   ["Barsleepra"]=true,
    ["Barpoison"]=true,  ["Barpoisonra"]=true,
    ["Barparalyze"]=true,["Barparalyzra"]=true,
    ["Barblind"]=true,   ["Barblindra"]=true,
    ["Barsilence"]=true, ["Barsilencera"]=true,
    ["Barpetrify"]=true, ["Barpetra"]=true,
    ["Barvirus"]=true,   ["Barvira"]=true,
    ["Baramnesia"]=true, ["Baramnesra"]=true,
    ["Embrava"]=true,    ["Adloquium"]=true,
    ["Animus Augeo"]=true,["Animus Minuo"]=true,
    ["Protect"]=true,  ["Protect II"]=true,  ["Protect III"]=true,
    ["Protect IV"]=true,["Protect V"]=true,
    ["Shell"]=true,    ["Shell II"]=true,    ["Shell III"]=true,
    ["Shell IV"]=true, ["Shell V"]=true,
    ["Protectra"]=true,["Protectra II"]=true,["Protectra III"]=true,
    ["Protectra IV"]=true,["Protectra V"]=true,
    ["Shellra"]=true,  ["Shellra II"]=true,  ["Shellra III"]=true,
    ["Shellra IV"]=true,["Shellra V"]=true,
    ["Haste"]=true,    ["Haste II"]=true,
    ["Flurry"]=true,   ["Flurry II"]=true,
    ["Crusade"]=true,  ["Reprisal"]=true,
    ["Enfire"]=true,    ["Enblizzard"]=true,  ["Enwater"]=true,
    ["Enaero"]=true,    ["Enstone"]=true,     ["Enthunder"]=true,
    ["Enfire II"]=true, ["Enblizzard II"]=true,["Enwater II"]=true,
    ["Enaero II"]=true, ["Enstone II"]=true,  ["Enthunder II"]=true,
    ["Enlight"]=true,   ["Enlight II"]=true,
    ["Endark"]=true,    ["Endark II"]=true,
    ["Auspice"]=true,   ["Spectral Jig"]=true,
    ["Reraise"]=true,   ["Reraise II"]=true,  ["Reraise III"]=true,
    ["Reraise IV"]=true,
    ["Sneak"]=true,     ["Invisible"]=true,   ["Deodorize"]=true,
}

-- Composure (RDM) buff id. When active, RDM enhancing spells SELF-CAST
-- have their duration multiplied by 3.
PW_BUFF_COMPOSURE = PW_BUFF_COMPOSURE or 419

-- ────────────────────────────────────────────────────────────────────
-- BLU set-spell traits + per-spell stat bonuses (v2)
-- ────────────────────────────────────────────────────────────────────
-- BLU job traits work by accumulating "trait points" in named categories
-- across the equipped spell set. Each spell contributes points to one or
-- more categories (e.g. Erratic Flutter: DW 8, Fast Cast 8). Once a
-- category reaches 8 points, you get tier I; 16 → II; 24 → III; 32 → IV.
-- Tiers V (40) and VI (48) are unlockable only with the JP gifts.
--
-- Job Point gifts: at 100 JP spent and again at 1200 JP spent, BLU gets
-- a "Job Trait Bonus" gift that adds +8 trait points to every equipped
-- trait. Two gifts → +16 across the board. Excluded from this bonus
-- (per BG-wiki): Auto-Refresh, Double Attack, Gilfinder, Rapid Shot,
-- Zanshin, Killer Traits, Resist Traits.
--
-- Trait → in-game effect tables come from BG-wiki Job Trait pages.
-- Per-spell stat dict keys mirror the lowercase keys used in stats[]
-- elsewhere in this file.
--
-- This table covers spells that affect anything OmniWatch's stats panel
-- displays (DW, DA, TA, MAB, Macc, AccBonus, AttackBonus, StoreTP,
-- FastCast, attribute bonuses). Spells with no stats-relevant effect
-- (sleep, gravity, dispel-on-cast, etc.) are deliberately omitted —
-- they'd contribute nothing to the panel.
--
-- Reference: https://www.bg-wiki.com/ffxi/Blue_Mage_Job_Traits
-- ── BLU spell trait + stat-bonus data (loaded from data/) ─────────
-- The full per-spell trait + stats table lives in data/resources/BlueMagic.lua
-- so it can be edited (e.g. when SE adds a spell) without touching the
-- main file. The actual data load happens in the centralised data-load
-- block below alongside DW_Gear, Unity_Gear, etc.; here we declare the
-- symbols. The case-insensitive index OW_BLU_SPELLS_LC handles spell-
-- name casing differences between sources ("Sub-Zero Smash" vs
-- "Sub-zero Smash") and is rebuilt right after data load.
--
-- Falls back to an empty table on missing data file — BLU traits / stat
-- bonuses simply won't apply, but everything else keeps working.
local OW_BLU_SPELLS       = {}
local OW_BLU_SPELLS_LC    = {}
local OW_BLU_SPELLS_BY_ID = {}

-- Trait → in-game effect threshold tables (auto-generated). Each:
--   points: trait-point thresholds for each tier (sorted ascending)
--   pct:    in-game effect at that tier (numeric flat or % depending on
--           stat). Roman/string tiers (e.g. "I", "DA") render as 0 here;
--           consumers can detect those by checking stat-name presence.
--   stat:   key written into the live stats[] dict
--   gift:   true if eligible for the +8/+16 BLU JP gift bonus
-- Per bluguide source, gift-EXEMPT categories are:
--   Double/Triple Attack, Auto Refresh, Gilfinder/TH
local OW_BLU_TRAIT_TABLES = {
    acc_bonus         = {points={  8,  16,  24,  32,  40,  48}, pct={ 10,  22,  35,  48,  60,  72}, stat='accuracy', gift=true , label='Accuracy Bonus'},
    attack_bonus      = {points={  8,  16,  24,  32,  40,  48}, pct={ 10,  22,  35,  48,  60,  72}, stat='attack', gift=true , label='Attack Bonus'},
    auto_refresh      = {points={  8}, pct={  1}, stat='refresh', gift=false, label='Auto Refresh'},
    auto_regen        = {points={  8,  16,  24}, pct={  1,   2,   3}, stat='regen', gift=true , label='Auto Regen'},
    beast_killer      = {points={  8}, pct={  0}, stat='beast killer', gift=true , label='Beast Killer'},
    clear_mind        = {points={  8,  16,  24,  32,  40}, pct={  3,   6,   9,  12,  15}, stat='clear mind', gift=true , label='Clear Mind'},
    conserve_mp       = {points={  8,  16,  24,  32,  40}, pct={ 25,  28,  31,  34,  37}, stat='conserve mp', gift=true , label='Conserve MP'},
    counter           = {points={  8,  16}, pct={ 10,  12}, stat='counter', gift=true , label='Counter'},
    crit_atk_bonus    = {points={  8,  16,  24}, pct={  5,   8,  11}, stat='crit. atk. bonus', gift=true , label='Critical Attack Bonus'},
    defense_bonus     = {points={  8,  16,  24,  32,  40,  48}, pct={ 10,  22,  35,  48,  60,  72}, stat='defense', gift=true , label='Defense Bonus'},
    da                = {points={  8}, pct={  7}, stat='double attack', gift=false, label='Double Attack'},
    triple_attack     = {points={  8}, pct={  5}, stat='triple attack', gift=false, label='Triple Attack'},
    dw                = {points={  8,  16,  24,  32,  40}, pct={ 10,  15,  25,  30,  35}, stat='dw trait', gift=true , label='Dual Wield'},
    evasion_bonus     = {points={  8,  16,  24,  32,  40}, pct={ 10,  22,  35,  48,  60}, stat='evasion', gift=true , label='Evasion Bonus'},
    fast_cast         = {points={  8,  16,  24,  32,  40}, pct={  5,  10,  15,  20,  25}, stat='fast cast', gift=true , label='Fast Cast'},
    gilfinder         = {points={  8,  16}, pct={  0,   0}, stat='gilfinder', gift=false, label='Gilfinder/TH'},
    inquartata        = {points={  8,  16,  24}, pct={  5,   7,   9}, stat='inquartata', gift=true , label='Inquartata'},
    lizard_killer     = {points={  8}, pct={  0}, stat='lizard killer', gift=true , label='Lizard Killer'},
    macc_bonus        = {points={  8,  16,  24}, pct={  0,   0,   0}, stat='magic accuracy', gift=true , label='Magic Accuracy Bonus'},
    mab               = {points={  8,  16,  24,  32,  40,  48}, pct={ 20,  24,  28,  32,  36,  40}, stat='magic attack bonus', gift=true , label='Magic Attack Bonus'},
    mbb               = {points={  8,  16,  24,  32,  40}, pct={  5,   7,   9,  11,  13}, stat='magic burst bonus', gift=true , label='Magic Burst Bonus'},
    mdb               = {points={  8,  16,  24,  32,  40}, pct={ 10,  12,  14,  16,  18}, stat='magic def. bonus', gift=true , label='Magic Defense Bonus'},
    mev_bonus         = {points={  8,  16,  24}, pct={  0,   0,   0}, stat='magic evasion', gift=true , label='Magic Evasion Bonus'},
    max_hp_boost      = {points={  8,  16,  24,  32,  40,  48}, pct={ 30,  60, 120, 180, 240, 280}, stat='max hp', gift=true , label='Max HP Boost'},
    max_mp_boost      = {points={  8,  16,  24,  32}, pct={ 10,  20,  40,  60}, stat='max mp', gift=true , label='Max MP Boost'},
    plantoid_killer   = {points={  8}, pct={  0}, stat='plantoid killer', gift=true , label='Plantoid Killer'},
    rapid_shot        = {points={  8}, pct={  0}, stat='rapid shot', gift=true , label='Rapid Shot'},
    resist_gravity    = {points={  8,  16,  24}, pct={  0,   0,   0}, stat='resist gravity', gift=true , label='Resist Gravity'},
    resist_silence    = {points={  8}, pct={  0}, stat='resist silence', gift=true , label='Resist Silence'},
    resist_sleep      = {points={  8,  16,  24,  32}, pct={  0,   0,   0,   0}, stat='resist sleep', gift=true , label='Resist Sleep'},
    resist_slow       = {points={  8}, pct={  0}, stat='resist slow', gift=true , label='Resist Slow'},
    sc_bonus          = {points={  8,  16,  24,  32,  40}, pct={  8,  12,  16,  20,  23}, stat='skillchain bonus', gift=true , label='Skillchain Bonus'},
    store_tp          = {points={  8,  16,  24,  32,  40}, pct={ 10,  15,  20,  25,  30}, stat='store tp', gift=true , label='Store TP'},
    tenacity          = {points={  8,  16,  24}, pct={  5,   7,   9}, stat='tenacity', gift=true , label='Tenacity'},
    undead_killer     = {points={  8}, pct={  0}, stat='undead killer', gift=true , label='Undead Killer'},
    zanshin           = {points={  8,  16,  24}, pct={ 15,  25,  35}, stat='zanshin', gift=true , label='Zanshin'},
}

-- Cache the equipped-set summary so the per-frame stat compute doesn't
-- redo the spell-name → table lookup. Invalidated whenever the
-- equipped spells signal changes (we re-poll on each get_player tick
-- since equipping a new spell isn't a separate windower event).
local _ow_blu_cache_signature = nil
local _ow_blu_cache           = nil   -- {dw, stats, debug={}}

-- Read BLU JP totals + master level from windower. Returns:
--   {jp_spent=N, master_level=M, gifts=G}
-- where gifts = number of trait-bonus gifts active (0/1/2).
-- Falls back to {0, 0, 0} when player isn't BLU or data missing.
local function ow_get_blu_jp_summary()
    local p = windower.ffxi.get_player()
    if not p then return {jp_spent=0, master_level=0, gifts=0} end
    -- jp_details / job_points field varies by windower version.
    -- Try common shapes: p.job_points.blu, p.job_points['BLU'].
    local jp_spent, master_level = 0, 0
    if p.job_points then
        local entry = p.job_points.blu or p.job_points['BLU']
        if entry then
            -- Different windower builds expose different fields:
            --   jp_spent / spent_jp / total / jp
            jp_spent = tonumber(entry.jp_spent or entry.spent_jp
                                or entry.total or entry.jp or 0) or 0
            master_level = tonumber(entry.master_level or entry.ml or 0) or 0
        end
    end
    -- If nothing, look at top-level shortcuts some builds expose:
    if jp_spent == 0 and p.master_level then
        master_level = tonumber(p.master_level) or 0
    end
    -- Gifts: 100 JP spent → gift 1, 1200 JP spent → gift 2.
    local gifts = 0
    if jp_spent >= 100  then gifts = gifts + 1 end
    if jp_spent >= 1200 then gifts = gifts + 1 end
    return {jp_spent=jp_spent, master_level=master_level, gifts=gifts}
end

-- Resolve the equipped BLU set + JP into trait/stat output. Returns
-- two values: dw_pct (legacy compat) and stats_dict (new: contains
-- everything — DW, DA, TA, MAB, macc, accuracy, attack, defense,
-- store TP, fast cast, plus per-spell flat stats).
local function ow_resolve_blu_set(spell_ids, jp_summary)
    if not spell_ids then return 0, {} end
    -- Build a stable signature that includes JP/ML/gifts so we
    -- recompute when those change too.
    local sorted = {}
    for _, sid in ipairs(spell_ids) do sorted[#sorted+1] = sid end
    table.sort(sorted)
    local sig = table.concat(sorted, ',') .. '|'
        .. tostring(jp_summary.jp_spent) .. '|'
        .. tostring(jp_summary.master_level) .. '|'
        .. tostring(jp_summary.gifts)
    if sig == _ow_blu_cache_signature and _ow_blu_cache then
        return _ow_blu_cache.dw, _ow_blu_cache.stats
    end

    -- Step 1: accumulate trait points across the equipped set.
    local trait_pts = {}     -- e.g. {dw=16, da=4, mab=4}
    local out_stats = {}
    for _, sid in ipairs(spell_ids) do
        local sp = res.spells and res.spells[sid]
        local name = sp and (sp.en or sp.name)
        local entry = name and (OW_BLU_SPELLS[name]
                                or OW_BLU_SPELLS_LC[name:lower()])
        if entry then
            for k, v in pairs(entry) do
                if k == 'stats' then
                    for sk, sv in pairs(v) do
                        out_stats[sk] = (out_stats[sk] or 0) + sv
                    end
                else
                    trait_pts[k] = (trait_pts[k] or 0) + v
                end
            end
        end
    end

    -- Step 2: apply gift bonus (+8 per gift) to gift-eligible categories.
    -- Gifts only matter if the trait already has at least 1 set point
    -- from spells (you can't get a trait purely from gifts), per the
    -- BG-wiki hotfix note. So only categories with >0 spell points
    -- receive the boost.
    local gift_bonus = (jp_summary.gifts or 0) * 8
    for cat, tbl in pairs(OW_BLU_TRAIT_TABLES) do
        if tbl.gift and gift_bonus > 0 and (trait_pts[cat] or 0) > 0 then
            trait_pts[cat] = trait_pts[cat] + gift_bonus
        end
    end

    -- Step 3: threshold each category and write into out_stats.
    local function find_tier(points, thresholds, values)
        -- Walk thresholds high→low; first that points >= → that tier.
        for i = #thresholds, 1, -1 do
            if points >= thresholds[i] then
                return values[i], i, thresholds[i]
            end
        end
        return 0, 0, 0
    end

    -- For categories whose canonical tier values are string labels
    -- ("I"/"II"/"III", "GF"/"TH"), the auto-generated table has pct=0
    -- so the simple write-flat path doesn't help. Handle those here
    -- explicitly: choose the right stat key (or pair of stats) based
    -- on which tier was reached.
    --
    --   gilfinder:    8pts → 'gilfinder' = 1, 16pts → 'treasure hunter' = 1
    --   killer cats:  any tier ≥1 → '<type> killer' = 1 flag
    --   resist cats:  any tier ≥1 → 'resist <x>' = tier_index (1..N for I..N)
    --
    -- (DA / TA used to be lumped here as 'da_ta' with 8pts→DA, 16pts→TA.
    -- Per BG-wiki Blue_Mage_Job_Traits they're distinct traits with
    -- different spell sets, so they're now standalone OW_BLU_TRAIT_TABLES
    -- entries with their own stat keys ('double attack', 'triple attack')
    -- and the standard tier-write path handles them — no special case
    -- needed.)
    local function apply_string_tier_trait(cat, tier_idx, pts_required)
        if cat == 'gilfinder' then
            if tier_idx >= 2 then
                out_stats['treasure hunter'] = (out_stats['treasure hunter'] or 0) + 1
            elseif tier_idx >= 1 then
                out_stats['gilfinder'] = (out_stats['gilfinder'] or 0) + 1
            end
        elseif cat == 'auto_refresh' then
            -- Auto Refresh: 8pts threshold gives flat +1 refresh tick.
            if tier_idx >= 1 then
                out_stats['refresh'] = (out_stats['refresh'] or 0) + 1
            end
        else
            -- Generic string-tier categories (Killers, Resists, Rapid Shot,
            -- Macc Bonus, Mev Bonus): record tier index as the stat value.
            -- Downstream the stats panel can render "I/II/III" if desired.
            local tbl = OW_BLU_TRAIT_TABLES[cat]
            if tbl and tbl.stat then
                out_stats[tbl.stat] = (out_stats[tbl.stat] or 0) + tier_idx
            end
        end
    end

    for cat, pts in pairs(trait_pts) do
        local tbl = OW_BLU_TRAIT_TABLES[cat]
        if tbl then
            local val, tier_idx, _ = find_tier(pts, tbl.points, tbl.pct)
            if val > 0 then
                -- Numeric-tier category: write the flat/% value directly.
                out_stats[tbl.stat] = (out_stats[tbl.stat] or 0) + val
            elseif tier_idx > 0 then
                -- String-tier category (DA/TA, Killer, Resist, etc.):
                -- pct came back 0 because the canonical value is a label.
                -- Translate via the helper.
                apply_string_tier_trait(cat, tier_idx, tbl.points[tier_idx])
            end
        end
    end

    -- Step 4: JP-category linear bonuses.
    -- Magic Atk Bonus / Magic Acc Bonus categories add +1 per JP level
    -- they're capped at 20 each (max 1100 JP per category, 20 levels at
    -- 50/100/150/...). Without per-category windower access we can't
    -- read which categories the user spent JP on; we apply a CAP based
    -- estimate only when the user has the corresponding override set.
    -- Skipped for now — we'll surface this as user_config later if you
    -- want it; unsubstantiated guessing would mislead.

    -- Step 5: Master Level gift stat bumps.
    -- ML5: MAB+5, ML10: macc+10, ML15: Tactical Parry trait, ML20: +1 set
    -- slot, ML25: MAB+5 (cum 10), ML30: Auto-Refresh II trait, ML35:
    -- macc+10 (cum 20), ML40: cap pts bonus (no stat), ML45: +5 set pts,
    -- ML50: Resist Petrification.
    local ml = jp_summary.master_level or 0
    if ml >= 5  then out_stats['magic attack bonus'] = (out_stats['magic attack bonus'] or 0) + 5  end
    if ml >= 10 then out_stats['magic accuracy']     = (out_stats['magic accuracy']     or 0) + 10 end
    if ml >= 25 then out_stats['magic attack bonus'] = (out_stats['magic attack bonus'] or 0) + 5  end
    if ml >= 35 then out_stats['magic accuracy']     = (out_stats['magic accuracy']     or 0) + 10 end

    -- Cache + return. dw value preserved for legacy callers.
    local dw = out_stats['dw trait'] or 0
    _ow_blu_cache_signature = sig
    _ow_blu_cache = {dw=dw, stats=out_stats, trait_pts=trait_pts}
    return dw, out_stats
end

-- Pull the currently-equipped BLU spells from windower. Returns a list
-- of spell IDs (numeric) or nil if the player isn't on BLU. Wraps
-- both main-job (BLU/main) and sub-job (BLU/sub) cases.
local function ow_get_blu_set_spells()
    local p = windower.ffxi.get_player()
    if not p then return nil end
    local main_job = p.main_job
    local sub_job  = p.sub_job
    if main_job ~= 'BLU' and sub_job ~= 'BLU' then return nil end
    local data = nil
    if main_job == 'BLU' and windower.ffxi.get_mjob_data then
        data = windower.ffxi.get_mjob_data()
    elseif sub_job == 'BLU' and windower.ffxi.get_sjob_data then
        data = windower.ffxi.get_sjob_data()
    end
    if not data then return nil end
    local raw = data.spells or data.spell_ids or {}
    local out = {}
    for _, v in ipairs(raw) do
        if type(v) == 'number' and v > 0 then
            out[#out+1] = v
        end
    end
    return out
end

-- Walk currently-equipped gear and sum roll-enhancing bonuses for the
-- given roll name (e.g. "Caster's Roll"). Resolves names → IDs lazily
-- on first call and caches.
local function ow_roll_plus_for(roll_name)
    if not _PW_ROLL_GEAR_BY_ID then
        _PW_ROLL_GEAR_BY_ID = {}
        for name, contrib in pairs(PW_ROLL_GEAR_BY_NAME) do
            local item = res.items and (res.items:with('en', name)
                                        or res.items:with('enl', name))
            if item and item.id then
                _PW_ROLL_GEAR_BY_ID[item.id] = contrib
            end
        end
    end
    local equipment = windower.ffxi.get_items
                      and windower.ffxi.get_items('equipment')
    if not equipment then return 0 end
    local total = 0
    local slots = {'main','sub','range','ammo','head','neck',
                   'left_ear','right_ear','body','hands',
                   'left_ring','right_ring','back','waist',
                   'legs','feet'}
    for _, sn in ipairs(slots) do
        local bag = equipment[sn..'_bag']
        local idx = equipment[sn]
        if idx and idx ~= 0 and bag then
            local idata = windower.ffxi.get_items(bag, idx)
            if idata and idata.id then
                local rule = _PW_ROLL_GEAR_BY_ID[idata.id]
                if rule and rule[roll_name] then
                    total = total + rule[roll_name]
                end
            end
        end
    end
    return total
end
do
    local function try_load(name)
        local ok, data = pcall(require, name)
        if ok and type(data) == 'table' then return data end
        return nil
    end
    -- ow_Gifts is now an alias for the global Gifts loaded by
    -- gearinfo/_loader.lua from gearinfo/res/Gifts.lua (single source of
    -- truth). The sim module reads _G.ow_Gifts; consumers in this file
    -- read ow_Gifts directly. Both paths resolve to the same data.
    ow_Gifts                = Gifts                                 or {}
    -- user_config lives in AppData (see ow_user_config_dir comments
    -- above), not the addon folder, so try_load (which uses require
    -- with the addon's package path) won't find it. Use loadfile with
    -- the absolute AppData path. If the file is missing, the template
    -- writer below creates it; ow_user_config stays empty until then.
    do
        local cfg_path = ow_user_config_path()
        local chunk, err = loadfile(cfg_path)
        if chunk then
            local ok, data = pcall(chunk)
            if ok and type(data) == 'table' then
                ow_user_config = data
            else
                windower.add_to_chat(123,
                    '[OmniWatch] user_config.lua exists but didn\'t '
                    .. 'return a table — keeping defaults. Error: '
                    .. tostring(data))
                ow_user_config = {}
            end
        else
            -- File missing or unreadable — that's fine on first run.
            -- Template writer will create it with defaults.
            ow_user_config = {}
        end

        -- ── One-time migration from legacy in-addon location ────────
        -- Earlier versions stored user_config inside addons/OmniWatch/
        -- data/user_config.lua. If we see that AppData is empty (no
        -- bards section) AND the legacy file exists with real values,
        -- copy them over. Only fires when AppData has nothing useful,
        -- so a re-run of the addon never clobbers fresh AppData edits.
        local needs_migration = (
            type(ow_user_config) ~= 'table'
            or ow_user_config.bards == nil
            or next(ow_user_config) == nil)
        if needs_migration then
            local legacy_path = windower.addon_path
                                .. 'data/user_config.lua'
            local legacy_chunk = loadfile(legacy_path)
            if legacy_chunk then
                local ok, legacy_data = pcall(legacy_chunk)
                if ok and type(legacy_data) == 'table'
                        and legacy_data.bards ~= nil then
                    ow_user_config = legacy_data
                    windower.add_to_chat(207,
                        '[OmniWatch] migrated user_config.lua from '
                        .. 'addon folder to %APPDATA%\\OmniWatch\\. '
                        .. 'You can delete the old file in '
                        .. 'data/user_config.lua now.')
                    -- The save call later (in setup wizard or chat
                    -- command) will write the new AppData copy. Don't
                    -- save here yet — legacy hand-edits to advanced
                    -- sections we don't round-trip would be lost.
                end
            end
        end
    end
    -- BLU spell trait + stat-bonus table. Populates the empty
    -- OW_BLU_SPELLS declared above and rebuilds the lowercase index.
    -- A missing file leaves both empty (BLU traits don't apply, but
    -- nothing else breaks).
    --
    -- BlueMagic.lua returns a name-keyed table with a `_by_id` sub-table
    -- at the bottom for id→entry fallback lookups; we copy only the
    -- name-keyed entries and leave _by_id accessible via the original
    -- module table for callers that want it.
    do
        local blu = try_load('data/resources/BlueMagic')
        if type(blu) == 'table' then
            for k, v in pairs(blu) do
                if k ~= '_by_id' then
                    OW_BLU_SPELLS[k] = v
                end
            end
            -- Stash the id-keyed fallback for callers that want it.
            OW_BLU_SPELLS_BY_ID = blu._by_id or {}
        end
        for k, v in pairs(OW_BLU_SPELLS) do
            OW_BLU_SPELLS_LC[k:lower()] = v
        end
    end
end

-- ── BRD song data adapter ─────────────────────────────────────────
-- Reads from TWO sources:
--   1. `Bard_Songs` global — loaded by gearinfo/_loader.lua from
--      gearinfo/res/Bard_Songs.lua. Flat id-keyed table, GearInfo-native
--      shape. Each entry has the standard GearInfo fields (id, en,
--      element, effect, ["Bard Bonus"]) PLUS our metadata extensions
--      (family, merit_key, merit_per, jp_key, jp_per, mirror_ranged,
--      marcato_extends_duration, haste_cap). GearInfo ignores the
--      extensions; OmniWatch reads them.
--   2. `gearinfo/res/BardGear.lua` — OmniWatch-specific gear tables
--      (gear name → Song+ levels, duration multipliers, song-class
--      duration). Returns {song_plus, duration, duration_by_class}.
--
-- Builds the legacy-named locals/globals (PW_SONG_GEAR_BY_NAME,
-- PW_SONG_HASTE_BY_NAME, PW_HONOR_MARCH_STATS_BY_NAME,
-- PW_SONG_STATS_BY_NAME, OW_SONG_DURATION_GEAR, OW_SONG_SPECIFIC_GEAR)
-- so existing consumer code works unchanged.
do
    -- Source 1: Bard_Songs global (id-keyed). Set by gearinfo/_loader.lua.
    local songs_by_id = (type(Bard_Songs) == 'table') and Bard_Songs or {}
    -- Source 2: gear tables.
    local ok_gear, bgear = pcall(require, 'gearinfo/res/BardGear')
    if not (ok_gear and type(bgear) == 'table') then bgear = {} end
    PW_SONG_GEAR_BY_NAME  = bgear.song_plus         or {}
    OW_SONG_DURATION_GEAR = bgear.duration          or {}
    OW_SONG_SPECIFIC_GEAR = bgear.duration_by_class or {}

    -- Initialize legacy-named per-song tables.
    PW_SONG_HASTE_BY_NAME        = {}
    PW_HONOR_MARCH_STATS_BY_NAME = {}
    PW_SONG_STATS_BY_NAME        = {}

    -- Walk songs by id, write into the legacy name-keyed tables.
    local song_count = 0
    for _, e in pairs(songs_by_id) do
        if type(e) == 'table' and e.en then
            song_count = song_count + 1
            local name   = e.en
            local effect = e.effect or {}
            local bonus  = e['Bard Bonus'] or {}

            -- Haste songs: GearInfo's effect[1] = 'ma_haste'.
            if effect[1] == 'ma_haste' then
                local cap = e.haste_cap or 8
                if name == 'Honor March' then
                    -- Multi-stat: bonus[plus] is a sub-table indexed
                    -- 1=ma_haste, 2=Accuracy, 3=Attack, 4=Ranged Acc.
                    local per_1024     = {}
                    local stats_by_plus = {}
                    for plus = 0, cap do
                        local row = bonus[plus]
                        if type(row) == 'table' then
                            per_1024[plus]      = row[1] or 0
                            stats_by_plus[plus] = {
                                acc = row[2] or 0,
                                att = row[3] or 0,
                            }
                        end
                    end
                    PW_SONG_HASTE_BY_NAME[name]        = {cap=cap, per_1024=per_1024}
                    PW_HONOR_MARCH_STATS_BY_NAME[name] = stats_by_plus
                else
                    -- Flat per-plus list.
                    local per_1024 = {}
                    for plus = 0, cap do
                        per_1024[plus] = bonus[plus] or 0
                    end
                    PW_SONG_HASTE_BY_NAME[name] = {cap=cap, per_1024=per_1024}
                end
            end

            -- Stat-injection metadata: songs with a family + merit/JP
            -- key get translated into PW_SONG_STATS_BY_NAME for the
            -- generic stat injector.
            if e.family and (e.merit_key or e.jp_key) then
                local stat_key = nil
                local eff1     = effect[1]
                if     eff1 == 'Attack'          then stat_key = 'attack'
                elseif eff1 == 'Accuracy'        then stat_key = 'accuracy'
                elseif eff1 == 'Ranged Accuracy' then stat_key = 'ranged accuracy'
                elseif eff1 == 'DEF'             then stat_key = 'defense'
                elseif eff1 == 'Evasion'         then stat_key = 'evasion'
                end
                if stat_key then
                    local potency = {}
                    for plus = 0, 8 do
                        potency[plus] = bonus[plus] or 0
                    end
                    PW_SONG_STATS_BY_NAME[name] = {
                        family        = e.family,
                        stat          = stat_key,
                        mirror_ranged = e.mirror_ranged or false,
                        potency       = potency,
                        merit_key     = e.merit_key,
                        merit_per     = e.merit_per or 0,
                        jp_key        = e.jp_key,
                        jp_per        = e.jp_per or 0,
                    }
                end
            end
        end
    end

    if song_count == 0 then
        windower.add_to_chat(123,
            '[OmniWatch] BardSongs adapter: Bard_Songs global empty — '
            .. 'gearinfo/_loader may not have loaded gearinfo/res/Bard_Songs.lua.')
    end
end

-- Normalize Cor_Rolls.lua entries. The GearInfo file uses a nested
-- 'bonus' table for the matching-job-in-party bonus, with the job in
-- bonus['Main job'] and the value in bonus.effect. Our compute path
-- expects flat fields bonus_job + job_bonus, so we fill those in here
-- without altering the source file. We also resolve the roll's buff_id
-- by name (each Phantom Roll's buff has the same display name as the
-- ability — "Hunter's Roll" buff sits on you while Hunter's is rolling).
do
    for roll_id, def in pairs(Cor_Rolls or {}) do
        if type(def) == 'table' then
            -- Map nested bonus → flat fields if not already set.
            if not def.bonus_job and def.bonus
               and type(def.bonus) == 'table' then
                local mj = def.bonus['Main job']
                if mj and mj ~= 'NON' and mj ~= '' then
                    def.bonus_job = mj
                end
                if not def.job_bonus and tonumber(def.bonus.effect) then
                    def.job_bonus = tonumber(def.bonus.effect)
                end
            end
            -- Resolve buff_id from the roll's name. Each roll's buff_id
            -- is named identically (Hunter's Roll JA → "Hunter's Roll" buff).
            if not def['status'] and not def['buff_id'] and def.en
               and res.buffs then
                local b = res.buffs:with('en', def.en)
                if not b then
                    b = res.buffs:with('enl', def.en)
                end
                if b and b.id then
                    def['buff_id'] = b.id
                end
            end
        end
    end
end

-- Convenience accessors. These read from the live stats dict (built by
-- ow_compute_stats from gear descriptions), since "Phantom Roll +N",
-- "Marches +N", and "Song +N" all appear as parseable stat lines on gear
-- and augments. Old user_config values (phantom_roll_plus, etc.) are kept
-- Returns the player's total Phantom Roll+ value used to boost roll
-- effects. Source priority:
--   1. ow_user_config.corsairs.self.phantom_roll (set via //ow setup
--      wizard) when non-zero — config is authoritative same as the
--      bard song_bonus chain.
--   2. stats['phantom roll'] (parsed from "Phantom Roll +N" gear
--      description text) as fallback for unconfigured users.
-- Returns 0 if neither source has a value.
local function ow_cfg_phantom_roll_plus(stats)
    local cfg = ow_user_config and ow_user_config.corsairs
                and ow_user_config.corsairs.self
                and tonumber(ow_user_config.corsairs.self.phantom_roll)
    if cfg and cfg > 0 then return cfg end
    return (stats and stats['phantom roll']) or 0
end

-- Walk currently-equipped gear and sum song-family bonuses from the
-- PW_SONG_GEAR_BY_NAME table. Returns the total Song+ levels for the
-- given family (e.g. 'marches', 'minuet'), INCLUDING the 'all' bucket.
-- Resolves names → IDs lazily on first call and caches.
local function ow_song_plus_for_family(family)
    if not _PW_SONG_GEAR_BY_ID then
        _PW_SONG_GEAR_BY_ID = {}
        -- Many items share the same English name across upgrade tiers
        -- (Gjallarhorn 75/80/85/90/95/99/119 all have en="Gjallarhorn",
        -- different IDs). res.items:with('en', name) returns only the
        -- FIRST match — so the user's equipped tier ID may not be in
        -- our map. Iterate the entire item resource table once and
        -- index EVERY ID whose name matches one of our entries.
        if res.items then
            for id, item in pairs(res.items) do
                if type(item) == 'table' then
                    local nm  = item.en
                    local nml = item.enl
                    local rule = (nm  and PW_SONG_GEAR_BY_NAME[nm])
                              or (nml and PW_SONG_GEAR_BY_NAME[nml])
                    if rule then
                        _PW_SONG_GEAR_BY_ID[id] = rule
                    end
                end
            end
        end
    end
    local equipment = windower.ffxi.get_items
                      and windower.ffxi.get_items('equipment')
    if not equipment then return 0 end
    local total = 0
    local hits = {}  -- for debug logging
    local all_slots = {}  -- for verbose debug: every slot + item name
    local slots = {'main','sub','range','ammo','head','neck',
                   'left_ear','right_ear','body','hands',
                   'left_ring','right_ring','back','waist',
                   'legs','feet'}
    for _, sn in ipairs(slots) do
        local bag = equipment[sn..'_bag']
        local idx = equipment[sn]
        if idx and idx ~= 0 and bag then
            local idata = windower.ffxi.get_items(bag, idx)
            if idata and idata.id then
                local item = res.items and res.items[idata.id]
                local nm = (item and (item.en or item.enl)) or ('id:'..idata.id)
                local rule = _PW_SONG_GEAR_BY_ID[idata.id]
                if rule then
                    local add = (rule[family] or 0) + (rule['all'] or 0)
                    if add > 0 then
                        total = total + add
                        hits[#hits+1] = string.format('%s(+%d)', nm, add)
                    end
                    all_slots[#all_slots+1] = string.format(
                        '%s=%s[+%d]', sn, nm, (rule[family] or 0) + (rule['all'] or 0))
                else
                    all_slots[#all_slots+1] = string.format(
                        '%s=%s', sn, nm)
                end
            end
        end
    end
    -- Throttled debug log: only print when the resulting total or hit
    -- list changes, to avoid chat spam on every compute tick.
    local key = family .. '|' .. total .. '|' .. table.concat(hits, ',')
    if _ow_song_walk_last_key ~= key then
        _ow_song_walk_last_key = key
        if _ow_cast_debug then
            windower.add_to_chat(207, string.format(
                '[OW] song-gear walk family=%s total=+%d gear=[%s]',
                family, total, table.concat(hits, ', ')))
            -- Verbose dump of every equipped slot. Lets us see what
            -- res.items[id].en returns for each item, so if a piece SHOULD
            -- give song+ but the table key doesn't match the resolved name,
            -- we can spot it.
            local chunk = {}
            for _, line in ipairs(all_slots) do
                chunk[#chunk+1] = line
                if #chunk >= 4 then
                    windower.add_to_chat(207, '[OW] eq: '
                        .. table.concat(chunk, ' | '))
                    chunk = {}
                end
            end
            if #chunk > 0 then
                windower.add_to_chat(207, '[OW] eq: '
                    .. table.concat(chunk, ' | '))
            end
        end
    end
    return total
end

-- Default user_config template. Used when data/user_config.lua is
-- missing or empty — written to disk on first load, then the user
-- hand-edits it. The previous flat-key schema (blu_dw_override only)
-- has been retired.
--
-- Structure:
--   setup_complete = bool
--                 Set to true after the user completes (or skips)
--                 //ow setup. While false/absent, addon prints a
--                 setup hint on load. Run //ow setup any time to
--                 re-run the wizard regardless of this flag.
--   bards = {
--     self    = { all_songs, minuet, march, madrigal, paeon, ballad,
--                 minne, mambo, prelude, carol, etude, scherzo },
--     <name>  = same shape, lowercase character name = key. Add one
--                 entry per ally bard whose songs you want attributed
--                 with correct potency. The key matches what
--                 buff.Caster carries in Buff_Processing's bard chain
--                 (windower normalizes player names to lowercase).
--   }
--   corsairs = {
--     self    = { phantom_roll },
--     <name>  = same shape for ally cors.
--   }
--
-- Future jobs (geomancers/etc.) can be added as sibling sections
-- without restructuring this one.
--
-- Each numeric value is the +N count for that song family from gear.
-- Examples:
--   all_songs    = 4   -- e.g. Gjallarhorn / Loughnashade
--   carol        = 2   -- e.g. Mousai Gages +1
--   minuet       = 1   -- e.g. Fili Hongreline (any +N tier)
--   phantom_roll = 5   -- e.g. Lanun gear stack
local PW_USER_CONFIG_DEFAULT = {
    setup_complete = false,
    bards = {
        self = {
            all_songs = 0,
            minuet    = 0,
            march     = 0,
            madrigal  = 0,
            paeon     = 0,
            ballad    = 0,
            minne     = 0,
            mambo     = 0,
            prelude   = 0,
            carol     = 0,
            etude     = 0,
            scherzo   = 0,
        },
        -- Add ally bards as sibling entries, lowercase character name
        -- as the key. Buff_Processing reads settings.Bards[buff.Caster]
        -- — buff.Caster is also lowercase, so keying lowercase here
        -- means the lookup hits naturally. Example:
        --   joachim = {
        --       all_songs = 7, march = 1, madrigal = 1, minuet = 1,
        --       paeon = 0, ballad = 0, minne = 0, mambo = 0,
        --       prelude = 0, carol = 0, etude = 0, scherzo = 0,
        --   },
    },
    corsairs = {
        self = {
            phantom_roll = 0,   -- "Phantom Roll +N" from gear (Lanun set, etc.)
        },
        -- Add ally cors keyed by lowercase character name. Example:
        --   sammeh = { phantom_roll = 5 },
    },
}

-- The list of family keys this addon recognizes. Used by the bard
-- settings refresh and the config validator. Keep in sync with the
-- default template above and with `result` in
-- _ow_brd_per_family_song_plus / settings.Bards.song_bonus.
local PW_BARD_FAMILY_KEYS = {
    'all_songs', 'minuet', 'march', 'madrigal', 'paeon', 'ballad',
    'minne', 'mambo', 'prelude', 'carol', 'etude', 'scherzo',
}

-- Geomancer field keys for self/ally entries. Stored under
-- ow_user_config.geomancers.<who>.<field>. Five fields:
--   indi      gear boosting Indi-spell potency
--   geo       gear boosting Geo-spell (Luopan) potency
--   bolster   gear boosting Bolster strength
--   handbell  Handbell skill bonus above 900 (scales "900 skill" base)
--   all       generic +all-geomancy gear bucket
local PW_GEO_FAMILY_KEYS = {
    'indi', 'geo', 'bolster', 'handbell', 'all',
}

-- Stub the old schema constant so any straggler reference doesn't
-- crash. Empty list — no flat keys exist anymore.
local PW_USER_CONFIG_SCHEMA = {}

-- Validate / normalize the loaded user_config to the expected shape.
-- For a nested config we don't "prune" unknown keys (that destroys
-- user's commented experiments). Instead we ensure required sections
-- exist with a default shape, so downstream code can read e.g.
-- ow_user_config.bards.self.carol without nil-checking every level.
do
    if type(ow_user_config) ~= 'table' then
        ow_user_config = {}
    end
    -- bards section
    if type(ow_user_config.bards) ~= 'table' then
        ow_user_config.bards = {}
    end
    if type(ow_user_config.bards.self) ~= 'table' then
        ow_user_config.bards.self = {}
    end
    -- Fill missing family keys on `self` with 0. Per-bard ally entries
    -- are left as-is — sparse entries (only listing non-zero families)
    -- read fine, downstream uses `(t[k] or 0)`.
    for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
        if ow_user_config.bards.self[fk] == nil then
            ow_user_config.bards.self[fk] = 0
        end
    end
    -- corsairs section. Single field today (phantom_roll), parallel
    -- shape so adding more (e.g. crooked_cards detection) is a one-
    -- liner later.
    if type(ow_user_config.corsairs) ~= 'table' then
        ow_user_config.corsairs = {}
    end
    if type(ow_user_config.corsairs.self) ~= 'table' then
        ow_user_config.corsairs.self = {}
    end
    if ow_user_config.corsairs.self.phantom_roll == nil then
        ow_user_config.corsairs.self.phantom_roll = 0
    end
    -- geomancers section. Mirrors the bard shape: self + zero-or-more
    -- ally entries, each with the five PW_GEO_FAMILY_KEYS fields.
    if type(ow_user_config.geomancers) ~= 'table' then
        ow_user_config.geomancers = {}
    end
    if type(ow_user_config.geomancers.self) ~= 'table' then
        ow_user_config.geomancers.self = {}
    end
    for _, fk in ipairs(PW_GEO_FAMILY_KEYS) do
        if ow_user_config.geomancers.self[fk] == nil then
            ow_user_config.geomancers.self[fk] = 0
        end
    end
    -- Setup completion flag. Drives the first-run prompt and the
    -- conditional setup nag on addon load.
    if ow_user_config.setup_complete == nil then
        ow_user_config.setup_complete = false
    end
end

-- Write the current ow_user_config back to data/user_config.lua, with
-- a friendly comment header. Returns ok, err. Uses raw io.open since
-- the addon path is known and we don't need fancy resource handling.
-- Write a starter user_config.lua if the file is missing. Hand-edit
-- thereafter — the addon does NOT round-trip your edits through chat
-- commands. Runtime config changes (//ow config <bard> <family> <N>)
-- update the in-memory ow_user_config but the user re-saves their
-- file by hand. This avoids fighting with hand-formatted comments.
local function ow_write_user_config_template_if_missing()
    -- Make sure %APPDATA%\OmniWatch\ exists before trying to write.
    -- No-ops if it's already there or if we can't run mkdir.
    ow_ensure_user_config_dir()
    local path = ow_user_config_path()
    local existing = io.open(path, 'r')
    if existing then existing:close(); return false end
    -- Binary mode ('wb') intentional: this source file has CRLF line
    -- endings, and Lua's default text-mode write on Windows would
    -- convert `\n` to `\r\n` — which doubles to `\r\r\n` when the
    -- source bytes are already `\r\n`. Binary mode passes bytes
    -- through unchanged. The resulting user_config.lua has CRLF
    -- line endings (matches Windows convention), which Lua's loader
    -- and any text editor handle fine.
    local f, err = io.open(path, 'wb')
    if not f then return false, err end
    f:write([[-- ─────────────────────────────────────────────────────────────────────────
-- OmniWatch user_config.lua
-- ─────────────────────────────────────────────────────────────────────────
-- Lives at: %APPDATA%\OmniWatch\user_config.lua
--   (typically C:\Users\<you>\AppData\Roaming\OmniWatch\user_config.lua)
-- Press Win+R, type %APPDATA%, hit Enter to navigate there.
--
-- This file moved out of the Windower addon folder because Windower
-- installs under Program Files can't write to data/ without admin
-- rights, which made the config wizard appear to silently fail.
--
-- Hand-edit this file, OR run `//ow setup` for a guided wizard.
-- After hand-editing, //lua r omniwatch.
--
-- Migrating to a new system: copy %APPDATA%\OmniWatch\ verbatim.
--
-- Structure:
--   setup_complete = bool — set to true once you've configured (or
--                   skipped) the wizard. While false, OmniWatch
--                   prints a setup hint on load. Run //ow setup
--                   any time to (re)configure.
--   bards.self    = your own song+ totals from gear, summed across
--                   all pieces of your usual cast set.
--   bards.<name>  = ally bard's song+ totals (lowercase character
--                   name as the key). Add one entry per ally bard
--                   you regularly play with whose song potency you
--                   want shown correctly on the panel. Without an
--                   entry, ally songs still get attribution but
--                   apply only base potency. Buff_Processing reads
--                   settings.Bards[buff.Caster] — buff.Caster is
--                   lowercase, so the key here must also be
--                   lowercase to match.
--   corsairs.self = your own Phantom Roll+ from gear (Lanun set,
--                   etc.). Single number that boosts all rolls.
--   corsairs.<name> = ally cor's phantom roll+, same shape.
--
-- Each numeric value is the +N count for that song family (sum
-- across all gear pieces in that bard's typical cast set). Examples:
--   all_songs    = 4   -- Gjallarhorn / Loughnashade
--   carol        = 2   -- Mousai Gages +1
--   minuet       = 1   -- Fili Hongreline (any +N tier prints "Minuet+1")
--   phantom_roll = 5   -- Lanun set with various pieces
--
-- Future jobs (geomancers / etc.) can be added as sibling sections;
-- this file's loader doesn't enforce a fixed top-level shape beyond
-- `bards` and `corsairs`.
-- ─────────────────────────────────────────────────────────────────────────
return {
    setup_complete = false,

    bards = {
        self = {
            all_songs = 0,
            minuet    = 0,
            march     = 0,
            madrigal  = 0,
            paeon     = 0,
            ballad    = 0,
            minne     = 0,
            mambo     = 0,
            prelude   = 0,
            carol     = 0,
            etude     = 0,
            scherzo   = 0,
        },
        -- Add ally bards here. Example:
        -- joachim = {
        --     all_songs = 7,
        --     minuet    = 1, march = 1, madrigal = 1,
        --     paeon = 0, ballad = 0, minne = 0, mambo = 0,
        --     prelude = 0, carol = 0, etude = 0, scherzo = 0,
        -- },
    },

    corsairs = {
        self = {
            phantom_roll = 0,
        },
        -- Add ally cors here. Example:
        -- sammeh = { phantom_roll = 5 },
    },
}
]])
    f:close()
    return true
end

-- Persist the in-memory ow_user_config back to disk in the same shape
-- as the template. Used by //ow config <bard> <family> <N> to commit
-- runtime changes. Preserves only what's in ow_user_config.bards —
-- other top-level sections the user added by hand are NOT preserved
-- (we round-trip only the bards section since that's what we own).
-- If you keep a hand-edit-only workflow you'll never call this.
local function ow_save_user_config()
    -- AppData location, not the addon folder — see ow_user_config_dir
    -- comments above. Make sure the dir exists first; on a fresh
    -- install the user might run //ow setup before the load handler
    -- has called ow_write_user_config_template_if_missing.
    ow_ensure_user_config_dir()
    local path = ow_user_config_path()
    local f, err = io.open(path, 'w')
    if not f then return false, err end
    f:write('-- ─────────────────────────────────────────────────────────────────────────\n')
    f:write('-- OmniWatch user_config.lua (auto-saved by //ow setup or //ow config)\n')
    f:write('-- Hand-edit if you prefer; structure is documented in the addon source.\n')
    f:write('-- ─────────────────────────────────────────────────────────────────────────\n')
    f:write('return {\n')
    f:write(string.format('    setup_complete = %s,\n',
        ow_user_config.setup_complete and 'true' or 'false'))
    f:write('\n')
    f:write('    bards = {\n')
    -- Walk known bard keys, write `self` first then sorted ally names.
    local function _emit_bard(key, t)
        f:write(string.format('        %s = {\n', key))
        for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
            local v = tonumber(t and t[fk]) or 0
            f:write(string.format('            %-10s = %d,\n', fk, v))
        end
        f:write('        },\n')
    end
    local bards = (ow_user_config and ow_user_config.bards) or {}
    if bards.self then _emit_bard('self', bards.self) end
    local ally_names = {}
    for k, _ in pairs(bards) do
        if k ~= 'self' and type(bards[k]) == 'table' then
            ally_names[#ally_names+1] = k
        end
    end
    table.sort(ally_names)
    for _, name in ipairs(ally_names) do
        _emit_bard(name, bards[name])
    end
    f:write('    },\n')
    f:write('\n')
    f:write('    corsairs = {\n')
    local function _emit_cor(key, t)
        f:write(string.format('        %s = {\n', key))
        f:write(string.format('            phantom_roll = %d,\n',
            tonumber(t and t.phantom_roll) or 0))
        f:write('        },\n')
    end
    local cors = (ow_user_config and ow_user_config.corsairs) or {}
    if cors.self then _emit_cor('self', cors.self) end
    local cor_ally_names = {}
    for k, _ in pairs(cors) do
        if k ~= 'self' and type(cors[k]) == 'table' then
            cor_ally_names[#cor_ally_names+1] = k
        end
    end
    table.sort(cor_ally_names)
    for _, name in ipairs(cor_ally_names) do
        _emit_cor(name, cors[name])
    end
    f:write('    },\n')
    f:write('\n')

    -- ── Geomancers section ─────────────────────────────────────────
    -- Wizard-managed gear-scaling values for Indi/Geo spells, Bolster,
    -- Handbell skill, and a generic +all bucket. self + zero-or-more
    -- ally entries; all five fields written for each (sparse 0 fields
    -- kept explicit so hand-editing is obvious). Consumed by
    -- _ow_refresh_geo_settings to populate settings.Geo[<name>].
    f:write('    geomancers = {\n')
    local function _emit_geo(key, t)
        f:write(string.format('        %s = {\n', key))
        for _, fk in ipairs(PW_GEO_FAMILY_KEYS) do
            f:write(string.format('            %-9s = %d,\n',
                fk, tonumber(t and t[fk]) or 0))
        end
        f:write('        },\n')
    end
    local geos = (ow_user_config and ow_user_config.geomancers) or {}
    if geos.self then _emit_geo('self', geos.self) end
    local geo_ally_names = {}
    for k, _ in pairs(geos) do
        if k ~= 'self' and type(geos[k]) == 'table' then
            geo_ally_names[#geo_ally_names+1] = k
        end
    end
    table.sort(geo_ally_names)
    for _, name in ipairs(geo_ally_names) do
        _emit_geo(name, geos[name])
    end
    f:write('    },\n')
    f:write('\n')

    -- ── Player section ──────────────────────────────────────────────
    -- General player-scoped settings the wizard writes alongside the
    -- bard/cor gear data. Currently just unity_rank (1=highest, 11=lowest)
    -- which feeds settings.player.rank via _ow_refresh_unity_rank.
    -- Defaults to 1 if not explicitly set, matching the loader's default.
    f:write('    player = {\n')
    do
        local p = (ow_user_config and ow_user_config.player) or {}
        local ur = tonumber(p.unity_rank) or 1
        if ur < 1  then ur = 1  end
        if ur > 11 then ur = 11 end
        f:write(string.format('        unity_rank = %d,\n', ur))
    end
    f:write('    },\n')
    f:write('}\n')
    f:close()
    return true
end

-- ── Optional icon extractor ─────────────────────────────────────────────────
-- Load icon_extractor lazily and tolerate it being missing / broken.
-- If it fails to load for any reason, the addon still runs and sends data;
-- only the icon extraction is disabled.
local icon_extractor  = nil
local icons_available = false

local ok, mod_or_err = pcall(require, 'icon_extractor')
if ok then
    icon_extractor  = mod_or_err
    icons_available = true
else
    windower.add_to_chat(123,
        '[OmniWatch] icon_extractor not loaded: ' .. tostring(mod_or_err))
    windower.add_to_chat(123,
        '[OmniWatch] Put icon_extractor.lua in Windower4/addons/OmniWatch/ '
        .. 'to enable icons. Addon will run without them.')
end

-- icon_extractor reads windower.ffxi_path at extraction time. If that isn't
-- set (rare, but possible on some installs), feed it the resolved path.
if icons_available and icon_extractor.ffxi_path then
    local ok2, err2 = pcall(icon_extractor.ffxi_path, windower.ffxi_path)
    if not ok2 then
        windower.add_to_chat(123,
            '[OmniWatch] icon_extractor ffxi_path error: ' .. tostring(err2))
    end
end

-- ── Icon cache path ─────────────────────────────────────────────────────────
-- BMPs land in addons/OmniWatch/icons/equipment/<item_id>.bmp
-- (Python reads from icons/equipment/; we write here directly so there's
-- a single canonical location and no duplicate parent-folder cache.)
local function norm_path(p)
    if not p or p == '' then return '' end
    if p:sub(-1) ~= '/' and p:sub(-1) ~= '\\' then p = p .. '/' end
    return p
end

-- windower.addon_path is the reliable variable for an addon's own folder.
-- Fall back to windower_path + 'addons/OmniWatch/' just in case.
local ADDON_PATH = norm_path(windower.addon_path)
if ADDON_PATH == '' then
    ADDON_PATH = norm_path(windower.windower_path) .. 'addons/OmniWatch/'
end
local ICON_DIR = ADDON_PATH .. 'icons/equipment/'
-- Buff/debuff status icons live in a sibling cache folder. Filenames are
-- '<buff_id>.bmp' (windower's status_id == FFXI internal buff id == the
-- DAT row index for the icon). Python loads from icons/status/<id>.bmp.
local STATUS_ICON_DIR = ADDON_PATH .. 'icons/status/'

-- Make sure the icons dir exists. Use `mkdir /q` (Windows shell) which
-- creates intermediate parents implicitly when the path uses backslashes.
-- Probe-write tests writeability after the mkdir, so a failed creation
-- still surfaces a chat error on first use.
do
    for _, d in ipairs({ICON_DIR, STATUS_ICON_DIR}) do
        local probe_path = d .. '.probe'
        local f = io.open(probe_path, 'wb')
        if not f then
            -- /q suppresses interactive prompts; backslash path is required
            -- on Windows for nested dir creation in cmd.exe.
            os.execute('mkdir "' .. d:gsub('/', '\\') .. '" 2>nul')
            f = io.open(probe_path, 'wb')
        end
        if f then f:close(); os.remove(probe_path) end
    end
end

-- Party data  → port 5000
local udp = socket.udp()
udp:setpeername("127.0.0.1", 5000)

-- Equipment data → port 5001
local udp_equip = socket.udp()
udp_equip:setpeername("127.0.0.1", 5001)

-- Rich equipment metadata (tooltip data) → port 5007
-- Format per packet (one per filled slot):
--   slot_idx|item_id|item_name|ilvl|jobs|category|level|augment1|augment2|augment3|augment4
-- Empty fields are still present. '|' in fields escaped as \p.
local udp_equip_rich = socket.udp()
udp_equip_rich:setpeername("127.0.0.1", 5007)

-- Parsed character stats (summed across all equipment) → port 5008
-- Format: lines of "STAT|<key>|<value>" separated by \n in a single packet.
-- Uses checkparam's parsing logic for item description text.
local udp_stats = socket.udp()
udp_stats:setpeername("127.0.0.1", 5008)

-- Target data → port 5002
local udp_target = socket.udp()
udp_target:setpeername("127.0.0.1", 5002)

-- Zone/position data → port 5003
local udp_zone = socket.udp()
udp_zone:setpeername("127.0.0.1", 5003)

-- Mob debuff/buff events → port 5004
-- Line-based ASCII protocol:
--   APPLY|<target_id>|<spell_id>|<effect_id>|<duration>|<actor_id>|<is_buff>
--   REMOVE|<target_id>|<effect_id>
--   CLEAR|<target_id>
local udp_status = socket.udp()
udp_status:setpeername("127.0.0.1", 5004)

-- GearSwap state events → port 5005
-- Line-based ASCII protocol:
--   SET|<literal set path>     (e.g. "Engaged.DW.MaxHaste")
--   STATE|<state fallback>     (e.g. "Engaged.Normal.Burtgang")
local udp_gs = socket.udp()
udp_gs:setpeername("127.0.0.1", 5005)

-- Mob cast/ability events → port 5006
-- Line-based ASCII protocol:
--   CAST_START|<mob_id>|<kind>|<name>
--   CAST_DONE|<mob_id>|<kind>|<name>
--   CAST_CANCEL|<mob_id>
-- kind is "spell" or "ability".
local udp_cast = socket.udp()
udp_cast:setpeername("127.0.0.1", 5006)

-- Build the CFGWIZ|open|<flat-fields> payload from ow_user_config and
-- send it to the pygame overlay. Used by both the //ow setup command
-- handler and the inbound CFGWIZ|request_open from the in-panel
-- "Gear settings" button. Defined AFTER udp_gs is declared so the
-- send call resolves to the right local (Lua's lexical scoping looks
-- backward from where the function body is parsed, not from where
-- it's called).
function _ow_cfgwiz_open()
    if not udp_gs then
        windower.add_to_chat(123,
            '[OW Setup] internal error: udp_gs not initialized')
        return
    end
    -- Format: dotted-path=int, comma-separated. Examples:
    --   bards.self.all_songs=4,bards.self.carol=2,
    --   bards.joachim.all_songs=7,
    --   corsairs.self.phantom_roll=5,
    --   player.unity_rank=1
    local parts = {}

    -- Player.unity_rank emitted FIRST so it sorts/reads at the top of
    -- the payload. Default 1 (highest tier) when nothing is saved yet,
    -- matching the loader's default for settings.player.rank. Clamp to
    -- 1..11 to defend against a corrupt config file.
    local ur = ow_user_config and ow_user_config.player
               and tonumber(ow_user_config.player.unity_rank) or 1
    if ur < 1 then ur = 1 end
    if ur > 11 then ur = 11 end
    parts[#parts+1] = string.format('player.unity_rank=%d', ur)

    local function emit_bard(key, t)
        for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
            parts[#parts+1] = string.format('bards.%s.%s=%d',
                key, fk, tonumber(t and t[fk]) or 0)
        end
    end
    local function emit_cor(key, t)
        parts[#parts+1] = string.format('corsairs.%s.phantom_roll=%d',
            key, tonumber(t and t.phantom_roll) or 0)
    end
    local function emit_geo(key, t)
        for _, fk in ipairs(PW_GEO_FAMILY_KEYS) do
            parts[#parts+1] = string.format('geomancers.%s.%s=%d',
                key, fk, tonumber(t and t[fk]) or 0)
        end
    end
    local bards = (ow_user_config and ow_user_config.bards) or {}
    emit_bard('self', bards.self or {})
    local bard_allies = {}
    for k, _ in pairs(bards) do
        if k ~= 'self' and type(bards[k]) == 'table' then
            bard_allies[#bard_allies+1] = k
        end
    end
    table.sort(bard_allies)
    for _, name in ipairs(bard_allies) do
        emit_bard(name, bards[name])
    end
    local cors = (ow_user_config and ow_user_config.corsairs) or {}
    emit_cor('self', cors.self or {})
    local cor_allies = {}
    for k, _ in pairs(cors) do
        if k ~= 'self' and type(cors[k]) == 'table' then
            cor_allies[#cor_allies+1] = k
        end
    end
    table.sort(cor_allies)
    for _, name in ipairs(cor_allies) do
        emit_cor(name, cors[name])
    end
    local geos = (ow_user_config and ow_user_config.geomancers) or {}
    emit_geo('self', geos.self or {})
    local geo_allies = {}
    for k, _ in pairs(geos) do
        if k ~= 'self' and type(geos[k]) == 'table' then
            geo_allies[#geo_allies+1] = k
        end
    end
    table.sort(geo_allies)
    for _, name in ipairs(geo_allies) do
        emit_geo(name, geos[name])
    end
    local payload = 'CFGWIZ|open|' .. table.concat(parts, ',')
    udp_gs:send(payload)
end

-- ── Timer stream (port 5009) ───────────────────────────────────────────────
-- Carries two related streams to the python overlay's timer panels:
--   RECAST|kind|name|seconds_remaining[|...]   — multiple per packet, one per active cooldown
--   BUFF|name|seconds_remaining|source         — self-cast buff with computed duration
-- kind for RECAST is 'spell' or 'ability'. source for BUFF is 'self', 'other', 'food', 'song', 'roll'.
-- Recast packets are sent at 4Hz (250ms) when polled. Buff packets are sent
-- at cast_complete time + on duration ticks.
local udp_timers = socket.udp()
udp_timers:setpeername("127.0.0.1", 5009)

-- ── DPS tracker stream (port 5010) ────────────────────────────────────────
-- Carries the rolling 5-min combat metrics to the python overlay's DPS
-- panel. Pipe-encoded line protocol; sent at 2 Hz from the prerender tick.
-- Format (single multi-line packet):
--   DPS|<scope>|<window_sec>|<total_white>|<total_magic>|<total_ws>|
--       <hits>|<misses>|<crits>|<blinks>|<parries>|<evasions>|
--       <mob_swings_at_me>|<spell_lands>|<spell_resists>|<longest_hit>
--   WS|<name>|<count>|<total_dmg>|<best>
--   MOB|<mob_name>|<total_dmg>|<seconds_since_last_hit>
--   PARTY|<member_name>|<total_white>|<total_magic>|<total_ws>
-- <scope> is "me" or "all" depending on PW_DPS_INCLUDE_PARTY.
-- The python side discards any panel block when an empty packet arrives
-- (e.g. on zone change or //ow dps reset).
local udp_dps = socket.udp()
udp_dps:setpeername("127.0.0.1", 5010)

-- ── Inventory snapshot stream (port 5012) ─────────────────────────────────
-- Carries per-slot lists of items the current main job can equip from the
-- player's bags. Pushed once at sim mode activation and again whenever
-- inventory changes (item used, gear swap, pull from bag, etc.). Format:
--   SIM_INV|MAIN_JOB|<3-letter job>           — sent first
--   SIM_INV|SLOT|<slot>|<id>:<name>;<id>:<name>;...    — one per slot
--   SIM_INV|END                               — terminator (atomic swap on python side)
-- Slot keys match SIM_GEAR_SLOTS in python: main, sub, range, ammo, head,
-- neck, left_ear, right_ear, body, hands, left_ring, right_ring, back,
-- waist, legs, feet.
local udp_inv = socket.udp()
udp_inv:setpeername("127.0.0.1", 5012)

-- ── Bags-at-top inventory snapshot (port 5012) ──────────────────────────
-- Separate stream from SIM_INV. Walks every bag and emits one packet per
-- bag plus an INV_END sentinel so the python "bags at top" widget can
-- show item counts and contents per bag. Always-on (not gated by sim
-- activation), but rate-limited to ~once every 5 seconds to avoid wire
-- spam. Format per bag:
--   INV_BAG|<bag_name>|<count>|<id>,<count>,<name>;<id>,<count>,<name>;...
-- Then sentinel:
--   INV_END|<unix_timestamp>
local _ow_bag_inv_last_emit = 0
local _OW_BAG_INV_BAGS = {
    'inventory', 'safe', 'safe2', 'storage', 'locker',
    'satchel',   'sack', 'case',
    'wardrobe',  'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
}

local function _ow_sanitize_item_name(name)
    -- Strip wire delimiters from item names. Returns cleaned string.
    if not name then return '' end
    return (tostring(name):gsub('[|;,]', ' '))
end

local function _ow_emit_inventory_snapshot()
    local items = windower.ffxi.get_items and windower.ffxi.get_items()
    if not items then return end
    for _, bag_name in ipairs(_OW_BAG_INV_BAGS) do
        local bag_data = items[bag_name]
        local entries = {}
        if type(bag_data) == 'table' then
            for slot = 1, 80 do
                local it = bag_data[slot]
                if type(it) == 'table' and it.id and it.id > 0 then
                    local cnt = tonumber(it.count) or 1
                    local nm = ''
                    if res and res.items and res.items[it.id] then
                        nm = res.items[it.id].english or res.items[it.id].en or ''
                    end
                    if nm == '' then nm = '#' .. tostring(it.id) end
                    nm = _ow_sanitize_item_name(nm)
                    entries[#entries + 1] = string.format('%d,%d,%s', it.id, cnt, nm)
                end
            end
        end
        local payload = string.format('INV_BAG|%s|%d|%s',
            bag_name, #entries, table.concat(entries, ';'))
        pcall(function() udp_inv:send(payload) end)
    end
    pcall(function() udp_inv:send('INV_END|' .. tostring(os.time())) end)
    _ow_bag_inv_last_emit = os.clock()
end

-- ── Inventory snapshot builder + sender ──────────────────────────────────
-- Walks all bags, looks each item up in res.items, and emits per-slot
-- packets containing items the current main job can equip in that slot.
-- Used by the sim window's gear dropdowns.
--
-- Throttled: only sends when sim is active AND inventory has changed
-- (or sim was just turned on). _ow_inv_snap_dirty is flipped to true on
-- any windower 'incoming chunk' that affects inventory (0x01D, 0x01E,
-- 0x01F, 0x020) plus on logout/zone-change. Drained by prerender.

-- Slot order matches python's SIM_GEAR_SLOTS exactly. The bit value is
-- res.slots:with('en', name).id.
local _OW_SIM_SLOT_KEYS = {
    'main', 'sub', 'range', 'ammo',
    'head', 'neck', 'left_ear', 'right_ear',
    'body', 'hands', 'left_ring', 'right_ring',
    'back', 'waist', 'legs', 'feet',
}

-- Lazy-built lookups. Populated on first send; stable across the addon
-- lifetime. The reverse maps avoid an O(slots) scan per item check.
local _OW_SLOT_NAME_TO_ID = nil   -- 'main' → bit number
local _OW_JOB_NAME_TO_ID  = nil   -- 'NIN'  → bit number

local function _ow_build_sim_lookups()
    if _OW_SLOT_NAME_TO_ID and _OW_JOB_NAME_TO_ID then return end
    _OW_SLOT_NAME_TO_ID = {}
    _OW_JOB_NAME_TO_ID  = {}
    if res and res.slots then
        for id, s in pairs(res.slots) do
            if s.en then _OW_SLOT_NAME_TO_ID[s.en:lower()] = id end
        end
        -- Map our underscore-style python slot keys to windower's
        -- with-space slot names. Windower uses 'left ear', 'right ear',
        -- 'left ring', 'right ring' (with space), and 'main' / 'sub' /
        -- 'range' / 'ammo' / 'head' / 'neck' / 'body' / 'hands' / 'legs'
        -- / 'feet' / 'back' / 'waist'.
        local aliases = {
            left_ear  = 'left ear',
            right_ear = 'right ear',
            left_ring = 'left ring',
            right_ring = 'right ring',
        }
        for py_key, win_key in pairs(aliases) do
            local id = _OW_SLOT_NAME_TO_ID[win_key]
            if id then _OW_SLOT_NAME_TO_ID[py_key] = id end
        end
    end
    if res and res.jobs then
        for id, j in pairs(res.jobs) do
            if j.ens then _OW_JOB_NAME_TO_ID[j.ens] = id end
        end
    end
end

-- Build the snapshot and send it. Heavy work — only call when actually
-- needed (sim toggled on, or inventory dirty + sim still on).
local _ow_inv_snap_dirty = true   -- prime: send on first sim activation
local _ow_inv_snap_last_sent = 0  -- guards against multi-send per second

-- Reverse lookup: item id → {bag = bag_id, idx = slot_idx}. Used by
-- the sim compute path to resolve sim'd item ids to a (bag, slot_idx)
-- pair so windower.ffxi.get_items(bag, idx) returns full item_data.
-- Without this cache, the compute would walk every bag every tick to
-- find sim'd items (16 slots × 12 bags × ~80 slots = ~15k lookups per
-- 100ms), which causes a noticeable delay between picking gear in the
-- sim window and the stats panel updating.
--
-- Invalidated whenever inventory changes (same packet ids that mark
-- _ow_inv_snap_dirty: 0x01D-0x020). Rebuilt on next access.
local _ow_inv_id_to_loc = nil  -- nil = needs rebuild

local function _ow_rebuild_id_to_loc()
    local map = {}
    if res and res.bags then
        for _, bag in pairs(res.bags) do
            local bag_items = windower.ffxi.get_items(bag.id)
            if bag_items then
                for slot_idx, it in pairs(bag_items) do
                    if type(it) == 'table' and it.id and it.id > 0 then
                        -- Multiple bags may have the same item id; first
                        -- found wins. The compute doesn't care which
                        -- specific copy it reads since the underlying
                        -- res.items[id] data is identical for non-augmented
                        -- gear, and augmented gear's extdata is per-slot
                        -- so we'd need a smarter lookup either way.
                        if not map[it.id] then
                            map[it.id] = {bag = bag.id, idx = slot_idx}
                        end
                    end
                end
            end
        end
    end
    _ow_inv_id_to_loc = map
end

-- Public: get (bag, idx) for an item id, or nil if not in any bag.
-- Caller is the sim compute path. Builds the cache lazily on first
-- call and after inventory changes.
function _ow_get_item_loc(iid)
    if _ow_inv_id_to_loc == nil then
        _ow_rebuild_id_to_loc()
    end
    return _ow_inv_id_to_loc and _ow_inv_id_to_loc[iid] or nil
end

-- Resolve a sim equipment reference into (bag, idx) for the gear scan.
-- The reference can be:
--   - integer 0      → empty slot
--   - integer N      → item id; resolves to ANY copy in bags (legacy)
--   - {id, bag, idx} → exact instance; verify the slot still holds the
--                       expected id, fall back to id-scan if it moved.
-- Returns (bag, idx) or nil if not found.
function _ow_resolve_sim_equip(ref)
    if type(ref) == 'number' then
        if ref <= 0 then return nil end
        local loc = _ow_get_item_loc(ref)
        return loc and loc.bag or nil, loc and loc.idx or nil
    end
    if type(ref) ~= 'table' then return nil end
    local want_id = tonumber(ref.id) or 0
    if want_id <= 0 then return nil end
    local bag = tonumber(ref.bag) or 0
    local idx = tonumber(ref.idx) or 0
    -- Verify the cached slot still holds the right item id.
    if bag > 0 and idx > 0 then
        local cur = windower.ffxi.get_items(bag, idx)
        if cur and cur.id == want_id then
            return bag, idx
        end
    end
    -- Cached slot is stale. Scan all bags for a copy of want_id with
    -- matching augment fingerprint. We don't have the fingerprint
    -- from the ref directly (sim only stored bag/idx); fall back to
    -- "any copy of this id" — better to find SOME instance than none.
    -- Future improvement: ref.fp would let us pick the exact copy.
    local loc = _ow_get_item_loc(want_id)
    return loc and loc.bag or nil, loc and loc.idx or nil
end

local function _ow_send_sim_inventory()
    if not (_sim and _sim.is_active and _sim.is_active()) then return end
    if not res or not res.items then return end

    _ow_build_sim_lookups()
    local p = windower.ffxi.get_player()
    if not p then return end
    local job = (p.main_job or ''):upper()
    local job_id = _OW_JOB_NAME_TO_ID[job]

    -- Walk every bag/slot. We do NOT dedupe by id anymore — augmented
    -- items with the same id (e.g. multiple Camulus's Mantles) need to
    -- appear as separate entries. Each entry carries the (bag, idx)
    -- location so the sim can resolve back to the exact item with its
    -- augments.
    --
    -- IMPORTANT: windower.ffxi.get_items(bag_id) returns a table with
    -- numeric slot indices (1..N) but ALSO metadata fields (count, max,
    -- enabled). Use pairs (not ipairs) so we don't stop at the first
    -- empty slot — items are in arbitrary slots, not packed at 1..N.
    -- Skip non-table entries (the metadata fields).
    local pool = {}    -- list of {id, name, slots, jobs, bag, idx, tag, fp}
    if res.bags then
        for _, bag in pairs(res.bags) do
            local bag_items = windower.ffxi.get_items(bag.id)
            if bag_items then
                for slot_idx, it in pairs(bag_items) do
                    if type(it) == 'table' and it.id and it.id > 0
                       and type(slot_idx) == 'number' then
                        local meta = res.items[it.id]
                        if meta and meta.slots and meta.jobs then
                            local en = meta.en or meta.enl or ('item:' .. it.id)
                            -- Augments: read via extdata, build tag + fingerprint
                            local augs = ow_get_item_augments(bag.id, slot_idx)
                            local tag  = augs and ow_augment_tag(augs) or ''
                            local fp   = augs and ow_augment_fingerprint(augs) or ''
                            table.insert(pool, {
                                id = it.id, name = en,
                                slots = meta.slots, jobs = meta.jobs,
                                bag = bag.id, idx = slot_idx,
                                tag = tag, fp = fp,
                            })
                        end
                    end
                end
            end
        end
    end

    -- Emit MAIN_JOB header.
    local ok, err = pcall(function()
        udp_inv:send('SIM_INV|MAIN_JOB|' .. job)
    end)
    if not ok then
        windower.add_to_chat(123, '[OmniWatch] sim inv send failed: ' .. tostring(err))
        return
    end

    -- For each slot, build semicolon-separated list of entries.
    -- Format per entry: <id>@<bag>:<idx>:<tag>:<name>
    --   - id, bag, idx are integers
    --   - tag is the short augment summary (e.g. "DEX/Acc/WSD") or empty
    --   - name is the item's English display name
    -- Encoding caveats:
    --   - Item names CAN contain commas/semicolons/colons in rare cases.
    --     Replace ; with ',' and : with '_' (lossy but rare and harmless
    --     for display).
    --   - Augment tag uses '/' as inner separator which is safe.
    -- Multiple instances of the same item id appear as separate entries
    -- with different (bag, idx) — augmented capes show up once per copy.
    for _, slot_key in ipairs(_OW_SIM_SLOT_KEYS) do
        local slot_id = _OW_SLOT_NAME_TO_ID[slot_key]
        if slot_id then
            local parts = {}
            for _, item in ipairs(pool) do
                if item.slots[slot_id] and (not job_id or item.jobs[job_id]) then
                    local safe_name = item.name:gsub(';', ','):gsub(':', '_')
                    local safe_tag  = (item.tag or ''):gsub(';', ','):gsub(':', '_')
                    table.insert(parts, string.format('%d@%d:%d:%s:%s',
                        item.id, item.bag, item.idx, safe_tag, safe_name))
                end
            end
            -- Send even when empty so python knows we considered the
            -- slot (vs. left it stale from a previous job/snapshot).
            local body = 'SIM_INV|SLOT|' .. slot_key .. '|' .. table.concat(parts, ';')
            -- UDP packets can't exceed ~64KB but slots typically have
            -- <100 items, so this is fine. If a freak edge case ever
            -- hits the limit, we'd switch to chunked sends.
            pcall(function() udp_inv:send(body) end)
        end
    end

    -- Currently-equipped item ids per slot. Python uses this to seed
    -- sim_state["equipment"] when sim activates, so the sim dropdowns
    -- start with the live-equipped items rather than empty. Format:
    --   SIM_INV|EQUIPPED|<slot>:<id>@<bag>:<idx>;<slot>:<id>@<bag>:<idx>;...
    -- Per slot we now include the exact (bag, idx) so augmented items
    -- equipped at sim-open time resolve to the correct instance.
    do
        local eq = windower.ffxi.get_items and windower.ffxi.get_items('equipment')
        if eq then
            local SLOT_NAMES = {
                'main','sub','range','ammo','head','neck',
                'left_ear','right_ear','body','hands',
                'left_ring','right_ring','back','waist','legs','feet'
            }
            local parts = {}
            for _, sn in ipairs(SLOT_NAMES) do
                local idx = eq[sn]
                local bag = eq[sn .. '_bag']
                local id  = 0
                local b   = 0
                local i   = 0
                if idx and idx ~= 0 and bag then
                    local item = windower.ffxi.get_items(bag, idx)
                    if item and item.id then
                        id = item.id
                        b  = bag
                        i  = idx
                    end
                end
                parts[#parts+1] = string.format('%s:%d@%d:%d', sn, id, b, i)
            end
            local body = 'SIM_INV|EQUIPPED|' .. table.concat(parts, ';')
            pcall(function() udp_inv:send(body) end)
        end
    end

    -- Augment fingerprints per (bag, idx). Lets python resolve nicknames
    -- and the lua-side compute path re-find an item by augment hash if
    -- it's been moved between bags. Format:
    --   SIM_INV|FP|<bag>:<idx>:<id>:<fingerprint>;<bag>:<idx>:<id>:<fp>;...
    -- Only entries with non-empty fingerprints are emitted (plain items
    -- without augments don't need this index).
    do
        local fp_parts = {}
        for _, item in ipairs(pool) do
            if item.fp and item.fp ~= '' then
                -- Encode pipes in the fingerprint as '~' to keep the
                -- line splittable. Augments don't usually contain pipes
                -- so this is harmless; it's a one-way escape since the
                -- fingerprint is opaque (used as a key, never displayed).
                local safe_fp = item.fp:gsub('|', '~')
                fp_parts[#fp_parts+1] = string.format('%d:%d:%d:%s',
                    item.bag, item.idx, item.id, safe_fp)
            end
        end
        if #fp_parts > 0 then
            local body = 'SIM_INV|FP|' .. table.concat(fp_parts, ';')
            pcall(function() udp_inv:send(body) end)
        end
    end

    -- Terminator so python can do an atomic swap.
    pcall(function() udp_inv:send('SIM_INV|END') end)
    _ow_inv_snap_last_sent = os.clock()
end

-- Public hook: flag the snapshot dirty. Called from inventory-change
-- packet handlers and from sim activation. The actual send happens on
-- the next prerender tick (rate-limited to 1 Hz max). Also invalidates
-- the id→(bag,idx) cache used by the sim compute path so a moved or
-- used item resolves to its new location on next stat compute.
function _ow_mark_inv_dirty()
    _ow_inv_snap_dirty = true
    _ow_inv_id_to_loc  = nil
end

-- ── Inbound command socket (port 5011) ─────────────────────────────────────
-- Listens for python→lua messages. Drained on every prerender by
-- _ow_drain_inbound(). Three message families share this socket, all
-- pipe-encoded ASCII:
--
--   SIM_MODE|on               → _sim.set_active(true)
--   SIM_MODE|off              → _sim.set_active(false)
--   SIM|<key>|<value>         → _sim.set_value(key, value)
--   SIM|<key>|<value>|<sub>   → _sim.set_value(key, value, sub)
--   SIM|reset                 → _sim.set_value('reset', nil)
--   SETTING|<key>|<value>     → reserved for future schema-pushed settings
--
-- Bind is best-effort: if another instance is already listening, we
-- skip and log. The Sim panel and inbound features will silently no-op
-- in that case but the rest of OmniWatch keeps working.
local udp_cmd_in = nil
do
    local s = socket.udp()
    s:settimeout(0)    -- non-blocking; receive returns nil immediately if empty
    local ok_bind, err_bind = s:setsockname("127.0.0.1", 5011)
    if ok_bind then
        udp_cmd_in = s
    else
        windower.add_to_chat(123,
            '[OmniWatch] could not bind inbound 5011: ' .. tostring(err_bind))
    end
end

-- Drain helper: pulls all queued packets off udp_cmd_in and routes each
-- to the appropriate handler. Called from the prerender loop. Wrapped
-- in a single pcall so a malformed packet can't kill the addon.
local function _ow_drain_inbound()
    if not udp_cmd_in then return end
    local guard = 64    -- max packets per drain (defensive)
    while guard > 0 do
        guard = guard - 1
        local data, err = udp_cmd_in:receive()
        if not data then break end       -- 'timeout' = empty queue, normal exit

        -- Split first field (header) off; rest is per-message payload.
        local sep = data:find('|', 1, true)
        local head = sep and data:sub(1, sep - 1) or data
        local rest = sep and data:sub(sep + 1) or ''

        if head == 'SIM_MODE' then
            if _sim then
                _sim.set_active(rest == 'on')
                -- When sim turns on, send a fresh inventory snapshot
                -- at the next prerender tick (rate-limit allows since
                -- _ow_inv_snap_last_sent starts at 0).
                if rest == 'on' and _ow_mark_inv_dirty then
                    _ow_mark_inv_dirty()
                end
            end
        elseif head == 'SIM' then
            -- rest is "<key>" or "<key>|<value>" or "<key>|<value>|<sub>"
            local p1, p2, p3 = nil, nil, nil
            local s1 = rest:find('|', 1, true)
            if s1 then
                p1 = rest:sub(1, s1 - 1)
                local tail = rest:sub(s1 + 1)
                local s2 = tail:find('|', 1, true)
                if s2 then
                    p2 = tail:sub(1, s2 - 1)
                    p3 = tail:sub(s2 + 1)
                else
                    p2 = tail
                end
            else
                p1 = rest
            end
            if _sim and p1 then
                _sim.set_value(p1, p2, p3)
            end
        elseif head == 'SETTING' then
            -- Future use: schema settings pushed from python. No-op for now.
        elseif head == 'CFGWIZ' then
            -- Config wizard messages from the pygame overlay. rest is
            -- one of:
            --   "save|<dotted_path>=<int>,<dotted_path>=<int>,..."
            --   "cancel"     (overlay closed without saving)
            --   "skip"       (mark complete, leave values unchanged)
            local sep2 = rest:find('|', 1, true)
            local action = sep2 and rest:sub(1, sep2 - 1) or rest
            local payload = sep2 and rest:sub(sep2 + 1) or ''
            if action == 'save' then
                -- Parse dotted-path=int pairs into ow_user_config.
                -- Reset the bards/corsairs sections first so removed
                -- ally entries actually disappear (overlay sends only
                -- what currently exists in its state). The player
                -- section gets reset too so a stale unity_rank can't
                -- linger after the user clears it via Skip; if the
                -- overlay didn't send player.unity_rank we backfill
                -- it to 1 below.
                ow_user_config.bards = {self = {}}
                ow_user_config.corsairs = {self = {}}
                ow_user_config.geomancers = {self = {}}
                ow_user_config.player = {}
                for pair in payload:gmatch('[^,]+') do
                    local eq = pair:find('=', 1, true)
                    if eq then
                        local path = pair:sub(1, eq - 1)
                        local v    = tonumber(pair:sub(eq + 1)) or 0
                        -- Walk dotted path (a.b.c) creating tables as needed.
                        local cur = ow_user_config
                        local last_key = nil
                        for seg in path:gmatch('[^.]+') do
                            if last_key then
                                cur[last_key] = cur[last_key] or {}
                                cur = cur[last_key]
                            end
                            last_key = seg
                        end
                        if last_key then cur[last_key] = v end
                    end
                end
                -- Ensure all PW_BARD_FAMILY_KEYS exist on self (overlay
                -- might emit a sparse set if a family had value 0; this
                -- guarantees the validator doesn't have to repair).
                for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
                    if ow_user_config.bards.self[fk] == nil then
                        ow_user_config.bards.self[fk] = 0
                    end
                end
                if ow_user_config.corsairs.self.phantom_roll == nil then
                    ow_user_config.corsairs.self.phantom_roll = 0
                end
                -- Same for the geomancer self entry.
                for _, fk in ipairs(PW_GEO_FAMILY_KEYS) do
                    if ow_user_config.geomancers.self[fk] == nil then
                        ow_user_config.geomancers.self[fk] = 0
                    end
                end
                -- Backfill unity_rank to 1 (highest) if the overlay
                -- didn't include it. Clamp 1..11 in case a malformed
                -- packet ever sneaks through (the overlay validates
                -- on its side, but defense-in-depth).
                local ur = tonumber(ow_user_config.player.unity_rank) or 1
                if ur < 1 then ur = 1 end
                if ur > 11 then ur = 11 end
                ow_user_config.player.unity_rank = ur
                ow_user_config.setup_complete = true
                local ok, err = ow_save_user_config()
                if ok then
                    windower.add_to_chat(207,
                        '[OW Setup] Configuration saved. Run //ow config '
                        .. 'to verify, or //ow setup to redo.')
                else
                    windower.add_to_chat(123,
                        '[OW Setup] Save failed: ' .. tostring(err))
                end
                -- Refresh settings.Bards immediately so the values flow
                -- without waiting for the next periodic refresh.
                if _ow_refresh_bard_settings then
                    pcall(_ow_refresh_bard_settings)
                end
                -- Same for settings.Cors so GearInfo's roll math picks up
                -- the wizard's Phantom Roll+ value on the very next roll.
                if _ow_refresh_cor_settings then
                    pcall(_ow_refresh_cor_settings)
                end
                -- And push the new Unity rank into settings.player.rank
                -- so GearInfo's Calculator scales Unity-augmented gear
                -- correctly on the next compute (rather than waiting
                -- for the recompute loop to call refresh on its own).
                if _ow_refresh_unity_rank then
                    pcall(_ow_refresh_unity_rank)
                end
                -- Push geo wizard values into settings.Geo[me] so the
                -- compute path picks them up on the next recompute.
                if _ow_refresh_geo_settings then
                    pcall(_ow_refresh_geo_settings)
                end
            elseif action == 'skip' then
                ow_user_config.setup_complete = true
                local ok, err = ow_save_user_config()
                if ok then
                    windower.add_to_chat(207,
                        '[OW Setup] Marked complete (no changes). '
                        .. 'Run //ow setup any time to (re)configure.')
                else
                    windower.add_to_chat(123,
                        '[OW Setup] Save failed: ' .. tostring(err))
                end
            elseif action == 'cancel' then
                windower.add_to_chat(207,
                    '[OW Setup] Cancelled. No changes saved.')
            elseif action == 'request_open' then
                -- Pygame UI clicked the "Gear settings" button or
                -- equivalent. Build the current state and send it
                -- back so the modal renders with up-to-date values.
                _ow_cfgwiz_open()
            end
        elseif head == 'CMD' then
            -- Hotbar buttons of kind="windower" send their command
            -- through here. Python strips the leading '/' before
            -- sending; we re-add it and dispatch via send_command.
            -- Header is 'CMD', rest is the slash-command body.
            -- Example: button command "input /checkparam <me>"
            -- arrives as data="CMD|input /checkparam <me>" and we
            -- run windower.send_command('input /checkparam <me>').
            if rest and rest ~= '' then
                if _ow_cast_debug then
                    windower.add_to_chat(207,
                        '[OW] CMD recv: ' .. tostring(rest))
                end
                windower.send_command(rest)
            end
        else
            -- Unrecognised header. Fall through to legacy bare-command
            -- mode: if the entire packet looks like a slash command
            -- payload (no pipe, no known header), treat the whole
            -- thing as one. This covers older python builds that
            -- didn't prefix CMD|.
            if not sep then
                if _ow_cast_debug then
                    windower.add_to_chat(207,
                        '[OW] bare cmd recv: ' .. tostring(data))
                end
                windower.send_command(data)
            end
        end
    end
end

-- Commands registered via //omniwatch. Supports:
--   //omniwatch set   <path>    - report literal gearswap set path
--   //omniwatch state <string>  - report fallback state string
--   //omniwatch debug           - toggle diagnostic printing in console/chat
_ow_cast_debug = false

-- Buff-timer parser debug. Turn on with //ow buffdebug to see the 0x063
-- packet contents printed to chat (one line per parsed slot, with computed
-- expiry seconds). Separate from _ow_cast_debug so you can troubleshoot
-- buff timers without the gear-walk / gifts-applied noise.
_ow_buff_debug = false

_ow_gs_debug   = false

-- Last STATE/SET strings echoed to chat under //ow debug. Used to
-- suppress duplicates so the heartbeat doesn't spam.
_ow_last_echoed_state = ''
_ow_last_echoed_set   = ''

-- Bolter's Roll value tracking. Cat=6 phantom roll packets carry the
-- roll id in act.param and the roll value (1..12) in action.param.
-- We snoop for our own rolls of id 118 (Bolter's) and store the value
-- so ow_compute_speed() can use the precise per-roll value rather
-- than a hardcoded estimate. Cleared on zone change / buff drop.
_ow_bolters_value = 0    -- 0 = no Bolter's active; 1..11 = roll value

-- Base character stats (race + job + level only). Updated from packet
-- 0x061 snoops. Empty until first 0x061 arrives — until then, formulas
-- that need base stats fall back to using delta-only (we'll be off by
-- the base value, ~80-90 per stat at 99). On zone change a fresh 0x061
-- is sent so this auto-refreshes.
_ow_base_stats = {}

-- Generic Phantom Roll state: { roll_id (cat-6 ability id) → roll_value }.
-- Populated by the all-rolls snoop. Cleared on zone change. Currently we
-- only USE _ow_bolters_value for the speed calc; this table is groundwork
-- for future per-roll stat effects (Hunter's→racc, Chaos→att, etc).
_ow_roll_state = {}
-- Parallel table: roll_id → true if this roll was cast under Crooked Cards.
-- Compute path multiplies the final roll value by 1.2 for these.
-- Cleared when the roll's buff drops (handled by _ow_prune_buff_sources).
_ow_roll_crooked = {}

-- Set of all Phantom Roll job-ability IDs (cat=6 act.param). Built once
-- by walking res.job_abilities for entries whose name starts with
-- "Phantom Roll" or whose category implies a roll. Static list to avoid
-- repeated lookups; sourced from BG-wiki / Cor_Rolls.lua keys.
local PW_PHANTOM_ROLL_IDS = {
    [98]=true,  [99]=true,  [100]=true, [101]=true,  -- early rolls
    [102]=true, [103]=true, [104]=true, [105]=true,
    [106]=true, [107]=true, [108]=true, [109]=true,
    [110]=true, [111]=true, [112]=true, [113]=true,
    [114]=true, [115]=true, [116]=true, [117]=true,
    [118]=true,                                       -- Bolter's
    [119]=true, [120]=true, [121]=true, [122]=true,
    [123]=true, [124]=true,
}

-- ── Buff source tracking ──────────────────────────────────────────────────
-- Maps buff_id → list of source records describing what applied that buff.
-- Each source: { src_kind = 'song'|'spell'|'roll'|'food',
--                src_id   = numeric id (spell/ability/item),
--                src_name = display name,
--                potency  = numeric (haste% * 100, attack delta, etc.) }
--
-- When a buff_id disappears from player.buffs we clear the corresponding
-- entries. Multiple sources can share a buff_id (e.g. multiple Marches
-- all share buff 33 [Haste]) — we keep them all so consumers can sum.
_ow_buff_sources = {}

-- Persistence path. Written whenever _ow_buff_sources changes; read once
-- at addon load so a omniwatch.py restart doesn't lose live buff data.
local _PW_BUFF_STATE_PATH = 'data/_ow_buff_state.lua'

local function _ow_save_buff_state()
    local path = (windower.addon_path or '') .. _PW_BUFF_STATE_PATH
    local f, err = io.open(path, 'w')
    if not f then return end
    f:write('-- Auto-generated by OmniWatch. Do not edit by hand.\n')
    f:write('return {\n')
    for buff_id, srcs in pairs(_ow_buff_sources) do
        f:write(string.format('  [%d] = {\n', buff_id))
        for _, s in ipairs(srcs) do
            f:write(string.format(
                '    { src_kind = %q, src_id = %d, src_name = %q, potency = %s },\n',
                s.src_kind or '', s.src_id or 0, s.src_name or '',
                tostring(s.potency or 0)))
        end
        f:write('  },\n')
    end
    f:write('}\n')
    f:close()
end

local function _ow_load_buff_state()
    local ok, data = pcall(require, _PW_BUFF_STATE_PATH:gsub('%.lua$', ''))
    if ok and type(data) == 'table' then
        _ow_buff_sources = data
    end
end

-- Remove source entries whose buff_id is no longer active on the player.
-- Called periodically so songs/spells that wore off don't keep contributing
-- to haste/speed/etc. Persists state if anything was removed.
local function _ow_prune_buff_sources()
    local player = windower.ffxi.get_player()
    if not (player and player.buffs) then return end
    local active = {}
    for _, bid in ipairs(player.buffs) do active[bid] = true end
    local changed = false
    local now = os.time()
    -- Grace period: when a song is cast, cat=4 fires before the buff
    -- packet (0x063) lands, so player.buffs won't contain the buff_id
    -- yet. If we prune in that window, we lose the just-written source
    -- and the song silently disappears from the haste sum. Skip the
    -- bucket entirely if any source in it was written in the last 5s.
    for bid, srcs in pairs(_ow_buff_sources) do
        if not active[bid] then
            local fresh = false
            if type(srcs) == 'table' then
                for _, s in ipairs(srcs) do
                    if s.cast_time and (now - s.cast_time) < 5 then
                        fresh = true
                        break
                    end
                end
            end
            if not fresh then
                -- Diagnostic: log what we're about to nuke
                if type(srcs) == 'table' and #srcs > 0 then
                    local names = {}
                    for _, s in ipairs(srcs) do
                        names[#names+1] = (s.src_kind or '?') .. ':' .. tostring(s.src_name or '?')
                    end
                    windower.add_to_chat(207, string.format(
                        '[OW] prune: bid=%d not in player.buffs, dropping %d records: %s',
                        bid, #srcs, table.concat(names, ',')))
                end
                _ow_buff_sources[bid] = nil
                changed = true
            end
        else
            -- Buff_id IS active, but individual song records within the
            -- bucket can still be stale. Songs share buff_id 214 (March
            -- bucket) — when Honor wears off but Victory is still up,
            -- buff 214 stays in player.buffs but Honor's source record
            -- is now stale and would otherwise keep contributing haste.
            -- Drop any source older than 30 min — well past any realistic
            -- song lifetime even with full duration gear (Carnwenhan 1.5×
            -- + instrument 1.4× + Troubadour 2× pushes max-duration songs
            -- to ~12-18 min). The previous 480s cap was dropping march
            -- source records while the buff was still alive in-game,
            -- causing the stat panel to revert to a no-buffs state ~8 min
            -- after a long song was cast.
            if type(srcs) == 'table' then
                local kept = {}
                for _, s in ipairs(srcs) do
                    local age = (s.cast_time and (now - s.cast_time)) or 0
                    if s.src_kind == 'song' and age > 1800 then
                        changed = true  -- record dropped
                    else
                        kept[#kept+1] = s
                    end
                end
                if #kept ~= #srcs then
                    if #kept == 0 then
                        _ow_buff_sources[bid] = nil
                    else
                        _ow_buff_sources[bid] = kept
                    end
                end
            end
        end
    end
    if changed then
        _ow_save_buff_state()
    end
    -- Food buff drop check: 251 is the standard Food buff id. When it
    -- drops, clear cached food stats so we stop contributing them.
    if _ow_food_item_id ~= 0 and not active[251] then
        _ow_food_stats = {}
        _ow_food_item_id = 0
    end
    -- Phantom Roll drop: each roll produces a buff with the roll's name
    -- (e.g. "Hunter's Roll" buff_id). When the buff is no longer in
    -- player.buffs, drop the cached roll value.
    if Cor_Rolls then
        for roll_id in pairs(_ow_roll_state) do
            local roll_def = Cor_Rolls[roll_id]
            local buff_id = roll_def and (tonumber(roll_def['status'])
                                          or tonumber(roll_def['buff_id']))
            if buff_id and not active[buff_id] then
                _ow_roll_state[roll_id] = nil
                _ow_roll_crooked[roll_id] = nil
            end
        end
    end
end

ow_safe_register('load', function()
    _ow_load_buff_state()
    -- Prime base stats from windower's last-cached 0x061. Without
    -- this, _ow_base_stats stays empty until a fresh server-side
    -- 0x061 fires (gear swap, level up, buff change) — which means
    -- accuracy/attack/etc. compute against incomplete inputs and
    -- read low. windower.packets.last_incoming gives us the most
    -- recent packet from the session's history. Pattern lifted
    -- from GearInfo's initialize_packet_parsing.
    pcall(function()
        if windower.packets and windower.packets.last_incoming then
            local cached = windower.packets.last_incoming(0x061)
            if cached then
                local ok, p = pcall(packets.parse, 'incoming', cached)
                if ok and p then
                    _ow_base_stats = {
                        str    = tonumber(p['Base STR']) or 0,
                        dex    = tonumber(p['Base DEX']) or 0,
                        vit    = tonumber(p['Base VIT']) or 0,
                        agi    = tonumber(p['Base AGI']) or 0,
                        ['int']= tonumber(p['Base INT']) or 0,
                        mnd    = tonumber(p['Base MND']) or 0,
                        chr    = tonumber(p['Base CHR']) or 0,
                    }
                    if _ow_cast_debug then
                        windower.add_to_chat(207, string.format(
                            '[OW] base stats primed from cached 0x061: '
                            ..'STR=%d DEX=%d VIT=%d AGI=%d INT=%d MND=%d CHR=%d',
                            _ow_base_stats.str, _ow_base_stats.dex,
                            _ow_base_stats.vit, _ow_base_stats.agi,
                            _ow_base_stats['int'], _ow_base_stats.mnd,
                            _ow_base_stats.chr))
                    end
                end
            end
        end
    end)
    -- Write the user_config.lua starter template if the file is missing.
    -- This way new installs get a clear template to hand-edit, instead
    -- of a silent empty config. Existing files are NOT touched.
    pcall(ow_write_user_config_template_if_missing)
    windower.add_to_chat(207, string.format(
        '[OmniWatch] loaded v%s. Type //ow help for commands.',
        _addon.version))
    -- First-run setup nag. setup_complete is set to true by the wizard
    -- on completion (or by 'skip'). Until then, point the user at the
    -- wizard. Idempotent — doesn't pester after they've completed
    -- once. Hand-editors who never run //ow setup can flip the flag
    -- in user_config.lua to silence this.
    if not (ow_user_config and ow_user_config.setup_complete) then
        windower.add_to_chat(207,
            '[OmniWatch] First run: type //ow setup to configure your '
            .. 'Song+ / Phantom Roll+ / Geomancy+ / Unity Rank values. '
            .. 'Or //ow setup skip to dismiss.')
    end
end)

-- Single source of truth for the command list — used by both the
-- load message (links here) and //ow help.
local PW_COMMANDS_HELP = {
    {'help',                  'Show this list of commands.'},
    {'debug',                 'Toggle diagnostic chat output (action packets, '
                              .. 'Bolter\'s rolls, gearswap state echoes).'},
    {'setup',                 'Open the config overlay (Song+ / Phantom Roll+ / Geomancy+ / Unity Rank).'},
    {'setup skip',            'Mark setup complete without opening the overlay.'},
    {'config',                'List current bard / cor config in chat.'},
    {'config <bard> <fam> <n>','Set bards.<bard>.<fam> = n in memory.'},
    {'config save',           'Persist config to data/user_config.lua.'},
    {'position [on|off]',     'Toggle panel-drag mode (forces panels visible '
                              .. 'with mock data so you can move them).'},
    {'set <path>',            'Report a literal gearswap set path (called by '
                              .. 'Wormfood-Globals on equip()).'},
    {'state <string>',        'Report fallback state string (called by '
                              .. 'Wormfood-Globals heartbeat).'},
    {'testcast',              'Emit a synthetic CAST_START event on yourself '
                              .. '(verifies the cast pipe works end-to-end).'},
    {'lock [on|off]',         'Toggle panel lock. When locked, panels can\'t '
                              .. 'be dragged or resized — accidental clicks '
                              .. 'pass through to hyperlinks. Setup mode '
                              .. 'auto-unlocks while it\'s on.'},
    {'events',                'List event-bus subscriber counts. Diagnostic '
                              .. 'for verifying that features have wired up '
                              .. 'to the internal pub/sub correctly.'},
    {'dumpbuffs',             'Print every active buff with id and name. Also '
                              .. 'prints resolved speed-buff IDs and the '
                              .. 'cached Bolter\'s roll value.'},
    {'dumpcharstats',         'Print player.stats (gear+buffs delta) and '
                              .. 'player.merits. Compare to /checkparam in-'
                              .. 'game to verify totals.'},
    {'dumpdesc',              'Print the raw description text of each '
                              .. 'equipped item. Lets us verify how items '
                              .. 'are actually formatted (single line / '
                              .. 'multi-line / Pet: split).'},
    {'dumpgear [slot]',        'Per-slot dump of equipped item id, name, '
                              .. 'desc text, real augments, and any '
                              .. 'ow_enhanced/DW_Gear/MA_Gear hidden-stat '
                              .. 'entry. Optional slot arg restricts to '
                              .. 'one slot, e.g. //ow dumpgear waist.'},
    {'dumpstats',             'Force a stats recompute and print summary; '
                              .. 'also writes data/omniwatch_stats.lua for '
                              .. 'gearswap to require.'},
    {'blu',                   'BLU set-spell diagnostic: lists equipped set '
                              .. 'spells, their per-spell trait points and '
                              .. 'stat bonuses, and the resolved DW% from '
                              .. 'set points. Only works on BLU main/sub.'},
    {'dumpduration',          'Print the current Phantom Roll and Enhancing '
                              .. 'Magic duration multipliers. Lists which '
                              .. 'equipped pieces contribute, plus merit / JP '
                              .. 'bonuses. Use to verify buff timer accuracy.'},
    {'dps',                   'Toggle the DPS panel on/off.'},
    {'dps reset',             'Clear the DPS rolling 5-min window.'},
    {'dps party',             'Toggle whether party-member damage is '
                              .. 'tracked alongside your own.'},
    {'dps window',            '<seconds> — set the DPS rolling window length '
                              .. '(default 300). Pass 0 to keep all events '
                              .. 'since the last reset (no rolling).'},
    {'dps status',            'Print DPS tracker diagnostics: how many '
                              .. 'actions we received, what categories, '
                              .. 'how many we classified as ours, and any '
                              .. 'unrecognized message_ids.'},
    {'serverstats [on|off|debug|status]',
                              'Experimental: silent server-truth pAtt fetcher '
                              .. 'via 0x061 packet. Default OFF. Use '
                              .. '"//ow serverstats on" to enable, "off" to '
                              .. 'disable, "debug on/off" for verbose logs, '
                              .. '"status" for state. See Server_Stats.lua '
                              .. 'header for full docs.'},
}
ow_safe_register('addon command', function(command, ...)
    command = (command or ''):lower()
    local args = {...}
    if command == 'help' or command == '' then
        windower.add_to_chat(207,
            '[OmniWatch] commands (prefix //ow or //omniwatch):')
        for _, cmd in ipairs(PW_COMMANDS_HELP) do
            windower.add_to_chat(207, string.format(
                '  %-22s  %s', cmd[1], cmd[2]))
        end
        return
    end
    if command == 'set' and #args > 0 then
        local path = table.concat(args, ' ')
        udp_gs:send('SET|' .. path)
        if _ow_gs_debug and path ~= _ow_last_echoed_set then
            _ow_last_echoed_set = path
            windower.add_to_chat(207, '[OW] SET -> ' .. path)
        end
    elseif command == 'state' and #args > 0 then
        local s = table.concat(args, ' ')
        udp_gs:send('STATE|' .. s)
    elseif command == 'debug' then
        _ow_cast_debug = not _ow_cast_debug
        _ow_gs_debug   = not _ow_gs_debug
        windower.add_to_chat(207, string.format('[OW] debug = %s',
            tostring(_ow_cast_debug)))
    elseif command == 'buffdebug' then
        _ow_buff_debug = not _ow_buff_debug
        _ow_last_buff_dbg = nil   -- force a fresh dump on next 0x063
        windower.add_to_chat(207, string.format('[OW] buff_debug = %s',
            tostring(_ow_buff_debug)))
    elseif command == 'buffts' then
        -- Toggle 0x063 sub-9 timestamp diagnostic logging. When on,
        -- prints raw and computed expiry timestamps for active buffs
        -- so we can empirically determine the right epoch formula.
        -- Used to develop/verify the server-pushed buff duration system.
        _ow_buffts_debug = not _ow_buffts_debug
        windower.add_to_chat(207, string.format(
            '[OW] buffts_debug = %s. Cast a buff and watch for [OW buffts] '
            .. 'lines.', tostring(_ow_buffts_debug)))
    elseif command == 'dumpcfg' then
        -- Diagnostic: dump current in-memory ow_user_config to chat.
        -- Useful when the wizard isn't showing expected values — this
        -- reveals whether the in-memory state matches what's saved
        -- on disk.
        local b = (ow_user_config and ow_user_config.bards) or {}
        local c = (ow_user_config and ow_user_config.corsairs) or {}
        windower.add_to_chat(207, '[OW DIAG] dumpcfg: ow_user_config in memory:')
        windower.add_to_chat(207, string.format(
            '[OW DIAG]   setup_complete = %s',
            tostring(ow_user_config and ow_user_config.setup_complete)))
        if b.self then
            local parts = {}
            for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
                parts[#parts+1] = string.format('%s=%s',
                    fk, tostring(b.self[fk]))
            end
            windower.add_to_chat(207, '[OW DIAG]   bards.self: '
                                      .. table.concat(parts, ' '))
        end
        if c.self then
            windower.add_to_chat(207, string.format(
                '[OW DIAG]   corsairs.self.phantom_roll = %s',
                tostring(c.self.phantom_roll)))
        end
    elseif command == 'dumpstats' then
        -- Dump the full computed stats dict to chat. Useful for
        -- verifying which stats a gear swap actually contributes.
        -- Sorted alphabetically so before/after diffs read cleanly.
        local stats = ow_compute_stats()
        local keys = {}
        for k, _ in pairs(stats) do
            keys[#keys+1] = k
        end
        table.sort(keys)
        windower.add_to_chat(207, string.format(
            '[OW] dumpstats: %d entries', #keys))
        for _, k in ipairs(keys) do
            windower.add_to_chat(207, string.format(
                '  %s = %s', k, tostring(stats[k])))
        end
    elseif command == 'jobbonus' then
        -- Show what each currently-active roll's job bonus WOULD add
        -- if the bonus job were in your party. Doesn't modify any
        -- stats — just shows what the panel would read with the bonus.
        --
        -- Also dumps GI plumbing values for diagnosing potency issues:
        -- settings.Cors[me] (what GI's Action_Processing reads as the
        -- player's PR+ bonus), Buffs_inform's "Attack perc" /1024 raw
        -- (the actual value GI's get_player_att divides), and the
        -- expected raw for the active Chaos roll given current PR+.
        local p = windower.ffxi.get_player()
        if not p then
            windower.add_to_chat(207, '[OW] jobbonus: no player')
            return
        end
        local me_lower = (p.name or ''):lower()
        local cors_setting = (settings and settings.Cors
                              and settings.Cors[me_lower]) or 'nil'
        local cfg_pr = (ow_user_config and ow_user_config.corsairs
                        and ow_user_config.corsairs.self
                        and ow_user_config.corsairs.self.phantom_roll) or 'nil'
        windower.add_to_chat(207, string.format(
            '[OW] PR+ wizard=%s | settings.Cors[%s]=%s',
            tostring(cfg_pr), me_lower, tostring(cors_setting)))
        if Buffs_inform then
            windower.add_to_chat(207, string.format(
                '[OW] Buffs_inform.Attack perc=%s (÷1024 = %.2f%%)',
                tostring(Buffs_inform['Attack perc']),
                ((tonumber(Buffs_inform['Attack perc']) or 0) / 1024) * 100))
        end
        local stats = ow_compute_stats() or {}
        local count = 0
        if _ow_roll_state and Cor_Rolls then
            local PCT_ROLLS = {
                ['Chaos Roll']     = {affects={'attack','attack2','ranged attack'}, label='Att'},
                ['Beast Roll']     = {affects={}, label='Pet Atk'},
                ["Gallant's Roll"] = {affects={'defense'}, label='Def'},
            }
            for ja_id, roll_value in pairs(_ow_roll_state) do
                local rd = Cor_Rolls[ja_id]
                if rd then
                    local nm = rd.en or '?'
                    -- Show expected raw value for this roll at current PR+:
                    -- raw = roll[N] + roll+1 × PR+
                    local roll_arr  = rd.roll
                    local step      = tonumber(rd['roll+1']) or 0
                    local pr_eff    = tonumber(cors_setting) or tonumber(cfg_pr) or 0
                    local rv_at_n   = roll_arr and roll_arr[roll_value]
                    if type(rv_at_n) == 'number' then
                        local expected_raw = rv_at_n + step * pr_eff
                        windower.add_to_chat(207, string.format(
                            '[OW]   %s rolled %d: expected raw=%d (= %d + %d×%d)',
                            nm, roll_value, expected_raw,
                            rv_at_n, step, pr_eff))
                    end
                    if rd.bonus and rd.bonus['Main job']
                       and rd.bonus['Main job'] ~= 'NON' then
                        local bj  = rd.bonus['Main job']
                        local eff = tonumber(rd.bonus.effect) or 0
                        windower.add_to_chat(207, string.format(
                            '[OW] %s — if %s in party (+%d):',
                            nm, bj, eff))
                        local pct_info = PCT_ROLLS[nm]
                        if pct_info then
                            local pct = eff / 1024 * 100
                            if #pct_info.affects == 0 then
                                windower.add_to_chat(207, string.format(
                                    "    +%.2f%% %s (panel doesn't show pet stats)",
                                    pct, pct_info.label))
                            else
                                for _, sk in ipairs(pct_info.affects) do
                                    local cur = stats[sk] or 0
                                    local add = math.floor(cur * eff / 1024)
                                    windower.add_to_chat(207, string.format(
                                        '    +%.2f%% %s: %s %d → %d (+%d)',
                                        pct, pct_info.label, sk, cur, cur + add, add))
                                end
                            end
                        else
                            local effect = rd.effect or ''
                            local FLAT_MAP = {
                                ["Accuracy"]            = {'accuracy','accuracy2','ranged accuracy'},
                                ["Ranged Accuracy"]     = {'ranged accuracy'},
                                ["Evasion"]             = {'evasion'},
                                ["DEF"]                 = {'defense'},
                                ["Magic Accuracy"]      = {'magic accuracy'},
                                ["Magic Atk. Bonus"]    = {'magic attack bonus'},
                                ["Magic Def. Bonus"]    = {'magic def. bonus'},
                                ["Magic Evasion"]       = {'magic evasion'},
                                ["Store TP"]            = {'store tp'},
                                ["Subtle Blow"]         = {'subtle blow'},
                                ["Critical hit rate"]   = {'critical hit rate'},
                                ["Double Attack"]       = {'double attack'},
                                ["Cure Potency"]        = {'cure potency'},
                                ["Refresh"]             = {'refresh'},
                                ["Regen"]               = {'regen'},
                                ["Regain"]              = {'regain'},
                                ["Save TP"]             = {'save tp'},
                                ["Fast Cast"]           = {'fast cast'},
                                ["Snapshot"]            = {'snapshot'},
                                ["Counter"]             = {'counter'},
                                ["Conserve MP"]         = {'conserve mp'},
                                ["Spell Interruption Rate"] = {'spell interruption rate'},
                                ["Skillchain Damage"]   = {'skillchain damage'},
                                ["Enhancing Magic Duration"] = {'enhancing magic duration'},
                            }
                            local keys = FLAT_MAP[effect]
                            if keys then
                                for _, sk in ipairs(keys) do
                                    local cur = stats[sk] or 0
                                    windower.add_to_chat(207, string.format(
                                        '    %s: %d → %d (+%d)',
                                        sk, cur, cur + eff, eff))
                                end
                            else
                                windower.add_to_chat(207, string.format(
                                    '    +%d %s (no panel mapping)',
                                    eff, effect))
                            end
                        end
                        count = count + 1
                    end
                end
            end
        end
        if count == 0 then
            windower.add_to_chat(207,
                '[OW] jobbonus: no active rolls (or none with a bonus job)')
        end
    elseif command == 'dumpjp' then
        -- Dump every field on p.job_points[mjob:lower()] so we can see
        -- the exact field names windower uses for per-tier Job Point
        -- categories (e.g. ranged_accuracy_bonus, phantom_roll_duration,
        -- etc.). These are SEPARATE from the Gift table; gifts are at
        -- specific JP totals and live in ow_Gifts, while these are
        -- per-tier purchases that go up to 20 each. Used to wire those
        -- bonuses into stats[] without guessing field names.
        local p = windower.ffxi.get_player()
        local mjob = p and p.main_job
        if not (mjob and p.job_points) then
            windower.add_to_chat(207, '[OW] dumpjp: no job_points data')
            return
        end
        local jpkey = mjob:lower()
        local jpdata = p.job_points[jpkey]
        if not jpdata then
            windower.add_to_chat(207, string.format(
                '[OW] dumpjp: no job_points[%s]', jpkey))
            return
        end
        windower.add_to_chat(207, string.format(
            '[OW] dumpjp %s:', mjob))
        local keys = {}
        for k in pairs(jpdata) do keys[#keys+1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            windower.add_to_chat(207, string.format(
                '  %s = %s', tostring(k), tostring(jpdata[k])))
        end
    elseif command == 'dumpgifts' then
        -- Dump the EXACT structure of GearInfo's Gifts data for the
        -- current main job. Shows raw threshold→{bonus_name=val} keys
        -- so we can see whether 'Ranged Accuracy Bonus' (or whatever
        -- string GearInfo uses) is actually in there, what threshold
        -- it's at, and whether the player has reached that threshold.
        -- Maps directly to the apply loop in ow_compute_stats so any
        -- name not appearing in _PW_GIFT_STAT_MAP gets silently dropped.
        local p = windower.ffxi.get_player()
        local mjob = p and p.main_job
        if not (mjob and ow_Gifts and ow_Gifts[mjob]) then
            windower.add_to_chat(207, string.format(
                '[OW] dumpgifts: no Gifts data for %s', tostring(mjob)))
            return
        end
        local jp_spent = 0
        if p.job_points and p.job_points[mjob:lower()] then
            jp_spent = p.job_points[mjob:lower()].jp_spent or 0
        end
        windower.add_to_chat(207, string.format(
            '[OW] dumpgifts %s — jp_spent=%d', mjob, jp_spent))
        local gifts = ow_Gifts[mjob]['Gifts'] or {}
        -- Sort thresholds for readable output.
        local thresholds = {}
        for t, _ in pairs(gifts) do thresholds[#thresholds+1] = t end
        table.sort(thresholds)
        for _, t in ipairs(thresholds) do
            local reached = (jp_spent >= t) and 'YES' or 'no'
            windower.add_to_chat(207, string.format(
                '[OW] @%dJP (reached=%s):', t, reached))
            local bonuses = gifts[t]
            if type(bonuses) == 'table' then
                for bn, bv in pairs(bonuses) do
                    local mapped = _PW_GIFT_STAT_MAP[bn]
                    windower.add_to_chat(207, string.format(
                        '  [%s] = %s  →  %s',
                        tostring(bn), tostring(bv),
                        mapped or '(NOT IN MAP — dropped)'))
                end
            else
                windower.add_to_chat(207, string.format(
                    '  (non-table value: %s)', tostring(bonuses)))
            end
        end
    elseif command == 'blu' then
        -- Diagnostic: dump the currently-equipped BLU set, JP summary,
        -- gift status, trait-point totals per category, the resolved
        -- tier values, and the per-spell stat bonuses.
        local p = windower.ffxi.get_player()
        if not p then
            windower.add_to_chat(207, '[OW] blu: no player data')
            return
        end
        if p.main_job ~= 'BLU' and p.sub_job ~= 'BLU' then
            windower.add_to_chat(207, string.format(
                '[OW] blu: not on BLU (main=%s sub=%s)',
                p.main_job or '?', p.sub_job or '?'))
            return
        end
        local spell_ids = ow_get_blu_set_spells()
        if not spell_ids then
            windower.add_to_chat(207,
                '[OW] blu: get_mjob_data/get_sjob_data returned no '
                .. 'spells. Try restarting Windower or report this.')
            return
        end
        local jp_sum = ow_get_blu_jp_summary()
        windower.add_to_chat(207, string.format(
            '[OW] blu: jp_spent=%d  master_level=%d  gifts=%d (+%d pts)',
            jp_sum.jp_spent, jp_sum.master_level, jp_sum.gifts,
            jp_sum.gifts * 8))
        windower.add_to_chat(207, string.format(
            '[OW] blu: %d equipped spells', #spell_ids))
        -- Per-spell breakdown.
        local missing = {}
        for _, sid in ipairs(spell_ids) do
            local sp = res.spells and res.spells[sid]
            local name = sp and (sp.en or sp.name) or ('spell:'..sid)
            local entry = OW_BLU_SPELLS[name]
                          or OW_BLU_SPELLS_LC[name:lower()]
            if entry then
                local parts = {}
                for k, v in pairs(entry) do
                    if k ~= 'stats' then
                        parts[#parts+1] = string.format('%s=%s', k, tostring(v))
                    end
                end
                if entry.stats then
                    local stat_parts = {}
                    for sk, sv in pairs(entry.stats) do
                        stat_parts[#stat_parts+1] = string.format(
                            '%s+%s', sk, tostring(sv))
                    end
                    if #stat_parts > 0 then
                        parts[#parts+1] = '['..table.concat(stat_parts, ',')..']'
                    end
                end
                windower.add_to_chat(207, string.format(
                    '  %s  %s', name, table.concat(parts, '  ')))
            else
                missing[#missing+1] = name
            end
        end
        if #missing > 0 then
            windower.add_to_chat(207, string.format(
                '[OW] blu: %d spell(s) NOT in OW_BLU_SPELLS table:',
                #missing))
            for _, n in ipairs(missing) do
                windower.add_to_chat(207, '  '..n)
            end
        end
        -- Resolved totals: print trait-point breakdown by category,
        -- then the final stat bonuses.
        local _, blu_stats = ow_resolve_blu_set(spell_ids, jp_sum)
        if _ow_blu_cache and _ow_blu_cache.trait_pts then
            local cats = {}
            for k, _ in pairs(_ow_blu_cache.trait_pts) do
                cats[#cats+1] = k
            end
            table.sort(cats)
            windower.add_to_chat(207, '[OW] blu: trait points '
                .. '(post-gift):')
            for _, c in ipairs(cats) do
                windower.add_to_chat(207, string.format(
                    '  %s = %d', c, _ow_blu_cache.trait_pts[c]))
            end
        end
        windower.add_to_chat(207, '[OW] blu: stat output:')
        local sk = {}
        for k, _ in pairs(blu_stats) do sk[#sk+1] = k end
        table.sort(sk)
        for _, k in ipairs(sk) do
            windower.add_to_chat(207, string.format(
                '  %s = %s', k, tostring(blu_stats[k])))
        end
    elseif command == 'setup' then
        -- //ow setup       - open the config overlay in the pygame UI
        -- //ow setup skip  - mark setup_complete=true without opening the
        --                    overlay (silences the first-run nag)
        --
        -- The overlay is rendered by OmniWatch.py. We send it the
        -- current config state via UDP (CFGWIZ|open|<flat-fields>),
        -- then the user clicks +/- buttons in the modal and either
        -- Save (CFGWIZ|save|<fields> back to us, we write file) or
        -- Cancel (no-op). Click-out also cancels.
        local sub = args[1] and args[1]:lower() or ''
        if sub == 'skip' then
            ow_user_config.setup_complete = true
            local ok, err = ow_save_user_config()
            if ok then
                windower.add_to_chat(207,
                    '[OW Setup] Marked complete (values unchanged). '
                    .. 'Run //ow setup any time to (re)configure.')
            else
                windower.add_to_chat(123,
                    '[OW Setup] Save failed: ' .. tostring(err))
            end
            return
        end
        _ow_cfgwiz_open()
        windower.add_to_chat(207,
            '[OW Setup] Config overlay opened. Click +/- to adjust values, '
            .. 'Save when done. (Click outside the modal to cancel.)')
        windower.add_to_chat(207,
            '[OW Setup] Tip: enter ONLY the values from your typical '
            .. 'cast set. all_songs sums every "All Songs +N" piece '
            .. '(Gjall=4, Mnbw=2, etc.); per-family fields like carol '
            .. 'sum the corresponding "Carol +N" pieces (Mousai Gages '
            .. 'NQ=1, +1=2).')
    elseif command == 'config' then
        -- //ow config                          - list current bard values
        -- //ow config <bard> <family> <n>      - set a family value
        -- //ow config save                     - persist to disk
        --   <bard>   = 'self' or any lowercase ally bard name
        --   <family> = one of all_songs, minuet, march, madrigal, paeon,
        --              ballad, minne, mambo, prelude, carol, etude, scherzo
        --   <n>      = integer +N (gear sum for that family)
        local sub = args[1] and args[1]:lower() or ''
        local bards = ow_user_config.bards
        if sub == '' then
            windower.add_to_chat(207,
                '[OW] user_config bards (edit data/user_config.lua + //lua r omniwatch):')
            local names = {}
            for k, _ in pairs(bards) do names[#names+1] = k end
            table.sort(names, function(a, b)
                if a == 'self' then return true end
                if b == 'self' then return false end
                return a < b
            end)
            for _, name in ipairs(names) do
                local t = bards[name] or {}
                local parts = {}
                for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
                    local v = tonumber(t[fk]) or 0
                    if v ~= 0 then
                        parts[#parts+1] = string.format('%s=%d', fk, v)
                    end
                end
                windower.add_to_chat(207, string.format('  %s: %s',
                    name,
                    #parts > 0 and table.concat(parts, ' ') or '(all zero)'))
            end
        elseif sub == 'save' then
            local ok, err = ow_save_user_config()
            if ok then
                windower.add_to_chat(207,
                    '[OW] saved to data/user_config.lua (your hand-edits to non-bards sections were not preserved).')
            else
                windower.add_to_chat(207, '[OW] save failed: ' .. tostring(err))
            end
        else
            -- //ow config <bard> <family> <n>
            local bard_name = args[1] and args[1]:lower() or nil
            local fam_name  = args[2] and args[2]:lower() or nil
            local value     = tonumber(args[3])
            if not (bard_name and fam_name and value) then
                windower.add_to_chat(207,
                    '[OW] usage: //ow config <bard> <family> <n>')
                windower.add_to_chat(207,
                    '       <bard> = self | <ally name lowercase>')
                windower.add_to_chat(207,
                    '       <family> = ' .. table.concat(PW_BARD_FAMILY_KEYS, ', '))
                return
            end
            local fam_known = false
            for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
                if fk == fam_name then fam_known = true; break end
            end
            if not fam_known then
                windower.add_to_chat(207, string.format(
                    '[OW] unknown family "%s". Valid: %s',
                    fam_name, table.concat(PW_BARD_FAMILY_KEYS, ', ')))
                return
            end
            bards[bard_name] = bards[bard_name] or {}
            bards[bard_name][fam_name] = value
            windower.add_to_chat(207, string.format(
                '[OW] bards.%s.%s = %d  (in memory; //ow config save to write file)',
                bard_name, fam_name, value))
        end
    elseif command == 'testcast' then
        -- Emit a synthetic cast event on your own id to prove the pipe works.
        local me = windower.ffxi.get_player()
        if me and me.id then
            udp_cast:send(string.format('CAST_START|%d|spell|TEST SPELL', me.id))
            windower.add_to_chat(207, '[OW] sent TEST CAST_START on self')
        end
    elseif command == 'position' then
        -- Toggle position-edit mode in the OmniWatch overlay: forces all
        -- panels visible with mock data and shows drag handles, so the user
        -- can position them without needing to be in combat / have a target
        -- / have party members. Optional second arg: 'on' or 'off' to set
        -- explicitly instead of toggle. (Was previously '//ow setup' but
        -- that name now belongs to the config wizard.)
        local mode = (args[1] or 'toggle'):lower()
        if mode ~= 'on' and mode ~= 'off' and mode ~= 'toggle' then
            mode = 'toggle'
        end
        udp_gs:send('SETUP|' .. mode)
        windower.add_to_chat(207, '[OW] panel position mode: ' .. mode
            .. ' (run //ow position again to exit)')
    elseif command == 'lock' then
        -- Toggle panel lock. When locked, panels can't be dragged or
        -- resized; clicks pass through to hyperlinks normally. Useful
        -- so accidental clicks during gameplay don't nudge things.
        -- Setup mode auto-unlocks while it's on.
        local mode = (args[1] or 'toggle'):lower()
        if mode ~= 'on' and mode ~= 'off' and mode ~= 'toggle' then
            mode = 'toggle'
        end
        udp_gs:send('LOCK|' .. mode)
        windower.add_to_chat(207, '[OW] panel lock: ' .. mode)
    elseif command == 'events' then
        -- Diagnostic: list current event-bus subscriber counts. Confirms
        -- that features have wired up to the events they need.
        windower.add_to_chat(207, '[OW] Event bus subscribers:')
        local any = false
        for evt, list in pairs(ow_events._subs) do
            any = true
            windower.add_to_chat(207, string.format(
                '[OW]   %-18s %d subscriber(s)', evt, #list))
        end
        if not any then
            windower.add_to_chat(207, '[OW]   (no subscribers registered)')
        end
    elseif command == 'dumpsources' then
        -- Show all snooped buff sources: songs, haste spells, food, rolls.
        -- Useful for verifying that the action snoops are catching casts
        -- and that pruning is working when buffs drop.
        windower.add_to_chat(207, '[OW] Buff sources by buff_id:')
        local any = false
        for bid, srcs in pairs(_ow_buff_sources) do
            any = true
            local nm = (res.buffs[bid] and (res.buffs[bid].en or res.buffs[bid].name))
                       or ('id:'..bid)
            windower.add_to_chat(207, string.format(
                '[OW]   buff %d (%s):', bid, nm))
            for _, s in ipairs(srcs) do
                windower.add_to_chat(207, string.format(
                    '[OW]     %s "%s" potency=%s',
                    s.src_kind or '?', s.src_name or '?',
                    tostring(s.potency or 0)))
            end
        end
        if not any then
            windower.add_to_chat(207, '[OW]   (none)')
        end
        windower.add_to_chat(207, '[OW] Phantom Roll state:')
        any = false
        for rid, val in pairs(_ow_roll_state) do
            any = true
            local nm = (res.job_abilities[rid] and res.job_abilities[rid].en)
                       or ('roll:'..rid)
            windower.add_to_chat(207, string.format(
                '[OW]   %s = %d', nm, val))
        end
        if not any then
            windower.add_to_chat(207, '[OW]   (none)')
        end
        windower.add_to_chat(207, string.format(
            '[OW] Food: %s (%d)',
            (_ow_food_item_id ~= 0 and res.items[_ow_food_item_id]
             and res.items[_ow_food_item_id].english) or 'none',
            _ow_food_item_id))
        if next(_ow_food_stats) then
            for k, v in pairs(_ow_food_stats) do
                windower.add_to_chat(207, string.format(
                    '[OW]   %s = %+d', k, v))
            end
        end
    elseif command == 'dumpgear' then
        -- Walk each equipped slot and dump the raw data we use to build
        -- stats: item id/name, description text, real augments, ow_enhanced
        -- entry, DW/MA gear table entry. This is the ground truth for
        -- diagnosing "why is stat X not showing up" questions.
        local equipment = windower.ffxi.get_items
                          and windower.ffxi.get_items('equipment')
        if not equipment then
            windower.add_to_chat(207, '[OW] no equipment data')
            return
        end
        local slots = {'main','sub','range','ammo','head','neck',
                       'left_ear','right_ear','body','hands',
                       'left_ring','right_ring','back','waist',
                       'legs','feet'}
        local target_slot = args[1] and args[1]:lower() or nil
        for _, sn in ipairs(slots) do
            if target_slot == nil or target_slot == sn then
                local bag = equipment[sn..'_bag']
                local idx = equipment[sn]
                if idx and idx ~= 0 and bag then
                    local idata = windower.ffxi.get_items(bag, idx)
                    if idata and idata.id and idata.id ~= 0 then
                        local nm = res.items[idata.id]
                                   and (res.items[idata.id].en or res.items[idata.id].enl)
                                   or '?'
                        windower.add_to_chat(207, string.format(
                            '[OW] %-10s id=%d  %s', sn, idata.id, nm))
                        -- Description text (the same text /checkparam-style
                        -- code reads). For ilvl items this comes from res
                        -- but with augments folded in by the game client.
                        local desc = res.items[idata.id]
                                     and res.items[idata.id].description
                        if desc and desc ~= '' then
                            windower.add_to_chat(207, '[OW]   desc: '
                                                      ..tostring(desc):sub(1, 200))
                        end
                        -- Augments via extdata (preferred) + item_data fallback.
                        local augs
                        if extdata and idata.extdata then
                            local ok, ext = pcall(extdata.decode, idata)
                            if ok and ext and ext.augments then
                                augs = ext.augments
                            end
                        end
                        if not augs and idata.augments then
                            augs = idata.augments
                        end
                        if augs and #augs > 0 then
                            for ai, a in ipairs(augs) do
                                if a and a ~= '' and a ~= 'none' then
                                    windower.add_to_chat(207, string.format(
                                        '[OW]   aug %d: "%s"', ai, tostring(a)))
                                end
                            end
                        end
                        if ow_enhanced[idata.id] then
                            windower.add_to_chat(207, '[OW]   enhanced: '
                                                      ..tostring(ow_enhanced[idata.id]))
                        end
                        if DW_Gear and DW_Gear[idata.id] then
                            local dw = DW_Gear[idata.id]['Dual Wield']
                            if dw then
                                windower.add_to_chat(207, string.format(
                                    '[OW]   DW_Gear: dual wield+%d', dw))
                            end
                        end
                        if Martial_Arts_Gear and Martial_Arts_Gear[idata.id] then
                            local ma = Martial_Arts_Gear[idata.id]['Martial Arts']
                            if ma then
                                windower.add_to_chat(207, string.format(
                                    '[OW]   MA_Gear: martial arts-%d', ma))
                            end
                        end
                    end
                end
            end
        end
    elseif command == 'dumpdesc' then
        -- Dump the raw description text of every equipped item, with
        -- escaped newlines visible. Lets us see how items like Nyame
        -- are actually formatted (single line / multi-line / Pet: split)
        -- so we can verify the description parser handles them correctly.
        local equipment = windower.ffxi.get_items
            and windower.ffxi.get_items('equipment')
        if not equipment then
            windower.add_to_chat(207, '[OW] no equipment table')
            return
        end
        local slot_names = {
            'main','sub','range','ammo','head','neck','left_ear','right_ear',
            'body','hands','left_ring','right_ring','back','waist','legs','feet'
        }
        for _, sn in ipairs(slot_names) do
            local bag   = equipment[sn .. '_bag']
            local index = equipment[sn]
            if index and index ~= 0 and bag then
                local idata = windower.ffxi.get_items(bag, index)
                if idata and idata.id and idata.id ~= 0 then
                    local id = idata.id
                    local name = (res.items[id] and res.items[id].english)
                                or ('id:' .. id)
                    local d = res.item_descriptions
                              and res.item_descriptions[id]
                    local txt = (d and d.english) or '(no description)'
                    -- Replace newlines with literal \n so we see them.
                    local visible = txt:gsub('\n', '\\n')
                    windower.add_to_chat(207, string.format(
                        '[PW DESC] %s [%d]: %s', sn, id, visible))
                end
            end
        end
    elseif command == 'dumpcharstats' then
        -- Print stat-related fields from get_player() so we can see what
        -- the API actually returns. player.stats.X is the gear+buffs
        -- delta (NOT a full total), while /checkparam in-game shows the
        -- full total. This command exposes both layers for debugging.
        local p = windower.ffxi.get_player()
        if not p then
            windower.add_to_chat(207, '[OW] no player data')
            return
        end
        windower.add_to_chat(207,
            '[OW] player.stats (delta — gear + merits + JP + buffs):')
        if p.stats then
            for _, k in ipairs({'str','dex','vit','agi','int','mnd','chr'}) do
                windower.add_to_chat(207, string.format(
                    '[OW]   %s = %s', k:upper(), tostring(p.stats[k])))
            end
        end
        windower.add_to_chat(207, '[OW] player.merits:')
        if p.merits then
            for _, k in ipairs({'str','dex','vit','agi','int','mnd','chr'}) do
                windower.add_to_chat(207, string.format(
                    '[OW]   %s = %s', k:upper(), tostring(p.merits[k])))
            end
        else
            windower.add_to_chat(207, '[OW]   (no merits table)')
        end
        windower.add_to_chat(207,
            '[OW] Compare to /checkparam (which shows the TOTAL).')
    elseif command == 'dumpbuffs' then
        -- Print every buff currently active on the player, with the buff's
        -- name from res.buffs and its numeric id. Useful for identifying
        -- unknown buffs (e.g. Memento Cheer effects from Mog Garden).
        local p = windower.ffxi.get_player()
        if p and p.buffs then
            if #p.buffs == 0 then
                windower.add_to_chat(207, '[OW] No active buffs.')
            end
            for i, bid in ipairs(p.buffs) do
                local b = res.buffs and res.buffs[bid]
                local nm = (b and (b.en or b.name)) or '(unknown)'
                windower.add_to_chat(207, string.format(
                    '[OW] buff %2d: id=%d  %s', i, bid, nm))
            end
        else
            windower.add_to_chat(207, '[OW] get_player() has no buff list.')
        end
        -- Resolved speed-buff IDs (from res.buffs lookup at load time).
        -- Useful for verifying the addon is looking for the right buff
        -- numbers if speed cells aren't updating.
        windower.add_to_chat(207, '[OW] Resolved speed-buff IDs:')
        local resolved = {
            {"Bolter's Roll", PW_BUFF_BOLTERS},
            {"Mazurka",       PW_BUFF_MAZURKA},
            {"Quickening",    PW_BUFF_QUICKENING},
            {"Bolt Storm",    PW_BUFF_BOLT_STORM},
            {"Weight",        PW_BUFF_WEIGHT},
            {"Bind",          PW_BUFF_BIND},
            {"Encumbrance",   PW_BUFF_ENCUMBRANCE},
        }
        for _, pair in ipairs(resolved) do
            windower.add_to_chat(207, string.format(
                '[OW]   %-14s -> %s', pair[1], tostring(pair[2])))
        end
        if _ow_bolters_value > 0 then
            windower.add_to_chat(207, string.format(
                '[OW] Cached Bolter\'s roll value = %d', _ow_bolters_value))
        end
    elseif command == 'dumpstats' then
        -- Force a recompute and print summary to chat.
        local ok, err = pcall(function()
            if ow_compute_stats and ow_send_stats then
                local s = ow_compute_stats()
                ow_send_stats(s)
                local keys = {'str','dex','vit','agi','int','mnd','chr'}
                local line = ''
                for _, k in ipairs(keys) do
                    line = line .. k:upper() .. ':' .. tostring(s[k] or '-') .. ' '
                end
                windower.add_to_chat(207, '[OW] ' .. line)
                windower.add_to_chat(207, string.format(
                    '[OW] Gear:%s%% Magic:%s%% JA:%s%% Total:%s%%',
                    tostring(s['haste'] or 0),
                    tostring(s['magic haste'] or 0),
                    tostring(s['ja haste'] or 0),
                    tostring(s['total haste'] or 0)))
                windower.add_to_chat(207, string.format(
                    '[OW] Acc1:%s Att1:%s TP/hit:%s Hits->WS:%s',
                    tostring(s['accuracy'] or '-'),
                    tostring(s['attack'] or '-'),
                    tostring(s['tp per hit'] or '-'),
                    tostring(s['hits to ws'] or '-')))
                -- DW breakdown so we can see what each piece contributes.
                -- Walks current equipment, calling DW_Gear for each
                -- equipped id and totalling. Also reports the trait DW
                -- and any free 'dual wield' parsed from raw description.
                do
                    local equipment = windower.ffxi.get_items
                                       and windower.ffxi.get_items('equipment')
                    if equipment then
                        local slots = {'main','sub','range','ammo','head','neck',
                                       'left_ear','right_ear','body','hands',
                                       'left_ring','right_ring','back','waist',
                                       'legs','feet'}
                        local total_dw_gear = 0
                        for _, sn in ipairs(slots) do
                            local bag = equipment[sn..'_bag']
                            local idx = equipment[sn]
                            if idx and idx ~= 0 and bag then
                                local idata = windower.ffxi.get_items(bag, idx)
                                if idata and idata.id ~= 0 then
                                    local id = idata.id
                                    local nm = (res.items[id] and res.items[id].en)
                                               or ('id:'..id)
                                    local dw_gear = DW_Gear and DW_Gear[id]
                                                    and DW_Gear[id]['Dual Wield'] or 0
                                    if dw_gear > 0 then
                                        windower.add_to_chat(207, string.format(
                                            '[OW]   DW_Gear: %s = +%d',
                                            nm, dw_gear))
                                        total_dw_gear = total_dw_gear + dw_gear
                                    end
                                end
                            end
                        end
                        windower.add_to_chat(207, string.format(
                            '[OW] DW_Gear total: %d (vs final stats DW: %s)',
                            total_dw_gear, tostring(s['dual wield'] or '-')))
                    end
                end
                windower.add_to_chat(207, string.format(
                    '[OW] file: addons/OmniWatch/data/omniwatch_stats.lua'))
            end
        end)
        if not ok then
            windower.add_to_chat(123, '[OW] dumpstats err: ' .. tostring(err))
        end
    elseif command == 'serverstats' then
        -- Experimental: silent server-truth stat fetcher via 0x061
        -- packet injection. Default OFF; user opts in.
        --   //ow serverstats              show status
        --   //ow serverstats on           enable
        --   //ow serverstats off          disable
        --   //ow serverstats debug on/off toggle module debug logging
        if not OW_ServerStats then
            windower.add_to_chat(123,
                '[OW] Server_Stats module not loaded. Place Server_Stats.lua '
                .. 'in the addon root and /reload.')
        else
            local sub = (args[1] or 'status'):lower()
            if sub == 'on' or sub == 'enable' then
                OW_ServerStats.enable()
            elseif sub == 'off' or sub == 'disable' then
                OW_ServerStats.disable()
            elseif sub == 'debug' then
                local v = (args[2] or ''):lower()
                if v == 'on' or v == '1' or v == 'true' then
                    OW_ServerStats.set_debug(true)
                    windower.add_to_chat(207, '[OW] serverstats debug ON')
                else
                    OW_ServerStats.set_debug(false)
                    windower.add_to_chat(207, '[OW] serverstats debug off')
                end
            elseif sub == 'trace' then
                -- Diagnostic: dump the most recent 0x061 and 0x063
                -- packets seen, with their parsed values. Use this
                -- after a roll cast where the panel didn't update
                -- correctly to see what the server actually sent.
                if not OW_ServerStats.trace then
                    windower.add_to_chat(123,
                        '[OW] serverstats: this build has no trace()')
                else
                    local t = OW_ServerStats.trace()
                    windower.add_to_chat(207, '[OW] serverstats trace:')
                    if t.last_0x061_hex then
                        windower.add_to_chat(207, string.format(
                            '[OW]   last 0x061 (age=%.1fs):',
                            t.last_0x061_age))
                        windower.add_to_chat(207,
                            '[OW]   ' .. t.last_0x061_hex)
                    else
                        windower.add_to_chat(207,
                            '[OW]   last 0x061: none seen yet')
                    end
                    if t.last_0x063_hex then
                        windower.add_to_chat(207, string.format(
                            '[OW]   last 0x063 (age=%.1fs):',
                            t.last_0x063_age))
                        windower.add_to_chat(207,
                            '[OW]   ' .. t.last_0x063_hex)
                    else
                        windower.add_to_chat(207,
                            '[OW]   last 0x063: none seen yet')
                    end
                    windower.add_to_chat(207, string.format(
                        '[OW]   cached: pAtt=%s def=%s pAcc=%s',
                        tostring(t.cached_patt or '-'),
                        tostring(t.cached_def  or '-'),
                        tostring(t.cached_pacc or '-')))
                end
            elseif sub == 'request' or sub == 'fetch' then
                -- v2 module is a passive listener — there's no request
                -- to make. The cache updates automatically whenever the
                -- server pushes a 0x061. Show the current cache state
                -- if there is one, otherwise explain.
                local s = OW_ServerStats.status()
                if s.cached_patt then
                    windower.add_to_chat(207, string.format(
                        '[OW] serverstats cached: pAtt=%d def=%d age=%.1fs',
                        s.cached_patt, s.cached_def, s.cache_age_s))
                else
                    windower.add_to_chat(207,
                        '[OW] serverstats: no sample yet — cast a roll '
                        .. 'or change buffs to trigger a server push')
                end
            else
                -- 'status' or anything else: print full state.
                local s = OW_ServerStats.status()
                windower.add_to_chat(207, string.format(
                    '[OW] serverstats: enabled=%s debug=%s',
                    tostring(s.enabled), tostring(s.debug)))
                windower.add_to_chat(207, string.format(
                    '[OW]   0x061: packets=%d captures=%d skipped=%d',
                    s.packets_seen or 0,
                    s.captures_made or 0,
                    s.skipped_partial or 0))
                windower.add_to_chat(207, string.format(
                    '[OW]   0x063: packets=%d captures=%d skipped=%d',
                    s.pacc_packets_seen or 0,
                    s.pacc_captures_made or 0,
                    s.pacc_skipped or 0))
                if s.cached_patt or s.cached_pacc then
                    local pa  = s.cached_patt and tostring(s.cached_patt) or '-'
                    local de  = s.cached_def  and tostring(s.cached_def)  or '-'
                    local pac = s.cached_pacc and tostring(s.cached_pacc) or '-'
                    windower.add_to_chat(207, string.format(
                        '[OW]   cached: pAtt=%s def=%s pAcc=%s',
                        pa, de, pac))
                    windower.add_to_chat(207, string.format(
                        '[OW]   ages: att=%.1fs acc=%.1fs',
                        s.cache_age_s, s.pacc_age_s))
                else
                    windower.add_to_chat(207,
                        '[OW]   cached: (no sample yet)')
                end
            end
        end
    elseif command == 'dumpduration' then
        -- Show what the addon thinks the roll + enhancing duration
        -- multipliers will be at the next cast, given current gear,
        -- merits, and JPs. Helps diagnose timer mismatches.
        local ok2, err2 = pcall(function()
            -- Build the gear inventories for both categories so we can
            -- list which equipped pieces contribute.
            if not _OW_ROLL_DURATION_GEAR_BY_ID then
                _ow_roll_duration_mult()  -- side-effect: builds cache
            end
            if not _OW_ENHANCING_DUR_BY_ID then
                local me = windower.ffxi.get_player()
                _ow_enhancing_duration_mult('Stoneskin',
                                             (me and me.buffs) or {})
            end

            -- Walk equipment for: roll-duration seconds, enhancing %,
            -- mainhand-only weapon filter, Tricorne synergy detection.
            local equipment = windower.ffxi.get_items
                              and windower.ffxi.get_items('equipment')
            local slots = {'main','sub','range','ammo','head','neck',
                           'left_ear','right_ear','body','hands',
                           'left_ring','right_ring','back','waist',
                           'legs','feet'}
            local roll_pieces, enh_pieces = {}, {}
            local roll_seconds, enh_total = 0, 0
            local has_tricorne_synergy = false
            -- Resolve mainhand-only ids by name.
            local mainhand_only_ids = {}
            for _, mh_name in ipairs({"Commodore's Knife", "Lanun Knife",
                                       "Rostam", "Rostam +1"}) do
                local item = res.items and (res.items:with('en', mh_name)
                                            or res.items:with('enl', mh_name))
                if item and item.id then
                    mainhand_only_ids[item.id] = true
                end
            end
            if equipment then
                for _, sn in ipairs(slots) do
                    local bag = equipment[sn..'_bag']
                    local idx = equipment[sn]
                    if idx and idx ~= 0 and bag then
                        local idata = windower.ffxi.get_items(bag, idx)
                        if idata and idata.id then
                            local nm = (res.items and res.items[idata.id]
                                        and res.items[idata.id].en) or '?'
                            local r = _OW_ROLL_DURATION_GEAR_BY_ID[idata.id]
                            if r then
                                if mainhand_only_ids[idata.id] and sn ~= 'main' then
                                    table.insert(roll_pieces,
                                        string.format(
                                          '%s: %s = +%ds (SKIPPED: mainhand-only)',
                                          sn, nm, r))
                                else
                                    roll_seconds = roll_seconds + r
                                    table.insert(roll_pieces,
                                        string.format('%s: %s = +%ds',
                                                       sn, nm, r))
                                end
                            end
                            if sn == 'head' and _OW_TRICORNE_SYNERGY_BY_ID[idata.id] then
                                has_tricorne_synergy = true
                            end
                            local e = _OW_ENHANCING_DUR_BY_ID[idata.id]
                            if e then
                                enh_total = enh_total + e
                                table.insert(enh_pieces,
                                    string.format('%s: %s = +%.0f%%',
                                                   sn, nm, e * 100))
                            end
                        end
                    end
                end
            end

            -- Read merits + JPs with source tracking for visibility.
            local ws, jpdur = 0, 0
            local ws_src, jp_src = 'none', 'none'
            local p = windower.ffxi.get_player()
            if p then
                if p.merits and tonumber(p.merits.winning_streak) then
                    local v = tonumber(p.merits.winning_streak) or 0
                    if v > 0 then ws = v; ws_src = 'live' end
                end
                if p.job_points and p.job_points.cor
                   and tonumber(p.job_points.cor.phantom_roll_duration) then
                    local v = tonumber(p.job_points.cor.phantom_roll_duration) or 0
                    if v > 0 then jpdur = v; jp_src = 'live' end
                end
            end
            if ws == 0 then
                local v = tonumber((PW_COR_MERITS or {}).winning_streak) or 0
                if v > 0 then ws = v; ws_src = 'manual config' end
            end
            if jpdur == 0 then
                local v = tonumber((PW_COR_JP_GIFTS or {}).phantom_roll_duration) or 0
                if v > 0 then jpdur = v; jp_src = 'manual config' end
            end
            ws    = math.min(5,  math.max(0, ws))
            jpdur = math.min(20, math.max(0, jpdur))

            local merit_seconds = ws * 20
            local synergy_seconds = has_tricorne_synergy and (ws * 6) or 0
            local jp_seconds = jpdur * 2
            local roll_base = 300
            local roll_final = roll_base + merit_seconds + synergy_seconds
                             + jp_seconds + roll_seconds
            local roll_mult = roll_final / roll_base

            windower.add_to_chat(207, '[OW] === Phantom Roll duration ===')
            windower.add_to_chat(207, string.format(
                '[OW] base 300s + %ds (Winning Streak %d, %s) + %ds (JP %d, %s) = %ds',
                merit_seconds, ws, ws_src, jp_seconds, jpdur, jp_src,
                roll_base + merit_seconds + jp_seconds))
            if has_tricorne_synergy then
                windower.add_to_chat(207, string.format(
                    '[OW] + %ds Tricorne synergy (Comm.Tri+2/Lanun head + Winning Streak %d)',
                    synergy_seconds, ws))
            end
            if #roll_pieces > 0 then
                for _, ln in ipairs(roll_pieces) do
                    windower.add_to_chat(207, '[OW]   ' .. ln)
                end
                windower.add_to_chat(207, string.format(
                    '[OW]   gear total: +%ds', roll_seconds))
            else
                windower.add_to_chat(207, '[OW]   (no roll-duration gear equipped)')
            end
            windower.add_to_chat(207, string.format(
                '[OW] -> final %ds (%dm %ds, mult %.3fx)',
                roll_final,
                math.floor(roll_final / 60), roll_final % 60,
                roll_mult))

            local me = windower.ffxi.get_player()
            local active = (me and me.buffs) or {}
            local has_comp = false
            for _, bid in ipairs(active) do
                if bid == PW_BUFF_COMPOSURE then has_comp = true; break end
            end
            local is_rdm = me and me.main_job == 'RDM'
            local comp_mult = (is_rdm and has_comp) and 3.0 or 1.0
            local enh_mult = (1.0 + enh_total) * comp_mult
            windower.add_to_chat(207, '[OW] === Enhancing duration (self) ===')
            if #enh_pieces > 0 then
                for _, ln in ipairs(enh_pieces) do
                    windower.add_to_chat(207, '[OW]   ' .. ln)
                end
            else
                windower.add_to_chat(207, '[OW]   (no enhancing-duration gear equipped)')
            end
            windower.add_to_chat(207, string.format(
                '[OW] gear +%.0f%% composure %s (RDM main: %s) -> mult %.3fx',
                enh_total * 100,
                has_comp and 'ACTIVE' or 'inactive',
                is_rdm and 'yes' or 'no',
                enh_mult))
        end)
        if not ok2 then
            windower.add_to_chat(123, '[OW] dumpduration err: ' .. tostring(err2))
        end
    elseif command == 'dps' then
        -- DPS panel control. Subcommands: bare 'dps' = toggle panel,
        -- 'reset' = clear rolling window, 'party' = toggle party tracking,
        -- 'window <sec>' = adjust rolling window length.
        local sub = (args[1] or ''):lower()
        if sub == '' then
            -- Toggle panel visibility on the python side via UDP.
            udp_dps:send('TOGGLE_PANEL')
            windower.add_to_chat(207, '[OW] DPS panel toggle sent.')
        elseif sub == 'reset' then
            _ow_dps_reset()
            udp_dps:send('DPS_EMPTY')
            windower.add_to_chat(207,
                '[OW] DPS rolling window cleared.')
        elseif sub == 'party' then
            PW_DPS_INCLUDE_PARTY = not PW_DPS_INCLUDE_PARTY
            windower.add_to_chat(207, string.format(
                '[OW] DPS party tracking: %s. Existing party events stay '
                .. 'in the buffer until they age out (or //ow dps reset).',
                PW_DPS_INCLUDE_PARTY and 'ON' or 'OFF'))
        elseif sub == 'window' then
            local n = tonumber(args[2])
            if n and n >= 0 and n <= 3600 then
                _ow_dps_window_s = (n == 0) and 36000 or n   -- 0 = effectively unbounded (10h)
                windower.add_to_chat(207, string.format(
                    '[OW] DPS window set to %ds.', _ow_dps_window_s))
                _ow_dps_prune()
            else
                windower.add_to_chat(207,
                    '[OW] usage: //ow dps window <0..3600>')
            end
        elseif sub == 'status' then
            -- Diagnostic dump for figuring out why the DPS panel is empty.
            windower.add_to_chat(207, '[OW] === DPS tracker status ===')
            windower.add_to_chat(207, string.format(
                '[OW] actions seen total: %d',
                _ow_dps_actions_total))
            local cats = {}
            for c, n in pairs(_ow_dps_actions_by_cat) do
                table.insert(cats, string.format('cat=%d:%d', c, n))
            end
            table.sort(cats)
            windower.add_to_chat(207, string.format(
                '[OW] by category:  %s',
                #cats > 0 and table.concat(cats, ' ') or '(none)'))
            windower.add_to_chat(207, string.format(
                '[OW] classified: yes=%d  no=%d',
                _ow_dps_classified_yes, _ow_dps_classified_no))
            windower.add_to_chat(207, string.format(
                '[OW] events recorded: %d  buffer size: %d  window: %ds',
                _ow_dps_recorded_events, #_ow_dps_events,
                _ow_dps_window_s))
            local me = windower.ffxi.get_player()
            windower.add_to_chat(207, string.format(
                '[OW] me.id=%d  me.name=%s  party_track=%s',
                me and me.id or 0,
                me and me.name or '?',
                PW_DPS_INCLUDE_PARTY and 'ON' or 'OFF'))
            windower.add_to_chat(207, string.format(
                '[OW] last action: cat=%d msg=%d actor_id=%d actor=%s',
                _ow_dps_last_cat, _ow_dps_last_msg,
                _ow_dps_last_actor_id, _ow_dps_last_actor_name))
            -- Top 8 unrecognized messages.
            local unrec_pairs = {}
            for m, n in pairs(_ow_dps_unrecognized_msgs) do
                table.insert(unrec_pairs, {m=m, n=n})
            end
            table.sort(unrec_pairs, function(a,b) return a.n > b.n end)
            if #unrec_pairs > 0 then
                local list = {}
                for i = 1, math.min(8, #unrec_pairs) do
                    table.insert(list, string.format(
                        'msg=%d:%d', unrec_pairs[i].m, unrec_pairs[i].n))
                end
                windower.add_to_chat(207, '[OW] unrecognized msgs (top 8): '
                    .. table.concat(list, ' '))
            end
        elseif sub == 'debug' then
            _ow_dps_debug = not _ow_dps_debug
            windower.add_to_chat(207, string.format(
                '[OW] DPS debug logging: %s',
                _ow_dps_debug and 'ON' or 'OFF'))
        else
            windower.add_to_chat(207, string.format(
                '[OW] unknown dps subcommand: %s', sub))
        end
    end
end)

local last_send        = 0
local last_equip_send  = 0
local last_rich_ids    = {}   -- slot_idx -> last sent item_id, for change detection
local last_ammo_count  = -1   -- last sent ammo stack count (-1 = never sent)
local last_rich_full   = 0    -- last time we forced a full rich resend
local last_stats_send  = 0    -- last time we recomputed stats
local last_stats_ids   = {}   -- [pos] = item_id snapshot at last stats calc
local last_target_send = 0
local last_zone_send   = 0
local last_gil_send    = 0
local last_gil_value   = -1  -- -1 = never sent
local party_buffs      = {}    -- keyed by player id
local extracted_ids    = {}    -- id -> true; tracks which icons we've already extracted this session

-- display_pos order from core.lua slotMapping (index 0-15 → slot_id)
local DISPLAY_ORDER = {
    [0]  = {slot_id = 0,  slot_name = 'main'      },
    [1]  = {slot_id = 1,  slot_name = 'sub'       },
    [2]  = {slot_id = 2,  slot_name = 'range'     },
    [3]  = {slot_id = 3,  slot_name = 'ammo'      },
    [4]  = {slot_id = 4,  slot_name = 'head'      },
    [5]  = {slot_id = 9,  slot_name = 'neck'      },
    [6]  = {slot_id = 11, slot_name = 'left_ear'  },
    [7]  = {slot_id = 12, slot_name = 'right_ear' },
    [8]  = {slot_id = 5,  slot_name = 'body'      },
    [9]  = {slot_id = 6,  slot_name = 'hands'     },
    [10] = {slot_id = 13, slot_name = 'left_ring' },
    [11] = {slot_id = 14, slot_name = 'right_ring'},
    [12] = {slot_id = 15, slot_name = 'back'      },
    [13] = {slot_id = 10, slot_name = 'waist'     },
    [14] = {slot_id = 7,  slot_name = 'legs'      },
    [15] = {slot_id = 8,  slot_name = 'feet'      },
}

function buff_name(id)
    local buff = res.buffs[id]
    return buff and buff.en or tostring(id)
end

-- Check if a file exists without opening it for reading an entire image.
local function file_exists(path)
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

-- Extract an icon BMP to the cache folder if we haven't already.
-- Returns true on success (file exists afterwards), false otherwise.
-- Silently no-ops if icon_extractor failed to load at addon start.
local function ensure_icon(id)
    if not icons_available then return false end
    if not id or id == 0 or id == 65535 then return false end
    if extracted_ids[id] then return true end

    local path = ICON_DIR .. tostring(id) .. '.bmp'
    if file_exists(path) then
        extracted_ids[id] = true
        return true
    end

    -- icon_extractor uses coroutines internally (coroutine.yield after write),
    -- so wrap the call so a yield doesn't abort our frame.
    local co = coroutine.create(function()
        icon_extractor.item_by_id(id, path)
    end)
    local ok, err = coroutine.resume(co)
    -- If it yielded, resume once more to let it finish its close().
    if ok and coroutine.status(co) == 'suspended' then
        coroutine.resume(co)
    end
    if not ok then
        -- Mark as attempted so we don't retry every equip tick for the same id.
        extracted_ids[id] = true
        windower.add_to_chat(123, '[OmniWatch] icon extract failed for id '
                                   .. tostring(id) .. ': ' .. tostring(err))
        return false
    end

    extracted_ids[id] = true
    return true
end

-- Status-icon extraction: like ensure_icon but pulls from the buff DAT
-- via icon_extractor.buff_by_id. Filename is the buff/status id; lives
-- in STATUS_ICON_DIR (icons/status/). Tracks attempted ids in a
-- separate table so failures don't poison the equipment cache and
-- vice-versa. Buff icons are 32x32 like equipment, so the python
-- side can use the same scaling pipeline.
local extracted_status_ids = {}
local function ensure_status_icon(id)
    if not icons_available then return false end
    if not id or id == 0 then return false end
    -- Buff DAT covers ids 0x000-0x400 per icon_extractor.lua's buff_dat_map;
    -- anything above that is either a synthetic (negative) id used by the
    -- sim feed or a windower res entry without a real icon. Skip silently.
    if id < 0 or id > 1024 then return false end
    if extracted_status_ids[id] then return true end

    local path = STATUS_ICON_DIR .. tostring(id) .. '.bmp'
    if file_exists(path) then
        extracted_status_ids[id] = true
        return true
    end

    -- buff_by_id uses coroutine.yield internally (same pattern as
    -- item_by_id) so wrap it to avoid frame interruption.
    local co = coroutine.create(function()
        icon_extractor.buff_by_id(id, path)
    end)
    local ok, err = coroutine.resume(co)
    if ok and coroutine.status(co) == 'suspended' then
        coroutine.resume(co)
    end
    if not ok then
        extracted_status_ids[id] = true
        windower.add_to_chat(123, '[OmniWatch] status icon extract failed '
                                   .. 'for id ' .. tostring(id) .. ': '
                                   .. tostring(err))
        return false
    end

    extracted_status_ids[id] = true
    return true
end

-- ── Buff packet handler ──────────────────────────────────────────────────────
ow_safe_register('incoming chunk', function(id, original)
    if id == 0x076 then
        for k = 0, 4 do
            local playerId = original:unpack('I', k*48+5)
            if playerId ~= 0 then
                local buffs = {}
                for i = 1, 32 do
                    local buff = original:byte(k*48+5+16+i-1) + 256*(
                        math.floor(
                            original:byte(k*48+5+8 + math.floor((i-1)/4)) / 4^((i-1)%4)
                        ) % 4
                    )
                    if buff ~= 255 then
                        table.insert(buffs, buff)
                    end
                end
                party_buffs[playerId] = buffs
            end
        end
    end
    -- ── Server_Stats 0x061 dispatch ────────────────────────────────────
    -- Route incoming 0x061 packets to the Server_Stats module if loaded.
    -- The module decides itself whether to act (subtype check, enabled
    -- flag, etc.). Call is wrapped in pcall so any module-internal
    -- error doesn't kill this incoming chunk handler.
    -- ── Server_Stats dispatch ──────────────────────────────────────────
    -- Route incoming 0x061 (pAtt+def) and 0x063 (pAcc) packets to the
    -- Server_Stats module if loaded. The module decides itself whether
    -- to act (subtype/size checks, enabled flag, sanity floor, etc.).
    -- Call is wrapped in pcall so any module-internal error doesn't
    -- kill this incoming chunk handler.
    if (id == 0x061 or id == 0x063) and OW_ServerStats then
        pcall(function() OW_ServerStats.on_incoming_chunk(id, original) end)
    end
end)

-- ── Mob debuff/buff tracking (based on Debuffed.lua by Xathe) ────────────────
-- Watches action packets (0x028) for debuffs landing on mobs, and action
-- message packets (0x029) for wear-offs. Sends events to Python on 5004.

-- Message IDs that mean "spell landed and applied its effect":
local MSG_DAMAGE_LAND   = { [2]   = true, [252] = true }
local MSG_ENFEEBLE_LAND = { [236] = true, [237] = true, [268] = true, [271] = true }

-- Message IDs that mean "mob died":
local MSG_DEATH = { [6] = true, [20] = true, [113] = true,
                    [406] = true, [605] = true, [646] = true }

-- Message IDs that mean "debuff wore off":
local MSG_WEAR_OFF = { [64] = true, [204] = true, [206] = true,
                       [350] = true, [531] = true }

-- Action categories: 4 = magic cast, 6 = job ability (shot uses this)
-- Action packet categories (from Windower community packet docs).
-- These are the actor's action type. Numbers can vary slightly by source; the
-- well-attested ones we need are listed below. Unknown categories fall through.
local CAT_SPELL_FINISH    = 4
local CAT_SPELL_BEGIN     = 8
local CAT_MOB_TP_BEGIN    = 11   -- monster beginning a TP move
local CAT_MOB_TP_FINISH   = 13   -- monster using the TP move
local CAT_INTERRUPTED     = 7    -- finish-like but the action didn't happen
-- Message IDs that indicate the spell was interrupted / failed mid-cast:
local MSG_INTERRUPTED = { [78] = true, [283] = true, [322] = true }
-- The buff id all three Marches share. Verified via HasteInfo statics.lua.
-- Marches do NOT use buff_id 33 (Haste) — they have their own slot 214.
local PW_MARCH_BUFF_ID = 214

-- Bard ability buffs that boost song potency at cast time:
-- Soul Voice (BRD 2H): doubles potency of next set of songs cast.
-- Marcato (BRD JA): increases potency of the NEXT song by 50% (one-shot).
-- Hardcoded from Windower/Resources/resources_data/buffs.lua:
--   id 52  = Soul Voice
--   id 231 = Marcato
-- MUST be declared at top of file (before action handler at ~line 1400)
-- because Lua locals are only visible from their declaration line forward.
local PW_BUFF_SOUL_VOICE = 52
local PW_BUFF_MARCATO    = 231
-- Crooked Cards (COR JA): multiplies next roll's value by 1.2.
-- Applied AFTER PR+ gear and Job Bonus. Does NOT affect double-up.
-- The buff sits on the COR until consumed by the next Phantom Roll cast.
-- Hardcoded id from Windower/Resources buffs.lua: id 601
local PW_BUFF_CROOKED_CARDS = 601

-- ── March song haste (BRD) ─────────────────────────────────────────────
-- Marches: per-1024 potency, indexed by gear March+ level. Sourced from
-- BG-wiki's published per-N tables, which are the authoritative numbers
-- (including game-side rounding quirks). HasteInfo's floor(base*(1+0.1*sp))
-- formula gets close but disagrees with BG-wiki on +N>=4 cases by 1-2/1024.
-- We use BG-wiki's numbers directly. Buff_id is 214 ("March") regardless
-- of which March family member was sung — verified via HasteInfo statics.
-- Defined HERE (top of file) instead of further down so action handler
-- (Song potency tables, Honor March stat layout, and the per-song
-- merit/JP/family metadata all live in gearinfo/res/Bard_Songs.lua
-- (loaded by gearinfo/_loader.lua into the global Bard_Songs); the
-- legacy locals PW_SONG_HASTE_BY_NAME, PW_HONOR_MARCH_STATS_BY_NAME,
-- and PW_SONG_STATS_BY_NAME are populated from that global by the
-- BardSongs adapter — see the data-load block above. The
-- _ow_brd_song_levels helper below reads live merit/JP from windower's
-- player data; the merit_key/jp_key for each song come from the
-- inline metadata fields in Bard_Songs entries.)

-- Read live merit/JP values for a song-class from windower's player
-- data. Returns (merit_levels, jp_levels). Falls back to 0 if the
-- player data isn't loaded yet or the keys aren't present.
local function _ow_brd_song_levels(merit_key, jp_key)
    local merit_lv, jp_lv = 0, 0
    local p = windower.ffxi.get_player()
    if not p then return merit_lv, jp_lv end
    if merit_key and p.merits then
        merit_lv = p.merits[merit_key] or 0
    end
    if jp_key and p.job_points and p.job_points.brd then
        jp_lv = p.job_points.brd[jp_key] or 0
    end
    return merit_lv, jp_lv
end

-- Like ow_song_plus_for_family but returns per-family AND all-songs
-- counts SEPARATELY (not summed). GearInfo's settings.Bards schema
-- requires them split: song_bonus.all_songs vs song_bonus[<family>].
-- Returns a table {
--     all      = N,                            -- "All Songs +N" sum
--     minuet   = N,                            -- "Minuet +N" sum
--     madrigal = N, minne = N, paeon = N,
--     ballad   = N, prelude = N, mambo = N,
--     march    = N, etude = N, carol = N,
--     mazurka  = N, ...                        -- one per family
-- }
-- Reads from windower.ffxi.get_items('equipment') and consults the
-- PW_SONG_GEAR_BY_NAME rules (loaded from gearinfo/res/BardGear.lua).
local function _ow_brd_per_family_song_plus()
    local result = {
        all=0, minuet=0, madrigal=0, minne=0, paeon=0,
        ballad=0, prelude=0, mambo=0, march=0,
        etude=0, carol=0, mazurka=0,
    }
    -- Build the lazy id index once, mirroring ow_song_plus_for_family.
    if not _PW_SONG_GEAR_BY_ID then
        _PW_SONG_GEAR_BY_ID = {}
        if res.items and PW_SONG_GEAR_BY_NAME then
            for id, item in pairs(res.items) do
                if type(item) == 'table' then
                    local nm  = item.en
                    local nml = item.enl
                    local rule = (nm  and PW_SONG_GEAR_BY_NAME[nm])
                              or (nml and PW_SONG_GEAR_BY_NAME[nml])
                    if rule then
                        _PW_SONG_GEAR_BY_ID[id] = rule
                    end
                end
            end
        end
    end
    local equipment = windower.ffxi.get_items
                      and windower.ffxi.get_items('equipment')
    if not equipment then return result end
    local slots = {'main','sub','range','ammo','head','neck',
                   'left_ear','right_ear','body','hands',
                   'left_ring','right_ring','back','waist',
                   'legs','feet'}
    for _, sn in ipairs(slots) do
        local bag = equipment[sn..'_bag']
        local idx = equipment[sn]
        if idx and idx ~= 0 and bag then
            local idata = windower.ffxi.get_items(bag, idx)
            if idata and idata.id then
                local rule = _PW_SONG_GEAR_BY_ID[idata.id]
                if rule then
                    -- Each rule may have an 'all' field (All Songs+),
                    -- and/or per-family fields ('minuet'=1, etc.).
                    -- Sum each into the matching result key.
                    --
                    -- Some legacy rules use plural family names
                    -- ('marches' instead of 'march'). Map them through
                    -- the alias table so settings.Bards.song_bonus.march
                    -- (GearInfo's expected key) gets the value.
                    local alias = {marches = 'march'}
                    for k, v in pairs(rule) do
                        local key = alias[k] or k
                        if result[key] ~= nil then
                            result[key] = result[key] + (tonumber(v) or 0)
                        end
                    end
                end
            end
        end
    end
    return result
end

-- ── settings.Bards auto-populate for self ─────────────────────────────
-- GearInfo's check_buffs (gearinfo/Buff_Processing.lua line 248+) walks
-- _ExtraData.player.buff_details, matches each buff against Bard_Songs,
-- and computes the song's stat contribution INTO the buff entry — but
-- ONLY if settings.Bards[caster_lowercase] exists. Without it, the
-- song's stat falls into a no-Caster fallback (line 264) that uses the
-- single global manual_bard_duration_bonus and produces wrong/zero
-- numbers. With GearInfo vendored into OmniWatch, no //gi addbard
-- command flow exists — settings.Bards is empty by default — so all
-- BRD song stat contributions silently drop on the floor.
--
-- This helper rebuilds settings.Bards[<my_name>] from live windower
-- data on every call (gear/merit/JP/equipment changes pick up
-- immediately), so GearInfo's check_buffs sees correct per-song values
-- and writes them into Buffs_inform via calculate_total_haste(), which
-- then flows into get_player_att / get_player_acc as the panel's
-- canonical totals.
--
-- Schema mirrors gearinfo/Statics.lua's default_bard_settings:
--   gjallarhorn = bool,                 -- Gjallarhorn equipped?
--   emperean_armor_bonus = N,           -- Aoidos+/Fili+ resists bump
--   song_bonus = {
--       all_songs = N,                  -- gear "All Songs +N"
--       <family>  = N,                  -- gear "<Family> +N"
--   },
--   merits = { <family> = N },          -- live windower.ffxi.get_player().merits
--   jp     = { <family> = N },          -- live .job_points.brd
local function _ow_refresh_bard_settings()
    if not settings then return end
    settings.Bards = settings.Bards or {}
    local p = windower.ffxi.get_player()
    if not (p and p.name) then return end
    local me = p.name:lower()

    -- Read config. ow_user_config.bards.self is the canonical source for
    -- this player's song+ totals — set via the //ow setup wizard or
    -- hand-edited in %APPDATA%\OmniWatch\user_config.lua. Live gear
    -- scanning was previously kept as a fallback, but now we trust
    -- config absolutely. If config is empty, song_bonus stays 0 and
    -- bard math falls into Buff_Processing's "no settings.Bards entry"
    -- branch (Bard Bonus[0]) — same as if the player just hadn't run
    -- the wizard yet. They'll see lower-than-expected potency and
    -- naturally run //ow setup.
    local cfg_self = (ow_user_config and ow_user_config.bards
                      and ow_user_config.bards.self) or {}

    -- Per-family value resolver. Reads config; no gear walk anywhere.
    local function fam_value(name)
        return tonumber(cfg_self[name]) or 0
    end
    local all_songs_value = fam_value('all_songs')

    -- Build family_snap as legacy compatibility for any code path that
    -- still reads it (Honor March's snap_gjall, etc.). Empty when using
    -- config — those paths handle a missing snap gracefully.
    local family_snap = {}

    -- Live windower merit/JP reads. Each merit/JP key in BG-wiki form is
    -- "<family>_effect"; the value is the count of merit points or JP
    -- gift levels invested. Default to 0 if the player isn't a BRD or
    -- hasn't invested.
    local function read_brd(family_key)
        local merit_lv = 0
        local jp_lv    = 0
        if p.merits then merit_lv = p.merits[family_key] or 0 end
        if p.job_points and p.job_points.brd then
            jp_lv = p.job_points.brd[family_key] or 0
        end
        return merit_lv, jp_lv
    end
    local minuet_m, minuet_j     = read_brd('minuet_effect')
    local madrigal_m, madrigal_j = read_brd('madrigal_effect')
    local minne_m, minne_j       = read_brd('minne_effect')
    local paeon_m, paeon_j       = read_brd('paeon_effect')
    local ballad_m, ballad_j     = read_brd('ballad_effect')
    local _, prelude_j           = read_brd('prelude_effect')
    local _, march_j             = read_brd('march_effect')

    -- Detect Gjallarhorn equipped. GearInfo subtracts its +4 from
    -- Honor March's potency (since Honor March requires Marsyas, you
    -- can't have both — but our gear snapshot may include Gjall after
    -- the cast completes, so we hint GearInfo to back it out).
    -- Prefer cast-time snapshot from active song records over live
    -- gear: Honor March cast → Marsyas equipped → snap_gjall=false.
    -- Live gear after the cast (back to idle/Gjall) would mis-flag.
    local gjall_equipped = nil
    if _ow_buff_sources then
        for _, srcs in pairs(_ow_buff_sources) do
            if type(srcs) == 'table' then
                for _, s in ipairs(srcs) do
                    if s.src_kind == 'song_v2'
                       and s.actor_was_self
                       and s.snap_gjall ~= nil then
                        -- Any false snap wins (Honor March requires
                        -- Marsyas, so its snap is always false; we
                        -- want that to dominate).
                        if s.snap_gjall == false then
                            gjall_equipped = false
                            break
                        elseif gjall_equipped == nil then
                            gjall_equipped = true
                        end
                    end
                end
                if gjall_equipped == false then break end
            end
        end
    end
    if gjall_equipped == nil then
        -- No song snapshots — fall back to live gear.
        gjall_equipped = false
        local equipment = windower.ffxi.get_items
                          and windower.ffxi.get_items('equipment')
        if equipment then
            local bag = equipment.range_bag
            local idx = equipment.range
            if idx and idx ~= 0 and bag then
                local idata = windower.ffxi.get_items(bag, idx)
                if idata and idata.id and res.items
                   and res.items[idata.id]
                   and (res.items[idata.id].en == 'Gjallarhorn'
                     or res.items[idata.id].enl == 'Gjallarhorn') then
                    gjall_equipped = true
                end
            end
        end
    end

    settings.Bards[me] = {
        gjallarhorn          = gjall_equipped,
        emperean_armor_bonus = 0,   -- TODO: derive from Aoidos+/Fili+ later
        song_bonus = {
            all_songs = all_songs_value,
            paeon     = fam_value('paeon'),
            ballad    = fam_value('ballad'),
            minne     = fam_value('minne'),
            minuet    = fam_value('minuet'),
            madrigal  = fam_value('madrigal'),
            prelude   = fam_value('prelude'),
            mambo     = fam_value('mambo'),
            march     = fam_value('march'),
            etude     = fam_value('etude'),
            carol     = fam_value('carol'),
            mazurka   = fam_value('mazurka'),
        },
        merits = {
            -- GearInfo's default schema only covers minne/minuet/madrigal,
            -- but we populate the full set since paeon_effect/ballad_effect
            -- are real merits on BG-wiki. Extra keys are harmless if
            -- GearInfo's code doesn't read them.
            minne    = minne_m,
            minuet   = minuet_m,
            madrigal = madrigal_m,
            paeon    = paeon_m,
            ballad   = ballad_m,
        },
        jp = {
            -- Same: GearInfo default schema only covers minne/minuet,
            -- but BG-wiki has gifts for all the families below.
            minne    = minne_j,
            minuet   = minuet_j,
            madrigal = madrigal_j,
            paeon    = paeon_j,
            ballad   = ballad_j,
            prelude  = prelude_j,
            march    = march_j,
        },
    }
    -- One-shot diagnostic: dump the per-family song_bonus values that
    -- check_buffs will see. Gated on _ow_buff_debug. Useful when songs
    -- aren't picking up the configured bonuses.
    if _ow_buff_debug then
        local sb = settings.Bards[me].song_bonus
        windower.add_to_chat(207, string.format(
            '[OW] song_bonus[%s]: all=%d carol=%d paeon=%d ballad=%d minne=%d minuet=%d madrigal=%d prelude=%d march=%d etude=%d',
            tostring(me), sb.all_songs or 0, sb.carol or 0,
            sb.paeon or 0, sb.ballad or 0, sb.minne or 0,
            sb.minuet or 0, sb.madrigal or 0, sb.prelude or 0,
            sb.march or 0, sb.etude or 0))
        windower.add_to_chat(207,
            '[OW] (config bards.self → settings.Bards; no gear scan)')
    end

    -- Populate settings.Bards for ALLY bards from config. Each entry
    -- in ow_user_config.bards (other than 'self') is keyed by lowercase
    -- character name and contains the same shape. We only write entries
    -- that have at least one non-zero family, because the empty
    -- template entries shouldn't override anything in settings.Bards
    -- that another addon may have set.
    --
    -- Allies who don't have a config entry: settings.Bards[<name>]
    -- stays unset, Buff_Processing falls into its no-Bards branch with
    -- All_songs=0 (their songs apply only at base Bard Bonus[0]). This
    -- is the documented multi-bard limitation.
    if ow_user_config and ow_user_config.bards then
        for ally_name, ally_cfg in pairs(ow_user_config.bards) do
            if ally_name ~= 'self' and type(ally_cfg) == 'table' then
                local nz = false
                for _, fk in ipairs(PW_BARD_FAMILY_KEYS) do
                    if (tonumber(ally_cfg[fk]) or 0) > 0 then
                        nz = true
                        break
                    end
                end
                if nz then
                    settings.Bards[ally_name] = {
                        gjallarhorn          = false,
                        emperean_armor_bonus = 0,
                        song_bonus = {
                            all_songs = tonumber(ally_cfg.all_songs) or 0,
                            paeon     = tonumber(ally_cfg.paeon)     or 0,
                            ballad    = tonumber(ally_cfg.ballad)    or 0,
                            minne     = tonumber(ally_cfg.minne)     or 0,
                            minuet    = tonumber(ally_cfg.minuet)    or 0,
                            madrigal  = tonumber(ally_cfg.madrigal)  or 0,
                            prelude   = tonumber(ally_cfg.prelude)   or 0,
                            mambo     = tonumber(ally_cfg.mambo)     or 0,
                            march     = tonumber(ally_cfg.march)     or 0,
                            etude     = tonumber(ally_cfg.etude)     or 0,
                            carol     = tonumber(ally_cfg.carol)     or 0,
                            -- Mazurka isn't in the config schema (no
                            -- known per-family Mazurka+ gear), but
                            -- Buff_Processing reads it; default to 0.
                            mazurka   = 0,
                        },
                        -- We don't carry merits/JP for ally bards. If
                        -- they have a Job Bonus enabled, that's already
                        -- baked into THEIR cast and not something we
                        -- can read from across the party. Leave empty
                        -- — Buff_Processing tolerates missing merit/jp
                        -- subtables (it falls back when the lookup is
                        -- nil).
                        merits = {},
                        jp     = {},
                    }
                end
            end
        end
    end
end

-- ── settings.Cors auto-populate for self ───────────────────────────────
--
-- Mirrors _ow_refresh_bard_settings for COR. GearInfo's
-- Action_Processing reads settings.Cors[caster_lowercase] to get the
-- Phantom Roll+ value used when computing roll potency:
--
--     if table.containskey(settings.Cors, member_table[index].name:lower()) then
--         Roll_bonus = settings.Cors[member_table[index].name:lower()]
--     else
--         Roll_bonus = manual_COR_bonus
--     end
--
-- Without an entry, Roll_bonus = manual_COR_bonus (defaults to 0 unless
-- the user hand-edits GearInfo's settings file). The wizard saves the
-- player's Phantom Roll+ to ow_user_config.corsairs.self.phantom_roll;
-- this helper bridges that into settings.Cors[me] so GearInfo's roll
-- math uses our authoritative wizard value.
--
-- Called at addon load and after every wizard save.
local function _ow_refresh_cor_settings()
    if not settings then return end
    settings.Cors = settings.Cors or {}
    local p = windower.ffxi.get_player()
    if not (p and p.name) then return end
    local me = p.name:lower()

    local cfg = ow_user_config and ow_user_config.corsairs
                and ow_user_config.corsairs.self
                and tonumber(ow_user_config.corsairs.self.phantom_roll)

    if cfg and cfg > 0 then
        settings.Cors[me] = cfg
        if _ow_buff_debug then
            windower.add_to_chat(207, string.format(
                '[OW] settings.Cors[%s] = %d (from wizard config)', me, cfg))
        end
    else
        -- No wizard config — leave settings.Cors alone so GearInfo's
        -- manual_COR_bonus fallback applies. Avoids stomping any value
        -- the user may have hand-set in GearInfo's settings.
        if _ow_buff_debug then
            windower.add_to_chat(207, string.format(
                '[OW] settings.Cors[%s] not set (no wizard phantom_roll)', me))
        end
    end
end

-- ── settings.Geo auto-populate for self ────────────────────────────────
--
-- Mirrors the bard/cor refreshers for Geomancers. Bridges the wizard
-- values stored under ow_user_config.geomancers.self.* into
-- settings.Geo[me]. Compute path (when wired) reads settings.Geo[me]
-- to scale Indi/Geo spell potency using Geo_Spells.lua's
-- ['Geomancy x'] per-bonus increment plus the base ['900 skill'].
--
-- Forward-declared above as `local _ow_refresh_geo_settings` to dodge
-- the same scoping pitfall the unity rank refresher hit (closures
-- registered earlier need to capture an upvalue, not a future global).
-- Plain assignment to the forward-declared local — NOT `local function`.
--
-- Called from the recompute hook every cycle and from the wizard save
-- handler immediately on save.
_ow_refresh_geo_settings = function()
    if not settings then return end
    settings.Geo = settings.Geo or {}
    local p = windower.ffxi.get_player()
    if not (p and p.name) then return end
    local me = p.name:lower()

    local cfg = ow_user_config and ow_user_config.geomancers
                and ow_user_config.geomancers.self
    if type(cfg) ~= 'table' then return end

    -- Build the per-me settings table mirroring the wizard fields.
    -- Stored as a flat dict so consumers can do
    -- `settings.Geo[me].indi`, `.geo`, `.bolster`, `.handbell`, `.all`.
    settings.Geo[me] = {
        indi     = tonumber(cfg.indi)     or 0,
        geo      = tonumber(cfg.geo)      or 0,
        bolster  = tonumber(cfg.bolster)  or 0,
        handbell = tonumber(cfg.handbell) or 0,
        all      = tonumber(cfg.all)      or 0,
    }
    if _ow_buff_debug then
        local g = settings.Geo[me]
        windower.add_to_chat(207, string.format(
            '[OW] settings.Geo[%s] = indi=%d geo=%d bolster=%d handbell=%d all=%d',
            me, g.indi, g.geo, g.bolster, g.handbell, g.all))
    end
end

-- Mirrors the bard/cor refreshers for Unity Rank. GearInfo's
-- Gear_Processing.lua reads `settings.player.rank` to scale Unity
-- Concord-augmented gear (formula at Gear_Processing.lua:57). The
-- _loader.lua sets settings.player.rank=1 at startup, but the wizard
-- is the user-facing knob that overrides it.
--
-- ow_user_config.player.unity_rank is what the cfgwiz writes;
-- this helper bridges that into settings.player.rank so the next
-- compute walks the player's actual Unity rank rather than the
-- default highest-tier (1) value.
--
-- Called at addon load and after every wizard save.
--
-- Note: the local was forward-declared at the top of the file (search
-- for "local _ow_refresh_unity_rank"). This is an assignment, not a
-- new declaration, so call sites BEFORE this point in the file (the
-- CFGWIZ save handler closure registered around line ~2825) can also
-- see the function once it's been assigned.
_ow_refresh_unity_rank = function()
    if not settings then return end
    settings.player = settings.player or {}
    local cfg = ow_user_config and ow_user_config.player
                and tonumber(ow_user_config.player.unity_rank)
    -- Resolve the target rank: clamped wizard value, or the default (1)
    -- if the user_config has no player section / no unity_rank yet.
    local target = nil
    if cfg and cfg >= 1 and cfg <= 11 then
        target = cfg
    end

    -- Only act when the rank actually changes. The recompute hook calls
    -- this on every compute pass, but a cache invalidation is expensive
    -- and unnecessary if the value hasn't moved. We track the last
    -- applied rank in _ow_last_unity_rank (file-scope global, defaults
    -- to nil so the first call always applies).
    local prev = _ow_last_unity_rank
    if target and target ~= prev then
        settings.player.rank = target
        _ow_last_unity_rank  = target
        -- Invalidate the GearInfo gear cache. The cache stamps the
        -- rank-derived Unity bonus into each item's edited_item entry
        -- at parse time, so changing settings.player.rank doesn't
        -- propagate to already-cached items unless we re-parse them.
        --
        -- Wiping full_gear_table_from_file forces check_equipped to
        -- re-run parse_new_single_item for each equipped slot on the
        -- next refresh_all, which recomputes the rank value with the
        -- new settings.player.rank in scope. Calling prime_inventory
        -- additionally re-walks the bags so every item in the cache
        -- is up to date for sim/swap previews.
        --
        -- This block only fires when the rank actually changes, so the
        -- ~50-300ms parse_inventory cost is bounded to once per wizard
        -- save (or once per /reload if the saved value differs from
        -- the loader default).
        if _G.full_gear_table_from_file ~= nil then
            _G.full_gear_table_from_file = T{}
        end
        if _gi and _gi.prime_inventory then
            pcall(_gi.prime_inventory)
        end
        if _ow_buff_debug then
            windower.add_to_chat(207, string.format(
                '[OW] settings.player.rank = %d (cache invalidated)', target))
        end
    elseif target then
        -- Same value, just keep settings.player.rank in sync (cheap).
        settings.player.rank = target
        if _ow_buff_debug then
            windower.add_to_chat(207, string.format(
                '[OW] settings.player.rank = %d (unchanged)', target))
        end
    else
        -- No wizard value — leave whatever _loader.lua set (default 1).
        if _ow_buff_debug then
            windower.add_to_chat(207,
                '[OW] settings.player.rank not overridden (no wizard unity_rank)')
        end
    end

    -- One-shot diagnostic for debugging "I set rank=N but stats are off
    -- by X" issues. Gated behind _ow_buff_debug; toggle with
    -- `//ow buffdebug` if you need to see what got resolved.
    if _ow_buff_debug and not _ow_unity_rank_announced then
        _ow_unity_rank_announced = true
        local has_section = (ow_user_config and ow_user_config.player) and 'yes' or 'NO'
        local raw         = (ow_user_config and ow_user_config.player
                             and tostring(ow_user_config.player.unity_rank)) or 'nil'
        windower.add_to_chat(207, string.format(
            '[OW] unity rank: settings.player.rank=%s, ow_user_config.player section=%s, raw value=%s',
            tostring(settings.player.rank), has_section, raw))
    end
end
local PW_SONG_HASTE_TABLE = nil  -- spell_id → {potency_base, song_cap}
local PW_SONG_HASTE       = nil  -- spell_id → true (membership test)
local PW_HONOR_MARCH_ID   = nil  -- resolved spell_id for Honor March
local PW_HONOR_MARCH_STATS = nil -- spell_id → stat bonuses table
local function _ow_build_song_tables()
    if PW_SONG_HASTE_TABLE then return end
    PW_SONG_HASTE_TABLE = {}
    PW_SONG_HASTE       = {}
    PW_HONOR_MARCH_STATS = {}
    for name, entry in pairs(PW_SONG_HASTE_BY_NAME) do
        local spell = res.spells and (res.spells:with('enl', name)
                                      or res.spells:with('en', name))
        if spell and spell.id then
            PW_SONG_HASTE_TABLE[spell.id] = entry
            PW_SONG_HASTE[spell.id] = true
            if name == 'Honor March' then
                PW_HONOR_MARCH_ID = spell.id
                PW_HONOR_MARCH_STATS[spell.id] = PW_HONOR_MARCH_STATS_BY_NAME[name]
            end
        else
            windower.add_to_chat(207, string.format(
                '[OW] song table: %s → NOT FOUND in res.spells', name))
        end
    end
end

-- ── DPS tracker ────────────────────────────────────────────────────────
-- Rolling 5-minute combat metrics. Built from the same action-packet hook
-- that drives mob debuff tracking and roll detection. Sends a per-tick
-- summary to python via UDP 5010 at 2 Hz.
--
-- Architecture:
--   _ow_dps_events     ring buffer of {ts, src, kind, ...} tables
--   _ow_dps_window_s   rolling window length (default 300s = 5min)
--   _ow_dps_emit_acc   accumulator throttled to 2 Hz emit rate
--   PW_DPS_INCLUDE_PARTY toggle for tracking party member damage
--
-- Event kinds (string tags so the emit/aggregator logic is readable):
--   'melee_hit'     — white damage swing landed (incl. crits)
--   'melee_miss'    — white damage swing missed
--   'melee_evaded'  — mob attack swing on me/party member, evaded
--   'ranged_hit', 'ranged_miss'
--   'ws'            — weaponskill damage
--   'magic_land'    — spell damage applied (including magic burst)
--   'magic_resist'  — spell resisted / no effect
--   'mob_swing_at'  — incoming mob attack against tracked source (denominator for evasion)
--
-- Each event has these fields when applicable:
--   {ts, src, src_name, kind, target_id, target_name, value, is_crit,
--    is_burst, ws_name, spell_id}
-- src is "me", "pet", or "<party_member_name>". Used for filtering in emit.
_ow_dps_events       = _ow_dps_events       or {}    -- list of event tables
_ow_dps_window_s     = _ow_dps_window_s     or 300   -- 5 minutes
_ow_dps_emit_acc     = _ow_dps_emit_acc     or 0     -- accumulator for 2 Hz emit throttling
_ow_dps_last_event_ts= _ow_dps_last_event_ts or 0    -- for "active combat" detection (UI hint)

PW_DPS_INCLUDE_PARTY = (PW_DPS_INCLUDE_PARTY == nil) and true or PW_DPS_INCLUDE_PARTY

-- Debug counters (globals so the slash-command parser registered above can
-- read them without forward-reference issues).
_ow_dps_debug = _ow_dps_debug or false
_ow_dps_actions_total    = _ow_dps_actions_total    or 0    -- every action seen
_ow_dps_actions_by_cat   = _ow_dps_actions_by_cat   or {}   -- cat → count
_ow_dps_classified_yes   = _ow_dps_classified_yes   or 0    -- actions we accepted (src_tag != nil)
_ow_dps_classified_no    = _ow_dps_classified_no    or 0    -- actions where actor wasn't us/pet/party
_ow_dps_recorded_events  = _ow_dps_recorded_events  or 0    -- events successfully added to buffer
_ow_dps_last_actor_id    = _ow_dps_last_actor_id    or 0
_ow_dps_last_actor_name  = _ow_dps_last_actor_name  or '?'
_ow_dps_last_msg         = _ow_dps_last_msg         or 0
_ow_dps_last_cat         = _ow_dps_last_cat         or -1
_ow_dps_unrecognized_msgs= _ow_dps_unrecognized_msgs or {}  -- msg_id → count

-- Action-message reaction code → semantic tag. Reaction is the lower
-- bits of the action's "reaction" field (or inferred from message_id
-- if reaction is unset). Values per Windower's res.action_messages.
-- We don't try to enumerate all message_ids — these few cover ~99% of
-- combat traffic and edge cases just don't get counted.
local DPS_MELEE_HIT_MSG  = {[1]=true,  [67]=true}    -- normal hit, crit
local DPS_MELEE_CRIT_MSG = {[67]=true}
local DPS_MELEE_MISS_MSG = {[15]=true, [63]=true,    -- miss, miss-anti
                             [282]=true}             -- shadow absorbed (treat as miss for accuracy)
local DPS_MELEE_EVADE_MSG= {[15]=true, [30]=true,    -- evade
                             [31]=true, [32]=true}   -- blink, anticipate (treated as defensive)
local DPS_MELEE_PARRY_MSG= {[14]=true, [64]=true}    -- parry, guarded
local DPS_RANGED_HIT_MSG = {[352]=true, [353]=true,
                             [576]=true, [577]=true} -- ranged hit / crit (regular, squad)
local DPS_RANGED_MISS_MSG= {[354]=true}              -- ranged miss
local DPS_WS_HIT_MSG     = {[185]=true, [187]=true,  -- WS hit, WS hit (additional effect)
                             [188]=true, [189]=true,
                             [157]=true, [158]=true} -- skillchain, magic burst
local DPS_WS_MISS_MSG    = {[188]=true, [324]=true,  -- WS miss / WS missed
                             [659]=true}             -- WS evaded
local DPS_MAGIC_LAND_MSG = {[2]=true,   [252]=true,  -- damage, magic burst
                             [264]=true, [265]=true, -- ditto special
                             [110]=true}             -- AoE damage tick
local DPS_MAGIC_BURST_MSG= {[252]=true}              -- subset of magic_land
local DPS_MAGIC_RESIST_MSG = {[85]=true, [283]=true, -- no effect, resisted
                              [284]=true, [654]=true}-- partial resist counts as land at the dmg amount it provided

-- Resolve "is this actor someone we're tracking?" → returns
-- (src_tag, src_name) or nil if we don't track them. src_tag is one of
-- 'me', 'pet', or '<party_name>' (also used as src_name in that case).
local function _ow_dps_classify_actor(actor_id)
    if not actor_id or actor_id == 0 then return nil end
    local me = windower.ffxi.get_player()
    if not me then return nil end
    if actor_id == me.id then return 'me', me.name end
    -- Pet: get_mob_by_id should expose an owner relationship. The simplest
    -- check is comparing against player.pet (the addon's own pet).
    if me.pet and me.pet.id and actor_id == me.pet.id then
        return 'pet', me.pet.name or 'pet'
    end
    if not PW_DPS_INCLUDE_PARTY then return nil end
    -- Party / alliance member?
    local party = windower.ffxi.get_party()
    if party then
        for slot, m in pairs(party) do
            if type(m) == 'table' and m.mob and m.mob.id == actor_id then
                return m.name, m.name
            end
        end
    end
    -- Pet of a party member: m.mob.pet_index → mob array. Skipped for
    -- simplicity; party-member pets get attributed to the pet's name only
    -- if they show up in the mob array, which they do.
    local pet_mob = windower.ffxi.get_mob_by_id(actor_id)
    if pet_mob and pet_mob.is_npc and party then
        for slot, m in pairs(party) do
            if type(m) == 'table' and m.mob and m.mob.pet_index
               and m.mob.pet_index ~= 0
               and pet_mob.index == m.mob.pet_index then
                return m.name .. "'s pet", m.name .. "'s pet"
            end
        end
    end
    return nil
end

local function _ow_dps_target_name(target_id)
    if not target_id or target_id == 0 then return '?' end
    local m = windower.ffxi.get_mob_by_id(target_id)
    return (m and m.name) or '?'
end

local function _ow_dps_record(ev)
    ev.ts = os.clock()
    table.insert(_ow_dps_events, ev)
    _ow_dps_last_event_ts = ev.ts
    _ow_dps_recorded_events = (_ow_dps_recorded_events or 0) + 1
end

-- Trim everything older than the rolling window. Cheap because events
-- are timestamp-ordered.
function _ow_dps_prune()
    local cutoff = os.clock() - _ow_dps_window_s
    local first_keep = 1
    while first_keep <= #_ow_dps_events
          and _ow_dps_events[first_keep].ts < cutoff do
        first_keep = first_keep + 1
    end
    if first_keep > 1 then
        -- Rebuild — cheaper than table.remove() in a loop for large lists.
        local kept = {}
        for i = first_keep, #_ow_dps_events do
            kept[#kept + 1] = _ow_dps_events[i]
        end
        _ow_dps_events = kept
    end
end

-- Reset the rolling buffer (e.g. on //ow dps reset or zone change).
function _ow_dps_reset()
    _ow_dps_events = {}
    _ow_dps_last_event_ts = 0
end

-- Hook called by handle_incoming_action — feeds DPS-relevant data in.
-- Returns nothing; safe to call on every action without consequence to
-- the existing pipeline.
local function _ow_dps_record_action(act)
    if not act or not act.targets or not act.actor_id then return end
    local cat = act.category
    if not cat then return end

    -- Diagnostic counters.
    _ow_dps_actions_total = _ow_dps_actions_total + 1
    _ow_dps_actions_by_cat[cat] = (_ow_dps_actions_by_cat[cat] or 0) + 1
    _ow_dps_last_cat      = cat
    _ow_dps_last_actor_id = act.actor_id
    local _actor_mob = windower.ffxi.get_mob_by_id(act.actor_id)
    _ow_dps_last_actor_name = (_actor_mob and _actor_mob.name) or '?'
    if act.targets[1] and act.targets[1].actions and act.targets[1].actions[1] then
        _ow_dps_last_msg = act.targets[1].actions[1].message or 0
    end

    -- Determine if WE are the actor (or one of our pets / party).
    local src_tag, src_name = _ow_dps_classify_actor(act.actor_id)
    if src_tag then
        _ow_dps_classified_yes = _ow_dps_classified_yes + 1
    else
        _ow_dps_classified_no  = _ow_dps_classified_no + 1
    end

    -- Mob attacking US (defensive metrics) — actor is a mob, target is me/party.
    -- Categories: 1 = melee, 2 = ranged, 11 = mob TP move (attack swing variants).
    if not src_tag and (cat == 1 or cat == 2 or cat == 11) then
        local me = windower.ffxi.get_player()
        if me then
            for _, t in ipairs(act.targets) do
                if t.id == me.id and t.actions then
                    -- Each per-target action is one swing.
                    for _, a in ipairs(t.actions) do
                        local msg = a.message or 0
                        _ow_dps_record({
                            src='me', src_name=me.name, kind='mob_swing_at',
                            target_id=act.actor_id,
                            target_name=_ow_dps_target_name(act.actor_id),
                            value=0, msg=msg,
                        })
                        if DPS_MELEE_EVADE_MSG[msg] then
                            _ow_dps_record({
                                src='me', src_name=me.name, kind='melee_evaded',
                                target_id=act.actor_id,
                                target_name=_ow_dps_target_name(act.actor_id),
                                value=0, msg=msg,
                            })
                        end
                    end
                end
            end
        end
        return
    end

    if not src_tag then return end   -- not a tracked actor

    -- Tracked-source outgoing action.
    if cat == 1 or cat == 2 then
        -- Melee/ranged round.
        local is_ranged = (cat == 2)
        for _, t in ipairs(act.targets) do
            if t.actions then
                for _, a in ipairs(t.actions) do
                    local msg = a.message or 0
                    local val = a.param or 0
                    -- Heuristic damage-cap fix: if a.param looks suspiciously
                    -- small for a hit message but we have a 'cparam' wider
                    -- field, prefer that.
                    if a.cparam and tonumber(a.cparam)
                       and tonumber(a.cparam) > val then
                        val = tonumber(a.cparam)
                    end
                    local is_hit  = (is_ranged and DPS_RANGED_HIT_MSG[msg])
                                    or (not is_ranged and DPS_MELEE_HIT_MSG[msg])
                    local is_miss = (is_ranged and DPS_RANGED_MISS_MSG[msg])
                                    or (not is_ranged and DPS_MELEE_MISS_MSG[msg])
                    local is_crit = DPS_MELEE_CRIT_MSG[msg]
                    if is_hit then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name,
                            kind=is_ranged and 'ranged_hit' or 'melee_hit',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=val, is_crit=is_crit and true or false,
                            msg=msg,
                        })
                    elseif is_miss then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name,
                            kind=is_ranged and 'ranged_miss' or 'melee_miss',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=0, msg=msg,
                        })
                    else
                        -- Track unbucketed messages so we can extend the
                        -- DPS_*_MSG tables.
                        _ow_dps_unrecognized_msgs[msg] =
                            (_ow_dps_unrecognized_msgs[msg] or 0) + 1
                    end
                end
            end
        end
        return
    end

    if cat == 3 then
        -- Weapon skill finish.
        local ws = act.param and res.weapon_skills and res.weapon_skills[act.param]
        local ws_name = (ws and (ws.en or ws.name)) or '?'
        for _, t in ipairs(act.targets) do
            if t.actions then
                for _, a in ipairs(t.actions) do
                    local msg = a.message or 0
                    local val = a.param or 0
                    if a.cparam and tonumber(a.cparam)
                       and tonumber(a.cparam) > val then
                        val = tonumber(a.cparam)
                    end
                    if DPS_WS_HIT_MSG[msg] then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name, kind='ws',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=val, ws_name=ws_name, msg=msg,
                        })
                    elseif DPS_WS_MISS_MSG[msg] then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name, kind='ws_miss',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=0, ws_name=ws_name, msg=msg,
                        })
                    end
                end
            end
        end
        return
    end

    if cat == 4 then
        -- Spell finish (offensive damage spell).
        local sp = act.param and res.spells and res.spells[act.param]
        local sp_name = (sp and (sp.en or sp.name)) or '?'
        for _, t in ipairs(act.targets) do
            if t.actions then
                for _, a in ipairs(t.actions) do
                    local msg = a.message or 0
                    local val = a.param or 0
                    if a.cparam and tonumber(a.cparam)
                       and tonumber(a.cparam) > val then
                        val = tonumber(a.cparam)
                    end
                    if DPS_MAGIC_LAND_MSG[msg] then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name, kind='magic_land',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=val,
                            is_burst=DPS_MAGIC_BURST_MSG[msg] and true or false,
                            spell_id=act.param, spell_name=sp_name, msg=msg,
                        })
                    elseif DPS_MAGIC_RESIST_MSG[msg] then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name, kind='magic_resist',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=0, spell_id=act.param,
                            spell_name=sp_name, msg=msg,
                        })
                    end
                end
            end
        end
        return
    end

    -- cat=13 = pet melee: covered by classify_actor returning 'pet'.
    if cat == 13 then
        for _, t in ipairs(act.targets) do
            if t.actions then
                for _, a in ipairs(t.actions) do
                    local msg = a.message or 0
                    local val = a.param or 0
                    if a.cparam and tonumber(a.cparam)
                       and tonumber(a.cparam) > val then
                        val = tonumber(a.cparam)
                    end
                    if DPS_MELEE_HIT_MSG[msg] then
                        _ow_dps_record({
                            src=src_tag, src_name=src_name, kind='pet_melee_hit',
                            target_id=t.id,
                            target_name=_ow_dps_target_name(t.id),
                            value=val,
                            is_crit=DPS_MELEE_CRIT_MSG[msg] and true or false,
                            msg=msg,
                        })
                    end
                end
            end
        end
    end
end

-- Aggregator: walk events and produce the per-source rolled-up totals.
-- Returns a nested table keyed by src_tag with all the metrics, plus
-- a per-WS map and per-mob map.
local function _ow_dps_aggregate()
    _ow_dps_prune()
    local out = {}
    local ws_per_src   = {}    -- src → {ws_name → {count, total, best}}
    local mob_per_src  = {}    -- src → {mob_name → {total, last_ts}}

    local function bucket(src)
        if not out[src] then
            out[src] = {
                white_total = 0, ranged_total = 0, magic_total = 0,
                ws_total = 0, longest_hit = 0,
                hits = 0, misses = 0, crits = 0,
                spells_landed = 0, spells_resisted = 0, magic_bursts = 0,
                evaded = 0, mob_swings_at = 0,
            }
        end
        return out[src]
    end

    for _, ev in ipairs(_ow_dps_events) do
        local src = ev.src
        local b = bucket(src)
        if ev.kind == 'melee_hit' then
            b.white_total = b.white_total + (ev.value or 0)
            b.hits = b.hits + 1
            if ev.is_crit then b.crits = b.crits + 1 end
            if (ev.value or 0) > b.longest_hit then b.longest_hit = ev.value end
        elseif ev.kind == 'pet_melee_hit' then
            b.white_total = b.white_total + (ev.value or 0)
            b.hits = b.hits + 1
            if ev.is_crit then b.crits = b.crits + 1 end
        elseif ev.kind == 'ranged_hit' then
            b.ranged_total = b.ranged_total + (ev.value or 0)
            b.hits = b.hits + 1
            if ev.is_crit then b.crits = b.crits + 1 end
            if (ev.value or 0) > b.longest_hit then b.longest_hit = ev.value end
        elseif ev.kind == 'melee_miss' or ev.kind == 'ranged_miss' then
            b.misses = b.misses + 1
        elseif ev.kind == 'ws' then
            b.ws_total = b.ws_total + (ev.value or 0)
            if (ev.value or 0) > b.longest_hit then b.longest_hit = ev.value end
            local m = ws_per_src[src] or {}
            local w = m[ev.ws_name] or {count=0, total=0, best=0}
            w.count = w.count + 1
            w.total = w.total + (ev.value or 0)
            if (ev.value or 0) > w.best then w.best = ev.value end
            m[ev.ws_name] = w
            ws_per_src[src] = m
        elseif ev.kind == 'magic_land' then
            b.magic_total = b.magic_total + (ev.value or 0)
            b.spells_landed = b.spells_landed + 1
            if ev.is_burst then b.magic_bursts = b.magic_bursts + 1 end
            if (ev.value or 0) > b.longest_hit then b.longest_hit = ev.value end
        elseif ev.kind == 'magic_resist' then
            b.spells_resisted = b.spells_resisted + 1
        elseif ev.kind == 'melee_evaded' then
            b.evaded = b.evaded + 1
        elseif ev.kind == 'mob_swing_at' then
            b.mob_swings_at = b.mob_swings_at + 1
        end
        if ev.kind == 'melee_hit' or ev.kind == 'ws'
           or ev.kind == 'magic_land' or ev.kind == 'ranged_hit'
           or ev.kind == 'pet_melee_hit' then
            local mm = mob_per_src[src] or {}
            local mname = ev.target_name or '?'
            local r = mm[mname] or {total=0, last_ts=0}
            r.total = r.total + (ev.value or 0)
            r.last_ts = ev.ts
            mm[mname] = r
            mob_per_src[src] = mm
        end
    end
    return out, ws_per_src, mob_per_src
end

-- Send a single DPS payload over UDP. Throttled to 2 Hz by the caller.
local function _ow_dps_emit()
    local out, ws_per_src, mob_per_src = _ow_dps_aggregate()
    local lines = {}
    local now = os.clock()

    local scope = PW_DPS_INCLUDE_PARTY and 'all' or 'me'

    for src, b in pairs(out) do
        local hits_or_crits = b.hits
        local total_swings  = b.hits + b.misses
        local melee_acc = total_swings > 0
                          and (hits_or_crits / total_swings) * 100
                          or 0
        local crit_pct  = (b.hits) > 0 and (b.crits / b.hits) * 100 or 0
        local mag_attempts = b.spells_landed + b.spells_resisted
        local mag_acc = mag_attempts > 0
                        and (b.spells_landed / mag_attempts) * 100 or 0
        local evasion = b.mob_swings_at > 0
                        and (b.evaded / b.mob_swings_at) * 100 or 0
        local total_dmg = b.white_total + b.ranged_total
                          + b.magic_total + b.ws_total
        local dps = total_dmg / _ow_dps_window_s
        table.insert(lines, string.format(
            'DPS|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%.1f|%.1f|%.1f|%.1f|%d|%d|%.1f',
            src, scope,
            _ow_dps_window_s,
            b.white_total, b.magic_total, b.ws_total,
            b.hits, b.misses, b.crits,
            b.spells_landed, b.spells_resisted,
            melee_acc, mag_acc, crit_pct, evasion,
            b.longest_hit, total_dmg, dps))

        local ws = ws_per_src[src] or {}
        for name, w in pairs(ws) do
            table.insert(lines, string.format(
                'WS|%s|%s|%d|%d|%d',
                src, name, w.count, w.total, w.best))
        end

        local mm = mob_per_src[src] or {}
        for mname, r in pairs(mm) do
            table.insert(lines, string.format(
                'MOB|%s|%s|%d|%.1f',
                src, mname, r.total, now - (r.last_ts or now)))
        end
    end

    if #lines == 0 then
        udp_dps:send('DPS_EMPTY')
    else
        udp_dps:send(table.concat(lines, '\n'))
    end
end

local function handle_incoming_action(act)
    if not act or not act.targets or not act.targets[1] then return end

    -- DPS tracker hook — feed every action through the DPS recorder so it
    -- can extract melee/ranged/WS/magic events for the rolling-window
    -- panel. pcall'd so a malformed packet can't kill the rest of the
    -- handler chain.
    pcall(_ow_dps_record_action, act)

    local tgt     = act.targets[1]
    local action  = tgt.actions and tgt.actions[1]
    local msg_id  = action and action.message
    local actor_id = act.actor_id
    local cat      = act.category

    -- Diagnostic: show every action category we receive so we can see
    -- which categories fire for mob casts in this environment.
    if _ow_cast_debug then
        local actor = windower.ffxi.get_mob_by_id(actor_id or 0)
        local actor_name = (actor and actor.name) or '?'
        windower.add_to_chat(207, string.format(
            '[OW] action cat=%d param=%d msg=%s actor=%s',
            cat or -1, act.param or -1, tostring(msg_id), actor_name))
    end

    -- ── Bolter's Roll snoop ─────────────────────────────────────────────
    -- Cat=6 (job ability), act.param=118 (Bolter's Roll id). The roll
    -- value (1..12) lives in the per-target action.param. We only count
    -- Self-buff JAs that put a status on us: emit buff_gain so the
    -- timer panel gets the accurate base duration (60s for Nightingale,
    -- Troubadour; 60s for Marcato; etc.) rather than the source='self'
    -- 3-minute fallback. The status_id and duration both come from
    -- res.job_abilities directly so this stays correct if SE retunes
    -- any of these.
    --
    -- Confirmed buff IDs (Windower buffs.lua / Sammeh's gearswap):
    --   Nightingale       347
    --   Troubadour        348
    --   Soul Voice         52
    --   Marcato           231
    --   Clarion Call      499
    --   Crooked Cards     601 (COR; sits until consumed by next roll)
    --
    -- We dispatch any cat=6 self-cast where res.job_abilities[id].status
    -- gives a buff id we recognise as one of these. The slot poller will
    -- bind the real 0x063 entry to our pending_meta exactly as it does
    -- for songs.
    if cat == 6 and act.actor_id then
        local me = windower.ffxi.get_player()
        local my_id = me and me.id or 0
        if act.actor_id == my_id then
            local ab = res.job_abilities and res.job_abilities[act.param]
            if ab and ab.status and ab.duration and ab.duration > 0 then
                local known_self_buff_jas = {
                    [347] = true,  -- Nightingale
                    [348] = true,  -- Troubadour
                    [52]  = true,  -- Soul Voice
                    [231] = true,  -- Marcato
                    [499] = true,  -- Clarion Call
                    [601] = true,  -- Crooked Cards
                }
                if known_self_buff_jas[ab.status] then
                    ow_events.emit('buff_gain', {
                        target_id    = my_id,
                        buff_id      = ab.status,
                        spell_id     = nil,  -- not a spell
                        duration     = ab.duration,
                        actor_id     = my_id,
                        display_name = ab.en or ab.name,
                    })
                    -- Always print so we see when JAs wire through.
                    windower.add_to_chat(207, string.format(
                        '[OW] JA WIRE: %s bid=%d dur=%ds (cat=6 self)',
                        ab.en or '?', ab.status, ab.duration))
                end
            end
        end
    end

    -- the roll if YOU are in the targets list (a party COR rolling on
    -- you, or you rolling yourself). On a bust (rollNum==12) we clear.
    if cat == 6 and act.param == 118 then
        -- Find the player's id and check whether they're targeted.
        local me = windower.ffxi.get_player()
        local my_id = me and me.id or 0
        local roll_value = nil
        for _, t in ipairs(act.targets or {}) do
            if t.id == my_id and t.actions and t.actions[1] then
                roll_value = t.actions[1].param
                break
            end
        end
        if roll_value then
            if roll_value == 12 then
                -- Bust: clear our cached value.
                _ow_bolters_value = 0
            elseif roll_value >= 1 and roll_value <= 11 then
                _ow_bolters_value = roll_value
            end
            if _ow_cast_debug then
                windower.add_to_chat(207, string.format(
                    '[OW] Bolters roll value = %d', roll_value))
            end
        end
    end

    -- ── All Phantom Roll snoop (general) ─────────────────────────────────
    -- For any cat=6 ability that's a Phantom Roll AND we're targeted by
    -- it, we record the roll id and the rolled value into _ow_roll_state.
    -- The effect calculation (per roll → which stat → per-value bonus)
    -- happens later at compute time using PW_ROLL_EFFECTS, which we'll
    -- expand over time. For now, just tracking what's active.
    if cat == 6 and PW_PHANTOM_ROLL_IDS[act.param] then
        local me = windower.ffxi.get_player()
        local my_id = me and me.id or 0
        local roll_value = nil
        for _, t in ipairs(act.targets or {}) do
            if t.id == my_id and t.actions and t.actions[1] then
                roll_value = t.actions[1].param
                break
            end
        end
        -- Crooked Cards detection: only for OUR own rolls (we can only
        -- see our own buff list reliably). If the buff is active on us
        -- AND we are the actor, the next roll gets the 1.2x multiplier.
        local crooked = false
        if act.actor_id == my_id and PW_BUFF_CROOKED_CARDS
           and me and me.buffs then
            for _, bid in ipairs(me.buffs) do
                if bid == PW_BUFF_CROOKED_CARDS then
                    crooked = true
                    break
                end
            end
        end
        if roll_value and roll_value >= 1 and roll_value <= 11 then
            -- Detect whether Double-Up Chance (buff_id 308) is currently
            -- active on us. The buff lasts 45s OR until bust — does NOT
            -- refresh on subsequent rolls in the same cycle. So we
            -- emit buff_gain only when 308 isn't already up. If it
            -- expired naturally (45s elapsed) before the next roll,
            -- THAT roll starts a new cycle and gets a fresh 45s window.
            local du_active = false
            if me and me.buffs then
                for _, bid in ipairs(me.buffs) do
                    if bid == 308 then du_active = true; break end
                end
            end
            _ow_roll_state[act.param] = roll_value
            _ow_roll_crooked[act.param] = crooked or nil
            if _ow_cast_debug then
                local nm = (res.job_abilities[act.param]
                            and res.job_abilities[act.param].en) or '?'
                windower.add_to_chat(207, string.format(
                    '[OW] roll %s = %d%s', nm, roll_value,
                    crooked and ' [CROOKED 1.2x]' or ''))
            end
            -- ── Server_Stats trigger ───────────────────────────────────
            -- If the experimental Server_Stats module is loaded AND
            -- enabled, fire a request for fresh server-truth pAtt.
            -- The request is queued (not fired immediately) so the
            -- roll buff has time to apply server-side. Wrapped in
            -- pcall so if anything goes wrong we don't disrupt the
            -- roll handler.
            if act.actor_id == my_id and OW_ServerStats then
                pcall(function()
                    OW_ServerStats.request('phantom_roll')
                end)
            end
            -- Emit buff_gain so the buff timer panel picks up the roll.
            -- Phantom Roll is a job ability (cat=6), so the spell-finish
            -- code path that normally emits buff_gain doesn't fire for
            -- it. We have to do it here. Resolve the buff_id from
            -- Cor_Rolls' status/buff_id field; resolve base duration
            -- from res.buffs[bid].duration. The handler will detect
            -- source='roll' (because actor_id == my_id) and apply
            -- _ow_roll_duration_mult() automatically.
            if act.actor_id == my_id and Cor_Rolls then
                local roll_def = Cor_Rolls[act.param]
                local buff_id  = roll_def and (tonumber(roll_def['status'])
                                            or tonumber(roll_def['buff_id']))
                if buff_id then
                    local base_dur = 300  -- 5min default for rolls
                    if res and res.buffs and res.buffs[buff_id]
                       and res.buffs[buff_id].duration then
                        base_dur = tonumber(res.buffs[buff_id].duration)
                                   or base_dur
                    end
                    -- Snapshot gear-aware duration multiplier at cat=6.
                    -- For our own rolls, this is the BEST moment we have:
                    -- the action just resolved (so midcast gear hasn't
                    -- swapped back yet on most gearswap setups). At
                    -- buff_gain time gearswap has typically fired
                    -- aftercast() and snapped to idle/TP gear, missing
                    -- duration pieces (Compensator, Camulus's, Regal
                    -- Necklace, Navarch's Gants).
                    if act.actor_id == my_id then
                        local mult = _ow_roll_duration_mult()
                        _ow_roll_cast_dur = _ow_roll_cast_dur or {}
                        _ow_roll_cast_dur[buff_id] = {
                            mult = mult,
                            ts   = os.time(),
                        }
                        if _ow_buff_debug then
                            windower.add_to_chat(207, string.format(
                                '[OW] roll dur snapshot bid=%d mult=%.3fx',
                                buff_id, mult))
                        end
                    end
                    ow_events.emit('buff_gain', {
                        target_id = my_id,
                        buff_id   = buff_id,
                        spell_id  = 0,        -- not a spell
                        duration  = base_dur,
                        actor_id  = my_id,    -- self-cast
                    })
                    -- Double-Up Chance (buff_id 308) lands once when
                    -- a roll cycle starts (no DU active). It persists
                    -- 45s OR until bust — does NOT refresh on subsequent
                    -- rolls in the same cycle. Emit only when 308
                    -- isn't already on us. If it expired naturally
                    -- before this roll, this roll starts a new cycle
                    -- and gets a fresh 45s window.
                    if act.actor_id == my_id and not du_active then
                        ow_events.emit('buff_gain', {
                            target_id = my_id,
                            buff_id   = 308,    -- Double-Up Chance
                            spell_id  = 0,
                            duration  = 45,
                            actor_id  = my_id,
                        })
                    end
                end
            end
        elseif roll_value == 12 then
            -- Bust: record -1 as sentinel. The roll is still active in
            -- the buff list (showing the bust debuff), but with a
            -- negative effect. Compute path applies Cor_Rolls[id].bust
            -- value when it sees -1.
            _ow_roll_state[act.param] = -1
            _ow_roll_crooked[act.param] = nil  -- crooked doesn't help busts
            -- Bust ends the Double-Up window early. Untrack the
            -- Double-Up Chance buff timer so the panel reflects that
            -- you can't continue rolling.
            if act.actor_id == my_id then
                _ow_untrack_buff(308)
            end
            -- Bust debuff is a universal status (buff_id 309), shared
            -- across all rolls. Older code tried to look up a per-roll
            -- bust id from Cor_Rolls[id].bust_id / .bust / .status —
            -- those fields are either nil or hold the EFFECT value
            -- (e.g. -100 for Chaos Roll attack penalty), NOT a buff id.
            -- Result: emission silently failed, the buff timer fell
            -- back to its generic 3-min unknown-buff default.
            --
            -- Reference: Windower AutoCOR addon, Action_Processing line
            -- showing `buffs[309] = param` on bust message 426.
            -- BG-wiki Bust article: "Duration: 5 Minutes" base.
            --
            -- Bust duration scales with the COR Bust Duration merit
            -- (group 1 merit, 5/5 max, -10s per level). Read the merit
            -- count via player.merits when available, else fall back to
            -- manual override. Final base: 300 - merit_count*10, with
            -- a floor of 60s.
            local BUST_BUFF_ID = 309
            if act.actor_id == my_id then
                local bust_dur = 300
                local ok_p, p = pcall(windower.ffxi.get_player)
                if ok_p and p and p.merits then
                    local m = tonumber(p.merits.bust_duration) or 0
                    bust_dur = bust_dur - (math.min(5, math.max(0, m)) * 10)
                end
                if bust_dur < 60 then bust_dur = 60 end
                ow_events.emit('buff_gain', {
                    target_id = my_id,
                    buff_id   = BUST_BUFF_ID,
                    spell_id  = 0,
                    duration  = bust_dur,
                    actor_id  = my_id,
                    -- Bust duration is fixed per-cast (only affected by
                    -- the bust_duration merit, computed above) — NOT by
                    -- Phantom Roll+ duration gear. The buff_gain handler
                    -- normally multiplies roll-classified buffs by the
                    -- duration multiplier; this flag tells it to skip
                    -- that for busts.
                    fixed_duration = true,
                })
            end
            if _ow_cast_debug then
                local nm = (res.job_abilities[act.param]
                            and res.job_abilities[act.param].en) or '?'
                windower.add_to_chat(207, '[OW] roll '..nm..' = BUST')
            end
        end
    end

    -- ── Buff source snoops (March, Haste spell, food) ───────────────────
    -- Goal: when a buff is applied to YOU, record exactly what spell/song/
    -- item produced it. This lets ow_compute_haste() distinguish e.g. a
    -- Haste II spell (30%) from a single Honor March (11.7%) — both share
    -- buff_id 33. Sources are saved to disk and reloaded across sessions.

    -- Diagnostic: log EVERY song cast we see (cat=4 + BardSong type),
    -- regardless of whether we're targeted. This makes the snoop's gating
    -- visible — if you see "song cast" but no "song-gear walk" / potency
    -- line afterward, the i_am_targeted check is filtering out your cast.
    -- Songs may come through as cat 4 (cast complete) OR cat 8 (cast finish).
    -- For cat 8 the spell_id is in act.targets[1].actions[1].param (NOT act.param).
    do
        local probe_id = nil
        if cat == 4 then
            probe_id = act.param
        elseif cat == 8 and act.targets and act.targets[1]
               and act.targets[1].actions and act.targets[1].actions[1] then
            probe_id = act.targets[1].actions[1].param
        end
        if probe_id then
            _ow_build_song_tables()
            local _sd = res.spells and res.spells[probe_id]
            local _stype = (_sd and _sd.type) or '<nil>'
            local _in_march_tbl = PW_SONG_HASTE and PW_SONG_HASTE[probe_id] or false
            -- Log when EITHER the probe is a march OR the spell is type=BardSong
            -- so we can see what's coming through and why it's being missed.
            if _in_march_tbl or _stype == 'BardSong' then
                local _sname = (_sd and (_sd.enl or _sd.en)) or '<missing>'
                local actor = windower.ffxi.get_mob_by_id(act.actor_id or 0)
                local actor_name = (actor and actor.name) or '?'
                windower.add_to_chat(207, string.format(
                    '[OW] song cast (cat=%d): id=%s name=%s type=[%s] in_march_tbl=%s actor=%s',
                    cat, tostring(probe_id), tostring(_sname),
                    tostring(_stype), tostring(_in_march_tbl), actor_name))
            end
        end
    end

    do
        local me = windower.ffxi.get_player()
        local my_id = me and me.id or 0
        local my_index = (me and me.index) or 0
        local i_am_targeted = false
        -- Match by either mob.id or mob.index — Windower's act.targets[].id
        -- can be either depending on action type. Also treat ourselves as
        -- targeted when WE are the actor (self-cast, or AoE songs we sang).
        if act.actor_id == my_id then
            i_am_targeted = true
        end
        for _, t in ipairs(act.targets or {}) do
            if t.id == my_id or t.id == my_index then
                i_am_targeted = true; break
            end
        end
        if i_am_targeted then
            -- buff_gain emit for ALL bard songs landing on us is handled
            -- INSIDE the cat=4 branch of the two-step capture below. The
            -- emit runs AFTER the gear snapshot completes so the buff
            -- timer panel gets the gear-aware duration, not a stale value
            -- left over from a previous cast.

            -- BRD songs: cat 13. Map song id → haste% (with bard_song_plus
            -- applied if the singer is YOU). For songs sung by other BRDs
            -- on you, we use base values (we can't see their gear).
            -- BRD songs: cat 13. Record source name + spell id for ALL
            -- songs targeting the player so the buff column can show the
            -- specific tier (Honor March vs Victory March etc.). For
            -- songs that grant haste (the three Marches), additionally
            -- compute their potency for the haste calculation.
            -- Songs come through as cat=4 (complete) or cat=8 (cast finish).
            -- For cat=8, spell_id is in targets[1].actions[1].param. For cat=4
            -- it's in act.param. Try both — whichever fires for this packet.
            local song_probe_id = nil
            if cat == 4 then
                song_probe_id = act.param
            elseif cat == 8 and act.targets and act.targets[1]
                   and act.targets[1].actions and act.targets[1].actions[1] then
                song_probe_id = act.targets[1].actions[1].param
            end
            if song_probe_id then
                _ow_build_song_tables()
                local spell_data = res.spells and res.spells[song_probe_id]

                -- For ALL bard songs (regardless of whether they're in
                -- the march-potency table) cast BY US at cat=8, capture
                -- the gear-aware duration so the buff_gain emit at cat=4
                -- has a real number to use. Without this, minuets /
                -- ballads / madrigals fall back to the spell's raw base
                -- (120s) since their cat=8 capture would otherwise be
                -- skipped — that's why the timer panel shows 2:00.
                -- Two-step capture for accurate gear-aware song durations:
                --
                --   cat=8 (cast START): Soul Voice / Marcato are visible
                --     in player.buffs but get CONSUMED the moment the
                --     song completes, so we MUST sample buffs here.
                --     player.equipment at this moment is unreliable —
                --     gearswaps usually have precast (fast cast) gear
                --     up, NOT the midcast SongEffect set with all the
                --     duration pieces. We do NOT compute final here.
                --
                --   cat=4 (cast FINISH): the gearswap midcast set has
                --     finished applying, so player.equipment now reflects
                --     the user's actual song-duration gear. We snapshot
                --     equipment here, merge with the buff state stashed
                --     at cat=8, and compute the final duration. The
                --     buff_gain emit (cat=4 path further down) reads
                --     the result from _ow_song_cast_dur[name].
                if act.actor_id == my_id and spell_data
                   and spell_data.type == 'BardSong' then
                    local _sname = spell_data.enl or spell_data.en
                    if _sname then
                        if cat == 8 then
                            -- Stash consumable buffs (SV/MC) for cat=4 merge.
                            local p = windower.ffxi.get_player()
                            local active_buffs = {}
                            if p and p.buffs then
                                for _, bid in ipairs(p.buffs) do
                                    active_buffs[#active_buffs+1] = bid
                                end
                            end
                            _ow_song_cast_pending = _ow_song_cast_pending or {}
                            _ow_song_cast_pending[_sname] = {
                                active_buffs = active_buffs,
                                ts = os.time(),
                            }
                        elseif cat == 4 then
                            -- Cast finished -- midcast gear is up. Read
                            -- equipment, merge with stashed buff state,
                            -- compute final.
                            local equip = _ow_equipment_snapshot()
                            local pending = (_ow_song_cast_pending or {})[_sname]
                            local active_buffs = (pending and pending.active_buffs)
                                                  or {}
                            -- (No pending may happen if the addon
                            -- (re)loaded mid-cast; we proceed without
                            -- SV/MC bonuses in that edge case.)
                            local song_class = _ow_classify_song(_sname)
                            local base       = _ow_song_base_duration(song_class)
                            local final      = _ow_compute_song_duration(
                                _sname, equip, active_buffs,
                                PW_BRD_JP_GIFTS or {})
                            _ow_song_cast_dur = _ow_song_cast_dur or {}
                            _ow_song_cast_dur[_sname] = {
                                base       = base,
                                final      = final or base,
                                equip      = equip,
                                ts         = os.time(),
                                song_class = song_class,
                            }
                            if _ow_song_cast_pending then
                                _ow_song_cast_pending[_sname] = nil
                            end

                            -- Emit buff_gain to the buff-timer panel.
                            -- buff_id comes from the spell resource's
                            -- .status field (214 for marches, 198 for
                            -- minuets, etc.). display_name carries the
                            -- specific tier so the buff timer panel
                            -- shows "Honor March", not just "March".
                            local sbid = spell_data.status
                            if sbid and sbid > 0 then
                                -- Apply -1s correction. The cast-anchored
                                -- timer is consistently ~1-2s ahead of
                                -- the real wear-off due to server tick
                                -- alignment + the gap between "cast
                                -- packet received" and "buff actually
                                -- starts ticking on the client". Knock
                                -- 1s off so the displayed timer hits 0
                                -- right when the buff wears off.
                                local emit_dur = (final or base) - 1.0
                                if emit_dur < 1 then emit_dur = 1 end
                                ow_events.emit('buff_gain', {
                                    target_id    = my_id,
                                    buff_id      = sbid,
                                    spell_id     = song_probe_id,
                                    duration     = emit_dur,
                                    actor_id     = act.actor_id or 0,
                                    display_name = _sname,
                                })
                                -- WIRE: ALWAYS fires (no debug flag).
                                -- This is the single most useful line
                                -- for diagnosing duration issues — shows
                                -- the exact bid/dur sent to the timer
                                -- panel for every song cast we capture.
                                windower.add_to_chat(207, string.format(
                                    '[OW] WIRE: %s bid=%d dur=%.1fs (cast_capture, -1s adj)',
                                    _sname, sbid, emit_dur))

                                -- Write to _ow_buff_sources so the stat
                                -- injection block (post-/checkparam) can
                                -- find this song and apply its att/acc/
                                -- def/etc. bonus. The march-tracker code
                                -- below ALSO writes to this table for
                                -- marches; we use a different src_kind
                                -- ('song_v2') to avoid double-counting
                                -- when the march path runs for the same
                                -- spell.
                                if act.actor_id == my_id then
                                    -- Family lookup: read inline from
                                    -- Bard_Songs[id].family. Works for
                                    -- ALL songs (haste, stat, regen,
                                    -- whatever), not just stat-injecting
                                    -- ones — Honor March's family =
                                    -- 'marches' even though its effect[1]
                                    -- is 'ma_haste' and PW_SONG_STATS_BY_NAME
                                    -- doesn't have it.
                                    local song_def = Bard_Songs and Bard_Songs[song_probe_id]
                                    local song_family = song_def and song_def.family
                                    -- Combined Song+ count (used by
                                    -- legacy march haste consumer; see
                                    -- the 'song_plus' field on the
                                    -- record).
                                    local sp = 0
                                    if song_family then
                                        sp = ow_song_plus_for_family(song_family) or 0
                                    end
                                    -- ALSO snapshot the SPLIT values
                                    -- (all_songs vs per-family) at cast
                                    -- time. GearInfo's check_buffs adds
                                    -- them itself (line 298), so we
                                    -- need to feed the components, not
                                    -- the sum, to settings.Bards.
                                    -- Without this, we'd be reading
                                    -- live gear at recompute time —
                                    -- which is whatever the user
                                    -- swapped to AFTER the cast (e.g.
                                    -- aftercast/idle), often weaker.
                                    local snap = _ow_brd_per_family_song_plus
                                                 and _ow_brd_per_family_song_plus()
                                                 or {all=0}
                                    -- Apply the same plural→singular
                                    -- alias here as in the helper itself
                                    -- ('marches' → 'march') so the snap
                                    -- value lines up with what
                                    -- settings.Bards expects.
                                    local snap_alias = {marches = 'march'}
                                    local snap_fam_key = song_family
                                                         and (snap_alias[song_family] or song_family)
                                    local snap_family = (snap_fam_key
                                                         and snap[snap_fam_key])
                                                         or 0
                                    -- Snapshot Gjallarhorn-equipped at
                                    -- cast time. Honor March requires
                                    -- Marsyas, so during its cat=4 the
                                    -- range slot is NOT Gjall — but the
                                    -- user may swap back to Gjall after.
                                    -- Live gear at refresh time would
                                    -- mis-flag gjall=true and trigger
                                    -- GearInfo's int=4 subtraction
                                    -- (Buff_Processing.lua line 277),
                                    -- silently shaving Honor March's
                                    -- All_songs by 4.
                                    local snap_gjall = false
                                    do
                                        local _eq = windower.ffxi.get_items
                                                    and windower.ffxi.get_items('equipment')
                                        if _eq then
                                            local _bag = _eq.range_bag
                                            local _idx = _eq.range
                                            if _idx and _idx ~= 0 and _bag then
                                                local _id = windower.ffxi.get_items(_bag, _idx)
                                                if _id and _id.id and res.items
                                                   and res.items[_id.id]
                                                   and (res.items[_id.id].en == 'Gjallarhorn'
                                                     or res.items[_id.id].enl == 'Gjallarhorn') then
                                                    snap_gjall = true
                                                end
                                            end
                                        end
                                    end
                                    _ow_buff_sources = _ow_buff_sources or {}
                                    _ow_buff_sources[sbid] =
                                        _ow_buff_sources[sbid] or {}
                                    -- Replace any existing 'song_v2'
                                    -- record for this exact spell name
                                    -- (stacking different songs with
                                    -- same bid land as separate names).
                                    local found = false
                                    for _, s in ipairs(_ow_buff_sources[sbid]) do
                                        if s.src_kind == 'song_v2'
                                           and s.src_name == _sname then
                                            s.song_plus    = sp
                                            s.snap_all     = snap.all or 0
                                            s.snap_family  = snap_family
                                            s.snap_family_name = snap_fam_key
                                            s.snap_gjall   = snap_gjall
                                            s.actor_was_self = true
                                            s.cast_time = os.time()
                                            found = true
                                            break
                                        end
                                    end
                                    if not found then
                                        table.insert(_ow_buff_sources[sbid], {
                                            src_kind = 'song_v2',
                                            src_id   = song_probe_id,
                                            src_name = _sname,
                                            song_plus = sp,
                                            snap_all  = snap.all or 0,
                                            snap_family = snap_family,
                                            snap_family_name = snap_fam_key,
                                            snap_gjall = snap_gjall,
                                            actor_was_self = true,
                                            cast_time = os.time(),
                                        })
                                    end
                                end
                            end
                            if _ow_buff_debug then
                                -- (DURATION CAPTURE / gear_matches /
                                -- equipped dumps removed: duration math
                                -- is solid; the song-stat / song-write /
                                -- prune / inventory lines below are what
                                -- we need for tracing.)
                            end
                        end
                    end
                end

                -- Recognise as a song if we have it in our March table.
                -- Don't depend on spell_data.type matching 'BardSong' since
                -- the type string varies across Windower res versions.
                local is_song = PW_SONG_HASTE and PW_SONG_HASTE[song_probe_id]
                if is_song then
                    local song_id   = song_probe_id
                    local song_name = (spell_data and (spell_data.enl or spell_data.en))
                                      or ('song:'..song_id)
                    -- Marches sit on buff_id 214 ("March"), NOT 33 (Haste).
                    -- Verified via HasteInfo statics.lua. Always use 214
                    -- regardless of whatever res.spells.status says, since
                    -- that field can be wrong/missing for some songs.
                    local buff_id = PW_MARCH_BUFF_ID

                    -- Compute potency using HasteInfo's proven formula:
                    --   potency_pct = floor(potency_base * (1 + 0.1 * sp)) / 1024 * 100
                    -- where sp is gear March+ capped at song-specific cap.
                    local entry = PW_SONG_HASTE_TABLE[song_id]
                    local potency = nil
                    if entry then
                        local sp = 0
                        if act.actor_id == my_id then
                            -- Gear walker is authoritative. The
                            -- PW_SONG_GEAR_BY_NAME table maps every
                            -- known Song+/March+ piece (and all upgrade
                            -- tiers thereof) to their gear-derived
                            -- contribution.
                            sp = ow_song_plus_for_family('marches')
                        end
                        sp = math.min(sp, entry.cap)
                        local potency_1024 = entry.per_1024[sp] or entry.per_1024[0]
                        potency = potency_1024 / 1024 * 100
                        -- Soul Voice / Marcato — applied BEFORE the song
                        -- finishes casting, but Marcato is consumed by
                        -- the act of singing. So we must check at cast
                        -- BEGIN (cat=8), remember the multiplier, and
                        -- apply it again at cast COMPLETE (cat=4).
                        -- BG-wiki: SV = +100% (2.0x), Marcato = +50%
                        -- (1.5x). They don't stack; SV wins if both.
                        if act.actor_id == my_id then
                            local mult = 1
                            if cat == 8 then
                                -- Cast begin: capture buff state and stash.
                                local p = windower.ffxi.get_player()
                                local has_sv, has_mc = false, false
                                local buffs_str = ''
                                local active_buffs = {}
                                if p and p.buffs then
                                    local parts = {}
                                    for _, bid in ipairs(p.buffs) do
                                        parts[#parts+1] = tostring(bid)
                                        active_buffs[#active_buffs+1] = bid
                                        if bid == PW_BUFF_SOUL_VOICE then has_sv = true end
                                        if bid == PW_BUFF_MARCATO    then has_mc = true end
                                    end
                                    buffs_str = table.concat(parts, ',')
                                    if has_sv then mult = 2.0
                                    elseif has_mc then mult = 1.5 end
                                end
                                _ow_song_cast_mult = _ow_song_cast_mult or {}
                                _ow_song_cast_mult[song_id] = {mult = mult, ts = os.time()}

                                -- Duration snapshot: capture equipment +
                                -- active buffs, compute gear-aware final
                                -- duration, stash by spell NAME (not id;
                                -- buff_gain has the name handy via
                                -- res.spells[spell_id].en).
                                local spell_name = nil
                                if res and res.spells and res.spells[song_id] then
                                    spell_name = res.spells[song_id].en or
                                                  res.spells[song_id].name
                                end
                                if spell_name then
                                    local equip = _ow_equipment_snapshot()
                                    local song_class = _ow_classify_song(spell_name)
                                    local base = _ow_song_base_duration(song_class)
                                    local final = _ow_compute_song_duration(
                                        spell_name, equip, active_buffs,
                                        PW_BRD_JP_GIFTS or {})
                                    _ow_song_cast_dur = _ow_song_cast_dur or {}
                                    _ow_song_cast_dur[spell_name] = {
                                        base       = base,
                                        final      = final or base,
                                        equip      = equip,
                                        ts         = os.time(),
                                        song_class = song_class,
                                    }
                                    if _ow_cast_debug or _ow_buff_debug then
                                        -- (Diagnostic suppressed: the
                                        -- generic-songs path higher up
                                        -- already prints DURATION CAPTURE
                                        -- with the same numbers and a
                                        -- gear hit / equipped dump. This
                                        -- branch only runs for marches,
                                        -- and the data it would print
                                        -- duplicates the upper one.)
                                    end
                                end

                                if _ow_cast_debug then
                                    windower.add_to_chat(207, string.format(
                                        '[OW] cat=8 buff snapshot: SV_id=%s MC_id=%s active=[%s] sv=%s mc=%s mult=%.1f',
                                        tostring(PW_BUFF_SOUL_VOICE),
                                        tostring(PW_BUFF_MARCATO),
                                        buffs_str,
                                        tostring(has_sv), tostring(has_mc), mult))
                                end
                            else
                                -- Cast complete: pull the cat=8 capture.
                                _ow_song_cast_mult = _ow_song_cast_mult or {}
                                local saved = _ow_song_cast_mult[song_id]
                                if saved and (os.time() - (saved.ts or 0)) < 30 then
                                    mult = tonumber(saved.mult) or 1
                                else
                                    -- Fallback: SV may still be up, but
                                    -- Marcato is gone by now. Only check
                                    -- SV at this point.
                                    local p = windower.ffxi.get_player()
                                    if p and p.buffs then
                                        for _, bid in ipairs(p.buffs) do
                                            if bid == PW_BUFF_SOUL_VOICE then
                                                mult = 2.0
                                                break
                                            end
                                        end
                                    end
                                end
                                _ow_song_cast_mult[song_id] = nil  -- consume
                            end
                            if mult ~= 1 then
                                potency = potency * mult
                                windower.add_to_chat(207, string.format(
                                    '[OW] %s: %s active, potency x%.1f = %.2f%%',
                                    song_name,
                                    (mult >= 2.0) and 'Soul Voice' or 'Marcato',
                                    mult, potency))
                            end
                        end
                        windower.add_to_chat(207, string.format(
                            '[OW] %s: gear March+%d (cap %d), potency %.2f%%',
                            song_name, sp, entry.cap, potency))
                    end
                    if buff_id and potency then
                        _ow_buff_sources[buff_id] = _ow_buff_sources[buff_id] or {}
                        local found = false
                        for _, s in ipairs(_ow_buff_sources[buff_id]) do
                            if s.src_kind == 'song' and s.src_id == song_id then
                                -- Don't overwrite a higher-potency record
                                -- with a lower one. Cat=8 fires at cast
                                -- BEGIN (precast gear, often no song+)
                                -- while cat=4 fires at cast COMPLETE
                                -- (midcast gear with full song+). If
                                -- cat=8 wrote first with low potency,
                                -- cat=4 will replace it with the higher
                                -- value. The reverse (cat=4 then later
                                -- cat=8 from a duplicate event) won't
                                -- demote the good value.
                                if (tonumber(s.potency) or 0) <= potency then
                                    s.src_name = song_name
                                    s.potency  = potency
                                    s.actor_was_self = (act.actor_id == my_id)
                                    s.cast_time = os.time()
                                end
                                found = true
                                break
                            end
                        end
                        if not found then
                            table.insert(_ow_buff_sources[buff_id], {
                                src_kind = 'song',
                                src_id   = song_id,
                                src_name = song_name,
                                potency  = potency,
                                actor_was_self = (act.actor_id == my_id),
                                cast_time = os.time(),
                            })
                        end
                        _ow_save_buff_state()
                        if _ow_cast_debug then
                            windower.add_to_chat(207, string.format(
                                '[OW] song %s applied: buff_id=%d potency=%s',
                                song_name, buff_id, tostring(potency or '-')))
                        end
                        -- Diagnostic: list ALL march source records currently
                        -- stored. Shows whether previous casts of other songs
                        -- under the same buff_id are still present (and at
                        -- what potency). Useful for debugging "Honor missing"
                        -- scenarios.
                        do
                            local parts = {}
                            for _, s in ipairs(_ow_buff_sources[buff_id] or {}) do
                                parts[#parts+1] = string.format(
                                    '%s=%s%%',
                                    tostring(s.src_name or '?'),
                                    tostring(s.potency or '-'))
                            end
                            windower.add_to_chat(207, string.format(
                                '[OW] march sources now: [%s]',
                                table.concat(parts, ', ')))
                        end
                    end
                end
            end
            -- Haste spell: cat 4, spell id 57 (Haste) or 511 (Haste II).
            -- Each replaces the existing magic-haste entry (only one
            -- haste spell can be active on the same target).
            if cat == 4 and PW_HASTE_SPELL_POTENCY[act.param] then
                local spell_id = act.param
                local spell_name = (res.spells[spell_id] and res.spells[spell_id].en) or ('spell:'..spell_id)
                local potency = PW_HASTE_SPELL_POTENCY[spell_id]
                _ow_buff_sources[33] = _ow_buff_sources[33] or {}
                -- Remove any existing 'spell' entries (haste spell replaces).
                local kept = {}
                for _, s in ipairs(_ow_buff_sources[33]) do
                    if s.src_kind ~= 'spell' then kept[#kept+1] = s end
                end
                kept[#kept+1] = {
                    src_kind = 'spell',
                    src_id   = spell_id,
                    src_name = spell_name,
                    potency  = potency,
                }
                _ow_buff_sources[33] = kept
                _ow_save_buff_state()
                if _ow_cast_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW] %s applied: %.1f%% magic haste', spell_name, potency))
                end
            end
        end
    end

    -- ── Cast / ability begin: pulsing yellow indicator ──────────────────────
    if cat == CAT_SPELL_BEGIN then
        -- On spell-begin packets, the spell id lives in the per-target
        -- action's param field, NOT in act.param (which is something else
        -- like a cast-animation id). Prefer action.param; fall back to
        -- act.param for safety.
        local sid = (action and action.param) or act.param
        local sp = res.spells[sid]
        if sp then
            local sname = sp.en or sp.name or ('Spell #' .. tostring(sid))
            udp_cast:send(string.format('CAST_START|%d|spell|%s',
                actor_id or 0, sname))
            ow_events.emit('cast_begin', {
                actor_id = actor_id, kind = 'spell',
                spell_id = sid, name = sname,
            })
        elseif _ow_cast_debug then
            windower.add_to_chat(207, string.format(
                '[OW] CAST_START: no spell for sid=%s (act.param=%s, action.param=%s)',
                tostring(sid), tostring(act.param), tostring(action and action.param)))
        end
        return
    elseif cat == CAT_MOB_TP_BEGIN then
        -- Monster ability wind-up. Same pattern: ability id is likely in
        -- action.param for the target.
        local aid = (action and action.param) or act.param
        local ab = res.monster_abilities and res.monster_abilities[aid]
        local n_ = (ab and (ab.en or ab.name)) or ('Ability #' .. tostring(aid))
        udp_cast:send(string.format('CAST_START|%d|ability|%s', actor_id or 0, n_))
        ow_events.emit('cast_begin', {
            actor_id = actor_id, kind = 'ability',
            ability_id = aid, name = n_,
        })
        return
    end

    -- ── Cast / ability finish: red text, then after processing, debuff check ─
    if cat == CAT_SPELL_FINISH then
        if msg_id and MSG_INTERRUPTED[msg_id] then
            udp_cast:send(string.format('CAST_CANCEL|%d', actor_id or 0))
            ow_events.emit('cast_interrupt', {
                actor_id = actor_id, kind = 'spell',
            })
        else
            local sp = res.spells[act.param]
            if sp then
                local sname = sp.en or sp.name or ('Spell #' .. tostring(act.param))
                udp_cast:send(string.format('CAST_DONE|%d|spell|%s',
                    actor_id or 0, sname))
                ow_events.emit('cast_complete', {
                    actor_id = actor_id, kind = 'spell',
                    spell_id = act.param, name = sname,
                    target_id = tgt and tgt.id, msg_id = msg_id,
                })
            end
        end
    elseif cat == CAT_MOB_TP_FINISH then
        local ab = res.monster_abilities and res.monster_abilities[act.param]
        local n_ = (ab and (ab.en or ab.name)) or ('Ability #' .. tostring(act.param))
        udp_cast:send(string.format('CAST_DONE|%d|ability|%s', actor_id or 0, n_))
        ow_events.emit('cast_complete', {
            actor_id = actor_id, kind = 'ability',
            ability_id = act.param, name = n_,
            target_id = tgt and tgt.id,
        })
    end

    -- ── Debuff tracking (unchanged, only for spell-finish category) ─────────
    if cat ~= CAT_SPELL_FINISH then return end
    if not msg_id then return end

    local target_id = tgt.id
    local spell_id  = act.param
    if not spell_id or not res.spells[spell_id] then return end
    local spell = res.spells[spell_id]

    local effect_id, duration
    if MSG_DAMAGE_LAND[msg_id] then
        effect_id = spell.status
        duration  = spell.duration or 0
    elseif MSG_ENFEEBLE_LAND[msg_id] then
        effect_id = action.param
        duration  = spell.duration or 0
    end

    if not effect_id or effect_id == 0 then return end

    udp_status:send(string.format('APPLY|%d|%d|%d|%d|%d|0',
        target_id, spell_id, effect_id, duration, actor_id or 0))
    ow_events.emit('buff_gain', {
        target_id = target_id,
        buff_id   = effect_id,
        spell_id  = spell_id,
        duration  = duration,
        actor_id  = actor_id or 0,
    })
end

local function handle_incoming_action_message(arr)
    if MSG_DEATH[arr.message_id] then
        udp_status:send(string.format('CLEAR|%d', arr.target_id))
    elseif MSG_WEAR_OFF[arr.message_id] then
        udp_status:send(string.format('REMOVE|%d|%d', arr.target_id, arr.param_1))
        ow_events.emit('buff_loss', {
            target_id = arr.target_id,
            buff_id   = arr.param_1,
        })
        -- Also: when a buff wears off ON US, remove the corresponding
        -- source record(s) from _ow_buff_sources so they stop contributing
        -- haste/etc. For shared-bucket buffs like March (id 214), only
        -- the OLDEST source in the bucket actually wore off — newer
        -- songs in the same bucket are still active.
        local me = windower.ffxi.get_player()
        local my_id = me and me.id or 0
        if arr.target_id == my_id and _ow_buff_sources then
            local bid = arr.param_1
            local srcs = _ow_buff_sources[bid]
            if type(srcs) == 'table' and #srcs > 0 then
                if #srcs == 1 then
                    -- Only one source, just nuke the bucket
                    _ow_buff_sources[bid] = nil
                else
                    -- Multiple songs share this bucket. The one that
                    -- expires first is the oldest cast_time (assuming
                    -- similar durations). Remove just that one record.
                    local oldest_idx = 1
                    local oldest_ts = srcs[1].cast_time or 0
                    for i = 2, #srcs do
                        local ts = srcs[i].cast_time or 0
                        if ts < oldest_ts then
                            oldest_ts = ts
                            oldest_idx = i
                        end
                    end
                    table.remove(srcs, oldest_idx)
                    if #srcs == 0 then
                        _ow_buff_sources[bid] = nil
                    end
                end
                pcall(_ow_save_buff_state)
            end
        end
    end
end

ow_safe_register('incoming chunk', function(id, data)
    if id == 0x028 then
        local ok, parsed = pcall(windower.packets.parse_action, data)
        if ok and parsed then
            local ok2, err2 = pcall(handle_incoming_action, parsed)
            -- Surface action-handler errors when buff_debug is on. The
            -- old code silently swallowed them via pcall, which was great
            -- for resilience but terrible for diagnosis when a new code
            -- path throws and you can't tell why your debug line never
            -- prints. Toggle buffdebug to see; never bothers normal users.
            if not ok2 and _ow_buff_debug then
                windower.add_to_chat(123, string.format(
                    '[OW] action handler error: %s', tostring(err2)))
            end
            -- Forward to GearInfo's captured action handler. Its
            -- Action_Processing.lua would normally register a 'action'
            -- event itself; our _loader.lua intercepts that and stashes
            -- the function as _gi.captured_action_handler. Call it here
            -- so GearInfo's process_action runs — that's what sets
            -- member_table[actor].Last_Spell for songs/spells in
            -- spells_to_watch, which Packet_parsing.lua's 0x063 handler
            -- reads when populating buff.full_name and buff.Caster.
            -- Without this, song buffs land in _ExtraData.player.buff_details
            -- with full_name=name (the bucket name "Minuet") and
            -- Caster=nil — both of which break check_buffs's song match.
            if _gi and _gi.captured_action_handler then
                local ok_gi, err_gi = pcall(_gi.captured_action_handler, parsed)
                if not ok_gi and _ow_buff_debug then
                    windower.add_to_chat(123, string.format(
                        '[OW] _gi action handler error: %s',
                        tostring(err_gi)))
                end
            end
        end
    elseif id == 0x029 then
        -- Manually unpack bytes to avoid depending on string:unpack, which
        -- is provided by Windower's 'packets' library but may not be
        -- available depending on load order / environment.
        -- Windower packet offsets are 1-indexed starting from the packet
        -- header, matching Lua's 1-indexed string.byte, so we pass the
        -- offset directly.
        local function u32(s, offset)
            local b1 = s:byte(offset)     or 0
            local b2 = s:byte(offset + 1) or 0
            local b3 = s:byte(offset + 2) or 0
            local b4 = s:byte(offset + 3) or 0
            return b1 + b2*256 + b3*65536 + b4*16777216
        end
        local function u16(s, offset)
            local b1 = s:byte(offset)     or 0
            local b2 = s:byte(offset + 1) or 0
            return b1 + b2*256
        end
        local arr = {
            target_id  = u32(data, 0x09),
            param_1    = u32(data, 0x0D),
            message_id = u16(data, 0x19) % 32768,
        }
        pcall(handle_incoming_action_message, arr)
    elseif id == 0x061 then
        -- Char Stats packet. Use Windower's packets.parse so we get the
        -- documented field names from fields.lua instead of relying on
        -- raw byte offsets (which differ between GearInfo's BSD-2 fork
        -- and the canonical Windower definitions).
        local ok, p = pcall(packets.parse, 'incoming', data)
        if ok and p then
            _ow_base_stats = {
                str    = tonumber(p['Base STR']) or 0,
                dex    = tonumber(p['Base DEX']) or 0,
                vit    = tonumber(p['Base VIT']) or 0,
                agi    = tonumber(p['Base AGI']) or 0,
                ['int']= tonumber(p['Base INT']) or 0,
                mnd    = tonumber(p['Base MND']) or 0,
                chr    = tonumber(p['Base CHR']) or 0,
            }
            if _ow_cast_debug then
                windower.add_to_chat(207, string.format(
                    '[OW] base stats updated: STR=%d DEX=%d VIT=%d AGI=%d INT=%d MND=%d CHR=%d',
                    _ow_base_stats.str, _ow_base_stats.dex,
                    _ow_base_stats.vit, _ow_base_stats.agi,
                    _ow_base_stats['int'], _ow_base_stats.mnd,
                    _ow_base_stats.chr))
            end
        end
    elseif id == 0x063 then
        -- 0x063 sub-0x09 carries the per-slot buff IDs and per-slot
        -- expiry timestamps. Rather than parse the packet ourselves
        -- (the byte offsets and timer math have shifted across FFXI
        -- updates and our own attempts at the gearswap formula gave
        -- wonky values), we read GearInfo's already-decoded result.
        --
        -- GearInfo is a peer addon that runs alongside us; its
        -- parse.i[0x063] handler is invoked just below in the GearInfo
        -- forwarding block. After it runs, _ExtraData.player.buff_details
        -- is a 1-based array of {id, name, time, ...} where time is a
        -- unix-epoch expiry timestamp (numeric, double-precision).
        --
        -- We snapshot _ExtraData into our own slot maps right after the
        -- forwarding pcall (see below). This block remains for
        -- recognition — the actual work happens at the read-back step.
    end

    -- ── Forward stat-relevant packets to GearInfo backend ─────────────
    -- GearInfo's parse.i[id] handlers populate `player.stats` (0x061),
    -- `player.skills` + run get_player_skill_in_gear (0x062), and
    -- `_ExtraData.player.buff_details` (0x063 type 9). These are the
    -- inputs the GearInfo formula path reads. Without this hand-off
    -- the GearInfo backend would be running on stale data.
    --
    -- We pcall in case GearInfo's handler hits an edge case (e.g. an
    -- unexpected packet shape on a Windower update); a thrown error
    -- here must NOT crash OmniWatch's other packet processing.
    if _gi and _gi.parse and _gi.parse.i and _gi.parse.i[id] then
        local ok_gi, err_gi = pcall(_gi.parse.i[id], data)
        if not ok_gi and _ow_cast_debug then
            windower.add_to_chat(123, string.format(
                '[OW] _gi.parse.i[0x%03X] error: %s', id, tostring(err_gi)))
        end
    end

    -- After GearInfo has parsed 0x063 sub-9, mirror the buff IDs into
    -- our slot maps. We deliberately DO NOT use the timer field — both
    -- our own packet math and GearInfo's give wonky values on current
    -- FFXI (rem=-214,748,054.9s, suggesting an integer-overflow / epoch
    -- shift somewhere we can't easily diagnose). Instead, we'll mark
    -- expires_at as nil here and let the reconcile loop compute durations
    -- from buff_gain events (which fire on each cast and carry the
    -- gear-aware spell.duration). See the loop in the timers emit block.
    -- ── 0x063 sub-9 timestamp diagnostic ────────────────────────────────
    -- Log the raw and decoded buff expiry data from the packet so we can
    -- empirically determine the right epoch offset for current FFXI.
    -- The classic GearSwap formula is:
    --   t = data:unpack('I', i*4 + 0x45) / 60 + 501079520 + 1009810800
    -- but our previous attempts gave nonsensical durations like
    -- rem=-214,748,054.9s (close to int32 overflow / 10), suggesting the
    -- formula is wrong on current FFXI.
    --
    -- Toggle with //ow buffts on — when enabled, prints up to 3 buff
    -- timestamp samples per packet, comparing 3 epoch interpretations.
    -- The one that gives sensible "seconds remaining" values (positive
    -- and reasonable, e.g. 0-3600) is the right formula.
    if id == 0x063 and (data:byte(0x05) or 0) == 0x09 and _ow_buffts_debug then
        local sample_count = 0
        local now_unix = os.time()
        for i = 1, 32 do
            -- Buff IDs at offset 7 + i*2 (16-bit unsigned LE).
            local b1_id = data:byte(i*2 + 7 + 0)
            local b2_id = data:byte(i*2 + 7 + 1)
            if not b1_id then break end
            local buff_id = (b1_id or 0) + (b2_id or 0) * 256
            -- Skip empty slots.
            if buff_id ~= 0 and buff_id ~= 255 and buff_id ~= 0xFFFF then
                -- Read the 32-bit timestamp value byte-by-byte, building
                -- an UNSIGNED integer manually. Lua 5.1's data:unpack('I')
                -- returns a SIGNED int that wraps when the high bit is
                -- set — which is exactly when FFXI's encoded values land,
                -- producing nonsensical negative results. Manual reads
                -- via data:byte() and arithmetic stay in float64 land
                -- which represents up to 2^53 exactly, no sign issues.
                local off = i*4 + 0x45
                local r1 = data:byte(off + 0) or 0
                local r2 = data:byte(off + 1) or 0
                local r3 = data:byte(off + 2) or 0
                local r4 = data:byte(off + 3) or 0
                local raw_uint = r1 + r2 * 256 + r3 * 65536 + r4 * 16777216
                -- Try the classic formula and a few alternates.
                local t_classic = raw_uint / 60 + 501079520 + 1009810800
                local t_direct  = raw_uint
                local t_no_div  = raw_uint + 501079520 + 1009810800
                -- HYPOTHESIS v2 (2026): empirical reverse-math from
                -- Double-Up Chance (exactly 45s duration, no variability)
                -- pins the FFXI epoch at 1,725,638,684.
                -- Formula: expiry_unix = raw/60 + 1725638684.
                local t_new     = raw_uint / 60 + 1725638684
                local d_classic = t_classic - now_unix
                local d_direct  = t_direct - now_unix
                local d_no_div  = t_no_div - now_unix
                local d_new     = t_new - now_unix
                local bname = (res.buffs[buff_id] and res.buffs[buff_id].en)
                              or ('id=' .. buff_id)
                windower.add_to_chat(207, string.format(
                    '[OW buffts] i=%d bid=%d (%s) raw=%u new=%+ds classic=%+ds direct=%+ds no_div=%+ds',
                    i, buff_id, bname, raw_uint,
                    math.floor(d_new),
                    math.floor(d_classic), math.floor(d_direct),
                    math.floor(d_no_div)))
                sample_count = sample_count + 1
                if sample_count >= 3 then break end
            end
        end
    end

    if id == 0x063 and (data:byte(0x05) or 0) == 0x09 then
        local now_clock = os.clock()
        local now_unix  = os.time()
        local bd = nil
        if _G._ExtraData and _G._ExtraData.player then
            bd = _G._ExtraData.player.buff_details
        end
        _ow_buff_slots = {}
        _ow_buff_slot_expires_at = {}

        -- ── Server-truth expiry timestamps ──────────────────────────────
        -- Read 0x063 sub-9 directly to get authoritative buff expiry
        -- times for each slot. The packet carries 32 (buff_id, raw_ts)
        -- pairs at fixed offsets:
        --   buff_id: 16-bit LE at offset 7 + i*2 (i = 1..32)
        --   raw_ts:  32-bit LE at offset 0x45 + i*4
        --
        -- Formula (verified empirically against in-game timers May 2026):
        --   expiry_unix = raw_ts / 60 + 1725638684
        --
        -- The constant 1,725,638,684 is the current FFXI server epoch
        -- (≈ Sept 2024 update). The /60 reflects FFXI's 60Hz tick.
        -- Anchor: Double-Up Chance is exactly 45 seconds. From a
        -- captured raw value + os.time() at capture, the epoch can be
        -- derived directly — see the //ow buffts diagnostic.
        --
        -- We convert expiry_unix → expiry as os.clock()-equivalent and
        -- store in _ow_buff_slot_expires_at[i-1]. The slot numbering is
        -- 0-indexed downstream, matching get_player().buffs which uses
        -- 0..31. The packet loop is 1-indexed for byte-offset clarity.
        --
        -- Slots with buff_id = 0 or 255 are empty (no buff) — we skip.
        local FFXI_EPOCH_2026 = 1725638684
        for i = 1, 32 do
            local b1 = data:byte(i*2 + 7 + 0) or 0
            local b2 = data:byte(i*2 + 7 + 1) or 0
            local buff_id = b1 + b2 * 256
            if buff_id ~= 0 and buff_id ~= 255 and buff_id ~= 0xFFFF then
                local off = i*4 + 0x45
                local r1 = data:byte(off + 0) or 0
                local r2 = data:byte(off + 1) or 0
                local r3 = data:byte(off + 2) or 0
                local r4 = data:byte(off + 3) or 0
                local raw_uint = r1 + r2 * 256 + r3 * 65536 + r4 * 16777216
                local expiry_unix = raw_uint / 60 + FFXI_EPOCH_2026
                local secs_remaining = expiry_unix - now_unix
                -- Convert to os.clock() basis since the rest of the
                -- buff-timer system uses monotonic clock, not wall time.
                local expires_at_clock = now_clock + secs_remaining
                -- Only record sane values: positive remaining, reasonable
                -- upper bound (a week — well above any real buff). This
                -- defends against single corrupted packets without losing
                -- the long-duration cases (Reraise = 1hr, food = 3hr).
                if secs_remaining > 0 and secs_remaining < 604800 then
                    -- Slot index is 0-based downstream (player.buffs is
                    -- 0..31); packet loop is 1-based for byte clarity.
                    _ow_buff_slot_expires_at[i - 1] = expires_at_clock
                end
            end
        end
        -- Identity-based tracking across packets. Each song instance is
        -- uniquely identified by (bid, gi_time) — gi_time is the server-
        -- assigned gain-instant timestamp, a fingerprint that survives
        -- the song moving between slot indices. The server may shuffle
        -- which slot index holds which song from packet to packet
        -- (e.g., when Minne II is cast on top of Minne I at slot cap,
        -- Minne II might land in slot 0 and push Minne I to slot 1, or
        -- vice versa). A pure slot→slot diff would mis-attribute.
        --
        -- prev_by_bid_gi[bid][gi] = slot_in_prev_packet
        -- This packet: for each (bid, gi) entry we observe, look up
        -- the prev slot that held it. If found, copy the timer entry
        -- (name, source, started_at, expires_at) from the old slot to
        -- the new slot — the song hasn't changed, just relocated.
        -- If not found, the song is brand-new this packet → leave the
        -- new slot's timer entry empty so reconcile binds it from
        -- pending_meta.
        local prev_by_bid_gi = _ow_buff_prev_by_bid_gi or {}
        _ow_buff_prev_by_bid_gi = {}
        -- Per-packet set of (bid, gi) pairs we observed. Used at end of
        -- the loop to drop stale _ow_buff_assoc entries (songs that
        -- ended this packet — buff slot empty, no longer in bd).
        local _assoc_seen = {}
        local new_timers = {}
        local prev_timers = _ow_buff_timers or {}
        -- Diagnostic: count bind decisions across the loop
        local _id_moved_count = 0   -- songs in prev that moved slot
        local _id_kept_count  = 0   -- songs in prev that stayed in same slot
        local _id_fresh_count = 0   -- songs not in prev (new casts)
        -- Helper: find a prev (bid, time) entry within tolerance.
        -- entry.time is a stable-ish timestamp per song instance, but
        -- it drifts slightly between packets (~0.05s observed). A song
        -- instance is identified by being within IDENTITY_TOL of the
        -- previous packet's time for the same bid. New casts have
        -- entry.time differing by seconds (the cast-time gap), well
        -- outside the tolerance.
        local IDENTITY_TOL = 2.0
        local function _find_prev_match(bid, gi)
            local list = prev_by_bid_gi[bid]
            if not list then return nil end
            -- list is { [gi_value] = slot_in_prev_packet }; iterate.
            local best_slot, best_diff = nil, math.huge
            for prev_gi, prev_slot in pairs(list) do
                local diff = math.abs(prev_gi - gi)
                if diff < IDENTITY_TOL and diff < best_diff then
                    best_slot = prev_slot
                    best_diff = diff
                end
            end
            return best_slot
        end
        -- Same tolerance match for the (full_name, Caster) stash. Returns
        -- the matching gi key (so the caller can drop or refresh the
        -- entry) and the stashed assoc table, or nil if no match.
        local function _find_assoc_match(bid, gi)
            local list = _ow_buff_assoc[bid]
            if not list then return nil, nil end
            local best_gi, best_assoc, best_diff = nil, nil, math.huge
            for stash_gi, stash_assoc in pairs(list) do
                local diff = math.abs(stash_gi - gi)
                if diff < IDENTITY_TOL and diff < best_diff then
                    best_gi     = stash_gi
                    best_assoc  = stash_assoc
                    best_diff   = diff
                end
            end
            return best_gi, best_assoc
        end
        -- Real 0x063 just arrived: drop any synthetic-slot entries in
        -- _ow_buff_timers so the reconcile loop rebuilds them from the
        -- real slots. Without this, a buff would have TWO timer entries
        -- (one at slot=101 from the me.buffs fallback, one at slot=0
        -- from this packet) and the panel would render duplicates.
        if _ow_buff_timers then
            for s, _ in pairs(_ow_buff_timers) do
                if s >= 100 then _ow_buff_timers[s] = nil end
            end
        end
        local _dbg_count = 0
        if type(bd) == 'table' then
            -- _ExtraData.player.buff_details is keyed by 1-based slot
            -- (gearswap convention). We use 0-based slots internally.
            for i = 1, 32 do
                local entry = bd[i]
                if entry and entry.id and entry.id ~= 0
                   and entry.id ~= 255 and entry.id ~= 0xFFFF then
                    local slot = i - 1
                    _ow_buff_slots[slot] = entry.id
                    local gi = entry.time or 0
                    -- Index this (bid, gi) for next packet's diff.
                    _ow_buff_prev_by_bid_gi[entry.id] = _ow_buff_prev_by_bid_gi[entry.id] or {}
                    _ow_buff_prev_by_bid_gi[entry.id][gi] = slot
                    -- ── Song attribution (full_name / Caster) ───────────
                    -- General rule: don't trust GearInfo's full_name and
                    -- Caster writes on entry. They come from a single
                    -- per-caster Last_Spell slot which can't disambiguate
                    -- when two buffs share a buff_id (Carols all have
                    -- bid=216 in res.buffs; Rolls and a few others have
                    -- the same shape). Instead, attribute from our own
                    -- per-cast pending_meta:
                    --
                    --   * At cast complete (cat=4 + buff_gain), PEND-PUSH
                    --     fires and stashes _ow_buff_pending_meta[bid] =
                    --     {name=spell_en, caster=actor_name, ts, ...}.
                    --   * Here, when a (bid, gi) pair appears that's
                    --     FRESH this packet (no prior-packet match) AND
                    --     pending_meta[bid] is fresh (<5s old), bind:
                    --       _ow_buff_assoc[bid][gi] = {full_name, Caster}.
                    --   * For every (bid, gi) — fresh or kept — that has
                    --     a stashed assoc entry, force-write entry.full_name
                    --     and entry.Caster from the assoc. This OVERRIDES
                    --     GearInfo's writes (which may be wrong for shared-
                    --     bid families, and right but redundant for unique-
                    --     bid families like Marches/Minuets).
                    --
                    -- Why this works for tier-stacking:
                    --   - Cast Fire Carol II → pending_meta[216] = {Fire
                    --     Carol II, wormfood}. 0x063 lands with new (216,
                    --     gi_α). Fresh. Bind assoc[216][gi_α] = {Fire
                    --     Carol II, wormfood}. Apply.
                    --   - Cast Fire Carol I → pending_meta[216] OVERWRITES
                    --     to {Fire Carol, wormfood}. 0x063 lands with
                    --     existing (216, gi_α) (kept) AND new (216, gi_β)
                    --     (fresh). Slot α has assoc — force-write Fire
                    --     Carol II. Slot β is fresh — bind assoc[216][gi_β]
                    --     from CURRENT pending_meta = Fire Carol. Both
                    --     correct.
                    --
                    -- Edge: rapid double-cast within a single packet (both
                    -- new (bid, gi) fresh this packet, but pending_meta
                    -- has only one entry). Mitigation deferred — Carol
                    -- cast time is 5+ seconds, well past 0x063 cadence.
                    do
                        local prev_slot = _find_prev_match(entry.id, gi)
                        local pm = (_ow_buff_pending_meta or {})[entry.id]
                        local pm_fresh = pm and (os.clock() - (pm.ts or 0)) < 5
                                         or false
                        local existing_gi, existing_assoc = nil, nil
                        if prev_slot ~= nil then
                            -- Kept/moved slot — tolerance match against
                            -- our stash is valid since gi may have
                            -- drifted ~0.05s between packets.
                            existing_gi, existing_assoc =
                                _find_assoc_match(entry.id, gi)
                        end
                        -- For fresh slots, deliberately DO NOT use the
                        -- tolerance _find_assoc_match. A genuinely-fresh
                        -- slot's gi could happen to land within IDENTITY_TOL
                        -- of another slot's stashed gi (rapid sequential
                        -- casts of the same bid), and we'd mis-attribute
                        -- the new buff to the old stash. Fresh slots get
                        -- attribution only via pending_meta below.
                        if prev_slot == nil and pm_fresh then
                            -- Fresh slot, fresh meta: bind to the most
                            -- recent cast. Strip the '~' prefix that
                            -- PEND-PUSH adds for other-caster buffs —
                            -- that's a timer-display convention, not
                            -- part of the song's name as Bard_Songs
                            -- knows it.
                            local nm = pm.name or ''
                            if nm:sub(1, 1) == '~' then
                                nm = nm:sub(2)
                            end
                            local cs = pm.caster
                            _ow_buff_assoc[entry.id] = _ow_buff_assoc[entry.id] or {}
                            _ow_buff_assoc[entry.id][gi] = {
                                full_name = nm,
                                Caster    = cs,
                            }
                            if _ow_buff_debug then
                                windower.add_to_chat(207, string.format(
                                    '[OW] assoc bind bid=%d slot=%d gi=%s: full=%s Caster=%s',
                                    entry.id, slot, tostring(gi),
                                    tostring(nm), tostring(cs)))
                            end
                            existing_assoc = _ow_buff_assoc[entry.id][gi]
                            existing_gi    = gi
                        end
                        if existing_assoc then
                            -- Force-write attribution onto the entry.
                            -- This overrides GearInfo's full_name/Caster
                            -- writes — ours is keyed on (bid, gi) so it
                            -- handles shared-bid stacking correctly.
                            if existing_assoc.full_name then
                                entry.full_name = existing_assoc.full_name
                            end
                            if existing_assoc.Caster then
                                entry.Caster = existing_assoc.Caster
                            end
                            -- Refresh stash key to current gi so future
                            -- tolerance matches stay centered on the
                            -- latest observed gi.
                            if existing_gi ~= gi then
                                _ow_buff_assoc[entry.id][existing_gi] = nil
                                _ow_buff_assoc[entry.id][gi] = existing_assoc
                            end
                        end
                        -- Mark seen for end-of-packet sweep.
                        _assoc_seen[entry.id] = _assoc_seen[entry.id] or {}
                        _assoc_seen[entry.id][gi] = true
                    end
                    -- ── end song attribution ────────────────────────────
                    -- Identity match against previous packet WITH
                    -- tolerance — entry.time drifts slightly between
                    -- packets even for the same song instance (we've
                    -- seen 0.05s shifts), so we match within ±2s.
                    local prev_slot = _find_prev_match(entry.id, gi)
                    if prev_slot ~= nil and prev_timers[prev_slot] then
                        -- Copy the prev entry, but update its .slot
                        -- field to the new slot. Other code reads
                        -- entry.slot for stable identification.
                        local copy = {}
                        for k, v in pairs(prev_timers[prev_slot]) do
                            copy[k] = v
                        end
                        copy.slot = slot
                        new_timers[slot] = copy
                        if prev_slot ~= slot then
                            _id_moved_count = _id_moved_count + 1
                            if _ow_buff_debug then
                                windower.add_to_chat(207, string.format(
                                    '[OW] song moved bid=%d gi=%.0f slot %d→%d (kept name=%s)',
                                    entry.id, gi, prev_slot, slot,
                                    tostring(prev_timers[prev_slot].name)))
                            end
                        else
                            _id_kept_count = _id_kept_count + 1
                        end
                    else
                        _id_fresh_count = _id_fresh_count + 1
                        if _ow_buff_debug then
                            windower.add_to_chat(207, string.format(
                                '[OW] song fresh bid=%d gi=%.0f slot=%d (no prev match)',
                                entry.id, gi, slot))
                        end
                    end
                    -- Do NOT use entry.time as expires_at; it's been
                    -- giving wonky values for that purpose. Leave
                    -- expires_at nil so the reconcile loop falls back
                    -- to pending_meta when needed.
                    _dbg_count = _dbg_count + 1
                end
            end
            -- Commit: replace _ow_buff_timers with new_timers. Slots
            -- whose songs ended (no longer in this packet) get dropped
            -- automatically since new_timers only has entries for
            -- songs we observed. Songs we observed but didn't have a
            -- prev entry for stay absent from new_timers — reconcile
            -- will create them fresh from pending_meta.
            _ow_buff_timers = new_timers
            -- Drop _ow_buff_assoc entries whose (bid, gi) wasn't observed
            -- this packet AND whose bid has no observations within
            -- tolerance either. The simple version: any (bid, gi) that
            -- isn't an exact key in _assoc_seen[bid] AND isn't within
            -- IDENTITY_TOL of one is gone — its song slot ended. Keeping
            -- stale entries forever isn't catastrophic (gi values for new
            -- casts differ by seconds, well outside tolerance) but it
            -- grows the table unboundedly, so sweep each packet.
            for bid, gi_map in pairs(_ow_buff_assoc) do
                local seen_gi_map = _assoc_seen[bid]
                if not seen_gi_map then
                    _ow_buff_assoc[bid] = nil
                else
                    for stash_gi, _ in pairs(gi_map) do
                        local keep = false
                        for seen_gi, _ in pairs(seen_gi_map) do
                            if math.abs(stash_gi - seen_gi) < IDENTITY_TOL then
                                keep = true
                                break
                            end
                        end
                        if not keep then
                            gi_map[stash_gi] = nil
                        end
                    end
                    if next(gi_map) == nil then
                        _ow_buff_assoc[bid] = nil
                    end
                end
            end
            -- Per-packet summary. Gated behind _ow_buff_debug since
            -- this was diagnostic-only — useful when we were debugging
            -- the song-attribution identity-tracker, but noisy for
            -- normal play (fires every time anyone in range casts).
            if _ow_buff_debug and (_id_fresh_count > 0 or _id_moved_count > 0) then
                windower.add_to_chat(207, string.format(
                    '[OW] 0x063 ident: kept=%d moved=%d fresh=%d total=%d',
                    _id_kept_count, _id_moved_count,
                    _id_fresh_count, _dbg_count))
            end
            -- Per-slot bd trace. Prints the FINAL state after the
            -- attribution write-back, so what shows here is what
            -- check_buffs will see. Gated on _ow_buff_debug.
            if _ow_buff_debug then
                for i = 1, 32 do
                    local entry = bd[i]
                    if entry and entry.id and entry.id ~= 0
                       and entry.id ~= 255 and entry.id ~= 0xFFFF then
                        windower.add_to_chat(207, string.format(
                            '[OW] bd[%d] bid=%s gi=%s name=%s full=%s Caster=%s',
                            i - 1,
                            tostring(entry.id),
                            tostring(entry.time),
                            tostring(entry.name),
                            tostring(entry.full_name),
                            tostring(entry.Caster)))
                    end
                end
            end
        end
        if _ow_buff_debug then
            if _dbg_count ~= (_ow_last_buff_dbg or -1) then
                windower.add_to_chat(207, string.format(
                    '[OW] _ExtraData buff snapshot: %d buffs (now_unix=%d)',
                    _dbg_count, now_unix))
                _ow_last_buff_dbg = _dbg_count
                for s, b in pairs(_ow_buff_slots) do
                    -- Print the entry.time field for diagnostic; the
                    -- math is bad but the relative trend is stable.
                    local entry_time = bd and bd[s+1] and bd[s+1].time or 0
                    windower.add_to_chat(207, string.format(
                        '[OW]   slot=%d bid=%d gi_time=%.0f',
                        s, b, entry_time))
                end
            end
        end
    end

    -- Flag inventory snapshot dirty on inv-related packets so the sim
    -- window's gear dropdowns refresh after items are used / moved /
    -- swapped.
    --   0x01D = item count update
    --   0x01E = item details (item finish)
    --   0x01F = item updates
    --   0x020 = item assigned to slot
    -- Sim's inventory sender is rate-limited so flagging on every one
    -- of these is fine.
    if id == 0x01D or id == 0x01E or id == 0x01F or id == 0x020 then
        if _ow_mark_inv_dirty then _ow_mark_inv_dirty() end
    end
end)

-- Clear everything on zone change.
-- ── Outgoing food snoop ─────────────────────────────────────────────────
-- Packet 0x037 fires when the player uses an item from their inventory.
-- We check if it's a food item (res.items[id].type == 7) and if so parse
-- its description into _ow_food_stats. Cleared on zone change or when
-- the food buff (id 251 typically) drops.
_ow_food_stats   = {}     -- key → numeric bonus (e.g. 'accuracy' → 6)
_ow_food_item_id = 0      -- last food item id we recorded

-- ── Recast panel config ───────────────────────────────────────────────────
-- Hand-edit OW_RECAST_CONFIG below to control which spells/abilities show
-- up in the recast panel and how they're ordered. Reload OmniWatch after
-- changes (//lua r omniwatch).
--
-- blacklist:  set of names (case-sensitive English) that will NEVER be
--             reported to the panel. Useful for hiding things you don't
--             care about cycling (Provoke, basic cures, etc).
-- sort_order: 'asc'  → closest-to-ready leftmost (default)
--             'desc' → longest-wait leftmost
--             'cast' → most-recently-used leftmost (preserves rotation order)
-- min_seconds: hide entries below this remaining time. 0 = show everything.
--              Useful to hide the tail end of long counts you'd already see.
-- show_spells:    set false to hide all spell recasts.
-- show_abilities: set false to hide all ability recasts.
local OW_RECAST_CONFIG = {
    sort_order  = 'asc',
    min_seconds = 0,
    show_spells     = true,
    show_abilities  = true,
    blacklist = {
        -- Common entries you might want to hide. Add more as needed.
        -- Use the EXACT name as it appears in res.spells / res.job_abilities.
        -- Examples (commented out — uncomment to enable):
        -- ['Provoke']  = true,
        -- ['Cure']     = true,
        -- ['Cure II']  = true,
        -- ['Cure III'] = true,
        -- ['Dia']      = true,
        -- ['Banish']   = true,
    },
}

-- Cast-order tracking. _ow_recast_last_cast_at[kind:recast_id] = os.clock()
-- of the most recent cast by the player. Used when sort_order = 'cast'
-- so python can render entries in the order the player triggered them.
-- _ow_recast_last_name[kind:recast_id] = the english name of that last
-- cast — used so e.g. all 31 Phantom Rolls share one recast slot but the
-- panel still shows the actual roll name you used (Bolter's, Tactician's,
-- whatever) rather than a generic label.
-- Subscribed to cast_complete events fired by the central action handler.
_ow_recast_last_cast_at = {}
_ow_recast_last_name    = {}
ow_events.on('cast_complete', function(data)
    if not data then return end
    local me = windower.ffxi.get_player()
    -- Only record OUR casts. Ignore other players / mobs.
    if not (me and me.id and data.actor_id == me.id) then return end
    if data.kind == 'spell' and data.spell_id then
        local sp = res.spells and res.spells[data.spell_id]
        local rid = sp and sp.recast_id
        if rid then
            _ow_recast_last_cast_at['spell:'..rid] = os.clock()
            _ow_recast_last_name['spell:'..rid] =
                sp.en or sp.name or ('Spell #'..data.spell_id)
        end
    elseif data.kind == 'ability' and data.ability_id then
        local ab = res.job_abilities and res.job_abilities[data.ability_id]
        local rid = ab and ab.recast_id
        if rid then
            _ow_recast_last_cast_at['ability:'..rid] = os.clock()
            _ow_recast_last_name['ability:'..rid] =
                ab.en or ab.name or ('Ability #'..data.ability_id)
        end
    end
end)

-- ── Food durations (minutes) ──────────────────────────────────────────────
-- Item id → duration in minutes. The game doesn't expose this in any
-- queryable way — the description text mentions duration in flavor text
-- but parsing it reliably from prose is a mess. Hardcoded table covers
-- the meta items most players use. Anything not in the table falls back
-- to OW_FOOD_DEFAULT_MIN. Future BG-wiki scrape can generate a complete
-- table programmatically; this serves until then.
local OW_FOOD_DEFAULT_MIN = 30
local OW_FOOD_DURATION_MIN = {
    -- Sushi (DD acc food)
    [4377] = 30,  -- Squid Sushi
    [4385] = 30,  -- Sole Sushi
    [4386] = 60,  -- Sole Sushi +1
    [4387] = 30,  -- Tuna Sushi
    [4388] = 60,  -- Tuna Sushi +1
    [6468] = 30,  -- Sublime Sushi
    [6469] = 60,  -- Sublime Sushi +1
    -- Daifuku (acc + MAB)
    [6343] = 30,  -- Grape Daifuku
    [6344] = 60,  -- Grape Daifuku +1
    [6345] = 30,  -- Rolanberry Daifuku
    [6346] = 60,  -- Rolanberry Daifuku +1
    [6347] = 30,  -- Bean Daifuku
    [6348] = 60,  -- Bean Daifuku +1
    -- Steaks/meat (DD att food)
    [4399] = 30,  -- Coeurl Sub
    [4400] = 60,  -- Coeurl Sub +1
    [5719] = 30,  -- Marinara Pizza
    [5720] = 60,  -- Marinara Pizza +1
    [5721] = 30,  -- Pepperoni Pizza
    [5722] = 60,  -- Pepperoni Pizza +1
    [5723] = 30,  -- Pizza Margherita
    [5724] = 60,  -- Pizza Margherita +1
    -- Mage food (INT/MND)
    [4448] = 30,  -- Pear Crepe
    [4449] = 60,  -- Pear au Lait
    [5727] = 30,  -- Hedgehog Pie
    [5728] = 60,  -- Hedgehog Pie +1
    [4395] = 30,  -- Sausage Roll
    [4396] = 60,  -- Sausage Roll +1
    -- HP/regen
    [4374] = 30,  -- Mithran Tomato
    [4376] = 30,  -- Wild Carrot
    [5749] = 30,  -- Bream Sushi
    -- MP/refresh
    [4397] = 30,  -- Yagudo Drink
    [4398] = 60,  -- Yagudo Drink +1
    [4516] = 30,  -- Pamamas au Lait
    -- Cure/healing potency
    [5687] = 30,  -- Pamtam Kelp Soup
    [5688] = 60,  -- Pamtam Kelp Soup +1
    -- Long-duration hMP/hHP (1-2 hours)
    [4427] = 60,  -- Mille Feuille
    [4428] = 60,  -- Cream Puff
    -- Misc ranged/magic
    [5749] = 30,  -- Bream Sushi
    [4393] = 30,  -- Marinara Pizza (legacy id, leaving in case)
}

local function ow_food_duration_min(item_id)
    return OW_FOOD_DURATION_MIN[item_id] or OW_FOOD_DEFAULT_MIN
end

-- ── Buff timer config ─────────────────────────────────────────────────────
-- Hand-edit OW_BUFF_CONFIG to control what shows up in the buff timer panel.
-- Reload OmniWatch after changes (//lua r omniwatch).
--
-- show_buffs_from_others: include buffs cast on us by other players. These
--                          use base duration (we don't know the caster's
--                          gear) and get a "~" prefix in the panel.
-- show_food:               include food buff timer
-- show_songs:              include BRD songs cast on us
-- show_rolls:              include COR rolls cast on us
-- show_self_spells:        include any other self-cast buff with a known
--                          duration (Hasso, Phalanx, Stoneskin, etc.)
-- sort_order: 'asc'  → soonest-expiring leftmost (default)
--             'desc' → longest-remaining leftmost
-- min_seconds: hide entries below this remaining time (0 = show all)
-- blacklist: set of buff names to never show
local OW_BUFF_CONFIG = {
    show_buffs_from_others = true,
    show_food              = true,
    show_songs             = true,
    show_rolls             = true,
    show_self_spells       = true,
    sort_order             = 'asc',
    min_seconds            = 0,
    blacklist              = {
        -- Common entries you might want to hide. Add more as needed.
        -- Examples (commented out — uncomment to enable):
        -- ['Sneak']  = true,
        -- ['Invisible']  = true,
    },
}

-- ── Buff timer state ─────────────────────────────────────────────────────
-- _ow_buff_timers[slot] = {
--     slot        = 0..31,      -- buff slot index (FFXI exposes 32 slots)
--     buff_id     = number,     -- the status effect id occupying this slot
--     name        = string,     -- display name
--     started_at  = os.clock(), -- when we started tracking
--     expires_at  = os.clock() + duration,
--     duration    = seconds,
--     source      = 'self' | 'other' | 'food' | 'song' | 'roll',
--     estimated   = boolean,    -- true: duration is a fallback guess
--     precise     = boolean,    -- true: expires_at came from 0x063 sub-0x09
-- }
-- Keying by slot (not buff_id) lets us distinguish March #1 from March #2
-- (same buff_id, different slots, distinct expiry times). The 0x063 sub-0x09
-- packet -- the gold standard for buff durations -- is naturally slot-keyed,
-- so this matches the upstream data shape.
--
-- Cleared when buff_loss event fires for a slot whose buff_id matches, or
-- on zone change, or when expires_at elapses (cleaned up at send time).
_ow_buff_timers = {}

-- _ow_buff_slots[slot] = buff_id   -- raw slot snapshot from poll/packet.
-- Updated by the slot poller (every 0.25s tick). Used by the auto-discovery
-- walk to drive _ow_buff_timers entries with precise expiry times.
_ow_buff_slots = {}

-- _ow_buff_slot_expires_at[slot] = os.clock() at expiry.
-- Captured from 0x063 sub-0x09 timestamps when available; nil if only the
-- buff_id is known and we have to fall back to a duration estimate.
_ow_buff_slot_expires_at = {}

-- _ow_buff_assoc[bid][gi] = {full_name=str, Caster=str}
--
-- Persistent stash of (full_name, Caster) per song instance, indexed by
-- (buff_id, gain-instant-time). Solves a clobber bug observed with Carols:
--
--   GearInfo's _gi.parse.i[0x063] populates _ExtraData.player.buff_details
--   from scratch on every 0x063 sub-9 packet. It assigns full_name/Caster
--   by reading member_table[caster].Last_Spell at a gated branch (see
--   Action_Processing.lua line 293). On the FIRST 0x063 after a cast,
--   Last_Spell is fresh and the assignment fires correctly. On the NEXT
--   0x063 (FFXI sends them periodically and on every buff change — gear
--   swaps, song count changes, etc.) Last_Spell is stale/cleared and the
--   gate fails: the same buff entry comes back with bare name="Carol" and
--   no full_name/Caster. check_buffs (Buff_Processing.lua) then can't
--   match the song record by name, the resist math never runs, and
--   stats['resist'] stays empty.
--
-- This table survives the rebuild. The 0x063 handler walks the new
-- packet's entries, and for each (bid, gi) within ±IDENTITY_TOL of a
-- stashed (bid, gi'), pastes the stashed full_name/Caster onto the new
-- buff_details entry before check_buffs runs.
--
-- Hardens not just Carols but any buff whose buff_id maps to a generic
-- bucket name (Roll, Carol, etc.). Songs with unique res.buffs entries
-- (Minuet V, Honor March) are unaffected — their full_name survives the
-- rebuild via res lookup, and the stash branch just no-ops re-stamps.
--
-- Cleared on zone change. Stale entries (bid+gi not seen this packet)
-- are dropped at the end of the per-packet loop.
_ow_buff_assoc = {}

-- Resource lookup helper. Resolves a buff name from buff_id.
local function _ow_buff_name(buff_id)
    local b = res.buffs and res.buffs[buff_id]
    if b then return b.en or b.name end
    return 'Buff #' .. tostring(buff_id)
end

-- Determine the source category for a tracked buff.
-- Songs use a known set of buff_ids (Marches, Minuets, Madrigals etc).
-- Rolls likewise. Food is buff_id 251. Anything else cast by us is 'self';
-- anything else cast by another player is 'other'.
local OW_SONG_BUFF_IDS = {
    [195] = true,   -- Minuet (most BRD songs land in 195-201 range; expand as needed)
    [196] = true,
    [197] = true,
    [198] = true,
    [199] = true,
    [200] = true,
    [201] = true,
    [214] = true,   -- Honor March, etc.
    [215] = true,
    [216] = true,
    [217] = true,
    [218] = true,
    [219] = true,
    [220] = true,
    [221] = true,
    [222] = true,
    [223] = true,
    [224] = true,
    [225] = true,
}
local OW_ROLL_BUFF_IDS = {}
do
    -- COR rolls span buff_id 308-340 roughly; populate from res.buffs by name.
    -- Match any buff whose name ends in " Roll" — covers both apostrophe
    -- forms ("Hunter's Roll", "Fighter's Roll") and bare forms ("Chaos
    -- Roll", "Choral Roll", "Beast Roll"). The original pattern required
    -- "'s roll" and silently classified Chaos/Choral/Beast as 'self',
    -- bypassing the gear-aware duration multiplier in buff_gain.
    if res and res.buffs then
        for bid, b in pairs(res.buffs) do
            local nm = (b.en or b.name or ''):lower()
            if nm:find(" roll$") or nm == "phantom roll" or nm:find("roll's") then
                OW_ROLL_BUFF_IDS[bid] = true
            end
        end
    end
    -- Bust (buff_id 309) is the bust state shared across all rolls. Its
    -- buff name is just "Bust" so the roll-name pattern above doesn't
    -- match. We add it explicitly so the classifier returns 'roll' for
    -- bust events. That routes them through the 'roll' branch in the
    -- buff_gain handler, which honors the fixed_duration flag we set on
    -- bust emissions (keeps duration at the emitted 5min instead of the
    -- 3-min 'self' fallback the slot poller would otherwise use if
    -- pending_meta didn't survive).
    OW_ROLL_BUFF_IDS[309] = true
end

local function _ow_classify_buff_source(buff_id, actor_id)
    local me = windower.ffxi.get_player()
    local is_self_cast = (me and me.id and actor_id == me.id)
    if buff_id == 251 then return 'food' end
    if OW_SONG_BUFF_IDS[buff_id] then return is_self_cast and 'song' or 'song_other' end
    if OW_ROLL_BUFF_IDS[buff_id] then return is_self_cast and 'roll' or 'roll_other' end
    return is_self_cast and 'self' or 'other'
end

-- ── Song duration computation ────────────────────────────────────────────
-- BG-wiki canonical formula:
--   final = (base + song_specific_seconds) * duration_multiplier * troub_mult
--           + marcato_jp_seconds + lullaby_jp_seconds + clarion_call_seconds
--
-- Where:
--   base = 120s (party songs), 60s (Lullaby and special)
--   song_specific_seconds = 10% of base for each "<SongName>+1" gear piece
--                            equipped (e.g. "March +1" on Fili Manchettes +1
--                            adds +12s to a March)
--   duration_multiplier = sum of all "Song duration +X%" gear bonuses
--   troub_mult = 2.0 if Troubadour active, 1.0 otherwise (applied AFTER
--                gear bonuses, BEFORE Marcato)
--   marcato_jp = +20s if Marcato JP gift purchased AND Marcato active when
--                song was cast (added LAST, post-Troubadour)
--   lullaby_jp = +20s for Lullaby specifically (also post-Troubadour)
--   clarion_call = +40s if Clarion Call active before Troubadour (multiplied
--                   by Troubadour)

-- (Song duration gear tables — all-songs duration gear like Carnwenhan
-- and song-class-specific gear like Fili Hongreline — live in
-- gearinfo/res/BardGear.lua and are populated into the GLOBALS
-- OW_SONG_DURATION_GEAR / OW_SONG_SPECIFIC_GEAR by the data-load
-- block above. Globals are required because the action handler at
-- line ~4150 reads them and locals declared this far down would not
-- be visible there at runtime.)

-- Song-name → song-class lookup.  Used to resolve which song-specific
-- gear bonuses apply.  Built once from res.spells at first use.
-- NOTE: declared as a GLOBAL (no `local` prefix), not file-local. The
-- action handler at line ~3819 references this and the other song
-- helpers below, but `local function` declarations only enter scope at
-- their declaration line — call sites BEFORE this line would resolve
-- the name as a global lookup against an empty global, crashing the
-- action handler with "attempt to call global '_ow_classify_song'
-- (a nil value)". Globals avoid the forward-ref hazard.
_ow_song_class_cache = nil
function _ow_classify_song(spell_name)
    if not spell_name then return nil end
    if _ow_song_class_cache == nil then
        _ow_song_class_cache = {}
        if res and res.spells then
            for _, sp in pairs(res.spells) do
                local sn = sp.en or sp.name or ''
                -- Pattern: "<Adjective> <Class> [<Numeral>]"
                -- e.g. "Victory March", "Sentinel's Scherzo", "Sword Madrigal"
                for _, klass in ipairs({
                    -- Buff songs that match a class word in their name:
                    'Madrigal', 'Minuet', 'March', 'Ballad', 'Paeon',
                    'Etude', 'Carol', 'Hymnus', 'Mambo', 'Aubade',
                    'Prelude', 'Lullaby', 'Mazurka',
                    'Minne',          -- Knight's Minne I-V (defense)
                    'Pastoral',       -- Herb Pastoral (poison resist)
                    'Operetta',       -- Puppet's Operetta (counter)
                    'Round',          -- Warding Round (magic resist)
                    'Nocturne',       -- Pining Nocturne (sleep resist)
                    'Fantasia',       -- Shining Fantasia (light/dark)
                    'Gavotte',        -- Goblin Gavotte (CHR)
                    'Sirvente',       -- Foe Sirvente (enmity+)
                    'Dirge',          -- Adventurer's Dirge (regen)
                    'Virelai',        -- Maiden's Virelai (regain)
                    'Scherzo',        -- Sentinel's Scherzo
                    -- Debuff songs (also affected by song-duration gear):
                    'Threnody', 'Requiem', 'Elegy', 'Finale',
                }) do
                    if sn:find(klass) then
                        _ow_song_class_cache[sn] = klass
                        break
                    end
                end
            end
        end
    end
    return _ow_song_class_cache[spell_name]
end

-- Determine base duration in seconds for a song class. Most party-buff
-- songs are 120s; Lullaby and a few others are shorter.
function _ow_song_base_duration(song_class)
    if song_class == 'Lullaby' then return 60 end
    return 120
end

-- Read equipped item names by slot. Returns table {slot_name: item_name}.
-- Wire format used by windower.ffxi.get_items().equipment:
--   equipment is a FLAT table of numbers, e.g.:
--     { main = 5, main_bag = 8, sub = 0, sub_bag = 0,
--       head = 12, head_bag = 8, ... }
--   The two paired keys are the inventory index (1-based) within a bag,
--   and the bag id (0=inventory, 8=wardrobe, 10..16=wardrobe2..8). To
--   resolve to a real item we look up that bag's array (items.inventory,
--   items.wardrobe, etc.) at [index] and read .id, then map to a name
--   via res.items[id].en.
function _ow_equipment_snapshot()
    local snapshot = {}
    local ok, items = pcall(windower.ffxi.get_items)
    if not (ok and items and items.equipment) then return snapshot end
    local bag_field = {
        [0]  = 'inventory',
        [8]  = 'wardrobe',
        [10] = 'wardrobe2',
        [11] = 'wardrobe3',
        [12] = 'wardrobe4',
        [13] = 'wardrobe5',
        [14] = 'wardrobe6',
        [15] = 'wardrobe7',
        [16] = 'wardrobe8',
    }
    -- Slots that we actually care about for song-duration gear. Iterating
    -- only these keeps us from tripping over the *_bag pair entries and
    -- non-equipment keys ('count', etc.). Keys are the canonical Windower
    -- slot names from windower.ffxi.get_items().equipment — note the
    -- 'left_ear/right_ear/left_ring/right_ring' naming, NOT 'ear1/ear2/
    -- ring1/ring2'. (An earlier version of this list used the latter and
    -- silently dropped earring/ring slots from the snapshot, which made
    -- ear/ring duration gear invisible to the duration calc.)
    local slots = {
        'main', 'sub', 'range', 'ammo',
        'head', 'neck', 'left_ear', 'right_ear',
        'body', 'hands', 'left_ring', 'right_ring',
        'back', 'waist', 'legs', 'feet',
    }
    local eq = items.equipment
    for _, slot in ipairs(slots) do
        local idx = eq[slot]               -- inventory index in the bag
        local bag = eq[slot .. '_bag']     -- which bag holds it
        if idx and idx ~= 0 and bag then
            local field = bag_field[bag]
            if field and items[field] and items[field][idx] then
                local entry = items[field][idx]
                if entry and entry.id and entry.id ~= 0
                   and res and res.items and res.items[entry.id] then
                    snapshot[slot] = res.items[entry.id].en
                                     or res.items[entry.id].name or ''
                end
            end
        end
    end
    return snapshot
end

-- Compute final song duration in seconds.
-- spell_name: e.g. "Valor Minuet IV"
-- equipment:  {slot_name = item_name, ...} as captured at cat=8
-- active_buffs: array of buff_ids active at cat=8
-- jp_gifts: optional {song_duration_5pct=true, lullaby_bonus=true,
--                     marcato_bonus=true, clarion_call_bonus=true}
-- Returns final duration in seconds (number) or nil if not a song.
function _ow_compute_song_duration(spell_name, equipment, active_buffs, jp_gifts)
    local song_class = _ow_classify_song(spell_name)
    if not song_class then return nil end
    local base = _ow_song_base_duration(song_class)

    -- Sum all-song duration bonuses across all equipped slots.
    local dur_pct = 0
    if equipment then
        for _slot, item_name in pairs(equipment) do
            local b = OW_SONG_DURATION_GEAR[item_name]
            if b then dur_pct = dur_pct + b end
        end
    end
    -- 1200 JP gift bonus (BRD only): +5% to song duration.
    jp_gifts = jp_gifts or {}
    if jp_gifts.song_duration_5pct then
        dur_pct = dur_pct + 0.05
    end

    -- Sum song-class-specific bonuses (additional to all-songs above).
    local specific_pct = 0
    if equipment and OW_SONG_SPECIFIC_GEAR[song_class] then
        local table_for_class = OW_SONG_SPECIFIC_GEAR[song_class]
        for _slot, item_name in pairs(equipment) do
            local b = table_for_class[item_name]
            if b then specific_pct = specific_pct + b end
        end
    end

    -- Detect Troubadour, Marcato, Clarion Call from buff snapshot taken
    -- at cat=8 (cast start). Marcato and Soul Voice get consumed by the
    -- act of singing, so by cat=4 they're gone -- the snapshot at cat=8
    -- is the only place these are reliably visible.
    local has_troub, has_marcato, has_clarion = false, false, false
    if active_buffs then
        for _, bid in ipairs(active_buffs) do
            if PW_BUFF_TROUBADOUR    and bid == PW_BUFF_TROUBADOUR    then has_troub   = true end
            if PW_BUFF_MARCATO       and bid == PW_BUFF_MARCATO       then has_marcato = true end
            if PW_BUFF_CLARION_CALL  and bid == PW_BUFF_CLARION_CALL  then has_clarion = true end
        end
    end
    local troub_mult = has_troub and 2.0 or 1.0
    -- Marcato (active buff, separate from the Marcato JP gift) only
    -- extends the DURATION of three specific songs:
    --   Hymnus, Mazurka, Scherzo
    -- For every other song class Marcato either boosts effect potency
    -- (most buff/debuff songs) or magic accuracy (Lullaby/Finale/Virelai)
    -- — NEITHER affects duration. Verified bg-wiki Marcato page.
    --
    -- The duration multiplier IS multiplicative with Troubadour. Per
    -- the Marcato Testing thread (bg-wiki), Mazurka with gear+Troub+Marcato
    -- = 9 min vs gear+Troub alone = 6 min, exactly ×1.5 stacking on top.
    local marcato_duration_classes = {
        Hymnus = true, Mazurka = true, Scherzo = true,
    }
    local marcato_mult = 1.0
    if has_marcato and marcato_duration_classes[song_class] then
        marcato_mult = 1.5
    end

    -- Clarion Call JP: +40s applied BEFORE Troubadour (so ×2'd by it).
    -- Lullaby Bonus JP: +20s applied BEFORE Troubadour, Lullaby class only.
    local pre_troub_bonus = 0
    if has_clarion and jp_gifts.clarion_call_bonus then
        pre_troub_bonus = pre_troub_bonus + 40
    end
    if song_class == 'Lullaby' and jp_gifts.lullaby_bonus then
        pre_troub_bonus = pre_troub_bonus + 20
    end

    -- Marcato Bonus JP: +20s applied AFTER Troubadour (not ×2'd).
    local post_troub_bonus = 0
    if has_marcato and jp_gifts.marcato_bonus then
        post_troub_bonus = post_troub_bonus + 20
    end

    -- Compute final duration. Per BG-wiki / community-verified formula:
    --
    --   pre_troub  = base
    --                + base × dur_pct           -- all-song duration gear
    --                + base × specific_pct      -- song+ class-specific gear
    --                + clarion_call_jp           -- +40s if clarion + JP
    --                + lullaby_class_jp          -- +20s if lullaby + JP
    --   final      = pre_troub × troub_mult     -- ×2 if Troubadour up
    --                         × marcato_mult     -- ×1.5 if Marcato up (buff
    --                                            -- songs only); cumulative
    --                                            -- with Troubadour
    --                + marcato_jp                -- +20s if marcato + JP
    --
    -- Crucially, duration-gear and specific-gear bonuses are computed
    -- as `base × pct` ADDITIVELY with the base, NOT as `(base+specific)
    -- × (1 + dur_pct)`. The latter overcounts by `specific × dur_pct`
    -- per song. Verified against bg-wiki and Marcato Testing thread.
    local dur_seconds      = base * dur_pct
    local specific_seconds = base * specific_pct
    local pre_troub = base + dur_seconds + specific_seconds + pre_troub_bonus
    local final = pre_troub * troub_mult * marcato_mult + post_troub_bonus
    return final
end

-- Optional: Job Point gifts the player has unlocked. Hand-edit to match
-- your character. These survive a //lua r so they're persistent.
PW_BRD_JP_GIFTS = PW_BRD_JP_GIFTS or {
    song_duration_5pct   = true,    -- 1200 JP "Song Duration" gift
    lullaby_bonus        = true,    -- "Horde Lullaby" / "Lullaby Bonus"
    marcato_bonus        = true,    -- "Marcato Bonus"
    clarion_call_bonus   = true,    -- "Clarion Call Bonus"
}

-- Buff IDs we sample at cast-begin to detect Troubadour / Marcato /
-- Clarion Call. Verified against Windower's res/buffs.lua AND active
-- community gearswap addons (Sammeh's lullaby.lua, Ivaar's Singer):
--   Troubadour     = 348  (was incorrectly 230 then 365 in earlier versions)
--   Marcato        = 231
--   Soul Voice     =  52  (defined elsewhere)
--   Clarion Call   = 499  (was incorrectly 595)
-- Set to your own values if your env's resources are different.
PW_BUFF_TROUBADOUR    = 348
PW_BUFF_MARCATO       = 231
PW_BUFF_CLARION_CALL  = 499
-- (PW_BUFF_SOUL_VOICE already exists from the potency block.)

-- Get the gear-aware multiplier for a specific song cast. Returns the
-- multiplier we should apply to the BASE duration that lua will pass to
-- _ow_compute_song_duration when we eat the buff_gain event.
-- Updated to take a spell name; the legacy no-arg form returns 1.0 so
-- the buff_gain code below can fall back gracefully if no cast was
-- captured.
function _ow_song_duration_mult(spell_name)
    if not spell_name then return 1.0 end
    if not _ow_song_cast_dur then return 1.0 end
    local entry = _ow_song_cast_dur[spell_name]
    if not entry then return 1.0 end
    -- Stored as a multiplier vs. the base. We just return the ratio.
    if entry.final and entry.base and entry.base > 0 then
        return entry.final / entry.base
    end
    return 1.0
end

-- Live-read merits and JP gifts from get_player() with manual override
-- fallback. Returns (winning_streak_levels, phantom_roll_duration_jp).
-- Both default to 0 if neither live nor manual provides a value.
local function _ow_cor_duration_inputs()
    local ws, jp = 0, 0
    -- 1. Try live read.
    local ok, p = pcall(windower.ffxi.get_player)
    if ok and p then
        if p.merits and tonumber(p.merits.winning_streak) then
            ws = tonumber(p.merits.winning_streak) or 0
        end
        -- job_points layout: p.job_points.cor.phantom_roll_duration
        -- (the key Windower uses for the COR roll-duration JP gift).
        if p.job_points and p.job_points.cor then
            local v = p.job_points.cor.phantom_roll_duration
            if tonumber(v) then jp = tonumber(v) or 0 end
        end
    end
    -- 2. Manual override wins ONLY if live read came back zero/empty
    -- (so a user who doesn't have JPs gets the override; a user who
    -- has them gets the real number).
    if ws == 0 then
        ws = tonumber((PW_COR_MERITS or {}).winning_streak) or 0
    end
    if jp == 0 then
        jp = tonumber((PW_COR_JP_GIFTS or {}).phantom_roll_duration) or 0
    end
    return math.min(5, math.max(0, ws)), math.min(20, math.max(0, jp))
end

-- ── Roll duration ──────────────────────────────────────────────────────
-- Sourced from BG-wiki Category:Phantom_Roll. Additive seconds formula:
--   final = 300                                      -- base 5min
--         + winning_streak * 20                      -- +20s/merit, max +100s
--         + winning_streak * 6 if Tricorne synergy   -- +6s/merit if Comm.Tri+2/RA+
--         + jp_phantom_roll_effect * 2               -- +2s/rank, max +40s
--         + sum(equipped duration gear seconds)      -- variable
--
-- Tricorne synergy: Commodore Tricorne +2 OR Reforged Empyrean +1/+2/+3
-- (Lanun Tricorne / +1 / +2 / +3) adds +6 extra seconds per Winning
-- Streak merit (i.e. +30s if all 5 merits and one of these heads is on).
--
-- Returns the multiplier vs the 300s base so callers can multiply through
-- unchanged (final / 300).
function _ow_roll_duration_mult()
    -- Build id-cache for duration gear lazily.
    if not _OW_ROLL_DURATION_GEAR_BY_ID then
        _OW_ROLL_DURATION_GEAR_BY_ID = {}
        local function record(name, val)
            local item = res.items and (res.items:with('en', name)
                                        or res.items:with('enl', name))
            if item and item.id then
                _OW_ROLL_DURATION_GEAR_BY_ID[item.id] = val
            end
        end
        for n, v in pairs(OW_ROLL_DURATION_GEAR) do record(n, v) end
        -- User overrides take precedence (later writes win).
        for n, v in pairs(OW_ROLL_DURATION_USER_OVERRIDES or {}) do
            record(n, v)
        end
    end
    -- Build Tricorne synergy id-cache lazily.
    if not _OW_TRICORNE_SYNERGY_BY_ID then
        _OW_TRICORNE_SYNERGY_BY_ID = {}
        for name, _ in pairs(OW_TRICORNE_SYNERGY_HEADS) do
            local item = res.items and (res.items:with('en', name)
                                        or res.items:with('enl', name))
            if item and item.id then
                _OW_TRICORNE_SYNERGY_BY_ID[item.id] = true
            end
        end
    end

    -- Walk equipped gear and sum additive seconds.
    -- Mainhand-only weapons (Commodore's/Lanun Knife, Rostam) are filtered
    -- by checking the slot — the same item in offhand provides no bonus.
    local gear_seconds = 0
    local has_tricorne_synergy = false
    local equipment = windower.ffxi.get_items
                      and windower.ffxi.get_items('equipment')
    if equipment then
        local slots = {'main','sub','range','ammo','head','neck',
                       'left_ear','right_ear','body','hands',
                       'left_ring','right_ring','back','waist',
                       'legs','feet'}
        local mainhand_only_ids = {}
        -- Resolve mainhand-only ids by name. Rostam's Path C augment
        -- (+60s duration) only applies in mainhand. Cheap; runs once
        -- per build. Cleared knife entries (Lanun/Commodore's) since
        -- they don't carry a duration bonus.
        for _, mh_name in ipairs({"Rostam", "Rostam +1"}) do
            local item = res.items and (res.items:with('en', mh_name)
                                        or res.items:with('enl', mh_name))
            if item and item.id then mainhand_only_ids[item.id] = true end
        end
        for _, sn in ipairs(slots) do
            local bag = equipment[sn..'_bag']
            local idx = equipment[sn]
            if idx and idx ~= 0 and bag then
                local idata = windower.ffxi.get_items(bag, idx)
                if idata and idata.id then
                    local v = _OW_ROLL_DURATION_GEAR_BY_ID[idata.id]
                    if v then
                        -- Mainhand-only weapons only count in 'main' slot.
                        if mainhand_only_ids[idata.id] and sn ~= 'main' then
                            -- skip
                        else
                            gear_seconds = gear_seconds + v
                        end
                    end
                    -- Tricorne synergy detection (head slot only).
                    if sn == 'head' and _OW_TRICORNE_SYNERGY_BY_ID[idata.id] then
                        has_tricorne_synergy = true
                    end
                end
            end
        end
    end

    local ws, jpdur = _ow_cor_duration_inputs()
    local merit_seconds = ws * 20
    local synergy_seconds = has_tricorne_synergy and (ws * 6) or 0
    local jp_seconds = jpdur * 2

    local base = 300
    local final = base + merit_seconds + synergy_seconds + jp_seconds + gear_seconds
    if base <= 0 then return 1.0 end
    return final / base
end

-- ── Self-Enhancing-Magic spell duration ────────────────────────────────
-- For self-cast enhancing-school spells, final = base * (1 + gear_pct) *
-- composure_mult. Composure_mult = 3 if Composure is active and player is
-- main RDM (job change suspends Composure auto). Returns the multiplier
-- to apply to base; 1.0 when nothing applies.
function _ow_enhancing_duration_mult(spell_name, active_buffs)
    if not spell_name or not OW_ENHANCING_SPELL_SET[spell_name] then
        return 1.0
    end

    -- Build cache lazily.
    if not _OW_ENHANCING_DUR_BY_ID then
        _OW_ENHANCING_DUR_BY_ID = {}
        local function record(name, val)
            local item = res.items and (res.items:with('en', name)
                                        or res.items:with('enl', name))
            if item and item.id then
                _OW_ENHANCING_DUR_BY_ID[item.id] = val
            end
        end
        for n, v in pairs(OW_ENHANCING_DURATION_GEAR) do record(n, v) end
        for n, v in pairs(OW_ENHANCING_DURATION_USER_OVERRIDES or {}) do
            record(n, v)
        end
    end

    -- Walk gear.
    local gear_pct = 0
    local equipment = windower.ffxi.get_items
                      and windower.ffxi.get_items('equipment')
    if equipment then
        local slots = {'main','sub','range','ammo','head','neck',
                       'left_ear','right_ear','body','hands',
                       'left_ring','right_ring','back','waist',
                       'legs','feet'}
        for _, sn in ipairs(slots) do
            local bag = equipment[sn..'_bag']
            local idx = equipment[sn]
            if idx and idx ~= 0 and bag then
                local idata = windower.ffxi.get_items(bag, idx)
                if idata and idata.id then
                    local v = _OW_ENHANCING_DUR_BY_ID[idata.id]
                    if v then gear_pct = gear_pct + v end
                end
            end
        end
    end

    -- Composure (RDM main only) — ×3 for self-cast.
    local composure_mult = 1.0
    local me = windower.ffxi.get_player()
    local is_rdm_main = me and me.main_job == 'RDM'
    if is_rdm_main and active_buffs then
        for _, bid in ipairs(active_buffs) do
            if bid == PW_BUFF_COMPOSURE then
                composure_mult = 3.0
                break
            end
        end
    end

    return (1.0 + gear_pct) * composure_mult
end

-- Track a buff with a computed duration.  Called from the buff_gain event
-- subscriber once we've classified the source and looked up the base
-- duration.  Existing entries in the same slot are overwritten (latest
-- buff in that slot wins, which matches game behaviour -- the slot
-- index is a property of the FFXI client's status effect tracker).
local function _ow_track_buff(slot, buff_id, name, duration_sec, source, opts)
    -- Real 0x063 slots are 0..31. The me.buffs synthetic fallback uses
    -- 100..131 as collision-free slot indices (so a real-slot entry for
    -- the same buff_id doesn't clobber the fallback or vice versa).
    if not slot or slot < 0 or slot > 199 then return end
    if not buff_id or not duration_sec or duration_sec <= 0 then return end
    opts = opts or {}
    local now = os.clock()
    local expires_at
    if opts.expires_at then
        expires_at = opts.expires_at
    else
        expires_at = now + duration_sec
    end
    -- Use caller-supplied started_at when available (slot migration case:
    -- the buff was in another slot last packet and we're carrying over
    -- the original start time so the fullness bar stays proportional).
    -- Otherwise start fresh from now.
    local started_at = opts.started_at or now
    _ow_buff_timers[slot] = {
        slot       = slot,
        buff_id    = buff_id,
        name       = name,
        started_at = started_at,
        expires_at = expires_at,
        duration   = duration_sec,
        source     = source,
        estimated  = opts.estimated or false,
        precise    = opts.precise or false,
    }
end

-- Untrack by slot. Called on buff_loss when we can identify the slot
-- (the loss event carries buff_id, so we scan slots for a match), and
-- by the slot poller when a slot transitions from occupied to empty.
local function _ow_untrack_buff_by_slot(slot)
    if not slot then return end
    _ow_buff_timers[slot] = nil
end

-- Untrack by buff_id (legacy path). buff_loss only knows the buff_id, not
-- the slot, so this scans for any slot holding that id and removes them
-- all -- which is correct: if you have two Marches and one wears off, FFXI
-- emits exactly one buff_loss for that buff_id and we want to clear the
-- specific slot. Without the slot, we conservatively clear all matching;
-- the 0x063 poll on the next tick will repopulate the surviving one.
local function _ow_untrack_buff(buff_id)
    if not buff_id then return end
    for slot, t in pairs(_ow_buff_timers) do
        if t.buff_id == buff_id then
            _ow_buff_timers[slot] = nil
        end
    end
end

-- Subscribe to the central buff_gain event.  We get target_id, buff_id,
-- spell_id, duration, and actor_id from the action handler.  We compute
-- a final duration from the spell's base + gear-aware multiplier (when
-- we cast it ourselves) and store.
ow_events.on('buff_gain', function(data)
    if not data or not data.buff_id then return end
    local me = windower.ffxi.get_player()
    -- Only track buffs ON US.  Buffs on other targets aren't ours to display.
    if not (me and me.id and data.target_id == me.id) then return end
    local buff_id = data.buff_id
    local source  = _ow_classify_buff_source(buff_id, data.actor_id or 0)
    -- Apply config gating.
    local cfg = OW_BUFF_CONFIG or {}
    if source == 'food' and not cfg.show_food then return end
    if source == 'song' and not cfg.show_songs then return end
    if source == 'roll' and not cfg.show_rolls then return end
    if source == 'self' and not cfg.show_self_spells then return end
    if (source == 'other' or source == 'song_other' or source == 'roll_other')
       and not cfg.show_buffs_from_others then return end
    -- Determine base duration. data.duration came from the spell's resource
    -- entry on the lua side. For self-cast buffs, scale by gear-aware mult.
    local base = tonumber(data.duration) or 0
    if base <= 0 then return end
    local final_dur = base
    if source == 'song' then
        -- Look up spell name from spell_id, then read the per-cast
        -- duration computed at cat=8.
        local spell_name = nil
        if data.spell_id and res and res.spells and res.spells[data.spell_id] then
            spell_name = res.spells[data.spell_id].en or
                          res.spells[data.spell_id].name
        end
        if spell_name and _ow_song_cast_dur and _ow_song_cast_dur[spell_name] then
            local entry = _ow_song_cast_dur[spell_name]
            -- Use the absolute final duration we computed at cast-begin,
            -- which already factors in gear, Troubadour, Marcato, etc.
            -- Only honor it if recent (within 30s of buff_gain — songs
            -- have ~5s casts but Troubadour effects can cap that high).
            if entry.final and (os.time() - (entry.ts or 0)) < 30 then
                final_dur = entry.final
            end
            _ow_song_cast_dur[spell_name] = nil  -- consume
        else
            -- Fall back to legacy ratio multiplier.
            final_dur = base * _ow_song_duration_mult(spell_name)
        end
    elseif source == 'roll' then
        -- Prefer the cat=6 cast-time snapshot (taken when the action
        -- just resolved, before gearswap aftercast snapped duration
        -- gear back to idle). Fall back to live read if no snapshot.
        --
        -- BUST EXCEPTION: if the emitter passed fixed_duration=true,
        -- skip the multiplier entirely. Bust duration is always 5min
        -- regardless of Phantom Roll+ duration gear; multiplying it
        -- would inflate the bust timer up to 11+ minutes which is
        -- visibly wrong.
        if data.fixed_duration then
            -- final_dur stays at base (5min for busts).
        else
            local snap = (_ow_roll_cast_dur or {})[buff_id]
            if snap and (os.time() - (snap.ts or 0)) < 30 and snap.mult then
                final_dur = base * snap.mult
                _ow_roll_cast_dur[buff_id] = nil  -- consume
            else
                final_dur = base * _ow_roll_duration_mult()
            end
        end
    elseif source == 'self' then
        -- Self-cast spell. If it's an enhancing-school spell, apply
        -- the gear-aware Enhancing Magic Duration multiplier (Telchine
        -- set, etc.) and Composure (RDM ×3 self-cast).
        local spell_name = nil
        if data.spell_id and res and res.spells and res.spells[data.spell_id] then
            spell_name = res.spells[data.spell_id].en or
                          res.spells[data.spell_id].name
        end
        if spell_name and OW_ENHANCING_SPELL_SET[spell_name] then
            local me = windower.ffxi.get_player()
            local active = (me and me.buffs) or {}
            final_dur = base * _ow_enhancing_duration_mult(spell_name, active)
        end
    end
    -- Other-player buffs use base (we don't know their gear).
    -- Prefer the emitter's display_name when present: songs pass the
    -- specific tier name ("Honor March", "Valor Minuet V"), which
    -- _ow_buff_name(buff_id) can't resolve since multiple songs share
    -- the same buff_id (March = 214 for all three).
    local nm = data.display_name or _ow_buff_name(buff_id)
    -- Apply blacklist.
    if cfg.blacklist and cfg.blacklist[nm] then return end
    -- Mark other-player buffs with ~ prefix.
    if source == 'other' or source == 'song_other' or source == 'roll_other' then
        nm = '~' .. nm
    end
    -- Stash the gear-aware duration + source in a side table keyed by
    -- buff_id. The slot poller (driven by 0x063 sub-0x09 packets) will
    -- find this entry when it sees the buff appear in a slot, prefer
    -- our computed name/source, but trust the packet's expires_at over
    -- our own duration estimate. The pending entry expires after 30s
    -- so a stale meta from a long-cancelled cast can't poison a future
    -- buff in the same slot.
    --
    -- Keyed by buff_id only (not a queue): when a second song of the
    -- same buff_id is cast, this overwrites the first entry. That's
    -- the correct behavior for two-tier labeling because:
    --   * Tier 1 already bound to its slot → existing.name is set →
    --     the existing-label-preservation in reconcile keeps tier 1's
    --     label.
    --   * The new tier 2 entry is what an UNLABELED slot picks up
    --     (the new song's slot) — that's the slot we actually want
    --     it to bind to.
    _ow_buff_pending_meta = _ow_buff_pending_meta or {}
    -- Resolve caster name from actor_id. For self-cast, this is us;
    -- for songs sung by another bard, this is them. Falls back to nil
    -- when get_mob_by_id can't resolve (rare; e.g. a faraway caster
    -- not in our zone scope) — that's fine, downstream attribution
    -- writes treat caster=nil as "don't write Caster, leave whatever
    -- GearInfo had".
    --
    -- IMPORTANT: store as lowercase. settings.Bards is keyed by
    -- p.name:lower() (see _ow_refresh_bard_settings), and Buff_Processing's
    -- bard chain looks up `settings.Bards[buff.Caster]` directly. If
    -- buff.Caster is "Wormfood" (capitalized from windower) the lookup
    -- misses and check_buffs falls into the no-Bards branch with
    -- All_songs=0 — Tier I songs lose their gear potency bonus and
    -- show base values regardless of Carol+/AllSongs+ gear. The notice
    -- prints "Song bonus +0" as the symptom. Lowercasing here keeps
    -- our attribution wire-compatible with the rest of the addon.
    local caster_name = nil
    do
        local aid = data.actor_id or 0
        if aid ~= 0 then
            local mob = windower.ffxi.get_mob_by_id(aid)
            if mob and mob.name then
                caster_name = mob.name:lower()
            end
        end
    end
    _ow_buff_pending_meta[buff_id] = {
        name      = nm,
        caster    = caster_name,
        duration  = final_dur,
        source    = source,
        ts        = os.clock(),
    }
    -- Diagnostic: shows what hit pending_meta for this bid. Gated
    -- behind _ow_buff_debug so it's silent in normal play.
    if _ow_buff_debug then
        windower.add_to_chat(207, string.format(
            '[OW] PEND-PUSH bid=%d nm=[%s] caster=%s dur=%.1fs src=%s',
            buff_id, nm, tostring(caster_name), final_dur, source))
    end
end)

-- buff_loss removes the timer immediately.
ow_events.on('buff_loss', function(data)
    if not data or not data.buff_id then return end
    local me = windower.ffxi.get_player()
    if not (me and me.id and data.target_id == me.id) then return end
    _ow_untrack_buff(data.buff_id)

    -- ── Server_Stats cache invalidation ───────────────────────────────
    -- When a roll-related buff wears off, the cached pAtt/def reflect
    -- a state that no longer exists. The server doesn't always push a
    -- fresh 0x061 with stat values on wear-off — sometimes it sends a
    -- partial-update packet we filter out. Drop the cache so the panel
    -- falls back to client math (which is reliable post-roll). The
    -- next 0x061 with real values will repopulate the cache.
    --
    -- Trigger on: any buff in OW_ROLL_BUFF_IDS (covers all 22 phantom
    -- rolls and the bust state, buff_id 309). Not invalidating for
    -- non-roll buffs (e.g. song wear-off) to avoid thrashing — the
    -- cache will refresh naturally on the next stat-bearing 0x061.
    if OW_ServerStats and OW_ServerStats.invalidate then
        local bid = data.buff_id
        if (OW_ROLL_BUFF_IDS and OW_ROLL_BUFF_IDS[bid]) or bid == 309 then
            pcall(function()
                OW_ServerStats.invalidate('roll_wear_off:' .. tostring(bid))
            end)
        end
    end
end)

-- Zone change wipes all timers since buffs persist across zones for some
-- but not others, and we'd rather restart fresh than show stale data.
-- The next 0x063 packet (sent within ~3s after a zone-in) will repopulate.
ow_events.on('zone_change', function()
    _ow_buff_timers = {}
    _ow_buff_slots = {}
    _ow_buff_slot_expires_at = {}
    _ow_buff_pending_meta = {}
    _ow_buff_assoc = {}
end)

-- Food buff is special — when the player eats, the food item ID and stats
-- are captured in _ow_food_stats / _ow_food_item_id (existing system).
-- We hook into that via a periodic check inside the timer-send loop:
-- if food buff (251) is active in player.buffs but not in our timer dict,
-- look up the food's known duration from OW_FOOD_DURATION_MIN.

ow_safe_register('outgoing chunk', function(id, data)
    if id ~= 0x037 then return end
    -- Bag at offset 0x05, Slot at offset 0x04 in the packet body.
    -- (Windower's parsed packet has 'Bag' and 'Inventory Index' fields,
    -- but we can read them directly from the bytes since we're already
    -- using string.byte elsewhere.)
    local ok, p = pcall(packets.parse, 'outgoing', data)
    if not ok or not p then return end
    local bag  = p['Inventory'] or p['Bag']
    local slot = p['Inventory Index'] or p['Slot']
    if not bag or not slot then return end
    local item = windower.ffxi.get_items(bag, slot)
    if not (item and item.id and item.id ~= 0) then return end
    local r = res.items[item.id]
    if not r or r.type ~= 7 then return end   -- 7 = Food
    -- Parse the description for stat lines.
    local desc = res.item_descriptions and res.item_descriptions[item.id]
    local helptext = (desc and desc.english) or ''
    if helptext == '' then return end
    -- Reset the food table — eating a new food replaces the old buff.
    _ow_food_stats = {}
    _ow_food_item_id = item.id
    for line in helptext:gmatch('[^\r\n]+') do
        ow_parse_desc_line(_ow_food_stats, line)
    end
    if _ow_cast_debug then
        local cnt = 0
        for _ in pairs(_ow_food_stats) do cnt = cnt + 1 end
        windower.add_to_chat(207, string.format(
            '[OW] food eaten: %s (id=%d, %d stat lines)',
            r.english or '?', item.id, cnt))
    end
end)

ow_safe_register('zone change', function()
    udp_status:send('CLEAR|0')   -- 0 = wipe all
    _ow_bolters_value = 0
    _ow_buff_sources = {}
    _ow_roll_state   = {}
    _ow_food_stats   = {}
    _ow_food_item_id = 0
    pcall(_ow_dps_reset)         -- DPS rolling window doesn't span zones
    pcall(_ow_save_buff_state)
    -- Notify subscribers (e.g. recast timer panel may want to flush state).
    local info = windower.ffxi.get_info() or {}
    ow_events.emit('zone_change', {zone_id = info.zone or 0})
end)

-- ── Cast-begin via incoming text (belt-and-suspenders) ──────────────────────
-- FFXI prints "<Mob> starts casting <Spell>." for enemy spell casts and
-- "<Mob> readies <Ability>." for TP moves. The packet-based CAST_START is
-- the primary source, but this catches cases where packet category numbers
-- differ from what we expected.
ow_safe_register('incoming text', function(original, modified, original_mode, modified_mode, blocked)
    if not original then return end

    -- Strip common FFXI control characters before pattern matching. The game
    -- uses various bytes in the 0x00-0x1F range as formatting / autotranslate
    -- markers that differ from plain ASCII.
    local text = original
    -- Remove any byte < 0x20 except newline and tab.
    text = text:gsub('[%z\1-\8\11-\31]', '')

    -- Diagnostic: if the raw text contains the keywords we care about, print
    -- it so we can inspect what the actual format is.
    if _ow_cast_debug and (text:find('casting') or text:find('readies')) then
        windower.add_to_chat(207, '[OW] text: ' .. text)
    end

    -- Only attend to lines we actually care about — cast-begin and ability-ready.
    -- Patterns are anchored loosely so leading chars (like "The ") don't break them.
    -- FFXI variants:
    --   "The Goblin Leecher starts casting Firaga III."
    --   "Goblin Leecher starts casting Firaga III."
    --   "The Goblin Leecher readies Hundred Fists."
    -- Note: pattern lives in a double-quoted Lua string so %' isn't needed.
    local mob_name, spell_name = text:match("([A-Z][%w%s%-%p]-) starts casting ([%w%s%p]+)%.")
    if mob_name and spell_name then
        -- Strip leading "The " if present.
        local clean = mob_name:gsub('^The ', '')
        local mob = windower.ffxi.get_mob_by_name(clean)
        if mob and mob.id then
            udp_cast:send(string.format('CAST_START|%d|spell|%s', mob.id, spell_name))
            if _ow_cast_debug then
                windower.add_to_chat(207, string.format('[OW] cast_start spell "%s" -> %s (id=%d)',
                    spell_name, clean, mob.id))
            end
        elseif _ow_cast_debug then
            windower.add_to_chat(207, string.format('[OW] cast_start but mob lookup failed: "%s"', clean))
        end
        return
    end

    local mob_name2, move_name = text:match("([A-Z][%w%s%-%p]-) readies ([%w%s%p]+)%.")
    if mob_name2 and move_name then
        local clean = mob_name2:gsub('^The ', '')
        local mob = windower.ffxi.get_mob_by_name(clean)
        if mob and mob.id then
            udp_cast:send(string.format('CAST_START|%d|ability|%s', mob.id, move_name))
            if _ow_cast_debug then
                windower.add_to_chat(207, string.format('[OW] cast_start ability "%s" -> %s (id=%d)',
                    move_name, clean, mob.id))
            end
        elseif _ow_cast_debug then
            windower.add_to_chat(207, string.format('[OW] cast_start ability but mob lookup failed: "%s"', clean))
        end
        return
    end
end)

-- Map numeric job ids to 3-letter abbreviations using the resources table.
local function job_abbr(job_id)
    if not job_id or job_id == 0 then return '' end
    local j = res.jobs[job_id]
    return (j and j.ens) or ''
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Character stats calculator.
--
-- Portions below (the integrate and enhanced tables, and the text-parsing
-- logic) are adapted from 'Checkparam' by from20020516 & Kigen, under a
-- BSD 2-Clause license. Their original copyright:
--   Copyright © 2018, from20020516. All rights reserved.
-- The ow_parse_desc_line / ow_compute_stats functions below use the same
-- parsing approach to walk res.item_descriptions and sum stat values.
-- ═══════════════════════════════════════════════════════════════════════════

-- Alias table: maps shorthand spellings found in item description text to a
-- single canonical stat name. Copied from checkparam for compatibility.
local ow_integrate = {
    ['quad atk'] = 'quadruple attack',
    ['quad attack'] = 'quadruple attack',
    ['triple atk'] = 'triple attack',
    ['double atk'] = 'double attack',
    ['dblatk'] = 'double attack',
    ['blood pact ability delay'] = 'blood pact delay',
    ['blood pact ability delay ii'] = 'blood pact delay ii',
    ['blood pact ab del ii'] = 'blood pact delay ii',
    ['blood pact recast time ii'] = 'blood pact delay ii',
    ['blood pact dmg'] = 'blood pact damage',
    ['enhancing magic duration'] = 'enhancing magic effect duration',
    ['eva'] = 'evasion',
    ['def'] = 'defense',
    ['acc'] = 'accuracy',
    ['att'] = 'attack',
    ['atk'] = 'attack',
    ['ratt'] = 'ranged attack',
    ['ratk'] = 'ranged attack',
    ['racc'] = 'ranged accuracy',
    ['indicolure spell duration'] = 'indicolure effect duration',
    ['indi eff dur'] = 'indicolure effect duration',
    ['mag eva'] = 'magic evasion',
    ['magic eva'] = 'magic evasion',
    ['magic atk bonus'] = 'magic attack bonus',
    ['magatkbns'] = 'magic attack bonus',
    ['mag atk bonus'] = 'magic attack bonus',
    ['mag acc'] = 'magic accuracy',
    ['m acc'] = 'magic accuracy',
    ['r acc'] = 'ranged accuracy',
    ['magic burst dmg'] = 'magic burst damage',
    ['mag dmg'] = 'magic damage',
    ['crithit rate'] = 'critical hit rate',
    ['phys dmg taken'] = 'physical damage taken',
    ['occ. quickens spellcasting'] = 'quick cast',
    ['occassionally quickens spellcasting'] = 'quick cast',
    ['song duration'] = 'song effect duration',
}

-- Hidden 'enhanced' stats that are on specific items but NOT in the item
-- description text. Keyed by item id → 'stat+value' string.
-- (ow_enhanced was forward-declared near the top of the file; this just
-- populates it.)
ow_enhanced = {
    [10392] = 'cursna+10', [10393] = 'cursna+15', [10394] = 'fast cast+5',
    [10469] = 'fast cast+10', [10752] = 'fast cast+2',
    [10790] = 'cursna+10', [10791] = 'cursna+15',
    [10802] = 'fast cast+5', [10806] = 'potency of cure effects received+15',
    [10826] = 'fast cast+3', [10838] = 'dual wield+5',
    [11000] = 'fast cast+3', [11001] = 'fast cast+4',
    [11037] = 'stoneskin+10', [11051] = 'increases resistance to all status ailments+5',
    [11544] = 'fast cast+1', [11602] = 'martial arts+10', [11603] = 'dual wield+3',
    [11615] = 'fast cast+5', [11618] = 'song effect duration+10',
    [11707] = 'fast cast+2', [11711] = 'rewards+2',
    [11715] = 'dual wield+1', [11722] = 'sublimation+1', [11732] = 'dual wield+5',
    [11734] = 'martial arts+10', [11735] = 'snapshot+3',
    [11753] = 'aquaveil+1', [11775] = 'occult acumen+20',
    [11856] = 'fast cast+10',
    [13177] = 'stoneskin+30',
    [14739] = 'dual wield+5', [14812] = 'fast cast+2', [14813] = 'double attack+5',
    [15857] = 'drain and aspir potency+5',
    [15960] = 'stoneskin+20', [15962] = 'magic burst damage+5',
    [16209] = 'snapshot+5',
    [19062] = 'divine benison+1', [19082] = 'divine benison+2',
    [19260] = 'dual wield+3', [19614] = 'divine benison+3',
    [19712] = 'divine benison+3', [19821] = 'divine benison+3',
    [19950] = 'divine benison+3',
    [20509] = 'counter+14', [20511] = 'martial arts+55',
    [20629] = 'song effect duration+5',
    [21062] = 'divine benison+3', [21063] = 'divine benison+3',
    [21078] = 'divine benison+3', [21201] = 'fast cast+2',
    [21699] = 'potency of cure effects received+10',
    [27279] = 'physical damage taken-6', [27280] = 'physical damage taken-7',
    [27768] = 'fast cast+5', [27775] = 'fast cast+10',
    [28054] = 'fast cast+7', [28058] = 'snapshot+4',
    [28184] = 'fast cast+5', [28197] = 'snapshot+9', [28206] = 'fast cast+10',
    [28335] = 'cursna+10',
    [28459] = 'potency of cure effects received+5',
    [28484] = 'cure potency+3', [28485] = 'cure potency+5',
    [28577] = 'potency of cure effects received+5',
    [28582] = 'magic burst damage+5',
    [28619] = 'cursna+15',
    [28631] = 'elemental siphon+30', [28637] = 'fast cast+7',
}

-- Path-augment resolution table for Unity Concord items that return
-- opaque "Path: A/B/C" strings via extdata. Populated with max-rank
-- values from BG-wiki / FFXIclopedia (rank 15). Lower ranks would over-
-- estimate, but most players who augment these items go to max — and
-- the alternative (showing nothing) is worse than slight over-count.
-- Keys are item_id then lowercase "path: a" / "path: b" / "path: c".
ow_path_augments = {
    -- Heishi Shorinken (katana, NIN aeonic)
    -- Path A max: DMG+7, "Blade: Shun" damage+10%, Ranged Acc+30, Magic Acc+30
    -- DMG and Blade: Shun damage don't map to our stat dict; Acc lines do.
    [20977] = {
        ['path: a'] = { 'Ranged Accuracy+30', 'Magic Accuracy+30' },
    },
}

-- JSE Neck augment lookup (formerly held Unity Concord items too).
--
-- HISTORICAL CONTEXT: this table originally stored max-rank augments for
-- BOTH Unity Concord items (Lustreless Scales/Hides/Wings) and JSE Necks.
-- Unity items have since been migrated to gearinfo/res/Unity_Gear.lua,
-- where they sit alongside the per-rank scaling data. GearInfo's
-- find_all_values reads Unity_rank[id].augments and parses them into
-- the item's stats during the gear cache build, so they flow through
-- Gear_info / compute_player_stats natively.
--
-- The remaining JSE neck collection (22 jobs × 3 tiers) plus future
-- entries for any other items with hidden hard-coded augments now
-- live in gearinfo/res/Misc_augments.lua — sourced via loadfile so
-- the file lives alongside the other gear data tables but OmniWatch
-- owns the loading without modifying GearInfo's _loader.lua.
--
-- The file returns a flat [item_id] = { augment_strings } table —
-- same shape as the inline definition that used to live here.
-- Consumers (the gear-walk overlay at line ~9023, fallback when
-- Unity_rank[id].augments isn't set) read ow_unity_augments[id]
-- unchanged.
--
-- Failure mode: if the file is missing or malformed, ow_unity_augments
-- stays empty and JSE neck augments won't apply (extdata-decoded gear
-- still works). A red chat warning fires so it's obvious.
do
    local base = windower.addon_path or ''
    if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
        base = base .. '/'
    end
    local path = base .. 'gearinfo/res/Misc_augments.lua'
    local chunk, load_err = loadfile(path)
    if chunk then
        local ok_run, ret = pcall(chunk)
        if ok_run and type(ret) == 'table' then
            local n = 0
            for k, v in pairs(ret) do
                ow_unity_augments[k] = v
                n = n + 1
            end
            if _ow_buff_debug then
                windower.add_to_chat(207, string.format(
                    '[OmniWatch] Misc_augments loaded: %d entries', n))
            end
        else
            windower.add_to_chat(123, string.format(
                '[OmniWatch] Misc_augments.lua ran but returned no table: %s',
                tostring(ret)))
        end
    else
        windower.add_to_chat(123, string.format(
            '[OmniWatch] Misc_augments.lua not loaded (%s) — JSE neck augments inactive.',
            tostring(load_err)))
    end
end

-- ── Server_Stats module loader ───────────────────────────────────────────
-- Optional, opt-in feature. Loads Server_Stats.lua from the addon root.
-- If the file is missing, OmniWatch runs normally — the feature is a
-- no-op. Default state is DISABLED; user enables explicitly via
-- //ow serverstats on. See Server_Stats.lua header for full docs.
--
-- The module exposes:
--   OW_ServerStats.request(reason)   → schedule outbound 0x061 inject
--   OW_ServerStats.tick()            → call from prerender loop
--   OW_ServerStats.get()             → fresh {patt,def,age_s} or nil
--   OW_ServerStats.on_incoming_chunk → 0x061 incoming dispatcher
--   OW_ServerStats.enable/disable    → runtime toggles
--   OW_ServerStats.set_debug(bool)
--   OW_ServerStats.status()          → diag table
--
-- If the load fails OW_ServerStats stays nil; all call sites use
-- pcall(...) so a nil reference is harmless.
OW_ServerStats = nil
-- Forward-declared flag set by Server_Stats's on_capture callback.
-- Prerender checks this and triggers a stats recompute so the panel
-- reflects the freshly captured server-truth pAtt/def.
_ow_serverstats_dirty = false
do
    local base = windower.addon_path or ''
    if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
        base = base .. '/'
    end
    local path = base .. 'Server_Stats.lua'
    local chunk, load_err = loadfile(path)
    if chunk then
        local ok_run, ret = pcall(chunk)
        if ok_run and type(ret) == 'table' then
            OW_ServerStats = ret
            -- Wire the capture callback: when the module captures a
            -- fresh subtype-384 sample, set the dirty flag. The
            -- prerender loop will see it on its next tick (within
            -- ~16ms) and force a stats recompute + send.
            if OW_ServerStats.set_on_capture then
                OW_ServerStats.set_on_capture(function(patt, def)
                    _ow_serverstats_dirty = true
                end)
            end
            -- Auto-enable on load. The module's request() and
            -- on_incoming_chunk() are no-ops while disabled, so leaving
            -- it off would silently drop all 0x061/0x063 captures.
            -- Per user spec: should be on by default. Wrapped in pcall
            -- in case the module's enable() ever does something risky.
            if OW_ServerStats.enable then
                pcall(OW_ServerStats.enable)
            end
            if _ow_buff_debug then
                windower.add_to_chat(207,
                    '[OmniWatch] Server_Stats module loaded and enabled. '
                    .. 'Use //ow serverstats off to disable.')
            end
        else
            windower.add_to_chat(123, string.format(
                '[OmniWatch] Server_Stats.lua ran but returned no table: %s',
                tostring(ret)))
        end
    else
        -- Missing-file is a normal state for users who removed the module.
        -- Don't yell about it. Only warn if debug is on.
        if _ow_buff_debug then
            windower.add_to_chat(207, string.format(
                '[OmniWatch] Server_Stats.lua not loaded: %s',
                tostring(load_err)))
        end
    end
end

-- Elemental affinity glyphs in item description strings. FFXI/Windower
-- stores them in different byte forms depending on whether the resources
-- file is loaded as Shift-JIS (single bytes 0xE0..0xE7) or as Unicode
-- private-use codepoints (UTF-8 sequences \238\128\128 .. \238\128\135).
-- We scan for BOTH and treat them the same.
--   Glyph order: Fire / Ice / Wind / Earth / Thunder / Water / Light / Dark
-- Note: 'thunder' is the internal key that the Python panel's "Lightning"
-- cell maps to (FFXI's res uses 'thunder' for the lightning element).
local PW_ELEM_KEYS = {
    'fire', 'ice', 'wind', 'earth',
    'thunder', 'water', 'light', 'dark',
}
-- Build single-byte patterns 0xE0..0xE7
local PW_ELEM_PATTERNS = {}
for i, key in ipairs(PW_ELEM_KEYS) do
    local b = 0xDF + i  -- 0xE0..0xE7
    PW_ELEM_PATTERNS[#PW_ELEM_PATTERNS + 1] =
        {pat = string.char(b),                              key = key}
    -- UTF-8 form: 0xEE 0x80 0x80..0x87 corresponds to U+E000..U+E007
    PW_ELEM_PATTERNS[#PW_ELEM_PATTERNS + 1] =
        {pat = string.char(0xEE, 0x80, 0x80 + (i - 1)),     key = key}
end

-- Walk an item description string and accumulate per-element values
-- into the stats dict. Looks for any of the glyph patterns followed
-- (with optional whitespace) by an integer with optional sign. Each
-- match adds the integer value to stats[<element>].
local function ow_extract_elem_glyphs(tbl, text)
    if not text or text == '' then return end
    for _, p in ipairs(PW_ELEM_PATTERNS) do
        -- Lua patterns: %s* matches whitespace, ([%+%-]?%d+) captures
        -- optional sign + digits. We use plain string.find with init
        -- in a loop so the byte-pattern is treated literally.
        local i = 1
        while true do
            local s, e = text:find(p.pat, i, true)  -- plain match
            if not s then break end
            -- Look for the number that follows.
            local rest = text:sub(e + 1)
            local num = rest:match('^%s*([%+%-]?%d+)')
            if num then
                local v = tonumber(num)
                if v then
                    tbl[p.key] = (tbl[p.key] or 0) + v
                end
            end
            i = e + 1
        end
    end
end

-- Parse a single line of description text and push each "key:value" or
-- "key+value" pair into the stats dict (summing if already present).
-- prefix: optional (e.g. 'pet: ') prepended to each key for pet-stat blocks.
local function ow_parse_desc_line(tbl, text, prefix)
    if not text or text == '' then return end
    -- Pattern mirrors checkparam: capture a non-digit key, optional colon,
    -- then a signed integer, optional % and trailing whitespace.
    for key, value in string.gmatch(text, '/?([%D]-):?([%+%-]?[0-9]+)%%?%s?') do
        key = string.lower(key)
        -- Strip surrounding quotes, periods, or trailing whitespace artifacts.
        key = key:gsub('^"(.-)"$', '%1')
        key = key:gsub('%.', '')
        key = key:gsub('%s+$', '')
        key = key:gsub('^%s+', '')
        -- Strip trailing +/- and any whitespace before it. Gear lines
        -- like "Fire +10" or "Wind -5" leave the sign in the key
        -- because the lazy %D- match grabs everything up to the digit.
        -- Without this, key 'fire +' would never match the panel's
        -- 'fire' cell lookup.
        key = key:gsub('[%+%-]+%s*$', '')
        key = key:gsub('%s+$', '')
        if key ~= '' then
            key = ow_integrate[key] or key
            if prefix then key = prefix .. key end

            local v = tonumber(value)
            if v then
                -- DEBUG: log Store TP / Dual Wield contributions
                if _ow_cast_debug and v ~= 0 then
                    if key == 'store tp' then
                        windower.add_to_chat(207, string.format(
                            '[OW] stp+: +%d from "%s"', v, text:sub(1, 60)))
                    elseif key == 'dual wield' then
                        windower.add_to_chat(207, string.format(
                            '[OW] dw+: +%d from "%s"', v, text:sub(1, 60)))
                    end
                end
                -- checkparam expands 'damage taken' into physical/magic/breath.
                -- We track BOTH the generic-DT-only sum (so the DT cell
                -- shows what came from generic "Damage taken" lines) AND
                -- the three specific sub-types (so PDT/MDT/BDT cells
                -- reflect total contribution from BOTH generic + specific).
                if key == 'damage taken' then
                    tbl['damage taken']          = v + (tbl['damage taken']          or 0)
                    tbl['physical damage taken'] = v + (tbl['physical damage taken'] or 0)
                    tbl['magic damage taken']    = v + (tbl['magic damage taken']    or 0)
                    tbl['breath damage taken']   = v + (tbl['breath damage taken']   or 0)
                elseif key == 'pet: damage taken' then
                    tbl['pet: damage taken']          = v + (tbl['pet: damage taken']          or 0)
                    tbl['pet: physical damage taken'] = v + (tbl['pet: physical damage taken'] or 0)
                    tbl['pet: magic damage taken']    = v + (tbl['pet: magic damage taken']    or 0)
                elseif key == 'blood pact damage' then
                    tbl['pet: blood pact damage'] = v + (tbl['pet: blood pact damage'] or 0)
                else
                    tbl[key] = v + (tbl[key] or 0)
                end
            end
        end
    end
end

-- ─── Augment introspection helpers ─────────────────────────────────────
-- Used by the sim inventory builder to differentiate items that share an
-- item id but carry different augments (e.g. multiple Camulus's Mantles).
-- Declared as globals (not locals) so they're callable from earlier in
-- the file (the SIM_INV builder around line ~1170, which runs after
-- module load completes — by then these are bound).
function ow_get_item_augments(bag, idx)
    if not bag or not idx or idx == 0 then return nil end
    if not (windower.ffxi.get_items) then return nil end
    local item = windower.ffxi.get_items(bag, idx)
    if not item or not item.id or item.id == 0 then return nil end
    local augs
    -- Prefer extdata.decode (Windower's library) since it's authoritative.
    if extdata and item.extdata then
        local ok, ext = pcall(extdata.decode, {id = item.id, extdata = item.extdata})
        if ok and ext and ext.augments then augs = ext.augments end
    end
    if not augs and item.augments then augs = item.augments end
    if type(augs) ~= 'table' then return nil end
    local cleaned = {}
    for _, a in ipairs(augs) do
        if a and a ~= '' and a ~= 'none' then
            local s = tostring(a):gsub('^%s+', ''):gsub('%s+$', '')
            if s ~= '' then cleaned[#cleaned+1] = s end
        end
    end
    if #cleaned == 0 then return nil end
    return cleaned
end

function ow_augment_fingerprint(augs)
    if type(augs) ~= 'table' or #augs == 0 then return '' end
    local sorted = {}
    for _, a in ipairs(augs) do sorted[#sorted+1] = tostring(a) end
    table.sort(sorted)
    return table.concat(sorted, '|')
end

-- Map a parsed stat key onto a 3-4 char abbreviation for the dropdown tag.
-- Keys not in this table fall through to a sensible default (first word
-- title-cased, truncated to 5 chars).
local _OW_AUG_TAG_ABBREV = {
    ['str']                   = 'STR',
    ['dex']                   = 'DEX',
    ['vit']                   = 'VIT',
    ['agi']                   = 'AGI',
    ['int']                   = 'INT',
    ['mnd']                   = 'MND',
    ['chr']                   = 'CHR',
    ['accuracy']              = 'Acc',
    ['attack']                = 'Att',
    ['ranged accuracy']       = 'RAcc',
    ['ranged attack']         = 'RAtt',
    ['magic accuracy']        = 'MAcc',
    ['magic attack bonus']    = 'MAB',
    ['magic damage']          = 'MDmg',
    ['weapon skill damage']   = 'WSD',
    ['critical hit rate']     = 'Crit',
    ['double attack']         = 'DA',
    ['triple attack']         = 'TA',
    ['quadruple attack']      = 'QA',
    ['store tp']              = 'STP',
    ['subtle blow']           = 'SubB',
    ['subtle blow ii']        = 'SubB2',
    ['dual wield']            = 'DW',
    ['phantom roll']          = 'PR+',
    ['fast cast']             = 'FC',
    ['quick magic']           = 'QM',
    ['haste']                 = 'Hst',
    ['enmity']                = 'Enm',
    ['regen']                 = 'Rgn',
    ['refresh']               = 'Rfr',
    ['movement speed']        = 'Move',
    ['hp']                    = 'HP',
    ['mp']                    = 'MP',
    ['evasion']               = 'Eva',
    ['magic evasion']         = 'MEva',
    ['defense']               = 'Def',
    ['magic defense bonus']   = 'MDB',
    ['cure potency']          = 'CurP',
    ['blood pact damage']     = 'BPD',
    ['pet: damage taken']     = 'PetDT',
    ['skillchain damage']     = 'SCD',
}

function ow_augment_tag(augs)
    if type(augs) ~= 'table' or #augs == 0 then return '' end
    -- Build a compact tag with abbreviated stat keys + their values.
    -- Example output: "DEX+30/Acc+30/WSD+10".
    -- All augments are included (no cap), since multiple augmented
    -- copies of the same item often share early stats and only differ
    -- on later ones. Capping would make distinct items look identical.
    --
    -- Each augment string is parsed via ow_parse_desc_line; the first
    -- (key, value) pair is used. If the parser produces nothing, the
    -- raw augment string is included instead so the user still sees
    -- something distinguishing.
    local seen = {}
    local tags = {}
    for _, a in ipairs(augs) do
        local raw = tostring(a)
        local tmp = {}
        ow_parse_desc_line(tmp, raw)
        local emitted = false
        for k, v in pairs(tmp) do
            if not seen[k] then
                seen[k] = true
                local abbr = _OW_AUG_TAG_ABBREV[k]
                if not abbr then
                    local first = k:match('^(%w+)') or k
                    abbr = first:sub(1, 1):upper() .. first:sub(2, 5)
                end
                -- Format value with sign — positive numbers get a
                -- leading +; negative numbers already have the minus.
                local sval
                if type(v) == 'number' then
                    sval = (v >= 0) and ('+' .. tostring(v)) or tostring(v)
                else
                    sval = tostring(v)
                end
                tags[#tags+1] = abbr .. sval
                emitted = true
                break
            end
        end
        if not emitted then
            -- Parser produced nothing — fall back to a short form of
            -- the raw augment string so the user has SOMETHING to
            -- distinguish copies. Strip wire-delimiters that would
            -- corrupt the SIM_INV protocol.
            local short = raw:gsub('[;:|]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
            if short ~= '' then tags[#tags+1] = short end
        end
    end
    return table.concat(tags, '/')
end

-- Compute the full stat dict from currently equipped gear.
-- ═════════════════════════════════════════════════════════════════════════
-- Haste estimation from player.buffs. Best-effort approximations: the
-- game doesn't distinguish Haste I from Haste II via buff id alone, so we
-- assume the higher tier when ambiguous. Values are in percent.
--
-- Categories: 'ma' (magic-haste, cap 43.75%), 'ja' (job-ability haste,
-- cap 25%). Gear haste (cap 25%) is summed from the description parser.
-- ═════════════════════════════════════════════════════════════════════════
-- buff_id → {category, percent} (assumes best-case tier where ambiguous)
-- Static haste-buff table. Values verified against GearInfo's
-- Buff_Processing.lua. Most are literal /1024 conversions to %:
--   GI 150 / 1024 ≈ 14.65%   (was wrong as 30.0 here)
--   GI 307 / 1024 ≈ 30.0%
--   GI 260 / 1024 ≈ 25.4%
--   GI 306 / 1024 ≈ 29.9%
-- Buffs with multiple spell variants (Haste/Haste II), dynamic scaling
-- (Last Resort with Desperate Blows, Hasso with gear), or stacking
-- mechanics (March via _ow_buff_sources) are handled in special-case
-- code paths and may have placeholder pct here.
local PW_HASTE_BUFFS = {
    -- ─── Magical haste ─────────────────────────────────────────────
    [ 33] = {cat='ma', pct=14.65},  -- Haste I (overridden by snoop for Haste II=30.0%)
    [214] = {cat='ma', pct=15.9},   -- March bucket; actual sum from _ow_buff_sources
    [228] = {cat='ma', pct=25.4},   -- Embrava (capped at 500+ enhancing)
    [580] = {cat='ma', pct=29.9},   -- Indi/Geo-Haste (base, no bolster)
    [604] = {cat='ma', pct=14.65},  -- Mighty Guard
    -- ─── JA haste ──────────────────────────────────────────────────
    [ 64] = {cat='ja', pct=15.2},   -- Last Resort (DRK99 base 156/1024≈15.2%)
    [273] = {cat='ja', pct=10.0},   -- Aftermath (Catastrophe / Liberator)
    [353] = {cat='ja', pct=10.0},   -- Hasso (103/1024≈10.06%)
    [370] = {cat='ja', pct=5.0},    -- Haste Samba (sub DNC, ~50/1024)
    [582] = {cat='ja', pct=10.0},   -- Impetus / other
    -- ─── Magical haste DEBUFFS (negative) ──────────────────────────
    [  1] = {cat='ma', pct=-100.0}, -- Weakness: full magic haste lost
    [ 13] = {cat='ma', pct=-29.3},  -- Slow / Slow II (300/1024 reduction)
    [565] = {cat='ma', pct=-19.9},  -- Indi-Slow / Geo-Slow (204/1024)
    [194] = {cat='ma', pct=-50.0},  -- Elegy (512/1024)
}

-- Movement-speed buff/debuff IDs → percent contribution.
-- Gear movement speed is summed separately (from description parser).
-- Positive entries: movement-speed boosts. Take the MAX among positives
--   since most don't stack (Mazurka + Bolt Storm → only the larger wins).
-- Negative entries: movement-speed reductions (Weight, Bind, etc.).
--   Apply additively AFTER positives.
-- Bolter's Roll fractional multiplier by roll value (1..11). Source:
-- GearInfo's Cor_Rolls.lua [118] table (BSD-2). Each value is the
-- coefficient that multiplies the gear-speed sum: total_with_bolters
-- = (1 + gear_speed_pct/100) * (1 + roll_fraction). Roll 12 is a bust
-- (cleared by snoop logic); roll 3 is Lucky, roll 11 is best non-bust.
local PW_BOLTERS_FRACTION = {
    [ 1] = 0.3,
    [ 2] = 0.3,
    [ 3] = 0.8,    -- Lucky 3
    [ 4] = 0.4,
    [ 5] = 0.4,
    [ 6] = 0.5,
    [ 7] = 0.5,
    [ 8] = 0.6,
    [ 9] = 0.2,    -- Unlucky 9
    [10] = 0.7,
    [11] = 1.0,    -- Lucky 11 (best non-bust)
}

-- Default Bolter's fraction when we haven't snooped the active roll
-- value (e.g. omniwatch reloaded mid-buff). Roll 1-2 baseline.
local PW_BOLTERS_DEFAULT_FRACTION = 0.3

-- ── March song haste (BRD) ─────────────────────────────────────────────
-- (Definitions moved to top of file — must be in scope before action
-- handler can reference them. See block near PW_MARCH_BUFF_ID.)

-- ── Haste spells ────────────────────────────────────────────────────────
-- Maps spell_id (cat 4) → magic haste %. Haste II overrides Haste I when
-- both attempt to land (the higher always wins via the cat-4 snoop's
-- "remove other spell entries" logic).
-- Haste spell potency. GearInfo values:
--   Haste I:                 150/1024 = 14.65%
--   Haste II / Erratic Flutter / Hastega II: 307/1024 = 30.0%
--   Refueling (PUP):         102/1024 ≈ 9.96%
-- NOTE: declared as a GLOBAL (no `local` prefix). The action handler
-- at line ~4422 references this table; making it local-here would
-- cause "attempt to index global 'PW_HASTE_SPELL_POTENCY' (a nil
-- value)" since locals only enter scope at their declaration line.
PW_HASTE_SPELL_POTENCY = {
    [57]  = 14.65,   -- Haste
    [511] = 30.0,    -- Haste II
}

-- Movement speed cap: hard limit is +60% over base (160% total).
local PW_SPEED_CAP_OVER_BASE = 60

-- Resolve speed-related buff IDs from Windower's res.buffs by name,
-- so we never hardcode incorrect numbers. Built once at addon load.
-- Falls back to nil if a name isn't found, in which case that buff
-- silently doesn't contribute (better than firing on a wrong id).
local function _ow_buff_id_by_name(name)
    local b = res.buffs:with('en', name)
    return b and b.id or nil
end

local PW_BUFF_BOLTERS    = _ow_buff_id_by_name("Bolter's Roll")
local PW_BUFF_MAZURKA    = _ow_buff_id_by_name("Mazurka")
local PW_BUFF_QUICKENING = _ow_buff_id_by_name("Quickening")
-- "Bolt Storm" is the buff applied by both the COR ability and the GEO
-- aura (Indi-/Geo-Bolt Storm), all sharing the same client-side buff id.
local PW_BUFF_BOLT_STORM = _ow_buff_id_by_name("Bolt Storm")
local PW_BUFF_WEIGHT     = _ow_buff_id_by_name("Weight")
local PW_BUFF_BIND       = _ow_buff_id_by_name("Bind")
local PW_BUFF_ENCUMBRANCE= _ow_buff_id_by_name("Encumbrance")
-- Flurry I and II: ranged-attack delay reduction (effectively a snapshot
-- bonus). Two distinct buff ids — Flurry I from RDM/Hastemaster, Flurry II
-- from BLU spell or Geo. Both names resolve to "Flurry" in res.buffs which
-- is unhelpful (id 265 for Flurry I, id 581 also named "Flurry" for II).
-- Hardcoded since the name lookup would collide.
local PW_BUFF_FLURRY_I  = 265
local PW_BUFF_FLURRY_II = 581
-- (PW_BUFF_SOUL_VOICE / PW_BUFF_MARCATO / PW_BUFF_CROOKED_CARDS moved to
--  top of file ~line 1220 since action handler references them — Lua
--  locals are forward-only-visible.)

-- Return total effective movement speed % (negative possible when debuffed).
-- Implements BG-wiki's published formula:
--   (100 + max(gear)) * (1 + bolters)
--   + min(quickening + mazurka, 20)
--   + other_positives + negatives
-- Clamped to ±[base..base+60], rounded down to nearest even.
-- The value returned is the bonus *over base* (so 0 = normal speed,
-- 25 = +25% movement, -50 = halved by Weight, etc.).
local function ow_compute_speed(gear_speed_pct, stats_dict)
    local player = windower.ffxi.get_player()
    local has_bolters = false
    local quickening = 0    -- Quickening
    local mazurka    = 0    -- Mazurka
    local bolt_storm = 0    -- Bolt Storm (also covers Geo/Indi-Bolt Storm
                            -- since they grant the same client-side buff)
    local neg_total  = 0
    if player and player.buffs then
        for _, bid in ipairs(player.buffs) do
            if     bid == PW_BUFF_BOLTERS    then has_bolters = true
            elseif bid == PW_BUFF_QUICKENING then quickening = 40
            elseif bid == PW_BUFF_MAZURKA    then mazurka    = 25
            elseif bid == PW_BUFF_BOLT_STORM then bolt_storm = 30
            elseif bid == PW_BUFF_WEIGHT     then neg_total = neg_total - 50
            elseif bid == PW_BUFF_BIND       then neg_total = neg_total - 100
            elseif bid == PW_BUFF_ENCUMBRANCE then neg_total = neg_total - 25
            end
        end
    end
    -- Clear cached Bolter's roll value when the buff drops, so a new
    -- roll on the same character starts fresh rather than reusing data.
    if not has_bolters and _ow_bolters_value ~= 0 then
        _ow_bolters_value = 0
    end

    local gear = gear_speed_pct or 0

    -- Step 1: Apply Bolter's multiplier to (100 + gear). This is the
    -- multiplicative path. Without Bolter's, base = 100 + gear directly.
    local base_plus_gear = 100 + gear
    if has_bolters then
        local frac = PW_BOLTERS_FRACTION[_ow_bolters_value]
                  or PW_BOLTERS_DEFAULT_FRACTION
        -- Phantom Roll+ gear from user_config raises the fraction by
        -- 0.2 per level for Bolter's (matches Cor_Rolls.lua roll+1=0.2).
        -- The COR who rolls determines this, so for non-COR jobs the
        -- value should remain 0 unless the user knows their roller's
        -- gear matches their config (rare and can be left at 0).
        local pr_plus = ow_cfg_phantom_roll_plus(stats_dict)
        if pr_plus > 0 then
            frac = frac + (0.2 * pr_plus)
        end
        base_plus_gear = base_plus_gear * (1 + frac)
    end

    -- Convert "total %" back to "bonus over 100% base".
    local bonus = base_plus_gear - 100

    -- Step 2: Quickening + Mazurka contribution, capped at +20% combined.
    -- These are additive with the multiplied result, NOT multiplicative.
    local q_m = math.min(quickening + mazurka, 20)
    bonus = bonus + q_m

    -- Step 3: Other positives (Bolt Storm aura) — flat addition.
    local other_pos = bolt_storm
    bonus = bonus + other_pos

    -- Step 4: Apply negatives.
    bonus = bonus + neg_total

    -- Step 5: Cap at +60 over base (the 160% total cap), allow negatives.
    if bonus > PW_SPEED_CAP_OVER_BASE then
        bonus = PW_SPEED_CAP_OVER_BASE
    end

    -- Step 6: Client only displays even values. Round down to nearest even.
    bonus = math.floor(bonus / 2) * 2

    return bonus
end

-- Compute magic-haste, JA-haste, and total-haste from player.buffs.
-- Returns (gear_haste_capped, magic_haste_capped, ja_haste_capped, total_haste).
local function ow_compute_haste(gear_haste_pct)
    local player = windower.ffxi.get_player()
    local ma_haste, ja_haste = 0, 0
    -- Detect which buffs are currently active (so we know when to use
    -- source data vs ignore stale entries).
    local active = {}
    if player and player.buffs then
        for _, bid in ipairs(player.buffs) do active[bid] = true end
    end

    -- Magic haste comes from two buff IDs:
    --   33  = Haste spell / Geo-Haste / Erratic Flutter / etc.
    --   214 = March (Honor / Victory / Advancing — multiple stack here)
    -- For each, if we have snooped sources, sum their precise potencies.
    -- Otherwise fall back to PW_HASTE_BUFFS for buff 33 (no fallback for
    -- 214 since the per-march potency varies too much to guess).
    if active[33] then
        local srcs = _ow_buff_sources[33]
        if srcs and #srcs > 0 then
            for _, s in ipairs(srcs) do
                if s.src_kind == 'song' or s.src_kind == 'spell' then
                    ma_haste = ma_haste + (tonumber(s.potency) or 0)
                end
            end
        else
            -- No source data — use static fallback (covers the case
            -- where PW reloaded mid-buff and we missed the cast).
            local entry = PW_HASTE_BUFFS[33]
            if entry and entry.cat == 'ma' then
                ma_haste = ma_haste + entry.pct
            end
        end
    end
    if active[PW_MARCH_BUFF_ID] then
        local srcs = _ow_buff_sources[PW_MARCH_BUFF_ID]
        if srcs and #srcs > 0 then
            for _, s in ipairs(srcs) do
                if s.src_kind == 'song' then
                    ma_haste = ma_haste + (tonumber(s.potency) or 0)
                end
            end
        end
    end

    -- Other haste buffs (non-id-33, non-march) still use the static map.
    if player and player.buffs then
        for _, bid in ipairs(player.buffs) do
            if bid ~= 33 and bid ~= PW_MARCH_BUFF_ID then
                local entry = PW_HASTE_BUFFS[bid]
                if entry then
                    if entry.cat == 'ma' then
                        ma_haste = ma_haste + entry.pct
                    elseif entry.cat == 'ja' then
                        ja_haste = ja_haste + entry.pct
                    end
                end
            end
        end
    end

    -- Return RAW values (uncapped). The Python renderer compares against
    -- STAT_CAPS and shows over-cap values in red. Total haste is summed
    -- from RAW components but bounded to 80% (the global delay-reduction
    -- cap) since values above that aren't physically meaningful.
    local raw_gear = gear_haste_pct or 0
    local raw_ma   = ma_haste
    local raw_ja   = ja_haste
    -- Total haste uses CAPPED component values (because that's what the
    -- game actually uses to compute attack speed) but capped at 80%.
    local total = math.min(math.min(raw_gear, 25)
                          + math.min(raw_ma, 43.75)
                          + math.min(raw_ja, 25), 80)
    return raw_gear, raw_ma, raw_ja, total
end

-- Map from GearInfo Set_bonus stat keys → our lowercase stat-dict keys.
-- The keys that are already lowercase match directly; this table handles
-- the abbreviated and mixed-case forms.
local _PW_SET_BONUS_STAT_MAP = {
    ["STR"] = "str", ["DEX"] = "dex", ["VIT"] = "vit", ["AGI"] = "agi",
    ["INT"] = "int", ["MND"] = "mnd", ["CHR"] = "chr",
    ["HP"]  = "hp",  ["MP"]  = "mp",
    ["DEF"] = "defense",
    ["Accuracy"] = "accuracy",
    ["Attack"]   = "attack",
    ["Ranged Accuracy"] = "ranged accuracy",
    ["Magic Accuracy"]  = "magic accuracy",
    ["Magic Atk. Bonus"]= "magic attack bonus",
    ["Critical Hit Rate"]= "critical hit rate",
    ["Critical hit damage"] = "critical hit damage",
    ["Cure potency"]    = "cure potency",
    ["Cure potency II"] = "cure potency ii",
    ["Double Attack"]   = "double attack",
    ["Triple Attack"]   = "triple attack",
    ["Dual Wield"]      = "dual wield",
    ["Fast Cast"]       = "fast cast",
    ["Haste"]           = "haste",
    ["Store TP"]        = "store tp",
    ["Subtle Blow"]     = "subtle blow",
    ["Martial Arts"]    = "martial arts",
    ["Weapon Skill Damage"] = "weapon skill damage",
    ["Counter"]         = "counter",
    ["Refresh"]         = "refresh",
    ["Regen"]           = "regen",
    ["DT"]  = "damage taken",
    ["PDT"] = "physical damage taken",
    ["MDT"] = "magic damage taken",
}

-- Map from Cor_Rolls.lua effect names → our lowercase stat-dict keys.
-- Only maps rolls whose effect contributes to a stat we display.
-- Bolter's Roll's "Movement Speed" effect is special-cased in
-- ow_compute_speed and intentionally absent here.
-- Map from Cor_Rolls.lua effect names → our stat-dict keys.
-- Covers all 23 standard rolls and 5 pet rolls per the BG-wiki chart.
-- Each roll's "effect" field in Cor_Rolls.lua names what it boosts;
-- this table tells us where to apply it on the stats panel.
local _PW_ROLL_EFFECT_MAP = {
    -- Combat rolls
    ["Acc & R.Acc"]         = {"accuracy", "ranged accuracy"},  -- Hunter's
    ["Atk & R.Atk"]         = {"attack",   "ranged attack"},    -- Chaos
    ["Double Atk"]          = "double attack",                  -- Fighter's
    ["Crit Rate"]           = "critical hit rate",              -- Rogue's
    ["Crit Hit Rate"]       = "critical hit rate",              -- alt name
    ["Subtle Blow"]         = "subtle blow",                    -- Monk's
    ["Store TP"]            = "store tp",                       -- Samurai's
    ["Save TP"]             = "save tp",                        -- Miser's
    ["Counter"]             = "counter",                        -- Avenger's
    ["Defense"]             = "defense",                        -- Gallant's
    ["Evasion"]             = "evasion",                        -- Ninja's
    -- Magic rolls
    ["MAB"]                 = "magic attack bonus",             -- Wizard's (gear key)
    ["M.Acc"]               = "magic accuracy",                 -- Warlock's
    ["M.Eva"]               = "magic evasion",                  -- Runeist's
    ["M.Def"]               = "magic defense bonus",            -- Magus's
    ["Conserve MP"]         = "conserve mp",                    -- Scholar's
    ["Magic Attack Bonus"]  = "magic attack bonus",             -- alt naming
    ["Magic Accuracy"]      = "magic accuracy",
    ["Magic Atk. Bonus"]    = "magic attack bonus",
    ["Magic Def. Bonus"]    = "magic defense bonus",
    ["Magic Defense"]       = "magic defense bonus",
    -- Cast / casting rolls
    ["Fast Cast"]           = "fast cast",                      -- Caster's
    ["Snapshot"]            = "snapshot",                       -- Courser's
    ["Spell Int Rate"]      = "spell interruption rate",        -- Choral (debuff)
    ["Spell Interruption Rate"] = "spell interruption rate",
    -- Healing / regen rolls
    ["Cure Pot Received"]   = "cure potency received",          -- Healer's
    ["Refresh"]             = "refresh",                        -- Evoker's
    ["Regen"]               = "regen",                          -- Tactician's (Regain actually)
    ["Regain"]              = "regain",                         -- Tactician's
    ["Enhancing Magic Dur"] = "enhancing magic duration",       -- Naturalist's
    -- Damage / skillchain
    ["Skillchain Damage"]   = "skillchain damage",
    ["SC Dmg & Acc"]        = {"skillchain damage", "accuracy"},-- Allies'
    ["Delay Reduction"]     = "delay reduction",                -- Blitzer's
    ["Movement Speed"]      = "movement speed",                 -- Bolter's (special-case)
    ["Accuracy"]            = "accuracy",
    ["Ranged Accuracy"]     = "ranged accuracy",
    ["Attack"]              = "attack",
    ["Ranged Attack"]       = "ranged attack",
    -- Pet rolls (only apply if user has pet — we skip those without)
    ["Pet Acc & R.Acc"]     = {"pet accuracy", "pet ranged accuracy"},
    ["Pet Atk & R.Atk"]     = {"pet attack",   "pet ranged attack"},
    ["Pet M.Acc & M.Atk"]   = {"pet magic accuracy", "pet magic attack bonus"},
    ["Pet Regain"]          = "pet regain",
    ["Pet Regen"]           = "pet regen",
    -- XP/CP roll (Corsair's): doesn't show on stats panel, no mapping.
    -- ["XP/CP/EP"] = nil,
}

-- Map from Gifts.lua gift names → our lowercase stat-dict keys.
-- Only maps gifts that affect our visible stats panel; non-stat gifts
-- (Superior, Fencer Effect, trait bonuses, pet effects) are ignored.
-- GLOBAL (no `local`) so command handlers above can reference the same
-- table the apply loop uses. Lua won't share locals across function
-- scopes — the //ow dumpgifts command at line ~2818 needs to see the
-- same name→stat mapping that compute_stats applies, otherwise the
-- diagnostic shows "(NOT IN MAP)" for entries that ARE actually mapped.
_PW_GIFT_STAT_MAP = {
    ["Physical Attack Bonus"]    = "attack",
    ["Physical Defense Bonus"]   = "defense",
    ["Physical Accuracy Bonus"]  = "accuracy",
    ["Physical Evasion Bonus"]   = "evasion",
    ["Magic Attack Bonus"]       = "magic attack bonus",
    ["Magic Defense Bonus"]      = "magic defense bonus",
    ["Magic Accuracy Bonus"]     = "magic accuracy",
    ["Magic Accuracy bonus"]     = "magic accuracy",
    ["Magic Evasion Bonus"]      = "magic evasion",
    ["Magic Damage Bonus"]       = "magic damage",
    ["Magic Burst Damage"]       = "magic burst damage",
    ["Double Attack Effect"]     = "double attack",
    ["Triple Attack Chance"]     = "triple attack",
    ["Dual Wield Effect"]        = "dual wield",
    ["Fast Cast Effect"]         = "fast cast",
    ["Store TP Effect"]          = "store tp",
    ["Subtle Blow Effect"]       = "subtle blow",
    ["Weapon Skill Damage"]      = "weapon skill damage",
    ["Critical Hit Bonus"]       = "critical hit rate",
    ["Critical Damage Bonus"]    = "critical hit damage",
    ["Critical Damage Dealt"]    = "critical hit damage",
    ["Martial Arts Effect"]      = "martial arts",
    ["Snapshot Effect"]          = "snapshot",
    ["Cure Potency Bonus"]       = "cure potency",
    ["Regen Bonus"]              = "regen",
    ["Counter Effect"]           = "counter",
    ["Enspell Damage"]           = "enspell damage",
    ["Enhancing Magic Skill"]    = "enhancing magic skill",
    ["Enfeebling Magic Skill"]   = "enfeebling magic skill",
    ["Healing Magic Skill"]      = "healing magic skill",
    ["Divine Magic Skill"]       = "divine magic skill",
    ["Dark Magic Skill"]         = "dark magic skill",
    ["Elemental Magic Skill"]    = "elemental magic skill",
    ["Summoning Magic Skill"]    = "summoning magic skill",
    ["Blue Magic Skill"]         = "blue magic skill",
    ["Song Effect Duration"]     = "song effect duration",
    ["Song Spellcasting Time"]   = "song spellcasting time",
    ["Singing Skill Bonus"]      = "singing skill",
    ["String Instrument Skill"]  = "string skill",
    ["Wind Instrument Skill"]    = "wind skill",
    ["Ninjutsu Effect Duration"] = "ninjutsu duration",
    ["Ninjutsu Skill Bonus"]     = "ninjutsu skill",
    ["Handbell Skill Bonus"]     = "handbell skill",
    ["Geomancy Skill Bonus"]     = "geomancy skill",
    ["Guarding Skill Bonus"]     = "guarding skill",
    ["Ranged Accuracy Bonus"]    = "ranged accuracy",
    ["Ranged Attack Bonus"]      = "ranged attack",
    -- Gifts not in this map (e.g. "Superior", pet stats, trait bonuses)
    -- are silently dropped. Add here as they become relevant.
}

function ow_compute_stats()
    -- Reset GearInfo-wrote-combat-stats flag for this compute. Set true
    -- below if the GearInfo backend successfully wrote acc/att/eva/def.
    -- Downstream song/buff/trait blocks check this and skip their adds.
    _gi_wrote_combat_stats = false

    if _ow_cast_debug then
        _ow_compute_stats_call_count = (_ow_compute_stats_call_count or 0) + 1
        if _ow_compute_stats_call_count <= 3 or _ow_compute_stats_call_count % 30 == 0 then
            windower.add_to_chat(207, '[OW] compute_stats called #' .. tostring(_ow_compute_stats_call_count))
        end
    end

    -- Sim mode: previously this short-circuited the entire gear scan and
    -- emitted only zeros + sim-buff contributions, so the panel showed
    -- buff-only baselines. User feedback: that's not what they want.
    -- They need to see CURRENT real stats and watch sim buffs ADD on top
    -- so they can decide if e.g. +6 March is enough to push them over a
    -- threshold without re-gearing.
    --
    -- New flow: don't bail here. Run the full real compute (gear, JP,
    -- traits, GearInfo backend) all the way down. AFTER that pipeline
    -- finishes and we've populated `stats` with real values, we layer
    -- sim buff bonuses on top (see "sim_on" block near the end of this
    -- function).
    --
    -- We still capture sim_on into a local so downstream code can use it.
    local sim_on = (_sim and _sim.is_active and _sim.is_active()) or false

    local stats = {}

    -- ── Sim mode is now a layered DELTA on top of the live compute ─────
    -- The starting stats table is built from the same live merges as
    -- non-sim mode (player.stats, gear scan, real food, real buffs,
    -- traits, gifts). Sim's only job is to:
    --   1) Override specific gear slots (so stats reflect a what-if set)
    --   2) Add the user's selected sim food on top of live food
    --   3) Add the user's selected sim buffs on top of live buffs
    -- Equipment override is applied below where the gear scan reads
    -- the equipment table; food/buffs are applied at the bottom of
    -- this function in the sim_on overlay block.

    local equipment = windower.ffxi.get_items and windower.ffxi.get_items('equipment')
    if not equipment then return stats end

    -- When sim is on, layer the user's gear picks ON TOP of the live
    -- equipment table. Per the new spec, sim is a delta calculator:
    -- start from what the player is currently wearing, then swap in
    -- whatever the user picked in the sim window. Slots the user
    -- hasn't picked stay LIVE, so the panel shows real-character
    -- stats and changes only where sim'd gear differs.
    --
    -- Items the user explicitly cleared (sim_eq[slot] == 0) become
    -- empty in the synthetic table — that's how the user can sim
    -- "what if I unequipped my back item" without giving up the
    -- rest of the live set.
    --
    -- For sim'd slots with a real item id, we look the item up in
    -- inventory bags via the cached id→(bag,idx) lookup so the
    -- existing code's `windower.ffxi.get_items(bag, index)` call
    -- still works and returns full item_data including augments.
    if sim_on and _sim and _sim.get_equipment then
        local sim_eq = _sim.get_equipment() or {}
        local synth = {}
        -- Copy the live equipment table as the default. This includes
        -- slot indices, bag ids, and all the other fields windower
        -- exposes (main_aug, sub_aug, etc.) — preserving them is
        -- essential since the gear scan reads augment data via these.
        if equipment then
            for k, v in pairs(equipment) do
                synth[k] = v
            end
        end
        -- For each sim'd slot, override the slot's idx/bag with the
        -- picked item's location. The reference can be an integer
        -- (legacy id-only) or a table {id, bag, idx} (instance-keyed
        -- for augmented items).
        for slot_key, ref in pairs(sim_eq) do
            -- "Empty" sentinel: int 0 or a table with id<=0
            local is_empty = (type(ref) == 'number' and ref == 0)
                          or (type(ref) == 'table' and (tonumber(ref.id) or 0) <= 0)
            if is_empty then
                synth[slot_key]           = 0
                synth[slot_key .. '_bag'] = 0
            else
                local bag, idx = _ow_resolve_sim_equip(ref)
                if bag and idx then
                    synth[slot_key]            = idx
                    synth[slot_key .. '_bag']  = bag
                end
            end
        end
        equipment = synth
    end

    -- Sidecar dict holding stat contributions from Unity augments
    -- (max-rank Lustreless augments not in item description text).
    -- These get parsed into the live stats[] dict during the gear
    -- walk, but GI's later compute overwrites stats['accuracy'/
    -- 'attack'/'defense'/'evasion'] with its own totals (which
    -- lack our extras), silently dropping them. The block right
    -- after the GI compute re-stamps the values from this overlay
    -- back onto stats[] so they survive. Mirror rules (acc -> acc2/
    -- r.acc, att -> att2/r.att) are applied at re-stamp time, so
    -- callers feeding the overlay only need to write to the primary
    -- key.
    local unity_aug_overlay = {}

    -- Walk all 16 slot keys exposed by the equipment table.
    for pos = 0, 15 do
        local entry = DISPLAY_ORDER[pos]
        if entry then
            local bag   = equipment[entry.slot_name .. '_bag']
            local index = equipment[entry.slot_name]
            if index and index ~= 0 and bag then
                local item_data = windower.ffxi.get_items(bag, index)
                if item_data and item_data.id and item_data.id ~= 0 then
                    local id = item_data.id

                    -- 1) Parse base description text.
                    local desc = res.item_descriptions and res.item_descriptions[id]
                    local helptext = (desc and desc.english) or ''
                    if helptext ~= '' then
                        -- Pull out elemental affinity glyphs FIRST. They use
                        -- non-printable byte ranges (Shift-JIS 0xE0..0xE7 or
                        -- the UTF-8 encoding of U+E000..U+E007 depending on
                        -- how Windower decoded the .dat) and would confuse
                        -- the regular text parser. We accumulate values into
                        -- stats['fire'], stats['ice'], etc.
                        ow_extract_elem_glyphs(stats, helptext)
                        -- Split at "Pet:" marker so pet stats can be prefixed
                        -- separately. Anchor on a newline+Pet: pair so we
                        -- don't false-positive on items that mention "pet"
                        -- mid-line. Everything BEFORE the marker is base
                        -- stats; everything AFTER is pet stats.
                        local base_text, pet_text = helptext:match(
                            '^(.-)\n[Pp]et:%s*(.*)$')
                        if not base_text then
                            -- No pet section.
                            base_text = helptext
                            pet_text  = nil
                        end
                        -- Parse all newline-delimited lines of the base block.
                        for line in base_text:gmatch('[^\r\n]+') do
                            ow_parse_desc_line(stats, line)
                        end
                        -- Parse pet block (if any) with the 'pet: ' prefix.
                        if pet_text and pet_text ~= '' then
                            for line in pet_text:gmatch('[^\r\n]+') do
                                ow_parse_desc_line(stats, line, 'pet: ')
                            end
                        end
                    end

                    -- 2) Augments from extdata (most accurate) or item_data fallback.
                    local augs
                    if extdata and item_data.extdata then
                        local ok, ext = pcall(extdata.decode,
                            {id = id, extdata = item_data.extdata})
                        if ok and ext and ext.augments then augs = ext.augments end
                    end
                    if not augs and item_data.augments then
                        augs = item_data.augments
                    end
                    if augs then
                        for _, a in ipairs(augs) do
                            if a and a ~= '' and a ~= 'none' then
                                local astr = tostring(a)
                                -- Unity-augmented items return opaque strings
                                -- like "Path: A" with no readable stats.
                                -- Resolve via ow_path_augments table when
                                -- present — otherwise the parser would never
                                -- find STR/DA/etc.
                                local lower = astr:lower():gsub('^%s+', ''):gsub('%s+$', '')
                                local resolved = ow_path_augments
                                                 and ow_path_augments[id]
                                                 and ow_path_augments[id][lower]
                                if resolved then
                                    for _, line in ipairs(resolved) do
                                        ow_parse_desc_line(stats, line)
                                    end
                                else
                                    ow_parse_desc_line(stats, astr)
                                end
                            end
                        end
                    end

                    -- 3) Enhanced hidden stats.
                    if ow_enhanced[id] then
                        -- Each is a single 'stat+value' or 'stat-value' string.
                        ow_parse_desc_line(stats, ow_enhanced[id])
                    end

                    -- 4) GearInfo DW_Gear: items that enhance Dual Wield via
                    -- "Enhances 'Dual Wield' effect" text. The description
                    -- parser can't extract the value, but this table knows it.
                    -- Skip when ow_enhanced[id] already provided a DW value
                    -- for this item — otherwise we'd double-count (e.g.
                    -- Suppanomimi adds +5 via both tables).
                    -- Reads from the global DW_Gear loaded by
                    -- gearinfo/_loader.lua from gearinfo/res/DW_Gear.lua.
                    if DW_Gear and DW_Gear[id] and DW_Gear[id]['Dual Wield'] then
                        local already_enhanced = ow_enhanced[id]
                            and tostring(ow_enhanced[id]):find('dual wield', 1, true)
                        if not already_enhanced then
                            stats['dual wield'] = (stats['dual wield'] or 0)
                                                + DW_Gear[id]['Dual Wield']
                        end
                    end

                    -- 5) GearInfo Martial_Arts_Gear: MA delay reduction. For
                    -- MNK/PUP this reduces effective hand-to-hand delay.
                    -- Stored under 'martial arts' (matches description syntax).
                    -- Reads from the global Martial_Arts_Gear loaded by
                    -- gearinfo/_loader.lua from gearinfo/res/Martial_Arts_Gear.lua.
                    if Martial_Arts_Gear and Martial_Arts_Gear[id] and Martial_Arts_Gear[id].delay then
                        stats['martial arts'] = (stats['martial arts'] or 0)
                                              + Martial_Arts_Gear[id].delay
                    end

                    -- 5c) Unity / JSE augments — apply max-rank augment
                    -- bonuses that aren't in the in-game item description.
                    --
                    -- Two sources are checked, in order:
                    --
                    --   (1) Unity_rank[id].augments — populated by the
                    --       loader from gearinfo/res/Unity_Gear.lua. This
                    --       is the canonical home for Unity Concord items
                    --       (Sailfi Belt +1, Cohort Cloak +1, Lugra +1,
                    --       etc.). One entry per item with a list of
                    --       augment strings. Single source of truth.
                    --
                    --   (2) ow_unity_augments[id] — legacy local table.
                    --       After the Unity migration, this only still
                    --       carries JSE Necks (Warrior's Beads, Monk's
                    --       Nodowa, etc., ids ~25417..25545). When those
                    --       move to a res/JSE_Necks.lua eventually, this
                    --       fallback can be deleted.
                    --
                    -- We check Unity_rank first because Unity_Gear.lua is
                    -- the file we want users editing for additions/fixes;
                    -- ow_unity_augments is "legacy until JSE migrates."
                    -- Both paths feed the same unity_aug_overlay sidecar
                    -- so the post-GI restamp block handles either source
                    -- identically.
                    --
                    -- Implementation note: Unity_rank[id] is the entry
                    -- table (with rank/Unity Ranking/augments fields).
                    -- The augments key may be nil for items that have a
                    -- ranking entry but no augment data yet (the "TODO"
                    -- stubs in Unity_Gear.lua) — we explicitly guard for
                    -- that, and fall through to the legacy table only if
                    -- the new path produced no augments.
                    local _ua_list = nil
                    if Unity_rank and Unity_rank[id] and Unity_rank[id].augments then
                        _ua_list = Unity_rank[id].augments
                    elseif ow_unity_augments[id] then
                        _ua_list = ow_unity_augments[id]
                    end
                    if _ua_list then
                        for _, aug_str in ipairs(_ua_list) do
                            ow_parse_desc_line(unity_aug_overlay, aug_str)
                        end
                    end

                    -- 6) GearInfo Set_bonus_by_item_id: collect equipped IDs
                    -- into a local table for post-walk set-detection. The
                    -- actual bonus application happens AFTER the loop since
                    -- we need to count matching items per set first.
                    -- Reads from the global Set_bonus_by_item_id loaded by
                    -- gearinfo/_loader.lua from gearinfo/res/Set_bonus_by_item_id.lua.
                    if Set_bonus_by_item_id and Set_bonus_by_item_id[id] then
                        _ow_equipped_set_items = _ow_equipped_set_items or {}
                        _ow_equipped_set_items[#_ow_equipped_set_items + 1] = id
                    end
                end
            end
        end
    end

    -- 7) Apply set bonuses. Group equipped items by set_id, count pieces,
    -- look up the N-piece bonus from the 'bonus' sub-table, and add each
    -- stat to the stats dict. Only the FIRST matching item for each set
    -- provides the bonus table (they all have the same sub-table).
    if _ow_equipped_set_items and #_ow_equipped_set_items > 0 then
        local by_set = {}
        for _, id in ipairs(_ow_equipped_set_items) do
            local e = Set_bonus_by_item_id and Set_bonus_by_item_id[id]
            if e and e['set id'] then
                local sid = e['set id']
                by_set[sid] = by_set[sid] or {count = 0, entries = {}}
                by_set[sid].count = by_set[sid].count + 1
                by_set[sid].entries[#by_set[sid].entries + 1] = e
            end
        end
        for _sid, group in pairs(by_set) do
            local first = group.entries[1]
            if first and first.bonus then
                -- bonus table is keyed 1..5 for 1-piece through 5-piece.
                -- Apply cumulatively: 3 pieces equipped → apply bonus[2] and bonus[3]
                -- (some sets only define certain tiers). GearInfo's minimum
                -- peices field tells us the starting threshold.
                local min_p = first['minimum peices'] or 2
                for tier = min_p, group.count do
                    local b = first.bonus and first.bonus[tier]
                    if type(b) == 'table' then
                        for stat_key, val in pairs(b) do
                            -- GearInfo uses abbreviations. Map to our keys.
                            local mapped = _PW_SET_BONUS_STAT_MAP[stat_key]
                                        or stat_key:lower()
                            stats[mapped] = (stats[mapped] or 0) + val
                        end
                    end
                end
            end
        end
        _ow_equipped_set_items = nil  -- reset for next call
    end

    -- ── Snapshot: gear + Flurry buff ─────────────────────────────────────
    -- Snapshot is a ranged-attack delay reduction stat. Gear contribution
    -- is parsed via 'snapshot' key. Flurry I (buff 265) adds +15%, Flurry II
    -- (buff 581) adds +30%. They don't stack — only one Flurry active at
    -- a time, II overrides I if cast.
    do
        local p = windower.ffxi.get_player()
        if p and p.buffs then
            local has_flurry_i, has_flurry_ii = false, false
            for _, bid in ipairs(p.buffs) do
                if     bid == PW_BUFF_FLURRY_I  then has_flurry_i  = true
                elseif bid == PW_BUFF_FLURRY_II then has_flurry_ii = true
                end
            end
            local flurry_bonus = 0
            if has_flurry_ii then flurry_bonus = 30
            elseif has_flurry_i then flurry_bonus = 15 end
            if flurry_bonus > 0 then
                stats['snapshot'] = (stats['snapshot'] or 0) + flurry_bonus
            end
        end
    end

    -- ── Battle stat sums via GearInfo backend (acc/att/eva/def) ───────────
    -- We delegate fully-summed Acc/Att/Eva/Def computation to the vendored
    -- GearInfo backend (gearinfo/Gear_Processing.lua's get_player_acc /
    -- get_player_att / get_player_evasion / get_player_defence). GearInfo
    -- has been the canonical FFXI gear addon for years and gets these
    -- formulas right; trying to reimplement them gave us subtle gaps
    -- across def/eva/att2.
    --
    -- The flow:
    --   1. _gi.refresh_all() syncs `player`, decodes equipment, runs
    --      get_equip_stats (populating Gear_info), updates Buffs_inform.
    --   2. _gi.compute_player_stats() returns { acc={main,sub,range,ammo},
    --      att={main,sub,range,ammo,str}, eva=N, def=N }.
    --   3. We map those into our wire format (accuracy / accuracy2 /
    --      attack / attack2 / ranged accuracy / ranged attack / etc).
    --
    -- For magic accuracy / magic attack bonus, GearInfo doesn't compute
    -- player totals — it only sums gear contributions in Gear_info. So
    -- we still derive macc/MAB locally here from gear + INT.
    --
    -- If _gi is nil (loader failed), we leave acc/att/eva/def at their
    -- gear-only values; downstream consumers will see partial data but
    -- not crash.
    -- First-run diagnostic — fires once when _ow_cast_debug is on, to
    -- confirm whether _gi is loaded and reachable from this code path.
    -- Toggle via //ow debug. Stays silent in normal play.
    if not _gi_traced and _ow_cast_debug then
        _gi_traced = true
        local has_gi      = (_gi ~= nil)
        local has_refresh = has_gi and (_gi.refresh_all ~= nil)
        local has_compute = has_gi and (_gi.compute_player_stats ~= nil)
        windower.add_to_chat(207, string.format(
            '[OW] _gi trace: present=%s refresh_all=%s compute_player_stats=%s',
            tostring(has_gi), tostring(has_refresh), tostring(has_compute)))
    end

    if _gi and _gi.refresh_all and _gi.compute_player_stats then
        -- Sim is now a delta calculator: live everything, with selected
        -- gear slots swapped per user picks. equip_overrides only
        -- contains slots the user picked (NOT a full empty-slot map).
        -- player_stats_override / sim_overrides stay nil so GearInfo
        -- reads from the live player as it would in non-sim mode.
        local equip_overrides = nil
        if sim_on and _sim and _sim.get_equipment then
            local sim_eq = _sim.get_equipment()
            if sim_eq and next(sim_eq) then
                equip_overrides = {}
                for slot, iid in pairs(sim_eq) do
                    equip_overrides[slot] = iid
                end
            end
        end
        -- Populate settings.Bards[<my_name>] from live windower data
        -- before the GearInfo refresh runs. GearInfo's check_buffs
        -- needs settings.Bards[caster] to compute song stat values;
        -- without it, song bonuses silently drop on the floor.
        pcall(_ow_refresh_bard_settings)
        -- Same for settings.Cors → GearInfo's Action_Processing reads
        -- this when computing roll potency. Without it, Roll_bonus
        -- falls back to manual_COR_bonus (typically 0), missing the
        -- ~25% the wizard's Phantom Roll+ should contribute.
        pcall(_ow_refresh_cor_settings)
        -- And settings.player.rank → GearInfo's Gear_Processing scales
        -- Unity-augmented gear by this. Default is 1 (highest tier);
        -- the wizard's saved value overrides it. Refreshing every
        -- recompute is cheap and keeps the rank in sync with whatever
        -- ow_user_config currently holds.
        pcall(_ow_refresh_unity_rank)
        -- And settings.Geo → bridge wizard values for Indi/Geo spell
        -- potency scaling. Compute path consumption is TBD; refresh
        -- here unconditionally so the data is in place when wired up.
        if _ow_refresh_geo_settings then
            pcall(_ow_refresh_geo_settings)
        end
        -- Refresh member_table too — picks up party changes (members
        -- joining/leaving) without needing a /reload.
        if _G.update_party then pcall(_G.update_party) end
        local ok_refresh, refresh_ret, refresh_msg = pcall(_gi.refresh_all,
            equip_overrides, nil, nil)
        -- Song-chain diagnostic: dumps settings.Bards[me] / Buffs_inform /
        -- _ExtraData.player.buff_details with Caster fields. Useful for
        -- debugging bard song detection issues. Gated behind _ow_buff_debug
        -- so it doesn't spam normal play; toggle with `//ow buffdebug`.
        -- One-line summary, deduplicated so it only re-fires when
        -- something meaningful changes.
        do
            local me_lower = ''
            do
                local p = windower.ffxi.get_player()
                if p and p.name then me_lower = p.name:lower() end
            end
            local bards_entry = settings and settings.Bards
                                and settings.Bards[me_lower]
            local sb_minuet = bards_entry and bards_entry.song_bonus
                              and bards_entry.song_bonus.minuet or 'nil'
            local sb_all    = bards_entry and bards_entry.song_bonus
                              and bards_entry.song_bonus.all_songs or 'nil'
            local m_minuet  = bards_entry and bards_entry.merits
                              and bards_entry.merits.minuet or 'nil'
            local j_minuet  = bards_entry and bards_entry.jp
                              and bards_entry.jp.minuet or 'nil'
            local bi_atk    = (Buffs_inform and Buffs_inform.Attack) or 'nil'
            local bi_acc    = (Buffs_inform and Buffs_inform.Accuracy) or 'nil'
            local bi_mahaste = (Buffs_inform and Buffs_inform.ma_haste) or 'nil'
            -- Walk buff_details for bard songs.
            local bard_buffs = {}
            local bd_total = 0
            local bd_sample = {}
            if _ExtraData and _ExtraData.player and _ExtraData.player.buff_details then
                for k, b in pairs(_ExtraData.player.buff_details) do
                    if type(b) == 'table' then
                        bd_total = bd_total + 1
                        if bd_total <= 6 then
                            bd_sample[#bd_sample+1] = string.format(
                                '%s/id=%s/full=%s/Caster=%s',
                                tostring(b.name),
                                tostring(b.id),
                                tostring(b.full_name),
                                tostring(b.Caster))
                        end
                        if b.full_name then
                            if PW_SONG_STATS_BY_NAME and PW_SONG_STATS_BY_NAME[b.full_name]
                               or b.full_name == 'Honor March'
                               or b.full_name == 'Victory March'
                               or b.full_name == 'Advancing March' then
                                bard_buffs[#bard_buffs+1] = string.format(
                                    '%s/Caster=%s/Atk=%s',
                                    tostring(b.full_name),
                                    tostring(b.Caster),
                                    tostring(b.Attack))
                            end
                        end
                    end
                end
            end
            -- member_table snapshot for diagnostic
            local mt_count = 0
            local mt_sample = {}
            if member_table then
                for k, v in pairs(member_table) do
                    mt_count = mt_count + 1
                    if mt_count <= 3 and type(v) == 'table' then
                        mt_sample[#mt_sample+1] = string.format(
                            '%s/id=%s/Last=%s',
                            tostring(k), tostring(v.id),
                            tostring(v.Last_Spell))
                    end
                end
            end
            local cah_set = (_gi and _gi.captured_action_handler ~= nil) and 'Y' or 'N'
            local sig = string.format(
                'me=%s sb.all=%s sb.min=%s mer.min=%s jp.min=%s bi.atk=%s bi.acc=%s bi.mh=%s bd_total=%d cah=%s mt=%d[%s] songs=[%s] sample=[%s]',
                me_lower,
                tostring(sb_all), tostring(sb_minuet),
                tostring(m_minuet), tostring(j_minuet),
                tostring(bi_atk), tostring(bi_acc), tostring(bi_mahaste),
                bd_total,
                cah_set,
                mt_count,
                table.concat(mt_sample, ' | '),
                table.concat(bard_buffs, '|'),
                table.concat(bd_sample, ' | '))
            _ow_chain_sig = _ow_chain_sig or ''
            if _ow_buff_debug and sig ~= _ow_chain_sig then
                _ow_chain_sig = sig
                windower.add_to_chat(207, '[OW] chain: ' .. sig)
            end
            -- ── Resist trace ────────────────────────────────────────────
            -- Dumps the full resist hop: per-buff this_buff[<X> Resist]
            -- (what check_buffs wrote), Buffs_inform[<X> Resist] (what the
            -- aggregator summed), and stats['resist'] (what compute_player_stats
            -- handed the panel — printed in the post-compute block below).
            -- Toggle with `//ow debug`. Each link in the chain prints on
            -- its own line so the break point is obvious from the log.
            -- Toggle with `//ow buffdebug` (not `//ow debug` — debug is
            -- noisier and would drown the trace).
            if _ow_buff_debug then
                -- Stat keys to trace. Covers every key check_buffs is
                -- known to write into temp[] (and thus into this_buff
                -- via the copy at Buff_Processing line 366-368). If a
                -- new song family gets added that writes to a different
                -- key, add it here too — otherwise the trace will go
                -- silent and you'll think the math broke when it's just
                -- the diagnostic that's blind.
                local TRACE_KEYS = {
                    -- Resists (Carols)
                    'Fire Resist', 'Ice Resist', 'Wind Resist', 'Earth Resist',
                    'Thunder Resist', 'Water Resist', 'Light Resist', 'Dark Resist',
                    -- Stat boosts (Madrigal/Minuet/Etude/etc.)
                    'STR','DEX','VIT','AGI','INT','MND','CHR',
                    -- Combat stats. DEF = Minne. Accuracy/Attack come
                    -- from Minuet/Madrigal etc; live in Buffs_inform's
                    -- reset under those exact strings.
                    'DEF', 'Accuracy', 'Attack', 'Ranged Accuracy', 'Ranged Attack',
                    'Magic Attack', 'Magic Accuracy',
                    -- Recurring per-tick (Paeon/Ballad/Tactician's Roll)
                    'Regen', 'Refresh', 'Regain',
                    -- Magic stats
                    'Magic Evasion', 'Magic Def. Bonus',
                    -- Misc
                    'Evasion', 'HP', 'MP', 'delay',
                }
                if _ExtraData and _ExtraData.player
                   and _ExtraData.player.buff_details then
                    for _, b in pairs(_ExtraData.player.buff_details) do
                        if type(b) == 'table' then
                            local hits = {}
                            for _, k in ipairs(TRACE_KEYS) do
                                if b[k] ~= nil and b[k] ~= 0 then
                                    hits[#hits+1] = string.format('%s=%s',
                                        k, tostring(b[k]))
                                end
                            end
                            if #hits > 0 then
                                windower.add_to_chat(207, string.format(
                                    '[OW] stats on buff full=%s id=%s: %s',
                                    tostring(b.full_name), tostring(b.id),
                                    table.concat(hits, ' ')))
                            end
                        end
                    end
                end
                if Buffs_inform then
                    local bi_hits = {}
                    for _, k in ipairs(TRACE_KEYS) do
                        local v = Buffs_inform[k]
                        if v and v ~= 0 then
                            bi_hits[#bi_hits+1] = string.format('%s=%s', k, tostring(v))
                        end
                    end
                    if #bi_hits > 0 then
                        windower.add_to_chat(207,
                            '[OW] Buffs_inform: ' .. table.concat(bi_hits, ' '))
                    else
                        windower.add_to_chat(207,
                            '[OW] Buffs_inform: ALL ZERO')
                    end
                end
            end
            -- ── end stats trace ─────────────────────────────────────────
        end
        if not ok_refresh then
            windower.add_to_chat(123, '[OW] _gi.refresh_all error: ' .. tostring(refresh_ret))
        else
            -- Trace Gear_info presence after refresh, once. Gated by
            -- _ow_cast_debug so it stays quiet in normal play.
            if not _gi_refresh_traced and _ow_cast_debug then
                _gi_refresh_traced = true
                local gi_present = (Gear_info ~= nil) and (next(Gear_info) ~= nil)
                local main_skill = Gear_info and Gear_info['main'] and Gear_info['main'].skill
                windower.add_to_chat(207, string.format(
                    '[OW] _gi refresh trace: ok=%s msg=%s populated=%s main.skill=%s STR=%s DEX=%s',
                    tostring(refresh_ret), tostring(refresh_msg),
                    tostring(gi_present),
                    tostring(main_skill),
                    tostring(Gear_info and Gear_info['STR']),
                    tostring(Gear_info and Gear_info['DEX'])))
            end
            local ok_compute, result = pcall(_gi.compute_player_stats)
            -- Trace the FIRST compute_player_stats result when in
            -- debug mode. Gated by _ow_cast_debug so normal play stays
            -- quiet; toggle on with //ow debug if you need it.
            if not _gi_compute_traced and _ow_cast_debug then
                _gi_compute_traced = true
                if ok_compute then
                    if type(result) == 'table' then
                        local function dump(t)
                            if type(t) ~= 'table' then return tostring(t) end
                            local out = {}
                            for k, v in pairs(t) do
                                out[#out+1] = tostring(k) .. '=' .. tostring(v)
                            end
                            return '{' .. table.concat(out, ',') .. '}'
                        end
                        windower.add_to_chat(207, '[OW] _gi compute trace: acc=' .. dump(result.acc))
                        windower.add_to_chat(207, '[OW] _gi compute trace: att=' .. dump(result.att))
                        windower.add_to_chat(207, '[OW] _gi compute trace: eva=' .. tostring(result.eva)
                            .. ' def=' .. tostring(result.def))
                        if result._errs and #result._errs > 0 then
                            windower.add_to_chat(123, '[OW] _gi compute helper errors: '
                                .. table.concat(result._errs, ' | '))
                        end
                    else
                        -- result might be nil with a 2nd return value (msg) from pcall
                        -- but pcall only gives us the first. Try calling directly to get the msg.
                        local _, _, msg = pcall(_gi.compute_player_stats)
                        windower.add_to_chat(207, string.format(
                            '[OW] _gi compute trace: returned %s (msg=%s)',
                            type(result), tostring(msg)))
                    end
                else
                    windower.add_to_chat(123, '[OW] _gi compute trace: ERROR ' .. tostring(result))
                end
            end
            if ok_compute and type(result) == 'table' then
                local acc, att = result.acc, result.att
                if acc then
                    if acc.main  then stats['accuracy']        = acc.main  end
                    if acc.sub   then stats['accuracy2']       = acc.sub   end
                    -- Ranged uses range slot when populated, else ammo.
                    if acc.range and acc.range > 0 then
                        stats['ranged accuracy'] = acc.range
                    elseif acc.ammo and acc.ammo > 0 then
                        stats['ranged accuracy'] = acc.ammo
                    end
                end
                if att then
                    if att.main  then stats['attack']          = att.main  end
                    if att.sub   then stats['attack2']         = att.sub   end
                    if att.range and att.range > 0 then
                        stats['ranged attack'] = att.range
                    elseif att.ammo and att.ammo > 0 then
                        stats['ranged attack'] = att.ammo
                    end
                end
                if result.eva then stats['evasion'] = result.eva end
                if result.def then stats['defense'] = result.def end

                -- Diagnostic: dump GI return vs Buffs_inform raw values
                -- so we can see whether GI is folding Chaos's "Attack perc"
                -- into att.main or not. If att.main is suspiciously
                -- low while Buffs_inform["Attack perc"] is non-zero,
                -- GI's compute isn't applying the perc multiplier
                -- and we need to apply it ourselves.
                if _ow_buff_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW] GI return: att.main=%s att.sub=%s att.range=%s eva=%s def=%s',
                        tostring(att and att.main),
                        tostring(att and att.sub),
                        tostring(att and att.range),
                        tostring(result.eva),
                        tostring(result.def)))
                    if Buffs_inform then
                        windower.add_to_chat(207, string.format(
                            '[OW] Buffs_inform: Attack=%s "Attack perc"=%s Accuracy=%s DEF=%s Evasion=%s',
                            tostring(Buffs_inform['Attack']),
                            tostring(Buffs_inform['Attack perc']),
                            tostring(Buffs_inform['Accuracy']),
                            tostring(Buffs_inform['DEF']),
                            tostring(Buffs_inform['Evasion'])))
                        -- Reverse-engineer what Attack perc GI's
                        -- compute used. Buffs_inform.Attack perc should
                        -- equal the sum of all active rolls' Chaos
                        -- contributions. If att.main implies a different
                        -- multiplier, the compute is reading a different
                        -- state of Buffs_inform than this diagnostic
                        -- (timing race or duplicate aggregator pass).
                        if att and att.main and att.main > 0 then
                            -- Print all the raw inputs that GI's
                            -- get_player_att uses to compute base_attack.
                            -- Per Gear_Processing line 465 (1H main):
                            --   base = 8 + main.value + STR + BI.STR + Attack
                            --        + get_player_att_from_job() + BI.Attack
                            --   att.main = floor(base * (1 + Attack perc/1024))
                            -- If anything in this list changes between
                            -- baseline and a roll being active, that's
                            -- our culprit.
                            local gi_attack   = (Gear_info and Gear_info['Attack']) or 0
                            local gi_str      = (Gear_info and Gear_info['STR']) or 0
                            local gi_main_val = (Gear_info and Gear_info['main'] and Gear_info['main'].value) or 0
                            local bi_str      = (Buffs_inform and Buffs_inform['STR']) or 0
                            local bi_attack   = (Buffs_inform and Buffs_inform['Attack']) or 0
                            -- Try to call GI's get_player_att_from_job
                            -- if exposed in our env.
                            local job_att = '?'
                            if _G.get_player_att_from_job then
                                local ok, v = pcall(_G.get_player_att_from_job)
                                if ok then job_att = tostring(v) end
                            end
                            windower.add_to_chat(207, string.format(
                                '[OW] att inputs: main.value=%s STR(gear)=%s STR(buff)=%s Attack(gear)=%s Attack(buff)=%s att_from_job=%s',
                                tostring(gi_main_val), tostring(gi_str), tostring(bi_str),
                                tostring(gi_attack), tostring(bi_attack), job_att))
                            local approx_base = 8 + gi_main_val + gi_str + bi_str
                                              + gi_attack + bi_attack
                                              + (tonumber(job_att) or 0)
                            if approx_base > 0 then
                                local implied_multi = (att.main / approx_base) - 1
                                windower.add_to_chat(207, string.format(
                                    '[OW] att.main=%d / approx_base=%d → implied multi=%.4f (=%.0f raw vs Buffs_inform=%s)',
                                    att.main, approx_base, implied_multi,
                                    implied_multi * 1024,
                                    tostring(Buffs_inform['Attack perc'])))
                            end
                        end
                    end
                end

                -- ── Re-stamp JSE neck augment contributions ───────
                -- After the Unity migration, GearInfo natively handles
                -- Unity augments via Gear_Processing.lua's find_all_values,
                -- so those contributions flow through Gear_info and
                -- compute_player_stats unchanged — no restamp needed.
                --
                -- This block now exists ONLY to restamp JSE neck
                -- augments (Warrior's Beads, Monk's Nodowa, etc.),
                -- which still live in OmniWatch's ow_unity_augments
                -- table because they haven't been migrated to a
                -- res/JSE_Necks.lua file yet. When that migration
                -- happens this block can be deleted entirely.
                --
                -- For Unity items, unity_aug_overlay is empty (the
                -- prep block at line ~8939 only fires for ids still
                -- in ow_unity_augments, i.e. JSE), so this restamp
                -- adds 0 — no double-counting.
                local _UNITY_OVERLAY_KEYS = {
                    'defense', 'evasion',
                    'accuracy', 'attack',
                    'magic accuracy', 'magic attack bonus',
                    'magic evasion', 'magic defense bonus',
                    'ranged accuracy', 'ranged attack',
                }
                for _, sk in ipairs(_UNITY_OVERLAY_KEYS) do
                    local v = unity_aug_overlay[sk]
                    if v and v ~= 0 then
                        stats[sk] = (stats[sk] or 0) + v
                        -- Acc/Att augments apply to BOTH hands and
                        -- ranged (same rule as food/JP gifts: a flat
                        -- bonus from one piece of gear adds to every
                        -- weapon slot's effective acc/att in unison).
                        if sk == 'accuracy' then
                            stats['accuracy2']       = (stats['accuracy2']       or 0) + v
                            stats['ranged accuracy'] = (stats['ranged accuracy'] or 0) + v
                        elseif sk == 'attack' then
                            stats['attack2']         = (stats['attack2']         or 0) + v
                            stats['ranged attack']   = (stats['ranged attack']   or 0) + v
                        end
                    end
                end

                -- Apply REMAINING overlay keys that GI's compute
                -- doesn't manage (STR, AGI, DEX, INT, MND, CHR, VIT,
                -- HP, MP, snapshot, store tp, double attack, etc.).
                -- These are gear stats that GI's gear-walk picks up
                -- from item descriptions; the augments need to be
                -- added because they aren't in the description text.
                -- Skip keys already handled above to avoid double-add.
                --
                -- DERIVATIVE EFFECTS: stat augments on STR/AGI/DEX/INT
                -- propagate to combat stats GI already finalized.
                -- STR→Attack and STR→Ranged Attack ratios per BG-wiki's
                -- "History of STR to Attack and Ranged Attack Ratio"
                -- table (Dec 11 2018 row):
                --   Two-handed:      1.00 (main)
                --   One-handed Main: 1.00
                --   One-handed Sub:  0.50
                --   H2H:             0.75
                --   Ranged:          1.00
                --
                -- AGI / DEX / INT / VIT / MND empirical ratios:
                --   AGI → Ranged Attack 1.0, Evasion floor(/2)
                --   DEX → Accuracy (all hands+ranged) 1.0
                --   INT → Magic Acc / Magic Atk Bonus floor(/2) each
                --   VIT → Defense × 1.5 (BG-wiki: VIT+2 = Def+3)
                --   MND → Magic Def. Bonus floor(/2)
                local _UNITY_HANDLED = {}
                for _, sk in ipairs(_UNITY_OVERLAY_KEYS) do
                    _UNITY_HANDLED[sk] = true
                end
                -- Pick STR→Att main-hand multiplier from active weapon.
                local _str_main_mul = 1.0
                local _main_skill = (Gear_info and Gear_info['main']
                                     and Gear_info['main'].skill) or ''
                if _main_skill == '' or _main_skill == 'Hand-to-Hand' then
                    _str_main_mul = 0.75
                end
                for sk, v in pairs(unity_aug_overlay) do
                    if v and v ~= 0 and not _UNITY_HANDLED[sk] then
                        stats[sk] = (stats[sk] or 0) + v
                        if sk == 'str' then
                            stats['attack']        = (stats['attack']        or 0) + math.floor(v * _str_main_mul)
                            stats['attack2']       = (stats['attack2']       or 0) + math.floor(v * 0.5)
                            stats['ranged attack'] = (stats['ranged attack'] or 0) + v
                        elseif sk == 'agi' then
                            stats['ranged attack'] = (stats['ranged attack'] or 0) + v
                            stats['evasion']       = (stats['evasion']       or 0) + math.floor(v / 2)
                        elseif sk == 'dex' then
                            stats['accuracy']        = (stats['accuracy']        or 0) + v
                            stats['accuracy2']       = (stats['accuracy2']       or 0) + v
                            stats['ranged accuracy'] = (stats['ranged accuracy'] or 0) + v
                        elseif sk == 'int' then
                            stats['magic accuracy']     = (stats['magic accuracy']     or 0) + math.floor(v / 2)
                            stats['magic attack bonus'] = (stats['magic attack bonus'] or 0) + math.floor(v / 2)
                        elseif sk == 'vit' then
                            stats['defense'] = (stats['defense'] or 0) + math.floor(v * 1.5)
                        elseif sk == 'mnd' then
                            stats['magic def. bonus'] = (stats['magic def. bonus'] or 0) + math.floor(v / 2)
                        end
                    end
                end

                -- ── Trust GearInfo's computed totals ─────────────────
                -- _gi.compute_player_stats() already consumed
                -- Buffs_inform when computing att.main / acc.main /
                -- eva / def. Those return values include song / roll /
                -- buff contributions. Re-stamping Buffs_inform.Attack
                -- on top would double-count.
                --
                -- The exception is keys GI doesn't return at all from
                -- compute_player_stats (HP, MP, magic def. bonus, the
                -- per-attribute buffs to STR/DEX/VIT/etc., and the
                -- Regen/Refresh/Regain ticks aggregated in
                -- Buffs_inform). For those we still need to stamp
                -- something or they show as zero. They live in the
                -- block below (b_regen / b_refresh / b_regain / etc.).
                --
                -- This block intentionally left empty; a former
                -- `add_stat` overlay was here, and was double-stamping
                -- songs/rolls onto already-rolled values from
                -- compute_player_stats. Removing it brings the panel
                -- in line with /checkparam.

                -- Pull Regen/Refresh/Regain contributions from
                -- Buffs_inform (aggregated by GearInfo's
                -- calculate_total_haste from buff_details). Songs
                -- (Paeon → Regen, Ballad → Refresh) and Cor rolls
                -- (Tactician's Roll → Regain) write these onto each
                -- buff entry; the aggregator sums them only because
                -- our gearinfo/Buff_Processing.lua patch added these
                -- keys to the Buffs_inform reset. Add to existing
                -- stats[] (don't overwrite) — gear and BLU traits also
                -- contribute through other paths.
                if Buffs_inform then
                    local b_regen = Buffs_inform['Regen'] or 0
                    if b_regen ~= 0 then
                        stats['regen'] = (stats['regen'] or 0) + b_regen
                    end
                    local b_refresh = Buffs_inform['Refresh'] or 0
                    if b_refresh ~= 0 then
                        stats['refresh'] = (stats['refresh'] or 0) + b_refresh
                    end
                    local b_regain = Buffs_inform['Regain'] or 0
                    if b_regain ~= 0 then
                        stats['regain'] = (stats['regain'] or 0) + b_regain
                    end
                    -- Roll/song-derived stats that GI's compute_player_stats
                    -- does NOT return. These come from rolls (Fighter's→
                    -- Double Attack, Samurai→Store TP, Tactician's→Regain
                    -- already above, Rogue's→Crit Rate, Caster's→Fast
                    -- Cast, Monk's→Subtle Blow, etc.) and a few song
                    -- effects. SAFE: GI doesn't write these keys onto
                    -- stats[], so adding here doesn't double-count.
                    --
                    -- IMPORTANT: bi_key strings must match GI's
                    -- Buffs_inform init in Buff_Processing.lua line 377.
                    -- Note GI's typo "Tripple Attack" — preserved verbatim.
                    local _BI_BUFF_STAMP = {
                        ['double attack']        = 'Double Attack',
                        ['triple attack']        = 'Tripple Attack',  -- GI typo
                        ['quadruple attack']     = 'Quadruple Attack',
                        ['critical hit rate']    = 'Critical hit rate',
                        ['critical hit damage']  = 'Critical hit damage',
                        ['store tp']             = 'Store TP',
                        ['dual wield']           = 'Dual Wield',
                        ['subtle blow']          = 'Subtle Blow',
                        ['fast cast']            = 'Fast Cast',
                        ['martial arts']         = 'Martial Arts',
                        ['snapshot']             = 'Snapshot',  -- Courser's Roll
                    }
                    for sk, bk in pairs(_BI_BUFF_STAMP) do
                        local v = Buffs_inform[bk] or 0
                        if v ~= 0 then
                            stats[sk] = (stats[sk] or 0) + v
                        end
                    end
                    -- Elemental resistances: Carols (and Tier II Carols)
                    -- write to Buffs_inform.<Element> Resist via the
                    -- bard chain. Map them into the stats['resist']
                    -- dict that the Python panel renders. Element keys
                    -- match the Python panel's `STATS_ELEM_ROWS` keys.
                    local resist_map = {
                        ['Fire Resist']    = 'fire',
                        ['Ice Resist']     = 'ice',
                        ['Wind Resist']    = 'wind',
                        ['Earth Resist']   = 'earth',
                        ['Thunder Resist'] = 'thunder',
                        ['Water Resist']   = 'water',
                        ['Light Resist']   = 'light',
                        ['Dark Resist']    = 'dark',
                    }
                    for bi_key, st_key in pairs(resist_map) do
                        local v = Buffs_inform[bi_key] or 0
                        if v ~= 0 then
                            stats['resist'] = stats['resist'] or {}
                            stats['resist'][st_key] =
                                (stats['resist'][st_key] or 0) + v
                        end
                    end
                    -- Trace what we just wrote (or didn't) to stats.resist.
                    -- This is the last hop before the dict gets serialized
                    -- to the Python panel. If Buffs_inform had values but
                    -- stats.resist is empty/nil, the resist_map mapping
                    -- broke. If both are populated here but the cell is
                    -- still empty, the break is in serialization or Python.
                    if _ow_buff_debug then
                        if type(stats['resist']) == 'table'
                           and next(stats['resist']) ~= nil then
                            local sr_hits = {}
                            for k, v in pairs(stats['resist']) do
                                sr_hits[#sr_hits+1] = string.format(
                                    '%s=%s', tostring(k), tostring(v))
                            end
                            windower.add_to_chat(207,
                                "[OW] stats['resist']: "
                                .. table.concat(sr_hits, ' '))
                        else
                            windower.add_to_chat(207,
                                "[OW] stats['resist']: EMPTY/NIL")
                        end
                    end
                end

                -- ── Bar spells (WHM Enhancing Magic) ──────────────────────
                -- These aren't BRD songs and don't flow through GearInfo's
                -- bard chain. Walk buff_details directly for known bar
                -- spell names and add estimated resist to stats['resist'].
                -- Real potency depends on the caster's Enhancing Magic
                -- skill + barspell+ gear (we can't see those). Estimates:
                --   Tier I & -ra: 130 resist (~450 skill)
                --   Tier II & -ra: 135 resist (real value adds ~5 MDB
                --                  separately — we don't track MDB yet)
                if _ExtraData and _ExtraData.player
                   and _ExtraData.player.buff_details then
                    local BAR_SPELL_RESIST = {
                        -- Fire
                        ['Barfire']      = {elem='fire',    val=130},
                        ['Barfira']      = {elem='fire',    val=130},
                        ['Barfire II']   = {elem='fire',    val=135},
                        ['Barfira II']   = {elem='fire',    val=135},
                        -- Ice
                        ['Barblizzard']    = {elem='ice', val=130},
                        ['Barblizzara']    = {elem='ice', val=130},
                        ['Barblizzard II'] = {elem='ice', val=135},
                        ['Barblizzara II'] = {elem='ice', val=135},
                        -- Wind
                        ['Baraero']      = {elem='wind',    val=130},
                        ['Baraera']      = {elem='wind',    val=130},
                        ['Baraero II']   = {elem='wind',    val=135},
                        ['Baraera II']   = {elem='wind',    val=135},
                        -- Earth
                        ['Barstone']     = {elem='earth',   val=130},
                        ['Barstonra']    = {elem='earth',   val=130},
                        ['Barstone II']  = {elem='earth',   val=135},
                        ['Barstonra II'] = {elem='earth',   val=135},
                        -- Lightning
                        ['Barthunder']    = {elem='thunder', val=130},
                        ['Barthundra']    = {elem='thunder', val=130},
                        ['Barthunder II'] = {elem='thunder', val=135},
                        ['Barthundra II'] = {elem='thunder', val=135},
                        -- Water
                        ['Barwater']     = {elem='water',   val=130},
                        ['Barwatera']    = {elem='water',   val=130},
                        ['Barwater II']  = {elem='water',   val=135},
                        ['Barwatera II'] = {elem='water',   val=135},
                    }
                    for _, b in pairs(_ExtraData.player.buff_details) do
                        if type(b) == 'table' then
                            -- Bar spells don't always get full_name set
                            -- (no Caster needed for stat math), so check
                            -- both fields. The buff's `name` field comes
                            -- from res.buffs[id].name — for bar spells
                            -- that's the spell name.
                            local bn = b.full_name or b.name
                            local entry = bn and BAR_SPELL_RESIST[bn]
                            if entry then
                                stats['resist'] = stats['resist'] or {}
                                stats['resist'][entry.elem] =
                                    (stats['resist'][entry.elem] or 0)
                                    + entry.val
                            end
                        end
                    end
                end

                -- Mark that GearInfo's backend wrote canonical totals.
                -- Downstream blocks that ADD song/buff/trait bonuses to
                -- acc/att/eva/def must skip — GearInfo's totals already
                -- include any buffs it tracks in Buffs_inform, so adding
                -- on top would double-count (manifests as panel values
                -- consistently overshooting /checkparam by the song amount).
                _gi_wrote_combat_stats = true

                if _ow_cast_debug or _ow_buff_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW] GI stats: acc1=%s acc2=%s att1=%s att2=%s eva=%s def=%s',
                        tostring(stats['accuracy']),
                        tostring(stats['accuracy2']),
                        tostring(stats['attack']),
                        tostring(stats['attack2']),
                        tostring(stats['evasion']),
                        tostring(stats['defense'])))
                end
            elseif not ok_compute then
                windower.add_to_chat(123, '[OW] _gi.compute_player_stats error: ' .. tostring(result))
            end
        end
    end

    -- Magic accuracy / Magic attack bonus: derive from gear + INT.
    -- Same approximation as before; GearInfo doesn't return these.
    do
        local p = windower.ffxi.get_player()
        if p and p.stats then
            local total_int = tonumber(p.stats['int']) or 0
            local gear_macc = stats['magic accuracy']     or 0
            local gear_matk = stats['magic attack bonus'] or 0
            stats['magic accuracy']     = math.floor(total_int * 0.5) + gear_macc
            stats['magic attack bonus'] = math.floor(total_int * 0.5) + gear_matk
        end
    end

    return stats
end

-- Encode stats dict to the UDP wire format and send.
function ow_send_stats(stats)
    local sim_on = (_sim and _sim.is_active and _sim.is_active()) or false

    -- Helper: get the equipment table with sim overrides layered on top.
    -- ow_send_stats has its own scope (no `equipment` local from
    -- compute_stats reaches here), so call this whenever a downstream
    -- block needs the sim-aware equipment view.
    local function _eq_with_sim()
        local eq = windower.ffxi.get_items and windower.ffxi.get_items('equipment')
        if not eq then return nil end
        if not sim_on or not (_sim and _sim.get_equipment) then return eq end
        local sim_eq = _sim.get_equipment()
        if not sim_eq or not next(sim_eq) then return eq end
        local out = {}
        for k, v in pairs(eq) do out[k] = v end
        for slot_key, ref in pairs(sim_eq) do
            local is_empty = (type(ref) == 'number' and ref == 0)
                          or (type(ref) == 'table' and (tonumber(ref.id) or 0) <= 0)
            if is_empty then
                out[slot_key]           = 0
                out[slot_key .. '_bag'] = 0
            else
                local bag, idx = _ow_resolve_sim_equip(ref)
                if bag and idx then
                    out[slot_key]           = idx
                    out[slot_key .. '_bag'] = bag
                end
            end
        end
        return out
    end
    -- Sim mode: skip the live windower merges so the panel shows pure
    -- "what would my buffs alone give me" values. Stats came in from
    -- ow_compute_stats() already containing only the sim's buff sums.
    -- The PLAYER header (and the file write at the end) still fire so
    -- the overlay updates its job display and the gearswap helper file
    -- stays in sync.
    -- We previously short-circuited the entire compute when sim was on.
    -- Now sim ADDS to real-gear stats instead of replacing them — see
    -- the sim-overlay block after this section. The function-scoped
    -- `sim_on` declared near the top of this function is still in
    -- scope here; we don't redeclare.

    -- Merge in live player stats from windower. player.stats has base+gear
    -- totals for the 7 primary attributes. These OVERRIDE any gear-only
    -- sums from parsed descriptions since the game-reported values are
    -- authoritative.
    do
        local p = windower.ffxi.get_player()
        if p then
            if p.stats then
                for _, k in ipairs({'str','dex','vit','agi','int','mnd','chr'}) do
                    if p.stats[k] then stats[k] = p.stats[k] end
                end
            end
            if p.resist then
                for _, k in ipairs({'fire','ice','wind','earth','thunder',
                                    'water','light','dark'}) do
                    if p.resist[k] then stats[k .. ' resistance'] = p.resist[k] end
                end
            end
        end
    end

    -- Merge food bonuses (parsed from the eaten food's description) into
    -- the stat dict. We skip the 7 primary attributes since player.stats
    -- already includes food's stat contribution as part of the gear+buff
    -- delta. For everything else (acc/att/etc), food is purely additive
    -- and we add it on top of the gear sum.
    do
        local SKIP = {str=true,dex=true,vit=true,agi=true,
                      ['int']=true,mnd=true,chr=true}
        for k, v in pairs(_ow_food_stats) do
            if not SKIP[k] then
                stats[k] = (stats[k] or 0) + v
            end
        end
    end

    -- ── Phantom Roll stat bonuses ─────────────────────────────────────
    -- (Removed.) GearInfo's Buff_Processing.lua line 225-244 walks
    -- every active roll buff in _ExtraData.player.buff_details and
    -- writes the roll's effect/value to this_buff[<effect_name>]:
    --   Companion's → "Pet: Regen" / "Pet: Regain"
    --   Hunter's    → "Accuracy" + "Ranged Accuracy"
    --   Chaos       → "Attack perc" (multiplicative on get_player_att)
    --   else        → this_buff[Cor_Rolls[id].effect] = value
    --                 (so Samurai's→"Store TP", Tactician's→"Regain",
    --                  Fighter's→"Double Atk", Rogue's→"Crit Rate", etc)
    -- These flow through calculate_total_haste into Buffs_inform, then
    -- attack/acc/eva/def go through compute_player_stats. We trust
    -- those outputs and DO NOT re-apply roll math here. The selective
    -- Buffs_inform stamp below picks up the non-att/acc/eva/def keys
    -- (Store TP, Double Atk, Regain, etc.) that compute_player_stats
    -- doesn't directly return.
    --
    -- The cat=6 snoop (~line 4870) still writes _ow_roll_state and
    -- _ow_roll_crooked because:
    --   * Bolter's Roll uses _ow_bolters_value in ow_compute_speed
    --   * The cast-time roll duration snapshot uses it for timer math
    --   * Crooked Cards detection is preserved for future use

    -- ── BRD song stat bonuses ───────────────────────────────────────────
    -- (Removed in Round 3.) Honor March att/acc/racc/ratt and generic
    -- song stats (Minuet/Madrigal/Minne/Prelude) used to be injected
    -- here from _ow_buff_sources['song_v2'] records. With settings.Bards
    -- now auto-populated via _ow_refresh_bard_settings (called before
    -- each _gi.refresh_all), GearInfo's check_buffs computes per-song
    -- stat values into Buffs_inform.Attack/Accuracy/etc, which flow
    -- through get_player_att / get_player_acc as the panel's canonical
    -- numbers. Keeping these blocks would double-count.
    --
    -- The cat=4 capture still writes 'song_v2' records to
    -- _ow_buff_sources for now — they're consumed by the timer/duration
    -- panel and the march haste sum (separate from stat injection).
    -- Cleanup of the unused song_v2 stat fields is a future round.

    -- ── Dual Wield job trait + BLU spell-set DW / stats ─────────────────
    -- DNC and NIN grant DW as a job trait. BLU grants DW based on points
    -- spent in equipped set spells, AND each equipped spell grants its
    -- own per-spell stat bonuses (Cocoon→VIT+2, Battery Charge→Refresh,
    -- Memento Mori→MAB, etc.). Both are auto-detected from windower's
    -- get_mjob_data() / get_sjob_data().
    -- Trait tiers (per BG-wiki):
    --   DNC: I@20=10%, II@40=15%, III@60=25%, IV@80=30%, V@95=35%
    --   NIN: I@10=10%, II@25=15%, III@45=25%, IV@65=30%, V@85=35%
    --   BLU DW: 8pts=8%, 16pts=15%, 28pts=25%, 38pts=30%
    -- For sub-job, effective level is capped at half main job's level.
    --
    -- SIM MODE: skip — sim's compute_synthetic_baseline() already
    -- applied DW trait via M.apply_traits() based on sim's chosen
    -- main_job/sub_job/master_level. The trait DW lands in stats['dw trait']
    -- exactly the same way as this block would write it.
    do
        local p = windower.ffxi.get_player()
        if p then
            -- Trait tiers per BG-wiki / FFXIclopedia:
            --   NIN: I@10=10%, II@25=15%, III@45=25%, IV@65=30%, V@85=35%
            --   DNC: I@20=10%, II@40=15%, III@60=25%, IV@80=30%, V@95=35%
            local function dw_for_job(job, level)
                if job ~= 'NIN' and job ~= 'DNC' then return 0 end
                if job == 'NIN' then
                    if level >= 85 then return 35
                    elseif level >= 65 then return 30
                    elseif level >= 45 then return 25
                    elseif level >= 25 then return 15
                    elseif level >= 10 then return 10
                    end
                elseif job == 'DNC' then
                    if level >= 95 then return 35
                    elseif level >= 80 then return 30
                    elseif level >= 60 then return 25
                    elseif level >= 40 then return 15
                    elseif level >= 20 then return 10
                    end
                end
                return 0
            end
            local main_dw = dw_for_job(p.main_job or '', p.main_job_level or 0)
            local sub_eff_lvl = math.min(p.sub_job_level or 0,
                                         math.floor((p.main_job_level or 0) / 2))
            local sub_dw  = dw_for_job(p.sub_job or '', sub_eff_lvl)
            local trait_dw = math.max(main_dw, sub_dw)
            -- BLU spell-set DW + stat bonuses + JP gifts. Pull the
            -- equipped spell list and JP summary from windower and
            -- resolve via the BLU module. Manual blu_dw_override
            -- (legacy user_config) still wins if set nonzero — useful
            -- when windower's API isn't available.
            local blu_dw = 0
            if p.main_job == 'BLU' or p.sub_job == 'BLU' then
                local spell_ids = ow_get_blu_set_spells()
                local jp_sum    = ow_get_blu_jp_summary()
                if spell_ids then
                    local _, blu_stats = ow_resolve_blu_set(spell_ids, jp_sum)
                    -- DW from set spells lands in blu_stats['dw trait'].
                    -- Pull it out into blu_dw (competes via max() with
                    -- NIN/DNC trait DW below). DO NOT mutate the
                    -- returned blu_stats table — it's the same table
                    -- ref held in _ow_blu_cache.stats, and clearing
                    -- 'dw trait' here would poison subsequent cache
                    -- hits. Instead skip 'dw trait' during the merge
                    -- loop so it doesn't double-add.
                    blu_dw = tonumber(blu_stats['dw trait']) or 0
                    -- Fold the rest of the per-set/per-spell stat
                    -- bonuses into the main stats dict. Skip 'dw trait'
                    -- (consumed separately above as blu_dw).
                    for k, v in pairs(blu_stats) do
                        if k ~= 'dw trait' then
                            stats[k] = (stats[k] or 0) + v
                        end
                    end
                end
                local manual = tonumber(ow_user_config.blu_dw_override) or 0
                if manual > 0 then blu_dw = manual end
            end
            local total_trait_dw = math.max(trait_dw, blu_dw)
            -- Store as a SEPARATE key from gear DW. The stats panel
            -- displays "DW Gear" (key 'dual wield' = gear only) and
            -- "DW Traits" (key 'dw trait' = job-trait + BLU contribution)
            -- as distinct cells. Downstream consumers (TP-calc, dw needed)
            -- read both and sum.
            stats['dw trait'] = total_trait_dw
        end
    end

    -- Haste breakdown. Uses parsed gear haste as the gear-capped input and
    -- sums magic/JA haste from active buffs. All outputs in percent.
    do
        local gear_h = stats['haste'] or 0
        local g, ma, ja, total = ow_compute_haste(gear_h)
        -- Report the CAPPED gear value as the "haste" cell to match player-visible.
        stats['haste']        = g
        stats['magic haste']  = ma
        stats['ja haste']     = ja
        stats['total haste']  = total
    end

    -- ── Time-conditional gear ───────────────────────────────────────────
    -- Some items only grant their bonus during specific in-game time
    -- windows (e.g. Hachiya Kyahan +3 = Movement Speed +12% from sundown
    -- to sunup). The description text parser doesn't capture these
    -- consistently, so we apply them here based on the FFXI clock.
    -- Game time: get_info().time = minutes-of-day (0..1439). Night runs
    -- 18:00 → 06:00 (1080..1439 + 0..359). 1 game day = 57.6 real minutes.
    do
        local info = windower.ffxi.get_info and windower.ffxi.get_info()
        local game_time = info and info.time or 0
        local is_night  = (game_time >= 1080) or (game_time < 360)
        if _ow_cast_debug then
            windower.add_to_chat(207, string.format(
                '[OW] game_time=%d (mins of day, 0..1439), is_night=%s',
                game_time, tostring(is_night)))
        end
        -- Reuse the outer function-scoped `equipment` (sim-aware) rather
        -- than re-reading windower.ffxi.get_items here, which would
        -- bypass sim's gear overrides.
        if equipment and is_night then
            -- Item id → { stat = lowercase key, value = number }.
            -- Note: VALUE here is the ADDITIVE bonus on top of any always-on
            -- bonus that the item description already carries. E.g. Hachiya
            -- Kyahan +3's description gives +12% always; this adds +13 more
            -- at night to reach the documented 25% "from dusk to dawn"
            -- total. Confirm with //ow dumpgear feet at night vs day.
            local night_only_gear = {
                [23655] = { stat = 'movement speed', value = 13 },  -- Hachiya Kyahan +3 (12 base + 13 night = 25)
                [23654] = { stat = 'movement speed', value = 13 },  -- Hachiya Kyahan +2
                [11800] = { stat = 'movement speed', value = 25 },  -- Ninja Kyahan (no day bonus)
                [15131] = { stat = 'movement speed', value = 25 },  -- Ninja Kyahan +1
            }
            -- Walk equipped slots; for each id matching the table, apply
            -- its bonus. We walk from the equipment struct, not from
            -- stats (which doesn't carry IDs by slot).
            local slots = {'main','sub','range','ammo','head','neck',
                           'left_ear','right_ear','body','hands',
                           'left_ring','right_ring','back','waist',
                           'legs','feet'}
            for _, sn in ipairs(slots) do
                local bag = equipment[sn..'_bag']
                local idx = equipment[sn]
                if idx and idx ~= 0 and bag then
                    local idata = windower.ffxi.get_items(bag, idx)
                    if idata and idata.id then
                        local rule = night_only_gear[idata.id]
                        if rule then
                            stats[rule.stat] = (stats[rule.stat] or 0) + rule.value
                        end
                    end
                end
            end
        end
    end

    -- ── Movement speed: gear + buff contributions ───────────────────────────
    -- checkparam parser puts gear mods under 'movement speed' (from the
    -- "Movement Speed+X%" item description text).
    do
        local gear_speed = stats['movement speed'] or 0
        stats['movement speed'] = ow_compute_speed(gear_speed, stats)
    end

    -- ── Job Point Gifts ─────────────────────────────────────────────────────
    -- DISABLED: Empirical testing confirms /checkparam ALREADY includes JP
    -- Gift bonuses (Physical Attack Bonus, Magic Attack Bonus, etc. from
    -- milestones at 100/300/600/... JP). GI's compute reads from
    -- player.equipment + buffs and matches /checkparam exactly. Adding
    -- gifts ON TOP of that double-counts: e.g. COR with full 8400 JP
    -- showed +41 attack from gifts in our panel but /checkparam already
    -- baked it in, leaving the panel ~41 attack high.
    --
    -- Per-tier JP purchases (below) are likely included by /checkparam
    -- too, but the user reported no observable doubling there because
    -- they hadn't spent JP in any per-tier category that maps onto a
    -- panel stat. Left active pending further validation; if those
    -- start doubling later, comment that block out the same way.
    --
    -- Original block preserved here in case the gift table needs to
    -- feed something else (e.g. simulator baselines, projection mode).
    --[==[
    do
        local p = windower.ffxi.get_player()
        local mjob = p and p.main_job
        if mjob and ow_Gifts[mjob] and ow_Gifts[mjob]['Gifts'] then
            local jp_spent = 0
            if p.job_points and p.job_points[mjob:lower()] then
                jp_spent = p.job_points[mjob:lower()].jp_spent or 0
            end
            local applied_total = 0
            local applied_log = {}
            local _GIFT_MIRROR = {
                ['accuracy']             = {'accuracy2', 'ranged accuracy'},
                ['attack']               = {'attack2',   'ranged attack'},
            }
            for threshold, bonuses in pairs(ow_Gifts[mjob]['Gifts']) do
                if jp_spent >= threshold and type(bonuses) == 'table' then
                    for bonus_name, val in pairs(bonuses) do
                        local mapped = _PW_GIFT_STAT_MAP[bonus_name]
                        if mapped then
                            stats[mapped] = (stats[mapped] or 0) + val
                            local mirror = _GIFT_MIRROR[mapped]
                            if mirror then
                                for _, mk in ipairs(mirror) do
                                    stats[mk] = (stats[mk] or 0) + val
                                end
                            end
                            applied_total = applied_total + 1
                            if _ow_cast_debug and #applied_log < 20 then
                                applied_log[#applied_log+1] = string.format(
                                    '  +%s %s (@%dJP)',
                                    tostring(val), bonus_name, threshold)
                            end
                        end
                    end
                end
            end
            if _ow_cast_debug and applied_total > 0 then
                windower.add_to_chat(207, string.format(
                    '[OW] gifts applied: %d entries at %d JP for %s',
                    applied_total, jp_spent, mjob))
                for _, line in ipairs(applied_log) do
                    windower.add_to_chat(207, line)
                end
                if applied_total > #applied_log then
                    windower.add_to_chat(207, string.format(
                        '  ... and %d more', applied_total - #applied_log))
                end
            elseif _ow_cast_debug then
                windower.add_to_chat(207, string.format(
                    '[OW] gifts applied: 0 — Gifts.lua may be missing or '..
                    'jp_spent=%d below first threshold for %s', jp_spent, mjob))
            end
        end
    end
    ]==]

    -- ── Per-tier Job Point category bonuses ────────────────────────────────
    -- Separate from the Gift table above. The per-tier purchases live
    -- directly on p.job_points[mjob:lower()] as fields holding the
    -- TIER COUNT (0-20). Each tier contributes a per-tier amount to
    -- a stat — e.g. COR's `ranged_accuracy_bonus = 20` means +20 RAcc.
    --
    -- Verified field names via //ow dumpjp. Tier-effect values come
    -- from BG-wiki's Job Point pages (the blue table, "Effect per Tier"
    -- column). Only the entries that actually move /checkparam stats
    -- are listed here — flavor effects (phantom roll duration,
    -- quick draw damage, etc.) are tracked by GearInfo elsewhere or
    -- aren't displayable on the panel.
    --
    -- Schema: _PW_JP_PER_TIER[main_job][field_name] = {stat=key, per_tier=N}
    --
    -- Only entries whose per-tier purchase actually moves a stat we
    -- display on the panel (acc/att/eva/def/macc/matk/etc.) are listed.
    -- Recast reductions, JA effect bonuses, pet-only stats, and flavor
    -- categories are intentionally omitted — they don't render here.
    --
    -- Field names verified or expected from windower's player struct
    -- (lowercase + underscores, matches BG-wiki "Category" column).
    -- Per-tier values from the "Effect per Tier" column. Max 20 tiers.
    local _PW_JP_PER_TIER = {
        -- Strict rule: only categories that are explicitly named
        -- "<Stat> Bonus" in BG-wiki AND contribute as a persistent
        -- per-tier addition to a /checkparam stat. Things like Zanshin
        -- Attack Bonus, Sange Effect, Defender Effect, Last Resort
        -- Effect, etc. are JA-conditional or flavor — they're not
        -- always-on stat rows so they're omitted.
        --
        -- Field names confirmed via //ow dumpjp where possible (COR
        -- verified). For new jobs, run //ow dumpjp first to confirm
        -- the exact key before adding here.
        RDM = {
            magic_accuracy_bonus = {stat='magic accuracy', per_tier=1},
        },
        BLU = {
            magic_accuracy_bonus = {stat='magic accuracy', per_tier=1},
        },
        COR = {
            ranged_accuracy_bonus = {stat='ranged accuracy', per_tier=1},
        },
        -- Other jobs: most don't have a "<Stat> Bonus" per-tier
        -- category that's always-on. Add as confirmed via dumpjp.
    }
    do
        local p = windower.ffxi.get_player()
        local mjob = p and p.main_job
        if mjob and _PW_JP_PER_TIER[mjob] and p.job_points
           and p.job_points[mjob:lower()] then
            local jpdata = p.job_points[mjob:lower()]
            for field_name, info in pairs(_PW_JP_PER_TIER[mjob]) do
                local tiers = tonumber(jpdata[field_name]) or 0
                if tiers > 0 then
                    local val = tiers * info.per_tier
                    stats[info.stat] = (stats[info.stat] or 0) + val
                    -- Mirror to other weapon slots when applicable
                    -- (acc/att-style stats: same as the gift mirror
                    -- table — a flat per-tier bonus from JP applies to
                    -- main, sub, and ranged in unison).
                    if info.mirror then
                        for _, mk in ipairs(info.mirror) do
                            stats[mk] = (stats[mk] or 0) + val
                        end
                    end
                    if _ow_cast_debug then
                        windower.add_to_chat(207, string.format(
                            '[OW] jp-per-tier: %s tiers=%d → +%d %s%s',
                            field_name, tiers, val, info.stat,
                            info.mirror and ' (+mirror)' or ''))
                    end
                end
            end
        end
    end

    -- ── Accuracy / Attack / Ranged / Magic / Defense / Evasion ──────────────
    -- Approximate the in-game formulas:
    --   Acc = floor(DEX * 0.75) + weapon_skill + gear + base
    --   Att = floor(STR * 0.75) + weapon_skill + gear + base
    -- Windower exposes player.combat_skills for us. Per-hand uses main vs sub
    -- weapon's skill. These values align closely with in-game /check accuracy.
    do
        local p = windower.ffxi.get_player()
        if p and p.stats and p.combat_skills then
            local dex = p.stats.dex or 0
            local str = p.stats.str or 0
            local agi = p.stats.agi or 0
            local _int = p.stats['int'] or 0

            -- Helper: get a weapon's combat skill value via its resource entry.
            local function skill_for_slot(slot_name, eq)
                local bag = eq[slot_name .. '_bag']
                local idx = eq[slot_name]
                if not idx or idx == 0 or not bag then return 0 end
                local item = windower.ffxi.get_items(bag, idx)
                if not item or not item.id then return 0 end
                local r = res.items[item.id]
                if not r or not r.skill then return 0 end
                -- combat_skills may be keyed by id or by skill-name-string.
                local v = p.combat_skills[r.skill]
                if not v and res.skills and res.skills[r.skill] then
                    local nm = res.skills[r.skill].en:lower():gsub(' ', '_')
                    v = p.combat_skills[nm]
                end
                return v or 0
            end

            -- Get sim-aware equipment view (live + user gear overrides).
            local eq = _eq_with_sim()
            local main_sk = 0
            local sub_sk  = 0
            local rng_sk  = 0
            if eq then
                main_sk = skill_for_slot('main',  eq)
                sub_sk  = skill_for_slot('sub',   eq)
                rng_sk  = skill_for_slot('range', eq)
            end

            -- Acc/Att/RAcc/RAtt/Def/Eva are computed earlier from either
            -- /checkparam scrape (preferred, exact game values) or formula
            -- approximation. We DON'T recompute them here — that block
            -- ran before scraping was added and was overwriting good values.
            -- Magic accuracy is also already set above; this block only
            -- runs the TP-per-hit / Hits-to-WS calculation that needs the
            -- per-slot weapon skill data we computed above.

        end
    end

    -- ──────────────────────────────────────────────────────────────────
    -- TP per hit + Hits to WS — ported from GearInfo Calculator.lua.
    -- The math is the BG-wiki "Tactical Points" published formulas:
    -- https://www.bg-wiki.com/ffxi/Tactical_Points
    --
    -- Modified delay rules:
    --   * Delay Reduction -% gear (Sword Strap etc) reduces delay.
    --   * Martial Arts trait reduces H2H delay.
    --   * Dual Wield trait reduces effective per-fist delay.
    --   * HASTE DOES NOT modify the delay used for TP. Haste affects
    --     swing RATE, not the delay value plugged into the TP table.
    --
    -- This block is INDEPENDENT of the Acc/Att gate above. It only needs
    -- get_player() (for job/merits/level) and equipment items, both of
    -- which are robust. Even if p.stats or p.combat_skills happens to be
    -- missing (e.g. brand-new login), this still runs.
    -- ──────────────────────────────────────────────────────────────────
    do
        if _ow_cast_debug then
            windower.add_to_chat(207, '[OW] tp-calc: ENTERED block')
        end
        local p = windower.ffxi.get_player()
        -- When sim is on, reuse the function-scoped `equipment` local
        -- (which we already replaced earlier with sim'd gear). Reading
        -- windower.ffxi.get_items('equipment') here would silently
        -- bypass the sim and read real-game equipment, breaking
        -- TP-per-hit / Hits-to-WS / DW calculations during sim.
        local eq = _eq_with_sim()
        if not (p and eq) then
            if _ow_cast_debug then
                windower.add_to_chat(207, '[OW] tp-calc: bail (no player/eq)')
            end
        else
            local function base_tp_from_delay(d)
                if     d > 0   and d <= 180 then return 61  + ((d - 180) * 63 / 360)
                elseif d > 180 and d <= 540 then return 61  + ((d - 180) * 88 / 360)
                elseif d > 540 and d <= 630 then return 149 + ((d - 540) * 20 / 360)
                elseif d > 630 and d <= 720 then return 154 + ((d - 630) * 28 / 360)
                elseif d > 720 and d <= 900 then return 161 + ((d - 720) * 24 / 360)
                elseif d > 900               then return 173 + ((d - 900) * 28 / 360)
                else return 0 end
            end

            local function _ow_get_equipped(slot)
                local bag_field = slot .. '_bag'
                local idx = eq[slot]
                local bag = eq[bag_field]
                if not (idx and idx ~= 0 and bag) then return nil end
                local it = windower.ffxi.get_items(bag, idx)
                if not (it and it.id and res.items[it.id]) then return nil end
                return res.items[it.id]
            end
            local main_item  = _ow_get_equipped('main')
            local sub_item   = _ow_get_equipped('sub')
            local range_item = _ow_get_equipped('range')
            local ammo_item  = _ow_get_equipped('ammo')

            local main_delay  = (main_item  and tonumber(main_item.delay))  or 0
            local sub_delay   = (sub_item   and tonumber(sub_item.delay))   or 0
            local range_delay = (range_item and tonumber(range_item.delay)) or 0
            local ammo_delay  = (ammo_item  and tonumber(ammo_item.delay))  or 0
            local has_real_sub = sub_item and tonumber(sub_item.damage) and tonumber(sub_item.damage) > 0
            local has_ranged   = range_item and tonumber(range_item.damage) and tonumber(range_item.damage) > 0
            local is_h2h = false
            if main_item and main_item.skill and res.skills and res.skills[main_item.skill] then
                local skname = tostring(res.skills[main_item.skill].en or '')
                is_h2h = skname:find('Hand') ~= nil
            end
            if _ow_cast_debug then
                windower.add_to_chat(207, string.format(
                    '[OW] tp-calc: main_d=%d sub_d=%d has_sub=%s h2h=%s range_d=%d',
                    main_delay, sub_delay, tostring(has_real_sub),
                    tostring(is_h2h), range_delay))
            end

            local main_job = tostring(p.main_job or ''):upper()
            local sub_job  = tostring(p.sub_job  or ''):upper()
            local main_lvl = tonumber(p.main_job_level) or 0
            local sub_lvl  = tonumber(p.sub_job_level)  or 0

            local job_stp = 0
            if main_job == 'SAM' then
                if     main_lvl >= 91 then job_stp = 30
                elseif main_lvl >= 71 then job_stp = 25
                elseif main_lvl >= 51 then job_stp = 20
                elseif main_lvl >= 31 then job_stp = 15
                elseif main_lvl >= 10 then job_stp = 10 end
            elseif sub_job == 'SAM' then
                if     sub_lvl  >= 31 then job_stp = 15
                elseif sub_lvl  >= 10 then job_stp = 10 end
            end

            local jp_stp_gift = 0
            local jp_dw_gift = 0
            local jp_ma_gift = 0
            if ow_Gifts and p.job_points then
                local jpkey = main_job:lower()
                local jpdata = p.job_points[jpkey]
                local jp_spent = (jpdata and tonumber(jpdata.jp_spent)) or 0
                local gifts_for_job = ow_Gifts[main_job] and ow_Gifts[main_job]['Gifts']
                if type(gifts_for_job) == 'table' then
                    for at_jp, gift_tbl in pairs(gifts_for_job) do
                        if tonumber(at_jp) and tonumber(at_jp) <= jp_spent and type(gift_tbl) == 'table' then
                            for k, v in pairs(gift_tbl) do
                                if k == 'Store TP Effect' then jp_stp_gift = jp_stp_gift + (tonumber(v) or 0)
                                elseif k == 'Dual Wield Effect' then jp_dw_gift = jp_dw_gift + (tonumber(v) or 0)
                                elseif k == 'Martial Arts Effect' then jp_ma_gift = jp_ma_gift + (tonumber(v) or 0)
                                end
                            end
                        end
                    end
                end
            end

            local merit_stp = 0
            local merit_ikishoten = 0
            if main_job == 'SAM' and p.merits then
                merit_stp = (tonumber(p.merits.store_tp_effect) or 0) * 2
                merit_ikishoten = tonumber(p.merits.ikishoten) or 0
            end

            -- DW total: gear + trait (now stored separately) + JP gifts.
            -- Previously these were merged into 'dual wield' but the
            -- stats panel needs them split, so we sum here.
            local total_dw = (stats['dual wield'] or 0)
                           + (stats['dw trait']   or 0)
                           + jp_dw_gift
            -- Persist jp_dw_gift so the sim-recompute block (which runs
            -- after sim buffs are applied) can include it. Without this
            -- the recompute drops the JP-gift contribution, making
            -- dw_needed jump down by jp_dw_gift% on every sim tick.
            stats['_jp_dw_gift'] = jp_dw_gift

            -- Compute base_delay per BG-wiki formulas.
            local base_delay_melee = 0
            local base_delay_range = 0
            if is_h2h then
                local h2h_base = 480
                local job_ma_red = 0
                if main_job == 'MNK' then
                    if     main_lvl >= 82 then job_ma_red = 200
                    elseif main_lvl >= 75 then job_ma_red = 180
                    elseif main_lvl >= 61 then job_ma_red = 160
                    elseif main_lvl >= 46 then job_ma_red = 140
                    elseif main_lvl >= 31 then job_ma_red = 120
                    elseif main_lvl >= 2  then job_ma_red = 100
                    elseif main_lvl >= 1  then job_ma_red = 80 end
                elseif main_job == 'PUP' then
                    if     main_lvl >= 97 then job_ma_red = 160
                    elseif main_lvl >= 87 then job_ma_red = 140
                    elseif main_lvl >= 75 then job_ma_red = 120
                    elseif main_lvl >= 50 then job_ma_red = 100
                    elseif main_lvl >= 25 then job_ma_red = 80 end
                end
                local gear_ma_red = stats['martial arts'] or 0
                h2h_base = h2h_base - job_ma_red - jp_ma_gift - gear_ma_red
                if h2h_base < 96 then h2h_base = 96 end
                local total_delay = h2h_base + main_delay
                base_delay_melee = math.floor(total_delay / 2)
            elseif has_real_sub then
                local combined = main_delay + sub_delay
                base_delay_melee = math.floor(combined * (1 - total_dw / 100) / 2)
            else
                base_delay_melee = main_delay
            end
            if has_ranged then
                base_delay_range = range_delay + ammo_delay
            end

            local base_tp_melee = math.floor(base_tp_from_delay(base_delay_melee))
            local base_tp_range = math.floor(base_tp_from_delay(base_delay_range))

            local gear_stp = stats['store tp'] or 0
            local total_stp = gear_stp + job_stp + jp_stp_gift + merit_stp
            local function apply_stp(t)
                return math.floor(t * (100 + total_stp) / 100)
            end
            local tp_per_hit_melee = apply_stp(base_tp_melee)
            local tp_per_hit_range = apply_stp(base_tp_range)
            local tp_per_hit_zanshin = 0
            if main_job == 'SAM' then
                tp_per_hit_zanshin = apply_stp(base_tp_melee + (3 * merit_ikishoten))
            end

            if tp_per_hit_melee > 0 then
                stats['tp per hit'] = tp_per_hit_melee
                stats['hits to ws'] = 1000 / tp_per_hit_melee
            elseif tp_per_hit_range > 0 then
                stats['tp per hit'] = tp_per_hit_range
                stats['hits to ws'] = 1000 / tp_per_hit_range
            end
            if tp_per_hit_range > 0 then
                stats['tp per hit ranged'] = tp_per_hit_range
                stats['hits to ws ranged'] = 1000 / tp_per_hit_range
            end
            if tp_per_hit_zanshin > 0 then
                stats['tp per hit zanshin'] = tp_per_hit_zanshin
            end
            stats['base delay melee']  = base_delay_melee
            stats['base delay ranged'] = base_delay_range
            stats['effective dw']      = total_dw
            stats['total store tp']    = total_stp
            -- Preserve the non-gear STP contribution and base TP values
            -- so the sim recompute below can re-apply STP after sim
            -- buffs (Samurai Roll) add to stats['store tp']. Without
            -- this the panel's TP-per-hit and total-store-tp cells
            -- would still show the pre-buff numbers when sim is on.
            stats['_stp_non_gear']     = job_stp + jp_stp_gift + merit_stp
            stats['_base_tp_melee']    = base_tp_melee
            stats['_base_tp_range']    = base_tp_range
            stats['_merit_ikishoten']  = merit_ikishoten
            local total_haste_pct = stats['total haste'] or 0

            -- DW-to-cap: how much MORE Dual Wield % the player needs to
            -- reach the attack-speed cap, given current haste and DW.
            --
            -- The attack-speed cap is 80% delay reduction. Haste and DW
            -- combine MULTIPLICATIVELY on the delay-multiplier:
            --   final_delay = base_delay * (1 - haste%) * (1 - DW%)
            -- We want final_delay <= base_delay * 0.20, so:
            --   (1 - haste%) * (1 - DW_total%) <= 0.20
            --   (1 - DW_total%) <= 0.20 / (1 - haste%)
            --   DW_total% >= 1 - (0.20 / (1 - haste%))
            --
            -- Examples (rounding up):
            --   haste 0%  → need 80%  total DW (no haste, full DW carries cap)
            --   haste 25% → need 73.33% total DW
            --   haste 43% → need 64.92% total DW
            --   haste >=80% (theoretical) → need 0%
            --
            -- The OLD formula here was `80 - haste`, which conflated haste-cap
            -- arithmetic with DW arithmetic and overstated the requirement
            -- when DW traits were already substantial.
            local haste_frac = math.min(0.80, math.max(0, total_haste_pct / 100))
            local dw_total_required_pct
            if haste_frac >= 0.80 then
                dw_total_required_pct = 0
            else
                dw_total_required_pct = math.ceil((1 - (0.20 / (1 - haste_frac))) * 100)
            end
            stats['dw needed'] = math.max(0, dw_total_required_pct - total_dw)

            if _ow_cast_debug then
                windower.add_to_chat(207, string.format(
                    '[OW] tp-calc: base_d_m=%d dw=%d(cell+jp%d) stp=%d(g%d+j%d+jp%d+m%d) base_tp=%d tp/hit=%d hits/ws=%.2f',
                    base_delay_melee, total_dw, jp_dw_gift,
                    total_stp, gear_stp, job_stp, jp_stp_gift, merit_stp,
                    base_tp_melee, tp_per_hit_melee,
                    (stats['hits to ws'] or 0)))
            end
        end
    end
    -- ── Sim buff overlay ────────────────────────────────────────────────────
    -- Real-gear compute is now complete. If sim is active, ADD the
    -- simulated buff contributions on top so the user can see "what
    -- would my stats become with this March/Roll active?" without
    -- re-gearing. Also re-derive Total Haste and DW Needed using the
    -- post-sim values so the displayed combat thresholds reflect the
    -- simulated state.
    -- ── Sim food overlay ────────────────────────────────────────────
    -- Sim'd food adds flat stats from a curated table (kept in
    -- OmniWatch_Sim.lua under SIM_FOOD_LIST + _FOOD_STATS). We apply
    -- BEFORE the sim buff overlay so food stacks with songs/rolls in
    -- the same way it would in-game (multiple separate sources, all
    -- additive).
    if sim_on and _sim and _sim.get_food_stats then
        local ok_f, food_stats = pcall(_sim.get_food_stats)
        if ok_f and type(food_stats) == 'table' then
            for k, v in pairs(food_stats) do
                if type(v) == 'number' then
                    -- Acc/Att food bonuses apply to both hands and ranged.
                    -- Same rule as Honor March: a flat bonus from a single
                    -- food source bumps every weapon-slot acc/att in unison.
                    if k == 'accuracy' then
                        stats['accuracy']        = (stats['accuracy']        or 0) + v
                        stats['accuracy2']       = (stats['accuracy2']       or 0) + v
                        stats['ranged accuracy'] = (stats['ranged accuracy'] or 0) + v
                    elseif k == 'attack' then
                        stats['attack']        = (stats['attack']        or 0) + v
                        stats['attack2']       = (stats['attack2']       or 0) + v
                        stats['ranged attack'] = (stats['ranged attack'] or 0) + v
                    else
                        -- Magic acc/MAB/MDmg etc. — single key, additive.
                        stats[k] = (stats[k] or 0) + v
                    end
                end
            end
        end
    end

    if sim_on and _sim and _sim.compute_active_buff_stats then
        local ok_b, buff_stats = pcall(_sim.compute_active_buff_stats)
        if ok_b and type(buff_stats) == 'table' then
            for k, v in pairs(buff_stats) do
                if type(v) == 'number' then
                    stats[k] = (stats[k] or 0) + v
                end
            end
            -- Acc/Att buffs apply to BOTH hands when dual-wielding (per
            -- BG-wiki: songs/rolls/food add the same flat amount to
            -- main, sub, and ranged simultaneously). The compute_active
            -- _buff_stats output only adds to the primary 'accuracy' /
            -- 'attack' keys, so we mirror those additions over to
            -- accuracy2 / attack2 / ranged accuracy / ranged attack.
            -- We compute the delta from the buff_stats table directly
            -- (not from stats[], which already had gear values in it
            -- before we added the buff) so we know exactly how much was
            -- added by sim and not double-add.
            local acc_add  = buff_stats['accuracy']        or 0
            local att_add  = buff_stats['attack']          or 0
            local racc_add = buff_stats['ranged accuracy'] or 0
            local ratt_add = buff_stats['ranged attack']   or 0
            -- Honor March doesn't ship racc/ratt entries today, but BRD
            -- songs that DO carry ranged bonuses would land in those
            -- keys. For acc/att, also propagate to the ranged slot
            -- since songs/food universally bump all three values.
            if acc_add > 0 then
                stats['accuracy2']       = (stats['accuracy2']       or 0) + acc_add
                stats['ranged accuracy'] = (stats['ranged accuracy'] or 0) + acc_add
            end
            if att_add > 0 then
                stats['attack2']       = (stats['attack2']       or 0) + att_add
                stats['ranged attack'] = (stats['ranged attack'] or 0) + att_add
            end
            -- racc/ratt-specific keys: only add to the ranged slot.
            -- (Already added once via the generic loop above; nothing
            -- more to do here.)

            -- Percent-based attack buffs (Chaos Roll, Indi-Fury) come
            -- through as 'attack pct' (a flat percentage like 34.7).
            -- Convert to a flat add by multiplying against the post-
            -- gear-and-buff attack value already in `stats.attack`.
            -- This applies AFTER additive buffs above so the percent
            -- stacks on top of song/food/melee gear bonuses — matching
            -- how the game evaluates: gear+food+songs additive, then
            -- rolls/indi-fury percent on top. Mirror onto attack2 and
            -- ranged attack so dual-wield + ranged attackers see it too.
            local atk_pct = buff_stats['attack pct'] or 0
            if atk_pct > 0 then
                local cur_atk  = stats['attack']        or 0
                local cur_atk2 = stats['attack2']       or 0
                local cur_rat  = stats['ranged attack'] or 0
                local mul = atk_pct / 100.0
                stats['attack']        = cur_atk  + math.floor(cur_atk  * mul)
                stats['attack2']       = cur_atk2 + math.floor(cur_atk2 * mul)
                stats['ranged attack'] = cur_rat  + math.floor(cur_rat  * mul)
            end

            -- Magic/JA haste caps are 43.75% / 25% respectively. Per
            -- user request: show the RAW value in stats[] so the panel
            -- can render over-cap in red (visualization aid for sim
            -- decisions). But Total Haste and DW Needed must use the
            -- CAPPED values, otherwise the math gets wrong delay
            -- reduction.
            -- Gear haste is also capped at 25% in the first compute
            -- path; keep parity here so dw_needed doesn't desync when
            -- toggling between sim-on and sim-off.
            local gh_cap = 25
            local mh_cap = 43.75
            local jh_cap = 25
            local gh_raw = stats['haste']       or 0
            local mh_raw = stats['magic haste'] or 0
            local jh_raw = stats['ja haste']    or 0
            local gh_eff = math.min(gh_cap, gh_raw)
            local mh_eff = math.min(mh_cap, mh_raw)
            local jh_eff = math.min(jh_cap, jh_raw)
            stats['total haste'] = math.min(80, gh_eff + mh_eff + jh_eff)

            -- Recompute DW Needed using the new haste + DW totals.
            -- Same multiplicative formula as the main path:
            --   (1 - haste_frac) * (1 - DW_total) <= 0.20
            -- INCLUDES jp_dw_gift (preserved from the first compute via
            -- the synthetic stats[_jp_dw_gift] key) so the recompute
            -- arrives at the same baseline as the first block when sim
            -- buffs add no DW/haste contributions.
            local total_dw = (stats['dual wield']   or 0)
                           + (stats['dw trait']     or 0)
                           + (stats['_jp_dw_gift']  or 0)
            local total_haste_pct = stats['total haste'] or 0
            local haste_frac = math.min(0.80, math.max(0, total_haste_pct / 100))
            local req_dw_pct
            if haste_frac >= 0.80 then
                req_dw_pct = 0
            else
                req_dw_pct = math.ceil((1 - (0.20 / (1 - haste_frac))) * 100)
            end
            stats['dw needed'] = math.max(0, req_dw_pct - total_dw)

            -- Recompute Store-TP-derived values when sim buffs (Samurai
            -- Roll) added flat STP into stats['store tp']. Mirrors the
            -- first compute path's STP block — the non-gear contribution
            -- (traits + JP gifts + merits) was preserved into
            -- stats['_stp_non_gear'] before the sim merge so we have a
            -- clean baseline to sum against the now-buffed gear STP.
            local stp_non_gear = stats['_stp_non_gear'] or 0
            local gear_stp     = stats['store tp']      or 0
            local total_stp    = gear_stp + stp_non_gear
            stats['total store tp'] = total_stp
            local function _apply_stp(t)
                return math.floor(t * (100 + total_stp) / 100)
            end
            local btm = stats['_base_tp_melee'] or 0
            local btr = stats['_base_tp_range'] or 0
            local tphm = _apply_stp(btm)
            local tphr = _apply_stp(btr)
            if tphm > 0 then
                stats['tp per hit'] = tphm
                stats['hits to ws'] = 1000 / tphm
            elseif tphr > 0 then
                stats['tp per hit'] = tphr
                stats['hits to ws'] = 1000 / tphr
            end
            if tphr > 0 then
                stats['tp per hit ranged'] = tphr
                stats['hits to ws ranged'] = 1000 / tphr
            end
            -- SAM-only zanshin TP per hit: re-derive using fresh STP.
            local _player = windower.ffxi.get_player()
            local _mj = _player and _player.main_job or ''
            if _mj == 'SAM' then
                local mi = stats['_merit_ikishoten'] or 0
                local tphz = _apply_stp(btm + (3 * mi))
                if tphz > 0 then stats['tp per hit zanshin'] = tphz end
            end
        end
    end

    -- ── Server_Stats override (post-everything) ─────────────────────────
    -- Server_Stats captures authoritative server values for two metrics:
    --   pAtt  (from 0x061 offset 48)  → primary attack
    --   def   (from 0x061 offset 50)  → defense
    --   pAcc  (from 0x063 offset 138) → primary accuracy
    --
    -- Why it matters: Phantom Roll percentage bonuses (Chaos Roll +X%
    -- Att, Hunter's Roll +X% Acc with Lanun proc, etc.) plus the
    -- RNG/COR Job Bonus multiplier create uncertainty the client can't
    -- model exactly because the proc is probabilistic per cast. The
    -- server knows the truth; we read it.
    --
    -- Ratio approach for aux/ranged: when a roll's percentage proc
    -- fires, it boosts ALL related stats by the same percentage. So
    -- if server pAtt is 9.77% higher than client modeled, then aAtt,
    -- rAtt are also 9.77% higher. We compute ratio = server / client
    -- and apply it to aux+ranged. Same for pAcc → aAcc, rAcc.
    --
    -- When proc DIDN'T fire, server == client → ratio = 1.0 → aux/
    -- ranged stay at client values (which are correct for flat-bonus
    -- effects like songs, food, gear).
    --
    -- Caveat: if client is wrong for some OTHER reason (missing gear
    -- stat, etc.), the ratio carries that error into aux/ranged. For
    -- the proc/multiplier uncertainty case this is correct.
    --
    -- Placement: AFTER the sim_on/buff_stats compute block. Last
    -- writer to attack/attack2/ranged attack/accuracy/accuracy2/ranged
    -- accuracy. Runs in both sim and normal mode.
    if OW_ServerStats then
        local ok_ss, ss = pcall(OW_ServerStats.get)
        if ok_ss and ss then
            -- Attack ratio + def
            if ss.patt then
                local client_patt = stats['attack'] or 0
                local server_patt = ss.patt
                stats['attack'] = server_patt
                if ss.def then stats['defense'] = ss.def end
                if client_patt > 0 and server_patt ~= client_patt then
                    local ratio = server_patt / client_patt
                    local cur_atk2 = stats['attack2']       or 0
                    local cur_rat  = stats['ranged attack'] or 0
                    if cur_atk2 > 0 then
                        stats['attack2'] = math.floor(cur_atk2 * ratio + 0.5)
                    end
                    if cur_rat > 0 then
                        stats['ranged attack'] = math.floor(cur_rat * ratio + 0.5)
                    end
                    if _ow_buff_debug then
                        windower.add_to_chat(207, string.format(
                            '[OW.SS] att override: %d→%d (×%.4f) aAtt→%d rAtt→%d',
                            client_patt, server_patt, ratio,
                            stats['attack2'] or 0,
                            stats['ranged attack'] or 0))
                    end
                elseif _ow_buff_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW.SS] att override: %d→%d (×1.00, aux unchanged)',
                        client_patt, server_patt))
                end
            end

            -- Accuracy ratio
            if ss.pacc then
                local client_pacc = stats['accuracy'] or 0
                local server_pacc = ss.pacc
                stats['accuracy'] = server_pacc
                if client_pacc > 0 and server_pacc ~= client_pacc then
                    local ratio = server_pacc / client_pacc
                    local cur_acc2 = stats['accuracy2']       or 0
                    local cur_rac  = stats['ranged accuracy'] or 0
                    if cur_acc2 > 0 then
                        stats['accuracy2'] = math.floor(cur_acc2 * ratio + 0.5)
                    end
                    if cur_rac > 0 then
                        stats['ranged accuracy'] = math.floor(cur_rac * ratio + 0.5)
                    end
                    if _ow_buff_debug then
                        windower.add_to_chat(207, string.format(
                            '[OW.SS] acc override: %d→%d (×%.4f) aAcc→%d rAcc→%d',
                            client_pacc, server_pacc, ratio,
                            stats['accuracy2'] or 0,
                            stats['ranged accuracy'] or 0))
                    end
                elseif _ow_buff_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW.SS] acc override: %d→%d (×1.00, aux unchanged)',
                        client_pacc, server_pacc))
                end
            end
        end
    end

    -- ── Flatten nested sub-dicts before serialization ──────────────────
    -- The wire format ('STAT|<key>|<value>' lines) and the gearswap-side
    -- Lua file serializer (further below) both call `tostring(v)` on the
    -- value, which on a table produces "table: 0x7f..." — useless on the
    -- Python side (parser tries float(parts[2]) and silently drops the
    -- line) and useless to gearswaps. Sub-dicts must therefore be flat-
    -- tened to dotted keys. Today only stats['resist'] is nested; if more
    -- nested sub-dicts get added later, extend this block.
    --
    -- Wire keys: 'resist.fire', 'resist.dark', etc. The Python parser is
    -- patched to detect 'resist.<elem>' prefix and re-group into a real
    -- dict on player_stats['resist'][<elem>] before the panel render.
    if type(stats['resist']) == 'table' then
        for elem, val in pairs(stats['resist']) do
            stats['resist.' .. tostring(elem)] = val
        end
        stats['resist'] = nil
    end

    local lines = {}
    for k, v in pairs(stats) do
        -- Skip cruft stat names that crept in from bad parses (empty, too long).
        -- Skip underscore-prefixed keys: those are internal scratch
        -- values (like _jp_dw_gift) used to pass info between compute
        -- blocks within the same tick, not for display.
        if k ~= '' and #k < 64 and k:sub(1, 1) ~= '_' then
            lines[#lines + 1] = string.format('STAT|%s|%s',
                k:gsub('|', '/'), tostring(v))
        end
    end
    -- Header line: PLAYER|<name>|<main_job>|<sub_job>
    -- Sim now uses live player's job (per the new "live + delta" spec),
    -- so we always read from windower regardless of sim state.
    local pname, mjob, sjob = '', '', ''
    do
        local player = windower.ffxi.get_player()
        pname = (player and player.name) or ''
        mjob  = (player and player.main_job) or ''
        sjob  = (player and player.sub_job)  or ''
    end
    local header = string.format('PLAYER|%s|%s|%s', pname, mjob, sjob)
    local payload
    if #lines == 0 then
        payload = 'BEGIN\n' .. header
    else
        payload = 'BEGIN\n' .. header .. '\n' .. table.concat(lines, '\n')
    end
    local ok_send, send_err = udp_stats:send(payload)
    if _ow_cast_debug then
        windower.add_to_chat(207, string.format(
            '[OW] stats sent: %d stat-lines, payload=%dB, ok=%s%s',
            #lines, #payload, tostring(ok_send),
            send_err and (' err=' .. tostring(send_err)) or ''))
    end
    if _ow_buff_debug then
        windower.add_to_chat(207, string.format(
            '[OW DIAG] stats sent: defense=%s ok=%s',
            tostring(stats['defense']), tostring(ok_send)))
    end

    -- Also write stats to a Lua file that any gearswap can require:
    --   <windower>/addons/OmniWatch/data/omniwatch_stats.lua
    -- Usage from gearswap:
    --   local f = loadfile(windower.addon_path..'addons/OmniWatch/data/omniwatch_stats.lua')
    --   if f then local s = f(); if (s.haste or 0) >= 25 then ... end end
    pcall(function()
        local dir  = windower.addon_path .. 'addons/OmniWatch/data'
        -- Ensure dir exists (best-effort on Windows via pcall).
        local path = dir .. '/omniwatch_stats.lua'
        local f = io.open(path, 'w')
        if not f then return end
        f:write('-- Auto-generated by OmniWatch; do not edit.\n')
        f:write('return {\n')
        for k, v in pairs(stats) do
            if k ~= '' and #k < 64 then
                local safe_k = k:gsub('\\', '\\\\'):gsub('"', '\\"')
                f:write(string.format('  ["%s"] = %s,\n', safe_k, tostring(v)))
            end
        end
        f:write(string.format('  _player   = "%s",\n', pname))
        f:write(string.format('  _main_job = "%s",\n', mjob))
        f:write(string.format('  _sub_job  = "%s",\n', sjob))
        f:write('}\n')
        f:close()
    end)
end

-- ── Main prerender loop ──────────────────────────────────────────────────────
ow_safe_register('prerender', function()
    local now = os.clock()

    -- Drain python→lua control channel first thing each frame so sim
    -- mode flips and other settings take effect before any compute.
    _ow_drain_inbound()

    -- ── Server_Stats tick ─────────────────────────────────────────────
    -- Lets the module fire any pending packet injection whose delay has
    -- elapsed. Cheap when nothing's queued (just a clock comparison).
    if OW_ServerStats then
        pcall(OW_ServerStats.tick)
    end

    -- ── Server_Stats dirty flag ───────────────────────────────────────
    -- When Server_Stats captures a fresh subtype-384 sample its
    -- on_capture callback sets _ow_serverstats_dirty=true. Force a
    -- stats recompute+send right now so the panel updates immediately
    -- with the server-truth pAtt/def values, instead of waiting for
    -- the next 1Hz tick or buff change.
    if _ow_serverstats_dirty then
        _ow_serverstats_dirty = false
        local ok_st, err_st = pcall(function()
            local s = ow_compute_stats()
            ow_send_stats(s)
        end)
        if not ok_st then
            windower.add_to_chat(123,
                '[OmniWatch] serverstats recompute err: ' .. tostring(err_st))
        end
    end

    -- Bags-at-top inventory snapshot (always-on). Rate-limited to once
    -- every 5 seconds. Drives the python bags widget that shows item
    -- counts per bag in the header.
    if (now - _ow_bag_inv_last_emit) >= 5.0 then
        pcall(_ow_emit_inventory_snapshot)
    end

    -- Send sim inventory snapshot when needed. Rate-limited to once per
    -- second so we don't spam UDP on rapid inventory changes (item use
    -- bursts after a fight, etc.). Only fires when sim is active —
    -- when sim is off, python doesn't need this data.
    if _sim and _sim.is_active and _sim.is_active() then
        if _ow_inv_snap_dirty and (now - _ow_inv_snap_last_sent) >= 1.0 then
            _ow_inv_snap_dirty = false
            pcall(_ow_send_sim_inventory)
        end
    end

    -- Party data at 10 Hz
    if now - last_send >= 0.1 then
        last_send = now

        -- Wrap everything in pcall so one bad frame (e.g. during zoning, when
        -- windower APIs briefly return nil) doesn't kill the prerender hook
        -- and freeze the data feed permanently.
        local ok, err = pcall(function()
            local party  = windower.ffxi.get_party()
            local player = windower.ffxi.get_player()
            if not party or not player then return end

            local data = ""
            local player_id = player.id or 0

            -- Build the per-member encoded string.
            -- group_id: 0=main party, 1=alliance 1, 2=alliance 2.
            -- Buffs are only computed for main party — alliance buffs aren't
            -- reliably exposed by Windower for non-local-zone members and
            -- the alliance render strip skips them anyway.
            local function encode_member(member, group_id)
                if not (member and member.mob and member.name) then return '' end
                local buffs = {}
                if group_id == 0 then
                    if member.mob.id == player_id then
                        buffs = player.buffs or {}
                    else
                        buffs = party_buffs[member.mob.id] or {}
                    end
                end
                local buff_string = ''
                -- Pair each buff with its numeric id in the wire format
                -- so the python side can render the status icon. Format:
                --   "<id>:<label>|" per buff, plus " x<n>" suffix on the
                -- label when it appears multiple times (Saber Madrigal x2,
                -- etc.). Python parses by splitting first '|', then split
                -- the leading 'id:' off the front of each entry; entries
                -- without a colon are treated as legacy name-only.
                -- Also kicks off async icon extraction for any new ids.
                local counts, order, ids = {}, {}, {}
                for _, b in ipairs(buffs) do
                    if b and b ~= 0 then
                        local label = buff_name(b)
                        if counts[label] == nil then
                            order[#order + 1] = label
                            counts[label] = 1
                            ids[label] = b   -- record id for first-seen
                            ensure_status_icon(b)
                        else
                            counts[label] = counts[label] + 1
                        end
                    end
                end
                for _, label in ipairs(order) do
                    local n = counts[label]
                    local id = ids[label] or 0
                    if n > 1 then
                        buff_string = buff_string .. tostring(id) .. ':'
                                      .. label .. ' x' .. tostring(n) .. '|'
                    else
                        buff_string = buff_string .. tostring(id) .. ':'
                                      .. label .. '|'
                    end
                end

                local hp  = member.hp  or 0
                local hpp = member.hpp or 0
                local mp  = member.mp  or 0
                local tp  = member.tp  or 0

                local mj, mjl, sj, sjl = '', 0, '', 0
                if member.mob.id == player_id then
                    mj  = player.main_job       or ''
                    mjl = player.main_job_level or 0
                    sj  = player.sub_job        or ''
                    sjl = player.sub_job_level  or 0
                else
                    mj  = member.main_job       or member.mjob or ''
                    mjl = member.main_job_level or member.mlvl or 0
                    sj  = member.sub_job        or member.sjob or ''
                    sjl = member.sub_job_level  or member.slvl or 0
                end
                if type(mj) == 'number' then mj = job_abbr(mj) end
                if type(sj) == 'number' then sj = job_abbr(sj) end

                local mob_idx = (member.mob and member.mob.index) or 0
                local pid = (member.mob and member.mob.id) or 0

                -- Pet: each party member's mob exposes .pet_index → the
                -- mob array slot of their pet (0 = no pet). Resolve it
                -- to fetch live name + hpp + tp. Pet TP isn't always
                -- exposed (alliance pets in distant zones, recently
                -- summoned avatars before the next packet), so default
                -- to 0 quietly. Fields 14, 15, 16 in the wire format.
                local pet_name, pet_hpp, pet_tp = '', 0, 0
                local pi = (member.mob and member.mob.pet_index) or 0
                if pi and pi ~= 0 then
                    local pet = windower.ffxi.get_mob_by_index(pi)
                    if pet and pet.name then
                        pet_name = pet.name
                        pet_hpp  = tonumber(pet.hpp) or 0
                        pet_tp   = tonumber(pet.tp)  or 0
                    end
                end

                return
                    tostring(member.name) .. ',' ..
                    tostring(hp)          .. ',' ..
                    tostring(hpp)         .. ',' ..
                    tostring(mp)          .. ',' ..
                    tostring(tp)          .. ',' ..
                    buff_string           .. ',' ..
                    tostring(mj)          .. ',' ..
                    tostring(mjl)         .. ',' ..
                    tostring(sj)          .. ',' ..
                    tostring(sjl)         .. ',' ..
                    tostring(mob_idx)     .. ',' ..
                    tostring(pid)         .. ',' ..
                    tostring(group_id)    .. ',' ..
                    tostring(pet_name)    .. ',' ..
                    tostring(pet_hpp)     .. ',' ..
                    tostring(pet_tp)      .. ';'
            end

            -- Main party: p0..p5 (group 0).
            for i = 0, 5 do
                data = data .. encode_member(party['p'..i], 0)
            end
            -- Alliance party 1: a10..a15 (group 1).
            for i = 0, 5 do
                data = data .. encode_member(party['a1'..i], 1)
            end
            -- Alliance party 2: a20..a25 (group 2).
            for i = 0, 5 do
                data = data .. encode_member(party['a2'..i], 2)
            end

            if data ~= "" then
                udp:send(data)
            end
        end)

        if not ok then
            -- Rate-limit the error spam: only print a given error once per 10s.
            local last_err_time = _omniwatch_last_err_time or 0
            if now - last_err_time > 10 then
                windower.add_to_chat(123, '[OmniWatch] party send error: ' .. tostring(err))
                _omniwatch_last_err_time = now
            end
        end
    end

    -- Equipment data at 2 Hz (changes rarely, no need to hammer it)
    if now - last_equip_send >= 0.5 then
        last_equip_send = now

        -- Every 30s, forget all cached rich ids so the next loop resends
        -- everything (handles case where Python restarted or dropped packets).
        if now - last_rich_full >= 30 then
            last_rich_full = now
            for k in pairs(last_rich_ids) do last_rich_ids[k] = nil end
            last_ammo_count = -1   -- force resend on next tick
        end

        local ok_eq, err_eq = pcall(function()
            local equipment = windower.ffxi.get_items('equipment')
            if not equipment then return end
            local ids = {}

            for pos = 0, 15 do
                local entry   = DISPLAY_ORDER[pos]
                local bag     = equipment[entry.slot_name .. '_bag']
                local index   = equipment[entry.slot_name]
                local item_id = 0
                local item_data = nil

                if index and index ~= 0 and bag then
                    item_data = windower.ffxi.get_items(bag, index)
                    if item_data then
                        item_id = item_data.id or 0
                    end
                end

                if item_id ~= 0 then
                    ensure_icon(item_id)
                end

                ids[#ids + 1] = tostring(item_id)

                -- Ammo slot (pos 3): also track and send stack count.
                -- Unlike the rich packet this can change without the item
                -- id changing (shooting arrows, consuming shihei/alexandrites).
                if pos == 3 then
                    local cnt = 0
                    if item_data and item_data.count then
                        cnt = item_data.count
                    end
                    if last_ammo_count ~= cnt then
                        last_ammo_count = cnt
                        -- COUNT|pos|item_id|count — lightweight extension
                        -- packet on the same 5007 socket.
                        udp_equip_rich:send(string.format('COUNT|%d|%d|%d',
                            pos, item_id, cnt))
                    end
                end

                -- Rich metadata: send once per slot when the equipped item
                -- changes (or first-ever send). Covers real augments from
                -- the item instance, not generic resource augments.
                if last_rich_ids[pos] ~= item_id then
                    last_rich_ids[pos] = item_id

                    if item_id == 0 then
                        -- Empty slot: clear the tooltip cache on python side.
                        udp_equip_rich:send(string.format('%d|0|||||||||', pos))
                    else
                        -- Wrap in its own pcall so one bad item doesn't
                        -- break rich sends for the other 15 slots.
                        local ok_rich, rich_err = pcall(function()
                            local resource = res.items and res.items[item_id]
                            local name = ''
                            local ilvl = 0
                            local cat  = ''
                            local lvl  = 0
                            local jobs = ''
                            if resource then
                                name = resource.en or resource.english or resource.name or ''
                                ilvl = tonumber(resource.item_level) or 0
                                lvl  = tonumber(resource.level) or 0
                                cat  = tostring(resource.category or '')
                                if resource.jobs then
                                    local jlist = {}
                                    local jdata = resource.jobs
                                    if type(jdata) == 'table' then
                                        for k, v in pairs(jdata) do
                                            -- Handle both {[jid]=true} and {jid1, jid2, ...} forms.
                                            local jid = (type(k) == 'number' and v == true) and k
                                                     or (type(v) == 'number' and v)
                                                     or nil
                                            if jid and res.jobs and res.jobs[jid] then
                                                jlist[#jlist + 1] = res.jobs[jid].ens or ''
                                            end
                                        end
                                    end
                                    jobs = table.concat(jlist, ',')
                                end
                            end
                            -- Real augments from the equipped item instance.
                            local augs = {}
                            if item_data and item_data.augments then
                                for _, a in ipairs(item_data.augments) do
                                    if a and a ~= '' and a ~= 'none' then
                                        augs[#augs + 1] = tostring(a)
                                    end
                                end
                            end
                            local function esc(s) return tostring(s or ''):gsub('|', '/') end
                            -- Fallback name if resource lookup missed.
                            if name == '' and item_data and item_data.name then
                                name = item_data.name
                            end
                            if name == '' then
                                name = 'Item #' .. tostring(item_id)
                            end
                            udp_equip_rich:send(string.format(
                                '%d|%d|%s|%d|%s|%s|%d|%s|%s|%s|%s',
                                pos, item_id, esc(name), ilvl, esc(jobs),
                                esc(cat), lvl,
                                esc(augs[1]), esc(augs[2]), esc(augs[3]), esc(augs[4])))
                            if _ow_gs_debug then
                                windower.add_to_chat(207, string.format(
                                    '[OW] rich slot=%d id=%d name=%s augs=%d',
                                    pos, item_id, name, #augs))
                            end
                        end)
                        if not ok_rich and _ow_gs_debug then
                            windower.add_to_chat(123, string.format(
                                '[OW] rich err slot=%d id=%d: %s',
                                pos, item_id, tostring(rich_err)))
                        end
                    end
                end
            end

            udp_equip:send(table.concat(ids, '|'))
        end)
        if not ok_eq then
            local last_err_time = _omniwatch_last_eq_err_time or 0
            if now - last_err_time > 10 then
                windower.add_to_chat(123, '[OmniWatch] equip send error: ' .. tostring(err_eq))
                _omniwatch_last_eq_err_time = now
            end
        end
    end

    -- Sim mode: signature check on a fast cadence (10 Hz). Stats
    -- update the moment the user clicks +/- in the sim window without
    -- waiting up to a second for the next 1 Hz tick. The signature
    -- compute is cheap (just a string concat over a few sim values),
    -- and ow_compute_stats only fires when the sig actually changed,
    -- so we don't pay for a recompute every 100ms — just on actual
    -- user interaction.
    if _sim and _sim.is_active and _sim.is_active() then
        if not _ow_last_sim_poll or now - _ow_last_sim_poll >= 0.1 then
            _ow_last_sim_poll = now
            local sig_parts = {}
            if _sim.get_equipment then
                local eq = _sim.get_equipment() or {}
                local keys = {}
                for k in pairs(eq) do keys[#keys+1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local ref = eq[k]
                    local serial
                    if type(ref) == 'table' then
                        serial = string.format('%d@%d:%d',
                            tonumber(ref.id) or 0,
                            tonumber(ref.bag) or 0,
                            tonumber(ref.idx) or 0)
                    else
                        serial = tostring(ref)
                    end
                    sig_parts[#sig_parts+1] = k .. '=' .. serial
                end
            end
            if _sim.list_active_buffs then
                local ab = _sim.list_active_buffs()
                for _, b in ipairs(ab) do
                    sig_parts[#sig_parts+1] = string.format('%s/%d/%d/%s/%s/%s',
                        b.id, b.plus or 0, b.level or 0,
                        tostring(b.optimal),
                        tostring(b.boost_sv or b.boost_cc or false),
                        tostring(b.boost_marcato or false))
                end
            end
            local sim_sig_fast = table.concat(sig_parts, '|')
            if sim_sig_fast ~= _ow_stats_last_simsig then
                _ow_stats_last_simsig = sim_sig_fast
                local ok_st, err_st = pcall(function()
                    local stats = ow_compute_stats()
                    ow_send_stats(stats)
                end)
                if not ok_st then
                    windower.add_to_chat(123,
                        '[OmniWatch] sim stats err: ' .. tostring(err_st))
                end
                -- Mark the slower 1 Hz path as "just sent" so it doesn't
                -- redo the work right after on its next tick.
                last_stats_send = now
            end
        end
    else
        _ow_stats_last_simsig = nil
    end

    -- ── Live buff fast-poll (10 Hz) ─────────────────────────────────────
    -- Hoists the buff-list change detection from the slower 1Hz block
    -- into a fast-poll path so roll buffs, song buffs, food buffs, etc.
    -- reflect on the panel within ~100ms of landing instead of within 1s.
    -- Critical for COR rolls in particular: the buff_potency value
    -- written by GearInfo's Action_Processing flows through Buffs_inform,
    -- and the panel needs a recompute to surface those numbers. Without
    -- this fast-poll, the user sees the panel "lag" the actual roll by
    -- up to one full second.
    --
    -- Only runs when sim is NOT active (sim has its own fast-poll above
    -- and they'd race). Cheap: just walks p.buffs, sorts, joins. The
    -- expensive ow_compute_stats only fires when the sig changed.
    if not (_sim and _sim.is_active and _sim.is_active()) then
        if not _ow_last_buff_poll or now - _ow_last_buff_poll >= 0.1 then
            _ow_last_buff_poll = now
            local p_fast = windower.ffxi.get_player()
            local buffs_sig_fast = ''
            if p_fast and p_fast.buffs then
                local bs = {}
                for _, bid in ipairs(p_fast.buffs) do
                    bs[#bs+1] = tostring(bid)
                end
                table.sort(bs)
                buffs_sig_fast = table.concat(bs, ',')
            end
            if buffs_sig_fast ~= _ow_stats_last_buffsig then
                _ow_stats_last_buffsig = buffs_sig_fast
                local ok_st, err_st = pcall(function()
                    local stats = ow_compute_stats()
                    ow_send_stats(stats)
                end)
                if not ok_st then
                    windower.add_to_chat(123,
                        '[OmniWatch] buff stats err: ' .. tostring(err_st))
                end
                -- Mark slower 1Hz path as just-sent so it skips its next tick.
                last_stats_send = now
                -- Server_Stats re-fetch on ANY buff change. Catches buff
                -- wear-offs (Double-Up Chance ending, song dropping, food
                -- expiring) and buff gains (party songs landing on us,
                -- indi/geo bubbles, food eaten, etc.). Without this, the
                -- 30s cache from the last roll cast goes stale and the
                -- panel falls back to client-modeled Att — which won't
                -- include things like Job Bonus from Lanun proc that
                -- only the server knows about.
                -- Wrapped in pcall so a buggy module call can't disrupt
                -- the buff fast-poll path.
                -- Trigger Server_Stats request on buff change so we
                -- can capture fresh post-roll values reliably. v2 is
                -- a passive listener — request() is essentially a hint
                -- that the cache may want to update, not an active
                -- packet inject, so this is cheap to fire on every
                -- buff change. Wrapped in pcall.
                if OW_ServerStats then
                    pcall(function()
                        OW_ServerStats.request('buff_change')
                    end)
                end
                if _ow_buff_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW DIAG] buff fast-poll triggered recompute (sig=%s)',
                        buffs_sig_fast:sub(1, 80)))
                end
            end
        end
    end

    -- Character stats at 1 Hz, but only recompute if equipment changed.
    if now - last_stats_send >= 1.0 then
        last_stats_send = now
        -- Prune any buff source entries whose buff_id is no longer active.
        -- Has to happen before haste/speed compute so wore-off songs/spells
        -- don't keep contributing to the displayed stats.
        pcall(_ow_prune_buff_sources)
        local changed = false

        -- Force resend every 30s (handles python restart or dropped packets).
        local full = false
        if not _ow_stats_last_full or now - _ow_stats_last_full >= 30 then
            _ow_stats_last_full = now
            full = true
        end

        -- Also force on job change since the job is part of the header.
        local p = windower.ffxi.get_player()
        local cur_job = p and (p.main_job or '') .. '/' .. (p.sub_job or '') or ''
        if cur_job ~= _ow_stats_last_job then
            _ow_stats_last_job = cur_job
            full = true
        end

        -- Also force on haste/speed-buff change (so those cells update
        -- when buffs are cast on or wear off you).
        local PW_SPEED_BUFF_IDS = {}
        for _, bid in ipairs({PW_BUFF_BOLTERS, PW_BUFF_MAZURKA,
                              PW_BUFF_QUICKENING, PW_BUFF_BOLT_STORM,
                              PW_BUFF_WEIGHT, PW_BUFF_BIND,
                              PW_BUFF_ENCUMBRANCE}) do
            if bid then PW_SPEED_BUFF_IDS[bid] = true end
        end
        local haste_sig = ''
        if p and p.buffs then
            local hs = {}
            for _, bid in ipairs(p.buffs) do
                if PW_HASTE_BUFFS[bid] or PW_SPEED_BUFF_IDS[bid] then
                    hs[#hs+1] = tostring(bid)
                end
            end
            table.sort(hs)
            haste_sig = table.concat(hs, ',')
        end
        if haste_sig ~= _ow_stats_last_hastesig then
            _ow_stats_last_hastesig = haste_sig
            full = true
        end

        -- ── Any-buff signature ─────────────────────────────────────
        -- The haste signature above only covers haste/speed buffs; it
        -- misses songs, rolls, and most defensive buffs (Minne adds
        -- DEF, Madrigal/Minuet add Acc/Att, Carols add resists, etc.)
        -- Without re-detecting those, the stats panel doesn't refresh
        -- when those buffs land — Buffs_inform updates internally but
        -- the panel keeps showing the pre-buff numbers because we
        -- never call compute_stats / send_stats for them.
        --
        -- Solution: hash the entire buff id list. Any change to any
        -- buff (gain, drop, swap) triggers a recompute. This fires a
        -- bit more often than strictly necessary (e.g. a sneeze buff
        -- that doesn't affect any panel stat still re-runs compute),
        -- but compute_stats is fast and runs at 1 Hz max anyway, so
        -- the cost is negligible compared to the bug it fixes.
        local buffs_sig = ''
        if p and p.buffs then
            local bs = {}
            for _, bid in ipairs(p.buffs) do
                bs[#bs+1] = tostring(bid)
            end
            table.sort(bs)
            buffs_sig = table.concat(bs, ',')
        end
        if buffs_sig ~= _ow_stats_last_buffsig then
            if _ow_buff_debug and _ow_stats_last_buffsig then
                windower.add_to_chat(207,
                    '[OW DIAG] buff sig changed → stats refresh: '
                    .. tostring(_ow_stats_last_buffsig)
                    .. ' → ' .. tostring(buffs_sig))
            end
            _ow_stats_last_buffsig = buffs_sig
            full = true
        end

        local cur = windower.ffxi.get_items and windower.ffxi.get_items('equipment')
        if cur then
            for pos = 0, 15 do
                local entry = DISPLAY_ORDER[pos]
                local bag   = entry and cur[entry.slot_name .. '_bag']
                local index = entry and cur[entry.slot_name]
                local iid   = 0
                if index and index ~= 0 and bag then
                    local d = windower.ffxi.get_items(bag, index)
                    if d then iid = d.id or 0 end
                end
                if last_stats_ids[pos] ~= iid then
                    if _ow_cast_debug then
                        windower.add_to_chat(207, string.format(
                            '[OW] gear-diff pos=%d slot=%s prev_id=%s new_id=%s',
                            pos,
                            (entry and entry.slot_name) or '?',
                            tostring(last_stats_ids[pos]),
                            tostring(iid)))
                    end
                    last_stats_ids[pos] = iid
                    changed = true
                    -- Server_Stats re-fetch on gear change. A piece of
                    -- gear coming on or off can shift pAtt independent of
                    -- any buff change (e.g. swapping main weapon, ring,
                    -- waist mid-fight). Without this, the cached server
                    -- pAtt stays stuck on the value from the gear set
                    -- when the last roll was cast, even if you've now
                    -- swapped to a different set.
                    -- Trigger Server_Stats on gear change so the
                    -- cached pAtt updates when we swap weapon sets.
                    -- Without this, cached server pAtt stays stuck on
                    -- the value from the gear set when the last roll
                    -- was cast, even after we've swapped to a different
                    -- set. v2 is a passive listener so request() is
                    -- nearly free (just a "consider me dirty" hint).
                    if OW_ServerStats then
                        pcall(function()
                            OW_ServerStats.request('gear_change')
                        end)
                    end
                end
            end
        else
            if _ow_cast_debug then
                windower.add_to_chat(207,
                    '[OW] gear-diff: get_items(equipment) returned nil')
            end
        end

        -- (Sim signature check moved earlier in the prerender into a
        -- 10 Hz fast-poll path — see _ow_last_sim_poll above. The 1 Hz
        -- block here only handles non-sim changes: gear, jobs, haste
        -- buffs. Sim-only changes are already handled before we get
        -- here, so we don't repeat the work.)

        if changed or full then
            if _ow_buff_debug then
                windower.add_to_chat(207, string.format(
                    '[OW DIAG] stats compute+send: changed=%s full=%s',
                    tostring(changed), tostring(full)))
            end
            local ok_st, err_st = pcall(function()
                local stats = ow_compute_stats()
                ow_send_stats(stats)
            end)
            if not ok_st then
                windower.add_to_chat(123, '[OmniWatch] stats err: ' .. tostring(err_st))
            end
        end
    end

    -- Gil at 2 Hz on the gearswap channel as GIL|<n>. Only pushes when
    -- the value changes OR every 10s as a heartbeat, so a late-starting
    -- omniwatch.py overlay picks up the value within 10s of starting.
    -- Note: gil lives in get_items().gil, NOT get_player().gil.
    if now - last_gil_send >= 0.5 then
        last_gil_send = now
        pcall(function()
            local items = windower.ffxi.get_items()
            local gil   = (items and items.gil) or 0
            local hb    = (now - (_ow_last_gil_heartbeat or 0)) >= 10
            if gil ~= last_gil_value or hb then
                last_gil_value = gil
                _ow_last_gil_heartbeat = now
                udp_gs:send('GIL|' .. tostring(gil))
                if _ow_gs_debug then
                    windower.add_to_chat(207, string.format(
                        '[OW] sent GIL=%d', gil))
                end
            end
        end)
    end

    -- Target data at 5 Hz. Sends BOTH main and sub-target info in one
    -- payload; they're separated by '||'. Each is 6 pipe-separated fields:
    --   name|id|hpp|family|zone_id|distance
    -- A missing target sends an empty segment (the '||' delimiter is still
    -- present so the Python side can tell them apart).
    if now - last_target_send >= 0.2 then
        last_target_send = now
        local ok_tg, err_tg = pcall(function()
            local info    = windower.ffxi.get_info()
            local zone_id = 0
            if info and info.zone then zone_id = info.zone end

            local function encode_mob(mob)
                if not mob then return '' end
                local name   = mob.name or ''
                local id     = mob.id   or 0
                local hpp    = mob.hpp  or 0
                local family = 0
                if mob.models and type(mob.models) == 'table' and mob.models[1] then
                    family = mob.models[1]
                end
                -- mob.distance is the SQUARED distance (yalms^2).
                local dist_sq = mob.distance or 0
                local dist = 0.0
                if dist_sq and dist_sq > 0 then dist = math.sqrt(dist_sq) end
                -- target_index: who this mob is locked onto (zone-local index).
                -- claim_id: entity ID of who has claim on the mob.
                -- The Python overlay tries both: target_index against the
                -- party member's mob.index, claim_id against the member's
                -- player.id. Reliable detection requires both since
                -- target_index is sometimes 0 even on aggro'd mobs.
                local tgt_idx = mob.target_index or 0
                local claim   = mob.claim_id or 0
                -- Classifier (per lor_ffxi.lua convention which is the
                -- standard across Windower addons):
                --   self            id == player.id
                --   trust           spawn_type 14 (alter ego)
                --   mob (enemy)     is_npc == true AND spawn_type ~= 14
                --   pc / NPC        otherwise
                -- Don't trust spawn_type==16 alone — many mob types use
                -- different spawn_types, and your own character can have
                -- spawn_type 1/13 depending on context. is_npc is the
                -- authoritative flag for "this is a server-controlled
                -- entity" (mobs and friendly NPCs).
                local me_id = (windower.ffxi.get_player() or {}).id or 0
                local is_pc = 1
                local kind = 'pc'
                if mob.id == me_id then
                    -- Self — render as PC card (no abilities, no aggro).
                    kind = 'pc'
                elseif mob.spawn_type == 14 then
                    kind = 'trust'
                elseif mob.is_npc then
                    is_pc = 0
                    -- GearSwap convention: friendly NPCs (vendors, quest-
                    -- givers, moogles) live at zone-local index >2047,
                    -- enemy monsters live at 0..2047. The mod-4096 strips
                    -- the zone byte. This is the most reliable way to
                    -- distinguish NPCs from mobs since both share is_npc.
                    if (mob.id % 4096) > 2047 then
                        kind = 'npc'
                    else
                        kind = 'mob'
                    end
                end
                -- For PC kind, resolve race id → display name (e.g. "Hume").
                -- res.races returns entries like {id=1, en='Hume',
                -- enl='Hume male', ja=...}. We strip the male/female suffix
                -- so both genders share the same race line. For mobs/trusts
                -- we send empty (Python will ignore).
                local race_str = ''
                -- Race-and-sex key for icon lookup: "HumeMale", "HumeFemale",
                -- "ElvaanMale", "ElvaanFemale", "TarutaruMale", "TarutaruFemale",
                -- "Mithra", "Galka". Race ID directly encodes both:
                --   1=Hume M, 2=Hume F, 3=Elvaan M, 4=Elvaan F,
                --   5=Tarutaru M, 6=Tarutaru F, 7=Mithra (always F),
                --   8=Galka (always M, technically genderless).
                -- Used by Python to look up mob_icons/HumeMale.png etc.
                local race_key = ''
                if kind == 'pc' and res.races then
                    -- Resolve race ID. mob.race is reliable for OTHER PCs
                    -- but is sometimes missing/zero for self — Windower's
                    -- get_mob_by_target('t') returns a partial struct when
                    -- the target is the current player. Fall back to
                    -- get_player() for self.
                    local race_id = mob.race
                    if (not race_id or race_id == 0) and mob.id == me_id then
                        local p = windower.ffxi.get_player()
                        if p and p.race then
                            race_id = p.race
                        end
                    end
                    if race_id and race_id > 0 then
                        local r = res.races[race_id]
                        if r and r.en then
                            race_str = r.en
                        end
                        if     race_id == 1 then race_key = 'HumeMale'
                        elseif race_id == 2 then race_key = 'HumeFemale'
                        elseif race_id == 3 then race_key = 'ElvaanMale'
                        elseif race_id == 4 then race_key = 'ElvaanFemale'
                        elseif race_id == 5 then race_key = 'TarutaruMale'
                        elseif race_id == 6 then race_key = 'TarutaruFemale'
                        elseif race_id == 7 then race_key = 'Mithra'
                        elseif race_id == 8 then race_key = 'Galka'
                        end
                    end
                end
                -- Job (PCs only). For self, read from get_player() directly.
                -- For party members, walk get_party() to find the matching id.
                -- For non-party PCs, we cannot access this info — leave blank.
                -- Title is only available for self (player struct).
                local main_job_str = ''
                local sub_job_str  = ''
                local title_str    = ''
                if kind == 'pc' then
                    if mob.id == me_id then
                        local p = windower.ffxi.get_player()
                        if p then
                            if p.main_job and p.main_job_level then
                                main_job_str = string.format('%s%d', p.main_job, p.main_job_level)
                            end
                            if p.sub_job and p.sub_job_level then
                                sub_job_str = string.format('%s%d', p.sub_job, p.sub_job_level)
                            end
                            if p.title and res.titles and res.titles[p.title] then
                                title_str = res.titles[p.title].en or ''
                            end
                        end
                    else
                        -- Other PC: try to find in party data. Party member
                        -- structures expose main_job/sub_job + level when in zone.
                        local party = windower.ffxi.get_party()
                        if party then
                            for _, member in pairs(party) do
                                if type(member) == 'table' and member.mob
                                   and member.mob.id == mob.id then
                                    local mj  = member.main_job or member.mjob
                                    local mjl = member.main_job_level or member.mlvl
                                    local sj  = member.sub_job  or member.sjob
                                    local sjl = member.sub_job_level or member.slvl
                                    if mj and mjl and mjl > 0 then
                                        main_job_str = string.format('%s%d', tostring(mj), mjl)
                                    end
                                    if sj and sjl and sjl > 0 then
                                        sub_job_str = string.format('%s%d', tostring(sj), sjl)
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
                -- Helper: encode an empty string as '~' so the wire
                -- never contains '||' inside a single segment (the
                -- main/sub delimiter is '||', so consecutive empty
                -- fields would collide). Python decodes '~' back to ''.
                local function ne(s)
                    return (s == '' or s == nil) and '~' or s
                end
                return
                    ne(tostring(name))    .. '|' ..
                    tostring(id)          .. '|' ..
                    tostring(hpp)         .. '|' ..
                    tostring(family)      .. '|' ..
                    tostring(zone_id)     .. '|' ..
                    string.format('%.2f', dist) .. '|' ..
                    tostring(tgt_idx)     .. '|' ..
                    tostring(claim)       .. '|' ..
                    tostring(is_pc)       .. '|' ..
                    ne(kind)              .. '|' ..
                    ne(race_str)          .. '|' ..
                    ne(main_job_str)      .. '|' ..
                    ne(sub_job_str)       .. '|' ..
                    ne(title_str)         .. '|' ..
                    ne(race_key)
            end

            local main_mob = windower.ffxi.get_mob_by_target('t')
            local sub_mob  = windower.ffxi.get_mob_by_target('st')
            -- Sub-target validity gate. The 'st' selector returns stale
            -- data whenever the player ISN'T actively in <st>/<stpc>/
            -- <stnpc> cursor mode — it just keeps returning whatever was
            -- last selected. We layer two checks to detect "cursor open
            -- right now":
            --   (a) target_arrow non-zero coords  — the in-game cursor
            --       position. {0,0,0} when no prompt up.
            --   (b) target_arrow CHANGES across frames. The game leaves
            --       stale non-zero coords after the cursor closes, so
            --       check (a) alone isn't enough. When the cursor IS
            --       active, the arrow updates continuously as the camera
            --       moves; if coords have been static for several
            --       polling ticks, the prompt was closed.
            local cursor_active = false
            if info and info.target_arrow then
                local ta = info.target_arrow
                if (ta.x and ta.x ~= 0) or (ta.y and ta.y ~= 0) or (ta.z and ta.z ~= 0) then
                    -- Arrow has non-zero coords. Check freshness.
                    local cx = tonumber(ta.x) or 0
                    local cy = tonumber(ta.y) or 0
                    local cz = tonumber(ta.z) or 0
                    local lx = _ow_last_arrow_x or 0
                    local ly = _ow_last_arrow_y or 0
                    local lz = _ow_last_arrow_z or 0
                    local stale_count = _ow_arrow_stale_count or 0
                    if cx == lx and cy == ly and cz == lz then
                        stale_count = stale_count + 1
                    else
                        stale_count = 0
                    end
                    _ow_last_arrow_x = cx
                    _ow_last_arrow_y = cy
                    _ow_last_arrow_z = cz
                    _ow_arrow_stale_count = stale_count
                    -- 30 polling ticks at the target poll rate (~5Hz) =
                    -- ~6 seconds without any arrow movement. A real
                    -- cursor session wiggles way more often than that
                    -- as you point at things.
                    if stale_count < 30 then
                        cursor_active = true
                    end
                else
                    -- Arrow truly zero — definitely no cursor. Reset the
                    -- staleness counter so the next non-zero burst is
                    -- treated as fresh.
                    _ow_arrow_stale_count = 0
                end
            end
            if not cursor_active then
                sub_mob = nil
            elseif sub_mob then
                -- Cursor active: still apply the same-id and self filters
                -- since 'st' can briefly mirror 't' or self when the cursor
                -- first opens.
                local me_id_now = (windower.ffxi.get_player() or {}).id or 0
                if main_mob and main_mob.id == sub_mob.id then
                    sub_mob = nil
                elseif sub_mob.id == me_id_now then
                    sub_mob = nil
                elseif sub_mob.valid_target == false then
                    sub_mob = nil
                end
            end
            local main_part = encode_mob(main_mob)
            local sub_part  = encode_mob(sub_mob)
            -- Always send, even if both are empty, so Python can fade.
            udp_target:send(main_part .. '||' .. sub_part)
        end)
        if not ok_tg then
            local last_err_time = _omniwatch_last_tg_err_time or 0
            if now - last_err_time > 10 then
                windower.add_to_chat(123, '[OmniWatch] target send error: ' .. tostring(err_tg))
                _omniwatch_last_tg_err_time = now
            end
        end
    end

    -- Zone / position data at 2 Hz. Doesn't change rapidly (except coords),
    -- and most of this is cheap to fetch. Python resolves the region name
    -- from the zone id using its bundled zones-to-regions table.
    if now - last_zone_send >= 0.5 then
        last_zone_send = now
        local ok_z, err_z = pcall(function()
            local info = windower.ffxi.get_info()
            local me   = windower.ffxi.get_mob_by_target('me')
            if not info then
                udp_zone:send('')
                return
            end

            -- Zone name from res/zones.
            local zone_id   = info.zone or 0
            local zone_name = ''
            local zone_res  = res.zones[zone_id]
            if zone_res then
                zone_name = zone_res.en or ''
            end

            -- Map index (mog house, or map page of current zone).
            local map_index = 0
            if info.mog_house then
                map_index = -1   -- sentinel for "Mog House"
            elseif info.map_index then
                map_index = info.map_index
            end

            -- Coords from the player mob.
            local x, y, z = 0.0, 0.0, 0.0
            if me then
                x = me.x or 0.0
                y = me.y or 0.0
                z = me.z or 0.0
            end

            -- Weather id (matches windower res.weathers).
            local weather_id = info.weather or 0

            -- FFXI map-grid position string ("(J-6)" style). Despite
            -- the wiki claiming get_position returns (map_id, x, y),
            -- it actually returns the formatted grid string directly
            -- as the first return value. Empty string if unavailable.
            local pos_str = ''
            if windower.ffxi.get_position then
                local ok_pos, raw = pcall(windower.ffxi.get_position)
                if ok_pos and type(raw) == 'string' then
                    pos_str = raw
                end
            end

            udp_zone:send(
                tostring(zone_id)        .. '|' ..
                tostring(zone_name)      .. '|' ..
                tostring(map_index)      .. '|' ..
                string.format('%.2f',  x)   .. '|' ..
                string.format('%.2f',  y)   .. '|' ..
                string.format('%.2f',  z)   .. '|' ..
                tostring(weather_id)     .. '|' ..
                tostring(pos_str)
            )
        end)
        if not ok_z then
            local last_err_time = _omniwatch_last_z_err_time or 0
            if now - last_err_time > 10 then
                windower.add_to_chat(123, '[OmniWatch] zone send error: ' .. tostring(err_z))
                _omniwatch_last_z_err_time = now
            end
        end
    end

    -- ── Recast timer poll (4 Hz) ────────────────────────────────────────────
    -- Polls spell and ability recasts every 250ms. For each non-zero recast,
    -- sends a record. Format:
    --   'RECAST_BATCH\t<sort_order>\n' + per-entry lines
    --   each entry: 'kind\tid\tname\tseconds_remaining\tcast_ts\n'
    -- where cast_ts is os.clock() at last cast (0 if never tracked, used
    -- only for sort_order='cast'). Filtering (blacklist, min_seconds, kind
    -- toggles) applied here so blacklisted entries never go over the wire.
    if not _ow_last_recast_send then _ow_last_recast_send = 0 end
    if now - _ow_last_recast_send >= 0.25 then
        _ow_last_recast_send = now
        pcall(function()
            local cfg = OW_RECAST_CONFIG or {}
            local blacklist  = cfg.blacklist or {}
            local min_secs   = tonumber(cfg.min_seconds) or 0
            local sort_order = cfg.sort_order or 'asc'
            local show_sp    = cfg.show_spells ~= false   -- default true
            local show_ab    = cfg.show_abilities ~= false
            local lines = {'RECAST_BATCH\t' .. tostring(sort_order)}

            -- Many spells/abilities share a single recast slot. Notable
            -- examples: all 31 Phantom Rolls share the Phantom Roll slot,
            -- BRD songs share song slot, Ninjutsu by tier. Iterating the
            -- resource table directly emits one entry per AbilityID even
            -- though they're all gated on the same countdown — we'd see
            -- 31 rolls when one Bolter's was active.
            --
            -- Bucket by recast_id and emit ONE entry per non-zero slot.
            -- Display name preference: most-recently-cast ability whose
            -- recast_id matches → falls back to the slot's natural name
            -- (which is the generic shared name, e.g. "Phantom Roll").

            if show_sp then
                local sp_recasts = windower.ffxi.get_spell_recasts() or {}
                -- Collect spells per recast slot.
                local sp_by_slot = {}
                for sp_id, sp in pairs(res.spells or {}) do
                    local rc_id = sp.recast_id
                    if rc_id and sp_recasts[rc_id] and sp_recasts[rc_id] > 0 then
                        if not sp_by_slot[rc_id] then sp_by_slot[rc_id] = {} end
                        sp_by_slot[rc_id][#sp_by_slot[rc_id] + 1] = {id = sp_id, sp = sp}
                    end
                end
                for rc_id, members in pairs(sp_by_slot) do
                    local frames = sp_recasts[rc_id]
                    local secs = frames / 60.0
                    if secs >= min_secs then
                        -- Prefer the spell we most recently cast on this
                        -- slot. _ow_recast_last_cast_at is keyed by
                        -- 'spell:<recast_id>' which is shared, so we need
                        -- a per-(recast_id,name) lookup. Track separately
                        -- when name varies — for now we just pick the
                        -- first member as fallback. The cast_complete
                        -- subscriber stores last_cast_name per slot in
                        -- _ow_recast_last_name['spell:<rc_id>'].
                        local nm = _ow_recast_last_name and _ow_recast_last_name['spell:'..rc_id]
                        if not nm then
                            -- Fallback: use the first member's name.
                            local m = members[1]
                            nm = m.sp.en or m.sp.name or ('Spell #'..m.id)
                        end
                        if not blacklist[nm] then
                            local ts = _ow_recast_last_cast_at['spell:'..rc_id] or 0
                            -- Use the recast_id as the wire id (so python
                            -- treats it as one entry across the whole slot).
                            lines[#lines + 1] = string.format(
                                'spell\t%d\t%s\t%.1f\t%.2f',
                                rc_id, nm, secs, ts)
                        end
                    end
                end
            end

            if show_ab then
                local ab_recasts = windower.ffxi.get_ability_recasts() or {}
                local ab_by_slot = {}
                for ab_id, ab in pairs(res.job_abilities or {}) do
                    local rc_id = ab.recast_id
                    if rc_id and ab_recasts[rc_id] and ab_recasts[rc_id] > 0 then
                        if not ab_by_slot[rc_id] then ab_by_slot[rc_id] = {} end
                        ab_by_slot[rc_id][#ab_by_slot[rc_id] + 1] = {id = ab_id, ab = ab}
                    end
                end
                for rc_id, members in pairs(ab_by_slot) do
                    local secs = ab_recasts[rc_id]
                    if secs >= min_secs then
                        local nm = _ow_recast_last_name and _ow_recast_last_name['ability:'..rc_id]
                        if not nm then
                            local m = members[1]
                            nm = m.ab.en or m.ab.name or ('Ability #'..m.id)
                        end
                        if not blacklist[nm] then
                            local ts = _ow_recast_last_cast_at['ability:'..rc_id] or 0
                            lines[#lines + 1] = string.format(
                                'ability\t%d\t%s\t%.1f\t%.2f',
                                rc_id, nm, secs, ts)
                        end
                    end
                end
            end
            udp_timers:send(table.concat(lines, '\n'))
        end)

        -- Send buff timers in a separate packet (same socket).
        --
        -- Source-of-truth pipeline (most-precise to least):
        --   1) _ow_buff_slots / _ow_buff_slot_expires_at -- populated by
        --      our 0x063 sub-0x09 chunk handler. Per-slot, real expiry
        --      timestamps. Lets us distinguish March #1 from March #2.
        --   2) _ow_buff_pending_meta -- populated by buff_gain events.
        --      Refines source classification ('song' vs 'song_other'),
        --      applies gear-aware durations (Telchine, Composure, song
        --      duration multipliers etc.). Used to override the slot
        --      poller's source/name when a recent cast matches.
        --   3) Fallback estimates -- only when the slot poller hasn't
        --      yet seen a slot (login race, before first 0x063), we
        --      use source-keyed default durations and mark estimated.
        pcall(function()
            local cfg = OW_BUFF_CONFIG or {}
            local sort_order = cfg.sort_order or 'asc'
            local min_secs   = tonumber(cfg.min_seconds) or 0
            local blacklist  = cfg.blacklist or {}
            local me = windower.ffxi.get_player()
            local my_id = (me and me.id) or 0
            local now_clock = os.clock()

            -- Reconcile _ow_buff_timers with _ow_buff_slots. We rebuild
            -- _ow_buff_timers from _ow_buff_slots each tick: for every
            -- occupied slot we ensure an entry exists; for empty slots
            -- we drop any entry. This makes the slot poller authoritative
            -- and prevents stale entries from lingering after wear-off.
            --
            -- Fallback: if _ow_buff_slots is empty (the 0x063 packet
            -- hasn't been seen yet — login race, parser hiccup, or the
            -- offsets are wrong on a future client patch), synthesise a
            -- slot map from me.buffs so the user still sees their active
            -- buffs (with estimated durations only). Once a real 0x063
            -- arrives, _ow_buff_slots becomes authoritative.
            local effective_slots = _ow_buff_slots
            if next(effective_slots) == nil then
                effective_slots = {}
                local active = (me and me.buffs) or {}
                for idx, bid in ipairs(active) do
                    if bid and bid > 0 then
                        -- Use 100+idx as a synthetic slot index so it
                        -- can't collide with real 0x063 slots (0..31).
                        -- The synthetic flag also means pkt_expires lookup
                        -- below returns nil, triggering the estimate path.
                        effective_slots[100 + idx] = bid
                    end
                end
            end
            local slot_seen = {}
            -- Build prev-packet (buff_id, expires_at) → slot map for
            -- migration detection. When a buff wears off in an earlier
            -- slot, FFXI compacts the slot list — buffs in higher slots
            -- shift down to fill gaps. Without migration tracking we'd
            -- treat the shifted buff as "new in this slot", resetting
            -- started_at and making its fullness bar jump back to 100%.
            --
            -- We match on (buff_id, expires_at) rather than buff_id
            -- alone so we don't accidentally migrate one Refresh's
            -- timer to another Refresh in a different slot (rare but
            -- possible — e.g. two casters refreshing the same target).
            -- Expires_at is a stable identity per buff instance.
            -- Tolerance of 1s handles minor server-side jitter.
            local prev_buff_instances = {}
            for prev_slot, prev_entry in pairs(_ow_buff_timers) do
                if prev_entry and prev_entry.buff_id and prev_entry.expires_at then
                    prev_buff_instances[#prev_buff_instances + 1] = {
                        slot       = prev_slot,
                        buff_id    = prev_entry.buff_id,
                        expires_at = prev_entry.expires_at,
                        started_at = prev_entry.started_at,
                        duration   = prev_entry.duration,
                    }
                end
            end
            for slot, bid in pairs(effective_slots) do
                slot_seen[slot] = true
                local existing = _ow_buff_timers[slot]
                local need_update = (not existing) or (existing.buff_id ~= bid)

                -- Expiry from the 0x063 packet (precise) if available.
                local pkt_expires = (_ow_buff_slot_expires_at or {})[slot]

                -- Source-classification + gear-aware refinement.
                -- Default: classify as self (slot poller doesn't carry
                -- caster info). buff_gain events that fire concurrently
                -- store their gear-aware result in _ow_buff_pending_meta;
                -- prefer that when the buff_id matches.
                local source = _ow_classify_buff_source(bid, my_id)
                local nm     = _ow_buff_name(bid)

                -- Slot-label policy. Once a slot is labeled (the slot
                -- poller has bound it to a name from pending_meta),
                -- the label sticks for the life of the slot. The slot
                -- only loses its label when:
                --   * the slot's bid changes (different buff entirely)
                --   * the slot's gi_time changes with same bid (the
                --     song was replaced in-place at slot cap; handled
                --     by the gi_time-tracker in the 0x063 reader, which
                --     clears _ow_buff_timers[slot] so this reconcile
                --     pass treats it as a fresh slot)
                --   * the slot empties (no longer present in 0x063)
                --
                -- FFXI buff-song stacking rules (per BG-wiki + observed):
                --   * Each unique buff song name occupies its own slot.
                --   * Different TIERS of the same song (Knight's Minne
                --     IV vs V, Valor Minuet IV vs V) are SEPARATE
                --     buffs that can stack as two slots — both buff the
                --     target with their own timer.
                --   * Different families sharing a buff_id (Honor March
                --     + Victory March, both bid=214) also stack.
                --   * Slot cap = 2 with no extra-song instrument, +1
                --     each from Daurdabla / Blurred Harp +1, Terpander /
                --     Loughnashade / Gjallarhorn / Marsyas + extra-song
                --     instrument, Clarion Call, Marcato.
                --   * When a new song is cast over the cap, the slot
                --     with the lowest remaining duration is overwritten.
                --
                -- The dict-keyed pending_meta works for the two-tier
                -- case because: when tier 2 is cast, tier 1 is already
                -- bound to its slot (existing_name set, label preserved
                -- by the branch below). The new tier 2 entry overwrites
                -- pending_meta[bid] with tier 2's name, then the unbound
                -- new slot picks it up via the elseif branch. Tier 1's
                -- slot is unaffected by the overwrite because it doesn't
                -- look at pending_meta when its label is already set.
                --
                -- KNOWN LIMITATION (multi-Bard): if Bard B (different
                -- caster) sings on us, we don't observe their cat=4 so
                -- we have no pending_meta for their cast. Their slot
                -- gets the spell-base estimate (bid → name via
                -- res.spells) or one of our own stale pending_meta
                -- entries (wrong name + duration). Proper fix: key
                -- pending_meta by (bid, actor_id) AND register cat=4
                -- from any actor whose target is us. TODO.
                local meta = nil
                local existing_name = existing and existing.buff_id == bid
                                       and existing.name or nil
                local pending = (_ow_buff_pending_meta or {})[bid]
                local pending_fresh = pending
                                      and (now_clock - (pending.ts or 0)) < 30
                                      or false
                if existing_name and existing_name ~= '' then
                    -- Slot already has a label. Keep it. Pending_meta
                    -- might have a newer entry for this bid (e.g.
                    -- second-tier cast), but that's destined for some
                    -- OTHER slot — we leave the new slot to pick it up.
                    --
                    -- This handles three cases at once:
                    --   (1) Stable existing slot, no new cast: kept ✓
                    --   (2) Tier 2 cast while tier 1 still active in
                    --       this slot: tier 1's slot keeps its label;
                    --       tier 2's new slot finds pending_meta and
                    --       binds to it ✓
                    --   (3) Re-cast of same song to refresh: gi_time
                    --       changes, the slot-population code clears
                    --       _ow_buff_timers[slot], so this branch isn't
                    --       hit — falls through to "take pending" below ✓
                    nm = existing_name
                    if existing.source then source = existing.source end
                elseif pending_fresh then
                    -- New slot (no existing label), fresh meta available.
                    meta = pending
                    nm = meta.name or nm
                    source = meta.source or source
                    -- DON'T consume on first read. The synthetic me.buffs
                    -- fallback can read meta on tick T, but the real
                    -- 0x063 may not arrive for ~3s. If we consumed, the
                    -- real-slot reconcile would find no meta and fall
                    -- to the estimate path. The 30s TTL prevents stale
                    -- meta poisoning a much later cast.
                end

                -- Source-gating from cfg. Same set as before.
                local gated = false
                if source == 'food'  and not cfg.show_food          then gated = true end
                if source == 'song'  and not cfg.show_songs         then gated = true end
                if source == 'roll'  and not cfg.show_rolls         then gated = true end
                if source == 'self'  and not cfg.show_self_spells   then gated = true end
                if (source == 'other' or source == 'song_other'
                    or source == 'roll_other')
                   and not cfg.show_buffs_from_others then gated = true end

                if gated then
                    _ow_buff_timers[slot] = nil
                else
                    -- Apply blacklist (uses unprefixed name).
                    local nm_for_blacklist = nm
                    if nm_for_blacklist:sub(1,1) == '~' then
                        nm_for_blacklist = nm_for_blacklist:sub(2)
                    end
                    if cfg.blacklist and cfg.blacklist[nm_for_blacklist] then
                        _ow_buff_timers[slot] = nil
                    elseif need_update or pkt_expires then
                        -- Compute duration. Three tiers of accuracy:
                        --   1) pkt_expires (precise from 0x063 sub-9):
                        --      server-pushed expiry timestamp, the
                        --      authoritative source. Includes any procs
                        --      and other modifiers we'd miss with
                        --      client-side math. Updated whenever the
                        --      server pushes a fresh sub-9 packet (on
                        --      buff gain, loss, zone change, login).
                        --   2) meta.duration (gear-aware, computed at
                        --      cast time from spell base × multiplier).
                        --      Used as a fallback in the small window
                        --      between cast and the server pushing
                        --      sub-9. Also covers cases where the
                        --      server hasn't pushed for some reason.
                        --   3) source-keyed estimate (last-resort default
                        --      when no cast info: 2m for songs, 5m rolls,
                        --      30m food, 3m other).
                        local opts = {}
                        local duration_sec
                        if pkt_expires then
                            opts.expires_at = pkt_expires
                            opts.precise    = true
                            duration_sec    = math.max(0.1,
                                                       pkt_expires - now_clock)
                            -- Migration check: if THIS slot is new (need_update),
                            -- but the same (buff_id, expires_at) was in a different
                            -- slot in the previous packet, we're seeing a slot
                            -- compaction. Carry over the original started_at and
                            -- duration so the fullness bar stays proportional.
                            -- Without this the bar visibly jumps to 100% every
                            -- time another buff wears off.
                            if need_update then
                                for _, prev in ipairs(prev_buff_instances) do
                                    if prev.buff_id == bid
                                       and prev.slot ~= slot
                                       and math.abs(prev.expires_at - pkt_expires) < 1.0
                                    then
                                        opts.started_at = prev.started_at
                                        -- Keep the original full-bar duration too;
                                        -- otherwise the bar would still be proportional
                                        -- to (now - started_at) / duration, where
                                        -- duration was just recomputed as
                                        -- (expires_at - now), shrinking it.
                                        if prev.duration and prev.duration > 0 then
                                            duration_sec = prev.duration
                                        end
                                        break
                                    end
                                end
                            end
                        elseif meta and meta.duration and meta.duration > 0
                               and meta.ts then
                            -- Anchor expiry to the cast-time moment, not
                            -- to "now". E.g. song was cast 2s ago with a
                            -- 198s duration → expires at meta.ts + 198,
                            -- which is now_clock + 196.
                            opts.expires_at = meta.ts + meta.duration
                            opts.precise    = true
                            duration_sec    = math.max(0.1,
                                                       opts.expires_at - now_clock)
                        else
                            opts.estimated  = true
                            if source == 'food' then
                                duration_sec = 30 * 60
                            elseif source == 'song' or source == 'song_other' then
                                duration_sec = 2 * 60
                            elseif source == 'roll' or source == 'roll_other' then
                                duration_sec = 5 * 60
                            else
                                duration_sec = 3 * 60
                            end
                            -- For estimated entries we also reuse meta's
                            -- gear-aware duration if available (when ts
                            -- is missing for some reason).
                            if meta and meta.duration and meta.duration > 0 then
                                duration_sec = meta.duration
                            end
                        end
                        _ow_track_buff(slot, bid, nm, duration_sec, source, opts)
                    end
                end
            end

            -- Drop _ow_buff_timers entries for slots no longer occupied.
            for slot, _ in pairs(_ow_buff_timers) do
                if not slot_seen[slot] then
                    _ow_buff_timers[slot] = nil
                end
            end

            -- Special case: food buff (id 251) gets its name from the
            -- food item id we recorded at /eat-time. The slot poller's
            -- _ow_buff_name(251) returns 'Food' generically, but we want
            -- 'Sublime Sushi +1' or similar. Patch the entry post-track.
            for slot, t in pairs(_ow_buff_timers) do
                if t.buff_id == 251 and cfg.show_food then
                    if _ow_food_item_id and _ow_food_item_id > 0
                       and res.items and res.items[_ow_food_item_id] then
                        local it = res.items[_ow_food_item_id]
                        local food_name = it.en or it.name
                        if food_name then t.name = food_name end
                    end
                end
            end

            -- Cull stale _ow_buff_pending_meta entries (>30s old). They
            -- had their chance to influence the slot poller; keeping
            -- them around invites stale-source bugs.
            if _ow_buff_pending_meta then
                for bid, m in pairs(_ow_buff_pending_meta) do
                    if type(m) == 'table' and (now_clock - (m.ts or 0)) > 30 then
                        _ow_buff_pending_meta[bid] = nil
                    end
                end
            end

            -- Build wire lines. Precise entries get pruned at expiry
            -- (the slot is empty in the next 0x063 anyway). Estimated
            -- entries (rare) stay until buff_loss explicitly clears them.
            local lines = {'BUFF_BATCH\t' .. tostring(sort_order)}
            for slot, t in pairs(_ow_buff_timers) do
                local rem = t.expires_at - now_clock
                if rem <= 0 and not t.estimated and not t.precise then
                    _ow_buff_timers[slot] = nil
                else
                    local rem_display = rem > 0 and rem or 0
                    if rem_display >= min_secs or t.estimated then
                        -- Wire format (slot-aware, version 3):
                        --   buff\tslot\tbuff_id\tname\tseconds_remaining\tsource\texpires_at_unix\tstarted_at_unix
                        -- Python reads len(fields) to detect format:
                        --   6 = legacy v2, no expires_at
                        --   7+ = v3, has expires_at and started_at as
                        --        absolute Unix timestamps for persistence.
                        -- The absolute timestamps let Python reconstruct
                        -- the full duration (expires - started) after a
                        -- Python reload, so the fullness bar starts at
                        -- the correct ratio rather than always 100%.
                        -- We convert os.clock() values back to wall-time
                        -- via the offset (now_unix - now_clock). This is
                        -- a one-frame approximation; perfectly accurate
                        -- for our purposes (sub-second drift is fine for
                        -- buff timer display).
                        local clock_to_unix = os.time() - now_clock
                        local expires_unix  = t.expires_at + clock_to_unix
                        local started_unix  = (t.started_at or now_clock)
                                              + clock_to_unix
                        lines[#lines + 1] = string.format(
                            'buff\t%d\t%d\t%s\t%.1f\t%s\t%d\t%d',
                            slot, t.buff_id, t.name, rem_display,
                            t.source or 'self',
                            math.floor(expires_unix),
                            math.floor(started_unix))
                    end
                end
            end
            udp_timers:send(table.concat(lines, '\n'))
        end)
    end

    -- DPS panel emit at 2 Hz (every 5th 10 Hz tick).
    _ow_dps_emit_acc = (_ow_dps_emit_acc or 0) + 1
    if _ow_dps_emit_acc >= 5 then
        _ow_dps_emit_acc = 0
        pcall(_ow_dps_emit)
    end
end)

--python -m PyInstaller --onefile omniwatch.py