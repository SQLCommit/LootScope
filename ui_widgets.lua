-- Stateless UI widgets; no DB, tracker or UI-module dependencies.

require 'common';

local imgui = require 'imgui';

local math_max = math.max;
local tostring = tostring;

local function help_marker(text)
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

local function optional_num_cell(value, render)
    imgui.TableNextColumn();
    local v = tonumber(value);
    if (v ~= nil and v >= 0) then
        imgui.Text(render(v));
    else
        imgui.TextDisabled('-');
    end
end

local M = {};

local function display_mob_name(n)
    if (n == 'none') then return '(distant - unknown)'; end
    if (n == nil) then return ''; end
    -- Strip control/star bytes for display only; preserve stored data.
    return (n:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', ''));
end

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
        local tip = 'TH at the time of the kill; shows the higher of the\nconfirmed level and the estimate. * marks an estimate.';
        if (th_srv > 0 and th_est > 0) then
            tip = tip .. '\nServer-confirmed: ' .. tostring(th_srv) .. '  |  Estimated: ' .. tostring(th_est);
            tip = tip .. '\nEstimate = job traits + gear + augments + kupowers';
        elseif (th_est > 0) then
            tip = tip .. '\n* = Estimated from job traits, gear, augments, and kupowers.';
            tip = tip .. '\nNo server-confirmed TH proc was recorded for this mob.';
        elseif (th_srv > 0) then
            tip = tip .. '\nServer-confirmed via TH proc message.';
        end
        imgui.SetTooltip(tip);
    end
end

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

M.display_mob_name = display_mob_name;
M.render_combined_th = render_combined_th;
M.render_header_row = render_header_row;

M.help_marker = help_marker;
M.optional_num_cell = optional_num_cell;

return M;
