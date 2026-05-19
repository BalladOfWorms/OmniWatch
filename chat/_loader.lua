-- OmniWatch chat module entry point.
-- Returns a table exposing the chat panel's Lua-side functionality:
--   classify_entity(id) → (category, display_name, party_slot|nil)
--   emit_chat(mode, sender_name, text)         -- incoming text capture
--   process_action(act)                        -- buff/debuff synthesis
--   process_battle_action(act)                 -- combat synthesis
--   process_action_message(...)                -- /checkparam capture
--   drain_text(udp_sock)   → count of events drained
--   text_ring   -- exposed for diagnostics (//ow chatdump)
--   text_history
--   set_debug(on) -- toggles per-emit chat echo
--
-- Loaded from OmniWatch.lua via loadfile, same pattern as gearinfo/_loader.
-- The chat module is OPTIONAL — if any file under chat/ fails to load,
-- OmniWatch continues running without the chat panel.

local M = {}

-- Resolve our own directory so child files can be loaded with absolute
-- paths (loadfile + absolute path is what the gearinfo and sim loaders
-- already use; require is avoided due to Windows filename casing quirks
-- with package.path resolution).
local base = windower.addon_path or ''
if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
    base = base .. '/'
end
local chat_dir = base .. 'chat/'

local function load_submod(name)
    local path = chat_dir .. name .. '.lua'
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, err
    end
    local ok, result = pcall(chunk)
    if not ok then
        return nil, result
    end
    return result, nil
end

-- Submodules load order: classifier and ring are dep-free; emit
-- depends on both; drain depends on nothing module-level (it takes
-- ring + sock at call time).

local classifier, cerr = load_submod('classifier')
if not classifier then
    return nil, 'chat/classifier.lua failed: ' .. tostring(cerr)
end

local ring, rerr = load_submod('ring')
if not ring then
    return nil, 'chat/ring.lua failed: ' .. tostring(rerr)
end

local emit, eerr = load_submod('emit')
if not emit then
    return nil, 'chat/emit.lua failed: ' .. tostring(eerr)
end

local drain, derr = load_submod('drain')
if not drain then
    return nil, 'chat/drain.lua failed: ' .. tostring(derr)
end

local buff_events, berr = load_submod('buff_events')
if not buff_events then
    return nil, 'chat/buff_events.lua failed: ' .. tostring(berr)
end

local checkparam_events, cperr = load_submod('checkparam_events')
if not checkparam_events then
    return nil, 'chat/checkparam_events.lua failed: ' .. tostring(cperr)
end

local battle_events, beerr = load_submod('battle_events')
if not battle_events then
    return nil, 'chat/battle_events.lua failed: ' .. tostring(beerr)
end

local chat_packets, cppkterr = load_submod('chat_packets')
if not chat_packets then
    return nil, 'chat/chat_packets.lua failed: ' .. tostring(cppkterr)
end

-- Wire emit's dependencies.
emit.set_deps(ring, classifier)
buff_events.set_deps(ring, classifier)
checkparam_events.set_deps(ring, classifier)
battle_events.set_deps(ring, classifier)
chat_packets.set_deps(ring, classifier)

-- Public API.
M.classify_entity = classifier.classify_entity

M.text_ring      = ring.text_ring
M.text_history   = ring.text_history

M.emit_chat     = emit.emit_chat

-- Hook called from OmniWatch.lua's handle_incoming_action with the
-- parsed action packet. Walks targets/actions and emits synthetic
-- chat events for status applications and wear-offs so the chat
-- panel's Buffs and Debuffs tabs can display them. Errors are
-- handled inside buff_events.process — never throws.
M.process_action = buff_events.process

-- Hook called from OmniWatch.lua's 0x029 handler with the unpacked
-- action-message fields. When the msg_id is a status wear-off
-- (64, 204, 206, 350, 531), synthesizes a colored chat event for
-- the Buffs/Debuffs/Mob tab. 0x028 action packets don't fire for
-- natural wear-offs; this is the only packet source that does.
M.process_status_message = buff_events.process_status_message

-- Hook called from OmniWatch.lua's 0x028 handler. Synthesizes
-- per-action colored chat events from the action packet, replacing
-- FFXI's native battle log lines in the chat panel. Status-effect
-- messages are intentionally skipped here so buff_events.lua handles
-- them without duplication.
M.process_battle_action = battle_events.process

-- Hook called from OmniWatch.lua's 0x029 handler with the parsed
-- action-message fields. /checkparam responses arrive as 0x029
-- packets with specific message IDs (712-715, 731, 733). The
-- checkparam_events module recognizes those IDs and synthesizes
-- chat events into the System tab. Non-checkparam message IDs are
-- ignored, so this is safe to call on every 0x029.
M.process_action_message = checkparam_events.process_action_message

-- Hook called from OmniWatch.lua's 'incoming chunk' event with the
-- raw packet bytes. The chat_packets module recognizes 0x017 (real
-- chat: say/tell/yell/shout/party/LS) and synthesizes colored chat
-- events. Non-0x017 packets are ignored, so this is safe to call on
-- every incoming chunk.
M.process_chat_packet = chat_packets.process

-- Tee callback: push each drained event into the history ring so
-- //ow chatdump has something to inspect even when the live ring is
-- empty (which is most of the time at 10Hz drain).
local function _tee_text(ev) ring.text_history.push(ev) end

function M.drain_text(udp_sock)
    return drain.drain(ring.text_ring, udp_sock, _tee_text)
end

-- Clear history ring without touching the live ring. Used by
-- //ow chatreset to clean up between test scenarios.
function M.reset_history()
    ring.text_history.reset()
end

function M.set_debug(on)
    emit.debug = on and true or false
end

function M.is_debug()
    return emit.debug
end

function M.set_hex_capture(on)
    emit.hex_capture = on and true or false
end

function M.is_hex_capture()
    return emit.hex_capture
end

-- Toggle for the checkparam packet diagnostic. When on, every 0x0DD
-- packet that arrives dumps its full parsed field set to chat so we
-- can see what's actually in it. Helpful when checkparam output isn't
-- landing in the System tab — most likely cause is wrong field names
-- in checkparam_events.STAT_FIELDS, which this surfaces.
function M.set_cp_debug(on)
    checkparam_events.debug = on and true or false
end

function M.is_cp_debug()
    return checkparam_events.debug
end

-- Toggle for the 0x017 chat packet diagnostic. When on, every chat
-- packet that arrives dumps its parsed mode/sender/message to chat.
-- Useful for diagnosing missing chat — see chat/chat_packets.lua.
function M.set_chat_pkt_debug(on)
    chat_packets.debug = on and true or false
end

function M.is_chat_pkt_debug()
    return chat_packets.debug
end

-- Toggle for the comprehensive 0x017 trace mode. When on, EVERY
-- chat packet (regardless of accepted-mode filter) is logged to
-- data/chat_packet_log.txt AND a compact one-liner to FFXI chat.
-- Used for empirical mode → channel mapping. See chat/chat_packets.lua.
function M.set_chat_pkt_trace(on)
    chat_packets.trace = on and true or false
    -- Mirror on emit.lua so a single "trace on" captures both packet
    -- and incoming-text events to the same file with [PKT]/[TXT] tags.
    emit.trace = on and true or false
    -- Mirror on checkparam_events to capture 0x029 message IDs (used
    -- for /check, /checkparam, and other action-message text). Helps
    -- find what msg IDs unknown commands use so we can route them.
    checkparam_events.trace = on and true or false
end

function M.is_chat_pkt_trace()
    return chat_packets.trace
end

-- Toggle for the buff_events action-message diagnostic. When on,
-- every action message reaching buff_events.process is logged with
-- its msg_id, status_id, target, and our classification result.
-- Used for finding mob wear-off msg_ids that aren't in STATUS_WEAR_MSGS
-- (otherwise "The X is no longer Y" never produces a chat event).
function M.set_buff_wear_probe(on)
    buff_events.debug_wear = on and true or false
end

function M.is_buff_wear_probe()
    return buff_events.debug_wear
end

-- Toggle for the dropped-high-mode telemetry. When on, every
-- never-before-seen mode that gets filtered out by the high-mode
-- filter prints a one-line preview to chat. Off by default to keep
-- the console clean. Toggle on when diagnosing "this line isn't
-- showing up" issues — it tells you what mode byte the missing
-- text arrived on so we know what to whitelist.
function M.set_dropped_mode_log(on)
    emit.dropped_mode_log = on and true or false
end

function M.is_dropped_mode_log()
    return emit.dropped_mode_log
end

-- Toggle for condensed multi-hit melee/ranged display. When on,
-- multiple swings on the same target in one packet collapse to one
-- chat line; when off, each swing is its own line. See
-- chat/battle_events.lua condense_melee.
--
-- The magic condense (AoE songs / Cure V / ga-spells) is bundled
-- under the same toggle for now — they're conceptually the same
-- "show one line per round instead of per hit" idea.
function M.set_condense_melee(on)
    battle_events.condense_melee = on and true or false
    battle_events.condense_magic = on and true or false
end

function M.is_condense_melee()
    return battle_events.condense_melee
end

return M