-- Treasure Hunter gear, trait and action estimates. Per-mob state is shared with the tracker.

require 'common';

local M = {};

-- Bound by tracker: its table (state + constants) and the private helpers this code shares.
local tracker = nil;
local db = nil;
local unsigned_sid, itemdata_lib, has_buff;

function M.bind(deps)
    tracker = deps.tracker;
    unsigned_sid = deps.unsigned_sid;
    itemdata_lib = deps.itemdata_lib;
    has_buff = deps.has_buff;
end
-- Refresh the DB reference on tracker.init; it may change after login.
function M.set_db(ref) db = ref; end

local th_settings = nil;

local cached_gear_th = nil;  -- nil = needs rescan

local cached_th_cap = nil;   -- nil = needs resolve (8 for THF, 4 for others)



local ffi = require 'ffi';

-- BLU Spell-Set Trait Detection
local BLU_JOB_ID = 16;

-- BLU memory stores spell IDs as (actual_id - 512)
local BLU_TH_SPELLS = {
    [168] = true,  -- Charged Whisker  (spell 680)
    [171] = true,  -- Everyone's Grudge (spell 683)
    [185] = true,  -- Amorphic Spikes  (spell 697)
};

local BLU_TH_SPELL_COUNT = 3;

-- Lazy-init BLU spell memory offset (nil=not attempted, false=failed)
local blu_mem_offset = nil;

