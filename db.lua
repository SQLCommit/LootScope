-- LootScope per-character SQLite persistence and query caches.

require 'common';

local sqlite3 = require 'sqlite3';
-- Read SQLite result codes from the binding; nil is also accepted for exec success.
local SQLITE_OK, SQLITE_DONE = 0, 101;
do
    local okl, lib = pcall(require, 'lsqlite3');
    if (okl and type(lib) == 'table') then SQLITE_OK = lib.OK or SQLITE_OK; SQLITE_DONE = lib.DONE or SQLITE_DONE; end
end
local schema   = require 'db_schema';
local backfill = require 'db_backfill';
local os_time = os.time;

local db = {};
db.conn = nil;
db.path = nil;

-- Source filter → content type name mapping (shared across db.lua and analysis.lua)
db.CONTENT_TYPE_MAP = {
    [4]  = 'Omen',
    [5]  = 'Ambuscade',       -- source-zone (prev == 249 Mhaura) DOES set this; 57 rows exist
    [6]  = 'Sortie',
    [7]  = 'Dynamis',
    [10] = 'Voidwatch',
    [11] = 'Domain Invasion',
    [12] = 'Wildskeeper',
    [13] = 'Einherjar',
    [14] = 'Nyzul',
    [15] = 'Salvage',
    [16] = 'Limbus',
    [17] = 'Vagary',
    [18] = 'Legion',
    [19] = 'Assault',
    [20] = 'Walk of Echoes',
    [21] = 'Skirmish',
    [22] = 'Meeble Burrows',
    [23] = 'Odyssey',
    [25] = 'Colonization Reive',
    [26] = 'Lair Reive',
};

-- Reive filters: 24 combines all kinds, 25/26 count end-spoil runs, and 12 counts Naakual kills.
db.REIVE_CONTENT_SQL = "('Wildskeeper', 'Colonization Reive', 'Lair Reive', 'Reive')";

-- Feed-only contents are excluded from instance statistics. Reive end spoils are listed under
-- Open World; Legion is a battlefield. Keep analysis.lua's fallback in sync.
db.INSTANCE_CONTENT_TYPES = {
    'Omen', 'Sortie', 'Dynamis',
    'Einherjar', 'Nyzul', 'Salvage',
    'Vagary', 'Assault', 'Walk of Echoes',
    'Skirmish', 'Meeble Burrows', 'Odyssey',
};

-- Pre-built SQL IN clause for "All Instances" queries.
local function build_instance_in_clause()
    local parts = {};
    for _, ct in ipairs(db.INSTANCE_CONTENT_TYPES) do
        parts[#parts + 1] = "'" .. ct .. "'";
    end
    return '(' .. table.concat(parts, ', ') .. ')';
end
db.INSTANCE_IN_SQL = build_instance_in_clause();

-- For container-only content such as Walk of Echoes, hide mob kills from analysis lists
-- while retaining them in storage and the live feed.
-- Reive mobs and obstacles drop nothing either: their content's rows are the end-spoils rows.
db.CONTAINER_ONLY_CONTENT_SQL = "('Walk of Echoes', 'Colonization Reive', 'Lair Reive', 'Reive')";
local CONTAINER_ONLY_MOBS_OUT = " AND NOT (COALESCE(k.content_type, '') IN " .. db.CONTAINER_ONLY_CONTENT_SQL .. " AND k.source_type = 0)";
-- A BCNM row is untagged or tagged 'BCNM'; a crate inside another content belongs to that content.
local BCNM_CONTENT_GUARD = " AND COALESCE(k.content_type, '') IN ('', 'BCNM')";
db.BCNM_CONTENT_GUARD = BCNM_CONTENT_GUARD;
db._init_failed = false;  -- true if DB open failed (one-shot warning, skip all writes)

-- Running counters (O(1) counts instead of COUNT(*) scans)
db._kill_count = 0;
db._drop_count = 0;
db._missed_kill_count = 0;
db._chest_event_count = 0;

-- Transaction batching state (amortize fsync across burst writes)
db._in_transaction = false;
db._batch_count = 0;
db._batch_start = 0;
local FLUSH_INTERVAL = 1.0;   -- seconds between forced commits
local FLUSH_THRESHOLD = 20;   -- ops before forced commit

-- Per-cache dirty flags (each consumer only clears its own flag)
db.stats_dirty = true;          -- consumed by UI + analysis to detect stat mutations
db.recent_drops_dirty = true;   -- get_recent_drops
db.recent_feed_dirty = true;    -- get_recent_feed
db.mob_stats_dirty = true;      -- get_mob_stats
db.all_mob_stats_dirty = true;  -- get_all_mob_stats
db.chest_stats_dirty = true;    -- get_chest_stats
db.chest_events_cache_dirty = true;  -- get_recent_chest_events

-- In-memory caches
db.recent_drops_cache = nil;
db.recent_drops_limit = 0;
db.recent_feed_cache = nil;
db.recent_feed_limit = 0;
db.mob_stats_cache = {};
db.all_mob_stats_cache = nil;
db.all_mob_stats_cache_key = nil;
db.zone_list_cache = nil;
db.spawn_stats_cache = {};
db.spawn_item_cache = {};

db.chest_events_cache = nil;
db.chest_events_limit = 0;
db.chest_stats_cache = nil;
db.content_counts_cache = nil;
db.content_counts_dirty = true;   -- get_content_counts

-- Initialization (deferred — called once character name is known)

function db.init(base_path, char_folder)
    if (db.conn ~= nil) then return true; end  -- already initialized
    if (db._init_failed) then return false; end

    -- Per-character subdirectory matching Ashita's settings folder convention
    local char_dir = base_path .. '\\' .. char_folder;
    ashita.fs.create_directory(char_dir);

    -- Migrate from old <CharName>/ folder if it exists
    local new_db_path = char_dir .. '\\lootscope.db';
    local char_name_only = char_folder:match('^(.+)_%d+$');
    if (char_name_only ~= nil) then
        local old_dir = base_path .. '\\' .. char_name_only;
        local old_db_path = old_dir .. '\\lootscope.db';
        local old_f = io.open(old_db_path, 'r');
        if (old_f ~= nil) then
            old_f:close();
            -- Only migrate if new DB doesn't already exist
            local new_f = io.open(new_db_path, 'r');
            if (new_f == nil) then
                local ok, err = os.rename(old_db_path, new_db_path);
                if (ok) then
                    -- Also move WAL/SHM companion files if they exist
                    pcall(os.rename, old_db_path .. '-wal', new_db_path .. '-wal');
                    pcall(os.rename, old_db_path .. '-shm', new_db_path .. '-shm');
                else
                    -- Rename failed — fall back to old path
                    new_db_path = old_db_path;
                end
            else
                new_f:close();
            end
        end
    end

    db.path = new_db_path;
    local open_ok, open_err = pcall(function()
        db.conn = sqlite3.open(db.path);
    end);
    if (not open_ok or db.conn == nil) then
        db._init_failed = true;
        local chat = require 'chat';
        print(chat.header('lootscope'):append(chat.error(
            'Database failed to open: ' .. tostring(open_err)
            .. '. Loot tracking disabled for this session.')));
        return false;
    end

    -- WAL mode + busy_timeout for safety; pcall so a corrupt DB degrades gracefully
    local schema_ok, schema_err = pcall(function()
        db.conn:exec('PRAGMA journal_mode=WAL;');
        db.conn:exec('PRAGMA synchronous=NORMAL;');   -- WAL+NORMAL: corruption-safe, fewer fsyncs (loses <1s only on power loss)
        db.conn:exec('PRAGMA foreign_keys=ON;');
        db.conn:exec('PRAGMA busy_timeout=3000;');

        -- Apply base tables, additive columns, data backfills, index changes, then auxiliary tables.
        -- Only backfill routines rewrite existing rows.
        schema.create_tables(db.conn);
        schema.migrate_columns(db.conn);
        backfill.apply(db.conn);
        backfill.apply_v2(db.conn);        -- own gate (data_ver < 2)
        backfill.apply_v3(db.conn);        -- own gate (data_ver < 3): classification corrections
        backfill.apply_v4(db.conn);        -- own gate (data_ver < 4): Escha Domain Invasion recovery
        schema.migrate_indexes(db.conn);
        schema.create_aux_tables(db.conn);
        -- Generation 5 requires battlefield_sessions; create auxiliary tables first.
        backfill.apply_v5(db.conn);        -- own gate (data_ver < 5): name a battlefield kill from its session
        backfill.apply_v6(db.conn);        -- own gate (data_ver < 6): remove fabricated zone-name battlefields
        backfill.apply_v7(db.conn);        -- own gate (data_ver < 7): name WoE HTMB boss kills (item display)
        backfill.apply_v8(db.conn);        -- own gate (data_ver < 8): mark those HTMB bosses HTBF (tier unknown)
        backfill.apply_v9(db.conn);        -- own gate (data_ver < 9): strip ★ from bf_name; battlefield kills are not distant
        backfill.apply_v10(db.conn);       -- own gate (data_ver < 10): a tier with no battlefield behind it is cleared

        -- Initialize running counters from existing data
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM kills') do db._kill_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM drops') do db._drop_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM missed_kills') do db._missed_kill_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM chest_events') do db._chest_event_count = row.c; end

        backfill.maintenance(db.conn);
    end);

    if (not schema_ok) then
        db._init_failed = true;
        pcall(function() db.conn:close(); end);
        db.conn = nil;
        local chat = require 'chat';
        print(chat.header('lootscope'):append(chat.error(
            'Database schema failed: ' .. tostring(schema_err)
            .. '. Loot tracking disabled for this session.')));
        return false;
    end

    -- Connection is healthy again: re-arm the one-shot warnings so a LATER failure is not
    -- swallowed.
    db._noconn_warned = false;
    db._write_warned  = false;

    return true;
end

-- Helpers: Cache Invalidation

-- Full invalidation — only used by clear_data()
local function invalidate_all()
    db.stats_dirty = true;
    db.recent_drops_dirty = true;
    db.recent_feed_dirty = true;
    db.mob_stats_dirty = true;
    db.all_mob_stats_dirty = true;
    db.content_counts_dirty = true;
    db.chest_events_cache_dirty = true;
    db.chest_stats_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.mob_stats_cache = {};
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
    db.zone_list_cache = nil;
    db.spawn_stats_cache = {};
    db.spawn_item_cache = {};
    
    db.chest_events_cache = nil;
    db.chest_stats_cache = nil;
end

-- Kill recorded: invalidates kill-related caches + stats
local function invalidate_kills()
    db.stats_dirty = true;
    db.recent_feed_dirty = true;
    db.mob_stats_dirty = true;
    db.all_mob_stats_dirty = true;
    db.content_counts_dirty = true;
    db.recent_feed_cache = nil;
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
    db.mob_stats_cache = {};
    db.spawn_stats_cache = {};
    db.spawn_item_cache = {};
    db.zone_list_cache = nil;
end

-- Drop recorded: invalidates drop-related caches + stats
local function invalidate_drops()
    db.stats_dirty = true;
    db.recent_drops_dirty = true;
    db.recent_feed_dirty = true;
    db.mob_stats_dirty = true;
    db.all_mob_stats_dirty = true;
    db.content_counts_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
    db.mob_stats_cache = {};
    db.spawn_item_cache = {};
end

-- Lot result updated: invalidates feed/drop display and stats (won status affects computed stats)
local function invalidate_drop_status()
    db.stats_dirty = true;
    db.recent_drops_dirty = true;
    db.recent_feed_dirty = true;
    db.mob_stats_dirty = true;
    db.all_mob_stats_dirty = true;
    db.content_counts_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.mob_stats_cache = {};
    db.spawn_item_cache = {};
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
end

-- Helpers: Transaction Batching

local function begin_batch()
    if (db.conn == nil) then return; end
    if (not db._in_transaction) then
        local ok = pcall(db.conn.exec, db.conn, 'BEGIN');
        if (not ok) then return; end
        db._in_transaction = true;
        db._batch_count = 0;
        db._batch_start = os.clock();
    end
end

local _commit_warn_logged = false;

local function maybe_commit()
    if (not db._in_transaction) then return; end
    db._batch_count = db._batch_count + 1;
    if (db._batch_count >= FLUSH_THRESHOLD or os.clock() - db._batch_start >= FLUSH_INTERVAL) then
        local ok = pcall(db.conn.exec, db.conn, 'COMMIT');
        if (ok) then
            db._in_transaction = false;
            _commit_warn_logged = false;
        else
            -- Reset batch counters so next cycle retries after a fresh threshold
            db._batch_count = 0;
            db._batch_start = os.clock();
            if (not _commit_warn_logged) then
                _commit_warn_logged = true;
                local chat = require 'chat';
                print(chat.header('lootscope'):append(chat.error(
                    'DB commit delayed (busy lock). Data is safe but buffered.')));
            end
        end
    end
end

-- One-shot warning when a write fails (prepare/step): a persistent DB write problem (disk full,
-- permissions, corruption) would otherwise lose records silently. Printed once per session.
local function warn_write_failure(what)
    if (db._write_warned) then return; end
    db._write_warned = true;
    local chat = require 'chat';
    print(chat.header('lootscope'):append(chat.error(
        'DB write failed (' .. what .. ') - some records may not be saved. Check disk space / permissions.')));
end

local function warn_no_connection(what)
    if (db._noconn_warned) then return; end
    db._noconn_warned = true;
    local chat = require 'chat';
    print(chat.header('lootscope'):append(chat.error(
        'not connected to the database - ' .. what .. ' are NOT being recorded. Reload the addon (/addon reload lootscope).')));
end

-- Force-flush any open transaction immediately (used before scan_pool on reload)
function db.flush_pending()
    if (not db._in_transaction) then return; end
    local ok = pcall(db.conn.exec, db.conn, 'COMMIT');
    if (ok) then
        db._in_transaction = false;
    end
end

-- Called from d3d_present to flush stale open transactions
function db.flush_writes_if_due()
    if (not db._in_transaction) then return; end
    if (os.clock() - db._batch_start >= FLUSH_INTERVAL) then
        local ok = pcall(db.conn.exec, db.conn, 'COMMIT');
        if (ok) then
            db._in_transaction = false;
        end
    end
end

-- Kill Recording

