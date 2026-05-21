--[[
    OmniWatch — Skillchains.lua sub-module

    Active skillchain display for the OmniWatch overlay. Listens to
    action packets (0x028) for weapon-skill / spell / job-ability /
    mob-TP-move events that open or extend a skillchain on a mob,
    tracks the resonating skillchain elements per mob, and emits a
    UDP stream on port 5015 carrying the current state.

    The Python side renders a panel with:
      • The active resonating properties on the player's current target
      • A timer bar for the skillchain window (red while waiting, green
        during the SC window itself)
      • Optional magic-burst window display
      • Current chain step (Lv.1 → Lv.4)
      • Suggestion lists: matching WS / spells / pet abilities that
        would continue the chain

    Architecture
    ────────────
    This file is loaded by OmniWatch.lua's loader block (mirrors the
    Server_Stats.lua loader). It returns a table with the public API:

        OW_Skillchains.handle_action(act)
            Called from OmniWatch.lua's handle_incoming_action with the
            parsed action packet. Picks out SC-relevant events and
            updates `resonating` state.

        OW_Skillchains.handle_chunk(id, data)
            Called from OmniWatch.lua's incoming chunk handler.
            Watches 0x50 (equipment change) so we know your current
            main/range weapon (for aeonic detection) and 0x063 sub-9
            (buffs) so we know if any aeonic Aftermath / chainbound
            buffs are active.

        OW_Skillchains.handle_targetstate(targ_id)
            Optional. Called from OmniWatch.lua's prerender loop with
            the current target id so we know which mob's resonating
            state to broadcast. Falls back to whichever mob has an
            active resonating entry if none provided.

        OW_Skillchains.tick(now)
            Called every prerender tick. Expires stale resonating
            entries, computes suggestions if any of the gate
            conditions changed (new resonating state, equipped WS
            list changed, job changed), and emits a UDP packet.

        OW_Skillchains.set_setting(key, value)
            Mutate one of the show_* booleans (called from a slash
            command in OmniWatch.lua or from Python via the inbound
            command channel).

        OW_Skillchains.status()
            Returns a diag table for `//ow sc dump`.

    Detection model (from Ivaar/Skillchains, ported to parse_action)
    ─────────────────────────────────────────────────────────────────
    For each parsed action, the relevant fields are:

        act.category    1=melee, 2=ranged, 3=WS finish, 4=spell finish,
                         6=ability, 11=mob TP move, 13=avatar TP, ...
        act.actor_id
        act.param       For category 3 (WS), this is the WS id.
                         For category 4 (spell), the spell id.
                         For ability, the ability id.
        act.targets[].id
        act.targets[].actions[].message
        act.targets[].actions[].param
        act.targets[].actions[].has_add_effect
        act.targets[].actions[].add_effect_message   ← SC element message
        act.targets[].actions[].add_effect_param     ← SC damage

    A skillchain "opens" when a WS / spell / ability fires and the
    target's action message_id is in MESSAGE_IDS (110, 185, 187, 317,
    802). These are the "lands with effect" messages. The resonating
    properties for the open are the WS's `skillchain` field.

    A skillchain "extends" or "closes" when the action's
    add_effect_message is in SKILLCHAIN_MSG_IDS (288-301, 385-397, 767-
    770). The SC name comes from the message-id offset:
        288-301 (player closes): index = msg - 287 into skillchain_names
        385-397 (mob   closes): index = msg - 384 into skillchain_names
        767-770 (Lv.4):           handled explicitly

    The 16-name list (from Ivaar):
       1=Light, 2=Darkness, 3=Gravitation, 4=Fragmentation,
       5=Distortion, 6=Fusion, 7=Compression, 8=Liquefaction,
       9=Induration, 10=Reverberation, 11=Transfixion, 12=Scission,
       13=Detonation, 14=Impaction, 15=Radiance, 16=Umbra

    Chainbound is a Chainspell-like mechanic where mob TP moves
    pre-set certain resonating properties via message_id 529 — handled
    similarly.

    UDP wire format on port 5015 (one line per packet, '|' separated)
    ─────────────────────────────────────────────────────────────────
    SC|<target_id>|<step>|<delay_ts>|<window_ts>|<props>|<closed>|<bound>|<action_id>|<resource>
        target_id   the mob id this state is for
        step        chain step (1 = open, 2..4 = extends, 4 = closed at Lv.4)
        delay_ts    os.time + delay (start of the SC window in seconds from epoch)
        window_ts   os.time + delay + 8 - step (end of the SC window)
        props       comma-separated list, e.g. "Fusion,Liquefaction"
        closed      "1" if the chain has been closed (no more extensions
                    possible), "0" otherwise
        bound       chainbound level if mob-bound; "0" otherwise
        action_id   the action id that triggered this state (e.g. WS id)
        resource    one of: weapon_skills | spells | monster_abilities |
                            job_abilities

    SC_EMPTY|<target_id>
        Emitted when the resonating window expires for that target.

    SUGGEST|<source>|<text>
        One line per suggestion. Text format:
          "Name           → Lv.N PropertyName"
        source is "ws" | "spell" | "pet" — Python renders each in its
        own column / colored row.

    SUGGEST_END
        End-of-suggestions sentinel. Python clears its list when it
        sees this and rebuilds from the SUGGEST lines that follow until
        the next SUGGEST_END.

    JOB|<main_job_short>
        Emitted when the player's main job changes (or once at startup).
        Lets Python apply per-job persistent toggles.

    SETTINGS|<csv>
        Echoes the current show_* toggles whenever they change, so
        Python can reflect them in its settings panel without having
        to query.
]]

local res     = require('resources')
local packets = require('packets')

local M = {}

-- ─────────────────────────────────────────────────────────────────────
-- Data tables — verbatim from Ivaar's Skillchains.lua + skills.lua,
-- with permission implicit in their BSD-style license (this file
-- carries a credit comment at the top).
-- ─────────────────────────────────────────────────────────────────────

-- 16 skillchain names, indexed 1..16. Used for message_id → name
-- conversion (288-301 player, 385-397 mob).
local skillchain_names = {
    [1]  = 'Light',         [2]  = 'Darkness',
    [3]  = 'Gravitation',   [4]  = 'Fragmentation',
    [5]  = 'Distortion',    [6]  = 'Fusion',
    [7]  = 'Compression',   [8]  = 'Liquefaction',
    [9]  = 'Induration',    [10] = 'Reverberation',
    [11] = 'Transfixion',   [12] = 'Scission',
    [13] = 'Detonation',    [14] = 'Impaction',
    [15] = 'Radiance',      [16] = 'Umbra',
}

-- Lv.4 SC msg ids (Radiance/Umbra). 767/769 = Radiance, 768/770 = Umbra.
-- These are the rare 4-property level-4 closes that happen when you
-- chain Light into Radiance or Darkness into Umbra.
local lv4_sc_by_msgid = {
    [767] = 'Radiance', [768] = 'Umbra',
    [769] = 'Radiance', [770] = 'Umbra',
}

-- "Lands with effect" message ids — when a WS / spell / ability hits
-- with one of these messages, it's eligible to open or extend an SC.
-- Source: Ivaar's `message_ids` set. 110 = WS damage with effect,
-- 185 = magic burst, 187 = spell damage, 317 = mob ability damage,
-- 802 = pet damage with effect.
local MESSAGE_IDS = {[110]=true, [185]=true, [187]=true, [317]=true, [802]=true}

-- Skillchain element messages (the add_effect_message values).
local SKILLCHAIN_MSG_IDS = {}
for i = 288, 301 do SKILLCHAIN_MSG_IDS[i] = true end
for i = 385, 397 do SKILLCHAIN_MSG_IDS[i] = true end
for i = 767, 770 do SKILLCHAIN_MSG_IDS[i] = true end

