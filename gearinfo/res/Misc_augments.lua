-- ═══════════════════════════════════════════════════════════════════════════
-- Misc_augments.lua  —  Gear augment overlay table
--
-- This file is the home for items whose max-rank augments aren't carried in
-- the in-game item description text. The description-text parser reads only
-- what's literally on the item; pieces with hidden / hard-coded augments
-- (most JSE necks, Sortie/Reisenjima accessories at certain ranks, gear that
-- ships with no augment text but has community-known max-rank values) need
-- their augments listed here so OmniWatch can fold them into the stats panel.
--
-- ── Schema ────────────────────────────────────────────────────────────────
-- A flat table keyed by item_id. Each value is a list of augment strings
-- in the same format you'd see on the item description text:
--
--   [<item_id>] = { 'STR+15', '"Triple Attack"+5', 'HP+75', ... },
--
-- Each string is fed through ow_parse_desc_line, which handles:
--   • Plain stat lines:           'Attack+30', 'STR+5', 'HP+50'
--   • Mag. abbreviations:         'Mag. Acc.+15', 'Magic Damage+30'
--   • Quoted-name stats:          '"Triple Attack"+5', '"Subtle Blow"+15'
--   • Percent stats:              'Quadruple Attack +3%', 'Double Attack+5'
--   • Negative values:            'Enmity-5', 'Damage taken-10%'
--   • Compound names:             '"Subtle Blow II"+10', 'Magic Burst Damage+8'
--
-- Stats integrated into the OmniWatch panel (cell map at OmniWatch.lua
-- line ~8284). Confirmed parser pass-through includes:
--   STR/DEX/VIT/AGI/INT/MND/CHR, HP, MP
--   Attack, Accuracy, Mag. Acc., Mag. Atk. Bns., Magic Damage
--   Defense, Evasion, Magic Evasion
--   Double Attack, Triple Attack, Quadruple Attack
--   Critical Hit Rate, Store TP
--   Subtle Blow, Subtle Blow II, Dual Wield
--   Fast Cast, Quick Magic, Haste
--   Damage Taken (PDT/MDT/BDT split applied)
--   Regen, Refresh
--
-- Stats parsed but not currently displayed (kept for documentation / forward
-- compatibility — they accumulate in the stats dict harmlessly):
--   Daken, Wyvern: stats, Helix effect duration, Luopan: stats,
--   Kick Attacks, Physical Damage Limit, Magic Burst Damage,
--   Magic Burst Accuracy, Avatar/Automaton/Pet stats
--
-- ── Source priority ───────────────────────────────────────────────────────
-- For each equipped item, OmniWatch's gear-walk applies augment values in
-- this order:
--
--   1. extdata.decode → augments        (most accurate; works for Odyssey,
--                                        most augmented Reisenjima/Sortie
--                                        gear, anything with a binary
--                                        extdata blob)
--   2. Unity_rank[id].augments          (per-rank Unity Concord items —
--                                        Sailfi Belt +1, Cohort Cloak +1,
--                                        etc., scaled by player.rank)
--   3. Misc_augments[id]  ← this file   (everything else with hidden /
--                                        hard-coded augments where extdata
--                                        doesn't return useful strings)
--
-- Step 1 handles most augmented gear without any local data needed. Step 2
-- handles Unity items that scale by player rank. Step 3 (this file) is the
-- catchall for the remainder — JSE necks were the original use case and
-- still the bulk of the table.
--
-- ── How to add a new entry ────────────────────────────────────────────────
-- 1. Find the item_id (windower res.items, or Find Item Online tools).
-- 2. Get the max-rank augment list from BG-wiki — use the literal text
--    SE shows, not paraphrased. Examples that work:
--       'STR+15'                            -- standard stat+N
--       '"Triple Attack"+5'                 -- quoted name + integer
--       'Quadruple Attack +3%'              -- spaced + percent
--       'Mag. Acc.+15'                      -- abbreviation, no space
--       'Magic Burst Damage+8'              -- multi-word, no space
--       'Damage taken-10%'                  -- negative + percent
-- 3. Add a one-line `-- <Item Name> (<Job>, R<rank>)` comment above the
--    entry so future readers don't need a second monitor open.
-- 4. Wear the item, run `//ow dumpgear <slot>` and verify the parser
--    extracted what you expect.
--
-- ═══════════════════════════════════════════════════════════════════════════

return {

    -- ─── JSE Necks ────────────────────────────────────────────────────────
    -- Reisenjima ambuscade currency / Sortie. 22 jobs × 3 tiers each
    -- (NQ R15 / +1 R20 / +2 R25). Names match items.lua 'en' field. The
    -- base description carries Acc/M.Acc/etc; the augments below are the
    -- per-rank max bonuses from BG-wiki's 'Maximum Augments' columns.

    -- Warrior's Beads (WAR, R15)
    [25417] = { 'HP+50', 'STR+10', 'DEX+10', 'Double Attack+5' },
    -- Warrior's Beads +1 (WAR, R20)
    [25418] = { 'HP+75', 'STR+12', 'DEX+12', 'Double Attack+6' },
    -- Warrior's Beads +2 (WAR, R25)
    [25419] = { 'HP+100', 'STR+15', 'DEX+15', 'Double Attack+7' },

    -- Monk's Nodowa (MNK, R15)
    [25423] = { 'DEX+10', 'MND+10', 'Kick Attacks+15',
                'Physical Damage Limit+6' },
    -- Monk's Nodowa +1 (MNK, R20)
    [25424] = { 'DEX+12', 'MND+12', 'Kick Attacks+20',
                'Physical Damage Limit+8' },
    -- Monk's Nodowa +2 (MNK, R25)
    [25425] = { 'DEX+15', 'MND+15', 'Kick Attacks+25',
                'Physical Damage Limit+10' },

    -- Cleric's Torque (WHM, R15)
    [25429] = { 'INT+10', 'MND+10', 'Enmity-15', 'Fast Cast+6' },
    -- Cleric's Torque +1 (WHM, R20)
    [25430] = { 'INT+12', 'MND+12', 'Enmity-20', 'Fast Cast+8' },
    -- Cleric's Torque +2 (WHM, R25)
    [25431] = { 'INT+15', 'MND+15', 'Enmity-25', 'Fast Cast+10' },

    -- Sorcerer's Stole (BLM, R15)
    [25435] = { 'INT+10', 'MND+10', 'Magic Burst Damage+6',
                'Magic Burst Accuracy+15' },
    -- Sorcerer's Stole +1 (BLM, R20)
    [25436] = { 'INT+12', 'MND+12', 'Magic Burst Damage+8',
                'Magic Burst Accuracy+20' },
    -- Sorcerer's Stole +2 (BLM, R25)
    [25437] = { 'INT+15', 'MND+15', 'Magic Burst Damage+10',
                'Magic Burst Accuracy+25' },

    -- Duelist's Torque (RDM, R15)
    [25441] = { 'INT+10', 'MND+10', 'Enhancing Magic effect duration+15',
                'Enfeebling Magic effect duration+15' },
    -- Duelist's Torque +1 (RDM, R20)
    [25442] = { 'INT+12', 'MND+12', 'Enhancing Magic effect duration+20',
                'Enfeebling Magic effect duration+20' },
    -- Duelist's Torque +2 (RDM, R25)
    [25443] = { 'INT+15', 'MND+15', 'Enhancing Magic effect duration+25',
                'Enfeebling Magic effect duration+25' },

    -- Assassin's Gorget (THF, R15)
    [25447] = { 'DEX+10', 'AGI+10', 'Evasion+15', 'Triple Attack+2' },
    -- Assassin's Gorget +1 (THF, R20)
    [25448] = { 'DEX+12', 'AGI+12', 'Evasion+20', 'Triple Attack+3' },
    -- Assassin's Gorget +2 (THF, R25)
    [25449] = { 'DEX+15', 'AGI+15', 'Evasion+25', 'Triple Attack+4' },

    -- Knight's Beads (PLD, R15)
    [25453] = { 'HP+30', 'VIT+10', 'MND+10', 'Damage taken-5' },
    -- Knight's Beads +1 (PLD, R20)
    [25454] = { 'HP+45', 'VIT+12', 'MND+12', 'Damage taken-6' },
    -- Knight's Beads +2 (PLD, R25)
    [25455] = { 'HP+60', 'VIT+15', 'MND+15', 'Damage taken-7' },

    -- Abyssal Beads (DRK, R15)
    [25459] = { 'STR+15', 'Store TP+5', 'Physical Damage Limit+6' },
    -- Abyssal Beads +1 (DRK, R20)
    [25460] = { 'STR+20', 'Store TP+6', 'Physical Damage Limit+8' },
    -- Abyssal Beads +2 (DRK, R25)
    [25461] = { 'STR+25', 'Store TP+7', 'Physical Damage Limit+10' },

    -- Beastmaster Collar (BST, R15)
    [25465] = { 'STR+10', 'DEX+10', 'Physical Damage Limit+6',
                'Pet: Double Attack+15' },
    -- Beastmaster Collar +1 (BST, R20)
    [25466] = { 'STR+12', 'DEX+12', 'Physical Damage Limit+8',
                'Pet: Double Attack+20' },
    -- Beastmaster Collar +2 (BST, R25)
    [25467] = { 'STR+15', 'DEX+15', 'Physical Damage Limit+10',
                'Pet: Double Attack+25' },

    -- Bard's Charm (BRD, R15)
    [25471] = { 'DEX+15', 'CHR+15', 'Store TP+5',
                'Physical Damage Limit+6' },
    -- Bard's Charm +1 (BRD, R20)
    [25472] = { 'DEX+20', 'CHR+20', 'Store TP+6',
                'Physical Damage Limit+8' },
    -- Bard's Charm +2 (BRD, R25)
    [25473] = { 'DEX+25', 'CHR+25', 'Store TP+7',
                'Physical Damage Limit+10' },

    -- Scout's Gorget (RNG, R15)
    [25477] = { 'AGI+15', 'Store TP+5', 'Physical Damage Limit+6' },
    -- Scout's Gorget +1 (RNG, R20)
    [25478] = { 'AGI+20', 'Store TP+6', 'Physical Damage Limit+8' },
    -- Scout's Gorget +2 (RNG, R25)
    [25479] = { 'AGI+25', 'Store TP+7', 'Physical Damage Limit+10' },

    -- Samurai's Nodowa (SAM, R15)
    [25483] = { 'STR+15', 'Store TP+5', 'Physical Damage Limit+6' },
    -- Samurai's Nodowa +1 (SAM, R20)
    [25484] = { 'STR+20', 'Store TP+6', 'Physical Damage Limit+8' },
    -- Samurai's Nodowa +2 (SAM, R25)
    [25485] = { 'STR+25', 'Store TP+7', 'Physical Damage Limit+10' },

    -- Ninja Nodowa (NIN, R15)
    [25489] = { 'DEX+10', 'AGI+10', 'Daken+15', 'Physical Damage Limit+6' },
    -- Ninja Nodowa +1 (NIN, R20)
    [25490] = { 'DEX+12', 'AGI+12', 'Daken+20', 'Physical Damage Limit+8' },
    -- Ninja Nodowa +2 (NIN, R25)
    [25491] = { 'DEX+15', 'AGI+15', 'Daken+25',
                'Physical Damage Limit+10' },

    -- Dragoon's Collar (DRG, R15)
    [25495] = { 'STR+10', 'VIT+10', 'Physical Damage Limit+6',
                'Wyvern: Damage Taken-15' },
    -- Dragoon's Collar +1 (DRG, R20)
    [25496] = { 'STR+12', 'VIT+12', 'Physical Damage Limit+8',
                'Wyvern: Damage Taken-20' },
    -- Dragoon's Collar +2 (DRG, R25)
    [25497] = { 'STR+15', 'VIT+15', 'Physical Damage Limit+10',
                'Wyvern: Damage Taken-25' },

    -- Summoner's Collar (SMN, R15)
    [25501] = { 'MP+30', 'Avatar: All Base Stats+15',
                'Blood Pact Damage+6' },
    -- Summoner's Collar +1 (SMN, R20)
    [25502] = { 'MP+40', 'Avatar: All Base Stats+20',
                'Blood Pact Damage+8' },
    -- Summoner's Collar +2 (SMN, R25)
    [25503] = { 'MP+50', 'Avatar: All Base Stats+25',
                'Blood Pact Damage+10' },

    -- Mirage Stole (BLU, R15)
    [25507] = { 'STR+15', 'DEX+15', 'Store TP+5', 'Critical Hit Rate+3' },
    -- Mirage Stole +1 (BLU, R20)
    [25508] = { 'STR+20', 'DEX+20', 'Store TP+6', 'Critical Hit Rate+4' },
    -- Mirage Stole +2 (BLU, R25)
    [25509] = { 'STR+25', 'DEX+25', 'Store TP+7', 'Critical Hit Rate+5' },

    -- Commodore Charm (COR, R15)
    [25513] = { 'STR+10', 'AGI+10', 'Magic Damage+15',
                'Magic Attack Bonus+5' },
    -- Commodore Charm +1 (COR, R20)
    [25514] = { 'STR+12', 'AGI+12', 'Magic Damage+20',
                'Magic Attack Bonus+6' },
    -- Commodore Charm +2 (COR, R25)
    [25515] = { 'STR+15', 'AGI+15', 'Magic Damage+25',
                'Magic Attack Bonus+7' },

    -- Puppetmaster's Collar (PUP, R15)
    [25519] = { 'DEX+10', 'AGI+10', 'Physical Damage Limit+6',
                'Automaton: Magic Attack Bonus+15' },
    -- Puppetmaster's Collar +1 (PUP, R20)
    [25520] = { 'DEX+12', 'AGI+12', 'Physical Damage Limit+8',
                'Automaton: Magic Attack Bonus+20' },
    -- Puppetmaster's Collar +2 (PUP, R25)
    [25521] = { 'DEX+15', 'AGI+15', 'Physical Damage Limit+10',
                'Automaton: Magic Attack Bonus+25' },

    -- Etoile Gorget (DNC, R15)
    [25525] = { 'DEX+15', 'CHR+15', 'Store TP+5',
                'Physical Damage Limit+6' },
    -- Etoile Gorget +1 (DNC, R20)
    [25526] = { 'DEX+20', 'CHR+20', 'Store TP+6',
                'Physical Damage Limit+8' },
    -- Etoile Gorget +2 (DNC, R25)
    [25527] = { 'DEX+25', 'CHR+25', 'Store TP+7',
                'Physical Damage Limit+10' },

    -- Argute Stole (SCH, R15)
    [25531] = { 'INT+10', 'MND+10', 'Magic Damage+15',
                'Helix effect duration+6' },
    -- Argute Stole +1 (SCH, R20)
    [25532] = { 'INT+12', 'MND+12', 'Magic Damage+20',
                'Helix effect duration+8' },
    -- Argute Stole +2 (SCH, R25)
    [25533] = { 'INT+15', 'MND+15', 'Magic Damage+25',
                'Helix effect duration+10' },

    -- Bagua Charm (GEO, R15)
    [25537] = { 'MP+30', 'Luopan Duration+15', 'Luopan: Absorbs Damage+6' },
    -- Bagua Charm +1 (GEO, R20)
    [25538] = { 'MP+40', 'Luopan Duration+20', 'Luopan: Absorbs Damage+8' },
    -- Bagua Charm +2 (GEO, R25)
    [25539] = { 'MP+50', 'Luopan Duration+25',
                'Luopan: Absorbs Damage+10' },

    -- Futhark Torque (RUN, R15)
    [25543] = { 'HP+30', 'STR+10', 'MND+10', 'Damage taken-5' },
    -- Futhark Torque +1 (RUN, R20)
    [25544] = { 'HP+45', 'STR+12', 'MND+12', 'Damage taken-6' },
    -- Futhark Torque +2 (RUN, R25)
    [25545] = { 'HP+60', 'STR+15', 'MND+15', 'Damage taken-7' },

    -- ─── Future entries below ─────────────────────────────────────────────
    -- Add new gear groups with a section header comment above each block.
    -- e.g. "-- ─── Sortie Accessories ────────────────────"
    --      "-- ─── Empyrean +3 special augments ──────────"
    -- Group entries by content source so it's easy to find what you need.

}