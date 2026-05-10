-- BRD gear tables (Song+ levels, duration percentages).
--
-- Companion to gearinfo/res/Bard_Songs.lua. The song potency data lives
-- in Bard_Songs.lua (GearInfo-native shape, id-keyed). This file holds
-- OmniWatch-specific gear tables that GearInfo's data model doesn't
-- cover: instrument/armor → Song+ levels, duration multipliers, and
-- song-class-specific duration bonuses.
--
-- Schema (returned table M):
--   M.song_plus = {            -- gear name → {family=N, all=N}
--       ["Gjallarhorn"]   = {all = 4},
--       ["Fili Hongreline"] = {minuet = 1},
--       ...
--   }
--   M.duration  = {            -- gear name → fractional duration bonus
--       ["Carnwenhan"]    = 0.50,
--       ...
--   }
--   M.duration_by_class = {    -- song-class → {gear name → fractional bonus}
--       Madrigal = { ["Fili Calot"] = 0.10, ... },
--       ...
--   }
--
-- OmniWatch's stat / duration helpers read from this file via the
-- adapter at OmniWatch.lua's data-load block.

local M = {}

-- ── Gear that grants Song+ levels ─────────────────────────────
M.song_plus = {
    -- ── Instruments (range slot) ──────────────────────────────────────
    -- Gjallarhorn (Relic horn): All Songs +2 base, scaling to +4 at 99
    ['Gjallarhorn']        = {all = 4},
    -- Loughnashade (Aeonic horn): All Songs +2 base, scaling to +4
    ['Loughnashade']       = {all = 4},
    -- Marsyas (Aeonic horn): NO Song+ bonus. Only adds Honor March to
    -- spell list and gives song duration. Listed here as 0 to document.
    -- Linos (augmentable): Song +1 to +3 — depends on augment, default +1
    ['Linos']              = {all = 1},
    -- Langeleik: Song +3
    ['Langeleik']          = {all = 3},
    -- Various +2 instruments
    ['Nibiru Harp']        = {all = 2},
    ['Blurred Harp +1']    = {all = 2},
    ['Eminent Flute']      = {all = 2},
    ['Iron Ram Horn']      = {all = 2},
    ['Faerie Piccolo']     = {all = 2},
    -- Various +1 instruments
    ['Blurred Harp']            = {all = 1},
    ["San d'Orian Horn"]        = {all = 1},
    ['Kingdom Horn']            = {all = 1},
    ["Royal Spearman's Horn"]   = {all = 1},

    -- ── Neck (Whistles) ───────────────────────────────────────────────
    -- Moonbow Whistle line — confirmed BG-wiki: NQ +2, +1 (HQ) +3
    ['Moonbow Whistle']    = {all = 2},
    ['Moonbow Whistle +1'] = {all = 3},
    ['Mnbw. Whistle']      = {all = 2},  -- abbreviated form Windower may emit
    ['Mnbw. Whistle +1']   = {all = 3},
    ['Brioso Whistle']     = {all = 1},

    -- ── Hands (Manchettes — March family) ─────────────────────────────
    -- Fili Manchettes line: ALL tiers grant "March" +1 (does NOT scale
    -- with HQ tier — confirmed via Guildwork item DB).
    ['Fili Manchettes']    = {marches = 1},
    ['Fili Manchettes +1'] = {marches = 1},
    ['Fili Manchettes +2'] = {marches = 1},
    ['Fili Manchettes +3'] = {marches = 1},
    ["Aoidos' Manchettes +2"] = {marches = 1},

    -- ── Other song-specific gear (head/body/legs/feet) ─────────────────
    -- Fili Calot line: "Madrigal" +1 (not marches)
    ['Fili Calot']         = {madrigal = 1},
    ['Fili Calot +1']      = {madrigal = 1},
    ['Fili Calot +2']      = {madrigal = 1},
    ['Fili Calot +3']      = {madrigal = 1},
    -- Fili Hongreline line: "Minuet" +1
    ['Fili Hongreline']    = {minuet = 1},
    ['Fili Hongreline +1'] = {minuet = 1},
    ['Fili Hongreline +2'] = {minuet = 1},
    ['Fili Hongreline +3'] = {minuet = 1},
    -- Fili Rhingrave line: "Ballad" +1 (legs)
    ['Fili Rhingrave']     = {ballad = 1},
    ['Fili Rhingrave +1']  = {ballad = 1},
    ['Fili Rhingrave +2']  = {ballad = 1},
    ['Fili Rhingrave +3']  = {ballad = 1},
    -- Fili Cothurnes line: "Prelude" +1 (feet)
    ['Fili Cothurnes']     = {prelude = 1},
    ['Fili Cothurnes +1']  = {prelude = 1},
    ['Fili Cothurnes +2']  = {prelude = 1},
    ['Fili Cothurnes +3']  = {prelude = 1},

    -- ── Brioso pieces (WHM AF reforge, also used by BRD) ──────────────
    -- These print song-specific +N on the item itself. Per the comment
    -- in duration_by_class below: "Brioso reforge tiers DO progress in
    -- song+ (unlike Fili)" — Brioso Cuffs +3 prints Lullaby +2 (vs +1
    -- on lower tiers). Roundlet line follows the same pattern.
    -- Levels here mirror the 0.10/0.20 values already encoded in
    -- duration_by_class (where 0.10 = +1, 0.20 = +2).
    ['Brioso Roundlet']    = {paeon = 1},
    ['Brioso Roundlet +1'] = {paeon = 1},
    ['Brioso Roundlet +2'] = {paeon = 1},
    ['Brioso Roundlet +3'] = {paeon = 2},
    ['Brioso Cuffs']       = {lullaby = 1},
    ['Brioso Cuffs +1']    = {lullaby = 1},
    ['Brioso Cuffs +2']    = {lullaby = 1},
    ['Brioso Cuffs +3']    = {lullaby = 2},

    -- ── Mousai pieces (RDM AF reforge, also used by BRD) ──────────────
    -- All five Mousai pieces print "<Family> +1" at NQ and "<Family>
    -- +2" at +1 (per Community Bard Guide / verified item DBs).
    -- Mousai Gages: Carol+
    ['Mousai Gages']       = {carol = 1},
    ['Mousai Gages +1']    = {carol = 2},
    -- Mousai Turban: Etude+
    ['Mousai Turban']      = {etude = 1},
    ['Mousai Turban +1']   = {etude = 2},
    -- Mousai Manteel: Threnody+ (note: not in song_bonus families since
    -- threnodies are debuffs cast on enemies, not buffs on us — kept
    -- here for completeness; settings.Bards.song_bonus may not include
    -- a 'threnody' key, in which case this is harmless dead data).
    ['Mou. Manteel']       = {threnody = 1},
    ['Mousai Manteel']     = {threnody = 1},
    ['Mousai Manteel +1']  = {threnody = 2},
    -- Mousai Crackows: Mambo+
    ['Mousai Crackows']    = {mambo = 1},
    ['Mousai Crackows +1'] = {mambo = 2},
    -- Mousai Seraweels: Minne+
    ['Mousai Seraweels']   = {minne = 1},
    ['Mousai Seraweels +1'] = {minne = 2},
}

