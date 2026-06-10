-- Chat event emitter — builds event records and pushes them to the
-- appropriate ring.
--
-- An event is a plain table with these fields:
--   ts            number  -- unix seconds (float, ~ms precision)
--   source        string  -- 'chat' | 'outgoing' | 'system' | 'battle' | 'echo'
--   mode          number  -- FFXI chat mode byte (0..255), or synthetic
--                            for 'battle' events. Python uses this to
--                            assign tab and color.
--   actor_id      number  -- mob id of the sender/actor, 0 if unknown
--   actor_name    string  -- display name (may be '' if unresolved)
--   actor_class   string  -- from classifier: self/party/alliance/mob/etc.
--   target_id     number  -- mob id of target (for tells, battle), 0 if none
--   target_name   string  -- ''
--   target_class  string  -- '' if no target
--   text          string  -- raw line text
--   segments      table   -- list of {text=str, color=str} tokens for
--                            word-level coloring. Empty for raw
--                            incoming-text events; populated by
--                            buff_events.lua and battle_events.lua.
--
-- emit_chat(): incoming chat-mode lines (say, party, tell, LS, system).
--   NOTE: real chat modes (say/tell/yell/shout/party/LS) are currently
--   dropped here in favor of an upcoming 0x017 packet handler. See
--   DROPPED_CHAT_MODES below.
--
-- Each emit:
--   1. Builds the event record
--   2. Pushes to text_ring
--   3. Optionally echoes to chat if _ow_chat_debug is on
--
-- emit functions are deliberately tiny — heavy lifting (classification,
-- name resolution) is delegated. This keeps the hot path (hundreds of
-- calls per second under heavy battle load) cheap.

local M = {}

-- Set by _loader at module init. Avoids requiring ring + classifier
-- from inside this file (Lua's loadfile pattern doesn't compose well
-- with relative requires; the loader passes deps in instead).
local _ring        = nil  -- chat/ring.lua module table
local _classifier  = nil  -- chat/classifier.lua module table

function M.set_deps(ring_mod, classifier_mod)
    _ring       = ring_mod
    _classifier = classifier_mod
end

-- Diagnostic toggle. When true, every emit also prints to the FFXI
-- chat log so we can verify events are landing without needing the
-- Python side to be running.
M.debug = false

-- Hex capture mode. When true, emit_chat prints a hex dump of the
-- raw (pre-strip) text to the FFXI chat log for any line that
-- contains non-ASCII bytes. Use to diagnose what bytes Windower's
-- 'incoming text' is handing us — especially for Japanese chat and
-- autotranslate phrases where the strip might be the wrong call.
--
-- Toggle via the //ow chathex command (Lua-side handler in
-- OmniWatch.lua). When on, you'll see lines like:
--   [hex mode=1] 4d 6f 62 6c 69 6e a0 ...
-- alongside the normal chat. Turn off when done diagnosing.
M.hex_capture = false

-- Unified trace mode. When on, every emit_chat call logs the line
-- (with mode + hex + printable text) to data/chat_packet_log.txt.
-- Shares the file with chat_packets.lua's trace so a single session
-- captures BOTH packet-sourced (0x017) and text-sourced (incoming
-- text) chat events with [TXT] / [PKT] source tags. Used to nail
-- down every chat surface in one go.
M.trace = false

-- Cached log file handle (opened lazily, reused across calls).
local _emit_trace_log_file = nil

-- Append one line to the shared trace log. Path is built relative
-- to windower.addon_path. Opens file lazily on first write; reuses
-- handle to avoid per-call open overhead.
local function _emit_trace_line(line)
    if not _emit_trace_log_file then
        -- Unified chatdebug log: %APPDATA%/OmniWatch/chatdebug_log.txt
        -- (same file as the other probes). Falls back to the addon data
        -- dir if APPDATA isn't set.
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
        local f, err = io.open(path, 'a')
        if not f then
            M.trace = false
            windower.add_to_chat(123,
                '[OW emit] trace open failed (' .. tostring(err)
                .. '). Trace disabled.')
            return
        end
        _emit_trace_log_file = f
        local now = os.date('*t')
        f:write(string.format(
            '\n=== emit (incoming text) trace started %04d-%02d-%02d %02d:%02d:%02d ===\n',
            now.year, now.month, now.day, now.hour, now.min, now.sec))
    end
    _emit_trace_log_file:write(line)
    _emit_trace_log_file:write('\n')
    _emit_trace_log_file:flush()
end

-- Pre-encoding strip: remove FFXI byte-level markers that exist
-- BEFORE we know the encoding (UTF-8 vs SJIS). The key markers we
-- need to nuke first are:
--
--   \x7F\xFC   sender-name wrapper opener
--   \x7F\xFB   sender-name wrapper closer
--   \x7F<digit>   end-of-message marker
--
-- These are FFXI-internal control sequences inserted by the game,
-- not part of the message text proper. They DON'T survive an
-- encoding round-trip cleanly:
--   * UTF-8 interpretation: \x7F is a valid 1-byte char (DEL), but
--     \xFC and \xFB by themselves are invalid UTF-8 leads — they'd
--     get walked into spaces by the strip's UTF-8 walker.
--   * SJIS interpretation: \xFC is a valid SJIS first-byte, so
--     windower.from_shift_jis pairs it with the NEXT byte (the
--     first letter of the player name) and produces a wrong kanji
--     character. e.g. "FC 41" ("FC" + "A") decodes as 魵.
--
-- We strip these markers first, then normalize the rest of the bytes
-- to UTF-8 (or leave them if they already are). Result: the encoding
-- normalizer never sees the FC/FB bytes, so it can't be confused by
-- them.
local function _pre_strip_byte_markers(text)
    if not text or text == '' then return text end
    -- Leading format-prefix byte. Some high-mode broadcasts begin with
    -- a single byte in 0x80-0xFF that is NOT part of the message text
    -- (observed: 0xA1 on Kupofried "ancient magic" / "Page N of the
    -- tome flares up!" lines, 0xD0 on "<Name> examines you."). It
    -- renders as a stray leading glyph. Strip it ONLY when the next
    -- byte is printable ASCII — that signature distinguishes a format
    -- prefix on an ASCII line from the lead byte of a real multibyte
    -- Shift-JIS character (which is followed by another high byte, not
    -- ASCII), so legitimate Japanese text is left intact.
    local b1 = text:byte(1)
    if b1 and b1 >= 0x80 then
        local b2 = text:byte(2)
        -- Strip when the next byte is printable ASCII (0x20-0x7E) OR the
        -- 0x7F marker byte that opens FFXI's name-wrapper (e.g. examine
        -- lines are "D0 7F FC <name> ..."). A genuine multibyte
        -- Shift-JIS char has a high (>=0x80) second byte, so this never
        -- eats real Japanese text.
        if b2 and ((b2 >= 0x20 and b2 <= 0x7E) or b2 == 0x7F) then
            text = text:sub(2)
        end
    end
    -- Order matters. Strip \x7F<digit> end-marker first (two-byte
    -- sequence) before the bare \x7F gets caught by the FC/FB pair
    -- strip below. The digit would otherwise be left orphan.
    text = text:gsub('\127%d', '')
    text = text:gsub('\127\252', '')      -- \x7F\xFC opener
    text = text:gsub('\127\251', '')      -- \x7F\xFB closer
    -- Some FFXI broadcasts (COR roll party-effect messages, group
    -- buff lines listing affected players) use BARE \xFC / \xFB
    -- without the \x7F prefix as name-token wrappers. Without these
    -- gsubs, the bare bytes survive into _normalize_to_utf8, which
    -- pairs them with the next ASCII byte via from_shift_jis and
    -- produces a wrong kanji that visually replaces the first
    -- letter of the player name. Observed in roll broadcasts where
    -- "Koru-Moru" rendered as "京oru-Moru", "Ilmia" as "弒lmia", etc.
    text = text:gsub('\252', '')          -- bare \xFC
    text = text:gsub('\251', '')          -- bare \xFB
    -- Stray \x8D marker before ASCII. Observed on the job-change
    -- Moogle's emote: "Moogle : \x8DChaaange...job!". The lone \x8D is
    -- an FFXI format/emote marker, but \x8D is also a Shift-JIS lead
    -- byte, so from_shift_jis pairs it with the following 'C' (0x43)
    -- and decodes the pair to the kanji 垢 — eating the C and rendering
    -- "垢haaange". Strip \x8D only when the next byte is printable ASCII
    -- (0x20-0x7E); a genuine \x8D-led Shift-JIS character has a trail
    -- byte that forms a real kanji in Japanese text, so this leaves
    -- legitimate SJIS intact.
    text = text:gsub('\141([\32-\126])', '%1')
    return text
