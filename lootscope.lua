--[[
    LootScope v1.2.1 - Loot Drop Tracker for Ashita v4

    Tracks treasure pool drops, lot/win outcomes, and Treasure Hunter
    levels. Stores data in SQLite for statistical analysis. Provides
    a dashboard UI with live feed, statistics, slot analysis, export,
    and compact mode.

    v1.2.1: VW bug fixes — consecutive cycle detection, relinquish
    tracking via 0x05B EventEnd, buff-based kill tagging (ID 475),
    three-layer finalization redundancy.
    v1.2.0: Voidwatch loot tracking (Riftworn Pyxis via 0x034),
    Voidwatch statistics category, content type tagging.
    v1.1.1: Slot Analysis tab, content type detection (0x0075),
    grouped statistics filters, battlefield mode, advanced export
    content-type filtering, dead code cleanup.
    v1.1.0: HTBF difficulty tracking (via 0x005C), chest interaction
    pre-identification (via outgoing 0x1A).

    Commands:
        /loot or /lootscope    - Toggle the LootScope window
        /loot show | hide      - Show or hide the window
        /loot compact          - Toggle compact mode
        /loot resetui          - Reset window size and position
        /loot stats [mob]      - Print drop stats to chat
        /loot help             - Show commands

    Author: SQLCommit
    Version: 1.2.1
]]--

addon.name    = 'lootscope';
addon.author  = 'SQLCommit';
addon.version = '1.2.1';
addon.desc    = 'Loot drop tracker with statistics and Treasure Hunter monitoring.';
addon.link    = 'https://github.com/SQLCommit/lootscope';

require 'common';

local chat     = require 'chat';
local settings = require 'settings';

local ok_db, db = pcall(require, 'db');
local ok_tr, tracker = pcall(require, 'tracker');
local ok_ui, ui = pcall(require, 'ui');
local ok_an, analysis = pcall(require, 'analysis');

if (not ok_db or not ok_tr or not ok_ui) then
    print(chat.header('lootscope'):append(chat.error(
        'Failed to load modules: '
        .. (not ok_db and 'db(' .. tostring(db) .. ') ' or '')
        .. (not ok_tr and 'tracker(' .. tostring(tracker) .. ') ' or '')
        .. (not ok_ui and 'ui(' .. tostring(ui) .. ')' or '')
    )));
    return;
end

if (not ok_an) then
    print(chat.header('lootscope'):append(chat.error(
        'Failed to load analysis module: ' .. tostring(analysis)
        .. '. Slot Analysis tab will be unavailable.')));
    analysis = nil;
end

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------
local default_settings = T{
    feed_max_entries  = 100,
    compact_mode      = false,
    show_empty_kills  = true,
    show_gil_drops    = true,
    compact_bg_alpha  = 0.8,
    compact_titlebar  = false,
    show_on_load      = true,
};

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local s = nil;

-------------------------------------------------------------------------------
-- Helper: Print with addon header
-------------------------------------------------------------------------------
local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function msg_success(text)
    print(chat.header(addon.name):append(chat.success(text)));
end

