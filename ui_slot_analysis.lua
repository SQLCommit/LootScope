-- Slot-analysis rendering. Share the analysis-state table; refresh settings references each frame.

require 'common';

local imgui = require 'imgui';
local state = require 'ui_state';
local widgets = require 'ui_widgets';   -- shared display primitives (help_marker)

local string_format = string.format;
local math_min      = math.min;

-- shared, aliased from ui_state (tables/strings: mutated, never reassigned)
local an                 = state.an;
local format_count       = state.format_count;
local build_instance_combo = state.build_instance_combo;
local walk_display_name    = state.walk_display_name;
local COLOR_CYAN        = state.COLOR_CYAN;
local COLOR_ERR         = state.COLOR_ERR;
local COLOR_GRAY        = state.COLOR_GRAY;
local COLOR_GREEN       = state.COLOR_GREEN;
local COLOR_LIGHT_GRAY  = state.COLOR_LIGHT_GRAY;
local COLOR_RED         = state.COLOR_RED;
local COLOR_WARN        = state.COLOR_WARN;
local COLOR_YELLOW      = state.COLOR_YELLOW;

-- Refresh shared references per render; initialization and character changes replace them.
local db, tracker, analysis, s = nil, nil, nil, nil;

-- private to this tab (verbatim from ui.lua)
local an_mob_sel = { 0 };
local ci_sort_keys = { 'item_name', 'drops', 'rate', 'ci_lower', 'ci_upper', 'ci_width', 'ci_width' };
local co_sort_keys = { 'name_a', 'name_b', 'observed', 'expected', 'deviation', 'order_consistency' };

local function reset_an_filter(new_source)
    an.source_filter = new_source;
    an.cache_dirty = true;
    an.zone_filter = -1;
    an.name_filter = nil;
    an.mob_filter = nil;
    an.mob_level_cap = nil;
    an.effective_sf = nil;
    an.mob_idx[1] = 0;
    an.result = nil;
    an.mob_stats = nil;
    an.ci_sort_col = 0;
    an.ci_sort_asc = false;
    an.co_sort_col = 0;
    an.co_sort_asc = false;
    an.mob_combo = { str = '', mobs = nil, key = '' };
    an.mob_content = nil;
end

-- All Instances rows carry their content; the query runs through that content's own filter.
local ct_to_sf = nil;
local function sf_for_content(ct)
    if (ct == nil or ct == '') then return nil; end
    if (ct_to_sf == nil) then
        ct_to_sf = {};
        for k, v in pairs(db.CONTENT_TYPE_MAP) do ct_to_sf[v] = k; end
    end
    return ct_to_sf[ct];
end

-- Reset statistics filters when switching category (file scope to avoid per-frame closure)

