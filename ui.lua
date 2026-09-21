-- LootScope dashboard and compact overlay.

require 'common';

local imgui = require 'imgui';
local state           = require 'ui_state';
local ui_slot_analysis = require 'ui_slot_analysis';
local ui_settings     = require 'ui_settings';
local ui_statistics   = require 'ui_statistics';
local ui_live_feed    = require 'ui_live_feed';
local ui_th           = require 'ui_th';
local widgets         = require 'ui_widgets';
local ui_export       = require 'ui_export';
local chat  = require 'chat';

local ui = {};

ui_settings.bind(ui);

local _compact_err_logged = false;   -- throttle the compact-render error print (once per session)

-- Distant kills (mob defeated far from you) can't resolve a name -> the client returns 'none'.
local display_mob_name = widgets.display_mob_name;
local render_combined_th = widgets.render_combined_th;
local render_header_row = widgets.render_header_row;
local source_colors = state.source_colors;
local status_colors = state.status_colors;
local status_labels = state.status_labels;
local difficulty_colors = state.difficulty_colors;

-- Cached References
local math_max = math.max;
local math_min = math.min;
local string_format = string.format;
local os_date = os.date;
local os_clock = os.clock;
local tostring = tostring;

-- Module State
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

-- Slot Analysis tab state — consolidated into one table (upvalue hygiene)
local an = state.an;   -- Slot Analysis state; shared object, mutated in place

-- Helpers

local format_count = state.format_count;

local COLOR_ERR, COLOR_LIGHT_GRAY    = state.COLOR_ERR, state.COLOR_LIGHT_GRAY;
local COLOR_GRAY, COLOR_WARN         = state.COLOR_GRAY, state.COLOR_WARN;
-- Share the reset confirmation buffer through ui_state.
local reset_confirm_buf = { '' };
local reset_confirm_buf_size = 32;

local FW = ImGuiTableColumnFlags_WidthFixed;
local FS = ImGuiTableColumnFlags_WidthStretch;
local DH = ImGuiTableColumnFlags_DefaultHide;


local compact_col_defs = {
    { key = 'time',       label = 'Time',    flags = FW,      width = 38,  tip = 'Real time the drop/kill occurred' },
    { key = 'item',       label = 'Item',    flags = FS,      width = 0,   tip = 'Item that appeared in the treasure pool' },
    { key = 'mob',        label = 'Mob',     flags = FS,      width = 0,   tip = 'Name of the defeated enemy or container' },
    { key = 'zone',       label = 'Zone',    flags = FS + DH, width = 0,   tip = 'Zone where the kill happened' },
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 40,  tip = 'Drop source: Mob, Chest, Coffer, or content type' },
    { key = 'qty',        label = 'Qty',     flags = FW + DH, width = 25,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 22,  tip = 'TH level on mob at kill\n* = estimated' },
    { key = 'status',     label = 'Status',  flags = FW + DH, width = 30,  tip = 'Won, Lost, or still in pool' },
    { key = 'lot',        label = 'Lot',     flags = FW + DH, width = 25,  tip = 'Winning lot value (0-999)' },
    { key = 'winner',     label = 'Winner',  flags = FS + DH, width = 0,   tip = 'Player who won the item' },
    { key = 'killer',     label = 'Killer',  flags = FW + DH, width = 60,  tip = 'Entity that dealt the killing blow' },
    { key = 'vana_day',   label = 'Day',     flags = FW + DH, width = 60,  tip = "Vana'diel day of the week" },
    { key = 'vana_hour',  label = 'V.Hour',  flags = FW + DH, width = 35,  tip = "Vana'diel hour (0-23)" },
    { key = 'moon_phase', label = 'Moon',    flags = FW + DH, width = 70,  tip = 'Moon phase at time of kill' },
    { key = 'moon_pct',   label = 'Moon%',  flags = FW + DH, width = 35,  tip = 'Moon illumination (0-100)' },
    { key = 'weather',    label = 'Weather', flags = FW + DH, width = 70,  tip = 'Weather condition at time of kill' },
    { key = 'kill_id',    label = 'Kill ID', flags = FW + DH, width = 35,  tip = 'Database record ID' },
    { key = 'mob_id',     label = 'Mob ID',  flags = FW + DH, width = 40,  tip = 'Server entity ID of the mob' },
};