-- Chain combination math — given two consecutive properties (old, new),
-- this table tells you what chain results and at what level. Verbatim
-- from Ivaar's `sc_info`.
local sc_info = {
    Radiance     = {'Fire','Wind','Lightning','Light',                                        lvl=4},
    Umbra        = {'Earth','Ice','Water','Dark',                                              lvl=4},
    Light        = {'Fire','Wind','Lightning','Light',     Light       = {4,'Light','Radiance'},     lvl=3},
    Darkness     = {'Earth','Ice','Water','Dark',          Darkness    = {4,'Darkness','Umbra'},     lvl=3},
    Gravitation  = {'Earth','Dark',                        Distortion  = {3,'Darkness'},
                                                            Fragmentation = {2,'Fragmentation'},     lvl=2},
    Fragmentation = {'Wind','Lightning',                   Fusion      = {3,'Light'},
                                                            Distortion  = {2,'Distortion'},          lvl=2},
    Distortion   = {'Ice','Water',                         Gravitation = {3,'Darkness'},
                                                            Fusion      = {2,'Fusion'},              lvl=2},
    Fusion       = {'Fire','Light',                        Fragmentation = {3,'Light'},
                                                            Gravitation = {2,'Gravitation'},         lvl=2},
    Compression  = {'Darkness',                            Transfixion = {1,'Transfixion'},
                                                            Detonation  = {1,'Detonation'},          lvl=1},
    Liquefaction = {'Fire',                                Impaction   = {2,'Fusion'},
                                                            Scission    = {1,'Scission'},            lvl=1},
    Induration   = {'Ice',                                 Reverberation = {2,'Fragmentation'},
                                                            Compression = {1,'Compression'},
                                                            Impaction   = {1,'Impaction'},           lvl=1},
    Reverberation = {'Water',                              Induration  = {1,'Induration'},
                                                            Impaction   = {1,'Impaction'},           lvl=1},
    Transfixion  = {'Light',                               Scission    = {2,'Distortion'},
                                                            Reverberation = {1,'Reverberation'},
                                                            Compression = {1,'Compression'},         lvl=1},
    Scission     = {'Earth',                               Liquefaction = {1,'Liquefaction'},
                                                            Reverberation = {1,'Reverberation'},
                                                            Detonation  = {1,'Detonation'},          lvl=1},
    Detonation   = {'Wind',                                Compression = {2,'Gravitation'},
                                                            Scission    = {1,'Scission'},            lvl=1},
    Impaction    = {'Lightning',                           Liquefaction = {1,'Liquefaction'},
                                                            Detonation  = {1,'Detonation'},          lvl=1},
}

-- Chainbound (mob TP move) property tables, keyed by chainbound level
-- (the message-529 param). Verbatim from Ivaar.
local chainbound = {
    [1] = {'Compression','Liquefaction','Induration','Reverberation','Scission'},
    [2] = {'Gravitation','Fragmentation','Distortion',
           'Compression','Liquefaction','Induration','Reverberation','Scission'},
    [3] = {'Light','Darkness',
           'Gravitation','Fragmentation','Distortion',
           'Compression','Liquefaction','Induration','Reverberation','Scission'},
}

-- Aeonic weapons — when equipped AND with an Aftermath buff (270/271/
-- 272) active at the right tier, certain WS get bonus chain props.
-- item_id → weapon flavor string used by skills.lua's `weapon` field
-- on entries that have an `aeonic` property.
local aeonic_weapon = {
    [20515] = 'Godhands',         [20594] = 'Aeneas',
    [20695] = 'Sequence',         [20843] = 'Chango',
    [20890] = 'Anguta',           [20935] = 'Trishula',
    [20977] = 'Heishi Shorinken', [21025] = 'Dojikiri Yasutsuna',
    [21082] = 'Tishtrya',         [21147] = 'Khatvanga',
    [21485] = 'Fomalhaut',        [21694] = 'Lionheart',
    [21753] = 'Tri-Edge',         [22117] = 'Fail-Not',
    [22131] = 'Fail-Not',         [22143] = 'Fomalhaut',
}

-- Aftermath buff ids that gate aeonic bonuses. From Ivaar's buff_dur:
--   163 = Chainbound (40s)
--   164 = Chainbound II (30s)
--   470 = Empyrean Aftermath (60s)
-- Plus 270/271/272 = Mythic AM 1/2/3.
local AFTERMATH_BUFFS = {[163]=40, [164]=30, [470]=60}

-- Skills tables — embedded from Ivaar's skills.lua. Each ability id
-- maps to {en=name, skillchain={'Prop1','Prop2',...}, aeonic=?, weapon=?, delay=?}.
-- aeonic and delay are optional; weapon is set on aeonic-eligible
-- entries so we can match the player's equipped weapon.
local skills = {}

