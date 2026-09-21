-- Treasure Hunter profile catalog and editor.

require 'common';

local imgui = require 'imgui';
local state = require 'ui_state';
local th    = require 'th';         -- TH settings / cache live in th.lua

local string_format = string.format;
local tostring      = tostring;

local an         = state.an;
local COLOR_GRAY = state.COLOR_GRAY;

-- Module refs, refreshed at every entry point
local db, tracker, s = nil, nil, nil;

local JOB_ABBRS = {
    [1]='WAR',[2]='MNK',[3]='WHM',[4]='BLM',[5]='RDM',[6]='THF',
    [7]='PLD',[8]='DRK',[9]='BST',[10]='BRD',[11]='RNG',[12]='SAM',[13]='NIN',
    [14]='DRG',[15]='SMN',[16]='BLU',[17]='COR',[18]='PUP',[19]='DNC',[20]='SCH',
    [21]='GEO',[22]='RUN',
};

local th_adv_open = { false };
local th_adv_profile_idx = { 0 };
local th_adv_items_cache = nil;
local th_adv_traits_cache = nil;
local th_adv_profile_id = nil;
local th_adv_dirty = true;
local th_adv_search_buf = { '' };
local th_adv_search_size = 64;

local th_add_open = false;
local th_add_item_id = { 0 };
local th_add_name_buf = { '' };
local th_add_name_size = 64;
local th_add_th_value = { 1 };
local th_add_slot_idx = { 0 };
local th_add_notes_buf = { '' };
local th_add_notes_size = 64;
local th_add_last_id = 0;  -- tracks last resolved ID for change detection

local th_trait_enabled_buf = { false };

local th_add_trait_open = false;
local th_add_trait_job_idx = { 5 };   -- default THF (index 5 in 0-based combo)
local th_add_trait_role_idx = { 0 };  -- 0=Main, 1=Sub
local th_add_trait_level = { 1 };
local th_add_trait_th = { 1 };

local th_new_profile_buf = { '' };
local th_new_profile_size = 64;
local th_new_profile_open = false;
local th_clone_mode = false;
local th_new_profile_error = '';

local th_profiles_cache = nil;
local th_profiles_dirty = true;

local function get_th_profiles_cached()
    if (th_profiles_dirty or th_profiles_cache == nil) then
        th_profiles_cache = db.get_th_profiles();
        th_profiles_dirty = false;
    end
    return th_profiles_cache;
end

local COLOR_YELLOW, COLOR_CYAN       = state.COLOR_YELLOW, state.COLOR_CYAN;

local TH_SLOT_LABELS = nil;
local TH_SLOT_COMBO = nil;

local function get_th_slot_combo()
    if (TH_SLOT_COMBO == nil and db ~= nil) then
        TH_SLOT_LABELS = {};
        for i = 0, 15 do TH_SLOT_LABELS[i + 1] = db.SLOT_NAMES[i] or '?'; end
        TH_SLOT_COMBO = table.concat(TH_SLOT_LABELS, '\0') .. '\0';
    end
    return TH_SLOT_COMBO;
end

local function slots_bitmask_to_idx(slots)
    if (slots == nil or slots == 0) then return 0; end
    for i = 0, 15 do
        if (bit.band(slots, bit.lshift(1, i)) ~= 0) then return i; end
    end
    return 0;
end

-- Follow the returned user profile ID after a copy-on-write edit of a shipped profile.
local function adopt_user_profile(uid)
    if (uid == nil or uid == th_adv_profile_id) then return; end
    th_adv_profile_id = uid;
    th_profiles_dirty = true;
end

local function refresh_th_adv_data(profile_id)
    if (profile_id == nil) then
        th_adv_items_cache = {};
        th_adv_traits_cache = {};
        return;
    end
    th_adv_items_cache = db.get_th_items(profile_id);
    th_adv_traits_cache = db.get_th_job_traits(profile_id);
    th_adv_profile_id = profile_id;
    th_adv_dirty = false;
end

