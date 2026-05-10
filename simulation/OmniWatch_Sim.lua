-- OmniWatch_Sim.lua
-- =============================================================================
-- Simulation module for OmniWatch. Loaded at OmniWatch.lua startup if present.
-- When sim mode is active, OmniWatch's stats compute reads from this module's
-- get_player() (and related accessors) instead of the real windower API.
--
-- Wire format: the python overlay sends UDP messages on port 5011 (the
-- existing inbound command channel) with these prefixes:
--
--   SIM_MODE|on              → set_active(true)
--   SIM_MODE|off             → set_active(false)
--   SIM|main_job|NIN         → set_value('main_job', 'NIN')
--   SIM|sub_job|WAR          → set_value('sub_job', 'WAR')
--   SIM|merit|<name>|<n>     → set_value('merit', n, name)
--   SIM|jp|<n>               → set_value('jp', n)         (total JP spent on
--                                                          current sim main job)
--   SIM|gift|<id>|<true|false> → set_value('gift', bool, id)
--   SIM|reset                → wipe state to defaults
--
-- Internal state: _ow_sim_state. Keys mirror windower.ffxi.get_player() field
-- names so OmniWatch's compute code (which reads p.main_job, p.merits.X,
-- p.job_points[mjob].jp_spent) keeps working without per-field branching.
--
-- Returns a module table (M) so the loader in OmniWatch.lua can capture it.
-- =============================================================================

local M = {}

-- ─── Buff data tables ──────────────────────────────────────────────────────
-- Each entry is keyed by canonical buff id ('honor_march', 'chaos_roll', etc).
-- The compute() function reads these to translate sim'd buff state into
-- stat additions on the synthetic player object.
--
-- Format reference:
--
--   For songs (BRD):
--     {
--       job = 'BRD', name = 'Honor March', kind = 'song',
--       stat = 'magic_haste', unit = '/1024',
--       base = 90, per_plus = 48, plus_max = 8,
--     }
--
--   For rolls (COR):
--     {
--       job = 'COR', name = 'Chaos Roll', kind = 'roll',
--       stat = 'attack_pct',  -- note: percent not /1024
--       potency_no_optimal = {6, 8, 9, 25, 11, 13, 16, 3, 17, 19, 31},
--       potency_with_optimal = {16, 18, 19, 35, 21, 22, 25, 13, 27, 29, 41},
--       optimal_job = 'DRK',
--       per_plus = 1.5,  -- approx per BG-wiki: each Phantom Roll +1 adds ~1.5%
--       plus_max = 11,
--     }
--
-- Numbers sourced from BG-wiki / FFXIclopedia / FFXIonline community
-- testing. Honor March / Advancing March numbers verified per
-- BG-wiki's Talk:Honor March (Byrthnoth's testing). Chaos Roll table
-- per FFXIonline 2007 thread (DRK column = with-optimal-job).
--
-- Hunter's Roll, Madrigal, etc. NOT YET MODELED — add to this table
-- with correct values from wiki when needed. Format makes adding new
-- entries data-only; no compute changes required.