local function build_an_filter(source_filter)
    if (an.filter_combo.src == source_filter
        and an.filter_combo.entries ~= nil
        and not db.stats_dirty and not an.cache_dirty) then
        return an.filter_combo.str, an.filter_combo.entries;
    end

    local all_stats = db.get_all_mob_stats(source_filter);
    local entries = T{};
    local seen = {};

    if (source_filter == 2 or source_filter == 3 or source_filter == 8) then
        -- BCNM/HTBF/All BF: unique battlefield + zone + level_cap/difficulty combos
        for _, row in ipairs(all_stats) do
            -- sf=2: cap=level_cap, sf=3: cap=bf_difficulty, sf=8: detect per row
            local lc = row.level_cap or 0;
            local bd = row.bf_difficulty or 0;
            local cap, eff_sf;
            if (source_filter == 3 or (source_filter == 8 and bd > 0)) then
                cap = bd;
                eff_sf = 3;  -- HTBF path
            else
                cap = lc;
                eff_sf = 2;  -- BCNM path
            end

            local key = tostring(row.zone_id) .. '_' .. (row.mob_name or '') .. '_' .. tostring(lc) .. '_' .. tostring(bd);
            if (not seen[key]) then
                seen[key] = true;
                local label = row.zone_name .. ' - ' .. row.mob_name;
                if (bd > 0) then
                    label = label .. ' [' .. tracker.get_difficulty_label(bd) .. ']';
                elseif (lc > 0) then
                    label = label .. ' (Lv' .. tostring(lc) .. ')';
                end
                entries:append({
                    label = label,
                    zone_id = row.zone_id,
                    name = row.mob_name,
                    level_cap = cap,
                    effective_sf = eff_sf,
                });
            end
        end
    else
        -- All other types: unique zones
        for _, row in ipairs(all_stats) do
            if (not seen[row.zone_id]) then
                seen[row.zone_id] = true;
                entries:append({ label = row.zone_name, zone_id = row.zone_id, name = nil });
            end
        end
        -- Chest/Coffer: also include zones with only chest_events
        if (source_filter == 1) then
            local chest_stats = db.get_chest_stats();
            for _, row in ipairs(chest_stats) do
                if (not seen[row.zone_id]) then
                    seen[row.zone_id] = true;
                    entries:append({ label = row.zone_name or '', zone_id = row.zone_id, name = nil });
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.label < b.label; end);

    local parts = { 'Select...' };
    for _, e in ipairs(entries) do
        parts[#parts + 1] = e.label;
    end

    an.filter_combo.str = table.concat(parts, '\0') .. '\0\0';
    an.filter_combo.entries = entries;
    an.filter_combo.src = source_filter;

    return an.filter_combo.str, an.filter_combo.entries;
end

--- Build mob name combo for a selected zone/battlefield.
local function build_mob_combo(source_filter, zone_id, name_filter)
    local cache_key = tostring(source_filter) .. '_' .. tostring(zone_id) .. '_' .. tostring(name_filter or '');
    if (an.mob_combo.key == cache_key and an.mob_combo.mobs ~= nil and not db.stats_dirty and not an.cache_dirty) then
        return an.mob_combo.str, an.mob_combo.mobs;
    end

    local all_stats = db.get_all_mob_stats(source_filter);
    local mobs = T{};
    local seen = {};

    for _, row in ipairs(all_stats) do
        if (row.zone_id == zone_id) then
            local match = true;
            if (name_filter ~= nil and name_filter ~= '') then
                if (source_filter == 2) then
                    match = (row.mob_name == name_filter);
                elseif (source_filter == 3) then
                    match = (row.mob_name == name_filter);
                end
            end
            local mkey = row.mob_name .. '|' .. (row.content_type or '');
            if (match and not seen[mkey]) then
                seen[mkey] = true;
                local total = row.kill_count or 0;
                local distant = row.distant_kills or 0;
                mobs:append({
                    mob_name  = row.mob_name,
                    zone_id   = row.zone_id,
                    kills     = total - distant,
                    level_cap = row.level_cap or row.bf_difficulty,
                    content   = row.content_type,   -- All Instances only
                });
            end
        end
    end

    -- Sort by kill count descending (most data first)
    table.sort(mobs, function(a, b) return a.kills > b.kills; end);

    local parts = { (source_filter == 20) and 'Select walk...' or 'Select mob...' };
    for _, m in ipairs(mobs) do
        if (source_filter == 20) then
            parts[#parts + 1] = walk_display_name(m.mob_name) .. ' (' .. tostring(m.kills) .. ' runs)';
        elseif (m.content ~= nil and m.content ~= '') then
            parts[#parts + 1] = m.mob_name .. ' (' .. tostring(m.kills) .. ' kills) [' .. m.content .. ']';
        else
            parts[#parts + 1] = m.mob_name .. ' (' .. tostring(m.kills) .. ' kills)';
        end
    end

    an.mob_combo.str = table.concat(parts, '\0') .. '\0\0';
    an.mob_combo.mobs = mobs;
    an.mob_combo.key = cache_key;

    return an.mob_combo.str, an.mob_combo.mobs;
end

--- Render Section 1: Confidence Intervals.
local function render_ci_section(result, kills, kw)
    local ci = result.confidence;
    if (#ci == 0) then
        imgui.TextDisabled('No item drops recorded.');
        return;
    end

    if (kills < analysis.MIN_KILLS_CI) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Results below %d %s may be unreliable — more data improves accuracy.',
            kills, kw, analysis.MIN_KILLS_CI, kw));
    end

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_Sortable,
        ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##ci_table', 7, flags, { 0, math_min(#ci * 24 + 28, 300) }) then
        imgui.TableSetupColumn('Item', ImGuiTableColumnFlags_DefaultSort, 150);
        imgui.TableSetupColumn('Drops', ImGuiTableColumnFlags_PreferSortDescending, 50);
        imgui.TableSetupColumn('Rate', ImGuiTableColumnFlags_PreferSortDescending, 55);
        imgui.TableSetupColumn('CI Low', ImGuiTableColumnFlags_PreferSortAscending, 55);
        imgui.TableSetupColumn('CI High', ImGuiTableColumnFlags_PreferSortDescending, 55);
        imgui.TableSetupColumn('Width', ImGuiTableColumnFlags_PreferSortAscending, 55);
        imgui.TableSetupColumn('Reliability', 0, 70);
        imgui.TableHeadersRow();

        -- Read sort specs and sort only when spec changes (no per-frame sort)
        local sort_specs = imgui.TableGetSortSpecs();
        if (sort_specs ~= nil and sort_specs.Specs ~= nil) then
            local new_col = sort_specs.Specs.ColumnIndex + 1;
            local new_asc = (sort_specs.Specs.SortDirection == 1);
            if (new_col ~= an.ci_sort_col or new_asc ~= an.ci_sort_asc) then
                an.ci_sort_col = new_col;
                an.ci_sort_asc = new_asc;
                local key = ci_sort_keys[new_col];
                if (key ~= nil) then
                    if (new_asc) then
                        table.sort(ci, function(a, b) return a[key] < b[key]; end);
                    else
                        table.sort(ci, function(a, b) return a[key] > b[key]; end);
                    end
                end
            end
        end

        for _, row in ipairs(ci) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.item_name);
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('Item dropped %d times out of %d nearby %s.', row.drops, row.kills, kw));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('Observed rate: %d / %d = %.2f%%%%\nThis is the raw observed rate (drops / %s).', row.drops, row.kills, row.rate * 100, kw));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.ci_lower * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Lower end of the estimated 95%% confidence interval.\nRead both bounds together; a narrow range is more precise.');
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', row.ci_upper * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Upper end of the estimated 95%% confidence interval.\nRead both bounds together; a narrow range is more precise.');
            end

            -- Width color-coded
            imgui.TableNextColumn();
            local width_pct = row.ci_width * 100;
            local width_color = COLOR_GREEN;
            if (width_pct > 15) then width_color = COLOR_RED;
            elseif (width_pct > 5) then width_color = COLOR_WARN; end
            imgui.TextColored(width_color, string_format('%.1f%%', width_pct));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'CI Width = upper bound - lower bound = %.1f%%%%\n'
                    .. 'Narrower = more precise estimate.\n\n'
                    .. 'Green: up to 5 points | Yellow: over 5 to 15 | Red: over 15',
                    width_pct));
            end

            -- Reliability badge
            imgui.TableNextColumn();
            local rel_label, rel_color;
            if (width_pct <= 5) then
                rel_label = 'High'; rel_color = COLOR_GREEN;
            elseif (width_pct <= 15) then
                rel_label = 'Medium'; rel_color = COLOR_WARN;
            else
                rel_label = 'Low'; rel_color = COLOR_RED;
            end
            imgui.TextColored(rel_color, rel_label);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%d drops / %d %s = %.1f%%%%\n95%%%% CI: [%.1f%%%%, %.1f%%%%] (width %.1f%%%%)\n\n%s',
                    row.drops, row.kills, kw, row.rate * 100,
                    row.ci_lower * 100, row.ci_upper * 100, width_pct,
                    width_pct > 15 and ('More ' .. kw .. ' needed for tighter estimate.') or 'Narrower interval; incomplete or mixed data can still bias it.'));
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 2: Slot Count Estimation.
local function render_slot_section(result)
    local se = result.slot_estimate;
    if (se == nil) then return; end

    -- Headline: Estimated Slots (best evidence from all metrics)
    local est_slots = math.max(se.max_observed, math.ceil(se.rate_sum));
    imgui.TextColored(COLOR_GREEN, string_format('Estimated Slots: %d', est_slots));
    if imgui.IsItemHovered() then
        imgui.SetTooltip(string_format(
            'Most items in one kill: %d\nRounded-up rate sum: %d (from %.2f)\nDistinct items recorded: %d\n\nModel estimate: %d slot(s) from %d item types.\nThis does not establish the server\'s actual slot count.',
            se.max_observed, math.ceil(se.rate_sum), se.rate_sum,
            se.unique_items, est_slots, se.unique_items
        ));
    end
    imgui.Spacing();

    local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_NoHostExtendX);
    if imgui.BeginTable('##slot_tbl', 2, tflags) then
        imgui.TableSetupColumn('Label', 0, 200);
        imgui.TableSetupColumn('Value', 0, 250);

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Unique items seen:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.unique_items));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Distinct item types recorded, excluding gil.\nUnseen items and repeated types mean this is not\nan upper bound on the server\'s slot count.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Max items in one kill:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.max_observed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Most items seen together. Under a one-item-per-slot\nmodel, at least this many slots would be needed.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Sum of all rates:');
        imgui.TableNextColumn();
        local rate_color = (se.rate_sum > 1.0) and COLOR_GREEN or COLOR_LIGHT_GRAY;
        imgui.TextColored(rate_color, string_format('%.2f', se.rate_sum));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('A total above 1 means more than one item per kill\non average. It does not prove independent slot rolls.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Avg items per kill:');
        imgui.TableNextColumn(); imgui.Text(string_format('%.2f', se.avg_items_per_kill));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Average recorded item count per kill, excluding gil.\nThis describes the sample, not a confirmed slot count.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Separator(); imgui.Text('Empty kills (observed):');
        imgui.TableNextColumn(); imgui.Separator();
        imgui.Text(string_format('%d (%.1f%%)', se.empty_observed_count, se.empty_observed_rate * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip(string_format(
                'Kills where zero items dropped (excluding gil).\n'
                .. '%d out of %d kills (%.1f%%%%).\n\n'
                .. 'Compare with expected rate below to evaluate model fit.',
                se.empty_observed_count, se.total_kills, se.empty_observed_rate * 100));
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Empty kills (expected):');
        imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', se.empty_expected_rate * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Predicted from independent slot model:\nProduct of (1 - rate_i) for all items.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Model fit:');
        imgui.TableNextColumn();
        local dev = math.abs(se.empty_observed_rate - se.empty_expected_rate);
        local fit_label, fit_color;
        if (dev < 0.05) then
            fit_label = 'Good'; fit_color = COLOR_GREEN;
        elseif (dev < 0.15) then
            fit_label = 'Fair'; fit_color = COLOR_WARN;
        else
            fit_label = 'Poor'; fit_color = COLOR_RED;
        end
        imgui.TextColored(fit_color, string_format('%s (%.1f%% deviation)', fit_label, dev * 100));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Compares recorded empty kills with the model prediction.\nA close match supports this model but does not prove it.\nDifferences can reflect loot rules, mixed data, or chance.');
        end

        imgui.EndTable();
    end
end

--- Render Section 3: Items-Per-Kill Distribution.
local function render_distribution_section(result, kill_word)
    local dist = result.distribution;
    if (dist == nil or #dist.bins == 0) then
        imgui.TextDisabled('No distribution data.');
        return;
    end


    local bins = dist.bins;
    local max_k = #bins;

    -- Build float arrays for PlotHistogram (cached on dist to avoid per-frame alloc)
    if (dist._obs_vals == nil) then
        local obs = {};
        local exp = {};
        local mr = 0;
        for i = 1, max_k do
            obs[i] = bins[i].obs_rate;
            exp[i] = bins[i].exp_rate;
            if (bins[i].obs_rate > mr) then mr = bins[i].obs_rate; end
            if (bins[i].exp_rate > mr) then mr = bins[i].exp_rate; end
        end
        dist._obs_vals = obs;
        dist._exp_vals = exp;
        dist._max_rate = mr;
    end
    local obs_vals = dist._obs_vals;
    local exp_vals = dist._exp_vals;
    local max_rate = dist._max_rate;

    -- Two histograms side by side
    imgui.Text('Observed:');
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Actual distribution of items dropped per ' .. kill_word .. '.\nEach bar = how often that many items dropped.');
    end
    imgui.SameLine(215);
    imgui.Text('Expected (independent model):');
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Predicted distribution if all drop slots are\nindependent (Poisson Binomial model).\nShould match observed if model is correct.');
    end

    imgui.PlotHistogram('##obs_hist', obs_vals, max_k, 0, '', 0, max_rate * 1.2, { 200, 80 });
    if imgui.IsItemHovered() then
        local tip_parts = {};
        for i = 1, max_k do
            tip_parts[#tip_parts + 1] = string_format('%d items: %.1f%%%%', bins[i].items, bins[i].obs_rate * 100);
        end
        imgui.SetTooltip(table.concat(tip_parts, '\n'));
    end
    imgui.SameLine();
    imgui.PlotHistogram('##exp_hist', exp_vals, max_k, 0, '', 0, max_rate * 1.2, { 200, 80 });
    if imgui.IsItemHovered() then
        local tip_parts = {};
        for i = 1, max_k do
            tip_parts[#tip_parts + 1] = string_format('%d items: %.1f%%%%', bins[i].items, bins[i].exp_rate * 100);
        end
        imgui.SetTooltip(table.concat(tip_parts, '\n'));
    end

    imgui.Spacing();

    -- Comparison table
    local tflags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp);
    if imgui.BeginTable('##dist_table', 4, tflags, { 0, math_min(max_k * 24 + 28, 200) }) then
        imgui.TableSetupColumn('Items', 0, 50);
        imgui.TableSetupColumn('Observed', 0, 70);
        imgui.TableSetupColumn('Expected', 0, 70);
        imgui.TableSetupColumn('Diff', 0, 60);
        imgui.TableHeadersRow();

        for _, b in ipairs(bins) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(tostring(b.items));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Number of items (excluding gil) dropped in a single ' .. kill_word .. '.');
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', b.obs_rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Observed: %.1f%%%% of %ss dropped exactly %d item(s).',
                    b.obs_rate * 100, kill_word, b.items));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f%%', b.exp_rate * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected: %.1f%%%% from the Poisson Binomial model\n'
                    .. '(independent slots with observed per-item rates).',
                    b.exp_rate * 100));
            end

            imgui.TableNextColumn();
            local diff_abs = math.abs(b.diff) * 100;
            local diff_color = COLOR_GREEN;
            if (diff_abs > 10) then diff_color = COLOR_RED;
            elseif (diff_abs > 3) then diff_color = COLOR_WARN; end
            local sign = (b.diff >= 0) and '+' or '';
            imgui.TextColored(diff_color, string_format('%s%.1f%%', sign, b.diff * 100));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%d-item %ss: observed %.1f%%%% vs expected %.1f%%%%\n%s',
                    b.items, kill_word, b.obs_rate * 100, b.exp_rate * 100,
                    diff_abs > 10 and 'Large deviation — model may not fit well.' or
                    diff_abs > 3 and 'Moderate deviation — more data may help.' or
                    'Good fit — model matches observation.'));
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 4: Co-occurrence Analysis.
local function render_cooccurrence_section(result, kills, kw)
    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Co-occurrence results below %d %s may be unreliable.',
            kills, kw, analysis.MIN_KILLS_COOCCURRENCE, kw));
    end

    local co = result.cooccurrence;
    if (#co == 0) then
        imgui.TextDisabled('No co-occurring item pairs found (need items with 5+ drops each).');
        return;
    end

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_Sortable,
        ImGuiTableFlags_SizingStretchProp, ImGuiTableFlags_ScrollY,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##co_table', 6, flags, { 0, math_min(#co * 24 + 28, 300) }) then
        imgui.TableSetupColumn('Item A', ImGuiTableColumnFlags_DefaultSort, 130);
        imgui.TableSetupColumn('Item B', 0, 130);
        imgui.TableSetupColumn('Observed', ImGuiTableColumnFlags_PreferSortDescending, 60);
        imgui.TableSetupColumn('Expected', ImGuiTableColumnFlags_PreferSortDescending, 60);
        imgui.TableSetupColumn('Deviation', ImGuiTableColumnFlags_PreferSortDescending, 65);
        imgui.TableSetupColumn('Order', ImGuiTableColumnFlags_PreferSortDescending, 80);
        imgui.TableHeadersRow();

        -- Read sort specs and sort only when spec changes (no per-frame sort)
        local sort_specs = imgui.TableGetSortSpecs();
        if (sort_specs ~= nil and sort_specs.Specs ~= nil) then
            local new_col = sort_specs.Specs.ColumnIndex + 1;
            local new_asc = (sort_specs.Specs.SortDirection == 1);
            if (new_col ~= an.co_sort_col or new_asc ~= an.co_sort_asc) then
                an.co_sort_col = new_col;
                an.co_sort_asc = new_asc;
                local key = co_sort_keys[new_col];
                if (key ~= nil) then
                    if (new_asc) then
                        table.sort(co, function(a, b) return (a[key] or 0) < (b[key] or 0); end);
                    else
                        table.sort(co, function(a, b) return (a[key] or 0) > (b[key] or 0); end);
                    end
                end
            end
        end

        for _, row in ipairs(co) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.name_a);
            imgui.TableNextColumn(); imgui.Text(row.name_b);
            imgui.TableNextColumn(); imgui.Text(tostring(row.observed));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('These items dropped together %d times.', row.observed));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f', row.expected));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected co-occurrences if independent:\nP(A) * P(B) * %s = %.1f',
                    kw, row.expected));
            end

            -- Deviation color
            imgui.TableNextColumn();
            local dev = row.deviation;
            local dev_color = COLOR_GREEN;
            if (dev < 0.5 or dev > 2.0) then dev_color = COLOR_RED;
            elseif (dev < 0.8 or dev > 1.2) then dev_color = COLOR_WARN; end
            imgui.TextColored(dev_color, string_format('%.2fx', dev));
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Observed pairs divided by the independent-model prediction.\n1.0: matches the prediction in this sample.\nAbove 1: seen together more often; below 1: less often.\nThis ratio alone does not establish independence.');
            end

            -- Order column
            imgui.TableNextColumn();
            if (row.order_text ~= nil) then
                local oc = row.order_consistency;
                local oc_color = COLOR_GREEN;
                if (oc < 0.7) then oc_color = COLOR_GRAY;
                elseif (oc < 0.9) then oc_color = COLOR_WARN; end
                imgui.TextColored(oc_color, row.order_text);
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('Which item arrives first when both drop?\nHigh consistency suggests stable delivery order;\nit does not prove separate server drop slots.');
                end
            else
                imgui.TextDisabled('--');
                if imgui.IsItemHovered() then
                    imgui.SetTooltip('No arrival-order data was recorded for this pair.\nOlder records may not include drop order.');
                end
            end
        end
        imgui.EndTable();
    end