-- Weapon skills. Indexed by WS id. Full set ported from Ivaar.
skills.weapon_skills = {
    [1]   = {en='Combo',               skillchain={'Impaction'}},
    [2]   = {en='Shoulder Tackle',     skillchain={'Reverberation','Impaction'}},
    [3]   = {en='One Inch Punch',      skillchain={'Compression'}},
    [4]   = {en='Backhand Blow',       skillchain={'Detonation'}},
    [5]   = {en='Raging Fists',        skillchain={'Impaction'}},
    [6]   = {en='Spinning Attack',     skillchain={'Liquefaction','Impaction'}},
    [7]   = {en='Howling Fist',        skillchain={'Transfixion','Impaction'}},
    [8]   = {en='Dragon Kick',         skillchain={'Fragmentation'}},
    [9]   = {en='Asuran Fists',        skillchain={'Gravitation','Liquefaction'}},
    [10]  = {en='Final Heaven',        skillchain={'Light','Fusion'}},
    [11]  = {en="Ascetic's Fury",      skillchain={'Fusion','Transfixion'}},
    [12]  = {en='Stringing Pummel',    skillchain={'Gravitation','Liquefaction'}},
    [13]  = {en='Tornado Kick',        skillchain={'Induration','Detonation','Impaction'}},
    [14]  = {en='Victory Smite',       skillchain={'Light','Fragmentation'}},
    [15]  = {en='Shijin Spiral',       skillchain={'Fusion','Reverberation'}, aeonic='Light', weapon='Godhands'},
    [16]  = {en='Wasp Sting',          skillchain={'Scission'}},
    [17]  = {en='Viper Bite',          skillchain={'Scission'}},
    [18]  = {en='Shadowstitch',        skillchain={'Reverberation'}},
    [19]  = {en='Gust Slash',          skillchain={'Detonation'}},
    [20]  = {en='Cyclone',             skillchain={'Detonation','Impaction'}},
    [23]  = {en='Dancing Edge',        skillchain={'Scission','Detonation'}},
    [24]  = {en='Shark Bite',          skillchain={'Fragmentation'}},
    [25]  = {en='Evisceration',        skillchain={'Gravitation','Transfixion'}},
    [26]  = {en='Mercy Stroke',        skillchain={'Darkness','Gravitation'}},
    [27]  = {en='Mandalic Stab',       skillchain={'Fusion','Compression'}},
    [28]  = {en='Mordant Rime',        skillchain={'Fragmentation','Distortion'}},
    [29]  = {en='Pyrrhic Kleos',       skillchain={'Distortion','Scission'}},
    [30]  = {en='Aeolian Edge',        skillchain={'Scission','Detonation','Impaction'}},
    [31]  = {en="Rudra's Storm",       skillchain={'Darkness','Distortion'}},
    [32]  = {en='Fast Blade',          skillchain={'Scission'}},
    [33]  = {en='Burning Blade',       skillchain={'Liquefaction'}},
    [34]  = {en='Red Lotus Blade',     skillchain={'Liquefaction','Detonation'}},
    [35]  = {en='Flat Blade',          skillchain={'Impaction'}},
    [36]  = {en='Shining Blade',       skillchain={'Scission'}},
    [37]  = {en='Seraph Blade',        skillchain={'Scission'}},
    [38]  = {en='Circle Blade',        skillchain={'Reverberation','Impaction'}},
    [40]  = {en='Vorpal Blade',        skillchain={'Scission','Impaction'}},
    [41]  = {en='Swift Blade',         skillchain={'Gravitation'}},
    [42]  = {en='Savage Blade',        skillchain={'Fragmentation','Scission'}},
    [43]  = {en='Knights of Round',    skillchain={'Light','Fusion'}},
    [44]  = {en='Death Blossom',       skillchain={'Fragmentation','Distortion'}},
    [45]  = {en='Atonement',           skillchain={'Fusion','Reverberation'}},
    [46]  = {en='Expiacion',           skillchain={'Distortion','Scission'}},
    [48]  = {en='Hard Slash',          skillchain={'Scission'}},
    [49]  = {en='Power Slash',         skillchain={'Transfixion'}},
    [50]  = {en='Frostbite',           skillchain={'Induration'}},
    [51]  = {en='Freezebite',          skillchain={'Induration','Detonation'}},
    [52]  = {en='Shockwave',           skillchain={'Reverberation'}},
    [53]  = {en='Crescent Moon',       skillchain={'Scission'}},
    [54]  = {en='Sickle Moon',         skillchain={'Scission','Impaction'}},
    [55]  = {en='Spinning Slash',      skillchain={'Fragmentation'}},
    [56]  = {en='Ground Strike',       skillchain={'Fragmentation','Distortion'}},
    [57]  = {en='Scourge',             skillchain={'Light','Fusion'}},
    [58]  = {en='Herculean Slash',     skillchain={'Induration','Detonation','Impaction'}},
    [59]  = {en='Torcleaver',          skillchain={'Light','Distortion'}},
    [60]  = {en='Resolution',          skillchain={'Fragmentation','Scission'}, aeonic='Light', weapon='Lionheart'},
    [61]  = {en='Dimidiation',         skillchain={'Light','Fragmentation'}},
    [64]  = {en='Raging Axe',          skillchain={'Detonation','Impaction'}},
    [65]  = {en='Smash Axe',           skillchain={'Induration','Reverberation'}},
    [66]  = {en='Gale Axe',            skillchain={'Detonation'}},
    [67]  = {en='Avalanche Axe',       skillchain={'Scission','Impaction'}},
    [68]  = {en='Spinning Axe',        skillchain={'Liquefaction','Scission','Impaction'}},
    [69]  = {en='Rampage',             skillchain={'Scission'}},
    [70]  = {en='Calamity',            skillchain={'Scission','Impaction'}},
    [71]  = {en='Mistral Axe',         skillchain={'Fusion'}},
    [72]  = {en='Decimation',          skillchain={'Fusion','Reverberation'}},
    [73]  = {en='Onslaught',           skillchain={'Darkness','Gravitation'}},
    [74]  = {en='Primal Rend',         skillchain={'Gravitation','Reverberation'}},
    [75]  = {en='Bora Axe',            skillchain={'Scission','Detonation'}},
    [76]  = {en='Cloudsplitter',       skillchain={'Darkness','Fragmentation'}},
    [77]  = {en='Ruinator',            skillchain={'Distortion','Detonation'}, aeonic='Darkness', weapon='Tri-Edge'},
    [80]  = {en='Shield Break',        skillchain={'Impaction'}},
    [81]  = {en='Iron Tempest',        skillchain={'Scission'}},
    [82]  = {en='Sturmwind',           skillchain={'Reverberation','Scission'}},
    [83]  = {en='Armor Break',         skillchain={'Impaction'}},
    [84]  = {en='Keen Edge',           skillchain={'Compression'}},
    [85]  = {en='Weapon Break',        skillchain={'Impaction'}},
    [86]  = {en='Raging Rush',         skillchain={'Induration','Reverberation'}},
    [87]  = {en='Full Break',          skillchain={'Distortion'}},
    [88]  = {en='Steel Cyclone',       skillchain={'Distortion','Detonation'}},
    [89]  = {en='Metatron Torment',    skillchain={'Light','Fusion'}},
    [90]  = {en="King's Justice",      skillchain={'Fragmentation','Scission'}},
    [91]  = {en='Fell Cleave',         skillchain={'Scission','Detonation','Impaction'}},
    [92]  = {en="Ukko's Fury",         skillchain={'Light','Fragmentation'}},
    [93]  = {en='Upheaval',            skillchain={'Fusion','Compression'}, aeonic='Light', weapon='Chango'},
    [96]  = {en='Slice',               skillchain={'Scission'}},
    [97]  = {en='Dark Harvest',        skillchain={'Reverberation'}},
    [98]  = {en='Shadow of Death',     skillchain={'Induration','Reverberation'}},
    [99]  = {en='Nightmare Scythe',    skillchain={'Compression','Scission'}},
    [100] = {en='Spinning Scythe',     skillchain={'Reverberation','Scission'}},
    [101] = {en='Vorpal Scythe',       skillchain={'Transfixion','Scission'}},
    [102] = {en='Guillotine',          skillchain={'Induration'}},
    [103] = {en='Cross Reaper',        skillchain={'Distortion'}},
    [104] = {en='Spiral Hell',         skillchain={'Distortion','Scission'}},
    [105] = {en='Catastrophe',         skillchain={'Darkness','Gravitation'}},
    [106] = {en='Insurgency',          skillchain={'Fusion','Compression'}},
    [107] = {en='Infernal Scythe',     skillchain={'Compression','Reverberation'}},
    [108] = {en='Quietus',             skillchain={'Darkness','Distortion'}},
    [109] = {en='Entropy',             skillchain={'Gravitation','Reverberation'}, aeonic='Darkness', weapon='Anguta'},
    [112] = {en='Double Thrust',       skillchain={'Transfixion'}},
    [113] = {en='Thunder Thrust',      skillchain={'Transfixion','Impaction'}},
    [114] = {en='Raiden Thrust',       skillchain={'Transfixion','Impaction'}},
    [115] = {en='Leg Sweep',           skillchain={'Impaction'}},
    [116] = {en='Penta Thrust',        skillchain={'Compression'}},
    [117] = {en='Vorpal Thrust',       skillchain={'Reverberation','Transfixion'}},
    [118] = {en='Skewer',              skillchain={'Transfixion','Impaction'}},
    [119] = {en='Wheeling Thrust',     skillchain={'Fusion'}},
    [120] = {en='Impulse Drive',       skillchain={'Gravitation','Induration'}},
    [121] = {en='Geirskogul',          skillchain={'Light','Distortion'}},
    [122] = {en='Drakesbane',          skillchain={'Fusion','Transfixion'}},
    [123] = {en='Sonic Thrust',        skillchain={'Transfixion','Scission'}},
    [124] = {en="Camlann's Torment",   skillchain={'Light','Fragmentation'}},
    [125] = {en='Stardiver',           skillchain={'Gravitation','Transfixion'}, aeonic='Darkness', weapon='Trishula'},
    [128] = {en='Blade: Rin',          skillchain={'Transfixion'}},
    [129] = {en='Blade: Retsu',        skillchain={'Scission'}},
    [130] = {en='Blade: Teki',         skillchain={'Reverberation'}},
    [131] = {en='Blade: To',           skillchain={'Induration','Detonation'}},
    [132] = {en='Blade: Chi',          skillchain={'Transfixion','Impaction'}},
    [133] = {en='Blade: Ei',           skillchain={'Compression'}},
    [134] = {en='Blade: Jin',          skillchain={'Detonation','Impaction'}},
    [135] = {en='Blade: Ten',          skillchain={'Gravitation'}},
    [136] = {en='Blade: Ku',           skillchain={'Gravitation','Transfixion'}},
    [137] = {en='Blade: Metsu',        skillchain={'Darkness','Fragmentation'}},
    [138] = {en='Blade: Kamu',         skillchain={'Fragmentation','Compression'}},
    [139] = {en='Blade: Yu',           skillchain={'Reverberation','Scission'}},
    [140] = {en='Blade: Hi',           skillchain={'Darkness','Gravitation'}},
    [141] = {en='Blade: Shun',         skillchain={'Fusion','Impaction'}, aeonic='Light', weapon='Heishi Shorinken'},
    [144] = {en='Tachi: Enpi',         skillchain={'Transfixion','Scission'}},
    [145] = {en='Tachi: Hobaku',       skillchain={'Induration'}},
    [146] = {en='Tachi: Goten',        skillchain={'Transfixion','Impaction'}},
    [147] = {en='Tachi: Kagero',       skillchain={'Liquefaction'}},
    [148] = {en='Tachi: Jinpu',        skillchain={'Scission','Detonation'}},
    [149] = {en='Tachi: Koki',         skillchain={'Reverberation','Impaction'}},
    [150] = {en='Tachi: Yukikaze',     skillchain={'Induration','Detonation'}},
    [151] = {en='Tachi: Gekko',        skillchain={'Distortion','Reverberation'}},
    [152] = {en='Tachi: Kasha',        skillchain={'Fusion','Compression'}},
    [153] = {en='Tachi: Kaiten',       skillchain={'Light','Fragmentation'}},
    [154] = {en='Tachi: Rana',         skillchain={'Gravitation','Induration'}},
    [155] = {en='Tachi: Ageha',        skillchain={'Compression','Scission'}},
    [156] = {en='Tachi: Fudo',         skillchain={'Light','Distortion'}},
    [157] = {en='Tachi: Shoha',        skillchain={'Fragmentation','Compression'}, aeonic='Light', weapon='Dojikiri Yasutsuna'},
    [158] = {en='Tachi: Suikawari',    skillchain={'Fusion'}},
    [160] = {en='Shining Strike',      skillchain={'Impaction'}},
    [161] = {en='Seraph Strike',       skillchain={'Impaction'}},
    [162] = {en='Brainshaker',         skillchain={'Reverberation'}},
    [165] = {en='Skullbreaker',        skillchain={'Induration','Reverberation'}},
    [166] = {en='True Strike',         skillchain={'Detonation','Impaction'}},
    [167] = {en='Judgment',            skillchain={'Impaction'}},
    [168] = {en='Hexa Strike',         skillchain={'Fusion'}},
    [169] = {en='Black Halo',          skillchain={'Fragmentation','Compression'}},
    [170] = {en='Randgrith',           skillchain={'Light','Fragmentation'}},
    [172] = {en='Flash Nova',          skillchain={'Induration','Reverberation'}},
    [174] = {en='Realmrazer',          skillchain={'Fusion','Impaction'}, aeonic='Light', weapon='Tishtrya'},
    [175] = {en='Exudation',           skillchain={'Darkness','Fragmentation'}},
    [176] = {en='Heavy Swing',         skillchain={'Impaction'}},
    [177] = {en='Rock Crusher',        skillchain={'Impaction'}},
    [178] = {en='Earth Crusher',       skillchain={'Detonation','Impaction'}},
    [179] = {en='Starburst',           skillchain={'Compression','Reverberation'}},
    [180] = {en='Sunburst',            skillchain={'Compression','Reverberation'}},
    [181] = {en='Shell Crusher',       skillchain={'Detonation'}},
    [182] = {en='Full Swing',          skillchain={'Liquefaction','Impaction'}},
    [184] = {en='Retribution',         skillchain={'Gravitation','Reverberation'}},
    [185] = {en='Gate of Tartarus',    skillchain={'Darkness','Distortion'}},
    [186] = {en='Vidohunir',           skillchain={'Fragmentation','Distortion'}},
    [187] = {en='Garland of Bliss',    skillchain={'Fusion','Reverberation'}},
    [188] = {en='Omniscience',         skillchain={'Gravitation','Transfixion'}},
    [189] = {en='Cataclysm',           skillchain={'Compression','Reverberation'}},
    [191] = {en='Shattersoul',         skillchain={'Gravitation','Induration'}, aeonic='Darkness', weapon='Khatvanga'},
    [192] = {en='Flaming Arrow',       skillchain={'Liquefaction','Transfixion'}},
    [193] = {en='Piercing Arrow',      skillchain={'Reverberation','Transfixion'}},
    [194] = {en='Dulling Arrow',       skillchain={'Liquefaction','Transfixion'}},
    [196] = {en='Sidewinder',          skillchain={'Reverberation','Transfixion','Detonation'}},
    [197] = {en='Blast Arrow',         skillchain={'Induration','Transfixion'}},
    [198] = {en='Arching Arrow',       skillchain={'Fusion'}},
    [199] = {en='Empyreal Arrow',      skillchain={'Fusion','Transfixion'}},
    [200] = {en='Namas Arrow',         skillchain={'Light','Distortion'}},
    [201] = {en='Refulgent Arrow',     skillchain={'Reverberation','Transfixion'}},
    [202] = {en="Jishnu's Radiance",   skillchain={'Light','Fusion'}},
    [203] = {en='Apex Arrow',          skillchain={'Fragmentation','Transfixion'}, aeonic='Light', weapon='Fail-Not'},
    [208] = {en='Hot Shot',            skillchain={'Liquefaction','Transfixion'}},
    [209] = {en='Split Shot',          skillchain={'Reverberation','Transfixion'}},
    [210] = {en='Sniper Shot',         skillchain={'Liquefaction','Transfixion'}},
    [212] = {en='Slug Shot',           skillchain={'Reverberation','Transfixion','Detonation'}},
    [213] = {en='Blast Shot',          skillchain={'Induration','Transfixion'}},
    [214] = {en='Heavy Shot',          skillchain={'Fusion'}},
    [215] = {en='Detonator',           skillchain={'Fusion','Transfixion'}},
    [216] = {en='Coronach',            skillchain={'Darkness','Fragmentation'}},
    [217] = {en='Trueflight',          skillchain={'Fragmentation','Scission'}},
    [218] = {en='Leaden Salute',       skillchain={'Gravitation','Transfixion'}},
    [219] = {en='Numbing Shot',        skillchain={'Induration','Detonation','Impaction'}},
    [220] = {en='Wildfire',            skillchain={'Darkness','Gravitation'}},
    [221] = {en='Last Stand',          skillchain={'Fusion','Reverberation'}, aeonic='Light', weapon='Fomalhaut'},
    [224] = {en='Exenterator',         skillchain={'Fragmentation','Scission'}, aeonic='Light', weapon='Aeneas'},
    [225] = {en='Chant du Cygne',      skillchain={'Light','Distortion'}},
    [226] = {en='Requiescat',          skillchain={'Gravitation','Scission'}, aeonic='Darkness', weapon='Sequence'},
    [227] = {en='Knights of Rotund',   skillchain={'Light'}},
    [228] = {en='Final Paradise',      skillchain={'Light'}},
    [238] = {en='Uriel Blade',         skillchain={'Light','Fragmentation'}},
    [239] = {en='Glory Slash',         skillchain={'Light','Fusion'}},
}