local BUFF_DATA = {
    honor_march = {
        job = 'BRD', name = 'Honor March', kind = 'song',
        -- Honor March is unique among marches: it grants acc/att/racc/ratt
        -- in addition to magic haste. Stats below indexed by gear March+
        -- level on the bard (same potency that PW_HONOR_MARCH_STATS_BY_NAME
        -- in OmniWatch.lua uses, kept in sync). Magic haste still scales
        -- linearly via base + per_plus.
        stat = 'magic_haste', unit_div = 1024,
        base = 90, per_plus = 48, plus_max = 8,
        -- Multi-stat additions: each entry is {stat_key, by_plus_table}.
        -- by_plus_table maps gear March+ level (0..max) → flat amount.
        -- Indexed up to plus 4 since that's the live cap; entries beyond
        -- 4 reuse the +4 row (game does not currently extend past 4).
        extra_stats = {
            attack   = {[0]=168, [1]=184, [2]=200, [3]=216, [4]=232,
                        [5]=232, [6]=232, [7]=232, [8]=232},
            accuracy = {[0]=42,  [1]=46,  [2]=50,  [3]=54,  [4]=58,
                        [5]=58,  [6]=58,  [7]=58,  [8]=58},
        },
        notes = 'BRD self-buff (NPC instrument). +1 March gives +48/1024 magic haste plus acc/att.',
    },
    advancing_march = {
        job = 'BRD', name = 'Advancing March', kind = 'song',
        stat = 'magic_haste', unit_div = 1024,
        base = 108, per_plus = 16, plus_max = 8,
        notes = 'Standard March song. +1 gives +16/1024.',
    },
    victory_march = {
        job = 'BRD', name = 'Victory March', kind = 'song',
        -- Victory March: stronger magic haste than Advancing, weaker
        -- than Honor. Base 138/1024 ≈ 13.5%; +1 March gives +24/1024.
        -- Cap at plus 8 same as the other marches.
        stat = 'magic_haste', unit_div = 1024,
        base = 138, per_plus = 24, plus_max = 8,
        notes = 'BRD March song. Base 138/1024 ≈ 13.5%; +1 gives +24/1024.',
    },
    -- ─── Minuets ────────────────────────────────────────────────────
    -- Pure attack-boost songs. Base values per BG-wiki Minuet pages,
    -- with +5 attack added from 5/5 Minuet Effect group-2 merits (the
    -- typical BRD merit setup). Gear bonuses (Minuet+ instruments,
    -- earrings) add +1 attack per +1 song-tier; capped at plus 8.
    -- Minuet III is the merit-tier Minuet — the +5 merit bonus only
    -- raises Minuet III's potency in-game, but most modern BRDs run
    -- the highest tier they have learned, so we apply +5 to all tiers
    -- as a "5/5 merit + tier potency" baseline. If a user runs lower
    -- merits the values overstate by 1-5; that's a known approximation.
    minuet_i = {
        job = 'BRD', name = 'Minuet I', kind = 'song',
        stat = 'attack',
        base = 17, per_plus = 1, plus_max = 8,
        notes = 'Attack +17 (12 base + 5/5 merit). +1 gives +1 attack.',
    },
    minuet_ii = {
        job = 'BRD', name = 'Minuet II', kind = 'song',
        stat = 'attack',
        base = 23, per_plus = 1, plus_max = 8,
        notes = 'Attack +23 (18 base + 5/5 merit). +1 gives +1 attack.',
    },
    minuet_iii = {
        job = 'BRD', name = 'Minuet III', kind = 'song',
        stat = 'attack',
        base = 27, per_plus = 1, plus_max = 8,
        notes = 'Attack +27 (22 base + 5/5 merit). +1 gives +1 attack.',
    },
    minuet_iv = {
        job = 'BRD', name = 'Minuet IV', kind = 'song',
        stat = 'attack',
        base = 32, per_plus = 1, plus_max = 8,
        notes = 'Attack +32 (27 base + 5/5 merit). +1 gives +1 attack.',
    },
    minuet_v = {
        job = 'BRD', name = 'Minuet V', kind = 'song',
        stat = 'attack',
        base = 36, per_plus = 1, plus_max = 8,
        notes = 'Attack +36 (31 base + 5/5 merit). +1 gives +1 attack.',
    },
    chaos_roll = {
        job = 'COR', name = 'Chaos Roll', kind = 'roll',
        stat = 'attack_pct',
        potency_no_opt   = {6, 8, 9, 25, 11, 13, 16, 3, 17, 19, 31},
        potency_with_opt = {16, 18, 19, 35, 21, 22, 25, 13, 27, 29, 41},
        optimal_job = 'DRK',
        per_plus = 1.5, plus_max = 11,
        notes = 'Atk%. Lucky 4, Unlucky 8. Phantom Roll+1 ≈ +1.5% per tier.',
    },
    sam_roll = {
        -- Samurai Roll. Store TP. Lucky 2, Unlucky 6. Optimal job SAM
        -- adds +10 to all values per BG-wiki community testing.
        job = 'COR', name = 'Samurai Roll', kind = 'roll',
        stat = 'store_tp',
        potency_no_opt   = {8, 32, 10, 12, 14, 4, 15, 20, 22, 24, 40},
        potency_with_opt = {18, 42, 20, 22, 24, 14, 25, 30, 32, 34, 50},
        optimal_job = 'SAM',
        per_plus = 1, plus_max = 11,
        notes = 'Store TP. Lucky 2, Unlucky 6. SAM in party adds +10.',
    },
    tactician_roll = {
        -- Tactician's Roll. Regain (TP/tick). Lucky 5, Unlucky 8.
        -- No traditional optimal job — Navarch's Frac +1/+2 adds the
        -- +10 bonus instead, treated here as a generic boost slot.
        job = 'COR', name = "Tactician's Roll", kind = 'roll',
        stat = 'regain',
        potency_no_opt   = {2, 4, 4, 2, 10, 4, 6, 1, 8, 8, 15},
        potency_with_opt = {12, 14, 14, 12, 20, 14, 16, 11, 18, 18, 25},
        optimal_job = '',  -- no job-based bonus; uses gear path
        per_plus = 1, plus_max = 11,
        notes = "Regain. Lucky 5, Unlucky 8. Navarch's Frac +2 adds +10.",
    },
    valor_madrigal = {
        -- Valor Madrigal: BRD acc song (tier I). Base +6 acc with
        -- 5/5 Madrigal Effect merits adding +5 → +11 baseline. +1
        -- instrument adds +1 per tier, capped at plus 8 like other
        -- BRD songs.
        job = 'BRD', name = 'Valor Madrigal', kind = 'song',
        stat = 'accuracy',
        base = 11, per_plus = 1, plus_max = 8,
        notes = 'Accuracy +11 (6 base + 5/5 merit). +1 gives +1 acc.',
    },
    blade_madrigal = {
        -- Blade Madrigal: BRD acc song (tier II, lvl 65). Base +10
        -- acc + 5/5 Madrigal Effect merits = +15 baseline. +1 inst
        -- gives +1 acc per tier, plus_max 8.
        job = 'BRD', name = 'Blade Madrigal', kind = 'song',
        stat = 'accuracy',
        base = 15, per_plus = 1, plus_max = 8,
        notes = 'Accuracy +15 (10 base + 5/5 merit). +1 gives +1 acc.',
    },
    indi_fury = {
        -- Indi-Fury: GEO indicolure attack-boost spell. Per BG-wiki
        -- Category:Geomancy + dev-team forum post:
        --   • Combined Geomancy + Handbell skill: 0 → +4.6% atk
        --     scales linearly to 900 → +34.7% atk
        --   • Each "Geomancy+" gear tier: +2.7% atk independent of
        --     skill. Idris counts as +10 (×10 multiplier on the
        --     base Geomancy+ bonus). Geomancy+ items don't stack —
        --     only the highest equipped value applies.
        -- We model it like a BRD song: assume capped 900 skill as
        -- baseline (typical 99 GEO with handbell main has well over
        -- 900 combined), and use the "Plus" +/- picker to represent
        -- equipped Geomancy+ tier (0..10). Plus 0 = no gear, Plus 1
        -- = Dunna, Plus 5 = Idris-equivalent endgame, etc.
        job = 'GEO', name = 'Indi-Fury', kind = 'song',
        stat = 'attack_pct',
        base = 34.7, per_plus = 2.7, plus_max = 10,
        notes = 'Atk%. Base assumes capped 900 combined skill. '
             .. 'Plus = Geomancy+ gear tier (Dunna +1, Idris +5+).',
    },
    indi_haste = {
        -- Indi-Haste: GEO indicolure magic-haste spell. Per BG-wiki:
        --   • 900 combined skill: +29.9% magic haste
        --   • Eminent Bell: +3.3%
        --   • Dunna / Nepote Bell / Bagua Charm: +5.5%
        --   • Bagua Charm +1: +6.6%, +2: +7.7%
        --   • Idris: +11%
        -- Modeled like Indi-Fury: assume capped 900 skill as
        -- baseline, Plus picker represents Geomancy+ gear tier.
        -- per_plus is set to the Dunna/Bagua baseline (5.5%) as the
        -- "common case" — Idris approximates as Plus 2, Bagua +2 as
        -- Plus 1.4 (rounds up). Stat key 'magic_haste' uses the
        -- /1024 unit convention; 29.9% = 306/1024, 5.5% = 56/1024.
        -- Note: in real game Indi-Haste DOES NOT stack with regular
        -- Haste spell magic-haste. Sim treats it as additive into
        -- the magic-haste bucket; the existing 43.75% cap clamp in
        -- the lua post-buff block handles overflow visually (red
        -- when over-cap, per the user's "raw value displayed"
        -- visualization preference).
        job = 'GEO', name = 'Indi-Haste', kind = 'song',
        stat = 'magic_haste', unit_div = 1024,
        base = 306, per_plus = 56, plus_max = 10,
        notes = 'Magic haste. Base assumes capped 900 combined skill. '
             .. 'Plus = Geomancy+ tier (Dunna +1, Idris ≈ +2).',
    },
    -- ─── Spell-kind: flat values, no plus/level/optimal ───────────
    -- These are simple "is the spell on?" buffs. The compute path
    -- for kind='spell' just adds `base` to the named stat — no
    -- multiplier, no scaling. Values use the same canonical units
    -- as the song path (e.g. magic_haste in /1024).
    spell_haste = {
        -- Haste (white magic). Per BG-wiki Attack Speed page:
        -- 150/1024 magic haste (~14.65%, displayed as 15%).
        job = 'WHM', name = 'Haste', kind = 'spell',
        stat = 'magic_haste', unit_div = 1024,
        base = 150,
        notes = 'Magic haste 150/1024 (~14.65%). Overwrites Flurry.',
    },
    spell_haste2 = {
        -- Haste II (white magic, lvl 80). 30% magic haste = 307/1024.
        job = 'WHM', name = 'Haste II', kind = 'spell',
        stat = 'magic_haste', unit_div = 1024,
        base = 307,
        notes = 'Magic haste 307/1024 (~30%). Overwrites Haste/Flurry.',
    },
    spell_flurry = {
        -- Flurry (white magic, lvl 35). 15% snapshot per BG-wiki
        -- Snapshot page (no exact /1024 value documented; using a
        -- flat percent as the display unit).
        job = 'WHM', name = 'Flurry', kind = 'spell',
        stat = 'snapshot',
        base = 15,
        notes = 'Snapshot +15%. Overwritten by Haste/Haste II.',
    },
    spell_flurry2 = {
        -- Flurry II (white magic, lvl 89). 30% snapshot per Freshly
        -- Picked Vana'diel #9 (BG-wiki sourced).
        job = 'WHM', name = 'Flurry II', kind = 'spell',
        stat = 'snapshot',
        base = 30,
        notes = 'Snapshot +30%. Overwritten by Haste/Haste II.',
    },
}

