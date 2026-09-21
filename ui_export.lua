-- Export filters, preview queries and export windows.

require 'common';

local imgui = require 'imgui';
local state = require 'ui_state';
local widgets = require 'ui_widgets';   -- shared display primitives (optional_num_cell)

-- Hoisted: handed to widgets.optional_num_cell per row, per frame -- an inline closure would
-- allocate on every cell.
local function pct_label(v) return tostring(math.floor(v)) .. '%'; end


local string_format = string.format;
local math_min      = math.min;
local math_max      = math.max;
local os_date       = os.date;
local os_clock      = os.clock;
local tostring      = tostring;

local format_count = state.format_count;
local COLOR_ERR    = state.COLOR_ERR;

-- Refresh shared references at every entry point; settings and DB bindings may change.
local db, tracker, analysis, s = nil, nil, nil, nil;

-- Injected by ui.lua via M.bind().
local source_colors, status_colors, status_labels;
local display_mob_name, render_combined_th, render_header_row;
local ui;

local zone_combo_cache = '';
local zone_combo_zones = nil;
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
    source_idx      = { 0 },       -- 0=All, 1=Field, 2=Chest/Coffer, 3=AllBF, 4=BCNM, 5=HTBF, 6+=content types
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
    player_action_idx = { 0 },     -- 0=All, 1=Lotted, 2=Passed, 3=No lot
    -- Chest filters
    chest_result_idx  = { 0 },     -- 0=All, 1=Gil, 2=Lockpick Failed, 3=Trapped, 4=Mimic, 5=Illusion
    -- Killer filter
    killer_buf      = { '' },
    killer_buf_size = 128,
    -- Combo strings and lookup maps
    player_action_combo = 'All\0Lotted\0Passed\0No lot\0\0',
    player_action_map   = { [0]=nil, [1]=1, [2]=2, [3]=0 },
    PREVIEW_LIMIT   = 100,
    filter_summary  = '',
    date_from_err   = false,
    date_to_err     = false,
    last_filters    = nil,
    -- Auto-update state
    auto_dirty      = false,
    text_dirty      = false,
    text_edit_time  = 0,
};
local function parse_date(str)
    if (str == nil or str == '') then return nil; end
    local y, m, d = str:match('^(%d%d%d%d)-(%d%d)-(%d%d)$');
    if (y == nil) then return nil; end
    local ok, ts = pcall(os.time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 });
    if (not ok) then return nil; end
    return ts;
end
-- Export preview column definitions (sortable, with user IDs for sort handler)
local EP_FW  = ImGuiTableColumnFlags_WidthFixed;
local EP_ASC = ImGuiTableColumnFlags_PreferSortAscending;
local EP_DSC = ImGuiTableColumnFlags_PreferSortDescending;
local EP_DEF = ImGuiTableColumnFlags_DefaultSort;
local EP_NH  = ImGuiTableColumnFlags_NoHide;
local EP_DH  = ImGuiTableColumnFlags_DefaultHide;

