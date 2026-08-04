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
-- Add new entries to this table with values from the wiki; the format
-- makes it data-only, no compute changes required.

local BUFF_DATA = {
    honor_march = {
        job = 'BRD', name = 'Honor March', kind = 'song',
        -- Honor March is unique among marches: it grants acc/att/racc/ratt
        -- in addition to magic haste. Stats below indexed by gear March+
        -- level on the bard (same potency that PW_HONOR_MARCH_STATS_BY_NAME
        -- in OmniWatch.lua uses, kept in sync). Magic haste still scales
        -- linearly via base + per_plus.
        -- Magic haste per BG-wiki Honor March potency table:
        --   +0 = 126/1024 (12.30%), then +12/1024 per gear March+ step
        --   (+1 138, +2 150, +3 162, +4 174). The acc/att rows below are
        --   the same table's Attack (168 +16/step) and Accuracy
        --   (42 +4/step) columns. Keep in sync with
        --   PW_HONOR_MARCH_STATS_BY_NAME in OmniWatch.lua.
        stat = 'magic_haste', unit_div = 1024,
        base = 126, per_plus = 12, plus_max = 8,
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
        notes = 'BRD self-buff (NPC instrument). +0 = 126/1024 (12.3%) '
             .. 'magic haste, +12/1024 per March+ step, plus acc/att.',
    },
    advancing_march = {
        job = 'BRD', name = 'Advancing March', kind = 'song',
        -- Magic haste scales as floor(base * (1 + 0.1 * March+)) per the
        -- HasteInfo/BG-wiki march formula (NOT a flat linear step). Base
        -- 108/1024 (10.55%) → 108,118,129,140,151,162,172,183,194 at
        -- +0..+8. haste_mult triggers the floor formula in compute.
        stat = 'magic_haste', unit_div = 1024,
        base = 108, plus_max = 8, haste_mult = true,
        notes = 'Standard March song. floor(108*(1+0.1*March+))/1024; '
             .. '+0 = 10.55%.',
    },
    victory_march = {
        job = 'BRD', name = 'Victory March', kind = 'song',
        -- Victory March is the strongest pure-haste march. Base
        -- 163/1024 (15.92%), scaling floor(163*(1+0.1*March+)) →
        -- 163,179,195,211,228,244,260,277,293 at +0..+8.
        stat = 'magic_haste', unit_div = 1024,
        base = 163, plus_max = 8, haste_mult = true,
        notes = 'BRD March song. floor(163*(1+0.1*March+))/1024; '
             .. '+0 = 15.92%.',
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
    fighters_roll = {
        -- Fighter's Roll. Double Attack rate. Lucky 5, Unlucky 9.
        -- Optimal job WAR adds +5 to every value (the "Bonus" row on
        -- the wiki page).
        --
        -- !! POTENCY IS THE SHAKIEST TABLE IN THIS FILE !! BG-wiki
        -- carries an explicit warning on it: the numbers came from a
        -- now-defunct JP site, nobody knows where that site got them,
        -- and tools able to measure Double Attack rate to this
        -- precision did not exist at the time. Treat a Fighter's Roll
        -- figure in sim as indicative, not authoritative, and do not
        -- "correct" other DA math to agree with it.
        job = 'COR', name = "Fighter's Roll", kind = 'roll',
        stat = 'double_attack',
        potency_no_opt   = {1, 2, 3, 4, 10, 5, 6, 6, 1, 7, 15},
        potency_with_opt = {6, 7, 8, 9, 15, 10, 11, 11, 6, 12, 20},
        optimal_job = 'WAR',
        per_plus = 1, plus_max = 11,
        notes = 'DA%. Lucky 5, Unlucky 9. WAR in party adds +5. '
             .. 'Potency table is flagged unreliable on BG-wiki.',
    },
    hunters_roll = {
        -- Hunter's Roll. Accuracy AND Ranged Accuracy, the same amount
        -- to both — hence extra_stats_same below rather than two
        -- entries. Lucky 4, Unlucky 8. Optimal job RNG adds +15.
        --
        -- NOT modeled: Barataria Ring (+5), which the wiki notes adds
        -- +25 accuracy to the roll's effect. That's a gear effect on
        -- the roller, not a property of the roll, and sim has no slot
        -- for "what the COR is wearing" — leave it out rather than
        -- bake someone else's ring into the number.
        job = 'COR', name = "Hunter's Roll", kind = 'roll',
        stat = 'accuracy',
        extra_stats_same = {'ranged_accuracy'},
        potency_no_opt   = {10, 13, 15, 40, 18, 20, 25, 5, 28, 30, 50},
        potency_with_opt = {25, 28, 30, 55, 33, 35, 40, 20, 43, 45, 65},
        optimal_job = 'RNG',
        per_plus = 5, plus_max = 11,
        notes = 'Acc + R.Acc. Lucky 4, Unlucky 8. RNG in party adds +15.',
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
        job = 'GEO', name = 'Indi / Geo Fury', kind = 'song',
        stat = 'attack_pct',
        base = 34.7, per_plus = 2.7, plus_max = 10,
        notes = 'Atk%. Base assumes capped 900 combined skill (34.7%). '
             .. 'Plus = Geomancy+ points: each point = 2.7% attack '
             .. '(Dunna 5 → +13.5%, Idris 10 → +27%).',
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
        job = 'GEO', name = 'Indi / Geo Haste', kind = 'song',
        stat = 'magic_haste', unit_div = 1024,
        base = 306, per_plus = 11.26, plus_max = 10,
        notes = 'Magic haste. Base assumes capped 900 combined skill '
             .. '(29.9%). Plus = Geomancy+ points: each point = 1.1% '
             .. 'magic haste (11.26/1024). Eminent Bell 3, Dunna/Bagua 5, '
             .. 'Bagua+1 6, Bagua+2 7, Idris 10 (+11%).',
    },
    indi_precision = {
        -- Indi-/Geo-Precision: GEO accuracy spell (boosts Accuracy AND
        -- Ranged Accuracy equally). Per SE's official "Effect Values of
        -- Indicolure Enhancement Spells" + BG-wiki Indi-Precision:
        --   • 900 combined skill (cap): +50 acc / +50 ranged acc
        --   • Each Geomancy+ gear tier:  +5 acc / +5 ranged acc
        --   • Idris counts as +10 tiers → +50 (max with Idris = 100)
        -- Modeled like the other GEO spells: assume capped 900 skill as
        -- the base, and the "Plus" picker is the Geomancy+ gear tier
        -- (0..10; Dunna +1, Idris ≈ +10). The ranged-accuracy half rides
        -- along via extra_stats_scaled so it tracks the same plus value.
        job = 'GEO', name = 'Indi / Geo Precision', kind = 'song',
        stat = 'accuracy',
        base = 50, per_plus = 5, plus_max = 10,
        extra_stats_scaled = {
            ['ranged accuracy'] = { base = 50, per_plus = 5 },
        },
        notes = 'Accuracy + Ranged Accuracy. Base assumes capped 900 '
             .. 'combined skill. Plus = Geomancy+ tier (Dunna +1, '
             .. 'Idris ≈ +10 for +50).',
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
    myoshu_ichi = {
        -- Myoshu: Ichi (NIN ninjutsu, lvl 85, ninja tool "kabenro").
        -- "Reduces TP dealt when striking an enemy" — Subtle Blow +10
        -- on the caster, per BG-wiki's notes. Self-target, 5:00.
        --
        -- BG-wiki states outright that this is affected by the 50
        -- Subtle Blow cap, which lines up with the panel's own
        -- STAT_CAPS entry — so a sim'd NIN whose gear already reaches
        -- 50 gains nothing real from it, and the cell going red past 50
        -- is the panel working, not an error.
        job = 'NIN', name = 'Myoshu: Ichi', kind = 'spell',
        stat = 'subtle_blow',
        base = 10,
        notes = 'Subtle Blow +10. Self, 5:00. Subject to the 50 cap.',
    },
    kakka_ichi = {
        -- Kakka: Ichi (NIN ninjutsu, lvl 93, ninja tool "ryuno").
        -- "Increases your TP gain" — Store TP +10. Self-target, 5:00.
        job = 'NIN', name = 'Kakka: Ichi', kind = 'spell',
        stat = 'store_tp',
        base = 10,
        notes = 'Store TP +10. Self, 5:00.',
    },
    embrava = {
        -- Embrava (SCH enhancing magic, lvl 5 w/ Tabula Rasa). A single
        -- unique status that bundles several effects; at the 500-skill
        -- cap (per BG-wiki Embrava) the combat-relevant pieces are:
        --   • Haste  : +20 +1 Haste  → 25.9% magic haste (266/1024)
        --   • Flurry : +20 +1 Flurry → 25.9% snapshot   (266/1024)
        --   • Regen  : +72 HP/tick   (panel 'regen' cell)
        --   • Refresh: +6  MP/tick   (panel 'refresh' cell)
        -- Because Embrava is a UNIQUE status it stacks with regular
        -- Haste/Flurry rather than overwriting them; the sim adds it into
        -- the magic-haste / snapshot buckets and the lua post-buff clamp
        -- handles the 43.75% magic-haste cap visually.
        --
        -- Primary stat is magic_haste (266/1024); the Flurry/snapshot
        -- and Regen/Refresh pieces ride along via extra_stats_flat (flat,
        -- no scaling — the spell path has no plus/level math).
        job = 'SCH', name = 'Embrava', kind = 'spell',
        stat = 'magic_haste', unit_div = 1024,
        base = 266,
        extra_stats_flat = { snapshot = 25.9, regen = 72, refresh = 6 },
        notes = 'SCH unique status. Magic haste 266/1024 (~25.9%) + '
             .. 'Flurry 25.9% snapshot + Regen 72/tick + Refresh 6/tick '
             .. 'at 500 skill. Stacks with Haste/Flurry.',
    },
    -- ─── Blue Magic (BLU) ───────────────────────────────────────────
    -- Self-cast BLU spells. Modeled on their combat-relevant pieces;
    -- non-combat / percent-defense effects that have no stats-panel
    -- cell are noted but not modeled (same policy as Embrava).
    erratic_flutter = {
        -- Erratic Flutter (BLU lvl 99). Grants Haste II — 307/1024
        -- magic haste (~29.98%), per BG-wiki. Same magnitude as the
        -- WHM Haste II spell. Overwrites Hojo: Ni / Hojo: Ichi / Slow
        -- but not most Slowga forms (not relevant to the stats panel).
        job = 'BLU', name = 'Erratic Flutter', kind = 'spell',
        stat = 'magic_haste', unit_div = 1024,
        base = 307,
        notes = 'BLU self-haste. Magic haste 307/1024 (~29.98%, Haste II).',
    },
    mighty_guard = {
        -- Mighty Guard (BLU lvl 99, requires Unbridled Learning/Wisdom).
        -- A unique status buff that stacks with other regen/haste/defense
        -- buffs (incl. Embrava). Per BG-wiki the effects are:
        --   • Magical haste +15%  → 153.6/1024 (panel 'magic haste')
        --   • Defense +25%        → 'defense pct' 25; the lua applies this
        --                           as a multiplier on the SIMULATED gear
        --                           defense (like Chaos Roll's attack pct)
        --   • Regen +30 HP/tick   → panel 'regen' cell
        --   • Magic Defense Bonus +15  (no stats-panel cell — not modeled)
        -- Mighty Guard grants NO Refresh (Regen only); only the pieces
        -- that map to a panel cell are modeled. 153.6/1024 = exactly
        -- 15.00% (wiki states "+15%").
        job = 'BLU', name = 'Mighty Guard', kind = 'spell',
        stat = 'magic_haste', unit_div = 1024,
        base = 153.6,
        extra_stats_flat = { regen = 30, ['defense pct'] = 25 },
        notes = 'BLU unique status. Magic haste +15% (153.6/1024) + '
             .. 'Regen +30/tick + Defense +25% (applied to sim defense). '
             .. 'MDB +15 has no panel cell. Stacks with Haste and Embrava.',
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
                    or field == 'boost_cc'
                    or field == 'boost_bolster'
                    or field == 'boost_bog' then
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
    -- Myoshu: Ichi. Underscore form here, spaced form on the panel.
    subtle_blow = {'subtle blow', function(v) return v end},
    -- Hunter's / Fighter's Roll. Underscore form here, spaced form on
    -- the panel; without these they'd pass through unnormalized and
    -- land under keys no cell reads.
    ranged_accuracy = {'ranged accuracy', function(v) return v end},
    double_attack   = {'double attack',   function(v) return v end},
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
    --   boost_bolster (GEO)   : Bolster, x2.0 — doubles ALL Geomancy
    --                           potency incl. Geomancy+ gear (BG-wiki).
    --   boost_bog (GEO)       : Blaze of Glory, x2.0 — same doubling.
    --                           Bolster and Blaze of Glory do NOT stack
    --                           with each other (BG-wiki), so either flag
    --                           applies x2 once, not x4.
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
                -- Bolster / Blaze of Glory (GEO). Both double geomancy
                -- potency and are mutually exclusive in-game, so OR them
                -- into a single x2 rather than multiplying twice.
                if entry.boost_bolster or entry.boost_bog then
                    mult = mult * 2.0
                end
            elseif def.kind == 'roll' then
                if entry.boost_cc      then mult = mult * 1.5 end
            end

            if def.kind == 'song' then
                local p = math.min(def.plus_max, math.max(0, entry.plus or 0))
                local add
                if def.haste_mult then
                    -- Marches (Advancing/Victory) scale multiplicatively:
                    -- floor(base * (1 + 0.1 * March+)), per the HasteInfo /
                    -- BG-wiki march formula. Not a flat linear per-plus
                    -- step. (Honor March is the exception — it uses an
                    -- explicit +12/1024 linear step, so it does NOT set
                    -- haste_mult.)
                    add = math.floor((def.base or 0) * (1 + 0.1 * p))
                else
                    add = (def.base or 0) + (def.per_plus or 0) * p
                end
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
                -- extra_stats_scaled: additional stats that scale with the
                -- SAME plus value as the primary (base + per_plus * p),
                -- rather than a fixed per-plus table. Used by Indi-/Geo-
                -- Precision so its ranged-accuracy half tracks the
                -- accuracy half exactly. Keys are canonical stat names.
                if def.extra_stats_scaled then
                    for stat_key, sdef in pairs(def.extra_stats_scaled) do
                        local v = (sdef.base or 0) + (sdef.per_plus or 0) * p
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
                -- extra_stats_same: further stats that receive the
                -- IDENTICAL computed amount, boosts included. Hunter's
                -- Roll grants one number to both accuracy and ranged
                -- accuracy, so listing it once and fanning out here
                -- keeps them from drifting apart if the table is ever
                -- corrected. (Songs use extra_stats / extra_stats_scaled
                -- and spells use extra_stats_flat for their own shapes;
                -- rolls had no equivalent until now.)
                if def.extra_stats_same then
                    for _, stat_key in ipairs(def.extra_stats_same) do
                        raw[stat_key] = (raw[stat_key] or 0) + add * mult
                    end
                end
            elseif def.kind == 'spell' then
                -- Flat add. No multiplier (mult is always 1.0 for
                -- spells — they don't have SV/Marcato/CC equivalents).
                local add = (def.base or 0)
                raw[def.stat] = (raw[def.stat] or 0) + add
                -- Some spells (Embrava) bundle additional flat stats on
                -- top of their primary. extra_stats_flat maps a buff-data
                -- stat key → flat amount (already in that stat's canonical
                -- unit; no plus/level scaling). Normalized below alongside
                -- the primary stat.
                if def.extra_stats_flat then
                    for stat_key, amount in pairs(def.extra_stats_flat) do
                        raw[stat_key] = (raw[stat_key] or 0) + (amount or 0)
                    end
                end
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
    -- Real windower res.items ids (verified against the Windower Resources
    -- items table) so res.items[id].en resolves to the right food name in
    -- the export "-- Food:" comment. Mirrors the python SIM_FOOD_LIST 1:1.
    --
    -- A stat value is either a NUMBER (flat add, e.g. str=5 → STR +5) or a
    -- TABLE {pct, cap} (percent-of-base with a flat cap, e.g.
    -- accuracy={15,72} → Accuracy +15%, max +72). FFXI's combat foods are
    -- mostly the latter; get_food_stats(base) resolves the percent against
    -- the caller's pre-food stat value and clamps to the cap.
    [6343] = {hp=20, str=2, vit=3, accuracy={10,80}, attack={10,50}, ['ranged accuracy']={10,80}, ['ranged attack']={10,50}, ['magic attack bonus']=3},
    [6344] = {hp=30, str=3, vit=4, accuracy={11,85}, attack={11,55}, ['ranged accuracy']={11,85}, ['ranged attack']={11,55}, ['magic attack bonus']=4},
    [5777] = {['int']=2, ['magic accuracy']={20,45}},
    [5893] = {hp=90, accuracy=90, ['ranged accuracy']=90, ['magic accuracy']=90},
    [6468] = {accuracy=75, ['ranged accuracy']=75, attack=50, ['ranged attack']=50},
    [6469] = {hp=45, str=7, dex=8, mnd=-4, chr=7, accuracy={11,105}, ['ranged accuracy']={11,105}},
    [5149] = {hp=20, str=5, dex=6, accuracy={15,72}, ['ranged accuracy']={15,72}},
    [5163] = {accuracy={16,76}, ['ranged accuracy']={16,76}, str=5, dex=6, hp=20},
    [5166] = {str=5, agi=1, ['int']=-2, attack={20,75}, ['ranged attack']={20,75}},
    [5167] = {attack={22,80}, ['ranged attack']={22,80}, str=5, agi=1},
    [5190] = {attack={18,65}, str=4, vit=2, ['store tp']=6},
    [6260] = {accuracy=90, attack=50, ['magic accuracy']=60},
    [6261] = {hp=30, vit=4, accuracy={11,54}, attack={17,54}, ['ranged accuracy']={11,54}, ['ranged attack']={17,54}},
    [6458] = {hp=50, str=5, vit=5, agi=3, attack={10,170}, ['ranged attack']={10,170}},
    [6459] = {hp=55, str=6, vit=6, agi=4, attack={11,175}, ['ranged attack']={11,175}},
    [6567] = {['int']=2, mnd=2, ['magic accuracy']={20,90}},
    [5759] = {hp=25, str=7, agi=1, ['int']=-2, attack={23,150}, ['ranged attack']={23,150}},
    [5757] = {hp=20, str=5, agi=2, ['int']=-4, attack={20,75}, ['ranged attack']={20,75}},
    [5763] = {hp=30, str=5, vit=2, agi=3, ['int']=-2, attack={22,85}, ['ranged attack']={22,85}},
}

-- Returns flat-stat additions from the active sim food, or empty table
-- if no food. Keys are canonical OmniWatch stat names so the caller
-- can add them directly to stats[]. `base` is the caller's pre-food
-- stats table (e.g. the `stats` table mid-compute); percent foods read
-- their base value from it. Pass {} (or nil) and percent foods resolve
-- to 0 (no base to take a percent of).
function M.get_food_stats(base)
    local fid = _ow_sim_state.food
    if not fid then return {} end
    local entry = _FOOD_STATS[fid]
    if not entry then return {} end
    base = base or {}
    local out = {}
    for k, v in pairs(entry) do
        if type(v) == 'table' then
            -- {pct, cap}: percent of the pre-food base stat, capped.
            local pct = v[1] or 0
            local cap = v[2]
            local b   = base[k] or 0
            local bonus = math.floor(b * pct / 100)
            if cap and bonus > cap then bonus = cap end
            out[k] = bonus
        else
            out[k] = v   -- flat add
        end
    end
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

    -- GearSwap slot-name mapping. The sim stores slots as left_ear /
    -- right_ear / left_ring / right_ring; GearSwap sets conventionally
    -- use ear1/ear2/ring1/ring2, which is the form shown in gear files.
    local GS_SLOT = {
        main = 'main', sub = 'sub', range = 'range', ammo = 'ammo',
        head = 'head', neck = 'neck',
        left_ear = 'ear1', right_ear = 'ear2',
        body = 'body', hands = 'hands',
        left_ring = 'ring1', right_ring = 'ring2',
        back = 'back', waist = 'waist', legs = 'legs', feet = 'feet',
    }
    -- Quote an augment string the GearSwap way: single quotes so inner
    -- stat names that carry double quotes (e.g. '"Store TP"+10') read
    -- cleanly. If an augment itself contains a single quote (rare), fall
    -- back to Lua's %q double-quoted escaping so the file still loads.
    local function quote_aug(s)
        s = tostring(s)
        if not s:find("'", 1, true) then
            return "'" .. s .. "'"
        end
        return string.format('%q', s)
    end
    -- Decode the augment strings for an item instance at (bag, idx) via
    -- Windower's extdata library. Returns a list of clean augment strings
    -- (empty when the item has none or decode is unavailable). Guarded so
    -- a missing lib / bad slot never aborts the export — we just emit the
    -- item name-only for that slot.
    local function read_augments(id, bag, idx)
        local out = {}
        if not (bag and idx) then return out end
        local ok, decoded = pcall(function()
            local extdata = require('extdata')
            local item = windower.ffxi.get_items(bag, idx)
            if item and item.id == id then
                return extdata.decode(item)
            end
            return nil
        end)
        if ok and decoded and type(decoded.augments) == 'table' then
            for _, a in ipairs(decoded.augments) do
                if a and a ~= '' and a ~= 'none' then
                    out[#out + 1] = a
                end
            end
        end
        return out
    end

    local slot_order = {
        'main', 'sub', 'range', 'ammo',
        'head', 'neck', 'left_ear', 'right_ear',
        'body', 'hands', 'left_ring', 'right_ring',
        'back', 'waist', 'legs', 'feet',
    }
    local lines = {}
    table.insert(lines, '-- OmniWatch sim export — ' .. os.date('%Y-%m-%d %H:%M:%S'))
    table.insert(lines, '-- Paste this into your gearswap file or rename "exported"')
    table.insert(lines, '-- to whatever set name you want (e.g. sets.engaged.DT.HighHaste).')
    table.insert(lines, 'sets.exported = {')
    for _, slot in ipairs(slot_order) do
        local ref = eq[slot]
        -- Resolve the slot's item id + (bag, idx) from the stored ref.
        -- ref may be: a {id,bag,idx} instance table, a legacy id int, or
        -- 0 / nil (empty / unset → omitted from the export).
        local id, bag, idx
        if type(ref) == 'table' then
            id  = ref.id or 0
            bag = ref.bag
            idx = ref.idx
        elseif type(ref) == 'number' then
            id = ref
        end
        if id and id > 0 then
            local res_ok, item = pcall(function()
                return res and res.items and res.items[id]
            end)
            local name = (res_ok and item and (item.en or item.enl)) or ('item:' .. id)
            local gs_slot = GS_SLOT[slot] or slot
            local augs = read_augments(id, bag, idx)
            if #augs > 0 then
                local parts = {}
                for _, a in ipairs(augs) do parts[#parts + 1] = quote_aug(a) end
                table.insert(lines, string.format(
                    '    %s={name=%q, augments={%s,}},',
                    gs_slot, name, table.concat(parts, ',')))
            else
                table.insert(lines, string.format('    %s=%q,', gs_slot, name))
            end
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

-- ─── Set import ─────────────────────────────────────────────────────────────
-- Pull a named gear set out of an arbitrary GearSwap gear file and load it
-- into the sim's equipment, regardless of the player's current job. Because
-- GearSwap sets are CODE (set_combine, gear.* refs, the `empty` token,
-- nested tables built inside init_gear_sets()), we can't just text-parse the
-- file — we execute it in a sandbox with stubs for the GearSwap globals,
-- then walk the dotted set path (e.g. "sets.engaged.HighHaste") into the
-- resolved table.
--
-- filepath : absolute path to the gear .lua file (chosen in the overlay).
-- setpath  : dotted set path, with or without a leading "sets."
--            ("sets.engaged.HighHaste" or "engaged.HighHaste" both work).

-- Map GearSwap slot names → the sim's slot keys.
local _SIM_SLOT_ALIASES = {
    ear1 = 'left_ear',  ear2 = 'right_ear',
    lear = 'left_ear',  rear = 'right_ear',
    ring1 = 'left_ring', ring2 = 'right_ring',
    lring = 'left_ring', rring = 'right_ring',
    -- pass-throughs (already match): main, sub, range, ammo, head, neck,
    -- body, hands, back, waist, legs, feet, left_ear, right_ear,
    -- left_ring, right_ring.
}
local _SIM_VALID_SLOTS = {
    main=true, sub=true, range=true, ammo=true, head=true, neck=true,
    left_ear=true, right_ear=true, body=true, hands=true,
    left_ring=true, right_ring=true, back=true, waist=true,
    legs=true, feet=true,
}

-- Build (or reuse) a lowercase item-name → id index from res.items.
local _sim_name_to_id = nil
local function _sim_build_name_index()
    if _sim_name_to_id then return _sim_name_to_id end
    _sim_name_to_id = {}
    if res and res.items then
        for id, it in pairs(res.items) do
            local n = it.en or it.enl
            if n then _sim_name_to_id[n:lower()] = id end
            if it.enl then _sim_name_to_id[it.enl:lower()] = id end
        end
    end
    return _sim_name_to_id
end

-- Resolve an item reference (string name, or a {name=,augments=} table, or a
-- stub value) to a numeric item id. Returns 0 if unresolvable.
local function _sim_ref_to_id(ref)
    if ref == nil then return 0 end
    local name = nil
    if type(ref) == 'string' then
        name = ref
    elseif type(ref) == 'table' then
        name = ref.name or ref.en or ref.enl
    end
    if not name or name == '' then return 0 end
    local idx = _sim_build_name_index()
    return idx[tostring(name):lower()] or 0
end

-- Build the sandbox environment for running a gear file.
local function _sim_make_sandbox()
    -- Auto-vivifying table: any nested access creates an empty sub-table,
    -- so `sets.engaged.HighHaste = {...}` and `gear.da.body` both work
    -- without the real globals being present.
    local function autoviv()
        local t = {}
        setmetatable(t, {
            __index = function(self, k)
                local v = autoviv()
                rawset(self, k, v)
                return v
            end,
        })
        return t
    end

    local env = {}
    -- Core Lua libs the file may touch.
    env._G = env
    env.pairs = pairs; env.ipairs = ipairs; env.type = type
    env.tostring = tostring; env.tonumber = tonumber
    env.table = table; env.string = string; env.math = math
    env.pcall = pcall; env.select = select; env.next = next
    env.setmetatable = setmetatable; env.rawget = rawget; env.rawset = rawset
    env.print = function() end

    -- GearSwap globals the gear file relies on.
    env.sets = autoviv()
    env.gear = autoviv()
    -- `empty` is GearSwap's "explicitly unequip" sentinel; represent as a
    -- table we recognize as empty when resolving.
    env.empty = { __ow_empty = true }
    -- set_combine(a, b, ...) merges left-to-right (later wins), shallow.
    env.set_combine = function(...)
        local out = {}
        for _, tbl in ipairs({...}) do
            if type(tbl) == 'table' then
                for k, v in pairs(tbl) do out[k] = v end
            end
        end
        return out
    end
    -- Mote state/list constructors → tolerant no-op stubs. A single
    -- universal stub object that is callable and indexable any number of
    -- levels deep, so M(...)/S{...}/state.X:set() etc. never error.
    local stub_obj
    stub_obj = setmetatable({}, {
        __index = function() return stub_obj end,
        __call  = function() return stub_obj end,
        __concat = function() return '' end,
    })
    env.M = function() return stub_obj end
    env.S = function() return stub_obj end
    env.T = function() return stub_obj end
    env.L = function() return stub_obj end
    -- Common GearSwap funcs that gear files sometimes call at set-build time.
    env.include = function() end
    env.get_sets = function() end
    env.add_to_chat = function() end
    env.windower = setmetatable({}, {__index = function() return function() end end})
    env.player = setmetatable({}, {__index = function() return '' end})
    env.world  = setmetatable({}, {__index = function() return '' end})
    env.res = res   -- let the file read resources if it wants
    -- Anything else the file references globally resolves to the tolerant
    -- stub instead of nil (prevents "attempt to index nil").
    setmetatable(env, {
        __index = function()
            return stub_obj
        end,
    })
    return env
end

-- Walk a dotted path ("sets.engaged.HighHaste") into a table. Returns the
-- value or nil. Tolerant of a leading "sets." (the sandbox's top table IS
-- `sets`, so we strip a leading "sets." segment).
local function _sim_walk_path(root_sets, setpath)
    local p = tostring(setpath or ''):gsub('%s+', '')
    -- Strip a leading "sets." if present.
    p = p:gsub('^sets%.', '')
    if p == '' then return nil end
    local node = root_sets
    for seg in p:gmatch('[^%.]+') do
        if type(node) ~= 'table' then return nil end
        -- Support bracket-quoted segments like ['Blade: Jin'] written as
        -- Blade: Jin in the path (rare; users typically type dotted).
        node = rawget(node, seg)
        if node == nil then return nil end
    end
    return node
end

function M.import_set(filepath, setpath)
    if not filepath or filepath == '' then
        windower.add_to_chat(123, '[OW/Sim] import: no file path given.')
        return false
    end
    if not setpath or setpath == '' then
        windower.add_to_chat(123, '[OW/Sim] import: no set path given.')
        return false
    end

    -- Read + load the file under the sandbox env.
    local chunk, lerr
    if loadfile then
        chunk, lerr = loadfile(filepath)
    end
    if not chunk then
        -- Fallback: read bytes and loadstring (handles odd path cases).
        local f = io.open(filepath, 'r')
        if not f then
            windower.add_to_chat(123,
                '[OW/Sim] import: cannot open file: ' .. tostring(filepath))
            return false
        end
        local body = f:read('*a'); f:close()
        chunk, lerr = loadstring(body, '@' .. filepath)
        if not chunk then
            windower.add_to_chat(123,
                '[OW/Sim] import: parse error: ' .. tostring(lerr))
            return false
        end
    end

    local env = _sim_make_sandbox()
    setfenv(chunk, env)
    local ok_run, run_err = pcall(chunk)
    if not ok_run then
        windower.add_to_chat(123,
            '[OW/Sim] import: file error: ' .. tostring(run_err))
        return false
    end

    -- Most gear files build sets inside init_gear_sets() (and sometimes
    -- user_setup/user_job_setup). Call whatever exists, in a sane order,
    -- each guarded so a missing dependency doesn't abort the whole import.
    for _, fn_name in ipairs({'user_setup', 'job_setup', 'user_job_setup',
                              'get_sets', 'init_gear_sets',
                              'job_init_gear_sets', 'init_sets'}) do
        local fn = rawget(env, fn_name)
        if type(fn) == 'function' then
            pcall(fn)
        end
    end

    local set = _sim_walk_path(env.sets, setpath)
    if type(set) ~= 'table' then
        windower.add_to_chat(123, string.format(
            '[OW/Sim] import: set "%s" not found in %s',
            tostring(setpath), tostring(filepath:match('[^/\\]+$') or filepath)))
        return false
    end

    -- Translate the resolved set into sim equipment. Clear existing sim
    -- equipment first so the imported set fully replaces it.
    _ow_sim_state.equipment = {}
    local applied, skipped = 0, 0
    for raw_slot, ref in pairs(set) do
        local sk = tostring(raw_slot):lower()
        sk = _SIM_SLOT_ALIASES[sk] or sk
        if _SIM_VALID_SLOTS[sk] then
            -- `empty` sentinel → explicit empty (id 0).
            if type(ref) == 'table' and ref.__ow_empty then
                _ow_sim_state.equipment[sk] = 0
                applied = applied + 1
            else
                local iid = _sim_ref_to_id(ref)
                if iid > 0 then
                    _ow_sim_state.equipment[sk] = iid
                    applied = applied + 1
                else
                    skipped = skipped + 1
                end
            end
        end
    end

    windower.add_to_chat(207, string.format(
        '[OW/Sim] imported "%s": %d slots applied%s',
        tostring(setpath), applied,
        (skipped > 0) and (', ' .. skipped .. ' unresolved') or ''))
    return true
end

return M