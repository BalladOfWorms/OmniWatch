-- Buff/debuff event detector for the chat panel.
--
-- Watches every action packet (hooked from OmniWatch.lua's
-- handle_incoming_action). For action messages that are status
-- applications or wear-offs, emits a SYNTHETIC chat event with
-- source='buff' or source='debuff' so the chat panel's Buffs and
-- Debuffs tabs can display them.
--
-- Why a synthetic event rather than parsing the chat text?
--   1. Action packets are the canonical source — chat text is
--      downstream and can be filtered by the FFXI client.
--   2. We get structured data: status_id (resolves to status name
--      via res.buffs), actor_id (resolves to actor name via the
--      mob array), wear-vs-apply, buff-vs-debuff (via enfeebling
--      table) — no string parsing.
--   3. Decoupled from BattleMod. Works whether BattleMod is
--      installed or not, with or without custom templates.
--
-- The status apply/wear message ID lists are kept in lockstep with
-- BattleMod's filter logic (generic_helpers.lua's STATUS_APPLY_MSGS
-- and STATUS_WEAR_MSGS). If new message IDs appear in real combat
-- and slip through, add them here and to BattleMod simultaneously.
--
-- Buff-vs-debuff classification uses BattleMod's `enfeebling` global
-- table (statics.lua line 163). When the chat panel loads from
-- OmniWatch and BattleMod isn't loaded, we fall back to a frozen copy
-- of that table to avoid breaking the chat panel.

local M = {}

-- Set by _loader at module init. emit_to_ring is a function reference
-- to the function we use to push events into the text ring; this
-- mirrors how emit.lua receives its deps.
local _ring        = nil
local _classifier  = nil

function M.set_deps(ring_mod, classifier_mod)
    _ring       = ring_mod
    _classifier = classifier_mod
end

-- ── Status message ID sets ──────────────────────────────────────────────

-- Message IDs for status APPLICATION (X gains the effect of Y).
--
-- Conservative set — only IDs verified to be status applications via
-- FFXI's action_messages dat. The previous broader set included several
-- speculative IDs (101, 116, 142, 229, 230, 268, 86, 412, 414-416, 420,
-- 421, 432, 433) that fire on non-status events: AoE buff packets,
-- ability animations, pet-buff effects (e.g. Ecliptic Howl uses 142,
-- not a status apply). When those non-status messages carried an
-- action.param that coincidentally fell in the enfeebling status ID
-- range (1-31, 128-149, etc. — common low integers), we rendered
-- bogus "X is afflicted with Y" lines on every party member.
--
-- Observed before this trim: full trust party "afflicted with disease/
-- blindness/stun/bind/sleep" appearing when Wormfood used abilities.
--
-- Add a message ID back ONLY after confirming it represents a real
-- status apply / wear from a packet capture or the action_messages dat.
local STATUS_APPLY_MSGS = T{
    82,    -- "X is afflicted with Y" (canonical debuff apply)
    127,   -- "X gains the effect of Y" (canonical buff apply)
    128,   -- buff apply variant
    130,   -- buff apply variant
    230,   -- bard song apply / general buff apply (confirmed via
           -- packet capture: msg=230 param=214 fires for March songs).
           -- The res.buffs validity gate in classify_status filters
           -- the non-status events (pet effects like Ecliptic Howl)
           -- that share this msg_id by checking that param resolves
           -- to a real buff.
    236,   -- bard song / pet buff apply
    242,   -- AoE buff apply
    270,   -- buff/heal apply
    271,   -- buff apply variant
    272,   -- buff apply variant
    -- 327 was added then reverted: it produces false-positive
    -- "gains 'Afflatus Solace'" lines when the user isn't WHM and
    -- never used the ability. msg=327 + param=417 appears to fire
    -- on something other than a literal Afflatus Solace apply
    -- (gift activation? zone-in passive? unconfirmed). Re-add only
    -- after determining what 327 actually represents.
    531,   -- special status apply (Voidwatch/etc.)
    645,   -- special status apply
}