local function msg_error(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

-------------------------------------------------------------------------------
-- Export to CSV
-------------------------------------------------------------------------------

local function csv_escape(val)
    local str = tostring(val or '');
    if (str:find('[,"\n]')) then
        return '"' .. str:gsub('"', '""') .. '"';
    end
    return str;
end

-- Shared CSV header (33 columns)
local CSV_HEADER = 'Kill ID,Date,Time,Mob,Mob Server ID,Zone,Zone ID,Source,TH,'
    .. 'Killer,Killer ID,TH Action,TH Action ID,'
    .. 'Vana Day,Vana Hour,Moon Phase,Moon %,Weather,'
    .. 'Battlefield,Difficulty,Content Type,Distant,Level Cap,'
    .. 'Item,Item ID,Qty,Won,Lot,'
    .. 'Winner ID,Winner,Player Lot,Player Action,Drop Time\n';

local function export_data()
    local base_dir = AshitaCore:GetInstallPath() .. '\\config\\addons\\lootscope\\exports';
    ashita.fs.create_directory(base_dir);

    local timestamp = os.date('%Y%m%d_%H%M%S');
    local char_name = tracker.char_name or 'unknown';
    local file_path = base_dir .. '\\lootscope_' .. char_name .. '_' .. timestamp .. '.csv';

    local f, err = io.open(file_path, 'w');
    if (not f) then
        msg_error('Failed to create export file: ' .. tostring(err));
        return;
    end

    f:write(CSV_HEADER);

    -- Wrap streaming in pcall so file handle is always closed on error
    local write_ok, write_err = pcall(function()
        db.stream_export_all(function(kill, drops)
            local ts      = kill.timestamp or 0;
            local date_s  = os.date('%Y-%m-%d', ts);
            local time_s  = os.date('%H:%M:%S', ts);
            local source  = tracker.get_source_label(kill.source_type, kill.bf_difficulty);
            local weekday = tracker.get_weekday_label(kill.vana_weekday);
            local vh      = (kill.vana_hour ~= nil and kill.vana_hour >= 0) and string.format('%02d:00', kill.vana_hour) or '';
            local mp      = (kill.moon_percent ~= nil and kill.moon_percent >= 0) and tostring(kill.moon_percent) or '';
            local phase   = (kill.moon_phase ~= nil and kill.moon_phase >= 0) and tracker.get_moon_phase_label(kill.moon_phase) or '';
            local th_act  = tracker.get_action_type_label(kill.th_action_type);
            local weather = (kill.weather ~= nil and kill.weather >= 0) and tracker.get_weather_label(kill.weather) or '';

            local kp = {
                tostring(kill.id or 0), csv_escape(date_s), csv_escape(time_s),
                csv_escape(kill.mob_name), tostring(kill.mob_server_id or 0),
                csv_escape(kill.zone_name), tostring(kill.zone_id or 0),
                csv_escape(source), tostring(kill.th_level or 0),
                csv_escape(kill.killer_name or ''), tostring(kill.killer_id or 0),
                csv_escape(th_act), tostring(kill.th_action_id or 0),
                csv_escape(weekday), csv_escape(vh),
                csv_escape(phase), csv_escape(mp),
                csv_escape(weather),
                csv_escape(kill.bf_name or ''),
                csv_escape(tracker.get_difficulty_label(kill.bf_difficulty)),
                csv_escape(kill.content_type or ''),
                tostring(kill.is_distant or 0),
                tostring(kill.level_cap or ''),
            };
            local kill_prefix = table.concat(kp, ',');

            if (drops and #drops > 0) then
                for _, drop in ipairs(drops) do
                    local drop_time = (drop.timestamp and drop.timestamp > 0) and os.date('%H:%M:%S', drop.timestamp) or '';
                    local row = {
                        kill_prefix,
                        csv_escape(drop.item_name), tostring(drop.item_id or 0),
                        tostring(drop.quantity or 1), tostring(drop.won or 0),
                        tostring(drop.lot_value or 0),
                        tostring(drop.winner_id or 0), csv_escape(drop.winner_name or ''),
                        tostring(drop.player_lot or 0), tostring(drop.player_action or 0),
                        csv_escape(drop_time),
                    };
                    f:write(table.concat(row, ',') .. '\n');
                end
            else
                f:write(kill_prefix .. ',,,,,,,,,,\n');
            end
        end);

        -- Append chest events (failures + gil) as separate rows
        local chest_events = db.get_recent_chest_events(10000);
        if (#chest_events > 0) then
            f:write('\n');
            f:write('Chest Event ID,Date,Time,Container,Result,Zone,Zone ID,Gil,');
            f:write('Vana Day,Vana Hour,Moon Phase,Moon %,Weather\n');
            for _, ce in ipairs(chest_events) do
                local ts = ce.timestamp or 0;
                local date_s = os.date('%Y-%m-%d', ts);
                local time_s = os.date('%H:%M:%S', ts);
                local container = tracker.get_container_label(ce.container_type);
                local result = tracker.get_chest_result_label(ce.result);
                local weekday = tracker.get_weekday_label(ce.vana_weekday);
                local vh = (ce.vana_hour ~= nil and ce.vana_hour >= 0) and string.format('%02d:00', ce.vana_hour) or '';
                local mp = (ce.moon_percent ~= nil and ce.moon_percent >= 0) and tostring(ce.moon_percent) or '';
                local phase = (ce.moon_phase ~= nil and ce.moon_phase >= 0) and tracker.get_moon_phase_label(ce.moon_phase) or '';
                local weather = (ce.weather ~= nil and ce.weather >= 0) and tracker.get_weather_label(ce.weather) or '';
                local row = {
                    tostring(ce.id or 0), csv_escape(date_s), csv_escape(time_s),
                    csv_escape(container), csv_escape(result),
                    csv_escape(ce.zone_name), tostring(ce.zone_id or 0),
                    tostring(ce.gil_amount or 0),
                    csv_escape(weekday), csv_escape(vh),
                    csv_escape(phase), csv_escape(mp),
                    csv_escape(weather),
                };
                f:write(table.concat(row, ',') .. '\n');
            end
        end
    end);

    f:close();

    if (not write_ok) then
        pcall(os.remove, file_path);  -- clean up partial file
        msg_error('Export write failed: ' .. tostring(write_err));
        return;
    end

    msg_success('Exported to exports\\lootscope_' .. char_name .. '_' .. timestamp .. '.csv');
end

-------------------------------------------------------------------------------
-- Export Filtered Data to CSV
-------------------------------------------------------------------------------

local function export_filtered_data()
    local filters = ui.get_export_filters();
    if (filters == nil) then
        msg_error('No filtered data to export. Apply filters first.');
        return;
    end

    local total = db.get_filtered_export_count(filters);
    if (total == 0) then
        msg_error('No results match the current filters.');
        return;
    end

    local base_dir = AshitaCore:GetInstallPath() .. '\\config\\addons\\lootscope\\exports';
    ashita.fs.create_directory(base_dir);

    local timestamp = os.date('%Y%m%d_%H%M%S');
    local char_name = tracker.char_name or 'unknown';
    local file_path = base_dir .. '\\lootscope_' .. char_name .. '_filtered_' .. timestamp .. '.csv';

    local f, err = io.open(file_path, 'w');
    if (not f) then
        msg_error('Failed to create export file: ' .. tostring(err));
        return;
    end

    f:write(CSV_HEADER);

    -- Wrap streaming in pcall so file handle is always closed on error
    local row_count = 0;
    local write_ok, write_err = pcall(function()
        db.stream_filtered_export(filters, function(row)
            local ts      = row.timestamp or 0;
            local date_s  = os.date('%Y-%m-%d', ts);
            local time_s  = os.date('%H:%M:%S', ts);
            local source  = tracker.get_source_label(row.source_type, row.bf_difficulty);
            local weekday = tracker.get_weekday_label(row.vana_weekday);
            local vh      = (row.vana_hour ~= nil and row.vana_hour >= 0) and string.format('%02d:00', row.vana_hour) or '';
            local mp      = (row.moon_percent ~= nil and row.moon_percent >= 0) and tostring(row.moon_percent) or '';
            local phase   = (row.moon_phase ~= nil and row.moon_phase >= 0) and tracker.get_moon_phase_label(row.moon_phase) or '';
            local drop_time = (row.drop_timestamp and row.drop_timestamp > 0) and os.date('%H:%M:%S', row.drop_timestamp) or '';
            local th_act  = tracker.get_action_type_label(row.th_action_type);
            local weather = (row.weather ~= nil and row.weather >= 0) and tracker.get_weather_label(row.weather) or '';

            local cols = {
                tostring(row.kill_id or 0), csv_escape(date_s), csv_escape(time_s),
                csv_escape(row.mob_name or ''), tostring(row.mob_server_id or 0),
                csv_escape(row.zone_name or ''), tostring(row.zone_id or 0),
                csv_escape(source), tostring(row.th_level or 0),
                csv_escape(row.killer_name or ''), tostring(row.killer_id or 0),
                csv_escape(th_act), tostring(row.th_action_id or 0),
                csv_escape(weekday), csv_escape(vh),
                csv_escape(phase), csv_escape(mp),
                csv_escape(weather),
                csv_escape(row.bf_name or ''),
                csv_escape(tracker.get_difficulty_label(row.bf_difficulty)),
                csv_escape(row.content_type or ''),
                tostring(row.is_distant or 0),
                tostring(row.level_cap or ''),
                csv_escape(row.item_name or ''), tostring(row.item_id or 0),
                tostring(row.quantity or 1), tostring(row.won or 0),
                tostring(row.lot_value or 0),
                tostring(row.winner_id or 0), csv_escape(row.winner_name or ''),
                tostring(row.player_lot or 0), tostring(row.player_action or 0),
                csv_escape(drop_time),
            };
            f:write(table.concat(cols, ',') .. '\n');
            row_count = row_count + 1;
        end);
    end);

    f:close();

    if (not write_ok) then
        pcall(os.remove, file_path);  -- clean up partial file
        msg_error('Filtered export write failed: ' .. tostring(write_err));
        return;
    end

    msg_success('Exported ' .. tostring(row_count) .. ' filtered rows to exports\\lootscope_' .. char_name .. '_filtered_' .. timestamp .. '.csv');
end

-------------------------------------------------------------------------------
-- Help
-------------------------------------------------------------------------------
local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));
    local cmds = T{
        { '/loot',              'Toggle the LootScope window.' },
        { '/loot show / hide',  'Show or hide the window.' },
        { '/loot compact',      'Toggle compact mode.' },
        { '/loot resetui',      'Reset window size and position.' },
        { '/loot stats [mob]',  'Print mob drop stats to chat.' },
        { '/loot help',         'Show this help message.' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.success(v[1])):append(chat.message(' - ' .. v[2])));
    end);