-- Spells. SCH Immanence (via elements 0-7), BLU set spells, BLM/RDM
-- nukes — anything with a skillchain property.
skills.spells = {
    -- BLM/RDM single-element nukes (all six tiers each)
    [144]={en='Fire',skillchain={'Liquefaction'}},     [145]={en='Fire II',skillchain={'Liquefaction'}},
    [146]={en='Fire III',skillchain={'Liquefaction'}}, [147]={en='Fire IV',skillchain={'Liquefaction'}},
    [148]={en='Fire V',skillchain={'Liquefaction'}},
    [149]={en='Blizzard',skillchain={'Induration'}},   [150]={en='Blizzard II',skillchain={'Induration'}},
    [151]={en='Blizzard III',skillchain={'Induration'}},[152]={en='Blizzard IV',skillchain={'Induration'}},
    [153]={en='Blizzard V',skillchain={'Induration'}},
    [154]={en='Aero',skillchain={'Detonation'}},       [155]={en='Aero II',skillchain={'Detonation'}},
    [156]={en='Aero III',skillchain={'Detonation'}},   [157]={en='Aero IV',skillchain={'Detonation'}},
    [158]={en='Aero V',skillchain={'Detonation'}},
    [159]={en='Stone',skillchain={'Scission'}},        [160]={en='Stone II',skillchain={'Scission'}},
    [161]={en='Stone III',skillchain={'Scission'}},    [162]={en='Stone IV',skillchain={'Scission'}},
    [163]={en='Stone V',skillchain={'Scission'}},
    [164]={en='Thunder',skillchain={'Impaction'}},     [165]={en='Thunder II',skillchain={'Impaction'}},
    [166]={en='Thunder III',skillchain={'Impaction'}}, [167]={en='Thunder IV',skillchain={'Impaction'}},
    [168]={en='Thunder V',skillchain={'Impaction'}},
    [169]={en='Water',skillchain={'Reverberation'}},   [170]={en='Water II',skillchain={'Reverberation'}},
    [171]={en='Water III',skillchain={'Reverberation'}},[172]={en='Water IV',skillchain={'Reverberation'}},
    [173]={en='Water V',skillchain={'Reverberation'}},
    -- SCH helix spells (these are what SCH Immanence converts)
    [278]={en='Geohelix',     skillchain={'Scission'},      delay=5},
    [279]={en='Hydrohelix',   skillchain={'Reverberation'}, delay=5},
    [280]={en='Anemohelix',   skillchain={'Detonation'},    delay=5},
    [281]={en='Pyrohelix',    skillchain={'Liquefaction'},  delay=5},
    [282]={en='Cryohelix',    skillchain={'Induration'},    delay=5},
    [283]={en='Ionohelix',    skillchain={'Impaction'},     delay=5},
    [284]={en='Noctohelix',   skillchain={'Compression'},   delay=5},
    [285]={en='Luminohelix',  skillchain={'Transfixion'},   delay=5},
    -- BLU set spells with skillchain properties (most-used subset)
    [503]={en='Impact',             skillchain={'Compression'}},
    [519]={en='Screwdriver',        skillchain={'Transfixion','Scission'}},
    [527]={en='Smite of Rage',      skillchain={'Detonation'}},
    [529]={en='Bludgeon',           skillchain={'Liquefaction'}},
    [539]={en='Terror Touch',       skillchain={'Compression','Reverberation'}},
    [540]={en='Spinal Cleave',      skillchain={'Scission','Detonation'}},
    [543]={en='Mandibular Bite',    skillchain={'Induration'}},
    [545]={en='Sickle Slash',       skillchain={'Compression'}},
    [551]={en='Power Attack',       skillchain={'Reverberation'}},
    [554]={en='Death Scissors',     skillchain={'Compression','Reverberation'}},
    [560]={en='Frenetic Rip',       skillchain={'Induration'}},
    [564]={en='Body Slam',          skillchain={'Impaction'}},
    [567]={en='Helldive',           skillchain={'Transfixion'}},
    [569]={en='Jet Stream',         skillchain={'Impaction'}},
    [577]={en='Foot Kick',          skillchain={'Detonation'}},
    [585]={en='Ram Charge',         skillchain={'Fragmentation'}},
    [587]={en='Claw Cyclone',       skillchain={'Scission'}},
    [589]={en='Dimensional Death',  skillchain={'Transfixion','Impaction'}},
    [594]={en='Uppercut',           skillchain={'Liquefaction','Impaction'}},
    [596]={en='Pinecone Bomb',      skillchain={'Liquefaction'}},
    [597]={en='Sprout Smack',       skillchain={'Reverberation'}},
    [599]={en='Queasyshroom',       skillchain={'Compression'}},
    [603]={en='Wild Oats',          skillchain={'Transfixion'}},
    [611]={en='Disseverment',       skillchain={'Distortion'}},
    [617]={en='Vertical Cleave',    skillchain={'Gravitation'}},
    [620]={en='Battle Dance',       skillchain={'Impaction'}},
    [622]={en='Grand Slam',         skillchain={'Induration'}},
    [623]={en='Head Butt',          skillchain={'Impaction'}},
    [628]={en='Frypan',             skillchain={'Impaction'}},
    [631]={en='Hydro Shot',         skillchain={'Reverberation'}},
    [638]={en='Feather Storm',      skillchain={'Transfixion'}},
    [640]={en='Tail Slap',          skillchain={'Reverberation'}},
    [641]={en='Hysteric Barrage',   skillchain={'Detonation'}},
    [643]={en='Cannonball',         skillchain={'Fusion'}},
    [650]={en='Seedspray',          skillchain={'Induration','Detonation'}},
    [652]={en='Spiral Spin',        skillchain={'Transfixion'}},
    [653]={en='Asuran Claws',       skillchain={'Liquefaction','Impaction'}},
    [654]={en='Sub-zero Smash',     skillchain={'Fragmentation'}},
    [665]={en='Final Sting',        skillchain={'Fusion'}},
    [666]={en='Goblin Rush',        skillchain={'Fusion','Impaction'}},
    [667]={en='Vanity Dive',        skillchain={'Transfixion','Scission'}},
    [669]={en='Whirl of Rage',      skillchain={'Scission','Detonation'}},
    [670]={en='Benthic Typhoon',    skillchain={'Gravitation','Transfixion'}},
    [673]={en='Quad. Continuum',    skillchain={'Distortion','Scission'}},
    [677]={en='Empty Thrash',       skillchain={'Compression','Scission'}},
    [682]={en='Delta Thrust',       skillchain={'Liquefaction','Detonation'}},
    [688]={en='Heavy Strike',       skillchain={'Fragmentation','Transfixion'}},
    [692]={en='Sudden Lunge',       skillchain={'Detonation'}},
    [693]={en='Quadrastrike',       skillchain={'Liquefaction','Scission','Impaction'}},
    [697]={en='Amorphic Spikes',    skillchain={'Gravitation'}},
    [699]={en='Barbed Crescent',    skillchain={'Distortion','Scission'}},
    [704]={en='Paralyzing Triad',   skillchain={'Gravitation'}},
    [706]={en='Glutinous Dart',     skillchain={'Fragmentation'}},
    [709]={en='Thrashing Assault',  skillchain={'Fusion'}},
    [714]={en='Sinker Drill',       skillchain={'Gravitation','Reverberation'}},
    [723]={en='Saurian Slide',      skillchain={'Fragmentation','Distortion'}},
    [740]={en='Tourbillion',        skillchain={'Light','Fragmentation'}},
    [742]={en='Bilgestorm',         skillchain={'Darkness','Gravitation'}},
    [743]={en='Bloodrake',          skillchain={'Darkness','Distortion'}},
    -- SCH helix II spells
    [885]={en='Geohelix II',    skillchain={'Scission'},      delay=5},
    [886]={en='Hydrohelix II',  skillchain={'Reverberation'}, delay=5},
    [887]={en='Anemohelix II',  skillchain={'Detonation'},    delay=5},
    [888]={en='Pyrohelix II',   skillchain={'Liquefaction'},  delay=5},
    [889]={en='Cryohelix II',   skillchain={'Induration'},    delay=5},
    [890]={en='Ionohelix II',   skillchain={'Impaction'},     delay=5},
    [891]={en='Noctohelix II',  skillchain={'Compression'},   delay=5},
    [892]={en='Luminohelix II', skillchain={'Transfixion'},   delay=5},
}

