-- Battle event synthesizer for the chat panel.
--
-- Hooks the 0x028 action packet (parsed by Windower's packets lib)
-- and synthesizes colored chat events for each combat action. This
-- replaces FFXI's native battle log lines (mode 28/29/30/etc.) in
-- the chat panel — they get suppressed at the filter level so we
-- aren't double-printing.
--
-- The output is structured segments (text + color_class pairs) which
-- the Python renderer paints with per-segment colors. Each event
-- carries the same kind/result classification we use in the BattleMod
-- fork's cooper_classifier, so coverage of FFXI's combat surface is
-- broadly aligned.
--
-- Why this approach (not regex parsing the chat text):
--   1. Action packets have structured data — actor, target, message,
--      params, spell_id — no parsing needed.
--   2. Works regardless of what addons (BattleMod, etc.) do to FFXI's
--      chat display. OmniWatch's chat panel is self-contained.
--   3. Color classification is data-driven (actor_class from the
--      entity classifier) rather than text-based.
--
-- Coverage:
--   cat 1   melee:        hit / crit / miss / block / parry / guard
--   cat 2   ranged:       hit / crit / miss / block / parry / guard
--   cat 3   weaponskill:  hit / crit / miss / block / parry / guard
--   cat 4   spell:        damage / heal / miss / cast / resist / etc.
--   cat 6   ability:      use / damage / heal / fail / etc.
--   cat 9   item:         use
--   cat 11  TP move:      hit / crit / miss / block / parry / guard
--   cat 12  ranged alt:   handled as ranged
--   cat 13  spell start:  cast announcement
--   cat 14  TP start:     ready announcement
--
-- Status messages (buff/debuff apply/wear) are handled by
-- buff_events.lua, NOT here, to keep the two concerns independent.
-- This module returns early when a message matches a status-event ID.

local M = {}

local _ring        = nil
local _classifier  = nil

-- Toggle: when true, multiple melee/ranged swings against the same
-- target in one round are condensed into a single chat line.
-- Example before:
--   Wormfood strikes Wasp for 770 damage
--   Wormfood strikes Wasp for 766 damage
--   Wormfood swings at Wasp and misses
-- Example after:
--   Wormfood strikes Wasp x2 (770/766) damage; 1 miss
-- Toggled via //ow condense [on|off] (handled in OmniWatch.lua).
M.condense_melee = true

-- Toggle: when true, AoE spells / songs that hit multiple targets in
-- one packet are condensed into a single chat line listing all
-- targets, instead of one line per target.
-- Example before:
--   Ulmia casts Victory March → Yoran-Oran
--   Ulmia casts Victory March → Qultada
--   Ulmia casts Victory March → Koru-Moru
--   Ulmia casts Victory March → Joachim
--   Ulmia casts Victory March → Wormfood
-- Example after:
--   Ulmia casts Victory March → 5 targets (Yoran-Oran, Qultada,
--     Koru-Moru, Joachim, Wormfood)
-- Single-target spells (most offensive nukes) are unaffected — only
-- multi-target rounds get condensed.
-- Toggled via //ow condense [on|off] alongside the melee toggle.
M.condense_magic = true

function M.set_deps(ring_mod, classifier_mod)
    _ring       = ring_mod
    _classifier = classifier_mod
end

-- Status apply/wear message IDs that buff_events.lua handles. We skip
-- them here so we don't double-emit. The synth-events flow guarantees
-- both modules see every action packet, so the partition is by message
-- ID set, not by hook routing.
local STATUS_APPLY_MSGS = T{
    82, 127, 128, 130, 236, 242, 270, 271, 272, 531, 645,
    230, 268, 86, 412, 414, 415, 416, 420, 421, 432, 433,
    101, 116, 142, 229,
}
local STATUS_WEAR_MSGS = T{
    64, 73, 203, 204, 206, 277, 279, 350, 754,
}
local function _is_status_msg(msg)
    return STATUS_APPLY_MSGS:contains(msg) or STATUS_WEAR_MSGS:contains(msg)
end

-- Physical-action result detection (melee/ranged/WS/TP move).
-- Mirrors the cooper_classifier logic. We classify the IMPACT type
-- (hit/crit/miss/block/parry/guard) from message + reaction; the
-- caller has already decided the kind (melee/ranged/etc.) from
-- packet category.
local MISS_MSGS = T{15, 63, 158, 188, 245, 324, 592, 658}
local CRIT_MSGS = T{67}

local function _physical_result(action)
    local msg = action.message
    if MISS_MSGS:contains(msg) then return 'miss' end
    if CRIT_MSGS:contains(msg) then return 'crit' end
    -- Check reaction flags for block (+4), parry (+3), guard (+2)
    -- AFTER message classifies as hit. reaction values 1-15 from
    -- FFXI: bit field where 4=block, 8=parry-ish, etc. The exact
    -- bits are implementation-specific; we use the same offsets as
    -- BattleMod's reaction_offsets table.
    local r = action.reaction or 0
    if r % 16 == 4 then return 'block' end
    if r % 16 == 3 then return 'parry' end
    if r % 16 == 2 then return 'guard' end
    -- No-damage case: hit landed but dealt 0. Param holds damage.
    if (action.param or 0) == 0 and msg ~= 0 then
        return 'no_damage'
    end
    return 'hit'
end

-- Spell result sets (per cooper_classifier).
local SPELL_DAMAGE = T{2, 252, 264, 265, 274, 275}
local SPELL_HEAL   = T{7, 8, 9, 14, 80, 263, 276}
local SPELL_MISS   = T{85, 284, 653, 654}
local SPELL_DRAIN  = T{132, 161, 227, 281}
local SPELL_ABSORB = T{572, 642}

local function _spell_result(msg)
    if SPELL_DAMAGE:contains(msg) then return 'damage' end
    if SPELL_HEAL:contains(msg)   then return 'heal'   end
    if SPELL_MISS:contains(msg)   then return 'miss'   end
    if SPELL_DRAIN:contains(msg)  then return 'drain'  end
    if SPELL_ABSORB:contains(msg) then return 'absorb' end
    return 'cast'
end

-- JA result sets.
local JA_ROLL   = T{319, 320, 421}
-- Damage messages per Windower wiki Message IDs reference:
--   110 - generic JA damage ("<actor> uses <ability>. <target> takes
--         <number> points of damage.")
--   185 - weapon-skill damage (some JAs share this message)
--   187 - HP-drain damage ("<actor> uses <ability>. <number> HP drained")
--
-- NOTE: message 100 was previously in this set, but 100 is the
-- generic "<actor> uses <ability>" baseline shared by status-applying
-- JAs (Nightingale/Troubadour/Marcato, Hasso/Seigan, Light/Dark Arts,
-- and many others). When 100 was here, action.param (the buff ID
-- being applied) was being rendered as a damage number — user saw
-- "Wormfood uses Nightingale → Wormfood for 347 damage" where 347
-- is actually the Nightingale buff ID. Removed.
--
-- If a JA actually does damage AND uses message 100, the worst case
-- is that we render it as "use" baseline ("Actor uses X → Target")
-- without the damage trailer. That's a visual omission rather than
-- a false claim about damage. Acceptable tradeoff.
local JA_DAMAGE = T{110, 185, 187}
local JA_HEAL   = T{102, 105, 197}
local JA_FAIL   = T{75, 156, 188, 244, 411, 645, 668}

-- Safety net: even within the tightened JA_DAMAGE set, double-check
-- that action.param resolves to a damage value and not a buff ID via
-- res.buffs. Defense in depth — protects against future cases where
-- a status-applying JA reuses one of the damage message IDs.
local function _ja_param_is_buff_id(param)
    if not param or param == 0 then return false end
    local res = _G.res
    if not res or not res.buffs then return false end
    local entry = res.buffs[param]
    if entry and entry.en and entry.en ~= '' then
        return true
    end
    return false
end

local function _ja_result(msg, param)
    if JA_ROLL:contains(msg)   then return 'roll'   end
    if JA_DAMAGE:contains(msg) then
        -- Param is a known buff ID → status-apply JA, not damage.
        if _ja_param_is_buff_id(param) then
            return 'use'
        end
        return 'damage'
    end
    if JA_HEAL:contains(msg)   then return 'heal'   end
    if JA_FAIL:contains(msg)   then return 'fail'   end
    return 'use'
end

-- ── Name resolution helpers ─────────────────────────────────────────────

local function _resolve(id, fallback_name)
    if not id or id == 0 then
        return fallback_name or '?', 'other'
    end
    local name = fallback_name
    local class = 'other'
    local mob = windower.ffxi.get_mob_by_id and
                windower.ffxi.get_mob_by_id(id)
    if mob and mob.name then name = mob.name end
    if _classifier and _classifier.classify_entity then
        local c, nm = _classifier.classify_entity(id)
        if c  then class = c  end
        if nm then name  = nm end
    end
    return name or '?', class
end

-- Look up a spell/ability/WS/item name from its id via Windower
-- resources. Falls back to '?' if the resource isn't available
-- (which shouldn't happen on a real Windower install).
local function _spell_name(spell_id)
    if not spell_id or spell_id == 0 then return '?' end
    local res = _G.res
    if res and res.spells and res.spells[spell_id] then
        return res.spells[spell_id].en or '?'
    end
    return '?'
end

local function _ja_name(ja_id)
    if not ja_id or ja_id == 0 then return '?' end
    local res = _G.res
    if res and res.job_abilities and res.job_abilities[ja_id] then
        return res.job_abilities[ja_id].en or '?'
    end
    return '?'
end

local function _ws_name(ws_id)
    if not ws_id or ws_id == 0 then return '?' end
    local res = _G.res
    if res and res.weapon_skills and res.weapon_skills[ws_id] then
        return res.weapon_skills[ws_id].en or '?'
    end
    return '?'
end

local function _item_name(item_id)
    if not item_id or item_id == 0 then return '?' end
    local res = _G.res
    if res and res.items and res.items[item_id] then
        return res.items[item_id].en or '?'
    end
    return '?'
end

local function _monster_tp_name(action_id)
    -- Mob TP moves: ID is in res.monster_abilities OR res.job_abilities
    -- depending on FFXI client version. Try both.
    if not action_id or action_id == 0 then return '?' end
    local res = _G.res
    if res and res.monster_abilities and res.monster_abilities[action_id] then
        return res.monster_abilities[action_id].en or '?'
    end
    if res and res.job_abilities and res.job_abilities[action_id] then
        return res.job_abilities[action_id].en or '?'
    end
    return '?'
end

-- ── Event emission helpers ──────────────────────────────────────────────

-- Build a {text, color} segment quickly. Slight verbosity here would
-- repeat across every template; this keeps templates compact.
local function S(text, color)
    return {text = text, color = color or 'default'}
end

-- Build and push an event from a list of segments. Computes the flat
-- text by concatenating segment texts, so callers don't have to
-- maintain both representations.
--
-- `kind` identifies the routing channel for the Python-side chat
-- routing system. Values: 'melee', 'ranged', 'weaponskills',
-- 'abilities', 'damage', 'healing', 'casting', 'readies', 'uses',
-- 'misses'. The routing engine consumes this to decide which tab
-- (Battle / Mob / hidden) the event should land in.
--
-- `target_class` mirrors actor_class but for the recipient of the
-- action — used by routing rules like "monsters' melee on me" vs
-- "monsters' melee on party". May be '' for self-targeted or
-- action-without-target events.
local function emit_event(actor_id, actor_name, actor_class,
                           target_id, target_name, target_class,
                           kind, segments)
    if not _ring or not _ring.text_ring then return end
    local flat_parts = {}
    for i = 1, #segments do flat_parts[i] = segments[i].text end
    local flat = table.concat(flat_parts)
    _ring.text_ring.push({
        ts           = os.time(),
        source       = 'battle',
        mode         = -3,     -- synthetic battle event (distinct from
                               -- -1 buff/debuff and -2 checkparam)
        kind         = kind or 'unknown',
        actor_id     = actor_id or 0,
        actor_name   = actor_name or '',
        actor_class  = actor_class or 'other',
        target_id    = target_id or 0,
        target_name  = target_name or '',
        target_class = target_class or '',
        text         = flat,
        segments     = segments,
    })
end

-- ── Per-category synthesis ─────────────────────────────────────────────

-- Physical action lines (melee/ranged/WS/TP-move). Uniform shape:
--   "<Actor> <verb> <target> for <N> damage[!]"
-- with variant suffixes for miss/block/parry/guard/no_damage.
-- weapon_skill_name and tp_move_name are optional (passed for WS / TP).
local function emit_physical(kind, actor_id, actor_name, actor_class,
                              target_id, target_name, target_class,
                              action, result, weapon_skill_name, tp_move_name)
    local segs = {S(actor_name, actor_class)}

    -- Verb selection by kind + result.
    local verb
    if kind == 'melee' then
        if result == 'miss' or result == 'parry' then
            verb = ' swings at '
        elseif result == 'crit' then
            verb = ' crits '
        else
            verb = ' strikes '
        end
    elseif kind == 'ranged' then
        if result == 'miss' or result == 'parry' then
            verb = ' shoots at '
        elseif result == 'crit' then
            verb = ' crits '
        else
            verb = ' shoots '
        end
    elseif kind == 'weaponskill' then
        verb = " uses '"
    elseif kind == 'tp_move' then
        verb = " uses '"
    else
        verb = ' acts on '
    end
    table.insert(segs, S(verb, 'default'))

    -- For WS / TP moves the ability name comes in the verb position.
    if kind == 'weaponskill' and weapon_skill_name then
        table.insert(segs, S(weapon_skill_name, 'weaponskill'))
        table.insert(segs, S("' → ", 'default'))
    elseif kind == 'tp_move' and tp_move_name then
        table.insert(segs, S(tp_move_name, 'ability'))
        table.insert(segs, S("' → ", 'default'))
    end

    table.insert(segs, S(target_name, target_class))

    -- Result-specific suffix.
    local damage = action.param or 0
    if result == 'miss' then
        table.insert(segs, S(' and misses', 'default'))
    elseif result == 'parry' then
        table.insert(segs, S(' and is parried', 'default'))
    elseif result == 'block' then
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' (blocked)', 'default'))
    elseif result == 'guard' then
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' (guarded)', 'default'))
    elseif result == 'no_damage' then
        table.insert(segs, S(' for no damage', 'default'))
    elseif result == 'crit' then
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' damage!', 'default'))
    else
        -- 'hit' baseline
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' damage', 'default'))
    end

    -- Channel for routing: kind is melee/ranged/weaponskill/tp_move,
    -- but the routing config uses 'weaponskills' (plural) and
    -- 'readies' (for tp_move). Map here so the GUI's channel names
    -- line up with what Lua emits.
    local channel
    if kind == 'melee' then        channel = 'melee'
    elseif kind == 'ranged' then   channel = 'ranged'
    elseif kind == 'weaponskill' then channel = 'weaponskills'
    elseif kind == 'tp_move' then  channel = 'readies'
    else                           channel = 'melee'
    end
    -- Misses get the 'misses' channel — overrides the above so a
    -- whiffed melee/ranged swing is routable separately from a hit.
    if result == 'miss' or result == 'parry' then
        channel = 'misses'
    end
    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               channel, segs)