function db.record_kill(mob_name, mob_server_id, zone_id, zone_name, th_level, source_type, vana_info, kill_info)
    if (db.conn == nil) then warn_no_connection('kills'); return nil; end

    begin_batch();

    local now = os_time();
    local vi = vana_info or {};
    local ki = kill_info or {};
    local stmt = db.conn:prepare([[
        INSERT INTO kills (mob_name, mob_server_id, zone_id, zone_name, th_level, source_type,
                           vana_weekday, vana_hour, moon_phase, moon_percent, timestamp,
                           killer_id, killer_name, th_action_type, th_action_id, weather,
                           battlefield, level_cap, is_distant,
                           bf_name, bf_difficulty, content_type, th_estimated,
                           app_version, bf_source,
                           previous_zone_id, entry_zone_id, content_source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]);
    if (stmt == nil) then warn_write_failure('kill'); maybe_commit(); return nil; end
    stmt:bind_values(
        mob_name, mob_server_id, zone_id, zone_name,
        th_level or 0, source_type or 0,
        vi.weekday or -1, vi.hour or -1,
        vi.moon_phase or -1, vi.moon_percent or -1,
        now,
        ki.killer_id or 0, ki.killer_name or '',
        ki.th_action_type or 0, ki.th_action_id or 0,
        vi.weather or -1,
        ki.battlefield, ki.level_cap,
        ki.is_distant or 0,
        ki.bf_name or '', ki.bf_difficulty or 0,
        ki.content_type or '',
        ki.th_estimated or 0,
        -- Provenance: which build wrote this row, and how its battlefield class was decided.
        (_G.addon ~= nil and _G.addon.version) or '',
        ki.bf_source or '',
        -- previous_zone_id records the last transition; entry_zone_id survives transitions within
        -- classify.SHARED_ZONE_GROUP.
        ki.previous_zone_id or 0, ki.entry_zone_id or 0,
        ki.content_source or ''
    );
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then warn_write_failure('kill'); maybe_commit(); return nil; end
    local rowid = db.conn:last_insert_rowid();

    db._kill_count = db._kill_count + 1;
    invalidate_kills();
    maybe_commit();

    return rowid;
end

-- Patch a kill record when 0x0029 defeat arrives after 0x00D2 fallback created it.
-- Clears is_distant flag and adds killer/TH metadata that the fallback path lacks.
function db.patch_kill_on_defeat(kill_id, info)
    if (db.conn == nil or kill_id == nil) then return; end
    info = info or {};   -- harden like record_kill's kill_info-or-{} idiom (caller passes a table today)

    begin_batch();

    local ct = info.content_type or '';
    local ct_clause = '';
    if (ct ~= '' and ct ~= 'Unknown Battlefield') then
        ct_clause = ", content_type = CASE WHEN COALESCE(content_type, '') IN ('', 'Unknown Battlefield') THEN ? ELSE content_type END"
                 .. ", content_source = CASE WHEN COALESCE(content_type, '') IN ('', 'Unknown Battlefield') THEN ? ELSE content_source END";
    end

    -- Never replace stored TH with a lower value: a pool-first kill may have consumed the proc already.
    -- Each SET expression reads the pre-update row, so all three comparisons use the same old level.
    local th = info.th_level or 0;
    local stmt = db.conn:prepare([[
        UPDATE kills SET is_distant = 0,
            killer_id = ?, killer_name = ?,
            th_level       = CASE WHEN ? > COALESCE(th_level, 0) THEN ? ELSE COALESCE(th_level, 0) END,
            th_action_type = CASE WHEN ? > COALESCE(th_level, 0) THEN ? ELSE th_action_type END,
            th_action_id   = CASE WHEN ? > COALESCE(th_level, 0) THEN ? ELSE th_action_id END,
            th_estimated = ?]] .. ct_clause .. [[
        WHERE id = ? AND is_distant = 1
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    if (ct ~= '') then
        stmt:bind_values(
            info.killer_id or 0, info.killer_name or '',
            th, th, th, info.th_action_type or 0, th, info.th_action_id or 0,
            info.th_estimated or 0,
            ct, info.content_source or '',
            kill_id
        );
    else
        stmt:bind_values(
            info.killer_id or 0, info.killer_name or '',
            th, th, th, info.th_action_type or 0, th, info.th_action_id or 0,
            info.th_estimated or 0,
            kill_id
        );
    end
    stmt:step();
    stmt:finalize();

    if (db.conn:changes() > 0) then
        invalidate_kills();
    end

    maybe_commit();
end

-- Drop Recording

-- Rename a kill row the tracker created moments ago (a Limbus chest learns its bonus/normal tier
-- from a message that may land after the first item). Live-row write, not a backfill.
function db.set_kill_name(kill_id, name)
    if (db.conn == nil) then warn_no_connection('kills'); return false; end
    if (kill_id == nil or name == nil or name == '') then return false; end
    local stmt = db.conn:prepare('UPDATE kills SET mob_name = ? WHERE id = ?');
    if (stmt == nil) then return false; end
    stmt:bind_values(name, kill_id);
    local rc = stmt:step(); stmt:finalize();
    db.recent_feed_dirty = true;
    return (rc == nil) or (rc == SQLITE_DONE) or (rc == SQLITE_OK);
end

function db.record_drop(kill_id, pool_slot, item_id, item_name, quantity, won, drop_order)
    -- Split deliberately: a nil kill_id is a legitimate skip and stays silent; a nil connection is
    -- silent DATA LOSS and must not be.
    if (db.conn == nil) then warn_no_connection('drops'); return nil; end
    if (kill_id == nil) then return nil; end

    begin_batch();

    local now = os_time();
    local stmt = db.conn:prepare([[
        INSERT INTO drops (kill_id, pool_slot, item_id, item_name, quantity, won, lot_value, drop_order, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
    ]]);
    if (stmt == nil) then warn_write_failure('drop'); maybe_commit(); return nil; end
    stmt:bind_values(kill_id, pool_slot, item_id, item_name, quantity or 1, won or 0, drop_order or -1, now);
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then warn_write_failure('drop'); maybe_commit(); return nil; end
    local rowid = db.conn:last_insert_rowid();

    db._drop_count = db._drop_count + 1;
    invalidate_drops();
    maybe_commit();

    return rowid;
end

-- Find Pending Drop (reconnect pool items after addon reload)

--- max_age_seconds bounds how far back a reconnect may reach.
function db.find_pending_drop(pool_slot, item_id, max_age_seconds)
    if (db.conn == nil) then return nil; end

    local cutoff = os_time() - (max_age_seconds or 900);   -- 15 min: 5 min pool + reconnect margin

    local stmt = db.conn:prepare([[
        SELECT d.id, d.kill_id, d.item_name, d.quantity, d.won
        FROM drops d
        WHERE d.pool_slot = ? AND d.item_id = ? AND d.won IN (0, -2) AND d.timestamp >= ?
        ORDER BY d.timestamp DESC LIMIT 1
    ]]);
    if (stmt == nil) then return nil; end
    stmt:bind_values(pool_slot, item_id, cutoff);

    local result = nil;
    for row in stmt:nrows() do
        result = {
            drop_id   = row.id,
            kill_id   = row.kill_id,
            item_name = row.item_name,
            quantity  = row.quantity,
            was_zoned = (row.won == -2),
        };
    end
    stmt:finalize();

    -- Reset Zoned status back to Pending if reconnecting
    if (result ~= nil and result.was_zoned) then
        begin_batch();
        local upd = db.conn:prepare('UPDATE drops SET won = 0 WHERE id = ?');
        if (upd == nil) then maybe_commit(); return result; end
        upd:bind_values(result.drop_id);
        upd:step();
        upd:finalize();
        invalidate_drop_status();
        maybe_commit();
    end

    return result;
end

-- Find most recent Wildskeeper kill in zone (for addon reload recovery)

function db.find_recent_wildskeeper_kill(zone_id, max_age_seconds)
    if (db.conn == nil or zone_id == nil) then return nil; end
    max_age_seconds = max_age_seconds or 120;

    local cutoff = os.time() - max_age_seconds;
    local stmt = db.conn:prepare(
        "SELECT id, mob_name FROM kills WHERE content_type = 'Wildskeeper' AND zone_id = ? "
        .. "AND timestamp >= ? ORDER BY id DESC LIMIT 1"
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(zone_id, cutoff);
    local result = nil;
    for row in stmt:nrows() do
        result = { kill_id = row.id, mob_name = row.mob_name };
        break;
    end
    stmt:finalize();
    return result;
end

-- Kill Name Update (retroactive mob name from chat when entity was out of range)

function db.update_kill_mob_name(kill_id, mob_name)
    if (db.conn == nil or kill_id == nil or mob_name == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare([[
        UPDATE kills SET mob_name = ? WHERE id = ? AND mob_name IN ('Unknown', 'Unknown (late join)')
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(mob_name, kill_id);
    stmt:step();
    stmt:finalize();

    invalidate_kills();
    -- Also invalidate drops (JOINs kills for mob_name)
    db.recent_drops_dirty = true;
    db.recent_drops_cache = nil;
    maybe_commit();
end

-- Drop Update (lot result)

--- drop_id targets ONE row and is strongly preferred.
function db.update_drop_won(kill_id, pool_slot, won, lot_value, lot_info, drop_id)
    if (db.conn == nil) then return; end

    begin_batch();

    local li = lot_info or {};
    local stmt;
    if (drop_id ~= nil) then
        stmt = db.conn:prepare([[
            UPDATE drops SET won = ?, lot_value = ?, winner_id = ?, winner_name = ?,
                             player_lot = ?, player_action = ?
            WHERE id = ?
        ]]);
    else
        stmt = db.conn:prepare([[
            UPDATE drops SET won = ?, lot_value = ?, winner_id = ?, winner_name = ?,
                             player_lot = ?, player_action = ?
            WHERE kill_id = ? AND pool_slot = ?
        ]]);
    end
    if (stmt == nil) then maybe_commit(); return; end
    if (drop_id ~= nil) then
        stmt:bind_values(
            won, lot_value or 0,
            li.winner_id or 0, li.winner_name or '',
            li.player_lot or 0, li.player_action or 0,
            drop_id
        );
    else
        stmt:bind_values(
            won, lot_value or 0,
            li.winner_id or 0, li.winner_name or '',
            li.player_lot or 0, li.player_action or 0,
            kill_id, pool_slot
        );
    end
    stmt:step();
    stmt:finalize();

    invalidate_drop_status();
    maybe_commit();
end

-- Queries (cached)

function db.get_recent_drops(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.recent_drops_dirty and db.recent_drops_cache ~= nil and db.recent_drops_limit == limit) then
        return db.recent_drops_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT d.*,
               CASE WHEN k.source_type IN (2,3) AND COALESCE(k.content_type,'') IN ('', 'BCNM') THEN COALESCE(NULLIF(k.battlefield,''), NULLIF(k.bf_name,''), k.mob_name) ELSE k.mob_name END AS mob_name,
               k.zone_name, k.zone_id, k.th_level, k.source_type,
               k.timestamp as kill_ts,
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name,
               k.bf_name, k.bf_difficulty,
               COALESCE(k.battlefield, '') as battlefield,
               COALESCE(k.content_type, '') as content_type
        FROM drops d
        JOIN kills k ON d.kill_id = k.id
        ORDER BY d.id DESC
        LIMIT ?
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(limit);
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.recent_drops_cache = results;
    db.recent_drops_limit = limit;
    db.recent_drops_dirty = false;

    return results;
end

function db.get_recent_feed(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.recent_feed_dirty and db.recent_feed_cache ~= nil and db.recent_feed_limit == limit) then
        return db.recent_feed_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT 'drop' as feed_type, d.timestamp as ts,
               -- 🚨 A named battlefield shows ITS name as the source, for boss/mob drops the
               -- same as for its crate/coffer -- so an HTBF's items read the HTBF name, not
               -- the boss mob's. Falls to mob_name in the open world (battlefield/bf_name empty).
               -- Battlefield CONTENT only: a Walk of Echoes row carries "Walk #3" there and keeps its name.
               CASE WHEN COALESCE(k.content_type,'') IN ('', 'BCNM')
                    THEN COALESCE(NULLIF(k.battlefield,''), NULLIF(k.bf_name,''), k.mob_name)
                    ELSE k.mob_name END as mob_name,
               k.zone_name, k.zone_id, k.th_level, k.source_type,
               d.item_name, d.item_id, d.quantity, d.won, d.pool_slot, d.kill_id,
               d.lot_value, d.winner_name, d.player_action,
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name,
               0 as container_type, 0 as chest_result, 0 as gil_amount,
               k.bf_name, k.bf_difficulty,
               COALESCE(k.battlefield, '') as battlefield,
               COALESCE(k.content_type, '') as content_type,
               COALESCE(k.th_estimated, 0) as th_estimated
        FROM drops d
        JOIN kills k ON d.kill_id = k.id
        UNION ALL
        SELECT 'kill' as feed_type, k.timestamp as ts,
               -- 🚨 A KILL row names the MOB. Only a container (chest/coffer/crate) takes the
               -- battlefield name -- it is not a mob. Applying the battlefield rule to mob kills
               -- (2026-08-31) made every scorpion in a BCNM read as the BCNM (reported 2026-09-02).
               -- The item rule above is unchanged: a battlefield's DROPS still read its name.
               CASE WHEN k.source_type IN (1, 2, 3) AND COALESCE(k.content_type,'') IN ('', 'BCNM')
                    THEN COALESCE(NULLIF(k.battlefield,''), NULLIF(k.bf_name,''), k.mob_name)
                    ELSE k.mob_name END as mob_name,
               k.zone_name, k.zone_id, k.th_level, k.source_type,
               NULL, 0, 0, 0, -1, k.id,
               0, '', 0,
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name,
               0, 0, 0,
               k.bf_name, k.bf_difficulty,
               COALESCE(k.battlefield, '') as battlefield,
               COALESCE(k.content_type, '') as content_type,
               COALESCE(k.th_estimated, 0) as th_estimated
        FROM kills k
        WHERE NOT EXISTS (SELECT 1 FROM drops d WHERE d.kill_id = k.id)
        UNION ALL
        SELECT 'chest' as feed_type, ce.timestamp as ts,
               '' as mob_name, ce.zone_name, ce.zone_id, 0 as th_level, ce.container_type as source_type,
               NULL, 0, 0, 0, -1, 0,
               0, '', 0,
               0, ce.vana_weekday, ce.vana_hour, ce.moon_phase, ce.moon_percent,
               ce.weather, '' as killer_name,
               ce.container_type, ce.result, ce.gil_amount,
               '' as bf_name, 0 as bf_difficulty,
               '' as battlefield,
               '' as content_type,
               0 as th_estimated
        FROM chest_events ce
        ORDER BY ts DESC, kill_id DESC
        LIMIT ?
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(limit);
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.recent_feed_cache = results;
    db.recent_feed_limit = limit;
    db.recent_feed_dirty = false;

    return results;
end

function db.get_mob_stats(mob_name, zone_id, source_filter, level_cap, bf_difficulty)
    if (db.conn == nil) then return nil; end

    local key = (mob_name or '') .. '_' .. tostring(zone_id or 0) .. '_' .. tostring(source_filter or -1) .. '_' .. tostring(level_cap or 'nil') .. '_' .. tostring(bf_difficulty or 'nil');
    if (not db.mob_stats_dirty and db.mob_stats_cache[key] ~= nil) then
        return db.mob_stats_cache[key];
    end

    local result = { kills = 0, distant_kills = 0, items = T{}, total_drops = 0 };

    -- BCNM mode: match by battlefield name instead of mob_name
    local is_bcnm = (source_filter == 2);
    local is_htbf = (source_filter == 3);
    local is_content = (db.CONTENT_TYPE_MAP[source_filter] ~= nil);
    local is_all_bf = (source_filter == 8);
    local is_all_inst = (source_filter == 9);
    local is_all_reive = (source_filter == 24);
    local kill_query, item_query;

    if (is_htbf) then
        -- HTBF: match by bf_name + zone + bf_difficulty. level_cap param carries bf_difficulty.
        local bf_name_expr = "COALESCE(NULLIF(bf_name, ''), COALESCE(battlefield, 'Unknown HTBF'))";
        local k_bf_name_expr = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, 'Unknown HTBF'))";
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE ' .. bf_name_expr .. ' = ? AND zone_id = ? AND bf_difficulty = ?';
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE ]] .. k_bf_name_expr .. [[ = ? AND k.zone_id = ? AND k.bf_difficulty = ?
            GROUP BY d.item_id ORDER BY times_dropped DESC
        ]];
    elseif (is_bcnm) then
        -- BCNM: must match get_all_mob_stats(2) -- either source_type=3 or content_type='BCNM'
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant, SUM(CASE WHEN source_type IN (2, 3) THEN 1 ELSE 0 END) as runs, SUM(CASE WHEN source_type IN (2, 3) AND is_distant = 1 THEN 1 ELSE 0 END) as runs_distant FROM kills WHERE COALESCE(NULLIF(battlefield, \'\'), NULLIF(bf_name, \'\'), \'Unknown BCNM\') = ? AND zone_id = ? AND (source_type = 3 OR COALESCE(content_type, \'\') = \'BCNM\' AND (COALESCE(battlefield, \'\') <> \'\' OR COALESCE(bf_name, \'\') <> \'\')) AND COALESCE(bf_difficulty, 0) = 0 AND COALESCE(content_type, \'\') IN (\'\', \'BCNM\')';
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE COALESCE(NULLIF(k.battlefield, ''), NULLIF(k.bf_name, ''), 'Unknown BCNM') = ? AND k.zone_id = ? AND (k.source_type = 3 OR (COALESCE(k.content_type, '') = 'BCNM' AND (COALESCE(k.battlefield, '') <> '' OR COALESCE(k.bf_name, '') <> ''))) AND COALESCE(k.bf_difficulty, 0) = 0]] .. BCNM_CONTENT_GUARD .. [[

        ]];
        -- Add level_cap filter if present
        if (level_cap ~= nil) then
            kill_query = kill_query .. ' AND level_cap = ?';
            item_query = item_query .. ' AND k.level_cap = ?';
        else
            kill_query = kill_query .. ' AND level_cap IS NULL';
            item_query = item_query .. ' AND k.level_cap IS NULL';
        end
        item_query = item_query .. ' GROUP BY d.item_id ORDER BY times_dropped DESC';
    elseif (is_content) then
        local ct = db.CONTENT_TYPE_MAP[source_filter];
        kill_query = "SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE mob_name = ? AND zone_id = ? AND COALESCE(content_type, '') = '" .. ct .. "'";
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE k.mob_name = ? AND k.zone_id = ? AND COALESCE(k.content_type, '') = ']] .. ct .. [['
            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    elseif (is_all_bf) then
        -- All Battlefields: match by battlefield name + level_cap + bf_difficulty
        local bf_expr = "COALESCE(NULLIF(bf_name, ''), COALESCE(battlefield, mob_name))";
        local k_bf_expr = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, k.mob_name))";
        local lc = level_cap or 0;
        local bd = bf_difficulty or 0;
        -- BCNM trials use chest opens; HTBF trials retain kill counts.
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant, SUM(CASE WHEN source_type IN (2, 3) THEN 1 ELSE 0 END) as runs, SUM(CASE WHEN source_type IN (2, 3) AND is_distant = 1 THEN 1 ELSE 0 END) as runs_distant FROM kills WHERE ' .. bf_expr .. ' = ? AND zone_id = ? AND COALESCE(level_cap, 0) = ' .. tostring(lc) .. ' AND COALESCE(bf_difficulty, 0) = ' .. tostring(bd);
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE ]] .. k_bf_expr .. [[ = ? AND k.zone_id = ? AND COALESCE(k.level_cap, 0) = ]] .. tostring(lc) .. [[ AND COALESCE(k.bf_difficulty, 0) = ]] .. tostring(bd) .. [[

            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    elseif (is_all_inst or is_all_reive) then
        local in_sql = is_all_reive and db.REIVE_CONTENT_SQL or db.INSTANCE_IN_SQL;
        kill_query = "SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE mob_name = ? AND zone_id = ? AND COALESCE(content_type, '') IN " .. in_sql;
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE k.mob_name = ? AND k.zone_id = ? AND COALESCE(k.content_type, '') IN ]] .. in_sql .. [[
            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    elseif (source_filter == 1) then
        -- Chest/Coffer: must match get_all_mob_stats(1) which filters source_type IN (1,2)
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE mob_name = ? AND zone_id = ? AND source_type IN (1, 2) AND COALESCE(content_type, \'\') = \'\'';
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE k.mob_name = ? AND k.zone_id = ? AND k.source_type IN (1, 2) AND COALESCE(k.content_type, '') = ''
            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    else
        -- Field (value 0): exclude content-tagged kills AND non-mob source types
        -- Matches get_all_mob_stats() Field branch: source_type = 0
        kill_query = "SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE mob_name = ? AND zone_id = ? AND source_type = 0 AND COALESCE(content_type, '') = ''";
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN d.won = -1 THEN 1 ELSE 0 END) as times_left,
                   SUM(CASE WHEN d.won IN (0, -2) THEN 1 ELSE 0 END) as times_pending,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped,
                   -- Number of KILLS that yielded this item, not the number of drop ROWS.
                   -- times_dropped/nearby_times_dropped count rows and are correct for display
                   -- ("3x", average stack size), but a mob dropping 3 of an item on one kill makes
                   -- them exceed the kill count. Probability maths (rate, Wilson CI, expected-empty)
                   -- needs successes-out-of-trials, so it must use this instead.
                   COUNT(DISTINCT CASE WHEN k.is_distant = 0 THEN d.kill_id END) as nearby_kills_with_drop,
                   COUNT(DISTINCT d.kill_id) as kills_with_drop
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE k.mob_name = ? AND k.zone_id = ? AND k.source_type = 0 AND COALESCE(k.content_type, '') = ''
            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    end

    -- Kill count (from kills table)
    local stmt = db.conn:prepare(kill_query);
    if (stmt == nil) then return result; end
    if (is_htbf) then
        stmt:bind_values(mob_name, zone_id, level_cap);  -- level_cap = bf_difficulty for HTBF
    elseif (is_bcnm and level_cap ~= nil) then
        stmt:bind_values(mob_name, zone_id, level_cap);
    else
        stmt:bind_values(mob_name, zone_id);  -- is_all_bf: level_cap/bf_difficulty inlined in query
    end
    for row in stmt:nrows() do
        result.kills = row.c;
        result.distant_kills = row.distant or 0;
        -- Use chest opens as the BCNM denominator, falling back to matched kills if no crate was recorded.
        -- HTBF rows retain the kill denominator.
        local bcnm_denominator = is_bcnm or (is_all_bf and (bf_difficulty or 0) == 0);
        if (bcnm_denominator and row.runs ~= nil and row.runs > 0) then
            result.kills = row.runs;
            result.distant_kills = row.runs_distant or 0;
        end
    end
    stmt:finalize();

    -- Chest/Coffer mode: add chest_events as additional attempts
    if (source_filter == 1) then
        local ctype = nil;
        if (mob_name == 'Treasure Chest') then ctype = 1;
        elseif (mob_name == 'Treasure Coffer') then ctype = 2; end
        if (ctype ~= nil) then
            -- Exclude illusions (result=4) from attempt count
            local ce_stmt = db.conn:prepare(
                'SELECT COUNT(*) as c FROM chest_events WHERE zone_id = ? AND container_type = ? AND result != 4');
            if (ce_stmt ~= nil) then
                ce_stmt:bind_values(zone_id, ctype);
                for row in ce_stmt:nrows() do
                    result.kills = result.kills + row.c;
                end
                ce_stmt:finalize();
            end
        end
    end

    if (result.kills == 0) then
        db.mob_stats_cache[key] = result;
        return result;
    end

    -- Per-item breakdown
    local stmt2 = db.conn:prepare(item_query);
    if (stmt2 == nil) then return result; end
    if (is_htbf) then
        stmt2:bind_values(mob_name, zone_id, level_cap);  -- level_cap = bf_difficulty for HTBF
    elseif (is_bcnm and level_cap ~= nil) then
        stmt2:bind_values(mob_name, zone_id, level_cap);
    else
        stmt2:bind_values(mob_name, zone_id);  -- is_all_bf: level_cap/bf_difficulty inlined in query
    end
    local nearby_kills = result.kills - result.distant_kills;
    for row in stmt2:nrows() do
        -- Probability uses kills yielding an item, not drop-row count; retain row counts for quantity
        -- display.
        local nearby_hits = row.nearby_kills_with_drop or row.nearby_times_dropped or row.times_dropped;
        local hits = row.kills_with_drop or row.times_dropped;
        -- Primary rate: nearby kills only (unbiased)
        row.drop_rate = (nearby_kills > 0) and (nearby_hits / nearby_kills) * 100 or 0;
        -- Combined rate: includes distant kills (biased — distant kills always have drops)
        row.combined_rate = (result.kills > 0) and (hits / result.kills) * 100 or -1;
        -- Gil (65535): shown in breakdown but excluded from aggregate counts
        if (row.item_id == 65535) then
            row.is_gil_drop = true;
            row.drop_rate = -1;  -- suppress % display
            row.combined_rate = -1;
        else
            result.total_drops = result.total_drops + row.times_dropped;
        end
        result.items:append(row);
    end
    stmt2:finalize();

    -- Enhance mob gil entry with min/max/avg amount
    for _, item in ipairs(result.items) do
        if (item.is_gil_drop and item.times_dropped > 0) then
            local gil_q;
            local gil_params;
            if (is_htbf) then
                local k_bf = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, 'Unknown HTBF'))";
                gil_q = 'SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND ' .. k_bf .. ' = ? AND k.zone_id = ? AND k.bf_difficulty = ?';
                gil_params = { mob_name, zone_id, level_cap };
            elseif (is_bcnm) then
                gil_q = [[
                    SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil
                    FROM drops d JOIN kills k ON d.kill_id = k.id
                    WHERE d.item_id = 65535 AND COALESCE(NULLIF(k.battlefield, ''), NULLIF(k.bf_name, ''), 'Unknown BCNM') = ? AND k.zone_id = ? AND (k.source_type = 3 OR (COALESCE(k.content_type, '') = 'BCNM' AND (COALESCE(k.battlefield, '') <> '' OR COALESCE(k.bf_name, '') <> ''))) AND COALESCE(k.bf_difficulty, 0) = 0]] .. BCNM_CONTENT_GUARD .. [[

                ]];
                if (level_cap ~= nil) then
                    gil_q = gil_q .. ' AND k.level_cap = ?';
                    gil_params = { mob_name, zone_id, level_cap };
                else
                    gil_q = gil_q .. ' AND k.level_cap IS NULL';
                    gil_params = { mob_name, zone_id };
                end
            elseif (is_content) then
                local ct = db.CONTENT_TYPE_MAP[source_filter];
                gil_q = "SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ? AND COALESCE(k.content_type, '') = '" .. ct .. "'";
                gil_params = { mob_name, zone_id };
            elseif (is_all_bf) then
                local k_bf = "COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, k.mob_name))";
                local lc = level_cap or 0;
                local bd = bf_difficulty or 0;
                gil_q = 'SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND ' .. k_bf .. ' = ? AND k.zone_id = ? AND COALESCE(k.level_cap, 0) = ' .. tostring(lc) .. ' AND COALESCE(k.bf_difficulty, 0) = ' .. tostring(bd);
                gil_params = { mob_name, zone_id };
            elseif (is_all_inst or is_all_reive) then
                gil_q = "SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ? AND COALESCE(k.content_type, '') IN " .. (is_all_reive and db.REIVE_CONTENT_SQL or db.INSTANCE_IN_SQL);
                gil_params = { mob_name, zone_id };
            elseif (source_filter == 1) then
                gil_q = 'SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ? AND k.source_type IN (1, 2) AND COALESCE(k.content_type, \'\') = \'\'';
                gil_params = { mob_name, zone_id };
            else
                -- Field: exclude content-tagged kills
                gil_q = "SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil FROM drops d JOIN kills k ON d.kill_id = k.id WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ? AND k.source_type = 0 AND COALESCE(k.content_type, '') = ''";
                gil_params = { mob_name, zone_id };
            end
            local gs = db.conn:prepare(gil_q);
            if (gs ~= nil) then
                gs:bind_values(unpack(gil_params));
                for gr in gs:nrows() do
                    local avg = math.floor(item.total_qty / item.times_dropped);
                    local mn = gr.min_gil or 0;
                    local mx = gr.max_gil or 0;
                    if (mn == mx) then
                        item.item_name = 'Gil (' .. tostring(avg) .. 'g)';
                    else
                        item.item_name = 'Gil (' .. tostring(mn) .. '-' .. tostring(mx) .. 'g, avg ' .. tostring(avg) .. 'g)';
                    end
                end
                gs:finalize();
            end
            break;  -- only one gil entry
        end
    end

    -- Chest/Coffer mode: add chest events as synthetic items in breakdown
    if (source_filter == 1) then
        local ctype = nil;
        if (mob_name == 'Treasure Chest') then ctype = 1;
        elseif (mob_name == 'Treasure Coffer') then ctype = 2; end
        if (ctype ~= nil) then
            local ce_detail = db.conn:prepare([[
                SELECT result,
                       COUNT(*) as times_dropped,
                       SUM(CASE WHEN result = 0 THEN gil_amount ELSE 0 END) as total_gil,
                       MIN(CASE WHEN result = 0 AND gil_amount > 0 THEN gil_amount ELSE NULL END) as min_gil,
                       MAX(CASE WHEN result = 0 THEN gil_amount ELSE NULL END) as max_gil
                FROM chest_events
                WHERE zone_id = ? AND container_type = ?
                GROUP BY result
                ORDER BY result ASC
            ]]);
            if (ce_detail ~= nil) then
                local result_names = {
                    [0] = 'Gil',
                    [1] = 'Lockpick Failed',
                    [2] = 'Trapped!',
                    [3] = 'Mimic!',
                    [4] = 'Illusion',
                };
                ce_detail:bind_values(zone_id, ctype);
                for row in ce_detail:nrows() do
                    local name = result_names[row.result] or ('Event #' .. tostring(row.result));
                    if (row.result == 0 and (row.total_gil or 0) > 0) then
                        local avg = math.floor(row.total_gil / row.times_dropped);
                        local mn = row.min_gil or 0;
                        local mx = row.max_gil or 0;
                        if (mn == mx) then
                            name = 'Gil (' .. tostring(avg) .. 'g)';
                        else
                            name = 'Gil (' .. tostring(mn) .. '-' .. tostring(mx) .. 'g, avg ' .. tostring(avg) .. 'g)';
                        end
                    end
                    -- Illusions (result=4) excluded from kills denominator, so no rate
                    local rate = (row.result == 4) and -1
                        or (row.times_dropped / result.kills) * 100;
                    result.items:append({
                        item_id       = -(row.result + 1),  -- negative IDs for chest events
                        item_name     = name,
                        times_dropped = row.times_dropped,
                        total_qty     = row.times_dropped,
                        times_won     = (row.result == 0) and row.times_dropped or 0,
                        drop_rate     = rate,
                        is_chest_event = true,
                    });
                    result.total_drops = result.total_drops + row.times_dropped;
                end
                ce_detail:finalize();
            end
        end
    end

    db.mob_stats_cache[key] = result;
    db.mob_stats_dirty = false;
    return result;
end

-- The five aggregate columns every get_all_mob_stats variant selects.
local STATS_AGG_COLS = [[
                   COUNT(DISTINCT k.id) as kill_count,
                   COUNT(DISTINCT CASE WHEN k.is_distant = 1 THEN k.id ELSE NULL END) as distant_kills,
                   COUNT(CASE WHEN d.item_id != 65535 THEN d.id ELSE NULL END) as drop_count,
                   COUNT(DISTINCT CASE WHEN d.item_id != 65535 THEN d.item_id ELSE NULL END) as unique_items,
                   COUNT(DISTINCT k.mob_server_id) as unique_spawns]];

local function finalise_stats_row(row)
    local has_runs = (row.run_count ~= nil and row.run_count > 0);
    local denom    = has_runs and row.run_count or row.kill_count;
    row.runs       = has_runs and row.run_count or nil;
    row.avg_drops  = denom > 0 and (row.drop_count / denom) or 0;
end

function db.get_all_mob_stats(source_filter)
    if (db.conn == nil) then return T{}; end

    -- Cache key includes source_filter to avoid stale results across views
    local cache_key = tostring(source_filter or -1);
    if (not db.all_mob_stats_dirty and db.all_mob_stats_cache ~= nil
        and db.all_mob_stats_cache_key == cache_key) then
        return db.all_mob_stats_cache;
    end

    local results = T{};
    local where_clause = '';

    if (source_filter == 0) then
        where_clause = " WHERE k.source_type = 0 AND COALESCE(k.content_type, '') = ''";
    elseif (source_filter == 1) then
        -- Chest/Coffer means OPEN-WORLD treasure chests and coffers.
        where_clause = " WHERE k.source_type IN (1, 2) AND COALESCE(k.content_type, '') = ''";
    elseif (source_filter == 2) then
        -- Exclude instance crates, such as Einherjar's Armoury Crate, from BCNM results.
        where_clause = " WHERE (k.source_type = 3 OR (COALESCE(k.content_type, '') = 'BCNM'"
                    .. " AND (COALESCE(k.battlefield, '') <> '' OR COALESCE(k.bf_name, '') <> '')))"
                    .. " AND COALESCE(k.bf_difficulty, 0) = 0" .. BCNM_CONTENT_GUARD;
    elseif (source_filter == 3) then
        where_clause = ' WHERE k.bf_difficulty > 0';
    elseif (db.CONTENT_TYPE_MAP[source_filter] ~= nil) then
        where_clause = " WHERE COALESCE(k.content_type, '') = '" .. db.CONTENT_TYPE_MAP[source_filter] .. "'" .. CONTAINER_ONLY_MOBS_OUT;
    elseif (source_filter == 8) then
        -- All Battlefields requires a BCNM name or an HTBF difficulty; do not group unnamed field mobs
        -- here.
        where_clause = " WHERE ((k.source_type = 3 OR (COALESCE(k.content_type, '') = 'BCNM'"
                    .. " AND (COALESCE(k.battlefield, '') <> '' OR COALESCE(k.bf_name, '') <> '')))"
                    .. " AND COALESCE(k.bf_difficulty, 0) = 0" .. BCNM_CONTENT_GUARD .. ") OR k.bf_difficulty > 0";
    elseif (source_filter == 9) then
        where_clause = " WHERE COALESCE(k.content_type, '') IN " .. db.INSTANCE_IN_SQL .. CONTAINER_ONLY_MOBS_OUT;
    elseif (source_filter == 24) then
        where_clause = " WHERE COALESCE(k.content_type, '') IN " .. db.REIVE_CONTENT_SQL .. CONTAINER_ONLY_MOBS_OUT;
    end

    -- BCNM/HTBF view: group by battlefield name; gil excluded from drop counts
    local query;
    if (source_filter == 2) then
        query = [[
            SELECT COALESCE(NULLIF(k.battlefield, ''), NULLIF(k.bf_name, ''), 'Unknown BCNM') as mob_name,
                   k.zone_name, k.zone_id, k.level_cap,
                   COUNT(DISTINCT CASE WHEN k.source_type IN (2, 3) THEN k.id END) as run_count,
]] .. STATS_AGG_COLS .. [[

            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY COALESCE(NULLIF(k.battlefield, ''), NULLIF(k.bf_name, ''), 'Unknown BCNM'), k.zone_id, k.level_cap
            -- This is a LOOT tracker: Stats/Slot model drop odds, so the population must be things
            -- that CAN drop. Mission BCNMs (Shadow Lord, Rank 2/5, Save the Children, ...) have no
            -- chest and no loot table -- measured: 6 of 12 rows here were pure noise. A run where you
            -- wiped without opening the chest is likewise not a trial. Keep a battlefield only if it
            -- has ever opened a container or ever produced a drop.
            HAVING COUNT(DISTINCT CASE WHEN k.source_type IN (2, 3) THEN k.id END) > 0
                OR COUNT(CASE WHEN d.item_id != 65535 THEN d.id END) > 0
            ORDER BY kill_count DESC
        ]];
    elseif (source_filter == 3) then
        -- HTBF view: group by bf_name + difficulty, include BOTH mob kills and crate drops
        query = [[
            SELECT COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, 'Unknown HTBF')) as mob_name,
                   k.zone_name, k.zone_id, k.bf_difficulty,
]] .. STATS_AGG_COLS .. [[

            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, 'Unknown HTBF')), k.zone_id, k.bf_difficulty
            ORDER BY kill_count DESC
        ]];
    elseif (source_filter == 8) then
        -- All Battlefields: group by battlefield name + level_cap + bf_difficulty
        -- BCNMs have level_cap, HTBFs have bf_difficulty — both shown as separate columns
        query = [[
            SELECT COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, k.mob_name)) as mob_name,
                   k.zone_name, k.zone_id, k.level_cap, k.bf_difficulty,
                   COUNT(DISTINCT CASE WHEN k.source_type IN (2, 3) THEN k.id END) as run_count,
]] .. STATS_AGG_COLS .. [[

            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY COALESCE(NULLIF(k.bf_name, ''), COALESCE(k.battlefield, k.mob_name)), k.zone_id, k.level_cap, k.bf_difficulty
            ORDER BY kill_count DESC
        ]];
    elseif (source_filter == 9 or source_filter == 24) then
        -- Aggregates over several contents: a mob name shared by two contents in one zone (275 hosts
        -- Vagary and Skirmish) must not merge, and the row has to say which content it is.
        query = [[
            SELECT k.mob_name, k.zone_name, k.zone_id, COALESCE(k.content_type, '') as content_type,
]] .. STATS_AGG_COLS .. [[

            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY k.mob_name, k.zone_id, COALESCE(k.content_type, '')
            ORDER BY kill_count DESC
        ]];
    else
        query = [[
            SELECT k.mob_name, k.zone_name, k.zone_id,
]] .. STATS_AGG_COLS .. [[

            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY k.mob_name, k.zone_id
            ORDER BY kill_count DESC
        ]];
    end

    local stmt = db.conn:prepare(query);
    if (stmt == nil) then return results; end
    for row in stmt:nrows() do
        finalise_stats_row(row);
        results:append(row);
    end
    stmt:finalize();

    -- Chest/Coffer mode: add chest_events as additional attempts
    if (source_filter == 1) then
        -- Build lookup: "mob_name|zone_id" → index in results
        local lookup = {};
        for i, row in ipairs(results) do
            lookup[row.mob_name .. '|' .. tostring(row.zone_id)] = i;
        end

        -- Map container_type to mob_name used in kills table
        local ctype_to_name = { [1] = 'Treasure Chest', [2] = 'Treasure Coffer' };

        -- Exclude illusions (result=4) from attempt count
        local ce_stmt = db.conn:prepare([[
            SELECT zone_id, zone_name, container_type,
                   COUNT(*) as event_count,
                   SUM(CASE WHEN result = 0 THEN 1 ELSE 0 END) as gil_count,
                   SUM(CASE WHEN result > 0 AND result != 4 THEN 1 ELSE 0 END) as fail_count,
                   SUM(CASE WHEN result = 0 THEN gil_amount ELSE 0 END) as total_gil,
                   MIN(CASE WHEN result = 0 AND gil_amount > 0 THEN gil_amount ELSE NULL END) as min_gil,
                   MAX(CASE WHEN result = 0 THEN gil_amount ELSE NULL END) as max_gil
            FROM chest_events
            WHERE result != 4
            GROUP BY zone_id, container_type
        ]]);
        if (ce_stmt ~= nil) then
            for row in ce_stmt:nrows() do
                local name = ctype_to_name[row.container_type] or 'Treasure Chest';
                local key = name .. '|' .. tostring(row.zone_id);
                local idx = lookup[key];
                if (idx ~= nil) then
                    -- Add chest events to existing kill row
                    results[idx].kill_count = results[idx].kill_count + row.event_count;
                    results[idx].avg_drops = results[idx].kill_count > 0
                        and (results[idx].drop_count / results[idx].kill_count) or 0;
                    results[idx].gil_count = (results[idx].gil_count or 0) + row.gil_count;
                    results[idx].fail_count = (results[idx].fail_count or 0) + row.fail_count;
                    results[idx].total_gil = (results[idx].total_gil or 0) + row.total_gil;
                    local cur_min = results[idx].min_gil;
                    local cur_max = results[idx].max_gil;
                    if (row.min_gil ~= nil) then
                        results[idx].min_gil = (cur_min == nil) and row.min_gil or math.min(cur_min, row.min_gil);
                    end
                    if (row.max_gil ~= nil) then
                        results[idx].max_gil = (cur_max == nil) and row.max_gil or math.max(cur_max, row.max_gil);
                    end
                else
                    -- No pool items yet — create a row from chest events alone
                    results:append({
                        mob_name = name,
                        zone_name = row.zone_name or '',
                        zone_id = row.zone_id,
                        kill_count = row.event_count,
                        drop_count = 0,
                        unique_items = 0,
                        unique_spawns = 0,
                        avg_drops = 0,
                        gil_count = row.gil_count,
                        fail_count = row.fail_count,
                        total_gil = row.total_gil,
                        min_gil = row.min_gil,
                        max_gil = row.max_gil,
                    });
                end
            end
            ce_stmt:finalize();
        end
    end

    db.all_mob_stats_cache = results;
    db.all_mob_stats_cache_key = cache_key;
    db.all_mob_stats_dirty = false;

    return results;
