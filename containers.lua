-- Chest, coffer and Limbus/WoE rewards. Keep shared state on the injected tracker table
-- so pool and gil handlers observe the same pending rewards.

require 'common';
local sunpack = struct.unpack;
local classify    = require 'classify';
local battlefield = require 'battlefield';
local ok_dat, datreader = pcall(require, 'datreader');
if (not ok_dat) then datreader = nil; end

local M = {};

-- Inject tracker state and shared kill/pool helpers.
local tracker = nil;
local db = nil;
-- Resolve tracker constants in bind(); keep the destination local to this module.
local chest_offset_map;
local capture_vana_info, content_source_for, get_entity_name, item_name_by_id, unsigned_sid, stamp_provenance;

function M.bind(deps)
    tracker = deps.tracker;
    chest_offset_map = {
        [0] = -1,                                 -- unlock (sets pending, not a result)
        [1] = tracker.CHEST_RESULT_FAIL_PICK,     -- fails to open
        [2] = tracker.CHEST_RESULT_FAIL_TRAP,     -- trapped!
        [4] = tracker.CHEST_RESULT_FAIL_MIMIC,    -- mimic!
        [6] = tracker.CHEST_RESULT_FAIL_ILLUSION, -- illusion
    };
    capture_vana_info = deps.capture_vana_info; content_source_for = deps.content_source_for; get_entity_name = deps.get_entity_name; item_name_by_id = deps.item_name_by_id; unsigned_sid = deps.unsigned_sid; stamp_provenance = deps.stamp_provenance;
end
-- db is REASSIGNED by tracker.init (it is nil until then), so it is pushed, never copied once.
function M.set_db(ref) db = ref; end

local chest_result_labels = {
    [0] = 'Gil',
    [1] = 'Lockpick Failed',
    [2] = 'Trapped!',
    [3] = 'Mimic!',
    [4] = 'Illusion',
};

function M.get_chest_result_label(result)
    return chest_result_labels[tonumber(result)] or '?';
end

local container_labels = {
    [1] = 'Chest',
    [2] = 'Coffer',
};

-- Display the interacted entity name separately from its container badge.
local container_full_labels = {
    [1] = 'Treasure Chest',
    [2] = 'Treasure Coffer',
};

function M.get_container_full_label(container_type)
    return container_full_labels[tonumber(container_type)] or 'Treasure Chest';
end

function M.get_container_label(container_type)
    return container_labels[tonumber(container_type)] or 'Chest';
end

-- Zone container types.
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

-- Fallback chest-unlock bases from retail dialog DATs. Prefer live DAT resolution; updates shift IDs.
-- Validate +1/+2/+4/+6 as fail/trapped/mimic/illusion messages.
local chest_msg_ids = {
    [9]    = 7487, -- PsoXja
    [11]   = 7772, -- Oldton_Movalpolos
    [12]   = 7277, -- Newton_Movalpolos
    [28]   = 7374, -- Sacrarium
    [130]  = 7368, -- RuAun_Gardens
    [141]  = 7380, -- Fort_Ghelsba
    [142]  = 7359, -- Yughott_Grotto
    [143]  = 7435, -- Palborough_Mines
    [145]  = 7430, -- Giddeus
    [147]  = 7384, -- Beadeaux
    [149]  = 7496, -- Davoi
    [150]  = 7310, -- Monastic_Cavern
    [151]  = 7449, -- Castle_Oztroja
    [153]  = 7182, -- The_Boyahda_Tree
    [157]  = 7345, -- Middle_Delkfutts_Tower
    [158]  = 7376, -- Upper_Delkfutts_Tower
    [159]  = 7341, -- Temple_of_Uggalepih
    [160]  = 7369, -- Den_of_Rancor
    [161]  = 7247, -- Castle_Zvahl_Baileys
    [162]  = 7247, -- Castle_Zvahl_Keep
    [169]  = 7387, -- Toraimarai_Canal
    [174]  = 7341, -- Kuftal_Tunnel
    [176]  = 7341, -- Sea_Serpent_Grotto
    [177]  = 7240, -- VeLugannon_Palace
    [190]  = 7303, -- King_Ranperres_Tomb
    [191]  = 7459, -- Dangruf_Wadi
    [192]  = 7362, -- Inner_Horutoto_Ruins
    [193]  = 7417, -- Ordelles_Caves
    [194]  = 7304, -- Outer_Horutoto_Ruins
    [195]  = 7426, -- The_Eldieme_Necropolis
    [196]  = 7399, -- Gusgen_Mines
    [197]  = 7276, -- Crawlers_Nest
    [198]  = 7379, -- Maze_of_Shakhrami
    [200]  = 7350, -- Garlaige_Citadel
    [204]  = 7384, -- FeiYin
    [205]  = 7274, -- Ifrits_Cauldron
    [208]  = 7341, -- Quicksand_Caves
    [213]  = 7341, -- Labyrinth_of_Onzozo
};

