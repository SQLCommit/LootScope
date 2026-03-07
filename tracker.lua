--[[
    LootScope v1.2.1 - Packet Tracker
    Parses 0x0028 (action), 0x0029 (defeat), 0x00D2 (treasure pool),
    0x00D3 (lot result), 0x0075 (battlefield entry), 0x005C (HTBF entry),
    0x034 (event/Voidwatch Pyxis), and outgoing 0x1A (NPC interaction)
    packets to track kills, loot drops, lot outcomes, Treasure Hunter
    procs, content type, HTBF difficulty, and Voidwatch Pyxis loot.

    Author: SQLCommit
    Version: 1.2.1
]]--

require 'common';

local sunpack = struct.unpack;
local breader = require 'bitreader';
local vana_time = require 'ffxi.time';
local dats = require 'ffxi.dats';
local ok_dat, datreader = pcall(require, 'datreader');
if (not ok_dat) then datreader = nil; end
local tracker = {};

-------------------------------------------------------------------------------
-- In-Memory State (cleared on zone change)
-------------------------------------------------------------------------------
tracker.th_levels = {};         -- mob_server_id -> TH level (from 0x0028 procs)
tracker.th_actions = {};        -- mob_server_id -> {cmd_no, cmd_arg} (action that triggered last TH proc)
tracker.active_pool = {};       -- pool_slot(0-9) -> {kill_id, item_id, mob_sid, player_lot, player_action}
tracker.mob_kills = {};         -- mob_server_id -> kill_id (link drops to kills)
tracker.mob_kill_times = {};    -- mob_server_id -> os.clock() when kill record was created
tracker.mob_names = {};         -- mob_server_id -> name (cached from 0x0029/0x00D2)
tracker.pet_to_master = {};    -- pet_server_id -> {master_sid, master_tidx} (AOE pet redirect)
tracker.current_zone_id = 0;
tracker.current_zone_name = '';
tracker.char_name = nil;        -- character name (nil until logged in)
tracker.char_folder = nil;      -- <CharName>_<ServerId> folder name

-- Weather memory pointer (initialized once on character login)
tracker.weather_ptr = nil;       -- nil=not attempted, false=failed, number=valid pointer

-- DAT-based entity name lookup (loaded per zone from FFXI DAT files)
tracker.dat_names = {};          -- target_index -> entity name (rebuilt on zone change)

-- Pending mob name resolution queue (for mobs too far to read entity name)
-- Each entry: {mob_sid, kill_id, time, expected_msgs, received_msgs}
tracker.pending_mob_resolves = {};

-- Distant kill dedup credits: each 0x00D2-created distant kill absorbs one msg_id=37
-- Unmatched msg_id=37 events = genuinely missed empty kills
tracker.distant_kill_credits = 0;

-- Deferred pool scan: retries once/sec (up to 10) until pool is loaded
tracker.pool_scan_pending = false;
tracker.pool_scan_retries = 0;
tracker.pool_scan_last_try = 0;

-- Chest unlock pending state (two-phase gil detection)
-- Set when "You unlock the chest/coffer!" detected, cleared on 0x00D2 or timeout.
tracker.chest_unlock_pending = nil;  -- { time, container_type, zone_id, zone_name }

-- Recent 0x001E memory: last gil update for text_in fallback when 0x002A races
tracker.last_gil_update = nil;

-- Battlefield (BCNM) state
tracker.battlefield = {
    name = nil,              -- "Shooting Fish", "Under Observation", etc.
    zone_id = nil,           -- Zone when entered
    level_cap = nil,         -- Detected level cap (nil if uncapped/KSNM)
    active = false,          -- Currently in a BCNM?
    cap_check_pending = false,
    last_kill_id = nil,      -- Most recent kill_id from BCNM crate (for gil recording)
    gil_handled = false,     -- Dedup: true when 0x001E/0x0053 already recorded BCNM gil
    pending_gil = nil,       -- Buffered gil amount: when 0x001E/0x0053 fires before 0x00D2
};

-- HTBF state — set from 0x005C, persists until zone change
tracker.htbf_info = nil;  -- { zone_id, bit_pos, difficulty, bf_name }

-- Outgoing 0x1A interaction — pre-identifies chest/coffer before 0x00D2
tracker.last_interact = nil;  -- { server_id, target_index, name, timestamp }

-- Content type — set by 0x0075, persists until zone change
tracker.content_info = nil;  -- { type='BCNM'|'Dynamis'|'Voidwatch'|..., mode=0x0001, ... }

-- Voidwatch state (Riftworn Pyxis loot tracking via 0x034)
tracker.voidwatch = {
    pyxis_active = false,       -- player talked to Riftworn Pyxis
    pyxis_sid = nil,            -- Pyxis entity server ID
    items_captured = false,     -- first 0x034 processed
    kill_id = nil,              -- linked kill record
    offered = {},               -- { [slot] = item_id } from first 0x034
    last_vw_kill = nil,         -- most recent VW NM kill_id (set by handle_defeat)
};

-- Drop arrival order per mob (for slot analysis ordering queries)
-- mob_server_id -> next sequence number, reset to 0 on kill, incremented per 0x00D2
tracker.drop_sequence = {};

-- Mob gil pending queue (FIFO).
-- After handle_defeat records a SOURCE_MOB kill, the kill_id is pushed here.
-- When 0x0029 msg_id=565 ("obtains X gil") arrives, the oldest entry is popped
-- and the gil recorded as a drop.  FIFO handles AoE: defeats arrive in order,
-- then DistributeGil fires for each mob in the same order.
-- Each entry: { kill_id, time, mob_name }
tracker.mob_gil_queue = {};


-- References set during init
local db = nil;
local base_path = nil;

-------------------------------------------------------------------------------
-- Source Type Constants
-------------------------------------------------------------------------------
tracker.SOURCE_MOB    = 0;
tracker.SOURCE_CHEST  = 1;
tracker.SOURCE_COFFER = 2;
tracker.SOURCE_BCNM   = 3;
tracker.POOL_MAX_SLOT = 9;   -- FFXI treasure pool has slots 0-9

-------------------------------------------------------------------------------
-- Instance Zone Lookup (WIP: Ambuscade/Omen/Sortie need more packet research)
-- Dynamis is detected by zone name prefix instead.
-------------------------------------------------------------------------------
tracker.INSTANCE_ZONES = {
    -- WIP: Uncomment when instance detection is tested
    -- [183] = 'Ambuscade',   -- Maquette Abdhaljs-Legion A
    -- [287] = 'Ambuscade',   -- Maquette Abdhaljs-Legion B
    -- [292] = 'Omen',        -- Reisenjima Henge
    -- [274] = 'Sortie',      -- Outer Ra'Kaznar
    -- [275] = 'Sortie',      -- Outer Ra'Kaznar [U1]
};

function tracker.get_content_type()
    if (tracker.content_info ~= nil) then
        return tracker.content_info.type;
    end
    return '';
end

-------------------------------------------------------------------------------
-- Packet: 0x0075 (S2C) - Battlefield entry (content type detection)
-- Sent on entry + reconnect. Mode 0x0001 = BCNM/HTBF.
-- WIP: Ambuscade/Omen/Sortie disabled — needs more packet research.
-------------------------------------------------------------------------------
local BATTLEFIELD_MODE_MAP = {
    [0x0001] = 'BCNM',
};

