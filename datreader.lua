--[[
    LootScope v1.3.1 - Zone Dialog DAT Reader
    Reads zone dialog DAT files to resolve HTBF battlefield names from
    the "Entering the battlefield for..." template strings.

    Zone dialog file IDs:
      - Zones < 256:  zone_id + 6420
      - Zones 256+:   zone_id + 85335

    The dialog DATs use the d_msg binary format:
      Header: 8-byte magic (0x64_5F_6D_73_67_00_00_00 = "d_msg\0\0\0")
      Then: table_offset(uint32), entry_size(uint32), data_size(uint32), entry_count(uint32)
      Entries: offset/length pairs pointing into string data block.
      Strings are null-terminated, may contain battlefield name templates like:
        [Name1/Name2/Name3]
      Indexed by bit position from 0x005C packet's num[1].

    Author: SQLCommit
    Version: 1.3.1
]]--

require 'common';

local ffi = require 'ffi';
local C   = ffi.C;
local dats = require 'ffxi.dats';

local datreader = {};

-- Per-zone cache: zone_id -> { bf_names = { [bit_pos] = "Name", ... } }
datreader.cache = {};

-------------------------------------------------------------------------------
-- Helper: Compute zone dialog DAT file ID
-------------------------------------------------------------------------------

local function get_zone_dialog_id(zone_id)
    if (zone_id < 256) then
        return zone_id + 6420;
    else
        return zone_id + 85335;
    end
end

-------------------------------------------------------------------------------
-- Helper: Read raw bytes from a DAT file path using FFI
-------------------------------------------------------------------------------

local function read_dat_file(file_path)
    if (file_path == nil or file_path == '') then
        return nil;
    end

    local f = C.fopen(file_path, 'rb');
    if (f == nil) then
        return nil;
    end

    C.fseek(f, 0, 2);  -- SEEK_END
    local size = C.ftell(f);
    if (size <= 0) then
        C.fclose(f);
        return nil;
    end

    C.fseek(f, 0, 0);  -- SEEK_SET
    local buf = ffi.new('uint8_t[?]', size);
    local read = C.fread(buf, 1, size, f);
    C.fclose(f);

    if (read <= 0) then
        return nil;
    end

    return ffi.string(buf, read);
end

-------------------------------------------------------------------------------
-- Helper: Read a uint32 (little-endian) from a raw string at byte offset
-------------------------------------------------------------------------------

local function read_u32(data, offset)
    if (offset + 4 > #data) then return nil; end
    local b0, b1, b2, b3 = data:byte(offset + 1, offset + 4);
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
end

-------------------------------------------------------------------------------
-- Parse d_msg format zone dialog DAT
--
-- d_msg header (32 bytes):
--   0-7: magic "d_msg\0\0\0", 8-11: flags, 12-15: data_size,
--   16-19: table_size, 20-23: entry_count, 24-31: reserved
-- Entry table: entry_count * 8 bytes (offset + flags per entry)
-- String data: null-terminated, zone dialogs typically unencrypted
-------------------------------------------------------------------------------

local function parse_d_msg(data)
    if (#data < 32) then return nil; end

    -- Check magic: "d_msg\0\0\0"
    local m0, m1, m2, m3, m4 = data:byte(1, 5);
    if (m0 ~= 0x64 or m1 ~= 0x5F or m2 ~= 0x6D or m3 ~= 0x73 or m4 ~= 0x67) then
        return nil;
    end

    local data_size   = read_u32(data, 12);
    local table_size  = read_u32(data, 16);
    local entry_count = read_u32(data, 20);

    if (data_size == nil or table_size == nil or entry_count == nil) then
        return nil;
    end
    if (entry_count == 0 or entry_count > 50000) then
        return nil;
    end

    -- Entry table starts at offset 32, each entry is 8 bytes
    local entry_table_start = 32;
    local string_data_start = entry_table_start + (entry_count * 8);

    if (string_data_start > #data) then
        return nil;
    end

    local strings = {};

    for i = 0, entry_count - 1 do
        local entry_offset = entry_table_start + (i * 8);
        local str_offset = read_u32(data, entry_offset);
        local str_flags  = read_u32(data, entry_offset + 4);

        if (str_offset ~= nil and str_flags ~= nil) then
            local abs_offset = string_data_start + str_offset;
            if (abs_offset < #data) then
                -- Read null-terminated string
                local str_end = abs_offset;
                while (str_end < #data and data:byte(str_end + 1) ~= 0) do
                    str_end = str_end + 1;
                end
                if (str_end > abs_offset) then
                    local raw = data:sub(abs_offset + 1, str_end);
                    strings[i] = raw;
                end
            end
        end
    end

    return strings;
end

-------------------------------------------------------------------------------
-- Search strings for battlefield name template: [Name1/Name2/.../NameN]
-------------------------------------------------------------------------------

local function find_bf_names(strings)
    if (strings == nil) then return nil; end

    -- Collect and sort keys for deterministic iteration (0-indexed table)
    local keys = {};
    for k, _ in pairs(strings) do
        keys[#keys + 1] = k;
    end
    table.sort(keys);

    for _, k in ipairs(keys) do
        local str = strings[k];
        -- Look for the pattern: text containing [xxx/xxx] with at least one /
        local bracket_content = str:match('%[([^%]]+/[^%]]+)%]');
        if (bracket_content ~= nil) then
            -- Split by /
            local names = {};
            local idx = 0;
            for name in bracket_content:gmatch('[^/]+') do
                names[idx] = name;
                idx = idx + 1;
            end
            if (idx > 0) then
                return names;
            end
        end
    end

    return nil;
end

-------------------------------------------------------------------------------
-- Public API: Load zone dialogs and extract battlefield names
-------------------------------------------------------------------------------

function datreader.load_zone(zone_id)
    if (datreader.cache[zone_id] ~= nil) then
        return datreader.cache[zone_id];
    end

    local file_id = get_zone_dialog_id(zone_id);
    local file_path = dats.get_file_path(file_id);

    local raw = read_dat_file(file_path);
    if (raw == nil) then
        datreader.cache[zone_id] = { bf_names = nil };
        return datreader.cache[zone_id];
    end

    local strings = parse_d_msg(raw);

    local bf_names = find_bf_names(strings);

    datreader.cache[zone_id] = { bf_names = bf_names };
    return datreader.cache[zone_id];
end

-------------------------------------------------------------------------------
-- Public API: Get battlefield name by zone_id and bit position
-------------------------------------------------------------------------------

function datreader.get_battlefield_name(zone_id, bit_pos)
    if (zone_id == nil or bit_pos == nil) then return nil; end

    local entry = datreader.load_zone(zone_id);
    if (entry == nil or entry.bf_names == nil) then
        return nil;
    end

    return entry.bf_names[bit_pos];
end

return datreader;
