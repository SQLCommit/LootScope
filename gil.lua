-- Mob gil attribution: retail pool Gold identifies the mob; message 565 uses kill timing.
-- Hold 565 until a following 566 can cancel a Fields of Valor payout. Share queues with the tracker.

require 'common';
local sunpack = struct.unpack;
local battlefield = require 'battlefield';   -- crate gil buffers into the session

local M = {};

-- Bound by tracker: its table (state + constants) and the private helpers this code shares.
local tracker = nil;
local db = nil;
local unsigned_sid;

function M.bind(deps)
    tracker = deps.tracker;
    unsigned_sid = deps.unsigned_sid;
end
-- Refresh the DB reference on tracker.init; it may change after login.
function M.set_db(ref) db = ref; end

local MOB_GIL_SANE_MAX = 1000000;

local last_565 = nil;      -- { entry = <pending entry> | nil, time = os.clock() }



local GIL_QUEUE_MAX = 50;

-- How long after its kill gil may still be attributed. BOTH carriers must use this one value:
-- record_mob_gil prunes the queue destructively, so a shorter prune silently evicts kills the
-- 565 path can still claim.
local GIL_ATTRIB_WINDOW = 10.0;

-- Forward declaration: book_mob_gil is defined below queue_kill_for_gil but called from it.
local book_mob_gil;

-- Hold pool Gold by mob ID until its kill row arrives or the attribution window expires.
local GIL_HOLD_MAX = 50;

local function prune_gil_hold(now)
    local hold = tracker.mob_gil_hold;
    if (hold == nil) then hold = {}; tracker.mob_gil_hold = hold; end
    local n = 0;
    for sid, h in pairs(hold) do
        if ((now - h.time) > GIL_ATTRIB_WINDOW) then hold[sid] = nil; else n = n + 1; end
    end
    if (n > GIL_HOLD_MAX) then tracker.mob_gil_hold = {}; end   -- runaway: never grow unbounded
    return tracker.mob_gil_hold;
end

