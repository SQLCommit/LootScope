-- Live-feed filters and rendering. Preformat display strings on cache refresh.

require 'common';

local imgui   = require 'imgui';
local state   = require 'ui_state';
local widgets = require 'ui_widgets';
local containers = require 'containers';   -- container / chest-result labels

local function pct_label(v) return tostring(math.floor(v)) .. '%'; end


local string_format = string.format;
local tostring      = tostring;
local os_date       = os.date;

local FW = ImGuiTableColumnFlags_WidthFixed;
local FS = ImGuiTableColumnFlags_WidthStretch;
local DH = ImGuiTableColumnFlags_DefaultHide;

local COLOR_GRAY  = state.COLOR_GRAY;
local COLOR_GREEN = state.COLOR_GREEN;
local COLOR_RED   = state.COLOR_RED;
local source_colors     = state.source_colors;
local status_colors     = state.status_colors;
local status_labels     = state.status_labels;
local difficulty_colors = state.difficulty_colors;

local display_mob_name   = widgets.display_mob_name;
local render_combined_th = widgets.render_combined_th;
local render_header_row  = widgets.render_header_row;

-- Module refs, refreshed at the entry point.
local db, tracker, s = nil, nil, nil;

local COLOR_CONTENT, COLOR_GRAY      = state.COLOR_CONTENT, state.COLOR_GRAY;

-- Use short names only for badges; keep full content names in source, storage and exports.
local CONTENT_SHORT = {
    ['Domain Invasion']    = 'DI',
    ['Walk of Echoes']     = 'WoE',
    ['Colonization Reive'] = 'CR',
    ['Lair Reive']         = 'LR',
};

local function content_label(ct, battlefield)
    local label = CONTENT_SHORT[ct] or ct;
    if (ct == 'Walk of Echoes' and battlefield ~= nil and battlefield ~= '') then
        local n = battlefield:match('^Walk #(%d+)$');
        if (n ~= nil) then return label .. ' #' .. n; end
    end
    return label;
end

local status_tips = {
    [ 1] = 'Got: Item obtained by a player.',
    [ 2] = 'Full: Inventory was full, item lost.',
    [-1] = 'Lost: Nobody lotted in time.',
    [-2] = 'Zone: Player left zone before lotting.',
    [ 0] = 'Pending: Still in treasure pool.',
};

local feed_col_defs = {
    { key = 'time',       label = 'Time',    flags = FW,      width = 45,  tip = 'Real time the drop/kill occurred' },
    { key = 'mob',        label = 'Mob',     flags = FS,      width = 0,   tip = 'Name of the defeated enemy or container' },
    { key = 'zone',       label = 'Zone',    flags = FS + DH, width = 0,   tip = 'Zone where the kill happened' },
    -- 90 fits the longest content name ("Domain Invasion", 15 chars) -- the same width 'moon_phase'
    -- below already uses for "Waxing Crescent". At 48 every content name was clipped.
    { key = 'source',     label = 'Source',  flags = FW + DH, width = 90,  tip = 'Drop source: Mob, Chest, Coffer, or content type' },
    { key = 'item',       label = 'Item',    flags = FS,      width = 0,   tip = 'Item that appeared in the treasure pool' },
    { key = 'qty',        label = 'Qty',     flags = FW,      width = 30,  tip = 'Quantity of the item dropped' },
    { key = 'th',         label = 'TH',      flags = FW,      width = 25,  tip = 'TH level on mob at kill\n* = estimated' },
    { key = 'status',     label = 'Status',  flags = FW,      width = 35,  tip = 'Won, Lost, or still in pool' },
    { key = 'lot',        label = 'Lot',     flags = FW + DH, width = 30,  tip = 'Winning lot (0-999), shown only when you cast a lot' },
    { key = 'winner',     label = 'Winner',  flags = FS + DH, width = 0,   tip = 'Player who won the item' },
    { key = 'killer',     label = 'Killer',  flags = FW + DH, width = 75,  tip = 'Entity that dealt the killing blow' },
    { key = 'vana_day',   label = 'Day',     flags = FW + DH, width = 75,  tip = "Vana'diel day of the week" },
    { key = 'vana_hour',  label = 'V.Hour',  flags = FW + DH, width = 42,  tip = "Vana'diel hour (0-23)" },
    { key = 'moon_phase', label = 'Moon',    flags = FW + DH, width = 90,  tip = 'Moon phase at time of kill' },
    { key = 'moon_pct',   label = 'Moon%',  flags = FW + DH, width = 42,  tip = 'Moon illumination (0-100)' },
    { key = 'weather',    label = 'Weather', flags = FW + DH, width = 80,  tip = 'Weather condition at time of kill' },
    { key = 'kill_id',    label = 'Kill ID', flags = FW + DH, width = 40,  tip = 'Database record ID' },
    { key = 'mob_id',     label = 'Mob ID',  flags = FW + DH, width = 50,  tip = 'Server entity ID of the mob' },
};

local feed_fmt_ref = nil;       -- last-formatted table reference

local feed_filter_src = nil;    -- raw_feed reference that produced the cached filter
local feed_filter_empty = nil;  -- show_empty value at cache time
local feed_filter_gil = nil;    -- show_gil value at cache time
local feed_filter_cache = nil;  -- the filtered T{} result

local function preformat_feed(feed)
    if (feed == feed_fmt_ref) then return; end
    feed_fmt_ref = feed;
    for _, row in ipairs(feed) do
        local ts = row.ts or row.timestamp or 0;
        row._fmt_hm   = os_date('%H:%M', ts);
        row._fmt_full = os_date('%Y-%m-%d %H:%M:%S', ts);
    end
