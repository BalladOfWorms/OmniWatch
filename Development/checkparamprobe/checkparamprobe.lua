--[[
═════════════════════════════════════════════════════════════════════════════
  CheckParamProbe v1.4 — packet stat-offset finder (0x061 + 0x062 + 0x063)

  CHANGES FROM 1.3
    - setstat is more forgiving: accepts either 8 positional numbers
      OR 8 name/value pairs OR a single space-separated string.
      Prints diagnostic showing arg/token counts so we can debug if
      Windower passes input in an unexpected way.

  CHANGES FROM 1.2
    - setstat takes all 8 combat stats positionally in one command:
      //cpp setstat <pacc> <patt> <aacc> <aatt> <racc> <ratt> <eva> <def>

  CHANGES FROM 1.1
    - 0x061 subtype reverted to byte 9 (was briefly byte 4 in 1.1).
      v1.0 with offset-8 u16 read gave sub=179 and sub=251 with 3/3
      and 9/9 stable hits respectively (good grouping). v1.1 switched
      to byte 4 to match 0x063, but that fragmented groups (32 groups
      from 46 packets) and we lost the patt/def stable hits. v1.2
      restores byte 9 for 0x061; keeps byte 4 for 0x063.

  CHANGES FROM 1.0
    - Added 0x062 (Skills Update) to listen targets

  GOAL
    Find offsets in incoming 0x061 / 0x062 / 0x063 packets where known
    stat values appear. Lets us empirically map server-pushed stats so
    OmniWatch can read them directly instead of computing from gear.

  WORKFLOW
    1. /checkparam <self>   → note pAcc / pAtt / aAcc / aAtt / etc.
    2. //cpp regstats       → auto-grabs STR/DEX/VIT/AGI/INT/MND/CHR
                              + HP/MP/maxHP/maxMP/TP from get_player()
    3. //cpp setstat <pacc> <patt> <aacc> <aatt> <racc> <ratt> <eva> <def>
       all 8 values in a row, in the order shown.
       example: //cpp setstat 1271 1201 1252 1039 0 0 1139 1197
    4. //cpp listen         → start passive listener
    5. Trigger packet events: zone briefly, change gear, eat food,
       cast a roll, sing a song, change job, use a JA. Each event
       sends one or more packets.
    6. //cpp report stable  → only offsets that hit the SAME value in
                              100% of packets within a subtype group.
                              These are the authoritative mappings.
       //cpp report         → full table including coincidence hits
       //cpp dump 061 3     → hex of the last 3 0x061 captures

  ENCODING
    For each offset 0..size-2 we test u16 LE, u16 BE, u32 LE, u32 BE.
    Values must be > 50 to filter out single-byte coincidences.

  STABLE-ONLY FILTER
    Coincidences (e.g. STR=137 happens to appear in a random byte pair
    of one packet) get filtered by requiring the same offset/encoding
    to carry the same value in EVERY packet of a given (id, size, sub)
    group. Real stat offsets are stable across packets where that stat
    didn't change; coincidences aren't.

  COMMANDS
    //cpp regstats                  auto-register base stats + vitals
    //cpp setstat <8 values>        pacc patt aacc aatt racc ratt eva def
    //cpp listen                    start listening
    //cpp stop                      stop
    //cpp report                    full per-subtype offset map (hit counts)
    //cpp report stable             only 100%-hit offsets (the real mappings)
    //cpp dump <061|062|063> <n>    hex of last N captures of packet id
    //cpp known                     list registered stats
    //cpp clear                     clear data
    //cpp status                    state
    //cpp help

═════════════════════════════════════════════════════════════════════════════
]]

_addon.name     = 'CheckParamProbe'
_addon.author   = 'Cooper + Claude'
_addon.version  = '1.4.0'
_addon.commands = {'cpp', 'checkparamprobe'}

-- ── State ────────────────────────────────────────────────────────────────
local state = {
    listen_enabled = false,
    -- known[lower_name] = numeric value. Single flat dict; user adds
    -- entries via regstats (bulk) and setstat (one at a time).
    known          = {},
    -- captures = list of {id, size, sub, hits, ts}
    -- hits = list of {offset, encoding, label, value}
    --   encoding = 'u16le' | 'u16be' | 'u32le' | 'u32be'
    captures       = {},
    -- last_hex[id] = list of last N hex dumps for that packet id
    last_hex       = { [0x061] = {}, [0x062] = {}, [0x063] = {} },
    total_seen     = 0,
}