function tracker.handle_battlefield_packet(data)
    if (#data < 6) then return; end

    local mode = sunpack('H', data, 0x04 + 1);

    local content_type = BATTLEFIELD_MODE_MAP[mode];
    if (content_type == nil) then
        -- WIP: 0xFFFF = progress bars (used by Omen, etc.)
        -- Instance zone disambiguation disabled until tested.
        content_type = 'Unknown Battlefield';
    end

    -- Skip if already classified with the same type (avoid re-processing duplicates)
    if (tracker.content_info ~= nil and tracker.content_info.type == content_type) then
        return;
    end

    tracker.content_info = { type = content_type };
end

-------------------------------------------------------------------------------
-- Chest Event Constants
-------------------------------------------------------------------------------
tracker.CHEST_RESULT_GIL           = 0;
tracker.CHEST_RESULT_FAIL_PICK     = 1;
tracker.CHEST_RESULT_FAIL_TRAP     = 2;
tracker.CHEST_RESULT_FAIL_MIMIC    = 3;
tracker.CHEST_RESULT_FAIL_ILLUSION = 4;

tracker.CONTAINER_CHEST  = 1;
tracker.CONTAINER_COFFER = 2;

-------------------------------------------------------------------------------
-- Lot Result Status Constants
-------------------------------------------------------------------------------
tracker.STATUS_OBTAINED = 1;   -- won and in inventory
tracker.STATUS_DROPPED  = 2;   -- won but inventory full, item dropped
tracker.STATUS_LOST     = -1;  -- lost lot or expired
tracker.STATUS_ZONED    = -2;  -- lost because player zoned away

local source_labels = {
    [0] = 'Mob',
    [1] = 'Chest',
    [2] = 'Coffer',
    [3] = 'BCNM',
};

function tracker.get_source_label(source_type, bf_difficulty)
    if (source_type == 3 and bf_difficulty ~= nil and bf_difficulty > 0) then
        return 'HTBF';
    end
    return source_labels[source_type] or 'Mob';
end

-------------------------------------------------------------------------------
-- Vana'diel Weekday & Moon Phase Labels
-------------------------------------------------------------------------------
local weekday_labels = {
    [0] = 'Firesday',
    [1] = 'Earthsday',
    [2] = 'Watersday',
    [3] = 'Windsday',
    [4] = 'Iceday',
    [5] = 'Lightningday',
    [6] = 'Lightsday',
    [7] = 'Darksday',
};

-- Client moon phase: 0-11 (12 segments), each named phase spans 1-2 values
local moon_phase_labels = {
    [0]  = 'New Moon',
    [1]  = 'Waxing Crescent',
    [2]  = 'Waxing Crescent',
    [3]  = 'First Quarter',
    [4]  = 'Waxing Gibbous',
    [5]  = 'Waxing Gibbous',
    [6]  = 'Full Moon',
    [7]  = 'Waning Gibbous',
    [8]  = 'Waning Gibbous',
    [9]  = 'Last Quarter',
    [10] = 'Waning Crescent',
    [11] = 'Waning Crescent',
};

function tracker.get_weekday_label(weekday)
    return weekday_labels[tonumber(weekday)] or '?';
end

function tracker.get_moon_phase_label(phase)
    return moon_phase_labels[tonumber(phase)] or '?';
end

-------------------------------------------------------------------------------
-- Weather Labels (client memory values 0-19)
-------------------------------------------------------------------------------
local weather_labels = {
    [0]  = 'Clear',
    [1]  = 'Sunny',
    [2]  = 'Cloudy',
    [3]  = 'Fog',
    [4]  = 'Hot Spell',
    [5]  = 'Heat Wave',
    [6]  = 'Rain',
    [7]  = 'Squall',
    [8]  = 'Dust Storm',
    [9]  = 'Sand Storm',
    [10] = 'Wind',
    [11] = 'Gales',
    [12] = 'Snow',
    [13] = 'Blizzard',
    [14] = 'Thunder',
    [15] = 'Thunderstorm',
    [16] = 'Auroras',
    [17] = 'Stellar Glare',
    [18] = 'Gloom',
    [19] = 'Darkness',
};

function tracker.get_weather_label(id)
    local n = tonumber(id);
    if (n == nil or n < 0) then return '-'; end
    return weather_labels[n] or '?';
end

-------------------------------------------------------------------------------
-- HTBF Difficulty Labels (from 0x005C num[2])
-------------------------------------------------------------------------------
local difficulty_labels = {
    [1] = 'VD',
    [2] = 'D',
    [3] = 'N',
    [4] = 'E',
    [5] = 'VE',
};

local difficulty_full_labels = {
    [1] = 'Very Difficult',
    [2] = 'Difficult',
    [3] = 'Normal',
    [4] = 'Easy',
    [5] = 'Very Easy',
};

function tracker.get_difficulty_label(difficulty)
    return difficulty_labels[tonumber(difficulty)] or '';
end

function tracker.get_difficulty_full_label(difficulty)
    return difficulty_full_labels[tonumber(difficulty)] or '';
end

-------------------------------------------------------------------------------
-- Action Type Labels (cmd_no from 0x0028 action packet)
-------------------------------------------------------------------------------
local action_type_labels = {
    [1]  = 'Melee',
    [2]  = 'Ranged',
    [3]  = 'Weapon Skill',
    [4]  = 'Magic',
    [5]  = 'Item',
    [6]  = 'Job Ability',
    [7]  = 'Pet WS',
    [8]  = 'Pet JA',
    [9]  = 'Trust WS',
    [11] = 'Monster Skill',
    [12] = 'Mount',
};

function tracker.get_action_type_label(action_type)
    return action_type_labels[tonumber(action_type)] or '';
end

-------------------------------------------------------------------------------
-- Weather Memory Scan
-------------------------------------------------------------------------------

local function init_weather_pointer()
    if (tracker.weather_ptr ~= nil) then return; end

    local ok, result = pcall(function()
        -- Pattern: 66A1????????663D????72 — reads weather byte from a static pointer
        local addr = ashita.memory.find('FFXiMain.dll', 0, '66A1????????663D????72', 0, 0);
        if (addr == 0 or addr == nil) then return nil; end

        -- Read the absolute pointer at scan+0x02
        local ptr = ashita.memory.read_uint32(addr + 0x02);
        if (ptr == 0 or ptr == nil) then return nil; end

        return ptr;
    end);

    if (ok and result ~= nil) then
        tracker.weather_ptr = result;
    else
        tracker.weather_ptr = false;  -- failed, no retry
    end
end

local function read_weather()
    if (not tracker.weather_ptr or tracker.weather_ptr == false) then return -1; end

    local ok, val = pcall(ashita.memory.read_uint8, tracker.weather_ptr);
    if (not ok or val == nil) then return -1; end

    local w = tonumber(val);
    if (w == nil or w < 0 or w > 19) then return -1; end
    return w;
end

-------------------------------------------------------------------------------
-- Helper: Capture current Vana'diel time snapshot
-------------------------------------------------------------------------------
local function capture_vana_info()
    local ok, raw = pcall(vana_time.get_game_time_raw);
    if (not ok or raw == nil) then
        return { weekday = -1, hour = -1, moon_phase = -1, moon_percent = -1, weather = -1 };
    end

    -- FFI functions return cdata<uint32_t> — must convert to Lua numbers
    -- for SQLite bind_values() and Lua comparisons to work correctly.
    raw = tonumber(raw) or 0;
    if (raw == 0) then
        return { weekday = -1, hour = -1, moon_phase = -1, moon_percent = -1, weather = -1 };
    end

    local ok_wd, weekday = pcall(vana_time.get_game_weekday, raw);
    local ok_hr, hour    = pcall(vana_time.get_game_hours, raw);
    local ok_mp, phase   = pcall(vana_time.get_game_moon_phase, raw);
    local ok_pct, pct    = pcall(vana_time.get_game_moon_percent, raw);

    return {
        weekday      = ok_wd  and tonumber(weekday) or -1,
        hour         = ok_hr  and tonumber(hour)    or -1,
        moon_phase   = ok_mp  and tonumber(phase)   or -1,
        moon_percent = ok_pct and tonumber(pct)     or -1,
        weather      = read_weather(),
    };
end

-------------------------------------------------------------------------------
-- Battlefield Detection (BCNM name from chat, level cap from memory)
-------------------------------------------------------------------------------

function tracker.handle_battlefield_text(msg)
    if (msg == nil or msg == '') then return; end

    -- 1. BCNM/HTBF: "Entering the battlefield for X!"
    local bf_name = msg:match('Entering the battlefield for (.+)!');
    if (bf_name ~= nil) then
        -- Strip non-ASCII bytes (FFXI control bytes, Shift-JIS fragments, auto-translate markers)
        bf_name = bf_name:gsub('[^ -~]', '');
        bf_name = bf_name:trim();
        if (bf_name == '') then return; end

        local mem = AshitaCore:GetMemoryManager();
        if (mem == nil) then return; end

        local player = mem:GetPlayer();
        if (player == nil) then return; end

        tracker.battlefield.name = bf_name;
        tracker.battlefield.zone_id = tracker.current_zone_id;
        tracker.battlefield.active = true;
        tracker.battlefield.cap_check_pending = true;
        tracker.battlefield.level_cap = nil;
        tracker.battlefield.last_kill_id = nil;
        tracker.battlefield.gil_handled = false;
        tracker.battlefield.pending_gil = nil;

        if (db ~= nil) then
            db.record_battlefield_entry(bf_name, tracker.current_zone_id, tracker.current_zone_name, os.time());
        end

        -- Set content_info if not already set by 0x0075
        if (tracker.content_info == nil) then
            tracker.content_info = { type = 'BCNM' };
        end
        -- bf_name is stored on htbf_info, not content_info
        return;
    end

    -- 2. Level restriction: "<name>'s level is currently restricted to <N>."
    local cap = msg:match("level is currently restricted to (%d+)");
    if (cap ~= nil) then
        cap = tonumber(cap);
        if (cap ~= nil and cap > 0 and tracker.battlefield.active) then
            tracker.battlefield.level_cap = cap;
            tracker.battlefield.cap_check_pending = false;
            if (db ~= nil) then
                db.update_battlefield_level_cap(cap);
            end
        end
        return;
    end

    -- WIP: Ambuscade/Omen/Sortie chat detection disabled.
    -- "Entering..." messages not confirmed for these content types.
    -- Will be re-enabled when instance detection is tested.

    -- 3. Dynamis (original + Divergence):
    --    Original: "You will now be warped to Dynamis - Windurst."
    --    Divergence: "Entering Dynamis - Windurst [D]."
    --    Primary detection is zone-name based (check_zone / on_login),
    --    but entry text serves as a secondary signal.
    local dyna_name = msg:match('Entering (Dynamis %- .+)%.') or msg:match('warped to (Dynamis %- .+)%.');
    if (dyna_name ~= nil) then
        dyna_name = dyna_name:gsub('[^ -~]', ''):trim();
        if (tracker.content_info == nil) then
            tracker.content_info = { type = 'Dynamis' };
        end
        -- dyna_city is informational only (not consumed by UI)
        return;
    end
end

function tracker.check_battlefield_level_cap()
    if (not tracker.battlefield.cap_check_pending) then return; end

    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end

    local player = mem:GetPlayer();
    if (player == nil) then return; end

    -- GetMainJobLevel() returns the CAPPED level inside a battlefield.
    -- GetJobLevel(job_id) returns the REAL (uncapped) level from the job table.
    -- Compare both to reliably detect level caps regardless of timing.
    local main_job = player:GetMainJob();
    local current_level = player:GetMainJobLevel();
    local real_level = player:GetJobLevel(main_job);

    if (real_level > 0 and current_level > 0 and current_level < real_level) then
        tracker.battlefield.level_cap = current_level;
        if (db ~= nil) then
            db.update_battlefield_level_cap(current_level);
        end
        tracker.battlefield.cap_check_pending = false;
    elseif (current_level > 0 and real_level > 0) then
        -- Both levels loaded but no cap detected — uncapped BCNM (KSNM, etc.)
        tracker.battlefield.cap_check_pending = false;
    end
    -- If levels are 0, client data hasn't loaded yet — keep pending for next frame
end

function tracker.check_battlefield_reconnect()
    if (tracker.battlefield.active) then return; end  -- already connected

    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end

    local player = mem:GetPlayer();
    if (player == nil) then return; end

    -- Check for battlefield status effect (icon 254)
    local buffs = player:GetBuffs();
    if (buffs == nil) then return; end

    local in_bcnm = false;
    for i = 0, 31 do
        if (buffs[i] == 254) then
            in_bcnm = true;
            break;
        end
    end

    if (not in_bcnm) then return; end

    -- Recover session from DB
    if (db ~= nil and tracker.current_zone_id > 0) then
        local session = db.get_active_battlefield(tracker.current_zone_id);
        if (session ~= nil) then
            tracker.battlefield.name = session.battlefield_name;
            tracker.battlefield.zone_id = session.zone_id;
            tracker.battlefield.level_cap = session.level_cap;
            tracker.battlefield.active = true;
        end
    end
end

-------------------------------------------------------------------------------
-- Mob Name Resolution (from chat messages when entity is out of range)
-- Uses a FIFO queue with per-kill drop counts so we know how many "You find"
-- chat messages to expect before advancing to the next pending kill.
-------------------------------------------------------------------------------

local function set_pending_mob_resolve(mob_sid, kill_id)
    -- Don't add if this kill_id is already in the queue
    for _, entry in ipairs(tracker.pending_mob_resolves) do
        if (entry.kill_id == kill_id) then return; end
    end
    table.insert(tracker.pending_mob_resolves, {
        mob_sid       = mob_sid,
        kill_id       = kill_id,
        time          = os.clock(),
        expected_msgs = 0,   -- incremented per drop in handle_treasure_pool
        received_msgs = 0,   -- incremented per "You find" chat message
    });
end

-- Called from handle_treasure_pool when a drop is recorded for an Unknown mob
local function increment_pending_resolve(kill_id)
    for _, entry in ipairs(tracker.pending_mob_resolves) do
        if (entry.kill_id == kill_id) then
            entry.expected_msgs = entry.expected_msgs + 1;
            return;
        end
    end
end

function tracker.resolve_mob_name_from_chat(mob_name, is_defeat_msg)
    -- Expire stale entries: 10s for entries that received zero of their expected
    -- messages (likely missed), 30s for entries actively receiving messages.
    local now = os.clock();
    while (#tracker.pending_mob_resolves > 0) do
        local front = tracker.pending_mob_resolves[1];
        local timeout = (front.expected_msgs > 0 and front.received_msgs == 0) and 10 or 30;
        if (now - front.time > timeout) then
            table.remove(tracker.pending_mob_resolves, 1);
        else
            break;
        end
    end

    if (#tracker.pending_mob_resolves == 0) then return; end

    local entry = tracker.pending_mob_resolves[1];

    -- For "You find" messages, don't process until at least one drop has been recorded
    if (not is_defeat_msg and entry.expected_msgs == 0) then return; end

    -- If this is a defeat message for a different mob than the front entry is
    -- waiting on, and the front entry is stuck waiting for drop messages, skip
    -- past it to avoid head-of-line blocking in rapid kill scenarios.
    if (is_defeat_msg and entry.expected_msgs > 0 and entry.received_msgs == 0) then
        -- Check if any queued entry matches this defeat by mob_sid
        -- (defeat messages don't carry mob_sid directly, but if the front entry
        -- has been waiting without progress, it's likely stale — evict it)
        table.remove(tracker.pending_mob_resolves, 1);
        if (#tracker.pending_mob_resolves == 0) then return; end
        entry = tracker.pending_mob_resolves[1];
    end

    -- Resolve name on first chat message for this mob (defeat or loot)
    if (tracker.mob_names[entry.mob_sid] == nil or tracker.mob_names[entry.mob_sid] == 'Unknown') then
        tracker.mob_names[entry.mob_sid] = mob_name;
        if (db ~= nil) then
            db.update_kill_mob_name(entry.kill_id, mob_name);
        end
    end

    if (is_defeat_msg) then
        -- Empty kill (no drops): resolve name and remove from queue immediately.
        -- If drops are expected, keep entry for "You find" message counting.
        if (entry.expected_msgs == 0) then
            table.remove(tracker.pending_mob_resolves, 1);
        end
        return;
    end

    -- "You find" message: count and advance queue when all consumed
    entry.received_msgs = entry.received_msgs + 1;
    if (entry.received_msgs >= entry.expected_msgs) then
        table.remove(tracker.pending_mob_resolves, 1);
    end
end

-------------------------------------------------------------------------------
-- Chest Event Detection
-- Primary: Packet-based
--   0x002A (messageSpecial) — unlock + failures (zone-specific message IDs)
--   0x001E (Item Quantity)  — gil amount (diff from snapshot at unlock time)
-- Fallback: text_in for zones not in lookup table or missed packets
--
-- Why 0x001E and not 0x0053:
--   Field chests/coffers call addGil() + messageSpecial() (another 0x002A).
--   Only BCNM crates call messageSystem() (0x0053). But addGil() ALWAYS
--   sends 0x001E regardless, making it the universal detection path.
--
-- Packet 0x002A (GP_SERV_COMMAND_TALKNUMWORK / messageSpecial):
--   Offset 0x18: uint16 ActIndex — NPC target index (Treasure_Chest/Coffer)
--   Offset 0x1A: uint16 MesNum — zone-specific message ID
--   CHEST_UNLOCKED offsets: +0=unlock, +1=fail, +2=trap, +4=mimic, +6=illusion
--
-- Packet 0x001E (GP_SERV_COMMAND_ITEM_NUM / Item Quantity Update):
--   Offset 0x04: uint32 ItemNum  — new total quantity (gil amount)
--   Offset 0x08: uint8  Category — 0=inventory
--   Offset 0x09: uint8  ItemIndex — 0=gil slot
-------------------------------------------------------------------------------

local chest_result_labels = {
    [0] = 'Gil',
    [1] = 'Lockpick Failed',
    [2] = 'Trapped!',
    [3] = 'Mimic!',
    [4] = 'Illusion',
};

function tracker.get_chest_result_label(result)
    return chest_result_labels[tonumber(result)] or '?';
end

local container_labels = {
    [1] = 'Chest',
    [2] = 'Coffer',
};

function tracker.get_container_label(container_type)
    return container_labels[tonumber(container_type)] or 'Chest';
end

-- Zone container types — extracted from LSB treasure.lua keyTable.
-- 1=chest only, 2=coffer only, 3=both. Zones with both need entity detection.
local zone_container_types = {
    [9]   = 1, -- PsoXja
    [11]  = 1, -- Oldton_Movalpolos
    [12]  = 2, -- Newton_Movalpolos
    [28]  = 1, -- Sacrarium
    [130] = 2, -- RuAun_Gardens
    [141] = 1, -- Fort_Ghelsba
    [142] = 1, -- Yughott_Grotto
    [143] = 1, -- Palborough_Mines
    [145] = 1, -- Giddeus
    [147] = 3, -- Beadeaux (both)
    [149] = 1, -- Davoi
    [150] = 2, -- Monastic_Cavern
    [151] = 3, -- Castle_Oztroja (both)
    [153] = 2, -- The_Boyahda_Tree
    [157] = 1, -- Middle_Delkfutts_Tower
    [158] = 1, -- Upper_Delkfutts_Tower
    [159] = 2, -- Temple_of_Uggalepih
    [160] = 2, -- Den_of_Rancor
    [161] = 3, -- Castle_Zvahl_Baileys (both)
    [162] = 1, -- Castle_Zvahl_Keep
    [169] = 2, -- Toraimarai_Canal
    [174] = 2, -- Kuftal_Tunnel
    [176] = 3, -- Sea_Serpent_Grotto (both)
    [177] = 2, -- VeLugannon_Palace
    [190] = 1, -- King_Ranperres_Tomb
    [191] = 1, -- Dangruf_Wadi
    [192] = 1, -- Inner_Horutoto_Ruins
    [193] = 1, -- Ordelles_Caves
    [194] = 1, -- Outer_Horutoto_Ruins
    [195] = 3, -- The_Eldieme_Necropolis (both)
    [196] = 1, -- Gusgen_Mines
    [197] = 3, -- Crawlers_Nest (both)
    [198] = 1, -- Maze_of_Shakhrami
    [200] = 3, -- Garlaige_Citadel (both)
    [204] = 1, -- FeiYin
    [205] = 2, -- Ifrits_Cauldron
    [208] = 2, -- Quicksand_Caves
    [213] = 1, -- Labyrinth_of_Onzozo
};

-- Zone ID -> CHEST_UNLOCKED base message ID (extracted from LSB IDs.lua files)
-- 38 zones with treasure chest/coffer unlock messages
local chest_msg_ids = {
    [9]   = 7482, -- PsoXja
    [11]  = 7766, -- Oldton_Movalpolos
    [12]  = 7272, -- Newton_Movalpolos
    [28]  = 7369, -- Sacrarium
    [130] = 7362, -- RuAun_Gardens
    [141] = 7374, -- Fort_Ghelsba
    [142] = 7353, -- Yughott_Grotto
    [143] = 7429, -- Palborough_Mines
    [145] = 7424, -- Giddeus
    [147] = 7379, -- Beadeaux
    [149] = 7490, -- Davoi
    [150] = 7305, -- Monastic_Cavern
    [151] = 7443, -- Castle_Oztroja
    [153] = 7176, -- The_Boyahda_Tree
    [157] = 7339, -- Middle_Delkfutts_Tower
    [158] = 7370, -- Upper_Delkfutts_Tower
    [159] = 7335, -- Temple_of_Uggalepih
    [160] = 7363, -- Den_of_Rancor
    [161] = 7242, -- Castle_Zvahl_Baileys
    [162] = 7242, -- Castle_Zvahl_Keep
    [169] = 7381, -- Toraimarai_Canal
    [174] = 7335, -- Kuftal_Tunnel
    [176] = 7335, -- Sea_Serpent_Grotto
    [177] = 7235, -- VeLugannon_Palace
    [190] = 7298, -- King_Ranperres_Tomb
    [191] = 7453, -- Dangruf_Wadi
    [192] = 7357, -- Inner_Horutoto_Ruins
    [193] = 7411, -- Ordelles_Caves
    [194] = 7299, -- Outer_Horutoto_Ruins
    [195] = 7421, -- The_Eldieme_Necropolis
    [196] = 7393, -- Gusgen_Mines
    [197] = 7271, -- Crawlers_Nest
    [198] = 7374, -- Maze_of_Shakhrami
    [200] = 7345, -- Garlaige_Citadel
    [204] = 7378, -- FeiYin
    [205] = 7269, -- Ifrits_Cauldron
    [208] = 7335, -- Quicksand_Caves
    [213] = 7335, -- Labyrinth_of_Onzozo
};

-- CHEST_UNLOCKED offset -> chest result constant
local chest_offset_map = {
    [0] = -1,                                 -- unlock (sets pending, not a result)
    [1] = tracker.CHEST_RESULT_FAIL_PICK,     -- fails to open
    [2] = tracker.CHEST_RESULT_FAIL_TRAP,     -- trapped!
    [4] = tracker.CHEST_RESULT_FAIL_MIMIC,    -- mimic!
    [6] = tracker.CHEST_RESULT_FAIL_ILLUSION, -- illusion
};


-- Timestamp of last packet-handled chest event (prevents text_in duplicates)
tracker.chest_packet_handled_at = 0;

-- Detect container type using zone_container_types lookup from LSB treasure.lua.
-- 31 of 38 zones have only one type → instant answer, no entity scanning needed.
-- Only 7 zones with both types fall back to entity name from memory.
--
-- NOTE: The 0x002A packet's ActIndex at 0x18 is the PLAYER entity, NOT the
-- chest/coffer NPC. LSB calls player:messageSpecial(), so the packet sender
-- is the player. Do NOT use the packet target_index for entity name lookup.
local function detect_container_type(target_index)
    local zct = zone_container_types[tracker.current_zone_id];
    if (zct == nil) then return tracker.CONTAINER_CHEST; end  -- unknown zone
    if (zct == 1) then return tracker.CONTAINER_CHEST; end    -- chest-only zone
    if (zct == 2) then return tracker.CONTAINER_COFFER; end   -- coffer-only zone

    -- Zone has both (zct == 3): read entity name from memory
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return tracker.CONTAINER_CHEST; end
    local entity = mem:GetEntity();
    if (entity == nil) then return tracker.CONTAINER_CHEST; end

    -- 1) Check player's current target (most reliable if player still has chest targeted)
    local target = mem:GetTarget();
    if (target ~= nil) then
        local ptidx = target:GetTargetIndex(0);
        if (ptidx ~= nil and ptidx > 0) then
            local name = entity:GetName(ptidx);
            if (name ~= nil and #name > 0) then
                local lower = name:lower();
                if (lower:find('coffer')) then return tracker.CONTAINER_COFFER; end
                if (lower:find('chest')) then return tracker.CONTAINER_CHEST; end
            end
        end
    end

    -- 2) Scan nearby entities for chest/coffer names.
    --    Ignore render flags — the entity may have just despawned but its name
    --    buffer is still valid in the entity array. Only require a valid name
    --    and position within 20 yalms of the player.
    local px = entity:GetLocalPositionX(0);  -- east/west
    local py = entity:GetLocalPositionY(0);  -- north/south (Y = horizontal, Z = elevation)
    if (px ~= nil and (px ~= 0 or py ~= 0)) then
        local best_dist = 20.0;
        local best_ctype = nil;
        for i = 1, 2303 do
            local name = entity:GetName(i);
            if (name ~= nil and #name > 0) then
                local lower = name:lower();
                local ctype = nil;
                if (lower:find('treasure') and lower:find('coffer')) then
                    ctype = tracker.CONTAINER_COFFER;
                elseif (lower:find('treasure') and lower:find('chest')) then
                    ctype = tracker.CONTAINER_CHEST;
                end
                if (ctype ~= nil) then
                    local ex = entity:GetLocalPositionX(i);
                    local ey = entity:GetLocalPositionY(i);
                    if (ex ~= nil) then
                        local dx = ex - px;
                        local dy = ey - py;
                        local d = math.sqrt(dx * dx + dy * dy);
                        if (d < best_dist) then
                            best_dist = d;
                            best_ctype = ctype;
                        end
                    end
                end
            end
        end
        if (best_ctype ~= nil) then
            return best_ctype;
        end
    end

    return tracker.CONTAINER_CHEST;
end

-------------------------------------------------------------------------------
-- Packet handler: 0x002A (messageSpecial) — chest unlock and failures
-------------------------------------------------------------------------------
function tracker.handle_chest_message(data)
    if (db == nil) then return; end
    if (#data < 28) then return; end

    local base = chest_msg_ids[tracker.current_zone_id];
    if (base == nil) then return; end

    local mesnum = sunpack('H', data, 0x1A + 1);
    local offset = mesnum - base;

    if (offset < 0 or offset > 6) then return; end
    local result = chest_offset_map[offset];
    if (result == nil) then return; end  -- offsets 3, 5 are not tracked

    local tidx = sunpack('H', data, 0x18 + 1);
    local ctype = detect_container_type(tidx);

    -- Offset 0 = unlock: set pending state for 0x001E gil detection
    if (offset == 0) then
        -- Snapshot current gil so 0x001E handler can compute the chest gil amount
        local prev_gil = 0;
        local inv_mem = AshitaCore:GetMemoryManager();
        if (inv_mem ~= nil) then
            local inv = inv_mem:GetInventory();
            if (inv ~= nil) then
                local gil_item = inv:GetContainerItem(0, 0);
                if (gil_item ~= nil) then
                    prev_gil = gil_item.Count or 0;
                end
            end
        end

        tracker.chest_unlock_pending = {
            time           = os.clock(),
            container_type = ctype,
            zone_id        = tracker.current_zone_id,
            zone_name      = tracker.current_zone_name,
            prev_gil       = prev_gil,
        };

        return;
    end

    tracker.chest_packet_handled_at = os.clock();  -- dedup: block text_in for recorded events
    local vana_info = capture_vana_info();
    db.record_chest_event(
        tracker.current_zone_id, tracker.current_zone_name,
        ctype, result, 0, vana_info
    );
end

-------------------------------------------------------------------------------
-- Packet handler: 0x001E (Item Quantity Update) — primary chest gil detection
-- When the server calls addGil(), it sends 0x001E with Category=0 (inventory),
-- ItemIndex=0 (gil slot), and the new total quantity. If a chest unlock is
-- pending, the diff from the snapshot is the chest gil amount.
--
-- This is the correct detection path because:
--   Field chests/coffers use messageSpecial (0x002A) for the "Obtained X gil"
--   text, NOT messageSystem (0x0053). Only BCNM crates use 0x0053.
--   But addGil() always sends 0x001E regardless of script type.
--
-- Packet structure:
--   0x04: uint32 ItemNum  (new total quantity)
--   0x08: uint8  Category (0 = inventory)
--   0x09: uint8  ItemIndex (0 = gil slot)
-------------------------------------------------------------------------------
function tracker.handle_item_quantity_update(data)
    if (db == nil) then return; end
    if (#data < 10) then return; end

    local category   = sunpack('B', data, 0x08 + 1);
    local item_index = sunpack('B', data, 0x09 + 1);

    -- Only care about inventory (0) slot 0 (gil)
    if (category ~= 0 or item_index ~= 0) then return; end

    local new_qty = sunpack('I', data, 0x04 + 1);

    -- Always remember the last gil update (even without pending).
    -- Ashita's packet_in fires BEFORE the game processes the packet, so
    -- the inventory memory still has the OLD value at this point.
    -- This allows the text_in fallback to retroactively use the data
    -- when 0x002A didn't match the zone's chest_msg_ids.
    local snapshot_gil = 0;
    local inv_mem = AshitaCore:GetMemoryManager();
    if (inv_mem ~= nil) then
        local inv = inv_mem:GetInventory();
        if (inv ~= nil) then
            local gil_item = inv:GetContainerItem(0, 0);
            if (gil_item ~= nil) then
                snapshot_gil = gil_item.Count or 0;
            end
        end
    end
    tracker.last_gil_update = {
        prev_gil = snapshot_gil,
        new_qty  = new_qty or 0,
        time     = os.clock(),
    };

    -- If no chest unlock pending, check for BCNM gil.
    -- BCNM crates send items via 0x00D2 but gil via addGil() → 0x001E.
    -- There's no chest_unlock_pending because BCNMs don't use the field
    -- chest dialog system (0x002A). Record as a drop tied to the crate kill.
    -- Note: Mob gil is NOT handled here — it uses 0x0029 msg_id=565 instead
    -- (exact amount in the Data field, no diff calculation needed).
    if (tracker.chest_unlock_pending == nil) then
        if (tracker.battlefield.active and not tracker.battlefield.gil_handled) then
            local gil_amount = (new_qty or 0) - snapshot_gil;
            if (gil_amount > 0) then
                if (tracker.battlefield.last_kill_id ~= nil) then
                    -- Kill record exists: record immediately
                    db.record_drop(
                        tracker.battlefield.last_kill_id,
                        -1,       -- pool_slot: -1 = not a pool item
                        65535,    -- item_id: 0xFFFF = gil
                        'Gil',
                        gil_amount,
                        1         -- won: auto-obtained (no lot)
                    );
                    tracker.battlefield.gil_handled = true;
                    tracker.battlefield.last_kill_id = nil;  -- consume: one gil per crate
                else
                    -- No kill record yet (0x00D2 hasn't fired): buffer for later
                    tracker.battlefield.pending_gil = gil_amount;
                end
                tracker.last_gil_update = nil;
            end
        end
        return;
    end

    local prev_gil = tracker.chest_unlock_pending.prev_gil or 0;
    local gil_amount = (new_qty or 0) - prev_gil;

    if (gil_amount <= 0) then
        return;
    end

    local elapsed = os.clock() - tracker.chest_unlock_pending.time;
    if (elapsed > 5.0) then
        tracker.chest_unlock_pending = nil;
        return;
    end

    db.record_chest_event(
        tracker.chest_unlock_pending.zone_id,
        tracker.chest_unlock_pending.zone_name,
        tracker.chest_unlock_pending.container_type,
        tracker.CHEST_RESULT_GIL,
        gil_amount,
        capture_vana_info()
    );
    tracker.chest_unlock_pending = nil;
    tracker.chest_packet_handled_at = os.clock();
    tracker.last_gil_update = nil;  -- consumed: prevent text_in retroactive duplicate
end

-------------------------------------------------------------------------------
-- Packet handler: 0x0053 (systemMessage) — secondary chest gil detection
-- When npcUtil.giveCurrency() is called with useTreasurePoolMsg=true,
-- the server sends messageSystem(OBTAINS_GIL, amount) → 0x0053.
-- This is a secondary path: 0x001E is preferred because it's universal,
-- but 0x0053 provides a direct amount (no diff calculation needed).
--
-- Packet structure:
--   0x04: uint32 para   (amount for OBTAINS_GIL)
--   0x08: uint32 para2  (unused, 0)
--   0x0C: uint16 Number (MsgStd message ID; 19 = OBTAINS_GIL)
--
-- Same race condition as 0x001E: arrives before text_in. So we also
-- store it for retroactive use by the text_in fallback.
-------------------------------------------------------------------------------
local MSGSTD_OBTAINS_GIL = 19;

function tracker.handle_system_message(data)
    if (db == nil) then return; end
    if (#data < 14) then return; end  -- need at least through offset 0x0C+2

    local msg_id = sunpack('H', data, 0x0C + 1);
    if (msg_id ~= MSGSTD_OBTAINS_GIL) then return; end

    local amount = sunpack('I', data, 0x04 + 1);
    if (amount == nil or amount <= 0) then return; end

    -- Remember for retroactive use (same as last_gil_update but from 0x0053)
    if (tracker.last_gil_update == nil) then
        tracker.last_gil_update = {
            prev_gil = 0,
            new_qty  = amount,
            time     = os.clock(),
            from_0x0053 = true,  -- flag: amount is direct, not a diff
        };
    end

    -- BCNM gil: 0x0053 provides direct amount, no diff needed.
    if (tracker.chest_unlock_pending == nil) then
        if (tracker.battlefield.active and not tracker.battlefield.gil_handled) then
            if (tracker.battlefield.last_kill_id ~= nil) then
                db.record_drop(
                    tracker.battlefield.last_kill_id,
                    -1,       -- pool_slot: -1 = not a pool item
                    65535,    -- item_id: 0xFFFF = gil
                    'Gil',
                    amount,
                    1         -- won: auto-obtained (no lot)
                );
                tracker.battlefield.gil_handled = true;
                tracker.battlefield.last_kill_id = nil;
                tracker.last_gil_update = nil;
            else
                -- No kill record yet: buffer for later
                tracker.battlefield.pending_gil = amount;
                tracker.last_gil_update = nil;
            end
        end
        return;
    end

    -- Already handled by 0x001E?
    if (tracker.chest_packet_handled_at > 0 and
        (os.clock() - tracker.chest_packet_handled_at) < 1.0) then
        return;
    end

    local elapsed = os.clock() - tracker.chest_unlock_pending.time;
    if (elapsed > 5.0) then
        tracker.chest_unlock_pending = nil;
        return;
    end

    db.record_chest_event(
        tracker.chest_unlock_pending.zone_id,
        tracker.chest_unlock_pending.zone_name,
        tracker.chest_unlock_pending.container_type,
        tracker.CHEST_RESULT_GIL,
        amount,
        capture_vana_info()
    );
    tracker.chest_unlock_pending = nil;
    tracker.chest_packet_handled_at = os.clock();
    tracker.last_gil_update = nil;  -- consumed: prevent text_in retroactive duplicate
end

-------------------------------------------------------------------------------
-- Text_in: chest failure detection + unlock fallback + gil text fallback
-- Failures (lockpick, trap, mimic, illusion) are text-only events with no
-- reliable packet equivalent (zone-specific dialog IDs). text_in is the
-- correct detection method for these.
-- Unlock detection is a fallback for 0x002A — if 0x002A already set pending,
-- this is a no-op. Gil detection uses 3 layers:
--   1. 0x001E (primary, diff-based)
--   2. 0x0053 (secondary, direct amount)
--   3. text "Obtained X,XXX gil" (fallback, pattern match)
-- Plus retroactive 0x001E: if 0x001E arrived before text_in set pending,
-- the remembered data is used immediately on unlock text detection.
-------------------------------------------------------------------------------
function tracker.handle_chest_text(text)
    if (text == nil or text == '') then return; end
    if (db == nil) then return; end

    -- Strip non-ASCII before matching
    local clean = text:gsub('[^\x20-\x7E]', '');

    -- Dedup: skip failures if 0x002A already recorded one recently
    local dedup_active = (os.clock() - tracker.chest_packet_handled_at) < 1.0;

    -- Detect container type using zone lookup (same as packet handler).
    -- FFXI always says "chest" in failure messages even for coffers, so text is unreliable.
    local function detect_container()
        return detect_container_type(0);
    end

    -- Failure patterns (immediate recording, dedup-gated)
    if (not dedup_active) then
        if (clean:find('fails to open the')) then
            local ctype = detect_container();
            db.record_chest_event(
                tracker.current_zone_id, tracker.current_zone_name,
                ctype, tracker.CHEST_RESULT_FAIL_PICK, 0, capture_vana_info()
            );
            return;
        end

        if (clean:find('was trapped')) then
            local ctype = detect_container();
            db.record_chest_event(
                tracker.current_zone_id, tracker.current_zone_name,
                ctype, tracker.CHEST_RESULT_FAIL_TRAP, 0, capture_vana_info()
            );
            return;
        end

        if (clean:find('was a mimic')) then
            local ctype = detect_container();
            db.record_chest_event(
                tracker.current_zone_id, tracker.current_zone_name,
                ctype, tracker.CHEST_RESULT_FAIL_MIMIC, 0, capture_vana_info()
            );
            return;
        end

        if (clean:find('was but an illusion')) then
            local ctype = detect_container();
            db.record_chest_event(
                tracker.current_zone_id, tracker.current_zone_name,
                ctype, tracker.CHEST_RESULT_FAIL_ILLUSION, 0, capture_vana_info()
            );
            return;
        end
    end

    -- Unlock fallback: if 0x002A didn't fire, detect unlock from text.
    -- After setting pending, immediately check if 0x001E already arrived
    -- (race condition: 0x001E fires before text_in when zone not in lookup).
    if (tracker.chest_unlock_pending == nil) then
        local unlock_match = clean:match('[Yy]ou unlock the (%a+)');
        if (unlock_match ~= nil) then
            -- FFXI says "You unlock the chest" for BOTH chests and coffers,
            -- so we CANNOT rely on the text word. Use entity detection instead.
            local ctype = detect_container_type(0);

            -- Check if 0x001E or 0x0053 already arrived (retroactive detection).
            -- This handles the race where 0x002A didn't set pending because
            -- the zone isn't in chest_msg_ids, so packets were processed before
            -- text_in could set pending.
            if (tracker.last_gil_update ~= nil) then
                local age = os.clock() - tracker.last_gil_update.time;
                local amount;
                if (tracker.last_gil_update.from_0x0053) then
                    amount = tracker.last_gil_update.new_qty;  -- 0x0053: direct amount
                else
                    amount = tracker.last_gil_update.new_qty - tracker.last_gil_update.prev_gil;  -- 0x001E: diff
                end
                if (age < 3.0 and amount > 0) then
                    db.record_chest_event(
                        tracker.current_zone_id, tracker.current_zone_name,
                        ctype, tracker.CHEST_RESULT_GIL, amount, capture_vana_info()
                    );
                    tracker.last_gil_update = nil;
                    tracker.chest_packet_handled_at = os.clock();
                    return;
                end
            end

            -- No recent 0x001E: set pending for future 0x001E or text fallback.
            local prev_gil = 0;
            local inv_mem = AshitaCore:GetMemoryManager();
            if (inv_mem ~= nil) then
                local inv = inv_mem:GetInventory();
                if (inv ~= nil) then
                    local gil_item = inv:GetContainerItem(0, 0);
                    if (gil_item ~= nil) then
                        prev_gil = gil_item.Count or 0;
                    end
                end
            end
            tracker.chest_unlock_pending = {
                time           = os.clock(),
                container_type = ctype,
                zone_id        = tracker.current_zone_id,
                zone_name      = tracker.current_zone_name,
                prev_gil       = prev_gil,
            };
            return;
        end
    end

    -- Gil text fallback: "Obtained X,XXX gil" while pending is active.
    -- This catches chest gil when 0x001E somehow fails or arrives with wrong data.
    -- Only fires if pending is set (from either 0x002A or the unlock text above).
    if (tracker.chest_unlock_pending ~= nil) then
        local gil_text = clean:match('[Oo]btained (%d[%d,]*) gil');
        if (gil_text ~= nil) then
            local amount = tonumber((gil_text:gsub(',', ''))) or 0;
            if (amount > 0) then
                db.record_chest_event(
                    tracker.chest_unlock_pending.zone_id,
                    tracker.chest_unlock_pending.zone_name,
                    tracker.chest_unlock_pending.container_type,
                    tracker.CHEST_RESULT_GIL,
                    amount,
                    capture_vana_info()
                );
                tracker.chest_unlock_pending = nil;
                tracker.chest_packet_handled_at = os.clock();
                return;
            end
        end
    end

    -- BCNM gil text fallback: "Obtained X,XXX gil" during active battlefield.
    -- Same multi-layer approach as chest/coffer: packets (0x001E/0x0053) are
    -- primary, text match is the reliable fallback.
    if (tracker.battlefield.active and not tracker.battlefield.gil_handled) then
        local gil_text = clean:match('[Oo]btains? (%d[%d,]*) gil');
        if (gil_text ~= nil) then
            local amount = tonumber((gil_text:gsub(',', ''))) or 0;
            if (amount > 0) then
                -- Find or create kill record for the BCNM crate
                local kill_id = tracker.battlefield.last_kill_id;
                if (kill_id == nil) then
                    -- Gil-only crate (no 0x00D2 items), create kill record
                    local vana_info = capture_vana_info();
                    kill_id = db.record_kill(
                        'Armoury Crate', 0,
                        tracker.current_zone_id, tracker.current_zone_name,
                        0, tracker.SOURCE_BCNM,
                        vana_info,
                        { battlefield = tracker.battlefield.name,
                          level_cap = tracker.battlefield.level_cap }
                    );
                end
                if (kill_id ~= nil) then
                    db.record_drop(kill_id, -1, 65535, 'Gil', amount, 1);
                    tracker.battlefield.gil_handled = true;
                    tracker.battlefield.last_kill_id = nil;
                    tracker.battlefield.pending_gil = nil;  -- consumed by text fallback
                end
            end
        end
    end
end

function tracker.check_chest_timeout()
    -- Expire stale last_gil_update (prevents false positives from NPC sales/trades)
    if (tracker.last_gil_update ~= nil and
        (os.clock() - tracker.last_gil_update.time) > 5.0) then
        tracker.last_gil_update = nil;
    end
    if (tracker.chest_unlock_pending == nil) then return; end
    if (os.clock() - tracker.chest_unlock_pending.time > 5.0) then
        tracker.chest_unlock_pending = nil;
    end
end

-------------------------------------------------------------------------------
-- Stale Resolve Cleanup (proactive, called from d3d_present)
-------------------------------------------------------------------------------

function tracker.cleanup_stale_resolves()
    if (#tracker.pending_mob_resolves == 0) then return; end
    local now = os.clock();
    while (#tracker.pending_mob_resolves > 0 and now - tracker.pending_mob_resolves[1].time > 30) do
        table.remove(tracker.pending_mob_resolves, 1);
    end
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function tracker.init(db_ref, config_path)
    db = db_ref;
    base_path = config_path;
end

-------------------------------------------------------------------------------
-- DAT-Based Entity Name Lookup
-- Loads mob/NPC names from FFXI DAT files for the current zone. This provides
-- name resolution even when entities are too far for client memory reads.
-- DAT format: 32-byte entries — name (28 bytes, null-padded) + id (uint32).
-- Target index = lower 12 bits of id. Pattern from filterscan addon.
-------------------------------------------------------------------------------

local function load_zone_dat(zone_id)
    tracker.dat_names = {};

    local file_path = nil;
    local dat_file = nil;  -- upvalue for cleanup after pcall

    local ok, err = pcall(function()
        local file = dats.get_zone_npclist(zone_id, 0);
        if (file == nil or #file == 0) then
            return;
        end
        file_path = file;

        dat_file = io.open(file, 'rb');
        if (dat_file == nil) then
            return;
        end

        local size = dat_file:seek('end');
        dat_file:seek('set', 0);

        if (size == 0 or (size % 0x20) ~= 0) then
            return;
        end

        for _ = 0, (size / 0x20) - 1 do
            local data = dat_file:read(0x20);
            if (data == nil) then break; end
            local name, id = struct.unpack('c28I', data);
            local tidx = bit.band(id, 0x0FFF);
            name = name:match('^[^\0]+') or '';
            if (#name > 0) then
                tracker.dat_names[tidx] = name;
            end
        end
    end);

    -- Always close file handle, even if pcall caught an error (e.g. struct.unpack threw)
    if (dat_file ~= nil) then
        dat_file:close();
    end
end

-------------------------------------------------------------------------------
-- Voidwatch Helpers (must be defined before check_zone which calls finalize)
-------------------------------------------------------------------------------

-- Check if the player currently has the Voidwatcher buff (ID 475).
-- Active during a VW cycle — wears off after Pyxis interaction completes.
local function has_voidwatcher_buff()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return false; end
    local player = mem:GetPlayer();
    if (player == nil) then return false; end
    local buffs = player:GetBuffs();
    if (buffs == nil) then return false; end
    for i = 0, 31 do
        if (buffs[i] == 475) then return true; end
    end
    return false;
end

-- Finalize VW Pyxis interaction. Marks remaining offered items with the
-- given won value: -1 = relinquished (default), 1 = obtained (Obtain All).
local function finalize_vw_interaction(won_value)
    local vw = tracker.voidwatch;
    if (not vw.items_captured or vw.kill_id == nil) then return; end
    if (db == nil) then return; end

    won_value = won_value or -1;

    for slot, _item_id in pairs(vw.offered) do
        db.update_drop_won(vw.kill_id, slot, won_value, 0);
    end

    vw.items_captured = false;
    vw.kill_id = nil;
    vw.offered = {};
end

-- Redundant VW finalization: if the Voidwatcher buff wears off while items
-- are still pending, finalize. Catches edge cases where 0x05B was missed
-- (addon reload mid-event, packet issues). Called from d3d_present.
function tracker.check_voidwatch_buff()
    if (not tracker.voidwatch.items_captured) then return; end
    if (tracker.voidwatch.kill_id == nil) then return; end
    if (not has_voidwatcher_buff()) then
        finalize_vw_interaction();
    end
end

-------------------------------------------------------------------------------
-- Zone Change Detection
-------------------------------------------------------------------------------

function tracker.check_zone()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end

    local party = mem:GetParty();
    if (party == nil) then return; end

    local zone_id = party:GetMemberZone(0);
    if (zone_id == tracker.current_zone_id) then return; end

    -- Initial zone detection (0 → actual) is NOT a real zone change — it's
    -- the addon discovering which zone we're already in. Don't mark pool
    -- items as Zoned or clear tracking data (scan_pool may have reconnected them).
    local is_real_zone_change = (tracker.current_zone_id ~= 0);

    if (is_real_zone_change) then
        -- Zone changed: mark any pending pool items as Zoned (server won't send
        -- 0x00D3 when the pool is destroyed by zoning)
        if (db ~= nil and db.conn ~= nil) then
            for slot, entry in pairs(tracker.active_pool) do
                if (entry.kill_id ~= nil) then
                    db.update_drop_won(entry.kill_id, slot, tracker.STATUS_ZONED, 0);
                end
            end
        end

        if (tracker.battlefield.active) then
            if (db ~= nil) then
                db.end_battlefield_session(os.time());
            end
            tracker.battlefield.active = false;
            tracker.battlefield.name = nil;
            tracker.battlefield.level_cap = nil;
            tracker.battlefield.cap_check_pending = false;
            tracker.battlefield.last_kill_id = nil;
            tracker.battlefield.gil_handled = false;
            tracker.battlefield.pending_gil = nil;
        end

        tracker.th_levels = {};
        tracker.th_actions = {};
        tracker.active_pool = {};
        tracker.mob_kills = {};
        tracker.mob_kill_times = {};
        tracker.mob_names = {};
        tracker.pet_to_master = {};
        tracker.pending_mob_resolves = {};
        tracker.drop_sequence = {};
        tracker.distant_kill_credits = 0;
        tracker.chest_unlock_pending = nil;
        tracker.chest_packet_handled_at = 0;
        tracker.last_gil_update = nil;
        tracker.mob_gil_queue = {};
        tracker.htbf_info = nil;
        tracker.last_interact = nil;
        finalize_vw_interaction();
        tracker.voidwatch.pyxis_active = false;
        tracker.voidwatch.last_vw_kill = nil;
        tracker.content_info = nil;
    end

    tracker.current_zone_id = zone_id;

    -- Load DAT entity names for the new zone (any zone change, including
    -- initial 0 → actual on addon reload)
    if (zone_id > 0) then
        load_zone_dat(zone_id);
    end

    local res = AshitaCore:GetResourceManager();
    if (res ~= nil and zone_id > 0) then
        tracker.current_zone_name = res:GetString('zones.names', zone_id) or '';
    else
        tracker.current_zone_name = '';
    end

    -- Dynamis detection: zone name starts with "Dynamis" for all 14 zones
    -- (original: 39-42, 134-135, 185-188; Divergence: 294-297).
    -- This covers both variants without needing 0x0075 (which original Dynamis
    -- never sends) or zone ID tables.
    if (tracker.content_info == nil and tracker.current_zone_name:match('^Dynamis')) then
        tracker.content_info = { type = 'Dynamis' };
    end
end

-------------------------------------------------------------------------------
-- Helper: Get entity name by target index
-------------------------------------------------------------------------------

local function get_entity_name(target_index)
    -- Primary: read from client entity memory (entity in range)
    local mem = AshitaCore:GetMemoryManager();
    if (mem ~= nil) then
        local entity = mem:GetEntity();
        if (entity ~= nil) then
            local name = entity:GetName(target_index);
            if (name ~= nil and name ~= '') then
                return name;
            end
        end
    end

    -- Fallback: DAT file lookup (works at any distance)
    local dat_name = tracker.dat_names[target_index];
    if (dat_name ~= nil) then
        return dat_name;
    end

    return 'Unknown';
end

-------------------------------------------------------------------------------
-- Helper: Read treasure pool item from client memory
-------------------------------------------------------------------------------

local function get_pool_item_info(slot)
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return nil; end

    local inv = mem:GetInventory();
    if (inv == nil) then return nil; end

    local pool_item = inv:GetTreasurePoolItem(slot);
    if (pool_item == nil or pool_item.ItemId == 0) then return nil; end

    -- Resolve item name from resource manager
    local item_name = 'Unknown';
    local res = AshitaCore:GetResourceManager();
    if (res ~= nil) then
        local item = res:GetItemById(pool_item.ItemId);
        if (item ~= nil and item.Name ~= nil) then
            item_name = item.Name[1] or 'Unknown';
        end
    end

    return {
        item_id             = pool_item.ItemId,
        item_name           = item_name,
        count               = pool_item.Count or 1,
        lot                 = pool_item.Lot or 0,
        winning_lot         = pool_item.WinningLot or 0,
        winning_entity_sid  = pool_item.WinningEntityServerId or 0,
        winning_entity_name = pool_item.WinningEntityName or '',
    };
end

-------------------------------------------------------------------------------
-- Helper: Classify container source type from entity name
-------------------------------------------------------------------------------

local function classify_container_by_name(entity_name)
    if (entity_name == nil) then return tracker.SOURCE_CHEST; end

    local lower = entity_name:lower();
    if (lower:find('armoury crate') or lower:find('sturdy pyxis')) then
        return tracker.SOURCE_BCNM;
    elseif (lower:find('coffer')) then
        return tracker.SOURCE_COFFER;
    else
        return tracker.SOURCE_CHEST;
    end
end

local function classify_source(entity_name, target_index)
    -- Primary: use SpawnFlags from entity memory if available
    if (target_index ~= nil and target_index > 0) then
        local ok, flags = pcall(function()
            local mem = AshitaCore:GetMemoryManager();
            if (mem == nil) then return nil; end
            local entity = mem:GetEntity();
            if (entity == nil) then return nil; end
            return entity:GetSpawnFlags(target_index);
        end);

        if (ok and flags ~= nil and flags > 0) then
            -- 0x0010 = Monster (NPC type 2)
            if (bit.band(flags, 0x0010) ~= 0) then
                return tracker.SOURCE_MOB;
            end
            -- 0x0020 = Object (chests, coffers, crates)
            if (bit.band(flags, 0x0020) ~= 0) then
                return classify_container_by_name(entity_name);
            end
        end
    end

    if (entity_name == nil) then return tracker.SOURCE_MOB; end
    return classify_container_by_name(entity_name);
end

-------------------------------------------------------------------------------
-- Helper: Check if an entity is a pet of another mob
-- Scans nearby Monster entities to see if any claim this target_index as pet.
-- Returns owner's target_index, or nil if not a pet.
-------------------------------------------------------------------------------

local function find_pet_owner(target_index)
    if (target_index == nil or target_index <= 0) then return nil; end

    local ok, result = pcall(function()
        local mem = AshitaCore:GetMemoryManager();
        if (mem == nil) then return nil; end
        local entity = mem:GetEntity();
        if (entity == nil) then return nil; end

        for i = 0, 2303 do
            if (i ~= target_index) then
                local flags = entity:GetSpawnFlags(i);
                if (flags ~= nil and bit.band(flags, 0x0010) ~= 0) then
                    local pet_tidx = entity:GetPetTargetIndex(i);
                    if (pet_tidx == target_index) then
                        return i;
                    end
                end
            end
        end
        return nil;
    end);

    if (ok) then return result; end
    return nil;
end

-------------------------------------------------------------------------------
-- Character Detection (deferred DB init)
-------------------------------------------------------------------------------

function tracker.check_character()
    if (tracker.char_name ~= nil) then return; end
    if (base_path == nil) then return; end

    local player = GetPlayerEntity();
    if (player == nil) then return; end

    local name = player.Name;
    if (name == nil or name == '' or name == 'N/A') then return; end

    local server_id = player.ServerId;
    if (server_id == nil or server_id == 0) then return; end

    -- Wait until actually in a zone (not character select screen).
    -- GetPlayerEntity() returns valid data at character select, but
    -- zone_id will be 0 until the player is in-game.
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return; end
    local party = mem:GetParty();
    if (party == nil) then return; end
    local zone_id = party:GetMemberZone(0);
    if (zone_id == nil or zone_id == 0) then return; end

    tracker.char_name = name;
    tracker.char_folder = name .. '_' .. tostring(server_id);

    -- Set zone_id early so check_battlefield_reconnect() can query DB by zone.
    -- check_zone() runs later in d3d_present and will see the same value (no-op),
    -- so we also load DATs and resolve zone name here (check_zone would skip them).
    tracker.current_zone_id = zone_id;
    local res = AshitaCore:GetResourceManager();
    if (res ~= nil) then
        local zone_str = res:GetString('zones.names', zone_id);
        if (zone_str ~= nil) then
            tracker.current_zone_name = zone_str;
        end
    end
    if (zone_id > 0) then
        load_zone_dat(zone_id);
    end

    db.init(base_path, tracker.char_folder);

    tracker.scan_pool();
    init_weather_pointer();
    tracker.check_battlefield_reconnect();

    -- Fallback: if 0x0075 hasn't fired yet but we're in a known zone,
    -- set content_info so kills aren't unclassified on addon reload.
    -- WIP: Instance zone detection (Ambuscade/Omen/Sortie) disabled until tested.
    if (tracker.content_info == nil and tracker.current_zone_id > 0) then
        if (tracker.current_zone_name:match('^Dynamis')) then
            tracker.content_info = { type = 'Dynamis' };
        end
    end
end

-------------------------------------------------------------------------------
-- Pool Scan: Recover pool items from client memory (addon reload / late join)
-- Creates active_pool stubs so 0x00D3 lot results can be tracked. DB records
-- are deferred to handle_lot_result's late-join logic to avoid duplicates.
-------------------------------------------------------------------------------

function tracker.scan_pool()
    if (db == nil or db.conn == nil) then return; end

    -- Flush any uncommitted transaction before scanning — ensures all records
    -- from a previous addon session are visible to find_pending_drop().
    -- Without this, a quick reload during batch writes can lose data.
    db.flush_pending();

    -- Guard: only scan if treasure pool is loaded in client memory
    local pool_ok, pool_status = pcall(function()
        local mem = AshitaCore:GetMemoryManager();
        if (mem == nil) then return nil; end
        local inv = mem:GetInventory();
        if (inv == nil) then return nil; end
        return inv:GetTreasurePoolStatus();
    end);
    if (pool_ok and pool_status ~= nil and pool_status ~= 1) then
        tracker.pool_scan_retries = tracker.pool_scan_retries + 1;
        if (tracker.pool_scan_retries <= 10) then
            tracker.pool_scan_pending = true;
        else
            tracker.pool_scan_pending = false;
        end
        return;
    end
    tracker.pool_scan_pending = false;
    tracker.pool_scan_retries = 0;

    local scanned = 0;
    local reconnected = 0;
    for slot = 0, 9 do
        if (tracker.active_pool[slot] == nil) then
            local info = get_pool_item_info(slot);
            if (info ~= nil) then
                -- Try to reconnect with existing DB record (addon reload)
                local pending = db.find_pending_drop(slot, info.item_id);
                if (pending ~= nil) then
                    tracker.active_pool[slot] = {
                        kill_id       = pending.kill_id,
                        item_id       = info.item_id,
                        item_name     = info.item_name,
                        item_count    = info.count,
                        mob_sid       = 0,
                        drop_id       = pending.drop_id,
                        player_lot    = info.lot,
                        player_action = (info.lot > 0) and 1 or 0,
                        highest_lot   = info.winning_lot,
                        late_join     = false,
                    };
                    reconnected = reconnected + 1;
                else
                    tracker.active_pool[slot] = {
                        kill_id       = nil,
                        item_id       = info.item_id,
                        item_name     = info.item_name,
                        item_count    = info.count,
                        mob_sid       = 0,
                        drop_id       = nil,
                        player_lot    = info.lot,
                        player_action = (info.lot > 0) and 1 or 0,
                        highest_lot   = info.winning_lot,
                        late_join     = true,
                        source_type   = tracker.SOURCE_MOB,  -- best guess; entity unavailable at scan time
                    };
                end
                scanned = scanned + 1;
            end
        end
    end

end

-------------------------------------------------------------------------------
-- Packet: 0x0029 - Battle Message (kill detection)
-- Message 6 = "X defeats Y" — records the kill BEFORE drops arrive.
-- This ensures mobs that drop nothing are still counted for drop rates.
-------------------------------------------------------------------------------

function tracker.handle_defeat(data)
    if (db == nil) then return; end
    if (#data < 26) then return; end

    local killer_id    = sunpack('I', data, 0x04 + 1);  -- caster/killer server ID
    local mob_sid      = sunpack('I', data, 0x08 + 1);  -- target server ID
    local killer_tidx  = sunpack('H', data, 0x14 + 1);  -- caster target index (ActIndexCas)
    local mob_tidx     = sunpack('H', data, 0x16 + 1);  -- target index
    local message_id   = sunpack('H', data, 0x18 + 1);  -- message ID

    -- msg_id=37: "too far from battle to gain experience" — distant party kill.
    -- Can't identify which mob was killed, but counting these lets us adjust
    -- drop rate statistics. Uses credit system to avoid double-counting kills
    -- already tracked via 0x00D2 treasure pool packets.
    if (message_id == 37) then
        if (tracker.distant_kill_credits > 0) then
            tracker.distant_kill_credits = tracker.distant_kill_credits - 1;
        else
            if (db ~= nil and tracker.current_zone_id > 0) then
                db.record_missed_kill(tracker.current_zone_id, tracker.current_zone_name);
            end
        end
        return;
    end

    -- msg_id=565: "<target> obtains <X> gil." — sent by DistributeGil (mob kills)
    -- AND by FoV/GoV regime rewards.  Both use the same message ID on 0x0029.
    -- The Data field (offset 0x0C) contains the exact gil amount.
    --
    -- Disambiguation: mob DistributeGil runs synchronously during the mob's death
    -- processing, so mob gil 565 always arrives BEFORE any FoV/GoV 565.  We match
    -- against the mob_gil_queue (FIFO) populated by msg_id=6 defeats.  If the queue
    -- is empty, this is FoV/GoV or another source — safely ignored.
    if (message_id == 565) then
            local now = os.clock();
        while (#tracker.mob_gil_queue > 0 and (now - tracker.mob_gil_queue[1].time) > 5.0) do
            table.remove(tracker.mob_gil_queue, 1);
        end

        if (#tracker.mob_gil_queue > 0) then
            local entry = table.remove(tracker.mob_gil_queue, 1);  -- pop oldest (FIFO)
            local gil_amount = sunpack('I', data, 0x0C + 1);       -- Data field = exact amount
            if (gil_amount ~= nil and gil_amount > 0) then
                db.record_drop(
                    entry.kill_id,
                    -1,       -- pool_slot: -1 = not a pool item
                    65535,    -- item_id: 0xFFFF = gil
                    'Gil',
                    gil_amount,
                    1         -- won: auto-obtained (no lot)
                );
            end
        end
        return;
    end

    if (message_id ~= 6) then return; end

    -- Server ID reuse: FFXI recycles mob server IDs from a fixed pool per zone.
    -- When a mob respawns and gets the same ID as a previously killed mob, clear
    -- stale state so the new kill is recorded correctly.
    --
    -- Race guard: In AoE/rapid kill scenarios, 0x00D2 (drop) can arrive before
    -- 0x0029 (defeat) for the same mob. The 0x00D2 fallback path creates a kill
    -- record and sets mob_kills[sid]. If we blindly clear it here, we'd create a
    -- duplicate kill. Check the timestamp: if the existing entry is recent (< 5s),
    -- it's from the same kill cycle — reuse it instead of creating a duplicate.
    if (tracker.mob_kills[mob_sid] ~= nil) then
        local kill_time = tracker.mob_kill_times[mob_sid] or 0;
        if ((os.clock() - kill_time) < 5.0) then
            -- Recent kill: 0x00D2 fallback already created this kill record.
            -- Don't duplicate. Patch the record with defeat metadata (clears
            -- is_distant flag, adds killer/TH info the fallback path lacked).
            local existing_kill = tracker.mob_kills[mob_sid];
            if (existing_kill ~= nil) then
                local th_level = tracker.th_levels[mob_sid] or 0;
                local th_action = tracker.th_actions[mob_sid];
                local killer_name = '';
                if (killer_tidx > 0) then
                    local kn = get_entity_name(killer_tidx);
                    if (kn ~= 'Unknown') then killer_name = kn; end
                end
                db.patch_kill_on_defeat(
                    existing_kill, killer_id, killer_name,
                    th_level,
                    th_action and th_action.cmd_no or 0,
                    th_action and th_action.cmd_arg or 0
                );
                tracker.mob_gil_queue[#tracker.mob_gil_queue + 1] = {
                    kill_id  = existing_kill,
                    time     = os.clock(),
                    mob_name = tracker.mob_names[mob_sid] or get_entity_name(mob_tidx),
                };
            end
            return;
        end
        -- Old kill (server ID reuse from mob respawn) — clear stale state
        tracker.mob_kills[mob_sid] = nil;
        tracker.mob_kill_times[mob_sid] = nil;
        tracker.drop_sequence[mob_sid] = nil;
        tracker.pet_to_master[mob_sid] = nil;
        tracker.th_levels[mob_sid] = nil;
        tracker.th_actions[mob_sid] = nil;
    end

    -- Pet detection: if this defeated entity is a pet of another mob,
    -- don't create a standalone kill record. Map it to the master mob
    -- so any drops from the pet entity are attributed to the master.
    local owner_tidx = find_pet_owner(mob_tidx);
    if (owner_tidx ~= nil) then
        local mem = AshitaCore:GetMemoryManager();
        if (mem ~= nil) then
            local entity = mem:GetEntity();
            if (entity ~= nil) then
                local master_sid = entity:GetServerId(owner_tidx);
                if (master_sid ~= nil and master_sid > 0) then
                    tracker.pet_to_master[mob_sid] = {
                        master_sid  = master_sid,
                        master_tidx = owner_tidx,
                    };
                end
            end
        end
        return;
    end

    local mob_name = get_entity_name(mob_tidx);
    tracker.mob_names[mob_sid] = mob_name;

    local th_level = tracker.th_levels[mob_sid] or 0;
    local th_action = tracker.th_actions[mob_sid];

    -- Resolve killer name using caster target index from packet
    local killer_name = '';
    if (killer_tidx > 0) then
        local kn = get_entity_name(killer_tidx);
        if (kn ~= 'Unknown') then killer_name = kn; end
    end

    local vana_info = capture_vana_info();

    -- Determine content type: Voidwatcher buff (475) = VW kill, else use
    -- the normal content_info (BCNM/HTBF/Dynamis from 0x0075 packet).
    local ct = tracker.get_content_type();
    if (ct == '' and has_voidwatcher_buff()) then
        ct = 'Voidwatch';
    end

    local ki = {
        killer_id      = killer_id,
        killer_name    = killer_name,
        th_action_type = th_action and th_action.cmd_no or 0,
        th_action_id   = th_action and th_action.cmd_arg or 0,
        bf_name        = tracker.htbf_info and tracker.htbf_info.bf_name or nil,
        bf_difficulty  = tracker.htbf_info and tracker.htbf_info.difficulty or 0,
        content_type   = ct,
    };

    -- Tag mob kills inside an active battlefield so the UI can show [BCNM]/[HTBF]
    if (tracker.battlefield.active) then
        ki.battlefield = tracker.battlefield.name;
        ki.level_cap = tracker.battlefield.level_cap;
    end

    local kill_id = db.record_kill(
        mob_name,
        mob_sid,
        tracker.current_zone_id,
        tracker.current_zone_name,
        th_level,
        tracker.SOURCE_MOB,
        vana_info,
        ki
    );
    tracker.mob_kills[mob_sid] = kill_id;
    tracker.mob_kill_times[mob_sid] = os.clock();
    tracker.drop_sequence[mob_sid] = 0;

    -- Track VW kill directly so handle_event_begin doesn't need to scan
    if (ct == 'Voidwatch') then
        tracker.voidwatch.last_vw_kill = kill_id;
    end

    -- Queue this kill for mob gil detection.
    -- DistributeGil sends 0x0029 msg_id=565 with exact amount shortly after defeat.
    -- FIFO queue handles AoE: defeats and gils arrive in the same order.
    if (kill_id ~= nil) then
        tracker.mob_gil_queue[#tracker.mob_gil_queue + 1] = {
            kill_id  = kill_id,
            time     = os.clock(),
            mob_name = mob_name,
        };
    end

    if (mob_name == 'Unknown' and kill_id ~= nil) then
        set_pending_mob_resolve(mob_sid, kill_id);
    end
end

-------------------------------------------------------------------------------
-- Packet: 0x00D2 - Treasure Pool Item (drop appears)
-------------------------------------------------------------------------------

function tracker.handle_treasure_pool(data)
    if (db == nil) then return; end
    if (#data < 23) then return; end

    local quantity     = sunpack('I', data, 0x04 + 1);
    local mob_sid      = sunpack('I', data, 0x08 + 1);
    local item_id      = sunpack('H', data, 0x10 + 1);
    local mob_tidx     = sunpack('H', data, 0x12 + 1);
    local pool_slot    = sunpack('B', data, 0x14 + 1);
    local is_old       = sunpack('B', data, 0x15 + 1);
    local is_container = sunpack('B', data, 0x16 + 1);

    if (item_id == 0) then return; end
    if (pool_slot > tracker.POOL_MAX_SLOT) then return; end

    -- Clear chest unlock pending state — item came through normal treasure pool
    -- so this is NOT a gil-only chest (cancel the two-phase gil detection).
    if (is_container == 1 and is_old == 0 and tracker.chest_unlock_pending ~= nil) then
        tracker.chest_unlock_pending = nil;
    end

    -- is_old=1: Pool refresh (joining party, opening pool, addon reload).
    -- Still need to populate active_pool so lot results (0x00D3) can resolve.
    -- If we already have a pool entry for this slot, skip (avoid duplicate DB records).
    if (is_old == 1 and tracker.active_pool[pool_slot] ~= nil) then
        return;
    end

    -- For is_old=1 items not yet in active_pool, try to reconnect with existing
    -- DB records before creating new ones (prevents duplicates on addon reload).
    if (is_old == 1) then
        local pending = db.find_pending_drop(pool_slot, item_id);
        if (pending ~= nil) then
            tracker.active_pool[pool_slot] = {
                kill_id       = pending.kill_id,
                item_id       = item_id,
                item_name     = pending.item_name,
                item_count    = pending.quantity or quantity,
                mob_sid       = mob_sid,
                drop_id       = pending.drop_id,
                player_lot    = 0,
                player_action = 0,
                late_join     = false,
            };
            return;
        end

        -- No DB match: create late_join stub instead of falling through to
        -- create new DB records with current timestamps. This fixes the initial
        -- login timestamp clustering bug where all is_old=1 items get os.time().
        -- DB records are deferred to handle_lot_result's late-join logic.
        local item_name = 'Unknown';
        local res = AshitaCore:GetResourceManager();
        if (res ~= nil) then
            local item = res:GetItemById(item_id);
            if (item ~= nil and item.Name ~= nil) then
                item_name = item.Name[1] or 'Unknown';
            end
        end
        -- Try to classify source while entity may still be in memory
        local stub_source = tracker.SOURCE_MOB;
        if (is_container == 1) then
            local stub_name = get_entity_name(mob_tidx);
            if (stub_name ~= 'Unknown') then
                stub_source = classify_source(stub_name, mob_tidx);
            end
        end
        tracker.active_pool[pool_slot] = {
            kill_id       = nil,
            item_id       = item_id,
            item_name     = item_name,
            item_count    = quantity,
            mob_sid       = mob_sid,
            drop_id       = nil,
            player_lot    = 0,
            player_action = 0,
            late_join     = true,
            source_type   = stub_source,
        };
        return;
    end

    -- Pet-to-master redirect: if this drop came from a pet entity,
    -- attribute it to the master mob instead (handles AOE pet kills)
    local effective_sid = mob_sid;
    local effective_tidx = mob_tidx;
    local pet_info = tracker.pet_to_master[mob_sid];
    if (pet_info ~= nil) then
        effective_sid = pet_info.master_sid;
        effective_tidx = pet_info.master_tidx;
    end

    local mob_name = tracker.mob_names[effective_sid] or get_entity_name(effective_tidx);

    -- If entity memory returned 'Unknown' for a container, try last_interact
    -- (outgoing 0x1A pre-identified the target before it despawned)
    if (mob_name == 'Unknown' and is_container == 1 and tracker.last_interact ~= nil) then
        if (tracker.last_interact.server_id == effective_sid
            and (os.clock() - tracker.last_interact.timestamp) < 5.0
            and tracker.last_interact.name ~= 'Unknown') then
            mob_name = tracker.last_interact.name;
        end
    end

    tracker.mob_names[effective_sid] = mob_name;

    local source_type = tracker.SOURCE_MOB;
    if (is_container == 1) then
        source_type = classify_source(mob_name, effective_tidx);
    end

    -- Auto-activate battlefield session when chest detected but session
    -- was lost (addon reload after buff expired, or reload after fight ended).
    -- This ensures 0x001E/0x0053 gil handlers see battlefield.active = true.
    if (source_type == tracker.SOURCE_BCNM and not tracker.battlefield.active) then
        tracker.battlefield.active = true;
        tracker.battlefield.gil_handled = false;
        tracker.battlefield.pending_gil = nil;
        -- Try to recover name from DB, otherwise use zone name
        if (db ~= nil and tracker.current_zone_id > 0) then
            local session = db.get_active_battlefield(tracker.current_zone_id);
            if (session ~= nil) then
                tracker.battlefield.name = session.battlefield_name;
                tracker.battlefield.level_cap = session.level_cap;
            end
        end
        if (tracker.battlefield.name == nil) then
            tracker.battlefield.name = tracker.current_zone_name or 'Unknown BCNM';
        end
        tracker.battlefield.zone_id = tracker.current_zone_id;
    end

    local th_level = tracker.th_levels[effective_sid] or 0;

    -- Use existing kill record from 0x0029 defeat, or create one for
    -- containers/chests that don't send defeat messages, or late-join pool items
    local kill_id = tracker.mob_kills[effective_sid];
    if (kill_id == nil and source_type == tracker.SOURCE_MOB and pet_info == nil) then
        -- Check if this entity is a pet whose 0x0029 defeat hasn't arrived yet.
        -- If so, redirect to master so drops are attributed correctly.
        local owner_tidx = find_pet_owner(effective_tidx);
        if (owner_tidx ~= nil) then
            local mem = AshitaCore:GetMemoryManager();
            if (mem ~= nil) then
                local entity = mem:GetEntity();
                if (entity ~= nil) then
                    local master_sid = entity:GetServerId(owner_tidx);
                    if (master_sid ~= nil and master_sid > 0) then
                        tracker.pet_to_master[mob_sid] = {
                            master_sid  = master_sid,
                            master_tidx = owner_tidx,
                        };
                        effective_sid = master_sid;
                        effective_tidx = owner_tidx;
                        mob_name = tracker.mob_names[effective_sid] or get_entity_name(effective_tidx);
                        tracker.mob_names[effective_sid] = mob_name;
                        kill_id = tracker.mob_kills[effective_sid];
                    end
                end
            end
        end
    end
    if (kill_id == nil) then
        local vana_info = capture_vana_info();
        local ki = {};
        if (source_type == tracker.SOURCE_BCNM and tracker.battlefield.active) then
            ki.battlefield = tracker.battlefield.name;
            ki.level_cap = tracker.battlefield.level_cap;
        end
        -- 0x00D2 without prior defeat (msg_id=6) for a fresh mob kill = distant
        -- kill with drops. Flag it so Statistics can separate nearby vs distant rates.
        if (is_old == 0 and source_type == tracker.SOURCE_MOB) then
            ki.is_distant = 1;
        end
        -- Attach HTBF info if active
        ki.bf_name = tracker.htbf_info and tracker.htbf_info.bf_name or nil;
        ki.bf_difficulty = tracker.htbf_info and tracker.htbf_info.difficulty or 0;
        ki.content_type = tracker.get_content_type();
        kill_id = db.record_kill(
            mob_name,
            effective_sid,
            tracker.current_zone_id,
            tracker.current_zone_name,
            th_level,
            source_type,
            vana_info,
            ki
        );
        tracker.mob_kills[effective_sid] = kill_id;
        tracker.mob_kill_times[effective_sid] = os.clock();

        -- Track last BCNM kill_id so 0x001E/0x0053 can attach gil to it
        if (source_type == tracker.SOURCE_BCNM and kill_id ~= nil) then
            tracker.battlefield.last_kill_id = kill_id;

            -- Flush buffered gil: 0x001E/0x0053 arrived before this 0x00D2
            if (tracker.battlefield.pending_gil ~= nil and not tracker.battlefield.gil_handled) then
                db.record_drop(kill_id, -1, 65535, 'Gil', tracker.battlefield.pending_gil, 1);
                tracker.battlefield.gil_handled = true;
                tracker.battlefield.pending_gil = nil;
                tracker.battlefield.last_kill_id = nil;
            end
        end

        -- Flag for chat-based name resolution if entity was out of range
        if (mob_name == 'Unknown' and kill_id ~= nil) then
            set_pending_mob_resolve(effective_sid, kill_id);
        end

        -- Credit: 0x00D2 without prior defeat = distant kill with drops.
        -- The corresponding msg_id=37 will consume this credit instead of
        -- being recorded as a missed kill. Only for fresh mob kills.
        if (is_old == 0 and source_type == tracker.SOURCE_MOB) then
            tracker.distant_kill_credits = tracker.distant_kill_credits + 1;
        end
    end

    if (kill_id == nil) then return; end

    local item_name = 'Unknown';
    local res = AshitaCore:GetResourceManager();
    if (res ~= nil) then
        local item = res:GetItemById(item_id);
        if (item ~= nil and item.Name ~= nil) then
            item_name = item.Name[1] or 'Unknown';
        end
    end

    -- Track drop arrival order per mob for slot analysis
    local seq_key = effective_sid;
    local cur_order = tracker.drop_sequence[seq_key] or 0;
    tracker.drop_sequence[seq_key] = cur_order + 1;

    local drop_id = db.record_drop(kill_id, pool_slot, item_id, item_name, quantity, nil, cur_order);

    if (mob_name == 'Unknown') then
        increment_pending_resolve(kill_id);
    end

    tracker.active_pool[pool_slot] = {
        kill_id       = kill_id,
        item_id       = item_id,
        item_name     = item_name,
        item_count    = quantity,
        mob_sid       = mob_sid,
        drop_id       = drop_id,
        player_lot    = 0,
        player_action = 0,
    };

end

-------------------------------------------------------------------------------
-- Packet: 0x00D3 - Trophy Solution (lot/win result)
-------------------------------------------------------------------------------

function tracker.handle_lot_result(data)
    if (db == nil) then return; end
    if (#data < 54) then return; end

    -- Full 0x00D3 packet layout (from LSB src/map/packets/s2c/0x0d3_trophy_solution.h):
    --   0x04  LootUniqueNo   uint32   Highest lotter's entity ID
    --   0x08  EntryUniqueNo  uint32   Current lotter's entity ID
    --   0x0C  LootActIndex   uint16   Highest lotter's target index
    --   0x0E  LootPoint      int16    Highest lotter's lot value
    --   0x10  EntryActIndex  uint15   Current lotter's target index (bits 0-14)
    --         EntryFlg       uint1    Entry flag (bit 15)
    --   0x12  EntryPoint     int16    Current lotter's lot value
    --   0x14  TrophyItemIndex uint8   Pool slot (0-9)
    --   0x15  JudgeFlg       uint8    0=lotted, 1=won, 2=inv full, 3=lost
    --   0x16  sLootName[16]  char[]   Highest lotter's name
    --   0x26  sLootName2[16] char[]   Current lotter's name

    local loot_id     = sunpack('I', data, 0x04 + 1);  -- highest lotter entity ID
    local entry_id    = sunpack('I', data, 0x08 + 1);  -- current lotter entity ID
    local loot_point  = sunpack('h', data, 0x0E + 1);  -- highest lot value
    local entry_raw   = sunpack('H', data, 0x10 + 1);  -- EntryActIndex:15 + EntryFlg:1
    local entry_point = sunpack('h', data, 0x12 + 1);  -- current lotter's lot value
    local pool_slot   = sunpack('B', data, 0x14 + 1);
    local judge_flag  = sunpack('B', data, 0x15 + 1);
    local entry_flg   = bit.rshift(entry_raw, 15);     -- bit 15 = EntryFlg

    -- Read highest lotter name: sLootName (16 bytes at offset 0x16)
    local loot_name_bytes = {};
    for i = 0, 15 do
        local b = sunpack('B', data, 0x16 + i + 1);
        if (b == 0) then break; end
        loot_name_bytes[#loot_name_bytes + 1] = string.char(b);
    end
    local loot_name = table.concat(loot_name_bytes);

    local entry_name_bytes = {};
    for i = 0, 15 do
        local b = sunpack('B', data, 0x26 + i + 1);
        if (b == 0) then break; end
        entry_name_bytes[#entry_name_bytes + 1] = string.char(b);
    end
    local entry_name = table.concat(entry_name_bytes);

    -- judge_flag == 0 is a "someone lotted/passed" notification (no final result).
    -- Track highest lot and our own lot value.
    if (judge_flag == 0) then
        local pool_entry = tracker.active_pool[pool_slot];

        -- No pool entry: item was in pool before addon loaded (reload, late join).
        -- Read item info from client memory and create a stub for lot tracking.
        if (pool_entry == nil) then
            local pool_info = get_pool_item_info(pool_slot);
            pool_entry = {
                kill_id       = nil,  -- no DB record yet; created on final result
                item_id       = pool_info and pool_info.item_id or 0,
                item_name     = pool_info and pool_info.item_name or 'Unknown',
                item_count    = pool_info and pool_info.count or 1,
                mob_sid       = 0,
                drop_id       = nil,
                player_lot    = 0,
                player_action = 0,
                late_join     = true,
            };
            tracker.active_pool[pool_slot] = pool_entry;
        end

        if (loot_point > (pool_entry.highest_lot or 0)) then
            pool_entry.highest_lot = loot_point;
        end

        local player = GetPlayerEntity();
        local my_sid = player and player.ServerId or 0;
        if (entry_id == my_sid and my_sid ~= 0) then
            pool_entry.player_lot = entry_point;
            pool_entry.player_action = entry_flg;
        end
        return;
    end

    local pool_entry = tracker.active_pool[pool_slot];
    if (pool_entry == nil) then
        return;
    end

    -- Judge flags: 0x01=Win, 0x02=WinError (inv full/lost), 0x03=Lost
    local status = tracker.STATUS_LOST;  -- default to lost for unknown flags
    if (judge_flag == 0x01) then
        status = tracker.STATUS_OBTAINED;
    elseif (judge_flag == 0x02) then
        status = tracker.STATUS_DROPPED;
    elseif (judge_flag == 0x03) then
        status = tracker.STATUS_LOST;
    end

    -- Late-join stub: no DB records exist yet. Create kill + drop now so we
    -- can store the lot result. Item info was read from client memory at stub creation.
    if (pool_entry.late_join and pool_entry.kill_id == nil) then
        if (pool_entry.item_id == 0) then
            local pool_info = get_pool_item_info(pool_slot);
            if (pool_info ~= nil) then
                pool_entry.item_id   = pool_info.item_id;
                pool_entry.item_name = pool_info.item_name;
                pool_entry.item_count = pool_info.count;
            end
        end

        local item_name = pool_entry.item_name or 'Unknown';
        local item_id   = pool_entry.item_id or 0;
        local item_qty  = pool_entry.item_count or 1;

        local vana_info = capture_vana_info();
        local kill_id = db.record_kill(
            'Unknown (late join)',
            0,
            tracker.current_zone_id,
            tracker.current_zone_name,
            0,
            pool_entry.source_type or tracker.SOURCE_MOB,
            vana_info
        );
        if (kill_id ~= nil) then
            pool_entry.kill_id = kill_id;
            db.record_drop(kill_id, pool_slot, item_id, item_name, item_qty);
        end
    end

    if (pool_entry.kill_id == nil) then
        tracker.active_pool[pool_slot] = nil;
        return;
    end

    -- Final packet may have LootPoint=0; use tracked highest lot from judge=0 packets.
    -- Third fallback: read WinningLot/Lot from client memory (survives addon reload).
    local final_lot = loot_point;
    if (final_lot <= 0 and (pool_entry.highest_lot or 0) > 0) then
        final_lot = pool_entry.highest_lot;
    end
    if (final_lot <= 0 or (pool_entry.player_lot or 0) <= 0) then
        local mem_info = get_pool_item_info(pool_slot);
        if (mem_info ~= nil) then
            if (final_lot <= 0 and mem_info.winning_lot > 0) then
                final_lot = mem_info.winning_lot;
            end
            if ((pool_entry.player_lot or 0) <= 0 and mem_info.lot > 0) then
                pool_entry.player_lot = mem_info.lot;
                pool_entry.player_action = 1;
            end
        end
    end

    local winner_name = loot_name;
    local winner_id   = loot_id;

    db.update_drop_won(pool_entry.kill_id, pool_slot, status, final_lot, {
        winner_id     = winner_id,
        winner_name   = winner_name,
        player_lot    = pool_entry.player_lot or 0,
        player_action = pool_entry.player_action or 0,
    });

    -- Clear pool slot (only on final result, never on lot notifications)
    tracker.active_pool[pool_slot] = nil;
end

-------------------------------------------------------------------------------
-- Packet: 0x0028 - Action (TH proc detection)
-- Uses bitreader to parse the bit-packed action packet.
-- Only looks for proc_message == 603 (TH level update).
-------------------------------------------------------------------------------

function tracker.handle_action(data)
    if (#data < 19) then return; end  -- minimum: 5-byte offset + 110 bits of header fields
    local reader = breader:new();
    reader:set_data(data);
    reader:set_pos(5);

    local actor_id   = reader:read(32);
    local trg_sum    = reader:read(6);
    local _res_sum   = reader:read(4);
    local _cmd_no    = reader:read(4);
    local _cmd_arg   = reader:read(32);
    local _info      = reader:read(32);

    for _t = 0, trg_sum - 1 do
        local target_id  = reader:read(32);

        -- bitreader:read(32) uses bit.bor which returns signed 32-bit.
        -- Normalize to unsigned to match sunpack('I') keys used in
        -- handle_defeat/handle_treasure_pool for consistent table lookups.
        -- Note: bit.band(x, 0xFFFFFFFF) is a no-op in LuaJIT (still signed).
        -- Adding 2^32 promotes to double with the correct unsigned value.
        if (target_id < 0) then
            target_id = target_id + 4294967296;
        end

        local result_sum = reader:read(4);

        for _r = 0, result_sum - 1 do
            -- Main result fields (85 bits total)
            reader:read(3);   -- miss
            reader:read(2);   -- kind
            reader:read(12);  -- sub_kind
            reader:read(5);   -- info
            reader:read(5);   -- scale
            reader:read(17);  -- value
            reader:read(10);  -- message
            reader:read(31);  -- bit

            local has_proc = reader:read(1);
            if (has_proc > 0) then
                local _proc_kind    = reader:read(6);
                local _proc_info    = reader:read(4);
                local proc_value    = reader:read(17);
                local proc_message  = reader:read(10);

                -- Message 603 = Treasure Hunter level update
                if (proc_message == 603) then
                    tracker.th_levels[target_id] = proc_value;
                    tracker.th_actions[target_id] = { cmd_no = _cmd_no, cmd_arg = _cmd_arg };
                end
            end

            local has_react = reader:read(1);
            if (has_react > 0) then
                reader:read(6);   -- react_kind
                reader:read(4);   -- react_info
                reader:read(14);  -- react_value
                reader:read(10);  -- react_message
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Packet: 0x005C - GP_SERV_COMMAND_PENDINGNUM (HTBF entry detection)
-- 8 x int32 params starting at offset 0x04.
-- When num[0]==2: HTBF entry event.
--   num[1] = bit position (battlefield name index within zone)
--   num[2] = difficulty: 1=VD, 2=D, 3=N, 4=E, 5=VE
--   num[3] = instance ID (unstable, not stored)
-------------------------------------------------------------------------------

function tracker.handle_pending_num(data)
    if (#data < 36) then return; end  -- need at least 8 uint32s (32 bytes) + 4 header

    local num0 = sunpack('I', data, 0x04 + 1);
    if (num0 ~= 2) then return; end  -- only HTBF entry events

    local bit_pos    = sunpack('I', data, 0x08 + 1);
    local difficulty = sunpack('I', data, 0x0C + 1);

    -- Range guard: BCNMs send 0, Sortie sends 0xFF — only HTBF uses 1-5
    if (difficulty < 1 or difficulty > 5) then return; end

    -- Resolve battlefield name from zone dialog DAT
    local bf_name = nil;
    if (datreader ~= nil and tracker.current_zone_id > 0) then
        bf_name = datreader.get_battlefield_name(tracker.current_zone_id, bit_pos);
    end

    tracker.htbf_info = {
        difficulty = difficulty,
        bf_name    = bf_name,
    };
end

-------------------------------------------------------------------------------
-- Packet: 0x034 (S2C) - GP_SERV_COMMAND_EVENTNUM (Voidwatch Pyxis loot)
-- Riftworn Pyxis sends item IDs in params[0-7] as int32.
-- First 0x034: record all offered items. Subsequent: detect taken items.
-------------------------------------------------------------------------------

function tracker.handle_event_begin(data)
    if (db == nil) then return; end
    if (not tracker.voidwatch.pyxis_active) then return; end
    if (#data < 0x34) then return; end

    local npc_sid = sunpack('I', data, 0x04 + 1);
    if (npc_sid ~= tracker.voidwatch.pyxis_sid) then return; end

    -- Read 8 int32 params at offset 0x08
    local params = {};
    for i = 0, 7 do
        local val = sunpack('i', data, 0x08 + (i * 4) + 1);
        params[i] = (val ~= nil and val > 0 and val < 65536) and val or 0;
    end

    if (not tracker.voidwatch.items_captured) then
        -------------------------------------------------
        -- FIRST 0x034: Record all offered items (won=0)
        -------------------------------------------------
        local items = {};
        for i = 0, 7 do
            if (params[i] > 0) then
                items[#items + 1] = { slot = i, item_id = params[i] };
            end
        end
        if (#items == 0) then return; end

        local kill_id = tracker.voidwatch.last_vw_kill;
        if (kill_id == nil) then return; end

        -- Record each offered item as a drop (won=0 = pending)
        local res = AshitaCore:GetResourceManager();
        for _, entry in ipairs(items) do
            local item_name = 'Unknown';
            if (res ~= nil) then
                local item = res:GetItemById(entry.item_id);
                if (item ~= nil and item.Name ~= nil) then
                    item_name = item.Name[1] or 'Unknown';
                end
            end
            db.record_drop(kill_id, entry.slot, entry.item_id, item_name, 1, 0);
        end

        tracker.voidwatch.items_captured = true;
        tracker.voidwatch.kill_id = kill_id;
        tracker.voidwatch.offered = {};
        for i = 0, 7 do
            if (params[i] > 0) then
                tracker.voidwatch.offered[i] = params[i];
            end
        end
    else
        -------------------------------------------------
        -- SUBSEQUENT 0x034: Detect taken items
        -- Param went from non-zero to zero → item taken
        -------------------------------------------------
        local kill_id = tracker.voidwatch.kill_id;
        if (kill_id == nil) then return; end

        for slot, item_id in pairs(tracker.voidwatch.offered) do
            if (params[slot] == 0) then
                db.update_drop_won(kill_id, slot, 1, 0);
                tracker.voidwatch.offered[slot] = nil;
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Voidwatch: Match an incoming inventory item against offered Pyxis items.
-- Called by both 0x01F (stackable items) and 0x020 (equipment/augmented).
-------------------------------------------------------------------------------

local function match_vw_item(item_id)
    if (db == nil) then return; end
    if (not tracker.voidwatch.pyxis_active) then return; end
    if (not tracker.voidwatch.items_captured) then return; end
    if (tracker.voidwatch.kill_id == nil) then return; end
    if (item_id == nil or item_id == 0) then return; end

    for slot, offered_id in pairs(tracker.voidwatch.offered) do
        if (offered_id == item_id) then
            db.update_drop_won(tracker.voidwatch.kill_id, slot, 1, 0);
            tracker.voidwatch.offered[slot] = nil;
            return;  -- match first occurrence only (handles duplicate item IDs)
        end
    end
end

-------------------------------------------------------------------------------
-- Packet: 0x01F (S2C) - GP_SERV_COMMAND_ITEM_LIST (inventory item assign)
-- Stackable VW items (materials, seals) are delivered via 0x01F.
--   Offset 0x08: ItemNo (uint16)
-------------------------------------------------------------------------------

function tracker.handle_item_assign(data)
    if (#data < 0x0C) then return; end
    local item_id = sunpack('H', data, 0x08 + 1);
    match_vw_item(item_id);
end

-------------------------------------------------------------------------------
-- Packet: 0x020 (S2C) - GP_SERV_COMMAND_ITEM_ATTR (item full info)
-- Equipment/augmented VW items are delivered via 0x020.
--   Offset 0x0C: ItemNo (uint16)
-------------------------------------------------------------------------------

function tracker.handle_item_full_info(data)
    if (#data < 0x0E) then return; end
    local item_id = sunpack('H', data, 0x0C + 1);
    match_vw_item(item_id);
end

-------------------------------------------------------------------------------
-- Packet: 0x5B (outgoing) - GP_CLI_COMMAND_EVENTEND (Voidwatch Pyxis close)
-- EndPara values for Pyxis: 1-8 = item selection, 9 = exit/leave,
-- 10 = obtain all remaining. 0x05B fires BEFORE delivery packets (0x01F/0x020),
-- so we must set the won value here — delivery packets arrive too late.
-------------------------------------------------------------------------------

function tracker.handle_event_end(data)
    if (not tracker.voidwatch.pyxis_active) then return; end
    if (not tracker.voidwatch.items_captured) then return; end
    if (#data < 0x0C) then return; end

    local npc_sid  = sunpack('I', data, 0x04 + 1);
    if (npc_sid ~= tracker.voidwatch.pyxis_sid) then return; end

    local end_para = sunpack('I', data, 0x08 + 1);
    if (end_para == 10) then
        finalize_vw_interaction(1);   -- obtain all = won
    elseif (end_para == 9) then
        finalize_vw_interaction(-1);  -- exit/leave = relinquished
    end
end

-------------------------------------------------------------------------------
-- Packet: 0x1A (outgoing) - GP_CLI_COMMAND_ACTION (chest interaction)
-- Tracks the most recent NPC interaction so we can pre-identify
-- chest/coffer targets before 0x00D2 drops arrive.
--   Offset 0x04: UniqueNo (uint32) — target entity server ID
--   Offset 0x08: ActIndex (uint16) — target entity index
--   Offset 0x0A: ActionID (uint16) — 0x00 = Talk/NPC Interact
-------------------------------------------------------------------------------

function tracker.handle_outgoing_action(data)
    if (#data < 12) then return; end

    local action_id = sunpack('H', data, 0x0A + 1);
    if (action_id ~= 0) then return; end  -- only Talk/Interact

    local server_id    = sunpack('I', data, 0x04 + 1);
    local target_index = sunpack('H', data, 0x08 + 1);

    local name = get_entity_name(target_index);

    tracker.last_interact = {
        server_id    = server_id,
        target_index = target_index,
        name         = name,
        timestamp    = os.clock(),
    };

    -- Detect Voidwatch Riftworn Pyxis interaction.
    -- Content type is tagged at kill time via Voidwatcher buff (475) in
    -- handle_defeat, NOT here — VW happens in open-world zones.
    if (name ~= nil) then
        local lower = name:lower();
        if (lower == 'riftworn pyxis') then
            if (tracker.voidwatch.pyxis_active
                and tracker.voidwatch.pyxis_sid == server_id
                and tracker.voidwatch.items_captured) then
                -- Same Pyxis entity with items already captured.
                -- Check if a new kill occurred (new VW cycle, Pyxis reused).
                local recent_kill = tracker.voidwatch.last_vw_kill;
                if (recent_kill ~= nil and recent_kill ~= tracker.voidwatch.kill_id) then
                    -- New kill → new cycle → reset state
                    finalize_vw_interaction();
                    tracker.voidwatch.pyxis_active = true;
                    tracker.voidwatch.pyxis_sid = server_id;
                    tracker.voidwatch.items_captured = false;
                    tracker.voidwatch.kill_id = nil;
                    tracker.voidwatch.offered = {};
                end
                -- else: same kill or no new kill → genuine re-interaction, keep state
            else
                -- Different Pyxis or first interaction
                finalize_vw_interaction();
                tracker.voidwatch.pyxis_active = true;
                tracker.voidwatch.pyxis_sid = server_id;
                tracker.voidwatch.items_captured = false;
                tracker.voidwatch.kill_id = nil;
                tracker.voidwatch.offered = {};
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Reset
-------------------------------------------------------------------------------

function tracker.reset()
    tracker.th_levels = {};
    tracker.th_actions = {};
    tracker.active_pool = {};
    tracker.mob_kills = {};
    tracker.mob_kill_times = {};
    tracker.mob_names = {};
    tracker.pet_to_master = {};
    tracker.pending_mob_resolves = {};
    tracker.dat_names = {};
    tracker.drop_sequence = {};
    tracker.distant_kill_credits = 0;
    tracker.chest_unlock_pending = nil;
    tracker.chest_packet_handled_at = 0;
    tracker.last_gil_update = nil;
    tracker.mob_gil_queue = {};
    tracker.pool_scan_pending = false;
    tracker.pool_scan_retries = 0;
    tracker.pool_scan_last_try = 0;
    tracker.battlefield.active = false;
    tracker.battlefield.name = nil;
    tracker.battlefield.zone_id = nil;
    tracker.battlefield.level_cap = nil;
    tracker.battlefield.cap_check_pending = false;
    tracker.battlefield.last_kill_id = nil;
    tracker.battlefield.gil_handled = false;
    tracker.battlefield.pending_gil = nil;
    tracker.htbf_info = nil;
    tracker.last_interact = nil;
    tracker.content_info = nil;
    tracker.voidwatch = { pyxis_active = false, pyxis_sid = nil, items_captured = false, kill_id = nil, offered = {}, last_vw_kill = nil };
end

return tracker;
