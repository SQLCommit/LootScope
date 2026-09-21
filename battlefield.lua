-- Battlefield session, level cap and crate/gil state. Keep M.state identity stable: the tracker aliases it.

local M = {};

M.state = {
    name = nil,              -- "Shooting Fish", "Under Observation", etc.
    zone_id = nil,           -- Zone when entered
    level_cap = nil,         -- Detected level cap (nil if uncapped/KSNM)
    active = false,          -- Currently in a BCNM?
    cap_check_pending = false,
    last_kill_id = nil,      -- Most recent kill_id from BCNM crate (for gil recording)
    gil_handled = false,     -- Dedup: true when 0x001E/0x0053 already recorded BCNM gil
    pending_gil = nil,       -- Buffered gil amount: when 0x001E/0x0053 fires before 0x00D2
};

-- Transitions

--- Fresh entry (chat text, or a pending entry restored across a zone change). The level cap is
--- UNKNOWN here, so cap polling is armed (cap_check_pending = true) and level_cap starts nil.
function M.begin(name, zone_id, source)
    local s = M.state;
    s.name              = name;
    s.zone_id           = zone_id;
    s.active            = true;
    s.cap_check_pending = true;
    s.level_cap         = nil;
    s.last_kill_id      = nil;
    s.gil_handled       = false;
    s.pending_gil       = nil;
    s.entered_via       = source;
end

--- Restore a session whose cap is already KNOWN (recovered from the DB after a reconnect or an
--- addon reload). Cap polling is NOT armed the cap came with the record.
function M.restore(name, zone_id, level_cap, source)
    local s = M.state;
    s.name        = name;
    s.zone_id     = zone_id;
    s.level_cap   = level_cap;
    s.active      = true;
    s.entered_via = source;
end

--- Recover a session from a chest that appeared with no active one (addon reload after the buff
--- expired, or a reload after the fight ended).
function M.recover(name, zone_id, level_cap, source)
    local s = M.state;
    s.active      = true;
    s.gil_handled = false;
    s.pending_gil = nil;
    s.name        = name;
    s.level_cap   = level_cap;
    s.zone_id     = zone_id;
    s.entered_via = source;
end

--- Gil booked for this crate: latch it, drop the buffer and the kill pointer.
--- because the buffered amount has just been written.
function M.consume_pending_gil()
    local s = M.state;
    s.gil_handled  = true;
    s.pending_gil  = nil;
    s.last_kill_id = nil;
end

--- Clear the session.
function M.exit()
    local s = M.state;
    s.active            = false;
    s.name              = nil;
    s.zone_id           = nil;
    s.level_cap         = nil;
    s.cap_check_pending = false;
    s.last_kill_id      = nil;
    s.gil_handled       = false;
    s.pending_gil       = nil;
    s.entered_via       = nil;
end

--- Cap detected: record it and stop polling.
function M.set_level_cap(cap)   M.state.level_cap = cap; M.state.cap_check_pending = false; end
function M.clear_cap_check()    M.state.cap_check_pending = false; end

function M.note_kill(kill_id)   M.state.last_kill_id = kill_id; end
function M.gil_pending(amount)  M.state.pending_gil = amount; end

-- Readers

function M.is_active()   return M.state.active == true; end
function M.name()        return M.state.name; end
function M.zone_id()     return M.state.zone_id; end
function M.level_cap()   return M.state.level_cap; end

return M;
