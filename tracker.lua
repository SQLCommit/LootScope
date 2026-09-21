-- LootScope packet tracking and shared reward state.

require 'common';

local sunpack = struct.unpack;
local has_buff;                     -- forward decl; defined below, used by the 0x0075 handler
local stamp_provenance;             -- forward decl; defined below, bound into containers.lua (handle_chest_text)
local EFFECT_BATTLEFIELD = 254;     -- LSB src/map/status_effect.h:330
local settings = require 'settings';   -- authoritative character identity (name / server_id)
local breader = require 'bitreader';
local classify = require 'classify';   -- pure content-classification rules + tables
local content  = require 'content';    -- content-classification STATE (evidence slots)
local battlefield = require 'battlefield';  -- BCNM/HTBF session state (4 recovery paths)
local containers  = require 'containers';   -- chest / coffer / Limbus chest handlers
local gil = require 'gil';   -- split gil.lua
local th = require 'th';   -- split th.lua
local vana_time = require 'ffxi.time';
local dats = require 'ffxi.dats';
local ok_dat, datreader = pcall(require, 'datreader');
if (not ok_dat) then datreader = nil; end
local ok_itemdata, itemdata_lib = pcall(require, 'ffxi.itemdata');
if (not ok_itemdata) then itemdata_lib = nil; end
local tracker = {};
tracker.has_datreader = ok_dat;
tracker.has_itemdata = ok_itemdata;
tracker.pending_warnings = {};

-- In-Memory State (cleared on zone change)
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

-- Previous zone ID: tracked for source-zone disambiguation (Odyssey vs WoE HTBF)
tracker.previous_zone_id = 0;

-- Distant kill dedup credits: each 0x00D2-created distant kill absorbs one msg_id=37
-- Unmatched msg_id=37 events = genuinely missed empty kills
tracker.distant_kill_credits = 0;

-- Deferred pool scan: retries once/sec (up to 10) until pool is loaded
tracker.pool_scan_pending = false;
tracker.pool_scan_retries = 0;
tracker.pool_scan_last_try = 0;

-- Chest unlock pending state (two-phase gil detection)
tracker.chest_unlock_pending = nil;  -- { time, container_type, zone_id, zone_name }
tracker.limbus_chest = nil;          -- { armed_at, server_id, name, kill_id, items, order, packet_items } -- owned by containers.lua
tracker.woe_coffer   = nil;          -- { armed_at, server_id, kill_id, offered, pending, drop_ids, echo, packet_marks } -- owned by containers.lua
tracker.reive_spoils = nil;     -- containers: buffered Colonization / Lair Reive end spoils (one row per Reive)
tracker.woe_walk     = nil;          -- { name, server_id } -- the walk entered via its conflux (containers.lua)
tracker.woe_conflux_pending = nil;   -- { number, server_id } -- a portal touched, entry not yet confirmed (containers.lua)
tracker.woe_recover_at = nil;        -- os.clock of the last entity scan for the walk's exit conflux (containers.lua)

-- Recent 0x001E memory: last gil update for text_in fallback when 0x002A races
tracker.last_gil_update = nil;

-- Battlefield (BCNM) state
tracker.battlefield = battlefield.state;

-- HTBF state — set from 0x005C, persists until zone change
tracker.htbf_info = nil;  -- { zone_id, bit_pos, difficulty, bf_name }

-- True once 0x005C has made a BCNM/HTBF determination for the CURRENT battlefield, regardless of
-- which way it went.
tracker.htbf_packet_seen = false;

-- Outgoing 0x1A interaction — pre-identifies chest/coffer before 0x00D2
tracker.last_interact = nil;  -- { server_id, target_index, name, timestamp }

-- Content type — set by 0x0075, persists until zone change
tracker.content = content.state;

-- Pending WoE HTBF entry — survives one zone change.
tracker.pending_htbf_entry = nil;   -- { name, difficulty, timestamp }
tracker.pending_woe_difficulty = nil; -- int (1-5) from 0x005C num[0]=1, consumed by pending entry

-- Voidwatch state (Riftworn Pyxis loot tracking via 0x034)
tracker.voidwatch = {
    pyxis_active = false,       -- player talked to Riftworn Pyxis
    pyxis_sid = nil,            -- Pyxis entity server ID
    items_captured = false,     -- first 0x034 processed
    kill_id = nil,              -- linked kill record
    offered = {},               -- { [slot] = item_id } from first 0x034
    drop_ids = {},              -- { [slot] = drops.id } so lot updates target ONE row
    last_vw_kill = nil,         -- most recent VW NM kill_id (set by handle_defeat)
};

-- Wildskeeper Reive state (direct inventory loot via 0x034 Event 2007)
tracker.wildskeeper = {
    active = false,             -- Reive Mark buff (511) is active
    kind = nil,                 -- 'Colonization' | 'Lair' | 'Wildskeeper' from the chat line that names it
    last_boss_name = nil,       -- name of last defeated Naakual
    last_boss_sid = nil,        -- server ID of last defeated Naakual
    last_kill_id = nil,         -- kill record ID for last Naakual defeat
    last_kill_time = 0,         -- os.clock() of last Naakual defeat
    mark_off_at    = nil,   -- os.clock when the Mark dropped (the spoils land after it)
    last_kind      = nil,   -- kind kept past the Mark loss for the spoils row
};

-- Drop arrival order per mob (for slot analysis ordering queries)
-- mob_server_id -> next sequence number, reset to 0 on kill, incremented per 0x00D2
tracker.drop_sequence = {};

-- Mob gil pending queue (FIFO).
tracker.mob_gil_queue = {};
-- Queue every pending gil message; AoE kills can produce several in one batch.
tracker.pending_mob_gil = {};    -- held 0x0029 565s awaiting their 566 cancel window
tracker.mob_gil_hold = {};       -- retail Gold that arrived before its kill row, by mob_sid (gil.lua)