-- Export owns parse_date/get_zone_combo/ef and the whole Advanced Export window; it needs these
-- shared helpers injected because requiring ui.lua from here would be a load cycle.
ui_export.bind({
    ui                 = ui,
    source_colors      = source_colors,
    status_colors      = status_colors,
    status_labels      = status_labels,
    display_mob_name   = display_mob_name,
    render_combined_th = render_combined_th,
    render_header_row  = render_header_row,
});

-- Initialization
function ui.init(db_ref, tracker_ref, settings_ref, analysis_ref)
    db = db_ref;
    tracker = tracker_ref;
    s = settings_ref;
    analysis = analysis_ref;
    -- Publish module references for the tab renderers.
    state.db, state.tracker, state.s, state.analysis = db_ref, tracker_ref, settings_ref, analysis_ref;
    compact_mode = s.compact_mode or false;
end

function ui.apply_settings(new_s)
    s = new_s;
    state.s = new_s;
    if s then
        compact_mode = s.compact_mode or false;
    end
end

function ui.sync_settings()
    if (s == nil) then return; end
    s.compact_mode = compact_mode;
end

-- Helpers: Pre-format timestamps on cached feed data (once per cache rebuild)
local compact_fmt_ref = nil;

-- Filtered compact drops cache
local compact_filter_src = nil;
local compact_filter_gil = nil;
local compact_filter_cache = nil;


local function preformat_compact(drops)
    if (drops == compact_fmt_ref) then return; end
    compact_fmt_ref = drops;
    for _, row in ipairs(drops) do
        local ts = row.timestamp or 0;
        row._fmt_hm   = os_date('%H:%M', ts);
        row._fmt_hms  = os_date('%H:%M:%S', ts);
    end
end

local export_tab_was_open = false;

-- Compact Mode
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

    local shown = imgui.Begin('LootScope', is_open, win_flags);
    if shown then
    local compact_ok, compact_err = pcall(function()
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
                            tip = tip .. '\nMoon: ' .. tostring(math.floor(mp)) .. '%% ' .. phase_label;
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
    end); -- pcall wraps the BODY only, so Begin/End + PopStyleColor stay balanced even on a render error
    if (not compact_ok and not _compact_err_logged) then
        _compact_err_logged = true;
        print(chat.header('lootscope'):append(chat.error('Compact render error: ' .. tostring(compact_err))));
    end
    end -- if shown
    imgui.End();
    imgui.PopStyleColor(#compact_style_color_ids);
end

-- Full Dashboard
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
        local char_label = tracker.char_folder and ('[' .. tracker.char_folder .. '] ')
                        or (tracker.char_name and ('[' .. tracker.char_name .. '] ') or '');
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
                ui_live_feed.render();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Statistics') then
                ui_statistics.render();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Slot Analysis') then
                ui_slot_analysis.render();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Export') then
                if (not export_tab_was_open) then
                    export_tab_was_open = true;
                    ui_export.set_db_size(db.get_file_size());
                end
                ui_export.render_tab();
                imgui.EndTabItem();
            else
                export_tab_was_open = false;
            end

            if imgui.BeginTabItem('Settings') then
                ui_settings.render();
                imgui.EndTabItem();
            end

            imgui.EndTabBar();
        end

        -- Reset popups
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

-- Main Render Entry Point
function ui.render()
    if not is_open[1] then return; end

    -- Don't render anything until character is logged in and DB is ready
    if (db.conn == nil) then return; end

    if (db.stats_dirty) then
        ui_statistics.mark_dirty();
        if (analysis ~= nil and an.analysis_inited) then
            an.cache_dirty = true;
            analysis.invalidate();
        end
    end

    if compact_mode then
        render_compact();
    else
        render_full();
    end

    -- Advanced Export is a standalone window (no dimming)
    ui_export.render_window();

    -- TH Advanced Management is a standalone window
    ui_th.render();

    -- Clear per-frame notification flags (per-cache dirty flags handle invalidation)
    db.stats_dirty = false;
end

-- Public: Window control
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

ui.get_export_filters = ui_export.get_export_filters;

return ui;
