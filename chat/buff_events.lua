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

-- Recent self debuff applies emitted via the 0x028 action path
-- (status_id -> os.time()). The 0x063 sub-9 self-buff diff checks this
-- so a debuff that DID arrive with a recognized 0x028 apply message
-- isn't reported twice (once by M.process, once by the 0x063 diff a
-- moment later). Pruned lazily on lookup.
local _recent_self_debuff = {}
local _RECENT_SELF_WINDOW = 3   -- seconds

-- Recent self debuff WEAR-OFFS emitted via the 0x029 action-message path
-- (status_id -> os.time()). Mirror of _recent_self_debuff but for the
-- removal direction: the 0x063 sub-9 self-buff diff checks this so a
-- debuff that wore off with a recognized 0x029 message (e.g. a Viruna
-- cure, or a natural wear) isn't reported twice — once by
-- process_status_message and again by the 0x063 removal diff a moment
-- later. Removals that DON'T fire a 0x029 (e.g. Mix: Vaccine) have no
-- entry here, so the 0x063 diff reports them. Pruned lazily on lookup.
local _recent_self_wear = {}

function M.set_deps(ring_mod, classifier_mod)
    _ring       = ring_mod
    _classifier = classifier_mod
end

-- ── Probe log file ───────────────────────────────────────────────────────
-- Writes all chat-debug diagnostic lines to a single log file in
-- AppData: %APPDATA%/OmniWatch/chatdebug_log.txt. Every probe (text
-- capture, battle-classify, buff/debuff apply+wear, trust, packet
-- trace, etc.) funnels here via the unified //ow chatdebug command, so
-- all diagnostics land in one place that's easy to find and send.
-- Lazy-opened, appended, flushed per line. Errors swallowed so the
-- probe can never break the buff synth path. Falls back to the addon
-- data dir if APPDATA isn't set (non-Windows / unusual config).
local _probe_log_file = nil
local function _probe_log(line)
    if not _probe_log_file then
        local path
        local appdata = os.getenv('APPDATA')
        if appdata and appdata ~= '' then
            appdata = appdata:gsub('\\', '/')
            path = appdata .. '/OmniWatch/chatdebug_log.txt'
        else
            local base = windower.addon_path or ''
            if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
                base = base .. '/'
            end
            path = base .. 'data/chatdebug_log.txt'
        end
        local f = io.open(path, 'a')
        if not f then return end
        _probe_log_file = f
        local now = os.date('*t')
        f:write(string.format(
            '\n=== chatdebug started %04d-%02d-%02d %02d:%02d:%02d ===\n',
            now.year, now.month, now.day, now.hour, now.min, now.sec))
    end
    _probe_log_file:write(line)
    _probe_log_file:write('\n')
    _probe_log_file:flush()
end
M._probe_log = _probe_log

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

-- Public buff-vs-debuff check by status id. Uses the same
-- fallback-protected enfeebling set as classify_status, so callers
-- outside this module (e.g. OmniWatch.lua's buff-timer source
-- classifier) don't have to depend on _G.enfeebling being present —
-- when BattleMod isn't loaded, _G.enfeebling is nil and a direct
-- :contains() call would silently do nothing. Returns true for
-- enfeebles/debuffs (e.g. Disease = id 8), false otherwise.
function M.is_debuff(buff_id)
    if not buff_id then return false end
    local enf = _enfeebling_set()
    return enf and enf:contains(buff_id) or false
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

