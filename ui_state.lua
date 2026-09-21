-- Shared UI palette, filters, analysis state and module references. No addon dependencies.

local state = {};

-- Read settings references per entry point; character resolution replaces state.s.
state.db       = nil;
state.tracker  = nil;
state.s        = nil;
state.analysis = nil;

-- Colour palette
state.COLOR_GREEN       = { 0.3, 1.0, 0.3, 1.0 };
state.COLOR_GREEN_MUTED = { 0.3, 1.0, 0.3, 0.8 };
state.COLOR_RED         = { 1.0, 0.4, 0.4, 1.0 };
state.COLOR_RED_MUTED   = { 1.0, 0.4, 0.4, 0.8 };
state.COLOR_BLUE_MUTED  = { 0.6, 0.8, 1.0, 0.7 };
state.COLOR_WARN        = { 1.0, 0.5, 0.0, 1.0 };
state.COLOR_ERR         = { 1.0, 0.3, 0.3, 1.0 };
state.COLOR_LIGHT_GRAY  = { 0.8, 0.8, 0.8, 1.0 };
state.COLOR_CONTENT     = { 0.5, 0.8, 1.0, 1.0 };
state.COLOR_GRAY        = { 0.7, 0.7, 0.7, 1.0 };
state.COLOR_YELLOW      = { 1.0, 0.9, 0.3, 1.0 };
state.COLOR_CYAN        = { 0.4, 0.9, 1.0, 1.0 };

-- HTBF difficulty badge colors

-- List recorded instance contents alphabetically with counts; share the cache between tabs.
-- Limbus is feed-only and Legion belongs under Battlefields.
local INSTANCE_SFS = { [7] = 'Dynamis', [4] = 'Omen', [13] = 'Einherjar', [14] = 'Nyzul', [15] = 'Salvage',
                       [6] = 'Sortie', [17] = 'Vagary', [19] = 'Assault', [20] = 'Walk of Echoes',
                       [21] = 'Skirmish', [22] = 'Meeble Burrows', [23] = 'Odyssey' };
state.instance_combo = { str = 'All Instances\0\0', sfs = { 9 }, idx_of = { [9] = 0 }, key = nil };