local function resolve_chest_base(zone_id)
    if (zone_id == nil or zone_id <= 0) then return nil; end
    local learned = tracker.chest_bases[zone_id];
    if (learned ~= nil) then return learned; end
    if (datreader ~= nil and datreader.find_chest_base ~= nil) then
        local ok, base = pcall(datreader.find_chest_base, zone_id);
        if (ok and type(base) == 'number') then return base; end
    end
    return chest_msg_ids[zone_id];
end

-- Learn unlock IDs only after an interaction-armed chest pays out, within 64 IDs of a known seed.
local function learn_chest_base(zone_id, mesnum)
    if (zone_id == nil or mesnum == nil or zone_id <= 0) then return; end
    if (tracker.chest_bases[zone_id] == mesnum) then return; end
    local seed = chest_msg_ids[zone_id];
    if (seed ~= nil and math.abs(mesnum - seed) > 64) then return; end
    tracker.chest_bases[zone_id] = mesnum;
end

-- Interaction detection must return nil for non-containers. The pool classifier has a different
-- contract: its packet already confirms a container, so unknown names may default to chest.
local function container_type_from_name(name)
    if (name == nil or name == '') then return nil; end
    local l = name:lower();
    if (l:find('coffer', 1, true)) then return tracker.CONTAINER_COFFER; end
    if (l:find('chest',  1, true)) then return tracker.CONTAINER_CHEST;  end
    return nil;
end

-- Deduplicate chest gil across wallet packets and chat fallbacks by amount within 15 seconds.
-- Identical payouts from different containers within that window are also collapsed.
local chest_gil_last = nil;   -- { amount, time }

local function record_chest_gil(zone_id, zone_name, ctype, amount, learn_msg)
    if (db == nil or amount == nil or amount <= 0) then return false; end
    if (chest_gil_last ~= nil and chest_gil_last.amount == amount
        and (os.clock() - chest_gil_last.time) < 15.0) then
        return false;                      -- another path already booked this open
    end
    chest_gil_last = { amount = amount, time = os.clock() };
    db.record_chest_event(zone_id, zone_name, ctype, tracker.CHEST_RESULT_GIL, amount,
                          capture_vana_info());
    -- A confirmed payout permits learning the pending unlock-message ID.
    if (learn_msg ~= nil) then learn_chest_base(zone_id, learn_msg); end
    tracker.chest_unlock_pending    = nil;
    tracker.chest_packet_handled_at = os.clock();
    tracker.last_gil_update         = nil;
    return true;
end

M.record_chest_gil = record_chest_gil;   -- called by tracker (gil routers / the pool packet)

-- Snapshot the wallet before payout on interaction; later messages must not replace that baseline.
local function arm_chest_pending(ctype, armed_by)
    local prev_gil = 0;
    local mm = AshitaCore:GetMemoryManager();
    if (mm ~= nil) then
        local inv = mm:GetInventory();
        if (inv ~= nil) then
            local g = inv:GetContainerItem(0, 0);
            if (g ~= nil) then prev_gil = g.Count or 0; end
        end
    end
    tracker.chest_unlock_pending = {
        time           = os.clock(),
        container_type = ctype,
        zone_id        = tracker.current_zone_id,
        zone_name      = tracker.current_zone_name,
        prev_gil       = prev_gil,
        armed_by       = armed_by,
        candidate_msg  = nil,
    };
end

-- CHEST_UNLOCKED offset -> chest result constant

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

    -- Allow recently despawned chest names within 20 yalms; render flags may already be cleared.
    local px = entity:GetLocalPositionX(0);  -- east/west
    local py = entity:GetLocalPositionY(0);  -- north/south
    if (px ~= nil and (px ~= 0 or py ~= 0)) then
        local best_dist = 20.0;
        local best_ctype = nil;
        for i = 1, 1023 do
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

