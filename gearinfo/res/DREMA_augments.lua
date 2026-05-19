-- ═══════════════════════════════════════════════════════════════════════════
-- DREMA_Augments.lua  —  Dynamis-Divergence / Relic / Empyrean / Mythic /
--                       Aeonic weapon path-augment overlay
--
-- Source-of-truth for max-rank (R15) path augments on REMA + Dynamis-
-- Divergence Su4/Su5 weapons. These weapons return opaque "Path: A" /
-- "Path: B" / "Path: C" strings via extdata.decode — they carry no
-- readable stat lines for the augment portion. This file maps each
-- item_id + lowercase path key to the literal augment list at R15 (max)
-- for that path, per BG-wiki's Ultimate Weapon Augments page.

--
-- ⚠ Note: BASE STATS of the weapon (DMG / Delay / skill / inherent
-- Accuracy / Magic Damage / etc.) come from the item description, NOT
-- from this file. This file ONLY contains the R15 AUGMENT OVERLAY —
-- the stats Oboro adds on top of the base item. For example, Heishi
-- Shorinken's base item carries Magic Damage +217 and various base
-- stats; the R15 augment list below adds DMG+7, "Blade: Shun" damage
-- +10%, Accuracy+30, and Magic Accuracy+30 ON TOP of the base.
--
-- ── Path layout per weapon type ───────────────────────────────────────────
--   • Relic 119-III, Mythic 119-III, Empyrean 119-III, Aeonic — single
--     path ('path: a'). At R15 these are FIXED — no path choice.
--   • Dynamis Divergence Su4 NQ/HQ1 and Su5 HQ2 — three paths
--     ('path: a', 'path: b', 'path: c'); player picks one at augment time
--
-- ── Schema ────────────────────────────────────────────────────────────────
-- Same shape as the inline `ow_path_augments` table in OmniWatch.lua:
--
--   [<item_id>] = {
--       ['path: a'] = { 'STR+15', 'Accuracy+30', '"Triple Attack"+5', ... },
--       ['path: b'] = { ... },
--       ['path: c'] = { ... },
--   },
--
-- Each string is fed through ow_parse_desc_line. The parser handles plain
-- stat lines, mag/atk abbreviations, quoted-name stats, percent stats,
-- negative values, and compound names — see Misc_augments.lua header.
--
-- ── Stats included verbatim ───────────────────────────────────────────────
-- Per author preference, ALL R15 augment lines are included even when the
-- stat name isn't in OmniWatch's stat dict (DMG, "Weaponskill" damage,
-- TP Bonus, Aftermath effects). They parse harmlessly into the stats dict
-- but don't display. Kept for documentation and forward compatibility.
--
-- ── Weapons explicitly NOT in this file ──────────────────────────────────
-- Per BG-wiki: certain shields and instruments are NOT augmentable.
--   • Aegis (PLD relic shield)         — no 119-III variant
--   • Gjallarhorn (BRD relic horn)     — no 119-III variant
--   • Daurdabla (BRD empyrean horn)    — no 119-III variant
--   • Marsyas (BRD aeonic horn)        — explicitly not eligible for augments
--   • Srivatsa (PUP aeonic shield)     — explicitly not eligible for augments
-- These weapons exist in the game but cannot receive Oboro path augments,
-- so they have no entry here.
--
-- ── Loading ───────────────────────────────────────────────────────────────
-- Loaded from gearinfo/res/DREMA_Augments.lua by OmniWatch's loader block.
-- Entries merge into ow_path_augments with per-path granularity — file
-- entries override inline ow_path_augments definitions for the same path.
--
-- ═══════════════════════════════════════════════════════════════════════════