end

-- Check if `s` is a well-formed UTF-8 byte sequence. We use this as
-- a gate before deciding whether to convert from Shift-JIS — Windower
-- claims to give us UTF-8 in `incoming text`, but observed behavior
-- on at least some installs shows Shift-JIS bytes. By validating first
-- we handle both cases without corrupting either: leave UTF-8 alone,
-- convert SJIS to UTF-8.
--
-- A byte sequence is valid UTF-8 if every byte fits the UTF-8 grammar:
--   0x00-0x7F: 1-byte (ASCII)
--   0xC2-0xDF: 2-byte lead, followed by 1 continuation (0x80-0xBF)
--   0xE0-0xEF: 3-byte lead, followed by 2 continuations
--   0xF0-0xF4: 4-byte lead, followed by 3 continuations
-- We also reject overlongs (sequences that encode a smaller-than-
-- required codepoint), since those frequently arise from SJIS-as-UTF-8
-- misreads producing valid-looking but wrong sequences.
--
-- Returns true if the entire string parses as UTF-8 with no errors.
local function _is_valid_utf8(s)
    if not s or s == '' then return true end
    local i = 1
    local n = #s
    while i <= n do
        local b1 = s:byte(i)
        if b1 < 0x80 then
            i = i + 1
        elseif b1 < 0xC2 then
            -- orphan continuation or overlong lead
            return false
        elseif b1 < 0xE0 then
            local b2 = i + 1 <= n and s:byte(i + 1) or 0
            if b2 < 0x80 or b2 > 0xBF then return false end
            i = i + 2
        elseif b1 < 0xF0 then
            local b2 = i + 1 <= n and s:byte(i + 1) or 0
            local b3 = i + 2 <= n and s:byte(i + 2) or 0
            if b2 < 0x80 or b2 > 0xBF then return false end
            if b3 < 0x80 or b3 > 0xBF then return false end
            i = i + 3
        elseif b1 < 0xF5 then
            local b2 = i + 1 <= n and s:byte(i + 1) or 0
            local b3 = i + 2 <= n and s:byte(i + 2) or 0
            local b4 = i + 3 <= n and s:byte(i + 3) or 0
            if b2 < 0x80 or b2 > 0xBF then return false end
            if b3 < 0x80 or b3 > 0xBF then return false end
            if b4 < 0x80 or b4 > 0xBF then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

-- Normalize a text string to UTF-8. The Windower wiki claims that the
-- incoming text event hands us UTF-8 already, but at least some
-- installs (and possibly the JP client of FFXI even in non-JP locales)
-- hand us Shift-JIS instead. We check the bytes for UTF-8 validity
-- first; if they look like valid UTF-8 we trust them and pass through.
-- If they fail UTF-8 validation, we fall back to windower.from_shift_jis
-- if available, converting the bytes to UTF-8 before downstream
-- processing. Either way the bytes that reach the strip / ring /
-- Python overlay are UTF-8.
local function _normalize_to_utf8(text)
    if not text or text == '' then return text end
    if _is_valid_utf8(text) then return text end
    if windower and windower.from_shift_jis then
        local ok, converted = pcall(windower.from_shift_jis, text)
        if ok and converted and converted ~= '' then
            return converted
        end
    end
    -- Last resort: leave as-is. Strip will replace invalid bytes with
    -- spaces and we'll lose the non-ASCII content, but at least the
    -- pipe doesn't break.
    return text
end

-- FFXI in-band formatting markers, mixed with valid UTF-8 text.
--
-- Windower's 'incoming text' event hands us a Lua string (= byte sequence)
-- that's a mix of:
--   * ASCII characters (0x00-0x7F)
--   * Valid UTF-8 multi-byte sequences (Japanese kana/kanji, accented
--     names like "Pénombre", emoji-like characters)
--   * FFXI's in-band marker bytes (0x80-0xFF) used as token separators,
--     name wrappers, etc. — these are NOT valid UTF-8 in context.
--   * Control bytes (0x01-0x1F, 0x7F) used as system message terminators.
--
-- Patterns observed empirically (live combat capture, May 2026):
--   \x7F<digit>      end-of-system-message marker ("Progress: 200.\x7f1")
--   \x7F             prefix/wrapper on outgoing tells, gain messages
--   bytes 0x80-0xFF  FFXI's name-token separators and metadata bytes
--                    (render as space/arrow in-game)
--   {Mob Name        autotranslate open before name token
--   }                autotranslate close
--   =Fire =III       `=` prefix on each spell/ability name fragment
--   $Honor $March    `$` prefix on song/spell names (similar to =)
--
-- The key insight: FFXI's high-bit markers and valid UTF-8 both use
-- bytes 0x80-0xFF, so we can't strip by byte range. We must validate
-- UTF-8 sequence-by-sequence and keep only the valid ones.
--
-- UTF-8 byte structure:
--   0x00-0x7F   1-byte: ASCII (lead byte = full character)
--   0xC2-0xDF   2-byte lead: needs 1 continuation byte (0x80-0xBF)
--   0xE0-0xEF   3-byte lead: needs 2 continuation bytes
--   0xF0-0xF4   4-byte lead: needs 3 continuation bytes
--   0x80-0xBF   continuation byte (only valid AFTER a lead)
--   0xC0-0xC1   never valid (would encode an overlong sequence)
--   0xF5-0xFF   never valid (above max Unicode codepoint)
--
-- Stripping order:
--   1. \x7F + digit FIRST (two-byte sequence). After step 2 strips
--      the \x7F, the digit would be left orphan, mangling text like
--      "Progress: 190/200." -> "Progress: 190/200.1".
--   2. Single control bytes (0x01-0x1F, 0x7F) → delete entirely.
--   3. UTF-8-aware walk: keep valid multi-byte sequences intact,
--      replace orphan/invalid high-bit bytes with a space (FFXI uses
--      them as separators; deleting glues tokens together).
--   4. Brace and equals/dollar markers (post-UTF-8 cleanup; safe to
--      apply against the now-clean string).
--   5. Collapse runs of whitespace and trim.
--
-- We also reject overlong encodings (e.g. \xC0\xA8 which technically
-- decodes but wastes bytes — these almost always indicate FFXI markers
-- that accidentally form a valid byte pair). Done by checking the
-- decoded codepoint against the minimum representable value for the
-- byte-length used.

