-- Chat ring drain — pulls queued events from a ring and sends them
-- over UDP as one or more CHAT_BATCH packets.
--
-- Wire format (tab-delimited, one event per line):
--   CHAT_BATCH\t<count>\t<batch_index>\t<batch_total>
--   chat\t<ts>\t<source>\t<mode>\t<actor_id>\t<actor_name>\t<actor_class>\t<target_id>\t<target_name>\t<target_class>\t<segments_b64>\t<text_b64>\t<kind>
--   chat\t...
--
--   <count>        total events across the batch (across all datagrams)
--   <batch_index>  1-based index of this datagram within the batch
--   <batch_total>  total datagrams in this batch
--
-- batch_index / batch_total let Python reassemble large batches that
-- got split across multiple datagrams (when one drain pulls more
-- events than fit in MAX_DATAGRAM_BYTES). Within a single 10Hz drain
-- the events are emitted in chronological order — Python can rely on
-- that for ordering.
--
-- text and segments are base64-encoded to sidestep escaping. Tabs
-- and newlines in chat lines (rare but possible) would corrupt the
-- wire format otherwise.

local M = {}

-- UDP datagram budget. Loopback can carry larger frames but typical
-- MTU + safety margin keeps this conservative. At ~200 bytes per
-- event line, 1200 bytes/datagram = ~6 events/datagram, plenty for
-- the 10Hz cadence we expect.
local MAX_DATAGRAM_BYTES = 1200

-- Pure-Lua base64 encoder. Avoids requiring an external mime/base64
-- library — Windower's lua install is barebones (no mime, no base64
-- module on most setups). Canonical RFC-4648 without line wrapping.
--
-- Speed: ~3μs per 100 bytes on a modest CPU. At our volumes (10s of
-- chat lines/sec average, 100s during heavy LS chatter) this is well
-- within budget.
local _B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64_encode(s)
    if not s or s == '' then return '' end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b1 = s:byte(i)         or 0
        local b2 = s:byte(i + 1)     or 0
        local b3 = s:byte(i + 2)     or 0
        local n1 = math.floor(b1 / 4)
        local n2 = (b1 % 4) * 16 + math.floor(b2 / 16)
        local n3 = (b2 % 16) * 4 + math.floor(b3 / 64)
        local n4 = b3 % 64
        out[#out + 1] = _B64_CHARS:sub(n1 + 1, n1 + 1)
        out[#out + 1] = _B64_CHARS:sub(n2 + 1, n2 + 1)
        if i + 1 > n then
            out[#out + 1] = '='
            out[#out + 1] = '='
        elseif i + 2 > n then
            out[#out + 1] = _B64_CHARS:sub(n3 + 1, n3 + 1)
            out[#out + 1] = '='
        else
            out[#out + 1] = _B64_CHARS:sub(n3 + 1, n3 + 1)
            out[#out + 1] = _B64_CHARS:sub(n4 + 1, n4 + 1)
        end
        i = i + 3
    end
    return table.concat(out)
end

-- JSON encoder for segment data. Each segment is {text=str, color=str}.
-- The Python parser at the other end expects a list of 2-element
-- lists [text, color] — so we emit JSON arrays in that shape, not
-- objects (more compact, faster to encode without a real JSON lib).
--
-- Strings need minimal escaping: backslash, double-quote, and the
-- common control chars (\n \r \t). Bytes >= 0x80 pass through as-is
-- since Python's base64 → utf-8 decode handles them correctly.
local function _json_escape(s)
    if not s or s == '' then return '' end
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

local function encode_segments(segs)
    if not segs or #segs == 0 then return '' end
    local parts = {}
    for i = 1, #segs do
        local s = segs[i]
        local t = _json_escape(s.text or '')
        local c = _json_escape(s.color or 'default')
        parts[i] = '["' .. t .. '","' .. c .. '"]'
    end
    -- Wrap in array brackets and base64-encode the whole thing.
    local json = '[' .. table.concat(parts, ',') .. ']'
    return b64_encode(json)
end

-- Format one event into its tab-delimited wire line. Caller joins
-- multiple lines into a datagram payload.
local function format_event(ev)
    return string.format(
        'chat\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s',
        math.floor(ev.ts or 0),
        ev.source or 'chat',
        ev.mode or 0,
        ev.actor_id or 0,
        ev.actor_name or '',
        ev.actor_class or 'other',
        ev.target_id or 0,
        ev.target_name or '',
        ev.target_class or '',
        encode_segments(ev.segments),
        b64_encode(ev.text or ''),
        ev.kind or '')
end

-- Drain a ring and send its contents to udp_sock as one or more
-- CHAT_BATCH datagrams. Returns the number of events sent.
--
-- on_drained: optional callback invoked once per event AFTER the
-- payload is built but BEFORE the send. Lets _loader.lua tee drained
-- events into a history ring without drain.lua having to know about
-- history. Signature: function(event_table) end. Errors in the
-- callback are caught with pcall so a bad history-side effect can't
-- break the send.
--
-- Splitting algorithm: greedy. Build a payload by appending event
-- lines; when adding the next line would exceed MAX_DATAGRAM_BYTES,
-- flush the current payload as one datagram and start a new one.
-- All datagrams in a batch carry the same total event count in the
-- header, plus their (1-based) index within the batch.
function M.drain(ring, udp_sock, on_drained)
    if not ring or not udp_sock then return 0 end
    local events = ring.drain()
    local total  = #events
    if total == 0 then return 0 end

    -- Tee to history BEFORE send. Doing this first means a UDP send
    -- failure can't lose the history record. pcall guards each call
    -- so a buggy callback can't kill the drain.
    if on_drained then
        for i = 1, total do
            pcall(on_drained, events[i])
        end
    end

    -- Format every event line up front.
    local lines = {}
    for i = 1, total do
        lines[i] = format_event(events[i])
    end

    -- Pack line ranges into datagrams. Each entry in `datagrams`
    -- holds first/last line indices for that datagram.
    local datagrams = {}
    local i = 1
    while i <= total do
        local payload_size = 32      -- header reservation
        local first = i
        while i <= total do
            local line_size = #lines[i] + 1
            if payload_size + line_size > MAX_DATAGRAM_BYTES
               and i > first then
                break
            end
            payload_size = payload_size + line_size
            i = i + 1
        end
        datagrams[#datagrams + 1] = {first = first, last = i - 1}
    end

    -- Send each datagram with correct (index, total) in header.
    local batch_total = #datagrams
    for idx, d in ipairs(datagrams) do
        local body = {}
        for j = d.first, d.last do
            body[#body + 1] = lines[j]
        end
        local hdr = string.format('CHAT_BATCH\t%d\t%d\t%d',
                                  total, idx, batch_total)
        udp_sock:send(hdr .. '\n' .. table.concat(body, '\n'))
    end

    return total
end

-- Expose b64_encode for unit-testing.
M._b64_encode = b64_encode

return M