end

--- Render Section 5: Shared Slot Candidates.
local function render_shared_slots_section(result, kills, kw)
    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d %s). Shared slot detection below %d %s may produce false positives.',
            kills, kw, analysis.MIN_KILLS_COOCCURRENCE, kw));
    end

    local ss = result.shared_slot_candidates;
    if (#ss == 0) then
        imgui.TextColored(COLOR_GREEN, 'No shared slot candidates detected.');
        imgui.TextDisabled('All item pairs with sufficient data have been observed co-occurring.');
        return;
    end

    imgui.TextColored(COLOR_WARN, 'Items that NEVER co-occur despite sufficient sample sizes:');
    imgui.Spacing();

    local flags = bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp,
        ImGuiTableFlags_Resizable, ImGuiTableFlags_Reorderable);
    if imgui.BeginTable('##ss_table', 6, flags, { 0, math_min(#ss * 24 + 28, 250) }) then
        imgui.TableSetupColumn('Item A', 0, 130);
        imgui.TableSetupColumn('Item B', 0, 130);
        imgui.TableSetupColumn('A Drops', 0, 55);
        imgui.TableSetupColumn('B Drops', 0, 55);
        imgui.TableSetupColumn('Expected Co-occur', 0, 95);
        imgui.TableSetupColumn('Confidence', 0, 70);
        imgui.TableHeadersRow();

        for _, row in ipairs(ss) do
            imgui.TableNextRow();
            imgui.TableNextColumn(); imgui.Text(row.name_a);
            imgui.TableNextColumn(); imgui.Text(row.name_b);
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops_a));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('%s dropped %d times total.', row.name_a, row.drops_a));
            end
            imgui.TableNextColumn(); imgui.Text(tostring(row.drops_b));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format('%s dropped %d times total.', row.name_b, row.drops_b));
            end
            imgui.TableNextColumn(); imgui.Text(string_format('%.1f', row.expected_co));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'If independent: P(A)*P(B)*%s = %.1f\n'
                    .. 'But observed 0 co-occurrences.\n'
                    .. 'A higher expected count is stronger evidence\n'
                    .. 'against independent rolls, but does not prove a shared slot.',
                    kw, row.expected_co));
            end

            imgui.TableNextColumn();
            local conf_color = COLOR_GREEN;
            if (row.confidence == 'High') then conf_color = COLOR_YELLOW;
            elseif (row.confidence == 'Possible') then conf_color = COLOR_GRAY; end
            imgui.TextColored(conf_color, row.confidence);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    'Expected %.1f co-occurrences but observed 0.\n'
                    .. 'A shared slot is one possible explanation.\n'
                    .. 'Other loot rules can also produce this pattern.',
                    row.expected_co));
            end
        end
        imgui.EndTable();
    end

    -- Drop position analysis for shared slot candidates
    local dp = result.drop_positions or T{};
    if (#dp > 0 and #ss > 0) then
        imgui.Spacing();
        imgui.TextDisabled('Drop Position Analysis (post-v1.1.1 data only):');

        -- Build quick lookup of shared slot item IDs (cached on result)
        if (result._ss_relevant == nil) then
            local ss_items = {};
            for _, ss_row in ipairs(ss) do
                ss_items[ss_row.item_a] = true;
                ss_items[ss_row.item_b] = true;
            end
            local rel = {};
            for _, p in ipairs(dp) do
                if (ss_items[p.item_id]) then
                    rel[#rel + 1] = p;
                end
            end
            result._ss_relevant = rel;
        end
        local relevant = result._ss_relevant;

        if (#relevant > 0) then
            for _, p in ipairs(relevant) do
                local pos_parts = {};
                for pos, cnt in pairs(p.positions) do
                    pos_parts[#pos_parts + 1] = string_format('pos %d: %dx', pos, cnt);
                end
                table.sort(pos_parts);
                imgui.BulletText(string_format('%s: %s', p.item_name, table.concat(pos_parts, ', ')));
            end
        else
            imgui.TextDisabled('No drop order data yet for shared slot candidates.');
        end
    end
end

--- Render Battlefield Drop Structure (replaces Slot Count Estimation for battlefields).
local function render_battlefield_drop_structure(result)
    local se = result.slot_estimate;
    if (se == nil) then return; end

    local guaranteed = se.guaranteed_items or T{};
    local variable = se.variable_items or T{};
    local std_dev = se.items_std_dev or 0;

    -- Summary metrics table
    local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_NoHostExtendX);
    if imgui.BeginTable('##bf_struct_tbl', 2, tflags) then
        imgui.TableSetupColumn('Label', 0, 220);
        imgui.TableSetupColumn('Value', 0, 250);

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Items per encounter:');
        imgui.TableNextColumn();
        local consistency_color = (std_dev < 0.5) and COLOR_GREEN or (std_dev < 1.0) and COLOR_WARN or COLOR_LIGHT_GRAY;
        imgui.TextColored(consistency_color, string_format('%.1f avg (std dev: %.1f)', se.avg_items_per_kill, std_dev));
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Average item count per encounter.\nA smaller standard deviation means more consistent counts;\nit does not establish fixed or conditional server slots.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Guaranteed drops:');
        imgui.TableNextColumn(); imgui.TextColored(COLOR_GREEN, tostring(#guaranteed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Items seen in at least 95%% of recorded runs.\nFrequent in this sample does not mean guaranteed.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Variable drops:');
        imgui.TableNextColumn(); imgui.Text(tostring(#variable));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Items seen in fewer than 95%% of recorded runs.\nThis does not establish a low chance or a shared slot.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Max items in one encounter:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.max_observed));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Most items seen in one run. Under a one-item-per-slot\nmodel, at least this many slots would be needed.');
        end

        imgui.TableNextRow();
        imgui.TableNextColumn(); imgui.Text('Unique items seen:');
        imgui.TableNextColumn(); imgui.Text(tostring(se.unique_items));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Distinct item types recorded from this battlefield.\nDifferent items can share a slot, and one item type\ncan appear in more than one slot.');
        end

        imgui.EndTable();
    end

    imgui.Spacing();

    -- Guaranteed items list
    if (#guaranteed > 0) then
        imgui.TextColored(COLOR_GREEN, 'Guaranteed:');
        for _, item in ipairs(guaranteed) do
            imgui.BulletText(string_format('%s  %.1f%%  [%d/%d]',
                item.item_name, item.rate * 100, item.drops, item.kills));
        end
        imgui.Spacing();
    end

    -- Variable items list
    if (#variable > 0) then
        imgui.TextColored(COLOR_WARN, 'Variable:');
        for _, item in ipairs(variable) do
            imgui.BulletText(string_format('%s  %.1f%%  [%d/%d]',
                item.item_name, item.rate * 100, item.drops, item.kills));
        end
    end

    if (#guaranteed == 0 and #variable == 0) then
        imgui.TextDisabled('No item drops recorded.');
    end
end

--- Render Inferred Battlefield Drop Table (union-find slot grouping).
local function render_inferred_drop_table(result, kills)
    local slots = result.inferred_slots;

    if (kills < analysis.MIN_KILLS_COOCCURRENCE) then
        imgui.TextColored(COLOR_WARN, string_format(
            'Low sample size (%d runs). Inferred slots below %d runs may be inaccurate.',
            kills, analysis.MIN_KILLS_COOCCURRENCE));
    end

    if (slots == nil or #slots == 0) then
        imgui.TextDisabled('No items with sufficient data for slot inference.');
        return;
    end

    imgui.TextDisabled('Items that never drop together are inferred to share a slot.');
    imgui.Spacing();

    for slot_idx, slot in ipairs(slots) do
        local items = slot.items;
        local label_color = slot.is_guaranteed and COLOR_GREEN or (slot.total_rate >= 0.5) and COLOR_WARN or COLOR_GRAY;

        if (#items == 1) then
            -- Single-item slot
            local item = items[1];
            imgui.TextColored(label_color, string_format('Slot %d (%.1f%%):',
                slot_idx, slot.total_rate * 100));
            imgui.SameLine();
            imgui.Text(item.item_name);
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string_format(
                    '%s\nDrop rate: %.1f%%%% (%d drops / %d runs)\n\n%s',
                    item.item_name, item.rate * 100, item.drops, kills,
                    slot.is_guaranteed and 'Frequent in recorded runs; this does not guarantee a drop.'
                    or 'No shared-item candidate found in this sample.'));
            end
        else
            -- Multi-item (shared) slot
            imgui.TextColored(label_color, string_format('Slot %d (%.1f%%):',
                slot_idx, slot.total_rate * 100));
            imgui.SameLine();

            -- Build inline item list: "ItemA (12.0%) | ItemB (8.0%)"
            local parts = {};
            for _, item in ipairs(items) do
                parts[#parts + 1] = string_format('%s (%.1f%%)', item.item_name, item.rate * 100);
            end
            imgui.Text(table.concat(parts, ' | '));
            if imgui.IsItemHovered() then
                local tip_lines = { string_format('Inferred group: %d item types:', #items) };
                for _, item in ipairs(items) do
                    tip_lines[#tip_lines + 1] = string_format('  %s: %.1f%%%% (%d drops)', item.item_name, item.rate * 100, item.drops);
                end
                tip_lines[#tip_lines + 1] = '';
                tip_lines[#tip_lines + 1] = 'Grouped from observed co-occurrence patterns.';
                tip_lines[#tip_lines + 1] = 'Possible shared slot; other loot rules can produce this pattern.';
                imgui.SetTooltip(table.concat(tip_lines, '\n'));
            end
        end
    end

    -- Summary
    imgui.Spacing();
    local shared_count = 0;
    for _, slot in ipairs(slots) do
        if (#slot.items > 1) then shared_count = shared_count + 1; end
    end
    if (shared_count == 0) then
        imgui.TextDisabled('All items appear to be on independent slots.');
    else
        imgui.TextDisabled(string_format('%d slot(s), %d shared — based on %d runs.',
            #slots, shared_count, kills));
    end
end

--- Main Slot Analysis tab renderer.
local function render_slot_analysis()
    if (analysis == nil) then
        imgui.TextColored(COLOR_ERR, 'Analysis module failed to load. Slot Analysis unavailable.');
        return;
    end

    -- Reinitialize analysis when the DB handle changes; character switches close the old connection.
    if (db.conn ~= nil and an.analysis_conn ~= db.conn) then
        analysis.init(db.conn, db.CONTENT_TYPE_MAP, db.INSTANCE_IN_SQL);
        analysis.invalidate();
        an.cache_dirty = true;
        an.analysis_conn = db.conn;
        an.analysis_inited = true;   -- read by ui.render's stats_dirty hook
    end

    -- Row 1: where you fight (same words as Statistics). Open World here means mobs only.
    if imgui.RadioButton('Open World##an', an.category == 0) then
        an.category = 0;
        reset_an_filter(0);
    end
    imgui.SameLine();
    if imgui.RadioButton('Battlefields##an', an.category == 1) then
        an.category = 1;
        reset_an_filter(8);
    end
    imgui.SameLine();
    if imgui.RadioButton('Instances##an', an.category == 2) then
        an.category = 2;
        reset_an_filter(9);  -- default to All Instances
    end
    widgets.help_marker(
        'Choose a category, then a zone and mob or battlefield.\nOpen World: nearby mob kills.\nBattlefields: BCNM, HTBF, and Legion loot.\nInstances: content with recorded data.\n\nDistant kills are excluded because their loot history\nis incomplete. Walk of Echoes shows offer frequency.\nUse Statistics for chests, Voidwatch, and Reives.');

    -- Row 2: Sub-filter (Battlefields: radio, Instances: combo)
    if (an.category == 1) then
        imgui.Spacing();
        if imgui.RadioButton('All BF##an', an.source_filter == 8) then reset_an_filter(8); end
        imgui.SameLine();
        if imgui.RadioButton('BCNM##an', an.source_filter == 2) then reset_an_filter(2); end
        imgui.SameLine();
        if imgui.RadioButton('HTBF##an', an.source_filter == 3) then reset_an_filter(3); end
        imgui.SameLine();
        if imgui.RadioButton('Legion##an', an.source_filter == 18) then reset_an_filter(18); end
    elseif (an.category == 2) then
        -- Instances: the contents with data, with counts (shared with Statistics)
        imgui.Spacing();
        local inst_str, inst_sfs, inst_idx_of = build_instance_combo(db);
        an.inst_idx[1] = inst_idx_of[an.source_filter] or 0;
        imgui.PushItemWidth(200);
        if imgui.Combo('##an_inst', an.inst_idx, inst_str) then
            local sf = inst_sfs[an.inst_idx[1] + 1];
            if (sf ~= nil) then
                reset_an_filter(sf);
            end
        end
        imgui.PopItemWidth();
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Select an instance content type for slot analysis.');
        end
    end

    imgui.Spacing();

    -- Zone/Battlefield combo
    local combo_str, combo_entries = build_an_filter(an.source_filter);
    imgui.SetNextItemWidth(300);
    if imgui.Combo('##an_zone', an.mob_idx, combo_str) then
        local idx = an.mob_idx[1];
        if (idx == 0) then
            an.zone_filter = -1;
            an.name_filter = nil;
            an.mob_filter  = nil;
            an.mob_level_cap = nil;
            an.effective_sf = nil;
            an.result = nil;
            an.mob_stats = nil;
        elseif (combo_entries ~= nil and combo_entries[idx] ~= nil) then
            local e = combo_entries[idx];
            an.zone_filter = e.zone_id;
            an.name_filter = e.name;
            an.mob_filter = nil;
            an.mob_level_cap = e.level_cap;  -- bf_difficulty for HTBF, level_cap for BCNM
            an.effective_sf = e.effective_sf;  -- remapped sf (2 or 3) for All BF entries
            an.result = nil;
            an.mob_stats = nil;
        end
        an.cache_dirty = true;
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Select a zone or battlefield to analyze.');
    end

    -- BCNM/HTBF/All BF zone combo = battlefield; others need mob combo
    if (an.zone_filter >= 0) then
        local needs_mob_combo = (an.source_filter ~= 2 and an.source_filter ~= 3 and an.source_filter ~= 8);

        if (needs_mob_combo) then
            local mob_str, mob_list = build_mob_combo(an.source_filter, an.zone_filter, an.name_filter);
            an_mob_sel[1] = 0;
            -- Find current selection
            if (an.mob_filter ~= nil and mob_list ~= nil) then
                for i, m in ipairs(mob_list) do
                    if (m.mob_name == an.mob_filter and (m.content or '') == (an.mob_content or '')) then
                        an_mob_sel[1] = i;
                        break;
                    end
                end
            end

            imgui.SameLine();
            imgui.SetNextItemWidth(300);
            if imgui.Combo('##an_mob', an_mob_sel, mob_str) then
                local idx = an_mob_sel[1];
                if (idx == 0) then
                    an.mob_filter = nil;
                    an.mob_level_cap = nil;
                    an.mob_content = nil;
                    an.effective_sf = nil;
                    an.result = nil;
                    an.mob_stats = nil;
                elseif (mob_list ~= nil and mob_list[idx] ~= nil) then
                    an.mob_filter = mob_list[idx].mob_name;
                    an.mob_level_cap = mob_list[idx].level_cap;
                    an.mob_content = mob_list[idx].content;
                    -- All Instances: query through the row's own content (no aggregate detail query)
                    an.effective_sf = (an.source_filter == 9) and sf_for_content(mob_list[idx].content) or nil;
                    an.result = nil;
                    an.mob_stats = nil;
                end
                an.cache_dirty = true;
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Select a mob to analyze its drop slots.');
            end
        else
            -- BCNM/HTBF: mob_filter is the battlefield name from zone combo
            if (an.mob_filter == nil and an.name_filter ~= nil) then
                an.mob_filter = an.name_filter;
            end
        end
    end

    imgui.Separator();

    -- Determine what to analyze
    local mob_name = an.mob_filter;
    local zone_id = an.zone_filter;
    local level_cap = an.mob_level_cap;
    -- For All BF (sf=8), route through BCNM (2) or HTBF (3) path
    local query_sf = an.effective_sf or an.source_filter;

    if (mob_name == nil or zone_id < 0) then
        imgui.Spacing();
        imgui.TextDisabled('Select a zone and mob to analyze drop slot probabilities.');
        an.cache_dirty = false;
        return;
    end

    -- Get mob stats (from db cache)
    if (an.mob_stats == nil or an.cache_dirty) then
        an.mob_stats = db.get_mob_stats(mob_name, zone_id, query_sf, level_cap);
    end

    if (an.mob_stats == nil or an.mob_stats.kills == 0) then
        imgui.TextDisabled('No kill data for this mob.');
        an.cache_dirty = false;
        return;
    end

    -- Compute analysis (cached)
    if (an.result == nil or an.cache_dirty) then
        an.result = analysis.compute(mob_name, zone_id, query_sf, level_cap, an.mob_stats);
        an.cache_dirty = false;
    end

    -- Nearby kills only — distant kills have partial drop visibility
    local kills = an.mob_stats.kills - (an.mob_stats.distant_kills or 0);

    if (an.result == nil) then
        if (kills == 0 and an.mob_stats.kills > 0) then
            local sf = an.source_filter;
            local dkw = (sf == 2 or sf == 3 or sf == 8) and 'runs' or 'kills';
            imgui.TextDisabled('All ' .. dkw .. ' are distant — slot analysis requires nearby ' .. dkw .. '.');
        else
            imgui.TextDisabled('Insufficient data for analysis.');
        end
        return;
    end

    -- Scrollable content area for analysis results
    if imgui.BeginChild('##an_scroll', { 0, 0 }) then

    local is_bf = an.result.is_battlefield;
    -- A Walk of Echoes coffer is a personal offered list: the unit is runs and the pool-only
    -- sections (co-occurrence, shared slots) do not apply.
    local is_woe = (an.source_filter == 20);
    local kw = (is_bf or is_woe) and 'runs' or 'kills';

    -- Header
    imgui.TextColored(COLOR_CYAN, is_woe and walk_display_name(mob_name) or mob_name);
    imgui.SameLine();
    imgui.TextDisabled(string_format('(%s nearby %s)', format_count(kills), kw));
    if imgui.IsItemHovered() then
        local distant = an.mob_stats.distant_kills or 0;
        if (distant > 0) then
            imgui.SetTooltip(string_format(
                'Slot analysis uses nearby %s only (%s nearby, %s distant).\n'
                .. 'Distant %s are excluded because you only see drops\n'
                .. 'that entered your treasure pool — empty distant %s\n'
                .. 'are invisible, which would bias all analysis.',
                kw, format_count(kills), format_count(distant), kw, kw));
        else
            imgui.SetTooltip('All ' .. kw .. ' are nearby (witnessed defeat message).\nNo distant ' .. kw .. ' to exclude.');
        end
    end
    imgui.Spacing();

    -- Section 1: Confidence Intervals (open by default, same for all modes)
    local ci_label = is_bf and 'Drop Rate Confidence Intervals (95% Wilson Score)'
        or (is_woe and 'Offer Frequency (95% Wilson Score)' or 'Confidence Intervals (95% Wilson Score)');
    local ci_open = imgui.CollapsingHeader(ci_label, ImGuiTreeNodeFlags_DefaultOpen);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'How precise are the observed drop rates?\n\n'
            .. 'Wilson Score CI gives a range where the TRUE drop rate\n'
            .. 'likely falls (95%% confidence). Narrower = more reliable.\n'
            .. (is_bf and 'More reliable with 30+ runs.' or 'More reliable with 30+ kills.'));
    end
    if (ci_open) then
        render_ci_section(an.result, kills, kw);
    end

    -- Section 2: Slot structure (mode-aware)
    if (is_bf) then
        -- Battlefield: Drop Structure replaces Slot Count Estimation
        local cs_open = imgui.CollapsingHeader('Battlefield Drop Structure', ImGuiTreeNodeFlags_DefaultOpen);
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Recorded reward counts and observed item frequencies.\nFrequent and variable groups describe this sample;\nthey do not confirm guaranteed drops or fixed server slots.');
        end
        if (cs_open) then
            render_battlefield_drop_structure(an.result);
        end
    elseif (is_woe) then
        -- no slot model for an offered list
    else
        -- Field/Instance: standard Slot Count Estimation
        local se_open = imgui.CollapsingHeader('Slot Count Estimation', ImGuiTreeNodeFlags_DefaultOpen);
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Estimate slot counts from recorded drops under an\nindependent-slot model. A rate sum or close model fit\nis evidence to compare, not proof of the server\'s rules.');
        end
        if (se_open) then
            render_slot_section(an.result);
        end
    end

    -- Section 3: Items-Per-Kill/Encounter Distribution
    local dist_label = is_bf and 'Items-Per-Encounter Distribution' or (is_woe and 'Items-Per-Coffer Distribution' or 'Items-Per-Kill Distribution');
    local dist_open = imgui.CollapsingHeader(dist_label);
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'How many items drop per encounter?\n\n'
                .. 'Compares the observed distribution against what the\n'
                .. 'independent slot model predicts (Poisson Binomial).\n'
                .. 'Large deviations suggest slots may not be independent.');
        else
            imgui.SetTooltip(
                'How many items drop per kill?\n\n'
                .. 'Compares the observed distribution against what the\n'
                .. 'independent slot model predicts (Poisson Binomial).\n'
                .. 'Large deviations suggest slots may not be independent.');
        end
    end
    if (dist_open) then
        render_distribution_section(an.result, is_bf and 'encounter' or (is_woe and 'coffer' or 'kill'));
    end

    if (is_woe) then
        imgui.TextDisabled('Co-occurrence and shared-slot sections do not apply: a coffer offers a personal list, not pool rolls.');
    else
    -- Section 4: Co-occurrence Analysis (collapsed by default)
    local co_open = imgui.CollapsingHeader('Co-occurrence Analysis');
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'Compare item pairs with an independent-roll prediction.\nA difference can reflect shared slots, other loot rules,\nor sampling variation. Different slots need not both\nproduce an item on every run.');
        else
            imgui.SetTooltip(
                'Compare item pairs with an independent-roll prediction.\nA difference can reflect shared slots, other loot rules,\nor sampling variation. More comparable kills help.');
        end
    end
    if (co_open) then
        render_cooccurrence_section(an.result, kills, kw);
    end

    -- Section 5: Shared Slot Candidates (collapsed by default)
    local ss_open = imgui.CollapsingHeader('Shared Slot Candidates');
    if imgui.IsItemHovered() then
        if (is_bf) then
            imgui.SetTooltip(
                'Pairs not seen together despite frequent individual drops.\nA shared slot is one possible explanation; separate\nconditions or a small sample can produce the same pattern.');
        else
            imgui.SetTooltip(
                'Pairs not seen together despite frequent individual drops.\nTreat these as candidates, not confirmed shared slots.\nCheck sample size and whether the kills are comparable.');
        end
    end
    if (ss_open) then
        render_shared_slots_section(an.result, kills, kw);
    end
    end -- not is_woe

    -- Section 6 (battlefields only): Inferred Drop Table
    if (is_bf) then
        local inf_open = imgui.CollapsingHeader('Inferred Battlefield Drop Table');
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Suggested item groups based on which rewards appeared\ntogether. Items never seen together may share a slot,\nbut this is an inferred model, not the server\'s drop table.');
        end
        if (inf_open) then
            render_inferred_drop_table(an.result, kills);
        end
    end
    end -- BeginChild

    imgui.EndChild();
end

local M = {};

--- The tab's only entry point. db/tracker/analysis/s are read from ui_state at call time so a
--- character switch or settings reload is picked up without rebinding anything here.
function M.render()
    db, tracker, analysis, s = state.db, state.tracker, state.analysis, state.s;
    return render_slot_analysis();
end

return M;
