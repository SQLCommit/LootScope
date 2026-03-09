--[[
    LootScope v1.3.0 - Slot Analysis Engine
    Statistical computation for drop slot probability analysis.
    Provides Wilson score confidence intervals, Poisson Binomial
    distribution, co-occurrence testing, and shared slot detection.

    Accepts db.conn via analysis.init(db_conn), owns all analysis SQL,
    and returns pre-computed result tables for ui.lua to render.

    Author: SQLCommit
    Version: 1.2.1
]]--

require 'common';

local analysis = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local Z_95                    = 1.96;    -- 95% confidence z-score
local GIL_ITEM_ID            = 65535;   -- excluded from all analysis
local MIN_KILLS_CI            = 30;     -- minimum kills for CI display
local MIN_KILLS_COOCCURRENCE  = 50;     -- minimum kills for co-occurrence
local MIN_ITEM_DROPS_PAIR     = 5;      -- minimum drops per item in a pair

-- Expose for UI display
analysis.MIN_KILLS_CI           = MIN_KILLS_CI;
analysis.MIN_KILLS_COOCCURRENCE = MIN_KILLS_COOCCURRENCE;

-------------------------------------------------------------------------------
-- Module State
-------------------------------------------------------------------------------
local conn = nil;
local cache = {};  -- keyed by composite filter string

function analysis.init(db_conn)
    conn = db_conn;
end

function analysis.invalidate()
    cache = {};
end

-------------------------------------------------------------------------------
-- Pure Lua Statistical Functions
-------------------------------------------------------------------------------

--- Wilson score confidence interval for a binomial proportion.
-- @param successes number of observed successes
-- @param trials total number of trials
-- @param z z-score (default 1.96 for 95%)
-- @return center, lower, upper bounds as fractions [0,1]
local function wilson_ci(successes, trials, z)
    z = z or Z_95;
    if (trials == 0) then return 0, 0, 0; end
    if (successes > trials) then successes = trials; end

    local p = successes / trials;
    local z2 = z * z;
    local denom = 1 + z2 / trials;
    local center = (p + z2 / (2 * trials)) / denom;
    local margin = (z / denom) * math.sqrt(p * (1 - p) / trials + z2 / (4 * trials * trials));
    local lower = center - margin;
    local upper = center + margin;

    if (lower < 0) then lower = 0; end
    if (upper > 1) then upper = 1; end

    return center, lower, upper;
end

--- Expected empty kill rate from independent slot model.
-- Product of (1 - p_i) for all items. If slots are independent,
-- this predicts how often a mob drops nothing.
-- @param item_rates array of drop rate fractions [0,1]
-- @return float expected empty rate
local function expected_empty_rate(item_rates)
    local product = 1.0;
    for i = 1, #item_rates do
        product = product * (1 - item_rates[i]);
    end
    return product;
end

