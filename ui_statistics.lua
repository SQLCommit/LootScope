-- Statistics filters, grouped results and display caches.

require 'common';

local imgui   = require 'imgui';
local chat    = require 'chat';
local state   = require 'ui_state';
local widgets = require 'ui_widgets';

local string_format = string.format;
local tostring      = tostring;

local an           = state.an;
local format_count = state.format_count;
local COLOR_WARN   = state.COLOR_WARN;
local difficulty_colors = state.difficulty_colors;
local display_mob_name  = widgets.display_mob_name;

-- Module refs, refreshed at the entry point.
local db, tracker, s = nil, nil, nil;

local stats_sort_col = 0;
local stats_sort_asc = false;
local stats_zone_filter = -1;  -- -1 = none selected, 0 = all zones
local stats_expanded_mob = nil;  -- mob_name_zone_id key for expanded row
local stats_expanded_spawn_section = {};  -- [mob_key] = true if Per-Spawn section is open
local stats_expanded_spawns = {};  -- [mob_key .. '_' .. server_id] = true if spawn items shown
local stats_cache_data = nil;       -- cached filtered+sorted result
local stats_cache_zone = -1;        -- zone filter when cache was built
local stats_cache_dirty = true;     -- tracks if db.stats_dirty changed
local stats_source_filter = 0;      -- 0=Field, 1=Chest, 2=BCNM, 3=HTBF, 4-7=Omen/Ambu/Sortie/Dynamis, 8=AllBF, 9=AllInst, 10-12=VW/DI/WK, 13-23=instances, 24-26=Reives all/CR/LR
local stats_category = 0;           -- 0=Open World mobs, 1=Battlefields, 2=Instances, 3=Open World events (VW/Reives), 4=Chest/Coffer
local stats_cache_source = -1;      -- source filter when cache was built
local stats_name_filter = nil;       -- name filter for BCNM/Chest-Coffer (nil = all)
local stats_cache_name = nil;        -- name filter when cache was built
local stats_detail_cache = {};       -- [row_key] -> { mob_stats, spawn_stats, spawn_items }

local stats_filter_combo = {
    str = '',
    entries = nil,
    src = -1,
};

local build_instance_combo = state.build_instance_combo;
local unit_label           = state.unit_label;
local walk_display_name    = state.walk_display_name;
local OFFERED_LIST_SF      = state.OFFERED_LIST_SF;

-- Reive sub-filters (24 = every kind together, 12 = Wildskeeper, 25/26 = Colonization/Lair spoils).
local REIVE_SF = { [24] = true, [12] = true, [25] = true, [26] = true };
-- Rows carrying a Content column (aggregates over several contents).
local CONTENT_COL_SF = { [9] = true, [24] = true };

-- Aggregate rows route their detail through their own content's filter (no aggregate detail query).
local ct_to_sf = nil;
local function detail_sf_for(row, sf)
    if (not CONTENT_COL_SF[sf] or row.content_type == nil or row.content_type == '') then return sf; end
    if (ct_to_sf == nil) then
        ct_to_sf = {};
        for k, v in pairs(db.CONTENT_TYPE_MAP) do ct_to_sf[v] = k; end
    end
    return ct_to_sf[row.content_type] or sf;
end

local stats_filter_idx = { 0 };
local stats_inst_idx = { 0 };   -- Instance combo index (Statistics tab)

local function reset_stats_filter(new_source)
    stats_source_filter = new_source;
    stats_cache_dirty = true;
    stats_expanded_mob = nil;
    stats_zone_filter = -1;
    stats_name_filter = nil;
end

local COLOR_GREEN, COLOR_GREEN_MUTED = state.COLOR_GREEN, state.COLOR_GREEN_MUTED;
local COLOR_RED, COLOR_RED_MUTED     = state.COLOR_RED, state.COLOR_RED_MUTED;
local COLOR_BLUE_MUTED, COLOR_WARN   = state.COLOR_BLUE_MUTED, state.COLOR_WARN;
local COLOR_GRAY                     = state.COLOR_GRAY;   -- used by the difficulty-colour fallback (DIFFICULTY_UNKNOWN=6 has no palette entry)
local COLOR_LIGHT_GRAY               = state.COLOR_LIGHT_GRAY;

local function sort_stats(data, col, asc, is_bcnm, is_chest, is_htbf)
    table.sort(data, function(a, b)
        local va, vb;
        if (col == 0) then
            va, vb = a.mob_name, b.mob_name;
        elseif (col == 1) then
            va, vb = a.zone_name, b.zone_name;
        elseif (col == 2) then
            if (is_htbf) then
                va, vb = (a.bf_difficulty or 0), (b.bf_difficulty or 0);
            elseif (is_bcnm) then
                va, vb = (a.level_cap or 999), (b.level_cap or 999);
            else
                va, vb = a.kill_count, b.kill_count;
            end
        elseif (col == 3) then
            if (is_bcnm or is_htbf) then
                -- sort on what the Runs cell DISPLAYS, else clicking the header reorders by a
                -- different (hidden) number than the one on screen
                va, vb = (a.runs or a.kill_count), (b.runs or b.kill_count);
            else
                va, vb = a.unique_items, b.unique_items;
            end
        elseif (col == 4) then
            if (is_chest) then
                va, vb = (a.gil_count or 0), (b.gil_count or 0);
            elseif (is_bcnm or is_htbf) then
                va, vb = a.unique_items, b.unique_items;
            else
                va, vb = (a.unique_spawns or 0), (b.unique_spawns or 0);
            end
        elseif (col == 5) then
            if (is_chest) then
                va, vb = (a.fail_count or 0), (b.fail_count or 0);
            else
                va, vb = a.avg_drops, b.avg_drops;
            end
        elseif (col == 7) then
            va, vb = (a.bf_difficulty or 0), (b.bf_difficulty or 0);
        elseif (col == 8) then
            va, vb = (a.content_type or ''), (b.content_type or '');
        else
            return false;
        end
        if (va == vb) then return false; end
        if asc then return va < vb; else return va > vb; end
    end);
