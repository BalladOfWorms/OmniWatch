--[[
═══════════════════════════════════════════════════════════════════════════
Server_Stats.lua  —  Passive server-truth stat listener (v2)

PURPOSE
  Read authoritative stat values from incoming 0x061 and 0x063 packets
  the FFXI server pushes automatically after rolls land, buffs change,
  gear is swapped, and similar events. No injection. No outbound
  traffic. Pure passive listener.

HOW IT WORKS
  Every incoming 0x061 packet contains, at offsets 48 and 50, the
  player's current primary attack (pAtt) and defense (def) values as
  16-bit little-endian unsigned integers. These reflect server-side
  reality including all gear, buffs (rolls, songs, food), and any
  hidden bonuses the client doesn't model.

  Incoming 0x063 packets at size 156 (sub-type 5) carry primary
  accuracy (pAcc) at offset 138. These fire less often than 0x061
  (typically on login, zone change, or equipment-screen interaction)
  but provide the same authoritative data for accuracy.

  Not all packets carry stat values — some are partial updates with
  zeros at the relevant offsets. We filter zero-or-trivial values and
  only update the cache when meaningful values arrive.

  When a fresh value is captured, we fire an on_capture callback so
  OmniWatch can trigger a stats recompute and the panel reflects the
  new value within ~16ms (one prerender frame).

WHAT IT STILL DOESN'T COVER
  pAtt + def + pAcc are captured. Aux/ranged equivalents are derived
  by ratio scaling. Eva/MAB/MAcc and other stats don't appear at
  fixed offsets in either packet, so the panel still computes those
  from gear/buffs client-side.

  Lanun gear's chance to proc a bonus on a Phantom Roll's accuracy is
  not always reflected — the proc fires after our last 0x063 capture
  and the server doesn't always push a fresh one in response.

KILL SWITCHES
  1. //ow serverstats off                  → runtime disable
  2. Set DISABLED = true near top of file  → permanent disable
  3. Delete this file                      → OmniWatch loader handles
                                              gracefully

API
  request(reason)         → no-op (kept for backward compatibility with
                            existing call sites; passive listener has
                            nothing to "request")
  tick()                  → no-op (no pending state to advance)
  get()                   → {patt, def, pacc, age_s} or nil
  enable() / disable()    → runtime toggle
  set_debug(bool)
  set_on_capture(fn)      → fires on every fresh capture
  status()                → diag table
  on_incoming_chunk(id,d) → packet handler (called by OmniWatch's
                            existing 'incoming chunk' dispatcher)
═══════════════════════════════════════════════════════════════════════════
]]

-- ── Module-level kill switch ─────────────────────────────────────────────
local DISABLED = false

if DISABLED then
    return {
        request           = function() end,
        tick              = function() end,
        get               = function() return nil end,
        enable            = function() end,
        disable           = function() end,
        set_debug         = function() end,
        set_on_capture    = function() end,
        status            = function() return 'DISABLED at module level' end,
        on_incoming_chunk = function() end,
    }
end

-- ── Configuration ────────────────────────────────────────────────────────
local CONFIG = {
    -- 0x061 ("Char Stats") — primary attack and defense.
    -- The packet has a "subtype" indicator at offset 8 (u16 LE). The
    -- value 384 (0x0180) is the COMPREHENSIVE layout that contains
    -- pAtt at offset 48 and def at offset 50. Other subtypes can have
    -- different fields at those same offsets (sometimes aAtt, eva,
    -- or zeros). To avoid caching the wrong stat, we ONLY accept
    -- subtype 384.
    pkt_stats_id      = 0x061,
    offset_subtype    = 8,
    subtype_with_patt = 384,
    offset_patt       = 48,
    offset_def        = 50,

    -- 0x063 — character info packet, carries primary accuracy.
    -- The 0x063 packet ID is reused for many different sub-types
    -- (size 16, 200, 220, 156 all observed). Empirical probe data
    -- (CheckParamProbe v0.8) showed that ONLY the size-156 variant
    -- with disc_a (offset 4-5 as u16 LE) == 5 carries pAcc at
    -- offset 138. All other 0x063 sub-types have zeros or unrelated
    -- data at that offset. We require both filters to match.
    pkt_acc_id        = 0x063,
    pkt_acc_size      = 156,
    pkt_acc_disc_off  = 4,
    pkt_acc_disc_val  = 5,
    offset_pacc       = 138,

    -- Minimum value to consider "real" — anything below this is treated
    -- as a zero/junk byte from a partial-update packet variant. 50 is
    -- well below any realistic player attack/acc value at endgame.
    sanity_floor = 50,
}