-- Packet handler: 0x002A (messageSpecial) — chest unlock and failures
function M.handle_chest_message(data)
    if (db == nil) then return; end
    if (#data < 28) then return; end

    local mesnum = sunpack('H', data, 0x1A + 1);

    -- Retain the last unlock candidate between interaction and payout.
    local pend = tracker.chest_unlock_pending;
    if (pend ~= nil and pend.armed_by == 'interact') then
        pend.candidate_msg = mesnum;
    end

    local base = resolve_chest_base(tracker.current_zone_id);
    if (base == nil) then return; end

    local offset = mesnum - base;

    if (offset < 0 or offset > 6) then return; end
    local result = chest_offset_map[offset];
    if (result == nil) then return; end  -- offsets 3, 5 are not tracked

    local tidx = sunpack('H', data, 0x18 + 1);
    -- Prefer the interacted container type; current target/proximity cannot distinguish nearby chest/coffer
    -- pairs.
    local ctype = (pend ~= nil and pend.container_type) or detect_container_type(tidx);

    -- Offset 0 = unlock: arm gil detection. Do NOT re-arm over an interaction-armed pending
    -- -- that one snapshotted gil earlier, which is the entire point of the snapshot.
    if (offset == 0) then
        if (tracker.chest_unlock_pending == nil) then
            arm_chest_pending(ctype, 'message');
        end
        return;
    end

    tracker.chest_packet_handled_at = os.clock();  -- dedup: block text_in for recorded events
    local vana_info = capture_vana_info();
    db.record_chest_event(
        tracker.current_zone_id, tracker.current_zone_name,
        ctype, result, 0, vana_info
    );
end

-- Text_in: chest failure detection + unlock fallback + gil text fallback
-- Failures (lockpick, trap, mimic, illusion).
function M.handle_chest_text(text)
    if (text == nil or text == '') then return; end
    if (db == nil) then return; end

    -- Strip non-ASCII before matching
    local clean = text:gsub('[^\x20-\x7E]', '');

    -- Dedup: skip failures if 0x002A already recorded one recently
    local dedup_active = (os.clock() - tracker.chest_packet_handled_at) < 1.0;

    -- Detect container type using zone lookup (same as packet handler).
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
    if (tracker.chest_unlock_pending == nil) then
        local unlock_match = clean:match('[Yy]ou unlock the (%a+)');
        if (unlock_match ~= nil) then
            local ctype = detect_container_type(0);

            -- Check if 0x001E or 0x0053 already arrived (retroactive detection).
            if (tracker.last_gil_update ~= nil) then
                local age = os.clock() - tracker.last_gil_update.time;
                local amount;
                if (tracker.last_gil_update.from_0x0053) then
                    amount = tracker.last_gil_update.new_qty;  -- 0x0053: direct amount
                else
                    amount = tracker.last_gil_update.new_qty - tracker.last_gil_update.prev_gil;  -- 0x001E: diff
                end
                if (age < 3.0 and amount > 0) then
                    record_chest_gil(tracker.current_zone_id, tracker.current_zone_name,
                                     ctype, amount, nil);
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

    -- Gil text fallback.
    if (tracker.chest_unlock_pending ~= nil) then
        local gil_text = clean:match('[Oo]btained (%d[%d,]*) gil');
        if (gil_text ~= nil) then
            local amount = tonumber((gil_text:gsub(',', ''))) or 0;
            if (amount > 0) then
                record_chest_gil(tracker.chest_unlock_pending.zone_id,
                                 tracker.chest_unlock_pending.zone_name,
                                 tracker.chest_unlock_pending.container_type,
                                 amount, tracker.chest_unlock_pending.candidate_msg);
                return;
            end
        end
    end

    -- BCNM gil text fallback.
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
                    local ki = { battlefield = tracker.battlefield.name,
                                 level_cap   = tracker.battlefield.level_cap };
                    stamp_provenance(ki);
                    kill_id = db.record_kill(
                        'Armoury Crate', 0,
                        tracker.current_zone_id, tracker.current_zone_name,
                        0, tracker.SOURCE_BCNM,
                        vana_info, ki
                    );
                end
                if (kill_id ~= nil) then
                    db.record_drop(kill_id, -1, 65535, 'Gil', amount, 1);
                    battlefield.consume_pending_gil();  -- consumed by text fallback
                end
            end
        end
    end
end

function M.check_chest_timeout()
    -- Expire stale last_gil_update
    if (tracker.last_gil_update ~= nil and
        (os.clock() - tracker.last_gil_update.time) > 5.0) then
        tracker.last_gil_update = nil;
    end
    if (tracker.chest_unlock_pending == nil) then return; end
    if (os.clock() - tracker.chest_unlock_pending.time > 5.0) then
        tracker.chest_unlock_pending = nil;
    end
end

-- Pool packets already confirm a container; unknown names default to chest here, unlike interaction
-- detection.
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

M.classify_container_by_name = classify_container_by_name;   -- called by tracker (gil routers / the pool packet)

-- Limbus rewards bypass the pool: 0x02A names the player, p0 is the item ID, and the obtained-message
-- ID is DAT-resolved. Pair packet items with English chat echoes; exclude key-item/unit messages.
-- These rewards feed the live feed only.
local LIMBUS_CHEST_WINDOW = 20.0;   -- allow delayed chest rewards

local function in_limbus()
    return classify.INSTANCE_ZONES[tracker.current_zone_id] == 'Limbus';
end

-- Recheck the Limbus zone when consuming rewards so stale windows cannot capture another NPC's items.
local function limbus_chest_live()
    local c = tracker.limbus_chest;
    if (c == nil) then return nil; end
    if ((os.clock() - c.armed_at) > LIMBUS_CHEST_WINDOW or not in_limbus()) then
        tracker.limbus_chest = nil; return nil;
    end
    return c;
end

-- Classify by units: 3000 normal, 5000 bonus (BG Wiki). Rename an existing reward row if units arrive
-- later.
local function limbus_set_units(units)
    local c = limbus_chest_live();
    if (c == nil or units == nil) then return; end
    c.bonus = (units >= 5000);
    c.display = c.name .. (c.bonus and ' (bonus)' or '');
    if (c.kill_id ~= nil and db ~= nil) then db.set_kill_name(c.kill_id, c.display); end
end

-- Track both log and short item names when pairing packet rewards with chat echoes.
local function item_log_name_by_id(item_id)
    if (item_id == nil) then return nil; end
    local res = AshitaCore:GetResourceManager();
    local item = (res ~= nil) and res:GetItemById(item_id) or nil;
    if (item == nil or item.LogNameSingular == nil) then return nil; end
    return item.LogNameSingular[1];
end

-- Packets are authoritative once present; use text fallback only while no packet reward was decoded.
local function limbus_record_item(item_id, item_name, from_packet)
    local c = limbus_chest_live();
    if (c == nil or db == nil) then return; end
    if (item_name == nil or item_name == '' or item_name == 'Unknown') then return; end
    -- Each reward message is one item, including repeated IDs. Count unmatched packet bookings
    -- so chat echoes pair off without collapsing separate copies.
    local key = item_name:lower();
    if (from_packet) then
        c.packet_items = c.packet_items + 1;
        c.items[key] = (c.items[key] or 0) + 1;
        local log_name = item_log_name_by_id(item_id);
        local log_key = (log_name ~= nil and log_name ~= '') and log_name:lower() or nil;
        if (log_key ~= nil and log_key ~= key) then c.items[log_key] = (c.items[log_key] or 0) + 1; end
    else
        if ((c.items[key] or 0) > 0) then c.items[key] = c.items[key] - 1; return; end   -- echo of a packet booking
        if (c.packet_items > 0) then return; end   -- the packet path is live: it is authoritative
    end
    if (c.kill_id == nil) then                  -- lazy: an aborted open leaves no row
        c.kill_id = db.record_kill(c.display or c.name, c.server_id, tracker.current_zone_id, tracker.current_zone_name,
            0, tracker.SOURCE_CHEST, capture_vana_info(), {
                content_type   = 'Limbus',
                content_source = content_source_for('Limbus'),
            });
        if (c.kill_id == nil) then return; end
    end
    c.order = c.order + 1;
    db.record_drop(c.kill_id, -1, item_id or 0, item_name, 1, 1, c.order);
end

-- 0x002A while a Limbus chest is open: the "Obtained: {item}" message addressed to the player.
function M.handle_limbus_reward(data)
    if (limbus_chest_live() == nil or #data < 28) then return; end
    if (datreader == nil) then return; end
    local player = GetPlayerEntity();
    if (player == nil) then return; end
    local actor = sunpack('I', data, 0x04 + 1);
    if (unsigned_sid(actor) ~= unsigned_sid(player.ServerId)) then return; end
    local obtained = datreader.find_message_id(tracker.current_zone_id, 'Obtained: ');
    if (obtained == nil) then return; end       -- DAT unreadable: the text signal still covers it
    local mesnum = bit.band(sunpack('H', data, 0x1A + 1), 0x7FFF);
    local p0 = sunpack('I', data, 0x08 + 1);
    if (mesnum == obtained) then
        limbus_record_item(p0, item_name_by_id(p0), true);
        return;
    end
    -- the units line names its zone ("Acquired Apollyon Units: "), so the phrase is exact per zone
    local zn = tracker.current_zone_name or '';
    if (zn ~= '') then
        local units_id = datreader.find_message_id(tracker.current_zone_id, 'Acquired ' .. zn .. ' Units');
        if (units_id ~= nil and mesnum == units_id) then limbus_set_units(p0); end
    end
end

-- Leave the pattern unanchored for timestamp prefixes; capture through the last period in item names.
function M.handle_limbus_text(text)
    if (limbus_chest_live() == nil) then return; end
    local units = text:match('Acquired %a+ Units: (%d+)');
    if (units ~= nil) then limbus_set_units(tonumber(units)); return; end
    local name = text:match('Obtained: (.+)%.');
    if (name == nil) then return; end
    name = name:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', '');
    limbus_record_item(nil, name, false);
end

-- Colonization/Lair spoils arrive through 0x02A, outside the treasure pool. Buffer them through
-- Reive Mark loss, then write one coffer row when the victory line identifies the kind or the
-- spoils timer expires. Wildskeeper rewards use event 2007 on the Naakual kill.
local REIVE_SPOILS_WINDOW = 10.0;   -- seconds after the Mark dropped in which spoils still belong to it
local REIVE_FLUSH_DELAY   = 5.0;    -- write the row this long after the last spoil without a victory line

local function reive_open()
    local w = tracker.wildskeeper;
    if (w == nil) then return false; end
    if (w.active) then return true; end
    return w.mark_off_at ~= nil and (os.clock() - w.mark_off_at) <= REIVE_SPOILS_WINDOW;
end

local function reive_kind()
    local w = tracker.wildskeeper;
    if (w == nil) then return nil; end
    -- A defeated Naakual settles it even when no chat line named the Reive (loaded mid-Reive).
    if (w.last_boss_name ~= nil) then return 'Wildskeeper'; end
    return w.kind or w.last_kind;
end

local function reive_content_name()
    local k = reive_kind();
    if (k == 'Colonization') then return 'Colonization Reive'; end
    if (k == 'Lair') then return 'Lair Reive'; end
    return 'Reive';
end

-- Write the buffered spoils as one row. A Wildskeeper kind means the buffer was the Naakual's
-- spoils seen before the kind was known: event 2007 owns those, so drop them.
local function reive_flush()
    local r = tracker.reive_spoils;
    if (r == nil) then return; end
    tracker.reive_spoils = nil;
    if (db == nil or #r.pending == 0 or reive_kind() == 'Wildskeeper') then return; end
    local name = reive_content_name();
    local kill_id = db.record_kill(name, 0, tracker.current_zone_id, tracker.current_zone_name,
        0, tracker.SOURCE_COFFER, capture_vana_info(), {
            content_type   = name,
            content_source = content_source_for(name),
        });
    if (kill_id == nil) then return; end
    for _, it in ipairs(r.pending) do
        db.record_drop(kill_id, -1, it.id, it.name, 1, 1, it.order);
    end
end

-- Packets are authoritative once present; chat echoes pair off by count, as for the Limbus chest.
local function reive_record_item(item_id, item_name, from_packet)
    if (item_name == nil or item_name == '' or item_name == 'Unknown') then return; end
    if (tracker.reive_spoils == nil and not reive_open()) then return; end
    if (reive_kind() == 'Wildskeeper') then return; end
    local r = tracker.reive_spoils;
    if (r == nil) then
        r = { pending = {}, packet_items = 0, echo = {}, order = 0, last_at = os.clock() };
        tracker.reive_spoils = r;
    end
    local key = item_name:lower();
    if (from_packet) then
        r.packet_items = r.packet_items + 1;
        r.echo[key] = (r.echo[key] or 0) + 1;
        local log_name = item_log_name_by_id(item_id);
        local log_key = (log_name ~= nil and log_name ~= '') and log_name:lower() or nil;
        if (log_key ~= nil and log_key ~= key) then r.echo[log_key] = (r.echo[log_key] or 0) + 1; end
    else
        if ((r.echo[key] or 0) > 0) then r.echo[key] = r.echo[key] - 1; return; end
        if (r.packet_items > 0) then return; end
    end
    r.order = r.order + 1;
    r.last_at = os.clock();
    r.pending[#r.pending + 1] = { id = item_id or 0, name = item_name, order = r.order };
end

-- 0x002A "Obtained: {item}" addressed to the player while a Reive is (or just was) up.
function M.handle_reive_reward(data)
    if (#data < 28 or datreader == nil) then return; end
    if (tracker.reive_spoils == nil and not reive_open()) then return; end
    local player = GetPlayerEntity();
    if (player == nil) then return; end
    if (unsigned_sid(sunpack('I', data, 0x04 + 1)) ~= unsigned_sid(player.ServerId)) then return; end
    local obtained = datreader.find_message_id(tracker.current_zone_id, 'Obtained: ');
    if (obtained == nil) then return; end
    if (bit.band(sunpack('H', data, 0x1A + 1), 0x7FFF) ~= obtained) then return; end
    local p0 = sunpack('I', data, 0x08 + 1);
    reive_record_item(p0, item_name_by_id(p0), true);
end

-- The chat side: "Obtained: <item>." echoes, and the victory line that closes the row. Runs AFTER
-- tracker.handle_reive_text, which has already read the kind off the same line.
function M.handle_reive_text(text)
    if (text:match('victorious in the (%a+) Reive') ~= nil) then
        -- Only YOUR victory line closes the row; a party member's line can land between two spoils.
        local player = GetPlayerEntity();
        local mine = (player == nil or player.Name == nil) or (text:find(player.Name .. ' is victorious in the ', 1, true) ~= nil);
        if (mine) then reive_flush(); end
        return;
    end
    if (tracker.reive_spoils == nil and not reive_open()) then return; end
    local name = text:match('Obtained: (.+)%.');
    if (name == nil) then return; end
    name = name:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', '');
    reive_record_item(nil, name, false);
end

-- Per frame: a Reive that ended without a victory line still gets its row.
function M.check_reive_timeout()
    local r = tracker.reive_spoils;
    if (r ~= nil and (os.clock() - r.last_at) > REIVE_FLUSH_DELAY) then reive_flush(); end
end

-- WoE coffer event 1601: ten u16 item slots at 0x0C; outgoing 0x05B options 1-10 select slots,
-- 11 relinquishes, 12 requests all. Flag +0x0E is 1 while open, 0 on close.
-- DAT-resolved 0x02A rewards name the coffer and item in p0; pair chat echoes with packet rewards.
-- Store offered=0, taken=1, relinquished=-1.
local WOE_COFFER_WINDOW = 600.0;   -- the walk is over; the coffer waits until the player leaves
local WOE_COFFER_EVENT  = 1601;
local WOE_OPT_RELINQUISH, WOE_OPT_OBTAIN_ALL = 11, 12;

local function in_walk_of_echoes()
    return classify.INSTANCE_ZONES[tracker.current_zone_id] == 'Walk of Echoes';
end

-- Remember the walk from conflux event 1000, option 1. Ignore browsing and exit event 1001.
-- Retain it through the coffer reward until a new entry, zone change or reset.
local WOE_CONFLUX_EVENT = 1000;
local WOE_OPT_ENTER     = 1;

local function woe_walk_live()
    local w = tracker.woe_walk;
    if (w == nil) then return nil; end
    if (not in_walk_of_echoes()) then tracker.woe_walk = nil; tracker.woe_conflux_pending = nil; return nil; end
    return w;
end

-- On reload inside a walk, recover its number only from one live exit conflux.
-- The lobby has multiple confluxes; ignore stale slots and leave ambiguous walks unnamed.
local WOE_RECOVER_EVERY = 5.0;
local function woe_recover_walk()
    if (tracker.woe_conflux_pending ~= nil) then return; end
    local now = os.clock();
    if (tracker.woe_recover_at ~= nil and (now - tracker.woe_recover_at) < WOE_RECOVER_EVERY) then return; end
    tracker.woe_recover_at = now;
    local ok, found, count = pcall(function()
        local mem = AshitaCore:GetMemoryManager(); if (mem == nil) then return nil, 0; end
        local entity = mem:GetEntity(); if (entity == nil) then return nil, 0; end
        local hit, n_hits = nil, 0;
        for i = 1, 1023 do
            local name = entity:GetName(i);
            if (name ~= nil and #name > 0 and entity:GetRenderFlags0(i) ~= 0) then
                local n = name:gsub('%s+', ''):lower():match('^veridicalconflux#(%d+)$');
                if (n ~= nil) then
                    n_hits = n_hits + 1;
                    hit = { number = tonumber(n), server_id = entity:GetServerId(i) };
                end
            end
        end
        return hit, n_hits;
    end);
    if (ok and found ~= nil and count == 1) then
        tracker.woe_walk = { name = ('Walk #%d'):format(found.number), server_id = found.server_id };
    end
end

--- The walk the player is in (or just finished), for the kill-row battlefield column. nil outside.
function M.woe_walk_name()
    local w = woe_walk_live();
    if (w == nil and in_walk_of_echoes()) then woe_recover_walk(); w = tracker.woe_walk; end
    return w and w.name or nil;
end

local function woe_conflux_entered(server_id)
    local p = tracker.woe_conflux_pending;
    if (p == nil or unsigned_sid(p.server_id) ~= unsigned_sid(server_id)) then return; end
    tracker.woe_walk = { name = ('Walk #%d'):format(p.number), server_id = server_id };
    tracker.woe_conflux_pending = nil;
end

local function woe_coffer_live()
    local c = tracker.woe_coffer;
    if (c == nil) then return nil; end
    if ((os.clock() - c.armed_at) > WOE_COFFER_WINDOW or not in_walk_of_echoes()) then
        tracker.woe_coffer = nil; return nil;
    end
    return c;
end

local function woe_pending_slots(c)
    local slots = {};
    for slot in pairs(c.pending) do slots[#slots + 1] = slot; end
    table.sort(slots);
    return slots;
end

local function woe_mark(c, slot, won, from_packet)
    if (db == nil or c.kill_id == nil or not c.pending[slot]) then return; end
    db.update_drop_won(c.kill_id, slot, won, 0, nil, c.drop_ids[slot]);
    c.pending[slot] = nil;
    if (from_packet) then
        c.packet_marks = c.packet_marks + 1;
        local id = c.offered[slot];
        for _, n in ipairs({ item_name_by_id(id), item_log_name_by_id(id) }) do
            if (n ~= nil and n ~= '' and n ~= 'Unknown') then
                local k = n:lower(); c.echo[k] = (c.echo[k] or 0) + 1;
            end
        end
    end
end

local function woe_close(c, won)
    for _, slot in ipairs(woe_pending_slots(c)) do woe_mark(c, slot, won, false); end
    tracker.woe_coffer = nil;
end

-- 0x034 from the coffer: the offer. A reopened menu re-sends it; the row is created once.
function M.handle_woe_coffer_event(data)
    local c = woe_coffer_live();
    if (c == nil or db == nil or #data < 0x2E) then return false; end
    if (unsigned_sid(sunpack('I', data, 0x04 + 1)) ~= unsigned_sid(c.server_id)) then return false; end
    if (sunpack('H', data, 0x2C + 1) ~= WOE_COFFER_EVENT) then return false; end
    if (c.kill_id ~= nil) then return true; end
    local offered = {};
    for slot = 0, 9 do
        local id = sunpack('H', data, 0x0C + slot * 2 + 1);
        if (id ~= nil and id > 0) then offered[slot] = id; end
    end
    if (next(offered) == nil) then return false; end
    local walk = M.woe_walk_name();
    c.kill_id = db.record_kill(walk and ('Treasure Coffer (%s)'):format(walk) or 'Treasure Coffer',
        c.server_id, tracker.current_zone_id, tracker.current_zone_name,
        0, tracker.SOURCE_COFFER, capture_vana_info(), {
            content_type   = 'Walk of Echoes',
            content_source = content_source_for('Walk of Echoes'),
            battlefield    = walk,
        });
    if (c.kill_id == nil) then return false; end
    for slot = 0, 9 do
        local id = offered[slot];
        if (id ~= nil) then
            c.offered[slot] = id; c.pending[slot] = true;
            c.drop_ids[slot] = db.record_drop(c.kill_id, slot, id, item_name_by_id(id), 1, 0);
        end
    end
    return true;
end

-- 0x02A from the coffer: one item taken (p0 = item id). The first still-pending slot holding that
-- id is the one -- an offer may hold the same item twice, and each take is its own message.
function M.handle_woe_coffer_obtained(data)
    local c = woe_coffer_live();
    if (c == nil or c.kill_id == nil or datreader == nil or #data < 28) then return; end
    if (unsigned_sid(sunpack('I', data, 0x04 + 1)) ~= unsigned_sid(c.server_id)) then return; end
    local obtained = datreader.find_message_id(tracker.current_zone_id, 'Obtained: ');
    if (obtained == nil) then return; end
    if (bit.band(sunpack('H', data, 0x1A + 1), 0x7FFF) ~= obtained) then return; end
    local id = sunpack('I', data, 0x08 + 1);
    for _, slot in ipairs(woe_pending_slots(c)) do
        if (c.offered[slot] == id) then woe_mark(c, slot, 1, true); return; end
    end
end

-- Pair chat echoes with packet-marked slots; text books independently only without decoded packet rewards.
function M.handle_woe_coffer_text(text)
    local c = woe_coffer_live();
    if (c == nil or c.kill_id == nil) then return; end
    local name = text:match('Obtained: (.+)%.');
    if (name == nil) then return; end
    name = name:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', ''):lower();
    if ((c.echo[name] or 0) > 0) then c.echo[name] = c.echo[name] - 1; return; end
    if (c.packet_marks > 0) then return; end
    for _, slot in ipairs(woe_pending_slots(c)) do
        local id = c.offered[slot];
        local short, long = item_name_by_id(id), item_log_name_by_id(id);
        if ((short ~= nil and short:lower() == name) or (long ~= nil and long:lower() == name)) then
            woe_mark(c, slot, 1, false); return;
        end
    end
end

-- Conflux option 1 enters. Coffer option 11 relinquishes; 12 requests all, but packets confirm
-- what fits. Close settles remaining slots as not obtained.
function M.handle_woe_menu_option(data)
    if (#data < 0x14 or not in_walk_of_echoes()) then return; end
    local sid     = sunpack('I', data, 0x04 + 1);
    local option  = sunpack('I', data, 0x08 + 1);
    local is_open = sunpack('H', data, 0x0E + 1);
    local event   = sunpack('H', data, 0x12 + 1);
    if (event == WOE_CONFLUX_EVENT) then
        if (option == WOE_OPT_ENTER and is_open == 1) then woe_conflux_entered(sid); end
        return;
    end
    local c = woe_coffer_live();
    if (c == nil or event ~= WOE_COFFER_EVENT) then return; end
    if (unsigned_sid(sid) ~= unsigned_sid(c.server_id)) then return; end
    if (option == WOE_OPT_RELINQUISH) then
        woe_close(c, -1);
    elseif (option == WOE_OPT_OBTAIN_ALL) then
        if (is_open == 0) then woe_close(c, -1); end   -- the takes marked themselves; leftovers did not fit
    end
end

function M.handle_outgoing_trade(data)
    if (db == nil) then return; end
    if (#data < 0x3C) then return; end

    local target_index = sunpack('H', data, 0x3A + 1);
    local server_id    = sunpack('I', data, 0x04 + 1);
    local name         = get_entity_name(target_index);

    local ctype = container_type_from_name(name);
    if (ctype == nil) then return; end

    tracker.last_interact = {
        server_id    = server_id,
        target_index = target_index,
        name         = name,
        timestamp    = os.clock(),
    };
    arm_chest_pending(ctype, 'interact');
end

-- The interact arm: chest/coffer pending + the Limbus reward window. Moved verbatim out of
-- handle_outgoing_action, which stays in tracker because it also feeds the pool and Voidwatch.
function M.on_interact(name, server_id)
    local ctype = container_type_from_name(name);
    if (ctype ~= nil and db ~= nil) then
        arm_chest_pending(ctype, 'interact');
    end
    -- Normalize spaces: packet names are truncated while client entity names contain full spaced names.
    local squashed = (name ~= nil) and name:gsub('%s+', ''):lower() or '';
    -- A portal touch remembers WHICH walk; the entry itself is confirmed by the menu.
    if (in_walk_of_echoes()) then
        local n = squashed:match('^veridicalconflux#(%d+)$');
        if (n ~= nil) then tracker.woe_conflux_pending = { number = tonumber(n), server_id = server_id }; end
    end
    -- The coffer's reward menu (see the Walk of Echoes block above).
    if (squashed == 'treasurecoffer' and in_walk_of_echoes()) then
        local c = tracker.woe_coffer;
        if (c == nil or unsigned_sid(c.server_id) ~= unsigned_sid(server_id)) then
            tracker.woe_coffer = { armed_at = os.clock(), server_id = server_id, kill_id = nil, offered = {},
                                   pending = {}, drop_ids = {}, echo = {}, packet_marks = 0 };
        else
            c.armed_at = os.clock();
        end
    end
    -- Limbus interactions also open the reward window; TemenosCoffer and ApollyonCoffer use the coffer
    -- type.
    if (ctype ~= nil and in_limbus()) then
        tracker.limbus_chest = { armed_at = os.clock(), server_id = server_id, name = name, display = nil,
                                 bonus = nil, kill_id = nil, items = {}, order = 0, packet_items = 0 };
    end
end

return M;