--- Rebuild the combo when the counts change; returns str, sfs, idx_of.
function state.build_instance_combo(db)
    local counts = (db ~= nil and db.get_content_counts ~= nil) and db.get_content_counts() or {};
    local entries, total = {}, 0;
    for sf, name in pairs(INSTANCE_SFS) do
        local n = counts[name] or 0;
        if (n > 0) then entries[#entries + 1] = { sf = sf, name = name, n = n }; total = total + n; end
    end
    table.sort(entries, function(a, b) return a.name < b.name; end);
    local key = tostring(total);
    for _, e in ipairs(entries) do key = key .. '|' .. e.sf .. ':' .. e.n; end
    local ic = state.instance_combo;
    if (ic.key == key) then return ic.str, ic.sfs, ic.idx_of; end
    local parts, sfs, idx_of = { 'All Instances (' .. state.format_count(total) .. ')' }, { 9 }, { [9] = 0 };
    for i, e in ipairs(entries) do
        parts[#parts + 1] = e.name .. ' (' .. state.format_count(e.n) .. ')';
        sfs[#sfs + 1] = e.sf;
        idx_of[e.sf] = i;
    end
    ic.str, ic.sfs, ic.idx_of, ic.key = table.concat(parts, '\0') .. '\0\0', sfs, idx_of, key;
    return ic.str, ic.sfs, ic.idx_of;
end

-- Count battlefield/coffer runs separately from mob kills; HTBF falls back to dimmed kill counts
-- when no crate was recorded.
state.UNIT_BY_SF = { [0] = 'Kills', [1] = 'Opens', [2] = 'Runs', [3] = 'Runs', [8] = 'Runs',
                     [10] = 'Kills', [12] = 'Kills', [20] = 'Runs', [24] = 'Kills / Runs', [25] = 'Runs', [26] = 'Runs' };
function state.unit_label(sf) return state.UNIT_BY_SF[sf] or 'Kills'; end

-- Offered-list contents: a personal list (pyxis, coffer), not a pool roll. Item rows read
-- offered / taken / left instead of a drop rate.
state.OFFERED_LIST_SF = { [10] = true, [20] = true };

-- Slot Analysis state
state.an = {
    category        = 0,       -- 0=Field, 1=Battlefields, 2=Instances
    source_filter   = 0,
    zone_filter     = -1,
    name_filter     = nil,
    mob_filter      = nil,     -- selected mob_name
    mob_level_cap   = nil,     -- for BCNM/HTBF
    effective_sf    = nil,     -- remapped source_filter for All BF entries (2=BCNM, 3=HTBF)
    mob_idx         = { 0 },   -- combo selection index
    result          = nil,     -- analysis.compute() output
    mob_stats       = nil,     -- db.get_mob_stats() for selected mob
    cache_dirty     = true,
    analysis_inited = false,
    analysis_conn   = nil,     -- the db.conn analysis is bound to; re-init when db.conn differs
    ci_sort_col     = 0,
    ci_sort_asc     = false,
    co_sort_col     = 0,
    co_sort_asc     = false,
    -- Filter combo cache (reuses build_stats_filter pattern)
    filter_combo    = { str = '', entries = nil, src = -1 },
    -- Mob combo cache
    mob_combo       = { str = '', mobs = nil, key = '' },
    inst_idx        = { 0 },   -- Instance combo index (Slot Analysis tab)
};

-- Reset confirmation input buffer

-- Instance combo: maps combo index → source_filter value for the dropdown

-- Walk of Echoes coffer rows are stored as 'Treasure Coffer (Walk #N)'; the lists show the walk.
function state.walk_display_name(name)
    if (name == nil) then return ''; end
    local n = name:match('%(Walk #(%d+)%)');
    if (n ~= nil) then return 'Walk #' .. n; end
    if (name:match('^Treasure ?Coffer')) then return 'Walk ?'; end
    return name;
end

-- Shared helper
function state.format_count(n)
    local str = tostring(n);
    if (#str <= 3) then return str; end
    local pos = #str % 3;
    if (pos == 0) then pos = 3; end
    local result = str:sub(1, pos);
    for i = pos + 1, #str, 3 do
        result = result .. ',' .. str:sub(i, i + 2);
    end
    return result;
end

-- Parse "YYYY-MM-DD" to a unix timestamp (start of that day), or nil on bad input.

-- Shared display maps. Pure data (no imgui), read by ui.lua, live feed, statistics and export.

state.source_colors = {
    [0] = { 0.7, 0.7, 0.7, 1.0 },  -- Mob (gray)
    [1] = { 0.6, 0.8, 1.0, 1.0 },  -- Chest (light blue)
    [2] = { 1.0, 0.8, 0.4, 1.0 },  -- Coffer (gold)
    [3] = { 0.8, 0.6, 1.0, 1.0 },  -- BCNM (purple)
};

state.status_colors = {
    [ 1] = { 0.3, 1.0, 0.3, 1.0 },  -- Obtained (green)
    [ 2] = { 1.0, 0.7, 0.2, 1.0 },  -- Dropped / inv full (orange)
    [-1] = { 1.0, 0.3, 0.3, 1.0 },  -- Lost (red)
    [-2] = { 0.4, 0.6, 1.0, 1.0 },  -- Zoned (blue)
    [ 0] = { 0.5, 0.5, 0.5, 1.0 },  -- Pending (gray)
};

state.status_labels = {
    [ 1] = 'Got',
    [ 2] = 'Full',
    [-1] = 'Lost',
    [-2] = 'Zone',
    [ 0] = '--',
};

state.difficulty_colors = {
    [1] = { 1.0, 0.3, 0.3, 1.0 },  -- VD (red)
    [2] = { 1.0, 0.6, 0.2, 1.0 },  -- D (orange)
    [3] = { 1.0, 1.0, 0.4, 1.0 },  -- N (yellow)
    [4] = { 0.4, 1.0, 0.4, 1.0 },  -- E (green)
    [5] = { 0.4, 0.8, 1.0, 1.0 },  -- VE (light blue)
};

return state;
