-- Versioned data backfills and per-open maintenance.

local os_time = os.time;

local backfill = {};


-- Check every SQLite result code before stamping a generation.
-- Use named constants from the binding; some versions return nil for exec success.
local SQLITE_OK, SQLITE_DONE = 0, 101;
do
    local ok, lib = pcall(require, 'lsqlite3');
    if (ok and lib ~= nil) then
        SQLITE_OK   = lib.OK   or SQLITE_OK;
        SQLITE_DONE = lib.DONE or SQLITE_DONE;
    end
end

-- Current data generation; increment when adding an apply_vN migration.
backfill.VERSION = 10;

local function exec_ok(conn, sql)
    local rc = conn:exec(sql);
    return (rc == nil) or (rc == SQLITE_OK);
end

-- Stamp only after all statements succeed and user_version equals version-1.
-- A failed generation must retry rather than being skipped by a later stamp.
local function stamp(conn, ok, version)
    if (not ok) then return; end
    local cur = 0;
    for row in conn:nrows('PRAGMA user_version') do cur = row.user_version; end
    if (cur ~= version - 1) then return; end
    conn:exec(('PRAGMA user_version = %d;'):format(version));
end

--- One-time data backfills. Gated by PRAGMA user_version.
function backfill.apply(conn)
        local data_ver = 0;
        for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
        if (data_ver < 1) then
        local ok = true;

        -- Migration: unify Dynamis + Dynamis [D] into single 'Dynamis' content_type
        local needs_dyn_rename = false;
        for row in conn:nrows("SELECT 1 FROM kills WHERE content_type = 'Dynamis [D]' LIMIT 1") do
            needs_dyn_rename = true;
        end
        if (needs_dyn_rename) then
            ok = exec_ok(conn, "UPDATE kills SET content_type = 'Dynamis' WHERE content_type = 'Dynamis [D]';") and ok;
        end
        local needs_dyn_backfill = false;
        for row in conn:nrows("SELECT 1 FROM kills WHERE COALESCE(content_type, '') = '' AND zone_id IN (39,40,41,42,134,135,185,186,187,188,294,295,296,297) LIMIT 1") do
            needs_dyn_backfill = true;
        end
        if (needs_dyn_backfill) then
            ok = exec_ok(conn, [[
                UPDATE kills SET content_type = 'Dynamis'
                WHERE COALESCE(content_type, '') = ''
                  AND zone_id IN (39, 40, 41, 42, 134, 135, 185, 186, 187, 188, 294, 295, 296, 297);
            ]]);
        end

        -- Migration: backfill content_type for instance zones added in v1.4.0.
        local instance_backfill = {
            { 'Omen',           '292' },
            { 'Einherjar',      '78' },
            { 'Nyzul',          '77' },
            { 'Salvage',        '73, 74, 75, 76' },
            { 'Limbus',         '37, 38' },
            -- Sortie (133/275/189), Vagary (133/275/189), Legion (183), Ambuscade (183/287)
            -- excluded from backfill — shared zones can't be disambiguated retroactively.
            { 'Assault',        '55, 56, 60, 63, 66, 69' },
            { 'Walk of Echoes', '182' },
            { 'Skirmish',       '259, 264, 271' },
            { 'Meeble Burrows', '129' },
        };
        for _, entry in ipairs(instance_backfill) do
            local ct, zones = entry[1], entry[2];
            local needs = false;
            for row in conn:nrows("SELECT 1 FROM kills WHERE (COALESCE(content_type, '') = '' OR content_type = 'Unknown Battlefield') AND zone_id IN (" .. zones .. ") LIMIT 1") do
                needs = true;
            end
            if (needs) then
                ok = exec_ok(conn, "UPDATE kills SET content_type = '" .. ct .. "' WHERE (COALESCE(content_type, '') = '' OR content_type = 'Unknown Battlefield') AND zone_id IN (" .. zones .. ");") and ok;
            end
        end

        stamp(conn, ok, 1);   -- only when every statement above actually succeeded
        end  -- (data_ver < 1) gate
end