-- ── Gear that adds song duration as a multiplier ──────────────
M.duration = {
    -- ── Main / sub (daggers, instruments) ──────────────────────────
    -- Carnwenhan Mythic (the value depends on iLvl: 75 = 10%,
    -- 95 = 40%, 99/119 = 50%). We assume endgame; if a player has
    -- the older version active they'll get a slight overestimate.
    ["Carnwenhan"]              = 0.50,
    ["Kali"]                    = 0.05,   -- main OR sub
    ["Legato Dagger"]           = 0.05,   -- main OR sub
    -- ── Range (instruments) ────────────────────────────────────────
    -- Per BG-wiki Category:Song: "All Songs +N" gear converts to N×10%
    -- duration. So Gjallarhorn's "All Songs +4" = +40% duration. The
    -- explicit numbers below combine the duration text on the item
    -- (where present) and the All-Songs+N → 10% conversion.
    ["Marsyas"]                 = 0.50,   -- Aeonic horn: "Song dur. +50%"
                                          -- (also +1 Honor March potency)
    ["Gjallarhorn"]             = 0.40,   -- Relic horn: "All Songs +4"
                                          -- (also +4 potency on every song)
    ["Loughnashade"]            = 0.40,   -- "All Songs +4"
    ["Daurdabla"]               = 0.30,   -- "All Songs +3" (Maraca-class)
    ["Terpander"]               = 0.10,   -- "All Songs +1"
    ["Blurred Harp +1"]         = 0.10,   -- "All Songs +1"
    -- Linos with Snowdim Stones can have All Songs +1/+2/+3 augments;
    -- since augmented values aren't visible from name alone, users with
    -- a Linos-based duration set can hand-add their own row, e.g.:
    --   ["Linos"] = 0.30, -- if augmented to All Songs +3
    -- ── Sub (grip) ─────────────────────────────────────────────────
    ["Ammurapi Shield"]         = 0.05,   -- BRD/SCH grip, "Song dur. +5%"
    -- ── Neck ───────────────────────────────────────────────────────
    ["Aoidos' Matinee"]         = 0.10,
    ["Moonbow Whistle"]         = 0.20,
    ["Mnbw. Whistle +1"]        = 0.30,   -- Windower's truncated form
    ["Moonbow Whistle +1"]      = 0.30,   -- in case res returns long form
    -- ── Body ───────────────────────────────────────────────────────
    -- Inyanga Jubbah (Sortie reforge, RUN/SCH/BRD/etc.). The "Song
    -- duration +X%" comes from text on the item itself.
    -- VERIFIED via FFXIclopedia / BG-wiki:
    ["Inyanga Jubbah"]          = 0.09,   -- Song eff. dur. +9% (NQ)
    ["Inyanga Jubbah +1"]       = 0.11,
    ["Inyanga Jubbah +2"]       = 0.13,
    ["Inyanga Jubbah +3"]       = 0.15,
    -- Fili Hongreline (BRD AF reforge). VERIFIED ffxidb.com / fandom:
    --   NQ:  Minuet+1, Song eff. dur. +11%
    --   +1:  Minuet+1, Song eff. dur. +12%
    --   +2:  Minuet+1, Song eff. dur. +13%
    --   +3:  Minuet+1, Song eff. dur. +14%
    -- Note: the "Minuet+1" portion lives in OW_SONG_SPECIFIC_GEAR
    -- below since it only applies to Minuets; the "all-songs %"
    -- portion applies universally and lives here.
    ["Fili Hongreline"]         = 0.11,
    ["Fili Hongreline +1"]      = 0.12,
    ["Fili Hongreline +2"]      = 0.13,
    ["Fili Hongreline +3"]      = 0.14,
    ["Aoidos' Hngrln. +2"]      = 0.05,   -- per fandom: "duration +5%"
    ["Aoidos' Hongreline +2"]   = 0.05,
    -- ── Legs ───────────────────────────────────────────────────────
    ["Marduk's Shalwar"]        = 0.08,
    ["Marduk's Shalwar +1"]     = 0.10,
    ["Mdk. Shalwar +1"]         = 0.10,   -- Windower truncation
    ["Inyanga Shalwar"]         = 0.13,
    ["Inyanga Shalwar +1"]      = 0.15,
    ["Inyanga Shalwar +2"]      = 0.17,
    ["Inyanga Shalwar +3"]      = 0.19,
    -- ── Feet ───────────────────────────────────────────────────────
    ["Brioso Slippers"]         = 0.10,
    ["Brioso Slippers +1"]      = 0.11,
    ["Brioso Slippers +2"]      = 0.13,
    ["Brioso Slippers +3"]      = 0.15,
    -- Note: Brioso Roundlet / Justaucorps / Cuffs / Cannions carry
    -- song-SPECIFIC bonuses (Paeon+, Lullaby+, etc.) → those are in
    -- OW_SONG_SPECIFIC_GEAR below, not in this all-songs table.
    -- Note: Aoidos' Calot / Cothurnes / Manchettes / Rhingrave +2 carry
    -- song-specific bonuses; those are also in OW_SONG_SPECIFIC_GEAR.
    -- 1200 JP gift bonus (handled separately, not gear)
}

