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
        local base = windower.addon_path or ''
        if base ~= '' and base:sub(-1) ~= '/' and base:sub(-1) ~= '\\' then
            base = base .. '/'
        end
        local path = base .. 'data/chat_packet_log.txt'
        local f, err = io.open(path, 'a')
        if not f then
            M.trace = false
            windower.add_to_chat(123,
                '[OW emit] trace open failed (' .. tostring(err)
                .. '). Trace disabled. Make sure data/ folder exists.')
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
local function _strip_ffxi_markers(text)
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
    [11] = true,    -- /yell
    [12] = true,    -- /tell sent
    [13] = true,    -- /party (alt)
    [14] = true,    -- /party (alt) / LS1 BattleMod-formatted
    [20] = true,    -- battle damage text (BattleMod fmt) — duplicates
                    --   synth from battle_events.lua via 0x028
    [26] = true,    -- /yell (zone-broadcast variant)
    [27] = true,    -- /linkshell 2 (LS2 actual)
    [36] = true,    -- defeat text — duplicates synth ("X defeats Y")
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
    -- We DO skip addon-injected modes (>= MAX_REAL_CHAT_MODE) even
    -- in trace, because those are our own chat outputs (debug, OW
    -- info lines, etc.) — they're not real FFXI chat and capturing
    -- them creates feedback loops (the trace echoes a line, the
    -- echo arrives via incoming text, the trace logs it again, etc).
    if M.trace and mode < MAX_REAL_CHAT_MODE then
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
    -- Currently whitelisted:
    --   151 — server announcement (Voidwatch / Campaign / Besieged
    --         world-event broadcasts: "Word has been received of an
    --         undead threat in <zone>." — observed by user in May
    --         2026 Voidwatch broadcasts).
    --   205 — LS message-of-the-day (login banner / /lsmes output)
    --
    -- When a user reports a missing system message, check their
    -- session log for the "[OW] dropped chat mode=N" telemetry
    -- line below; the mode that produced the dropped text snippet
    -- can then be added here.
    local REAL_HIGH_MODES = {
        [151] = true,
        [205] = true,
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
    if DROPPED_CHAT_MODES[mode] then
        local is_gearswap = false
        if text:sub(1, 10) == '[GearSwap]' or text:sub(1, 6) == '[CHAR]' then
            is_gearswap = true
        elseif text:match("^[A-Za-z][A-Za-z0-9 ]-%s+is now%s+[A-Za-z0-9_]+%.$") then
            is_gearswap = true
        end

        local is_own_echo = false
        if not is_gearswap then
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

    text = _strip_ffxi_markers(text)

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