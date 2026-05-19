-- Bounded ring buffer for chat events.
--
-- Design choices:
--   * Drop-OLDEST on overflow, not drop-newest. Rationale: in a chat
--     stream, the most recent events are always the most relevant.
--     If the drain falls behind (e.g. prerender stalls), we'd rather
--     lose old stuff than newest.
--   * Two rings — text (chat/outgoing/system) and battle (action
--     packets). They're independent: a stalled battle drain (5014)
--     can't slow the text drain (5013), and vice versa. Sizing
--     differs accordingly — text ring is small (rare events), battle
--     ring is large (firehose).
--   * Single drain consumer per ring. drain() returns the contents
--     and resets — the caller is the only thing reading.
--   * No per-entry timestamp tracking in the ring itself. The event
--     payload already carries its own ts; the ring is just storage.
--
-- Lua array semantics: we use a numeric-keyed table with explicit
-- head/tail indices instead of table.insert/remove. table.remove
-- from the front is O(n) — fine for a 256-entry ring but ugly to
-- watch fire 100x/sec under heavy battle load. Head/tail indices
-- give O(1) push and O(n) drain (which we want — we're consuming
-- all of it).

local M = {}

-- Default sizes. emit module sets these via M.new() when it creates
-- the rings; these are just fallbacks for direct unit-test use.
local DEFAULT_TEXT_SIZE   = 256

-- Ring instance constructor. Returns a table with closure-bound
-- push/drain/peek/size methods. Keeping each ring as its own object
-- (rather than a single global with two ring fields) keeps the API
-- symmetric and lets future code create more rings if needed.
function M.new(capacity)
    capacity = capacity or DEFAULT_TEXT_SIZE
    local buf = {}                  -- 1..capacity slots, nil = empty
    local head = 1                  -- next write position
    local count = 0                 -- entries currently held
    local dropped = 0               -- total entries dropped due to overflow
                                    -- across the ring's lifetime (diagnostic)

    local ring = {}

    function ring.push(ev)
        buf[head] = ev
        head = head + 1
        if head > capacity then head = 1 end
        if count < capacity then
            count = count + 1
        else
            -- Overwrote an unread entry. The new event lands at the
            -- slot the oldest entry used to occupy; conceptually the
            -- read pointer moves forward by one. Since we don't track
            -- a read pointer separately (drain consumes everything in
            -- one go), all we need to do is bump the dropped counter.
            dropped = dropped + 1
        end
    end

    -- Snapshot of current contents without modifying the ring.
    -- Used by //ow chatdump diagnostic to peek at the queue.
    -- Returns events in chronological order (oldest first).
    function ring.peek()
        local out = {}
        if count == 0 then return out end
        -- Oldest entry is at (head - count) wrapped into [1..capacity].
        local idx = head - count
        if idx < 1 then idx = idx + capacity end
        for i = 1, count do
            out[i] = buf[idx]
            idx = idx + 1
            if idx > capacity then idx = 1 end
        end
        return out
    end

    -- Pull everything out and empty the ring. Returns events in
    -- chronological order. Called by drain.lua on every 10Hz tick.
    function ring.drain()
        local out = ring.peek()
        -- Clear by reassigning rather than per-slot nil-out: simpler,
        -- and Lua's GC handles the now-orphaned slot table cheaply.
        for i = 1, capacity do buf[i] = nil end
        head = 1
        count = 0
        return out
    end

    function ring.size()      return count   end
    function ring.capacity()  return capacity end
    function ring.dropped()   return dropped end

    -- Reset dropped counter (useful after restarting a session).
    function ring.reset_dropped() dropped = 0 end

    -- Empty the ring and reset all counters. Used by //ow chatreset
    -- to clear the history rings between test scenarios.
    function ring.reset()
        for i = 1, capacity do buf[i] = nil end
        head = 1
        count = 0
        dropped = 0
    end

    return ring
end

-- Module-level convenience: pre-create the text ring at default size.
-- The emit module imports M.text_ring directly. Centralizing creation
-- here means tests can swap it out with a custom-sized ring without
-- touching emit.
M.text_ring   = M.new(DEFAULT_TEXT_SIZE)

-- History ring — populated by drain.lua after events are sent over UDP.
-- Gives //ow chatdump something to show even when the live ring is
-- empty (which it almost always is, since the drain runs at 10Hz and
-- typical chat volume keeps the live ring empty between drains).
--
-- Size tuned for recent-context lookback: 500 lines ~ a few minutes of
-- typical chat. Drops oldest on overflow; old entries are not useful
-- for diagnostics anyway.
M.text_history   = M.new(500)

return M