-- ── State ────────────────────────────────────────────────────────────────
local state = {
    enabled        = false,    -- runtime toggle (//ow serverstats on/off)
    cached_patt    = nil,
    cached_def     = nil,
    cached_pacc    = nil,
    cached_at      = 0,
    cached_pacc_at = 0,
    debug          = false,
    -- Diagnostics
    packets_seen   = 0,        -- 0x061 seen
    captures_made  = 0,        -- 0x061 captures with real pAtt/def
    skipped_partial = 0,       -- 0x061 filtered (zeros / sanity floor)
    pacc_packets_seen = 0,     -- 0x063 seen at expected size
    pacc_captures_made = 0,    -- 0x063 captures with real pAcc
    pacc_skipped       = 0,    -- 0x063 too small / sanity floor
    -- Last-seen packet snapshots, used by //ow serverstats trace to
    -- diagnose proc-miss issues. We keep just the most recent of each
    -- packet ID — enough to inspect "what did the server actually
    -- send?" right after a mis-displayed cast.
    last_0x061_hex     = nil,
    last_0x061_at      = 0,
    last_0x063_hex     = nil,
    last_0x063_at      = 0,
    -- Callback invoked when a fresh sample is captured. OmniWatch sets
    -- this to a function that triggers a stats recompute so the panel
    -- updates immediately with the new values.
    on_capture     = nil,
}

-- ── Logging helpers ──────────────────────────────────────────────────────
local function log(msg)
    if not state.debug then return end
    if windower and windower.add_to_chat then
        windower.add_to_chat(207, '[OW.SS] ' .. tostring(msg))
    end
end

local function log_warn(msg)
    if windower and windower.add_to_chat then
        windower.add_to_chat(123, '[OW.SS] ' .. tostring(msg))
    end
end

-- ── Packet parsing ───────────────────────────────────────────────────────

local function read_u16_le(bytes, off)
    if off + 2 > #bytes then return nil end
    return bytes:byte(off + 1) + bytes:byte(off + 2) * 256
end

-- Called from OmniWatch's existing 'incoming chunk' dispatcher whenever
-- a relevant packet arrives.
--
-- 0x061 ("Char Stats"): pAtt at offset 48, def at offset 50 (u16 LE).
-- Some 0x061 variants are partial-update packets with zeros at those
-- offsets — we filter those out via the sanity floor.
--
-- 0x063 ("Set Update"): pAcc at offset 138 (u16 LE) when size>=200.
-- Smaller 0x063 packets are different layouts and skipped.
local function on_incoming_chunk(id, data)
    if not state.enabled then return end
    if not data then return end

    -- ── 0x061: pAtt and def ─────────────────────────────────────────────
    if id == CONFIG.pkt_stats_id then
        if #data < CONFIG.offset_def + 2 then return end

        state.packets_seen = state.packets_seen + 1
        -- Snapshot for trace command (always recorded, even if we
        -- end up filtering this packet as a partial-update).
        do
            local n = math.min(#data, 80)
            local parts = {}
            for i = 1, n do
                parts[i] = string.format('%02X', data:byte(i))
            end
            state.last_0x061_hex = table.concat(parts, ' ')
            if #data > 80 then
                state.last_0x061_hex = state.last_0x061_hex
                                       .. string.format(' …(+%d)', #data - 80)
            end
            state.last_0x061_at = os.clock()
        end

        -- Filter by subtype: only the comprehensive layout (subtype 384)
        -- has pAtt at off=48 and def at off=50 reliably. Other subtypes
        -- can have different stats at those same offsets which would
        -- corrupt the cache if we accepted them. Filter rejects any
        -- 0x061 whose subtype byte at offset 8 isn't 384.
        local subtype = read_u16_le(data, CONFIG.offset_subtype)
        if subtype ~= CONFIG.subtype_with_patt then
            state.skipped_partial = state.skipped_partial + 1
            log(string.format('0x061 wrong subtype=%s (want %d), skipping',
                tostring(subtype), CONFIG.subtype_with_patt))
            return
        end

        local patt = read_u16_le(data, CONFIG.offset_patt)
        local def  = read_u16_le(data, CONFIG.offset_def)

        if not patt or not def
           or patt < CONFIG.sanity_floor
           or def  < CONFIG.sanity_floor then
            state.skipped_partial = state.skipped_partial + 1
            return
        end

        state.cached_patt = patt
        state.cached_def  = def
        state.cached_at   = os.clock()
        state.captures_made = state.captures_made + 1

        log(string.format('0x061 captured pAtt=%d def=%d (#%d, subtype=%d)',
            patt, def, state.captures_made, subtype))

        if state.on_capture then
            pcall(state.on_capture, patt, def, state.cached_pacc)
        end
        return
    end

    -- ── 0x063: pAcc ─────────────────────────────────────────────────────
    if id == CONFIG.pkt_acc_id then
        -- Filter to the specific 0x063 sub-type that carries pAcc:
        -- exact size match + discriminator byte at offset 4 must
        -- equal CONFIG.pkt_acc_disc_val (default: 5). Other 0x063
        -- sub-types (size 16, 200, 220) carry unrelated data and
        -- would corrupt the cache if accepted.
        if #data ~= CONFIG.pkt_acc_size then
            return
        end
        local disc = read_u16_le(data, CONFIG.pkt_acc_disc_off)
        if disc ~= CONFIG.pkt_acc_disc_val then
            return
        end
        state.pacc_packets_seen = state.pacc_packets_seen + 1
        -- Snapshot for trace command. Use a higher byte cap (160) so
        -- we capture through offset 138 + a few bytes of context.
        do
            local n = math.min(#data, 160)
            local parts = {}
            for i = 1, n do
                parts[i] = string.format('%02X', data:byte(i))
            end
            state.last_0x063_hex = table.concat(parts, ' ')
            if #data > 160 then
                state.last_0x063_hex = state.last_0x063_hex
                                       .. string.format(' …(+%d)', #data - 160)
            end
            state.last_0x063_at = os.clock()
        end

        local pacc = read_u16_le(data, CONFIG.offset_pacc)
        if not pacc or pacc < CONFIG.sanity_floor then
            state.pacc_skipped = state.pacc_skipped + 1
            return
        end

        state.cached_pacc    = pacc
        state.cached_pacc_at = os.clock()
        state.pacc_captures_made = state.pacc_captures_made + 1

        log(string.format('0x063 captured pAcc=%d (#%d)',
            pacc, state.pacc_captures_made))

        if state.on_capture then
            pcall(state.on_capture,
                  state.cached_patt, state.cached_def, pacc)
        end
        return
    end
end

-- ── Public API ───────────────────────────────────────────────────────────

-- request() and tick() are no-ops in the passive listener. Kept for
-- backward compatibility with OmniWatch call sites that were written
-- against the inject-based v1 module. Removing them would require
-- editing OmniWatch.lua's prerender loop and the cat=6 / buff /
-- gear-change trigger sites. Easier to just stub them here.
local function request(reason) end
local function tick() end

local function get()
    if not state.enabled then return nil end
    if not state.cached_patt and not state.cached_pacc then return nil end
    return {
        patt    = state.cached_patt,
        def     = state.cached_def,
        pacc    = state.cached_pacc,
        age_s   = state.cached_at > 0
                  and (os.clock() - state.cached_at) or 0,
        pacc_age_s = state.cached_pacc_at > 0
                     and (os.clock() - state.cached_pacc_at) or 0,
    }
end

local function enable()
    state.enabled = true
    log('Server_Stats enabled (passive listener)')
end

local function disable()
    state.enabled = false
    state.cached_patt = nil
    state.cached_def  = nil
    state.cached_pacc = nil
    log('Server_Stats disabled')
end

local function set_debug(on)
    state.debug = on and true or false
end

local function set_on_capture(fn)
    state.on_capture = fn
end

-- Drop the cached values without disabling the module. Used by
-- OmniWatch when a roll wears off — the post-wear-off pAtt would be
-- different from the cached value, but the server doesn't always
-- push a 0x061 with stat values on wear-off (sometimes it's a
-- partial-update packet we filter out). Invalidating forces the
-- panel to fall back to client math, which is reliable when no
-- roll is active.
local function invalidate(reason)
    if not state.cached_patt and not state.cached_pacc then return end
    log(string.format('cache invalidated (%s)', reason or 'unspecified'))
    state.cached_patt = nil
    state.cached_def  = nil
    state.cached_pacc = nil
    state.cached_at   = 0
    state.cached_pacc_at = 0
    -- Notify consumer so the panel re-renders without our override.
    if state.on_capture then
        pcall(state.on_capture, nil, nil, nil)
    end
end

-- Trace report — dumps the most recent 0x061 and 0x063 packet hex with
-- parsed values. Useful for diagnosing "panel didn't update on proc"
-- issues: cast a roll, wait a moment, then //ow serverstats trace to
-- see what the server actually sent.
local function trace()
    return {
        last_0x061_hex = state.last_0x061_hex,
        last_0x061_age = state.last_0x061_at > 0
                         and (os.clock() - state.last_0x061_at) or -1,
        last_0x063_hex = state.last_0x063_hex,
        last_0x063_age = state.last_0x063_at > 0
                         and (os.clock() - state.last_0x063_at) or -1,
        cached_patt    = state.cached_patt,
        cached_def     = state.cached_def,
        cached_pacc    = state.cached_pacc,
    }
end

local function status()
    return {
        enabled         = state.enabled,
        debug           = state.debug,
        cached_patt     = state.cached_patt,
        cached_def      = state.cached_def,
        cached_pacc     = state.cached_pacc,
        cache_age_s     = state.cached_at > 0
                          and (os.clock() - state.cached_at) or -1,
        pacc_age_s      = state.cached_pacc_at > 0
                          and (os.clock() - state.cached_pacc_at) or -1,
        packets_seen    = state.packets_seen,
        captures_made   = state.captures_made,
        skipped_partial = state.skipped_partial,
        pacc_packets_seen  = state.pacc_packets_seen,
        pacc_captures_made = state.pacc_captures_made,
        pacc_skipped       = state.pacc_skipped,
    }
end

-- ── Module export ────────────────────────────────────────────────────────
return {
    request           = request,
    tick              = tick,
    get               = get,
    enable            = enable,
    disable           = disable,
    set_debug         = set_debug,
    set_on_capture    = set_on_capture,
    invalidate        = invalidate,
    status            = status,
    trace             = trace,
    on_incoming_chunk = on_incoming_chunk,
}