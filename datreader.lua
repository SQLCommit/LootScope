--[[
    LootScope - Zone Dialog DAT Reader
    Reads zone dialog DAT files to resolve HTBF battlefield names from
    the "Entering the battlefield for..." template strings.
]]--

require 'common';

local ffi = require 'ffi';
local bit = require 'bit';
local C   = ffi.C;
local dats = require 'ffxi.dats';

local datreader = {};

-- Per-zone cache: zone_id -> { bf_names = { [bit_pos] = "Name", ... } }
datreader.cache = {};

-- Helper: Compute zone dialog DAT file ID

local function get_zone_dialog_id(zone_id)
    if (zone_id < 256) then
        return zone_id + 6420;
    else
        return zone_id + 85335;
    end
end

-- Helper: Read raw bytes from a DAT file path using FFI

local function read_dat_file(file_path)
    if (file_path == nil or file_path == '') then
        return nil;
    end

    local f = C.fopen(file_path, 'rb');
    if (f == nil) then
        return nil;
    end

    local SEEK_SET, SEEK_END = 0, 2;
    C.fseek(f, 0, SEEK_END);
    local size = C.ftell(f);
    if (size <= 0) then
        C.fclose(f);
        return nil;
    end

    C.fseek(f, 0, SEEK_SET);
    local buf = ffi.new('uint8_t[?]', size);
    local read = C.fread(buf, 1, size, f);
    C.fclose(f);

    if (read <= 0) then
        return nil;
    end

    return ffi.string(buf, read);
end

-- Helper: Read a uint32 (little-endian) from a raw string at byte offset