local function _utf8_strip_invalid(text)
    -- Walk the byte sequence character by character. Build the output
    -- buffer in a table (string concat in Lua is O(n²); table.concat
    -- is O(n)).
    --
    -- For each position:
    --   * Lead byte → check continuation bytes match expected count
    --     and form a valid (non-overlong, in-range) codepoint.
    --     If yes: append the full multi-byte sequence verbatim.
    --     If no:  append a space, advance by 1.
    --   * Orphan continuation byte → append space, advance by 1.
    --   * Invalid lead (0xC0, 0xC1, 0xF5+) → append space, advance by 1.
    --   * ASCII → append verbatim.
    local out = {}
    local i = 1
    local n = #text
    while i <= n do
        local b1 = text:byte(i)
        if b1 < 0x80 then
            -- ASCII fast path.
            out[#out + 1] = text:sub(i, i)
            i = i + 1
        elseif b1 < 0xC2 then
            -- 0x80-0xBF (orphan continuation) or 0xC0-0xC1 (overlong
            -- lead, always invalid). Replace with space.
            out[#out + 1] = ' '
            i = i + 1
        elseif b1 < 0xE0 then
            -- 2-byte lead, expect 1 continuation in 0x80-0xBF.
            local b2 = i + 1 <= n and text:byte(i + 1) or 0
            if b2 >= 0x80 and b2 <= 0xBF then
                -- Decoded codepoint = ((b1 & 0x1F) << 6) | (b2 & 0x3F)
                local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
                if cp >= 0x80 then
                    -- Valid 2-byte sequence.
                    out[#out + 1] = text:sub(i, i + 1)
                    i = i + 2
                else
                    -- Overlong (encodes ASCII as 2 bytes). Strip.
                    out[#out + 1] = ' '
                    i = i + 1
                end
            else
                out[#out + 1] = ' '
                i = i + 1
            end
        elseif b1 < 0xF0 then
            -- 3-byte lead, expect 2 continuation bytes.
            local b2 = i + 1 <= n and text:byte(i + 1) or 0
            local b3 = i + 2 <= n and text:byte(i + 2) or 0
            if b2 >= 0x80 and b2 <= 0xBF
               and b3 >= 0x80 and b3 <= 0xBF then
                local cp = (b1 - 0xE0) * 4096
                         + (b2 - 0x80) * 64
                         + (b3 - 0x80)
                -- Reject overlong (cp < 0x800) and UTF-16 surrogates
                -- (0xD800-0xDFFF, not valid as standalone codepoints).
                if cp >= 0x800 and not (cp >= 0xD800 and cp <= 0xDFFF) then
                    out[#out + 1] = text:sub(i, i + 2)
                    i = i + 3
                else
                    out[#out + 1] = ' '
                    i = i + 1
                end
            else
                out[#out + 1] = ' '
                i = i + 1
            end
        elseif b1 < 0xF5 then
            -- 4-byte lead (rare — emoji-plane characters). Expect 3
            -- continuation bytes.
            local b2 = i + 1 <= n and text:byte(i + 1) or 0
            local b3 = i + 2 <= n and text:byte(i + 2) or 0
            local b4 = i + 3 <= n and text:byte(i + 3) or 0
            if b2 >= 0x80 and b2 <= 0xBF
               and b3 >= 0x80 and b3 <= 0xBF
               and b4 >= 0x80 and b4 <= 0xBF then
                local cp = (b1 - 0xF0) * 262144
                         + (b2 - 0x80) * 4096
                         + (b3 - 0x80) * 64
                         + (b4 - 0x80)
                if cp >= 0x10000 and cp <= 0x10FFFF then
                    out[#out + 1] = text:sub(i, i + 3)
                    i = i + 4
                else
                    out[#out + 1] = ' '
                    i = i + 1
                end
            else
                out[#out + 1] = ' '
                i = i + 1
            end
        else
            -- 0xF5-0xFF, never valid in UTF-8.
            out[#out + 1] = ' '
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Resolve FD-format autotranslate sequences to their English phrase
-- text via Windower's res.auto_translates lookup. Returns the input
-- text with all 6-byte AT phrases replaced by "{Phrase Name}".
-- Unresolvable IDs render as "{AT}".
--
-- Format per Windower forums "Outputting an Autotranslate Message":
--   byte 1: 0xFD     start marker
--   byte 2: type / category
--   byte 3: language
--   bytes 4-5: phrase ID, big-endian
--   byte 6: 0xFD     end marker
--
-- We do this with a manual byte walk rather than gsub because the
-- inner bytes can be any value 0x00-0xFF, which is awkward to express
-- in Lua patterns. Walking explicitly is robust against any input.
--
-- Mirrors chat_packets.lua's _resolve_all_at_phrases logic; kept
-- separate here to avoid a hard dependency from emit.lua on the
-- chat_packets module (the modules can be loaded independently).
local _at_res = nil
local _at_res_load_attempted = false
local function _load_at_resources()
    if _at_res_load_attempted then return _at_res end
    _at_res_load_attempted = true
    local ok, r = pcall(require, 'resources')
    if ok and r and r.auto_translates then
        _at_res = r
    end
    return _at_res
end

local function _resolve_fd_autotranslate(s)
    if not s or s == '' then return s end
    -- Fast path: no \xFD bytes means no AT phrases to resolve.
    if not s:find('\253', 1, true) then return s end

    local r = _load_at_resources()
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = s:byte(i)
        if b == 0xFD and i + 5 <= n and s:byte(i + 5) == 0xFD then
            -- Found a 6-byte AT sequence. Resolve via res lookup.
            local b4 = s:byte(i + 3)
            local b5 = s:byte(i + 4)
            local id = b4 * 256 + b5
            local resolved = nil
            if r then
                local entry = r.auto_translates[id]
                if entry and entry.en then
                    resolved = '{' .. entry.en .. '}'
                else
                    -- Try alternate id ordering as a defensive
                    -- fallback (some categories may use bytes 2-3).
                    local b2 = s:byte(i + 1)
                    local b3 = s:byte(i + 2)
                    local alt = r.auto_translates[b2 * 256 + b3]
                    if alt and alt.en then
                        resolved = '{' .. alt.en .. '}'
                    end
                end
            end
            out[#out + 1] = resolved or '{AT}'
            i = i + 6
        else
            out[#out + 1] = string.char(b)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Done once per emit, before ring push. Clean text flows through
-- history, drain, UDP, Python -- all downstream consumers see the
-- same already-clean string.
--
-- Assumes input is UTF-8 (or ASCII). Pre-strip byte markers
-- (\x7F\xFC, \x7F\xFB, \x7F+digit) must already have been removed
-- before encoding normalization by _pre_strip_byte_markers, since
-- those byte sequences would interfere with the SJIS-detection
-- step in _normalize_to_utf8.
local function _strip_ffxi_markers(text, mode)
    if not text or text == '' then return text end
    -- (Pre-strip byte markers — \x7F+digit, \x7F\xFC, \x7F\xFB —
    -- handled earlier in the pipeline via _pre_strip_byte_markers.
    -- We don't duplicate that work here. If this function is called
    -- on text that still contains those markers, they'll be cleaned
    -- up below by the UTF-8 walker's invalid-byte handling, just
    -- less precisely.)
    -- 1b. Autotranslate phrase wrappers.
    --
    -- Different byte pairs are used for opener vs closer:
    --   \xEF\x27   →  '{' (opener)
    --   \xEF\x28   →  '}' (closer)
    --
    -- We map them directly rather than using a toggle, because some
    -- chat content may legitimately contain only an opener or only a
    -- closer (FFXI's auto-translate phrase types vary, and the byte
    -- pair is category-specific). Treating opener and closer
    -- positions explicitly avoids miscounting if one slips through.
    --
    -- Both bytes are in the printable-ASCII range as their second byte
    -- (\x27 is `'`, \x28 is `(`). When my UTF-8 walker sees \xEF
    -- followed by a non-continuation byte (< 0x80), it treats \xEF as
    -- an invalid lead and would otherwise replace it with a space,
    -- leaving the lone `'` or `(` rendering as ASCII. Doing the strip
    -- here BEFORE the UTF-8 walker preserves the autotranslate
    -- semantics.
    --
    -- We may also see \xEF followed by other bytes for other phrase
    -- categories (greetings vs job abilities, etc.). If you spot a
    -- pattern that still leaks through, add it to the list below.
    --
    -- Lua-pattern escaping note: \x28 is the literal `(` byte which
    -- has SPECIAL meaning in Lua patterns (start of capture group).
    -- We escape it as %( to match the literal byte. \x27 has no
    -- special meaning so no escaping needed.
    text = text:gsub('\239\039', '{')   -- \xEF\x27 → {
    text = text:gsub('\239%(',   '}')   -- \xEF\x28 → } (escaped)

    -- 1c. FD-format autotranslate phrases. These are 6-byte sequences:
    --   \xFD <type> <lang> <id_hi> <id_lo> \xFD
    -- The phrase ID maps to res.auto_translates[id].en — same lookup
    -- chat_packets.lua does for inbound 0x017 chat. The difference:
    -- chat_packets handles INBOUND server chat (other players' /say to
    -- you), and resolves AT phrases correctly there. emit.lua handles
    -- incoming-text-event chat (your own outgoing /say echoes back to
    -- you via this path), which previously had no AT resolution — the
    -- FD bytes hit the UTF-8 walker below (step 3) which rejected them
    -- as invalid bytes and replaced each with a space. Result: your
    -- own autotranslate phrases were destroyed (the user saw "[X]"
    -- artifacts or empty space where {Hello!} should have appeared).
    --
    -- Must run BEFORE step 3 (UTF-8 walker) — once that step runs,
    -- the FD bytes are gone.
    text = _resolve_fd_autotranslate(text)
    -- 2. Stray control bytes 0x01-0x1F and 0x7F (DEL). Done AFTER
    --    the 7F-pair strip above so we don't disturb the FC/FB
    --    matching (this delete-pass would otherwise eat the lone
    --    \x7F and leave the FC/FB orphaned).
    text = text:gsub('[\1-\31\127]', '')
    -- 3. UTF-8-aware: preserve valid sequences (kana, kanji, accented
    --    Latin names), replace FFXI marker bytes / invalid sequences
    --    with a space.
    text = _utf8_strip_invalid(text)
    -- 4. Capital-letter prefixes from FFXI's spell/ability/song token
    --    rendering. Note: literal `{` and `}` are NOT stripped here
    --    anymore (used to be), because step 1b converts the
    --    autotranslate \xEF\x27 wrappers INTO { ... } braces. Now any
    --    `{`/`}` in the text is meaningful autotranslate punctuation
    --    we want to keep.
    text = text:gsub('=(%u)', '%1')
    text = text:gsub('%$(%u)', '%1')
    -- 4a. FFXI mode-prefix letters. Some chat modes prefix the message
    --     with a single lowercase letter that the native FFXI client
    --     hides during rendering, but we receive verbatim. Observed:
    --       mode 121: "yYou find a spool..." → leading y is the prefix
    --       gearswap notices: "zOmniWatch Notice: ..." → leading z
    --     We strip ONLY when the prefix is one of a known set
    --     {y, z, w} AND the next char is uppercase (which forms the
    --     real word). Doesn't touch legitimate text like "iPad" or
    --     "yesterday" — first letter must be in the set, second char
    --     must be uppercase, and only the very first character is
    --     considered.
    text = text:gsub('^([yzw])(%u)', '%2')
    -- 4b. FFXI leading-brace prefix on certain SYSTEM modes. Modes like
    --     123 ("{There are no party members.") prepend a literal '{'
    --     (0x7B) byte that the native client hides during rendering but
    --     we receive verbatim. We strip a leading '{' or '}' followed by
    --     an uppercase letter ONLY on these known system modes — never on
    --     real chat, where '{' is meaningful auto-translate punctuation
    --     (e.g. a "{Hello!}" greeting would start the same way).
    local BRACE_PREFIX_MODES = {[121]=true, [122]=true, [123]=true, [124]=true}
    if mode and BRACE_PREFIX_MODES[mode] then
        text = text:gsub('^([{}])(%u)', '%2')
    end
    -- 5. Collapse runs of whitespace from the strips, trim ends.
    text = text:gsub('%s+', ' ')
    text = text:gsub('^%s*(.-)%s*$', '%1')
    return text
end

-- emit_chat: an incoming chat-mode line from windower's 'incoming text'
-- event. Classifies the sender if we can resolve it from name; otherwise
-- 'other' with the name carried through verbatim.
--
-- Arguments:
--   mode         number  -- FFXI mode code (1=say, 2=shout, 4=tell, etc.)
--   sender_name  string  -- name as it appears in the line (may be '')
--   text         string  -- cleaned line text (control bytes already stripped)
--
-- Note: 'incoming text' doesn't directly give us a sender mob_id — only
-- the name. We try get_mob_by_name to resolve, but this fails for
-- senders outside the local mob array (most tells, all LS chatter).
-- That's fine: actor_class falls back to 'other' and Python still has
-- the name to render.
--
-- Mode filter: we accept only modes corresponding to real in-game chat
-- channels and system messages. The 150+ range is reserved for addon-
-- injected output via windower.add_to_chat(N, ...) — including our own
-- debug echoes below. Capturing those would create a feedback loop
-- (we'd re-emit every line we print) AND pollute the chat panel with
-- GearSwap rule fires, other addon notifications, etc. Real chat modes
-- max out around 30-ish in FFXI, so a cutoff at 150 is safely above
-- anything legitimate while well below the addon range.
local MAX_REAL_CHAT_MODE = 150

-- Chat modes we INTENTIONALLY drop from emit_chat. These are the
-- "real chat" channels (say/tell/yell/shout/party/LS) where we
-- prefer packet-sourced events from a future 0x017 packet handler
-- over incoming-text capture. Until that handler ships, these modes
-- are dropped here — meaning the chat panel will be empty for them.
--
-- Modes NOT in this set still flow through normally:
--   * System messages (RoE, sparks, drops, etc.)
--   * Battle modes (28/29/30/etc.) — though Python's routing hides
--     those by default (they duplicate the colored packet synth)
--   * GearSwap / addon output (mode >= 150 caught by the next check)
--
-- To re-enable a mode here, remove it from this set.
local DROPPED_CHAT_MODES = {
    [1]  = true,    -- /say
    [2]  = true,    -- /say echo (outgoing)
    [3]  = true,    -- /shout
    [4]  = true,    -- /tell received
    [5]  = true,    -- /party
    [6]  = true,    -- /linkshell (mode 6)
    [7]  = true,    -- /linkshell (mode 7) - placeholder
    [8]  = true,    -- /linkshell 2 (placeholder)
    [9]  = true,    -- /emote
    [10] = true,    -- /shout (text-path duplicate). FFXI delivers
                    --   /shout TWICE on the wire: once via the 0x017
                    --   chat packet (handled by chat_packets.lua → chat
                    --   shout → World) and again via incoming-text on
                    --   mode 10 with no sender_name. The packet path is
                    --   canonical (structured fields, correct sender
                    --   color); the text duplicate was falling through
                    --   to System and showing the same shout twice.
                    --   Verified via chatdebug capture: Kwonsan and
                    --   Gabimaru /shout lines all on text-mode 10 while
                    --   their World copies came via the packet path.
    [11] = true,    -- /yell
    [12] = true,    -- /tell sent
    [13] = true,    -- /party (alt)
    [14] = true,    -- /party (alt) / LS1 BattleMod-formatted
    [15] = true,    -- battle message: melee/abilities ("X pokes Y",
                    --   "Scythe Tail → you"). Duplicates 0x028 synth
                    --   from battle_events.lua (classified + ally-gated);
                    --   leaked into System tab with \x7F prefix glyphs.
    [16] = true,    -- battle message (others' combat actions) — dup synth
    [17] = true,    -- battle message (party combat actions) — dup synth
    [18] = true,    -- battle message (alliance combat actions) — dup synth
    [19] = true,    -- battle message (misc combat) — dup synth
    [20] = true,    -- battle damage text (BattleMod fmt) — duplicates
                    --   synth from battle_events.lua via 0x028
    [25] = true,    -- offensive item/Mix damage ("Monberaux uses Mix:
                    --   Dark Potion.The Apex Raptor takes 666 points of
                    --   damage"). Chemist offensive-item text; dup of
                    --   0x028 synth, was leaking into System.
    [28] = true,    -- mob/actor ability action+damage ("X uses → Y for
                    --   N damage", "The X uses Ability.Y takes N...") —
                    --   dup of 0x028 synth; leaked into System garbled.
    [31] = true,    -- medicine / item-use + HP recovery ("Monberaux uses
                    --   Max. Potion.Wormfood recovers 500 HP", "X uses
                    --   Mix: Vaccine → Y for N"). Chemist/Alchemy ability
                    --   text. Duplicates 0x028 synth and was leaking into
                    --   System / mis-rendering cures as damage in Battle.
                    --   (Remove this entry to show cure/recovery text.)
    [90] = true,    -- plain item-use completion ("Wormfood uses a warp
                    --   ring.", "...uses a dimensional ring (Dem)."), i.e.
                    --   utility/teleport ring (and similar) item use with
                    --   no damage/recovery/buff. Dup of 0x028 synth
                    --   (battle_events "uses" kind); was leaking into the
                    --   System tab. (Remove this entry to show item-use
                    --   text.)
    [111] = true,   -- trust/player ability-use + buff-gain text
                    --   ("Monberaux uses Mix: Guard Drink.Monberaux gains
                    --   the effect of Protect", "...status parameters are
                    --   boosted"). Mix/medicine and similar ability
                    --   applications. Dup of 0x028 synth (which already
                    --   emits trust/party buff gains); was leaking the
                    --   whole Mix line into the System tab.
    [50] = true,    -- ability/song readies ("[Ulmia] Blade Madrigal →
                    --   Ulmia") — dup synth.
    [56] = true,    -- AoE buff target-list ("{6}: A, B, C ... is
                    --   affected") / mob TP-move self-damage ("Apex Jagil
                    --   uses → Apex Jagil for N damage") — dup synth.
    [57] = true,    -- AoE TP-move DAMAGE target-list ("Apex Bats uses →
                    --   {4}: Valaineral, Elletear... for 147 damage").
                    --   Mob AoE TP move hitting multiple targets; dup of
                    --   0x028 synth (ally-gated in battle_events). Was
                    --   leaking OTHER parties' fights into System.
    [63] = true,    -- AoE TP-move NO-DAMAGE target-list ("Apex Bats uses
                    --   → {2}: Raidenmei and Ifrit for no damage"). Dup
                    --   synth; other-party leak into System.
    [112] = true,   -- mob ability + debuff-on-target ("The Apex Bats uses
                    --   Sonic Boom.Valaineral receives the effect of
                    --   Attack Down"). Dup of 0x028 synth; other-party
                    --   leak into System.
    [114] = true,   -- AoE TP-move no-damage target-list variant ("Apex
                    --   Bats uses → {2}: Monberaux and Nekonoshippo for
                    --   no damage"). Dup synth; other-party leak.
    [26] = true,    -- /yell (zone-broadcast variant)
    [27] = true,    -- /linkshell 2 (LS2 actual)
    [36] = true,    -- defeat text — duplicates synth ("X defeats Y")
    [101] = true,   -- AoE ability target-list ("X uses → {6}: A, B, C")
                    --   — dup of 0x028 synth.
    [104] = true,   -- mob TP-move MISS ("The Apex Raptor uses Ripper
                    --   Fang, but misses Wormfood"). Counterpart to the
                    --   mode-28 hit; battle_events synthesizes the miss
                    --   (cat 11 → miss), so the text line is a dup that
                    --   was leaking into System.
    [110] = true,   -- mob readies ability ("[Apex Raptor] Scythe Tail →
                    --   Wormfood") — dup of 0x028 synth; this is the mob-
                    --   ability line that was showing in System garbled.
    [144] = true,   -- NPC dialog ("Yoskolo : Welcome to..."). Users
                    --   see this in FFXI's own chat already and it
                    --   doesn't need a separate panel slot. To route
                    --   somewhere visible, remove this entry.
}

function M.emit_chat(mode, sender_name, text)
    if not _ring then return end  -- module not fully initialized
    mode = mode or 0
    text = text or ''

    -- ── Unified trace mode (file log) ──────────────────────────────
    -- When M.trace is true, log EVERY incoming text event to a file
    -- under data/. Fires BEFORE most drop filters so we see what
    -- Windower actually passes us. Same file as chat_packets.lua's
    -- trace, with [TXT] source tag to distinguish from [PKT].
    -- See chat/chat_packets.lua _trace_log_line for file path.
    --
    -- We log high modes too (so dropped server announcements like the
    -- Ambuscade-tome / Kupofried / Besieged broadcasts show their mode
    -- number — otherwise they'd never appear here and we couldn't tell
    -- which mode to whitelist). We DO skip our OWN injected lines
    -- (prefixed "[OW") to avoid the feedback loop where the trace
    -- echoes a line, the echo re-enters via incoming text, and logs
    -- again.
    if M.trace and text:sub(1, 3) ~= '[OW' then
        local now = os.date('*t')
        local timestamp = string.format(
            '%02d:%02d:%02d', now.hour, now.min, now.sec)
        -- Hex dump (first 60 bytes) of the raw text - some lines
        -- contain SJIS / autotranslate / color escapes we want to
        -- see in raw form.
        local hex_parts = {}
        local lim = math.min(#text, 60)
        for i = 1, lim do
            hex_parts[i] = string.format('%02X', text:byte(i))
        end
        -- Replace non-printable bytes in display version with '.'
        local printable = text:gsub('[%z\1-\31\127-\255]', '.'):sub(1, 80)
        _emit_trace_line(string.format(
            '[%s] [TXT] mode=%d len=%d text=[%s]',
            timestamp, mode, #text, printable))
        if #hex_parts > 0 then
            _emit_trace_line('         hex: ' .. table.concat(hex_parts, ' '))
        end
    end

    -- Drop addon-injected lines. This includes our own debug echo
    -- below, which would otherwise re-enter via the incoming-text
    -- handler and recurse infinitely.
    --
    -- EXCEPTION: high-mode FFXI system messages we WANT through.
    -- These are mode bytes >= 150 that carry legitimate game text
    -- (not addon-injected). The list is conservative — opening
    -- more modes risks letting addon-injected chat (BattleMod,
    -- Healer, Itemizer notices, etc.) flood the panel. Add a new
    -- entry only when telemetry below shows a real game message
    -- being dropped on that mode and we've confirmed it's not an
    -- addon source.
    --
    --   151 — server announcement (Voidwatch / Campaign / Besieged
    --         world-event broadcasts) + home-point / system info.
    --   150 — NPC dialog / conversation ("Jeggim : Without a
    --         watercraft..."). The same line also arrives on mode 152
    --         (twice) — a duplicate framing we deliberately leave
    --         dropped so the NPC line shows once, not three times.
    --   161 — periodic world announcements: King Kupofried's "ancient
    --         magic" buff broadcast, and "Page N of the tome flares
    --         up!" (Ambuscade tome progress). Confirmed via trace.
    --   205 — LS message-of-the-day (login banner / /lsmes output)
    --   208 — /check examine line ("<Name> examines you."). Confirmed
    --         via trace. Python's _EXAMINE_PATTERN_R then routes it to
    --         the examine channel → System tab.
    --
    -- NOT whitelisted (intentionally):
    --   152 — duplicate framing of mode-150 NPC dialog (fires 2x for
    --         the same line). Dropping it avoids triplicate NPC lines.
    --   160 — a third-party /checkparam addon's GearSwap-style stat
    --         readout that runs alongside /check. User wants it
    --         ignored, so it stays dropped.
    --
    -- When a user reports a missing system message, check their
    -- session log for the "[OW] dropped chat mode=N" telemetry
    -- line below; the mode that produced the dropped text snippet
    -- can then be added here.
    local REAL_HIGH_MODES = {
        [150] = true,
        [151] = true,
        [161] = true,
        [205] = true,
        -- 217 — LS2 message-of-the-day (the LS2 counterpart to mode 205
        --        for LS1). Confirmed via chatdebug: "[2]< <LS2name>:
        --        <setter> >" header + body line, e.g. "working on the next
        --        gobbiebag items... (Jun. 3, ...)". Without this whitelist
        --        the LS2 MoTD was silently dropped here while the LS1 MoTD
        --        (205) passed — so LS1 showed and LS2 didn't. Python maps
        --        mode 217 → chat_ls2 → LS2 tab and colors it LS green.
        [217] = true,
        [208] = true,
        -- 212 — Unity Concord chat (text-path mode for /cm u). Carries
        --       Unity NPC dialogue ("{Yoran-Oran} The Rhinostery...") AND
        --       Unity member chat — including ONE-CHARACTER check-in
        --       messages (a player typing just "." or "、" to ping the
        --       group; confirmed via chatdebug: Vyihfe's body was a single
        --       0x2E period). Those short messages are REAL and decode
        --       fine, so there is deliberately NO length filter here — an
        --       earlier attempt to drop short mode-212 lines as "status
        --       pings" was wrong and suppressed legitimate check-ins.
        --       Body may be Shift-JIS or {auto-translate}-wrapped; the
        --       decode pipeline below handles both. Python maps mode 212
        --       → chat_unity → Unity tab.
        [212] = true,
        -- 211 — your OWN outgoing Unity chat echoes here ("{Wormfood} ..."),
        --       NOT on mode 33 (the 0x017 packet path doesn't carry your
        --       own sends) and NOT on 212. Confirmed via chatdebug:
        --       "[TXT] mode=211 text=[{Wormfood} ..]" after a /uc send.
        --       Without this whitelist your Unity messages never display.
        --       Routed to chat_unity (same as 212) by the Python
        --       classifier; the name carries the 0x7F 0xFC wrapper so the
        --       self-keep logic below treats it as your own line.
        [211] = true,
    }
    if mode >= MAX_REAL_CHAT_MODE and not REAL_HIGH_MODES[mode] then
        -- Silently drop. Previously this printed a one-line preview of
        -- the first occurrence of each unseen high mode for diagnosis,
        -- but the prints landed in the FFXI chat console as red text
        -- and cluttered every session. If a chat line ever needs
        -- diagnosing again, use //ow chatpkttrace which writes to
        -- data/chat_packet_log.txt without touching chat.
        return
    end

    -- Mode 212 (Unity, incoming-text path) carries TWO things:
    --   * PC member chat — sender wrapped in the 0x7F 0xFC ... 0x7F 0xFB
    --       name markers ("{<7F FC>Armistice<7F FB>} ..."). This path
    --       MANGLES autotranslate (Windower delivers AT as FD FD <id>
    --       with a lossy high-byte shift → renders as garbage). The SAME
    --       member chat also arrives — cleanly, with resolved AT — on the
    --       0x017 packet path (mode 33, chat_packets.lua), so we DROP the
    --       mangled member-chat copy here and let mode 33 be canonical.
    --   * NPC dialogue — plain ASCII braces, NO name-wrapper
    --       ("{Yoran-Oran} The Rhinostery..."). NPC dialogue NEVER appears
    --       on mode 33, so we KEEP it here.
    -- Discriminator (from packet hex): a 0x7F 0xFC sequence in the raw
    -- text means a wrapped PC name → member chat → drop. No wrapper →
    -- NPC dialogue → keep. Checked on the RAW text before any marker
    -- stripping below removes the wrapper bytes.
    if mode == 212 or mode == 211 then
        -- Your OWN outgoing Unity echo (mode 211) carries autotranslate as
        -- bare FD bytes (Windower mangles the AT id on the echo), so an
        -- AT-only send like "/u {Hello!}" arrives as "{Wormfood} \xFD\xFD"
        -- and the body renders empty — only your name shows. The outgoing-
        -- text hook (OmniWatch.lua) captured the INTACT typed phrase and
        -- stored the resolved "{Phrase}" body keyed by mode 211. Swap the
        -- mangled body for it here so your Unity message displays in full.
        if mode == 211 and _G._ow_own_outgoing_suppress then
            local sup = _G._ow_own_outgoing_suppress[211]
            if sup and sup.resolved and (os.clock() - (sup.ts or 0)) < 1.0 then
                _G._ow_own_outgoing_suppress[211] = nil
                -- Preserve the "{Name} " sender prefix (literal braces +
                -- trailing space) and replace everything after it with the
                -- resolved phrase. If no recognizable prefix, replace whole.
                local prefix = text:match('^(%b{}%s)')
                if prefix then
                    text = prefix .. sup.resolved
                else
                    text = sup.resolved
                end
            end
        end
        if text:find('\127\252', 1, true) then
            -- Wrapped PC name → member-chat duplicate of the clean mode-33
            -- packet. Drop it — UNLESS it's your OWN message (mode 211 is
            -- ALWAYS your own outgoing Unity, and outgoing chat may also
            -- echo on 212). If your own send doesn't also arrive cleanly
            -- on mode 33 we'd suppress it entirely, so only drop when the
            -- wrapped name is NOT the local player. Extract the name from
            -- between the wrapper bytes (7F FC <name> 7F FB) and compare to
            -- the player name; keep on match.
            local _wname = text:match('\127\252(.-)\127\251')
            local _player = windower.ffxi.get_player()
            local _pname = _player and _player.name or nil
            local _is_self = _wname and _pname and _wname == _pname
            if not _is_self then
                return   -- other player's mangled duplicate → drop
            end
            -- own message → fall through and emit (this is the copy that
            -- shows YOUR Unity message in the panel).
        end
        -- else: plain-brace NPC dialogue → fall through and emit normally.
    end

    -- Bead-pouch / coffer item-use spam. In Escha/Reisenjima, players
    -- repeatedly pop bead pouches and the broadcast "<Name> uses a bead
    -- pouch. <Name> obtains N escha beads." floods System with one line
    -- per pop for every nearby player (mode 127). It's another player's
    -- item-use, not chat. Like the progression filter, keep only your
    -- own (so you can still see your own bead/coffer results) and drop
    -- everyone else's. Matches the pouch-use + bead/stone obtain phrasing
    -- so it won't catch ordinary chat that happens to mention beads.
    do
        local is_pouch_spam =
            (text:find(' uses a ', 1, true)
             and (text:find(' pouch', 1, true)
                  or text:find('obtains', 1, true)))
            and (text:find('escha beads', 1, true)
                 or text:find('escha stone', 1, true)
                 or text:find('potpourri', 1, true)
                 or text:find(' beads.', 1, true))
        if is_pouch_spam then
            local player = windower.ffxi.get_player()
            local pname = player and player.name or nil
            -- Keep only if the line is about us (our name leads it).
            if not (pname and pname ~= ''
                    and text:find(pname, 1, true) == 1) then
                return
            end
        end
    end

    -- Progression-message self-filter. FFXI broadcasts "<Name> earns a
    -- job point!", "<Name> gains N limit points", and exemplar/capacity
    -- gains for everyone in your area — so other players' gains flood the
    -- System tab ("Delchan earns a job point!"). Keep only your own.
    -- These are actorless-feeling system lines that lead with the subject
    -- player's name, so we self-check by leading name.
    do
        local is_progression =
            text:find('earns a job point', 1, true)
            or text:find(' limit points', 1, true)
            or text:find(' exemplar points', 1, true)
            or text:find(' capacity points', 1, true)
        if is_progression then
            local player = windower.ffxi.get_player()
            local pname = player and player.name or nil
            -- Show only if the line is about us (our name leads it).
            if not (pname and pname ~= ''
                    and text:find(pname, 1, true) == 1) then
                return
            end
        end
    end

    -- Drop real-chat modes (say/tell/LS/etc.) so they don't flow into
    -- the chat panel via incoming text. The 0x017 packet handler
    -- sources INCOMING chat (messages received from others) — packets
    -- are more reliable than text capture for that.
    --
    -- EXCEPTIONS that still pass through this filter:
    --
    -- 1. GearSwap state-set echoes piggyback on mode 1 (no explicit
    --    color = same mode as /say). We keep those so the Gearswap
    --    tab still gets its content. Patterns:
    --      "[GearSwap] ..."      explicit prefix
    --      "[CHAR] ..."          user-convention prefix in rule files
    --      "X is now Y."         state.X:set(value) echo
    --
    -- 2. Your OWN outgoing chat (/say, /p, /tell sent, /sh, /y, /ls).
    --    0x017 doesn't fire for messages YOU send to yourself — it
    --    only carries inbound chat from others. So your own sends
    --    must come through here. We detect "own" by looking for your
    --    player name at the start of the line, or in the bracketed
    --    formats FFXI uses ("(Name) text" for /p, "<Name>>text" for
    --    sent tell, etc.). If detected, pass through.
    -- Mode 111 carries several line types, ALL of which duplicate the
    -- 0x028 synth and were leaking into System:
    --   * Mix/medicine text dupes ("Monberaux uses Mix: ...gains Protect")
    --   * Party/trust buff-gains ("Yoran-Oran gains the effect of Protect")
    --   * Mob ability self-buffs ("The Apex Crab uses Scissor Guard.
    --     The Apex Crab gains the effect of Defense Boost")
    -- The synth emits party buffs (Buffs tab), Mix (Battle), and mob TP
    -- moves (cat 11 → Battle → the user's Mob filter) on their own paths,
    -- so the raw text version on 111 is redundant everywhere and only
    -- ever leaked into System. Drop the whole mode. (An earlier attempt
    -- to selectively keep mob lines here was wrong: the text version
    -- still routed to System, not the Mob tab — the Mob tab is fed by the
    -- synth, not this path.)
    -- Skillchain exception: mode 20 (battle damage text) is normally
    -- dropped as a BattleMod-format duplicate, but a SKILLCHAIN result
    -- line ("Fragmentation: 1023 → Apex Crab") rides mode 20 too and is
    -- NOT a duplicate of any synth — there's no skillchain synth, so if
    -- we drop it here Python never sees it. Let skillchain lines through
    -- (Python's routing then files them under weaponskills). Detected by
    -- the skillchain property names followed by a colon — tight enough to
    -- not catch ordinary damage text.
    local _is_skillchain = false
    if mode == 20 then
        local _l = text:lower()
        if _l:find('skillchain', 1, true)
           or _l:find('light:', 1, true)   or _l:find('darkness:', 1, true)
           or _l:find('radiance:', 1, true) or _l:find('umbra:', 1, true)
           or _l:find('gravitation:', 1, true)
           or _l:find('fragmentation:', 1, true)
           or _l:find('fusion:', 1, true)  or _l:find('distortion:', 1, true)
           or _l:find('compression:', 1, true)
           or _l:find('liquefaction:', 1, true)
           or _l:find('induration:', 1, true)
           or _l:find('reverberation:', 1, true)
           or _l:find('transfixion:', 1, true)
           or _l:find('scission:', 1, true)
           or _l:find('detonation:', 1, true)
           or _l:find('impaction:', 1, true) then
            _is_skillchain = true
        end
    end
    -- Emote carve-out (mirrors the skillchain exception above). Mode 15
    -- is OVERLOADED: it carries BOTH battle text ("X hits Y for N",
    -- "X takes N points of damage", "X misses Y") AND social emotes
    -- ("<Name> waves", "<Name> bows"). It's in DROPPED_CHAT_MODES to
    -- suppress the battle-text duplicate (the 0x028 synth handles those),
    -- but that also dropped the social emotes — which belong in World.
    -- This carve-out passes a mode-15 line that is a SOCIAL EMOTE: it has
    -- the player-name wrapper (\127\252 ... \127\251) AND lacks any battle
    -- signature. Fail-closed: if there's no name wrapper we treat it as
    -- battle text and let it drop (better to miss a weird emote than to
    -- leak battle spam). Without this, emotes vanish from World entirely.
    local _is_emote = false
    if mode == 15 then
        local _has_name_wrap = text:find('\127\252', 1, true) ~= nil
        if _has_name_wrap then
            local _l = text:lower()
            local _looks_battle =
                _l:find(' hits ', 1, true)   or _l:find(' takes ', 1, true)
                or _l:find(' misses', 1, true) or _l:find(' evades', 1, true)
                or _l:find(' resists', 1, true)
                or _l:find('points of damage', 1, true)
                or _l:find(' recovers ', 1, true)
                or _l:find(' hp', 1, true)    or _l:find(' mp', 1, true)
                or _l:find(' tp', 1, true)
                or _l:find('\226\134\146', 1, true)  -- "→" damage arrow (UTF-8)
            if not _looks_battle then
                _is_emote = true
            end
        end
    end
    if DROPPED_CHAT_MODES[mode] and not _is_skillchain
            and not _is_emote then
        local is_gearswap = false
        if text:sub(1, 10) == '[GearSwap]' or text:sub(1, 6) == '[CHAR]' then
            is_gearswap = true
        elseif text:sub(1, 2) == '$[' then
            -- GearSwap macro-set echoes: "$[Macro Set: WAR] Book: 1
            -- Page: 3". Fired on mode 1 (same as /say) with no color,
            -- so they look like chat but are addon output. Confirmed
            -- via trace. Strip the leading "$" marker so the line
            -- displays as "[Macro Set: WAR] Book: 1 Page: 3".
            is_gearswap = true
            text = text:sub(2)
        elseif text:match("^[A-Za-z][A-Za-z0-9 ]-%s+is now%s+[A-Za-z0-9_]+%.$") then
            is_gearswap = true
        end

        local is_own_echo = false
        local _CHAT_ECHO_MODES = {
            [1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,
            [7]=true,[8]=true,[9]=true,[11]=true,[12]=true,[13]=true,
            [14]=true,[26]=true,[27]=true,
        }
        if not is_gearswap and _CHAT_ECHO_MODES[mode] then
            local player = windower.ffxi.get_player()
            local pname = player and player.name or nil
            if pname and pname ~= '' and text:find(pname, 1, true) then
                -- Player's name appears in the line. Be a bit
                -- conservative: only treat as own-echo when the name
                -- appears in the FIRST 30 chars (i.e. as sender, not
                -- just mentioned in the body).
                local pos = text:find(pname, 1, true)
                if pos and pos <= 30 then
                    is_own_echo = true
                end
            end
        end

        -- Repair the MANGLED echo of our own outgoing auto-translate
        -- chat. Windower's incoming-text echo drops the AT id's high
        -- byte, so a phrase like {test} (id 7801) renders as a stray
        -- char ("y"). OmniWatch's 'outgoing text' hook captured the
        -- phrase from the INTACT typed command and stored the resolved
        -- body keyed by mode. Here we swap the mangled body for the
        -- resolved text, then let the echo display normally (it already
        -- passes the own-echo gate). Consume the flag; short TTL guards
        -- against repairing an unrelated later line.
        if is_own_echo and _G._ow_own_outgoing_suppress then
            local sup = _G._ow_own_outgoing_suppress[mode]
            if sup and sup.resolved and (os.clock() - (sup.ts or 0)) < 1.0 then
                _G._ow_own_outgoing_suppress[mode] = nil
                -- The echo is "<sender-prefix><mangled body>". Preserve
                -- the prefix (everything up to and including the first
                -- ") " or "> " that FFXI uses to separate sender from
                -- body) and replace the body with the resolved text.
                local prefix = text:match('^(.-[%)>]%s)')
                if prefix then
                    text = prefix .. sup.resolved
                else
                    -- No recognizable sender prefix — replace whole body.
                    text = sup.resolved
                end
            end
        end

        if not is_gearswap and not is_own_echo then return end
    end

    sender_name = sender_name or ''

    -- Hex capture: dump raw bytes BEFORE normalization or strip so we
    -- can see what Windower handed us. Limit to lines with non-ASCII
    -- bytes to keep the FFXI chat log readable. Capped at 80 bytes
    -- per line so a long message doesn't flood the chat log; the
    -- first 80 bytes are usually enough to identify a pattern.
    if M.hex_capture and text ~= '' then
        local has_high = false
        for i = 1, #text do
            if text:byte(i) >= 0x80 then has_high = true; break end
        end
        if has_high then
            local parts = {}
            local lim = math.min(#text, 80)
            for i = 1, lim do
                parts[i] = string.format("%02x", text:byte(i))
            end
            local trail = (#text > lim) and (' ... (+' .. (#text - lim) .. ' more bytes)') or ''
            -- Tag with utf8/sjis based on whether the bytes parse as
            -- valid UTF-8 — this is the same check the normalizer
            -- uses to decide whether to convert.
            local tag = _is_valid_utf8(text) and 'utf8' or 'sjis?'
            windower.add_to_chat(207,
                string.format('[hex mode=%d %s] %s%s', mode, tag,
                              table.concat(parts, ' '), trail))
            -- Also print the ASCII-decoded view so we can correlate
            -- "this byte X renders as Y" at a glance.
            windower.add_to_chat(207,
                string.format('[hex mode=%d] text: %s', mode, text))
        end
    end

    -- Pre-strip byte-level markers (FC/FB name wrappers, \x7F+digit
    -- end-marker). Done BEFORE encoding normalization because these
    -- markers don't survive SJIS decoding cleanly — \xFC is a valid
    -- SJIS first-byte and would combine with the next byte to make
    -- a wrong kanji character if we left it for the normalizer.
    text = _pre_strip_byte_markers(text)

    -- Normalize to UTF-8 BEFORE strip. The strip's UTF-8 walker
    -- assumes UTF-8 input — if Windower hands us SJIS bytes (which
    -- it apparently does on some installs despite the wiki claim),
    -- the walker would treat SJIS bytes as garbage and strip them
    -- into spaces. Convert first to give the strip clean UTF-8 to
    -- work with.
    text = _normalize_to_utf8(text)

    text = _strip_ffxi_markers(text, mode)

    -- Resolve sender → mob id → classification. Most chat senders
    -- won't be findable by name (different zones, LS chatter etc.),
    -- in which case we fall through to 'other' with id=0.
    local actor_id, actor_class, actor_display = 0, 'other', sender_name
    if sender_name ~= '' then
        local mob = windower.ffxi.get_mob_by_name and
                    windower.ffxi.get_mob_by_name(sender_name)
        if mob and mob.id then
            actor_id = mob.id
            if _classifier and _classifier.classify_entity then
                local cat, nm = _classifier.classify_entity(mob.id)
                if cat then actor_class = cat end
                if nm  then actor_display = nm end
            end
        end
    end

    local ev = {
        ts           = os.time(),
        source       = 'chat',
        mode         = mode,
        actor_id     = actor_id,
        actor_name   = actor_display,
        actor_class  = actor_class,
        target_id    = 0,
        target_name  = '',
        target_class = '',
        text         = text,
        segments     = {},   -- raw incoming text has no word-level coloring
    }
    _ring.text_ring.push(ev)

    if M.debug then
        windower.add_to_chat(207, string.format(
            '[OW chat] mode=%d %s [%s]: %s',
            ev.mode, ev.actor_name, ev.actor_class, ev.text))
    end
end

-- Expose for unit testing
M._strip_ffxi_markers = _strip_ffxi_markers
M._pre_strip_byte_markers = _pre_strip_byte_markers
M._is_valid_utf8 = _is_valid_utf8
M._normalize_to_utf8 = _normalize_to_utf8

-- Combined cleanup pipeline that matches the order in emit_chat.
-- Tests call this to exercise the full path. Production code uses
-- the three stages individually so the hex-capture diagnostic can
-- inspect each stage's output.
function M._clean(text)
    text = _pre_strip_byte_markers(text)
    text = _normalize_to_utf8(text)
    text = _strip_ffxi_markers(text)
    return text
end

return M