-- Listen targets. v1.1: added 0x062 (Skills Update). Each FFXI packet
-- type has a different role:
--   0x061 — Char Stats (HP/MP/base stats/combat stats per subtype)
--   0x062 — Skills Update (weapon/magic skill values)
--   0x063 — Set Update (multi-purpose dispatcher: buff list, merit
--           menu, BLU spell set, etc., differentiated by sub byte 4)
local LISTEN_IDS = { [0x061] = true, [0x062] = true, [0x063] = true }

-- Per-packet subtype discriminator for grouping. Determined empirically:
--   0x061: byte at offset 9 (Windower wiki suggests 0x061 has a
--          structured layout where byte 9 marks the variant.
--          v1.0 read u16 at offset 8 which gave 179/251 — that's
--          byte 9 with byte 10 = 0, so reading byte 9 directly is
--          equivalent and cleaner. v1.1 briefly tried offset 4 but
--          that fragments groups; the prior offset-8 grouping found
--          stable hp/patt/def mappings, so v1.2 restores it.
--   0x062: no observed sub-discriminator yet; report as nil.
--   0x063: u8 at offset 4 (the standard FFXI 0x063 discriminator).
local function get_subtype(id, data)
    if id == 0x061 then
        if #data < 10 then return nil end
        return data:byte(10)  -- 1-indexed: this is byte at offset 9
    elseif id == 0x062 then
        return nil
    elseif id == 0x063 then
        if #data < 5 then return nil end
        return data:byte(5)
    end
    return nil
end

-- ── Byte reading helpers ────────────────────────────────────────────────
local function read_u16_le(bytes, off)
    if off + 2 > #bytes then return nil end
    return bytes:byte(off + 1) + bytes:byte(off + 2) * 256
end

local function read_u16_be(bytes, off)
    if off + 2 > #bytes then return nil end
    return bytes:byte(off + 1) * 256 + bytes:byte(off + 2)
end

local function read_u32_le(bytes, off)
    if off + 4 > #bytes then return nil end
    return bytes:byte(off + 1)
         + bytes:byte(off + 2) * 256
         + bytes:byte(off + 3) * 65536
         + bytes:byte(off + 4) * 16777216
end

local function read_u32_be(bytes, off)
    if off + 4 > #bytes then return nil end
    return bytes:byte(off + 1) * 16777216
         + bytes:byte(off + 2) * 65536
         + bytes:byte(off + 3) * 256
         + bytes:byte(off + 4)
end

local function hex_dump(bytes, max_bytes)
    max_bytes = max_bytes or 200
    local n = math.min(#bytes, max_bytes)
    local parts = {}
    for i = 1, n do
        parts[i] = string.format('%02X', bytes:byte(i))
    end
    local s = table.concat(parts, ' ')
    if #bytes > max_bytes then
        s = s .. string.format(' ...(+%d)', #bytes - max_bytes)
    end
    return s
end

-- ── Stat-offset scanner ─────────────────────────────────────────────────
-- For each offset, try u16/u32 in LE/BE and record any hits to
-- known stat values. value > 50 filter cuts the worst coincidences
-- (a random pair of nulls hitting 0 etc.); real coincidences are
-- removed by the "stable" report filter downstream.
local function find_all_known(bytes)
    local hits = {}
    if not next(state.known) then return hits end

    -- Reverse lookup: value -> list of stat labels carrying that value.
    -- Multiple stats can share a value.
    local lookup = {}
    for name, v in pairs(state.known) do
        if v and v > 50 then
            if not lookup[v] then lookup[v] = {} end
            lookup[v][#lookup[v]+1] = name
        end
    end
    if not next(lookup) then return hits end

    local n = #bytes
    -- u16 sweep
    for off = 0, n - 2 do
        local le = read_u16_le(bytes, off)
        local be = read_u16_be(bytes, off)
        if le and lookup[le] then
            for _, label in ipairs(lookup[le]) do
                hits[#hits+1] = { offset=off, encoding='u16le', label=label, value=le }
            end
        end
        if be and be ~= le and lookup[be] then
            for _, label in ipairs(lookup[be]) do
                hits[#hits+1] = { offset=off, encoding='u16be', label=label, value=be }
            end
        end
    end
    -- u32 sweep (skip anything that fits in u16 — already handled above —
    -- and anything >1M which can't realistically be a stat).
    for off = 0, n - 4 do
        local le = read_u32_le(bytes, off)
        local be = read_u32_be(bytes, off)
        if le and le > 65535 and le < 1000000 and lookup[le] then
            for _, label in ipairs(lookup[le]) do
                hits[#hits+1] = { offset=off, encoding='u32le', label=label, value=le }
            end
        end
        if be and be ~= le and be > 65535 and be < 1000000 and lookup[be] then
            for _, label in ipairs(lookup[be]) do
                hits[#hits+1] = { offset=off, encoding='u32be', label=label, value=be }
            end
        end
    end
    return hits
end

-- ── Packet capture ──────────────────────────────────────────────────────
windower.register_event('incoming chunk', function(id, data)
    if not state.listen_enabled then return end
    if not LISTEN_IDS[id] then return end

    state.total_seen = state.total_seen + 1
    local sub = get_subtype(id, data)
    local hits = find_all_known(data)

    state.captures[#state.captures + 1] = {
        id   = id,
        size = #data,
        sub  = sub,
        hits = hits,
        ts   = os.clock(),
    }

    -- Per-id hex ring buffer (last 5).
    if not state.last_hex[id] then state.last_hex[id] = {} end
    state.last_hex[id][#state.last_hex[id] + 1] = {
        size = #data, sub = sub, hex = hex_dump(data, 200), ts = os.clock(),
    }
    while #state.last_hex[id] > 5 do
        table.remove(state.last_hex[id], 1)
    end
end)

-- ── Auto-register base stats from windower.ffxi.get_player() ────────────
local function regstats_auto()
    local p = windower.ffxi.get_player()
    if not p then
        windower.add_to_chat(123, '[CPP] get_player() returned nil')
        return 0
    end
    local added = 0
    if p.stats then
        for _, k in ipairs({'str','dex','vit','agi','int','mnd','chr'}) do
            local v = tonumber(p.stats[k])
            if v and v > 0 then
                state.known[k] = v
                added = added + 1
            end
        end
    end
    if p.vitals then
        local v = p.vitals
        local mapping = {
            hp     = v.hp,
            mp     = v.mp,
            max_hp = v.max_hp,
            max_mp = v.max_mp,
            tp     = v.tp,
        }
        for k, val in pairs(mapping) do
            local n = tonumber(val)
            if n and n > 0 then
                state.known[k] = n
                added = added + 1
            end
        end
    end
    return added
end

local function known_count()
    local c = 0
    for _ in pairs(state.known) do c = c + 1 end
    return c
end

-- ── Slash-command dispatch ──────────────────────────────────────────────
windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local args = {...}

    if cmd == 'help' then
        windower.add_to_chat(207, '[CPP] v' .. _addon.version)
        windower.add_to_chat(207, '  //cpp regstats              auto base stats + vitals')
        windower.add_to_chat(207, '  //cpp setstat <pacc> <patt> <aacc> <aatt> <racc> <ratt> <eva> <def>')
        windower.add_to_chat(207, '  //cpp listen / stop')
        windower.add_to_chat(207, '  //cpp report [stable]       per-subtype offset map')
        windower.add_to_chat(207, '  //cpp dump <061|062|063> [n]  hex of last N captures')
        windower.add_to_chat(207, '  //cpp known                 list registered stats')
        windower.add_to_chat(207, '  //cpp clear / status')

    elseif cmd == 'regstats' then
        local n = regstats_auto()
        windower.add_to_chat(207, string.format(
            '[CPP] regstats: %d entries from get_player() (total known: %d)',
            n, known_count()))
        local names = {}
        for k in pairs(state.known) do names[#names+1] = k end
        table.sort(names)
        windower.add_to_chat(207, '[CPP]   ' .. table.concat(names, ', '))

    elseif cmd == 'setstat' then
        -- Accept any of three input styles so users can type whichever
        -- they remember:
        --   (a) 8 positional values:
        --       //cpp setstat 1271 1201 1252 1039 0 0 1139 1197
        --   (b) 8 name/value pairs (16 tokens):
        --       //cpp setstat pacc 1271 patt 1201 ...
        --   (c) single quoted/spaced string (rare Windower edge case)
        local LABELS = {'pacc','patt','aacc','aatt','racc','ratt','eva','def'}
        local LABEL_SET = {}
        for _, l in ipairs(LABELS) do LABEL_SET[l] = true end

        -- Step 1: flatten args. If Windower bundled into one arg with
        -- spaces, split it.
        local tokens = {}
        for _, a in ipairs(args) do
            for tok in tostring(a):gmatch('%S+') do
                tokens[#tokens+1] = tok
            end
        end

        -- Diagnostic so we can see exactly what came through.
        windower.add_to_chat(207, string.format(
            '[CPP] setstat received %d arg(s), %d token(s)', #args, #tokens))

        if #tokens == 0 then
            windower.add_to_chat(123,
                '[CPP] usage: //cpp setstat 1271 1201 1252 1039 0 0 1139 1197')
            return
        end

        local values = {}

        if #tokens == 8 then
            -- (a) positional: 8 numbers in fixed order
            for i, label in ipairs(LABELS) do
                local v = tonumber(tokens[i])
                if not v then
                    windower.add_to_chat(123, string.format(
                        '[CPP] arg %d (%s) = "%s" is not a number',
                        i, label, tokens[i]))
                    return
                end
                values[i] = v
            end
        elseif #tokens == 16 then
            -- (b) name/value pairs: pacc 1271 patt 1201 ...
            -- Build a temp dict first to validate all before committing.
            local seen = {}
            for i = 1, 16, 2 do
                local name = tokens[i]:lower()
                local val  = tonumber(tokens[i+1])
                if not LABEL_SET[name] then
                    windower.add_to_chat(123, string.format(
                        '[CPP] token %d: "%s" is not a valid stat name', i, tokens[i]))
                    windower.add_to_chat(123, string.format(
                        '[CPP] valid: %s', table.concat(LABELS, ', ')))
                    return
                end
                if not val then
                    windower.add_to_chat(123, string.format(
                        '[CPP] token %d (%s value): "%s" is not a number',
                        i+1, name, tokens[i+1]))
                    return
                end
                seen[name] = val
            end
            for i, label in ipairs(LABELS) do
                if seen[label] == nil then
                    windower.add_to_chat(123, string.format(
                        '[CPP] missing stat "%s" in input', label))
                    return
                end
                values[i] = seen[label]
            end
        else
            windower.add_to_chat(123, string.format(
                '[CPP] expected 8 numbers or 16 name/value tokens, got %d', #tokens))
            windower.add_to_chat(123,
                '[CPP] try: //cpp setstat 1271 1201 1252 1039 0 0 1139 1197')
            windower.add_to_chat(123,
                '[CPP] order: pacc patt aacc aatt racc ratt eva def')
            return
        end

        for i, label in ipairs(LABELS) do
            state.known[label] = values[i]
        end
        windower.add_to_chat(207, string.format(
            '[CPP] set 8 combat stats (total known: %d)', known_count()))
        windower.add_to_chat(207, string.format(
            '[CPP]   pacc=%d patt=%d aacc=%d aatt=%d',
            values[1], values[2], values[3], values[4]))
        windower.add_to_chat(207, string.format(
            '[CPP]   racc=%d ratt=%d eva=%d def=%d',
            values[5], values[6], values[7], values[8]))

    elseif cmd == 'known' then
        local names = {}
        for k in pairs(state.known) do names[#names+1] = k end
        if #names == 0 then
            windower.add_to_chat(207, '[CPP] no registered stats. //cpp regstats and //cpp setstat')
            return
        end
        table.sort(names)
        windower.add_to_chat(207, string.format(
            '[CPP] known stats (%d):', #names))
        local line = ''
        for i, nm in ipairs(names) do
            line = line .. string.format('%s=%d  ', nm, state.known[nm])
            if i % 4 == 0 or i == #names then
                windower.add_to_chat(207, '[CPP] ' .. line)
                line = ''
            end
        end

    elseif cmd == 'listen' then
        if not next(state.known) then
            windower.add_to_chat(123, '[CPP] register stats first: //cpp regstats')
            return
        end
        state.listen_enabled = true
        windower.add_to_chat(207,
            '[CPP] listening for 0x061 + 0x062 + 0x063. trigger packets, then //cpp report stable')

    elseif cmd == 'stop' then
        state.listen_enabled = false
        windower.add_to_chat(207, string.format(
            '[CPP] stopped. captured %d packets', #state.captures))

    elseif cmd == 'clear' then
        state.captures = {}
        state.last_hex = { [0x061] = {}, [0x062] = {}, [0x063] = {} }
        state.total_seen = 0
        windower.add_to_chat(207, '[CPP] cleared captures (known stats preserved)')

    elseif cmd == 'report' then
        local stable_only = (args[1] and args[1]:lower() == 'stable')
        if #state.captures == 0 then
            windower.add_to_chat(207, '[CPP] no captures')
            return
        end

        -- Group captures by (id, size, sub). For each group, track
        -- which (offset, encoding, label) tuples appeared and how
        -- many packets they appeared in. "Stable" = appeared in EVERY
        -- packet of the group.
        local groups = {}
        for _, c in ipairs(state.captures) do
            local key = string.format('id=0x%03X sz=%-4d sub=%s',
                c.id, c.size, tostring(c.sub))
            local g = groups[key]
            if not g then
                g = { count = 0, hits = {} }
                groups[key] = g
            end
            g.count = g.count + 1
            -- Per-packet dedup: if the same value appears at the same
            -- offset twice in one packet (shouldn't happen but just in
            -- case), count it once.
            local seen_this_pkt = {}
            for _, h in ipairs(c.hits) do
                local hkey = string.format('off=%-3d enc=%s label=%s',
                    h.offset, h.encoding, h.label)
                if not seen_this_pkt[hkey] then
                    seen_this_pkt[hkey] = true
                    g.hits[hkey] = (g.hits[hkey] or 0) + 1
                end
            end
        end

        local keys = {}
        for k in pairs(groups) do keys[#keys+1] = k end
        table.sort(keys)

        windower.add_to_chat(207, string.format(
            '[CPP] %d packets across %d subtype groups%s',
            #state.captures, #keys,
            stable_only and ' (stable-only)' or ''))

        for _, k in ipairs(keys) do
            local g = groups[k]
            local hkeys = {}
            for hk in pairs(g.hits) do hkeys[#hkeys+1] = hk end
            table.sort(hkeys)

            local hit_lines = {}
            for _, hk in ipairs(hkeys) do
                local cnt = g.hits[hk]
                if not stable_only or cnt == g.count then
                    hit_lines[#hit_lines+1] = string.format(
                        '%s (%d/%d)', hk, cnt, g.count)
                end
            end

            if not stable_only or #hit_lines > 0 then
                windower.add_to_chat(207, string.format(
                    '[CPP] %s   ×%d packets', k, g.count))
                for _, line in ipairs(hit_lines) do
                    windower.add_to_chat(207, '[CPP]   ' .. line)
                end
                if #hit_lines == 0 then
                    windower.add_to_chat(207, '[CPP]   (no hits)')
                end
            end
        end

    elseif cmd == 'dump' then
        if not args[1] then
            windower.add_to_chat(123, '[CPP] usage: //cpp dump <061|062|063> [n]')
            return
        end
        local id_arg = args[1]
        local id = tonumber('0x' .. id_arg) or tonumber(id_arg)
        if not id or not state.last_hex[id] then
            windower.add_to_chat(123, '[CPP] no captures for id ' .. tostring(id_arg))
            return
        end
        local n = tonumber(args[2]) or #state.last_hex[id]
        n = math.min(n, #state.last_hex[id])
        if n == 0 then
            windower.add_to_chat(207, string.format('[CPP] no 0x%03X captures yet', id))
            return
        end
        local start = #state.last_hex[id] - n + 1
        for i = start, #state.last_hex[id] do
            local e = state.last_hex[id][i]
            windower.add_to_chat(207, string.format(
                '[CPP] 0x%03X dump #%d sz=%d sub=%s:',
                id, i, e.size, tostring(e.sub)))
            windower.add_to_chat(207, '[CPP] ' .. e.hex)
        end

    elseif cmd == 'status' then
        windower.add_to_chat(207, string.format(
            '[CPP] listen=%s known=%d total_seen=%d unique=%d',
            state.listen_enabled and 'ON' or 'off',
            known_count(), state.total_seen, #state.captures))

    else
        windower.add_to_chat(123, '[CPP] unknown command: ' .. tostring(cmd))
        windower.add_to_chat(123, '[CPP] try //cpp help')
    end
end)

windower.register_event('load', function()
    windower.add_to_chat(207, string.format(
        '[CPP] v%s loaded — 0x061 + 0x062 + 0x063 offset finder', _addon.version))
    windower.add_to_chat(207, '[CPP] quickstart:')
    windower.add_to_chat(207, '[CPP]   //cpp regstats')
    windower.add_to_chat(207, '[CPP]   //cpp setstat <pacc> <patt> <aacc> <aatt> <racc> <ratt> <eva> <def>')
    windower.add_to_chat(207, '[CPP]   //cpp listen')
    windower.add_to_chat(207, '[CPP]   trigger packets (zone/gear/buff)')
    windower.add_to_chat(207, '[CPP]   //cpp report stable')
end)