--- Second-generation backfills. OWN gate (data_ver < 2) per the rule in this file's header --
--- users already stamped version 1 never re-run the < 1 block, so these must be separate.
function backfill.apply_v2(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 2) then return; end
    local ok = true;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = 'Vagary',
               bf_source    = 'migrated_vagary_zone'
         WHERE COALESCE(content_type, '') = 'BCNM'
           AND zone_id IN (133, 275, 189);
    ]]) and ok;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET bf_difficulty = 0,
               bf_source     = 'migrated_star_falsepos'
         WHERE bf_difficulty = 6;
    ]]) and ok;

    stamp(conn, ok, 2);
end

--- v3: classification corrections
function backfill.apply_v3(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 3) then return; end
    local ok = true;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = 'BCNM',
               bf_source    = 'migrated_woe_htbf'
         WHERE content_type = 'Unknown Battlefield'
           AND zone_id IN (279, 298);
    ]]) and ok;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = '',
               bf_source    = 'migrated_escha_open'
         WHERE content_type IN ('BCNM', 'Unknown Battlefield')
           AND zone_id IN (288, 289, 291);
    ]]) and ok;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = '',
               bf_source    = 'migrated_besieged_open'
         WHERE content_type = 'Unknown Battlefield'
           AND zone_id = 48;
    ]]) and ok;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = 'Skirmish',
               bf_source    = 'migrated_skirmish_zone'
         WHERE content_type = 'BCNM'
           AND zone_id = 271;
    ]]) and ok;

    stamp(conn, ok, 3);
end

--- v4: recover the Domain Invasion rows
function backfill.apply_v4(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 4) then return; end
    local ok = true;

    ok = exec_ok(conn, [[
        UPDATE kills
           SET content_type = 'Domain Invasion',
               bf_source    = 'migrated_escha_di'
         WHERE zone_id IN (288, 289, 291)
           AND COALESCE(content_type, '') IN ('', 'Unknown Battlefield')
           AND (   mob_name LIKE 'Quetzalcoatl%'
                OR mob_name LIKE 'Naga Raja%'
                OR mob_name LIKE 'Azi Dahaka%'
                OR mob_name LIKE 'Mireu%'   );
    ]]) and ok;

    stamp(conn, ok, 4);
end

-- Generation 5: recover missing battlefield names from exactly one matching session.
-- Require the same zone, a bounded session interval and existing battlefield/container evidence.
-- Do not change classification or bf_source; leave ambiguous and already-named rows untouched.
function backfill.apply_v5(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 5) then return; end

    -- Require battlefield_sessions before querying; fresh databases may not have it yet.
    local has_sessions = false;
    for _ in conn:nrows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='battlefield_sessions'") do
        has_sessions = true;
    end
    if (not has_sessions) then return; end

    local ok = exec_ok(conn, [[
        UPDATE kills SET battlefield = (
            SELECT s.battlefield_name FROM battlefield_sessions s
             WHERE s.zone_id = kills.zone_id
               AND COALESCE(s.battlefield_name,'') <> ''
               AND kills.timestamp >= s.entered_at
               AND kills.timestamp <= COALESCE(s.exited_at, s.entered_at)
        )
        WHERE COALESCE(battlefield,'') = ''
          AND (COALESCE(content_type,'') = 'BCNM' OR source_type IN (2,3))
          AND (SELECT COUNT(*) FROM battlefield_sessions s
                WHERE s.zone_id = kills.zone_id
                  AND COALESCE(s.battlefield_name,'') <> ''
                  AND kills.timestamp >= s.entered_at
                  AND kills.timestamp <= COALESCE(s.exited_at, s.entered_at)) = 1;
    ]]);

    stamp(conn, ok, 5);
end

-- Generation 6: clear zone names incorrectly stored as battlefield names; leave them unknown.
function backfill.apply_v6(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 6) then return; end
    local ok = exec_ok(conn, "UPDATE kills SET battlefield = '' WHERE battlefield = zone_name;");
    local has_sessions = false;
    for _ in conn:nrows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='battlefield_sessions'") do
        has_sessions = true;
    end
    if (has_sessions) then
        ok = exec_ok(conn, "UPDATE battlefield_sessions SET battlefield_name = '' WHERE battlefield_name = zone_name;") and ok;
    end
    stamp(conn, ok, 6);
end

