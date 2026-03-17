--[[
    LootScope v1.3.1 - UI Module
    ImGui dashboard with Live Feed, Statistics, Slot Analysis, Export,
    and Settings tabs. Includes compact mode for minimal overlay.

    Author: SQLCommit
    Version: 1.3.1
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

-- Job abbreviation lookup (hoisted to avoid per-frame allocation)
local JOB_ABBRS = {
    [1]='WAR',[2]='MNK',[3]='WHM',[4]='BLM',[5]='RDM',[6]='THF',
    [7]='PLD',[8]='DRK',[9]='BST',[10]='BRD',[11]='RNG',[12]='SAM',[13]='NIN',
    [14]='DRG',[15]='SMN',[16]='BLU',[17]='COR',[18]='PUP',[19]='DNC',[20]='SCH',
    [21]='GEO',[22]='RUN',
};

-------------------------------------------------------------------------------
-- Module State
-------------------------------------------------------------------------------
local db = nil;
local tracker = nil;
local s = nil;  -- settings reference
local analysis = nil;  -- slot analysis module (may be nil if load failed)

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
local stats_source_filter = 0;      -- 0=Field, 1=Chest/Coffer, 2=BCNM, 3=HTBF, 4=Omen, 5=Ambu, 6=Sortie, 7=Dynamis, 8=AllBF, 9=AllInst, 10=Voidwatch, 11=Domain Invasion, 12=Wildskeeper
local stats_category = 0;           -- 0=Field, 1=Battlefields, 2=Instances, 3=Chest/Coffer, 4=Voidwatch, 5=Wildskeeper, 6=Domain Invasion
local stats_cache_source = -1;      -- source filter when cache was built
local stats_name_filter = nil;       -- name filter for BCNM/Chest-Coffer (nil = all)
local stats_cache_name = nil;        -- name filter when cache was built
local stats_detail_cache = {};       -- [row_key] -> { mob_stats, htbf_data, spawn_stats, spawn_items }

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
    source_idx      = { 0 },       -- 0=All, 1=Mob, 2=Chest, 3=Coffer, 4=BCNM, 5=HTBF
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
    filter_summary  = '',
    date_from_err   = false,
    date_to_err     = false,
    last_filters    = nil,
    -- Auto-update state
    auto_dirty      = false,
    text_dirty      = false,
    text_edit_time  = 0,
};

-- Slot Analysis tab state — consolidated into one table (upvalue hygiene)
local an = {
    category        = 0,       -- same as stats: 0=Field, 1=BF, 2=Inst, 3=Chest
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
    ci_sort_col     = 0,
    ci_sort_asc     = false,
    co_sort_col     = 0,
    co_sort_asc     = false,
    -- Filter combo cache (reuses build_stats_filter pattern)
    filter_combo    = { str = '', entries = nil, src = -1 },
    -- Mob combo cache
    mob_combo       = { str = '', mobs = nil, key = '' },
};

-- Reset confirmation input buffer
local reset_confirm_buf = { '' };
local reset_confirm_buf_size = 32;

-- Reusable widget buffers (avoid per-frame table allocation in render functions)
local stats_filter_idx = { 0 };
local an_mob_sel = { 0 };
local set_int_buf = { 0 };        -- Settings tab: SliderInt buffer
local set_float_buf = { 0.0 };    -- Settings tab: SliderFloat buffer
local set_bool_buf = { false };    -- Settings tab: Checkbox buffer

-- TH Advanced Management window state
local th_adv_open = { false };
local th_adv_profile_idx = { 0 };
local th_adv_items_cache = nil;
local th_adv_traits_cache = nil;
local th_adv_profile_id = nil;
local th_adv_dirty = true;
local th_adv_search_buf = { '' };
local th_adv_search_size = 64;
-- Add item popup
local th_add_open = false;
local th_add_item_id = { 0 };
local th_add_name_buf = { '' };
local th_add_name_size = 64;
local th_add_th_value = { 1 };
local th_add_slot_idx = { 0 };
local th_add_notes_buf = { '' };
local th_add_notes_size = 64;
local th_add_last_id = 0;  -- tracks last resolved ID for change detection

-- Reusable buffer for per-trait enable/disable checkbox (avoids per-frame allocation)
local th_trait_enabled_buf = { false };

-- Add Trait popup state
local th_add_trait_open = false;
local th_add_trait_job_idx = { 5 };   -- default THF (index 5 in 0-based combo)
local th_add_trait_role_idx = { 0 };  -- 0=Main, 1=Sub
local th_add_trait_level = { 1 };
local th_add_trait_th = { 1 };
-- New profile popup
local th_new_profile_buf = { '' };
local th_new_profile_size = 64;
local th_new_profile_open = false;
local th_clone_mode = false;
local th_new_profile_error = '';

-- TH profiles cache (avoid per-frame DB queries)
local th_profiles_cache = nil;
local th_profiles_dirty = true;

local function get_th_profiles_cached()
    if (th_profiles_dirty or th_profiles_cache == nil) then
        th_profiles_cache = db.get_th_profiles();
        th_profiles_dirty = false;
    end
    return th_profiles_cache;
end

-- Render combined TH value (shared by live feed, export preview, kills detail)
local function render_combined_th(th_srv, th_est, show_tooltip)
    local th_combined = math_max(th_srv, th_est);
    if (th_combined > 0) then
        if (th_srv > 0 and th_srv >= th_est) then
            imgui.Text(tostring(th_combined));
        else
            imgui.Text(tostring(th_combined) .. '*');
        end
    else
        imgui.TextDisabled('-');
    end
    if (show_tooltip and imgui.IsItemHovered()) then
        local tip = 'Treasure Hunter level on mob at time of kill.';
        if (th_srv > 0 and th_est > 0) then
            tip = tip .. '\nServer-confirmed: ' .. tostring(th_srv) .. '  |  Estimated: ' .. tostring(th_est);
            tip = tip .. '\nEstimate = job traits + gear + augments + kupowers';
        elseif (th_est > 0) then
            tip = tip .. '\n* = Estimated from job traits, gear, augments, and kupowers.';
            tip = tip .. '\nNo server TH proc (msg 603) was received for this mob.';
        elseif (th_srv > 0) then
            tip = tip .. '\nServer-confirmed via TH proc message.';
        end
        imgui.SetTooltip(tip);
    end
end

-- Static sort key maps for sortable analysis tables (hoisted to avoid per-frame allocation)
local ci_sort_keys = { 'item_name', 'drops', 'rate', 'ci_lower', 'ci_upper', 'ci_width', 'ci_width' };
local co_sort_keys = { 'name_a', 'name_b', 'observed', 'expected', 'deviation', 'order_consistency' };

-- Reset slot analysis filters when switching category (file scope to avoid per-frame closure)
local function reset_an_filter(new_source)
    an.source_filter = new_source;
    an.cache_dirty = true;
    an.zone_filter = -1;
    an.name_filter = nil;
    an.mob_filter = nil;
    an.mob_level_cap = nil;
    an.effective_sf = nil;
    an.mob_idx[1] = 0;
    an.result = nil;
    an.mob_stats = nil;
    an.ci_sort_col = 0;
    an.ci_sort_asc = false;
    an.co_sort_col = 0;
    an.co_sort_asc = false;
    an.mob_combo = { str = '', mobs = nil, key = '' };
end

-- Reset statistics filters when switching category (file scope to avoid per-frame closure)
local function reset_stats_filter(new_source)
    stats_source_filter = new_source;
    stats_cache_dirty = true;
    stats_expanded_mob = nil;
    stats_zone_filter = -1;
    stats_name_filter = nil;
end

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
local COLOR_LIGHT_GRAY  = { 0.8, 0.8, 0.8, 1.0 };
local COLOR_CONTENT     = { 0.5, 0.8, 1.0, 1.0 };
local COLOR_GRAY        = { 0.7, 0.7, 0.7, 1.0 };

-- HTBF difficulty badge colors
local difficulty_colors = {
    [1] = { 1.0, 0.3, 0.3, 1.0 },  -- VD (red)
    [2] = { 1.0, 0.6, 0.2, 1.0 },  -- D (orange)
    [3] = { 1.0, 1.0, 0.4, 1.0 },  -- N (yellow)
    [4] = { 0.4, 1.0, 0.4, 1.0 },  -- E (green)
    [5] = { 0.4, 0.8, 1.0, 1.0 },  -- VE (light blue)
};

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
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 48,  tip = 'Drop source: Mob, Chest, Coffer, BCNM, HTBF, or content-specific' },
    { key = 'item',       label = 'Item',    flags = FS,      width = 0,   tip = 'Item that appeared in the treasure pool' },
    { key = 'qty',        label = 'Qty',     flags = FW,      width = 30,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 25,  tip = 'Treasure Hunter level on mob at kill. Sources: server procs, gear scan, job traits, augments, kupowers. * = estimated (no server confirmation)' },
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
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 40,  tip = 'Drop source: Mob, Chest, Coffer, BCNM, HTBF, or content-specific' },
    { key = 'qty',        label = 'Qty',     flags = FW + DH, width = 25,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 22,  tip = 'Treasure Hunter level on mob at kill. Sources: server procs, gear scan, job traits, augments, kupowers. * = estimated (no server confirmation)' },
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
    { label = 'Source',  flags = EP_FW+EP_ASC,              width = 48,  id = 6,  tip = 'Drop source: Mob, Chest, Coffer, BCNM, HTBF, or content-specific' },
    { label = 'TH',      flags = EP_FW+EP_DSC,              width = 25,  id = 7,  tip = 'Treasure Hunter level on mob at kill. Sources: server procs, gear scan, job traits, augments, kupowers. * = estimated (no server confirmation)' },
    { label = 'Killer',  flags = EP_FW+EP_ASC,              width = 75,  id = 8,  tip = 'Entity that dealt the killing blow' },
    { label = 'TH Act',  flags = EP_FW+EP_ASC+EP_DH,        width = 55,  id = 9,  tip = 'Action type that last procced TH (melee, ranged, spell, etc.)' },
    { label = 'Act ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 10, tip = 'Specific ability/spell ID that procced TH' },
    { label = 'Day',     flags = EP_FW+EP_ASC,              width = 75,  id = 11, tip = "Vana'diel day of the week at time of kill" },
    { label = 'V.Hour',  flags = EP_FW+EP_ASC,              width = 42,  id = 12, tip = "Vana'diel hour (0-23) at time of kill" },
    { label = 'Moon',    flags = EP_FW+EP_ASC,              width = 90,  id = 13, tip = 'Moon phase at time of kill' },
    { label = 'Moon%',   flags = EP_FW+EP_DSC,              width = 42,  id = 14, tip = 'Moon illumination percentage (0-100)' },
    { label = 'Weather', flags = EP_FW+EP_ASC,              width = 80,  id = 15, tip = 'Weather condition at time of kill' },
    { label = 'BF Name', flags = EP_FW+EP_ASC+EP_DH,        width = 80,  id = 16, tip = 'Battlefield name (HTBF only)' },
    { label = 'Diff',    flags = EP_FW+EP_ASC+EP_DH,        width = 30,  id = 17, tip = 'HTBF difficulty: VD, D, N, E, VE' },
    { label = 'Content', flags = EP_FW+EP_ASC,              width = 70,  id = 18, tip = 'Content type: BCNM, HTBF, Dynamis, Voidwatch, Domain Invasion, Wildskeeper' },
    { label = 'Item',    flags = EP_FW+EP_ASC,              width = 110, id = 19, tip = 'Item that appeared in the treasure pool' },
    { label = 'ItemID',  flags = EP_FW+EP_DSC+EP_DH,        width = 40,  id = 20, tip = 'Numeric item ID from the game database' },
    { label = 'Qty',     flags = EP_FW+EP_DSC,              width = 25,  id = 21, tip = 'Quantity of the item dropped' },
    { label = 'Lot',     flags = EP_FW+EP_DSC,              width = 30,  id = 22, tip = 'Winning lot value (0-999)' },
    { label = 'Status',  flags = EP_FW+EP_DSC,              width = 40,  id = 23, tip = 'Won, Lost, Inv Full, Zoned, or Pending' },
    { label = 'Win ID',  flags = EP_FW+EP_DSC+EP_DH,        width = 45,  id = 24, tip = 'Server entity ID of the player who won the item' },
    { label = 'Winner',  flags = EP_FW+EP_ASC,              width = 75,  id = 25, tip = 'Player who won the item' },
    { label = 'P.Lot',   flags = EP_FW+EP_DSC+EP_DH,        width = 35,  id = 26, tip = 'Your lot value on this item' },
    { label = 'P.Act',   flags = EP_FW+EP_DSC+EP_DH,        width = 32,  id = 27, tip = 'Your action: 1=Lotted, 0=Passed' },
    { label = 'Drop At', flags = EP_FW+EP_DSC,              width = 55,  id = 28, tip = 'Time the drop appeared in the treasure pool' },
    { label = 'Distant',flags = EP_FW+EP_DSC+EP_DH,        width = 42,  id = 29, tip = 'Distant kill: drops seen but no defeat message (biased sample)' },
    { label = 'Lvl Cap',flags = EP_FW+EP_DSC+EP_DH,        width = 42,  id = 30, tip = 'BCNM level cap (20/40/60/75 or uncapped)' },
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

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function ui.init(db_ref, tracker_ref, settings_ref, analysis_ref)
    db = db_ref;
    tracker = tracker_ref;
    s = settings_ref;
    analysis = analysis_ref;
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

    -- Unified feed (kills + drops + chest events), filtered client-side
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
        local has_bf = (row.battlefield ~= nil and row.battlefield ~= '');

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
            local bf_diff = tonumber(row.bf_difficulty);
            local src_color = source_colors[row.source_type] or source_colors[0];
            local src_label = tracker.get_source_label(row.source_type, bf_diff);
            local ct = row.content_type or '';
            if (row.source_type ~= 0) then
                imgui.TextColored(src_color, '[' .. src_label .. '] ');
                imgui.SameLine(0, 0);
            elseif (has_bf) then
                -- Mob kill inside a BCNM/HTBF — show battlefield prefix
                local bf_label = (bf_diff ~= nil and bf_diff > 0) and 'HTBF' or 'BCNM';
                imgui.TextColored(source_colors[3], '[' .. bf_label .. '] ');
                imgui.SameLine(0, 0);
            elseif (ct ~= '') then
                -- Content type badge (Omen, Sortie, Dynamis, Ambuscade)
                imgui.TextColored(COLOR_CONTENT, '[' .. ct .. '] ');
                imgui.SameLine(0, 0);
            end
            imgui.Text(row.mob_name or '');
            -- HTBF difficulty badge (inline after mob name)
            if (bf_diff ~= nil and bf_diff > 0) then
                imgui.SameLine(0, 4);
                local dc = difficulty_colors[bf_diff] or COLOR_GRAY;
                imgui.TextColored(dc, '[' .. tracker.get_difficulty_label(bf_diff) .. ']');
            end
            if imgui.IsItemHovered() then
                local tip = row.mob_name or '';
                if (row.mob_server_id ~= nil and row.mob_server_id > 0) then
                    tip = tip .. string_format('\nMob ID: %.0f', tonumber(row.mob_server_id));
                end
                if (row.zone_name ~= nil and row.zone_name ~= '') then
                    tip = tip .. '\nZone: ' .. row.zone_name;
                end
                if (has_bf) then
                    tip = tip .. '\nBattlefield: ' .. row.battlefield;
                end
                if (bf_diff ~= nil and bf_diff > 0) then
                    tip = tip .. '\nDifficulty: ' .. tracker.get_difficulty_full_label(bf_diff);
                    local bf_name = row.bf_name;
                    if (bf_name ~= nil and bf_name ~= '') then
                        tip = tip .. '\nHTBF: ' .. bf_name;
                    end
                end
                if (ct ~= '') then
                    tip = tip .. '\nContent: ' .. ct;
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
            local bf_d = tonumber(row.bf_difficulty);
            local src_c;
            local src_l;
            local row_ct = row.content_type or '';
            if (row.source_type == 0 and has_bf) then
                -- Mob kill inside battlefield: show BCNM/HTBF label
                src_c = source_colors[3];
                src_l = (bf_d ~= nil and bf_d > 0) and 'HTBF' or 'BCNM';
            elseif (row.source_type == 0 and row_ct ~= '') then
                -- Mob kill inside content zone: show content type
                src_c = COLOR_CONTENT;
                src_l = row_ct;
            else
                src_c = source_colors[row.source_type] or source_colors[0];
                src_l = tracker.get_source_label(row.source_type, bf_d);
            end
            imgui.TextColored(src_c, src_l);
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
        render_combined_th(row.th_level or 0, row.th_estimated or 0, true);

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
                va, vb = a.kill_count, b.kill_count;
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
        -- Content types (Dynamis; Omen/Ambuscade/Sortie WIP): unique zones
        for _, row in ipairs(all_stats) do
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name, zone_id = row.zone_id, name = nil });
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
    -- Row 1a: General content categories (Field | Battlefields | Instances | Chest/Coffer)
    if imgui.RadioButton('Field', stats_category == 0) then
        stats_category = 0;
        reset_stats_filter(0);
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Field Statistics (Open-World Mobs)\n'
            .. '------------------------------\n'
            .. 'Mob kills outside instanced content.\n'
            .. 'Excludes Dynamis and other instanced content.\n\n'
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
    if imgui.RadioButton('Battlefields', stats_category == 1) then
        stats_category = 1;
        reset_stats_filter(8);  -- default to All Battlefields
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Battlefield Statistics (BCNM + HTBF)\n'
            .. '------------------------------\n'
            .. 'Burning Circle Notorious Monsters and\n'
            .. 'High-Tier Battlefields (difficulty-based).\n\n'
            .. '  BCNM\n'
            .. '  Groups by battlefield name (drops from chest).\n'
            .. '  Name from entry chat message.\n'
            .. '  Level cap detected from job level change.\n'
            .. '  KSNMs show no cap (uncapped).\n\n'
            .. '  HTBF\n'
            .. '  Groups by battlefield name + difficulty.\n'
            .. '  Items drop directly after kill (no chest).\n'
            .. '  VD, D, N, E, VE detected from 0x005C packet.\n'
            .. '  Name resolved from zone dialog DAT files.\n\n'
            .. '  Addon Reload Recovery\n'
            .. '  Session persisted to DB. On reload, buff icon\n'
            .. '  254 confirms active battlefield, name recovered.');
    end

    imgui.SameLine();
    if imgui.RadioButton('Instances', stats_category == 2) then
        stats_category = 2;
        reset_stats_filter(7);  -- default to Dynamis (only supported instance)
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Instance Statistics\n'
            .. '------------------------------\n'
            .. 'Currently supports Dynamis only.\n'
            .. 'Dynamis detected by zone name prefix.\n\n'
            .. '  Dynamis — Original (10 zones) + Divergence (4 zones)\n\n'
            .. 'Ambuscade, Omen, and Sortie are WIP —\n'
            .. 'more packet research needed.\n\n'
            .. 'All kills are grouped by mob name per zone.');
    end

    imgui.SameLine();
    if imgui.RadioButton('Chest/Coffer', stats_category == 3) then
        stats_category = 3;
        reset_stats_filter(1);
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

    -- Row 1b: Buff-based content categories
    if imgui.RadioButton('Voidwatch', stats_category == 4) then
        stats_category = 4;
        reset_stats_filter(10);
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Voidwatch Statistics\n'
            .. '------------------------------\n'
            .. 'Loot from Riftworn Pyxis after VW NM kills.\n\n'
            .. 'Detection: entity name "Planar Rift" or\n'
            .. '"Riftworn Pyxis" during NPC interaction.\n\n'
            .. 'Items recorded from Pyxis event data\n'
            .. '(bypasses treasure pool - uses 0x034).\n\n'
            .. 'All offered items are recorded as drops.\n'
            .. 'Taken = won, relinquished = lost.');
    end
    imgui.SameLine();
    if imgui.RadioButton('Wildskeeper', stats_category == 5) then
        stats_category = 5;
        reset_stats_filter(12);
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Wildskeeper Reive Statistics\n'
            .. '------------------------------\n'
            .. 'Loot from Naakual boss kills.\n\n'
            .. 'Detection: Reive Mark buff (511)\n'
            .. '+ Naakual boss defeat.\n\n'
            .. 'Items delivered directly to inventory\n'
            .. 'via Event 2007 (no treasure pool).\n\n'
            .. 'All items are auto-obtained (won=1).');
    end
    imgui.SameLine();
    if imgui.RadioButton('Domain Inv.', stats_category == 6) then
        stats_category = 6;
        reset_stats_filter(11);
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Domain Invasion Statistics\n'
            .. '------------------------------\n'
            .. 'Kills during Domain Invasion events\n'
            .. 'in Escha zones.\n\n'
            .. 'Detection: Elvorseal buff (603)\n'
            .. 'in Escha Zi\'Tah/Ru\'Aun/Reisenjima.\n\n'
            .. 'Uses normal treasure pool for drops.');
    end

    -- Row 2: Sub-filter radio buttons (Battlefields: All/BCNM/HTBF, Instances: Dynamis)
    if (stats_category == 1) then
        -- Battlefields: All | BCNM | HTBF
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
    elseif (stats_category == 2) then
        -- Instances: Dynamis only for now; Ambuscade/Omen/Sortie are WIP
        if imgui.RadioButton('Dynamis', stats_source_filter == 7) then
            reset_stats_filter(7);
        end
        imgui.SameLine();
        imgui.TextDisabled('Ambuscade / Omen / Sortie (WIP)');
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

    -- BCNM view:   Battlefield | Zone | Lv Cap     | Runs  | Unique Items | Avg Drops
    -- HTBF view:   Battlefield | Zone | Difficulty | Runs  | Unique Items | Avg Drops
    -- All BF view: Battlefield | Zone | Runs       | Unique Items | Avg Drops | (empty)
    -- Chest view:  Container   | Zone | Opens      | Items | Gil          | Failures
    -- Mob view:    Mob Name    | Zone | Kills      | Unique Items | Spawns | Avg Drops
    local num_cols = is_all_bf and 7 or 6;
    if not imgui.BeginTable('stats_table', num_cols, table_flags, { 0, 0 }) then return; end

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
                sort_stats(stats_cache_data, col, asc, is_bcnm or is_all_bf, is_chest_mode, is_htbf);
            end
        end
    end

    for _, row in ipairs(stats_cache_data) do
        imgui.TableNextRow();

        local row_disambig;
        if (is_all_bf) then
            row_disambig = tostring(row.level_cap or 0) .. '_' .. tostring(row.bf_difficulty or 0);
        elseif (is_htbf) then
            row_disambig = tostring(row.bf_difficulty or 0);
        else
            row_disambig = tostring(row.level_cap or 'nil');
        end
        local row_key = row.mob_name .. '_' .. tostring(row.zone_id) .. '_' .. row_disambig;
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
            imgui.TableNextColumn();
            imgui.Text(tostring(row.kill_count));

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

            -- Column 4: Runs (kill_count)
            imgui.TableNextColumn();
            imgui.Text(tostring(row.kill_count));

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
            local detail_cap = is_htbf and row.bf_difficulty or row.level_cap;
            local detail_bf_diff = is_all_bf and (row.bf_difficulty or 0) or nil;
            local detail = stats_detail_cache[row_key];
            if (detail == nil) then
                detail = { mob_stats = db.get_mob_stats(row.mob_name, row.zone_id, stats_source_filter, detail_cap, detail_bf_diff) };
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
                    end

                    imgui.TableNextColumn();
                    if (mob_distant > 0 and item.nearby_times_dropped ~= nil) then
                        local distant_d = item.times_dropped - item.nearby_times_dropped;
                        imgui.TextDisabled(tostring(item.nearby_times_dropped) .. 'x');
                        if (distant_d > 0) then
                            imgui.SameLine(0, 2);
                            imgui.TextColored(COLOR_BLUE_MUTED, '(+' .. tostring(distant_d) .. ')');
                        end
                    else
                        imgui.TextDisabled(tostring(item.times_dropped) .. 'x');
                    end

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
                                'Nearby: %d / %d = %.1f%%%%\n'
                                .. 'Combined: %d / %d = %.1f%%%%\n\n'
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
                end
            end

            -- HTBF difficulty breakdown (only for BCNM view — shows per-difficulty stats)
            if (is_bcnm) then
                if (detail.htbf_data == nil) then
                    detail.htbf_data = db.get_htbf_breakdown(row.mob_name, row.zone_id) or {};
                end
                local htbf_data = detail.htbf_data;
                if (htbf_data ~= nil and #htbf_data > 0) then
                    imgui.TableNextRow();
                    imgui.TableNextColumn();
                    imgui.TextDisabled('  -- Difficulty Breakdown --');
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();
                    imgui.TableNextColumn();

                    for _, hrow in ipairs(htbf_data) do
                        imgui.TableNextRow();

                        imgui.TableNextColumn();
                        local dc = difficulty_colors[hrow.bf_difficulty] or COLOR_GRAY;
                        local dlabel = tracker.get_difficulty_full_label(hrow.bf_difficulty);
                        imgui.TextColored(dc, '    [' .. tracker.get_difficulty_label(hrow.bf_difficulty) .. '] ' .. dlabel);
                        if imgui.IsItemHovered() and (hrow.bf_name ~= nil and hrow.bf_name ~= '') then
                            imgui.SetTooltip('Battlefield: ' .. hrow.bf_name);
                        end

                        imgui.TableNextColumn(); -- zone (blank)

                        imgui.TableNextColumn(); -- lv cap (blank)

                        imgui.TableNextColumn(); -- runs
                        imgui.TextDisabled(tostring(hrow.kill_count));

                        imgui.TableNextColumn(); -- unique items
                        imgui.TextDisabled(tostring(hrow.unique_items));

                        imgui.TableNextColumn(); -- avg drops
                        imgui.TextDisabled(string_format('%.1f', hrow.avg_drops));
                    end
                end
            end

            -- Per-spawn breakdown (only for Mob view — not applicable for BF or Chest/Coffer)
            -- Show section when spawn IDs have item drops.
            -- Hide individual spawns that only have gil drops (0 unique items).
            if (not is_bcnm and not is_htbf and not is_all_bf and not is_chest_mode) then
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

    -- Combo: 0=All, 1=Field, 2=Chest/Coffer, 3=AllBF, 4=BCNM, 5=HTBF, 6=Dynamis, 7=VW, 8=DI
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
            if imgui.Combo('##exp_source', ef.source_idx, 'All\0Field\0Chest/Coffer\0All BF\0BCNM\0HTBF\0Dynamis\0Voidwatch\0Domain Invasion\0Wildskeeper\0\0') then
                ef.auto_dirty = true;
            end
            imgui.PopItemWidth();
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Filter by content type.\nField = open-world mobs (no instances).\nAll BF = BCNM + HTBF combined.');
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

                -- ScrollY requires explicit height; y=0 sizes the table to zero.
                -- Use remaining content region so the table fills available space.
                local _, avail_h = imgui.GetContentRegionAvail();
                if (avail_h < 60) then avail_h = 60; end  -- minimum usable height

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

-------------------------------------------------------------------------------
-- Slot Analysis Tab
-------------------------------------------------------------------------------

-- Color constants for slot analysis (pre-allocated)
local COLOR_YELLOW  = { 1.0, 0.9, 0.3, 1.0 };
local COLOR_CYAN    = { 0.4, 0.9, 1.0, 1.0 };

--- Build zone/battlefield filter combo for slot analysis (mirrors stats filter).
local function build_an_filter(source_filter)
    if (an.filter_combo.src == source_filter
        and an.filter_combo.entries ~= nil
        and not db.stats_dirty and not an.cache_dirty) then
        return an.filter_combo.str, an.filter_combo.entries;
    end

    local all_stats = db.get_all_mob_stats(source_filter);
    local entries = T{};
    local seen = {};

    if (source_filter == 2 or source_filter == 3 or source_filter == 8) then
        -- BCNM/HTBF/All BF: unique battlefield + zone + level_cap/difficulty combos
        for _, row in ipairs(all_stats) do
            -- sf=2: cap=level_cap, sf=3: cap=bf_difficulty, sf=8: detect per row
            local lc = row.level_cap or 0;
            local bd = row.bf_difficulty or 0;
            local cap, eff_sf;
            if (source_filter == 3 or (source_filter == 8 and bd > 0)) then
                cap = bd;
                eff_sf = 3;  -- HTBF path
            else
                cap = lc;
                eff_sf = 2;  -- BCNM path
            end

            local key = tostring(row.zone_id) .. '_' .. (row.mob_name or '') .. '_' .. tostring(lc) .. '_' .. tostring(bd);
            if (not seen[key]) then
                seen[key] = true;
                local label = row.zone_name .. ' - ' .. row.mob_name;
                if (bd > 0) then
                    label = label .. ' [' .. tracker.get_difficulty_label(bd) .. ']';
                elseif (lc > 0) then
                    label = label .. ' (Lv' .. tostring(lc) .. ')';
                end
                entries:append({
                    label = label,
                    zone_id = row.zone_id,
                    name = row.mob_name,
                    level_cap = cap,
                    effective_sf = eff_sf,
                });
            end
        end
    else
        -- All other types: unique zones
        for _, row in ipairs(all_stats) do
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name, zone_id = row.zone_id, name = nil });
            end
        end
        -- Chest/Coffer: also include zones with only chest_events
        if (source_filter == 1) then
            local chest_stats = db.get_chest_stats();
            for _, row in ipairs(chest_stats) do
                if (not seen[row.zone_id]) then
                    seen[row.zone_id] = true;
                    entries:append({ label = row.zone_name or '', zone_id = row.zone_id, name = nil });
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.label < b.label; end);

    local parts = { 'Select...' };
    for _, e in ipairs(entries) do
        parts[#parts + 1] = e.label;
    end

    an.filter_combo.str = table.concat(parts, '\0') .. '\0\0';
    an.filter_combo.entries = entries;
    an.filter_combo.src = source_filter;

    return an.filter_combo.str, an.filter_combo.entries;
end

--- Build mob name combo for a selected zone/battlefield.
local function build_mob_combo(source_filter, zone_id, name_filter)
    local cache_key = tostring(source_filter) .. '_' .. tostring(zone_id) .. '_' .. tostring(name_filter or '');
    if (an.mob_combo.key == cache_key and an.mob_combo.mobs ~= nil and not db.stats_dirty and not an.cache_dirty) then
        return an.mob_combo.str, an.mob_combo.mobs;
    end

    local all_stats = db.get_all_mob_stats(source_filter);
    local mobs = T{};
    local seen = {};

    for _, row in ipairs(all_stats) do
        if (row.zone_id == zone_id) then
            local match = true;
            if (name_filter ~= nil and name_filter ~= '') then
                if (source_filter == 2) then
                    match = (row.mob_name == name_filter);
                elseif (source_filter == 3) then
                    match = (row.mob_name == name_filter);
                end
            end
            if (match and not seen[row.mob_name]) then
                seen[row.mob_name] = true;
                local total = row.kill_count or 0;
                local distant = row.distant_kills or 0;
                mobs:append({
                    mob_name  = row.mob_name,
                    zone_id   = row.zone_id,
                    kills     = total - distant,
                    level_cap = row.level_cap or row.bf_difficulty,
                });
            end
        end
    end

    -- Sort by kill count descending (most data first)
    table.sort(mobs, function(a, b) return a.kills > b.kills; end);

    local parts = { 'Select mob...' };
    for _, m in ipairs(mobs) do
        parts[#parts + 1] = m.mob_name .. ' (' .. tostring(m.kills) .. ' kills)';
    end

    an.mob_combo.str = table.concat(parts, '\0') .. '\0\0';
    an.mob_combo.mobs = mobs;
    an.mob_combo.key = cache_key;

    return an.mob_combo.str, an.mob_combo.mobs;
end

--- Render Section 1: Confidence Intervals.
local function render_ci_section(result, kills)
    local ci = result.confidence;
    if (#ci == 0) then
        imgui.TextDisabled('No item drops recorded.');
        return;
    end

    local kw = result.is_battlefield and 'runs' or 'kills';
    if (kills < analysis.MIN_KILLS_CI) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Results below %d %s may be unreliable — more data improves accuracy.',
            kills, kw, analysis.MIN_KILLS_CI, kw));
    end

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_Sortable,
        ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##ci_table', 7, flags, { 0, math_min(#ci * 24 + 28, 300) }) then
        imgui.TableSetupColumn('Item', ImGuiTableColumnFlags_DefaultSort, 150);
        imgui.TableSetupColumn('Drops', ImGuiTableColumnFlags_PreferSortDescending, 50);
        imgui.TableSetupColumn('Rate', ImGuiTableColumnFlags_PreferSortDescending, 55);
        imgui.TableSetupColumn('CI Low', ImGuiTableColumnFlags_PreferSortAscending, 55);
        imgui.TableSetupColumn('CI High', ImGuiTableColumnFlags_PreferSortDescending, 55);
        imgui.TableSetupColumn('Width', ImGuiTableColumnFlags_PreferSortAscending, 55);
        imgui.TableSetupColumn('Reliability', 0, 70);
        imgui.TableHeadersRow();

        -- Read sort specs and sort only when spec changes (no per-frame sort)
        local sort_specs = imgui.TableGetSortSpecs();
        if (sort_specs ~= nil and sort_specs.Specs ~= nil) then
            local new_col = sort_specs.Specs.ColumnIndex + 1;
            local new_asc = (sort_specs.Specs.SortDirection == 1);
            if (new_col ~= an.ci_sort_col or new_asc ~= an.ci_sort_asc) then
                an.ci_sort_col = new_col;
                an.ci_sort_asc = new_asc;
                local key = ci_sort_keys[new_col];
                if (key ~= nil) then
                    if (new_asc) then
                        table.sort(ci, function(a, b) return a[key] < b[key]; end);
                    else
                        table.sort(ci, function(a, b) return a[key] > b[key]; end);
                    end
                end
            end
        end

        for _, row in ipairs(ci) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.item_name);
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('Item dropped %d times out of %d nearby %s.', row.drops, row.kills, kw));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('Observed rate: %d / %d = %.2f%%%%\nThis is the raw observed rate (drops / %s).', row.drops, row.kills, row.rate * 100, kw));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.ci_lower * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Lower bound of the 95%% confidence interval.\nThe true drop rate is very likely above this value.');
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.ci_upper * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Upper bound of the 95%% confidence interval.\nThe true drop rate is very likely below this value.');
            end

            -- Width color-coded
            imgui.TableNextColumn();
            local width_pct = row.ci_width * 100;
            local width_color = COLOR_GREEN;
            if (width_pct > 15) then width_color = COLOR_RED;
            elseif (width_pct > 5) then width_color = COLOR_WARN; end
            imgui.TextColored(width_color, string_format('%.1f%%', width_pct));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'CI Width = upper bound - lower bound = %.1f%%%%\n'
                    .. 'Narrower = more precise estimate.\n\n'
                    .. 'Green: < 5%%%%  |  Yellow: 5-15%%%%  |  Red: > 15%%%%',
                    width_pct));
            end

            -- Reliability badge
            imgui.TableNextColumn();
            local rel_label, rel_color;
            if (width_pct <= 5) then
                rel_label = 'High'; rel_color = COLOR_GREEN;
            elseif (width_pct <= 15) then
                rel_label = 'Medium'; rel_color = COLOR_WARN;
            else
                rel_label = 'Low'; rel_color = COLOR_RED;
            end
            imgui.TextColored(rel_color, rel_label);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%d drops / %d %s = %.1f%%%%\n95%%%% CI: [%.1f%%%%, %.1f%%%%] (width %.1f%%%%)\n\n%s',
                    row.drops, row.kills, kw, row.rate * 100,
                    row.ci_lower * 100, row.ci_upper * 100, width_pct,
                    width_pct > 15 and ('More ' .. kw .. ' needed for tighter estimate.') or 'Estimate is reliable.'));
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 2: Slot Count Estimation.
local function render_slot_section(result)
    local se = result.slot_estimate;
    if (se == nil) then return; end

    -- Headline: Estimated Slots (best evidence from all metrics)
    local est_slots = math.max(se.max_observed, math.ceil(se.rate_sum));
    imgui.TextColored(COLOR_GREEN, string_format('Estimated Slots: %d', est_slots));
    if imgui.IsItemHovered() then
        imgui.SetTooltip(string_format(
            'Best estimate based on strongest evidence:\n' ..
            '  - Max items in one kill: %d (hard lower bound)\n' ..
            '  - Ceil of rate sum: %d (from %.2f total)\n' ..
            '  - Unique items seen: %d (upper bound)\n\n' ..
            'True slot count is between %d and %d.',
            se.max_observed, math.ceil(se.rate_sum), se.rate_sum,
            se.unique_items, est_slots, se.unique_items
        ));
    end
    imgui.Spacing();

    local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_NoHostExtendX);
    if imgui.BeginTable('##slot_tbl', 2, tflags) then
        imgui.TableSetupColumn('Label', 0, 200);
        imgui.TableSetupColumn('Value', 0, 250);

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Unique items seen:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.unique_items));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Total distinct items (excluding gil) dropped by this mob.\nThis is the upper bound on how many drop slots exist.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Max items in one kill:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.max_observed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Hard lower bound on the number of independent drop slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Sum of all rates:');
        imgui.TableNextColumn();
        local rate_color = (se.rate_sum > 1.0) and COLOR_GREEN or COLOR_LIGHT_GRAY;
        imgui.TextColored(rate_color, string_format('%.2f', se.rate_sum));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('If > 1.0, items MUST be on separate independent slots.\nHigher values = more evidence for multiple slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Avg items per kill:');
        imgui.TableNextColumn(); imgui.Text(string_format('%.2f', se.avg_items_per_kill));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Average number of items (excluding gil) per kill.\nHigher values suggest more active drop slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Separator(); imgui.Text('Empty kills (observed):');
        imgui.TableNextColumn(); imgui.Separator();
        imgui.Text(string_format('%d (%.1f%%)', se.empty_observed_count, se.empty_observed_rate * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip(string_format(
                'Kills where zero items dropped (excluding gil).\n'
                .. '%d out of %d kills (%.1f%%%%).\n\n'
                .. 'Compare with expected rate below to evaluate model fit.',
                se.empty_observed_count, se.total_kills, se.empty_observed_rate * 100));
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Empty kills (expected):');
        imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', se.empty_expected_rate * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Predicted from independent slot model:\nProduct of (1 - rate_i) for all items.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Model fit:');
        imgui.TableNextColumn();
        local dev = math.abs(se.empty_observed_rate - se.empty_expected_rate);
        local fit_label, fit_color;
        if (dev < 0.05) then
            fit_label = 'Good'; fit_color = COLOR_GREEN;
        elseif (dev < 0.15) then
            fit_label = 'Fair'; fit_color = COLOR_WARN;
        else
            fit_label = 'Poor'; fit_color = COLOR_RED;
        end
        imgui.TextColored(fit_color, string_format('%s (%.1f%%%% deviation)', fit_label, dev * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Compares observed vs predicted empty kill rate.\nGood = independent slot model fits well.\nPoor = slots may not be independent (shared slots?).');
        end

        imgui.EndTable();
    end
end

--- Render Section 3: Items-Per-Kill Distribution.
local function render_distribution_section(result)
    local dist = result.distribution;
    if (dist == nil or #dist.bins == 0) then
        imgui.TextDisabled('No distribution data.');
        return;
    end

    local is_bf = result.is_battlefield;
    local kill_word = is_bf and 'encounter' or 'kill';

    local bins = dist.bins;
    local max_k = #bins;

    -- Build float arrays for PlotHistogram (cached on dist to avoid per-frame alloc)
    if (dist._obs_vals == nil) then
        local obs = {};
        local exp = {};
        local mr = 0;
        for i = 1, max_k do
            obs[i] = bins[i].obs_rate;
            exp[i] = bins[i].exp_rate;
            if (bins[i].obs_rate > mr) then mr = bins[i].obs_rate; end
            if (bins[i].exp_rate > mr) then mr = bins[i].exp_rate; end
        end
        dist._obs_vals = obs;
        dist._exp_vals = exp;
        dist._max_rate = mr;
    end
    local obs_vals = dist._obs_vals;
    local exp_vals = dist._exp_vals;
    local max_rate = dist._max_rate;

    -- Two histograms side by side
    imgui.Text('Observed:');
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Actual distribution of items dropped per ' .. kill_word .. '.\nEach bar = how often that many items dropped.');
    end
    imgui.SameLine(215);
    imgui.Text('Expected (independent model):');
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Predicted distribution if all drop slots are\nindependent (Poisson Binomial model).\nShould match observed if model is correct.');
    end

    imgui.PlotHistogram('##obs_hist', obs_vals, max_k, 0, '', 0, max_rate * 1.2, { 200, 80 });
    if imgui.IsItemHovered() then
        local tip_parts = {};
        for i = 1, max_k do
            tip_parts[#tip_parts + 1] = string_format('%d items: %.1f%%%%', bins[i].items, bins[i].obs_rate * 100);
        end
        imgui.SetTooltip(table.concat(tip_parts, '\n'));
    end
    imgui.SameLine();
    imgui.PlotHistogram('##exp_hist', exp_vals, max_k, 0, '', 0, max_rate * 1.2, { 200, 80 });
    if imgui.IsItemHovered() then
        local tip_parts = {};
        for i = 1, max_k do
            tip_parts[#tip_parts + 1] = string_format('%d items: %.1f%%%%', bins[i].items, bins[i].exp_rate * 100);
        end
        imgui.SetTooltip(table.concat(tip_parts, '\n'));
    end

    imgui.Spacing();

    -- Comparison table
    local tflags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp);
    if imgui.BeginTable('##dist_table', 4, tflags, { 0, math_min(max_k * 24 + 28, 200) }) then
        imgui.TableSetupColumn('Items', 0, 50);
        imgui.TableSetupColumn('Observed', 0, 70);
        imgui.TableSetupColumn('Expected', 0, 70);
        imgui.TableSetupColumn('Diff', 0, 60);
        imgui.TableHeadersRow();

        for _, b in ipairs(bins) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(tostring(b.items));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Number of items (excluding gil) dropped in a single ' .. kill_word .. '.');
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', b.obs_rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Observed: %.1f%%%% of %ss dropped exactly %d item(s).',
                    b.obs_rate * 100, kill_word, b.items));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', b.exp_rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected: %.1f%%%% from the Poisson Binomial model\n'
                    .. '(independent slots with observed per-item rates).',
                    b.exp_rate * 100));
            end

            imgui.TableNextColumn();
            local diff_abs = math.abs(b.diff) * 100;
            local diff_color = COLOR_GREEN;
            if (diff_abs > 10) then diff_color = COLOR_RED;
            elseif (diff_abs > 3) then diff_color = COLOR_WARN; end
            local sign = (b.diff >= 0) and '+' or '';
            imgui.TextColored(diff_color, string_format('%s%.1f%%', sign, b.diff * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%d-item %ss: observed %.1f%%%% vs expected %.1f%%%%\n%s',
                    b.items, kill_word, b.obs_rate * 100, b.exp_rate * 100,
                    diff_abs > 10 and 'Large deviation — model may not fit well.' or
                    diff_abs > 3 and 'Moderate deviation — more data may help.' or
                    'Good fit — model matches observation.'));
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 4: Co-occurrence Analysis.
local function render_cooccurrence_section(result, kills)
    local kw = result.is_battlefield and 'runs' or 'kills';
    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Co-occurrence results below %d %s may be unreliable.',
            kills, kw, analysis.MIN_KILLS_COOCCURRENCE, kw));
    end

    local co = result.cooccurrence;
    if (#co == 0) then
        imgui.TextDisabled('No co-occurring item pairs found (need items with 5+ drops each).');
        return;
    end

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_Sortable,
        ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##co_table', 6, flags, { 0, math_min(#co * 24 + 28, 300) }) then
        imgui.TableSetupColumn('Item A', ImGuiTableColumnFlags_DefaultSort, 130);
        imgui.TableSetupColumn('Item B', 0, 130);
        imgui.TableSetupColumn('Observed', ImGuiTableColumnFlags_PreferSortDescending, 60);
        imgui.TableSetupColumn('Expected', ImGuiTableColumnFlags_PreferSortDescending, 60);
        imgui.TableSetupColumn('Deviation', ImGuiTableColumnFlags_PreferSortDescending, 65);
        imgui.TableSetupColumn('Order', ImGuiTableColumnFlags_PreferSortDescending, 80);
        imgui.TableHeadersRow();

        -- Read sort specs and sort only when spec changes (no per-frame sort)
        local sort_specs = imgui.TableGetSortSpecs();
        if (sort_specs ~= nil and sort_specs.Specs ~= nil) then
            local new_col = sort_specs.Specs.ColumnIndex + 1;
            local new_asc = (sort_specs.Specs.SortDirection == 1);
            if (new_col ~= an.co_sort_col or new_asc ~= an.co_sort_asc) then
                an.co_sort_col = new_col;
                an.co_sort_asc = new_asc;
                local key = co_sort_keys[new_col];
                if (key ~= nil) then
                    if (new_asc) then
                        table.sort(co, function(a, b) return (a[key] or 0) < (b[key] or 0); end);
                    else
                        table.sort(co, function(a, b) return (a[key] or 0) > (b[key] or 0); end);
                    end
                end
            end
        end

        for _, row in ipairs(co) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.name_a);
            imgui.TableNextColumn(); imgui.Text(row.name_b);
            imgui.TableNextColumn(); imgui.Text(tostring(row.observed));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('These items dropped together %d times.', row.observed));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f', row.expected));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected co-occurrences if independent:\nP(A) * P(B) * %s = %.1f',
                    kw, row.expected));
            end

            -- Deviation color
            imgui.TableNextColumn();
            local dev = row.deviation;
            local dev_color = COLOR_GREEN;
            if (dev < 0.5 or dev > 2.0) then dev_color = COLOR_RED;
            elseif (dev < 0.8 or dev > 1.2) then dev_color = COLOR_WARN; end
            imgui.TextColored(dev_color, string_format('%.2fx', dev));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Observed / Expected co-occurrence.\n1.0 = perfect independence.\n> 1.0 = co-occur more than expected.\n< 1.0 = co-occur less (possible shared slot).');
            end

            -- Order column
            imgui.TableNextColumn();
            if (row.order_text ~= nil) then
                local oc = row.order_consistency;
                local oc_color = COLOR_GREEN;
                if (oc < 0.7) then oc_color = COLOR_GRAY;
                elseif (oc < 0.9) then oc_color = COLOR_WARN; end
                imgui.TextColored(oc_color, row.order_text);
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('When both items drop, which arrives first?\nHigh consistency (>90%%) = separate drop table slots\nwith predictable ordering.');
                end
            else
                imgui.TextDisabled('--');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('No drop order data available.\nOrder tracking starts after v1.1.1 migration.');
                end
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 5: Shared Slot Candidates.
local function render_shared_slots_section(result, kills)
    local kw = result.is_battlefield and 'runs' or 'kills';
    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Shared slot detection below %d %s may produce false positives.',
            kills, kw, analysis.MIN_KILLS_COOCCURRENCE, kw));
    end

    local ss = result.shared_slot_candidates;
    if (#ss == 0) then
        imgui.TextColored(COLOR_GREEN, 'No shared slot candidates detected.');
        imgui.TextDisabled('All item pairs with sufficient data have been observed co-occurring.');
        return;
    end

    imgui.TextColored(COLOR_WARN, 'Items that NEVER co-occur despite sufficient sample sizes:');
    imgui.Spacing();

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##ss_table', 6, flags, { 0, math_min(#ss * 24 + 28, 250) }) then
        imgui.TableSetupColumn('Item A', 0, 130);
        imgui.TableSetupColumn('Item B', 0, 130);
        imgui.TableSetupColumn('A Drops', 0, 55);
        imgui.TableSetupColumn('B Drops', 0, 55);
        imgui.TableSetupColumn('Expected Co-occur', 0, 95);
        imgui.TableSetupColumn('Confidence', 0, 70);
        imgui.TableHeadersRow();

        for _, row in ipairs(ss) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.name_a);
            imgui.TableNextColumn(); imgui.Text(row.name_b);
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops_a));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('%s dropped %d times total.', row.name_a, row.drops_a));
            end
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops_b));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('%s dropped %d times total.', row.name_b, row.drops_b));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f', row.expected_co));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'If independent: P(A)*P(B)*%s = %.1f\n'
                    .. 'But observed 0 co-occurrences.\n'
                    .. 'Higher expected = stronger shared slot evidence.',
                    kw, row.expected_co));
            end

            imgui.TableNextColumn();
            local conf_color = COLOR_GREEN;
            if (row.confidence == 'High') then conf_color = COLOR_YELLOW;
            elseif (row.confidence == 'Possible') then conf_color = COLOR_GRAY; end
            imgui.TextColored(conf_color, row.confidence);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected %.1f co-occurrences but observed 0.\n'
                    .. 'These items likely share a drop table slot\n'
                    .. '(the server picks one OR the other, never both).',
                    row.expected_co));
            end
        end
        imgui.EndTable();
    end

    -- Drop position analysis for shared slot candidates
    local dp = result.drop_positions or T{};
    if (#dp > 0 and #ss > 0) then
        imgui.Spacing();
        imgui.TextDisabled('Drop Position Analysis (post-v1.1.1 data only):');

        -- Build quick lookup of shared slot item IDs (cached on result)
        if (result._ss_relevant == nil) then
            local ss_items = {};
            for _, ss_row in ipairs(ss) do
                ss_items[ss_row.item_a] = true;
                ss_items[ss_row.item_b] = true;
            end
            local rel = {};
            for _, p in ipairs(dp) do
                if (ss_items[p.item_id]) then
                    rel[#rel + 1] = p;
                end
            end
            result._ss_relevant = rel;
        end
        local relevant = result._ss_relevant;

        if (#relevant > 0) then
            for _, p in ipairs(relevant) do
                local pos_parts = {};
                for pos, cnt in pairs(p.positions) do
                    pos_parts[#pos_parts + 1] = string_format('pos %d: %dx', pos, cnt);
                end
                table.sort(pos_parts);
                imgui.BulletText(string_format('%s: %s', p.item_name, table.concat(pos_parts, ', ')));
            end
        else
            imgui.TextDisabled('No drop order data yet for shared slot candidates.');
        end
    end
end

--- Render Battlefield Drop Structure (replaces Slot Count Estimation for battlefields).
local function render_battlefield_drop_structure(result)
    local se = result.slot_estimate;
    if (se == nil) then return; end

    local guaranteed = se.guaranteed_items or T{};
    local variable = se.variable_items or T{};
    local std_dev = se.items_std_dev or 0;

    -- Summary metrics table
    local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_NoHostExtendX);
    if imgui.BeginTable('##bf_struct_tbl', 2, tflags) then
        imgui.TableSetupColumn('Label', 0, 220);
        imgui.TableSetupColumn('Value', 0, 250);

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Items per encounter:');
        imgui.TableNextColumn();
        local consistency_color = (std_dev < 0.5) and COLOR_GREEN or (std_dev < 1.0) and COLOR_WARN or COLOR_LIGHT_GRAY;
        imgui.TextColored(consistency_color, string_format('%.1f avg (std dev: %.1f)', se.avg_items_per_kill, std_dev));
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Average items dropped per battlefield encounter.\n'
                .. 'Low std dev = consistent slot count (fixed drop table).\n'
                .. 'High std dev = variable drops (conditional slots?).');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Guaranteed drops:');
        imgui.TableNextColumn(); imgui.TextColored(COLOR_GREEN, tostring(#guaranteed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Items with 95%%%% or higher drop rate.\nThese drop on virtually every run.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Variable drops:');
        imgui.TableNextColumn(); imgui.Text(tostring(#variable));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Items with less than 95%%%% drop rate.\nThese are contested or low-chance slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Max items in one encounter:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.max_observed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('The most items seen in a single run.\nHard lower bound on total drop slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Unique items seen:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.unique_items));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Total distinct items (excluding gil) from this battlefield.\nItems sharing a slot inflate this count above actual slot count.');
        end

        imgui.EndTable();
    end

    imgui.Spacing();

    -- Guaranteed items list
    if (#guaranteed > 0) then
        imgui.TextColored(COLOR_GREEN, 'Guaranteed:');
        for _, item in ipairs(guaranteed) do
            imgui.BulletText(string_format('%s  %.1f%%%%  [%d/%d]',
                item.item_name, item.rate * 100, item.drops, item.kills));
        end
        imgui.Spacing();
    end

    -- Variable items list
    if (#variable > 0) then
        imgui.TextColored(COLOR_WARN, 'Variable:');
        for _, item in ipairs(variable) do
            imgui.BulletText(string_format('%s  %.1f%%%%  [%d/%d]',
                item.item_name, item.rate * 100, item.drops, item.kills));
        end
    end

    if (#guaranteed == 0 and #variable == 0) then
        imgui.TextDisabled('No item drops recorded.');
    end
end

--- Render Inferred Battlefield Drop Table (union-find slot grouping).
local function render_inferred_drop_table(result, kills)
    local slots = result.inferred_slots;

    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d runs). Inferred slots below %d runs may be inaccurate.',
            kills, analysis.MIN_KILLS_COOCCURRENCE));
    end

    if (slots == nil or #slots == 0) then
        imgui.TextDisabled('No items with sufficient data for slot inference.');
        return;
    end

    imgui.TextDisabled('Items that never drop together are inferred to share a slot.');
    imgui.Spacing();

    for slot_idx, slot in ipairs(slots) do
        local items = slot.items;
        local label_color = slot.is_guaranteed and COLOR_GREEN or (slot.total_rate >= 0.5) and COLOR_WARN or COLOR_GRAY;

        if (#items == 1) then
            -- Single-item slot
            local item = items[1];
            imgui.TextColored(label_color, string_format('Slot %d (%.1f%%%%):',
                slot_idx, slot.total_rate * 100));
            imgui.SameLine();
            imgui.Text(item.item_name);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%s\nDrop rate: %.1f%%%% (%d drops / %d runs)\n\n%s',
                    item.item_name, item.rate * 100, item.drops, kills,
                    slot.is_guaranteed and 'Guaranteed drop — appears on virtually every run.'
                    or 'Independent slot — no shared items detected.'));
            end
        else
            -- Multi-item (shared) slot
            imgui.TextColored(label_color, string_format('Slot %d (%.1f%%%%):',
                slot_idx, slot.total_rate * 100));
            imgui.SameLine();

            -- Build inline item list: "ItemA (12.0%) | ItemB (8.0%)"
            -- %%%% → string_format produces %% → ImGui printf displays %
            local parts = {};
            for _, item in ipairs(items) do
                parts[#parts + 1] = string_format('%s (%.1f%%%%)', item.item_name, item.rate * 100);
            end
            imgui.Text(table.concat(parts, ' | '));
            if imgui.IsItemHovered() then
                local tip_lines = { string_format('Shared slot — %d mutually exclusive items:', #items) };
                for _, item in ipairs(items) do
                    tip_lines[#tip_lines + 1] = string_format('  %s: %.1f%%%% (%d drops)', item.item_name, item.rate * 100, item.drops);
                end
                tip_lines[#tip_lines + 1] = '';
                tip_lines[#tip_lines + 1] = 'These items were never observed dropping together.';
                tip_lines[#tip_lines + 1] = 'The server picks one from this group per run.';
                imgui.SetTooltip(table.concat(tip_lines, '\n'));
            end
        end
    end

    -- Summary
    imgui.Spacing();
    local shared_count = 0;
    for _, slot in ipairs(slots) do
        if (#slot.items > 1) then shared_count = shared_count + 1; end
    end
    if (shared_count == 0) then
        imgui.TextDisabled('All items appear to be on independent slots.');
    else
        imgui.TextDisabled(string_format('%d slot(s), %d shared — based on %d runs.',
            #slots, shared_count, kills));
    end
end

--- Main Slot Analysis tab renderer.
local function render_slot_analysis()
    if (analysis == nil) then
        imgui.TextColored(COLOR_ERR, 'Analysis module failed to load. Slot Analysis unavailable.');
        return;
    end

    -- Lazy init: pass db.conn to analysis once it's available
    if (not an.analysis_inited and db.conn ~= nil) then
        analysis.init(db.conn);
        an.analysis_inited = true;
    end

    -- Row 1: Category radio buttons (same as Statistics for visual consistency)
    if imgui.RadioButton('Field##an', an.category == 0) then
        an.category = 0;
        reset_an_filter(0);
    end
    imgui.SameLine();
    if imgui.RadioButton('Battlefields##an', an.category == 1) then
        an.category = 1;
        reset_an_filter(8);
    end
    imgui.SameLine();
    if imgui.RadioButton('Instances##an', an.category == 2) then
        an.category = 2;
        reset_an_filter(7);  -- default to Dynamis (only supported instance)
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Slot Analysis Categories\n'
            .. '------------------------------\n'
            .. 'Select a category, then a zone and mob to analyze.\n'
            .. 'All analysis uses nearby kills only — distant kills\n'
            .. 'are excluded because you only see drops that entered\n'
            .. 'your treasure pool (empty distant kills are invisible).\n\n'
            .. '  Field — Open-world mobs (excludes instance content)\n'
            .. '  Battlefields — BCNM (chest drops) and HTBF (direct drops)\n'
            .. '  Instances — Dynamis (Omen/Ambuscade/Sortie WIP)\n\n'
            .. 'Chest/Coffer and Voidwatch are not shown here —\n'
            .. 'slot analysis requires treasure pool drops.\n'
            .. 'See the Statistics tab for those categories.');
    end

    -- Row 2: Sub-filter radio buttons (Battlefields / Instances)
    if (an.category == 1) then
        imgui.Spacing();
        if imgui.RadioButton('All BF##an', an.source_filter == 8) then reset_an_filter(8); end
        imgui.SameLine();
        if imgui.RadioButton('BCNM##an', an.source_filter == 2) then reset_an_filter(2); end
        imgui.SameLine();
        if imgui.RadioButton('HTBF##an', an.source_filter == 3) then reset_an_filter(3); end
    elseif (an.category == 2) then
        imgui.Spacing();
        if imgui.RadioButton('Dynamis##an', an.source_filter == 7) then reset_an_filter(7); end
        imgui.SameLine();
        imgui.TextDisabled('Ambuscade / Omen / Sortie (WIP)');
    end

    imgui.Spacing();

    -- Zone/Battlefield combo
    local combo_str, combo_entries = build_an_filter(an.source_filter);
    imgui.SetNextItemWidth(300);
    if imgui.Combo('##an_zone', an.mob_idx, combo_str) then
        local idx = an.mob_idx[1];
        if (idx == 0) then
            an.zone_filter = -1;
            an.name_filter = nil;
            an.mob_filter = nil;
            an.mob_level_cap = nil;
            an.effective_sf = nil;
            an.result = nil;
            an.mob_stats = nil;
        elseif (combo_entries ~= nil and combo_entries[idx] ~= nil) then
            local e = combo_entries[idx];
            an.zone_filter = e.zone_id;
            an.name_filter = e.name;
            an.mob_filter = nil;
            an.mob_level_cap = e.level_cap;  -- bf_difficulty for HTBF, level_cap for BCNM
            an.effective_sf = e.effective_sf;  -- remapped sf (2 or 3) for All BF entries
            an.result = nil;
            an.mob_stats = nil;
        end
        an.cache_dirty = true;
    end

    -- BCNM/HTBF/All BF zone combo = battlefield; others need mob combo
    if (an.zone_filter >= 0) then
        local needs_mob_combo = (an.source_filter ~= 2 and an.source_filter ~= 3 and an.source_filter ~= 8);

        if (needs_mob_combo) then
            local mob_str, mob_list = build_mob_combo(an.source_filter, an.zone_filter, an.name_filter);
            an_mob_sel[1] = 0;
            -- Find current selection
            if (an.mob_filter ~= nil and mob_list ~= nil) then
                for i, m in ipairs(mob_list) do
                    if (m.mob_name == an.mob_filter) then
                        an_mob_sel[1] = i;
                        break;
                    end
                end
            end

            imgui.SameLine();
            imgui.SetNextItemWidth(300);
            if imgui.Combo('##an_mob', an_mob_sel, mob_str) then
                local idx = an_mob_sel[1];
                if (idx == 0) then
                    an.mob_filter = nil;
                    an.mob_level_cap = nil;
                    an.effective_sf = nil;
                    an.result = nil;
                    an.mob_stats = nil;
                elseif (mob_list ~= nil and mob_list[idx] ~= nil) then
                    an.mob_filter = mob_list[idx].mob_name;
                    an.mob_level_cap = mob_list[idx].level_cap;
                    an.result = nil;
                    an.mob_stats = nil;
                end
                an.cache_dirty = true;
            end
        else
            -- BCNM/HTBF: mob_filter is the battlefield name from zone combo
            if (an.mob_filter == nil and an.name_filter ~= nil) then
                an.mob_filter = an.name_filter;
            end
        end
    end

    imgui.Separator();

    -- Determine what to analyze
    local mob_name = an.mob_filter;
    local zone_id = an.zone_filter;
    local level_cap = an.mob_level_cap;
    -- For All BF (sf=8), route through BCNM (2) or HTBF (3) path
    local query_sf = an.effective_sf or an.source_filter;

    if (mob_name == nil or zone_id < 0) then
        imgui.Spacing();
        imgui.TextDisabled('Select a zone and mob to analyze drop slot probabilities.');
        an.cache_dirty = false;
        return;
    end

    -- Get mob stats (from db cache)
    if (an.mob_stats == nil or an.cache_dirty) then
        an.mob_stats = db.get_mob_stats(mob_name, zone_id, query_sf, level_cap);
    end

    if (an.mob_stats == nil or an.mob_stats.kills == 0) then
        imgui.TextDisabled('No kill data for this mob.');
        an.cache_dirty = false;
        return;
    end

    -- Compute analysis (cached)
    if (an.result == nil or an.cache_dirty) then
        an.result = analysis.compute(mob_name, zone_id, query_sf, level_cap, an.mob_stats);
        an.cache_dirty = false;
    end

    -- Nearby kills only — distant kills have partial drop visibility
    local kills = an.mob_stats.kills - (an.mob_stats.distant_kills or 0);

    if (an.result == nil) then
        if (kills == 0 and an.mob_stats.kills > 0) then
            local sf = an.source_filter;
            local dkw = (sf == 2 or sf == 3 or sf == 8) and 'runs' or 'kills';
            imgui.TextDisabled('All ' .. dkw .. ' are distant — slot analysis requires nearby ' .. dkw .. '.');
        else
            imgui.TextDisabled('Insufficient data for analysis.');
        end
        return;
    end

    -- Scrollable content area for analysis results
    imgui.BeginChild('##an_scroll', { 0, 0 });

    local is_bf = an.result.is_battlefield;
    local kw = is_bf and 'runs' or 'kills';

    -- Header
    imgui.TextColored(COLOR_CYAN, mob_name);
    imgui.SameLine();
    imgui.TextDisabled(string_format('(%s nearby %s)', format_count(kills), kw));
    if imgui.IsItemHovered() then
        local distant = an.mob_stats.distant_kills or 0;
        if (distant > 0) then
            imgui.SetTooltip(string_format(
                'Slot analysis uses nearby %s only (%s nearby, %s distant).\n'
                .. 'Distant %s are excluded because you only see drops\n'
                .. 'that entered your treasure pool — empty distant %s\n'
                .. 'are invisible, which would bias all analysis.',
                kw, format_count(kills), format_count(distant), kw, kw));
        else
            imgui.SetTooltip('All ' .. kw .. ' are nearby (witnessed defeat message).\nNo distant ' .. kw .. ' to exclude.');
        end
    end
    imgui.Spacing();

    -- Section 1: Confidence Intervals (open by default, same for all modes)
    local ci_label = is_bf and 'Drop Rate Confidence Intervals (95% Wilson Score)' or 'Confidence Intervals (95% Wilson Score)';
    local ci_open = imgui.CollapsingHeader(ci_label, ImGuiTreeNodeFlags_DefaultOpen);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'How precise are the observed drop rates?\n\n'
            .. 'Wilson Score CI gives a range where the TRUE drop rate\n'
            .. 'likely falls (95%% confidence). Narrower = more reliable.\n'
            .. (is_bf and 'More reliable with 30+ runs.' or 'More reliable with 30+ kills.'));
    end
    if (ci_open) then
        render_ci_section(an.result, kills);
    end

    -- Section 2: Slot structure (mode-aware)
    if (is_bf) then
        -- Battlefield: Drop Structure replaces Slot Count Estimation
        local cs_open = imgui.CollapsingHeader('Battlefield Drop Structure', ImGuiTreeNodeFlags_DefaultOpen);
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Battlefield drop table structure.\n\n'
                .. 'Battlefields have fixed drop slots — some always drop\n'
                .. '(guaranteed), others have a chance (variable).\n'
                .. 'Items per encounter shows how consistent the slot count is.');
        end
        if (cs_open) then
            render_battlefield_drop_structure(an.result);
        end
    else
        -- Field/Instance: standard Slot Count Estimation
        local se_open = imgui.CollapsingHeader('Slot Count Estimation', ImGuiTreeNodeFlags_DefaultOpen);
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'How many independent drop slots does this mob have?\n\n'
                .. 'FFXI mobs have a drop table of independent slots,\n'
                .. 'each with one item and a fixed probability. The server\n'
                .. 'rolls each slot independently on kill.\n\n'
                .. 'Key indicators:\n'
                .. '  Rate sum > 1.0 = multiple independent slots confirmed\n'
                .. '  Empty kill rate matches model = slots are independent');
        end
        if (se_open) then
            render_slot_section(an.result);
        end
    end

    -- Section 3: Items-Per-Kill/Encounter Distribution
    local dist_label = is_bf and 'Items-Per-Encounter Distribution' or 'Items-Per-Kill Distribution';
    local dist_open = imgui.CollapsingHeader(dist_label);
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'How many items drop per encounter?\n\n'
                .. 'Compares the observed distribution against what the\n'
                .. 'independent slot model predicts (Poisson Binomial).\n'
                .. 'Large deviations suggest slots may not be independent.');
        else
            imgui.SetTooltip(
                'How many items drop per kill?\n\n'
                .. 'Compares the observed distribution against what the\n'
                .. 'independent slot model predicts (Poisson Binomial).\n'
                .. 'Large deviations suggest slots may not be independent.');
        end
    end
    if (dist_open) then
        render_distribution_section(an.result);
    end

    -- Section 4: Co-occurrence Analysis (collapsed by default)
    local co_open = imgui.CollapsingHeader('Co-occurrence Analysis');
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'Do item pairs drop together as often as expected?\n\n'
                .. 'If two items are on independent slots, their co-occurrence\n'
                .. 'rate should equal P(A) * P(B). Deviation from 1.0x means\n'
                .. 'the items may share a slot or be correlated.\n\n'
                .. 'For battlefield drops, items on different slots always\n'
                .. 'co-occur. Items on the same slot never co-occur.\n'
                .. 'More reliable with 50+ runs.');
        else
            imgui.SetTooltip(
                'Do item pairs drop together as often as expected?\n\n'
                .. 'If two items are on independent slots, their co-occurrence\n'
                .. 'rate should equal P(A) * P(B). Deviation from 1.0x means\n'
                .. 'the items may share a slot or be correlated.\n'
                .. 'More reliable with 50+ kills.');
        end
    end
    if (co_open) then
        render_cooccurrence_section(an.result, kills);
    end

    -- Section 5: Shared Slot Candidates (collapsed by default)
    local ss_open = imgui.CollapsingHeader('Shared Slot Candidates');
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'Items that NEVER drop together despite high individual rates.\n\n'
                .. 'For battlefield drops, shared slots mean items that are\n'
                .. 'mutually exclusive outcomes from the same drop table position.\n'
                .. 'The server picks one OR the other per run — never both.');
        else
            imgui.SetTooltip(
                'Items that NEVER drop together despite high individual rates.\n\n'
                .. 'If two items share a drop table slot, the server picks one\n'
                .. 'OR the other — never both. Zero co-occurrences with high\n'
                .. 'expected count is strong evidence for a shared slot.');
        end
    end
    if (ss_open) then
        render_shared_slots_section(an.result, kills);
    end

    -- Section 6 (battlefields only): Inferred Drop Table
    if (is_bf) then
        local inf_open = imgui.CollapsingHeader('Inferred Battlefield Drop Table');
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Reverse-engineered battlefield drop table.\n\n'
                .. 'Groups items into slots based on co-occurrence data:\n'
                .. 'items that NEVER drop together share a slot.\n'
                .. 'More reliable with 50+ runs.');
        end
        if (inf_open) then
            render_inferred_drop_table(an.result, kills);
        end
    end

    imgui.EndChild();
end

-------------------------------------------------------------------------------
-- Export Tab
-------------------------------------------------------------------------------

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
-- TH Advanced Management Window
-------------------------------------------------------------------------------

-- Derive slot labels from db.SLOT_NAMES (0-indexed) into 1-indexed array for ImGui combo
-- Built lazily on first use (db is nil at require time, set later in ui.init)
local TH_SLOT_LABELS = nil;
local TH_SLOT_COMBO = nil;

local function get_th_slot_combo()
    if (TH_SLOT_COMBO == nil and db ~= nil) then
        TH_SLOT_LABELS = {};
        for i = 0, 15 do TH_SLOT_LABELS[i + 1] = db.SLOT_NAMES[i] or '?'; end
        TH_SLOT_COMBO = table.concat(TH_SLOT_LABELS, '\0') .. '\0';
    end
    return TH_SLOT_COMBO;
end

local function slot_id_to_combo_idx(slot_id)
    if (slot_id == nil or slot_id < 0 or slot_id > 15) then return 0; end
    return slot_id;
end

-- Convert IItem.Slots bitmask to first matching slot index (0-15)
local function slots_bitmask_to_idx(slots)
    if (slots == nil or slots == 0) then return 0; end
    for i = 0, 15 do
        if (bit.band(slots, bit.lshift(1, i)) ~= 0) then return i; end
    end
    return 0;
end

local function refresh_th_adv_data(profile_id)
    if (profile_id == nil) then
        th_adv_items_cache = {};
        th_adv_traits_cache = {};
        return;
    end
    th_adv_items_cache = db.get_th_items(profile_id);
    th_adv_traits_cache = db.get_th_job_traits(profile_id);
    th_adv_profile_id = profile_id;
    th_adv_dirty = false;
end

local function render_th_advanced_window()
    if (not th_adv_open[1]) then return; end

    imgui.SetNextWindowSize({ 600, 500 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('TH Management##adv', th_adv_open, ImGuiWindowFlags_None)) then
        local profiles = get_th_profiles_cached();

        -- Profile selector
        local profile_names = {};
        for i, p in ipairs(profiles) do
            profile_names[i] = p.name;
            if (p.id == th_adv_profile_id) then
                th_adv_profile_idx[1] = i - 1;
            end
        end

        -- Default to first profile if none selected
        if (th_adv_profile_id == nil and #profiles > 0) then
            th_adv_profile_idx[1] = 0;
            refresh_th_adv_data(profiles[1].id);
        end

        local combo_str = (#profile_names > 0) and (table.concat(profile_names, '\0') .. '\0') or '\0';
        imgui.PushItemWidth(200);
        if imgui.Combo('Profile', th_adv_profile_idx, combo_str) then
            local sel = profiles[th_adv_profile_idx[1] + 1];
            if (sel ~= nil) then
                refresh_th_adv_data(sel.id);
            end
        end
        imgui.PopItemWidth();
        if imgui.IsItemHovered() then
            imgui.SetTooltip('TH profile defines which job traits and gear items grant TH.\nThe active profile is set in the Settings tab.\nUse different profiles for different servers (e.g., Retail vs HorizonXI).');
        end

        -- Profile actions
        imgui.SameLine();
        if imgui.Button('+ New') then
            th_new_profile_open = true;
            th_clone_mode = false;
            th_new_profile_buf[1] = '';
            th_new_profile_error = '';
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Create an empty profile with no traits or gear.');
        end
        imgui.SameLine();
        if imgui.Button('Clone') then
            th_new_profile_open = true;
            th_clone_mode = true;
            th_new_profile_buf[1] = '';
            th_new_profile_error = '';
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Duplicate the current profile with all its traits and gear.\nUseful for creating a server-specific variant.');
        end
        imgui.SameLine();
        if (#profiles > 1 and th_adv_profile_id ~= nil) then
            -- Prevent deleting the active settings profile
            local is_active = false;
            if (s ~= nil and s.th_profile ~= nil) then
                for _, p in ipairs(profiles) do
                    if (p.id == th_adv_profile_id and p.name == s.th_profile) then
                        is_active = true;
                        break;
                    end
                end
            end
            if (is_active) then
                imgui.BeginDisabled();
                imgui.Button('Delete');
                imgui.EndDisabled();
                if imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled) then
                    imgui.SetTooltip('Cannot delete the active profile. Switch to a different profile first.');
                end
            else
                if imgui.Button('Delete') then
                    db.delete_th_profile(th_adv_profile_id);
                    th_adv_profile_id = nil;
                    th_adv_profile_idx[1] = 0;
                    th_adv_dirty = true;
                    th_profiles_dirty = true;
                    if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                end
            end
        end

        -- New/Clone profile modal
        if (th_new_profile_open) then
            imgui.OpenPopup('New TH Profile##modal');
            th_new_profile_open = false;
        end
        if imgui.BeginPopupModal('New TH Profile##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
            imgui.Text(th_clone_mode and 'Clone profile as:' or 'New profile name:');
            imgui.PushItemWidth(200);
            imgui.InputText('##th_new_name', th_new_profile_buf, th_new_profile_size);
            imgui.PopItemWidth();
            if (th_new_profile_error ~= '') then
                imgui.TextColored({1, 0.3, 0.3, 1}, th_new_profile_error);
            end
            if imgui.Button('Create') then
                local name = th_new_profile_buf[1];
                if (name == nil or name == '') then
                    th_new_profile_error = 'Name cannot be empty.';
                else
                    local new_id;
                    if (th_clone_mode and th_adv_profile_id ~= nil) then
                        new_id = db.clone_th_profile(th_adv_profile_id, name);
                    else
                        new_id = db.create_th_profile(name);
                    end
                    if (new_id ~= nil) then
                        refresh_th_adv_data(new_id);
                        th_profiles_dirty = true;
                        if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                        th_new_profile_error = '';
                        imgui.CloseCurrentPopup();
                    else
                        th_new_profile_error = 'Profile "' .. name .. '" already exists.';
                    end
                end
            end
            imgui.SameLine();
            if imgui.Button('Cancel') then
                imgui.CloseCurrentPopup();
            end
            imgui.EndPopup();
        end

        if (th_adv_dirty and th_adv_profile_id ~= nil) then
            refresh_th_adv_data(th_adv_profile_id);
        end

        imgui.Separator();

        if (th_adv_profile_id ~= nil) then
            -- Job Traits section
            if imgui.CollapsingHeader('Job Traits', ImGuiTreeNodeFlags_DefaultOpen) then
                -- Add Trait button (top of section)
                if imgui.SmallButton('+ Add Trait') then
                    th_add_trait_open = true;
                    th_add_trait_job_idx[1] = 5;  -- THF
                    th_add_trait_role_idx[1] = 0;  -- Main
                    th_add_trait_level[1] = 1;
                    th_add_trait_th[1] = 1;
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Add a job trait that grants TH at a certain level.\nUseful for private servers with custom TH on non-THF jobs.');
                end

                -- Add Trait modal
                if (th_add_trait_open) then
                    imgui.OpenPopup('Add Job Trait##modal');
                    th_add_trait_open = false;
                end
                if imgui.BeginPopupModal('Add Job Trait##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                    local job_combo = 'WAR\0MNK\0WHM\0BLM\0RDM\0THF\0PLD\0DRK\0BST\0BRD\0RNG\0SAM\0NIN\0DRG\0SMN\0BLU\0COR\0PUP\0DNC\0SCH\0GEO\0RUN\0';
                    imgui.PushItemWidth(100);
                    imgui.Combo('Job', th_add_trait_job_idx, job_combo);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('The job that receives this TH trait.');
                    end
                    imgui.Combo('Role', th_add_trait_role_idx, 'Main\0Sub\0');
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Main = when this job is your main job.\nSub = when this job is your subjob (usually lower TH).');
                    end
                    imgui.InputInt('Min Level', th_add_trait_level);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Minimum job level required to activate this trait.\nRetail THF gets TH at 15, 45, and 90.');
                    end
                    imgui.SliderInt('TH Value', th_add_trait_th, 1, 10);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('TH level granted by this trait.\nHigher-tier traits replace lower ones (they do not stack).');
                    end
                    imgui.PopItemWidth();

                    -- Clamp level
                    if (th_add_trait_level[1] < 1) then th_add_trait_level[1] = 1; end
                    if (th_add_trait_level[1] > 99) then th_add_trait_level[1] = 99; end

                    imgui.Spacing();
                    imgui.TextDisabled('For private servers with custom TH traits.');
                    imgui.TextDisabled('Retail THF traits are pre-populated.');

                    if imgui.Button('Add##trait') then
                        if (th_adv_profile_id ~= nil) then
                            local job_id = th_add_trait_job_idx[1] + 1;  -- combo is 0-based, jobs are 1-based
                            local is_main = (th_add_trait_role_idx[1] == 0) and 1 or 0;
                            db.add_th_job_trait(th_adv_profile_id, job_id, is_main, th_add_trait_level[1], th_add_trait_th[1]);
                            th_adv_dirty = true;
                            if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                        end
                        imgui.CloseCurrentPopup();
                    end
                    imgui.SameLine();
                    if imgui.Button('Cancel##trait') then
                        imgui.CloseCurrentPopup();
                    end
                    imgui.EndPopup();
                end

                imgui.Spacing();

                if (th_adv_traits_cache ~= nil and #th_adv_traits_cache > 0) then
                    for _, trait in ipairs(th_adv_traits_cache) do
                        local role = trait.is_main == 1 and 'Main' or 'Sub';
                        local job_abbr = JOB_ABBRS[trait.job_id] or ('Job' .. tostring(trait.job_id));
                        local trait_label = string_format('%s %s  Lv%d: +%d', job_abbr, role, trait.min_level, trait.th_value);
                        if (trait.job_id == 16) then
                            trait_label = trait_label .. '  (spell-set)';
                        end

                        -- Enable/disable checkbox
                        th_trait_enabled_buf[1] = (trait.enabled ~= 0);
                        if imgui.Checkbox('##trait_en_' .. tostring(trait.id), th_trait_enabled_buf) then
                            db.set_th_job_trait_enabled(trait.id, th_trait_enabled_buf[1]);
                            th_adv_dirty = true;
                            if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                        end
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(th_trait_enabled_buf[1] and 'Disable this trait (keeps it for later)' or 'Enable this trait');
                        end
                        imgui.SameLine();
                        if (trait.enabled == 0) then
                            imgui.TextDisabled(trait_label);
                        else
                            imgui.Text(trait_label);
                        end
                        if imgui.IsItemHovered() then
                            if (trait.job_id == 16) then
                                imgui.SetTooltip('BLU spell-set TH trait.\nRequires Charged Whisker + Everyone\'s Grudge + Amorphic Spikes all set.\nDetected automatically from memory. Use /loot bluspells to verify.');
                            else
                                imgui.SetTooltip(string_format('%s %s job: grants TH+%d at level %d and above.\nUncheck to disable without deleting. X to remove permanently.',
                                    job_abbr, role, trait.th_value, trait.min_level));
                            end
                        end
                        imgui.SameLine();
                        if imgui.SmallButton('X##trait_' .. tostring(trait.id)) then
                            db.delete_th_job_trait(trait.id);
                            th_adv_dirty = true;
                            if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                        end
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip('Delete this trait permanently.');
                        end
                    end
                else
                    imgui.TextDisabled('  No job traits defined.');
                end

                if (tracker ~= nil and tracker.th_trust_source ~= nil) then
                    imgui.TextDisabled('  Trust/Pet TH1 active: ' .. tracker.th_trust_source);
                end
            end

            imgui.Spacing();

            -- TH Gear section
            if imgui.CollapsingHeader('TH Gear', ImGuiTreeNodeFlags_DefaultOpen) then
                imgui.TextDisabled('Augmented TH (e.g., Herculean +TH) is auto-detected at scan time.');
                imgui.TextDisabled('Add items here for intrinsic TH gear or custom server items.');
                -- Search + Add
                imgui.PushItemWidth(200);
                imgui.InputTextWithHint('##th_search', 'Search by name or notes...', th_adv_search_buf, th_adv_search_size);
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter items by name or notes.');
                end
                imgui.SameLine();
                if imgui.Button('+ Add Item') then
                    th_add_open = true;
                    th_add_item_id[1] = 0;
                    th_add_name_buf[1] = '';
                    th_add_th_value[1] = 1;
                    th_add_slot_idx[1] = 0;
                    th_add_notes_buf[1] = '';
                    th_add_last_id = 0;
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Add a gear item that grants TH when equipped.\nEnter the item ID and name/slot/TH auto-fill from game data.\nSet TH=0 for augmentable gear (augments detected automatically).');
                end

                -- Add item modal
                if (th_add_open) then
                    imgui.OpenPopup('Add TH Item##modal');
                    th_add_open = false;
                end
                if imgui.BeginPopupModal('Add TH Item##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                    imgui.PushItemWidth(120);
                    if imgui.InputInt('Item ID', th_add_item_id) then
                        -- ID changed — auto-fill name, slot, and TH value from resource
                        local cur_id = th_add_item_id[1];
                        if (cur_id > 0 and cur_id ~= th_add_last_id) then
                            th_add_last_id = cur_id;
                            local res = AshitaCore:GetResourceManager();
                            if (res ~= nil) then
                                local ritem = res:GetItemById(cur_id);
                                if (ritem ~= nil) then
                                    if (ritem.Name ~= nil and ritem.Name[1] ~= nil) then
                                        th_add_name_buf[1] = ritem.Name[1];
                                    end
                                    th_add_slot_idx[1] = slots_bitmask_to_idx(ritem.Slots);
                                end
                            end
                            -- Pre-fill TH value from existing profile entry if present
                            if (th_adv_profile_id ~= nil) then
                                local existing = db.get_th_items_by_item_id(th_adv_profile_id);
                                if (existing ~= nil and existing[cur_id] ~= nil) then
                                    th_add_th_value[1] = existing[cur_id].th_value or 1;
                                else
                                    th_add_th_value[1] = 1;
                                end
                            end
                        elseif (cur_id <= 0) then
                            th_add_last_id = 0;
                            th_add_name_buf[1] = '';
                            th_add_th_value[1] = 1;
                            th_add_slot_idx[1] = 0;
                        end
                    end
                    imgui.PopItemWidth();

                    imgui.PushItemWidth(200);
                    imgui.InputText('Item Name', th_add_name_buf, th_add_name_size);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Auto-filled from game data when a valid Item ID is entered.');
                    end
                    imgui.PopItemWidth();
                    imgui.PushItemWidth(120);
                    imgui.SliderInt('TH Value', th_add_th_value, 0, 10);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Intrinsic TH granted by this item.\nSet to 0 for augmentable gear (TH detected from augments).\nSet to the actual TH value for items with built-in TH.');
                    end
                    imgui.Combo('Slot', th_add_slot_idx, get_th_slot_combo() or '');
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Equipment slot this item occupies.\nAuto-filled from game data when a valid Item ID is entered.');
                    end
                    imgui.PopItemWidth();
                    imgui.PushItemWidth(200);
                    imgui.InputText('Notes', th_add_notes_buf, th_add_notes_size);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Optional notes (e.g., "augmentable", "private server only").');
                    end
                    imgui.PopItemWidth();

                    imgui.Spacing();
                    imgui.TextDisabled('TH=0 for augmentable gear (TH detected from augments).');
                    imgui.TextDisabled('Set TH value for intrinsic or custom server items.');

                    if imgui.Button('Add') then
                        if (th_add_item_id[1] > 0 and th_adv_profile_id ~= nil) then
                            db.add_th_item(
                                th_adv_profile_id,
                                th_add_item_id[1],
                                th_add_name_buf[1] or '',
                                th_add_th_value[1],
                                th_add_slot_idx[1],
                                th_add_notes_buf[1] or ''
                            );
                            th_adv_dirty = true;
                            if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                        end
                        imgui.CloseCurrentPopup();
                    end
                    imgui.SameLine();
                    if imgui.Button('Cancel##add') then
                        imgui.CloseCurrentPopup();
                    end
                    imgui.EndPopup();
                end

                -- Items table
                if (th_adv_items_cache ~= nil and #th_adv_items_cache > 0) then
                    local search = (th_adv_search_buf[1] or ''):lower();
                    local flags = ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg + ImGuiTableFlags_ScrollY
                        + ImGuiTableFlags_Resizable + ImGuiTableFlags_SizingStretchProp;
                    if imgui.BeginTable('th_items_tbl', 6, flags, { 0, 280 }) then
                        imgui.TableSetupColumn('ID', ImGuiTableColumnFlags_WidthFixed, 55);
                        imgui.TableSetupColumn('Name', ImGuiTableColumnFlags_WidthStretch);
                        imgui.TableSetupColumn('TH', ImGuiTableColumnFlags_WidthFixed, 35);
                        imgui.TableSetupColumn('Slot', ImGuiTableColumnFlags_WidthFixed, 55);
                        imgui.TableSetupColumn('Notes', ImGuiTableColumnFlags_WidthFixed, 120);
                        imgui.TableSetupColumn('', ImGuiTableColumnFlags_WidthFixed, 25);
                        imgui.TableHeadersRow();

                        for _, item in ipairs(th_adv_items_cache) do
                            local name_lower = (item.item_name or ''):lower();
                            local notes_lower = (item.notes or ''):lower();
                            if (search == '' or name_lower:find(search, 1, true) or notes_lower:find(search, 1, true)) then
                                imgui.TableNextRow();
                                imgui.TableNextColumn();
                                imgui.Text(tostring(item.item_id));
                                imgui.TableNextColumn();
                                imgui.Text(item.item_name or '');
                                imgui.TableNextColumn();
                                if (item.th_value > 0) then
                                    imgui.Text('+' .. tostring(item.th_value));
                                    if imgui.IsItemHovered() then
                                        imgui.SetTooltip('Intrinsic TH+%d from this item.', item.th_value);
                                    end
                                else
                                    imgui.TextDisabled('aug');
                                    if imgui.IsItemHovered() then
                                        imgui.SetTooltip('TH from augments only (detected automatically at scan time).\nNo intrinsic TH value on the base item.');
                                    end
                                end
                                imgui.TableNextColumn();
                                local slot_name = db.SLOT_NAMES[item.slot_id] or '?';
                                imgui.Text(slot_name);
                                imgui.TableNextColumn();
                                local notes = item.notes or '';
                                if (notes ~= '') then
                                    imgui.TextDisabled(notes);
                                end
                                imgui.TableNextColumn();
                                if imgui.SmallButton('X##item_' .. tostring(item.id)) then
                                    db.delete_th_item(item.id);
                                    th_adv_dirty = true;
                                    if (tracker ~= nil) then tracker.invalidate_th_cache(); end
                                end
                                if imgui.IsItemHovered() then
                                    imgui.SetTooltip('Remove this item from the profile.');
                                end
                            end
                        end
                        imgui.EndTable();
                    end

                    imgui.TextDisabled(string_format('Items: %d', #th_adv_items_cache));
                else
                    imgui.TextDisabled('  No TH gear items defined.');
                end
            end
        else
            imgui.TextDisabled('No profile selected.');
        end
    end
    imgui.End();
end

-------------------------------------------------------------------------------
-- Tab 4: Settings
-------------------------------------------------------------------------------
local settings_header_color = { 1.0, 0.65, 0.26, 1.0 };

local function render_settings_tab()
    imgui.TextColored(settings_header_color, 'Live Feed');
    imgui.Separator();

    local slider_w = math_min((imgui.GetContentRegionAvail()), 250);

    set_int_buf[1] = s.feed_max_entries;
    imgui.PushItemWidth(slider_w);
    if imgui.SliderInt('Live Feed Max Entries', set_int_buf, 10, 500) then
        s.feed_max_entries = set_int_buf[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Maximum number of entries shown in the Live Feed tab.');
    end

    set_bool_buf[1] = s.show_empty_kills;
    if imgui.Checkbox('Show Kills Without Drops', set_bool_buf) then
        s.show_empty_kills = set_bool_buf[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show mobs that died without dropping anything in the Live Feed.\nUseful for tracking TH levels on empty kills.');
    end

    set_bool_buf[1] = s.show_gil_drops ~= false;
    if imgui.Checkbox('Show Kills With Gil Drops', set_bool_buf) then
        s.show_gil_drops = set_bool_buf[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show gil drops from mob kills in the Live Feed.\nDisable to reduce noise when farming for items.');
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'Compact Mode');
    imgui.Separator();

    set_float_buf[1] = s.compact_bg_alpha or 0.8;
    imgui.PushItemWidth(slider_w);
    if imgui.SliderFloat('Background Opacity', set_float_buf, 0.0, 1.0, '%.2f') then
        s.compact_bg_alpha = set_float_buf[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Background transparency for compact mode.\n0 = fully transparent, 1 = fully opaque.');
    end

    set_bool_buf[1] = s.compact_titlebar ~= false;
    if imgui.Checkbox('Show Title Bar', set_bool_buf) then
        s.compact_titlebar = set_bool_buf[1];
        ui.settings_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Show or hide the window title bar in compact mode.\nThe window is still draggable without it.');
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'TH Management');
    imgui.Separator();

    set_bool_buf[1] = s.th_estimation_enabled ~= false;
    if imgui.Checkbox('Enable gear-based TH estimation (Beta)', set_bool_buf) then
        s.th_estimation_enabled = set_bool_buf[1];
        ui.settings_dirty = true;
        if (tracker ~= nil) then tracker.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Estimate TH from job traits, equipped gear, and augments.\nScans on each offensive action (cached until gear swap).\nSupports THF, BLU spell-set trait, and all TH gear.\nUseful for non-THF jobs and servers without TH proc messages.');
    end

    set_bool_buf[1] = s.th_trust_detection ~= false;
    if imgui.Checkbox('Detect TH trusts and pets (Beta)', set_bool_buf) then
        s.th_trust_detection = set_bool_buf[1];
        ui.settings_dirty = true;
        if (tracker ~= nil) then tracker.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Detect party trusts (THF/sub-THF) and BST jug pets that apply TH+1.\nChecked once per mob per trust — no repeated scans.\nEnsures TH+1 minimum even when you have no TH gear equipped.');
    end

    set_bool_buf[1] = s.th_zone_effects ~= false;
    if imgui.Checkbox('Detect zone TH effects (Beta)', set_bool_buf) then
        s.th_zone_effects = set_bool_buf[1];
        ui.settings_dirty = true;
        if (tracker ~= nil) then tracker.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Detect zone-wide TH bonuses that add to your estimate.\nCurrently supported:\n  - Treasure Hound kupower (+1 with Signet)\nPlanned:\n  - Atma of Dread (+1 in Abyssea)\n  - GoV Prowess TH (+1 per level, max 3 levels)');
    end

    -- Profile dropdown
    local th_profiles = get_th_profiles_cached();
    if (#th_profiles > 0) then
        local profile_names = {};
        local current_idx = 0;
        for i, p in ipairs(th_profiles) do
            profile_names[i] = p.name;
            if (p.name == (s.th_profile or 'Retail')) then
                current_idx = i - 1;
            end
        end
        local combo_str = table.concat(profile_names, '\0') .. '\0';
        set_int_buf[1] = current_idx;
        imgui.PushItemWidth(math_min((imgui.GetContentRegionAvail()), 200));
        if imgui.Combo('Active Profile', set_int_buf, combo_str) then
            local new_name = profile_names[set_int_buf[1] + 1];
            if (new_name ~= nil and new_name ~= s.th_profile) then
                s.th_profile = new_name;
                ui.settings_dirty = true;
                if (tracker ~= nil) then
                    tracker.invalidate_th_cache();
                    tracker.set_settings(s);
                end
            end
        end
        imgui.PopItemWidth();
    end

    imgui.SameLine();
    if imgui.Button('Advanced Settings##th') then
        th_adv_open[1] = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Manage TH gear profiles, items, and job traits.\nPre-populated with retail THF gear and trait data.\nCreate custom profiles for private servers.');
    end

    imgui.Spacing();
    imgui.TextColored(settings_header_color, 'Startup');
    imgui.Separator();

    set_bool_buf[1] = s.show_on_load;
    if imgui.Checkbox('Open window when addon loads', set_bool_buf) then
        s.show_on_load = set_bool_buf[1];
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
-- Compact mode style color indices (hoisted to avoid per-frame allocation)
local compact_style_color_ids = {
    ImGuiCol_Border, ImGuiCol_BorderShadow,
    ImGuiCol_ScrollbarBg, ImGuiCol_ScrollbarGrab,
    ImGuiCol_ScrollbarGrabHovered, ImGuiCol_ScrollbarGrabActive,
    ImGuiCol_TableHeaderBg, ImGuiCol_TableBorderStrong, ImGuiCol_TableBorderLight,
    ImGuiCol_TableRowBg, ImGuiCol_TableRowBgAlt,
    ImGuiCol_ResizeGrip, ImGuiCol_ResizeGripHovered, ImGuiCol_ResizeGripActive,
};

-- Pre-allocated color tables for scaled_color (avoids 14 table allocs per frame)
local compact_scaled_colors = {};
for i = 1, #compact_style_color_ids do
    compact_scaled_colors[i] = { 0, 0, 0, 0 };
end

-- Helper: read a theme color, scale alpha, write into pre-allocated table
local function scaled_color(pool_idx, color_idx, a)
    local r, g, b, ca = imgui.GetStyleColorVec4(color_idx);
    local c = compact_scaled_colors[pool_idx];
    c[1] = r; c[2] = g; c[3] = b; c[4] = ca * a;
    return c;
end

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
    for i, col_idx in ipairs(compact_style_color_ids) do
        imgui.PushStyleColor(col_idx, scaled_color(i, col_idx, a));
    end

    -- Window flags: optional title bar
    local win_flags = ImGuiWindowFlags_NoScrollbar;
    local hide_titlebar = (s ~= nil and s.compact_titlebar == false);
    if (hide_titlebar) then
        win_flags = win_flags + ImGuiWindowFlags_NoTitleBar;
    end

    local compact_ok, compact_err = pcall(function()
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
                    -- Battlefield prefix for mob kills inside BCNM/HTBF
                    local c_bf_diff = tonumber(drop.bf_difficulty);
                    local c_has_bf = (drop.battlefield ~= nil and drop.battlefield ~= '');
                    if (drop.source_type == 0 and c_has_bf) then
                        local c_bf_label = (c_bf_diff ~= nil and c_bf_diff > 0) and 'HTBF' or 'BCNM';
                        imgui.TextColored(source_colors[3], '[' .. c_bf_label .. '] ');
                        imgui.SameLine(0, 0);
                    end
                    imgui.TextDisabled(drop.mob_name or '');
                    -- HTBF difficulty badge (inline)
                    if (c_bf_diff ~= nil and c_bf_diff > 0) then
                        imgui.SameLine(0, 4);
                        local c_dc = difficulty_colors[c_bf_diff] or COLOR_GRAY;
                        imgui.TextColored(c_dc, '[' .. tracker.get_difficulty_label(c_bf_diff) .. ']');
                    end
                    if imgui.IsItemHovered() then
                        local tip = '';
                        if (drop.mob_server_id ~= nil and drop.mob_server_id > 0) then
                            tip = string_format('Mob ID: %.0f', tonumber(drop.mob_server_id));
                        end
                        if (c_has_bf) then
                            if (tip ~= '') then tip = tip .. '\n'; end
                            tip = tip .. 'Battlefield: ' .. drop.battlefield;
                        end
                        if (c_bf_diff ~= nil and c_bf_diff > 0) then
                            if (tip ~= '') then tip = tip .. '\n'; end
                            tip = tip .. 'Difficulty: ' .. tracker.get_difficulty_full_label(c_bf_diff);
                            local c_bf_name = drop.bf_name;
                            if (c_bf_name ~= nil and c_bf_name ~= '') then
                                tip = tip .. '\nHTBF: ' .. c_bf_name;
                            end
                        end
                        if (tip ~= '') then
                            imgui.SetTooltip(tip);
                        end
                    end

                    imgui.TableNextColumn();
                    imgui.TextDisabled(drop.zone_name or '');

                    imgui.TableNextColumn();
                    local c_src_c;
                    local c_src_l;
                    if (drop.source_type == 0 and c_has_bf) then
                        c_src_c = source_colors[3];
                        c_src_l = (c_bf_diff ~= nil and c_bf_diff > 0) and 'HTBF' or 'BCNM';
                    else
                        c_src_c = source_colors[drop.source_type] or source_colors[0];
                        c_src_l = tracker.get_source_label(drop.source_type, c_bf_diff);
                    end
                    imgui.TextColored(c_src_c, c_src_l);

                    imgui.TableNextColumn();
                    if ((drop.quantity or 1) > 1) then
                        imgui.Text(tostring(drop.quantity));
                    else
                        imgui.TextDisabled('1');
                    end

                    imgui.TableNextColumn();
                    render_combined_th(drop.th_level or 0, drop.th_estimated or 0, true);

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
    end); -- pcall: ensures PopStyleColor runs even on error
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

        -- Propagate DB dirty flags BEFORE tab rendering.
        -- Tabs are lazy-evaluated (only the active tab runs), so propagation
        -- inside each tab's render function would miss inactive tabs.
        if (db.stats_dirty) then
            stats_cache_dirty = true;
            if (analysis ~= nil and an.analysis_inited) then
                an.cache_dirty = true;
                analysis.invalidate();
            end
        end

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

            if imgui.BeginTabItem('Slot Analysis') then
                render_slot_analysis();
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

        -- Reset popups (must be at same ID scope as BeginPopupModal, not inside tab)
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

    -- TH Advanced Management is a standalone window
    render_th_advanced_window();

    -- Clear per-frame notification flags (per-cache dirty flags handle invalidation)
    db.stats_dirty = false;
    db.kills_dirty = false;
    db.drops_dirty = false;
    db.chest_events_dirty = false;
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