end

-- Append a zone entry once per zone_id.
local function append_unique_zone(entries, seen, row, label)
    if (seen[row.zone_id]) then return; end
    seen[row.zone_id] = true;
    entries:append({ label = label, zone_id = row.zone_id, name = nil });
end

local function build_stats_filter(source_filter)
    -- Rebuild if source changed or data is dirty
    if (stats_filter_combo.src == source_filter
        and stats_filter_combo.entries ~= nil
        and not db.stats_dirty and not stats_cache_dirty) then
        return stats_filter_combo.str, stats_filter_combo.entries;
    end

    local all_stats = db.get_all_mob_stats(source_filter);
    local entries = T{};
    local seen = {};

    if (source_filter == 0) then
        -- Mob: unique zones, sorted by zone_name
        for _, row in ipairs(all_stats) do
            append_unique_zone(entries, seen, row, row.zone_name);
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    elseif (source_filter == 1) then
        -- Chest/Coffer: unique zones (combining chests and coffers per zone)
        for _, row in ipairs(all_stats) do
            append_unique_zone(entries, seen, row, row.zone_name);
        end
        -- Also include zones that only have chest_events (no pool items)
        local chest_stats = db.get_chest_stats();
        for _, row in ipairs(chest_stats) do
            append_unique_zone(entries, seen, row, row.zone_name or '');
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    elseif (source_filter == 2) then
        -- BCNM: unique zone + name combos
        for _, row in ipairs(all_stats) do
            local key = tostring(row.zone_id) .. '_' .. (row.mob_name or '');
            if (not seen[key]) then
                seen[key] = true;
                entries:append({
                    label = row.zone_name .. ' - ' .. row.mob_name,
                    zone_id = row.zone_id,
                    name = row.mob_name,
                });
            end
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    elseif (source_filter == 3) then
        -- HTBF: unique zone + bf_name combos
        for _, row in ipairs(all_stats) do
            local key = tostring(row.zone_id) .. '_' .. (row.mob_name or '');
            if (not seen[key]) then
                seen[key] = true;
                entries:append({
                    label = row.zone_name .. ' - ' .. row.mob_name,
                    zone_id = row.zone_id,
                    name = row.mob_name,
                });
            end
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    else
        -- Content types (instances + events): unique zones
        for _, row in ipairs(all_stats) do
            append_unique_zone(entries, seen, row, row.zone_name);
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    end

    local parts = { 'All' };
    for _, e in ipairs(entries) do
        parts[#parts + 1] = e.label;
    end

    stats_filter_combo.str = table.concat(parts, '\0') .. '\0\0';
    stats_filter_combo.entries = entries;
    stats_filter_combo.src = source_filter;

    return stats_filter_combo.str, stats_filter_combo.entries;
end

--- Runs cell. `row.runs` is the real run count (chest opens) and is only set when the view computed
--- it and the battlefield actually has crates recorded. 
local function render_runs_cell(row)
    imgui.TableNextColumn();
    if (row.runs ~= nil) then
        imgui.Text(tostring(row.runs));
    else
        imgui.TextDisabled(tostring(row.kill_count));
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('No chest opens recorded for this battlefield.\n'
                .. 'Showing kill records instead -- this is NOT a run count.');
        end
    end
end

-- Precompute per-row identity strings once per cache build, mirroring preformat_feed() in
-- ui_live_feed.
local stats_fmt_ref, stats_fmt_mode = nil, nil;
local function preformat_stats(data, mode)
    if (data == stats_fmt_ref and mode == stats_fmt_mode) then return; end
    stats_fmt_ref, stats_fmt_mode = data, mode;
    for _, row in ipairs(data) do
        local d;
        if (mode == 'allbf') then
            d = tostring(row.level_cap or 0) .. '_' .. tostring(row.bf_difficulty or 0);
        elseif (mode == 'htbf') then
            d = tostring(row.bf_difficulty or 0);
        else
            d = tostring(row.level_cap or 'nil');
        end
        if (row.content_type ~= nil and row.content_type ~= '') then d = d .. '_' .. row.content_type; end
        row._disambig = d;
        row._key      = row.mob_name .. '_' .. tostring(row.zone_id) .. '_' .. d;
    end
end

local HELP_OPEN_WORLD = 'Open World\n'
    .. 'Mobs: kills, drops, and nearby drop rates.\n'
    .. 'Voidwatch: Riftworn Pyxis offers, taken items, and items left.\n'
    .. 'Reives: Wildskeeper boss loot, plus Colonization/Lair\n'
    .. 'end rewards counted once per recorded run.\n'
    .. '\n'
    .. 'Combined rates include distant kills and can read high\n'
    .. 'because distant kills without drops may go unseen.';
local HELP_BATTLEFIELDS = 'Battlefields\n'
    .. 'BCNM: loot by battlefield name and level cap.\n'
    .. 'HTBF: loot by battlefield name and difficulty.\n'
    .. 'Legion: loot from each recorded NM kill.\n'
    .. '\n'
    .. 'Runs count recorded crate opens. Where no crate was\n'
    .. 'recorded, dimmed counts show kills instead.';
local HELP_INSTANCES = 'Instances\n'
    .. 'Choose content with recorded data; the number beside\n'
    .. 'its name is the count of recorded kills or reward opens.\n'
    .. 'All Instances keeps different contents separate.\n'
    .. '\n'
    .. 'Walk of Echoes uses coffer offers, taken items, and items left.\n'
    .. 'Ambuscade, Domain Invasion, Limbus, and Besieged are\n'
    .. 'feed-only and do not appear in these statistics.';
local HELP_CHEST = 'Chests and coffers\n'
    .. 'Track item rewards, gil, and failed opening attempts.\n'
    .. 'Illusions appear in the feed but do not count toward\n'
    .. 'opens or success rates.\n'
    .. '\n'
    .. 'Hover gil totals for minimum, maximum, and average amounts.\n'
    .. 'Hover chest events in the Live Feed for estimated\n'
    .. 'respawn countdowns.';

local function render_statistics()
    -- Row 1: where you fight (Open World | Battlefields | Instances) + Chest/Coffer.
    local open_world = (stats_category == 0 or stats_category == 3);
    if imgui.RadioButton('Open World', open_world) then
        stats_category = 0;
        reset_stats_filter(0);
    end
    widgets.help_marker(HELP_OPEN_WORLD);
    imgui.SameLine();
    if imgui.RadioButton('Battlefields', stats_category == 1) then
        stats_category = 1;
        reset_stats_filter(8);  -- default to All Battlefields
    end
    widgets.help_marker(HELP_BATTLEFIELDS);
    imgui.SameLine();
    if imgui.RadioButton('Instances', stats_category == 2) then
        stats_category = 2;
        reset_stats_filter(9);  -- default to All Instances
    end
    widgets.help_marker(HELP_INSTANCES);
    imgui.SameLine();
    if imgui.RadioButton('Chest/Coffer', stats_category == 4) then
        stats_category = 4;
        reset_stats_filter(1);
    end
    widgets.help_marker(HELP_CHEST);

    -- Row 2: the content list for that place
    if (open_world) then
        if imgui.RadioButton('Mobs', stats_category == 0) then
            stats_category = 0;
            reset_stats_filter(0);
        end
        imgui.SameLine();
        if imgui.RadioButton('Voidwatch', stats_category == 3 and stats_source_filter == 10) then
            stats_category = 3;
            reset_stats_filter(10);
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Riftworn Pyxis rewards from recorded Voidwatch NM kills.\nCompare how often items were offered, taken, or left.');
        end
        imgui.SameLine();
        if imgui.RadioButton('Reives', stats_category == 3 and REIVE_SF[stats_source_filter] == true) then
            stats_category = 3;
            reset_stats_filter(24);
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Wildskeeper counts Naakual kills and their rewards.\nColonization and Lair count runs with recorded end rewards.');
        end
        -- Row 3: the Reive kind
        if (stats_category == 3 and REIVE_SF[stats_source_filter]) then
            if imgui.RadioButton('All##rv', stats_source_filter == 24) then reset_stats_filter(24); end
            imgui.SameLine();
            if imgui.RadioButton('Wildskeeper', stats_source_filter == 12) then reset_stats_filter(12); end
            imgui.SameLine();
            if imgui.RadioButton('Colonization', stats_source_filter == 25) then reset_stats_filter(25); end
            imgui.SameLine();
            if imgui.RadioButton('Lair', stats_source_filter == 26) then reset_stats_filter(26); end
        end
    elseif (stats_category == 1) then
        -- Battlefields: All | BCNM | HTBF | Legion
        if imgui.RadioButton('All##bf', stats_source_filter == 8) then
            reset_stats_filter(8);
        end
        imgui.SameLine();
        if imgui.RadioButton('BCNM', stats_source_filter == 2) then
            reset_stats_filter(2);
        end
        imgui.SameLine();
        if imgui.RadioButton('HTBF', stats_source_filter == 3) then
            reset_stats_filter(3);
        end
        imgui.SameLine();
        if imgui.RadioButton('Legion', stats_source_filter == 18) then
            reset_stats_filter(18);
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Loot from recorded Legion NM kills, grouped by mob.\nEach kill counts separately.');
        end
    elseif (stats_category == 2) then
        -- Instances: combo of the contents with data, with counts
        local inst_str, inst_sfs, inst_idx_of = build_instance_combo(db);
        stats_inst_idx[1] = inst_idx_of[stats_source_filter] or 0;
        imgui.PushItemWidth(200);
        if imgui.Combo('##stats_inst', stats_inst_idx, inst_str) then
            local sf = inst_sfs[stats_inst_idx[1] + 1];
            if (sf ~= nil) then
                reset_stats_filter(sf);
            end
        end
        imgui.PopItemWidth();
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Choose an instance with recorded loot history.\nCounts include recorded kills or reward opens, not items.');
        end
    end

    -- Row 3: Zone/battlefield filter combo
    local filter_str, entries = build_stats_filter(stats_source_filter);

    local combo_width = 300;

    local combo_str = 'Filter...\0' .. filter_str;

    -- Map current filter state to combo index
    stats_filter_idx[1] = 0;  -- 0 = placeholder
    if (stats_zone_filter == 0 and stats_name_filter == nil) then
        stats_filter_idx[1] = 1;  -- "All"
    elseif (stats_zone_filter ~= nil and stats_zone_filter > 0) then
        for i, e in ipairs(entries) do
            if (e.zone_id == stats_zone_filter) then
                if (stats_source_filter == 0 or stats_source_filter == 1 or stats_source_filter >= 4 or e.name == stats_name_filter) then
                    stats_filter_idx[1] = i + 1;
                    break;
                end
            end
        end
    end

    imgui.PushItemWidth(combo_width);
    if imgui.Combo('##stats_filter', stats_filter_idx, combo_str) then
        if (stats_filter_idx[1] == 0) then
            stats_zone_filter = -1;
            stats_name_filter = nil;
        elseif (stats_filter_idx[1] == 1) then
            stats_zone_filter = 0;
            stats_name_filter = nil;
        else
            local entry = entries[stats_filter_idx[1] - 1];
            stats_zone_filter = entry.zone_id;
            stats_name_filter = entry.name;
        end
        stats_cache_dirty = true;
    end
    imgui.PopItemWidth();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Select a zone or battlefield to view drop statistics.');
    end

    imgui.Separator();

    -- No filter selected yet
    if (stats_zone_filter == -1) then
        imgui.TextDisabled('Select a filter above to view statistics.');
        return;
    end

    local is_bcnm = (stats_source_filter == 2);
    local is_htbf = (stats_source_filter == 3);
    local is_all_bf = (stats_source_filter == 8);
    local is_chest_mode = (stats_source_filter == 1);
    local is_offer      = (OFFERED_LIST_SF[stats_source_filter] == true);   -- Voidwatch / WoE: a personal list
    local is_woe        = (stats_source_filter == 20);
    local has_content   = (CONTENT_COL_SF[stats_source_filter] == true);    -- All Instances / all Reives
    local unit          = unit_label(stats_source_filter);
    local is_reive_view = (stats_source_filter == 24 or stats_source_filter == 25 or stats_source_filter == 26);

    -- Rebuild cache if data changed, filter changed, or source filter changed
    if (db.stats_dirty or stats_cache_dirty or stats_cache_data == nil
        or stats_cache_zone ~= stats_zone_filter
        or stats_cache_source ~= stats_source_filter
        or stats_cache_name ~= stats_name_filter) then
        local all_stats = db.get_all_mob_stats(stats_source_filter);

        local filtered = T{};
        for _, row in ipairs(all_stats) do
            local zone_ok = (stats_zone_filter == 0 or row.zone_id == stats_zone_filter);
            local name_ok = (stats_name_filter == nil or row.mob_name == stats_name_filter);
            if (zone_ok and name_ok) then
                filtered:append(row);
            end
        end

        sort_stats(filtered, stats_sort_col, stats_sort_asc, is_bcnm or is_all_bf, is_chest_mode, is_htbf);
        stats_cache_data = filtered;
        stats_cache_zone = stats_zone_filter;
        stats_cache_source = stats_source_filter;
        stats_cache_name = stats_name_filter;
        stats_cache_dirty = false;
        stats_detail_cache = {};  -- invalidate detail cache when stats data changes
    end

    -- Chest/Coffer mode merges chest_events into table rows
    local has_pool_data = (stats_cache_data ~= nil and #stats_cache_data > 0);

    if (not has_pool_data) then
        imgui.TextDisabled('No data recorded for this source type.');
        return;
    end

    -- Main stats table (treasure pool items grouped by mob/zone)

    local table_flags = ImGuiTableFlags_Resizable
        + ImGuiTableFlags_RowBg
        + ImGuiTableFlags_BordersInnerV
        + ImGuiTableFlags_SizingFixedFit
        + ImGuiTableFlags_Sortable
        + ImGuiTableFlags_ScrollY;

    local num_cols = (is_all_bf or has_content) and 7 or 6;
    local _a, _b = imgui.GetContentRegionAvail();
    local stats_avail_h = (type(_b) == 'number' and _b) or (type(_a) == 'number' and _a) or 0;
    if (stats_avail_h < 60) then stats_avail_h = 280; end
    if not imgui.BeginTable('stats_table', num_cols, table_flags, { 0, stats_avail_h }) then return; end

    imgui.TableSetupScrollFreeze(0, 1);
    if (is_all_bf) then
        imgui.TableSetupColumn('Battlefield',  ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Lv Cap',       ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 45, 2);
        imgui.TableSetupColumn('Difficulty',   ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 65, 7);
        imgui.TableSetupColumn('Runs',         ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 40, 3);
        imgui.TableSetupColumn('Unique Items', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 80, 4);
        imgui.TableSetupColumn('Avg Drops',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 65, 5);
    elseif (is_htbf) then
        imgui.TableSetupColumn('Battlefield',  ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Difficulty',   ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 65, 2);
        imgui.TableSetupColumn('Runs',         ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 40, 3);
        imgui.TableSetupColumn('Unique Items', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 80, 4);
        imgui.TableSetupColumn('Avg Drops',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 65, 5);
    elseif (is_bcnm) then
        imgui.TableSetupColumn('Battlefield',  ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Lv Cap',       ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 45, 2);
        imgui.TableSetupColumn('Runs',         ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 40, 3);
        imgui.TableSetupColumn('Unique Items', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 80, 4);
        imgui.TableSetupColumn('Avg Drops',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 65, 5);
    elseif (is_chest_mode) then
        imgui.TableSetupColumn('Container',    ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Opens',        ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 50, 2);
        imgui.TableSetupColumn('Items',        ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 45, 3);
        imgui.TableSetupColumn('Gil',          ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 35, 4);
        imgui.TableSetupColumn('Failures',     ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 55, 5);
    elseif (is_woe) then
        imgui.TableSetupColumn('Walk',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Runs',         ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 75, 2);
        imgui.TableSetupColumn('Unique Items', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 80, 3);
        imgui.TableSetupColumn('Offered',      ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 60, 4);
        imgui.TableSetupColumn('Avg Items',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 65, 5);
    else
        imgui.TableSetupColumn(is_reive_view and 'Reive' or 'Mob Name', ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        if (has_content) then
            imgui.TableSetupColumn('Content',  ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 110, 8);
        end
        imgui.TableSetupColumn(unit,           ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, (#unit > 5) and 92 or 75, 2);
        imgui.TableSetupColumn('Unique Items', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 80, 3);
        imgui.TableSetupColumn('Spawns',       ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 50, 4);
        imgui.TableSetupColumn('Avg Drops',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 65, 5);
    end
    imgui.TableHeadersRow();

    -- Handle sort spec changes (re-sort cached data in-place, no DB re-query)
    local sort_specs = imgui.TableGetSortSpecs();
    if sort_specs then
        local spec = sort_specs.Specs;
        if spec then
            local col = spec.ColumnUserID;
            local asc = spec.SortDirection == ImGuiSortDirection_Ascending;
            if (col ~= stats_sort_col or asc ~= stats_sort_asc) then
                stats_sort_col = col;
                stats_sort_asc = asc;
                sort_stats(stats_cache_data, col, asc, is_bcnm or is_all_bf, is_chest_mode, is_htbf);
            end
        end
    end

    preformat_stats(stats_cache_data, is_all_bf and 'allbf' or (is_htbf and 'htbf' or 'other'));
    for _, row in ipairs(stats_cache_data) do
        imgui.TableNextRow();

        -- Precomputed once per cache build by preformat_stats(); pure row identity, unchanged
        -- while the data object and the view mode hold.
        local row_disambig = row._disambig;
        local row_key      = row._key;
        local is_expanded = (stats_expanded_mob == row_key);

        -- Column 1: Mob Name / Battlefield Name
        imgui.TableNextColumn();
        local arrow = is_expanded and 'v ' or '> ';
        local shown_name = is_woe and walk_display_name(row.mob_name) or display_mob_name(row.mob_name);
        if imgui.Selectable(arrow .. shown_name .. '##' .. row_key, is_expanded, ImGuiSelectableFlags_SpanAllColumns) then
            if is_expanded then
                stats_expanded_mob = nil;
            else
                stats_expanded_mob = row_key;
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Click to ' .. (is_expanded and 'collapse' or 'expand') .. ' drop details.');
        end

        -- Column 2: Zone
        imgui.TableNextColumn();
        imgui.Text(row.zone_name);

        if (has_content) then
            imgui.TableNextColumn();
            imgui.TextColored(COLOR_LIGHT_GRAY, row.content_type or '');
        end

        if (is_all_bf) then
            -- Column 3: Level Cap
            imgui.TableNextColumn();
            if (row.level_cap ~= nil and row.level_cap > 0) then
                imgui.Text('Lv' .. tostring(row.level_cap));
            else
                imgui.TextDisabled('--');
            end

            -- Column 4: Difficulty
            imgui.TableNextColumn();
            local abd = row.bf_difficulty or 0;
            if (abd > 0) then
                local dc = difficulty_colors[abd] or COLOR_GRAY;
                imgui.TextColored(dc, tracker.get_difficulty_full_label(abd));
            else
                imgui.TextDisabled('--');
            end

            -- Column 5: Runs
            render_runs_cell(row);

            -- Column 6: Unique Items
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_items));

            -- Column 7: Avg Drops
            imgui.TableNextColumn();
            imgui.Text(string_format('%.1f', row.avg_drops));
        elseif (is_htbf) then
            -- Column 3: Difficulty
            imgui.TableNextColumn();
            local h_diff = row.bf_difficulty or 0;
            if (h_diff > 0) then
                local dc = difficulty_colors[h_diff] or COLOR_GRAY;
                imgui.TextColored(dc, tracker.get_difficulty_full_label(h_diff));
            else
                imgui.TextDisabled('--');
            end

            -- Column 4: Runs (chest opens where known)
            render_runs_cell(row);

            -- Column 5: Unique Items
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_items));

            -- Column 6: Avg Drops
            imgui.TableNextColumn();
            imgui.Text(string_format('%.1f', row.avg_drops));
        elseif (is_bcnm) then
            -- Column 3: Level Cap
            imgui.TableNextColumn();
            if (row.level_cap ~= nil) then
                imgui.Text('Lv' .. tostring(row.level_cap));
            else
                imgui.TextDisabled('--');
            end

            -- Column 4: Runs (chest opens where known)
            render_runs_cell(row);

            -- Column 5: Unique Items
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_items));

            -- Column 6: Avg Drops
            imgui.TableNextColumn();
            imgui.Text(string_format('%.1f', row.avg_drops));
        elseif (is_chest_mode) then
            -- Column 3: Opens (total attempts: pool items + chest events)
            imgui.TableNextColumn();
            imgui.Text(tostring(row.kill_count));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Total opens: item drops + gil + failures.');
            end

            -- Column 4: Items (unique pool items from this container)
            imgui.TableNextColumn();
            if (row.unique_items > 0) then
                imgui.Text(tostring(row.unique_items));
            else
                imgui.TextDisabled('0');
            end

            -- Column 5: Gil (successful gil opens)
            imgui.TableNextColumn();
            local gc = row.gil_count or 0;
            if (gc > 0) then
                imgui.TextColored(COLOR_GREEN, tostring(gc));
                if imgui.IsItemHovered() then
                    local tg = row.total_gil or 0;
                    local avg = gc > 0 and math.floor(tg / gc) or 0;
                    local mn = row.min_gil or 0;
                    local mx = row.max_gil or 0;
                    imgui.SetTooltip(string_format(
                        'Total gil: %s\nMin: %s | Max: %s | Avg: %s',
                        format_count(tg), format_count(mn), format_count(mx), format_count(avg)));
                end
            else
                imgui.TextDisabled('0');
            end

            -- Column 6: Failures (lockpick, trap, mimic — NOT illusions)
            imgui.TableNextColumn();
            local fc = row.fail_count or 0;
            if (fc > 0) then
                imgui.TextColored(COLOR_RED, tostring(fc));
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Lockpick failures, traps, and mimics.\nIllusions are not counted (not a real chest).');
                end
            else
                imgui.TextDisabled('0');
            end
        else
            -- Column 3: Kills (nearby + per-mob distant annotation for Mob view)
            imgui.TableNextColumn();
            local mob_distant = row.distant_kills or 0;
            local nearby_kills = row.kill_count - mob_distant;
            if (mob_distant > 0) then
                imgui.Text(tostring(nearby_kills));
                imgui.SameLine();
                imgui.TextColored(COLOR_BLUE_MUTED, '(+' .. tostring(mob_distant) .. ')');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip(
                        tostring(nearby_kills) .. ' nearby kill(s) + '
                        .. tostring(mob_distant) .. ' distant kill(s) with drops.\n'
                        .. 'Combined total: ' .. tostring(row.kill_count) .. ' kills.\n\n'
                        .. 'Distant kills are detected via treasure pool packets\n'
                        .. '(drops appeared without a prior defeat message).\n'
                        .. 'Note: distant kills with drops are a biased sample.');
                end
            else
                imgui.Text(tostring(row.kill_count));
                if (is_woe and imgui.IsItemHovered()) then
                    imgui.SetTooltip('Coffer opens recorded for this walk (one per walk).');
                elseif (is_reive_view and row.mob_name:match('Reive$') ~= nil and imgui.IsItemHovered()) then
                    imgui.SetTooltip('Reive runs with recorded end spoils.');
                end
            end

            -- Column 4: Unique Items
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_items));

            -- Column 5: Spawns (unique mob server IDs) / Offered (WoE: items the coffers held)
            imgui.TableNextColumn();
            if (is_woe) then
                imgui.Text(tostring(row.drop_count or 0));
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Items offered by the coffer across these runs.');
                end
            else
                imgui.Text(tostring(row.unique_spawns or 0));
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Number of unique spawn IDs for this mob in this zone.');
                end
            end

            -- Column 6: Avg Drops
            imgui.TableNextColumn();
            imgui.Text(string_format('%.1f', row.avg_drops));
        end

        -- Expanded: per-item breakdown + collapsible per-spawn tree
        if is_expanded then
            local detail_cap = is_htbf and row.bf_difficulty or row.level_cap;
            local detail_bf_diff = is_all_bf and (row.bf_difficulty or 0) or nil;
            local detail = stats_detail_cache[row_key];
            if (detail == nil) then
                detail = { mob_stats = db.get_mob_stats(row.mob_name, row.zone_id, detail_sf_for(row, stats_source_filter), detail_cap, detail_bf_diff) };
                stats_detail_cache[row_key] = detail;
            end
            local mob_stats = detail.mob_stats;
            if (mob_stats ~= nil and mob_stats.items ~= nil) then
                local mob_distant = mob_stats.distant_kills or 0;

                for _, item in ipairs(mob_stats.items) do
                    imgui.TableNextRow();

                    imgui.TableNextColumn();
                    -- Chest events: color-coded (green=gil, red=failure)
                    -- Mob gil drops: green (same style as chest gil)
                    if (item.is_chest_event) then
                        local ce_color = (item.times_won > 0)
                            and COLOR_GREEN_MUTED   -- gil = green
                            or  COLOR_RED_MUTED;   -- failure = red
                        imgui.TextColored(ce_color, '    ' .. item.item_name);
                    elseif (item.is_gil_drop) then
                        imgui.TextColored(COLOR_GREEN_MUTED, '    ' .. item.item_name);
                    else
                        imgui.TextDisabled('    ' .. item.item_name);
                    end

                    imgui.TableNextColumn();

                    if (is_bcnm or is_htbf) then
                        imgui.TableNextColumn(); -- lv cap / difficulty
                    elseif (is_all_bf) then
                        imgui.TableNextColumn(); -- lv cap
                        imgui.TableNextColumn(); -- difficulty
                    elseif (has_content) then
                        imgui.TableNextColumn(); -- content
                    end

                    imgui.TableNextColumn();
                    if (is_offer) then
                        -- A personal list: how often it was offered, and what you did with it.
                        local offered = item.times_dropped or 0;
                        local taken   = item.times_won or 0;
                        local left    = item.times_left or 0;
                        local pending = item.times_pending or 0;
                        imgui.TextDisabled(tostring(offered) .. 'x offered');
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip('Times this item was offered in the list.');
                        end
                        imgui.TableNextColumn();
                        imgui.TextColored(COLOR_GREEN_MUTED, tostring(taken) .. ' taken');
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip('Taken from the list.');
                        end
                        imgui.TableNextColumn();
                        if (left > 0 or pending > 0) then
                            local txt = (left > 0) and (tostring(left) .. ' left') or '';
                            if (pending > 0) then txt = txt .. ((txt ~= '') and ', ' or '') .. tostring(pending) .. ' pending'; end
                            imgui.TextColored(COLOR_RED_MUTED, txt);
                            if imgui.IsItemHovered() then
                                imgui.SetTooltip('Left in the list (relinquished or the list closed),\nor still pending (the list is still open).');
                            end
                        end
                        imgui.TableNextColumn();
                    elseif (mob_distant > 0 and item.nearby_times_dropped ~= nil) then
                        local distant_d = item.times_dropped - item.nearby_times_dropped;
                        imgui.TextDisabled(tostring(item.nearby_times_dropped) .. 'x');
                        if (distant_d > 0) then
                            imgui.SameLine(0, 2);
                            imgui.TextColored(COLOR_BLUE_MUTED, '(+' .. tostring(distant_d) .. ')');
                        end
                    else
                        imgui.TextDisabled(tostring(item.times_dropped) .. 'x');
                    end

                    if (not is_offer) then
                    imgui.TableNextColumn();
                    if (item.drop_rate < 0 or item.item_id == 65535) then
                        -- Illusions: no rate (excluded from denominator)
                        -- Gil: no rate (always drops on mobs that give gil)
                        imgui.TextDisabled('--');
                    elseif (mob_distant > 0 and (item.combined_rate or -1) >= 0) then
                        local nearby_k = mob_stats.kills - mob_distant;
                        -- kills that yielded the item, not drop rows (matches the rate's numerator)
                        local nearby_d = item.nearby_kills_with_drop or item.nearby_times_dropped or item.times_dropped;
                        local combined_d = item.kills_with_drop or item.times_dropped;
                        imgui.TextDisabled(string_format('%.1f%%', item.drop_rate));
                        imgui.SameLine();
                        imgui.TextColored(COLOR_BLUE_MUTED, string_format('(%.1f%%)', item.combined_rate));
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(string_format(
                                'Nearby: %d / %d = %.1f%%%%\n'
                                .. 'Combined: %d / %d = %.1f%%%%\n\n'
                                .. 'Includes %d distant kill(s) with drops for this mob.\n'
                                .. 'Distant kills are a biased sample (only seen\n'
                                .. 'because they dropped loot). Nearby rate is unbiased.',
                                nearby_d, nearby_k, item.drop_rate,
                                combined_d, mob_stats.kills, item.combined_rate,
                                mob_distant));
                        end
                    else
                        imgui.TextDisabled(string_format('%.1f%%', item.drop_rate));
                    end

                    if (is_chest_mode) then
                        imgui.TableNextColumn();
                        imgui.TableNextColumn();
                    elseif (not is_bcnm and not is_htbf and not is_all_bf) then
                        imgui.TableNextColumn();
                        imgui.TableNextColumn();
                        if (item.times_dropped > 0 and item.total_qty ~= item.times_dropped) then
                            imgui.TextDisabled('avg ' .. string_format('%.1f', item.total_qty / item.times_dropped));
                        end
                    else
                        imgui.TableNextColumn();
                        if (item.times_dropped > 0 and item.total_qty ~= item.times_dropped) then
                            imgui.TextDisabled('avg ' .. string_format('%.1f', item.total_qty / item.times_dropped));
                        end
                    end
                    end -- not is_offer
                end
            end

            -- Per-spawn breakdown (only for Mob view — not applicable for BF or Chest/Coffer)
            -- Show section when spawn IDs have item drops.
            if (not is_bcnm and not is_htbf and not is_all_bf and not is_chest_mode and not is_offer and not is_reive_view) then
                if (detail.raw_spawn_stats == nil) then
                    detail.raw_spawn_stats = db.get_spawn_stats(row.mob_name, row.zone_id) or {};
                end
                local raw_spawn_stats = detail.raw_spawn_stats;
                local spawn_stats = T{};
                if (raw_spawn_stats ~= nil) then
                    for _, sp in ipairs(raw_spawn_stats) do
                        if (sp.unique_items > 0) then
                            spawn_stats:append(sp);
                        end
                    end
                end
                if (raw_spawn_stats ~= nil and #spawn_stats > 0) then
                    local spawn_section_key = row_key;
                    local spawn_section_open = stats_expanded_spawn_section[spawn_section_key] or false;

                    imgui.TableNextRow();
                    imgui.TableNextColumn();
                    local spawn_arrow = spawn_section_open and '  v ' or '  > ';
                    if imgui.Selectable(spawn_arrow .. 'Per-Spawn (' .. tostring(#spawn_stats) .. ')##spawn_' .. row_key, spawn_section_open) then
                        stats_expanded_spawn_section[spawn_section_key] = not spawn_section_open;
                    end
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Click to ' .. (spawn_section_open and 'collapse' or 'expand') .. ' per-spawn breakdown.');
                    end
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    if (has_content) then imgui.TableNextColumn(); end

                    if spawn_section_open then
                        for _, spawn in ipairs(spawn_stats) do
                            local spawn_id_key = row_key .. '_' .. tostring(spawn.mob_server_id);
                            local spawn_open = stats_expanded_spawns[spawn_id_key] or false;

                            imgui.TableNextRow();
                            imgui.TableNextColumn();
                            local id_arrow = spawn_open and '      v ' or '      > ';
                            if imgui.Selectable(id_arrow .. string_format('ID %.0f', tonumber(spawn.mob_server_id)) .. '##sid_' .. spawn_id_key, spawn_open) then
                                stats_expanded_spawns[spawn_id_key] = not spawn_open;
                            end
                            if imgui.IsItemHovered() then
                                imgui.SetTooltip('Click to ' .. (spawn_open and 'collapse' or 'expand') .. ' item drops for this spawn.');
                            end

                            imgui.TableNextColumn();
                            if (has_content) then imgui.TableNextColumn(); end

                            imgui.TableNextColumn();
                            imgui.TextDisabled(tostring(spawn.kill_count) .. ' kills');

                            imgui.TableNextColumn();
                            imgui.TextDisabled(tostring(spawn.unique_items) .. ' items');

                            imgui.TableNextColumn();

                            imgui.TableNextColumn();
                            imgui.TextDisabled(string_format('%.1f avg', spawn.avg_drops));

                            -- Per spawn item breakdown (deepest level)
                            if spawn_open then
                                local si_key = tostring(spawn.mob_server_id);
                                if (detail.spawn_items == nil) then detail.spawn_items = {}; end
                                if (detail.spawn_items[si_key] == nil) then
                                    detail.spawn_items[si_key] = db.get_spawn_item_stats(row.mob_name, row.zone_id, spawn.mob_server_id);
                                end
                                local spawn_items = detail.spawn_items[si_key];
                                if (#spawn_items > 0) then
                                    for _, si in ipairs(spawn_items) do
                                        imgui.TableNextRow();

                                        imgui.TableNextColumn();
                                        if (si.is_gil_drop) then
                                            imgui.TextColored(COLOR_GREEN_MUTED, '        ' .. si.item_name);
                                        else
                                            imgui.TextDisabled('        ' .. si.item_name);
                                        end

                                        imgui.TableNextColumn();
                                        if (has_content) then imgui.TableNextColumn(); end

                                        imgui.TableNextColumn();
                                        imgui.TextDisabled(tostring(si.times_dropped) .. 'x');

                                        imgui.TableNextColumn();
                                        if (si.is_gil_drop) then
                                            imgui.TextDisabled('--');
                                        else
                                            imgui.TextDisabled(string_format('%.1f%%', si.drop_rate));
                                        end

                                        imgui.TableNextColumn();

                                        imgui.TableNextColumn();
                                        if (not si.is_gil_drop and si.times_dropped > 0 and si.total_qty ~= si.times_dropped) then
                                            imgui.TextDisabled('avg ' .. string_format('%.1f', si.total_qty / si.times_dropped));
                                        end
                                    end
                                else
                                    imgui.TableNextRow();
                                    imgui.TableNextColumn();
                                    imgui.TextDisabled('        No drops recorded.');
                                    imgui.TableNextColumn();
                                    imgui.TableNextColumn();
                                    imgui.TableNextColumn();
                                    imgui.TableNextColumn();
                                    imgui.TableNextColumn();
                                    if (has_content) then imgui.TableNextColumn(); end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    imgui.EndTable();
end

local M = {};

--- Invalidate this tab's aggregate caches. Called by ui.lua when it sees db.stats_dirty, and by
--- anything else that changes what the tables should show.
function M.mark_dirty()
    stats_cache_dirty = true;
end

function M.render()
    db, tracker, s = state.db, state.tracker, state.s;
    return render_statistics();
end

return M;