-- BST job-ability pet skills with SC properties. Pet uses Spur, master
-- chooses Sic / Ready, this is the ready-table SC mapping. Verbatim
-- from Ivaar.
skills.job_abilities = {
    [513]={en='Poison Nails',        skillchain={'Transfixion'}},
    [521]={en='Regal Scratch',       skillchain={'Scission'}},
    [528]={en='Moonlit Charge',      skillchain={'Compression'}},
    [529]={en='Crescent Fang',       skillchain={'Transfixion'}},
    [534]={en='Eclipse Bite',        skillchain={'Gravitation','Scission'}},
    [544]={en='Punch',               skillchain={'Liquefaction'}},
    [546]={en='Burning Strike',     skillchain={'Impaction'}},
    [547]={en='Double Punch',        skillchain={'Compression'}},
    [550]={en='Flaming Crush',       skillchain={'Fusion','Reverberation'}},
    [560]={en='Rock Throw',          skillchain={'Scission'}},
    [562]={en='Rock Buster',         skillchain={'Reverberation'}},
    [563]={en='Megalith Throw',      skillchain={'Induration'}},
    [566]={en='Mountain Buster',     skillchain={'Gravitation','Induration'}},
    [570]={en='Crag Throw',          skillchain={'Gravitation','Scission'}},
    [576]={en='Barracuda Dive',      skillchain={'Reverberation'}},
    [578]={en='Tail Whip',           skillchain={'Detonation'}},
    [582]={en='Spinning Dive',       skillchain={'Distortion','Detonation'}},
    [592]={en='Claw',                skillchain={'Detonation'}},
    [598]={en='Predator Claws',      skillchain={'Fragmentation','Scission'}},
    [608]={en='Axe Kick',            skillchain={'Induration'}},
    [612]={en='Double Slap',         skillchain={'Scission'}},
    [614]={en='Rush',                skillchain={'Distortion','Scission'}},
    [624]={en='Shock Strike',        skillchain={'Impaction'}},
    [630]={en='Chaotic Strike',      skillchain={'Fragmentation','Transfixion'}},
    [634]={en='Volt Strike',         skillchain={'Fragmentation','Scission'}},
    [656]={en='Camisado',            skillchain={'Compression'}},
    [667]={en='Blindside',           skillchain={'Gravitation','Transfixion'}},
    [672]={en='Foot Kick',           skillchain={'Reverberation'}},
    [674]={en='Whirl Claws',         skillchain={'Impaction'}},
    [675]={en='Head Butt',           skillchain={'Detonation'}},
    [677]={en='Wild Oats',           skillchain={'Transfixion'}},
    [678]={en='Leaf Dagger',         skillchain={'Scission'}},
    [681]={en='Razor Fang',          skillchain={'Impaction'}},
    [682]={en='Claw Cyclone',        skillchain={'Scission'}},
    [683]={en='Tail Blow',           skillchain={'Impaction'}},
    [685]={en='Blockhead',           skillchain={'Reverberation'}},
    [686]={en='Brain Crush',         skillchain={'Liquefaction'}},
    [689]={en='Lamb Chop',           skillchain={'Impaction'}},
    [691]={en='Sheep Charge',        skillchain={'Reverberation'}},
    [695]={en='Big Scissors',        skillchain={'Scission'}},
    [698]={en='Needleshot',          skillchain={'Transfixion'}},
    [699]={en='??? Needles',         skillchain={'Darkness','Fragmentation'}},
    [700]={en='Frogkick',            skillchain={'Compression'}},
    [707]={en='Power Attack',        skillchain={'Reverberation'}},
    [709]={en='Rhino Attack',        skillchain={'Detonation'}},
    [717]={en='Mandibular Bite',     skillchain={'Detonation'}},
    [723]={en='Nimble Snap',         skillchain={'Impaction'}},
    [724]={en='Cyclotail',           skillchain={'Impaction'}},
    [726]={en='Double Claw',         skillchain={'Liquefaction'}},
    [727]={en='Grapple',             skillchain={'Reverberation'}},
    [728]={en='Spinning Top',        skillchain={'Impaction'}},
    [732]={en='Suction',             skillchain={'Compression'}},
    [736]={en='Sudden Lunge',        skillchain={'Impaction'}},
    [737]={en='Spiral Spin',         skillchain={'Scission'}},
    [743]={en='Scythe Tail',         skillchain={'Liquefaction'}},
    [744]={en='Ripper Fang',         skillchain={'Induration'}},
    [745]={en='Chomp Rush',          skillchain={'Darkness','Gravitation'}},
    [749]={en='Back Heel',           skillchain={'Reverberation'}},
    [753]={en='Tortoise Stomp',      skillchain={'Liquefaction'}},
    [756]={en='Wing Slap',           skillchain={'Gravitation','Liquefaction'}},
    [757]={en='Beak Lunge',          skillchain={'Scission'}},
    [759]={en='Recoil Dive',         skillchain={'Transfixion'}},
    [761]={en='Sensilla Blades',     skillchain={'Scission'}},
    [762]={en='Tegmina Buffet',      skillchain={'Distortion','Detonation'}},
    [764]={en='Swooping Frenzy',     skillchain={'Fusion','Reverberation'}},
    [765]={en='Sweeping Gouge',      skillchain={'Induration'}},
    [767]={en='Pentapeck',           skillchain={'Light','Distortion'}},
    [768]={en='Tickling Tendrils',   skillchain={'Impaction'}},
    [772]={en='Somersault',          skillchain={'Compression'}},
    [776]={en='Pecking Flurry',      skillchain={'Transfixion'}},
    [777]={en='Sickle Slash',        skillchain={'Transfixion'}},
    [780]={en='Regal Gash',          skillchain={'Distortion','Detonation'}},
    [961]={en='Welt',                skillchain={'Scission'}},
    [964]={en='Roundhouse',          skillchain={'Detonation'}},
    [970]={en='Hysteric Assault',    skillchain={'Fragmentation','Transfixion'}},
}