end

-- Condensed multi-hit line. Collapses an array of swing/shot actions
-- on the same target into a single chat event. Format:
--   Actor strikes Target x3 (770/766/592) damage  [crit]
--   Actor crits Target x2 (1704/812) damage!
--   Actor swings at Target — all 3 miss
--   Actor strikes Target x2 (770/766) ; 1 miss
--
-- The intent: in melee rounds you commonly get 2-4 hits in a single
-- packet. Showing each as a separate line clutters the panel; one
-- summary line per round is more readable. Toggled via M.condense_melee.
local function emit_physical_condensed(kind,
                                       actor_id, actor_name, actor_class,
                                       target_id, target_name, target_class,
                                       actions_list)
    -- Bucket actions by result. We track damage values per bucket so we
    -- can print them inline; misses just need a count.
    local hits, crits, blocks, guards, parries = {}, {}, {}, {}, {}
    local misses = 0
    for _, action in pairs(actions_list) do
        local result = _physical_result(action)
        local dmg = action.param or 0
        if result == 'crit' then
            crits[#crits + 1] = dmg
        elseif result == 'miss' then
            misses = misses + 1
        elseif result == 'parry' then
            parries[#parries + 1] = true
        elseif result == 'block' then
            blocks[#blocks + 1] = dmg
        elseif result == 'guard' then
            guards[#guards + 1] = dmg
        else
            -- normal hit, 'no_damage' (rare), or unknown
            hits[#hits + 1] = dmg
        end
    end

    local hit_count = #hits + #crits + #blocks + #guards
    local total = hit_count + misses + #parries

    local segs = {S(actor_name, actor_class)}

    -- Verb: prefer "crits" if any crit, "strikes/shoots" if any hit,
    -- "swings/shoots at" if everything missed.
    local verb_strike, verb_swing
    if kind == 'ranged' then
        verb_strike = ' shoots '
        verb_swing  = ' shoots at '
    else
        verb_strike = ' strikes '
        verb_swing  = ' swings at '
    end
    if #crits > 0 and hit_count == #crits then
        -- All hits were crits
        table.insert(segs, S(kind == 'ranged' and ' crits ranged on ' or ' crits ', 'default'))
    elseif hit_count > 0 then
        table.insert(segs, S(verb_strike, 'default'))
    else
        table.insert(segs, S(verb_swing, 'default'))
    end

    table.insert(segs, S(target_name, target_class))

    if hit_count > 1 then
        table.insert(segs, S(' x' .. tostring(hit_count), 'default'))
    end

    if hit_count > 0 then
        local nums = {}
        for _, d in ipairs(hits)  do nums[#nums + 1] = tostring(d) end
        for _, d in ipairs(crits) do nums[#nums + 1] = tostring(d) .. '!' end
        for _, d in ipairs(blocks) do nums[#nums + 1] = tostring(d) .. '(B)' end
        for _, d in ipairs(guards) do nums[#nums + 1] = tostring(d) .. '(G)' end
        if #nums > 0 then
            table.insert(segs, S(' (', 'default'))
            table.insert(segs, S(table.concat(nums, '/'), 'damage_number'))
            table.insert(segs, S(') damage', 'default'))
        end
    end

    if hit_count == 0 and misses > 0 then
        if misses == total then
            table.insert(segs, S(' and miss', 'default'))
        else
            table.insert(segs, S(' and miss x' .. tostring(misses), 'default'))
        end
    elseif misses > 0 then
        table.insert(segs, S('; ' .. tostring(misses) .. ' miss', 'default'))
    end
    if #parries > 0 then
        table.insert(segs, S('; ' .. tostring(#parries) .. ' parried', 'default'))
    end

    -- Routing channel — pure-hit goes to melee/ranged; pure-miss goes
    -- to misses; mixed defaults to the hit channel.
    local channel
    if kind == 'ranged' then channel = 'ranged' else channel = 'melee' end
    if hit_count == 0 then channel = 'misses' end

    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               channel, segs)
end

-- Spell line. Result-dependent shape:
--   damage:  "<Actor> casts <Spell> → <Target> for <N> damage"
--   heal:    "<Actor> casts <Spell> → <Target> for <N> HP"
--   miss:    "<Actor> casts <Spell> → <Target> but it misses"
--   cast:    "<Actor> casts <Spell> → <Target>"          (no number)
--   drain:   "<Actor> drains <N> from <Target> with <Spell>"
--   absorb:  same shape as drain
local function emit_spell(actor_id, actor_name, actor_class,
                           target_id, target_name, target_class,
                           action, spell_name, result)
    local damage = action.param or 0
    local segs = {S(actor_name, actor_class)}

    if result == 'damage' or result == 'cast' then
        table.insert(segs, S(' casts ', 'default'))
        table.insert(segs, S(spell_name, 'spell'))
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        if result == 'damage' then
            table.insert(segs, S(' for ', 'default'))
            table.insert(segs, S(tostring(damage), 'damage_number'))
            table.insert(segs, S(' damage', 'default'))
        end
    elseif result == 'heal' then
        table.insert(segs, S(' casts ', 'default'))
        table.insert(segs, S(spell_name, 'spell'))
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' HP', 'default'))
    elseif result == 'miss' then
        table.insert(segs, S(' casts ', 'default'))
        table.insert(segs, S(spell_name, 'spell'))
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' but it misses', 'default'))
    elseif result == 'drain' then
        table.insert(segs, S(' drains ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' from ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' with ', 'default'))
        table.insert(segs, S(spell_name, 'spell'))
    elseif result == 'absorb' then
        table.insert(segs, S(' absorbs ', 'default'))
        table.insert(segs, S(tostring(damage), 'damage_number'))
        table.insert(segs, S(' from ', 'default'))
        table.insert(segs, S(target_name, target_class))
    else
        -- Unknown result: just say cast.
        table.insert(segs, S(' casts ', 'default'))
        table.insert(segs, S(spell_name, 'spell'))
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
    end

    -- Channel for routing: damage spells go to 'damage', heals to
    -- 'healing', drain/absorb count as damage, misses to 'misses',
    -- everything else (plain cast) to 'casting'.
    local channel
    if result == 'damage' or result == 'drain' or result == 'absorb' then
        channel = 'damage'
    elseif result == 'heal' then
        channel = 'healing'
    elseif result == 'miss' then
        channel = 'misses'
    else
        channel = 'casting'
    end
    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               channel, segs)
end

-- Condensed multi-target spell line. Collapses an AoE spell (or song,
-- ga-spell, etc.) hitting many targets into a single chat event with
-- a target list. Format:
--   Actor casts Victory March → 5 targets (Yoran-Oran, Qultada, ...)
--   Actor casts Cure V → 3 targets (Ulmia/520, Joachim/520, Wormfood/520) HP
--   Actor casts Firaga III → 3 targets (Wasp/3200, Wasp/3200, Wasp/3200) damage
--
-- Only used when there are 2+ targets in the same spell packet AND
-- M.condense_magic is on. Single-target spells fall through to the
-- normal emit_spell.
local function emit_spell_condensed(actor_id, actor_name, actor_class,
                                     spell_name, targets_info)
    -- targets_info: array of {name, class, action, result}
    local segs = {S(actor_name, actor_class)}

    -- Determine an aggregate result. Mixed results are rare for AoE
    -- (most AoEs are pure damage or pure buff); when mixed, prefer
    -- the most-frequent result.
    local result_counts = {}
    for _, t in ipairs(targets_info) do
        result_counts[t.result] = (result_counts[t.result] or 0) + 1
    end
    local agg_result, agg_max = 'cast', 0
    for r, c in pairs(result_counts) do
        if c > agg_max then agg_max, agg_result = c, r end
    end

    table.insert(segs, S(' casts ', 'default'))
    table.insert(segs, S(spell_name, 'spell'))
    table.insert(segs, S(' → ', 'default'))
    table.insert(segs, S(tostring(#targets_info) .. ' targets', 'default'))

    -- Build the target list, with per-target damage/heal numbers when
    -- the result has a meaningful value.
    table.insert(segs, S(' (', 'default'))
    local include_value = (agg_result == 'damage' or agg_result == 'heal'
                          or agg_result == 'drain' or agg_result == 'absorb')
    for i, t in ipairs(targets_info) do
        if i > 1 then
            table.insert(segs, S(', ', 'default'))
        end
        table.insert(segs, S(t.name, t.class))
        if include_value then
            local v = t.action.param or 0
            if v > 0 then
                table.insert(segs, S('/' .. tostring(v), 'damage_number'))
            end
        end
    end
    table.insert(segs, S(')', 'default'))

    -- Trailing unit label if there was a value.
    if agg_result == 'damage' or agg_result == 'drain' or agg_result == 'absorb' then
        table.insert(segs, S(' damage', 'default'))
    elseif agg_result == 'heal' then
        table.insert(segs, S(' HP', 'default'))
    elseif agg_result == 'miss' then
        table.insert(segs, S(' (all miss)', 'default'))
    end

    -- Routing channel — same rules as single-target emit_spell, based
    -- on aggregate result.
    local channel
    if agg_result == 'damage' or agg_result == 'drain' or agg_result == 'absorb' then
        channel = 'damage'
    elseif agg_result == 'heal' then
        channel = 'healing'
    elseif agg_result == 'miss' then
        channel = 'misses'
    else
        channel = 'casting'
    end

    -- Build the event with no specific target_id/class (multi-target,
    -- so target fields are kept neutral). target_name in the event
    -- gets the first target as a representative for routing purposes.
    local first = targets_info[1]
    emit_event(actor_id, actor_name, actor_class,
               first.action.target_id or 0, first.name, first.class,
               channel, segs)
end

-- Job ability line. Result-dependent shape:
--   damage: "<Actor> uses <Ability> → <Target> for <N> damage"
--   heal:   "<Actor> uses <Ability> → <Target> for <N> HP"
--   roll:   "<Actor> uses <Ability>" (no target)
--   fail:   "<Actor> uses <Ability> → <Target> but has no effect"
--   use:    "<Actor> uses <Ability> → <Target>"
local function emit_ability(actor_id, actor_name, actor_class,
                              target_id, target_name, target_class,
                              action, ja_name, result)
    local val = action.param or 0
    local segs = {S(actor_name, actor_class)}
    table.insert(segs, S(' uses ', 'default'))
    table.insert(segs, S(ja_name, 'ability'))

    if result == 'roll' then
        -- COR rolls: actor only, no target on this line.
    elseif result == 'damage' then
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(val), 'damage_number'))
        table.insert(segs, S(' damage', 'default'))
    elseif result == 'heal' then
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' for ', 'default'))
        table.insert(segs, S(tostring(val), 'damage_number'))
        table.insert(segs, S(' HP', 'default'))
    elseif result == 'fail' then
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
        table.insert(segs, S(' but has no effect', 'default'))
    else
        -- 'use' baseline
        if target_name and target_name ~= '' and target_id ~= actor_id then
            table.insert(segs, S(' → ', 'default'))
            table.insert(segs, S(target_name, target_class))
        end
    end

    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               'abilities', segs)
end

-- Item line. "<Actor> uses <Item> → <Target>"
local function emit_item(actor_id, actor_name, actor_class,
                          target_id, target_name, target_class,
                          item_name)
    local segs = {
        S(actor_name, actor_class),
        S(' uses ', 'default'),
        S(item_name, 'default'),
    }
    if target_id ~= 0 and target_id ~= actor_id then
        table.insert(segs, S(' → ', 'default'))
        table.insert(segs, S(target_name, target_class))
    end
    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               'uses', segs)
end

-- Cast start (cat 13): "<Actor> starts casting <Spell> → <Target>"
local function emit_cast_start(actor_id, actor_name, actor_class,
                                target_id, target_name, target_class,
                                spell_name)
    local segs = {
        S(actor_name, actor_class),
        S(' starts casting ', 'default'),
        S(spell_name, 'spell'),
        S(' → ', 'default'),
        S(target_name, target_class),
    }
    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               'casting', segs)
end

-- TP ready (cat 14): "<Actor> readies <Ability> → <Target>"
local function emit_tp_ready(actor_id, actor_name, actor_class,
                              target_id, target_name, target_class,
                              ability_name)
    local segs = {
        S(actor_name, actor_class),
        S(' readies ', 'default'),
        S(ability_name, 'ability'),
        S(' → ', 'default'),
        S(target_name, target_class),
    }
    emit_event(actor_id, actor_name, actor_class,
               target_id, target_name, target_class,
               'readies', segs)
end

-- ── Public entry point ──────────────────────────────────────────────────

-- Called from OmniWatch.lua's handle_incoming_action (same hook
-- buff_events uses). Walks each (target, action) and synthesizes an
-- appropriate chat panel event based on packet category + message.
function M.process(act)
    if not act or not act.targets then return end
    if not _ring or not _ring.text_ring then return end

    local cat = act.category
    if not cat then return end

    local actor_id = act.actor_id
    local actor_name, actor_class = _resolve(actor_id, nil)

    -- act.param at the action level is the spell/ability/WS/item id
    -- depending on category. Resolve to a display name once per packet.
    local primary_id = act.param

    -- ── Magic condense pre-pass ─────────────────────────────────────
    -- For cat 4 (spells) when M.condense_magic is on, collect every
    -- target's action up front and emit ONE combined line if the
    -- spell hit multiple targets. AoE songs, ga-spells, Cure V on a
    -- party, etc. all benefit from this — otherwise we get one line
    -- per target which clutters the panel. Single-target spells (one
    -- target in the packet) fall through to the normal per-target
    -- loop below.
    --
    -- We include EVERY target here — including the caster when they
    -- are one of the AoE recipients. The caster's entry typically
    -- has a status-apply message (not a "spell hit" message), so a
    -- naive _is_status_msg filter would drop them and undercount the
    -- target list by 1. buff_events.lua handles the per-target buff
    -- apply lines independently; this condense is purely about the
    -- "spell cast" line, so showing all recipients (caster included)
    -- is the right count.
    if M.condense_magic and cat == 4 then
        local spell_name = _spell_name(primary_id)
        local targets_info = {}
        for _, tgt in pairs(act.targets) do
            if tgt.actions then
                local tname, tclass = _resolve(tgt.id, nil)
                for _, action in pairs(tgt.actions) do
                    action.target_id = tgt.id  -- stash for downstream
                    -- Determine result. Status-msg actions (typical
                    -- for the caster's own slot in an AoE buff) are
                    -- best treated as a plain 'cast' for aggregation
                    -- purposes — there's no damage/heal number on
                    -- them. Everything else uses normal spell-result
                    -- classification.
                    local result
                    if _is_status_msg(action.message) then
                        result = 'cast'
                    else
                        result = _spell_result(action.message)
                    end
                    targets_info[#targets_info + 1] = {
                        name   = tname,
                        class  = tclass,
                        action = action,
                        result = result,
                    }
                end
            end
        end
        if #targets_info >= 2 then
            -- Multi-target — emit one condensed line and we're done.
            emit_spell_condensed(actor_id, actor_name, actor_class,
                                 spell_name, targets_info)
            return
        end
        -- 0 or 1 targets: fall through to normal loop (no condense).
    end

    for _, tgt in pairs(act.targets) do
        if tgt.actions then
            local target_id = tgt.id
            local target_name, target_class = _resolve(target_id, nil)

            -- For melee (cat 1) and ranged (cat 2/12) multi-hit rounds,
            -- collapse all actions on this target into a single line
            -- when M.condense_melee is true. Builds a non-status action
            -- list first, then emits one summary. Other categories
            -- (WS, spell, ability, etc.) emit per-action as before.
            if M.condense_melee and (cat == 1 or cat == 2 or cat == 12) then
                local actions_for_target = {}
                for _, action in pairs(tgt.actions) do
                    if not _is_status_msg(action.message) then
                        actions_for_target[#actions_for_target + 1] = action
                    end
                end
                if #actions_for_target > 0 then
                    local kind = (cat == 1) and 'melee' or 'ranged'
                    emit_physical_condensed(kind,
                        actor_id, actor_name, actor_class,
                        target_id, target_name, target_class,
                        actions_for_target)
                end
            else

            for _, action in pairs(tgt.actions) do
                -- Skip status apply/wear messages — buff_events handles
                -- those. Both modules run on every packet; we partition
                -- by message ID set.
                if not _is_status_msg(action.message) then
                    if cat == 1 then
                        emit_physical('melee',
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            action, _physical_result(action))
                    elseif cat == 2 or cat == 12 then
                        emit_physical('ranged',
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            action, _physical_result(action))
                    elseif cat == 3 then
                        emit_physical('weaponskill',
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            action, _physical_result(action),
                            _ws_name(primary_id))
                    elseif cat == 11 then
                        emit_physical('tp_move',
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            action, _physical_result(action),
                            nil, _monster_tp_name(primary_id))
                    elseif cat == 4 then
                        emit_spell(
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            action, _spell_name(primary_id),
                            _spell_result(action.message))
                    elseif cat == 6 then
                        -- Skip emit when JA name is unknown ('?'). This
                        -- catches enchantment items (Warp Ring, trust
                        -- primers, Mog Pell, etc.) which fire under cat 6
                        -- with a primary_id that doesn't map to any
                        -- res.job_abilities entry. FFXI's native chat
                        -- renders these as "uses an item" via
                        -- incoming_text — that's the better source.
                        local ja_nm = _ja_name(primary_id)
                        if ja_nm ~= '?' then
                            emit_ability(
                                actor_id, actor_name, actor_class,
                                target_id, target_name, target_class,
                                action, ja_nm,
                                _ja_result(action.message, action.param))
                        end
                    elseif cat == 9 then
                        emit_item(
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            _item_name(primary_id))
                    elseif cat == 13 then
                        emit_cast_start(
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            _spell_name(primary_id))
                    elseif cat == 14 then
                        -- Same packet for mob TP readies AND player JA preps.
                        -- Use monster_abilities first then job_abilities
                        -- fallback (matches _monster_tp_name internals).
                        emit_tp_ready(
                            actor_id, actor_name, actor_class,
                            target_id, target_name, target_class,
                            _monster_tp_name(primary_id))
                    end
                end
            end
            end  -- closes the 'else' branch of condense_melee if/else
        end
    end
end

return M