local function get_blu_mem_offset()
    if (blu_mem_offset ~= nil) then return blu_mem_offset; end
    local ok, ptr = pcall(ashita.memory.find, 0, 0,
        'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0);
    if (not ok or ptr == nil or ptr == 0) then
        blu_mem_offset = false;
        tracker.pending_warnings[#tracker.pending_warnings + 1] =
            'BLU set-spell signature not found - TH-trait detection disabled (likely a client update).';
        return false;
    end
    blu_mem_offset = ffi.cast('uint32_t*', ptr);
    return blu_mem_offset;
end

-- Check if the 3 BLU spells for TH trait are currently set.
-- is_main: true = check main job spell set, false = check sub job spell set
local function are_blu_th_spells_set(is_main)
    local offset = get_blu_mem_offset();
    if (not offset) then return false; end

    local inv_ptr = AshitaCore:GetPointerManager():Get('inventory');
    if (inv_ptr == nil or inv_ptr == 0) then return false; end
    local ptr = ashita.memory.read_uint32(inv_ptr);
    if (ptr == 0) then return false; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return false; end

    -- Main job spells at +0x04, sub job spells at +0xA0 (20 slots × 1 byte each)
    local ok_read, spell_data = pcall(ashita.memory.read_array,
        (ptr + offset[0]) + (is_main and 0x04 or 0xA0), 0x14);
    if (not ok_read or spell_data == nil) then return false; end

    local found = 0;
    for _, spell_id in ipairs(spell_data) do
        if (BLU_TH_SPELLS[spell_id]) then
            found = found + 1;
            if (found >= BLU_TH_SPELL_COUNT) then return true; end
        end
    end
    return false;
end

-- TH Cap Constants
-- THF main base cap = 8 (server procs can push to 12-14 with JP gifts)
-- Non-THF main cap = 4
local THF_JOB_ID = 6;

local TH_CAP_THF  = 8;

local TH_CAP_OTHER = 4;

local SIGNET_BUFF_ID = 253;

-- Trust / Pet TH Detection
-- Trusts on THF or /THF apply TH1. BST jug pets with THF apply TH1.
local TH_TRUST_NAMES = {
    -- THF main trusts
    ['Aldo'] = true,
    ['Chacharoon'] = true,
    ['Fablinix'] = true,
    ['JakohWahcondalo'] = true,  -- no space (LSB mob_pools)
    ['Jakoh Wahcondalo'] = true, -- space variant (retail)
    ['Lehko Habhoka'] = true,
    ['Lion'] = true,
    ['Maximilian'] = true,
    ['Nanaa Mihgo'] = true,
    ['Romaa Mihgo'] = true,
    -- /THF sub trusts
    ['Ark Angel MR'] = true,
    ['Maat'] = true,
    ['Margret'] = true,
};

-- BST jug pets that apply TH1 (THF-based pets)
-- Include name variants: in-game display may differ from wiki/pet_list
local TH_PET_NAMES = {
    ['Dipper Yuly'] = true,
    ['DipperYuly'] = true,
    ['Faithful Falcorr'] = true,
    ['Faithful Falcor'] = true,   -- LSB pet_list spelling
    ['FaithfulFalcorr'] = true,
    ['Threestar Lynn'] = true,    -- may not be in LSB yet
    ['ThreestarLynn'] = true,
};

-- Cache: server_id -> true/false/name (is this actor a TH trust/pet?)
-- Populated lazily on first offensive action, cleared on zone change.
local th_source_cache = {};

local function resolve_th_source(actor_sid)
    local cached = th_source_cache[actor_sid];
    if (cached ~= nil) then return cached; end

    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then th_source_cache[actor_sid] = false; return false; end

    -- Check party members (covers trusts — they appear as party members)
    local party = mem:GetParty();
    if (party ~= nil) then
        for i = 1, 5 do
            if (party:GetMemberIsActive(i) == 1) then
                local sid = unsigned_sid(party:GetMemberServerId(i));
                if (sid == actor_sid) then
                    local name = party:GetMemberName(i);
                    if (name ~= nil and TH_TRUST_NAMES[name]) then
                        th_source_cache[actor_sid] = name;
                        return name;
                    end
                    th_source_cache[actor_sid] = false;
                    return false;
                end
            end
        end
    end

    -- Check if it's our BST pet (GetPetTargetIndex → single entity read, no scan)
    local entity = mem:GetEntity();
    if (entity ~= nil and party ~= nil) then
        local my_idx = party:GetMemberTargetIndex(0);
        local pet_idx = (my_idx ~= nil and my_idx > 0) and entity:GetPetTargetIndex(my_idx) or nil;
        if (pet_idx ~= nil and pet_idx ~= 0) then
            local pet_sid = unsigned_sid(entity:GetServerId(pet_idx));
            if (pet_sid == actor_sid) then
                local name = entity:GetName(pet_idx);
                if (name ~= nil and TH_PET_NAMES[name]) then
                    th_source_cache[actor_sid] = name;
                    return name;
                end
                th_source_cache[actor_sid] = false;
                return false;
            end
        end
    end

    -- Unknown actor — not a TH source
    th_source_cache[actor_sid] = false;
    return false;
end

function M.set_settings(s)
    th_settings = s;
end

-- Rebuild item lookup cache from DB for active profile
local function refresh_th_items_cache(profile_id)
    if (db == nil or profile_id == nil) then
        tracker.th_items_cache = nil;
        tracker.th_profile_id = nil;
        return;
    end
    tracker.th_items_cache = db.get_th_items_by_item_id(profile_id);
    tracker.th_profile_id = profile_id;
end

-- Get current profile ID from settings, refreshing cache if needed
local cached_profile_name = nil;  -- tracks which profile name the cache was built for

local function get_active_profile_id()
    if (th_settings == nil) then return nil; end
    if (not th_settings.th_estimation_enabled) then return nil; end
    local profile_name = th_settings.th_profile;
    if (profile_name == nil or profile_name == '') then return nil; end

    -- Check if cache matches current profile name
    if (tracker.th_items_cache ~= nil and tracker.th_profile_id ~= nil and cached_profile_name == profile_name) then
        return tracker.th_profile_id;
    end

    -- Resolve profile name to ID (profile changed or cache empty)
    local profile = db.get_th_profile_by_name(profile_name);
    if (profile == nil) then return nil; end
    refresh_th_items_cache(profile.id);
    cached_profile_name = profile_name;
    return profile.id;
end

local function scan_th_gear()
    if (cached_gear_th ~= nil) then return cached_gear_th; end

    local profile_id = get_active_profile_id();
    if (profile_id == nil) then return 0; end

    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return 0; end
    local inv = mem:GetInventory();
    if (inv == nil) then return 0; end
    local player = mem:GetPlayer();
    if (player == nil) then return 0; end

    -- Job trait TH
    local main_job = player:GetMainJob();
    local sub_job = player:GetSubJob();
    local main_level = player:GetMainJobLevel();
    local sub_level = player:GetSubJobLevel();

    -- BLU spell-set trait check: TH+1 requires 3 specific spells to be set
    local skip_blu = false;
    if (main_job == BLU_JOB_ID or sub_job == BLU_JOB_ID) then
        local is_main = (main_job == BLU_JOB_ID);
        skip_blu = not are_blu_th_spells_set(is_main);
    end

    local trait_th = db.compute_trait_th(profile_id, main_job, sub_job, main_level, sub_level, skip_blu);

    -- Gear TH (intrinsic + augmented)
    local gear_th = 0;
    local augmented_th = 0;
    local item_lookup = tracker.th_items_cache or {};

    local res = AshitaCore:GetResourceManager();

    for slot = 0, 15 do
        local eitem = inv:GetEquippedItem(slot);
        if (eitem ~= nil and eitem.Index ~= 0) then
            local container = bit.rshift(bit.band(eitem.Index, 0xFF00), 8);
            local index = eitem.Index % 0x0100;
            local item = inv:GetContainerItem(container, index);
            if (item ~= nil and item.Id > 0) then
                -- Layer 1: Intrinsic TH from profile
                local th_entry = item_lookup[item.Id];
                if (th_entry ~= nil) then
                    gear_th = gear_th + th_entry.th_value;
                end

                -- Layer 2: Augmented TH (augment ID 147)
                if (itemdata_lib ~= nil and res ~= nil) then
                    local ritem = res:GetItemById(item.Id);
                    if (ritem ~= nil) then
                        local ok_aug, augments = pcall(itemdata_lib.parse_augments, item, ritem);
                        if (ok_aug and augments ~= nil) then
                            for _, aug in ipairs(augments) do
                                if (aug.index == 147) then
                                    augmented_th = augmented_th + (tonumber(aug.value) or 0) + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local total = trait_th + gear_th + augmented_th;

    -- Apply TH cap based on main job (THF=8, others=4)
    -- Server-confirmed procs (th_level) can exceed this cap; gear estimate cannot.
    local cap = (main_job == THF_JOB_ID) and TH_CAP_THF or TH_CAP_OTHER;
    cached_th_cap = cap;
    if (total > 0) then
        total = math.min(total, cap);
    end

    cached_gear_th = total;
    return total;
end

-- Compute live TH bonus from zone-wide effects (not cached — checked per call).
local function get_live_th_bonus()
    if (not th_settings or not th_settings.th_zone_effects) then return 0; end
    if (tracker.zone_has_treasure_hound and has_buff(SIGNET_BUFF_ID)) then
        return 1;
    end
    -- TODO: Atma of Dread (Abyssea, buff 287) — needs user toggle
    -- TODO: Prowess TH (GoV, buff 474) — +1 per level, max 3 levels; needs user toggle for tier
    return 0;
end

-- Update TH estimate for a mob (max tracking — never decreases per mob)
-- Short-circuits when mob already has our current gear TH (avoids redundant work per hit).
local function update_th_estimate(mob_sid)
    local gear = scan_th_gear();
    local bonus = get_live_th_bonus();
    local total = gear + bonus;
    -- Apply cap (cached_th_cap set by scan_th_gear)
    if (total > 0 and cached_th_cap ~= nil) then
        total = math.min(total, cached_th_cap);
    end
    if (total <= 0) then return; end
    local current = tracker.th_estimated[mob_sid] or 0;
    if (current >= total) then return; end
    tracker.th_estimated[mob_sid] = total;
end

function M.clear_th_state()
    tracker.th_levels = {};
    tracker.th_actions = {};
    tracker.th_estimated = {};
    tracker.engaged_mobs = {};
    tracker.th_trust_source = nil;
    tracker.zone_has_treasure_hound = false;
    th_source_cache = {};
    cached_gear_th = nil;
    cached_th_cap = nil;
end

-- Handle equipment change packet (0x0050)
function M.handle_equipment_change(data)
    if (#data < 8) then return; end
    cached_gear_th = nil;
    -- If engaged with any mobs, recalculate TH for all.
    -- Max-tracking means we only need to update if new total exceeds stored estimates.
    if (not th_settings or not th_settings.th_estimation_enabled) then return; end
    if (next(tracker.engaged_mobs) == nil) then return; end
    local gear = scan_th_gear();
    local total = gear + get_live_th_bonus();
    local cap = cached_th_cap;  -- set by scan_th_gear() above
    if (cap ~= nil and total > cap) then total = cap; end
    if (total <= 0) then return; end
    for mob_sid, _ in pairs(tracker.engaged_mobs) do
        local mob_th = math.max(tracker.th_levels[mob_sid] or 0, tracker.th_estimated[mob_sid] or 0);
        if (mob_th < total and (cap == nil or mob_th < cap)) then
            tracker.th_estimated[mob_sid] = total;
        end
    end
end

-- Public wrapper for BLU TH spell check (used by /loot bluspells debug command)
function M.check_blu_th_spells(is_main)
    return are_blu_th_spells_set(is_main);
end

-- Invalidate TH items cache (called when profile changes in UI)
function M.invalidate_th_cache()
    tracker.th_items_cache = nil;
    tracker.th_profile_id = nil;
    cached_profile_name = nil;
    cached_gear_th = nil;
    cached_th_cap = nil;
    th_source_cache = {};
end

-- Lifted verbatim from handle_action (the block stays a one-line call there).
function M.on_action(target_id, actor_id, is_self_offensive, _cmd_no)
    -- TH estimation: skip entirely if mob already at TH cap for our job.
    local mob_th = math.max(tracker.th_levels[target_id] or 0, tracker.th_estimated[target_id] or 0);
    if (cached_th_cap ~= nil and mob_th >= cached_th_cap) then
        -- Mob is at cap — no TH work needed.
    elseif (is_self_offensive) then
        -- Gear estimation: only when enabled and server TH hasn't already matched gear.
        if (th_settings ~= nil and th_settings.th_estimation_enabled) then
            local server_th = tracker.th_levels[target_id];
            if (server_th == nil or cached_gear_th == nil or server_th < cached_gear_th) then
                update_th_estimate(target_id);
            end
        end
    -- Trust/Pet TH: only check if mob doesn't already have trust TH applied.
    elseif (_cmd_no >= 1 and _cmd_no <= 6 and th_settings ~= nil and th_settings.th_trust_detection) then
        if ((tracker.th_estimated[target_id] or 0) < 1) then
            local source_name = resolve_th_source(actor_id);
            if (source_name) then
                tracker.th_estimated[target_id] = 1;
                tracker.th_trust_source = source_name;
            end
        end
    end
end

return M;