-- Public accessor so the python/lua UI can query the buff list (for
-- populating the "pick a buff" dropdown). Returns a list of
-- {id, job, name} sorted by job then name.
function M.list_buffs()
    local out = {}
    for id, def in pairs(BUFF_DATA) do
        table.insert(out, {id = id, job = def.job, name = def.name})
    end
    table.sort(out, function(a, b)
        if a.job ~= b.job then return a.job < b.job end
        return a.name < b.name
    end)
    return out
end

function M.get_buff_def(id)
    return BUFF_DATA[id]
end

-- ─── State ─────────────────────────────────────────────────────────────────
-- Default state: pure-scratch (everything zeroed) per the user's spec. When
-- sim toggles on, the panel starts blank and the user fills values in.
local function fresh_state()
    return {
        active   = false,    -- sim on/off
        main_job = '',       -- 3-letter job code
        sub_job  = '',
        merits   = {},       -- name → count
        jp_spent = 0,        -- on the sim main_job
        master_level = 0,    -- 0..50; +1 to all 7 base stats per ML
        gifts    = {},       -- id → bool
        buffs    = {},       -- key → number (legacy +N values; deprecated)
        active_buffs = {},   -- list of {id, level (1-11 for rolls), plus, optimal}
                             -- e.g. {id='honor_march', plus=4} or
                             -- {id='chaos_roll', level=11, plus=0, optimal=true}
        -- New: gear slot overrides. Maps slot key ('main', 'sub', etc.)
        -- to item id. Value 0 means "explicitly empty" (sim slot is
        -- unequipped during compute). Absent slot means "use real gear
        -- for this slot".
        equipment = {},
        -- New: simulated food. nil means no food active. Otherwise an
        -- integer item id matching a curated SIM_FOOD_LIST entry on
        -- the python side (food data is python-side; lua just receives
        -- the id and trusts python's stat additions are pre-applied
        -- via SIM|food → sim_state but the actual stat lookup happens
        -- in OmniWatch.lua's compute path via FOOD_STATS_BY_ID below).
        food = nil,
    }
end

local _ow_sim_state = fresh_state()

-- ─── Activation ────────────────────────────────────────────────────────────
function M.is_active()
    return _ow_sim_state.active and true or false
end

function M.set_active(on)
    _ow_sim_state.active = on and true or false
    if not on then
        -- Wipe state when sim turns off so the next session starts blank.
        _ow_sim_state = fresh_state()
    end
    -- (Removed chat print — sim state is visible in the overlay UI.)
end

-- ─── Setters ───────────────────────────────────────────────────────────────
-- Single entry point. The python overlay pushes one SIM|... message per
-- field change; this routes by key.
function M.set_value(key, value, sub)
    if key == 'main_job' or key == 'sub_job' or key == 'merit' or key == 'jp' then
        -- IGNORED: per spec, these come from the live player. The python
        -- overlay may still send them for backward-compat with older
        -- builds; we silently drop. Live values are pulled via
        -- _sync_from_live() on activation and refresh_from_live() on
        -- every compute tick.
        return
    elseif key == 'master_level' then
        -- IGNORED: ML is pulled from the live player.
        return
    elseif key == 'gift' then
        -- value=true/false, sub=gift_id
        local b = (value == true) or (value == 'true') or (value == 1)
        if sub then
            _ow_sim_state.gifts[tostring(sub)] = b
        end
    elseif key == 'buff' then
        -- value=count/level, sub=buff key (e.g. 'brd_songs', 'cor_rolls')
        -- LEGACY: kept for backward compat with the old +N UI.
        local n = tonumber(value) or 0
        if sub and sub ~= '' then
            _ow_sim_state.buffs[tostring(sub):lower()] = n
        end
    elseif key == 'buff_add' then
        -- Add a buff to the active list. value=buff_id, sub unused.
        -- Initial state: level=11 (rolls) or plus=0 (songs).
        local id = tostring(value or '')
        local def = BUFF_DATA[id]
        if def then
            local entry = {id = id}
            if def.kind == 'roll' then
                entry.level = 11    -- assume optimal roll for testing
                entry.plus  = 0
                entry.optimal = false
            else  -- 'song'
                entry.plus = 0
            end
            table.insert(_ow_sim_state.active_buffs, entry)
        end
    elseif key == 'buff_remove' then
        -- Remove buff at index. value=index (1-based).
        local idx = tonumber(value) or 0
        if idx > 0 and idx <= #_ow_sim_state.active_buffs then
            table.remove(_ow_sim_state.active_buffs, idx)
        end
    elseif key == 'buff_update' then
        -- Update a field on an active buff. Format:
        --   value = "<idx>:<field>:<new_value>"
        -- e.g. "1:plus:5", "2:level:11", "1:optimal:true"
        local s = tostring(value or '')
        local parts = {}
        for chunk in s:gmatch('[^:]+') do
            table.insert(parts, chunk)
        end
        if #parts == 3 then
            local idx = tonumber(parts[1]) or 0
            local field = parts[2]
            local new_v = parts[3]
            local entry = _ow_sim_state.active_buffs[idx]
            if entry then
                if field == 'plus' or field == 'level' then
                    entry[field] = tonumber(new_v) or 0
                elseif field == 'optimal'
                    or field == 'boost_sv'
                    or field == 'boost_marcato'
                    or field == 'boost_cc' then
                    entry[field] = (new_v == 'true' or new_v == '1')
                end
            end
        end
    elseif key == 'equip' then
        -- Sim equipment override.
        --   value = "0"                  → explicit empty
        --   value = "<id>"               → legacy id-only (best-effort lookup)
        --   value = "<id>@<bag>:<idx>"   → instance-keyed (preferred,
        --                                  carries augments via location)
        -- sub = slot key (e.g. 'main', 'head', 'left_ear').
        if not (sub and sub ~= '') then return end
        local sk = tostring(sub):lower()
        local raw = tostring(value or '')
        -- Parse instance ref form first.
        local id_s, bag_s, idx_s = raw:match('^(%-?%d+)@(%d+):(%d+)$')
        if id_s then
            _ow_sim_state.equipment[sk] = {
                id  = tonumber(id_s)  or 0,
                bag = tonumber(bag_s) or 0,
                idx = tonumber(idx_s) or 0,
            }
        else
            -- Legacy id-only or "0" for empty.
            local iid = tonumber(raw) or 0
            _ow_sim_state.equipment[sk] = iid
        end
    elseif key == 'food' then
        -- Sim food. value=item_id (0 means none).
        local fid = tonumber(value) or 0
        _ow_sim_state.food = (fid > 0) and fid or nil
    elseif key == 'export' then
        -- Write the current sim equipment to disk as a GearSwap-style
        -- .lua file. Implemented by export_set() below; called via the
        -- public M.export_set hook so OmniWatch.lua can also trigger
        -- it from a slash command later if needed.
        if M.export_set then
            local ok, err = pcall(M.export_set)
            if not ok then
                windower.add_to_chat(123, '[OW/Sim] export_set failed: ' .. tostring(err))
            end
        end
    elseif key == 'reset' then
        _ow_sim_state = fresh_state()
        _ow_sim_state.active = true   -- preserve active flag through reset
    end
end

-- ─── Accessors ─────────────────────────────────────────────────────────────
-- Sim no longer fakes a player table; OmniWatch.lua reads the live
-- player directly. Only sim-specific accessors remain (gift state for
-- sim'd buff/gift pickers, plus the buff helpers below).
function M.get_gift(gift_id)
    return _ow_sim_state.gifts[tostring(gift_id)] or false
end

function M.get_buff(key)
    -- Returns the +N for sim'd buffs (brd_songs, cor_rolls). 0 if unset.
    -- The lua compute side reads these to derive stat boosts when sim
    -- is active — TBD wiring; kept here as a hook for that work.
    return _ow_sim_state.buffs[tostring(key):lower()] or 0
end

-- Compute the aggregate stat additions from all active buffs. Returns
-- a table keyed by stat name. Output keys and units MUST match what
-- the rest of OmniWatch (and the python overlay) expects:
--
--   'magic haste'   → percent  (cap 43.75% per FFXI mechanics)
--   'ja haste'      → percent  (cap 25%)
--   'attack'        → flat add to base attack
--   'accuracy'      → flat
--   'attack pct'    → percent multiplier (rolls)
--
-- BUFF_DATA stores values in canonical FFXI units (e.g. songs in /1024).
-- This function converts those to the keys/units the overlay reads.
local _STAT_NORMALIZE = {
    -- buff-data key  → (canonical name, unit conversion fn taking val)
    magic_haste = {'magic haste', function(v) return v * 100 / 1024 end},
    ja_haste    = {'ja haste',    function(v) return v * 100 / 1024 end},
    attack_pct  = {'attack pct',  function(v) return v end},
    accuracy    = {'accuracy',    function(v) return v end},
    attack      = {'attack',      function(v) return v end},
    -- Snapshot is a flat percent (Flurry 15, Flurry II 30). No /1024
    -- conversion needed — the panel reads 'snapshot' as a percent.
    snapshot    = {'snapshot',    function(v) return v end},
    -- Store TP comes from Samurai Roll. The panel reads the stat under
    -- the canonical 'store tp' key (with space); buff_data uses the
    -- underscore form for lua-friendly keys, so normalize here.
    store_tp    = {'store tp',    function(v) return v end},
    str         = {'str',         function(v) return v end},
    dex         = {'dex',         function(v) return v end},
    vit         = {'vit',         function(v) return v end},
    agi         = {'agi',         function(v) return v end},
    ['int']     = {'int',         function(v) return v end},
    mnd         = {'mnd',         function(v) return v end},
    chr         = {'chr',         function(v) return v end},
}

function M.compute_active_buff_stats()
    -- Each buff entry can carry boost flags that multiply its output:
    --   boost_sv (songs)      : Soul Voice, x2.0 — BRD 1-hour
    --   boost_marcato (songs) : Marcato, x1.5 — BRD JA (in real play
    --                           only boosts the next song cast, so the
    --                           per-buff toggle here lets the user
    --                           pick exactly which song it lands on)
    --   boost_cc (rolls)      : Crooked Cards, x1.5 — COR 1-hour
    -- Multipliers stack multiplicatively when both apply (e.g. SV +
    -- Marcato on the same song = x3.0).
    local raw = {}
    for _, entry in ipairs(_ow_sim_state.active_buffs or {}) do
        local def = BUFF_DATA[entry.id]
        if def then
            -- Compute the per-buff multiplier first; applies uniformly
            -- to all stat outputs from this buff.
            local mult = 1.0
            if def.kind == 'song' then
                if entry.boost_sv      then mult = mult * 2.0 end
                if entry.boost_marcato then mult = mult * 1.5 end
            elseif def.kind == 'roll' then
                if entry.boost_cc      then mult = mult * 1.5 end
            end

            if def.kind == 'song' then
                local p = math.min(def.plus_max, math.max(0, entry.plus or 0))
                local add = (def.base or 0) + (def.per_plus or 0) * p
                raw[def.stat] = (raw[def.stat] or 0) + add * mult
                -- Some songs (Honor March) also grant acc/att/racc/ratt
                -- in addition to their primary stat. extra_stats maps
                -- canonical stat key → {[plus]=amount}.
                if def.extra_stats then
                    for stat_key, by_plus in pairs(def.extra_stats) do
                        local v = by_plus[p] or by_plus[def.plus_max] or 0
                        raw[stat_key] = (raw[stat_key] or 0) + v * mult
                    end
                end
            elseif def.kind == 'roll' then
                local lv = math.max(1, math.min(11, entry.level or 11))
                local table_to_use = entry.optimal
                    and def.potency_with_opt or def.potency_no_opt
                local base = (table_to_use[lv] or 0)
                local p = math.min(def.plus_max, math.max(0, entry.plus or 0))
                local add = base + (def.per_plus or 0) * p
                raw[def.stat] = (raw[def.stat] or 0) + add * mult
            elseif def.kind == 'spell' then
                -- Flat add. No multiplier (mult is always 1.0 for
                -- spells — they don't have SV/Marcato/CC equivalents).
                local add = (def.base or 0)
                raw[def.stat] = (raw[def.stat] or 0) + add
            end
        end
    end
    -- Normalize into the canonical keys/units OmniWatch expects.
    local out = {}
    for k, v in pairs(raw) do
        local norm = _STAT_NORMALIZE[k]
        if norm then
            local target_key = norm[1]
            local converter  = norm[2]
            out[target_key] = (out[target_key] or 0) + converter(v)
        else
            -- Unknown buff stat — pass through unchanged. Better to
            -- show something funny than swallow a real value.
            out[k] = (out[k] or 0) + v
        end
    end
    return out
end

function M.list_active_buffs()
    -- Returns a copy of active_buffs with definition fields merged in,
    -- so python side can render labels/stat targets without needing
    -- the BUFF_DATA table on its side. Format:
    --   {{id, name, job, kind, plus, level, optimal, max_plus, max_level}, ...}
    local out = {}
    for i, entry in ipairs(_ow_sim_state.active_buffs or {}) do
        local def = BUFF_DATA[entry.id]
        if def then
            table.insert(out, {
                idx = i,
                id = entry.id, name = def.name, job = def.job, kind = def.kind,
                plus = entry.plus or 0,
                level = entry.level or 11,
                optimal = entry.optimal and true or false,
                max_plus = def.plus_max or 0,
                max_level = (def.kind == 'roll') and 11 or 0,
                stat = def.stat,
            })
        end
    end
    return out
end

-- Diagnostic dump — used by //ow simdump if we add it later.
function M.dump()
    return _ow_sim_state
end

-- ─── Equipment & food accessors ─────────────────────────────────────────
-- Returns the sim's equipment override map. Caller (compute path)
-- merges this with real-game equipment: any slot present here wins
-- (with 0 meaning "force unequip"); any slot absent keeps real gear.
function M.get_equipment()
    return _ow_sim_state.equipment or {}
end

-- Returns the sim'd food id, or nil if no food active.
function M.get_food()
    return _ow_sim_state.food
end

-- Returns the sim'd master level (0..50).
function M.get_master_level()
    return _ow_sim_state.master_level or 0
end

-- ─── Base stats — intentionally absent ─────────────────────────────────
-- Earlier iterations attempted to model per-(race, job) base STR/DEX/etc
-- from the FFXI Status Calculator grade tables. We removed that for two
-- reasons: (1) coverage was incomplete (no published grades for the 7
-- post-2007 jobs — BLU/COR/PUP/DNC/SCH/GEO/RUN), and (2) the user's spec
-- for sim is "show me what my CHOICES contribute", not "model a real
-- character". Sim therefore starts STR/DEX/VIT/AGI/INT/MND/CHR/HP/MP at
-- zero. Master Level still adds +1 per level to the 7 attributes
-- (so ML 50 reads as +50 STR/DEX/VIT/AGI/INT/MND/CHR even with zero
-- base). Sub job effective level still rises with ML for sub trait cap.
-- Merits, JP gifts, traits, gear, food, and buffs add normally on top.

-- Curated food stat table. Keyed by item id; values are flat additions
-- to OmniWatch's stats[] table using canonical key names. MUST stay in
-- sync with SIM_FOOD_LIST in OmniWatch.py — that's the user-facing
-- list. The dual-source isn't ideal but lua/python don't share a data
-- file; if you add a food, add the same entry in both places.
local _FOOD_STATS = {
    [5736] = {accuracy=50, attack=50, ['magic accuracy']=35, ['magic attack bonus']=35},
    [5734] = {accuracy=60, attack=60, ['magic accuracy']=40, ['magic attack bonus']=40},
    [5733] = {accuracy=60, attack=60},
    [4359] = {accuracy=75, ['ranged accuracy']=75, attack=50, ['ranged attack']=50},
    [4360] = {accuracy=80, ['ranged accuracy']=80, attack=55, ['ranged attack']=55},
    [5735] = {accuracy=90, ['ranged accuracy']=90, attack=30, ['ranged attack']=30},
    [5739] = {accuracy=95, ['ranged accuracy']=95, attack=35, ['ranged attack']=35},
    [5746] = {accuracy=90, attack=50, ['magic accuracy']=60},
    [5660] = {accuracy=70, attack=70, ['magic accuracy']=50, ['magic attack bonus']=50},
    [5754] = {['magic attack bonus']=80, ['magic accuracy']=60, ['magic damage']=40},
    [5305] = {attack=75, accuracy=50},
    [5306] = {['magic attack bonus']=75, ['magic accuracy']=50},
}

-- Returns flat-stat additions from the active sim food, or empty table
-- if no food. Keys are canonical OmniWatch stat names so the caller
-- can add them directly to stats[].
function M.get_food_stats()
    local fid = _ow_sim_state.food
    if not fid then return {} end
    local entry = _FOOD_STATS[fid]
    if not entry then return {} end
    -- Shallow copy so caller's mutations don't affect our table.
    local out = {}
    for k, v in pairs(entry) do out[k] = v end
    return out
end

-- ─── Set export ─────────────────────────────────────────────────────────
-- Writes the current sim equipment to a GearSwap-style .lua file under
-- /simulation/export/. File contains a `sets.exported = { main='...', ...}`
-- table the user can copy into their gearswap file. Filenames are
-- timestamped so multiple exports don't overwrite each other.
function M.export_set()
    local eq = _ow_sim_state.equipment or {}
    if not next(eq) then
        windower.add_to_chat(123, '[OW/Sim] export: nothing to export (no slots set).')
        return
    end

    -- Build slot → name lookups. Item id 0 means "(empty)" → we omit
    -- that slot from the export rather than writing empty='' (gearswap
    -- treats absent slots as "leave alone", which matches the user's
    -- "build a partial set" intent).
    local slot_order = {
        'main', 'sub', 'range', 'ammo',
        'head', 'neck', 'left_ear', 'right_ear',
        'body', 'hands', 'left_ring', 'right_ring',
        'back', 'waist', 'legs', 'feet',
    }
    local lines = {}
    table.insert(lines, '-- OmniWatch sim export — ' .. os.date('%Y-%m-%d %H:%M:%S'))
    table.insert(lines, '-- Paste this into your gearswap file or rename "exported"')
    table.insert(lines, '-- to whatever set name you want (e.g. sets.engaged.high_acc).')
    table.insert(lines, 'sets.exported = {')
    for _, slot in ipairs(slot_order) do
        local iid = eq[slot]
        if iid and iid > 0 then
            local res_ok, item = pcall(function() return res and res.items and res.items[iid] end)
            local name = (res_ok and item and (item.en or item.enl)) or ('item:' .. iid)
            table.insert(lines, string.format('    %-12s = %q,', slot, name))
        end
    end
    table.insert(lines, '}')
    -- Add the food on a separate line as a comment for reference.
    if _ow_sim_state.food then
        local fitem = pcall(function() return res and res.items[_ow_sim_state.food] end)
        local fname = (fitem and res and res.items[_ow_sim_state.food]
                       and res.items[_ow_sim_state.food].en) or ('food:' .. _ow_sim_state.food)
        table.insert(lines, '-- Food: ' .. fname)
    end

    local body = table.concat(lines, '\n') .. '\n'

    -- Resolve output path. windower.addon_path points at addons/OmniWatch/.
    -- We write under simulation/export/. Filename includes timestamp +
    -- player name when available so concurrent characters don't collide.
    local out_dir = windower.addon_path .. 'simulation/export/'
    -- Best-effort: try to ensure the directory exists. lua's io can't
    -- mkdir directly, so we use os.execute as a fallback. If that fails
    -- silently, the io.open below will surface a more specific error.
    pcall(function()
        os.execute('mkdir "' .. out_dir:gsub('/', '\\') .. '" 2>nul')
    end)

    local pname = (windower.ffxi.get_player() and windower.ffxi.get_player().name) or 'Unknown'
    local fname = string.format('%s_%s.lua', pname, os.date('%Y%m%d_%H%M%S'))
    local fullpath = out_dir .. fname
    local f, err = io.open(fullpath, 'w')
    if not f then
        windower.add_to_chat(123, '[OW/Sim] export failed (open): ' .. tostring(err))
        return
    end
    f:write(body)
    f:close()
    windower.add_to_chat(207, '[OW/Sim] exported set to ' .. fname)
end

return M