local function render_th_advanced_window()
    if (not th_adv_open[1]) then return; end

    imgui.SetNextWindowSize({ 600, 500 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('TH Management##adv', th_adv_open, ImGuiWindowFlags_None)) then
        local profiles = get_th_profiles_cached();

        -- Profile selector
        local profile_names = {};
        for i, p in ipairs(profiles) do
            profile_names[i] = p.name;
            if (p.id == th_adv_profile_id) then
                th_adv_profile_idx[1] = i - 1;
            end
        end

        -- Default to first profile if none selected
        if (th_adv_profile_id == nil and #profiles > 0) then
            th_adv_profile_idx[1] = 0;
            refresh_th_adv_data(profiles[1].id);
        end

        local combo_str = (#profile_names > 0) and (table.concat(profile_names, '\0') .. '\0') or '\0';
        imgui.PushItemWidth(200);
        if imgui.Combo('Profile', th_adv_profile_idx, combo_str) then
            local sel = profiles[th_adv_profile_idx[1] + 1];
            if (sel ~= nil) then
                refresh_th_adv_data(sel.id);
            end
        end
        imgui.PopItemWidth();
        if imgui.IsItemHovered() then
            imgui.SetTooltip('TH profile defines which job traits and gear items grant TH.\nThe active profile is set in the Settings tab.\nUse different profiles for different servers (e.g., Retail vs HorizonXI).');
        end

        -- Profile actions
        imgui.SameLine();
        if imgui.Button('+ New') then
            th_new_profile_open = true;
            th_clone_mode = false;
            th_new_profile_buf[1] = '';
            th_new_profile_error = '';
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Create an empty profile with no traits or gear.');
        end
        imgui.SameLine();
        if imgui.Button('Clone') then
            th_new_profile_open = true;
            th_clone_mode = true;
            th_new_profile_buf[1] = '';
            th_new_profile_error = '';
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Duplicate the current profile with all its traits and gear.\nUseful for creating a server-specific variant.');
        end
        imgui.SameLine();
        local sel_p = nil;
        for _, p in ipairs(profiles) do
            if (p.id == th_adv_profile_id) then sel_p = p; break; end
        end
        if (sel_p ~= nil) then
            if (sel_p.origin == 'shipped') then
                imgui.TextColored(COLOR_GRAY, '[shipped]');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Ships with the addon and is never modified in place.\nEditing it creates your own copy automatically;\nthe original stays available to restore.');
                end
            elseif ((sel_p.has_default or 0) > 0) then
                imgui.TextColored(COLOR_YELLOW, '[modified]');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Your edited copy of a profile that ships with the addon.\nThe shipped original is untouched -- Reset restores it.');
                end
                imgui.SameLine();
                if imgui.Button('Reset') then
                    if (db.reset_th_profile(th_adv_profile_id)) then
                        th_adv_profile_id = nil;
                        th_adv_profile_idx[1] = 0;
                        th_adv_dirty = true;
                        th_profiles_dirty = true;
                        if (tracker ~= nil) then th.invalidate_th_cache(); end
                    end
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Discard your changes and go back to the shipped version.\nOnly your copy is removed; nothing else is affected.');
                end
            else
                imgui.TextColored(COLOR_CYAN, '[custom]');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('A profile you created. It is never overwritten by addon updates.');
                end
            end
            imgui.SameLine();
        end
        if (#profiles > 1 and th_adv_profile_id ~= nil) then
            -- Prevent deleting the active settings profile
            local is_active = false;
            if (s ~= nil and s.th_profile ~= nil) then
                for _, p in ipairs(profiles) do
                    if (p.id == th_adv_profile_id and p.name == s.th_profile) then
                        is_active = true;
                        break;
                    end
                end
            end
            -- A shipped profile has no user row to delete; Reset is the operation that applies.
            local is_shipped = (sel_p ~= nil and sel_p.origin == 'shipped');
            if (is_active or is_shipped) then
                imgui.BeginDisabled();
                imgui.Button('Delete');
                imgui.EndDisabled();
                if imgui.IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled) then
                    imgui.SetTooltip(is_shipped
                        and 'Shipped profiles cannot be deleted -- they are part of the addon.\nEdit it to make your own copy, or use Clone.'
                        or  'Cannot delete the active profile. Switch to a different profile first.');
                end
            else
                if imgui.Button('Delete') then
                    db.delete_th_profile(th_adv_profile_id);
                    th_adv_profile_id = nil;
                    th_adv_profile_idx[1] = 0;
                    th_adv_dirty = true;
                    th_profiles_dirty = true;
                    if (tracker ~= nil) then th.invalidate_th_cache(); end
                end
            end
        end

        -- New/Clone profile modal
        if (th_new_profile_open) then
            imgui.OpenPopup('New TH Profile##modal');
            th_new_profile_open = false;
        end
        if imgui.BeginPopupModal('New TH Profile##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
            imgui.Text(th_clone_mode and 'Clone profile as:' or 'New profile name:');
            imgui.PushItemWidth(200);
            imgui.InputText('##th_new_name', th_new_profile_buf, th_new_profile_size);
            imgui.PopItemWidth();
            if (th_new_profile_error ~= '') then
                imgui.TextColored({1, 0.3, 0.3, 1}, th_new_profile_error);
            end
            if imgui.Button('Create') then
                local name = th_new_profile_buf[1];
                if (name == nil or name == '') then
                    th_new_profile_error = 'Name cannot be empty.';
                else
                    local new_id;
                    if (th_clone_mode and th_adv_profile_id ~= nil) then
                        new_id = db.clone_th_profile(th_adv_profile_id, name);
                    else
                        new_id = db.create_th_profile(name);
                    end
                    if (new_id ~= nil) then
                        refresh_th_adv_data(new_id);
                        th_profiles_dirty = true;
                        if (tracker ~= nil) then th.invalidate_th_cache(); end
                        th_new_profile_error = '';
                        imgui.CloseCurrentPopup();
                    else
                        th_new_profile_error = 'Profile "' .. name .. '" already exists.';
                    end
                end
            end
            imgui.SameLine();
            if imgui.Button('Cancel') then
                imgui.CloseCurrentPopup();
            end
            imgui.EndPopup();
        end

        if (th_adv_dirty and th_adv_profile_id ~= nil) then
            refresh_th_adv_data(th_adv_profile_id);
        end

        imgui.Separator();

        if (th_adv_profile_id ~= nil) then
            -- Job Traits section
            if imgui.CollapsingHeader('Job Traits', ImGuiTreeNodeFlags_DefaultOpen) then
                -- Add Trait button (top of section)
                if imgui.SmallButton('+ Add Trait') then
                    th_add_trait_open = true;
                    th_add_trait_job_idx[1] = 5;  -- THF
                    th_add_trait_role_idx[1] = 0;  -- Main
                    th_add_trait_level[1] = 1;
                    th_add_trait_th[1] = 1;
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Add a job trait that grants TH at a certain level.\nUseful for private servers with custom TH on non-THF jobs.');
                end

                -- Add Trait modal
                if (th_add_trait_open) then
                    imgui.OpenPopup('Add Job Trait##modal');
                    th_add_trait_open = false;
                end
                if imgui.BeginPopupModal('Add Job Trait##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                    local job_combo = 'WAR\0MNK\0WHM\0BLM\0RDM\0THF\0PLD\0DRK\0BST\0BRD\0RNG\0SAM\0NIN\0DRG\0SMN\0BLU\0COR\0PUP\0DNC\0SCH\0GEO\0RUN\0';
                    imgui.PushItemWidth(100);
                    imgui.Combo('Job', th_add_trait_job_idx, job_combo);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('The job that receives this TH trait.');
                    end
                    imgui.Combo('Role', th_add_trait_role_idx, 'Main\0Sub\0');
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Main = when this job is your main job.\nSub = when this job is your subjob (usually lower TH).');
                    end
                    imgui.InputInt('Min Level', th_add_trait_level);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Minimum job level required to activate this trait.\nRetail THF gets TH at 15, 45, and 90.');
                    end
                    imgui.SliderInt('TH Value', th_add_trait_th, 1, 10);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('TH level granted by this trait.\nHigher-tier traits replace lower ones (they do not stack).');
                    end
                    imgui.PopItemWidth();

                    -- Clamp level
                    if (th_add_trait_level[1] < 1) then th_add_trait_level[1] = 1; end
                    if (th_add_trait_level[1] > 99) then th_add_trait_level[1] = 99; end

                    imgui.Spacing();
                    imgui.TextDisabled('For private servers with custom TH traits.');
                    imgui.TextDisabled('Retail THF traits are pre-populated.');

                    if imgui.Button('Add##trait') then
                        if (th_adv_profile_id ~= nil) then
                            local job_id = th_add_trait_job_idx[1] + 1;  -- combo is 0-based, jobs are 1-based
                            local is_main = (th_add_trait_role_idx[1] == 0) and 1 or 0;
                            db.add_th_job_trait(th_adv_profile_id, job_id, is_main, th_add_trait_level[1], th_add_trait_th[1]);
                            adopt_user_profile(db.materialize_th_profile(th_adv_profile_id));
                            th_adv_dirty = true;
                            if (tracker ~= nil) then th.invalidate_th_cache(); end
                        end
                        imgui.CloseCurrentPopup();
                    end
                    imgui.SameLine();
                    if imgui.Button('Cancel##trait') then
                        imgui.CloseCurrentPopup();
                    end
                    imgui.EndPopup();
                end

                imgui.Spacing();

                if (th_adv_traits_cache ~= nil and #th_adv_traits_cache > 0) then
                    for _, trait in ipairs(th_adv_traits_cache) do
                        local role = trait.is_main == 1 and 'Main' or 'Sub';
                        local job_abbr = JOB_ABBRS[trait.job_id] or ('Job' .. tostring(trait.job_id));
                        local trait_label = string_format('%s %s  Lv%d: +%d', job_abbr, role, trait.min_level, trait.th_value);
                        if (trait.job_id == 16) then
                            trait_label = trait_label .. '  (spell-set)';
                        end

                        -- Enable/disable checkbox
                        th_trait_enabled_buf[1] = (trait.enabled ~= 0);
                        if imgui.Checkbox('##trait_en_' .. tostring(trait.id), th_trait_enabled_buf) then
                            -- by identity within the PROFILE, never by row id (a shipped row id
                            -- names an unrelated custom row in the user store)
                            adopt_user_profile(db.set_th_job_trait_enabled(th_adv_profile_id,
                                trait.job_id, trait.is_main, trait.min_level, th_trait_enabled_buf[1]));
                            th_adv_dirty = true;
                            if (tracker ~= nil) then th.invalidate_th_cache(); end
                        end
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(th_trait_enabled_buf[1] and 'Disable this trait (keeps it for later)' or 'Enable this trait');
                        end
                        imgui.SameLine();
                        if (trait.enabled == 0) then
                            imgui.TextDisabled(trait_label);
                        else
                            imgui.Text(trait_label);
                        end
                        if imgui.IsItemHovered() then
                            if (trait.job_id == 16) then
                                imgui.SetTooltip('BLU spell-set TH trait.\nRequires Charged Whisker + Everyone\'s Grudge + Amorphic Spikes all set.\nDetected automatically from memory. Use /loot bluspells to verify.');
                            else
                                imgui.SetTooltip(string_format('%s %s job: grants TH+%d at level %d and above.\nUncheck to disable without deleting. X to remove permanently.',
                                    job_abbr, role, trait.th_value, trait.min_level));
                            end
                        end
                        imgui.SameLine();
                        if imgui.SmallButton('X##trait_' .. tostring(trait.id)) then
                            adopt_user_profile(db.delete_th_job_trait(th_adv_profile_id,
                                trait.job_id, trait.is_main, trait.min_level));
                            th_adv_dirty = true;
                            if (tracker ~= nil) then th.invalidate_th_cache(); end
                        end
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip('Delete this trait permanently.');
                        end
                    end
                else
                    imgui.TextDisabled('  No job traits defined.');
                end

                if (tracker ~= nil and tracker.th_trust_source ~= nil) then
                    imgui.TextDisabled('  Trust/Pet TH1 active: ' .. tracker.th_trust_source);
                end
            end

            imgui.Spacing();

            -- TH Gear section
            if imgui.CollapsingHeader('TH Gear', ImGuiTreeNodeFlags_DefaultOpen) then
                imgui.TextDisabled('Augmented TH (e.g., Herculean +TH) is auto-detected at scan time.');
                imgui.TextDisabled('Add items here for intrinsic TH gear or custom server items.');
                -- Search + Add
                imgui.PushItemWidth(200);
                imgui.InputTextWithHint('##th_search', 'Search by name or notes...', th_adv_search_buf, th_adv_search_size);
                imgui.PopItemWidth();
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Filter items by name or notes.');
                end
                imgui.SameLine();
                if imgui.Button('+ Add Item') then
                    th_add_open = true;
                    th_add_item_id[1] = 0;
                    th_add_name_buf[1] = '';
                    th_add_th_value[1] = 1;
                    th_add_slot_idx[1] = 0;
                    th_add_notes_buf[1] = '';
                    th_add_last_id = 0;
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Add a gear item that grants TH when equipped.\nEnter the item ID and name/slot/TH auto-fill from game data.\nSet TH=0 for augmentable gear (augments detected automatically).');
                end

                -- Add item modal
                if (th_add_open) then
                    imgui.OpenPopup('Add TH Item##modal');
                    th_add_open = false;
                end
                if imgui.BeginPopupModal('Add TH Item##modal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                    imgui.PushItemWidth(120);
                    if imgui.InputInt('Item ID', th_add_item_id) then
                        -- ID changed auto-fill name, slot, and TH value from resource
                        local cur_id = th_add_item_id[1];
                        if (cur_id > 0 and cur_id ~= th_add_last_id) then
                            th_add_last_id = cur_id;
                            local res = AshitaCore:GetResourceManager();
                            if (res ~= nil) then
                                local ritem = res:GetItemById(cur_id);
                                if (ritem ~= nil) then
                                    if (ritem.Name ~= nil and ritem.Name[1] ~= nil) then
                                        th_add_name_buf[1] = ritem.Name[1];
                                    end
                                    th_add_slot_idx[1] = slots_bitmask_to_idx(ritem.Slots);
                                end
                            end
                            -- Pre fill TH value from existing profile entry if present
                            if (th_adv_profile_id ~= nil) then
                                local existing = db.get_th_items_by_item_id(th_adv_profile_id);
                                if (existing ~= nil and existing[cur_id] ~= nil) then
                                    th_add_th_value[1] = existing[cur_id].th_value or 1;
                                else
                                    th_add_th_value[1] = 1;
                                end
                            end
                        elseif (cur_id <= 0) then
                            th_add_last_id = 0;
                            th_add_name_buf[1] = '';
                            th_add_th_value[1] = 1;
                            th_add_slot_idx[1] = 0;
                        end
                    end
                    imgui.PopItemWidth();

                    imgui.PushItemWidth(200);
                    imgui.InputText('Item Name', th_add_name_buf, th_add_name_size);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Auto-filled from game data when a valid Item ID is entered.');
                    end
                    imgui.PopItemWidth();
                    imgui.PushItemWidth(120);
                    imgui.SliderInt('TH Value', th_add_th_value, 0, 10);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Intrinsic TH granted by this item.\nSet to 0 for augmentable gear (TH detected from augments).\nSet to the actual TH value for items with built-in TH.');
                    end
                    imgui.Combo('Slot', th_add_slot_idx, get_th_slot_combo() or '');
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Equipment slot this item occupies.\nAuto-filled from game data when a valid Item ID is entered.');
                    end
                    imgui.PopItemWidth();
                    imgui.PushItemWidth(200);
                    imgui.InputText('Notes', th_add_notes_buf, th_add_notes_size);
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip('Optional notes (e.g., "augmentable", "private server only").');
                    end
                    imgui.PopItemWidth();

                    imgui.Spacing();
                    imgui.TextDisabled('TH=0 for augmentable gear (TH detected from augments).');
                    imgui.TextDisabled('Set TH value for intrinsic or custom server items.');

                    if imgui.Button('Add') then
                        if (th_add_item_id[1] > 0 and th_adv_profile_id ~= nil) then
                            db.add_th_item(
                                th_adv_profile_id,
                                th_add_item_id[1],
                                th_add_name_buf[1] or '',
                                th_add_th_value[1],
                                th_add_slot_idx[1],
                                th_add_notes_buf[1] or ''
                            );
                            adopt_user_profile(db.materialize_th_profile(th_adv_profile_id));
                            th_adv_dirty = true;
                            if (tracker ~= nil) then th.invalidate_th_cache(); end
                        end
                        imgui.CloseCurrentPopup();
                    end
                    imgui.SameLine();
                    if imgui.Button('Cancel##add') then
                        imgui.CloseCurrentPopup();
                    end
                    imgui.EndPopup();
                end

                -- Items table
                if (th_adv_items_cache ~= nil and #th_adv_items_cache > 0) then
                    local search = (th_adv_search_buf[1] or ''):lower();
                    local flags = ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg + ImGuiTableFlags_ScrollY
                        + ImGuiTableFlags_Resizable + ImGuiTableFlags_SizingStretchProp;
                    if imgui.BeginTable('th_items_tbl', 6, flags, { 0, 280 }) then
                        imgui.TableSetupColumn('ID', ImGuiTableColumnFlags_WidthFixed, 55);
                        imgui.TableSetupColumn('Name', ImGuiTableColumnFlags_WidthStretch);
                        imgui.TableSetupColumn('TH', ImGuiTableColumnFlags_WidthFixed, 35);
                        imgui.TableSetupColumn('Slot', ImGuiTableColumnFlags_WidthFixed, 55);
                        imgui.TableSetupColumn('Notes', ImGuiTableColumnFlags_WidthFixed, 120);
                        imgui.TableSetupColumn('', ImGuiTableColumnFlags_WidthFixed, 25);
                        imgui.TableHeadersRow();

                        for _, item in ipairs(th_adv_items_cache) do
                            local name_lower = (item.item_name or ''):lower();
                            local notes_lower = (item.notes or ''):lower();
                            if (search == '' or name_lower:find(search, 1, true) or notes_lower:find(search, 1, true)) then
                                imgui.TableNextRow();
                                imgui.TableNextColumn();
                                imgui.Text(tostring(item.item_id));
                                imgui.TableNextColumn();
                                imgui.Text(item.item_name or '');
                                imgui.TableNextColumn();
                                if (item.th_value > 0) then
                                    imgui.Text('+' .. tostring(item.th_value));
                                    if imgui.IsItemHovered() then
                                        imgui.SetTooltip(string_format('Intrinsic TH+%d from this item.', item.th_value));
                                    end
                                else
                                    imgui.TextDisabled('aug');
                                    if imgui.IsItemHovered() then
                                        imgui.SetTooltip('TH from augments only (detected automatically at scan time).\nNo intrinsic TH value on the base item.');
                                    end
                                end
                                imgui.TableNextColumn();
                                local slot_name = db.SLOT_NAMES[item.slot_id] or '?';
                                imgui.Text(slot_name);
                                imgui.TableNextColumn();
                                local notes = item.notes or '';
                                if (notes ~= '') then
                                    imgui.TextDisabled(notes);
                                end
                                imgui.TableNextColumn();
                                if imgui.SmallButton('X##item_' .. tostring(item.id)) then
                                    adopt_user_profile(db.delete_th_item(th_adv_profile_id, item.item_id));
                                    th_adv_dirty = true;
                                    if (tracker ~= nil) then th.invalidate_th_cache(); end
                                end
                                if imgui.IsItemHovered() then
                                    imgui.SetTooltip('Remove this item from the profile.');
                                end
                            end
                        end
                        imgui.EndTable();
                    end

                    imgui.TextDisabled(string_format('Items: %d', #th_adv_items_cache));
                else
                    imgui.TextDisabled('  No TH gear items defined.');
                end
            end
        else
            imgui.TextDisabled('No profile selected.');
        end
    end
    imgui.End();
end

local M = {};

local function sync()
    db, tracker, s = state.db, state.tracker, state.s;
end

--- Raise the TH Management window (the Settings tab's button).
function M.open()
    th_adv_open[1] = true;
end

--- Cached profile list, shared with the Settings tab's profile combo.
function M.get_profiles()
    sync();
    return get_th_profiles_cached();
end

--- Invalidate the profile cache after an external catalog change.
function M.mark_dirty()
    th_profiles_dirty = true;
end

function M.render()
    sync();
    return render_th_advanced_window();
end

return M;