-- Message IDs for status WEAR-OFF (X's effect wears off).
local STATUS_WEAR_MSGS = T{
    64, 73, 203, 204, 206, 277, 279, 350, 754,
}

-- Frozen fallback of BattleMod's debuff status ID set, used when
-- BattleMod isn't loaded. Pulled from BattleMod statics.lua line 163
-- as of May 2026; safe to leave stale since the enfeebling list
-- itself rarely changes (SE doesn't usually add new debuff statuses).
local FALLBACK_ENFEEBLING = T{
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 128, 129, 130, 131,
    132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144,
    145, 146, 147, 148, 149, 155, 156, 157, 158, 159, 167, 168, 174,
    175, 177, 186, 189, 192, 193, 194, 223, 259, 260, 261, 262, 263,
    264, 298, 378, 379, 380, 386, 387, 388, 389, 390, 391, 392, 393,
    394, 395, 396, 397, 398, 399, 400, 404, 448, 449, 450, 451, 452,
    473, 540, 557, 558, 559, 560, 561, 562, 563, 564, 565, 566, 567,
    572, 576, 597, 630, 631,
}

-- Use BattleMod's live table if available, otherwise the frozen copy.
-- Re-checked on every call (not at module load) so reloading BattleMod
-- mid-session picks up its current table without restarting OmniWatch.
local function _enfeebling_set()
    if _G.enfeebling then return _G.enfeebling end
    return FALLBACK_ENFEEBLING
end

-- ── Per-message classification ──────────────────────────────────────────

-- Returns ('buff'|'debuff', 'apply'|'wear') for status-effect messages,
-- nil otherwise. Mirrors BattleMod's cooper_classifier.status_kind_result
-- but standalone here so we don't need BattleMod loaded.
--
-- Validity gate: status_param must resolve to a real entry in res.buffs.
-- Without this, msg_ids that are SHARED between real status events and
-- non-status events (e.g. 230 for both bard songs AND Ecliptic Howl
-- pet effects) would emit bogus "X gains '#142'" lines when the
-- non-status event happens to use an arbitrary param. Requiring the
-- param to be a real buff filters those false positives — non-status
-- events use param values that don't appear in res.buffs.
local function classify_status(msg_id, status_param)
    local is_apply = STATUS_APPLY_MSGS:contains(msg_id)
    local is_wear  = STATUS_WEAR_MSGS:contains(msg_id)
    if not is_apply and not is_wear then return nil, nil end

    -- Param must resolve to a real buff. Without a name to render,
    -- there's nothing to emit anyway. Cheap O(1) lookup.
    local res = _G.res
    if not res or not res.buffs or not status_param then
        return nil, nil
    end
    local entry = res.buffs[status_param]
    if not entry or not (entry.en or entry.enl) then
        return nil, nil
    end

    local enf = _enfeebling_set()
    local is_debuff = status_param and enf:contains(status_param)
    return (is_debuff and 'debuff' or 'buff'),
           (is_apply and 'apply' or 'wear')
end

-- Resolve a status ID to a display name via Windower's buffs resource.
-- Returns the English name, or 'effect #N' as a last-resort placeholder
-- so the chat panel never shows an empty status name.
local function status_name(status_id)
    if not status_id or status_id == 0 then return 'effect #0' end
    local res = _G.res
    if res and res.buffs and res.buffs[status_id] then
        return res.buffs[status_id].en or res.buffs[status_id].enl
                or ('effect #' .. tostring(status_id))
    end
    return 'effect #' .. tostring(status_id)
end

-- Resolve a mob ID to a display name. Used to label whose status
-- gained/lost an effect. Falls back to id-as-string if the mob isn't
-- in the local mob array (which can happen for distant party
-- members in a sparse zone).
local function actor_name_for(id)
    if not id or id == 0 then return '?' end
    local mob = windower.ffxi.get_mob_by_id and
                windower.ffxi.get_mob_by_id(id)
    if mob and mob.name then return mob.name end
    return 'id#' .. tostring(id)
end

-- ── Public entry point ──────────────────────────────────────────────────

-- Called from OmniWatch.lua's handle_incoming_action with the parsed
-- action packet. Walks every (target, action) pair, classifies each
-- message, and emits a chat panel event for any status applications
-- or wear-offs.
--
-- One action packet can affect multiple targets (AoE buff like Hastega,
-- multi-target dispel like Erase from RDM SP) and each target can have
-- multiple actions. We emit one synthetic event per (target, action)
-- pair that classifies as a status event.
--
-- Errors are swallowed at the pcall boundary in OmniWatch.lua — this
-- function should never throw, but if it does it won't kill the rest
-- of the action handler chain.
function M.process(act)
    if not act or not act.targets then return end
    if not _ring or not _ring.text_ring then return end

    for _, tgt in pairs(act.targets) do
        if tgt.actions then
            for _, action in pairs(tgt.actions) do
                -- Diagnostic: log every action message we see, with
                -- our classification verdict. Toggle on with
                -- //ow buffwearprobe. Helpful for finding msg_ids
                -- that should be in STATUS_WEAR_MSGS but aren't.
                if M.debug_wear then
                    local k, r = classify_status(action.message, action.param)
                    local res_name = '?'
                    if _G.res and _G.res.buffs and _G.res.buffs[action.param] then
                        res_name = _G.res.buffs[action.param].en or '?'
                    end
                    windower.add_to_chat(207, string.format(
                        '[buff-probe] msg=%d param=%d tgt=%d kind=%s result=%s name=%s',
                        action.message or 0, action.param or 0,
                        tgt.id or 0, tostring(k), tostring(r), res_name))
                end
                local kind, result = classify_status(action.message,
                                                     action.param)
                if kind then
                    local subject_id   = tgt.id
                    local subject_name = actor_name_for(subject_id)
                    local actor_class = 'other'
                    if _classifier and _classifier.classify_entity then
                        local c = _classifier.classify_entity(subject_id)
                        if c then actor_class = c end
                    end

                    local status_nm = status_name(action.param)
                    -- Verb selection per kind + result. Buffs use the
                    -- neutral "gains/loses". Debuffs use stronger,
                    -- more clinical wording to make negative effects
                    -- visually distinct in the panel:
                    --   buff apply:    "gains 'X'"
                    --   buff wear:     "loses 'X'"
                    --   debuff apply:  "is afflicted with 'X'"
                    --   debuff wear:   "recovers from 'X'"
                    local verb
                    if kind == 'debuff' then
                        verb = (result == 'apply')
                               and 'is afflicted with'
                               or  'recovers from'
                    else
                        verb = (result == 'apply') and 'gains' or 'loses'
                    end
                    local text = string.format("%s %s '%s'",
                                               subject_name, verb,
                                               status_nm)

                    -- Build colored segments. Subject is colored by
                    -- their actor_class (self/party/mob/etc.), the
                    -- verb is colored by semantic outcome (gaining a
                    -- buff or shedding a debuff = good = yellow;
                    -- losing a buff or being afflicted = bad = pink),
                    -- and the status name uses the buff_status or
                    -- debuff_status color.
                    local status_color = (kind == 'debuff')
                                         and 'debuff_status' or 'buff_status'
                    local verb_color
                    if kind == 'debuff' then
                        verb_color = (result == 'apply')
                                     and 'verb_bad' or 'verb_good'
                    else
                        verb_color = (result == 'apply')
                                     and 'verb_good' or 'verb_bad'
                    end
                    local segments = {
                        {text = subject_name,           color = actor_class},
                        {text = ' ',                    color = 'default'},
                        {text = verb,                   color = verb_color},
                        {text = " '",                   color = 'default'},
                        {text = status_nm,              color = status_color},
                        {text = "'",                    color = 'default'},
                    }

                    local ev = {
                        ts           = os.time(),
                        source       = kind,    -- 'buff' or 'debuff'
                        mode         = -1,
                        actor_id     = subject_id or 0,
                        actor_name   = subject_name,
                        actor_class  = actor_class,
                        target_id    = 0,
                        target_name  = '',
                        target_class = '',
                        text         = text,
                        segments     = segments,
                        status_id    = action.param,
                        result       = result,
                    }
                    _ring.text_ring.push(ev)
                end
            end
        end
    end
end

-- Action-message wear-off IDs that arrive as 0x029 packets rather
-- than 0x028 action targets. When a debuff wears off naturally,
-- FFXI doesn't fire an action packet — it fires an action-message
-- packet (0x029). This set mirrors OmniWatch.lua's MSG_WEAR_OFF.
local STATUS_MSG_WEAR_OFF = T{64, 204, 206, 350, 531}

-- Called from OmniWatch.lua's 0x029 handler. Args are the unpacked
-- packet fields (no full action object — 0x029 is a flat message
-- packet, not nested target/actions). When the msg_id is a status
-- wear-off, synthesizes a colored chat event for the Buffs/Debuffs/
-- Mob tab (depending on actor_class and buff/debuff classification).
--
-- Mirrors process()'s output format exactly so the two paths render
-- identically on the user side. Routing differs only by source:
-- process() emits source='buff'/'debuff', this emits the same.
function M.process_status_message(msg_id, target_id, status_id)
    if not STATUS_MSG_WEAR_OFF:contains(msg_id) then return end
    if not status_id or status_id == 0 then return end
    if not _ring or not _ring.text_ring then return end

    -- Buff vs debuff via enfeebling set. Wear-offs don't carry any
    -- other signal — we infer the kind purely from the status id.
    local enf = _enfeebling_set()
    local is_debuff = enf:contains(status_id)
    local kind   = is_debuff and 'debuff' or 'buff'
    local result = 'wear'

    local subject_name = actor_name_for(target_id)
    local actor_class  = 'other'
    if _classifier and _classifier.classify_entity then
        local c = _classifier.classify_entity(target_id)
        if c then actor_class = c end
    end

    local status_nm = status_name(status_id)
    -- Verb pairs match process(): buff loses, debuff recovers from.
    local verb = is_debuff and 'recovers from' or 'loses'
    local text = string.format("%s %s '%s'", subject_name, verb, status_nm)

    local status_color = is_debuff and 'debuff_status' or 'buff_status'
    -- Verb color: wear-off semantics are inverted between buff and debuff.
    -- Losing a buff is bad (pink), recovering from a debuff is good (yellow).
    local verb_color = is_debuff and 'verb_good' or 'verb_bad'
    local segments = {
        {text = subject_name,           color = actor_class},
        {text = ' ',                    color = 'default'},
        {text = verb,                   color = verb_color},
        {text = " '",                   color = 'default'},
        {text = status_nm,              color = status_color},
        {text = "'",                    color = 'default'},
    }

    local ev = {
        ts           = os.time(),
        source       = kind,
        mode         = -1,
        actor_id     = target_id or 0,
        actor_name   = subject_name,
        actor_class  = actor_class,
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = text,
        segments     = segments,
        status_id    = status_id,
        result       = result,
    }
    _ring.text_ring.push(ev)

    if M.debug_wear then
        windower.add_to_chat(207, string.format(
            '[buff-029] msg=%d sid=%d tgt=%d kind=%s name=%s class=%s',
            msg_id, status_id, target_id, kind, status_nm, actor_class))
    end
end

-- Expose for unit testing.
M._classify_status = classify_status
M._status_name     = status_name

return M