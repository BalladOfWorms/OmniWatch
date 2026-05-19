-- chat/chat_packets.lua
--
-- Handler for incoming chat packet 0x017 (say/shout/tell/yell/
-- party/LS/emote). Replaces the incoming-text route for these
-- channels — packets are more reliable than text (no addon mangling,
-- no encoding ambiguity, no orphan color bytes from BattleMod).
--
-- Packet format (from Windower's fields.lua):
--   offset 0x04 (1 byte):  Mode
--   offset 0x05 (1 byte):  GM flag (bool)
--   offset 0x06 (2 bytes): padding (yell mode 0x1A uses for zone id)
--   offset 0x08 (15 bytes): Sender Name (null-padded, char[0xF])
--   offset 0x17 (var):     Message (null-terminated, max 150 chars)
--
-- Lua unpack format: 'iCBHS16z'
--   i  - 4-byte header (ignored)
--   C  - 1-byte Mode (unsigned char)
--   B  - 1-byte GM flag (bool)
--   H  - 2-byte zone/padding (unsigned short)
--   S16 - 16-byte sender name (we trim trailing nulls)
--   z  - null-terminated message
--
-- Mode codes (FFXI server's, matches Windower's incoming text mode):
--   1  = /say
--   2  = /say echo (own outgoing — won't appear via 0x017, that's 0x0B6)
--   3  = /shout
--   4  = /tell received
--   5  = /party
--   6  = /linkshell 1
--   7  = /linkshell 2 (placeholder; 27 is actual)
--   9  = /emote
--   11 = /yell
--   12 = /tell sent (own — won't appear via 0x017)
--   26 = /yell zone-broadcast variant
--   27 = /linkshell 2

local M = {}

-- Dependencies injected by _loader.lua via set_deps(ring, classifier).
local _ring, _classifier

function M.set_deps(ring, classifier)
    _ring = ring
    _classifier = classifier
end

-- ── Mode filter ─────────────────────────────────────────────────────────
-- Modes we ACCEPT (synthesize an event for). These are PACKET modes
-- from 0x017, not FFXI "incoming text" modes. They differ from the
-- mode values that emit.lua sees on incoming text.
--
-- Empirical observation (Asura, 2026 client):
--   3 = tell received  (CONFIRMED)
-- Others assumed based on Windower wiki + standard FFXI packet
-- Mode filter ─────────────────────────────────────────────────────────
-- Modes we ACCEPT (synthesize an event for). These are PACKET modes
-- from 0x017, not FFXI "incoming text" modes. They differ from the
-- mode values that emit.lua sees on incoming text.
--
-- Empirical observation (Asura, 2026 client):
--   3  = tell received       (CONFIRMED)
--   5  = linkshell 1         (CONFIRMED)
--   26 = yell / shout        (CONFIRMED)
--   33 = server AT broadcast (NOT chat — /sea results, RoE
--        announcements, achievements, etc.; always carries the same
--        AT phrase. Empirically observed to NOT be player chat.
--        Excluded by omission from this list.)
-- Others assumed based on Windower wiki + standard FFXI packet
-- documentation; will be refined as we observe more packet types.
-- If a packet arrives with mode not in this set, it's ignored.
local ACCEPTED_MODES = {
    [0]  = true,    -- /say (assumed)
    [1]  = true,    -- /shout (assumed)
    [3]  = true,    -- /tell received (CONFIRMED)
    [4]  = true,    -- /party (assumed)
    [5]  = true,    -- /linkshell 1 (CONFIRMED)
    [7]  = true,    -- /emote (assumed)
    [26] = true,    -- /yell (CONFIRMED)
    [27] = true,    -- /linkshell 2 (assumed)
}

-- ── Helpers ─────────────────────────────────────────────────────────────

-- Resource library for resolving auto-translate phrase IDs to text.
-- Loaded lazily on first AT lookup; some Windower setups don't have
-- the resources library available, in which case we fall through to
-- {AT} placeholder.
local _res = nil
local _res_load_attempted = false

local function _load_resources()
    if _res_load_attempted then return _res end
    _res_load_attempted = true
    local ok, res = pcall(require, 'resources')
    if ok and res and res.auto_translates then
        _res = res
    end
    return _res
end

-- Resolve a single 6-byte AT sequence (FD A B C D FD) to its English
-- phrase text from windower resources. Returns the wrapped phrase
-- like "{Null Loop}" or the {AT} placeholder if not found.
--
-- Format per Windower forums "Outputting an Autotranslate Message":
--   byte 1: 0xFD (start marker)
--   byte 2: type / category
--   byte 3: language indicator
--   bytes 4-5: phrase ID, big-endian (= b4*256 + b5)
--   byte 6: 0xFD (end marker)
--
-- The phrase ID maps directly to res.auto_translates[id].en. If we
-- can't find it (or resources lib unavailable), return {AT}.
local function _resolve_at_phrase(b2, b3, b4, b5)
    local res = _load_resources()
    if not res then return '{AT}' end
    local id = b4 * 256 + b5
    local entry = res.auto_translates[id]
    if entry and entry.en then
        return '{' .. entry.en .. '}'
    end
    -- Items / Key Items use different encoding ranges. Try alternate
    -- byte combinations just in case the field order varies. (Defensive
    -- fallback; rarely needed.)
    local alt_id = b2 * 256 + b3
    local alt = res.auto_translates[alt_id]
    if alt and alt.en then
        return '{' .. alt.en .. '}'
    end
    return '{AT}'
end

-- Strip FFXI's autotranslate markers and color codes, and clean any
-- non-ASCII byte sequences that would render as boxes in Python.
--
-- Bytes we handle:
--   \xFD <4 non-zero bytes> \xFD   - autotranslate phrase (6 bytes total).
--                                    We attempt to RESOLVE the phrase via
--                                    windower res.auto_translates lookup
--                                    (showing "{Null Loop}" instead of
--                                    "{AT}"). Falls back to "{AT}" if the
--                                    resources lib isn't loadable or the
--                                    ID isn't in the dictionary.
--   \x1F<byte>                      - foreground color set (2-byte sequence)
--   \x1E<byte>                      - foreground color reset (2-byte sequence)
--   \x01-\x1F, \x7F                 - control bytes - drop
--   bytes >= 0x80                   - Shift-JIS extended bytes. FFXI chat
--                                    is SJIS-encoded but Python expects
--                                    UTF-8. Replace with '?' until proper
--                                    SJIS→UTF-8 conversion is added.
local _FD = string.char(0xFD)
local _COLOR_SET  = string.char(0x1F) .. '.'
local _COLOR_RST  = string.char(0x1E) .. '.'

-- Walk a string and resolve all AT sequences. We do this with a manual
-- byte scan rather than gsub, because gsub's capture-based replacement
-- function would let us look at the 4 inner bytes, but the FD-bracket
-- pattern is fragile with Lua's pattern matcher when bytes can be any
-- value 0x01-0xFF. Walking explicitly is more robust.
--
-- Two AT phrase formats observed in FFXI chat:
--   1. New format: FD XX XX XX XX FD (6 bytes)
--      Used by the auto-translate system internally; XX bytes contain
--      type, language, and 2-byte phrase ID.
--   2. Old format: EF 27 ... EF 28 (variable length, ASCII text inside)
--      Used by older auto-translate routes and by /echo with literal
--      {word} input. The text inside the brackets is the phrase as-is.
--      Replace the wrappers with curly braces.
local function _resolve_all_at_phrases(s)
    if not s or s == '' then return '' end

    -- Old format first (EF 27 ... EF 28) — replace wrappers with { }
    -- so the inner ASCII text becomes a normal {...} display.
    local EF27 = string.char(0xEF, 0x27)
    local EF28 = string.char(0xEF, 0x28)
    s = s:gsub(EF27, '{')
    s = s:gsub(EF28, '}')

    -- New format (FD...FD) — resolve via res.auto_translates lookup.
    if not s:find(_FD, 1, true) then return s end

    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = s:byte(i)
        if b == 0xFD and i + 5 <= n and s:byte(i + 5) == 0xFD then
            -- Found 6-byte AT sequence. Resolve and emit.
            local b2 = s:byte(i + 1)
            local b3 = s:byte(i + 2)
            local b4 = s:byte(i + 3)
            local b5 = s:byte(i + 4)
            out[#out + 1] = _resolve_at_phrase(b2, b3, b4, b5)
            i = i + 6
        else
            out[#out + 1] = string.char(b)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function _strip_markers(s)
    if not s or s == '' then return '' end

    -- Autotranslate phrases FIRST. AT byte sequences (FD..FD or
    -- EF27..EF28) contain high bytes that would be mangled by SJIS
    -- decoding. Resolving them to readable {Phrase} text removes
    -- those marker bytes from the stream.
    s = _resolve_all_at_phrases(s)

    -- Color escape sequences. Drop the escape byte AND the byte
    -- following it.
    s = s:gsub(_COLOR_SET, '')
    s = s:gsub(_COLOR_RST, '')

    -- Remaining single control bytes (0x01-0x1F, 0x7F) - drop.
    s = s:gsub('[%z\1-\8\11-\31\127]', '')

    -- Convert remaining SJIS bytes to UTF-8. FFXI chat from packet
    -- sources is often Shift-JIS encoded (★ icons, Japanese player
    -- names, etc.). The Python overlay expects UTF-8 and its font has
    -- UTF-8 glyphs, so we normalize here. Skip if all bytes are
    -- already ASCII to avoid the round-trip overhead.
    if windower and windower.from_shift_jis then
        local has_high = false
        for i = 1, #s do
            if s:byte(i) >= 0x80 then has_high = true; break end
        end
        if has_high then
            local ok, converted = pcall(windower.from_shift_jis, s)
            if ok and converted and converted ~= '' then
                s = converted
            end
        end
    end

    return s
end

-- Resolve sender_name → actor_class via the classifier. The classifier
-- expects an ID, but 0x017 only carries a name. Look up the mob by
-- name; if not present (most tells, all distant LS), fall back to
-- 'other' so the renderer still gets something usable.
local function _classify_sender(sender_name)
    if not sender_name or sender_name == '' then
        return 'other'
    end
    if not _classifier or not _classifier.classify_entity then
        return 'other'
    end
    local mob = windower.ffxi.get_mob_by_name(sender_name)
    if mob and mob.id then
        local class = _classifier.classify_entity(mob.id)
        if class then return class end
    end
    return 'other'
end

-- ── Packet handler ──────────────────────────────────────────────────────

-- Handle a 0x0CC (Linkshell Message) packet. Extracts the LS MoTD
-- text and synthesizes an LS1/LS2 chat event.
--
-- Empirical packet structure (from trace data):
--   Bytes 1-4:    Packet header (id + len + seq)
--   Bytes 5-8:    Flags / permission bits. Byte 5 = 0x05 indicates
--                 the "no message exists" reply; byte 5 = 0x70 (or
--                 similar non-0x05) indicates a real message.
--   Bytes 9-136:  Message text (128 bytes, NUL-padded, may contain
--                 Shift-JIS multi-byte for stars/icons like 81 99 = ★).
--   Bytes 137-140: Timestamp or last-edit ID (uint32).
--   Bytes 141-156: Setter name (16 bytes, NUL-padded ASCII).
--   Bytes 157-160: LS slot indicator (uint32 little-endian).
--                 01 = Linkshell 1, 02 = Linkshell 2.
--   Bytes 161+:   Trailing bytes (timestamps, padding) — ignored.
--
-- When the message is empty (no MoTD set), the server typically also
-- emits an incoming-text "No linkshell message exists." line at
-- mode 123, so we don't need to synthesize anything in that case.
local function _handle_lsmes_packet(data)
    if #data < 160 then return end

    -- Detect "no message" via empty/garbage at message position.
    -- We require the first byte at offset 0x08 to be printable
    -- ASCII (0x20-0x7E) OR a known SJIS high byte (0x80-0x9F /
    -- 0xE0-0xFC). Otherwise it's the empty/header-only reply.
    local first_msg_byte = data:byte(9) or 0
    local is_printable = (first_msg_byte >= 0x20 and first_msg_byte <= 0x7E)
                      or (first_msg_byte >= 0x80 and first_msg_byte <= 0x9F)
                      or (first_msg_byte >= 0xE0 and first_msg_byte <= 0xFC)
    if not is_printable then return end

    -- Extract message text (bytes 9-136, NUL-terminated).
    local msg_chars = {}
    for i = 9, 136 do
        local b = data:byte(i)
        if not b or b == 0 then break end
        msg_chars[#msg_chars + 1] = string.char(b)
    end
    local message_raw = table.concat(msg_chars)
    if message_raw == '' then return end
    local message = _strip_markers(message_raw)

    -- Extract setter name (bytes 141-156).
    local setter_chars = {}
    for i = 141, 156 do
        local b = data:byte(i)
        if not b or b == 0 then break end
        setter_chars[#setter_chars + 1] = string.char(b)
    end
    local setter = table.concat(setter_chars)
    if setter == '' then setter = '?' end

    -- LS slot determination. Empirically observed:
    --   /ls2mes (pearl in LS2 slot) → byte 6 = 0x42 (bit 0x40 set)
    --   /lsmes  (pearl in LS1 slot) → byte 6 = 0x02 (bit 0x40 clear)
    -- The bit 0x40 in byte 6 reliably indicates LS2 vs LS1. Earlier
    -- versions of this code used byte 157 (`02 00 00 00`) but that
    -- byte is constant `02` regardless of which LS the message is
    -- for — likely an unrelated status field.
    local flags_byte = data:byte(6) or 0
    local is_ls2 = (flags_byte % 128) >= 64   -- test bit 0x40 (Lua 5.1
                                              -- has no bitwise ops;
                                              -- modulo + threshold
                                              -- isolates that bit)

    -- Build segments and route. LS1 → chat_ls1, LS2 → chat_ls2.
    -- The whole MoTD line is themed with the channel color (light
    -- green for LS1, dark green for LS2) rather than just the sender
    -- name — makes login banner lines visually distinct from regular
    -- LS chat where only the sender is colored.
    --
    -- Format matches FFXI's native MoTD echo:
    --   [N]< <LS name>: <Setter> >
    --   <Message text>
    -- LS name is pulled from windower.ffxi.get_player().linkshell or
    -- .linkshell2 since the 0x0CC packet doesn't carry it.
    local channel, sender_color, slot_num
    if is_ls2 then
        channel      = 'chat_ls2'
        sender_color = 'ch_ls2'
        slot_num     = 2
    else
        channel      = 'chat_ls1'
        sender_color = 'ch_ls1'
        slot_num     = 1
    end

    -- Pull the LS name from player info. Preferred source is the
    -- slot matching the packet's flag bit (linkshell2 for LS2,
    -- linkshell for LS1). When that slot is empty (common: the
    -- server sends BOTH an LS1 and an LS2 MoTD on zone-in even when
    -- only one pearl is equipped — the unequipped-slot field is
    -- nil), fall back to whichever LS field IS populated. You can
    -- only receive a MoTD for an LS you're equipped to, so the
    -- populated field is the right name to show. If both fields
    -- are empty (rare race during pearl swap / zoning), fall back
    -- to a generic label so we at least produce something.
    local ls_name
    local player = windower.ffxi.get_player()
    if player then
        local ls1 = player.linkshell
        local ls2 = player.linkshell2
        if ls1 == '' then ls1 = nil end
        if ls2 == '' then ls2 = nil end
        if is_ls2 then
            ls_name = ls2 or ls1
        else
            ls_name = ls1 or ls2
        end
    end
    if not ls_name or ls_name == '' then
        ls_name = '(linkshell)'
    end

    -- Header line: [N]< LS_name: Setter >
    -- Body line:   the actual MoTD message
    --
    -- Emit as TWO SEPARATE ring events rather than one event with an
    -- embedded '\n'. The Python wrap+render path treats '\n' as a
    -- normal character (the wrap word-splitter only breaks on ' '),
    -- which causes pygame's font.render to either inline-render the
    -- newline as a box glyph or produce a multi-line surface that
    -- gets blitted at a single (x, y) — both result in visible
    -- character overlap in the chat panel. Two events render as two
    -- clean chat rows with no special-casing needed downstream.
    local header_text = string.format('[%d]< %s: %s >',
                                      slot_num, ls_name, setter)

    -- Translate to FFXI incoming-text mode 205 (LS MoTD), which
    -- CHAT_MODE_SET_LS1 already routes to LS1 tab. LS2 still uses
    -- ls_slot to route via channel hint.
    local now_ts = os.time()

    -- Event 1: header line.
    _ring.text_ring.push({
        ts           = now_ts,
        source       = 'chat',
        mode         = 205,
        kind         = channel,
        actor_id     = 0,
        actor_name   = setter,
        actor_class  = 'other',
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = header_text,
        segments     = {
            {text = header_text, color = sender_color},
        },
    })

    -- Event 2: body line. Same ts / mode / kind so it lands in the
    -- same tab as the header, rendered as the row directly below.
    _ring.text_ring.push({
        ts           = now_ts,
        source       = 'chat',
        mode         = 205,
        kind         = channel,
        actor_id     = 0,
        actor_name   = setter,
        actor_class  = 'other',
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = message,
        segments     = {
            {text = message, color = sender_color},
        },
    })
end

-- Trace mode: when on, every 0x017 packet (regardless of mode) is
-- logged to a file under the addon's data/ folder. Useful for
-- empirical mode → channel mapping: turn on, do a normal chat session,
-- review the log to see what modes correspond to what channels.
--
-- The log file is chat_packet_log.txt; entries are append-only with
-- timestamp + mode + sender + msg + hex. One line per packet. Toggle
-- with //ow chatpkttrace or set M.trace = true from Lua console.
M.trace = false

-- Cached log file handle (opened lazily). Closed on addon unload via
-- the loader's reset/unload path if available; otherwise FFXI will
-- flush it on session end.
local _trace_log_file = nil
local _trace_log_path = nil

-- Build the trace log path. windower.addon_path is something like
-- 'C:/.../addons/OmniWatch/', so we put the file under data/.
local function _resolve_trace_path()
    if _trace_log_path then return _trace_log_path end
    local base = windower.addon_path or ''
    if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
        base = base .. '/'
    end
    _trace_log_path = base .. 'data/chat_packet_log.txt'
    return _trace_log_path
end

-- Append one line to the trace log. Opens the file lazily; reuses the
-- handle across calls so we're not paying the open cost per packet.
local function _trace_log_line(line)
    if not _trace_log_file then
        local path = _resolve_trace_path()
        local f, err = io.open(path, 'a')
        if not f then
            -- Disable trace on open failure; print to chat so user
            -- knows. data/ may not exist; user should create it.
            M.trace = false
            windower.add_to_chat(123,
                '[OW chat_pkt] trace open failed (' .. tostring(err)
                .. '). Trace disabled. Make sure data/ folder exists.')
            return
        end
        _trace_log_file = f
        -- Header on first write of a session for easy boundary spotting.
        local now = os.date('*t')
        f:write(string.format(
            '\n=== chat_packet trace started %04d-%02d-%02d %02d:%02d:%02d ===\n',
            now.year, now.month, now.day, now.hour, now.min, now.sec))
    end
    _trace_log_file:write(line)
    _trace_log_file:write('\n')
    _trace_log_file:flush()   -- flush so kills/crashes don't lose data
end

-- Called from OmniWatch.lua's 'incoming chunk' event handler.
-- Returns silently for non-0x017 ids or unaccepted modes.
function M.process(id, data)
    if not _ring or not _ring.text_ring then return end

    -- ── 0x0CC: Linkshell Message (/lsmes, /ls2mes) ─────────────────
    -- LS message-of-the-day arrives via this packet, NOT via incoming
    -- text. Trace mode dumps the full hex so we can decode the
    -- structure empirically; the actual parsing + LS1/LS2 routing is
    -- handled separately (see _handle_lsmes_packet below).
    if id == 0x0CC then
        if M.trace then
            local now = os.date('*t')
            local timestamp = string.format(
                '%02d:%02d:%02d', now.hour, now.min, now.sec)
            local hex = {}
            local lim = math.min(#data, 200)   -- LS msgs can be long
            for i = 1, lim do
                hex[i] = string.format('%02X', data:byte(i))
            end
            -- Printable form so we can spot text bytes
            local printable_chars = {}
            for i = 1, lim do
                local b = data:byte(i)
                if b >= 0x20 and b < 0x7F then
                    printable_chars[i] = string.char(b)
                else
                    printable_chars[i] = '.'
                end
            end
            _trace_log_line(string.format(
                '[%s] [LSMES] 0x0CC len=%d', timestamp, #data))
            _trace_log_line('       hex: ' .. table.concat(hex, ' '))
            _trace_log_line('       txt: ' .. table.concat(printable_chars))
        end
        _handle_lsmes_packet(data)
        return
    end

    if id ~= 0x017 then return end

    -- Parse the packet by reading bytes directly. The packet layout
    -- (offsets refer to the data string, which includes the 4-byte
    -- chunk header at 0-3):
    --   0x04 : Mode (unsigned char)
    --   0x05 : GM flag (bool)
    --   0x06-0x07 : zone/padding (unsigned short)
    --   0x08-0x16 : Sender Name (15 bytes, char[0xF], null-padded)
    --   0x17+ : Message (null-terminated, max 150 chars)
    --
    -- Sender width verified empirically: with the message field at
    -- byte 25 (offset 0x18, the wiki value) the first character of
    -- the message was being dropped (typed "TEST CHAT", read
    -- "EST CHAT"). Shifting to byte 24 (offset 0x17) — matching
    -- fields.lua's char[0xF]=15 — captures the full message.
    --
    -- IMPORTANT: Packet memory is NOT zeroed. The space inside the
    -- sender field beyond the actual name length can contain LEFTOVER
    -- garbage from previous packets. The NUL-stop in the sender
    -- reader handles this correctly — we stop at the first NUL.
    --
    -- Note: Windower's pack library uses 1-based indexing for byte
    -- positions; data:byte(N) is the Nth byte (1-indexed). So packet
    -- offset 0x04 is data:byte(5), offset 0x08 is data:byte(9),
    -- offset 0x17 is data:byte(24).

    if #data < 0x17 then return end   -- truncated

    local mode = data:byte(5)         -- offset 0x04
    if not mode then return end

    -- Sender name: 15 bytes starting at offset 0x08 (data:byte(9)).
    -- Stop at first NUL.
    local sender_name = ''
    for i = 9, 23 do   -- offsets 0x08 through 0x16
        local b = data:byte(i)
        if not b or b == 0 then break end
        sender_name = sender_name .. string.char(b)
    end

    -- Message: from offset 0x17 (data:byte(24)), null-terminated.
    local message_raw = ''
    for i = 24, #data do
        local b = data:byte(i)
        if not b or b == 0 then break end
        message_raw = message_raw .. string.char(b)
    end

    -- ── Trace mode (file log + chat echo) ──────────────────────────
    -- When M.trace is true, log EVERY 0x017 packet regardless of
    -- mode. Used for empirical mode → channel mapping. Writes to
    -- data/chat_packet_log.txt and echoes a compact one-liner to
    -- FFXI chat. This bypasses ACCEPTED_MODES so we see modes we
    -- don't yet recognize (NPC dialog, system messages, etc.).
    if M.trace then
        -- Build a printable representation of message: strip markers
        -- so the log isn't full of \xFD..\xFD binary, and replace
        -- non-ASCII with ? (we'll add SJIS conversion later).
        local msg_print = _strip_markers(message_raw)
        local now = os.date('*t')
        local timestamp = string.format(
            '%02d:%02d:%02d', now.hour, now.min, now.sec)

        -- Hex dump (up to 64 bytes) so we can sanity-check parsing
        -- if a mode looks wrong. Compact form, no spaces, for log.
        local hex_parts = {}
        local lim = math.min(#data, 64)
        for i = 1, lim do
            hex_parts[i] = string.format('%02X', data:byte(i))
        end
        local hex_str = table.concat(hex_parts, ' ')

        _trace_log_line(string.format(
            '[%s] [PKT] pkt_mode=%d data_len=%d sender=[%s] msg=[%s]',
            timestamp, mode, #data, sender_name, msg_print))
        _trace_log_line('       hex: ' .. hex_str)
    end

    -- Diagnostic: trace every 0x017 BEFORE mode filtering. Toggle on
    -- with //ow chatpktdebug to see what's actually arriving.
    if M.debug then
        windower.add_to_chat(207, string.format(
            '[OW chat_pkt] mode=%d sender=[%s] msg=[%s]',
            mode, sender_name, message_raw:sub(1, 60)))
    end

    if not ACCEPTED_MODES[mode] then return end

    -- sender_name is already trimmed above (byte-by-byte read stops at
    -- NUL). message gets marker-stripping for color escapes and
    -- autotranslate brackets.
    local message = _strip_markers(message_raw or '')

    local actor_class = _classify_sender(sender_name)

    -- Channel for routing (matches Python's _chat_classify_event
    -- channel names for real chat).
    --
    -- Mode mapping (EMPIRICAL on Asura, may differ from Windower wiki):
    --   3 = tell received (confirmed via hex dump testing)
    --   5 = linkshell 1 (confirmed via testing)
    --   26 = yell (confirmed via testing)
    --   Others TBD via further empirical testing.
    local channel
    local sender_color   -- segment color class for the sender name
    if     mode == 0               then channel = 'chat_say';   sender_color = 'ch_say'
    elseif mode == 1               then channel = 'chat_shout'; sender_color = 'ch_shout'
    elseif mode == 3               then channel = 'chat_tell';  sender_color = 'ch_tell'
    elseif mode == 4               then channel = 'chat_party'; sender_color = 'ch_party'
    elseif mode == 5               then channel = 'chat_ls1';   sender_color = 'ch_ls1'
    elseif mode == 7               then channel = 'chat_emote'; sender_color = 'ch_emote'
    elseif mode == 26              then channel = 'chat_yell';  sender_color = 'ch_yell'
    elseif mode == 27              then channel = 'chat_ls2';   sender_color = 'ch_ls2'
    else                                channel = 'chat_other'; sender_color = 'ch_other'
    end

    -- Build colored segments. Format varies by mode:
    --   say:    "Wormfood : Hello"
    --   shout:  "Wormfood : SHOUT"
    --   yell:   "Wormfood : YELL"
    --   tell:   ">>Wormfood : whisper"   (received)
    --   party:  "(Wormfood) party msg"
    --   ls1:    "<Wormfood> ls chat"      (no LS name in packet)
    --   emote:  whole message as-is (FFXI builds the verb)
    --
    -- Sender name is colored per CHANNEL (sender_color above) rather
    -- than per actor_class. World, Party, LS1, LS2 etc each get their
    -- own theme color so it's easy to tell which channel a line came
    -- from when looking at a mixed tab.
    local segments
    if mode == 3 then
        -- Tell received (empirical: mode 3 on Asura)
        segments = {
            {text = '>>',             color = 'default'},
            {text = sender_name,      color = sender_color},
            {text = ' : ',            color = 'default'},
            {text = message,          color = 'default'},
        }
    elseif mode == 4 then
        -- Party (assumed)
        segments = {
            {text = '(',              color = 'default'},
            {text = sender_name,      color = sender_color},
            {text = ') ',             color = 'default'},
            {text = message,          color = 'default'},
        }
    elseif mode == 5 or mode == 27 then
        -- Linkshell 1 / 2 — bracketed sender, "[1]<name>" feel.
        local prefix = (mode == 5) and '[1]<' or '[2]<'
        segments = {
            {text = prefix,           color = 'default'},
            {text = sender_name,      color = sender_color},
            {text = '> ',             color = 'default'},
            {text = message,          color = 'default'},
        }
    elseif mode == 7 then
        -- Emote (assumed) — message text already includes the verb
        segments = {
            {text = sender_name,      color = sender_color},
            {text = ' ',              color = 'default'},
            {text = message,          color = 'default'},
        }
    else
        -- say / shout / yell / fallthrough
        segments = {
            {text = sender_name,      color = sender_color},
            {text = ' : ',            color = 'default'},
            {text = message,          color = 'default'},
        }
    end

    -- Flat text for rendering fallback if segments path fails.
    local flat_parts = {}
    for i = 1, #segments do flat_parts[i] = segments[i].text end
    local flat = table.concat(flat_parts)

    -- Translate the 0x017 packet mode to the FFXI "incoming text"
    -- mode that Python's _chat_classify_event understands. The two
    -- numbering systems differ; without this translation, tabs land
    -- wrong (e.g. tells go to the shout/World tab).
    --
    -- Packet mode → incoming-text mode mapping:
    --   0  (say)        → 1
    --   1  (shout)      → 3
    --   3  (tell)       → 4
    --   4  (party)      → 5
    --   5  (linkshell1) → 6
    --   7  (emote)      → 9
    --   26 (yell)       → 11
    --   27 (linkshell2) → 7
    local TEXT_MODE_FROM_PACKET = {
        [0]  = 1,
        [1]  = 3,
        [3]  = 4,
        [4]  = 5,
        [5]  = 6,
        [7]  = 9,
        [26] = 11,
        [27] = 7,
    }
    local text_mode = TEXT_MODE_FROM_PACKET[mode] or mode

    _ring.text_ring.push({
        ts           = os.time(),
        source       = 'chat',     -- regular chat, not synth combat
        mode         = text_mode,  -- translated to FFXI incoming-text mode
        kind         = channel,    -- routing channel hint
        actor_id     = 0,          -- 0x017 doesn't carry sender_id
        actor_name   = sender_name,
        actor_class  = actor_class,
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = flat,
        segments     = segments,
    })

    if M.debug then
        windower.add_to_chat(207, string.format(
            '[OW chat_pkt EMIT] pkt=%d txt=%d %s [%s] -> %s',
            mode, text_mode, sender_name, actor_class,
            channel))
    end
end

-- Toggle for the diagnostic echo above.
M.debug = false

return M