end

-- Counts (O(1) via running counters)

function db.get_counts()
    if (db.conn == nil) then return 0, 0, 0, 0; end
    return db._kill_count, db._drop_count, db._missed_kill_count, db._chest_event_count;
end

-- Missed Kills (distant party kills with no mob identity)

function db.record_missed_kill(zone_id, zone_name)
    if (db.conn == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare('INSERT INTO missed_kills (zone_id, zone_name, timestamp) VALUES (?, ?, ?)');
    if (stmt == nil) then warn_write_failure('missed kill'); maybe_commit(); return; end
    stmt:bind_values(zone_id, zone_name, os_time());
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then warn_write_failure('missed kill'); maybe_commit(); return; end

    db._missed_kill_count = db._missed_kill_count + 1;
    
    -- Informational only (no mob identity) — no stats invalidation needed

    maybe_commit();
end

-- Zone List (for filter dropdowns)

function db.get_zone_list()
    if (db.conn == nil) then return T{}; end

    if (not db.stats_dirty and db.zone_list_cache ~= nil) then
        return db.zone_list_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare('SELECT DISTINCT zone_id, zone_name FROM kills ORDER BY zone_name ASC');
    if (stmt == nil) then return results; end
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.zone_list_cache = results;
    return results;
end

-- Per-Spawn Stats (by mob_server_id)

function db.get_spawn_stats(mob_name, zone_id)
    if (db.conn == nil) then return T{}; end

    local key = (mob_name or '') .. '_' .. tostring(zone_id or 0);
    if (not db.stats_dirty and db.spawn_stats_cache[key] ~= nil) then
        return db.spawn_stats_cache[key];
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT k.mob_server_id,
               COUNT(DISTINCT k.id) as kill_count,
               COUNT(CASE WHEN d.item_id != 65535 THEN d.id ELSE NULL END) as drop_count,
               COUNT(DISTINCT CASE WHEN d.item_id != 65535 THEN d.item_id ELSE NULL END) as unique_items,
               MAX(k.th_level) as max_th
        FROM kills k
        LEFT JOIN drops d ON d.kill_id = k.id
        WHERE k.mob_name = ? AND k.zone_id = ?
        GROUP BY k.mob_server_id
        ORDER BY kill_count DESC
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(mob_name, zone_id);
    for row in stmt:nrows() do
        finalise_stats_row(row);
        results:append(row);
    end
    stmt:finalize();

    db.spawn_stats_cache[key] = results;
    return results;
end

-- Per-Spawn Item Breakdown

function db.get_spawn_item_stats(mob_name, zone_id, mob_server_id)
    if (db.conn == nil) then return T{}; end

    local key = (mob_name or '') .. '_' .. tostring(zone_id or 0) .. '_' .. tostring(mob_server_id or 0);
    if (not db.stats_dirty and db.spawn_item_cache[key] ~= nil) then
        return db.spawn_item_cache[key];
    end

    -- Kill count for this specific spawn
    local kill_count = 0;
    local stmt_kc = db.conn:prepare('SELECT COUNT(*) as c FROM kills WHERE mob_name = ? AND zone_id = ? AND mob_server_id = ?');
    if (stmt_kc == nil) then return T{}; end
    stmt_kc:bind_values(mob_name, zone_id, mob_server_id);
    for row in stmt_kc:nrows() do kill_count = row.c; end
    stmt_kc:finalize();

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT d.item_id, d.item_name,
               COUNT(*) as times_dropped,
               SUM(d.quantity) as total_qty,
               SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won
        FROM drops d
        JOIN kills k ON d.kill_id = k.id
        WHERE k.mob_name = ? AND k.zone_id = ? AND k.mob_server_id = ?
        GROUP BY d.item_id
        ORDER BY times_dropped DESC
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(mob_name, zone_id, mob_server_id);
    for row in stmt:nrows() do
        if (row.item_id == 65535) then
            row.is_gil_drop = true;
            row.drop_rate = -1;
        else
            row.drop_rate = kill_count > 0 and (row.times_dropped / kill_count) * 100 or 0;
        end
        results:append(row);
    end
    stmt:finalize();

    -- Enhance mob gil entry with min/max/avg amount
    for _, item in ipairs(results) do
        if (item.is_gil_drop and item.times_dropped > 0) then
            local gs = db.conn:prepare([[
                SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil
                FROM drops d JOIN kills k ON d.kill_id = k.id
                WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ? AND k.mob_server_id = ?
            ]]);
            if (gs ~= nil) then
                gs:bind_values(mob_name, zone_id, mob_server_id);
                for gr in gs:nrows() do
                    local avg = math.floor(item.total_qty / item.times_dropped);
                    local mn = gr.min_gil or 0;
                    local mx = gr.max_gil or 0;
                    if (mn == mx) then
                        item.item_name = 'Gil (' .. tostring(avg) .. 'g)';
                    else
                        item.item_name = 'Gil (' .. tostring(mn) .. '-' .. tostring(mx) .. 'g, avg ' .. tostring(avg) .. 'g)';
                    end
                end
                gs:finalize();
            end
            break;
        end
    end

    db.spawn_item_cache[key] = results;
    return results;
end

-- Filtered Export: Shared filter builder

-- The export SELECT column list.
local function export_base_query(join_type)
    return 'SELECT k.id AS kill_id, k.timestamp, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.mob_server_id,'
        .. ' k.zone_name, k.zone_id, k.th_level, k.source_type,'
        .. ' k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,'
        .. ' k.killer_id, k.killer_name, k.th_action_type, k.th_action_id, k.weather,'
        .. " COALESCE(k.bf_name, '') AS bf_name, k.bf_difficulty,"
        .. " COALESCE(k.content_type, '') AS content_type,"
        .. ' COALESCE(k.is_distant, 0) AS is_distant, k.level_cap,'
        .. ' COALESCE(k.th_estimated, 0) AS th_estimated,'
        .. ' d.item_name, d.item_id, d.pool_slot, d.quantity, d.won, d.lot_value,'
        .. ' d.winner_id, d.winner_name, d.player_lot, d.player_action,'
        .. ' d.timestamp AS drop_timestamp'
        .. ' FROM kills k ' .. join_type .. ' JOIN drops d ON d.kill_id = k.id';
end

local function build_export_filters(filters)
    local f = filters or {};
    local conditions = {};
    local params = {};
    local has_drop_filter = false;

    -- Kill filters
    if (f.zone_id ~= nil and f.zone_id >= 0) then
        conditions[#conditions + 1] = 'k.zone_id = ?';
        params[#params + 1] = f.zone_id;
    end

    if (f.content_type ~= nil and f.content_type ~= '') then
        conditions[#conditions + 1] = "COALESCE(k.content_type, '') = ?";
        params[#params + 1] = f.content_type;
    elseif (f.field_only) then
        -- Field = mob kills with no instanced content
        conditions[#conditions + 1] = "k.source_type = 0 AND COALESCE(k.content_type, '') = ''";
    elseif (f.bf_all) then
        -- All BF / BCNM: content_type='BCNM' catches mob kills + crate drops
        conditions[#conditions + 1] = "COALESCE(k.content_type, '') = 'BCNM'";
        if (f.bf_difficulty_eq ~= nil) then
            conditions[#conditions + 1] = 'k.bf_difficulty = ?';
            params[#params + 1] = f.bf_difficulty_eq;
        end
    elseif (f.htbf_only) then
        conditions[#conditions + 1] = "COALESCE(k.content_type, '') = 'BCNM' AND k.bf_difficulty > 0";
    elseif (f.source_type_list ~= nil) then
        local placeholders = {};
        for _, v in ipairs(f.source_type_list) do
            placeholders[#placeholders + 1] = '?';
            params[#params + 1] = v;
        end
        conditions[#conditions + 1] = 'k.source_type IN (' .. table.concat(placeholders, ',') .. ')';
    elseif (f.source_type ~= nil and f.source_type >= 0) then
        conditions[#conditions + 1] = 'k.source_type = ?';
        params[#params + 1] = f.source_type;
    end

    if (f.mob_search ~= nil and f.mob_search ~= '') then
        conditions[#conditions + 1] = 'COALESCE(k.battlefield, k.mob_name) LIKE ?';
        params[#params + 1] = '%' .. f.mob_search .. '%';
    end

    if (f.th_min ~= nil and f.th_min > 0) then
        conditions[#conditions + 1] = 'k.th_level >= ?';
        params[#params + 1] = f.th_min;
    end

    if (f.date_from ~= nil) then
        conditions[#conditions + 1] = 'k.timestamp >= ?';
        params[#params + 1] = f.date_from;
    end

    if (f.date_to ~= nil) then
        conditions[#conditions + 1] = 'k.timestamp <= ?';
        params[#params + 1] = f.date_to;
    end

    -- Vana'diel time filters
    if (f.weekday ~= nil) then
        conditions[#conditions + 1] = 'k.vana_weekday = ?';
        params[#params + 1] = f.weekday;
    end

    if (f.hour_min ~= nil and f.hour_max ~= nil) then
        if (f.hour_min <= f.hour_max) then
            conditions[#conditions + 1] = 'k.vana_hour >= ? AND k.vana_hour <= ?';
            params[#params + 1] = f.hour_min;
            params[#params + 1] = f.hour_max;
        else
            -- Wrap-around (e.g. 20:00 to 04:00)
            conditions[#conditions + 1] = '(k.vana_hour >= ? OR k.vana_hour <= ?)';
            params[#params + 1] = f.hour_min;
            params[#params + 1] = f.hour_max;
        end
    end

    -- Moon phase filter: client returns 0-11 (12 segments), named phases span 1-2 raw values
    if (f.moon_phase ~= nil) then
        if (f.moon_phase_max ~= nil and f.moon_phase_max ~= f.moon_phase) then
            conditions[#conditions + 1] = 'k.moon_phase >= ? AND k.moon_phase <= ?';
            params[#params + 1] = f.moon_phase;
            params[#params + 1] = f.moon_phase_max;
        else
            conditions[#conditions + 1] = 'k.moon_phase = ?';
            params[#params + 1] = f.moon_phase;
        end
    end

    if (f.mob_sid ~= nil) then
        conditions[#conditions + 1] = 'k.mob_server_id = ?';
        params[#params + 1] = f.mob_sid;
    end

    if (f.killer_search ~= nil and f.killer_search ~= '') then
        conditions[#conditions + 1] = 'k.killer_name LIKE ?';
        params[#params + 1] = '%' .. f.killer_search .. '%';
    end

    if (f.weather ~= nil and f.weather >= 0) then
        conditions[#conditions + 1] = 'k.weather = ?';
        params[#params + 1] = f.weather;
    end

    -- Drop filters
    if (f.item_search ~= nil and f.item_search ~= '') then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.item_name LIKE ?';
        params[#params + 1] = '%' .. f.item_search .. '%';
    end

    if (f.status ~= nil) then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.won = ?';
        params[#params + 1] = f.status;
    end

    if (f.item_id ~= nil) then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.item_id = ?';
        params[#params + 1] = f.item_id;
    end

    if (f.winner_search ~= nil and f.winner_search ~= '') then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.winner_name LIKE ?';
        params[#params + 1] = '%' .. f.winner_search .. '%';
    end

    if (f.winner_id ~= nil) then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.winner_id = ?';
        params[#params + 1] = f.winner_id;
    end

    if (f.player_action ~= nil) then
        has_drop_filter = true;
        conditions[#conditions + 1] = 'd.player_action = ?';
        params[#params + 1] = f.player_action;
    end

    -- INNER JOIN when drop filters are active or include_empty is off;
    -- LEFT JOIN only when include_empty is on AND no drop filters active.
    local join_type = 'LEFT';
    if (has_drop_filter or not f.include_empty) then
        join_type = 'INNER';
    end

    return conditions, params, has_drop_filter, join_type;
end

-- Chest Event UNION Builder (for filtered export)

local function build_chest_event_union(filters)
    local f = filters or {};

    -- Include chest events when source is All, Chest/Coffer list, or explicit Chest(1)/Coffer(2)
    -- Exclude for Field/BF/HTBF/content_type filters (no chest events in those contexts)
    local is_all = (f.source_type == nil and f.source_type_list == nil
        and not f.field_only and not f.bf_all and not f.htbf_only
        and (f.content_type == nil or f.content_type == ''));
    local is_chest_source = (f.source_type == 1 or f.source_type == 2);
    local is_chest_list = (f.source_type_list ~= nil);
    if (not is_all and not is_chest_source and not is_chest_list) then
        return nil, {};
    end

    local conditions = {};
    local params = {};

    -- Container type: only restrict when filtering to a specific chest type
    if (is_chest_source) then
        conditions[#conditions + 1] = 'ce.container_type = ?';
        params[#params + 1] = f.source_type;
    end
    -- All and Chest/Coffer list: no container_type restriction (include both)

    -- Zone filter
    if (f.zone_id ~= nil and f.zone_id >= 0) then
        conditions[#conditions + 1] = 'ce.zone_id = ?';
        params[#params + 1] = f.zone_id;
    end

    -- Date range
    if (f.date_from ~= nil) then
        conditions[#conditions + 1] = 'ce.timestamp >= ?';
        params[#params + 1] = f.date_from;
    end
    if (f.date_to ~= nil) then
        conditions[#conditions + 1] = 'ce.timestamp <= ?';
        params[#params + 1] = f.date_to;
    end

    -- Vana'diel time filters
    if (f.weekday ~= nil) then
        conditions[#conditions + 1] = 'ce.vana_weekday = ?';
        params[#params + 1] = f.weekday;
    end
    if (f.hour_min ~= nil and f.hour_max ~= nil) then
        if (f.hour_min <= f.hour_max) then
            conditions[#conditions + 1] = 'ce.vana_hour >= ? AND ce.vana_hour <= ?';
            params[#params + 1] = f.hour_min;
            params[#params + 1] = f.hour_max;
        else
            conditions[#conditions + 1] = '(ce.vana_hour >= ? OR ce.vana_hour <= ?)';
            params[#params + 1] = f.hour_min;
            params[#params + 1] = f.hour_max;
        end
    end
    if (f.moon_phase ~= nil) then
        if (f.moon_phase_max ~= nil and f.moon_phase_max ~= f.moon_phase) then
            conditions[#conditions + 1] = 'ce.moon_phase >= ? AND ce.moon_phase <= ?';
            params[#params + 1] = f.moon_phase;
            params[#params + 1] = f.moon_phase_max;
        else
            conditions[#conditions + 1] = 'ce.moon_phase = ?';
            params[#params + 1] = f.moon_phase;
        end
    end
    if (f.weather ~= nil and f.weather >= 0) then
        conditions[#conditions + 1] = 'ce.weather = ?';
        params[#params + 1] = f.weather;
    end

    -- Chest result filter
    if (f.chest_result ~= nil) then
        conditions[#conditions + 1] = 'ce.result = ?';
        params[#params + 1] = f.chest_result;
    end

    -- Item search: filter chest events by their computed item_name
    if (f.item_search ~= nil and f.item_search ~= '') then
        conditions[#conditions + 1] = "(CASE ce.result"
            .. " WHEN 0 THEN 'Gil'"
            .. " WHEN 1 THEN 'Lockpick Failed'"
            .. " WHEN 2 THEN 'Trapped!'"
            .. " WHEN 3 THEN 'Mimic!'"
            .. " WHEN 4 THEN 'Illusion'"
            .. " END) LIKE ?";
        params[#params + 1] = '%' .. f.item_search .. '%';
    end

    -- Status filter: map won values to chest result types
    -- won=1 means success (result=0 gil), won=-1 means failure (result>0)
    if (f.status ~= nil) then
        if (f.status == 1) then
            -- Obtained = successful opens (gil)
            conditions[#conditions + 1] = 'ce.result = 0';
        elseif (f.status == -1) then
            -- Lost = failures
            conditions[#conditions + 1] = 'ce.result > 0';
        else
            -- Other statuses (Pending, Inv Full, Zoned) don't apply to chests — exclude all
            conditions[#conditions + 1] = '0 = 1';
        end
    end

    -- Build SELECT mapped to kills+drops column structure
    local query = 'SELECT -ce.id AS kill_id, ce.timestamp,'
        .. " CASE WHEN ce.container_type = 1 THEN 'Treasure Chest' ELSE 'Treasure Coffer' END AS mob_name,"
        .. ' 0 AS mob_server_id, ce.zone_name, ce.zone_id,'
        .. ' 0 AS th_level, ce.container_type AS source_type,'
        .. ' ce.vana_weekday, ce.vana_hour, ce.moon_phase, ce.moon_percent,'
        .. " 0 AS killer_id, '' AS killer_name, 0 AS th_action_type, 0 AS th_action_id, ce.weather,"
        .. " '' AS bf_name, 0 AS bf_difficulty, '' AS content_type,"
        .. ' 0 AS is_distant, NULL AS level_cap, 0 AS th_estimated,'
        .. " CASE ce.result"
        .. " WHEN 0 THEN 'Gil'"
        .. " WHEN 1 THEN 'Lockpick Failed'"
        .. " WHEN 2 THEN 'Trapped!'"
        .. " WHEN 3 THEN 'Mimic!'"
        .. " WHEN 4 THEN 'Illusion'"
        .. " END AS item_name,"
        .. ' CASE WHEN ce.result = 0 THEN 65535 ELSE 0 END AS item_id, 0 AS pool_slot,'
        .. ' CASE WHEN ce.result = 0 THEN ce.gil_amount ELSE 0 END AS quantity,'
        .. ' CASE WHEN ce.result = 0 THEN 1 ELSE -1 END AS won,'
        .. " 0 AS lot_value, 0 AS winner_id, '' AS winner_name,"
        .. ' 0 AS player_lot, 0 AS player_action,'
        .. ' NULL AS drop_timestamp'
        .. ' FROM chest_events ce';

    if (#conditions > 0) then
        query = query .. ' WHERE ' .. table.concat(conditions, ' AND ');
    end

    return query, params;
end

-- Filtered Export Query (for Export tab)

function db.get_filtered_export(filters, limit)
    if (db.conn == nil) then return T{}, 0; end

    local conditions, params, _, join_type = build_export_filters(filters);

    local query = export_base_query(join_type);

    if (#conditions > 0) then
        query = query .. ' WHERE ' .. table.concat(conditions, ' AND ');
    end

    -- UNION ALL with chest_events when source is Chest or Coffer
    local ce_query, ce_params = build_chest_event_union(filters);
    if (ce_query ~= nil) then
        query = query .. ' UNION ALL ' .. ce_query;
        for _, p in ipairs(ce_params) do
            params[#params + 1] = p;
        end
    end

    query = query .. ' ORDER BY 2 DESC';  -- column 2 = k.timestamp (unambiguous positional ref)

    if (limit ~= nil) then
        query = query .. ' LIMIT ' .. tostring(limit);
    end

    local results = T{};
    local stmt = db.conn:prepare(query);
    if (stmt == nil) then return results, 0; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    return results, #results;
end

-- Filtered Export Count

function db.get_filtered_export_count(filters)
    if (db.conn == nil) then return 0; end

    local conditions, params, _, join_type = build_export_filters(filters);

    local query = 'SELECT COUNT(*) as c'
        .. ' FROM kills k ' .. join_type .. ' JOIN drops d ON d.kill_id = k.id';

    if (#conditions > 0) then
        query = query .. ' WHERE ' .. table.concat(conditions, ' AND ');
    end

    -- Include chest_events in count when source is Chest or Coffer.
    -- Reuse build_chest_event_union() to avoid duplicating filter logic.
    local ce_query, ce_params = build_chest_event_union(filters);
    if (ce_query ~= nil) then
        query = 'SELECT (SELECT COUNT(*) FROM kills k ' .. join_type
            .. ' JOIN drops d ON d.kill_id = k.id';
        if (#conditions > 0) then
            query = query .. ' WHERE ' .. table.concat(conditions, ' AND ');
        end
        query = query .. ') + (SELECT COUNT(*) FROM (' .. ce_query .. ')) AS c';

        -- Merge chest event params after kill params
        for _, p in ipairs(ce_params) do
            params[#params + 1] = p;
        end
    end

    local count = 0;
    local stmt = db.conn:prepare(query);
    if (stmt == nil) then return 0; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end
    for row in stmt:nrows() do
        count = row.c;
    end
    stmt:finalize();

    return count;
end

-- Battlefield Sessions (BCNM tracking)

function db.record_battlefield_entry(name, zone_id, zone_name, timestamp)
    if (db.conn == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare([[
        INSERT INTO battlefield_sessions (battlefield_name, zone_id, zone_name, entered_at)
        VALUES (?, ?, ?, ?)
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(name, zone_id, zone_name or '', timestamp);
    stmt:step();
    stmt:finalize();

    maybe_commit();
end

function db.update_battlefield_level_cap(level_cap)
    if (db.conn == nil or level_cap == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare([[
        UPDATE battlefield_sessions SET level_cap = ?
        WHERE id = (SELECT id FROM battlefield_sessions WHERE exited_at IS NULL ORDER BY id DESC LIMIT 1)
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(level_cap);
    stmt:step();
    stmt:finalize();

    maybe_commit();
end

function db.end_battlefield_session(timestamp)
    if (db.conn == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare([[
        UPDATE battlefield_sessions SET exited_at = ?
        WHERE exited_at IS NULL
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(timestamp);
    stmt:step();
    stmt:finalize();

    maybe_commit();
end

function db.get_active_battlefield(zone_id)
    if (db.conn == nil) then return nil; end

    -- Only match sessions from the last 4 hours (no BCNM lasts longer)
    local cutoff = os_time() - (4 * 60 * 60);
    local result = nil;
    local stmt = db.conn:prepare([[
        SELECT battlefield_name, zone_id, zone_name, level_cap, entered_at
        FROM battlefield_sessions
        WHERE exited_at IS NULL AND zone_id = ? AND entered_at >= ?
        ORDER BY id DESC LIMIT 1
    ]]);
    if (stmt == nil) then return nil; end
    stmt:bind_values(zone_id, cutoff);
    for row in stmt:nrows() do
        result = row;
    end
    stmt:finalize();

    return result;
end

-- Chest Event Recording

function db.record_chest_event(zone_id, zone_name, container_type, result, gil_amount, vana_info)
    if (db.conn == nil) then return nil; end

    begin_batch();

    local now = os_time();
    local vi = vana_info or {};
    local stmt = db.conn:prepare([[
        INSERT INTO chest_events (zone_id, zone_name, container_type, result, gil_amount,
                                  vana_weekday, vana_hour, moon_phase, moon_percent, weather,
                                  timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]);
    if (stmt == nil) then warn_write_failure('chest'); maybe_commit(); return nil; end
    stmt:bind_values(
        zone_id, zone_name, container_type, result, gil_amount or 0,
        vi.weekday or -1, vi.hour or -1,
        vi.moon_phase or -1, vi.moon_percent or -1,
        vi.weather or -1,
        now
    );
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then warn_write_failure('chest'); maybe_commit(); return nil; end
    local rowid = db.conn:last_insert_rowid();

    db._chest_event_count = db._chest_event_count + 1;
    db.chest_events_cache_dirty = true;
    db.chest_stats_dirty = true;
    db.chest_events_cache = nil;
    db.chest_stats_cache = nil;
    -- Also invalidate feed + stats (chest events appear in both)
    db.recent_feed_dirty = true;
    db.recent_feed_cache = nil;
    db.stats_dirty = true;
    db.all_mob_stats_dirty = true;
    db.content_counts_dirty = true;
    db.mob_stats_dirty = true;
    db.mob_stats_cache = {};

    maybe_commit();

    return rowid;
end

-- Chest Event Queries (cached)

function db.get_recent_chest_events(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.chest_events_cache_dirty and db.chest_events_cache ~= nil and db.chest_events_limit == limit) then
        return db.chest_events_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT id, zone_id, zone_name, container_type, result, gil_amount,
               vana_weekday, vana_hour, moon_phase, moon_percent, weather, timestamp
        FROM chest_events ORDER BY id DESC LIMIT ?
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(limit);
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.chest_events_cache = results;
    db.chest_events_limit = limit;
    db.chest_events_cache_dirty = false;
    return results;
end

-- Kill-row counts per content for the Instances combo: contents with data, with their counts.
-- Container-only contents count their coffer rows (the mobs are hidden from the lists too).
function db.get_content_counts()
    if (db.conn == nil) then return {}; end
    if (db.content_counts_cache ~= nil and not db.stats_dirty and not db.content_counts_dirty) then
        return db.content_counts_cache;
    end
    local counts = {};
    local stmt = db.conn:prepare("SELECT COALESCE(k.content_type, '') as ct, COUNT(*) as c FROM kills k WHERE COALESCE(k.content_type, '') <> ''"
        .. CONTAINER_ONLY_MOBS_OUT .. " GROUP BY COALESCE(k.content_type, '')");
    if (stmt == nil) then return counts; end
    for row in stmt:nrows() do counts[row.ct] = row.c; end
    stmt:finalize();
    db.content_counts_cache = counts;
    db.content_counts_dirty = false;
    return counts;
end

function db.get_chest_stats()
    if (db.conn == nil) then return T{}; end

    if (db.chest_stats_cache ~= nil and not db.chest_stats_dirty) then
        return db.chest_stats_cache;
    end

    local results = T{};
    -- Illusions (result=4) excluded from totals but queried separately for display
    local stmt = db.conn:prepare([[
        SELECT zone_id, zone_name, container_type,
               SUM(CASE WHEN result != 4 THEN 1 ELSE 0 END) as total_events,
               SUM(CASE WHEN result = 0 THEN 1 ELSE 0 END) as gil_count,
               SUM(CASE WHEN result > 0 AND result != 4 THEN 1 ELSE 0 END) as fail_count,
               SUM(CASE WHEN result = 1 THEN 1 ELSE 0 END) as fail_lockpick,
               SUM(CASE WHEN result = 2 THEN 1 ELSE 0 END) as fail_trap,
               SUM(CASE WHEN result = 3 THEN 1 ELSE 0 END) as fail_mimic,
               SUM(CASE WHEN result = 4 THEN 1 ELSE 0 END) as fail_illusion,
               SUM(CASE WHEN result = 0 THEN gil_amount ELSE 0 END) as total_gil,
               CASE WHEN SUM(CASE WHEN result = 0 THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN result = 0 THEN gil_amount ELSE 0 END) * 1.0
                         / SUM(CASE WHEN result = 0 THEN 1 ELSE 0 END)
                    ELSE 0 END as avg_gil
        FROM chest_events
        GROUP BY zone_id, container_type
        ORDER BY total_events DESC
    ]]);
    if (stmt == nil) then return results; end
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.chest_stats_cache = results;
    db.chest_stats_dirty = false;
    return results;
end

-- Clear Data

function db.clear_data()
    if (db.conn == nil) then return; end

    -- Commit any open transaction before clearing
    if (db._in_transaction) then
        pcall(db.conn.exec, db.conn, 'COMMIT');
        db._in_transaction = false;
    end

    local ok, err = pcall(function()
        db.conn:exec('BEGIN;');
        db.conn:exec('DELETE FROM drops;');
        db.conn:exec('DELETE FROM kills;');
        db.conn:exec('DELETE FROM missed_kills;');
        db.conn:exec('DELETE FROM battlefield_sessions;');
        db.conn:exec('DELETE FROM chest_events;');
        db.conn:exec('COMMIT;');
    end);
    if (not ok) then
        pcall(db.conn.exec, db.conn, 'ROLLBACK');
        error('clear_data failed: ' .. tostring(err));
    end
    pcall(db.conn.exec, db.conn, 'VACUUM;');

    db._kill_count = 0;
    db._drop_count = 0;
    db._missed_kill_count = 0;
    db._chest_event_count = 0;

    invalidate_all();
end

-- Export: Streaming (constant memory instead of loading entire DB)

function db.stream_export_all(write_row)
    if (db.conn == nil) then return; end

    local current_kill = nil;
    local current_drops = {};

    local stmt = db.conn:prepare([[
        SELECT k.id AS kid, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.mob_server_id, k.zone_name, k.zone_id,
               k.th_level, k.source_type, k.vana_weekday, k.vana_hour,
               k.moon_phase, k.moon_percent, k.timestamp AS k_timestamp,
               k.killer_id, k.killer_name, k.th_action_type, k.th_action_id, k.weather,
               COALESCE(k.bf_name, '') AS bf_name, k.bf_difficulty,
               COALESCE(k.content_type, '') AS content_type,
               COALESCE(k.is_distant, 0) AS is_distant, k.level_cap,
               COALESCE(k.th_estimated, 0) AS th_estimated,
               d.item_name, d.item_id, d.pool_slot, d.quantity,
               d.won, d.lot_value, d.timestamp AS d_timestamp,
               d.winner_id, d.winner_name, d.player_lot, d.player_action
        FROM kills k
        LEFT JOIN drops d ON d.kill_id = k.id
        ORDER BY k.id ASC, d.pool_slot ASC
    ]]);
    if (stmt == nil) then return; end

    for row in stmt:nrows() do
        local kid = row.kid;

        -- New kill encountered — flush previous
        if (current_kill ~= nil and kid ~= current_kill.id) then
            write_row(current_kill, current_drops);
            current_drops = {};
        end

        -- Start new kill record
        if (current_kill == nil or kid ~= current_kill.id) then
            current_kill = {
                id              = kid,
                mob_name        = row.mob_name,
                mob_server_id   = row.mob_server_id,
                zone_name       = row.zone_name,
                zone_id         = row.zone_id,
                th_level        = row.th_level,
                source_type     = row.source_type,
                vana_weekday    = row.vana_weekday,
                vana_hour       = row.vana_hour,
                moon_phase      = row.moon_phase,
                moon_percent    = row.moon_percent,
                timestamp       = row.k_timestamp,
                killer_id       = row.killer_id,
                killer_name     = row.killer_name,
                th_action_type  = row.th_action_type,
                th_action_id    = row.th_action_id,
                weather         = row.weather,
                bf_name         = row.bf_name,
                bf_difficulty   = row.bf_difficulty,
                content_type    = row.content_type,
                is_distant      = row.is_distant,
                level_cap       = row.level_cap,
                th_estimated    = row.th_estimated,
            };
        end

        -- Append drop if present (LEFT JOIN produces NULL item_name for no-drop kills)
        if (row.item_name ~= nil) then
            current_drops[#current_drops + 1] = {
                item_name     = row.item_name,
                item_id       = row.item_id,
                pool_slot     = row.pool_slot,
                quantity      = row.quantity,
                won           = row.won,
                lot_value     = row.lot_value,
                timestamp     = row.d_timestamp,
                winner_id     = row.winner_id,
                winner_name   = row.winner_name,
                player_lot    = row.player_lot,
                player_action = row.player_action,
            };
        end
    end

    stmt:finalize();

    -- Flush final kill
    if (current_kill ~= nil) then
        write_row(current_kill, current_drops);
    end
end

function db.stream_filtered_export(filters, write_row)
    if (db.conn == nil) then return; end

    local conditions, params, _, join_type = build_export_filters(filters);

    local query = export_base_query(join_type);

    if (#conditions > 0) then
        query = query .. ' WHERE ' .. table.concat(conditions, ' AND ');
    end

    -- UNION ALL with chest_events when source is Chest or Coffer
    local ce_query, ce_params = build_chest_event_union(filters);
    if (ce_query ~= nil) then
        query = query .. ' UNION ALL ' .. ce_query;
        for _, p in ipairs(ce_params) do
            params[#params + 1] = p;
        end
    end

    query = query .. ' ORDER BY 2 DESC';  -- column 2 = k.timestamp (unambiguous positional ref)

    local stmt = db.conn:prepare(query);
    if (stmt == nil) then return; end
    if (#params > 0) then
        stmt:bind_values(unpack(params));
    end
    for row in stmt:nrows() do
        write_row(row);
    end
    stmt:finalize();
end

-- TH Items Database (shared, addon-local)

db.th_conn = nil;       -- separate connection for th_items.db
db.th_path = nil;
db._th_init_failed = false;

-- Equipment slot names for display
db.SLOT_NAMES = {
    [0] = 'Main', [1] = 'Sub', [2] = 'Range', [3] = 'Ammo',
    [4] = 'Head', [5] = 'Body', [6] = 'Hands', [7] = 'Legs',
    [8] = 'Feet', [9] = 'Neck', [10] = 'Waist',
    [11] = 'Ear1', [12] = 'Ear2', [13] = 'Ring1', [14] = 'Ring2',
    [15] = 'Back',
};

-- Retail TH gear seed data: { item_id, item_name, th_value, slot_id, notes }
-- Source: https://www.bg-wiki.com/ffxi/Treasure_Hunter
-- Items with th_value=0 are augmentable, TH comes from augment, not intrinsic.
-- Auto-detection reads augments from equipped gear at scan time.
local RETAIL_TH_ITEMS = {
    -- Daggers (Main hand, slot 0)
    { 16480, 'Thief\'s Knife',         1,  0, '' },           -- THF
    { 20618, 'Sandung',                1,  0, '' },           -- THF JSE
    { 21573, 'Assassin\'s Knife',      1,  0, '' },           -- THF
    { 21574, 'Plun. Knife',            2,  0, '' },           -- THF
    { 21575, 'Gandring',               3,  0, '' },           -- THF
    -- Ammo (slot 3)
    { 22299, 'Per. Lucky Egg',         1,  3, '' },           -- All Jobs
    -- Head (slot 4)
    { 23713, 'Volte Cap',              1,  4, '' },           -- All Jobs
    { 25679, 'Wh. Rarab Cap +1',       1,  4, '' },           -- All Jobs
    -- Body (slot 5)
    { 23717, 'Volte Jupon',            2,  5, '' },           -- All Jobs
    -- Hands (slot 6)
    { 15107, 'Asn. Armlets',           1,  6, '' },           -- THF
    { 14914, 'Asn. Armlets +1',        1,  6, '' },           -- THF
    { 10695, 'Asn. Armlets +2',        2,  6, '' },           -- THF
    { 26986, 'Plun. Armlets',          2,  6, '' },           -- THF
    { 26987, 'Plun. Armlets +1',       3,  6, '' },           -- THF
    { 23202, 'Plun. Armlets +2',       3,  6, '' },           -- THF
    { 23537, 'Plun. Armlets +3',       4,  6, '' },           -- THF
    { 23721, 'Volte Bracers',          1,  6, '' },           -- All Jobs
    -- Legs (slot 7)
    { 23725, 'Volte Hose',             1,  7, '' },           -- All Jobs
    -- Feet (slot 8)
    { 11149, 'Raid. Poulaines +2',     1,  8, '' },           -- THF
    { 27421, 'Skulk. Poulaines',       2,  8, '' },           -- THF
    { 27422, 'Skulk. Poulaines +1',    3,  8, '' },           -- THF
    { 23358, 'Skulk. Poulaines +2',    4,  8, '' },           -- THF
    { 23693, 'Skulk. Poulaines +3',    5,  8, '' },           -- THF
    { 23729, 'Volte Boots',            1,  8, '' },           -- All Jobs
    -- Waist (slot 10)
    { 28450, 'Chaac Belt',             1, 10, '' },           -- All Jobs
    -- Ring (slot 13)
    { 27585, 'Gorney Ring',            1, 13, '' },           -- All Jobs
    { 26197, 'Gorney Ring +1',         1, 13, '' },           -- All Jobs
    { 26236, 'Hoxne Ring',             2, 13, '' },           -- All Jobs
    -- Augmentable gear (th_value=0, TH from augment auto-detected at scan time)
    -- Set TH value manually if auto-detection doesn't work on your server.
    -- Herculean (Oseem augments via Dark Matter / Stones)
    { 25642, 'Herculean Helm',         0,  4, 'Augmentable (Oseem)' },
    { 25718, 'Herculean Vest',         0,  5, 'Augmentable (Oseem)' },
    { 27140, 'Herculean Gloves',       0,  6, 'Augmentable (Oseem)' },
    { 25842, 'Herculean Trousers',     0,  7, 'Augmentable (Oseem)' },
    { 27496, 'Herculean Boots',        0,  8, 'Augmentable (Oseem)' },
    -- Other augmentable
    { 20596, 'Taming Sari',            0,  0, 'Augmentable (Sinister Reign)' },  -- THF/BRD/DNC
    { 13212, 'Tarutaru Sash',          0, 10, 'Augmentable (Abyssea)' },
};

-- Retail TH job trait seed data: { job_id, is_main, min_level, th_value }
-- Source: https://www.bg-wiki.com/ffxi/Treasure_Hunter
-- THF (6): innate job trait at 15/45/90
-- BLU (16): spell-set trait (Charged Whisker + Evryone. Grudge + Amorphic Spikes)
--           requires Lv98+ to learn Amorphic Spikes, main only (sub can't set enough)
local RETAIL_TH_TRAITS = {
    { 6, 1, 15, 1 },   -- THF main Lv15: TH+1
    { 6, 1, 45, 2 },   -- THF main Lv45: TH+2
    { 6, 1, 90, 3 },   -- THF main Lv90: TH+3
    { 6, 0, 15, 1 },   -- THF sub Lv15: TH+1
    { 6, 0, 45, 2 },   -- THF sub Lv45: TH+2
    { 16, 1, 98, 1 },  -- BLU main Lv98: TH+1 (spell-set trait)
};

function db.init_th_items(addon_path)
    if (db.th_conn ~= nil) then return true; end
    if (db._th_init_failed) then return false; end

    -- Keep shipped th_items.default.db read-only and overrides in config/th_items.db.
    -- User profiles shadow shipped names; editing copies the profile first, and reset deletes that copy.
    local th_dir = addon_path .. '\\data';
    ashita.fs.create_directory(th_dir);
    db.th_default_path = th_dir .. '\\th_items.default.db';

    local user_dir = AshitaCore:GetInstallPath() .. '\\config\\addons\\lootscope';
    ashita.fs.create_directory(user_dir);
    db.th_path = user_dir .. '\\th_items.db';

    -- Migration A:
    local legacy_root = addon_path .. '\\th_items.db';
    local legacy_data = th_dir .. '\\th_items.db';
    local function exists(p) local f = io.open(p, 'rb'); if (f ~= nil) then f:close(); return true; end return false; end

    if (exists(legacy_root) and not exists(legacy_data)) then
        os.rename(legacy_root, legacy_data);
        os.rename(legacy_root .. '-shm', legacy_data .. '-shm');
        os.rename(legacy_root .. '-wal', legacy_data .. '-wal');
    elseif (exists(legacy_root)) then
        os.remove(legacy_root); os.remove(legacy_root .. '-shm'); os.remove(legacy_root .. '-wal');
    end

    -- Migration B
    if (exists(legacy_data) and not exists(db.th_path)) then
        os.rename(legacy_data, db.th_path);
        os.rename(legacy_data .. '-shm', db.th_path .. '-shm');
        os.rename(legacy_data .. '-wal', db.th_path .. '-wal');
    end

    local open_ok, open_err = pcall(function()
        db.th_conn = sqlite3.open(db.th_path);
    end);
    if (not open_ok or db.th_conn == nil) then
        db._th_init_failed = true;
        db._th_init_error = 'TH database failed to open: ' .. tostring(open_err);
        return false;
    end

    local schema_ok, schema_err = pcall(function()
        db.th_conn:exec('PRAGMA journal_mode=WAL;');
        db.th_conn:exec('PRAGMA synchronous=NORMAL;');
        db.th_conn:exec('PRAGMA foreign_keys=ON;');
        db.th_conn:exec('PRAGMA busy_timeout=3000;');

        -- Attach the shipped catalog read-only as `shipped`. Missing/unreadable is NOT fatal:
        -- db.th_has_shipped gates every union so the addon degrades to user-only rather than
        -- failing to start.
        db.th_has_shipped = false;
        local dpath = db.th_default_path;
        if (dpath ~= nil) then
            local f = io.open(dpath, 'rb');
            if (f ~= nil) then
                f:close();
                local att_ok = pcall(function()
                    db.th_conn:exec("ATTACH DATABASE '" .. dpath:gsub("'", "''") .. "' AS shipped;");
                end);
                if (att_ok) then
                    -- confirm it really has the tables before trusting it
                    local probe_ok = pcall(function()
                        for _ in db.th_conn:nrows('SELECT 1 FROM shipped.th_profiles LIMIT 1') do end
                    end);
                    db.th_has_shipped = probe_ok;
                end
            end
        end

        db.th_conn:exec([[
            CREATE TABLE IF NOT EXISTS th_profiles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS th_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id INTEGER NOT NULL,
                item_id INTEGER NOT NULL,
                item_name TEXT NOT NULL,
                th_value INTEGER NOT NULL DEFAULT 1,
                slot_id INTEGER NOT NULL DEFAULT -1,
                notes TEXT DEFAULT '',
                FOREIGN KEY (profile_id) REFERENCES th_profiles(id) ON DELETE CASCADE,
                UNIQUE(profile_id, item_id)
            );

            CREATE TABLE IF NOT EXISTS th_job_traits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id INTEGER NOT NULL,
                job_id INTEGER NOT NULL DEFAULT 6,
                is_main INTEGER NOT NULL DEFAULT 1,
                min_level INTEGER NOT NULL,
                th_value INTEGER NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                FOREIGN KEY (profile_id) REFERENCES th_profiles(id) ON DELETE CASCADE,
                UNIQUE(profile_id, job_id, is_main, min_level)
            );
        ]]);

        -- Migration: add enabled column to th_job_traits if missing (pre-existing DBs)
        local has_enabled = false;
        for row in db.th_conn:nrows("PRAGMA table_info(th_job_traits)") do
            if (row.name == 'enabled') then has_enabled = true; break; end
        end
        if (not has_enabled) then
            db.th_conn:exec('ALTER TABLE th_job_traits ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;');
        end

        -- Seed Retail profile if no profiles exist
        local count = 0;
        for row in db.th_conn:nrows('SELECT COUNT(*) as c FROM th_profiles') do
            count = row.c;
        end
        if (count == 0) then
            db.th_conn:exec('BEGIN TRANSACTION');
            db.th_conn:exec("INSERT INTO th_profiles (name, created_at) VALUES ('Retail', " .. tostring(os_time()) .. ");");
            local profile_id = db.th_conn:last_insert_rowid();

            local item_stmt = db.th_conn:prepare(
                'INSERT INTO th_items (profile_id, item_id, item_name, th_value, slot_id, notes) VALUES (?, ?, ?, ?, ?, ?)'
            );
            for _, item in ipairs(RETAIL_TH_ITEMS) do
                item_stmt:bind_values(profile_id, item[1], item[2], item[3], item[4], item[5] or '');
                item_stmt:step();
                item_stmt:reset();
            end
            item_stmt:finalize();

            local trait_stmt = db.th_conn:prepare(
                'INSERT INTO th_job_traits (profile_id, job_id, is_main, min_level, th_value) VALUES (?, ?, ?, ?, ?)'
            );
            for _, trait in ipairs(RETAIL_TH_TRAITS) do
                trait_stmt:bind_values(profile_id, trait[1], trait[2], trait[3], trait[4]);
                trait_stmt:step();
                trait_stmt:reset();
            end
            trait_stmt:finalize();
            db.th_conn:exec('COMMIT');
        end
    end);

    if (not schema_ok) then
        db._th_init_failed = true;
        db._th_init_error = 'TH database schema failed: ' .. tostring(schema_err);
        pcall(function() db.th_conn:close(); end);
        db.th_conn = nil;
        return false;
    end

    return true;
end

-- TH catalog: shipped (read-only) + user (writable)
db.TH_SHIPPED_BASE = 1000000;

local function th_route(profile_id)
    local id = tonumber(profile_id) or 0;
    if (id >= db.TH_SHIPPED_BASE) then return 'shipped', id - db.TH_SHIPPED_BASE; end
    return 'main', id;
end

--- Copy a shipped profile into the user store so it can be edited (copy-on-write).
function db.materialize_th_profile(profile_id)
    local schema, real = th_route(profile_id);
    if (schema == 'main') then return real; end
    if (not db.th_has_shipped) then return nil; end

    local name = nil;
    local s = db.th_conn:prepare('SELECT name FROM shipped.th_profiles WHERE id = ?');
    if (s == nil) then return nil; end
    s:bind_values(real);
    for row in s:nrows() do name = row.name; end
    s:finalize();
    if (name == nil) then return nil; end

    -- Already materialised under this name? use it.
    local existing = nil;
    local e = db.th_conn:prepare('SELECT id FROM main.th_profiles WHERE name = ?');
    if (e ~= nil) then
        e:bind_values(name);
        for row in e:nrows() do existing = row.id; end
        e:finalize();
    end
    if (existing ~= nil) then return existing; end

    local ok = pcall(function()
        db.th_conn:exec('BEGIN');
        local ins = db.th_conn:prepare('INSERT INTO main.th_profiles (name, created_at) VALUES (?, ?)');
        ins:bind_values(name, os_time()); ins:step(); ins:finalize();
        local nid = db.th_conn:last_insert_rowid();
        db.th_conn:exec(([[
            INSERT INTO main.th_items (profile_id, item_id, item_name, th_value, slot_id, notes)
            SELECT %d, item_id, item_name, th_value, slot_id, notes FROM shipped.th_items WHERE profile_id = %d;
        ]]):format(nid, real));
        db.th_conn:exec(([[
            INSERT INTO main.th_job_traits (profile_id, job_id, is_main, min_level, th_value, enabled)
            SELECT %d, job_id, is_main, min_level, th_value, enabled FROM shipped.th_job_traits WHERE profile_id = %d;
        ]]):format(nid, real));
        db.th_conn:exec('COMMIT');
        existing = nid;
    end);
    if (not ok) then pcall(function() db.th_conn:exec('ROLLBACK'); end); return nil; end
    return existing;
end

--- Discard the user's copy of a profile, revealing the shipped one again.
--- Returns false for a profile that only exists in the user store (nothing to fall back to).
function db.reset_th_profile(profile_id)
    local schema, real = th_route(profile_id);
    if (schema ~= 'main' or db.th_conn == nil) then return false; end
    if (not db.th_has_shipped) then return false; end

    local name = nil;
    local s = db.th_conn:prepare('SELECT name FROM main.th_profiles WHERE id = ?');
    if (s == nil) then return false; end
    s:bind_values(real);
    for row in s:nrows() do name = row.name; end
    s:finalize();
    if (name == nil) then return false; end

    local shipped_exists = false;
    local c = db.th_conn:prepare('SELECT 1 AS x FROM shipped.th_profiles WHERE name = ?');
    if (c ~= nil) then
        c:bind_values(name);
        for _ in c:nrows() do shipped_exists = true; end
        c:finalize();
    end
    if (not shipped_exists) then return false; end   -- user-only profile: deleting would lose it

    local ok = pcall(function()
        db.th_conn:exec('BEGIN');
        for _, sql in ipairs({
            'DELETE FROM main.th_items WHERE profile_id = %d;',
            'DELETE FROM main.th_job_traits WHERE profile_id = %d;',
            'DELETE FROM main.th_profiles WHERE id = %d;',
        }) do db.th_conn:exec(sql:format(real)); end
        db.th_conn:exec('COMMIT');
    end);
    if (not ok) then pcall(function() db.th_conn:exec('ROLLBACK'); end); return false; end
    return true;
end

function db.get_th_profiles()
    if (db.th_conn == nil) then return {}; end
    local results = {};
    -- User profiles first; then shipped ones NOT shadowed by a user profile of the same name.
    local uq = db.th_has_shipped
        and [[SELECT id, name, created_at, 'user' AS origin,
                     (SELECT COUNT(*) FROM shipped.th_profiles sp WHERE sp.name = p.name) AS has_default
                FROM main.th_profiles p ORDER BY id ASC]]
        or  "SELECT id, name, created_at, 'user' AS origin, 0 AS has_default FROM main.th_profiles ORDER BY id ASC";
    for row in db.th_conn:nrows(uq) do
        results[#results + 1] = row;
    end
    if (db.th_has_shipped) then
        local q = ([[SELECT id + %d AS id, name, created_at, 'shipped' AS origin, 0 AS has_default
                     FROM shipped.th_profiles
                     WHERE name NOT IN (SELECT name FROM main.th_profiles)
                     ORDER BY id ASC]]):format(db.TH_SHIPPED_BASE);
        local ok = pcall(function()
            for row in db.th_conn:nrows(q) do results[#results + 1] = row; end
        end);
        if (not ok) then db.th_has_shipped = false; end
    end
    return results;
end

function db.get_th_profile_by_name(name)
    if (db.th_conn == nil or name == nil) then return nil; end
    local result = nil;
    local stmt = db.th_conn:prepare("SELECT id, name, created_at, 'user' AS origin FROM main.th_profiles WHERE name = ?");
    if (stmt ~= nil) then
        stmt:bind_values(name);
        for row in stmt:nrows() do result = row; end
        stmt:finalize();
    end
    if (result ~= nil) then return result; end          -- user copy shadows shipped
    if (not db.th_has_shipped) then return nil; end
    local q = db.th_conn:prepare(("SELECT id + %d AS id, name, created_at, 'shipped' AS origin FROM shipped.th_profiles WHERE name = ?"):format(db.TH_SHIPPED_BASE));
    if (q == nil) then return nil; end
    q:bind_values(name);
    for row in q:nrows() do result = row; end
    q:finalize();
    return result;
end

function db.create_th_profile(name)
    if (db.th_conn == nil or name == nil or name == '') then return nil; end
    local stmt = db.th_conn:prepare('INSERT INTO th_profiles (name, created_at) VALUES (?, ?)');
    if (stmt == nil) then return nil; end
    stmt:bind_values(name, os_time());
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then return nil; end
    return db.th_conn:last_insert_rowid();
end

function db.clone_th_profile(source_id, new_name)
    if (db.th_conn == nil) then return nil; end

    -- The source may be a SHIPPED profile, whose id is offset by TH_SHIPPED_BASE and whose rows
    -- live in the attached read-only catalog.
    local src_schema, src_real = th_route(source_id);
    if (src_schema == 'shipped' and not db.th_has_shipped) then return nil; end

    local ok, result = pcall(function()
        db.th_conn:exec('BEGIN TRANSACTION');

        local new_id = db.create_th_profile(new_name);
        if (new_id == nil) then
            db.th_conn:exec('ROLLBACK');
            return nil;
        end

        -- Clone items
        local stmt = db.th_conn:prepare(([[
            INSERT INTO main.th_items (profile_id, item_id, item_name, th_value, slot_id, notes)
            SELECT ?, item_id, item_name, th_value, slot_id, notes FROM %s.th_items WHERE profile_id = ?
        ]]):format(src_schema));
        if (stmt ~= nil) then
            stmt:bind_values(new_id, src_real);
            local rc = stmt:step();
            stmt:finalize();
            if (rc ~= sqlite3.DONE) then
                db.th_conn:exec('ROLLBACK');
                return nil;
            end
        end

        -- Clone traits
        local trait_stmt = db.th_conn:prepare(([[
            INSERT INTO main.th_job_traits (profile_id, job_id, is_main, min_level, th_value, enabled)
            SELECT ?, job_id, is_main, min_level, th_value, enabled FROM %s.th_job_traits WHERE profile_id = ?
        ]]):format(src_schema));
        if (trait_stmt ~= nil) then
            trait_stmt:bind_values(new_id, src_real);
            local rc = trait_stmt:step();
            trait_stmt:finalize();
            if (rc ~= sqlite3.DONE) then
                db.th_conn:exec('ROLLBACK');
                return nil;
            end
        end

        db.th_conn:exec('COMMIT');
        return new_id;
    end);

    if (not ok) then
        pcall(db.th_conn.exec, db.th_conn, 'ROLLBACK');
        return nil;
    end
    return result;
end

function db.delete_th_profile(profile_id)
    if (db.th_conn == nil) then return false; end
    -- A shipped profile cannot be deleted -- it lives in the read-only catalog. Removing a user
    -- copy is db.reset_th_profile(), which reveals the shipped one again.
    local sch, real = th_route(profile_id);
    if (sch ~= 'main') then return false; end
    profile_id = real;
    local stmt = db.th_conn:prepare('DELETE FROM main.th_profiles WHERE id = ?');
    if (stmt == nil) then return false; end
    stmt:bind_values(profile_id);
    stmt:step();
    stmt:finalize();
    return db.th_conn:changes() > 0;
end

-- TH Items: Item CRUD

function db.get_th_items(profile_id)
    if (db.th_conn == nil) then return {}; end
    -- shipped profiles carry an offset id; read from whichever schema owns it
    local sch, profile_id = th_route(profile_id);
    if (sch == 'shipped' and not db.th_has_shipped) then return {}; end
    local results = {};
    local stmt = db.th_conn:prepare(
        ('SELECT id, item_id, item_name, th_value, slot_id, notes FROM ' .. sch .. '.th_items WHERE profile_id = ? ORDER BY slot_id ASC, item_name ASC')
    );
    if (stmt == nil) then return results; end
    stmt:bind_values(profile_id);
    for row in stmt:nrows() do
        results[#results + 1] = row;
    end
    stmt:finalize();
    return results;
end

function db.get_th_items_by_item_id(profile_id)
    if (db.th_conn == nil) then return {}; end
    -- shipped profiles carry an offset id; read from whichever schema owns it
    local sch, profile_id = th_route(profile_id);
    if (sch == 'shipped' and not db.th_has_shipped) then return {}; end
    local results = {};
    local stmt = db.th_conn:prepare(
        ('SELECT item_id, th_value, slot_id FROM ' .. sch .. '.th_items WHERE profile_id = ?')
    );
    if (stmt == nil) then return results; end
    stmt:bind_values(profile_id);
    for row in stmt:nrows() do
        results[row.item_id] = row;
    end
    stmt:finalize();
    return results;
end

function db.add_th_item(profile_id, item_id, item_name, th_value, slot_id, notes)
    if (db.th_conn == nil) then return nil; end
    -- Shipped profiles are read-only: materialise a user copy first so the shipped
    -- original stays pristine and Reset can fall back to it.
    profile_id = db.materialize_th_profile(profile_id);
    if (profile_id == nil) then return nil; end
    local stmt = db.th_conn:prepare(
        'INSERT OR REPLACE INTO th_items (profile_id, item_id, item_name, th_value, slot_id, notes) VALUES (?, ?, ?, ?, ?, ?)'
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(profile_id, item_id, item_name or '', th_value or 1, slot_id or -1, notes or '');
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then return nil; end
    return db.th_conn:last_insert_rowid();
end

-- Resolve edits in the user store by profile and item/trait identity, never a shipped row ID.
-- Materialize shipped profiles first and return the user profile ID for the editor to follow.
function db.update_th_item(profile_id, item_id, th_value, slot_id, notes)
    if (db.th_conn == nil) then return nil; end
    local pid = db.materialize_th_profile(profile_id);
    if (pid == nil) then return nil; end
    local stmt = db.th_conn:prepare(
        'UPDATE main.th_items SET th_value = ?, slot_id = ?, notes = ? WHERE profile_id = ? AND item_id = ?'
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(th_value or 1, slot_id or -1, notes or '', pid, item_id);
    stmt:step();
    stmt:finalize();
    return pid;
end

function db.delete_th_item(profile_id, item_id)
    if (db.th_conn == nil) then return nil; end
    local pid = db.materialize_th_profile(profile_id);
    if (pid == nil) then return nil; end
    local stmt = db.th_conn:prepare('DELETE FROM main.th_items WHERE profile_id = ? AND item_id = ?');
    if (stmt == nil) then return nil; end
    stmt:bind_values(pid, item_id);
    stmt:step();
    stmt:finalize();
    return pid;
end

-- TH Items: Job Trait CRUD

function db.get_th_job_traits(profile_id)
    if (db.th_conn == nil) then return {}; end
    -- shipped profiles carry an offset id; read from whichever schema owns it
    local sch, profile_id = th_route(profile_id);
    if (sch == 'shipped' and not db.th_has_shipped) then return {}; end
    local results = {};
    local stmt = db.th_conn:prepare(
        ('SELECT id, job_id, is_main, min_level, th_value, enabled FROM ' .. sch .. '.th_job_traits WHERE profile_id = ? ORDER BY is_main DESC, min_level ASC')
    );
    if (stmt == nil) then return results; end
    stmt:bind_values(profile_id);
    for row in stmt:nrows() do
        results[#results + 1] = row;
    end
    stmt:finalize();
    return results;
end

function db.add_th_job_trait(profile_id, job_id, is_main, min_level, th_value, enabled)
    if (db.th_conn == nil) then return nil; end
    -- Shipped profiles are read-only: materialise a user copy first so the shipped
    -- original stays pristine and Reset can fall back to it.
    profile_id = db.materialize_th_profile(profile_id);
    if (profile_id == nil) then return nil; end
    local stmt = db.th_conn:prepare(
        'INSERT INTO th_job_traits (profile_id, job_id, is_main, min_level, th_value, enabled) VALUES (?, ?, ?, ?, ?, ?)'
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(profile_id, job_id or 6, is_main or 1, min_level, th_value, (enabled == nil or enabled) and 1 or 0);
    local rc = stmt:step();
    stmt:finalize();
    if (rc ~= sqlite3.DONE) then return nil; end
    return db.th_conn:last_insert_rowid();
end

-- Trait identity = (profile, job, role, level); see the F1 note above update_th_item.
function db.set_th_job_trait_enabled(profile_id, job_id, is_main, min_level, enabled)
    if (db.th_conn == nil) then return nil; end
    local pid = db.materialize_th_profile(profile_id);
    if (pid == nil) then return nil; end
    local stmt = db.th_conn:prepare(
        'UPDATE main.th_job_traits SET enabled = ? WHERE profile_id = ? AND job_id = ? AND is_main = ? AND min_level = ?'
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(enabled and 1 or 0, pid, job_id, is_main, min_level);
    stmt:step();
    stmt:finalize();
    return pid;
end

function db.delete_th_job_trait(profile_id, job_id, is_main, min_level)
    if (db.th_conn == nil) then return nil; end
    local pid = db.materialize_th_profile(profile_id);
    if (pid == nil) then return nil; end
    local stmt = db.th_conn:prepare(
        'DELETE FROM main.th_job_traits WHERE profile_id = ? AND job_id = ? AND is_main = ? AND min_level = ?'
    );
    if (stmt == nil) then return nil; end
    stmt:bind_values(pid, job_id, is_main, min_level);
    stmt:step();
    stmt:finalize();
    return pid;
end

-- TH Items: Compute TH from traits for given job/level

function db.compute_trait_th(profile_id, main_job, sub_job, main_level, sub_level, skip_blu)
    if (db.th_conn == nil) then return 0; end

    local sch, profile_id = th_route(profile_id);
    if (sch == 'shipped' and not db.th_has_shipped) then return 0; end

    local main_th = 0;
    local sub_th = 0;
    local stmt = db.th_conn:prepare(
        ('SELECT job_id, is_main, min_level, th_value, enabled FROM ' .. sch .. '.th_job_traits WHERE profile_id = ? ORDER BY min_level ASC')
    );
    if (stmt == nil) then return 0; end
    stmt:bind_values(profile_id);

    for row in stmt:nrows() do
        -- Skip disabled traits
        if (row.enabled == 0) then
            -- disabled by user
        -- BLU TH is a spell-set trait; skip if required spells are not set
        elseif (skip_blu and row.job_id == 16) then
            -- skip BLU trait (spells not set)
        elseif (row.is_main == 1 and main_job == row.job_id and main_level >= row.min_level) then
            main_th = row.th_value;  -- higher tier replaces previous
        elseif (row.is_main == 0 and sub_job == row.job_id and sub_level >= row.min_level) then
            sub_th = row.th_value;
        end
    end
    stmt:finalize();

    -- Use the higher of main or sub trait (they don't stack)
    return math.max(main_th, sub_th);
end

-- Cleanup

function db.get_file_size()
    if (db.path == nil) then return 0; end
    local f = io.open(db.path, 'rb');
    if (f == nil) then return 0; end
    local size = f:seek('end');
    f:close();
    return size or 0;
end

--- Close ONLY the per-character database, leaving th_conn open.
function db.close_character()
    if (db.conn ~= nil) then
        if (db._in_transaction) then
            local ok = pcall(db.conn.exec, db.conn, 'COMMIT');
            if (not ok) then pcall(db.conn.exec, db.conn, 'COMMIT'); end
            db._in_transaction = false;
        end
        pcall(db.conn.close, db.conn);
        db.conn = nil;
    end
    -- Invalidate all character caches on close; stats_dirty also invalidates UI analysis.
    invalidate_all();
end

function db.close()
    if (db.conn ~= nil) then
        -- Commit any open transaction before closing (pcall to prevent data loss)
        if (db._in_transaction) then
            local ok, err = pcall(db.conn.exec, db.conn, 'COMMIT');
            if (not ok) then
                -- Retry once — transient busy lock can clear quickly
                pcall(db.conn.exec, db.conn, 'COMMIT');
            end
            db._in_transaction = false;
        end
        pcall(db.conn.close, db.conn);
        db.conn = nil;
    end
    invalidate_all();   -- same reason as close_character
    if (db.th_conn ~= nil) then
        pcall(db.th_conn.close, db.th_conn);
        db.th_conn = nil;
    end
end

return db;
