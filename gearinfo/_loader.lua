-- ═══════════════════════════════════════════════════════════════════════════
-- gearinfo/_loader.lua
-- ═══════════════════════════════════════════════════════════════════════════
-- Vendored copy of sebyg666/GearInfo, integrated into OmniWatch as a
-- library. This loader:
--   (1) initializes the global state expected by GearInfo (Statics.lua)
--   (2) loads the data tables under gearinfo/res/
--   (3) loads the function modules (Gear_Processing, Calculator, Buff_Processing)
--   (4) loads Packet_parsing and Action_Processing but does NOT register
--       windower events from them — the parse.i[] table and on_action()
--       function are exposed for OmniWatch's existing event handlers to call.
--
-- The original GearInfo addon must be UNLOADED while OmniWatch runs, since
-- both define the same globals (player, Gear_info, Buffs_inform, etc.) and
-- registering both addons' packet handlers would double-fire. From the
-- console: //unload GearInfo
--
-- We use loadfile with absolute paths everywhere (no `require 'gearinfo/X'`)
-- to avoid Windows package.path quirks and case-sensitivity surprises.
-- ═══════════════════════════════════════════════════════════════════════════

local _gi = {}

-- Resolve the gearinfo/ folder absolute path. windower.addon_path points to
-- the OmniWatch addon root (with trailing slash usually, but we normalize).
local _base = windower.addon_path or ''
if _base ~= '' and _base:sub(-1) ~= '/' and _base:sub(-1) ~= '\\' then
    _base = _base .. '/'
end
local _gi_dir = _base .. 'gearinfo/'

-- Helper: load a file by relative path under gearinfo/ via loadfile and run
-- it. For data files (returns a table), captures the table. For module
-- files (no return; sets globals), the chunk just executes.
-- Throws an error with a contextual message if loading fails — caller's
-- pcall catches it.
local function load_chunk(rel_path, expect_table)
    local full = _gi_dir .. rel_path
    local chunk, err = loadfile(full)
    if not chunk then
        error(string.format('loadfile failed for %s: %s', rel_path, tostring(err)))
    end
    local result = chunk()
    if expect_table and type(result) ~= 'table' then
        error(string.format('%s did not return a table (got %s)',
                            rel_path, type(result)))
    end
    return result
end

-- Same as load_chunk but for non-critical data tables — returns an empty
-- table instead of throwing if the file fails or doesn't return a table.
-- Used for Bard_Songs / Cor_Rolls / Geo_Spells / etc. where a nil result
-- shouldn't kill the whole loader.
local function load_table_safe(rel_path)
    local full = _gi_dir .. rel_path
    local chunk, load_err = loadfile(full)
    if not chunk then
        windower.add_to_chat(123, string.format(
            '[OW/GI] %s could not be loaded (%s); using empty fallback.',
            rel_path, tostring(load_err)))
        return {}
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= 'table' then
        windower.add_to_chat(123, string.format(
            '[OW/GI] %s did not return a table; using empty fallback.',
            rel_path))
        return {}
    end
    return result
end

-- Standard Windower libraries needed by GearInfo's modules. These use
-- require because they live in addons/libs/, which IS on package.path
-- by Windower's default setup.
require('tables')
require('lists')
require('strings')
require('logger')
require('pack')

res     = res     or require('resources')
Extdata = Extdata or require('extdata')
config  = config  or require('config')
files   = files   or require('files')
packets = packets or require('packets')
chat    = chat    or require('chat')

-- ── Phase 1: Statics ────────────────────────────────────────────────────────
-- Sets player.equipment, player.stats, Buffs_inform, Gear_info,
-- member_table, settings defaults, etc. as GLOBALS.
load_chunk('Statics.lua', false)

-- Populate the `settings` global. GearInfo.lua's options_load() does this
-- via the `config` library reading from a player-specific XML file. We
-- short-circuit that: copy `defaults` (set by Statics) into `settings` so
-- Unity gear computation, song-bonus math, etc. all have a reachable
-- value. The Unity rank is the most-referenced field — we default to 1
-- (lowest), which gives accurate values for non-Unity-ranked players.
settings = settings or {}
if defaults then
    for k, v in pairs(defaults) do
        if settings[k] == nil then settings[k] = v end
    end