local function queue_kill_for_gil(kill_id, mob_sid, mob_name)
    if (kill_id == nil) then return; end
    local now = os.clock();
    local entry = {
        kill_id  = kill_id,
        mob_sid  = mob_sid,
        time     = now,
        mob_name = mob_name,
    };
    tracker.mob_gil_queue[#tracker.mob_gil_queue + 1] = entry;
    while (#tracker.mob_gil_queue > GIL_QUEUE_MAX) do
        table.remove(tracker.mob_gil_queue, 1);
    end
    -- Gold that landed before this kill's row: book it now, through the one write rule.
    local hold = prune_gil_hold(now);
    local held = hold[mob_sid];
    if (held ~= nil) then
        hold[mob_sid] = nil;
        book_mob_gil(entry, held.amount);
    end
end

M.queue_kill_for_gil = queue_kill_for_gil;   -- called by tracker.lua

-- Book gil once per kill across both carriers. Mark queue entries; removing one could
-- attribute a duplicate carrier to the previous kill.
local mob_gil_last = nil;   -- { kill_id, amount, time } -- cross-checks the per-entry mark

book_mob_gil = function(entry, amount)
    if (entry == nil) then return false; end
    if (db == nil or entry.kill_id == nil or amount == nil or amount <= 0) then
        entry.gil_booked = false;                 -- release: this kill may still receive gil
        return false;
    end
    -- gil_booked was set at CLAIM time (a reservation), so it is not a refusal here. Every refusal
    -- below MUST release it, or the kill can never be claimed again.
    if (entry.gil_written) then return false; end
    if (mob_gil_last ~= nil and mob_gil_last.kill_id == entry.kill_id
        and mob_gil_last.amount == amount
        and (os.clock() - mob_gil_last.time) < 15.0) then
        entry.gil_booked = false;                 -- release: a duplicate, not a consumed kill
        return false;
    end
    entry.gil_written = true;
    mob_gil_last = { kill_id = entry.kill_id, amount = amount, time = os.clock() };
    db.record_drop(entry.kill_id, -1, 65535, 'Gil', amount, 1);
    return true;
end

-- Resolve message 565 ownership on arrival; a newer kill may already be queued by frame-time flush.
local function claim_kill_for_gil()
    local now = os.clock();
    for i = #tracker.mob_gil_queue, 1, -1 do
        local e = tracker.mob_gil_queue[i];
        if ((now - e.time) > GIL_ATTRIB_WINDOW) then break; end  -- queue is in kill order
        if (not e.gil_booked) then return e; end
    end
    return nil;                                       -- no recent unbooked kill: DROP, never guess
end

-- Hold for a 565's 566: regimes.lua emits the pair in one server tick, so they land in one packet
-- batch and the hold need only outlive the batch. Raising it adds Live Feed lag on every gil drop.
local FOV_CANCEL_WINDOW = 0.05;

-- A held 565 is gil the player ALREADY HAS (the wallet moved first): every path that discards the
-- list must flush(true) first -- check_zone, reset, unload do. `force` also bypasses the FOV window.
function M.flush_mob_gil(force)
    local held = tracker.pending_mob_gil;
    -- Nil-safe: runs every frame, so a reset that missed the list must not throw per frame.
    if (held == nil) then tracker.pending_mob_gil = {}; return; end
    if (#held == 0) then return; end
    local now = os.clock();
    -- Arrival order: stop at the first entry still inside its window; everything after it is newer.
    local ready = {};
    while (#held > 0 and (force or (now - held[1].time) >= FOV_CANCEL_WINDOW)) do
        ready[#ready + 1] = table.remove(held, 1);
    end
    for i = 1, #ready do
        book_mob_gil(ready[i].owner, ready[i].amount);
    end
end

-- Retail Gold is u16 at 0x0C in 0x00D2. Attribute by mob ID; never guess an unmatched kill.
-- LandSandBoat sends message 565 instead.
local function record_mob_gil(mob_sid, amount)
    if (db == nil or amount == nil or amount <= 0) then return; end
    local now = os.clock();
    while (#tracker.mob_gil_queue > 0 and (now - tracker.mob_gil_queue[1].time) > GIL_ATTRIB_WINDOW) do
        table.remove(tracker.mob_gil_queue, 1);
    end
    for _, e in ipairs(tracker.mob_gil_queue) do
        if (e.mob_sid == mob_sid and e.kill_id ~= nil) then
            book_mob_gil(e, amount);
            return;
        end
    end
    -- Hold unmatched pool gil by mob ID until defeat queues the kill or the attribution window expires.
    local hold = prune_gil_hold(now);
    hold[mob_sid] = { amount = amount, time = now };
end

M.record_mob_gil = record_mob_gil;   -- called by tracker.lua

-- Check the recipient on both 565 and 566; a foreign cancel must not remove the player's pending gil.
local function is_about_me(killer_id)
    local player = GetPlayerEntity();
    local my_sid = (player ~= nil) and unsigned_sid(player.ServerId) or 0;
    return (my_sid ~= 0 and unsigned_sid(killer_id) == my_sid);
end

-- 0x0029 msg 566 (FOV tabs): cancels the 565 it directly follows.
function M.on_tabs(killer_id)
    if (not is_about_me(killer_id)) then return; end
    -- Cancels the 565 this 566 DIRECTLY FOLLOWS -- not the last held entry, which differs whenever
    -- the reward's own 565 was dropped for want of an owner.
    local h = last_565;
    last_565 = nil;
    if (h == nil or h.entry == nil) then return; end
    if ((os.clock() - h.time) > 1.0) then return; end   -- stale: not this 566's 565
    for i = #tracker.pending_mob_gil, 1, -1 do
        if (tracker.pending_mob_gil[i] == h.entry) then
            table.remove(tracker.pending_mob_gil, i);
            -- Release the reservation claim_kill_for_gil() made, or the kill can never receive
            -- gil and a later 565 silently skips to an OLDER kill.
            if (h.entry.owner ~= nil) then h.entry.owner.gil_booked = false; end
            break;
        end
    end
end

-- 0x0029 msg 565: the LSB gil carrier, held for a possible 566.
function M.on_obtains(killer_id, data)
    -- 0x0029 is BROADCAST: check ownership first. DistributeGil sends each member their own share
    -- with actor == target == them.
    if (not is_about_me(killer_id)) then return; end
    -- LSB stores message 565 gil at 0x0C. This offset is unverified on retail, which uses pool Gold.
    -- Reject out-of-range amounts rather than clamping a possible misread.
    local amount = sunpack('I', data, 0x0C + 1);
    -- Record the disposition on every exit: a following 566 must tell "held" from "dropped".
    last_565 = { entry = nil, time = os.clock() };
    if (amount ~= nil and amount > 0 and amount <= MOB_GIL_SANE_MAX) then
        -- Cap: if the frame loop ever stalls, write the backlog out rather than grow it.
        if (#tracker.pending_mob_gil >= 64) then M.flush_mob_gil(true); end
        local owner = claim_kill_for_gil();
        if (owner ~= nil) then
            -- Mark NOW so the next 565 in this same batch cannot claim the same kill.
            owner.gil_booked = true;
            local held = { amount = amount, time = os.clock(), owner = owner };
            tracker.pending_mob_gil[#tracker.pending_mob_gil + 1] = held;
            last_565.entry = held;
        end
    end
end

-- Book crate gil once, or buffer it until the crate row arrives. Consume the wallet update either way.
function M.book_battlefield_gil(amount)
    if (not tracker.battlefield.active or tracker.battlefield.gil_handled) then return false; end
    if (tracker.battlefield.last_kill_id ~= nil) then
        db.record_drop(
            tracker.battlefield.last_kill_id,
            -1,       -- pool_slot: -1 = not a pool item
            65535,    -- item_id: 0xFFFF = gil
            'Gil',
            amount,
            1         -- won: auto-obtained (no lot)
        );
        battlefield.consume_pending_gil();  -- one gil per crate
    else
        battlefield.gil_pending(amount);  -- no kill record yet (0x00D2 has not fired): buffer for later
    end
    tracker.last_gil_update = nil;
    return true;
end

-- Apply buffered crate gil when its row arrives, or to the last kill before session teardown.
function M.flush_battlefield_gil(kill_id)
    if (kill_id == nil or db == nil) then return false; end
    if (tracker.battlefield.pending_gil == nil or tracker.battlefield.gil_handled) then return false; end
    db.record_drop(kill_id, -1, 65535, 'Gil', tracker.battlefield.pending_gil, 1);
    battlefield.consume_pending_gil();
    return true;
end

return M;