end

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
        local has_visible = nil;
        if (not show_gil) then
            has_visible = {};
            for _, row in ipairs(raw_feed) do
                if (row.feed_type == 'drop'
                    and not (row.item_id == 65535 and row.source_type == 0)) then
                    has_visible[row.kill_id] = true;
                end
            end
        end

        feed = T{};
        for _, row in ipairs(raw_feed) do
            local dominated = false;
            local emit = row;
            -- Hide empty kills (no drops at all) when setting is off
            if (not show_empty and row.feed_type == 'kill') then
                dominated = true;
            end
            -- Hide mob gil drops when setting is off (keep chest/BCNM gil)
            if (not show_gil and row.feed_type == 'drop'
                and row.item_id == 65535 and row.source_type == 0) then
                if (show_empty and not has_visible[row.kill_id]) then
                    emit = {};
                    for k, v in pairs(row) do emit[k] = v; end
                    emit.feed_type = 'kill';
                    emit.item_name = nil; emit.item_id = 0; emit.quantity = 0;
                    emit.won = 0;         emit.pool_slot = -1;
                    emit.lot_value = 0;   emit.winner_name = '';
                else
                    dominated = true;
                end
            end
            if (not dominated) then
                feed:append(emit);
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

    local _a, _b = imgui.GetContentRegionAvail();
    local avail_h = (type(_b) == 'number' and _b) or (type(_a) == 'number' and _a) or 0;
    if (avail_h < 60) then avail_h = 280; end
    if not imgui.BeginTable('live_feed', #feed_col_defs, table_flags, { 0, avail_h }) then return; end

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
        -- A battlefield string alone does not imply BCNM/HTBF; WoE also stores walk names there.
        local row_content = row.content_type or '';
        local is_bf_content = has_bf and (row_content == '' or row_content == 'BCNM');

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
                tip = tip .. '\nMoon: ' .. tostring(math.floor(mp)) .. '%% ' .. phase_label;
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
            local ctype_label = containers.get_container_label(row.container_type);
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
            -- Name the interacted entity; payout belongs in the item/quantity columns.
            imgui.Text(containers.get_container_full_label(row.container_type));
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
            -- Prefer content badges over container type when both are known.
            if (is_bf_content) then
                local bf_label = (bf_diff ~= nil and bf_diff > 0) and 'HTBF' or 'BCNM';
                imgui.TextColored(source_colors[3], '[' .. bf_label .. '] ');
                imgui.SameLine(0, 0);
            elseif (row.source_type ~= 0 and ct == '') then
                imgui.TextColored(src_color, '[' .. src_label .. '] ');
                imgui.SameLine(0, 0);
            elseif (ct ~= '') then
                -- Content type badge (any content_type: Dynamis, Omen, Sortie, Voidwatch, etc.),
                -- shortened by CONTENT_SHORT; a walk that knows its number wears it: [WoE #3].
                imgui.TextColored(COLOR_CONTENT, '[' .. content_label(ct, row.battlefield) .. '] ');
                imgui.SameLine(0, 0);
            end
            -- The coffer row is STORED as "Treasure Coffer (Walk #3)" so Statistics keeps the walks
            -- apart; the feed shows the plain name, the badge above carries the walk.
            imgui.Text((display_mob_name(row.mob_name):gsub(' %(Walk #%d+%)$', '')));
            -- HTBF difficulty badge (inline after mob name)
            if (bf_diff ~= nil and bf_diff > 0) then
                imgui.SameLine(0, 4);
                local dc = difficulty_colors[bf_diff] or COLOR_GRAY;
                imgui.TextColored(dc, '[' .. tracker.get_difficulty_label(bf_diff) .. ']');
            end
            if imgui.IsItemHovered() then
                local tip = display_mob_name(row.mob_name);
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
            imgui.TextColored(src_chest_color, containers.get_container_label(row.container_type));
        else
            local bf_d = tonumber(row.bf_difficulty);
            local src_c;
            local src_l;
            local row_ct = row.content_type or '';
            -- Show content when known, otherwise the source object type, for containers and mobs alike.
            if (is_bf_content) then
                src_c = source_colors[3];
                src_l = (bf_d ~= nil and bf_d > 0) and 'HTBF' or 'BCNM';
            elseif (row_ct ~= '') then
                src_c = COLOR_CONTENT;
                src_l = row_ct;   -- full name here; only the badge is shortened
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
                -- Gil is automatic; omit lot/win/loss status.
                imgui.TextDisabled('-');
            else
                imgui.TextColored(COLOR_RED, containers.get_chest_result_label(row.chest_result));
            end
        elseif (is_empty_kill) then
            imgui.TextDisabled('-');
        elseif ((row.item_id or 0) == 65535) then
            -- Gil is always auto-obtained: no lot, no win, no loss. A status here is noise.
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
        elseif ((row.lot_value or 0) > 0 and (row.player_action or 0) == 1) then
            -- Show a lot only for an explicit player roll; server auto-distribution can also generate
            -- 0-999.
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

        widgets.optional_num_cell(row.moon_phase,   tracker.get_moon_phase_label);
        widgets.optional_num_cell(row.moon_percent, pct_label);
        widgets.optional_num_cell(row.weather,      tracker.get_weather_label);

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

local M = {};

function M.render()
    db, tracker, s = state.db, state.tracker, state.s;
    return render_live_feed();
end

return M;