end
-- Belt-and-suspenders: even if defaults is missing, ensure settings.player.rank
-- exists so Unity_rank lookup at Gear_Processing.lua:57 doesn't blow up.
settings.player = settings.player or {}
if settings.player.rank == nil then settings.player.rank = 1 end

-- Statics zeroes player.stats; if we're already logged in, re-prime from
-- windower so the first compute has real values.
do
    local p = windower.ffxi.get_player()
    if p and p.stats then
        player.stats = {
            STR = p.stats.str or 0, DEX = p.stats.dex or 0,
            VIT = p.stats.vit or 0, AGI = p.stats.agi or 0,
            INT = p.stats['int'] or 0, MND = p.stats.mnd or 0,
            CHR = p.stats.chr or 0,
        }
    end
end

-- ── Phase 2: Data tables (res/*.lua) ───────────────────────────────────────
-- These are pure `return {...}` files. Filename casing matches the
-- repository (sebyg666/GearInfo) exactly. If a file is named
-- differently on disk, this load will throw.
--
-- CRITICAL tables (loader fails if they're missing, since the stat
-- formulas read from them):
--   - DW_Gear, Unity_rank, Martial_Arts_Gear: referenced by find_all_values
--     during item parsing
--   - Set_bonus_by_Set_ID, Set_bonus_by_item_id: referenced by get_equip_stats
--   - Gifts: referenced by Calculator's TP helpers and acc/att/eva/def job-trait
--     computations
--
-- NON-CRITICAL tables (use safe loader, fall back to empty {} on failure):
--   - Blu_spells: only used when player.main_job == 'BLU'
--   - Cor_Rolls: only used when COR rolls are active
--   - Bard_Songs: only used when bard songs are active
--   - Geo_Spells: only used when geo spells are active
DW_Gear              = load_chunk('res/DW_Gear.lua',              true)
Unity_rank           = load_chunk('res/Unity_Gear.lua',            true)
Martial_Arts_Gear    = load_chunk('res/Martial_Arts_Gear.lua',    true)
Set_bonus_by_Set_ID  = load_chunk('res/Set_bonus_by_Set_ID.lua',  true)
Set_bonus_by_item_id = load_chunk('res/Set_bonus_by_item_id.lua', true)
Gifts                = load_chunk('res/Gifts.lua',                true)
Blu_spells           = load_table_safe('res/Blue_Mage_Spells.lua')
Cor_Rolls            = load_table_safe('res/Cor_Rolls.lua')
Bard_Songs           = load_table_safe('res/Bard_Songs.lua')
Geo_Spells           = load_table_safe('res/Geo_Spells.lua')

-- ── Phase 3: Function modules ──────────────────────────────────────────────
load_chunk('Gear_Processing.lua', false)
load_chunk('Calculator.lua',      false)
load_chunk('Buff_Processing.lua', false)

-- Packet_parsing defines `parse` table (parse.i[id] = function). It does NOT
-- register events itself, so loading it just makes the table available for
-- our incoming_chunk handler to call.
load_chunk('Packet_parsing.lua', false)

-- Action_Processing IS a problem: at file-load time it registers a windower
-- 'action' event. OmniWatch already has its own action handler, and we
-- don't want a second one fighting it. Workaround: shadow
-- windower.register_event briefly so GearInfo's call is captured rather
-- than registered, save the function for our handler to invoke, restore
-- the original.
local _captured_action_handler = nil
do
    local _orig_register = windower.register_event
    windower.register_event = function(evt, fn)
        if evt == 'action' and not _captured_action_handler then
            _captured_action_handler = fn
            return -1  -- pretend we registered; return a fake id
        end
        return _orig_register(evt, fn)
    end
    load_chunk('Action_Processing.lua', false)
    windower.register_event = _orig_register
end
_gi.captured_action_handler = _captured_action_handler

-- ── Phase 3.5: Item-cache + equipped-decoder helpers ───────────────────────
-- These five functions live in GearInfo's main entry-point file (GearInfo.lua)
-- rather than in any of its sub-modules. We don't load GearInfo.lua itself
-- (it registers windower events, draws UI, manages settings — none of which
-- belong in OmniWatch). Instead we vendor the five functions verbatim here.
--
-- They build/maintain `full_gear_table_from_file` — a lookup cache mapping
-- item id (and augment fingerprint) to the parsed-stat table from
-- find_all_values(). check_equipped() reads this cache when scanning equipped
-- gear, falling back to parse_new_single_item() if an unfamiliar item is seen.
--
-- Persistence: save_table_to_file writes to data/<player>_gearinfo_cache.lua
-- (we use a distinct filename so we don't collide with vanilla GearInfo's
-- _data.lua if the user has both addons installed historically).

function save_table_to_file(item_table)
    local new_item = item_table
    -- Use a distinct cache filename so we don't trample over GearInfo's
    -- own cache file or any other addon's data file in this folder.
    local f = io.open(windower.addon_path..'data/'..player.name..'_gearinfo_cache.lua','w')
    if not f then return end
    f:write('return ' .. T(new_item):tovstring())
    f:close()
end

function get_equipment_from_file()
    local f = io.open(windower.addon_path..'data/'..player.name..'_gearinfo_cache.lua','r')
    if not f then return T{} end
    local t = f:read("*all")
    t = assert(loadstring(t))()
    f:close()
    return t
end

function parse_inventory()
    local items_in_bag = T{}
    local full_gear_table_rw = T{}
    for k,v in pairs(res.bags) do
        for i,n in pairs(windower.ffxi.get_items(v.id)) do
            items_in_bag[#items_in_bag +1] = n
        end
    end
    for k,v in pairs(items_in_bag) do
        if v ~= nil and type(v) == 'table' then
            if v.id ~= 0 then
                local this_item = find_all_values(v)
                if this_item ~= nil then
                    full_gear_table_rw[#full_gear_table_rw +1] = this_item
                end
            end
        end
    end
    full_gear_table_from_file = full_gear_table_rw
    save_table_to_file(full_gear_table_from_file)
end

function parse_new_single_item(item)
    if item ~= nil and type(item) == 'table' then
        if item.id ~= 0 then
            local this_item = find_all_values(item)
            if this_item ~= nil then
                full_gear_table_from_file[#full_gear_table_from_file +1] = this_item
            end
            save_table_to_file(full_gear_table_from_file)
            return this_item
        end
    end
end

function check_equipped()
    local new_gear_table = T{}
    local local_gear_table = T{}
    local items_equipped = windower.ffxi.get_items().equipment

    local default_slot = T{'sub','range','ammo','head','body','hands','legs','feet','neck','waist', 'left_ear', 'right_ear', 'left_ring', 'right_ring','back'}
    default_slot[0]= 'main'

    if items_equipped then
        for id,name in pairs(default_slot) do
            items_equipped[name] = {
                slot = items_equipped[name],
                bag = items_equipped[name..'_bag']
            }
            items_equipped[name..'_bag'] = nil
        end
    end

    for k,v in pairs(items_equipped) do
        if v.slot == 0 then
            new_gear_table[k] = {count = 0 ,status = 0,id = 0,slot = 0,bazaar = 0,extdata = ''}
        else
            new_gear_table[k] = windower.ffxi.get_items(v.bag, v.slot)
        end
    end

    local sloted_items = new_gear_table
    for k,v in pairs(new_gear_table) do
        if v.count > 0 then
            local item_has_augment = Extdata.decode(v)
            local no_match = true
            local temp_item = new_gear_table[k]

            for x,y in pairs(full_gear_table_from_file) do
                if v.id == y.id then
                    if type(item_has_augment.augments) == 'table' and table.length(item_has_augment.augments) > 0 then
                        for i, j in pairs(y) do
                            local int = 0
                            if i == 'augments' then
                                for a,b in pairs(item_has_augment.augments) do
                                    if j[a]:contains(b) then
                                        int = int +1
                                    end
                                end
                                if int == table.length(item_has_augment.augments) then
                                    y.augments = item_has_augment.augments
                                    local_gear_table[#local_gear_table +1] = y
                                    sloted_items[k] = local_gear_table[#local_gear_table]
                                    no_match = false
                                    break
                                end
                            end
                        end
                    else
                        no_match = false
                        local_gear_table[#local_gear_table+1] = y
                        sloted_items[k] = local_gear_table[#local_gear_table]
                    end
                end
            end

            if no_match == true then
                local_gear_table[#local_gear_table+1] = parse_new_single_item(temp_item)
                sloted_items[k] = local_gear_table[#local_gear_table]
                no_match = false
            end
        else
            local_gear_table[#local_gear_table+1] = {id = 0, en = '', category = '', delay = 0, haste = 0, dual_wield = 0, stp = 0, augments = '' }
            sloted_items[k] = local_gear_table[#local_gear_table]
        end
    end

    player.equipment = sloted_items

    return sloted_items
end

-- ── Phase 4: Inventory prime ───────────────────────────────────────────────
-- parse_inventory() walks all bags and runs find_all_values() on each item,
-- populating full_gear_table_from_file (the cache that check_equipped
-- reads). Without this prime, check_equipped would re-parse every item in
-- the equipment slots on first run.
-- We also try to load any prior cache file from disk so cold-start is fast.
local function prime_inventory()
    if not windower.ffxi.get_info().logged_in then return end

    -- Make sure the data/ folder exists (save_table_to_file uses io.open
    -- which won't create missing folders). The 'files' lib has helpers
    -- but fall back to a no-op if anything goes sideways.
    pcall(function()
        local d = windower.addon_path .. 'data'
        if files and files.dir_exists and not files.dir_exists(d) then
            -- Most install layouts already have addon_path/data; if not,
            -- we just skip cache persistence and live with reparsing on
            -- next reload. parse_inventory still populates the in-memory
            -- table, so the live session is fine.
        end
    end)

    -- Try to load prior cache for warm start. Failure is fine — we'll
    -- repopulate from scratch via parse_inventory.
    local p = windower.ffxi.get_player()
    if p and p.name then
        local ok_load, t = pcall(get_equipment_from_file)
        if ok_load and type(t) == 'table' and next(t) ~= nil then
            full_gear_table_from_file = t
        end
    end

    local ok, err = pcall(parse_inventory)
    if not ok then
        log('[OW/GI] parse_inventory failed: ' .. tostring(err))
    end
end
_gi.prime_inventory = prime_inventory

-- ── Phase 5: Convenience helpers OmniWatch uses ────────────────────────────
-- refresh_all: matches the data-flow at the top of GearInfo's update().
-- Reads windower's player table, decodes equipped items, parses gear stats,
-- runs the buff/haste pipeline. Should be called before compute_player_stats.
function _gi.refresh_all(equip_overrides, player_stats_override, sim_overrides)
    if not windower.ffxi.get_info().logged_in then
        return false, 'not logged in'
    end
    local p_native = windower.ffxi.get_player()
    if not p_native then
        return false, 'get_player() returned nil'
    end

    -- Sync GearInfo's `player` global with windower's current snapshot.
    -- IMPORTANT: windower.ffxi.get_player().stats is sometimes nil even
    -- when logged_in == true (the engine populates it asynchronously
    -- after the 0x061 packet fires). The 0x061 packet is reliably cached
    -- by Windower, so as a fallback we read base stats directly from
    -- last_incoming(0x061) at offsets 0x15-0x21 (matching GearInfo's
    -- Packet_parsing.lua).
    --
    -- GearInfo's formulas (get_player_acc/att) read player.stats keyed
    -- UPPERCASE (STR/DEX/VIT/AGI/INT/MND/CHR), so we always assign in
    -- that shape regardless of source.
    player = p_native
    local stats_set = false
    if p_native.stats and (p_native.stats.STR or p_native.stats.str) then
        if p_native.stats.STR then
            -- Already uppercase (GearInfo's parse.i[0x061] ran)
            player.stats = p_native.stats
            stats_set = true
        elseif p_native.stats.str then
            -- Lowercase — need to mirror to uppercase shape
            player.stats = {
                STR = p_native.stats.str or 0,
                DEX = p_native.stats.dex or 0,
                VIT = p_native.stats.vit or 0,
                AGI = p_native.stats.agi or 0,
                INT = p_native.stats['int'] or 0,
                MND = p_native.stats.mnd or 0,
                CHR = p_native.stats.chr or 0,
            }
            stats_set = true
        end
    end
    -- Fallback: parse base stats from last_incoming(0x061) directly.
    -- Note: this gives BASE stats (no gear/buff). The GearInfo formula
    -- adds gear-stat sums on top via stat_table['STR'], so this is OK.
    if not stats_set then
        local cached = windower.packets and windower.packets.last_incoming
                       and windower.packets.last_incoming(0x061)
        if cached and #cached >= 0x22 then
            local function u16(s, off)
                local b1 = s:byte(off)     or 0
                local b2 = s:byte(off + 1) or 0
                return b1 + b2 * 256
            end
            player.stats = {
                STR = u16(cached, 0x15),
                DEX = u16(cached, 0x17),
                VIT = u16(cached, 0x19),
                AGI = u16(cached, 0x1B),
                INT = u16(cached, 0x1D),
                MND = u16(cached, 0x1F),
                CHR = u16(cached, 0x21),
            }
            stats_set = true
        end
    end
    if not stats_set then
        return false, 'no stats source (get_player().stats nil and 0x061 not cached)'
    end

    -- Sim mode: when caller passes player_stats_override, replace
    -- player.stats with those values. The override is keyed lowercase
    -- (str/dex/vit/agi/int/mnd/chr) since that's what OmniWatch's sim
    -- baseline produces; we mirror to UPPERCASE shape for GearInfo's
    -- formulas. Used by sim's "naked baseline" so get_player_acc adds
    -- the SYNTHETIC base stats (or zeros if no base data) instead of
    -- the live game's gear-inflated values.
    if player_stats_override then
        player.stats = {
            STR = tonumber(player_stats_override.str) or 0,
            DEX = tonumber(player_stats_override.dex) or 0,
            VIT = tonumber(player_stats_override.vit) or 0,
            AGI = tonumber(player_stats_override.agi) or 0,
            INT = tonumber(player_stats_override['int']) or 0,
            MND = tonumber(player_stats_override.mnd) or 0,
            CHR = tonumber(player_stats_override.chr) or 0,
        }
    end

    -- Sim mode: override player.main_job, player.sub_job, player.merits,
    -- and player.job_points so GearInfo's Calculator.lua walks the sim'd
    -- values rather than live ones. This isolates the GearInfo backend
    -- to the sim's chosen scenario instead of leaking real-job traits/
    -- merits/JP into the computed acc/att/eva/def.
    --
    -- sim_overrides shape (caller passes only the keys it has):
    --   {main_job='NIN', sub_job='WAR', main_job_level=99, sub_job_level=49,
    --    merits={ikishoten=5, store_tp_effect=5, ...},
    --    job_points={nin={jp_spent=2100}, ...}}
    if sim_overrides then
        if sim_overrides.main_job and sim_overrides.main_job ~= '' then
            player.main_job = sim_overrides.main_job
            player.main_job_level = tonumber(sim_overrides.main_job_level) or 99
        end
        if sim_overrides.sub_job and sim_overrides.sub_job ~= '' then
            player.sub_job = sim_overrides.sub_job
            player.sub_job_level = tonumber(sim_overrides.sub_job_level) or 49
        end
        -- Merits/job_points are tables; replace wholesale so GearInfo
        -- helpers reading e.g. player.merits.ikishoten see sim values.
        if sim_overrides.merits then
            player.merits = sim_overrides.merits
        end
        if sim_overrides.job_points then
            player.job_points = sim_overrides.job_points
        end
    end

    -- Decoded equipment + parsed gear-summed stats.
    local current_equip = check_equipped()
    if not current_equip then
        return false, 'check_equipped returned nil'
    end
    if not next(current_equip) then
        return false, 'check_equipped returned empty table'
    end

    -- Sim equipment overrides: replace specific slots before stats are
    -- summed. equip_overrides is an optional table keyed by slot name
    -- (lowercase) → item_id (0 = explicit empty / unequipped).
    -- Caller (OmniWatch.lua's compute path) supplies this when sim is
    -- active. We re-parse the swapped item via parse_new_single_item
    -- so its stat fields are populated in current_equip.
    if equip_overrides and next(equip_overrides) then
        for slot, iid in pairs(equip_overrides) do
            -- "Empty" sentinel: integer 0 or a table with id<=0.
            local is_empty = (iid == 0)
                          or (type(iid) == 'table' and (tonumber(iid.id) or 0) <= 0)
            if is_empty then
                -- Explicit empty: zero entry, no contribution.
                current_equip[slot] = {
                    id = 0, en = '', category = '', delay = 0,
                    haste = 0, dual_wield = 0, stp = 0, augments = '',
                }
            elseif type(iid) == 'number' and iid > 0 then
                -- Resolve the item from cache, parse if absent.
                local replacement = nil
                for _, cached in ipairs(full_gear_table_from_file or {}) do
                    if cached.id == iid then
                        replacement = cached
                        break
                    end
                end
                if not replacement then
                    -- Item isn't in cache (probably never equipped before).
                    -- Fabricate a windower-shaped entry and run it through
                    -- parse_new_single_item so its augments/etc. parse
                    -- correctly from item description.
                    local synthetic = {id = iid, count = 1, augments = nil, extdata = ''}
                    replacement = parse_new_single_item(synthetic)
                end
                if replacement then
                    current_equip[slot] = replacement
                end
            elseif type(iid) == 'table' and tonumber(iid.id) and tonumber(iid.id) > 0 then
                -- Instance-keyed override: {id, bag, idx}. Fetch the live
                -- item at (bag, idx) and parse it through the GearInfo
                -- pipeline so the actual augments propagate. Falls back
                -- to id-only path if (bag, idx) doesn't resolve.
                local want_id = tonumber(iid.id)
                local bag = tonumber(iid.bag) or 0
                local idx = tonumber(iid.idx) or 0
                local live_item = nil
                if bag > 0 and idx > 0 then
                    local got = windower.ffxi.get_items(bag, idx)
                    if got and got.id == want_id then
                        live_item = got
                    end
                end
                local replacement
                if live_item then
                    -- parse_new_single_item handles augment decoding via
                    -- extdata; the result table includes the augmented
                    -- gear stats merged in.
                    replacement = parse_new_single_item(live_item)
                end
                if not replacement then
                    -- Fall back to id-only lookup.
                    for _, cached in ipairs(full_gear_table_from_file or {}) do
                        if cached.id == want_id then
                            replacement = cached
                            break
                        end
                    end
                    if not replacement then
                        local synthetic = {id = want_id, count = 1, augments = nil, extdata = ''}
                        replacement = parse_new_single_item(synthetic)
                    end
                end
                if replacement then
                    current_equip[slot] = replacement
                end
            end
        end
    end

    local gi = get_equip_stats(current_equip)
    if not gi then
        return false, 'get_equip_stats returned nil'
    end
    Gear_info = gi

    if check_buffs then pcall(check_buffs) end
    if calculate_total_haste then pcall(calculate_total_haste) end
    return true, 'ok'
end

-- compute_player_stats: returns a table { acc, att, eva, def } using
-- GearInfo's formulas.
--
-- IMPORTANT ordering subtlety: GearInfo's helpers expect to be called in a
-- specific order on the SAME stat_table reference, because get_player_acc()
-- mutates the table by ADDING player.stats[stat] to stat_table[stat] for
-- each primary stat (STR/DEX/VIT/AGI/INT/MND/CHR). The other helpers
-- (get_player_att/evasion/defence) READ those stats but do NOT add player.stats
-- themselves. So if we call them on independent copies of Gear_info, attack
-- comes out missing the player-base STR component (manifests as Total_att.str=0
-- and a 100-200pt undercount).
--
-- We mirror GearInfo's update() flow: build a single working copy, run
-- get_player_acc first (mutating it to add player.stats), then run the
-- other three helpers on that same mutated copy. Each helper still returns
-- its own value table; we just share the input.
function _gi.compute_player_stats()
    if not Gear_info then
        return nil, 'Gear_info nil'
    end
    if not next(Gear_info) then
        return nil, 'Gear_info empty'
    end
    local working = table.copy(Gear_info)
    local r = {}
    -- Each helper is wrapped in pcall so one failure doesn't take all four down.
    local ok_acc, acc = pcall(get_player_acc, working)
    -- After get_player_acc, working[STR/DEX/etc] now include player.stats.
    -- Pass the SAME mutated table to att/eva/def.
    local ok_att, att = pcall(get_player_att, working)
    local ok_eva, eva = pcall(get_player_evasion, working)
    local ok_def, def = pcall(get_player_defence, working)
    r.acc = ok_acc and acc or nil
    r.att = ok_att and att or nil
    r.eva = ok_eva and eva or nil
    r.def = ok_def and def or nil
    r._errs = {}
    if not ok_acc then r._errs[#r._errs+1] = 'acc:' .. tostring(acc) end
    if not ok_att then r._errs[#r._errs+1] = 'att:' .. tostring(att) end
    if not ok_eva then r._errs[#r._errs+1] = 'eva:' .. tostring(eva) end
    if not ok_def then r._errs[#r._errs+1] = 'def:' .. tostring(def) end
    return r
end

-- Expose parse.i for OmniWatch's incoming_chunk handler to call.
_gi.parse = parse

return _gi