-- Verification dump for the 0x063 sub-9 self-buff parse. Called from the
-- OmniWatch 0x063 handler when M.debug_apply is on. Logs the raw packet
-- bytes (hex) plus the reconstructed buff-id list, throttled to once per
-- ~2s (0x063 sub-9 is sent very frequently). Lets us confirm the byte
-- layout / bitmask offsets against the live game. Defined AFTER
-- status_name so the local is in scope (Lua closes over locals visible
-- at definition point, not at call time).
local _self_dump_last = 0
function M.debug_self_buff_dump(packet, parsed_ct)
    if not M.debug_apply then return end
    local now = os.clock()
    if (now - _self_dump_last) < 2.0 then return end
    _self_dump_last = now

    local hexparts = {}
    for i = 1, 56 do
        local b = packet:byte(i)
        if not b then break end
        hexparts[#hexparts + 1] = string.format('%02X', b)
    end
    local idparts = {}
    if type(parsed_ct) == 'table' then
        for bid, cnt in pairs(parsed_ct) do
            idparts[#idparts + 1] =
                string.format('%d(%s)x%d', bid, status_name(bid), cnt)
        end
    end
    local t = os.date('*t')
    _probe_log(string.format(
        '[%02d:%02d:%02d] [0x063-raw] bytes: %s',
        t.hour, t.min, t.sec, table.concat(hexparts, ' ')))
    _probe_log(string.format(
        '             [0x063-parsed] %s',
        (#idparts > 0 and table.concat(idparts, ', ') or '(none)')))
end

-- Per-member 0x076 dump for the trust-buff-loss diagnostic. Called from
-- OmniWatch.lua's 0x076 handler for every member. Uses the SAME proven
-- path as debug_self_buff_dump: gated by M.debug_apply directly (not the
-- _loader is_buff_apply_probe accessor, which may not be deployed), and
-- writes via the buff_events-local _probe_log (always available, no
-- _loader export dependency). This sidesteps the deploy uncertainty that
-- kept the earlier _chat._probe_log-gated 0x076 probe silent. buffs is
-- the member's current buff-id list; player_id identifies the member.
function M.debug_party_member_dump(player_id, buffs)
    if not M.debug_apply then return end
    if not _probe_log then return end

    local cls = 'other'
    if _classifier and _classifier.classify_entity then
        local c = _classifier.classify_entity(player_id)
        if c then cls = c end
    end

    local ids = {}
    if type(buffs) == 'table' then
        for _, b in ipairs(buffs) do ids[#ids + 1] = tostring(b) end
    end
    local t = os.date('*t')
    _probe_log(string.format(
        '[%02d:%02d:%02d] [0x076-member] pid=%s class=%s nbuffs=%d ids={%s}',
        t.hour, t.min, t.sec,
        tostring(player_id), cls,
        (type(buffs) == 'table' and #buffs or 0),
        table.concat(ids, ',')))
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

    -- AoE probe: when a packet has 3+ targets (clearly an AoE
    -- buff/spell), log each target's action message + param + our
    -- classification to the chatdebug log. Captures the data needed to
    -- fix AoE buff-gain display (which message IDs non-primary targets
    -- use). Gated by M.debug_apply (the unified //ow chatdebug switch) —
    -- it used to be always-on, which spammed the log every fight.
    --
    -- CRITICAL: fully pcall-isolated. A diagnostic must NEVER be able to
    -- break the real apply emission below it. If print/format throws,
    -- the outer pcall in OmniWatch.lua would kill this whole function and
    -- silently drop ALL buff-apply events (while wear-offs, handled in a
    -- separate function, keep working) — so the probe is wrapped here.
    if M.debug_apply then
    pcall(function()
        local n_tgt = 0
        for _ in pairs(act.targets) do n_tgt = n_tgt + 1 end
        if n_tgt >= 3 then
            -- Classify the ACTOR (caster) once — this is the field the
            -- routing keys on for whether an AoE buff is shown. Seeing
            -- it here tells us why an other-party buff slips through:
            -- if the actor (or first subject) resolves to a visible
            -- class, the line shows. _cls() is tolerant of a missing
            -- classifier so the probe never throws.
            local function _cls(id)
                if not _classifier or not _classifier.classify_entity then
                    return 'noclassifier'
                end
                local c = _classifier.classify_entity(id)
                return tostring(c)
            end
            local actor_id = act.actor_id or 0
            local now = os.date('*t')
            _probe_log(string.format(
                '[%02d:%02d:%02d] [aoe-buff] ACTOR id=%s class=%s  '
                .. '(n_tgt=%d cat=%s act.param=%s spell=%s)',
                now.hour, now.min, now.sec,
                tostring(actor_id), _cls(actor_id), n_tgt,
                tostring(act.category), tostring(act.param),
                (function()
                    local sp = _G.res and _G.res.spells
                               and act.param and _G.res.spells[act.param]
                    return sp and (sp.en or sp.enl) or '?'
                end)()))
            for _, tgt in pairs(act.targets) do
                if tgt.actions then
                    for _, action in pairs(tgt.actions) do
                        local k, r = classify_status(action.message, action.param)
                        local rn = '?'
                        if _G.res and _G.res.buffs and _G.res.buffs[action.param] then
                            rn = _G.res.buffs[action.param].en or '?'
                        end
                        _probe_log(string.format(
                            '            cat=%s msg=%s param=%s tgt=%s '
                            .. 'tgtclass=%s kind=%s result=%s buffname=%s',
                            tostring(act.category), tostring(action.message),
                            tostring(action.param), tostring(tgt.id),
                            _cls(tgt.id),
                            tostring(k), tostring(r), rn))
                    end
                end
            end
        end
    end)
    end

    -- Targeted debuff-apply probe. Fires when M.debug_apply is on. The
    -- AoE probe above only triggers at 3+ targets, so a mob debuffing
    -- JUST YOU (a 1-target packet) is never captured there. This probe
    -- logs every action whose target is YOU or a party/alliance member,
    -- with msg_id / param / buffname and whether classify_status
    -- currently recognizes it. Used to find the message ID a mob
    -- TP-move/ability debuff-apply uses — the suspected cause of "I see
    -- the wear-off but not the apply": the apply lands on a message ID
    -- that battle_events SKIPS (in its STATUS_APPLY_MSGS) but buff_events
    -- does NOT recognize (not in its narrower set) — a dead zone where
    -- neither module emits a line. pcall-isolated; never throws.
    if M.debug_apply then
        pcall(function()
            local me = windower.ffxi.get_player()
            local my_id = me and me.id or 0
            local function _is_ally_target(id)
                if not _classifier or not _classifier.classify_entity then
                    return id == my_id
                end
                local c = _classifier.classify_entity(id)
                return c == 'self' or c == 'party' or c == 'alliance'
            end
            local now = os.date('*t')
            for _, tgt in pairs(act.targets) do
                if tgt.actions and _is_ally_target(tgt.id) then
                    for _, action in pairs(tgt.actions) do
                        local k, r = classify_status(action.message, action.param)
                        local rn = '?'
                        if _G.res and _G.res.buffs and _G.res.buffs[action.param] then
                            rn = _G.res.buffs[action.param].en or '?'
                        end
                        -- recognized = would buff_events emit a line for this?
                        local recognized = (k ~= nil)
                        _probe_log(string.format(
                            '[%02d:%02d:%02d] [debuff-apply] cat=%s msg=%s param=%s '
                            .. 'tgt=%s actor=%s recognized=%s kind=%s result=%s '
                            .. 'buffname=%s',
                            now.hour, now.min, now.sec,
                            tostring(act.category), tostring(action.message),
                            tostring(action.param), tostring(tgt.id),
                            tostring(act.actor_id),
                            tostring(recognized), tostring(k), tostring(r), rn))

                        -- ADDITIONAL-EFFECT sub-block. A mob TP move / WS
                        -- that also inflicts a status (Scythe Tail → Stun,
                        -- weapon procs, etc.) carries the status in a
                        -- SEPARATE add_effect sub-field, NOT in the main
                        -- action.message/param above. windower.packets
                        -- .parse_action exposes has_add_effect +
                        -- add_effect_message + add_effect_param (and a
                        -- spike_effect_* variant). We never logged these,
                        -- which is why the stun apply was invisible in the
                        -- packet stream even though it clearly landed.
                        -- Log them whenever present so we can see the real
                        -- (msg, param) the status rides on.
                        local ae_msg = action.add_effect_message
                        local ae_prm = action.add_effect_param
                        local has_ae = action.has_add_effect
                        if has_ae or (ae_msg and ae_msg ~= 0)
                           or (ae_prm and ae_prm ~= 0) then
                            local aen = '?'
                            if _G.res and _G.res.buffs and ae_prm
                               and _G.res.buffs[ae_prm] then
                                aen = _G.res.buffs[ae_prm].en or '?'
                            end
                            _probe_log(string.format(
                                '            └ ADD_EFFECT has=%s ae_msg=%s '
                                .. 'ae_param=%s ae_anim=%s ae_buffname=%s',
                                tostring(has_ae), tostring(ae_msg),
                                tostring(ae_prm),
                                tostring(action.add_effect_animation), aen))
                        end
                        -- Spike-effect variant (some retaliatory/elemental
                        -- procs use this slot instead of add_effect).
                        local se_msg = action.spike_effect_message
                        local se_prm = action.spike_effect_param
                        if action.has_spike_effect
                           or (se_msg and se_msg ~= 0)
                           or (se_prm and se_prm ~= 0) then
                            local sen = '?'
                            if _G.res and _G.res.buffs and se_prm
                               and _G.res.buffs[se_prm] then
                                sen = _G.res.buffs[se_prm].en or '?'
                            end
                            _probe_log(string.format(
                                '            └ SPIKE_EFFECT has=%s se_msg=%s '
                                .. 'se_param=%s se_buffname=%s',
                                tostring(action.has_spike_effect),
                                tostring(se_msg), tostring(se_prm), sen))
                        end
                    end
                end
            end
        end)
    end

    -- ("A, B, C gain 'March'") instead of one line per recipient.
    -- A single-element list renders the normal singular form.
    -- kind = 'buff'|'debuff'; result = 'apply'|'wear'.
    local _NAME_CAP = 18  -- show all names up to a full alliance (18).
                          -- Support players need to see everyone who got
                          -- the buff; "+N" overflow only triggers beyond
                          -- a full alliance, which doesn't happen for real
                          -- party/alliance buffs.
    local function _emit_status_event(subject_ids, param, kind, result)
        if type(subject_ids) ~= 'table' then
            subject_ids = { subject_ids }
        end
        if #subject_ids == 0 then return end
        local multi = (#subject_ids > 1)

        local status_nm = status_name(param)
        -- Verb agrees in number. Plural drops the trailing 's' / uses
        -- "are"/"recover" for the multi-subject condensed line.
        local verb
        if kind == 'debuff' then
            if result == 'apply' then
                verb = multi and 'are afflicted with' or 'is afflicted with'
            else
                verb = multi and 'recover from' or 'recovers from'
            end
        else
            if result == 'apply' then
                verb = multi and 'gain' or 'gains'
            else
                verb = multi and 'lose' or 'loses'
            end
        end

        local status_color = (kind == 'debuff')
                             and 'debuff_status' or 'buff_status'
        local verb_color
        if kind == 'debuff' then
            verb_color = (result == 'apply') and 'verb_bad' or 'verb_good'
        else
            verb_color = (result == 'apply') and 'verb_good' or 'verb_bad'
        end

        -- Build the subject portion: colored name segments separated by
        -- ", ", capped at _NAME_CAP with a "+N" overflow marker.
        local segments = {}
        local shown = math.min(#subject_ids, _NAME_CAP)
        local first_name, first_id
        for i = 1, shown do
            local sid = subject_ids[i]
            local snm = actor_name_for(sid)
            local sclass = 'other'
            if _classifier and _classifier.classify_entity then
                local c = _classifier.classify_entity(sid)
                if c then sclass = c end
            end
            if i == 1 then first_name, first_id = snm, sid end
            if i > 1 then
                segments[#segments + 1] = {text = ', ', color = 'default'}
            end
            segments[#segments + 1] = {text = snm, color = sclass}
        end
        local overflow = #subject_ids - shown
        if overflow > 0 then
            segments[#segments + 1] =
                {text = string.format(' +%d', overflow), color = 'default'}
        end
        -- " <verb> 'Status'"
        segments[#segments + 1] = {text = ' ',       color = 'default'}
        segments[#segments + 1] = {text = verb,      color = verb_color}
        segments[#segments + 1] = {text = " '",      color = 'default'}
        segments[#segments + 1] = {text = status_nm, color = status_color}
        segments[#segments + 1] = {text = "'",       color = 'default'}

        -- Flat text mirror.
        local name_parts = {}
        for i = 1, shown do
            name_parts[i] = actor_name_for(subject_ids[i])
        end
        local names_str = table.concat(name_parts, ', ')
        if overflow > 0 then
            names_str = names_str .. string.format(' +%d', overflow)
        end
        local text = string.format("%s %s '%s'", names_str, verb, status_nm)

        -- actor_id/class on the event reflect the FIRST subject (used by
        -- routing — an AoE party buff's first recipient is enough to land
        -- it in the Buffs tab; routing keys on buff_apply/wear channel).
        local first_class = 'other'
        if _classifier and _classifier.classify_entity and first_id then
            local c = _classifier.classify_entity(first_id)
            if c then first_class = c end
        end

        _ring.text_ring.push({
            ts           = os.time(),
            source       = kind,
            mode         = -1,
            actor_id     = first_id or 0,
            actor_name   = first_name or '',
            actor_class  = first_class,
            target_id    = 0,
            target_name  = '',
            target_class = '',
            text         = text,
            segments     = segments,
            status_id    = param,
            result       = result,
        })

        -- If this was a DEBUFF APPLY that includes the local player as a
        -- subject, record it so the 0x063 sub-9 self-buff diff doesn't
        -- re-report the same debuff a moment later. Only debuffs that
        -- happen to arrive via a recognized 0x028 message reach here;
        -- the 0x063 path is the catch-all for those that don't.
        if kind == 'debuff' and result == 'apply' then
            local me = windower.ffxi.get_player()
            local my_id = me and me.id
            if my_id then
                for i = 1, #subject_ids do
                    if subject_ids[i] == my_id then
                        _recent_self_debuff[param] = os.time()
                        break
                    end
                end
            end
        end
    end

    -- Pass 1: scan the packet for an established status apply. An AoE
    -- buff sends ONE packet where only the primary target carries the
    -- recognized "gains the effect" message; the other recipients get
    -- message 0 (continuation) with the same buff param. We capture the
    -- established (param, kind, result) so pass 2 can propagate it to
    -- recipients whose own message classify_status doesn't recognize.
    -- Only set for APPLY (AoE wear-offs come via process_status_message
    -- per-target, and we don't want to fabricate wears).
    --
    -- cat-11 AoE buffs (Protect/Shellra-as-cat11, Magic Atk/Def Boost,
    -- etc.) use messages classify_status doesn't key on: msg 194 on the
    -- primary, msg 280 on the other recipients. Neither is in
    -- STATUS_APPLY_MSGS, so without special handling aoe_param never
    -- establishes and the ENTIRE buff (every recipient, incl. trusts)
    -- shows nothing. Recognize the (cat 11, msg 194/280) PAIR as a buff
    -- apply, gated by the param resolving to a real buff — narrow and
    -- safe (other cat-11 msgs like 185/238/159/264 are damage/TP-move
    -- messages and are left alone). These are BUFFS, so a stray misfire
    -- would at worst show a spurious buff gain, not a phantom debuff.
    local function _cat11_buff_apply(action)
        if act.category ~= 11 then return nil end
        local m = action.message
        if m ~= 194 and m ~= 280 then return nil end
        local p = action.param
        local res = _G.res
        if not (res and res.buffs and p and res.buffs[p]
                and (res.buffs[p].en or res.buffs[p].enl)) then
            return nil
        end
        local enf = _enfeebling_set()
        local is_debuff = enf:contains(p)
        return (is_debuff and 'debuff' or 'buff')
    end

    local aoe_param, aoe_kind, aoe_result = nil, nil, nil
    for _, tgt in pairs(act.targets) do
        if tgt.actions then
            for _, action in pairs(tgt.actions) do
                local k, r = classify_status(action.message, action.param)
                if not k then
                    -- cat-11 buff apply (msg 194/280) isn't caught by
                    -- classify_status; recognize it here so Protect/Boost
                    -- AoEs establish an aoe_param to propagate.
                    local ck = _cat11_buff_apply(action)
                    if ck then k, r = ck, 'apply' end
                end
                if k and r == 'apply' and action.param and action.param ~= 0 then
                    aoe_param  = action.param
                    aoe_kind   = k
                    aoe_result = r
                    break
                end
            end
        end
        if aoe_param then break end
    end

    -- Pass 2: collect subjects grouped by (param, kind, result), then
    -- emit once per group — condensed to a single line when 2+ recipients
    -- share the same status (the AoE case). Use the target's own
    -- classification when recognized; otherwise propagate the established
    -- AoE apply to recipients that clearly share it.
    local groups = {}        -- key -> {param, kind, result, ids={}}
    local group_order = {}   -- preserve first-seen order
    local seen_ids = {}      -- per (key,id) dedupe within this packet

    local function _add_subject(sid, param, kind, result)
        if not sid then return end
        local key = tostring(param) .. '|' .. kind .. '|' .. result
        local g = groups[key]
        if not g then
            g = {param = param, kind = kind, result = result, ids = {}}
            groups[key] = g
            group_order[#group_order + 1] = key
        end
        local dk = key .. '|' .. tostring(sid)
        if not seen_ids[dk] then
            seen_ids[dk] = true
            g.ids[#g.ids + 1] = sid
        end
    end

    for _, tgt in pairs(act.targets) do
        if tgt.actions then
            for _, action in pairs(tgt.actions) do
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
                    -- Target carries its own recognized status message.
                    _add_subject(tgt.id, action.param, kind, result)
                elseif aoe_param then
                    -- Target didn't classify, but the packet is an AoE
                    -- status apply. Propagate only when it clearly shares
                    -- the effect: same param, or a pure continuation slot
                    -- (param AND message both 0/nil). A different non-zero
                    -- param is left alone (got something else / resisted).
                    local m = action.message
                    local p = action.param
                    local same_param   = (p == aoe_param)
                    local continuation = (p == 0 or p == nil)
                                         and (m == 0 or m == nil)
                    if same_param or continuation then
                        _add_subject(tgt.id, aoe_param, aoe_kind, aoe_result)
                    end
                end
            end
        end
    end

    -- Emit one event per group (condensed automatically when >1 id).
    for _, key in ipairs(group_order) do
        local g = groups[key]
        _emit_status_event(g.ids, g.param, g.kind, g.result)
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

    -- Record self DEBUFF wear-offs so the 0x063 removal diff doesn't
    -- double-report a removal that already came through here (natural
    -- wear, or a spell cure like Viruna that fires a 0x029 message).
    if is_debuff and result == 'wear' then
        local me = windower.ffxi.get_player()
        if me and me.id and target_id == me.id then
            _recent_self_wear[status_id] = os.time()
        end
    end

    if M.debug_wear then
        windower.add_to_chat(207, string.format(
            '[buff-029] msg=%d sid=%d tgt=%d kind=%s name=%s class=%s',
            msg_id, status_id, target_id, kind, status_nm, actor_class))
    end
end

-- Called from OmniWatch.lua's 0x076 party-buff diff. FFXI only sends
-- 0x029 status wear-off action-messages for the LOCAL player — a party
-- member losing a buff is reflected only in the periodic 0x076 party
-- buff packet, never as a 0x029. So self wear-offs come via
-- process_status_message (0x029) while PARTY/ALLIANCE wear-offs are
-- detected by diffing successive 0x076 snapshots and reported here.
--
-- Args are already resolved: player_id (whose buff dropped) and
-- buff_id (the status that disappeared from their list). No message-id
-- gating — the caller's diff already established this is a real loss.
-- The local player is intentionally NOT routed here by the caller
-- (their losses arrive via 0x029); doing both would double-emit.
--
-- Mirrors process_status_message's output exactly so party wear-offs
-- render identically to self wear-offs, differing only in actor_class.
function M.process_party_buff_loss(player_id, buff_id)
    if not buff_id or buff_id == 0 then return end
    if not _ring or not _ring.text_ring then return end

    -- Only emit for party/alliance members. The caller already skips
    -- the local player, but re-check here so a stray call can't fabricate
    -- a self wear-off that would duplicate the 0x029 path. Unaffiliated
    -- ids (another party seen via shared alliance packets, etc.) are
    -- dropped — consistent with the rest of the chat panel's affiliation
    -- model.
    local actor_class = 'other'
    if _classifier and _classifier.classify_entity then
        local c = _classifier.classify_entity(player_id)
        if c then actor_class = c end
    end
    if actor_class ~= 'party' and actor_class ~= 'alliance' then
        return
    end

    local enf = _enfeebling_set()
    local is_debuff = enf:contains(buff_id)
    local kind   = is_debuff and 'debuff' or 'buff'
    local result = 'wear'

    local subject_name = actor_name_for(player_id)
    local status_nm    = status_name(buff_id)
    -- Verb pairs match process()/process_status_message: buff loses,
    -- debuff recovers from.
    local verb = is_debuff and 'recovers from' or 'loses'
    local text = string.format("%s %s '%s'", subject_name, verb, status_nm)

    local status_color = is_debuff and 'debuff_status' or 'buff_status'
    local verb_color   = is_debuff and 'verb_good' or 'verb_bad'
    local segments = {
        {text = subject_name, color = actor_class},
        {text = ' ',          color = 'default'},
        {text = verb,         color = verb_color},
        {text = " '",         color = 'default'},
        {text = status_nm,    color = status_color},
        {text = "'",          color = 'default'},
    }

    _ring.text_ring.push({
        ts           = os.time(),
        source       = kind,
        mode         = -1,
        actor_id     = player_id or 0,
        actor_name   = subject_name,
        actor_class  = actor_class,
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = text,
        segments     = segments,
        status_id    = buff_id,
        result       = result,
    })

    if M.debug_wear then
        windower.add_to_chat(207, string.format(
            '[buff-076] pid=%d bid=%d kind=%s name=%s class=%s',
            player_id or 0, buff_id, kind, status_nm, actor_class))
    end
end

-- Called from OmniWatch.lua's 0x063 sub-9 self-buff diff. Reports a
-- DEBUFF that newly appeared in YOUR buff list. Probe captures proved
-- mob debuffs (Scythe Tail stun etc.) never surface in the 0x028 action
-- stream (not main message, add_effect, or spike_effect) — they arrive
-- only as the buff appearing in the 0x063 buff array the server pushes.
-- Diffing that packet is the packet-native way to catch them, parallel
-- to the 0x076 party-buff diff. Decoding a server packet, NOT polling
-- client state.
--
-- DEBUFFS ONLY: buffs you receive already emit a "gains" line via the
-- recognized status-apply messages in M.process (msg 230 etc.), so
-- emitting them here too would double them. Self wear-offs stay on the
-- 0x029 path (process_status_message), so this emits APPLIES ONLY.
-- The caller diffs and calls this once per buff_id that newly appeared.
function M.process_self_debuff_apply(buff_id)
    if not buff_id or buff_id == 0 then return end
    if not _ring or not _ring.text_ring then return end

    local enf = _enfeebling_set()
    local is_deb = enf:contains(buff_id)

    -- Probe: log EVERY newly-appeared buff the 0x063 diff detected, before
    -- filtering, so we can confirm the packet path is firing and see what
    -- it catches. Gated by the debuffapplyprobe toggle (M.debug_apply),
    -- written to the same data/ow_classify_probe.log as the 0x028 probe.
    if M.debug_apply then
        local now = os.date('*t')
        local nm = status_name(buff_id)
        _probe_log(string.format(
            '[%02d:%02d:%02d] [0x063-self] bid=%d is_debuff=%s name=%s',
            now.hour, now.min, now.sec,
            buff_id, tostring(is_deb), tostring(nm)))
    end

    -- Debuffs only. A non-enfeebling status that newly appears is a buff
    -- you received, already reported by the recognized 0x028 apply path.
    if not is_deb then return end

    -- Dedupe: if this exact debuff was just emitted via the 0x028 action
    -- path (recognized apply message), don't report it again. Prune the
    -- entry as we check it.
    local seen = _recent_self_debuff[buff_id]
    if seen then
        if (os.time() - seen) <= _RECENT_SELF_WINDOW then
            _recent_self_debuff[buff_id] = nil
            if M.debug_apply then
                _probe_log('             └ DEDUPED (already shown via 0x028)')
            end
            return
        end
        _recent_self_debuff[buff_id] = nil
    end

    local me = windower.ffxi.get_player()
    if not me or not me.id then return end

    local subject_name = me.name or actor_name_for(me.id)
    local status_nm    = status_name(buff_id)
    -- Debuff apply verb matches M.process: "is afflicted with".
    local verb = 'is afflicted with'
    local text = string.format("%s %s '%s'", subject_name, verb, status_nm)

    local segments = {
        {text = subject_name, color = 'self'},
        {text = ' ',          color = 'default'},
        {text = verb,         color = 'verb_bad'},   -- gaining a debuff: bad
        {text = " '",         color = 'default'},
        {text = status_nm,    color = 'debuff_status'},
        {text = "'",          color = 'default'},
    }

    _ring.text_ring.push({
        ts           = os.time(),
        source       = 'debuff',
        mode         = -1,
        actor_id     = me.id,
        actor_name   = subject_name,
        actor_class  = 'self',
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = text,
        segments     = segments,
        status_id    = buff_id,
        result       = 'apply',
    })

    if M.debug_wear then
        windower.add_to_chat(207, string.format(
            '[buff-063] bid=%d name=%s (self debuff apply)',
            buff_id, status_nm))
    end
end

-- Called from OmniWatch.lua's 0x063 sub-9 self-buff diff when a DEBUFF
-- leaves your buff array. Mirror of process_self_debuff_apply for the
-- removal direction. Catches debuff removals that DON'T fire a standard
-- 0x029 wear-off message — notably Mix: Vaccine (a Chemist ability) and
-- other ability-based cures. A spell cure like Viruna DOES fire a 0x029
-- wear-off (already shown via process_status_message), so we dedupe
-- against recent self wear-offs to avoid double-reporting those.
-- Debuffs only — a buff leaving your array is a buff wearing off, which
-- the 0x029 path already handles for self.
function M.process_self_debuff_loss(buff_id)
    if not buff_id or buff_id == 0 then return end
    if not _ring or not _ring.text_ring then return end

    local enf = _enfeebling_set()
    local is_deb = enf:contains(buff_id)

    if M.debug_apply then
        local now = os.date('*t')
        _probe_log(string.format(
            '[%02d:%02d:%02d] [0x063-self-loss] bid=%d is_debuff=%s name=%s',
            now.hour, now.min, now.sec,
            buff_id, tostring(is_deb), tostring(status_name(buff_id))))
    end

    -- Debuffs only. A buff leaving your array wears off via the 0x029
    -- self path already; reporting it here too would double it.
    if not is_deb then return end

    -- Dedupe: if this debuff just wore off via a recognized 0x029
    -- message (natural wear, or a spell cure like Viruna), don't report
    -- it again. Prune as we check.
    local seen = _recent_self_wear[buff_id]
    if seen then
        if (os.time() - seen) <= _RECENT_SELF_WINDOW then
            _recent_self_wear[buff_id] = nil
            if M.debug_apply then
                _probe_log('             └ DEDUPED (already shown via 0x029)')
            end
            return
        end
        _recent_self_wear[buff_id] = nil
    end

    local me = windower.ffxi.get_player()
    if not me or not me.id then return end

    local subject_name = me.name or actor_name_for(me.id)
    local status_nm    = status_name(buff_id)
    -- Debuff wear verb matches process_status_message: "recovers from".
    local verb = 'recovers from'
    local text = string.format("%s %s '%s'", subject_name, verb, status_nm)

    local segments = {
        {text = subject_name, color = 'self'},
        {text = ' ',          color = 'default'},
        {text = verb,         color = 'verb_good'},  -- recovering: good
        {text = " '",         color = 'default'},
        {text = status_nm,    color = 'debuff_status'},
        {text = "'",          color = 'default'},
    }

    _ring.text_ring.push({
        ts           = os.time(),
        source       = 'debuff',
        mode         = -1,
        actor_id     = me.id,
        actor_name   = subject_name,
        actor_class  = 'self',
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = text,
        segments     = segments,
        status_id    = buff_id,
        result       = 'wear',
    })

    if M.debug_wear then
        windower.add_to_chat(207, string.format(
            '[buff-063] bid=%d name=%s (self debuff loss)',
            buff_id, status_nm))
    end
end

-- Expose for unit testing.
M._classify_status = classify_status
M._status_name     = status_name

return M