local function read_u32(data, offset)
    if (offset + 4 > #data) then return nil; end
    local b0, b1, b2, b3 = data:byte(offset + 1, offset + 4);
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
end

-- Parse d_msg format zone dialog DAT (see file header for format details)

local function parse_d_msg(data)
    if (#data < 32) then return nil; end

    -- Check magic: "d_msg\0\0\0"
    local m0, m1, m2, m3, m4 = data:byte(1, 5);
    if (m0 ~= 0x64 or m1 ~= 0x5F or m2 ~= 0x6D or m3 ~= 0x73 or m4 ~= 0x67) then
        return nil;
    end

    local data_size   = read_u32(data, 12);  -- read for corruption check
    local table_size  = read_u32(data, 16);  -- read for corruption check
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
        local str_flags  = read_u32(data, entry_offset + 4);  -- read for corruption check

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

-- Search strings for battlefield name template: [Name1/Name2/.../NameN]

-- Defined below, alongside the XOR helpers it uses. Forward-declared because load_zone sits
-- ABOVE them and a direct call would resolve to a nil global.
local parse_xor_dmsg;

-- Recognize English battlefield-roster phrases; return nil if none match. Entry text takes priority.
local ROSTER_ANCHORS = {
    'clear time record',
    'battlefield clear time',
    'clear time for',
};

local function has_anchor(str)
    local low = str:lower();
    for _, a in ipairs(ROSTER_ANCHORS) do
        if (low:find(a, 1, true) ~= nil) then return true; end
    end
    return false;
end

local function find_bf_names(strings)
    if (strings == nil) then return nil; end

    -- Collect and sort keys for deterministic iteration (0-indexed table)
    local keys = {};
    for k, _ in pairs(strings) do
        keys[#keys + 1] = k;
    end
    table.sort(keys);

    -- Use only the clear-time-record roster template. Other lists may name zones or NPCs.
    -- Return nil for unsupported languages or zones without a record board.
    local best, best_n = nil, 0;
    for _, k in ipairs(keys) do
        local str = strings[k];
        if (has_anchor(str)) then
            local bracket_content = str:match('%[([^%]]+/[^%]]+)%]');
            if (bracket_content ~= nil) then
                local names = {};
                local idx = 0;
                for name in bracket_content:gmatch('[^/]+') do
                    names[idx] = name;
                    idx = idx + 1;
                end
                if (idx > best_n) then best, best_n = names, idx; end
            end
        end
    end

    return best;
end

-- Public API: Load zone dialogs and extract battlefield names

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

    -- Try the d_msg header format, then the XOR format used by retail zone dialog DATs.
    local strings = parse_d_msg(raw) or parse_xor_dmsg(raw);

    local bf_names = find_bf_names(strings);

    datreader.cache[zone_id] = { bf_names = bf_names };
    return datreader.cache[zone_id];
end

-- Public API: Get battlefield name by zone_id and bit position

function datreader.get_battlefield_name(zone_id, bit_pos)
    if (zone_id == nil or bit_pos == nil) then return nil; end

    local entry = datreader.load_zone(zone_id);
    if (entry == nil or entry.bf_names == nil) then
        return nil;
    end

    return entry.bf_names[bit_pos];
end


-- Read chest message bases from the client DAT; updates can shift numeric IDs.
-- Retail XOR dmsg: header low 24 bits = size-4, offsets XOR 0x80808080, payload XOR 0x80.
-- Accept a base only if +1/+2/+4/+6 match fail/trapped/mimic/illusion messages.

local chest_base_cache = {};

-- Search the RAW bytes for the XOR'd form of a string -- far cheaper than decoding
-- 11,000+ entries, and it needs no allocation per entry.
local function xor80(str)
    local out = {};
    for i = 1, #str do out[i] = string.char(bit.bxor(str:byte(i), 0x80)); end
    return table.concat(out);
end

local function xor_offsets(data)
    local hdr = read_u32(data, 0);
    if (hdr == nil) then return nil; end
    if (bit.band(hdr, 0xFFFFFF) ~= #data - 4) then return nil; end   -- not this variant
    local first = bit.bxor(read_u32(data, 4) or 0, 0x80808080);
    local n = math.floor(first / 4);
    if (n < 16 or n > 60000) then return nil; end
    local offs = {};
    for i = 0, n - 1 do
        local o = read_u32(data, 4 + i * 4);
        if (o == nil) then return nil; end
        offs[i] = bit.bxor(o, 0x80808080);
    end
    return offs, n;
end

-- entry index whose payload contains file offset `pos0` (0-based)
local function entry_at(offs, n, pos0)
    local lo, hi, best = 0, n - 1, nil;
    while (lo <= hi) do
        local mid = math.floor((lo + hi) / 2);
        if (offs[mid] + 4 <= pos0) then best = mid; lo = mid + 1; else hi = mid - 1; end
    end
    return best;
end

local function entry_has(data, offs, n, idx, needle)
    if (idx == nil or idx < 0 or idx >= n) then return false; end
    local s = offs[idx] + 5;                                  -- 1-based payload start
    local e = (idx + 1 < n) and (offs[idx + 1] + 4) or #data; -- 1-based exclusive end
    if (s > #data) then return false; end
    return data:sub(s, e):find(needle, 1, true) ~= nil;
end

-- Decode XOR dmsg into the same zero-based table as plain dmsg.
-- Header low 24 bits = size-4; offsets XOR 0x80808080; payload XOR 0x80.
function parse_xor_dmsg(data)
    if (data == nil or #data < 32) then return nil; end
    local offs, n = xor_offsets(data);
    if (offs == nil) then return nil; end
    local out = {};
    for i = 0, n - 1 do
        local a = offs[i] + 5;                                    -- 1-based payload start
        local b = (i + 1 < n) and (offs[i + 1] + 4) or #data;     -- 1-based exclusive end
        if (a <= #data and b >= a) then
            local raw = data:sub(a, b);
            local z = raw:find('\0', 1, true);                    -- payload is NUL-terminated
            if (z ~= nil) then raw = raw:sub(1, z - 1); end
            out[i] = xor80(raw);
        end
    end
    return out;
end

function datreader.find_chest_base(zone_id)
    if (zone_id == nil or zone_id <= 0) then return nil; end
    local hit = chest_base_cache[zone_id];
    if (hit ~= nil) then
        if (hit == false) then return nil; end
        return hit;
    end
    chest_base_cache[zone_id] = false;   -- cache the failure too: never re-read per chest

    local raw = read_dat_file(dats.get_file_path(get_zone_dialog_id(zone_id)));
    if (raw == nil or #raw < 64) then return nil; end
    local offs, n = xor_offsets(raw);
    if (offs == nil) then return nil; end

    local pos = raw:find(xor80('You unlock the '), 1, true);
    while (pos ~= nil) do
        local idx = entry_at(offs, n, pos - 1);
        -- accept ONLY if the whole block lootscope indexes off this base is present
        if (entry_has(raw, offs, n, idx,     xor80('You unlock the '))
        and entry_has(raw, offs, n, idx + 1, xor80('fails to open the'))
        and entry_has(raw, offs, n, idx + 2, xor80('was trapped'))
        and entry_has(raw, offs, n, idx + 4, xor80('was a mimic'))
        and entry_has(raw, offs, n, idx + 6, xor80('but an illusion'))) then
            chest_base_cache[zone_id] = idx;
            return idx;
        end
        pos = raw:find(xor80('You unlock the '), pos + 1, true);
    end
    return nil;
end

-- Return the first DAT message beginning with phrase, or nil. Cache by zone and phrase, including misses.
-- A private server's message index may differ from the client DAT.
local msg_id_cache = {};
function datreader.find_message_id(zone_id, phrase)
    if (zone_id == nil or zone_id <= 0 or phrase == nil or phrase == '') then return nil; end
    local key = zone_id .. '|' .. phrase;
    local hit = msg_id_cache[key];
    if (hit ~= nil) then return (hit ~= false) and hit or nil; end
    msg_id_cache[key] = false;

    local raw = read_dat_file(dats.get_file_path(get_zone_dialog_id(zone_id)));
    if (raw == nil or #raw < 64) then return nil; end
    local offs, n = xor_offsets(raw);
    if (offs == nil) then return nil; end

    local needle = xor80(phrase);
    local pos = raw:find(needle, 1, true);
    while (pos ~= nil) do
        local idx = entry_at(offs, n, pos - 1);
        -- STARTS with: the match must sit at the entry's payload start, not inside longer text
        if (idx ~= nil and offs[idx] + 4 == pos - 1) then
            msg_id_cache[key] = idx;
            return idx;
        end
        pos = raw:find(needle, pos + 1, true);
    end
    return nil;
end

return datreader;