local export_col_defs = {
    { label = 'Kill',    flags = EP_FW+EP_DSC+EP_DEF+EP_NH, width = 35,  id = 0,  tip = 'Database record ID' },
    { label = 'Time',    flags = EP_FW+EP_DSC,              width = 70,  id = 1,  tip = 'Real date/time the kill occurred' },
    { label = 'Mob',     flags = EP_FW+EP_ASC,              width = 100, id = 2,  tip = 'Name of the defeated enemy or container' },
    { label = 'Mob SID', flags = EP_FW+EP_DSC+EP_DH,        width = 50,  id = 3,  tip = 'Server entity ID of the mob' },
    { label = 'Zone',    flags = EP_FW+EP_ASC,              width = 90,  id = 4,  tip = 'Zone where the kill happened' },
    { label = 'ZoneID',  flags = EP_FW+EP_ASC+EP_DH,        width = 38,  id = 5,  tip = 'Numeric zone ID' },
    { label = 'Source',  flags = EP_FW+EP_ASC,              width = 48,  id = 6,  tip = 'Drop source type' },
    { label = 'TH',      flags = EP_FW+EP_DSC,              width = 25,  id = 7,  tip = 'TH level on mob at kill\n* = estimated' },
    { label = 'Killer',  flags = EP_FW+EP_ASC,              width = 75,  id = 8,  tip = 'Entity that dealt the killing blow' },
    { label = 'TH Act',  flags = EP_FW+EP_ASC+EP_DH,        width = 55,  id = 9,  tip = 'Action type that last procced TH' },
    { label = 'Act ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 10, tip = 'Ability/spell ID that procced TH' },
    { label = 'Day',     flags = EP_FW+EP_ASC,              width = 75,  id = 11, tip = "Vana'diel day of the week" },
    { label = 'V.Hour',  flags = EP_FW+EP_ASC,              width = 42,  id = 12, tip = "Vana'diel hour (0-23)" },
    { label = 'Moon',    flags = EP_FW+EP_ASC,              width = 90,  id = 13, tip = 'Moon phase at time of kill' },
    { label = 'Moon%',  flags = EP_FW+EP_DSC,              width = 42,  id = 14, tip = 'Moon illumination (0-100)' },
    { label = 'Weather', flags = EP_FW+EP_ASC,              width = 80,  id = 15, tip = 'Weather condition at time of kill' },
    { label = 'BF Name', flags = EP_FW+EP_ASC+EP_DH,        width = 80,  id = 16, tip = 'Recorded battlefield name, including BCNM and HTBF' },
    { label = 'Diff',    flags = EP_FW+EP_ASC+EP_DH,        width = 30,  id = 17, tip = 'HTBF difficulty: VD, D, N, E, VE' },
    { label = 'Content', flags = EP_FW+EP_ASC,              width = 70,  id = 18, tip = 'Content type tag' },
    { label = 'Item',    flags = EP_FW+EP_ASC,              width = 110, id = 19, tip = 'Recorded item, gil, or personal reward offer' },
    { label = 'ItemID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 20, tip = 'Numeric item ID' },
    { label = 'Qty',     flags = EP_FW+EP_DSC,              width = 25,  id = 21, tip = 'Quantity dropped' },
    { label = 'Lot',     flags = EP_FW+EP_DSC,              width = 30,  id = 22, tip = 'Winning lot value (0-999)' },
    { label = 'Status',  flags = EP_FW+EP_DSC,              width = 40,  id = 23, tip = 'Won, Lost, Inv Full, Zoned, Pending' },
    { label = 'Win ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 45,  id = 24, tip = 'Server ID of the winner' },
    { label = 'Winner',  flags = EP_FW+EP_ASC,              width = 75,  id = 25, tip = 'Player who won the item' },
    { label = 'P.Lot',   flags = EP_FW+EP_DSC+EP_DH,        width = 35,  id = 26, tip = 'Your lot value on this item' },
    { label = 'P.Act',   flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 27, tip = 'Your action: Lot, Pass, or no action recorded' },
    { label = 'Drop At', flags = EP_FW+EP_DSC,              width = 55,  id = 28, tip = 'Time the drop or reward offer was recorded' },
    { label = 'Distant', flags = EP_FW+EP_DSC+EP_DH,        width = 42,  id = 29, tip = 'Distant kill (biased sample)' },
    { label = 'Lvl Cap', flags = EP_FW+EP_DSC+EP_DH,        width = 42,  id = 30, tip = 'BCNM level cap' },
};
-- Shared zone combo builder
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
local advanced_export_open = { false };
local db_size_cache = 0;
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

    -- Combo: 0=All, 1=Field, 2=Chest/Coffer, 3=AllBF, 4=BCNM, 5=HTBF, 6-25=content types
    -- Filters by content_type so BF mob kills are grouped with their content.
    local source_type = nil;
    local source_type_list = nil;
    local content_type = nil;
    local field_only = false;
    local bf_all = false;
    local bf_difficulty_eq = nil;  -- nil=any, 0=BCNM, >0 not used (htbf uses gt)
    local htbf_only = false;
    if (ef.source_idx[1] == 1) then
        field_only = true;         -- source_type=0 AND content_type=''
    elseif (ef.source_idx[1] == 2) then
        source_type_list = { 1, 2 };  -- Chest + Coffer
    elseif (ef.source_idx[1] == 3) then
        bf_all = true;             -- content_type='BCNM' (mob kills + crate drops)
    elseif (ef.source_idx[1] == 4) then
        bf_all = true;             -- content_type='BCNM' AND bf_difficulty=0
        bf_difficulty_eq = 0;
    elseif (ef.source_idx[1] == 5) then
        htbf_only = true;          -- content_type='BCNM' AND bf_difficulty>0
    elseif (ef.source_idx[1] == 6) then
        content_type = 'Dynamis';
    elseif (ef.source_idx[1] == 7) then
        content_type = 'Voidwatch';
    elseif (ef.source_idx[1] == 8) then
        content_type = 'Domain Invasion';
    elseif (ef.source_idx[1] == 9) then
        content_type = 'Wildskeeper';
    elseif (ef.source_idx[1] == 10) then
        content_type = 'Omen';
    elseif (ef.source_idx[1] == 11) then
        content_type = 'Einherjar';
    elseif (ef.source_idx[1] == 12) then
        content_type = 'Nyzul';
    elseif (ef.source_idx[1] == 13) then
        content_type = 'Salvage';
    elseif (ef.source_idx[1] == 14) then
        content_type = 'Limbus';
    elseif (ef.source_idx[1] == 15) then
        content_type = 'Sortie';
    elseif (ef.source_idx[1] == 16) then
        content_type = 'Vagary';
    elseif (ef.source_idx[1] == 17) then
        content_type = 'Legion';
    elseif (ef.source_idx[1] == 18) then
        content_type = 'Assault';
    elseif (ef.source_idx[1] == 19) then
        content_type = 'Walk of Echoes';
    elseif (ef.source_idx[1] == 20) then
        content_type = 'Skirmish';
    elseif (ef.source_idx[1] == 21) then
        content_type = 'Meeble Burrows';
    elseif (ef.source_idx[1] == 22) then
        content_type = 'Odyssey';
    elseif (ef.source_idx[1] == 23) then
        content_type = 'Ambuscade';
    elseif (ef.source_idx[1] == 24) then
        content_type = 'Colonization Reive';
    elseif (ef.source_idx[1] == 25) then
        content_type = 'Lair Reive';
    end

    local status = af_status_map[ef.status_idx[1]];

    -- Date validation
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
        field_only      = field_only,
        bf_all          = bf_all,
        bf_difficulty_eq = bf_difficulty_eq,
        htbf_only       = htbf_only,
        content_type    = content_type,
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

    -- Store filters for streaming export
    ef.last_filters = filters;
    ef.row_count = db.get_filtered_export_count(filters);
    ef.data = db.get_filtered_export(filters, ef.PREVIEW_LIMIT);
    ef.sort_col = 0;
    ef.sort_asc = false;

    -- Auto-show preview after Apply
    ef.show_preview[1] = true;

    -- Pre-format timestamps
    for _, row in ipairs(ef.data) do
        row._fmt_time = os_date('%m/%d %H:%M', row.timestamp or 0);
        row._fmt_full = os_date('%Y-%m-%d %H:%M:%S', row.timestamp or 0);
        row._fmt_drop = (row.drop_timestamp and row.drop_timestamp > 0)
            and os_date('%H:%M:%S', row.drop_timestamp) or '-';
    end

    -- Build active filter summary
    local parts = {};
    if (zone_id >= 0 and ef.zone_idx[1] <= #apply_zones) then
        parts[#parts + 1] = 'Zone: ' .. apply_zones[ef.zone_idx[1]].zone_name;
    end
    if (content_type ~= nil) then
        parts[#parts + 1] = 'Source: ' .. content_type;
    elseif (field_only) then
        parts[#parts + 1] = 'Source: Field';
    elseif (bf_all and bf_difficulty_eq == 0) then
        parts[#parts + 1] = 'Source: BCNM';
    elseif (bf_all) then
        parts[#parts + 1] = 'Source: All BF';
    elseif (htbf_only) then
        parts[#parts + 1] = 'Source: HTBF';
    elseif (source_type_list ~= nil) then
        parts[#parts + 1] = 'Source: Chest/Coffer';
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
            if imgui.Combo('##exp_source', ef.source_idx, 'All\0Field\0Chest/Coffer\0All BF\0BCNM\0HTBF\0Dynamis\0Voidwatch\0Domain Invasion\0Wildskeeper\0Omen\0Einherjar\0Nyzul\0Salvage\0Limbus\0Sortie\0Vagary\0Legion\0Assault\0Walk of Echoes\0Skirmish\0Meeble Burrows\0Odyssey\0Ambuscade\0Colonization Reive\0Lair Reive\0\0') then
                ef.auto_dirty = true;
            end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Choose which content to export.\nField: open-world mobs without a content tag.\nAll BF: BCNM and HTBF together.\nChoose Legion or another content name to export it separately.');
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
                imgui.SetTooltip('Minimum server-confirmed TH. Estimates marked * do not\ncount toward this filter. Set 0 to include all TH levels.');
            end

            imgui.SameLine(col2_label);
            imgui.Text('Status:');
            imgui.SameLine(col2);
            imgui.PushItemWidth(w2);
            if imgui.Combo('##exp_status', ef.status_idx, 'All\0Obtained\0Inv Full\0Lost\0Zoned\0Pending\0\0') then ef.auto_dirty = true; end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Filter by recorded outcome.\nObtained: received or awarded to a player.\nInv Full: could not receive the item.\nLost: pool item lost, or a personal offer left behind.\nZoned: zone changed before the outcome was confirmed.\nPending: no final outcome recorded yet.');
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
                -- Skip query on invalid dates; still update error flags for red indicator
                local bad_from = (ef.date_from[1] ~= '' and parse_date(ef.date_from[1]) == nil);
                local bad_to   = (ef.date_to[1] ~= '' and parse_date(ef.date_to[1]) == nil);
                ef.date_from_err = bad_from;
                ef.date_to_err   = bad_to;
                if (not bad_from and not bad_to) then
                    apply_filters();
                end
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

            -- Active filter summary
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
                    + ImGuiTableFlags_Hideable;

                local _a, _b = imgui.GetContentRegionAvail();
                local avail_h = (type(_b) == 'number' and _b) or (type(_a) == 'number' and _a) or 0;
                if (avail_h < 60) then avail_h = 280; end

                if imgui.BeginTable('export_preview', #export_col_defs, table_flags, { 0, avail_h }) then
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
                                    elseif (col == 16) then va, vb = (a.bf_name or ''),        (b.bf_name or '');
                                    elseif (col == 17) then va, vb = (a.bf_difficulty or 0),   (b.bf_difficulty or 0);
                                    elseif (col == 18) then va, vb = (a.content_type or ''),   (b.content_type or '');
                                    elseif (col == 19) then va, vb = (a.item_name or ''),      (b.item_name or '');
                                    elseif (col == 20) then va, vb = (a.item_id or 0),         (b.item_id or 0);
                                    elseif (col == 21) then va, vb = (a.quantity or 0),        (b.quantity or 0);
                                    elseif (col == 22) then va, vb = (a.lot_value or 0),       (b.lot_value or 0);
                                    elseif (col == 23) then va, vb = (a.won or 0),             (b.won or 0);
                                    elseif (col == 24) then va, vb = (a.winner_id or 0),       (b.winner_id or 0);
                                    elseif (col == 25) then va, vb = (a.winner_name or ''),    (b.winner_name or '');
                                    elseif (col == 26) then va, vb = (a.player_lot or 0),      (b.player_lot or 0);
                                    elseif (col == 27) then va, vb = (a.player_action or 0),   (b.player_action or 0);
                                    elseif (col == 28) then va, vb = (a.drop_timestamp or 0),  (b.drop_timestamp or 0);
                                    elseif (col == 29) then va, vb = (a.is_distant or 0),      (b.is_distant or 0);
                                    elseif (col == 30) then va, vb = (a.level_cap or 0),       (b.level_cap or 0);
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

                        -- Time (date + time)
                        imgui.TableNextColumn();
                        imgui.TextDisabled(row._fmt_time or os_date('%m/%d %H:%M', row.timestamp or 0));
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(row._fmt_full or os_date('%Y-%m-%d %H:%M:%S', row.timestamp or 0));
                        end

                        imgui.TableNextColumn();
                        imgui.Text(display_mob_name(row.mob_name));

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
                        imgui.TextColored(src_color, tracker.get_source_label(row.source_type, tonumber(row.bf_difficulty)));

                        imgui.TableNextColumn();
                        render_combined_th(row.th_level or 0, row.th_estimated or 0, false);

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

                        widgets.optional_num_cell(row.moon_phase,   tracker.get_moon_phase_label);
                        widgets.optional_num_cell(row.moon_percent, pct_label);
                        widgets.optional_num_cell(row.weather,      tracker.get_weather_label);

                        -- BF Name
                        imgui.TableNextColumn();
                        local bfn = row.bf_name or '';
                        if (bfn ~= '') then
                            imgui.Text(bfn);
                        else
                            imgui.TextDisabled('-');
                        end

                        -- Difficulty
                        imgui.TableNextColumn();
                        local bfd = tonumber(row.bf_difficulty) or 0;
                        if (bfd > 0) then
                            imgui.Text(tracker.get_difficulty_label(bfd));
                        else
                            imgui.TextDisabled('-');
                        end

                        -- Content Type
                        imgui.TableNextColumn();
                        local ct = row.content_type or '';
                        if (ct ~= '') then
                            imgui.Text(ct);
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
                        if (is_empty or (row.item_id or 0) == 65535) then
                            -- Gil is always auto-obtained: a Got/Lost status is meaningless.
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
                        elseif ((row.player_action or 0) == 1) then
                            imgui.Text('Lot');
                        elseif ((row.player_action or 0) == 2) then
                            imgui.Text('Pass');
                        else
                            imgui.TextDisabled('-');
                        end

                        -- Drop Time
                        imgui.TableNextColumn();
                        if (is_empty) then
                            imgui.TextDisabled('-');
                        else
                            imgui.TextDisabled(row._fmt_drop or '-');
                        end

                        -- Distant kill
                        imgui.TableNextColumn();
                        local dist = tonumber(row.is_distant) or 0;
                        if (dist > 0) then
                            imgui.TextColored({ 0.4, 0.7, 1.0, 1.0 }, 'Yes');
                        else
                            imgui.TextDisabled('-');
                        end

                        -- Level cap
                        imgui.TableNextColumn();
                        local lcap = tonumber(row.level_cap);
                        if (lcap ~= nil and lcap > 0) then
                            imgui.Text(tostring(lcap));
                        else
                            imgui.TextDisabled('-');
                        end
                    end

                    imgui.EndTable();
                end

                -- Preview limit notice shown in button bar above
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

local M = {};

function M.bind(t)
    ui                 = t.ui;
    source_colors      = t.source_colors;
    status_colors      = t.status_colors;
    status_labels      = t.status_labels;
    display_mob_name   = t.display_mob_name;
    render_combined_th = t.render_combined_th;
    render_header_row  = t.render_header_row;
end

-- Refresh references after character or settings changes.
local function sync()
    db, tracker, analysis, s = state.db, state.tracker, state.analysis, state.s;
end

--- DB file size, sampled by ui.lua when the Export tab is first opened (it owns the tab-switch
--- edge detection); read by render_export_tab.
function M.set_db_size(n)
    db_size_cache = n or 0;
end

--- Filters from the last preview build -- lootscope.lua reads this when writing the CSV.
function M.get_export_filters()
    return ef.last_filters;
end

function M.render_tab()
    sync();
    return render_export_tab();
end

function M.render_window()
    sync();
    return render_advanced_export_window();
end

return M;
