--[[
    LootScope v1.0.0 - UI Module
    ImGui dashboard with Live Feed, Statistics, Export, and Settings tabs.
    Includes compact mode for minimal overlay.

    Author: SQLCommit
    Version: 1.0.0
]]--

require 'common';

local imgui = require 'imgui';

local ui = {};

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local math_max = math.max;
local math_min = math.min;
local string_format = string.format;
local os_date = os.date;
local os_clock = os.clock;
local tostring = tostring;

-------------------------------------------------------------------------------
-- Module State
-------------------------------------------------------------------------------
local db = nil;
local tracker = nil;
local s = nil;  -- settings reference

-- UI-local state
local is_open = { true };
local compact_mode = false;
local restore_full_size = false;
local reset_pending = false;
local saved_full_size = nil;     -- { w, h } captured before entering compact
local saved_compact_size = nil;  -- { w, h } captured before entering full
local restore_compact_size = false;

-- Action flags (read by main module)
ui.settings_dirty = false;
ui.export_requested = false;
ui.filtered_export_requested = false;
ui.reset_requested = false;
ui.reset_step = 0;  -- 0=idle, 1=warning, 2=type CONFIRM, 3=final

-- Stats tab state
local stats_sort_col = 0;
local stats_sort_asc = false;
local stats_zone_filter = -1;  -- -1 = none selected, 0 = all zones
local stats_expanded_mob = nil;  -- mob_name_zone_id key for expanded row
local stats_expanded_spawn_section = {};  -- [mob_key] = true if Per-Spawn section is open
local stats_expanded_spawns = {};  -- [mob_key .. '_' .. server_id] = true if spawn items shown
local stats_cache_data = nil;       -- cached filtered+sorted result
local stats_cache_zone = -1;        -- zone filter when cache was built
local stats_cache_dirty = true;     -- tracks if db.stats_dirty changed
local stats_source_filter = 0;      -- 0=Mob, 1=Chest/Coffer, 2=BCNM
local stats_cache_source = -1;      -- source filter when cache was built
local stats_name_filter = nil;       -- name filter for BCNM/Chest-Coffer (nil = all)
local stats_cache_name = nil;        -- name filter when cache was built

-- Zone combo cache (shared by Export tab)
local zone_combo_cache = '';
local zone_combo_zones = nil;

-- Stats filter combo (context-sensitive dropdown per source type)
local stats_filter_combo = {
    str = '',
    entries = nil,
    src = -1,
};

-- Export tab state — consolidated into one table to stay under 60-upvalue limit
local ef = {
    -- Query results
    data            = nil,
    row_count       = 0,
    sort_col        = 0,
    sort_asc        = false,
    show_preview    = { true },
    -- Kill filter widgets
    zone_idx        = { 0 },
    source_idx      = { 0 },       -- 0=All, 1=Mob, 2=Chest, 3=Coffer, 4=BCNM
    mob_buf         = { '' },
    mob_buf_size    = 128,
    th_min          = { 0 },
    mob_sid_buf     = { '' },
    mob_sid_size    = 64,
    -- Time filter widgets
    date_from       = { '' },
    date_from_size  = 16,
    date_to         = { '' },
    date_to_size    = 16,
    -- Vana'diel filter widgets
    weekday_idx     = { 0 },       -- 0=All, 1-8=Firesday..Darksday
    hour_min        = { 0 },
    hour_max        = { 23 },
    moon_phase_idx  = { 0 },       -- 0=All, 1-8=New Moon..Waning Crescent
    weather_idx     = { 0 },       -- 0=All, 1-20=Clear..Darkness
    -- Drop filter widgets
    status_idx      = { 0 },       -- 0=All, 1=Obtained, 2=Inv Full, 3=Lost, 4=Zoned, 5=Pending
    item_buf        = { '' },
    item_buf_size   = 128,
    include_empty   = { true },
    item_id_buf     = { '' },
    item_id_size    = 16,
    winner_buf      = { '' },
    winner_buf_size = 128,
    winner_id_buf   = { '' },
    winner_id_size  = 64,
    player_action_idx = { 0 },     -- 0=All, 1=Lotted, 2=Passed
    -- Chest filters
    chest_result_idx  = { 0 },     -- 0=All, 1=Gil, 2=Lockpick Failed, 3=Trapped, 4=Mimic, 5=Illusion
    -- Killer filter
    killer_buf      = { '' },
    killer_buf_size = 128,
    -- Combo strings and lookup maps
    player_action_combo = 'All\0Lotted\0Passed\0\0',
    player_action_map   = { [0]=nil, [1]=1, [2]=0 },
    PREVIEW_LIMIT   = 100,
    -- UX 4: Active filter summary
    filter_summary  = '',
    -- UX 7: Date validation error flags
    date_from_err   = false,
    date_to_err     = false,
    -- Fix 3: Store last-applied filters for streaming export
    last_filters    = nil,
    -- Auto-update state
    auto_dirty      = false,
    text_dirty      = false,
    text_edit_time  = 0,
};

-- Reset confirmation input buffer
local reset_confirm_buf = { '' };
local reset_confirm_buf_size = 32;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function format_count(n)
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
local function parse_date(str)
    if (str == nil or str == '') then return nil; end
    local y, m, d = str:match('^(%d%d%d%d)-(%d%d)-(%d%d)$');
    if (y == nil) then return nil; end
    local ok, ts = pcall(os.time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 });
    if (not ok) then return nil; end
    return ts;
end

local source_colors = {
    [0] = { 0.7, 0.7, 0.7, 1.0 },  -- Mob (gray)
    [1] = { 0.6, 0.8, 1.0, 1.0 },  -- Chest (light blue)
    [2] = { 1.0, 0.8, 0.4, 1.0 },  -- Coffer (gold)
    [3] = { 0.8, 0.6, 1.0, 1.0 },  -- BCNM (purple)
};

-- Status display: maps DB won values to colors and labels
local status_colors = {
    [ 1] = { 0.3, 1.0, 0.3, 1.0 },  -- Obtained (green)
    [ 2] = { 1.0, 0.7, 0.2, 1.0 },  -- Dropped / inv full (orange)
    [-1] = { 1.0, 0.3, 0.3, 1.0 },  -- Lost (red)
    [-2] = { 0.4, 0.6, 1.0, 1.0 },  -- Zoned (blue)
    [ 0] = { 0.5, 0.5, 0.5, 1.0 },  -- Pending (gray)
};

local status_labels = {
    [ 1] = 'Got',
    [ 2] = 'Full',
    [-1] = 'Lost',
    [-2] = 'Zone',
    [ 0] = '--',
};

-- Reusable color constants for hot render paths (avoid per-frame table allocation)
local COLOR_GREEN       = { 0.3, 1.0, 0.3, 1.0 };
local COLOR_GREEN_MUTED = { 0.3, 1.0, 0.3, 0.8 };
local COLOR_RED         = { 1.0, 0.4, 0.4, 1.0 };
local COLOR_RED_MUTED   = { 1.0, 0.4, 0.4, 0.8 };
local COLOR_BLUE_MUTED  = { 0.6, 0.8, 1.0, 0.7 };
local COLOR_WARN        = { 1.0, 0.5, 0.0, 1.0 };
local COLOR_ERR         = { 1.0, 0.3, 0.3, 1.0 };

local status_tips = {
    [ 1] = 'Got: Item obtained by a player.',
    [ 2] = 'Full: Inventory was full, item lost.',
    [-1] = 'Lost: Nobody lotted in time.',
    [-2] = 'Zone: Player left zone before lotting.',
    [ 0] = 'Pending: Still in treasure pool.',
};

-- Column definitions: ImGui Hideable manages visibility via right-click context menu.
-- DefaultHide columns start hidden but can be toggled on by the user.
local FW = ImGuiTableColumnFlags_WidthFixed;
local FS = ImGuiTableColumnFlags_WidthStretch;
local DH = ImGuiTableColumnFlags_DefaultHide;

local feed_col_defs = {
    { key = 'time',       label = 'Time',    flags = FW,      width = 45,  tip = 'Real time the drop/kill occurred' },
    { key = 'mob',        label = 'Mob',     flags = FS,      width = 0,   tip = 'Name of the defeated enemy or container' },
    { key = 'zone',       label = 'Zone',    flags = FS + DH, width = 0,   tip = 'Zone where the kill happened' },
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 48,  tip = 'Drop source: Mob, Chest, Coffer, or BCNM' },
    { key = 'item',       label = 'Item',    flags = FS,      width = 0,   tip = 'Item that appeared in the treasure pool' },
    { key = 'qty',        label = 'Qty',     flags = FW,      width = 30,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 25,  tip = 'Treasure Hunter level active on the mob' },
    { key = 'status',     label = 'Status',  flags = FW,      width = 35,  tip = 'Won, Lost, or still in pool' },
    { key = 'lot',        label = 'Lot',     flags = FW + DH, width = 30,  tip = 'Winning lot value (0-999)' },
    { key = 'winner',     label = 'Winner',  flags = FS + DH, width = 0,   tip = 'Player who won the item' },
    { key = 'killer',     label = 'Killer',  flags = FW + DH, width = 75,  tip = 'Entity that dealt the killing blow' },
    { key = 'vana_day',   label = 'Day',     flags = FW + DH, width = 75,  tip = "Vana'diel day of the week at time of kill" },
    { key = 'vana_hour',  label = 'V.Hour',  flags = FW + DH, width = 42,  tip = "Vana'diel hour (0-23) at time of kill" },
    { key = 'moon_phase', label = 'Moon',    flags = FW + DH, width = 90,  tip = 'Moon phase at time of kill' },
    { key = 'moon_pct',   label = 'Moon%',   flags = FW + DH, width = 42,  tip = 'Moon illumination percentage (0-100)' },
    { key = 'weather',    label = 'Weather', flags = FW + DH, width = 80,  tip = 'Weather condition at time of kill' },
    { key = 'kill_id',    label = 'Kill ID', flags = FW + DH, width = 40,  tip = 'Database record ID linking drops to their kill' },
    { key = 'mob_id',     label = 'Mob ID',  flags = FW + DH, width = 50,  tip = 'Server entity ID of the defeated mob' },
};

local compact_col_defs = {
    { key = 'time',       label = 'Time',    flags = FW,      width = 38,  tip = 'Real time the drop/kill occurred' },
    { key = 'item',       label = 'Item',    flags = FS,      width = 0,   tip = 'Item that appeared in the treasure pool' },
    { key = 'mob',        label = 'Mob',     flags = FS,      width = 0,   tip = 'Name of the defeated enemy or container' },
    { key = 'zone',       label = 'Zone',    flags = FS + DH, width = 0,   tip = 'Zone where the kill happened' },
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 40,  tip = 'Drop source: Mob, Chest, Coffer, or BCNM' },
    { key = 'qty',        label = 'Qty',     flags = FW + DH, width = 25,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 22,  tip = 'Treasure Hunter level active on the mob' },
    { key = 'status',     label = 'Status',  flags = FW + DH, width = 30,  tip = 'Won, Lost, or still in pool' },
    { key = 'lot',        label = 'Lot',     flags = FW + DH, width = 25,  tip = 'Winning lot value (0-999)' },
    { key = 'winner',     label = 'Winner',  flags = FS + DH, width = 0,   tip = 'Player who won the item' },
    { key = 'killer',     label = 'Killer',  flags = FW + DH, width = 60,  tip = 'Entity that dealt the killing blow' },
    { key = 'vana_day',   label = 'Day',     flags = FW + DH, width = 60,  tip = "Vana'diel day of the week at time of kill" },
    { key = 'vana_hour',  label = 'V.Hour',  flags = FW + DH, width = 35,  tip = "Vana'diel hour (0-23) at time of kill" },
    { key = 'moon_phase', label = 'Moon',    flags = FW + DH, width = 70,  tip = 'Moon phase at time of kill' },
    { key = 'moon_pct',   label = 'Moon%',   flags = FW + DH, width = 35,  tip = 'Moon illumination percentage (0-100)' },
    { key = 'weather',    label = 'Weather', flags = FW + DH, width = 70,  tip = 'Weather condition at time of kill' },
    { key = 'kill_id',    label = 'Kill ID', flags = FW + DH, width = 35,  tip = 'Database record ID linking drops to their kill' },
    { key = 'mob_id',     label = 'Mob ID',  flags = FW + DH, width = 40,  tip = 'Server entity ID of the defeated mob' },
};