end

-------------------------------------------------------------------------------
-- Print Stats to Chat
-------------------------------------------------------------------------------
local function print_stats(mob_name)
    if (mob_name == nil or mob_name == '') then
        local kc, dc, mc, cc = db.get_counts();
        local summary = 'Session totals: ' .. tostring(kc) .. ' kills, ' .. tostring(dc) .. ' drops';
        if (mc > 0) then
            summary = summary .. ', ' .. tostring(mc) .. ' missed (mob ID unknown)';
        end
        if (cc > 0) then
            summary = summary .. ', ' .. tostring(cc) .. ' chest events';
        end
        msg(summary);
        return;
    end

    local all = db.get_all_mob_stats();
    local found = false;
    for _, row in ipairs(all) do
        if (row.mob_name ~= nil and row.mob_name:lower() == mob_name:lower()) then
            found = true;
            local mob_distant = row.distant_kills or 0;
            local nearby = row.kill_count - mob_distant;
            local header;
            if (mob_distant > 0) then
                header = row.mob_name .. ' (' .. row.zone_name .. '): ' ..
                    tostring(nearby) .. ' nearby + ' .. tostring(mob_distant) .. ' distant = ' ..
                    tostring(row.kill_count) .. ' kills, ' ..
                    tostring(row.drop_count) .. ' drops (' ..
                    tostring(row.unique_items) .. ' unique)';
            else
                header = row.mob_name .. ' (' .. row.zone_name .. '): ' ..
                    tostring(row.kill_count) .. ' kills, ' ..
                    tostring(row.drop_count) .. ' drops (' ..
                    tostring(row.unique_items) .. ' unique)';
            end
            msg(header);

            local stats = db.get_mob_stats(row.mob_name, row.zone_id);
            if (stats ~= nil and stats.items ~= nil) then
                for _, item in ipairs(stats.items) do
                    local rate_str = string.format('%.1f%%', item.drop_rate);
                    if (mob_distant > 0 and (item.combined_rate or -1) >= 0) then
                        rate_str = rate_str .. string.format(' | combined: %.1f%%', item.combined_rate);
                    end
                    print(chat.header(addon.name):append(chat.message(
                        '  ' .. item.item_name .. ': ' ..
                        tostring(item.times_dropped) .. 'x (' .. rate_str .. ')'
                    )));
                end
            end
        end
    end

    if (not found) then
        msg_error('No data found for mob: ' .. mob_name);
    end
