-- Resolve content from independent evidence slots in fixed priority order; late stronger signals win.

local classify = require 'classify';

local M = {};

-- State

--- Identity-shared with tracker (same pattern as battlefield.state): tracker aliases this table
--- so existing readers keep working without every call site changing at once.
M.state = {
    session     = nil,
    chat        = nil,
    zone        = nil,
    source      = nil,
    packet      = nil,
    entry_zone  = nil,
};

local function pick(s)
    if (s.session ~= nil) then return s.session, 'session'; end
    if (s.chat    ~= nil) then return s.chat,    'chat';    end
    if (s.zone    ~= nil) then return s.zone,    'zone';    end
    if (s.source  ~= nil) then return s.source,  'source';  end
    if (s.packet  ~= nil) then return s.packet,  'packet';  end
    return nil, nil;
end

-- Writers -- one slot each, unconditional

function M.set(slot, ct)
    if (ct == nil or ct == '') then return; end
    M.state[slot] = ct;
end

function M.set_session(ct)     M.set('session', ct);     end
function M.set_packet(ct)      M.set('packet', ct);      end
function M.set_chat(ct)        M.set('chat', ct);        end
function M.set_source(ct)      M.set('source', ct);      end

function M.set_zone_from(zone_id, zone_name)
    local r = classify.from_zone(zone_id, zone_name);
    M.state.zone = r ~= nil and r.type or nil;
end

function M.set_source_from(zone_id, prev_zone_id)
    M.state.source = classify.from_source_zone(zone_id, prev_zone_id);
end

-- Reader

-- Return an empty string when no content evidence exists.
function M.resolve()
    local v = pick(M.state);
    return v or '';
end

-- Return the evidence slot that supplied the resolved content type.
function M.resolved_by()
    local _, k = pick(M.state);
    return k;
end

-- Clearing

function M.clear_for_zone(new_zone_id, old_zone_id, keep_group)
    local s = M.state;
    s.session     = nil;
    s.chat        = nil;
    s.zone        = nil;
    s.packet      = nil;
    if (keep_group and classify.same_group(new_zone_id, old_zone_id)) then
        return;   -- inner transition: `source` AND the entry zone that produced it both survive
    end
    s.source     = nil;
    s.entry_zone = old_zone_id;
end

function M.end_battlefield()
    local s = M.state;
    s.session = nil; s.chat = nil; s.packet = nil;
end

--- Full reset: character switch, addon unload, /reload.
function M.reset()
    local s = M.state;
    s.session = nil; s.chat = nil; s.zone = nil; s.source = nil;
    s.packet = nil; s.entry_zone = nil;
end

return M;