return {

    -- ═══════════════════════════════════════════════════════════════════════
    -- RELIC WEAPONS (Level 119 III)
    -- Source: BG-wiki "Ultimate Weapon Augments" → Relic Weapons table.
    -- Each Relic has a single augment path (Path A) at Rank 15.
    -- Relic R15 augments contain: DMG+N, WS damage+20%, and a utility line.
    -- No accuracy is granted by Relic augments.
    -- ═══════════════════════════════════════════════════════════════════════

    -- Spharai (MNK, Hand-to-Hand)
    [20509] = {
        ['path: a'] = {
            'DMG+24',
            'Final Heaven: Damage+20%',
            '"Counter" damage+30%',
        },
    },

    -- Mandau (RDM/THF/BRD, Dagger) — Main hand only

    [20583] = {
        ['path: a'] = {
            'DMG+7',
            'Mercy Stroke: Damage+20%',
            '"Triple Attack" damage+10%',
        },
    },

    -- Excalibur (RDM/PLD, Sword) — Main hand only

    [20685] = {
        ['path: a'] = {
            'DMG+9',
            'Knights of Round: Damage+20%',
            'Chance of successful block+10%',
        },
    },

    -- Ragnarok (WAR/PLD/DRK, Great Sword)
    [21683] = {
        ['path: a'] = {
            'DMG+17',
            'Scourge: Damage+20%',
            'Critical hit damage+5%',
        },
    },

    -- Guttler (BST, Axe) — Main hand only
    [21750] = {
        ['path: a'] = {
            'DMG+12',
            'Onslaught: Damage+20%',
            'Pet: "Double Attack"+5%',
        },
    },

    -- Bravura (WAR, Great Axe)
    [21756] = {
        ['path: a'] = {
            'DMG+20',
            'Metatron Torment: Damage+20%',
            '"Double Attack" damage+10%',
        },
    },

    -- Apocalypse (DRK, Scythe)
    [21808] = {
        ['path: a'] = {
            'DMG+21',
            'Catastrophe: Damage+20%',
            '"Drain" potency+10%',
        },
    },

    -- Gungnir (DRG, Polearm)
    [21857] = {
        ['path: a'] = {
            'DMG+20',
            'Geirskogul: Damage+20%',
            'All Jumps damage+15%',
        },
    },

    -- Kikoku (NIN, Katana) — Main hand only
    [21906] = {
        ['path: a'] = {
            'DMG+8',
            'Blade: Metsu: Damage+20%',
            'Ninjutsu casting time-20%',
        },
    },

    -- Amanomurakumo (SAM, Great Katana)
    [21954] = {
        ['path: a'] = {
            'DMG+18',
            'Tachi: Kaiten: Damage+20%',
            'Skillchain damage+5%',
        },
    },

    -- Mjollnir (WHM, Club) — Main hand only
    [21077] = {
        ['path: a'] = {
            'DMG+12',
            'Randgrith: Damage+20%',
            '"Cure" potency+30%',
        },
    },

    -- Claustrum (BLM/SMN, Staff)
    [22060] = {
        ['path: a'] = {
            'DMG+16',
            'Gates of Tartarus: Damage+20%',
            'Enmity-20',
        },
    },

    -- Yoichinoyumi (RNG/SAM, Bow) — also exists as "Yoichinoyumi (Augmented)"
    -- with same R15 augment list; both share gameplay properties.
    -- TODO: id yoichinoyumi_119_3 (and yoichinoyumi_augmented separately)
    [22115] = {
        ['path: a'] = {
            'DMG+7',
            'Namas Arrow: Damage+20%',
            'Critical hit rate+5%',
        },
    },

    -- Annihilator (RNG, Gun) — also exists as "Annihilator (Augmented)"
    -- which is the Dispense-replacement form. Same R15 augments.
    -- TODO: id annihilator_119_3 (and annihilator_augmented separately)
    [21267] = {
        ['path: a'] = {
            'DMG+12',
            'Coronach: Damage+20%',
            '"Store TP"+5',
        },
    },


    -- ═══════════════════════════════════════════════════════════════════════
    -- MYTHIC / ERGON WEAPONS (Level 119 III)
    -- Source: BG-wiki "Ultimate Weapon Augments" → Mythic/Ergon table.
    -- Each Mythic has a single augment path (Path A) at Rank 15.
    -- Mythic R15 augments are uniform: DMG+N, WS damage+15%,
    -- Accuracy+30, Magic Accuracy+30 (or Ranged Accuracy for guns/crossbows).
    -- Burtgang is the one exception — instead of WS damage, it has
    -- "Atonement: Enmity+100".
    -- Nirvana's accuracy bonus is to the AVATAR ("Avatar: Accuracy +30 /
    -- Magic Accuracy +30") rather than the player.
    -- ═══════════════════════════════════════════════════════════════════════

    -- Conqueror (WAR, Great Axe, Mythic)
    [21757] = {
        ['path: a'] = {
            'DMG+32',
            "King's Justice: Damage+15%",
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Glanzfaust (MNK, Hand-to-Hand, Mythic)
    [20510] = {
        ['path: a'] = {
            'DMG+29',
            "Ascetic's Fury: Damage+15%",
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Yagrush (WHM, Club, Mythic) — Main hand only

    [21078] = {
        ['path: a'] = {
            'DMG+17',
            'Mystic Boon: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Laevateinn (BLM, Staff, Mythic)
    [22062] = {
        ['path: a'] = {
            'DMG+26',
            'Vidohunir: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Murgleis (RDM, Sword, Mythic) — Main hand only

    [20686] = {
        ['path: a'] = {
            'DMG+17',
            'Death Blossom: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Vajra (THF, Dagger, Mythic) — Main hand only

    [20585] = {
        ['path: a'] = {
            'DMG+15',
            'Mandalic Stab: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Burtgang (PLD, Sword, Mythic) — Main hand only
    -- Note: instead of WS damage, has Atonement Enmity+100

    [20687] = {
        ['path: a'] = {
            'DMG+20',
            'Atonement: Enmity+100',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Liberator (DRK, Scythe, Mythic)
    [21809] = {
        ['path: a'] = {
            'DMG+34',
            'Insurgency: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Aymur (BST, Axe, Mythic) — Main hand only

    [21751] = {
        ['path: a'] = {
            'DMG+20',
            'Primal Rend: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Carnwenhan (BRD, Dagger, Mythic) — Main hand only

    [20586] = {
        ['path: a'] = {
            'DMG+14',
            'Mordant Rime: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Gastraphetes (RNG, Crossbow, Mythic)

    [21266] = {
        ['path: a'] = {
            'DMG+5',
            'Trueflight: Damage+15%',
            'Ranged Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Kogarasumaru (SAM, Great Katana, Mythic)
    -- WS is Tachi: Rana (NOT Tachi: Kasha — common mistake)

    [21955] = {
        ['path: a'] = {
            'DMG+29',
            'Tachi: Rana: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Nagi (NIN, Katana, Mythic) — Main hand only

    [21907] = {
        ['path: a'] = {
            'DMG+14',
            'Blade: Kamu: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Ryunohige (DRG, Polearm, Mythic)
    [21858] = {
        ['path: a'] = {
            'DMG+32',
            'Drakesbane: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Nirvana (SMN, Staff, Mythic)
    -- Note: accuracy bonus is to the AVATAR, not the player.

    [22063] = {
        ['path: a'] = {
            'DMG+26',
            'Garland of Bliss: Damage+15%',
            'Avatar: Accuracy+30',
            'Avatar: Magic Accuracy+30',
        },
    },

    -- Tizona (BLU, Sword, Mythic) — Main hand only

    [20688] = {
        ['path: a'] = {
            'DMG+18',
            'Expiacion: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Death Penalty (COR, Gun, Mythic) — also exists as augmented form
    -- TODO: id death_penalty_119_3 (and death_penalty_augmented separately)
    [21268] = {
        ['path: a'] = {
            'DMG+6',
            'Leaden Salute: Damage+15%',
            'Ranged Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Kenkonken (PUP, Hand-to-Hand, Mythic)
    [20511] = {
        ['path: a'] = {
            'DMG+24',
            'Stringing Pummel: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Terpsichore (DNC, Dagger, Mythic) — Main hand only

    [20584] = {
        ['path: a'] = {
            'DMG+16',
            'Pyrrhic Kleos: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Tupsimati (SCH, Staff, Mythic)
    -- WS is Omniscience (NOT Myrkr — Myrkr is Hvergelmir's WS)

    [22061] = {
        ['path: a'] = {
            'DMG+26',
            'Omniscience: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Idris (GEO, Club, Mythic) — Main hand only
    -- Note: Idris is a CLUB, not a staff (common mistake).

    [21080] = {
        ['path: a'] = {
            'DMG+22',
            'Exudation: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Epeolatry (RUN, Great Sword, Ergon)
    -- Ergon weapons are the RUN/GEO equivalents of Mythic, added with
    -- Seekers of Adoulin. Same R15 augment pattern as Mythic.

    [21685] = {
        ['path: a'] = {
            'DMG+39',
            'Dimidiation: Damage+15%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },


    -- ═══════════════════════════════════════════════════════════════════════
    -- EMPYREAN WEAPONS (Level 119 III)
    -- Source: BG-wiki "Ultimate Weapon Augments" → Empyrean table.
    -- Each Empyrean has a single augment path (Path A) at Rank 15.
    -- Empyrean R15 augments are: DMG+N, WS damage+10%, plus 2-4 raw
    -- stat lines (+15 to +30 each, varies per weapon). No accuracy.
    -- ═══════════════════════════════════════════════════════════════════════

    -- Verethragna (MNK/PUP, Hand-to-Hand)
    [20512] = {
        ['path: a'] = {
            'DMG+20',
            'Victory Smite: Damage+10%',
            'STR+20',
            'DEX+20',
        },
    },

    -- Twashtar (THF/BRD/DNC, Dagger) — Main hand only

    [20587] = {
        ['path: a'] = {
            'DMG+4',
            "Rudra's Storm: Damage+10%",
            'DEX+20',
            'AGI+20',
        },
    },

    -- Almace (RDM/PLD/BLU, Sword) — Main hand only

    [20689] = {
        ['path: a'] = {
            'DMG+5',
            'Chant du Cygne: Damage+10%',
            'DEX+20',
            'MND+20',
        },
    },

    -- Caladbolg (PLD/DRK, Great Sword)
    [21684] = {
        ['path: a'] = {
            'DMG+11',
            'Torcleaver: Damage+10%',
            'STR+20',
            'VIT+20',
        },
    },

    -- Farsha (WAR/BST, Axe) — Main hand only
    -- Note: 4 stats at +15 each (not 2 stats at +20)

    [21752] = {
        ['path: a'] = {
            'DMG+6',
            'Cloudsplitter: Damage+10%',
            'STR+15',
            'DEX+15',
            'MND+15',
            'CHR+15',
        },
    },

    -- Ukonvasara (WAR, Great Axe)
    [21758] = {
        ['path: a'] = {
            'DMG+12',
            "Ukko's Fury: Damage+10%",
            'STR+20',
            'DEX+20',
        },
    },

    -- Redemption (DRK, Scythe)
    -- Note: 4 stats at +15 each (not 2 stats at +20)
    -- WS is Quietus (NOT Entropy — Entropy is Anguta's Aeonic WS)

    [21810] = {
        ['path: a'] = {
            'DMG+13',
            'Quietus: Damage+10%',
            'STR+15',
            'DEX+15',
            'INT+15',
            'MND+15',
        },
    },

    -- Rhongomiant (DRG, Polearm)
    -- WS is Camlann's Torment (NOT Stardiver — Stardiver is Trishula's Aeonic WS)

    [21859] = {
        ['path: a'] = {
            'DMG+12',
            "Camlann's Torment: Damage+10%",
            'STR+20',
            'VIT+20',
        },
    },

    -- Kannagi (NIN, Katana) — Main hand only

    [21908] = {
        ['path: a'] = {
            'DMG+5',
            'Blade: Hi: Damage+10%',
            'DEX+20',
            'AGI+20',
        },
    },

    -- Masamune (SAM, Great Katana)
    [21956] = {
        ['path: a'] = {
            'DMG+11',
            'Tachi: Fudo: Damage+10%',
            'STR+20',
            'AGI+20',
        },
    },

    -- Gambanteinn (WHM, Club) — Main hand only
    -- Note: "Dagan" potency (not damage); 3 stats at +20

    [21079] = {
        ['path: a'] = {
            'DMG+7',
            '"Dagan" potency+10%',
            'HP+20',
            'MP+20',
            'MND+20',
        },
    },

    -- Hvergelmir (BLM/SMN/SCH, Staff)
    -- Note: "Myrkr" potency (not damage); single MP+30 stat

    [22064] = {
        ['path: a'] = {
            'DMG+10',
            '"Myrkr" potency+10%',
            'MP+30',
        },
    },

    -- Gandiva (RNG, Bow) — also exists as "Gandiva (Augmented)"
    -- TODO: id gandiva_119_3 (and gandiva_augmented separately)
    [22116] = {
        ['path: a'] = {
            'DMG+7',
            "Jishnu's Radiance: Damage+10%",
            'STR+20',
            'DEX+20',
        },
    },

    -- Armageddon (RNG/COR, Gun) — also exists as "Armageddon (Augmented)"
    -- TODO: id armageddon_119_3 (and armageddon_augmented separately)
    [21269] = {
        ['path: a'] = {
            'DMG+8',
            'Wildfire: Damage+10%',
            'STR+20',
            'AGI+20',
        },
    },


    -- ═══════════════════════════════════════════════════════════════════════
    -- AEONIC WEAPONS
    -- Source: BG-wiki "Ultimate Weapon Augments" → Aeonic table.
    -- Each Aeonic has a single augment path (Path A) at Rank 15.
    -- Aeonic R15 augments are uniform: DMG+N, WS damage+10%,
    -- Accuracy+30, Magic Accuracy+30 (or Ranged Accuracy for guns/bows).
    -- Marsyas (BRD horn) and Srivatsa (PUP shield) are NOT eligible for
    -- augments per BG-wiki — they are intentionally not in this file.
    -- ═══════════════════════════════════════════════════════════════════════

    -- Godhands (MNK/PUP, Hand-to-Hand)
    -- WS is Shijin Spiral (NOT Stringing Pummel — that's Kenkonken Mythic)

    [20515] = {
        ['path: a'] = {
            'DMG+24',
            'Shijin Spiral: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Aeneas (THF/BRD/DNC, Dagger) — Main hand only
    -- WS is Exenterator

    [20594] = {
        ['path: a'] = {
            'DMG+6',
            'Exenterator: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Sequence (RDM/PLD/BLU, Sword) — Main hand only
    -- WS is Requiescat

    [20695] = {
        ['path: a'] = {
            'DMG+8',
            'Requiescat: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Lionheart (RUN, Great Sword)
    -- WS is Resolution

    [21694] = {
        ['path: a'] = {
            'DMG+16',
            'Resolution: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Tri-edge (BST, Axe) — Main hand only
    -- WS is Ruinator

    [21753] = {
        ['path: a'] = {
            'DMG+9',
            'Ruinator: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Chango (WAR, Great Axe)
    -- WS is Upheaval (NOT Ukko's Fury — that's Ukonvasara Empyrean)

    [20843] = {
        ['path: a'] = {
            'DMG+16',
            'Upheaval: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Anguta (DRK, Scythe)
    -- WS is Entropy

    [20890] = {
        ['path: a'] = {
            'DMG+17',
            'Entropy: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Trishula (DRG, Polearm)
    -- WS is Stardiver

    [20935] = {
        ['path: a'] = {
            'DMG+15',
            'Stardiver: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Heishi Shorinken (NIN, Katana) — Main hand only — item id 20977 (confirmed)
    -- WS is Blade: Shun
    -- NOTE: BG-wiki and FFXIclopedia both list "Ranged Accuracy +30" but
    -- the in-game item text reads "Accuracy +30" (melee). Wiki is wrong.
    -- Verified in-game by user 2026-05-13.
    [20977] = {
        ['path: a'] = {
            'DMG+7',
            '"Blade: Shun" damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Dojikiri Yasutsuna (SAM, Great Katana)
    -- WS is Tachi: Shoha (NOT Tachi: Fudo — that's Masamune's Empyrean WS)

    [21025] = {
        ['path: a'] = {
            'DMG+15',
            'Tachi: Shoha: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Tishtrya (WHM/GEO, Club) — Main hand only
    -- WS is Realmrazer (NOT Khatvanga's Shattersoul — different weapons)

    [21082] = {
        ['path: a'] = {
            'DMG+8',
            'Realmrazer: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Khatvanga (BLM/SMN/SCH, Staff)
    -- WS is Shattersoul (NOT Garland of Bliss — that's Nirvana's Mythic WS)

    [21147] = {
        ['path: a'] = {
            'DMG+8',
            'Shattersoul: Damage+10%',
            'Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Fail-Not (RNG, Bow) — also exists as "Fail-Not (Augmented)"
    -- WS is Apex Arrow (NOT Jishnu's Radiance — that's Gandiva's Empyrean WS)
    -- TODO: id fail_not_aeonic (and fail_not_augmented separately)
    [22117] = {
        ['path: a'] = {
            'DMG+7',
            'Apex Arrow: Damage+10%',
            'Ranged Accuracy+30',
            'Magic Accuracy+30',
        },
    },

    -- Fomalhaut (RNG/COR, Gun) — also exists as "Fomalhaut (Augmented)"
    -- WS is Last Stand
    -- TODO: id fomalhaut_aeonic (and fomalhaut_augmented separately)
    [21485] = {
        ['path: a'] = {
            'DMG+9',
            'Last Stand: Damage+10%',
            'Ranged Accuracy+30',
            'Magic Accuracy+30',
        },
    },


    -- ═══════════════════════════════════════════════════════════════════════
    -- DYNAMIS DIVERGENCE WEAPONS (Su4 NQ / Su4 HQ1 / Su5 HQ2)
    --
    -- Status: PENDING DETAILED TRANSCRIPTION
    --
    -- The Dynamis Divergence (JSE) weapons use Path A / Path B / Path C
    -- selectable augments. The Path A and Path B "headers" are uniform
    -- across all weapons of the same tier:
    --
    --   Su4 NQ  (Max Rank 15):
    --     Path A: Chance of double damage+30%, "Store TP"+15
    --     Path B: Chance of follow-up attack+30%, "Subtle Blow II"+15
    --     Path C: weapon-specific (works everywhere, not just Dynamis-D)
    --
    --   Su4 HQ1 (Max Rank 20):
    --     Path A: Chance of double damage+40%, "Store TP"+20
    --     Path B: Chance of follow-up attack+40%, "Subtle Blow II"+20
    --     Path C: weapon-specific, main hand only
    --
    --   Su5 HQ2/3 (Max Rank 25):
    --     Path A: Chance of double damage+50%, "Store TP"+25, DMG+N
    --     Path B: Chance of follow-up attack+50%, "Subtle Blow II"+25, DMG+N
    --     Path C: weapon-specific, main hand only, DMG+N
    --
    -- Mechanical notes from FFXIAH discussion (verified):
    --   • Path A/B universal augments (Store TP, Subtle Blow II) apply to
    --     ALL swings (mainhand + offhand + ranged) while the weapon is
    --     equipped in mainhand.
    --   • Path A's "Chance of double damage" and Path B's "Chance of
    --     follow-up attack" apply ONLY to mainhand swings.
    --   • Path C augments require the weapon worn in mainhand to take
    --     effect, but most apply to all relevant actions (e.g. Crocea
    --     Mors's enspell bonus only affects Crocea Mors swings since
    --     enspells are per-hand, but Rostam's Phantom Roll duration
    --     bonus applies to all rolls).
    --
    -- Each weapon's Path C is unique to its job (e.g. Rostam's Path C is
    -- COR Phantom Roll bonuses; Crocea Mors's is RDM Enspell damage).
    --
    -- ── Item IDs ────────────────────────────────────────────────────────
    -- Only Crocea Mors's item_id is currently confirmed (21627). All
    -- other entries use placeholder negative IDs in the form [-5xx]
    -- (Su4 NQ), [-6xx] (Su4 HQ1), [-7xx] (Su5 HQ2). Replace placeholders
    -- with real item_ids from res/items.lua as they're confirmed.
    -- ═══════════════════════════════════════════════════════════════════════


    -- ───────────────────────────────────────────────────────────────────
    -- SU4 NQ WEAPONS (Max Rank 15) — 22 weapons
    -- Headers: Path A = Chance of double damage+30%, "Store TP"+15
    --          Path B = Chance of follow-up attack+30%, "Subtle Blow II"+15
    -- No per-weapon DMG bonus at this tier.
    -- ───────────────────────────────────────────────────────────────────

    -- Wyrm Lance (DRG, Polearm, Su4 NQ)
    [21876] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = { 'Wyvern: HP+150', 'Wyvern: Damage Taken-10%' },
    },

    -- Cleric's Wand (WHM, Club, Su4 NQ)
    [22033] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Afflatus Misery" stored+150%',
            'Healing magic recast delay-15%',
            'Damage Taken-10%',
        },
    },

    -- Bard's Knife (BRD, Dagger, Su4 NQ)
    [21576] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Song spellcasting time-15%',
            'Song effects: "Double Attack"+2%',
        },
    },

    -- Bagua Wand (GEO, Club, Su4 NQ)
    [22036] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Magic burst damage II+6',
            'Magic burst accuracy+20',
            '"Drain" and "Aspir" potency+10',
        },
    },

    -- Duelist's Sword (RDM, Sword, Su4 NQ)
    [21625] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Sword enhancement spell damage+300%',
            'Elemental weapon skill damage+50%',
        },
    },

    -- Summoner's Staff (SMN, Staff, Su4 NQ)
    [22094] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Pet: Chance of double damage+20%',
            'Chance of doubling "Blood Pact" status+15%',
            'Blood Pact Dmg.+10',
        },
    },

    -- Abyss Scythe (DRK, Scythe, Su4 NQ)
    [21823] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Drain" potency+15%',
            'Weapon Skill Damage+10%',
        },
    },

    -- Koga Shin. (NIN, Katana, Su4 NQ)
    [21915] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Ninjutsu recast time-15%',
            'Enmity +6 for each Utsusemi',
        },
    },

    -- Saotome-no-tachi (SAM, Great Katana, Su4 NQ)
    [21968] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Sekkanoki" recast time-15%',
            '"Sekkanoki": Weapon Skill Damage+50%',
        },
    },

    -- Assassin's Knife (THF, Dagger, Su4 NQ)
    [21573] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Evasion+50',
            'TP during evasion+20',
        },
    },

    -- Sorcerer's Staff (BLM, Staff, Su4 NQ)
    [22091] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'MP+50',
            '"Mana Wall"+15%',
            'Damage Taken-10%',
        },
    },

    -- War. Chopper (WAR, Great Axe, Su4 NQ)
    [21772] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'TP Gained when landing critical hits+30',
            'Crit. Hit Rate+6%',
        },
    },

    -- Valor Sword (PLD, Sword, Su4 NQ)
    [21628] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'HP+150',
            '"Cure" potency+15%',
            '"Refresh"+2',
        },
    },

    -- Futhark Claymore (RUN, Great Sword, Su4 NQ)
    [21667] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Potency of "Regen" effects received+15',
            '"Vivacious Pulse" potency+20%',
        },
    },

    -- Argute Staff (SCH, Staff, Su4 NQ)
    [22097] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Regen" potency+15',
            '"Cure" potency+15%',
            '"Fast Cast"+6%',
        },
    },

    -- Monster Axe (BST, Axe, Su4 NQ)
    [21715] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Damage Taken-15%',
            'Pet: Damage Taken-10%',
        },
    },

    -- Comm. Knife (COR, Dagger, Su4 NQ)
    [21579] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Phantom Roll" effect duration+30',
            '"Phantom Roll XI": Recover HP and MP+10%',
            '"Phantom Roll"+6',
        },
    },

    -- Melee Fists (MNK, Hand-to-Hand, Su4 NQ)
    [21521] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'HP+200',
            '"Chakra"+20',
        },
    },

    -- Etoile Knife (DNC, Dagger, Su4 NQ)
    [21582] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Flourish" recast time-15%',
            '"Step" duration+30',
        },
    },

    -- Scout's Crossbow (RNG, Marksmanship, Su4 NQ)
    [22147] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Additional ammo damage+200%',
            'Additional ammo accuracy+100',
        },
    },

    -- Pantin Fists (PUP, Hand-to-Hand, Su4 NQ)
    [21524] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            'Weapon skill damage+10%',
            'Automaton: Special attack damage+15%',
        },
    },

    -- Mirage Sword (BLU, Sword, Su4 NQ)
    [21631] = {
        ['path: a'] = { 'Chance of double damage+30%', '"Store TP"+15' },
        ['path: b'] = { 'Chance of follow-up attack+30%', '"Subtle Blow II"+15' },
        ['path: c'] = {
            '"Chain Affinity" recast time-15%',
            '"Burst Affinity" recast time-15%',
        },
    },


    -- ───────────────────────────────────────────────────────────────────
    -- SU4 HQ1 WEAPONS (Max Rank 20) — 22 weapons
    -- Headers: Path A = Chance of double damage+40%, "Store TP"+20
    --          Path B = Chance of follow-up attack+40%, "Subtle Blow II"+20
    -- No per-weapon DMG bonus at this tier.
    -- Path C is main hand only on HQ1 (note in wiki header).
    -- ───────────────────────────────────────────────────────────────────

    -- Pteroslaver Lance (DRG, Polearm, Su4 HQ1)
    [21877] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = { 'Wyvern: HP+200', 'Wyvern: Damage Taken-12%' },
    },

    -- Piety Wand (WHM, Club, Su4 HQ1)
    [22034] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Afflatus Misery" stored+200%',
            'Healing magic recast delay-20%',
            'Damage Taken-12%',
        },
    },

    -- Bihu Knife (BRD, Dagger, Su4 HQ1)
    [21577] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Song spellcasting time-20%',
            'Song effects: "Double Attack"+3%',
        },
    },

    -- Sifang Wand (GEO, Club, Su4 HQ1)
    [22037] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Magic burst damage II+8%',
            'Magic burst accuracy+25',
            '"Drain" and "Aspir" potency+15',
        },
    },

    -- Vitiation Sword (RDM, Sword, Su4 HQ1)
    [21626] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Sword enhancement spell damage+400%',
            'Elemental weapon skill damage+75%',
        },
    },

    -- Glyphic Staff (SMN, Staff, Su4 HQ1)
    [22095] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Pet: Chance of double damage+35%',
            'Chance of doubling "Blood Pact" status+20%',
            'Blood Pact Dmg.+12',
        },
    },

    -- Fallen's Scythe (DRK, Scythe, Su4 HQ1)
    [21824] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Drain" Potency+20%',
            'Weapon Skill Damage+12%',
        },
    },

    -- Mochi. Shin. (NIN, Katana, Su4 HQ1)
    [21916] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Ninjutsu recast time-20%',
            'Enmity +8 for each Utsusemi',
        },
    },

    -- Sakonji-no-tachi (SAM, Great Katana, Su4 HQ1)
    [21969] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Sekkanoki" recast time-20%',
            '"Sekkanoki": Weapon Skill Damage+75%',
        },
    },

    -- Plun. Knife (THF, Dagger, Su4 HQ1)
    [21574] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Evasion+75',
            'TP during evasion+35',
        },
    },

    -- Archmage's Staff (BLM, Staff, Su4 HQ1)
    [22092] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'MP+75',
            '"Mana Wall"+20%',
            'Damage Taken-12%',
        },
    },

    -- Agoge Chopper (WAR, Great Axe, Su4 HQ1)
    [21773] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'TP Gained when landing critical hits+40',
            'Crit. Hit Rate+8%',
        },
    },

    -- Cabal. Sword (PLD, Sword, Su4 HQ1)
    [21629] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'HP+200',
            '"Cure" potency+20%',
            '"Refresh"+3',
        },
    },

    -- Peord Claymore (RUN, Great Sword, Su4 HQ1)
    [21668] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Potency of "Regen" effects received+20',
            '"Vivacious Pulse" potency+25%',
        },
    },

    -- Pedagogy Staff (SCH, Staff, Su4 HQ1)
    [22098] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Regen" potency+20',
            '"Cure" potency+20%',
            '"Fast Cast"+8%',
        },
    },

    -- Ankusa Axe (BST, Axe, Su4 HQ1)
    [21716] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Damage Taken-20%',
            'Pet: Damage Taken-12%',
        },
    },

    -- Lanun Knife (COR, Dagger, Su4 HQ1)
    [21580] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Phantom Roll" effect duration+45',
            '"Phantom Roll XI": Recover HP and MP+12%',
            '"Phantom Roll"+7',
        },
    },

    -- Hes. Fists (MNK, Hand-to-Hand, Su4 HQ1)
    [21522] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'HP+300',
            '"Chakra"+35',
        },
    },

    -- Horos Knife (DNC, Dagger, Su4 HQ1)
    [21583] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Flourish" recast time-20%',
            '"Step" duration+45',
        },
    },

    -- Arke Crossbow (RNG, Marksmanship, Su4 HQ1)
    [22148] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Additional ammo damage+250%',
            'Additional ammo accuracy+125',
        },
    },

    -- Pitre Fists (PUP, Hand-to-Hand, Su4 HQ1)
    [21525] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            'Weapon skill damage+12%',
            'Automaton: Special attack damage+20%',
        },
    },

    -- Luhlaza Sword (BLU, Sword, Su4 HQ1)
    [21632] = {
        ['path: a'] = { 'Chance of double damage+40%', '"Store TP"+20' },
        ['path: b'] = { 'Chance of follow-up attack+40%', '"Subtle Blow II"+20' },
        ['path: c'] = {
            '"Chain Affinity" recast time-20%',
            '"Burst Affinity" recast time-20%',
        },
    },


    -- ───────────────────────────────────────────────────────────────────
    -- SU5 HQ2/3 WEAPONS (Max Rank 25) — 22 weapons
    -- Headers: Path A = Chance of double damage+50%, "Store TP"+25, DMG+N
    --          Path B = Chance of follow-up attack+50%, "Subtle Blow II"+25, DMG+N
    --          Path C = weapon-specific (main hand only), DMG+N
    -- Per-weapon DMG bonus at this tier (Route A/B column).
    -- ───────────────────────────────────────────────────────────────────

    -- Aram (DRG, Polearm, Su5 HQ2)
    [21878] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+14',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+14',
        },
        ['path: c'] = {
            'Wyvern: HP+250',
            'Wyvern: Damage Taken-15%',
            'DMG+14',
        },
    },

    -- Asclepius (WHM, Club, Su5 HQ2)
    [22035] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+8',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+8',
        },
        ['path: c'] = {
            '"Afflatus Misery" stored+250%',
            'Healing magic recast delay-25%',
            'Damage Taken-15%',
            'DMG+8',
        },
    },

    -- Barfawc (BRD, Dagger, Su5 HQ2)
    [21578] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+5',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+5',
        },
        ['path: c'] = {
            'Song Spellcasting Time-25%',
            'Song Effects: Double Attack+4%',
            'DMG+5',
        },
    },

    -- Bhima (GEO, Club, Su5 HQ2)
    [22038] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+8',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+8',
        },
        ['path: c'] = {
            'Magic burst damage II+10%',
            'Magic burst accuracy+30',
            '"Drain" and "Aspir" potency+20',
            'DMG+8',
        },
    },

    -- Crocea Mors (RDM, Sword, Su5 HQ2) — item id 21627 (confirmed)
    [21627] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+7',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+7',
        },
        ['path: c'] = {
            'Sword enhancement spell damage+500%',
            'Elemental weapon skill damage+100%',
            'DMG+7',
        },
    },

    -- Draumstafir (SMN, Staff, Su5 HQ2)
    [22096] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+11',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+11',
        },
        ['path: c'] = {
            'Pet: Chance of double damage+50%',
            'Chance of doubling "Blood Pact" status+25%',
            'Blood Pact Dmg.+15',
            'DMG+11',
        },
    },

    -- Father Time (DRK, Scythe, Su5 HQ2)
    [21825] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+15',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+15',
        },
        ['path: c'] = {
            '"Drain" Potency+25%',
            'Weapon Skill Damage+15%',
            'DMG+15',
        },
    },

    -- Fudo Masamune (NIN, Katana, Su5 HQ2)
    [21917] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+7',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+7',
        },
        ['path: c'] = {
            'Ninjutsu recast time-25%',
            'Enmity+10 for each Utsusemi',
            'DMG+7',
        },
    },

    -- Fusenaikyo (SAM, Great Katana, Su5 HQ2)
    [21970] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+13',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+13',
        },
        ['path: c'] = {
            '"Sekkanoki" recast time-25%',
            '"Sekkanoki": Weapon Skill Damage+100%',
            'DMG+13',
        },
    },

    -- Gandring (THF, Dagger, Su5 HQ2)
    [21575] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+5',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+5',
        },
        ['path: c'] = {
            'Evasion+100',
            'TP during evasion+50',
            'DMG+5',
        },
    },

    -- Kaumodaki (BLM, Staff, Su5 HQ2)
    [22093] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+11',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+11',
        },
        ['path: c'] = {
            'MP+100',
            '"Mana Wall"+25%',
            'Damage Taken-15%',
            'DMG+11',
        },
    },

    -- Labraunda (WAR, Great Axe, Su5 HQ2)
    [21774] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+14',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+14',
        },
        ['path: c'] = {
            'TP Gained when landing critical hits+50',
            'Crit. Hit Rate+10%',
            'DMG+14',
        },
    },

    -- Moralltach (PLD, Sword, Su5 HQ2)
    [21630] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+7',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+7',
        },
        ['path: c'] = {
            'HP+250',
            '"Cure" potency+25%',
            '"Refresh"+4',
            'DMG+7',
        },
    },

    -- Morgelai (RUN, Great Sword, Su5 HQ2)
    [21669] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+14',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+14',
        },
        ['path: c'] = {
            'Potency of "Regen" effects received+25',
            '"Vivacious Pulse" potency+30%',
            'DMG+14',
        },
    },

    -- Musa (SCH, Staff, Su5 HQ2)
    [22099] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+11',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+11',
        },
        ['path: c'] = {
            '"Regen" potency+25',
            '"Cure" potency+25%',
            '"Fast Cast"+10%',
            'DMG+11',
        },
    },

    -- Pangu (BST, Axe, Su5 HQ2)
    [21717] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+11',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+11',
        },
        ['path: c'] = {
            'Damage Taken-25%',
            'Pet: Damage Taken-15%',
            'DMG+11',
        },
    },

    -- Rostam (COR, Dagger, Su5 HQ2)
    [21581] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+5',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+5',
        },
        ['path: c'] = {
            '"Phantom Roll" effect duration+60',
            '"Phantom Roll XI": Recover HP and MP+15%',
            '"Phantom Roll"+8',
            'DMG+5',
        },
    },

    -- Sagitta (MNK, Hand-to-Hand, Su5 HQ2)
    [21523] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+12',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+12',
        },
        ['path: c'] = {
            'HP+400',
            '"Chakra"+50',
            'DMG+12',
        },
    },

    -- Setan Kober (DNC, Dagger, Su5 HQ2)
    [21584] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+5',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+5',
        },
        ['path: c'] = {
            '"Flourish" recast time-25%',
            '"Step" duration+60',
            'DMG+5',
        },
    },

    -- Sharanga (RNG, Marksmanship, Su5 HQ2)
    [22149] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+6',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+6',
        },
        ['path: c'] = {
            'Additional ammo damage+250%',
            'Additional ammo accuracy+150',
            'DMG+6',
        },
    },

    -- Xiucoatl (PUP, Hand-to-Hand, Su5 HQ2)
    [21526] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+12',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+12',
        },
        ['path: c'] = {
            'Weapon Skill Damage+15%',
            'Automaton: Special attack damage+25%',
            'DMG+12',
        },
    },

    -- Zomorrodnegar (BLU, Sword, Su5 HQ2)
    [21633] = {
        ['path: a'] = {
            'Chance of double damage+50%',
            '"Store TP"+25',
            'DMG+7',
        },
        ['path: b'] = {
            'Chance of follow-up attack+50%',
            '"Subtle Blow II"+25',
            'DMG+7',
        },
        ['path: c'] = {
            '"Chain Affinity" recast time-25%',
            '"Burst Affinity" recast time-25%',
            'DMG+7',
        },
    },

}