-- SCH Immanence: the resource is `elements` keyed 0-7. Maps SCH spell
-- after Immanence pre-cast to its SC property.
skills.elements = {
    [0] = {en='Fire',     skillchain={'Liquefaction'}},
    [1] = {en='Ice',      skillchain={'Induration'}},
    [2] = {en='Wind',     skillchain={'Detonation'}},
    [3] = {en='Earth',    skillchain={'Scission'}},
    [4] = {en='Lightning',skillchain={'Impaction'}},
    [5] = {en='Water',    skillchain={'Reverberation'}},
    [6] = {en='Light',    skillchain={'Transfixion'}},
    [7] = {en='Dark',     skillchain={'Compression'}},
}

-- ─────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────

local SETTINGS_DEFAULT = {
    show_panel       = true,    -- master on/off for the panel
    track_sc         = true,    -- show resonating props + window + step
    track_magic_burst = true,   -- show burst window after a close
    show_props       = true,    -- per-info: properties row
    show_timer       = true,    -- per-info: window timer row
    show_step        = true,    -- per-info: current step row
    show_weapon      = true,    -- per-info: WS suggestions
    show_spell       = true,    -- per-info: spell suggestions (SCH/BLU)
    show_pet         = true,    -- per-info: pet ability suggestions (BST/SMN)
}

-- Per-job overrides. Each job can have its own subset of these keys
-- set; missing keys fall back to global. Persisted by Python.
local per_job_settings = {}

-- Global "current" settings — what the panel is actually using right
-- now. Recomputed when job changes from `global ⊕ per_job_settings[job]`.
local current_settings = {}
for k, v in pairs(SETTINGS_DEFAULT) do current_settings[k] = v end

local resonating = {}        -- target_id → resonating state table
local active_target_id = nil -- last known engaged target id

-- Player + weapon info.
local player_id   = nil
local main_job    = nil   -- short name e.g. 'SAM'
local main_weapon_id   = 0
local main_weapon_bag  = 0
local range_weapon_id  = 0
local range_weapon_bag = 0
local aeonic_flavor = nil  -- string ('Heishi Shorinken', 'Lionheart', ...)
                            -- if player's equipped weapon is aeonic, else nil

-- Buff tracking for aeonic Aftermath (270/271/272) and Chainbound
-- (163/164/470). Keyed by buff_id → expiry_unix.
local player_buffs = {}

-- UDP socket. Set by init() once the addon is loaded.
local socket = require('socket')
local udp = nil

-- Last-emitted snapshot. Lets us skip re-sending unchanged state at
-- 10Hz. Hashes the (target, step, props, closed) tuple.
local last_emit_key = nil
local last_emit_time = 0

-- Last computed suggestions, keyed by (resonating_id, equipped_ws_hash,
-- job, aeonic_flavor). Invalidated when any of those change.
local last_suggest_key = nil
local last_suggest_text = nil

-- ─────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────

-- Convert a numeric msg_id from add_effect_message into a skillchain
-- name string. Returns nil if the id isn't a known SC id.
local function sc_name_from_msgid(msg_id)
    if not msg_id then return nil end
    if msg_id >= 288 and msg_id <= 301 then
        return skillchain_names[msg_id - 287]
    elseif msg_id >= 385 and msg_id <= 397 then
        -- Mob-side close. Offset by 384.
        return skillchain_names[msg_id - 384]
    elseif lv4_sc_by_msgid[msg_id] then
        return lv4_sc_by_msgid[msg_id]
    end
    return nil
end

-- Test whether the player's aeonic Aftermath stack tier is high enough
-- to grant bonus chain properties on the given step. Ivaar's rule:
--   step=1 → need AM tier 1+
--   step=2 → need AM tier 2+
--   step=3 → need AM tier 3
-- Buff 270 = AM1, 271 = AM2, 272 = AM3. Returns true if eligible.
local function aeonic_am_active(step)
    if not step then return false end
    for buff_id = 270, 272 do
        if player_buffs[buff_id] then
            local tier = buff_id - 269  -- 270 → 1, 271 → 2, 272 → 3
            return tier >= step
        end
    end
    return false
end