end

-------------------------------------------------------------------------------
-- Event: Load
-------------------------------------------------------------------------------
ashita.events.register('load', 'lootscope_load', function()
    s = settings.load(default_settings);

    -- Store base path for deferred per-character DB init
    local config_path = AshitaCore:GetInstallPath() .. '\\config\\addons\\lootscope';
    ashita.fs.create_directory(config_path);

    -- DB init is deferred until character name is detected (tracker.check_character)
    tracker.init(db, config_path);
    ui.init(db, tracker, s, analysis);

    if (not s.show_on_load) then
        ui.hide();
    end

    print(chat.header(addon.name):append(chat.message('v' .. addon.version .. ' loaded. Use ')):append(chat.success('/loot')):append(chat.message(' to toggle window.')));
end);

-------------------------------------------------------------------------------
-- Event: Unload
-------------------------------------------------------------------------------
ashita.events.register('unload', 'lootscope_unload', function()
    -- Don't mark pool items as Zoned here — they may still be in the pool
    -- on addon reload. scan_pool() reconnects with existing DB records on load.
    -- Actual zone changes are handled by check_zone().

    pcall(ui.sync_settings);
    pcall(settings.save);
    pcall(db.close);
end);

-------------------------------------------------------------------------------
-- Event: Text In (mob name resolution from chat when entity is out of range)
-- Parses "X defeats MobName." and "You find ... on MobName." messages.
-------------------------------------------------------------------------------
ashita.events.register('text_in', 'lootscope_text_in', function(e)
    local text = e.message_modified;
    if (text == nil or text == '') then return; end

    local ok, err = pcall(function()
        -- Chest failure detection via text patterns (gil is handled by 0x001E packet)
        tracker.handle_chest_text(text);

        -- Battlefield entry detection (fires before mob name resolution check)
        tracker.handle_battlefield_text(text);

        -- Only parse mob name resolution when we have unresolved mob names pending
        if (#tracker.pending_mob_resolves == 0) then return; end

        -- Strip non-ASCII bytes (FFXI control bytes, auto-translate markers)
        local clean = text:gsub('[^\x20-\x7E]', '');

        -- Match defeat message (fires for all kills including empty)
        local defeat_mob = clean:match('defeats the (.+)%.') or clean:match('defeats (.+)%.');
        if (defeat_mob ~= nil and defeat_mob ~= '') then
            tracker.resolve_mob_name_from_chat(defeat_mob, true);
            return;
        end

        -- Match loot message
        local loot_mob = clean:match('find .+ on the (.+)%.') or clean:match('find .+ on (.+)%.');
        if (loot_mob ~= nil and loot_mob ~= '') then
            tracker.resolve_mob_name_from_chat(loot_mob, false);
        end
    end);
    -- text_in errors are silently dropped (never print from text_in — stack overflow)
end);

-------------------------------------------------------------------------------
-- Event: Command
-------------------------------------------------------------------------------
ashita.events.register('command', 'lootscope_command', function(e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/loot', '/lootscope')) then
        return;
    end

    e.blocked = true;

    local cmd = (#args >= 2) and args[2]:lower() or 'toggle';

    if (cmd == 'toggle') then
        ui.toggle();

    elseif (cmd == 'show') then
        ui.show();

    elseif (cmd == 'hide') then
        ui.hide();

    elseif (cmd == 'compact') then
        ui.toggle_compact();

    elseif (cmd == 'resetui') then
        ui.reset_ui();
        msg_success('Window size and position reset.');

    elseif (cmd == 'stats') then
        local mob_name = nil;
        if (#args >= 3) then
            mob_name = args:concat(' ', 3);
        end
        print_stats(mob_name);

    elseif (cmd == 'help') then
        print_help();

    else
        msg_error('Unknown command: ' .. tostring(args[2]) .. '. Use /loot help');
    end
end);

-------------------------------------------------------------------------------
-- Helper: Throttled pcall for per-frame functions (logs each unique error once)
-------------------------------------------------------------------------------
local _frame_errors = {};

local function safe_frame_call(fn, label)
    local ok, err = pcall(fn);
    if (not ok) then
        local key = label .. tostring(err);
        if (not _frame_errors[key]) then
            _frame_errors[key] = true;
            msg_error(label .. ': ' .. tostring(err));
        end
    end
end

-------------------------------------------------------------------------------
-- Helper: Error-capturing pcall (logs errors instead of silently eating them)
-------------------------------------------------------------------------------
local function safe_call(fn, data, label)
    local ok, err = pcall(fn, data);
    if (not ok) then
        msg_error(label .. ': ' .. tostring(err));
    end
end

-------------------------------------------------------------------------------
-- Event: Incoming Packet
-------------------------------------------------------------------------------
ashita.events.register('packet_in', 'lootscope_packet_in', function(e)
    -- 0x0028: Action (TH proc detection)
    if (e.id == 0x0028) then
        safe_call(tracker.handle_action, e.data_modified, '0x0028');
        return;
    end

    -- 0x0029: Battle Message (kill detection — must fire before 0x00D2)
    if (e.id == 0x0029) then
        safe_call(tracker.handle_defeat, e.data_modified, '0x0029');
        return;
    end

    -- 0x00D2: Treasure Pool Item (drop appears, links to existing kill)
    if (e.id == 0x00D2) then
        safe_call(tracker.handle_treasure_pool, e.data_modified, '0x00D2');
        return;
    end

    -- 0x00D3: Lot Result (obtained/dropped/lost)
    if (e.id == 0x00D3) then
        safe_call(tracker.handle_lot_result, e.data_modified, '0x00D3');
        return;
    end

    -- 0x002A: messageSpecial / TALKNUMWORK (chest unlock + failure detection)
    if (e.id == 0x002A) then
        safe_call(tracker.handle_chest_message, e.data_modified, '0x002A');
        return;
    end

    -- 0x001E: Item Quantity Update (chest gil detection — diff from snapshot)
    if (e.id == 0x001E) then
        safe_call(tracker.handle_item_quantity_update, e.data_modified, '0x001E');
        -- Do NOT return — other handlers may want this packet too
    end

    -- 0x0053: systemMessage (secondary chest gil detection via OBTAINS_GIL)
    if (e.id == 0x0053) then
        safe_call(tracker.handle_system_message, e.data_modified, '0x0053');
    end

    -- 0x005C: GP_SERV_COMMAND_PENDINGNUM (HTBF entry detection)
    if (e.id == 0x005C) then
        safe_call(tracker.handle_pending_num, e.data_modified, '0x005C');
    end

    -- 0x0075: GP_SERV_COMMAND_BATTLEFIELD (content type detection)
    if (e.id == 0x0075) then
        safe_call(tracker.handle_battlefield_packet, e.data_modified, '0x0075');
    end

    -- 0x0034: GP_SERV_COMMAND_EVENTNUM (Voidwatch Pyxis loot detection)
    if (e.id == 0x0034) then
        safe_call(tracker.handle_event_begin, e.data_modified, '0x034');
    end

    -- 0x001F: GP_SERV_COMMAND_ITEM_LIST (Voidwatch stackable item delivery)
    if (e.id == 0x001F) then
        safe_call(tracker.handle_item_assign, e.data_modified, '0x01F');
    end

    -- 0x0020: GP_SERV_COMMAND_ITEM_ATTR (Voidwatch equipment/augmented item delivery)
    if (e.id == 0x0020) then
        safe_call(tracker.handle_item_full_info, e.data_modified, '0x020');
    end
end);

-------------------------------------------------------------------------------
-- Event: Outgoing Packet
-------------------------------------------------------------------------------
ashita.events.register('packet_out', 'lootscope_packet_out', function(e)
    -- 0x001A: GP_CLI_COMMAND_ACTION (chest/NPC interaction pre-identification)
    if (e.id == 0x001A) then
        safe_call(tracker.handle_outgoing_action, e.data_modified, '0x1A out');
    end

    -- 0x005B: GP_CLI_COMMAND_EVENTEND (Voidwatch Pyxis close / relinquish all)
    if (e.id == 0x005B) then
        safe_call(tracker.handle_event_end, e.data_modified, '0x5B out');
    end
end);

-------------------------------------------------------------------------------
-- Event: d3d_present (every frame)
-------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'lootscope_present', function()
    -- Deferred DB init: detect character name once logged in
    safe_frame_call(tracker.check_character, 'check_character');

    safe_frame_call(tracker.check_zone, 'check_zone');
    safe_frame_call(tracker.check_battlefield_level_cap, 'check_bf_cap');
    safe_frame_call(tracker.check_voidwatch_buff, 'check_vw_buff');

    -- Retry deferred pool scan (throttled to 1/sec)
    if (tracker.pool_scan_pending) then
        local now = os.clock();
        if (now - tracker.pool_scan_last_try >= 1.0) then
            tracker.pool_scan_last_try = now;
            safe_frame_call(tracker.scan_pool, 'scan_pool');
        end
    end

    -- Proactive stale resolve cleanup (every 5s)
    safe_frame_call(tracker.cleanup_stale_resolves, 'stale_resolves');

    -- Check chest unlock timeout (pending gil detection)
    safe_frame_call(tracker.check_chest_timeout, 'chest_timeout');

    safe_frame_call(db.flush_writes_if_due, 'db_flush');

    if (ui.settings_dirty) then
        ui.settings_dirty = false;
        safe_frame_call(ui.sync_settings, 'sync_settings');
        safe_frame_call(settings.save, 'settings_save');
    end

    if (ui.export_requested) then
        ui.export_requested = false;
        local ok, err = pcall(export_data);
        if (not ok) then
            msg_error('Export failed: ' .. tostring(err));
        end
    end

    if (ui.filtered_export_requested) then
        ui.filtered_export_requested = false;
        local ok, err = pcall(export_filtered_data);
        if (not ok) then
            msg_error('Filtered export failed: ' .. tostring(err));
        end
    end

    if (ui.reset_requested) then
        ui.reset_requested = false;
        local ok, err = pcall(db.clear_data);
        if (ok) then
            tracker.reset();
            if (analysis ~= nil) then analysis.invalidate(); end
            msg_success('All loot data cleared.');
        else
            msg_error('Clear failed: ' .. tostring(err));
        end
    end

    safe_frame_call(ui.render, 'render');
end);

-------------------------------------------------------------------------------
-- Event: Settings changed externally
-------------------------------------------------------------------------------
settings.register('settings', 'lootscope_settings_update', function(new_s)
    if (new_s ~= nil) then
        s = new_s;
        ui.apply_settings(s);
    end
end);