-- Generation 7: fill empty WoE HTBF names from an explicit boss whitelist in zones 279/298.
-- Never rename adds or existing battlefield names; the original difficulty cannot be recovered.
function backfill.apply_v7(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 7) then return; end
    local ok = exec_ok(conn, [[
        UPDATE kills SET battlefield = CASE mob_name
            WHEN 'Lady Lilith'      THEN 'Maiden of the Dusk'
            WHEN 'Lilith Ascendant' THEN 'Maiden of the Dusk'
            WHEN 'Odin Prime'       THEN 'A Stygian Pact'
            WHEN 'Cait Sith'        THEN 'Champion of the Dawn'
        END
        WHERE zone_id IN (279, 298)
          AND COALESCE(battlefield, '') = ''
          AND mob_name IN ('Lady Lilith', 'Lilith Ascendant', 'Odin Prime', 'Cait Sith');
    ]]);
    stamp(conn, ok, 7);
end

-- Generation 8: mark those confirmed WoE HTBF bosses as difficulty unknown (6).
-- Preserve known tiers and leave level_cap unchanged.
function backfill.apply_v8(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 8) then return; end
    local ok = exec_ok(conn, [[
        UPDATE kills SET bf_difficulty = 6
        WHERE zone_id IN (279, 298)
          AND COALESCE(bf_difficulty, 0) = 0
          AND mob_name IN ('Lady Lilith', 'Lilith Ascendant', 'Odin Prime', 'Cait Sith');
    ]]);
    stamp(conn, ok, 8);
end

-- Generation 9: strip display-control bytes from battlefield names and clear distant flags
-- for confirmed battlefield rows recorded before their defeat packet.
function backfill.apply_v9(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 9) then return; end
    -- bf_name strip is done in LUA, not SQL: the stored bytes are raw Shift-JIS (★ = 0x81 0x9A),
    -- but SQLite char(129) emits UTF-8 0xC2 0x81, so a REPLACE never matches. gsub is byte-exact.
    local ok = true;
    local fix = {};
    for row in conn:nrows("SELECT id, bf_name FROM kills WHERE COALESCE(bf_name, '') <> ''") do
        local clean = row.bf_name:gsub('[^ -~]', ''):gsub('^%s+', ''):gsub('%s+$', '');
        if (clean ~= row.bf_name) then fix[#fix + 1] = { id = row.id, name = clean }; end
    end
    for _, r in ipairs(fix) do
        local st = conn:prepare("UPDATE kills SET bf_name = ? WHERE id = ?");
        if (st == nil) then ok = false; else
            st:bind_values(r.name, r.id);
            local rc = st:step(); st:finalize();
            ok = ok and (rc == nil or rc == SQLITE_DONE or rc == SQLITE_OK);
        end
    end
    ok = exec_ok(conn, [[
        UPDATE kills SET is_distant = 0
        WHERE is_distant = 1
          AND (COALESCE(bf_difficulty, 0) > 0 OR source_type = 3 OR COALESCE(battlefield, '') <> '');
    ]]) and ok;
    stamp(conn, ok, 9);
end

-- Generation 10: clear entry-event tiers that have no battlefield name or session behind them.
function backfill.apply_v10(conn)
    local data_ver = 0;
    for row in conn:nrows('PRAGMA user_version') do data_ver = row.user_version; end
    if (data_ver >= 10) then return; end
    local ok = exec_ok(conn, [[
        UPDATE kills SET bf_difficulty = 0, bf_source = ''
        WHERE COALESCE(bf_difficulty, 0) > 0
          AND COALESCE(battlefield, '') = ''
          AND COALESCE(bf_name, '') = '';
    ]]);
    stamp(conn, ok, 10);
end

function backfill.maintenance(conn)
        -- Close stale battlefield sessions (orphaned by crash/reload, older than 4h)
        local stale_cutoff = os_time() - (4 * 60 * 60);
        local stale_stmt = conn:prepare('UPDATE battlefield_sessions SET exited_at = entered_at WHERE exited_at IS NULL AND entered_at < ?');
        -- A failed prepare must fail the migration, not count as an empty update.
        if (stale_stmt == nil) then return false; end

        stale_stmt:bind_values(stale_cutoff);
        local rc = stale_stmt:step();
        stale_stmt:finalize();
        return (rc == nil) or (rc == SQLITE_DONE) or (rc == SQLITE_OK);
end

return backfill;