-- TH gear estimation state (cleared on zone change)
tracker.th_estimated = {};     -- mob_server_id -> max TH estimate seen across all scans
tracker.engaged_mobs = {};     -- mob_server_id -> true (mobs we're actively fighting)

-- TH trust/pet tracking: name of active TH trust/pet (for UI display, cleared on zone change)
tracker.th_trust_source = nil;     -- name of last TH trust/pet that hit a mob

-- TH items lookup cache (rebuilt when profile changes)
tracker.th_items_cache = nil;  -- item_id -> { th_value, slot_id } (from active profile)
tracker.th_profile_id = nil;   -- active profile id for cache invalidation

-- Cached player server ID (updated on zone/login, avoids per-action lookup)
local cached_player_sid = nil;


-- 0x00D3 EntryFlg distinguishes a roll (1, 0-999) from a pass (0, -1).
-- Memory Lot=0xFFFF also covers no lot round, so memory-only reads remain ACTION_NONE.
local ACTION_NONE   = 0;   -- item reached us with no lot from us, or we never saw the notification
local ACTION_LOTTED = 1;
local ACTION_PASSED = 2;

local DIFFICULTY_UNKNOWN = 6;  -- sentinel: HTBF detected from ★ prefix, difficulty not yet resolved

local function unsigned_sid(sid)
    if (sid ~= nil and sid < 0) then return sid + 4294967296; end
    return sid;
end


-- Resolve whether an actor server ID is a TH trust or pet.
local function mem_player()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return nil; end
    return mem:GetPlayer();
end

local function mem_party()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return nil; end
    return mem:GetParty();
end

local function mem_entity()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return nil; end
    return mem:GetEntity();
end

local function mem_inventory()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return nil; end
    return mem:GetInventory();
end


-- Treasure Hound grants TH+1 while Signet is active. Cache the zone kupower, check Signet live.
-- TODO: Atma of Dread and Prowess need configuration; their buffs do not identify active bonuses.
-- Prowess adds TH+1 per level, up to TH+3.
tracker.zone_has_treasure_hound = false;

function tracker.handle_kupower_text(msg)
    if (msg == nil or msg == '') then return; end
    -- FFXI sends: "This area is currently affected by the Super Kupower: Treasure Hound!"
    if (msg:find('Treasure Hound', 1, true)) then
        tracker.zone_has_treasure_hound = true;
    end
end

-- References set during init
local db = nil;
local base_path = nil;

-- Source Type Constants
tracker.SOURCE_MOB    = 0;
tracker.SOURCE_CHEST  = 1;
tracker.SOURCE_COFFER = 2;
tracker.SOURCE_BCNM   = 3;
tracker.POOL_MAX_SLOT = 9;   -- FFXI treasure pool has slots 0-9

-- Odyssey NPC Instance IDs (from upper 12 bits of entity server IDs).
-- Used for addon reload fallback detection in shared WoE P1/P2 zones.
local ODYSSEY_INSTANCES = {
    [1019] = true, [1020] = true,  -- Sheol A
    [1021] = true, [1022] = true,  -- Sheol B
    [1023] = true, [1024] = true,  -- Sheol C
};

--- Odyssey fallback: detect via NPC instance IDs in 0x000E packets.
--- Only fires when in WoE P1/P2 (279/298) with no content_info set
--- (addon reload scenario where previous_zone_id is unknown).
function tracker.handle_npc_update(data)
    if (content.resolve() ~= '') then return; end
    local zone_id = tracker.current_zone_id;
    if (zone_id ~= 279 and zone_id ~= 298) then return; end
    if (#data < 8) then return; end

    local server_id = sunpack('I', data, 0x04 + 1);
    local instance = bit.band(bit.rshift(server_id, 12), 0xFFF);
    if (ODYSSEY_INSTANCES[instance]) then
        content.set_source('Odyssey');
    end
end

-- Instance Zone Lookup: Zone ID → content type string.
-- Dynamis is detected by zone name prefix instead (not in this table).

function tracker.get_content_type()
    return content.resolve();
end

-- Packet: 0x0075 (S2C) - Battlefield entry (content type detection)
-- Sent on entry + reconnect. Mode 0x0001 = BCNM/HTBF.
local BATTLEFIELD_MODE_MAP = {
    [0x0001] = 'BCNM',
    [0x030D] = 'Omen',   -- Reisenjima Henge
};

local OBJ_FLAG_FENCE = 0x08;   -- flags: 1=COUNTDOWN 2=PROGRESS 4=HELP 8=FENCE

function tracker.handle_battlefield_packet(data)
    if (#data < 0x25) then return; end            -- Mode u32 @0x04, Flags u8 @0x24

    local mode  = sunpack('I', data, 0x04 + 1);   -- was 'H' -- Mode is uint32, we read half of it
    local flags = sunpack('B', data, 0x24 + 1);   -- never read before; it carries the meaning

    if (flags == 0) then
        if (tracker.battlefield.active) then
            -- Book buffered crate gil onto the last kill before exit discards session state.
            gil.flush_battlefield_gil(tracker.battlefield.last_kill_id);
            if (db ~= nil) then db.end_battlefield_session(os.time()); end
            battlefield.exit();
        end
        tracker.htbf_info = nil;
        tracker.htbf_packet_seen = false;
        content.end_battlefield();
        return;
    end
    -- Mode 0 clears content info.
    if (mode == 0) then return; end
    -- FENCE = an open-world bounded encounter (Domain Invasion, Geas Fete).
    if (bit.band(flags, OBJ_FLAG_FENCE) ~= 0) then return; end
    -- Escha hosts Domain Invasion AND Geas Fete, and DI also sends one (mode 1, flags 1) with no
    -- fence bit.
    if (classify.DOMAIN_INVASION_ZONES[tracker.current_zone_id]) then return; end

    -- Unknown mode: stay SILENT.
    local content_type = BATTLEFIELD_MODE_MAP[mode];
    if (content_type == nil) then return; end

    -- Mode 1 is shared with timed QUESTS, which fire in the OPEN WORLD
    if (content_type == 'BCNM' and not has_buff(EFFECT_BATTLEFIELD)) then return; end

    content.set_packet(content_type);
end

-- Chest Event Constants
tracker.CHEST_RESULT_GIL           = 0;
tracker.CHEST_RESULT_FAIL_PICK     = 1;
tracker.CHEST_RESULT_FAIL_TRAP     = 2;
tracker.CHEST_RESULT_FAIL_MIMIC    = 3;
tracker.CHEST_RESULT_FAIL_ILLUSION = 4;

tracker.CONTAINER_CHEST  = 1;
tracker.CONTAINER_COFFER = 2;

-- Lot Result Status Constants
tracker.STATUS_OBTAINED = 1;   -- won and in inventory
tracker.STATUS_DROPPED  = 2;   -- won but inventory full, item dropped
tracker.STATUS_LOST     = -1;  -- lost lot or expired
tracker.STATUS_ZONED    = -2;  -- lost because player zoned away

local source_labels = {
    [0] = 'Mob',
    [1] = 'Chest',
    [2] = 'Coffer',
    [3] = 'Crate',   -- Armoury Crate / Sturdy Pyxis. Reached only for a container OUTSIDE any
                     -- classified content; inside one, the feed shows the content instead.
};

function tracker.get_source_label(source_type, bf_difficulty)
    if (source_type == 3 and bf_difficulty ~= nil and bf_difficulty > 0) then
        return 'HTBF';
    end
    return source_labels[source_type] or 'Mob';
end

-- Vana'diel Weekday & Moon Phase Labels
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

-- Weather Labels (client memory values 0-19)
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

-- HTBF Difficulty Labels (from 0x005C num[2])
local difficulty_labels = {
    [1] = 'VD',
    [2] = 'D',
    [3] = 'N',
    [4] = 'E',
    [5] = 'VE',
    [6] = '?',
};

local difficulty_full_labels = {
    [1] = 'Very Difficult',
    [2] = 'Difficult',
    [3] = 'Normal',
    [4] = 'Easy',
    [5] = 'Very Easy',
    [6] = 'Unknown',
};

function tracker.get_difficulty_label(difficulty)
    return difficulty_labels[tonumber(difficulty)] or '';
end

function tracker.get_difficulty_full_label(difficulty)
    return difficulty_full_labels[tonumber(difficulty)] or '';
end

-- Inverse of difficulty_full_labels: maps chat text to difficulty number.
local chat_text_to_difficulty = {
    ['Very difficult'] = 1, ['Difficult'] = 2, ['Normal'] = 3,
    ['Easy'] = 4, ['Very easy'] = 5,
    -- Title-case variants (WoE HTBF entry text uses "Very Easy" not "Very easy")
    ['Very Difficult'] = 1, ['Very Easy'] = 5,
};

-- Action Type Labels (cmd_no from 0x0028 action packet)
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

-- Weather Memory Scan

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
        tracker.pending_warnings[#tracker.pending_warnings + 1] =
            'Weather signature not found - weather stats disabled (likely a client update).';
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

-- Helper: Capture current Vana'diel time snapshot
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

-- TH Gear Estimation (scans equipped gear against active TH profile)

-- Settings reference (set by tracker.set_settings)


-- Check buffs before TH and content helpers use them.
local function item_name_by_id(item_id)
    local res = AshitaCore:GetResourceManager();
    if (res == nil) then return 'Unknown'; end
    local item = res:GetItemById(item_id);
    if (item == nil or item.Name == nil) then return 'Unknown'; end
    return item.Name[1] or 'Unknown';
end

function has_buff(buff_id)
    local player = mem_player();
    if (player == nil) then return false; end
    local buffs = player:GetBuffs();
    if (buffs == nil) then return false; end
    for i = 0, 31 do
        if (buffs[i] == buff_id) then return true; end
    end
    return false;
end


-- Clear reused mob-ID kill state, but retain TH/engagement from the new life.
-- Consume TH only when recording its kill row; defeat may arrive after the current life's proc.
local function clear_stale_mob_state(sid)
    tracker.mob_kills[sid] = nil;
    tracker.mob_kill_times[sid] = nil;
    tracker.drop_sequence[sid] = nil;
    tracker.pet_to_master[sid] = nil;
    tracker.mob_names[sid] = nil;
end

-- Take this life's server TH (0x0028 msg 603) off the table: whatever lands next belongs to
-- the next life. Returns level (nil when none was seen) and the action that procced it.
local function consume_th(sid)
    local level, action = tracker.th_levels[sid], tracker.th_actions[sid];
    tracker.th_levels[sid] = nil;
    tracker.th_actions[sid] = nil;
    return level, action;
end


-- Battlefield Detection (BCNM name from chat, level cap from memory)

function tracker.handle_battlefield_text(msg)
    if (msg == nil or msg == '') then return; end

    if (msg:find('Now entering a skirmish', 1, true) ~= nil) then
        content.set_chat('Skirmish');
        return;
    end

    if (msg:find('Legion points', 1, true) ~= nil) then
        content.set_chat('Legion');
        return;
    end

    -- 1. BCNM/HTBF: "Entering the battlefield for X!"
    local bf_name = msg:match('Entering the battlefield for (.+)!');
    if (bf_name ~= nil) then
        -- Detect HTBF ★ prefix BEFORE stripping non-ASCII bytes.
        local has_star = bf_name:find('\129\154', 1, true) ~= nil;

        -- Strip non-ASCII bytes (FFXI control bytes, Shift-JIS fragments, auto-translate markers)
        bf_name = bf_name:gsub('[^ -~]', '');
        bf_name = bf_name:trim();
        if (bf_name == '') then return; end

        local player = mem_player();
        if (player == nil) then return; end

        battlefield.begin(bf_name, tracker.current_zone_id, 'chat');

        if (db ~= nil) then
            db.record_battlefield_entry(bf_name, tracker.current_zone_id, tracker.current_zone_name, os.time());
        end

        -- Use Vagary entry-text prefixes as a fallback to source-zone detection; its entry packet
        -- fields overlap ordinary BCNM fields.
        if (bf_name:sub(1, 8) == 'Vagary: ') then
            content.set_chat('Vagary');
        else
            content.set_chat('BCNM');
        end

        -- Fallback HTBF detection: ★ in the battlefield name indicates HTBF.
        -- ONLY consulted when 0x005C never arrived (addon loaded mid-battlefield).
        if (has_star and not tracker.htbf_packet_seen and tracker.htbf_info == nil) then
            tracker.htbf_info = {
                difficulty = DIFFICULTY_UNKNOWN,
                bf_name    = bf_name,
                source     = 'star',   -- chat fallback; only reached when 0x005C never arrived
            };
        end
        return;
    end

    -- WoE HTBF entry text precedes zoning from Selbina; retain it for the destination.
    -- Do not anchor the pattern: timestamp addons prepend text. Require the star-byte prefix.
    local entering_raw = msg:match('Entering (.+)%.');
    if (entering_raw ~= nil and (entering_raw:byte(1) or 0) > 127) then
        local clean = entering_raw:gsub('[^ -~]', ''):trim();
        if (clean ~= '') then
            -- Parse difficulty from name: "A Stygian Pact: Very Easy" → name, difficulty
            local name_part, diff_text = clean:match('^(.+):%s*(.+)$');
            if (name_part == nil) then name_part = clean; end

            local difficulty = DIFFICULTY_UNKNOWN;
            if (diff_text ~= nil) then
                difficulty = chat_text_to_difficulty[diff_text] or DIFFICULTY_UNKNOWN;
            end
            -- Packet-based difficulty (0x005C num[0]=1) overrides chat text if available
            if (tracker.pending_woe_difficulty ~= nil) then
                difficulty = tracker.pending_woe_difficulty;
                tracker.pending_woe_difficulty = nil;
            end

            tracker.pending_htbf_entry = {
                name       = name_part,
                difficulty = difficulty,
                timestamp  = os.time(),
            };
        end
        return;
    end

    -- 2. Level restriction: "<name>'s level is currently restricted to <N>."
    local cap = msg:match("level is currently restricted to (%d+)");
    if (cap ~= nil) then
        cap = tonumber(cap);
        if (cap ~= nil and cap > 0 and tracker.battlefield.active) then
            battlefield.set_level_cap(cap);
            if (db ~= nil) then
                db.update_battlefield_level_cap(cap);
            end
        end
        return;
    end

    -- 2b. HTBF difficulty from chat: "Current difficulty level: Very difficult."
    -- Refines the ★-detected fallback (difficulty=6 "Unknown") with the real value.
    if (tracker.htbf_info ~= nil and tracker.htbf_info.difficulty == DIFFICULTY_UNKNOWN) then
        local diff_text = msg:match('Current difficulty level: (.+)%.');
        if (diff_text ~= nil) then
            local d = chat_text_to_difficulty[diff_text];
            if (d ~= nil) then
                tracker.htbf_info.difficulty = d;
            end
            return;
        end
    end

    -- 3. Dynamis (original + Divergence):
    --    Original: "You will now be warped to Dynamis - Windurst."
    --    Divergence: "Entering Dynamis - Windurst [D]."
    --    Primary detection is zone-name based (check_zone / on_login),
    --    but entry text serves as a secondary signal.
    local dyna_name = msg:match('Entering (Dynamis %- .+)%.') or msg:match('warped to (Dynamis %- .+)%.');
    if (dyna_name ~= nil) then
        dyna_name = dyna_name:gsub('[^ -~]', ''):trim();
        content.set_chat('Dynamis');
        -- dyna_city is informational only (not consumed by UI)
        return;
    end
end

function tracker.check_battlefield_level_cap()
    if (not tracker.battlefield.cap_check_pending) then return; end

    local player = mem_player();
    if (player == nil) then return; end

    -- Compare capped main-job level with the uncapped job-table level.
    local main_job = player:GetMainJob();
    local current_level = player:GetMainJobLevel();
    local real_level = player:GetJobLevel(main_job);

    if (real_level > 0 and current_level > 0 and current_level < real_level) then
        battlefield.set_level_cap(current_level);
        if (db ~= nil) then
            db.update_battlefield_level_cap(current_level);
        end
    elseif (current_level > 0 and real_level > 0) then
        -- Both levels loaded but no cap detected — uncapped BCNM (KSNM, etc.)
        battlefield.clear_cap_check();
    end
    -- If levels are 0, client data hasn't loaded yet — keep pending for next frame
end

function tracker.check_battlefield_reconnect()
    if (tracker.battlefield.active) then return; end  -- already connected

    local player = mem_player();
    if (player == nil) then return; end

    -- Check for battlefield status effect (buff 254)
    if (not has_buff(254)) then return; end

    -- Recover session from DB
    if (db ~= nil and tracker.current_zone_id > 0) then
        local session = db.get_active_battlefield(tracker.current_zone_id);
        if (session ~= nil) then
            battlefield.restore(session.battlefield_name, session.zone_id, session.level_cap, 'reconnect');

            -- Set content_info so 0x0075 'Unknown Battlefield' doesn't overwrite.
            -- Covers WoE HTBFs on addon reload (0x0075 sends non-0x0001 modes).
            content.set_session('BCNM');
        end
    end
end

-- Mob Name Resolution (from chat messages when entity is out of range)
-- Uses a FIFO queue with per-kill drop counts so we know how many "You find"
-- chat messages to expect before advancing to the next pending kill.

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

    -- Evict stale pending resolutions so rapid defeats do not block newer entries.
    if (is_defeat_msg and entry.expected_msgs > 0 and entry.received_msgs == 0) then
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

-- Chest Event Detection


-- Private-server message IDs may differ from client DATs. Detect chest opens by interaction;
-- use message IDs only for failure labels. Prefer payout-confirmed IDs, then DATs, then shipped values.
tracker.chest_bases = {};   -- zone_id -> base learned from this server. Table, never reassigned.


-- Timestamp of last packet-handled chest event (prevents text_in duplicates)
tracker.chest_packet_handled_at = 0;


-- Packet handler: 0x001E (Item Quantity Update)
function tracker.handle_item_quantity_update(data)
    if (db == nil) then return; end
    if (#data < 10) then return; end

    local category   = sunpack('B', data, 0x08 + 1);
    local item_index = sunpack('B', data, 0x09 + 1);

    -- Only care about inventory (0) slot 0 (gil)
    if (category ~= 0 or item_index ~= 0) then return; end

    local new_qty = sunpack('I', data, 0x04 + 1);

    -- Always remember the last gil update (even without pending).
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

    -- Route remaining wallet gil through the shared battlefield rule.
    if (tracker.chest_unlock_pending == nil) then
        local gil_amount = (new_qty or 0) - snapshot_gil;
        if (gil_amount > 0) then gil.book_battlefield_gil(gil_amount); end
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

    containers.record_chest_gil(
        tracker.chest_unlock_pending.zone_id,
        tracker.chest_unlock_pending.zone_name,
        tracker.chest_unlock_pending.container_type,
        gil_amount,
        tracker.chest_unlock_pending.candidate_msg
    );
end

-- Packet handler: 0x0053 (systemMessage) — secondary chest gil detection
--
-- Packet structure:
--   0x04: uint32 para   (amount for OBTAINS_GIL)
--   0x08: uint32 para2  (unused, 0)
--   0x0C: uint16 Number (MsgStd message ID; 19 = OBTAINS_GIL)
local MSGSTD_OBTAINS_GIL = 19;

function tracker.handle_system_message(data)
    if (db == nil) then return; end
    if (#data < 14) then return; end  -- need at least through offset 0x0C+2

    local msg_id = sunpack('H', data, 0x0C + 1);
    if (msg_id ~= MSGSTD_OBTAINS_GIL) then return; end

    local amount = sunpack('I', data, 0x04 + 1);
    if (amount == nil or amount <= 0) then return; end

    if (tracker.last_gil_update == nil) then
        tracker.last_gil_update = {
            prev_gil = 0,
            new_qty  = amount,
            time     = os.clock(),
            from_0x0053 = true,
        };
    end

    -- Route remaining wallet gil through the shared battlefield rule.
    if (tracker.chest_unlock_pending == nil) then
        gil.book_battlefield_gil(amount);
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

    containers.record_chest_gil(
        tracker.chest_unlock_pending.zone_id,
        tracker.chest_unlock_pending.zone_name,
        tracker.chest_unlock_pending.container_type,
        amount,
        tracker.chest_unlock_pending.candidate_msg
    );
end


-- Stale Resolve Cleanup (proactive, called from d3d_present)

function tracker.cleanup_stale_resolves()
    if (#tracker.pending_mob_resolves == 0) then return; end
    local now = os.clock();
    while (#tracker.pending_mob_resolves > 0 and now - tracker.pending_mob_resolves[1].time > 30) do
        table.remove(tracker.pending_mob_resolves, 1);
    end
end

-- Initialization

function tracker.init(db_ref, config_path)
    db = db_ref;
    th.set_db(db_ref);
    gil.set_db(db_ref);
    containers.set_db(db_ref);
    base_path = config_path;
end

-- DAT-Based Entity Name Lookup

local function load_zone_dat(zone_id)
    tracker.dat_names = {};

    local file_path = nil;
    local dat_file = nil;

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

    if (dat_file ~= nil) then
        dat_file:close();
    end
end

-- Voidwatch / Domain Invasion Helpers
-- (has_buff defined earlier near TH scanning; wrappers here for readability)

local function has_voidwatcher_buff() return has_buff(475); end  -- Active during VW cycle
local function has_elvorseal_buff()   return has_buff(603); end  -- Active during Domain Invasion
local function has_battlefield_buff()  return has_buff(EFFECT_BATTLEFIELD); end  -- inside ANY battlefield

local function content_source_for(ct)
    local by = content.resolved_by();
    if (by == nil and (ct or '') ~= '') then return 'buff'; end
    return by or '';
end

function stamp_provenance(ki)
    ki.previous_zone_id = tracker.previous_zone_id or 0;
    ki.entry_zone_id    = content.state.entry_zone or 0;
    ki.content_source   = content_source_for(ki.content_type);
end
local function has_reive_mark_buff()  return has_buff(511); end  -- Active during Reive


-- Forward declaration (defined later, needed by is_party_or_alliance_kill)
local find_pet_owner;

-- Check if a killer server ID belongs to any party/alliance member (or their pet).
local function party_has_sid(party, sid)
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) == 1) then
            if (unsigned_sid(party:GetMemberServerId(i)) == sid) then return true; end
        end
    end
    return false;
end

local function is_party_or_alliance_kill(killer_sid, killer_tidx)
    local party = mem_party();
    if (party == nil) then return false; end

    -- Check all 18 party/alliance slots (0 = self, 1-5 = party, 6-17 = alliance)
    if (party_has_sid(party, killer_sid)) then return true; end

    -- Check if killer is a pet of a party/alliance member
    if (killer_tidx ~= nil and killer_tidx > 0) then
        local entity = mem_entity();
        if (entity ~= nil) then
            local owner_tidx = find_pet_owner(killer_tidx);
            if (owner_tidx ~= nil) then
                local owner_sid = unsigned_sid(entity:GetServerId(owner_tidx));
                if (owner_sid ~= nil) then
                    return party_has_sid(party, owner_sid);
                end
            end
        end
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
        db.update_drop_won(vw.kill_id, slot, won_value, 0, nil, vw.drop_ids and vw.drop_ids[slot]);
    end

    vw.items_captured = false;
    vw.kill_id = nil;
    vw.offered = {};
    vw.drop_ids = {};
end

-- Finalize pending Voidwatch rewards if the buff ends without a closing 0x05B.
function tracker.check_voidwatch_buff()
    if (not tracker.voidwatch.items_captured) then return; end
    if (tracker.voidwatch.kill_id == nil) then return; end
    if (not has_voidwatcher_buff()) then
        finalize_vw_interaction();
    end
end

-- Identify the Reive kind from participation or victory text. Colonization/Lair entry wording
-- is inferred; without a matching line, keep the generic Reive label.
function tracker.handle_reive_text(text)
    local kind = text:match('participate in the (%a+) Reive') or text:match('joined the (%a+) Reive')
              or text:match('victorious in the (%a+) Reive');
    if (kind ~= nil) then
        tracker.wildskeeper.kind = kind;
        tracker.wildskeeper.last_kind = kind;   -- survives the Mark loss for the spoils row
    end
end

function tracker.check_reive_buff()
    local has_mark = has_reive_mark_buff();
    if (has_mark and not tracker.wildskeeper.active) then
        -- Entered a Reive (or addon reloaded while in one)
        tracker.wildskeeper.active = true;

        -- Reload recovery: check DB for recent Wildskeeper kill in this zone
        if (tracker.wildskeeper.last_kill_id == nil and tracker.current_zone_id ~= 0) then
            local recent = db.find_recent_wildskeeper_kill(tracker.current_zone_id, 120);
            if (recent) then
                tracker.wildskeeper.last_kill_id = recent.kill_id;
                tracker.wildskeeper.last_boss_name = recent.mob_name;
            end
        end
    elseif (not has_mark and tracker.wildskeeper.active) then
        -- Retain the kind and end time briefly so delayed spoils and victory text can finish the run.
        tracker.wildskeeper.active = false;
        tracker.wildskeeper.mark_off_at = os.clock();
        tracker.wildskeeper.last_kind = tracker.wildskeeper.kind;
        tracker.wildskeeper.kind = nil;
        tracker.wildskeeper.last_boss_name = nil;
        tracker.wildskeeper.last_boss_sid = nil;
        tracker.wildskeeper.last_kill_id = nil;
        tracker.wildskeeper.last_kill_time = 0;
    end
end

-- Zone Change Detection

function tracker.check_zone()
    local party = mem_party();
    if (party == nil) then return; end

    local zone_id = party:GetMemberZone(0);
    if (zone_id == tracker.current_zone_id) then return; end

    -- Initial zone detection (0 → actual)
    local is_real_zone_change = (tracker.current_zone_id ~= 0);

    if (is_real_zone_change) then
        -- Zone changed: mark any pending pool items as Zoned (server won't send
        -- 0x00D3 when the pool is destroyed by zoning)
        if (db ~= nil and db.conn ~= nil) then
            for slot, entry in pairs(tracker.active_pool) do
                if (entry.kill_id ~= nil) then
                    db.update_drop_won(entry.kill_id, slot, tracker.STATUS_ZONED, 0, nil, entry.drop_id);
                end
            end
        end

        if (tracker.battlefield.active) then
            if (db ~= nil) then
                db.end_battlefield_session(os.time());
            end
            battlefield.exit();
        end

        th.clear_th_state();
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
        -- Write out held gil BEFORE dropping the queue it is attributed against: the player
        -- already has this gil, and a zone change must not silently lose it.
        gil.flush_mob_gil(true);
        tracker.mob_gil_queue = {};
        tracker.pending_mob_gil = {};
        tracker.mob_gil_hold = {};
        tracker.htbf_info = nil;
        tracker.htbf_packet_seen = false;   -- next battlefield must not inherit this determination
        tracker.last_interact = nil;
        finalize_vw_interaction();
        tracker.voidwatch.pyxis_active = false;
        tracker.voidwatch.last_vw_kill = nil;
        tracker.wildskeeper.active = false;
        tracker.wildskeeper.last_boss_name = nil;
        tracker.wildskeeper.last_boss_sid = nil;
        tracker.wildskeeper.last_kill_id = nil;
        tracker.wildskeeper.last_kill_time = 0;
        content.clear_for_zone(zone_id, tracker.current_zone_id, true);
        cached_player_sid = nil;
    end

    tracker.previous_zone_id = tracker.current_zone_id;
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

    -- Dynamis (zone-name prefix) then INSTANCE_ZONES. Runs before WoE HTBF restoration.
    content.set_zone_from(zone_id, tracker.current_zone_name);

    -- Clear unconsumed pre-entry difficulty on zoning; aborted entries must not label the next run.
    tracker.pending_woe_difficulty = nil;

    -- WoE HTBF: restore pending battlefield state from before zone change.
    if (tracker.pending_htbf_entry ~= nil) then
        local p = tracker.pending_htbf_entry;
        tracker.pending_htbf_entry = nil;  -- consume (one-shot)

        -- Restore recent held entries only in WoE P1/P2; zoning elsewhere must discard them.
        if ((os.time() - p.timestamp <= 300) and (zone_id == 279 or zone_id == 298)) then
            battlefield.begin(p.name, zone_id, 'pending_entry');

            if (db ~= nil) then
                db.record_battlefield_entry(p.name, zone_id, tracker.current_zone_name, os.time());
            end

            content.set_chat('BCNM');
            tracker.htbf_info = {
                difficulty = p.difficulty,
                bf_name    = p.name,
                source     = 'woe',    -- Walk of Echoes pending entry restored across the zone
            };
        end
    end

    -- Odyssey: entered from Rabao (247) into WoE P1/P2 (279/298).
    if (content.resolve() == '') then
        local prev = tracker.previous_zone_id;

        content.set_source_from(zone_id, prev);
    end
end

-- Helper: Get entity name by target index

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

-- Helper: Read treasure pool item from client memory

-- Normalize memory Lot=0xFFFF to no roll; it does not distinguish a pass from no lot round.
local LOT_MAX = 999;

local function player_roll(v)
    v = tonumber(v) or 0;
    if (v < 1 or v > LOT_MAX) then return 0; end
    return v;
end

-- Resolve battlefield provenance from packet, chat or the active session's entry source.
function tracker.current_bf_source()
    if (tracker.htbf_info ~= nil and tracker.htbf_info.source) then return tracker.htbf_info.source; end
    if (tracker.htbf_packet_seen) then return 'packet'; end
    if (battlefield.is_active() and battlefield.state.entered_via) then return battlefield.state.entered_via; end
    return '';
end

-- Use 0x005C tier/name/source only with an active battlefield session. Other content can
-- send the same event fields without having difficulty tiers.
local function packet_battlefield_fields()
    if (not battlefield.is_active()) then return nil, 0, ''; end
    local info = tracker.htbf_info;
    return info and info.bf_name or nil, info and info.difficulty or 0, tracker.current_bf_source();
end


-- Reject implausibly large gil values to avoid recording a misread packet field.

local MSG_OBTAINS_GIL  = 565;   -- msg_basic.h `Obtains`; LSB DistributeGil sends this on a kill
local MSG_OBTAINS_TABS = 566;   -- FOV_OBTAINS_TABS -- its presence means the 565 was a regime pay


-- A 566 cancels only the immediately preceding 565 if it was held; never cancel an older pending entry.


local function get_pool_item_info(slot)
    local inv = mem_inventory();
    if (inv == nil) then return nil; end

    local pool_item = inv:GetTreasurePoolItem(slot);
    if (pool_item == nil or pool_item.ItemId == 0) then return nil; end

    -- Resolve item name from resource manager
    local item_name = item_name_by_id(pool_item.ItemId);

    return {
        item_id             = pool_item.ItemId,
        item_name           = item_name,
        count               = pool_item.Count or 1,
        lot                 = player_roll(pool_item.Lot),
        winning_lot         = player_roll(pool_item.WinningLot),
    };
end

-- Helper: Classify container source type from entity name


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
                return containers.classify_container_by_name(entity_name);
            end
        end
    end

    if (entity_name == nil) then return tracker.SOURCE_MOB; end
    return containers.classify_container_by_name(entity_name);
end

-- Helper: Check if an entity is a pet of another mob

find_pet_owner = function(target_index)
    if (target_index == nil or target_index <= 0) then return nil; end

    local ok, result = pcall(function()
        local mem = AshitaCore:GetMemoryManager();
        if (mem == nil) then return nil; end
        local entity = mem:GetEntity();
        if (entity == nil) then return nil; end

        for i = 1024, 1791 do
            if (i ~= target_index) then
                if (entity:GetRenderFlags0(i) ~= 0) then
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

-- Character Detection (deferred DB init)

function tracker.check_character()
    if (base_path == nil) then return; end
    -- Backoff after a failed db.init (see the retry block at the bottom of this function).
    if (tracker.init_retry_at ~= nil) then
        if (os.clock() < tracker.init_retry_at) then return; end
        tracker.init_retry_at = nil;
    end

    if (not settings.logged_in) then return; end
    local name      = settings.name;
    local server_id = settings.server_id;
    if (name == nil or name == '' or server_id == nil or server_id == 0) then return; end

    -- Compare-and-swap instead of a one-way latch, so logging out and back in as a DIFFERENT
    -- character rebinds to that character's database instead of writing into the previous one.
    local want_folder = name .. '_' .. tostring(server_id);
    if (want_folder == tracker.char_folder) then return; end

    -- Wait until actually in a zone (not character select screen).
    local party = mem_party();
    if (party == nil) then return; end
    local zone_id = party:GetMemberZone(0);
    if (zone_id == nil or zone_id == 0) then return; end

    -- CHARACTER SWITCH: about to rebind to a different database file.
    if (tracker.char_folder ~= nil) then
        if (db ~= nil and db.conn ~= nil) then
            for slot, entry in pairs(tracker.active_pool) do
                if (entry.kill_id ~= nil) then
                    pcall(function()
                        db.update_drop_won(entry.kill_id, slot, tracker.STATUS_ZONED, 0, nil, entry.drop_id);
                    end);
                end
            end
            if (tracker.battlefield.active) then
                pcall(function() db.end_battlefield_session(os.time()); end);
            end
            -- close_character, NOT close: db.close() also drops th_conn, which is opened once at load
            pcall(db.close_character);
        end

        -- Clear exactly the state check_zone would otherwise write with. The rest of its clears are
        -- write-free, so letting them run afterwards on the new character is harmless.
        tracker.active_pool = {};
        battlefield.exit();
        tracker.htbf_info = nil;
        tracker.htbf_packet_seen = false;
        content.reset();

        -- _init_failed describes ONE database file, not the session.
        if (db ~= nil) then db._init_failed = false; end
    end

    tracker.char_name = name;
    tracker.char_folder = want_folder;

    -- Set zone_id early so check_battlefield_reconnect() can query DB by zone.
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

    if (db.init(base_path, tracker.char_folder) == false) then
        tracker.char_folder   = nil;
        tracker.char_name     = nil;
        db._init_failed       = false;
        tracker.init_retry_at = os.clock() + 10;
        return;
    end

    tracker.scan_pool();
    init_weather_pointer();
    tracker.check_battlefield_reconnect();

    if (tracker.current_zone_id > 0) then
        content.set_zone_from(tracker.current_zone_id, tracker.current_zone_name);
    end
end

-- Pool Scan: Recover pool items from client memory (addon reload / late join)

function tracker.scan_pool()
    if (db == nil or db.conn == nil) then return; end

    -- Flush any uncommitted transaction before scanning
    db.flush_pending();

    -- Guard: only scan if treasure pool is loaded in client memory
    local pool_ok, pool_status = pcall(function()
        local inv = mem_inventory();
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
                        player_action = (info.lot > 0) and ACTION_LOTTED or ACTION_NONE,
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
                        player_action = (info.lot > 0) and ACTION_LOTTED or ACTION_NONE,
                        highest_lot   = info.winning_lot,
                        late_join     = true,
                        source_type   = tracker.SOURCE_MOB,
                    };
                end
                scanned = scanned + 1;
            end
        end
    end

end

-- Packet: 0x0029 - Battle Message (kill detection)

function tracker.handle_defeat(data)
    if (db == nil) then return; end
    if (#data < 26) then return; end

    local killer_id    = sunpack('I', data, 0x04 + 1);  -- caster/killer server ID
    local mob_sid      = sunpack('I', data, 0x08 + 1);  -- target server ID
    local killer_tidx  = sunpack('H', data, 0x14 + 1);  -- caster target index (ActIndexCas)
    local mob_tidx     = sunpack('H', data, 0x16 + 1);  -- target index
    local message_id   = sunpack('H', data, 0x18 + 1);  -- message ID

    -- msg_id=37: "too far from battle to gain experience" — distant party kill.
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

    -- Mob gil has two carriers: retail pool Gold and LandSandBoat message 565.
    -- Hold 565 briefly; a following 566 cancels a Fields of Valor reward. Initialize shared pending state
    -- once.
    if (tracker.pending_mob_gil == nil) then tracker.pending_mob_gil = {}; end
    if (message_id == MSG_OBTAINS_TABS) then gil.on_tabs(killer_id); return; end
    if (message_id == MSG_OBTAINS_GIL) then gil.on_obtains(killer_id, data); return; end

    if (message_id ~= 6) then return; end

    -- Filter out non-mob entities: PCs (1024-1791) and trusts/pets (1792-2303).
    -- Only NPC/mob entities (0-1023) should be recorded as kills.
    if (mob_tidx >= 1024) then return; end

    -- Credit engaged mobs, party/alliance killing blows (including pets), or the Domain Invasion boss
    -- while Elvorseal is active. Pre-wave mobs still require normal attribution.
    local dominated = tracker.engaged_mobs[mob_sid];
    if (not dominated) then
        if (not is_party_or_alliance_kill(killer_id, killer_tidx)) then
            local di_boss = classify.DOMAIN_INVASION_ZONES[tracker.current_zone_id]
                and has_elvorseal_buff()
                and classify.DOMAIN_INVASION_NM_NAMES[tracker.mob_names[mob_sid] or get_entity_name(mob_tidx)];
            if (not di_boss) then return; end
        end
    end

    -- Server ID reuse.
    if (tracker.mob_kills[mob_sid] ~= nil) then
        local kill_time = tracker.mob_kill_times[mob_sid] or 0;
        if ((os.clock() - kill_time) < 5.0) then
            -- Recent kill: 0x00D2 fallback already created this kill record.
            local existing_kill = tracker.mob_kills[mob_sid];
            if (existing_kill ~= nil) then
                -- The pool path may already have recorded (and consumed) this life's TH into the
                -- row; patch_kill_on_defeat never lowers what the row holds.
                local th_level, th_action = consume_th(mob_sid);
                local killer_name = '';
                if (killer_tidx > 0) then
                    local kn = get_entity_name(killer_tidx);
                    if (kn ~= 'Unknown') then killer_name = kn; end
                end
                local ct = classify.from_buffs(tracker.get_content_type(),
                    tracker.mob_names[mob_sid] or get_entity_name(mob_tidx), {
                        zone_id            = tracker.current_zone_id,
                        wildskeeper_active = tracker.wildskeeper.active, reive_kind = tracker.wildskeeper.kind,
                        has_voidwatcher    = has_voidwatcher_buff,
                        has_elvorseal      = has_elvorseal_buff,
                        has_battlefield    = has_battlefield_buff,
                    });
                db.patch_kill_on_defeat(existing_kill, {
                    killer_id      = killer_id,
                    killer_name    = killer_name,
                    th_level       = th_level,
                    th_action_type = th_action and th_action.cmd_no or 0,
                    th_action_id   = th_action and th_action.cmd_arg or 0,
                    th_estimated   = tracker.th_estimated[mob_sid] or 0,
                    content_type   = ct,
                    content_source = content_source_for(ct),
                });
                gil.queue_kill_for_gil(existing_kill, mob_sid,
                    tracker.mob_names[mob_sid] or get_entity_name(mob_tidx));
                -- Wire Reive loot attribution for the drop-before-defeat race (mirror the main path)
                if (ct == 'Wildskeeper') then
                    tracker.wildskeeper.last_boss_name = tracker.mob_names[mob_sid] or get_entity_name(mob_tidx);
                    tracker.wildskeeper.last_boss_sid = mob_sid;
                    tracker.wildskeeper.last_kill_id = existing_kill;
                    tracker.wildskeeper.last_kill_time = os.clock();
                end
            end
            return;
        end
        -- Old kill (server ID reuse from mob respawn) — clear stale state.
        clear_stale_mob_state(mob_sid);
    end

    -- Pet detection: if this defeated entity is a pet of another mob,
    -- don't create a standalone kill record.
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

    -- Consumed here: the record site owns this life's TH.
    local th_level, th_action = consume_th(mob_sid);
    th_level = th_level or 0;

    -- Resolve killer name using caster target index from packet
    local killer_name = '';
    if (killer_tidx > 0) then
        local kn = get_entity_name(killer_tidx);
        if (kn ~= 'Unknown') then killer_name = kn; end
    end

    local vana_info = capture_vana_info();

    -- Resolve buff-based content using the current mob name before falling back to entry/zone evidence.
    local ct = classify.from_buffs(tracker.get_content_type(), mob_name, {
        zone_id            = tracker.current_zone_id,
        wildskeeper_active = tracker.wildskeeper.active, reive_kind = tracker.wildskeeper.kind,
        has_voidwatcher    = has_voidwatcher_buff,
        has_elvorseal      = has_elvorseal_buff,
        has_battlefield    = has_battlefield_buff,
    });

    local pbf_name, pbf_tier, pbf_source = packet_battlefield_fields();
    local ki = {
        killer_id      = killer_id,
        killer_name    = killer_name,
        th_action_type = th_action and th_action.cmd_no or 0,
        th_action_id   = th_action and th_action.cmd_arg or 0,
        bf_name        = pbf_name,
        bf_difficulty  = pbf_tier,
        bf_source      = pbf_source,
        content_type   = ct,
        th_estimated   = tracker.th_estimated[mob_sid] or 0,
    };
    stamp_provenance(ki);

    -- Tag mob kills inside an active battlefield so the UI can show [BCNM]/[HTBF]
    if (battlefield.is_active()) then
        ki.battlefield = battlefield.name();
        ki.level_cap = battlefield.level_cap();
    else
        ki.battlefield = containers.woe_walk_name();   -- "Walk #N" inside a Walk of Echoes, else nil
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

    -- Clean up engagement tracking for defeated mob
    tracker.engaged_mobs[mob_sid] = nil;

    -- Track VW kill directly so handle_event_begin doesn't need to scan
    if (ct == 'Voidwatch') then
        tracker.voidwatch.last_vw_kill = kill_id;
    end

    -- Track Wildskeeper Reive Naakual kill for 0x034 Event 2007 loot attribution
    if (ct == 'Wildskeeper') then
        tracker.wildskeeper.last_boss_name = mob_name;
        tracker.wildskeeper.last_boss_sid = mob_sid;
        tracker.wildskeeper.last_kill_id = kill_id;
        tracker.wildskeeper.last_kill_time = os.clock();
    end

    -- Queue this kill for mob gil detection.
    gil.queue_kill_for_gil(kill_id, mob_sid, mob_name);

    if (mob_name == 'Unknown' and kill_id ~= nil) then
        set_pending_mob_resolve(mob_sid, kill_id);
    end
end

-- Packet: 0x00D2 - Treasure Pool Item (drop appears)

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

    -- Process gil before the item guard: gil-only packets have item_id == 0.
    local gold = sunpack('H', data, 0x0C + 1);
    if (gold ~= nil and gold > 0) then
        gil.record_mob_gil(mob_sid, gold);
    end

    if (item_id == 0) then return; end
    if (pool_slot > tracker.POOL_MAX_SLOT) then return; end

    -- Clear chest unlock pending state — item came through normal treasure pool
    -- so this is NOT a gil-only chest (cancel the two-phase gil detection).
    if (is_container == 1 and is_old == 0 and tracker.chest_unlock_pending ~= nil) then
        tracker.chest_unlock_pending = nil;
    end

    -- is_old=1: Pool refresh (joining party, opening pool, addon reload).
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
                player_action = ACTION_NONE,
                late_join     = false,
            };
            return;
        end

        -- No DB match: create late_join stub instead of falling through to
        -- create new DB records with current timestamps.
        local item_name = item_name_by_id(item_id);
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
            player_action = ACTION_NONE,
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
    if (source_type == tracker.SOURCE_BCNM and not battlefield.is_active()) then
        -- Recover the name from the DB session if there is one, else fall back to the zone name.
        local rec_name, rec_cap = battlefield.name(), battlefield.level_cap();
        if (db ~= nil and tracker.current_zone_id > 0) then
            local session = db.get_active_battlefield(tracker.current_zone_id);
            if (session ~= nil) then
                rec_name = session.battlefield_name;
                rec_cap  = session.level_cap;
            end
        end
        -- Use the packet-resolved battlefield name if available; never substitute the zone name.
        if (rec_name == nil and tracker.htbf_info ~= nil) then rec_name = tracker.htbf_info.bf_name; end
        battlefield.recover(rec_name, tracker.current_zone_id, rec_cap, 'chest_recovery');
    end

    -- Read, not consumed: only the record site below (a NEW row) consumes it; an existing row's
    -- defeat already did, or will.
    local th_level = tracker.th_levels[effective_sid] or 0;
    -- Store the proc action with its TH level before either is consumed by a pool-first kill.
    local th_action = tracker.th_actions[effective_sid];

    -- Server ID reuse guard.
    local kill_id = tracker.mob_kills[effective_sid];
    if (kill_id ~= nil) then
        local kill_time = tracker.mob_kill_times[effective_sid] or 0;
        if ((os.clock() - kill_time) > 5.0 and is_old == 0) then
            clear_stale_mob_state(effective_sid);
            kill_id = nil;
        end
    end

    -- Use existing kill record from 0x0029 defeat, or create one for
    -- containers/chests that don't send defeat messages, or late-join pool items
    if (kill_id == nil and source_type == tracker.SOURCE_MOB and pet_info == nil) then
        -- Check if this entity is a pet whose 0x0029 defeat hasn't arrived yet.
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
        local ki = {
            th_estimated   = tracker.th_estimated[effective_sid] or 0,
            th_action_type = th_action and th_action.cmd_no or 0,
            th_action_id   = th_action and th_action.cmd_arg or 0,
        };
        -- Tag containers by the active battlefield, not source type; Trove rewards use coffers, not crates.
        if (battlefield.is_active()) then
            ki.battlefield = battlefield.name();
            ki.level_cap = battlefield.level_cap();
        else
            ki.battlefield = containers.woe_walk_name();   -- "Walk #N" inside a Walk of Echoes, else nil
        end
        -- Pool-before-defeat implies distant drops only outside battlefields; inside an arena it is packet
        -- ordering.
        if (is_old == 0 and source_type == tracker.SOURCE_MOB and not battlefield.is_active()) then
            ki.is_distant = 1;
        end
        -- Attach HTBF info if active
        ki.bf_name, ki.bf_difficulty, ki.bf_source = packet_battlefield_fields();
        -- Apply the same buff fallback as defeat handling; crate rows never receive a defeat packet.
        local ct = classify.from_buffs(tracker.get_content_type(), mob_name, {
            zone_id            = tracker.current_zone_id,
            wildskeeper_active = tracker.wildskeeper.active, reive_kind = tracker.wildskeeper.kind,
            has_voidwatcher    = has_voidwatcher_buff,
            has_elvorseal      = has_elvorseal_buff,
            has_battlefield    = has_battlefield_buff,
        });
        ki.content_type   = ct;
        ki.content_source = content_source_for(ct);
        stamp_provenance(ki);
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
        consume_th(effective_sid);   -- this life's TH is in the row now
        tracker.mob_kills[effective_sid] = kill_id;
        tracker.mob_kill_times[effective_sid] = os.clock();
        tracker.drop_sequence[effective_sid] = 0;

        -- Track last BCNM kill_id so 0x001E/0x0053 can attach gil to it
        if (source_type == tracker.SOURCE_BCNM and kill_id ~= nil) then
            battlefield.note_kill(kill_id);
            gil.flush_battlefield_gil(kill_id);   -- 0x001E/0x0053 arrived before this 0x00D2
        end

        -- Flag for chat-based name resolution if entity was out of range
        if (mob_name == 'Unknown' and kill_id ~= nil) then
            set_pending_mob_resolve(effective_sid, kill_id);
        end

        -- Credit: 0x00D2 without prior defeat = distant kill with drops.
        if (is_old == 0 and source_type == tracker.SOURCE_MOB) then
            tracker.distant_kill_credits = tracker.distant_kill_credits + 1;
        end
    end

    if (kill_id == nil) then return; end

    local item_name = item_name_by_id(item_id);

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
        player_action = ACTION_NONE,
    };

end

-- Packet: 0x00D3 - Trophy Solution (lot/win result)

function tracker.handle_lot_result(data)
    if (db == nil) then return; end
    if (#data < 54) then return; end

    -- Full 0x00D3 packet layout:
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
    if (pool_slot > tracker.POOL_MAX_SLOT) then return; end
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

    -- judge_flag == 0 is a "someone lotted/passed" notification (no final result).
    if (judge_flag == 0) then
        local pool_entry = tracker.active_pool[pool_slot];

        -- No pool entry: item was in pool before addon loaded (reload, late join).
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
                player_action = ACTION_NONE,
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
            pool_entry.player_action = (entry_flg == 1) and ACTION_LOTTED or ACTION_PASSED;
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

    -- Late-join stub: no DB records exist yet.
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
        local ki = {};
        stamp_provenance(ki);
        local kill_id = db.record_kill(
            'Unknown (late join)',
            0,
            tracker.current_zone_id,
            tracker.current_zone_name,
            0,
            pool_entry.source_type or tracker.SOURCE_MOB,
            vana_info, ki
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
                pool_entry.player_action = ACTION_LOTTED;
            end
        end
    end

    local winner_name = loot_name;
    local winner_id   = loot_id;

    -- Pass drop_id so the result lands on THIS item only.
    db.update_drop_won(pool_entry.kill_id, pool_slot, status, final_lot, {
        winner_id     = winner_id,
        winner_name   = winner_name,
        player_lot    = pool_entry.player_lot or 0,
        player_action = pool_entry.player_action or ACTION_NONE,
    }, pool_entry.drop_id);

    -- Clear pool slot (only on final result, never on lot notifications)
    tracker.active_pool[pool_slot] = nil;
end

-- Packet: 0x0028 - Action (TH proc detection)

function tracker.handle_action(data)
    if (#data < 19) then return; end  -- minimum: 5-byte offset + 110 bits of header fields
    local reader = breader:new();
    -- Parse a byte table to avoid tohex concatenation and regex allocations on frequent action packets.
    local bytes = {};
    for i = 1, #data do bytes[i] = data:byte(i); end
    reader:set_data(bytes);
    reader:set_pos(5);

    local actor_id   = reader:read(32);
    local trg_sum    = reader:read(6);
    local _res_sum   = reader:read(4);
    local _cmd_no    = reader:read(4);
    local _cmd_arg   = reader:read(32);
    local _info      = reader:read(32);

    -- Normalize actor_id to unsigned for comparison
    actor_id = unsigned_sid(actor_id);

    -- Check if this is the local player's offensive action.
    local is_self_offensive = false;
    if (_cmd_no >= 1 and _cmd_no <= 6) then
        -- Lazy-init cached player SID
        if (cached_player_sid == nil) then
            local mem = AshitaCore:GetMemoryManager();
            if (mem ~= nil) then
                local entity = mem:GetEntity();
                local party = mem:GetParty();
                if (entity ~= nil and party ~= nil) then
                    local my_sid = unsigned_sid(entity:GetServerId(party:GetMemberTargetIndex(0)));
                    if (my_sid ~= nil and my_sid ~= 0) then
                        cached_player_sid = my_sid;
                    end
                end
            end
        end
        is_self_offensive = (cached_player_sid ~= nil and actor_id == cached_player_sid);
    end

    for _t = 0, trg_sum - 1 do
        local target_id  = reader:read(32);

        target_id = unsigned_sid(target_id);

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

        -- Kill attribution: always track engaged mobs (Tier 1 of kill filter).
        if (is_self_offensive) then
            tracker.engaged_mobs[target_id] = true;
        end

        th.on_action(target_id, actor_id, is_self_offensive, _cmd_no);   -- TH estimation (th.lua)
    end
end

-- Packet: 0x005C - GP_SERV_COMMAND_PENDINGNUM (HTBF entry detection)
-- 8 x int32 params starting at offset 0x04.

function tracker.handle_pending_num(data)
    if (#data < 36) then return; end  -- need at least 8 uint32s (32 bytes) + 4 header

    local num0 = sunpack('I', data, 0x04 + 1);

    -- Hold difficulty from pre-entry num[0]=1 or 4; the starred WoE entry text consumes it.
    -- Unrelated values expire on zoning.
    if (num0 == 1 or num0 == 4) then
        local difficulty = sunpack('I', data, 0x0C + 1);
        if (difficulty >= 1 and difficulty <= 5) then
            tracker.pending_woe_difficulty = difficulty;
        end
        return;
    end

    if (num0 ~= 2) then return; end  -- only standard HTBF entry events

    local bit_pos    = sunpack('I', data, 0x08 + 1);
    local difficulty = sunpack('I', data, 0x0C + 1);

    if (difficulty >= 0 and difficulty <= 5) then
        tracker.htbf_packet_seen = true;
    end

    -- Accept difficulty 0-5: zero is BCNM, 1-5 HTBF. Reject unrelated values such as Sortie's 0xFF.
    if (difficulty > 5) then return; end

    -- Resolve battlefield name from zone dialog DAT
    local bf_name = nil;
    if (datreader ~= nil and tracker.current_zone_id > 0) then
        bf_name = datreader.get_battlefield_name(tracker.current_zone_id, bit_pos);
        -- Strip star and auto-translate bytes before storing names; statistics read the raw field.
        if (bf_name ~= nil) then bf_name = bf_name:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', ''); end
    end

    tracker.htbf_info = {
        difficulty = difficulty,
        bf_name    = bf_name,
        source     = 'packet', -- 0x005C, authoritative
    };
end

-- Packet: 0x034 (S2C) - GP_SERV_COMMAND_EVENTNUM (Voidwatch Pyxis loot)
-- Riftworn Pyxis sends item IDs in params[0-7] as int32.
-- First 0x034: record all offered items. Subsequent: detect taken items.

function tracker.handle_event_begin(data)
    if (db == nil) then return; end
    if (#data < 0x34) then return; end

    -- Wildskeeper Reive: Event 2007 delivers items in num[1..3]
    -- Items go directly to inventory — all are auto-obtained (won=1)
    local event_num = sunpack('H', data, 0x2A + 1);
    if (event_num == 2007) then
        local kill_id = tracker.wildskeeper.last_kill_id;

        -- Fallback: recover kill_id from DB after addon reload
        if (kill_id == nil and tracker.wildskeeper.active) then
            local recent = db.find_recent_wildskeeper_kill(tracker.current_zone_id, 120);
            if (recent) then
                kill_id = recent.kill_id;
            end
        end

        if (kill_id ~= nil) then
            -- Read 8 int32 params at offset 0x08
            local params = {};
            for i = 0, 7 do
                local val = sunpack('i', data, 0x08 + (i * 4) + 1);
                params[i] = (val ~= nil and val > 0 and val < 65536) and val or 0;
            end

            local slot = 0;

            -- Params 1-3 contain item IDs (param 0 is a flag/count)
            for i = 1, 3 do
                if (params[i] > 0) then
                    local item_name = item_name_by_id(params[i]);
                    db.record_drop(kill_id, slot, params[i], item_name, 1, 1);  -- won=1 (auto-obtained)
                    slot = slot + 1;
                end
            end

            -- Clear after capturing — one Event 2007 per kill
            tracker.wildskeeper.last_kill_id = nil;
            return;
        end
    end

    -- Voidwatch: Riftworn Pyxis loot (existing handler)
    if (not tracker.voidwatch.pyxis_active) then return; end

    local npc_sid = sunpack('I', data, 0x04 + 1);
    if (npc_sid ~= tracker.voidwatch.pyxis_sid) then return; end

    -- Read 8 int32 params at offset 0x08
    local params = {};
    for i = 0, 7 do
        local val = sunpack('i', data, 0x08 + (i * 4) + 1);
        params[i] = (val ~= nil and val > 0 and val < 65536) and val or 0;
    end

    if (not tracker.voidwatch.items_captured) then
        -- FIRST 0x034: Record all offered items (won=0)
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
        local drop_ids = {};
        for _, entry in ipairs(items) do
            local item_name = item_name_by_id(entry.item_id);
            drop_ids[entry.slot] = db.record_drop(kill_id, entry.slot, entry.item_id, item_name, 1, 0);
        end

        tracker.voidwatch.items_captured = true;
        tracker.voidwatch.kill_id = kill_id;
        tracker.voidwatch.drop_ids = drop_ids;
        tracker.voidwatch.offered = {};
        for i = 0, 7 do
            if (params[i] > 0) then
                tracker.voidwatch.offered[i] = params[i];
            end
        end
    else
        local kill_id = tracker.voidwatch.kill_id;
        if (kill_id == nil) then return; end

        for slot, item_id in pairs(tracker.voidwatch.offered) do
            if (params[slot] == 0) then
                db.update_drop_won(kill_id, slot, 1, 0, nil,
                    tracker.voidwatch.drop_ids and tracker.voidwatch.drop_ids[slot]);
                tracker.voidwatch.offered[slot] = nil;
                if (tracker.voidwatch.drop_ids ~= nil) then tracker.voidwatch.drop_ids[slot] = nil; end
            end
        end
    end
end

-- Voidwatch: Match an incoming inventory item against offered Pyxis items.

local function match_vw_item(item_id)
    if (db == nil) then return; end
    if (not tracker.voidwatch.pyxis_active) then return; end
    if (not tracker.voidwatch.items_captured) then return; end
    if (tracker.voidwatch.kill_id == nil) then return; end
    if (item_id == nil or item_id == 0) then return; end

    for slot, offered_id in pairs(tracker.voidwatch.offered) do
        if (offered_id == item_id) then
            db.update_drop_won(tracker.voidwatch.kill_id, slot, 1, 0, nil,
                tracker.voidwatch.drop_ids and tracker.voidwatch.drop_ids[slot]);
            tracker.voidwatch.offered[slot] = nil;
            if (tracker.voidwatch.drop_ids ~= nil) then tracker.voidwatch.drop_ids[slot] = nil; end
            return;  -- match first occurrence only (handles duplicate item IDs)
        end
    end
end

-- Packet: 0x01F (S2C) - GP_SERV_COMMAND_ITEM_LIST (inventory item assign)

function tracker.handle_item_assign(data)
    if (#data < 0x0C) then return; end
    local item_id = sunpack('H', data, 0x08 + 1);
    match_vw_item(item_id);
end

-- Packet: 0x020 (S2C) - GP_SERV_COMMAND_ITEM_ATTR (item full info)

function tracker.handle_item_full_info(data)
    if (#data < 0x0E) then return; end
    local item_id = sunpack('H', data, 0x0C + 1);
    match_vw_item(item_id);
end

-- Packet: 0x5B (outgoing) - GP_CLI_COMMAND_EVENTEND (Voidwatch Pyxis close)

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

-- Packet: 0x1A (outgoing) - GP_CLI_COMMAND_ACTION (chest interaction)


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

    -- Arm chest detection on interaction instead of server-specific message IDs.
    -- Failed/locked chests simply expire without a reward.
    containers.on_interact(name, server_id);   -- chest/coffer pending + the Limbus window (containers.lua)

    -- Detect Voidwatch Riftworn Pyxis interaction.
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

-- Opening a locked chest sends a trade (0x36), not interaction 0x1A.
-- Layout: +0x04 u32 target ID, +0x08 u32[10] quantities, +0x30 u8[10] inventory slots,
-- +0x3A u16 target index, +0x3C u8 item count.


-- Reset

function tracker.reset()
    th.clear_th_state();
    tracker.active_pool = {};
    tracker.mob_kills = {};
    tracker.mob_kill_times = {};
    tracker.mob_names = {};
    tracker.pet_to_master = {};
    tracker.pending_mob_resolves = {};
    tracker.dat_names = {};
    tracker.drop_sequence = {};
    tracker.distant_kill_credits = 0;
    tracker.limbus_chest = nil;           -- the Limbus reward window (containers.lua)
    tracker.woe_coffer = nil;             -- the Walk of Echoes coffer menu (containers.lua)
    tracker.reive_spoils = nil;
    tracker.woe_walk = nil; tracker.woe_conflux_pending = nil; tracker.woe_recover_at = nil;
    tracker.chest_unlock_pending = nil;
    tracker.chest_packet_handled_at = 0;
    tracker.last_gil_update = nil;
    gil.flush_mob_gil(true);       -- same reason as check_zone: do not discard real gil
    tracker.mob_gil_queue = {};
    tracker.pending_mob_gil = {};
    tracker.mob_gil_hold = {};
    tracker.pool_scan_pending = false;
    tracker.pool_scan_retries = 0;
    tracker.pool_scan_last_try = 0;
    battlefield.exit();
    tracker.htbf_info = nil;
    tracker.last_interact = nil;
    content.reset();
    tracker.pending_htbf_entry = nil;
    tracker.pending_woe_difficulty = nil;
    tracker.previous_zone_id = 0;
    tracker.voidwatch = { pyxis_active = false, pyxis_sid = nil, items_captured = false, kill_id = nil, offered = {}, drop_ids = {}, last_vw_kill = nil };
    tracker.wildskeeper = { active = false, last_boss_name = nil, last_boss_sid = nil, last_kill_id = nil, last_kill_time = 0 };
end

-- Bind after all shared helpers are declared; earlier binding would capture nil globals.
containers.bind({ tracker = tracker, capture_vana_info = capture_vana_info, content_source_for = content_source_for, get_entity_name = get_entity_name, item_name_by_id = item_name_by_id, unsigned_sid = unsigned_sid, stamp_provenance = stamp_provenance });

gil.bind({ tracker = tracker, unsigned_sid = unsigned_sid });

th.bind({ tracker = tracker, unsigned_sid = unsigned_sid, itemdata_lib = itemdata_lib, has_buff = has_buff });

return tracker;
