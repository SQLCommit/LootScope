-- LootScope settings tab.

require 'common';

local imgui = require 'imgui';
local state = require 'ui_state';
local th    = require 'th';         -- TH settings / cache live in th.lua
local ui_th = require 'ui_th';

-- Module refs, refreshed at the entry point. `ui` is injected by M.bind() from ui.lua.
local tracker, s = nil, nil;
local ui = nil;

local set_int_buf = { 0 };        -- Settings tab: SliderInt buffer
local set_float_buf = { 0.0 };    -- Settings tab: SliderFloat buffer
local set_bool_buf = { false };    -- Settings tab: Checkbox buffer

local settings_header_color = { 1.0, 0.65, 0.26, 1.0 };

local function render_settings_tab()
    if (s == nil) then return; end
    imgui.TextColored(settings_header_color, 'Live Feed');
    imgui.Separator();

    local slider_w = 250;   -- fixed so settings widgets don't resize with the window

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
        if (tracker ~= nil) then th.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Estimate TH from the active profile, equipped gear,\nand supported augments. Updates when you attack.\nIncludes supported job traits and the BLU spell-set trait.\nAn estimate is not a server-confirmed proc.');
    end

    set_bool_buf[1] = s.th_trust_detection ~= false;
    if imgui.Checkbox('Detect TH trusts and pets (Beta)', set_bool_buf) then
        s.th_trust_detection = set_bool_buf[1];
        ui.settings_dirty = true;
        if (tracker ~= nil) then th.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Include TH-capable party trusts and BST jug pets\nin the estimate, with a minimum of TH+1 when detected.\nThis is an estimate, not confirmation of a proc.');
    end

    set_bool_buf[1] = s.th_zone_effects ~= false;
    if imgui.Checkbox('Detect zone TH effects (Beta)', set_bool_buf) then
        s.th_zone_effects = set_bool_buf[1];
        ui.settings_dirty = true;
        if (tracker ~= nil) then th.set_settings(s); end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Include Treasure Hound in the estimate: +1 while\nSignet is active and the kupower has been detected.\nAtma and Prowess bonuses are not currently included.');
    end

    -- Profile dropdown
    local th_profiles = ui_th.get_profiles();
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
        imgui.PushItemWidth(200);   -- fixed width (no resize with window)
        if imgui.Combo('Active Profile', set_int_buf, combo_str) then
            local new_name = profile_names[set_int_buf[1] + 1];
            if (new_name ~= nil and new_name ~= s.th_profile) then
                s.th_profile = new_name;
                ui.settings_dirty = true;
                if (tracker ~= nil) then
                    th.invalidate_th_cache();
                    th.set_settings(s);
                end
            end
        end
        imgui.PopItemWidth();
    end

    imgui.SameLine();
    if imgui.Button('Advanced Settings##th') then
        ui_th.open();
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

local M = {};

--- ui.lua hands us its own table so the tab can set reset_step / settings_dirty on it.
function M.bind(ui_ref)
    ui = ui_ref;
end

function M.render()
    tracker, s = state.tracker, state.s;
    return render_settings_tab();
end

return M;