--- Poisson Binomial PMF via dynamic programming.
-- Exact distribution for N independent Bernoulli trials with different probs.
-- O(n^2) — capped at 30 items for performance.
-- @param probs array of individual probabilities
-- @return array of P(exactly k successes) for k=0..#probs
local function poisson_binomial_pmf(probs)
    local n = #probs;
    if (n == 0) then return { 1.0 }; end
    if (n > 30) then
        -- Truncate to top 30 probabilities by magnitude
        local sorted = {};
        for i = 1, n do
            sorted[#sorted + 1] = probs[i];
        end
        table.sort(sorted, function(a, b) return a > b; end);
        probs = {};
        for i = 1, 30 do
            probs[i] = sorted[i];
        end
        n = 30;
    end

    -- dp[k+1] = P(exactly k successes after processing items so far)
    -- Use 1-indexed: dp[1] = P(0 successes), dp[2] = P(1 success), etc.
    local dp = {};
    for k = 0, n do
        dp[k + 1] = 0;
    end
    dp[1] = 1.0;  -- P(0 successes) = 1 before any items

    for i = 1, n do
        local p = probs[i];
        -- Process in reverse to avoid overwriting values we still need
        for k = i, 1, -1 do
            dp[k + 1] = dp[k + 1] * (1 - p) + dp[k] * p;
        end
        dp[1] = dp[1] * (1 - p);
    end

    return dp;
end

-------------------------------------------------------------------------------
-- SQL WHERE Clause Builder
-- Replicates db.lua's filter logic for all source_filter values.
-- Returns (where_clause, bind_params_array) for kills table alias 'k'.
-- NOTE: must stay in sync with db.CONTENT_TYPE_MAP in db.lua.
-------------------------------------------------------------------------------
local content_type_map = { [4] = 'Omen', [5] = 'Ambuscade', [6] = 'Sortie', [7] = 'Dynamis', [10] = 'Voidwatch', [11] = 'Domain Invasion' };

local function build_kill_where(mob_name, zone_id, source_filter, level_cap)
    local parts = {};
    local params = {};

    if (source_filter == 3) then
        -- HTBF: match by bf_name + zone + bf_difficulty (level_cap carries difficulty)
        local expr = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, 'Unknown HTBF'))";
        parts[#parts + 1] = expr .. ' = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = 'k.bf_difficulty = ?';
        params[#params + 1] = level_cap;
    elseif (source_filter == 2) then
        -- BCNM: match by battlefield name + zone + source_type=3 + bf_difficulty=0
        -- Must match get_all_mob_stats(2) which filters bf_difficulty = 0
        parts[#parts + 1] = "COALESCE(k.battlefield, 'Unknown BCNM') = ?";
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = 'k.source_type = 3';
        parts[#parts + 1] = 'k.bf_difficulty = 0';
        if (level_cap ~= nil) then
            parts[#parts + 1] = 'k.level_cap = ?';
            params[#params + 1] = level_cap;
        else
            parts[#parts + 1] = 'k.level_cap IS NULL';
        end
    elseif (content_type_map[source_filter] ~= nil) then
        -- Content types (Omen/Ambuscade/Sortie/Dynamis/Voidwatch/Domain Invasion)
        local ct = content_type_map[source_filter];
        parts[#parts + 1] = 'k.mob_name = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = "COALESCE(k.content_type, '') = ?";
        params[#params + 1] = ct;
    elseif (source_filter == 8) then
        -- All Battlefields: match by bf_name/battlefield expression + zone + level_cap + bf_difficulty
        -- Must match db.get_mob_stats() and get_all_mob_stats(8) which use the same COALESCE expression
        local bf_expr = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, k.mob_name))";
        parts[#parts + 1] = bf_expr .. ' = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        -- Inline level_cap and bf_difficulty to match db.lua's COALESCE pattern
        local lc = level_cap or 0;
        parts[#parts + 1] = 'COALESCE(k.level_cap, 0) = ' .. tostring(lc);
        parts[#parts + 1] = '((k.source_type = 3 AND k.bf_difficulty = 0) OR k.bf_difficulty > 0)';
    elseif (source_filter == 9) then
        -- All Instances
        parts[#parts + 1] = 'k.mob_name = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = "COALESCE(k.content_type, '') IN ('Omen', 'Ambuscade', 'Sortie', 'Dynamis')";
    elseif (source_filter == 1) then
        -- Chest/Coffer: must match get_all_mob_stats(1) which filters source_type IN (1,2)
        parts[#parts + 1] = 'k.mob_name = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = 'k.source_type IN (1, 2)';
    else
        -- Field (value 0): exclude content-tagged kills AND non-mob source types
        -- Must match db.get_mob_stats() and get_all_mob_stats() Field branch exactly
        parts[#parts + 1] = 'k.mob_name = ?';
        params[#params + 1] = mob_name;
        parts[#parts + 1] = 'k.zone_id = ?';
        params[#params + 1] = zone_id;
        parts[#parts + 1] = 'k.source_type = 0';
        parts[#parts + 1] = "COALESCE(k.content_type, '') = ''";
    end

    -- Exclude distant kills from all analysis: partial drop visibility makes
    -- CI, co-occurrence, and shared-slot inference unreliable.
    parts[#parts + 1] = 'k.is_distant = 0';

    return table.concat(parts, ' AND '), params;
end

-------------------------------------------------------------------------------
-- Query: Items per kill (for histogram + empty rate)
-------------------------------------------------------------------------------
local function query_items_per_kill(mob_name, zone_id, source_filter, level_cap)
    local where, params = build_kill_where(mob_name, zone_id, source_filter, level_cap);

    local sql = 'SELECT k.id, COUNT(CASE WHEN d.item_id != ' .. GIL_ITEM_ID
        .. ' THEN d.id ELSE NULL END) as item_count'
        .. ' FROM kills k LEFT JOIN drops d ON d.kill_id = k.id'
        .. ' WHERE ' .. where
        .. ' GROUP BY k.id';

    local stmt = conn:prepare(sql);
    if (stmt == nil) then return {}; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end

    local results = {};
    for row in stmt:nrows() do
        results[#results + 1] = row.item_count;
    end
    stmt:finalize();
    return results;
end

-------------------------------------------------------------------------------
-- Query: Co-occurrence pairs (self-join on drops)
-------------------------------------------------------------------------------
local function query_cooccurrence(mob_name, zone_id, source_filter, level_cap)
    local where, params = build_kill_where(mob_name, zone_id, source_filter, level_cap);

    local sql = [[
        SELECT d1.item_id as item_a, d1.item_name as name_a,
               d2.item_id as item_b, d2.item_name as name_b,
               COUNT(DISTINCT d1.kill_id) as co_count
        FROM drops d1
        JOIN drops d2 ON d1.kill_id = d2.kill_id AND d1.item_id < d2.item_id
        JOIN kills k ON d1.kill_id = k.id
        WHERE ]] .. where .. [[
          AND d1.item_id != ]] .. GIL_ITEM_ID .. [[
          AND d2.item_id != ]] .. GIL_ITEM_ID .. [[
        GROUP BY d1.item_id, d2.item_id
    ]];

    local stmt = conn:prepare(sql);
    if (stmt == nil) then return {}; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end

    local results = {};
    for row in stmt:nrows() do
        results[#results + 1] = {
            item_a   = row.item_a,
            name_a   = row.name_a,
            item_b   = row.item_b,
            name_b   = row.name_b,
            co_count = row.co_count,
        };
    end
    stmt:finalize();
    return results;
end

-------------------------------------------------------------------------------
-- Query: Drop arrival ordering (uses drop_order column)
-------------------------------------------------------------------------------
local function query_drop_ordering(mob_name, zone_id, source_filter, level_cap)
    local where, params = build_kill_where(mob_name, zone_id, source_filter, level_cap);

    local sql = [[
        SELECT d1.item_id as item_a, d1.item_name as name_a,
               d2.item_id as item_b, d2.item_name as name_b,
               SUM(CASE WHEN d1.drop_order < d2.drop_order THEN 1 ELSE 0 END) as a_before_b,
               SUM(CASE WHEN d1.drop_order > d2.drop_order THEN 1 ELSE 0 END) as b_before_a,
               COUNT(*) as co_count
        FROM drops d1
        JOIN drops d2 ON d1.kill_id = d2.kill_id AND d1.item_id < d2.item_id
        JOIN kills k ON d1.kill_id = k.id
        WHERE ]] .. where .. [[
          AND d1.item_id != ]] .. GIL_ITEM_ID .. [[
          AND d2.item_id != ]] .. GIL_ITEM_ID .. [[
          AND d1.drop_order >= 0 AND d2.drop_order >= 0
        GROUP BY d1.item_id, d2.item_id
    ]];

    local stmt = conn:prepare(sql);
    if (stmt == nil) then return {}; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end

    local results = {};
    for row in stmt:nrows() do
        results[#results + 1] = {
            item_a     = row.item_a,
            name_a     = row.name_a,
            item_b     = row.item_b,
            name_b     = row.name_b,
            a_before_b = row.a_before_b,
            b_before_a = row.b_before_a,
            co_count   = row.co_count,
        };
    end
    stmt:finalize();
    return results;
end

-------------------------------------------------------------------------------
-- Query: Drop order position distribution per item
-------------------------------------------------------------------------------
local function query_drop_positions(mob_name, zone_id, source_filter, level_cap)
    local where, params = build_kill_where(mob_name, zone_id, source_filter, level_cap);

    local sql = [[
        SELECT d.item_id, d.item_name, d.drop_order, COUNT(*) as cnt
        FROM drops d JOIN kills k ON d.kill_id = k.id
        WHERE ]] .. where .. [[
          AND d.item_id != ]] .. GIL_ITEM_ID .. [[
          AND d.drop_order >= 0
        GROUP BY d.item_id, d.drop_order
        ORDER BY d.item_id, d.drop_order
    ]];

    local stmt = conn:prepare(sql);
    if (stmt == nil) then return {}; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end

    -- Group by item_id
    local items = {};
    local item_order = {};
    for row in stmt:nrows() do
        local id = row.item_id;
        if (items[id] == nil) then
            items[id] = { item_id = id, item_name = row.item_name, positions = {} };
            item_order[#item_order + 1] = id;
        end
        items[id].positions[row.drop_order] = row.cnt;
    end
    stmt:finalize();

    local results = {};
    for _, id in ipairs(item_order) do
        results[#results + 1] = items[id];
    end
    return results;
end

-------------------------------------------------------------------------------
-- Main Computation Function
-------------------------------------------------------------------------------

--- Compute all slot analysis statistics for a given mob.
-- @param mob_name string mob name (or battlefield name for BCNM/HTBF)
-- @param zone_id number zone ID
-- @param source_filter number filter index (0-9)
-- @param level_cap number|nil level cap or bf_difficulty
-- @param mob_stats table from db.get_mob_stats() — reused for base counts
-- @return result table with all computed statistics
function analysis.compute(mob_name, zone_id, source_filter, level_cap, mob_stats)
    if (conn == nil) then return nil; end
    if (mob_stats == nil or mob_stats.kills == 0) then return nil; end

    local cache_key = (mob_name or '') .. '|' .. tostring(zone_id or 0)
        .. '|' .. tostring(source_filter or -1) .. '|' .. tostring(level_cap or 'nil');

    if (cache[cache_key] ~= nil) then
        return cache[cache_key];
    end

    local items = mob_stats.items or T{};

    ---------------------------------------------------------------------------
    -- Query kill count from DB (authoritative — mob_stats.kills may include
    -- chest_events that aren't in kills table).
    ---------------------------------------------------------------------------
    local ipk_raw = query_items_per_kill(mob_name, zone_id, source_filter, level_cap);
    local max_observed = 0;
    local empty_observed_count = 0;
    local total_items_sum = 0;

    for i = 1, #ipk_raw do
        local c = ipk_raw[i];
        if (c > max_observed) then max_observed = c; end
        if (c == 0) then empty_observed_count = empty_observed_count + 1; end
        total_items_sum = total_items_sum + c;
    end

    local total_kills_counted = #ipk_raw;
    if (total_kills_counted == 0) then return nil; end

    -- Use query-counted kills as authoritative denominator for ALL rate calcs
    local kills = total_kills_counted;

    local empty_observed_rate = empty_observed_count / kills;
    local avg_items_per_kill = total_items_sum / kills;

    ---------------------------------------------------------------------------
    -- Section 1: Confidence Intervals
    ---------------------------------------------------------------------------
    local confidence = T{};
    local item_rates = {};  -- for Poisson Binomial and empty rate
    local item_drops_map = {};  -- item_id -> drops count (for co-occurrence expected)

    for _, item in ipairs(items) do
        if (item.item_id ~= GIL_ITEM_ID and not item.is_chest_event) then
            -- Use nearby drops only — distant kills have partial drop visibility
            local drops = item.nearby_times_dropped or item.times_dropped or 0;
            if (drops > 0) then
                local rate = drops / kills;
                local ci_center, ci_lower, ci_upper = wilson_ci(drops, kills);
                local ci_width = ci_upper - ci_lower;

                confidence:append({
                    item_id       = item.item_id,
                    item_name     = item.item_name,
                    drops         = drops,
                    kills         = kills,
                    rate          = rate,
                    ci_center     = ci_center,
                    ci_lower      = ci_lower,
                    ci_upper      = ci_upper,
                    ci_width      = ci_width,
                });

                item_rates[#item_rates + 1] = rate;
                item_drops_map[item.item_id] = drops;
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Section 2: Slot Count Estimation
    ---------------------------------------------------------------------------
    local rate_sum = 0;
    for i = 1, #item_rates do
        rate_sum = rate_sum + item_rates[i];
    end

    -- Truncate to top 30 rates for Poisson Binomial (O(n^2) cap)
    local pmf_rates = item_rates;
    if (#item_rates > 30) then
        pmf_rates = {};
        for i = 1, #item_rates do
            pmf_rates[i] = item_rates[i];
        end
        table.sort(pmf_rates, function(a, b) return a > b; end);
        local truncated = {};
        for i = 1, 30 do
            truncated[i] = pmf_rates[i];
        end
        pmf_rates = truncated;
    end

    local empty_expected = expected_empty_rate(pmf_rates);

    -- Detect battlefield content (BCNM, HTBF, All Battlefields)
    local is_battlefield = (source_filter == 2 or source_filter == 3 or source_filter == 8);

    local slot_estimate = {
        max_observed       = max_observed,
        unique_items       = #item_rates,
        rate_sum           = rate_sum,
        empty_observed_count = empty_observed_count,
        empty_observed_rate = empty_observed_rate,
        empty_expected_rate = empty_expected,
        avg_items_per_kill = avg_items_per_kill,
        total_kills        = kills,
    };

    -- Battlefield-specific: guaranteed vs variable items, std dev
    if (is_battlefield) then
        local guaranteed = T{};
        local variable = T{};
        for _, ci_row in ipairs(confidence) do
            if (ci_row.rate >= 0.95) then
                guaranteed:append(ci_row);
            else
                variable:append(ci_row);
            end
        end
        table.sort(guaranteed, function(a, b) return a.rate > b.rate; end);
        table.sort(variable, function(a, b) return a.rate > b.rate; end);
        slot_estimate.guaranteed_items = guaranteed;
        slot_estimate.variable_items = variable;

        -- Items-per-encounter consistency (sample standard deviation)
        local mean = avg_items_per_kill;
        local variance_sum = 0;
        for i = 1, #ipk_raw do
            local diff = ipk_raw[i] - mean;
            variance_sum = variance_sum + diff * diff;
        end
        local std_dev = (#ipk_raw > 1) and math.sqrt(variance_sum / (#ipk_raw - 1)) or 0;
        slot_estimate.items_std_dev = std_dev;
    end

    ---------------------------------------------------------------------------
    -- Section 3: Items-Per-Kill Distribution
    ---------------------------------------------------------------------------
    -- Build observed histogram
    local dist_bins = {};
    for i = 1, #ipk_raw do
        local c = ipk_raw[i];
        dist_bins[c] = (dist_bins[c] or 0) + 1;
    end

    local distribution = { bins = T{} };
    local expected_pmf = poisson_binomial_pmf(pmf_rates);

    for k = 0, max_observed do
        local obs_count = dist_bins[k] or 0;
        local obs_rate = obs_count / kills;
        local exp_rate = expected_pmf[k + 1] or 0;
        distribution.bins:append({
            items    = k,
            count    = obs_count,
            obs_rate = obs_rate,
            exp_rate = exp_rate,
            diff     = obs_rate - exp_rate,
        });
    end
    ---------------------------------------------------------------------------
    -- Section 4: Co-occurrence Analysis
    ---------------------------------------------------------------------------
    local cooccurrence = T{};
    local shared_slot_candidates = T{};
    local order_raw_cache = nil;

    if (kills >= 2) then  -- need at least 2 kills for co-occurrence to be meaningful
        local co_raw = query_cooccurrence(mob_name, zone_id, source_filter, level_cap);
        order_raw_cache = query_drop_ordering(mob_name, zone_id, source_filter, level_cap);
        local order_raw = order_raw_cache;

        -- Build ordering lookup: "itemA_itemB" -> order data
        local order_map = {};
        for _, o in ipairs(order_raw) do
            local key = tostring(o.item_a) .. '_' .. tostring(o.item_b);
            order_map[key] = o;
        end

        -- Build co-occurrence map: "itemA_itemB" -> observed count
        local co_map = {};
        for _, co in ipairs(co_raw) do
            local drops_a = item_drops_map[co.item_a] or 0;
            local drops_b = item_drops_map[co.item_b] or 0;

            if (drops_a >= MIN_ITEM_DROPS_PAIR and drops_b >= MIN_ITEM_DROPS_PAIR) then
                local p_a = drops_a / kills;
                local p_b = drops_b / kills;
                local expected_co = p_a * p_b * kills;
                local deviation = (expected_co > 0) and (co.co_count / expected_co) or 0;

                local order_key = tostring(co.item_a) .. '_' .. tostring(co.item_b);
                local order_info = order_map[order_key];
                local order_text = nil;
                local order_consistency = 0;
                if (order_info ~= nil and order_info.co_count > 0) then
                    local ab = order_info.a_before_b or 0;
                    local ba = order_info.b_before_a or 0;
                    local total = ab + ba;
                    if (total > 0) then
                        if (ab >= ba) then
                            order_consistency = ab / total;
                            order_text = 'A<B (' .. math.floor(order_consistency * 100 + 0.5) .. '%)';
                        else
                            order_consistency = ba / total;
                            order_text = 'B<A (' .. math.floor(order_consistency * 100 + 0.5) .. '%)';
                        end
                    end
                end

                cooccurrence:append({
                    item_a    = co.item_a,
                    name_a    = co.name_a,
                    item_b    = co.item_b,
                    name_b    = co.name_b,
                    observed  = co.co_count,
                    expected  = expected_co,
                    deviation = deviation,
                    order_text = order_text,
                    order_consistency = order_consistency,
                });

                co_map[order_key] = co.co_count;
            end
        end

        -----------------------------------------------------------------------
        -- Section 5: Shared Slot Candidates (items that NEVER co-occur)
        -----------------------------------------------------------------------
        -- Check all pairs of items that both have enough drops but zero co-occurrence
        local item_list = {};
        for _, item in ipairs(items) do
            if (item.item_id ~= GIL_ITEM_ID and not item.is_chest_event) then
                local drops = item.nearby_times_dropped or item.times_dropped or 0;
                if (drops >= MIN_ITEM_DROPS_PAIR) then
                    item_list[#item_list + 1] = {
                        item_id   = item.item_id,
                        item_name = item.item_name,
                        drops     = drops,
                    };
                end
            end
        end

        for i = 1, #item_list do
            for j = i + 1, #item_list do
                local a = item_list[i];
                local b = item_list[j];
                -- Ensure a.item_id < b.item_id for consistent key
                local ia, ib = a, b;
                if (ia.item_id > ib.item_id) then ia, ib = b, a; end

                local key = tostring(ia.item_id) .. '_' .. tostring(ib.item_id);
                local observed = co_map[key] or 0;

                local p_a = ia.drops / kills;
                local p_b = ib.drops / kills;
                local expected_co = p_a * p_b * kills;

                if (observed == 0 and expected_co >= 2) then
                    local conf;
                    if (expected_co >= 5) then
                        conf = 'Very High';
                    else
                        conf = 'High';
                    end

                    shared_slot_candidates:append({
                        item_a      = ia.item_id,
                        name_a      = ia.item_name,
                        item_b      = ib.item_id,
                        name_b      = ib.item_name,
                        drops_a     = ia.drops,
                        drops_b     = ib.drops,
                        expected_co = expected_co,
                        confidence  = conf,
                    });
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Section 6: Drop Position Data
    ---------------------------------------------------------------------------
    local drop_positions = T{};

    if (kills >= 2) then  -- need at least 2 kills for positions to be meaningful
        local pos_raw = query_drop_positions(mob_name, zone_id, source_filter, level_cap);
        for _, p in ipairs(pos_raw) do
            drop_positions:append(p);
        end
    end

    ---------------------------------------------------------------------------
    -- Section 5b: Inferred Battlefield Drop Table (union-find grouping)
    -- Uses shared_slot_candidates (Section 5) + confidence data (Section 1)
    ---------------------------------------------------------------------------
    local inferred_slots = T{};

    if (is_battlefield and kills >= 2 and #confidence > 0) then
        -- Union-Find: items that never co-occur share a slot
        local parent = {};
        local item_info = {};
        for _, ci_row in ipairs(confidence) do
            parent[ci_row.item_id] = ci_row.item_id;
            item_info[ci_row.item_id] = {
                name = ci_row.item_name,
                rate = ci_row.rate,
                drops = ci_row.drops,
            };
        end

        local function find(x)
            while parent[x] ~= x do
                parent[x] = parent[parent[x]];
                x = parent[x];
            end
            return x;
        end

        local function union(a, b)
            local ra, rb = find(a), find(b);
            if (ra ~= rb) then parent[ra] = rb; end
        end

        -- Merge items that never co-occur (shared slot candidates)
        for _, ss in ipairs(shared_slot_candidates) do
            union(ss.item_a, ss.item_b);
        end

        -- Collect groups by root
        local groups = {};
        for id, _ in pairs(parent) do
            local root = find(id);
            if (groups[root] == nil) then groups[root] = T{}; end
            groups[root]:append({
                item_id   = id,
                item_name = item_info[id].name,
                rate      = item_info[id].rate,
                drops     = item_info[id].drops,
            });
        end

        -- Sort items within each group by rate descending
        for _, group in pairs(groups) do
            table.sort(group, function(a, b) return a.rate > b.rate; end);
        end

        -- Convert to ordered list with metadata
        for _, group in pairs(groups) do
            local total_rate = 0;
            for _, item in ipairs(group) do
                total_rate = total_rate + item.rate;
            end
            local is_guaranteed = (#group == 1 and group[1].rate >= 0.95);
            inferred_slots:append({
                items        = group,
                total_rate   = total_rate,
                is_guaranteed = is_guaranteed,
            });
        end
        table.sort(inferred_slots, function(a, b) return a.total_rate > b.total_rate; end);
    end

    ---------------------------------------------------------------------------
    -- Assemble result
    ---------------------------------------------------------------------------
    local result = {
        confidence           = confidence,
        slot_estimate        = slot_estimate,
        distribution         = distribution,
        cooccurrence         = cooccurrence,
        shared_slot_candidates = shared_slot_candidates,
        drop_positions       = drop_positions,
        is_battlefield       = is_battlefield,
        inferred_slots       = inferred_slots,
    };

    cache[cache_key] = result;
    return result;
end

return analysis;
