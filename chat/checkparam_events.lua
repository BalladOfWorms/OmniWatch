-- Checkparam event detector for the chat panel.
--
-- /checkparam <target> response arrives as a series of 0x029 action
-- message packets, NOT as a single 0x0DD packet as we initially
-- guessed. The FFXI client renders these directly to chat WITHOUT
-- firing the 'incoming text' event, so our normal capture path
-- never sees them.
--
-- Empirical packet pattern (May 2026, retail FFXI):
--   msg=733  p1=0    p2=0    p3=0   → "<Name>:" header line
--   msg=731  p1=N    p2=0    p3=0   → "Average item level: N."
--   msg=712  p1=A    p2=B    p3=0   → "Primary Accuracy: A / Primary Attack: B."
--   msg=713  p1=A    p2=B    p3=0   → "Auxiliary Accuracy: A / Auxiliary Attack: B."
--   msg=714  p1=A    p2=B    p3=0   → "Ranged Accuracy: A / Ranged Attack: B."
--   msg=715  p1=A    p2=B    p3=0   → "Evasion: A / Defense: B."
--
-- We watch for these message IDs in 0x029 packets and synthesize
-- chat events into the System tab. Other 0x029 messages (combat
-- action results, buff applications, etc.) are NOT touched here —
-- this module only fires for the checkparam-specific message IDs.
--
-- The 1+ second cooldown prevents duplicate emission if the server
-- sends the same checkparam line twice (rare but observed for some
-- queries).

local M = {}

local _ring        = nil
local _classifier  = nil

function M.set_deps(ring_mod, classifier_mod)
    _ring       = ring_mod
    _classifier = classifier_mod
end

M.debug = false

-- Trace mode: when on, log EVERY 0x029 message ID seen (with its
-- params) to the shared chat_packet_log.txt. Used to find msg IDs
-- for /check (mob examine) and other 0x029-carried text that
-- doesn't fit known sets. Mirrors emit/chat_packets trace toggle.
M.trace = false

local _trace_log_file = nil
local function _trace_log_line(line)
    if not _trace_log_file then
        local base = windower.addon_path or ''
        if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
            base = base .. '/'
        end
        local f, err = io.open(base .. 'data/chat_packet_log.txt', 'a')
        if not f then return end
        _trace_log_file = f
        local now = os.date('*t')
        f:write(string.format(
            '\n=== checkparam (0x029) trace started %04d-%02d-%02d %02d:%02d:%02d ===\n',
            now.year, now.month, now.day, now.hour, now.min, now.sec))
    end
    _trace_log_file:write(line)
    _trace_log_file:write('\n')
    _trace_log_file:flush()
end

-- Message IDs that constitute /checkparam output. Keys are message
-- IDs; values are formatter functions taking (p1, p2) returning a
-- chat line. Empirically determined from packet captures.
--
-- Header (msg 733) has no params — we resolve target name from id.
-- ilvl (msg 731): p1 = item level. p2 unused.
-- Stat pairs (712-715): p1 = left value, p2 = right value.
local CHECKPARAM_FORMATTERS = {
    [733] = function(name) return name .. ':' end,
    [731] = function(p1)   return string.format('Average item level: %d.', p1) end,
    [712] = function(p1, p2)
        return string.format('Primary Accuracy: %d / Primary Attack: %d.', p1, p2)
    end,
    [713] = function(p1, p2)
        return string.format('Auxiliary Accuracy: %d / Auxiliary Attack: %d.', p1, p2)
    end,
    [714] = function(p1, p2)
        return string.format('Ranged Accuracy: %d / Ranged Attack: %d.', p1, p2)
    end,
    [715] = function(p1, p2)
        return string.format('Evasion: %d / Defense: %d.', p1, p2)
    end,
}

-- Cooldown to suppress duplicate emissions if the server sends the
-- same checkparam line multiple times in rapid succession. Keyed by
-- (target_id, message_id) so different stat lines for the same
-- target don't collide. 1 second is well below user-driven
-- /checkparam cadence (manual command, ~1s round-trip).
local _last_emit = {}
local EMIT_COOLDOWN_SEC = 1

local function _name_for(id)
    if not id or id == 0 then return '?' end
    local mob = windower.ffxi.get_mob_by_id and
                windower.ffxi.get_mob_by_id(id)
    if mob and mob.name then return mob.name end
    return 'id#' .. tostring(id)
end

local function _build_event(target_name, target_id, line_text, actor_class)
    return {
        ts           = os.time(),
        source       = 'system',     -- routes to System tab
        mode         = -2,           -- synthetic
        actor_id     = target_id or 0,
        actor_name   = target_name or '',
        actor_class  = actor_class or 'other',
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = line_text,
        segments     = {},
    }
end

-- ── Public entry point ──────────────────────────────────────────────────

-- Called from OmniWatch.lua's 0x029 handler. Receives parsed fields
-- from the packet (msg_id, target_id, p1, p2). If the message ID is
-- a checkparam-line ID, format and push to the text ring.
--
-- Returns true if the message was handled (a checkparam line),
-- false otherwise.
function M.process_action_message(msg_id, target_id, p1, p2)
    if not _ring or not _ring.text_ring then return false end

    -- Trace every 0x029 msg ID with its params. Lets us find what
    -- message IDs /check (mob examine) and other unknown commands
    -- use, so we can route them later.
    if M.trace then
        local now = os.date('*t')
        _trace_log_line(string.format(
            '[%02d:%02d:%02d] [0x029] msg=%d target=%d p1=%d p2=%d',
            now.hour, now.min, now.sec,
            msg_id or 0, target_id or 0, p1 or 0, p2 or 0))
    end

    local formatter = CHECKPARAM_FORMATTERS[msg_id]
    if not formatter then return false end

    -- Cooldown: skip if we just emitted this exact (target, msg) pair.
    local now = os.time()
    local key = (target_id or 0) * 1000 + msg_id
    if (now - (_last_emit[key] or 0)) < EMIT_COOLDOWN_SEC then
        if M.debug then
            windower.add_to_chat(207,
                '[OW chkp] cooldown skipped msg=' .. tostring(msg_id))
        end
        return true
    end
    _last_emit[key] = now

    local target_name = _name_for(target_id)
    local line

    if msg_id == 733 then
        line = formatter(target_name)
    elseif msg_id == 731 then
        line = formatter(p1 or 0)
    else
        line = formatter(p1 or 0, p2 or 0)
    end

    local actor_class = 'other'
    if _classifier and _classifier.classify_entity and target_id then
        local c = _classifier.classify_entity(target_id)
        if c then actor_class = c end
    end

    _ring.text_ring.push(_build_event(target_name, target_id,
                                       line, actor_class))

    if M.debug then
        windower.add_to_chat(207, string.format(
            '[OW chkp] emitted: %s', line))
    end
    return true
end

M._CHECKPARAM_FORMATTERS = CHECKPARAM_FORMATTERS

return M