-- ── Gear that adds duration only for a specific song class ────
M.duration_by_class = {
    -- Madrigal (head: Fili Calot; back: Intarabus's Cape Madrigal+ aug)
    Madrigal = {
        -- Fili Calot line all print "Madrigal +1" (verified all 4 tiers):
        ["Fili Calot"]          = 0.10,
        ["Fili Calot +1"]       = 0.10,
        ["Fili Calot +2"]       = 0.10,
        ["Fili Calot +3"]       = 0.10,
        ["Aoidos' Calot +2"]    = 0.10,   -- "Madrigal +1" (verified)
        -- Intarabus's Cape with the right augment line gives Madrigal+1
        -- AND/OR Prelude+1; users who have this should hand-add a key
        -- by literal item name (Windower can't see augment text):
        --   ["Intarabus's Cape"] = 0.10, -- if augmented Madrigal+1
        -- (commented out by default since not all augments include it)
    },
    -- Minuet (body: Fili Hongreline / Aoidos)
    Minuet = {
        -- Verified: Fili Hongreline NQ/+1/+2/+3 ALL print "Minuet +1".
        ["Fili Hongreline"]     = 0.10,
        ["Fili Hongreline +1"]  = 0.10,
        ["Fili Hongreline +2"]  = 0.10,
        ["Fili Hongreline +3"]  = 0.10,
        ["Aoidos' Hngrln. +2"]  = 0.10,   -- "Minuet +1" (verified)
        ["Aoidos' Hongreline +2"] = 0.10,
    },
    -- March (hands: Fili Manchettes)
    March = {
        ["Fili Manchettes"]     = 0.10,
        ["Fili Manchettes +1"]  = 0.10,
        ["Fili Manchettes +2"]  = 0.10,
        -- Per Community Bard Guide: "Fili Manchettes +3 gives +1 to
        -- March". So +3 prints March+1 same as lower tiers — NOT +3.
        ["Fili Manchettes +3"]  = 0.10,
        ["Ad. Mnchtte. +2"]     = 0.10,
        -- Marsyas adds Honor March *potency*, not duration; not here.
    },
    -- Ballad (legs: Fili Rhingrave)
    Ballad = {
        ["Fili Rhingrave"]      = 0.10,
        ["Fili Rhingrave +1"]   = 0.10,
        ["Fili Rhingrave +2"]   = 0.10,
        ["Fili Rhingrave +3"]   = 0.10,
        ["Aoidos' Rhing. +2"]   = 0.10,
    },
    -- Paeon (head: Brioso Roundlet)
    Paeon = {
        ["Brioso Roundlet"]     = 0.10,
        ["Brioso Roundlet +1"]  = 0.10,
        -- NOTE: Brioso reforge tiers DO progress in song+ (unlike Fili).
        -- Verified: Brioso Cuffs +3 prints "Lullaby +2" (vs +1 on NQ/+1).
        -- Brioso +2 likely +1, +3 likely +2 (matches Sammeh's gearswap).
        ["Brioso Roundlet +2"]  = 0.10,
        ["Brioso Roundlet +3"]  = 0.20,
    },
    -- Lullaby (hands: Brioso Cuffs)
    Lullaby = {
        ["Brioso Cuffs"]        = 0.10,   -- "Lullaby +1" (verified)
        ["Brioso Cuffs +1"]     = 0.10,   -- "Lullaby +1" (verified)
        ["Brioso Cuffs +2"]     = 0.10,   -- (estimate; likely Lullaby+1)
        ["Brioso Cuffs +3"]     = 0.20,   -- "Lullaby +2" (verified)
    },
    -- Mambo (feet: Mousai Crackows / Brioso?)
    Mambo = {
        ["Mousai Crackows"]     = 0.10,
        ["Mousai Crackows +1"]  = 0.20,   -- "Mambo +2" (per Community Bard Guide)
    },
    -- Threnody (body: Mousai Manteel)
    Threnody = {
        ["Mou. Manteel"]        = 0.10,   -- "Threnody +1" (typical NQ)
        ["Mousai Manteel"]      = 0.10,
        ["Mousai Manteel +1"]   = 0.20,   -- "Threnody +2" (per Community Bard Guide)
    },
    -- Carol (hands: Mousai Gages)
    Carol = {
        ["Mousai Gages"]        = 0.10,
        ["Mousai Gages +1"]     = 0.20,   -- "Carol +2" (per Community Bard Guide)
    },
    -- Etude (head: Mousai Turban)
    Etude = {
        ["Mousai Turban"]       = 0.10,
        ["Mousai Turban +1"]    = 0.20,   -- "Etude +2" (per Community Bard Guide)
    },
    -- Minne (legs: Mousai Seraweels). VERIFIED missing from old table —
    -- this is why Knight's Minne IV was falling back to 120s before.
    Minne = {
        ["Mousai Seraweels"]    = 0.10,
        ["Mousai Seraweels +1"] = 0.20,   -- "Minne +2" (per Community Bard Guide)
    },
    -- Scherzo (feet: Fili Cothurnes — Sentinel's Scherzo only)
    Scherzo = {
        ["Fili Cothurnes"]      = 0.10,
        ["Fili Cothurnes +1"]   = 0.10,
        ["Fili Cothurnes +2"]   = 0.10,
        ["Fili Cothurnes +3"]   = 0.10,
    },
    -- Prelude (back: Intarabus's Cape Prelude+ augment)
    Prelude = {
        -- Cape augment Prelude+1 same caveat as Madrigal augment.
        --   ["Intarabus's Cape"] = 0.10, -- if augmented Prelude+1
    },
}

return M