-- Resolve an ability's effective chain properties accounting for
-- aeonic bonuses. If the ability has an aeonic property AND the actor
-- is the player AND the player has the matching aeonic weapon equipped,
-- the bonus property is appended. Returns the property list.
local function effective_props(ability, actor_id)
    if not ability then return nil end
    if ability.aeonic and ability.weapon
            and ability.weapon == aeonic_flavor
            and actor_id == player_id then
        return {ability.skillchain[1], ability.skillchain[2], ability.aeonic}
    end
    return ability.skillchain
end

-- Given an "old" property list (currently resonating) and "new" list
-- (just-applied WS / spell), find the first (i,j) combination that
-- forms a chain. Returns (resulting_level, resulting_chain_name,
-- aeonic_followup_name?) or nil if no chain forms.
local function check_props(old, new)
    if not old or not new then return nil end
    for k = 1, #old do
        local first = old[k]
        local combo = sc_info[first]
        if combo then
            for i = 1, #new do
                local second = new[i]
                local result = combo[second]
                if result then
                    return result[1], result[2], result[3]
                end
                -- If we're at high step and same level, stop here so we
                -- don't accidentally promote into a non-existing chain.
                if #old > 3 and sc_info[second]
                        and combo.lvl == sc_info[second].lvl then
                    break
                end
            end
        end
    end
    return nil
end

-- Set/refresh resonating state for a target. delay = wait period
-- before the SC window opens (ranges 2..9s depending on action type
-- and step). step = chain step (1..5). closed = whether the chain has
-- reached its terminal level. bound = chainbound level if mob-bound.
local function apply_properties(target_id, resource, action_id,
                                 properties, delay, step, closed, bound)
    if not target_id then return end
    local clock = os.clock()
    resonating[target_id] = {
        res         = resource,
        id          = action_id,
        active      = properties,
        delay_until = clock + delay,
        window_end  = clock + delay + 8 - (step or 1),
        step        = step,
        closed      = closed or false,
        bound       = bound,
        -- Record creation time so we can prune stale entries that
        -- never received a target-update for ages.
        created     = clock,
    }
    -- Invalidate suggestion cache so it recomputes next tick.
    last_suggest_key = nil
end

-- Color codes from Ivaar (FFXI element palette). Used when Python
-- requests colored output, but we emit raw color names — Python does
-- the color mapping. Kept here for reference / future use.
-- local colors = { ... }

-- ─────────────────────────────────────────────────────────────────────
-- Action handler — called per-incoming-action by OmniWatch.lua
-- ─────────────────────────────────────────────────────────────────────

-- Map parse_action category → resource table key.
local CATEGORY_RESOURCE = {
    [3]  = 'weapon_skills',     -- weapon skill finish
    [4]  = 'spells',            -- spell finish
    [6]  = 'job_abilities',     -- ability (BST ready, etc.)
    [11] = 'monster_abilities', -- mob TP move finish
    [13] = 'job_abilities',     -- avatar TP move (SMN BP)
    [14] = 'job_abilities',     -- ability unblinkable
}

function M.handle_action(act)
    if not act or not act.targets or not act.targets[1] then return end
    if not act.category then return end
    local resource = CATEGORY_RESOURCE[act.category]
    if not resource then return end
    if act.param == 0 then return end   -- no action, just chatter

    local actor = act.actor_id
    local target = act.targets[1]
    local action = target.actions and target.actions[1]
    if not action then return end
    local target_id = target.id
    local action_id = act.param

    -- For helix and BLU dual-ID spells, the "real" id is sometimes
    -- carried per-action; prefer that when present.
    if action.param and action.param ~= 0
            and (resource == 'spells' or resource == 'job_abilities') then
        -- some spells carry their canonical id here; keep act.param
        -- as the fallback. Helix uses act.param, BLU usually too.
    end

    local message_id = action.message
    local add_eff_msg = action.has_add_effect and action.add_effect_message or nil

    local ability = skills[resource] and skills[resource][action_id]

    -- ── Path 1: SC closes / extends ───────────────────────────────
    -- An add_effect_message in the skillchain range means the chain
    -- just resolved at the next level.
    if add_eff_msg and SKILLCHAIN_MSG_IDS[add_eff_msg] then
        local sc_name = sc_name_from_msgid(add_eff_msg)
        if sc_name and sc_info[sc_name] then
            local level = sc_info[sc_name].lvl or 1
            local reson = resonating[target_id]
            local delay = (ability and ability.delay) or 3
            local step = (reson and reson.step or 1) + 1
            -- Aeonic-step recomputation: at level 3 with an ability
            -- present and a resonating state, re-check whether the
            -- aeonic bonus would have promoted the result.
            if level == 3 and reson and ability then
                local recomputed = check_props(
                    reson.active, effective_props(ability, actor))
                if recomputed then level = recomputed end
            end
            local closed = step > 5 or level == 4
            apply_properties(target_id, resource, action_id,
                {sc_name}, delay, step, closed)
            return
        end
    end

    -- ── Path 2: SC opens (no add_effect, just the lands-with-effect
    --           message id). The resonating props are the WS's own
    --           property list, optionally with aeonic bonus.
    if ability and (MESSAGE_IDS[message_id]
                    or (message_id == 2  -- "X uses Y on Z" generic
                        and player_buffs and
                        (player_buffs[164] or player_buffs[470]
                         or player_buffs[163]))) then
        apply_properties(target_id, resource, action_id,
            effective_props(ability, actor),
            (ability.delay or 3), 1)
        return
    end

    -- ── Path 3: Chainbound (mob TP move with message_id 529).
    --           param carries the bound level (1..3).
    if message_id == 529 and action.param and chainbound[action.param] then
        apply_properties(target_id, resource, action_id,
            chainbound[action.param], 2, 1, false, action.param)
        return
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Incoming chunk handler — equipment + buff tracking
-- ─────────────────────────────────────────────────────────────────────

local function refresh_aeonic_flavor()
    -- Main weapon first, then range (e.g. RNG/COR with aeonic ranged).
    local main_item = main_weapon_id ~= 0
        and windower.ffxi.get_items(main_weapon_bag, main_weapon_id)
    local main_id = main_item and main_item.id or 0
    if aeonic_weapon[main_id] then
        aeonic_flavor = aeonic_weapon[main_id]
        return
    end
    local range_item = range_weapon_id ~= 0
        and windower.ffxi.get_items(range_weapon_bag, range_weapon_id)
    local range_id = range_item and range_item.id or 0
    if aeonic_weapon[range_id] then
        aeonic_flavor = aeonic_weapon[range_id]
        return
    end
    aeonic_flavor = nil
end

function M.handle_chunk(id, data)
    if id == 0x050 then
        -- Equipment slot change. Byte 5 = item slot in bag,
        -- byte 6 = equipment slot (0=main, 2=range), byte 7 = bag id.
        local equip_slot = data:byte(6)
        if equip_slot == 0 then
            main_weapon_id  = data:byte(5)
            main_weapon_bag = data:byte(7)
            refresh_aeonic_flavor()
        elseif equip_slot == 2 then
            range_weapon_id  = data:byte(5)
            range_weapon_bag = data:byte(7)
            refresh_aeonic_flavor()
        end
    elseif id == 0x063 and data:byte(5) == 9 then
        -- Buff list refresh (sub-type 9). 32 buff slots starting at
        -- byte 9, each 2 bytes little-endian.
        local new_buffs = {}
        for n = 1, 32 do
            local lo = data:byte(8 + n * 2 + 1) or 0
            local hi = data:byte(8 + n * 2 + 2) or 0
            local buff_id = lo + 256 * hi
            -- Only track buffs relevant to skillchain logic.
            if AFTERMATH_BUFFS[buff_id]
                    or (buff_id >= 270 and buff_id <= 272) then
                new_buffs[buff_id] = true
            end
        end
        player_buffs = new_buffs
        last_suggest_key = nil   -- aftermath state may have changed
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Suggestion computation
-- ─────────────────────────────────────────────────────────────────────