-- Export preview column definitions (sortable, with user IDs for sort handler)
local EP_FW  = ImGuiTableColumnFlags_WidthFixed;
local EP_ASC = ImGuiTableColumnFlags_PreferSortAscending;
local EP_DSC = ImGuiTableColumnFlags_PreferSortDescending;
local EP_DEF = ImGuiTableColumnFlags_DefaultSort;
local EP_NH  = ImGuiTableColumnFlags_NoHide;
local EP_DH  = ImGuiTableColumnFlags_DefaultHide;

local export_col_defs = {
    { label = 'Kill',    flags = EP_FW+EP_DSC+EP_DEF+EP_NH, width = 35,  id = 0,  tip = 'Database record ID linking drops to their kill' },
    { label = 'Time',    flags = EP_FW+EP_DSC,              width = 70,  id = 1,  tip = 'Real date/time the kill occurred' },
    { label = 'Mob',     flags = EP_FW+EP_ASC,              width = 100, id = 2,  tip = 'Name of the defeated enemy or container' },
    { label = 'Mob SID', flags = EP_FW+EP_DSC+EP_DH,        width = 50,  id = 3,  tip = 'Server entity ID of the defeated mob' },
    { label = 'Zone',    flags = EP_FW+EP_ASC,              width = 90,  id = 4,  tip = 'Zone where the kill happened' },
    { label = 'ZoneID',  flags = EP_FW+EP_ASC+EP_DH,        width = 38,  id = 5,  tip = 'Numeric zone ID' },
    { label = 'Source',  flags = EP_FW+EP_ASC,              width = 48,  id = 6,  tip = 'Drop source: Mob, Chest, Coffer, or BCNM' },
    { label = 'TH',      flags = EP_FW+EP_DSC,              width = 25,  id = 7,  tip = 'Treasure Hunter level active on the mob' },
    { label = 'Killer',  flags = EP_FW+EP_ASC,              width = 75,  id = 8,  tip = 'Entity that dealt the killing blow' },
    { label = 'TH Act',  flags = EP_FW+EP_ASC+EP_DH,        width = 55,  id = 9,  tip = 'Action type that last procced TH (melee, ranged, spell, etc.)' },
    { label = 'Act ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 10, tip = 'Specific ability/spell ID that procced TH' },
    { label = 'Day',     flags = EP_FW+EP_ASC,              width = 75,  id = 11, tip = "Vana'diel day of the week at time of kill" },
    { label = 'V.Hour',  flags = EP_FW+EP_ASC,              width = 42,  id = 12, tip = "Vana'diel hour (0-23) at time of kill" },
    { label = 'Moon',    flags = EP_FW+EP_ASC,              width = 90,  id = 13, tip = 'Moon phase at time of kill' },
    { label = 'Moon%',   flags = EP_FW+EP_DSC,              width = 42,  id = 14, tip = 'Moon illumination percentage (0-100)' },
    { label = 'Weather', flags = EP_FW+EP_ASC,              width = 80,  id = 15, tip = 'Weather condition at time of kill' },
    { label = 'Item',    flags = EP_FW+EP_ASC,              width = 110, id = 16, tip = 'Item that appeared in the treasure pool' },
    { label = 'ItemID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 17, tip = 'Numeric item ID from the game database' },
    { label = 'Qty',     flags = EP_FW+EP_DSC,              width = 25,  id = 18, tip = 'Quantity of the item dropped' },
    { label = 'Lot',     flags = EP_FW+EP_DSC,              width = 30,  id = 19, tip = 'Winning lot value (0-999)' },
    { label = 'Status',  flags = EP_FW+EP_DSC,              width = 40,  id = 20, tip = 'Won, Lost, Inv Full, Zoned, or Pending' },
    { label = 'Win ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 45,  id = 21, tip = 'Server entity ID of the player who won the item' },
    { label = 'Winner',  flags = EP_FW+EP_ASC,              width = 75,  id = 22, tip = 'Player who won the item' },
    { label = 'P.Lot',   flags = EP_FW+EP_DSC+EP_DH,        width = 35,  id = 23, tip = 'Your lot value on this item' },
    { label = 'P.Act',   flags = EP_FW+EP_DSC+EP_DH,        width = 32,  id = 24, tip = 'Your action: 1=Lotted, 0=Passed' },
    { label = 'Drop At', flags = EP_FW+EP_DSC,              width = 55,  id = 25, tip = 'Time the drop appeared in the treasure pool' },
};

-- Render header row with tooltips from col_defs[].tip
local function render_header_row(col_defs)
    imgui.TableNextRow(ImGuiTableRowFlags_Headers or 0);
    for i, def in ipairs(col_defs) do
        if (imgui.TableSetColumnIndex(i - 1)) then
            imgui.TableHeader(def.label);
            if (def.tip and imgui.IsItemHovered()) then
                imgui.SetTooltip(def.tip);
            end
        end
    end
end

-- Shared zone combo builder (Perf 4)
local function get_zone_combo()
    local zones = db.get_zone_list();
    if (zones == zone_combo_zones) then
        return zone_combo_cache, zones;
    end
    local parts = { 'All Zones' };
    for _, z in ipairs(zones) do
        parts[#parts + 1] = z.zone_name;
    end
    local items = table.concat(parts, '\0') .. '\0\0';
    zone_combo_cache = items;
    zone_combo_zones = zones;
    return items, zones;
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function ui.init(db_ref, tracker_ref, settings_ref)
    db = db_ref;
    tracker = tracker_ref;
    s = settings_ref;
    compact_mode = s.compact_mode or false;
end

function ui.apply_settings(new_s)
    s = new_s;
    if s then
        compact_mode = s.compact_mode or false;
    end
end

function ui.sync_settings()
    if (s == nil) then return; end
    s.compact_mode = compact_mode;
end

-------------------------------------------------------------------------------
-- Helpers: Pre-format timestamps on cached feed data (once per cache rebuild)
-------------------------------------------------------------------------------
local feed_fmt_ref = nil;       -- last-formatted table reference
local compact_fmt_ref = nil;

-- Filtered feed cache (avoids new T{} per frame when filters are active)
local feed_filter_src = nil;    -- raw_feed reference that produced the cached filter
local feed_filter_empty = nil;  -- show_empty value at cache time
local feed_filter_gil = nil;    -- show_gil value at cache time
local feed_filter_cache = nil;  -- the filtered T{} result

-- Filtered compact drops cache
local compact_filter_src = nil;
local compact_filter_gil = nil;
local compact_filter_cache = nil;

local function preformat_feed(feed)
    if (feed == feed_fmt_ref) then return; end
    feed_fmt_ref = feed;
    for _, row in ipairs(feed) do
        local ts = row.ts or row.timestamp or 0;
        row._fmt_hm   = os_date('%H:%M', ts);
        row._fmt_full = os_date('%Y-%m-%d %H:%M:%S', ts);
    end
end

local function preformat_compact(drops)
    if (drops == compact_fmt_ref) then return; end
    compact_fmt_ref = drops;
    for _, row in ipairs(drops) do
        local ts = row.timestamp or 0;
        row._fmt_hm   = os_date('%H:%M', ts);
        row._fmt_hms  = os_date('%H:%M:%S', ts);
    end
end

-------------------------------------------------------------------------------
-- Tab 1: Live Feed
-------------------------------------------------------------------------------
local function render_live_feed()
    local limit = (s ~= nil) and s.feed_max_entries or 100;
    local show_empty = (s ~= nil) and s.show_empty_kills;
    local show_gil   = (s == nil) or (s.show_gil_drops ~= false);

    -- Always use the unified feed (includes kills, drops, AND chest events).
    -- Filter client-side based on settings. Cached to avoid per-frame T{} allocation.
    local raw_feed = db.get_recent_feed(limit);
    local feed;
    if (show_empty and show_gil) then
        feed = raw_feed;
    elseif (raw_feed == feed_filter_src and show_empty == feed_filter_empty and show_gil == feed_filter_gil) then
        feed = feed_filter_cache;
    else
        feed = T{};
        for _, row in ipairs(raw_feed) do
            local dominated = false;
            -- Hide empty kills (no drops at all) when setting is off
            if (not show_empty and row.feed_type == 'kill') then
                dominated = true;
            end
            -- Hide mob gil drops when setting is off (keep chest/BCNM gil)
            if (not show_gil and row.feed_type == 'drop'
                and row.item_id == 65535 and row.source_type == 0) then
                dominated = true;
            end
            if (not dominated) then
                feed:append(row);
            end
        end
        feed_filter_src = raw_feed;
        feed_filter_empty = show_empty;
        feed_filter_gil = show_gil;
        feed_filter_cache = feed;
    end

    if (#feed == 0) then
        imgui.TextDisabled('No activity recorded yet. Kill some mobs!');
        return;
    end

    preformat_feed(feed);

    local table_flags = ImGuiTableFlags_Resizable
        + ImGuiTableFlags_RowBg
        + ImGuiTableFlags_BordersInnerV
        + ImGuiTableFlags_SizingFixedFit
        + ImGuiTableFlags_ScrollY
        + ImGuiTableFlags_Hideable;

    if not imgui.BeginTable('live_feed', #feed_col_defs, table_flags, { 0, 0 }) then return; end

    imgui.TableSetupScrollFreeze(0, 1);
    for _, def in ipairs(feed_col_defs) do
        imgui.TableSetupColumn(def.label, def.flags, def.width);
    end
    render_header_row(feed_col_defs);

    for _, row in ipairs(feed) do
        imgui.TableNextRow();

        local is_empty_kill = (row.feed_type == 'kill');
        local is_chest_event = (row.feed_type == 'chest');

        -- Time (tooltip: Vana'diel time + moon + weather)
        imgui.TableNextColumn();
        imgui.TextDisabled(row._fmt_hm);
        if imgui.IsItemHovered() then
            local tip = row._fmt_full;
            if (row.vana_weekday ~= nil and tonumber(row.vana_weekday) >= 0) then
                tip = tip .. '\n' .. tracker.get_weekday_label(row.vana_weekday);
                local hr = tonumber(row.vana_hour);
                if (hr ~= nil and hr >= 0) then
                    tip = tip .. string_format(' %02d:00', hr);
                end
            end
            local mp = tonumber(row.moon_percent);
            if (mp ~= nil and mp >= 0) then
                local phase_label = '';
                local mph = tonumber(row.moon_phase);
                if (mph ~= nil and mph >= 0) then
                    phase_label = tracker.get_moon_phase_label(mph);
                end
                tip = tip .. '\nMoon: ' .. tostring(math.floor(mp)) .. '% ' .. phase_label;
            end
            local w = tonumber(row.weather);
            if (w ~= nil and w >= 0) then
                tip = tip .. '\nWeather: ' .. tracker.get_weather_label(w);
            end
            imgui.SetTooltip(tip);
        end

        -- Mob (with source type color, tooltip: mob ID + zone)
        imgui.TableNextColumn();
        if (is_chest_event) then
            local ctype_label = tracker.get_container_label(row.container_type);
            local chest_color;
            if (row.chest_result == 0) then
                -- Success (gil): use source_colors for Chest (blue) / Coffer (gold)
                chest_color = source_colors[row.container_type] or source_colors[1];
            else
                -- Failure: red-ish
                chest_color = COLOR_RED;
            end
            imgui.TextColored(chest_color, '[' .. ctype_label .. '] ');
            imgui.SameLine(0, 0);
            local result_label = tracker.get_chest_result_label(row.chest_result);
            if (row.chest_result == 0 and (row.gil_amount or 0) > 0) then
                result_label = tostring(row.gil_amount) .. ' gil';
            end
            imgui.Text(result_label);
            if imgui.IsItemHovered() then
                local tip = '';
                if (row.zone_name ~= nil) then
                    tip = 'Zone: ' .. row.zone_name;
                end
                -- Respawn / illusion timer based on event type and timestamp
                local age = os.time() - (row.ts or 0);
                if (row.chest_result == 0) then
                    -- Gil success: respawn 180s, illusion cooldown 1800-3600s
                    local respawn_left = 180 - age;
                    local illusion_min = 1800 - age;
                    local illusion_max = 3600 - age;
                    if (respawn_left > 0) then
                        tip = tip .. string_format('\nRespawn in: ~%d:%02d', math.floor(respawn_left / 60), respawn_left % 60);
                    else
                        tip = tip .. '\nRespawn: ready (new position)';
                    end
                    if (illusion_max > 0) then
                        if (illusion_min > 0) then
                            tip = tip .. string_format('\nIllusion cooldown: %d:%02d - %d:%02d',
                                math.floor(illusion_min / 60), illusion_min % 60,
                                math.floor(illusion_max / 60), illusion_max % 60);
                        else
                            tip = tip .. string_format('\nIllusion cooldown: 0:00 - %d:%02d',
                                math.floor(illusion_max / 60), illusion_max % 60);
                        end
                    else
                        tip = tip .. '\nIllusion cooldown: expired';
                    end
                elseif (row.chest_result == 1) then
                    tip = tip .. '\nChest still there — try again!';
                elseif (row.chest_result == 2) then
                    -- Trap: respawn 180s
                    local left = 180 - age;
                    if (left > 0) then
                        tip = tip .. string_format('\nRespawn in: ~%d:%02d', math.floor(left / 60), left % 60);
                    else
                        tip = tip .. '\nRespawn: ready (new position)';
                    end
                elseif (row.chest_result == 3) then
                    -- Mimic: immediate respawn (5s)
                    tip = tip .. '\nRespawn: immediate (mimic)';
                elseif (row.chest_result == 4) then
                    -- Illusion: respawn 180s
                    local left = 180 - age;
                    if (left > 0) then
                        tip = tip .. string_format('\nRespawn in: ~%d:%02d', math.floor(left / 60), left % 60);
                    else
                        tip = tip .. '\nRespawn: ready (new position)';
                    end
                end
                imgui.SetTooltip(tip);
            end
        else
            local src_color = source_colors[row.source_type] or source_colors[0];
            local src_label = tracker.get_source_label(row.source_type);
            if (row.source_type ~= 0) then
                imgui.TextColored(src_color, '[' .. src_label .. '] ');
                imgui.SameLine(0, 0);
            end
            imgui.Text(row.mob_name or '');
            if imgui.IsItemHovered() then
                local tip = row.mob_name or '';
                if (row.mob_server_id ~= nil and row.mob_server_id > 0) then
                    tip = tip .. string_format('\nMob ID: %.0f', tonumber(row.mob_server_id));
                end
                if (row.zone_name ~= nil and row.zone_name ~= '') then
                    tip = tip .. '\nZone: ' .. row.zone_name;
                end
                imgui.SetTooltip(tip);
            end
        end

        imgui.TableNextColumn();
        imgui.TextDisabled(row.zone_name or '');

        imgui.TableNextColumn();
        if (is_chest_event) then
            local src_chest_color;
            if (row.chest_result == 0) then
                src_chest_color = source_colors[row.container_type] or source_colors[1];
            else
                src_chest_color = COLOR_RED;
            end
            imgui.TextColored(src_chest_color, tracker.get_container_label(row.container_type));
        else
            local src_c = source_colors[row.source_type] or source_colors[0];
            imgui.TextColored(src_c, tracker.get_source_label(row.source_type));
        end

        -- Item (colored by status, or "No Drop" for empty kills, or chest result)
        imgui.TableNextColumn();
        if (is_chest_event) then
            if (row.chest_result == 0) then
                imgui.TextColored(COLOR_GREEN, 'Gil');
            else
                imgui.TextColored(COLOR_RED, 'Failed');
            end
        elseif (is_empty_kill) then
            imgui.TextDisabled('No Drop');
        else
            local s_color = status_colors[row.won] or status_colors[0];
            imgui.TextColored(s_color, row.item_name or '');
            if imgui.IsItemHovered() and row.item_id ~= nil then
                imgui.SetTooltip('Item ID: ' .. tostring(row.item_id));
            end
        end

        imgui.TableNextColumn();
        if (is_chest_event) then
            if (row.chest_result == 0 and (row.gil_amount or 0) > 0) then
                imgui.Text(tostring(row.gil_amount));
            else
                imgui.TextDisabled('-');
            end
        elseif (is_empty_kill) then
            imgui.TextDisabled('-');
        elseif (row.quantity > 1) then
            imgui.Text(tostring(row.quantity));
        else
            imgui.TextDisabled('1');
        end

        imgui.TableNextColumn();
        if (row.th_level > 0) then
            imgui.Text(tostring(row.th_level));
        else
            imgui.TextDisabled('-');
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Treasure Hunter level on mob at time of kill.');
        end

        imgui.TableNextColumn();
        if (is_chest_event) then
            if (row.chest_result == 0) then
                imgui.TextColored(COLOR_GREEN, 'Gil');
            else
                imgui.TextColored(COLOR_RED, tracker.get_chest_result_label(row.chest_result));
            end
        elseif (is_empty_kill) then
            imgui.TextDisabled('-');
        else
            local s_color = status_colors[row.won] or status_colors[0];
            local s_label = status_labels[row.won] or '--';
            imgui.TextColored(s_color, s_label);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(status_tips[row.won] or 'Unknown status.');
            end
        end

        imgui.TableNextColumn();
        if (is_empty_kill or is_chest_event) then
            imgui.TextDisabled('-');
        elseif ((row.lot_value or 0) > 0) then
            imgui.Text(tostring(row.lot_value));
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        if (is_empty_kill or is_chest_event) then
            imgui.TextDisabled('-');
        elseif (row.winner_name ~= nil and row.winner_name ~= '') then
            imgui.Text(row.winner_name);
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local kname = row.killer_name or '';
        if (kname ~= '') then
            imgui.Text(kname);
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local wd = tonumber(row.vana_weekday);
        if (wd ~= nil and wd >= 0) then
            imgui.Text(tracker.get_weekday_label(wd));
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local hr = tonumber(row.vana_hour);
        if (hr ~= nil and hr >= 0) then
            imgui.Text(string_format('%02d:00', hr));
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local mph = tonumber(row.moon_phase);
        if (mph ~= nil and mph >= 0) then
            imgui.Text(tracker.get_moon_phase_label(mph));
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local mp = tonumber(row.moon_percent);
        if (mp ~= nil and mp >= 0) then
            imgui.Text(tostring(math.floor(mp)) .. '%');
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        local w = tonumber(row.weather);
        if (w ~= nil and w >= 0) then
            imgui.Text(tracker.get_weather_label(w));
        else
            imgui.TextDisabled('-');
        end

        imgui.TableNextColumn();
        imgui.TextDisabled(tostring(row.kill_id or 0));

        imgui.TableNextColumn();
        if ((row.mob_server_id or 0) > 0) then
            imgui.TextDisabled(string_format('%.0f', tonumber(row.mob_server_id)));
        else
            imgui.TextDisabled('-');
        end
    end

    imgui.EndTable();
end

-------------------------------------------------------------------------------
-- Tab 2: Statistics
-------------------------------------------------------------------------------
local function sort_stats(data, col, asc, is_bcnm, is_chest)
    table.sort(data, function(a, b)
        local va, vb;
        if (col == 0) then
            va, vb = a.mob_name, b.mob_name;
        elseif (col == 1) then
            va, vb = a.zone_name, b.zone_name;
        elseif (col == 2) then
            if (is_bcnm) then
                va, vb = (a.level_cap or 999), (b.level_cap or 999);
            else
                va, vb = a.kill_count, b.kill_count;
            end
        elseif (col == 3) then
            if (is_bcnm) then
                va, vb = a.kill_count, b.kill_count;
            else
                va, vb = a.unique_items, b.unique_items;
            end
        elseif (col == 4) then
            if (is_chest) then
                va, vb = (a.gil_count or 0), (b.gil_count or 0);
            elseif (is_bcnm) then
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
        else
            return false;
        end
        if asc then return va < vb; else return va > vb; end
    end);
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
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name, zone_id = row.zone_id, name = nil });
            end
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    elseif (source_filter == 1) then
        -- Chest/Coffer: unique zones (combining chests and coffers per zone)
        for _, row in ipairs(all_stats) do
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name, zone_id = row.zone_id, name = nil });
            end
        end
        -- Also include zones that only have chest_events (no pool items)
        local chest_stats = db.get_chest_stats();
        for _, row in ipairs(chest_stats) do
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name or '', zone_id = row.zone_id, name = nil });
            end
        end
        table.sort(entries, function(a, b) return a.label < b.label; end);
    else
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

local function render_statistics()
    -- Propagate DB dirty flag before anything consumes it
    if (db.stats_dirty) then
        stats_cache_dirty = true;
    end

    -- Build context-sensitive filter combo for current source type
    local filter_str, entries = build_stats_filter(stats_source_filter);

    -- Filter combo (flush-left, no label)
    local placeholder, combo_width;
    if (stats_source_filter == 0) then
        placeholder = 'Select a zone...';
        combo_width = 180;
    elseif (stats_source_filter == 2) then
        placeholder = 'Select a battlefield...';
        combo_width = 280;
    elseif (stats_source_filter == 1) then
        placeholder = 'Select a zone...';
        combo_width = 180;
    else
        placeholder = 'Select a source...';
        combo_width = 250;
    end

    local combo_str = placeholder .. '\0' .. filter_str;

    -- Map current filter state to combo index
    local filter_idx = { 0 };  -- 0 = placeholder
    if (stats_zone_filter == 0 and stats_name_filter == nil) then
        filter_idx[1] = 1;  -- "All"
    elseif (stats_zone_filter ~= nil and stats_zone_filter > 0) then
        for i, e in ipairs(entries) do
            if (e.zone_id == stats_zone_filter) then
                if (stats_source_filter == 0 or stats_source_filter == 1 or e.name == stats_name_filter) then
                    filter_idx[1] = i + 1;
                    break;
                end
            end
        end
    end

    imgui.PushItemWidth(combo_width);
    if imgui.Combo('##stats_filter', filter_idx, combo_str) then
        if (filter_idx[1] == 0) then
            stats_zone_filter = -1;
            stats_name_filter = nil;
        elseif (filter_idx[1] == 1) then
            stats_zone_filter = 0;
            stats_name_filter = nil;
        else
            local entry = entries[filter_idx[1] - 1];
            stats_zone_filter = entry.zone_id;
            stats_name_filter = entry.name;
        end
        stats_cache_dirty = true;
    end
    imgui.PopItemWidth();

    -- Source type radio buttons with per-category tooltips
    imgui.SameLine(); imgui.Spacing(); imgui.SameLine();

    if imgui.RadioButton('Mob', stats_source_filter == 0) then
        stats_source_filter = 0;
        stats_cache_dirty = true;
        stats_expanded_mob = nil;
        stats_zone_filter = -1;
        stats_name_filter = nil;
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Mob Statistics\n'
            .. '------------------------------\n'
            .. 'Nearby Rate = drops from nearby kills / nearby kills\n'
            .. 'Combined Rate = all drops / all kills (blue, biased)\n\n'
            .. 'Edge Cases:\n\n'
            .. '  Distant Kills (blue +N)\n'
            .. '  Kills where drops appeared via treasure pool but\n'
            .. '  no defeat message was received (you were too far).\n'
            .. '  These are a biased sample — only visible because\n'
            .. '  they dropped loot. Shown separately from nearby.\n\n'
            .. '  Missed Kills\n'
            .. '  Zone-level "too far" kills with no drops. Cannot\n'
            .. '  be attributed to a specific mob. Informational only.\n\n'
            .. '  Addon Reload Mid-Pool\n'
            .. '  Active pool items are reconnected to existing\n'
            .. '  DB records on reload. If no match is found,\n'
            .. '  items are tracked but do not inflate kill counts.\n\n'
            .. '  Late Loot (zone-in after kill)\n'
            .. '  Pool items received after zoning in are matched\n'
            .. '  to prior records when possible. Unmatched items\n'
            .. '  appear in Live Feed but do not affect stats.');
    end

    imgui.SameLine();
    if imgui.RadioButton('BCNM', stats_source_filter == 2) then
        stats_source_filter = 2;
        stats_cache_dirty = true;
        stats_expanded_mob = nil;
        stats_zone_filter = -1;
        stats_name_filter = nil;
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'BCNM Statistics\n'
            .. '------------------------------\n'
            .. 'Groups by battlefield name, not mob name\n'
            .. '(all BCNM drops come from Armoury Crate).\n\n'
            .. '  BCNM Name Detection\n'
            .. '  Captured from "Entering the battlefield for X!"\n'
            .. '  chat message on entry.\n\n'
            .. '  Level Cap\n'
            .. '  Detected by comparing job level before and after\n'
            .. '  entry. KSNMs show no cap (uncapped).\n\n'
            .. '  Addon Reload Recovery\n'
            .. '  Battlefield session persisted to DB. On reload,\n'
            .. '  buff icon 254 confirms active BCNM, name\n'
            .. '  recovered from DB.\n\n'
            .. '  Pre-Feature Data\n'
            .. '  Data recorded before this feature shows as\n'
            .. '  "Unknown BCNM" with zone name.');
    end

    imgui.SameLine();
    if imgui.RadioButton('Chest/Coffer', stats_source_filter == 1) then
        stats_source_filter = 1;
        stats_cache_dirty = true;
        stats_expanded_mob = nil;
        stats_zone_filter = -1;
        stats_name_filter = nil;
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Chest & Coffer Statistics\n'
            .. '------------------------------\n'
            .. 'Tracks Treasure Chests and Treasure Coffers.\n\n'
            .. '  Item Drops (via treasure pool)\n'
            .. '  Tracked automatically when items enter pool.\n\n'
            .. '  Failures & Gil (via chat + entity detection)\n'
            .. '  Lockpick failures, traps, mimics, and gil rewards\n'
            .. '  detected from chat messages.\n'
            .. '  Gil column tooltip shows min/max/avg amounts.\n\n'
            .. '  Illusions\n'
            .. '  Illusions are recorded but NOT counted toward\n'
            .. '  opens or percentages (not a real chest).\n\n'
            .. '  Container Detection\n'
            .. '  31 of 38 zones have only one type (instant).\n'
            .. '  7 dual zones use entity name scan to distinguish\n'
            .. '  chests vs coffers.\n\n'
            .. '  Respawn Timers\n'
            .. '  Hover chest events in Live Feed for countdown\n'
            .. '  timers (respawn ~3min, illusion 30-60min).');
    end

    imgui.Separator();

    -- No filter selected yet
    if (stats_zone_filter == -1) then
        imgui.TextDisabled('Select a filter above to view statistics.');
        return;
    end

    local is_bcnm = (stats_source_filter == 2);
    local is_chest_mode = (stats_source_filter == 1);

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

        sort_stats(filtered, stats_sort_col, stats_sort_asc, is_bcnm, is_chest_mode);
        stats_cache_data = filtered;
        stats_cache_zone = stats_zone_filter;
        stats_cache_source = stats_source_filter;
        stats_cache_name = stats_name_filter;
        stats_cache_dirty = false;
    end

    -- For Chest/Coffer mode, chest_events are merged into the main table rows
    -- so we always have data if any chest activity occurred.
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

    -- BCNM view:   Battlefield | Zone | Lv Cap  | Runs  | Unique Items | Avg Drops
    -- Chest view:  Container   | Zone | Opens   | Items | Gil          | Failures
    -- Mob view:    Mob Name    | Zone | Kills   | Unique Items | Spawns | Avg Drops
    local num_cols = 6;
    if not imgui.BeginTable('stats_table', num_cols, table_flags, { 0, 0 }) then return; end

    imgui.TableSetupScrollFreeze(0, 1);
    if (is_bcnm) then
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
    else
        imgui.TableSetupColumn('Mob Name',     ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        imgui.TableSetupColumn('Zone',         ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 1);
        imgui.TableSetupColumn('Kills',        ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 75, 2);
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
                sort_stats(stats_cache_data, col, asc, is_bcnm, is_chest_mode);
            end
        end
    end

    for _, row in ipairs(stats_cache_data) do
        imgui.TableNextRow();

        local row_key = row.mob_name .. '_' .. tostring(row.zone_id) .. '_' .. tostring(row.level_cap or 'nil');
        local is_expanded = (stats_expanded_mob == row_key);

        -- Column 1: Mob Name / Battlefield Name
        imgui.TableNextColumn();
        local arrow = is_expanded and 'v ' or '> ';
        if imgui.Selectable(arrow .. row.mob_name .. '##' .. row_key, is_expanded, ImGuiSelectableFlags_SpanAllColumns) then
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

        if (is_bcnm) then
            -- Column 3: Level Cap
            imgui.TableNextColumn();
            if (row.level_cap ~= nil) then
                imgui.Text('Lv' .. tostring(row.level_cap));
            else
                imgui.TextDisabled('--');
            end

            -- Column 4: Runs (kill_count)
            imgui.TableNextColumn();
            imgui.Text(tostring(row.kill_count));

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
            end

            -- Column 4: Unique Items
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_items));

            -- Column 5: Spawns (unique mob server IDs)
            imgui.TableNextColumn();
            imgui.Text(tostring(row.unique_spawns or 0));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Number of unique spawn IDs for this mob in this zone.');
            end

            -- Column 6: Avg Drops
            imgui.TableNextColumn();
            imgui.Text(string_format('%.1f', row.avg_drops));
        end

        -- Expanded: per-item breakdown + collapsible per-spawn tree
        if is_expanded then
            local mob_stats = db.get_mob_stats(row.mob_name, row.zone_id, stats_source_filter, row.level_cap);
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

                    if (is_bcnm) then
                        imgui.TableNextColumn(); -- lv cap
                    end

                    imgui.TableNextColumn();
                    imgui.TextDisabled(tostring(item.times_dropped) .. 'x');

                    imgui.TableNextColumn();
                    if (item.drop_rate < 0 or item.item_id == 65535) then
                        -- Illusions: no rate (excluded from denominator)
                        -- Gil: no rate (always drops on mobs that give gil)
                        imgui.TextDisabled('--');
                    elseif (mob_distant > 0 and (item.combined_rate or -1) >= 0) then
                        local nearby_k = mob_stats.kills - mob_distant;
                        local nearby_d = item.nearby_times_dropped or item.times_dropped;
                        imgui.TextDisabled(string_format('%.1f%%', item.drop_rate));
                        imgui.SameLine();
                        imgui.TextColored(COLOR_BLUE_MUTED, string_format('(%.1f%%)', item.combined_rate));
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(string_format(
                                'Nearby: %d / %d = %.1f%%\n'
                                .. 'Combined: %d / %d = %.1f%%\n\n'
                                .. 'Includes %d distant kill(s) with drops for this mob.\n'
                                .. 'Distant kills are a biased sample (only seen\n'
                                .. 'because they dropped loot). Nearby rate is unbiased.',
                                nearby_d, nearby_k, item.drop_rate,
                                item.times_dropped, mob_stats.kills, item.combined_rate,
                                mob_distant));
                        end
                    else
                        imgui.TextDisabled(string_format('%.1f%%', item.drop_rate));
                    end

                    if (is_chest_mode) then
                        imgui.TableNextColumn();
                        imgui.TableNextColumn();
                    elseif (not is_bcnm) then
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
                end
            end

            -- Per-spawn breakdown (only for Mob view — not applicable for BCNM or Chest/Coffer)
            -- Show section when multiple spawn IDs exist (raw count).
            -- Hide individual spawns that only have gil drops (0 unique items).
            if (not is_bcnm and not is_chest_mode) then
                local raw_spawn_stats = db.get_spawn_stats(row.mob_name, row.zone_id);
                local spawn_stats = T{};
                if (raw_spawn_stats ~= nil) then
                    for _, sp in ipairs(raw_spawn_stats) do
                        if (sp.unique_items > 0) then
                            spawn_stats:append(sp);
                        end
                    end
                end
                if (raw_spawn_stats ~= nil and #raw_spawn_stats > 1 and #spawn_stats > 0) then
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

                            imgui.TableNextColumn();
                            imgui.TextDisabled(tostring(spawn.kill_count) .. ' kills');

                            imgui.TableNextColumn();
                            imgui.TextDisabled(tostring(spawn.unique_items) .. ' items');

                            imgui.TableNextColumn();

                            imgui.TableNextColumn();
                            imgui.TextDisabled(string_format('%.1f avg', spawn.avg_drops));

                            -- Per-spawn item breakdown (deepest level)
                            if spawn_open then
                                local spawn_items = db.get_spawn_item_stats(row.mob_name, row.zone_id, spawn.mob_server_id);
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

-------------------------------------------------------------------------------
-- Tab 3: Export
-------------------------------------------------------------------------------
local advanced_export_open = { false };
local db_size_cache = 0;
local export_tab_was_open = false;

-- Static lookup tables for apply_filters (allocated once, never recreated)
local af_status_map = { [0] = nil, [1] = 1, [2] = 2, [3] = -1, [4] = -2, [5] = 0 };
local af_status_labels = { [0] = nil, [1] = 'Obtained', [2] = 'Inv Full', [3] = 'Lost', [4] = 'Zoned', [5] = 'Pending' };
local af_weekday_names = { 'Firesday', 'Earthsday', 'Watersday', 'Windsday', 'Iceday', 'Lightningday', 'Lightsday', 'Darksday' };
local af_moon_raw_map = {
    { 0, 0 },    -- New Moon
    { 1, 2 },    -- Waxing Crescent
    { 3, 3 },    -- First Quarter
    { 4, 5 },    -- Waxing Gibbous
    { 6, 6 },    -- Full Moon
    { 7, 8 },    -- Waning Gibbous
    { 9, 9 },    -- Last Quarter
    { 10, 11 },  -- Waning Crescent
};
local af_moon_names = { 'New Moon', 'Waxing Crescent', 'First Quarter', 'Waxing Gibbous', 'Full Moon', 'Waning Gibbous', 'Last Quarter', 'Waning Crescent' };
local af_chest_result_labels_c = { [1] = 'Gil', [2] = 'Lockpick Failed', [3] = 'Trapped', [4] = 'Mimic', [5] = 'Illusion' };

local function apply_filters()
    local apply_zones = db.get_zone_list();
    local zone_id = -1;
    if (ef.zone_idx[1] > 0 and ef.zone_idx[1] <= #apply_zones) then
        zone_id = apply_zones[ef.zone_idx[1]].zone_id;
    end

    -- CQ 4: nil instead of -1 for unfiltered source
    -- Combo: 0=All, 1=Mob(0), 2=Chest/Coffer(1+2), 3=BCNM(3)
    local source_type = nil;
    local source_type_list = nil;  -- for multi-value filter (chest+coffer)
    if (ef.source_idx[1] == 1) then
        source_type = 0;   -- Mob
    elseif (ef.source_idx[1] == 2) then
        source_type_list = { 1, 2 };  -- Chest + Coffer
    elseif (ef.source_idx[1] == 3) then
        source_type = 3;   -- BCNM
    end

    local status = af_status_map[ef.status_idx[1]];

    -- UX 7: Date validation
    local date_from = parse_date(ef.date_from[1]);
    local date_to   = parse_date(ef.date_to[1]);
    ef.date_from_err = (ef.date_from[1] ~= '' and date_from == nil);
    ef.date_to_err = (ef.date_to[1] ~= '' and date_to == nil);
    -- date_to should be end-of-day (23:59:59)
    if (date_to ~= nil) then date_to = date_to + 86399; end

    -- Weekday: combo idx 0=All, 1-8 maps to DB values 0-7
    local weekday = nil;
    if (ef.weekday_idx[1] > 0) then
        weekday = ef.weekday_idx[1] - 1;
    end

    -- Moon phase: combo idx 0=All, 1-8 maps to client raw values 0-11
    local moon_phase = nil;
    local moon_phase_max = nil;
    if (ef.moon_phase_idx[1] > 0 and af_moon_raw_map[ef.moon_phase_idx[1]]) then
        moon_phase = af_moon_raw_map[ef.moon_phase_idx[1]][1];
        moon_phase_max = af_moon_raw_map[ef.moon_phase_idx[1]][2];
    end

    -- Hour range: only apply if not full range
    local hour_min = nil;
    local hour_max = nil;
    if (ef.hour_min[1] > 0 or ef.hour_max[1] < 23) then
        hour_min = ef.hour_min[1];
        hour_max = ef.hour_max[1];
    end

    -- Weather: combo idx 0=All, 1-20 maps to DB values 0-19
    local weather = nil;
    if (ef.weather_idx[1] > 0) then
        weather = ef.weather_idx[1] - 1;
    end

    -- Parse number-from-text helpers
    local mob_sid     = tonumber(ef.mob_sid_buf[1]);
    local item_id     = tonumber(ef.item_id_buf[1]);
    local winner_id   = tonumber(ef.winner_id_buf[1]);

    -- Player action
    local player_action = ef.player_action_map[ef.player_action_idx[1]];

    -- Chest result: idx 0=All, 1=Gil(0), 2=Lockpick(1), 3=Trapped(2), 4=Mimic(3), 5=Illusion(4)
    local chest_result = nil;
    if (ef.chest_result_idx[1] > 0) then
        chest_result = ef.chest_result_idx[1] - 1;
    end

    local filters = {
        -- Kill filters
        zone_id         = zone_id,
        source_type     = source_type,
        source_type_list = source_type_list,
        mob_search      = ef.mob_buf[1] or '',
        th_min          = ef.th_min[1],
        mob_sid         = mob_sid,
        killer_search   = ef.killer_buf[1] or '',
        -- Time filters
        date_from       = date_from,
        date_to         = date_to,
        -- Vana'diel filters
        weekday         = weekday,
        hour_min        = hour_min,
        hour_max        = hour_max,
        moon_phase      = moon_phase,
        moon_phase_max  = moon_phase_max,
        weather         = weather,
        -- Drop filters
        item_search     = ef.item_buf[1] or '',
        status          = status,
        include_empty   = ef.include_empty[1],
        item_id         = item_id,
        winner_search   = ef.winner_buf[1] or '',
        winner_id       = winner_id,
        player_action   = player_action,
        -- Chest filters
        chest_result    = chest_result,
    };

    -- Fix 3: Store filters for streaming export, use COUNT + LIMIT
    ef.last_filters = filters;
    ef.row_count = db.get_filtered_export_count(filters);
    ef.data = db.get_filtered_export(filters, ef.PREVIEW_LIMIT);
    ef.sort_col = 0;
    ef.sort_asc = false;

    -- UX 3: Auto-show preview after Apply
    ef.show_preview[1] = true;

    -- Perf 5: Pre-format timestamps
    for _, row in ipairs(ef.data) do
        row._fmt_time = os_date('%m/%d %H:%M', row.timestamp or 0);
        row._fmt_full = os_date('%Y-%m-%d %H:%M:%S', row.timestamp or 0);
        row._fmt_drop = (row.drop_timestamp and row.drop_timestamp > 0)
            and os_date('%H:%M:%S', row.drop_timestamp) or '-';
    end

    -- UX 4: Active filter summary
    local parts = {};
    if (zone_id >= 0 and ef.zone_idx[1] <= #apply_zones) then
        parts[#parts + 1] = 'Zone: ' .. apply_zones[ef.zone_idx[1]].zone_name;
    end
    if (source_type_list ~= nil) then
        parts[#parts + 1] = 'Source: Chest/Coffer';
    elseif (source_type ~= nil) then
        parts[#parts + 1] = 'Source: ' .. tracker.get_source_label(source_type);
    end
    if (ef.mob_buf[1] ~= nil and ef.mob_buf[1] ~= '') then
        parts[#parts + 1] = 'Mob: "' .. ef.mob_buf[1] .. '"';
    end
    if (ef.th_min[1] > 0) then
        parts[#parts + 1] = 'TH>=' .. tostring(ef.th_min[1]);
    end
    if (ef.killer_buf[1] ~= nil and ef.killer_buf[1] ~= '') then
        parts[#parts + 1] = 'Killer: "' .. ef.killer_buf[1] .. '"';
    end
    if (ef.date_from[1] ~= '') then parts[#parts + 1] = 'From: ' .. ef.date_from[1]; end
    if (ef.date_to[1] ~= '') then parts[#parts + 1] = 'To: ' .. ef.date_to[1]; end
    if (weekday ~= nil) then parts[#parts + 1] = af_weekday_names[weekday + 1] or '?'; end
    if (moon_phase ~= nil) then parts[#parts + 1] = af_moon_names[ef.moon_phase_idx[1]] or '?'; end
    if (weather ~= nil) then parts[#parts + 1] = 'Weather: ' .. tracker.get_weather_label(weather); end
    if (ef.item_buf[1] ~= nil and ef.item_buf[1] ~= '') then
        parts[#parts + 1] = 'Item: "' .. ef.item_buf[1] .. '"';
    end
    if (af_status_labels[ef.status_idx[1]] ~= nil) then
        parts[#parts + 1] = 'Status: ' .. af_status_labels[ef.status_idx[1]];
    end
    if (ef.include_empty[1]) then parts[#parts + 1] = '+Empty kills'; end
    if (af_chest_result_labels_c[ef.chest_result_idx[1]] ~= nil) then
        parts[#parts + 1] = 'Result: ' .. af_chest_result_labels_c[ef.chest_result_idx[1]];
    end
    ef.filter_summary = #parts > 0 and table.concat(parts, ' | ') or 'No filters';
end

local function render_advanced_export_window()
    if (not advanced_export_open[1]) then return; end

    imgui.SetNextWindowSize({ 750, 580 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Advanced Export##ls', advanced_export_open, ImGuiWindowFlags_NoScrollbar + ImGuiWindowFlags_NoScrollWithMouse) then

        -- Scrollable content area (reserve 30px for bottom buttons)
        if imgui.BeginChild('##adv_export_content', { 0, -30 }) then

            -- Proportional layout columns with min floors and max caps
            local cw = imgui.GetContentRegionAvail();
            local col1 = math_min(math_max(cw * 0.12, 65), 85);
            local col2_label = math_min(math_max(cw * 0.48, 235), 330);
            local col2 = math_min(math_max(cw * 0.62, 310), 415);
            local w1 = math_min(math_max(col2_label - col1 - 20, 110), 230);
            local w2 = math_min(math_max(cw - col2 - 8, 80), 200);

            -- Quick Filters (always visible)
            imgui.TextDisabled('Filters');
            imgui.Separator();

            -- Row 1: Zone + Source
            local exp_zone_items = get_zone_combo();
            imgui.Text('Zone:');
            imgui.SameLine(col1);
            imgui.PushItemWidth(w1);
            if imgui.Combo('##exp_zone', ef.zone_idx, exp_zone_items) then ef.auto_dirty = true; end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Filter by zone where kills occurred.');
            end

            imgui.SameLine(col2_label);
            imgui.Text('Source:');
            imgui.SameLine(col2);
            imgui.PushItemWidth(w2);
            if imgui.Combo('##exp_source', ef.source_idx, 'All\0Mob\0Chest/Coffer\0BCNM\0\0') then
                ef.auto_dirty = true;
            end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Filter by source type (Mob, Chest/Coffer, BCNM).');
            end

            -- Row 2: Mob + Item
            imgui.Text('Mob:');
            imgui.SameLine(col1);
            imgui.PushItemWidth(w1);
            imgui.InputTextWithHint('##exp_mob', 'Filter by mob...', ef.mob_buf, ef.mob_buf_size);
            if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Search by mob or battlefield name (partial match).');
            end

            imgui.SameLine(col2_label);
            imgui.Text('Item:');
            imgui.SameLine(col2);
            imgui.PushItemWidth(w2);
            imgui.InputTextWithHint('##exp_item', 'Filter by item...', ef.item_buf, ef.item_buf_size);
            if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Search by item name (partial match).');
            end

            -- Row 3: TH Min + Status
            imgui.Text('TH Min:');
            imgui.SameLine(col1);
            imgui.PushItemWidth(w1);
            imgui.SliderInt('##exp_th', ef.th_min, 0, 14);
            if imgui.IsItemDeactivatedAfterEdit() then ef.auto_dirty = true; end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Minimum Treasure Hunter level. 0 = no filter.');
            end

            imgui.SameLine(col2_label);
            imgui.Text('Status:');
            imgui.SameLine(col2);
            imgui.PushItemWidth(w2);
            if imgui.Combo('##exp_status', ef.status_idx, 'All\0Obtained\0Inv Full\0Lost\0Zoned\0Pending\0\0') then ef.auto_dirty = true; end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Filter by drop outcome.\nObtained = Won by player\nInv Full = Inventory full\nLost = Nobody lotted\nZoned = Left zone\nPending = Still in pool');
            end

            -- Row 4: Include empty kills
            if imgui.Checkbox('Include empty kills', ef.include_empty) then ef.auto_dirty = true; end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Include kills that had no drops in the treasure pool.');
            end

            imgui.Spacing();

            -- More Filters (collapsed by default)
            if imgui.TreeNode('More Filters##exp') then
                imgui.Unindent();
                -- Row 1: Killer + Winner
                imgui.Text('Killer:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                imgui.InputTextWithHint('##exp_killer', 'Filter by killer...', ef.killer_buf, ef.killer_buf_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Search by killer name (partial match). The entity that dealt the killing blow.');
                end

                imgui.SameLine(col2_label);
                imgui.Text('Winner:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                imgui.InputTextWithHint('##exp_winner', 'Filter by winner...', ef.winner_buf, ef.winner_buf_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Winner name search. Leave blank for all.');
                end

                -- Row 2: Date From + Date To
                imgui.Text('From:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                imgui.InputTextWithHint('##exp_from', 'YYYY-MM-DD', ef.date_from, ef.date_from_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Start date (YYYY-MM-DD). Leave blank for no lower bound.');
                end
                if (ef.date_from_err) then
                    imgui.SameLine();
                    imgui.TextColored(COLOR_ERR, 'Invalid date');
                end

                imgui.SameLine(col2_label);
                imgui.Text('To:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                imgui.InputTextWithHint('##exp_to', 'YYYY-MM-DD', ef.date_to, ef.date_to_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('End date (YYYY-MM-DD). Leave blank for no upper bound.');
                end
                if (ef.date_to_err) then
                    imgui.SameLine();
                    imgui.TextColored(COLOR_ERR, 'Invalid date');
                end

                -- Row 3: Vana Day + Moon Phase
                imgui.Text('V. Day:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                if imgui.Combo('##exp_weekday', ef.weekday_idx,
                    'All Days\0Firesday\0Earthsday\0Watersday\0Windsday\0Iceday\0Lightningday\0Lightsday\0Darksday\0\0') then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter by Vana\'diel day of the week.');
                end

                imgui.SameLine(col2_label);
                imgui.Text('M. Phase:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                if imgui.Combo('##exp_moon', ef.moon_phase_idx,
                    'All Phases\0New Moon (0-5%)\0Waxing Crescent (6-24%)\0First Quarter (25-49%)\0Waxing Gibbous (50-74%)\0Full Moon (75-100%)\0Waning Gibbous (50-74%)\0Last Quarter (25-49%)\0Waning Crescent (6-24%)\0\0') then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter by moon phase. Percent ranges shown for reference.');
                end

                -- Row 4: Vana Hour Min + Max
                imgui.Text('V. Hour:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                imgui.SliderInt('##exp_hour_min', ef.hour_min, 0, 23, 'Min: %d:00');
                if imgui.IsItemDeactivatedAfterEdit() then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Minimum Vana\'diel hour (0-23). Set 0-23 for all hours.');
                end

                imgui.SameLine(col2_label);
                imgui.PushItemWidth(w2);
                imgui.SliderInt('##exp_hour_max', ef.hour_max, 0, 23, 'Max: %d:00');
                if imgui.IsItemDeactivatedAfterEdit() then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Maximum Vana\'diel hour (0-23). Set 0-23 for all hours.');
                end

                -- Row 5: Weather + Result
                imgui.Text('Weather:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                if imgui.Combo('##exp_weather', ef.weather_idx,
                    'All Weather\0Clear\0Sunny\0Cloudy\0Fog\0Hot Spell\0Heat Wave\0Rain\0Squall\0Dust Storm\0Sand Storm\0Wind\0Gales\0Snow\0Blizzard\0Thunder\0Thunderstorm\0Auroras\0Stellar Glare\0Gloom\0Darkness\0\0') then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter by weather conditions at time of kill.');
                end

                imgui.SameLine(col2_label);
                imgui.Text('Result:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                if imgui.Combo('##exp_chest_result', ef.chest_result_idx,
                    'All Chest Results\0Gil\0Lockpick Failed\0Trapped!\0Mimic!\0Illusion\0\0') then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter chest/coffer events by result type.\nGil = successful open with gil reward.\nOthers = various failure outcomes.');
                end

                imgui.Indent();
                imgui.TreePop();
            end

            -- ID Filters (collapsed by default)
            if imgui.TreeNode('ID Filters##exp') then
                imgui.Unindent();
                -- Row 1: Mob SID + Item ID
                imgui.Text('Mob SID:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                imgui.InputTextWithHint('##exp_mobsid', 'Mob server ID...', ef.mob_sid_buf, ef.mob_sid_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Exact mob server entity ID. Leave blank for all.');
                end

                imgui.SameLine(col2_label);
                imgui.Text('ItemID:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                imgui.InputTextWithHint('##exp_itemid', 'Item ID...', ef.item_id_buf, ef.item_id_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Exact item ID. Leave blank for all.');
                end

                -- Row 2: Winner ID + Player Action
                imgui.Text('Win ID:');
                imgui.SameLine(col1);
                imgui.PushItemWidth(w1);
                imgui.InputTextWithHint('##exp_winid', 'Winner ID...', ef.winner_id_buf, ef.winner_id_size);
                if imgui.IsItemEdited() then ef.text_dirty = true; ef.text_edit_time = os_clock(); end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Winner entity ID. Leave blank for all.');
                end

                imgui.SameLine(col2_label);
                imgui.Text('P.Act:');
                imgui.SameLine(col2);
                imgui.PushItemWidth(w2);
                if imgui.Combo('##exp_pact', ef.player_action_idx, ef.player_action_combo) then ef.auto_dirty = true; end
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter by your lot action (Lotted or Passed).');
                end

                imgui.Indent();
                imgui.TreePop();
            end

            imgui.Separator();

            -- Auto-update: debounced text (0.5s) or immediate discrete change
            local now = os_clock();
            local auto_trigger = ef.auto_dirty
                or (ef.text_dirty and (now - ef.text_edit_time) > 0.5);
            if (auto_trigger) then
                ef.auto_dirty = false;
                ef.text_dirty = false;
                apply_filters();
            end

            -- Apply / Reset / Show Preview buttons + row count
            local apply_clicked = imgui.Button('Apply Filters');
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Query the database with the current filters.');
            end
            if apply_clicked then
                ef.auto_dirty = false;
                ef.text_dirty = false;
                apply_filters();
            end

            imgui.SameLine();
            local reset_clicked = imgui.Button('Reset Filters');
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Clear all filters and results.');
            end
            if reset_clicked then
                -- Quick filters
                ef.zone_idx[1] = 0;
                ef.source_idx[1] = 0;
                ef.mob_buf[1] = '';
                ef.item_buf[1] = '';
                ef.th_min[1] = 0;
                ef.status_idx[1] = 0;
                ef.include_empty[1] = true;
                -- More filters
                ef.killer_buf[1] = '';
                ef.winner_buf[1] = '';
                ef.date_from[1] = '';
                ef.date_to[1] = '';
                ef.weekday_idx[1] = 0;
                ef.moon_phase_idx[1] = 0;
                ef.hour_min[1] = 0;
                ef.hour_max[1] = 23;
                ef.weather_idx[1] = 0;
                ef.chest_result_idx[1] = 0;
                -- ID filters
                ef.mob_sid_buf[1] = '';
                ef.item_id_buf[1] = '';
                ef.winner_id_buf[1] = '';
                ef.player_action_idx[1] = 0;
                -- Clear results and hide preview
                ef.data = nil;
                ef.row_count = 0;
                ef.filter_summary = '';
                ef.date_from_err = false;
                ef.date_to_err = false;
                ef.last_filters = nil;
                ef.show_preview[1] = true;
                ef.auto_dirty = false;
                ef.text_dirty = false;
            end

            imgui.SameLine();
            imgui.Checkbox('Preview', ef.show_preview);
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Show or hide the data preview table below.');
            end

            imgui.SameLine();
            if (ef.data ~= nil and ef.row_count > ef.PREVIEW_LIMIT) then
                imgui.TextDisabled('Matched: ' .. format_count(ef.row_count)
                    .. ' rows  (preview: ' .. tostring(ef.PREVIEW_LIMIT) .. ')');
            else
                imgui.TextDisabled('Showing: ' .. format_count(ef.row_count) .. ' rows');
            end

            -- UX 4: Active filter summary
            if (ef.filter_summary ~= '') then
                imgui.TextDisabled(ef.filter_summary);
            end

            imgui.Separator();

            -- Preview area
            if (ef.data == nil) then
                imgui.TextDisabled('Adjust filters above — preview updates automatically.');
            elseif (#ef.data == 0) then
                imgui.TextDisabled('No results match the current filters.');
            elseif (ef.show_preview[1]) then
                local table_flags = ImGuiTableFlags_Resizable
                    + ImGuiTableFlags_RowBg
                    + ImGuiTableFlags_BordersInnerV
                    + ImGuiTableFlags_SizingFixedFit
                    + ImGuiTableFlags_Sortable
                    + ImGuiTableFlags_ScrollX
                    + ImGuiTableFlags_ScrollY
                    + ImGuiTableFlags_Hideable;  -- UX 6

                -- ScrollY requires explicit height; y=0 sizes the table to zero.
                -- Use remaining content region so the table fills available space.
                local _, avail_h = imgui.GetContentRegionAvail();
                if (avail_h < 60) then avail_h = 60; end  -- minimum usable height

                -- 26 sortable columns — mirrors all CSV export fields
                if imgui.BeginTable('export_preview', 26, table_flags, { 0, avail_h }) then
                    imgui.TableSetupScrollFreeze(1, 1); -- freeze Kill ID column + header row

                    for _, def in ipairs(export_col_defs) do
                        imgui.TableSetupColumn(def.label, def.flags, def.width, def.id);
                    end
                    render_header_row(export_col_defs);

                    -- Sort handling
                    local sort_specs = imgui.TableGetSortSpecs();
                    if sort_specs then
                        local spec = sort_specs.Specs;
                        if spec then
                            local col = spec.ColumnUserID;
                            local asc = spec.SortDirection == ImGuiSortDirection_Ascending;
                            if (col ~= ef.sort_col or asc ~= ef.sort_asc) then
                                ef.sort_col = col;
                                ef.sort_asc = asc;

                                table.sort(ef.data, function(a, b)
                                    local va, vb;
                                    if     (col == 0)  then va, vb = (a.kill_id or 0),         (b.kill_id or 0);
                                    elseif (col == 1)  then va, vb = (a.timestamp or 0),       (b.timestamp or 0);
                                    elseif (col == 2)  then va, vb = (a.mob_name or ''),       (b.mob_name or '');
                                    elseif (col == 3)  then va, vb = (a.mob_server_id or 0),   (b.mob_server_id or 0);
                                    elseif (col == 4)  then va, vb = (a.zone_name or ''),      (b.zone_name or '');
                                    elseif (col == 5)  then va, vb = (a.zone_id or 0),         (b.zone_id or 0);
                                    elseif (col == 6)  then va, vb = (a.source_type or 0),     (b.source_type or 0);
                                    elseif (col == 7)  then va, vb = (a.th_level or 0),        (b.th_level or 0);
                                    elseif (col == 8)  then va, vb = (a.killer_name or ''),    (b.killer_name or '');
                                    elseif (col == 9)  then va, vb = (a.th_action_type or 0),  (b.th_action_type or 0);
                                    elseif (col == 10) then va, vb = (a.th_action_id or 0),    (b.th_action_id or 0);
                                    elseif (col == 11) then va, vb = (a.vana_weekday or -1),   (b.vana_weekday or -1);
                                    elseif (col == 12) then va, vb = (a.vana_hour or -1),      (b.vana_hour or -1);
                                    elseif (col == 13) then va, vb = (a.moon_phase or -1),     (b.moon_phase or -1);
                                    elseif (col == 14) then va, vb = (a.moon_percent or -1),   (b.moon_percent or -1);
                                    elseif (col == 15) then va, vb = (a.weather or -1),        (b.weather or -1);
                                    elseif (col == 16) then va, vb = (a.item_name or ''),      (b.item_name or '');
                                    elseif (col == 17) then va, vb = (a.item_id or 0),         (b.item_id or 0);
                                    elseif (col == 18) then va, vb = (a.quantity or 0),        (b.quantity or 0);
                                    elseif (col == 19) then va, vb = (a.lot_value or 0),       (b.lot_value or 0);
                                    elseif (col == 20) then va, vb = (a.won or 0),             (b.won or 0);
                                    elseif (col == 21) then va, vb = (a.winner_id or 0),       (b.winner_id or 0);
                                    elseif (col == 22) then va, vb = (a.winner_name or ''),    (b.winner_name or '');
                                    elseif (col == 23) then va, vb = (a.player_lot or 0),      (b.player_lot or 0);
                                    elseif (col == 24) then va, vb = (a.player_action or 0),   (b.player_action or 0);
                                    elseif (col == 25) then va, vb = (a.drop_timestamp or 0),  (b.drop_timestamp or 0);
                                    else return false;
                                    end
                                    if asc then return va < vb; else return va > vb; end
                                end);
                            end
                        end
                    end

                    local preview_count = math_min(#ef.data, ef.PREVIEW_LIMIT);
                    for i = 1, preview_count do
                        local row = ef.data[i];
                        imgui.TableNextRow();

                        local is_empty = (row.item_name == nil);

                        imgui.TableNextColumn();
                        imgui.TextDisabled(tostring(row.kill_id or 0));

                        -- Time (date + time) — Perf 5: use pre-formatted strings
                        imgui.TableNextColumn();
                        imgui.TextDisabled(row._fmt_time or os_date('%m/%d %H:%M', row.timestamp or 0));
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(row._fmt_full or os_date('%Y-%m-%d %H:%M:%S', row.timestamp or 0));
                        end

                        imgui.TableNextColumn();
                        imgui.Text(row.mob_name or '');

                        imgui.TableNextColumn();
                        if ((row.mob_server_id or 0) > 0) then
                            imgui.TextDisabled(string_format('%.0f', tonumber(row.mob_server_id)));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        imgui.TextDisabled(row.zone_name or '');

                        imgui.TableNextColumn();
                        imgui.TextDisabled(tostring(row.zone_id or 0));

                        imgui.TableNextColumn();
                        local src_color = source_colors[row.source_type] or source_colors[0];
                        imgui.TextColored(src_color, tracker.get_source_label(row.source_type));

                        imgui.TableNextColumn();
                        if ((row.th_level or 0) > 0) then
                            imgui.Text(tostring(row.th_level));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local kname = row.killer_name or '';
                        if (kname ~= '') then
                            imgui.Text(kname);
                            if (imgui.IsItemHovered() and (row.killer_id or 0) > 0) then
                                imgui.SetTooltip('Entity ID: ' .. string_format('%.0f', tonumber(row.killer_id)));
                            end
                        elseif ((row.killer_id or 0) > 0) then
                            imgui.TextDisabled(string_format('%.0f', tonumber(row.killer_id)));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local th_act = tracker.get_action_type_label(row.th_action_type);
                        if (th_act ~= '') then
                            imgui.Text(th_act);
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if ((row.th_action_id or 0) > 0) then
                            imgui.TextDisabled(tostring(row.th_action_id));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local wd = tonumber(row.vana_weekday);
                        if (wd ~= nil and wd >= 0) then
                            imgui.Text(tracker.get_weekday_label(wd));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local hr = tonumber(row.vana_hour);
                        if (hr ~= nil and hr >= 0) then
                            imgui.Text(string_format('%02d:00', hr));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local mph = tonumber(row.moon_phase);
                        if (mph ~= nil and mph >= 0) then
                            imgui.Text(tracker.get_moon_phase_label(mph));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local mp = tonumber(row.moon_percent);
                        if (mp ~= nil and mp >= 0) then
                            imgui.Text(tostring(math.floor(mp)) .. '%');
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        local w = tonumber(row.weather);
                        if (w ~= nil and w >= 0) then
                            imgui.Text(tracker.get_weather_label(w));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('No Drop');
                        else
                            local s_color = status_colors[row.won] or status_colors[0];
                            imgui.TextColored(s_color, row.item_name or '');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        else
                            imgui.TextDisabled(tostring(row.item_id or 0));
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif ((row.quantity or 1) > 1) then
                            imgui.Text(tostring(row.quantity));
                        else
                            imgui.TextDisabled('1');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif ((row.lot_value or 0) > 0) then
                            imgui.Text(tostring(row.lot_value));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        else
                            local s_color = status_colors[row.won] or status_colors[0];
                            local s_label = status_labels[row.won] or '--';
                            imgui.TextColored(s_color, s_label);
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif ((row.winner_id or 0) > 0) then
                            imgui.TextDisabled(string_format('%.0f', tonumber(row.winner_id)));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif (row.winner_name ~= nil and row.winner_name ~= '') then
                            imgui.Text(row.winner_name);
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif ((row.player_lot or 0) > 0) then
                            imgui.Text(tostring(row.player_lot));
                        else
                            imgui.TextDisabled('-');
                        end

                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        elseif ((row.player_action or 0) > 0) then
                            imgui.Text(tostring(row.player_action));
                        else
                            imgui.TextDisabled('-');
                        end

                        -- Drop Time — Perf 5: use pre-formatted string
                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        else
                            imgui.TextDisabled(row._fmt_drop or '-');
                        end
                    end

                    imgui.EndTable();
                end

                -- Preview limit notice now shown in the button bar above (Fix 1 & 2)
            end

        end
        imgui.EndChild();

        -- Fixed bottom bar (outside child)
        if (ef.data ~= nil and #ef.data > 0) then
            if imgui.Button('Export Filtered to CSV') then
                ui.filtered_export_requested = true;
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('Export %s filtered rows to CSV.', format_count(ef.row_count)));
            end
            imgui.SameLine();
        end
        if imgui.Button('Close') then
            advanced_export_open[1] = false;
        end
    end
    imgui.End();
end

local function render_export_tab()
    imgui.Spacing();

    -- Export All button (counts in tooltip to avoid overflow at high numbers)
    local kc, dc, _, cc = db.get_counts();
    if imgui.Button('Export All to CSV') then
        ui.export_requested = true;
    end
    if imgui.IsItemHovered() then
        local tip = string_format('%s kills, %s drops', format_count(kc), format_count(dc));
        if (cc > 0) then
            tip = tip .. string_format(', %s chest events', format_count(cc));
        end
        imgui.SetTooltip(tip .. ' (unfiltered)');
    end
    imgui.SameLine();
    local db_size = db_size_cache;
    local size_label;
    if (db_size >= 1048576) then
        size_label = string_format('%.1f MB', db_size / 1048576);
    else
        size_label = string_format('%.0f KB', db_size / 1024);
    end
    local summary_text = string_format('%s kills, %s drops', format_count(kc), format_count(dc));
    if (cc > 0) then
        summary_text = summary_text .. string_format(', %s chests', format_count(cc));
    end
    imgui.TextDisabled(string_format('%s  (%s)', summary_text, size_label));

    imgui.Spacing();

    -- Advanced Export Settings button -> opens separate window
    if imgui.Button('Advanced Export Settings') then
        advanced_export_open[1] = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Filter and preview data before exporting.');
    end
end

-------------------------------------------------------------------------------
-- Tab 4: Settings
-------------------------------------------------------------------------------
local settings_header_color = { 1.0, 0.65, 0.26, 1.0 };

local function render_settings_tab()
    imgui.TextColored(settings_header_color, 'Live Feed');
    imgui.Separator();

    local v;
    local slider_w = math_min((imgui.GetContentRegionAvail()), 250);

    v = { s.feed_max_entries };
    imgui.PushItemWidth(slider_w);
    if imgui.SliderInt('Live Feed Max Entries', v, 10, 500) then
        s.feed_max_entries = v[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Maximum number of entries shown in the Live Feed tab.');
    end

    v = { s.show_empty_kills };
    if imgui.Checkbox('Show Kills Without Drops', v) then
        s.show_empty_kills = v[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show mobs that died without dropping anything in the Live Feed.\nUseful for tracking TH levels on empty kills.');
    end

    v = { s.show_gil_drops ~= false };
    if imgui.Checkbox('Show Kills With Gil Drops', v) then
        s.show_gil_drops = v[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show gil drops from mob kills in the Live Feed.\nDisable to reduce noise when farming for items.');
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'Compact Mode');
    imgui.Separator();

    v = { s.compact_bg_alpha or 0.8 };
    imgui.PushItemWidth(slider_w);
    if imgui.SliderFloat('Background Opacity', v, 0.0, 1.0, '%.2f') then
        s.compact_bg_alpha = v[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Background transparency for compact mode.\n0 = fully transparent, 1 = fully opaque.');
    end

    v = { s.compact_titlebar ~= false };
    if imgui.Checkbox('Show Title Bar', v) then
        s.compact_titlebar = v[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show or hide the window title bar in compact mode.\nThe window is still draggable without it.');
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'Startup');
    imgui.Separator();

    v = { s.show_on_load };
    if imgui.Checkbox('Open window when addon loads', v) then
        s.show_on_load = v[1];
        ui.settings_dirty = true;
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'Actions');
    imgui.Separator();

    -- Clear data button (popups rendered in render_full at window scope)
    if imgui.Button('Clear All Data') then
        ui.reset_step = 1;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Delete all recorded kills, drops, and chest events.\nThis cannot be undone!');
    end

end

-------------------------------------------------------------------------------
-- Compact Mode
-------------------------------------------------------------------------------
-- Helper: read a theme color and return it with alpha scaled
local function scaled_color(idx, a)
    local r, g, b, ca = imgui.GetStyleColorVec4(idx);
    return { r, g, b, ca * a };
end

-- Compact mode style color indices (hoisted to avoid per-frame allocation)
local compact_style_color_ids = {
    ImGuiCol_Border, ImGuiCol_BorderShadow,
    ImGuiCol_ScrollbarBg, ImGuiCol_ScrollbarGrab,
    ImGuiCol_ScrollbarGrabHovered, ImGuiCol_ScrollbarGrabActive,
    ImGuiCol_TableHeaderBg, ImGuiCol_TableBorderStrong, ImGuiCol_TableBorderLight,
    ImGuiCol_TableRowBg, ImGuiCol_TableRowBgAlt,
    ImGuiCol_ResizeGrip, ImGuiCol_ResizeGripHovered, ImGuiCol_ResizeGripActive,
};

local function render_compact()
    if (restore_compact_size and saved_compact_size) then
        restore_compact_size = false;
        imgui.SetNextWindowSize(saved_compact_size, ImGuiCond_Always);
    elseif (restore_compact_size) then
        restore_compact_size = false;
        imgui.SetNextWindowSize({ 300, 200 }, ImGuiCond_Always);
    else
        imgui.SetNextWindowSize({ 300, 200 }, ImGuiCond_FirstUseEver);
    end

    -- Configurable background opacity
    local bg_alpha = (s ~= nil and s.compact_bg_alpha) or 0.8;
    imgui.SetNextWindowBgAlpha(bg_alpha);

    -- Scale all UI element colors by the opacity setting
    local a = bg_alpha;
    for _, col_idx in ipairs(compact_style_color_ids) do
        imgui.PushStyleColor(col_idx, scaled_color(col_idx, a));
    end

    -- Window flags: optional title bar
    local win_flags = ImGuiWindowFlags_NoScrollbar;
    local hide_titlebar = (s ~= nil and s.compact_titlebar == false);
    if (hide_titlebar) then
        win_flags = win_flags + ImGuiWindowFlags_NoTitleBar;
    end

    if imgui.Begin('LootScope', is_open, win_flags) then
        local limit = (s ~= nil) and math_min(s.feed_max_entries, 20) or 20;
        local raw_drops = db.get_recent_drops(limit);
        local show_gil_c = (s == nil) or (s.show_gil_drops ~= false);
        local drops;
        if (show_gil_c) then
            drops = raw_drops;
        elseif (raw_drops == compact_filter_src and show_gil_c == compact_filter_gil) then
            drops = compact_filter_cache;
        else
            drops = T{};
            for _, row in ipairs(raw_drops) do
                if (not (row.item_id == 65535 and row.source_type == 0)) then
                    drops:append(row);
                end
            end
            compact_filter_src = raw_drops;
            compact_filter_gil = show_gil_c;
            compact_filter_cache = drops;
        end
        preformat_compact(drops);

        if (#drops == 0) then
            imgui.TextDisabled('No drops yet.');
        else
            local table_flags = ImGuiTableFlags_Resizable
                + ImGuiTableFlags_RowBg
                + ImGuiTableFlags_BordersInnerV
                + ImGuiTableFlags_SizingFixedFit
                + ImGuiTableFlags_ScrollY
                + ImGuiTableFlags_Hideable;

            if imgui.BeginTable('compact_feed', #compact_col_defs, table_flags, { 0, -18 }) then
                imgui.TableSetupScrollFreeze(0, 1);
                for _, def in ipairs(compact_col_defs) do
                    imgui.TableSetupColumn(def.label, def.flags, def.width);
                end
                render_header_row(compact_col_defs);

                for _, drop in ipairs(drops) do
                    imgui.TableNextRow();

                    imgui.TableNextColumn();
                    imgui.TextDisabled(drop._fmt_hm);
                    if imgui.IsItemHovered() then
                        local tip = drop._fmt_hms;
                        if (drop.vana_weekday ~= nil and tonumber(drop.vana_weekday) >= 0) then
                            tip = tip .. '\n' .. tracker.get_weekday_label(drop.vana_weekday);
                        end
                        local mp = tonumber(drop.moon_percent);
                        if (mp ~= nil and mp >= 0) then
                            local phase_label = '';
                            local mph = tonumber(drop.moon_phase);
                            if (mph ~= nil and mph >= 0) then
                                phase_label = tracker.get_moon_phase_label(mph);
                            end
                            tip = tip .. '\nMoon: ' .. tostring(math.floor(mp)) .. '% ' .. phase_label;
                        end
                        local w = tonumber(drop.weather);
                        if (w ~= nil and w >= 0) then
                            tip = tip .. '\nWeather: ' .. tracker.get_weather_label(w);
                        end
                        imgui.SetTooltip(tip);
                    end

                    imgui.TableNextColumn();
                    local s_color = status_colors[drop.won] or status_colors[0];
                    imgui.TextColored(s_color, drop.item_name or '');
                    if imgui.IsItemHovered() then
                        local tip = drop.item_name or '';
                        if (drop.zone_name ~= nil and drop.zone_name ~= '') then
                            tip = tip .. '\nZone: ' .. drop.zone_name;
                        end
                        if (drop.item_id ~= nil) then
                            tip = tip .. '\nItem ID: ' .. tostring(drop.item_id);
                        end
                        local s_label = status_labels[drop.won] or '--';
                        tip = tip .. '\nStatus: ' .. s_label;
                        imgui.SetTooltip(tip);
                    end

                    imgui.TableNextColumn();
                    imgui.TextDisabled(drop.mob_name or '');
                    if imgui.IsItemHovered() and drop.mob_server_id ~= nil and drop.mob_server_id > 0 then
                        imgui.SetTooltip(string_format('Mob ID: %.0f', tonumber(drop.mob_server_id)));
                    end

                    imgui.TableNextColumn();
                    imgui.TextDisabled(drop.zone_name or '');

                    imgui.TableNextColumn();
                    local src_color = source_colors[drop.source_type] or source_colors[0];
                    imgui.TextColored(src_color, tracker.get_source_label(drop.source_type));

                    imgui.TableNextColumn();
                    if ((drop.quantity or 1) > 1) then
                        imgui.Text(tostring(drop.quantity));
                    else
                        imgui.TextDisabled('1');
                    end

                    imgui.TableNextColumn();
                    if (drop.th_level > 0) then
                        imgui.Text(tostring(drop.th_level));
                    else
                        imgui.TextDisabled('-');
                    end
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Treasure Hunter level on mob at time of kill.');
                    end

                    imgui.TableNextColumn();
                    local sc = status_colors[drop.won] or status_colors[0];
                    local sl = status_labels[drop.won] or '--';
                    imgui.TextColored(sc, sl);

                    imgui.TableNextColumn();
                    if ((drop.lot_value or 0) > 0) then
                        imgui.Text(tostring(drop.lot_value));
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    if (drop.winner_name ~= nil and drop.winner_name ~= '') then
                        imgui.Text(drop.winner_name);
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local ckname = drop.killer_name or '';
                    if (ckname ~= '') then
                        imgui.Text(ckname);
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local wd = tonumber(drop.vana_weekday);
                    if (wd ~= nil and wd >= 0) then
                        imgui.Text(tracker.get_weekday_label(wd));
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local hr = tonumber(drop.vana_hour);
                    if (hr ~= nil and hr >= 0) then
                        imgui.Text(string_format('%02d:00', hr));
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local mph = tonumber(drop.moon_phase);
                    if (mph ~= nil and mph >= 0) then
                        imgui.Text(tracker.get_moon_phase_label(mph));
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local mp2 = tonumber(drop.moon_percent);
                    if (mp2 ~= nil and mp2 >= 0) then
                        imgui.Text(tostring(math.floor(mp2)) .. '%');
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    local w2 = tonumber(drop.weather);
                    if (w2 ~= nil and w2 >= 0) then
                        imgui.Text(tracker.get_weather_label(w2));
                    else
                        imgui.TextDisabled('-');
                    end

                    imgui.TableNextColumn();
                    imgui.TextDisabled(tostring(drop.kill_id or 0));

                    imgui.TableNextColumn();
                    if ((drop.mob_server_id or 0) > 0) then
                        imgui.TextDisabled(string_format('%.0f', tonumber(drop.mob_server_id)));
                    else
                        imgui.TextDisabled('-');
                    end
                end

                imgui.EndTable();
            end
        end

        -- Expand button, right-aligned in reserved bottom space
        local bw = imgui.GetContentRegionAvail();
        imgui.SetCursorPosX(imgui.GetCursorPosX() + bw - 38);
        if imgui.SmallButton('>>') then
            local w, h = imgui.GetWindowSize();
            saved_compact_size = { w, h };
            compact_mode = false;
            restore_full_size = true;
            ui.settings_dirty = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Expand to full view');
        end
    end
    imgui.End();
    imgui.PopStyleColor(#compact_style_color_ids);
end

-------------------------------------------------------------------------------
-- Full Dashboard
-------------------------------------------------------------------------------
local function render_full()
    if reset_pending then
        reset_pending = false;
        restore_full_size = false;
        imgui.SetNextWindowSize({ 500, 400 }, ImGuiCond_Always);
        imgui.SetNextWindowPos({ 100, 100 }, ImGuiCond_Always);
    elseif restore_full_size then
        restore_full_size = false;
        local sz = saved_full_size or { 500, 400 };
        saved_full_size = nil;
        imgui.SetNextWindowSize(sz, ImGuiCond_Always);
    else
        imgui.SetNextWindowSize({ 500, 400 }, ImGuiCond_FirstUseEver);
    end

    if imgui.Begin('LootScope', is_open, ImGuiWindowFlags_NoScrollbar + ImGuiWindowFlags_NoScrollWithMouse) then
        -- Toolbar
        local kc, dc, _, cc = db.get_counts();
        local char_label = tracker.char_name and ('[' .. tracker.char_name .. '] ') or '';
        local toolbar_text = string_format('%s%s kills | %s drops', char_label, format_count(kc), format_count(dc));
        if (cc > 0) then
            toolbar_text = toolbar_text .. ' | ' .. format_count(cc) .. ' chests';
        end
        imgui.TextDisabled(toolbar_text);

        imgui.SameLine();
        local avail_w = imgui.GetContentRegionAvail();
        imgui.SameLine(imgui.GetCursorPosX() + avail_w - 155);
        if imgui.SmallButton('Reset UI') then
            reset_pending = true;
            saved_full_size = nil;
            saved_compact_size = nil;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Reset window size and position to defaults.');
        end
        imgui.SameLine();
        if imgui.SmallButton('Compact') then
            local w, h = imgui.GetWindowSize();
            saved_full_size = { w, h };
            compact_mode = true;
            restore_compact_size = true;
            ui.settings_dirty = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Switch to compact overlay.');
        end

        imgui.Separator();

        -- Tabs
        if imgui.BeginTabBar('lootscope_tabs') then
            if imgui.BeginTabItem('Live Feed') then
                render_live_feed();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Statistics') then
                render_statistics();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Export') then
                if (not export_tab_was_open) then
                    export_tab_was_open = true;
                    db_size_cache = db.get_file_size();
                end
                render_export_tab();
                imgui.EndTabItem();
            else
                export_tab_was_open = false;
            end

            if imgui.BeginTabItem('Settings') then
                render_settings_tab();
                imgui.EndTabItem();
            end

            imgui.EndTabBar();
        end

        -- Reset confirmation popups (shared by toolbar Reset button and Settings Clear All Data)
        -- OpenPopup must be at the same ID scope as BeginPopupModal, so we trigger here
        -- rather than inside render_settings_tab() which is nested inside a tab item.
        if (ui.reset_step == 1) then
            imgui.OpenPopup('Clear Data Warning##ls');
        end
        if (ui.reset_step == 2) then
            ui.reset_step = 3;
            imgui.OpenPopup('Confirm Deletion##ls');
        end

        imgui.SetNextWindowSize({ 380, 180 }, ImGuiCond_FirstUseEver);
        if imgui.BeginPopupModal('Clear Data Warning##ls', nil, ImGuiWindowFlags_NoResize) then
            local popup_kc, popup_dc = db.get_counts();
            imgui.Spacing();
            imgui.TextColored(COLOR_WARN, 'WARNING');
            imgui.Separator();
            imgui.Spacing();
            imgui.Text('This will permanently delete:');
            imgui.TextColored(COLOR_WARN, '  ' .. format_count(popup_kc) .. ' kills and ' .. format_count(popup_dc) .. ' drops');
            imgui.Spacing();
            imgui.TextColored(COLOR_WARN, 'This cannot be undone!');
            imgui.Spacing();
            imgui.Separator();
            imgui.Spacing();
            if imgui.Button('I understand, continue') then
                reset_confirm_buf[1] = '';
                ui.reset_step = 2;
                imgui.CloseCurrentPopup();
            end
            imgui.SameLine();
            if imgui.Button('Cancel##reset1') then
                ui.reset_step = 0;
                imgui.CloseCurrentPopup();
            end
            imgui.EndPopup();
        end

        imgui.SetNextWindowSize({ 380, 180 }, ImGuiCond_FirstUseEver);
        if imgui.BeginPopupModal('Confirm Deletion##ls', nil, ImGuiWindowFlags_NoResize) then
            imgui.Spacing();
            imgui.TextColored(COLOR_ERR, 'FINAL CONFIRMATION');
            imgui.Separator();
            imgui.Spacing();
            imgui.Text('Type CONFIRM below to delete all data:');
            imgui.Spacing();
            imgui.PushItemWidth(150);
            imgui.InputText('##reset_confirm', reset_confirm_buf, reset_confirm_buf_size);
            imgui.PopItemWidth();
            imgui.Spacing();
            imgui.Separator();
            imgui.Spacing();
            local typed_confirm = (reset_confirm_buf[1] == 'CONFIRM');
            imgui.BeginDisabled(not typed_confirm);
            if imgui.Button('Delete All Data') then
                ui.reset_requested = true;
                ui.reset_step = 0;
                reset_confirm_buf[1] = '';
                imgui.CloseCurrentPopup();
            end
            imgui.EndDisabled();
            imgui.SameLine();
            if imgui.Button('Cancel##reset2') then
                ui.reset_step = 0;
                reset_confirm_buf[1] = '';
                imgui.CloseCurrentPopup();
            end
            imgui.EndPopup();
        end
    end
    imgui.End();
end

-------------------------------------------------------------------------------
-- Main Render Entry Point
-------------------------------------------------------------------------------
function ui.render()
    if not is_open[1] then return; end

    -- Don't render anything until character is logged in and DB is ready
    if (db.conn == nil) then return; end

    if compact_mode then
        render_compact();
    else
        render_full();
    end

    -- Advanced Export is a standalone window (no dimming)
    render_advanced_export_window();
end

-------------------------------------------------------------------------------
-- Public: Window control
-------------------------------------------------------------------------------
function ui.toggle()
    is_open[1] = not is_open[1];
end

function ui.show()
    is_open[1] = true;
end

function ui.hide()
    is_open[1] = false;
end

function ui.toggle_compact()
    compact_mode = not compact_mode;
    if compact_mode then
        restore_compact_size = true;
    else
        restore_full_size = true;
    end
    ui.settings_dirty = true;
end

function ui.reset_ui()
    compact_mode = false;
    saved_full_size = nil;
    saved_compact_size = nil;
    export_tab_was_open = false;
    reset_pending = true;
end

function ui.get_export_filters()
    return ef.last_filters;
end

return ui;