-- For each available ability id, see if it would chain off the current
-- resonating props. Returns a list of formatted suggestion strings
-- like "Resolution      → Lv.3 Light", grouped by chain level (Lv.4
-- first, Lv.1 last).
local function add_suggestions(out, ability_ids, active_props, resource, aeonic_eligible)
    if not ability_ids or not active_props then return end
    local tt = {{}, {}, {}, {}}   -- buckets by chain level
    local resmap = skills[resource]
    if not resmap then return end
    for _, ability_id in ipairs(ability_ids) do
        local skill = resmap[ability_id]
        if skill then
            local effective = effective_props(skill, player_id)
            local lvl, prop, aeonic_followup = check_props(active_props, effective)
            if lvl and prop then
                if aeonic_eligible and aeonic_followup then
                    prop = aeonic_followup
                end
                -- Resolve the ability's display name. Fall back to
                -- the in-table en if res doesn't have it.
                local name
                if res[resource] and res[resource][ability_id]
                        and res[resource][ability_id].name then
                    name = res[resource][ability_id].name
                else
                    name = skill.en
                end
                if tt[lvl] then
                    table.insert(tt[lvl],
                        string.format('%-18s|Lv.%d %s', name, lvl, prop))
                end
            end
        end
    end
    -- Emit high-level first.
    for x = 4, 1, -1 do
        for k = #tt[x], 1, -1 do
            out[#out + 1] = tt[x][k]
        end
    end
end

local function compute_suggestions(reson)
    local out = {}
    -- Spells (SCH Immanence elements 0..7, BLU set spells).
    if current_settings.show_spell and main_job == 'SCH' then
        add_suggestions(out, {0,1,2,3,4,5,6,7}, reson.active, 'elements')
    elseif current_settings.show_spell and main_job == 'BLU' then
        local mj = windower.ffxi.get_mjob_data()
        if mj and mj.spells then
            add_suggestions(out, mj.spells, reson.active, 'spells')
        end
    end
    -- Pet abilities (BST/SMN with active pet).
    if current_settings.show_pet then
        local pet = windower.ffxi.get_mob_by_target('pet')
        if pet then
            local jas = windower.ffxi.get_abilities()
            if jas and jas.job_abilities then
                add_suggestions(out, jas.job_abilities,
                    reson.active, 'job_abilities')
            end
        end
    end
    -- Weapon skills.
    if current_settings.show_weapon then
        local jas = windower.ffxi.get_abilities()
        if jas and jas.weapon_skills then
            add_suggestions(out, jas.weapon_skills,
                reson.active, 'weapon_skills',
                aeonic_flavor and aeonic_am_active(reson.step))
        end
    end
    return out
end

-- ─────────────────────────────────────────────────────────────────────
-- UDP emission
-- ─────────────────────────────────────────────────────────────────────

local function emit_line(line)
    if udp then
        pcall(function() udp:send(line) end)
    end
end

local function emit_settings()
    -- Compact CSV of the booleans Python cares about.
    local cs = current_settings
    local function b(v) return v and '1' or '0' end
    emit_line(string.format('SETTINGS|%s,%s,%s,%s,%s,%s,%s,%s,%s',
        b(cs.show_panel),  b(cs.track_sc),    b(cs.track_magic_burst),
        b(cs.show_props),  b(cs.show_timer),  b(cs.show_step),
        b(cs.show_weapon), b(cs.show_spell),  b(cs.show_pet)))
end

local function emit_job()
    if main_job then
        emit_line(string.format('JOB|%s', main_job))
    end
end

-- Returns the current "target of interest" id — the player's target
-- if they have one with a resonating entry, otherwise the most-
-- recently-updated mob with resonating state.
local function pick_active_target()
    local targ = windower.ffxi.get_mob_by_target('t', 'bt')
    if targ and resonating[targ.id] then
        return targ.id
    end
    -- Fall back to the mob with the latest resonating update.
    local best_id, best_when = nil, -1
    for tid, r in pairs(resonating) do
        if r.created > best_when then
            best_id, best_when = tid, r.created
        end
    end
    return best_id
end

function M.tick(now_clock)
    if not udp then return end
    now_clock = now_clock or os.clock()
    -- Garbage-collect entries that haven't been touched in 30s
    -- (covers the case where a mob dies and we never see the death
    -- packet, or where the player switches zones mid-fight).
    local stale_cutoff = now_clock - 30
    for tid, r in pairs(resonating) do
        if r.created < stale_cutoff then
            resonating[tid] = nil
        end
    end

    local targ_id = pick_active_target()
    local reson = targ_id and resonating[targ_id]

    -- Nothing to show — emit an empty packet (so Python clears its
    -- panel) at most once per second.
    if not reson then
        if last_emit_key ~= 'EMPTY' and (os.clock() - last_emit_time) > 1.0 then
            emit_line('SC_EMPTY|0')
            last_emit_key = 'EMPTY'
            last_emit_time = os.clock()
        end
        return
    end

    -- Compose a state key. If nothing meaningful has changed since
    -- the last emit, skip the rebroadcast.
    local props_str = table.concat(reson.active or {}, ',')
    local key = string.format('%d|%d|%s|%s|%d',
        targ_id, reson.step or 0, props_str,
        reson.closed and '1' or '0', reson.bound or 0)
    local now_t = os.clock()
    if key ~= last_emit_key or (now_t - last_emit_time) > 0.5 then
        local delay_ts = math.floor(os.time() + (reson.delay_until - now_t))
        local win_ts   = math.floor(os.time() + (reson.window_end  - now_t))
        emit_line(string.format(
            'SC|%d|%d|%d|%d|%s|%s|%d|%d|%s',
            targ_id,
            reson.step or 0,
            delay_ts, win_ts,
            props_str,
            reson.closed and '1' or '0',
            reson.bound or 0,
            reson.id or 0,
            reson.res or ''))
        last_emit_key = key
        last_emit_time = now_t
    end

    -- Suggestions. Recompute when the cache is invalidated.
    if last_suggest_key ~= key then
        local lines = compute_suggestions(reson)
        emit_line('SUGGEST_BEGIN')
        for _, l in ipairs(lines) do
            emit_line('SUGGEST|' .. l)
        end
        emit_line('SUGGEST_END')
        last_suggest_key = key
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Settings API (called from OmniWatch slash commands / Python inbound)
-- ─────────────────────────────────────────────────────────────────────

function M.set_setting(key, value)
    if SETTINGS_DEFAULT[key] == nil then return false end
    current_settings[key] = value and true or false
    -- Persist into the per-job override so it follows the job.
    if main_job then
        per_job_settings[main_job] = per_job_settings[main_job] or {}
        per_job_settings[main_job][key] = current_settings[key]
    end
    last_suggest_key = nil
    emit_settings()
    return true
end

function M.get_setting(key)
    return current_settings[key]
end

function M.handle_job_change()
    local p = windower.ffxi.get_player()
    if not p then return end
    local new_job = p.main_job
    if new_job ~= main_job then
        main_job = new_job
        -- Re-apply per-job overrides on top of defaults.
        for k, v in pairs(SETTINGS_DEFAULT) do
            current_settings[k] = v
        end
        if per_job_settings[main_job] then
            for k, v in pairs(per_job_settings[main_job]) do
                current_settings[k] = v
            end
        end
        emit_job()
        emit_settings()
        last_suggest_key = nil
    end
end

function M.status()
    return {
        player_id = player_id, main_job = main_job,
        aeonic_flavor = aeonic_flavor,
        main_weapon_id = main_weapon_id,
        range_weapon_id = range_weapon_id,
        active_target = active_target_id,
        resonating_count = (function()
            local n = 0; for _ in pairs(resonating) do n = n + 1 end
            return n
        end)(),
        settings = current_settings,
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Init — called by OmniWatch.lua after this module is required
-- ─────────────────────────────────────────────────────────────────────

function M.init()
    -- Set up the UDP socket.
    udp = socket.udp()
    udp:setpeername('127.0.0.1', 5015)
    udp:settimeout(0)

    local p = windower.ffxi.get_player()
    if p then
        player_id = p.id
        main_job = p.main_job
    end
    -- Snapshot current equipment so we know aeonic state on first
    -- frame. The 0x050 handler will keep us up to date thereafter.
    local equip = windower.ffxi.get_items('equipment')
    if equip then
        main_weapon_id   = equip.main or 0
        main_weapon_bag  = equip.main_bag or 0
        range_weapon_id  = equip.range or 0
        range_weapon_bag = equip.range_bag or 0
    end
    refresh_aeonic_flavor()
    emit_job()
    emit_settings()
end

function M.handle_zone_change()
    resonating = {}
    last_emit_key = nil
    last_suggest_key = nil
end

return M