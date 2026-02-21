--[[
    LootScope v1.0.0 - SQLite3 Persistence Layer
    Five-table schema: kills, drops, missed_kills, battlefield_sessions,
    chest_events.
    Uses Ashita v4.30's built-in LuaSQLite3 with dirty-flag caching.

    Per-character databases: each character gets their own DB file under
    config/addons/lootscope/<CharName>_<ServerId>/lootscope.db matching
    Ashita's settings folder convention. Avoids multi-box write contention
    and keeps data separated across characters/servers.

    Author: SQLCommit
    Version: 1.0.0
]]--

require 'common';

local sqlite3 = require 'sqlite3';
local os_time = os.time;

local db = {};
db.conn = nil;
db.path = nil;
db.char_name = nil;  -- character this DB belongs to
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

-- Cache dirty flags
db.kills_dirty = true;
db.drops_dirty = true;
db.stats_dirty = true;

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
db.missed_zone_cache = {};
db.chest_events_cache = nil;
db.chest_events_limit = 0;
db.chest_events_dirty = true;
db.chest_stats_cache = nil;

-------------------------------------------------------------------------------
-- Initialization (deferred — called once character name is known)
-------------------------------------------------------------------------------

function db.init(base_path, char_folder)
    if (db.conn ~= nil) then return true; end  -- already initialized
    if (db._init_failed) then return false; end

    -- Per-character subdirectory: config/addons/lootscope/<CharName>_<ServerId>/
    -- Matches Ashita's settings library folder convention.
    db.char_name = char_folder;
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
                os.rename(old_db_path, new_db_path);
                -- Also move WAL/SHM companion files if they exist
                pcall(os.rename, old_db_path .. '-wal', new_db_path .. '-wal');
                pcall(os.rename, old_db_path .. '-shm', new_db_path .. '-shm');
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

    -- WAL mode for concurrent read safety, busy_timeout for rare write contention
    -- (e.g. if two addons in same process somehow race — defensive measure).
    -- Wrap schema creation and migrations in pcall — a corrupt DB should degrade
    -- gracefully rather than crash the addon.
    local schema_ok, schema_err = pcall(function()
        db.conn:exec('PRAGMA journal_mode=WAL;');
        db.conn:exec('PRAGMA foreign_keys=ON;');
        db.conn:exec('PRAGMA busy_timeout=3000;');

        db.conn:exec([[
            CREATE TABLE IF NOT EXISTS kills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mob_name TEXT NOT NULL COLLATE NOCASE,
                mob_server_id INTEGER NOT NULL,
                zone_id INTEGER NOT NULL,
                zone_name TEXT NOT NULL,
                th_level INTEGER DEFAULT 0,
                source_type INTEGER DEFAULT 0,
                vana_weekday INTEGER DEFAULT -1,
                vana_hour INTEGER DEFAULT -1,
                moon_phase INTEGER DEFAULT -1,
                moon_percent INTEGER DEFAULT -1,
                timestamp INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS drops (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kill_id INTEGER NOT NULL REFERENCES kills(id) ON DELETE CASCADE,
                pool_slot INTEGER NOT NULL,
                item_id INTEGER NOT NULL,
                item_name TEXT NOT NULL,
                quantity INTEGER DEFAULT 1,
                won INTEGER DEFAULT 0,
                lot_value INTEGER DEFAULT 0,
                timestamp INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_kills_mob ON kills(mob_name, zone_id);
            CREATE INDEX IF NOT EXISTS idx_kills_ts ON kills(timestamp);
            CREATE INDEX IF NOT EXISTS idx_kills_sid ON kills(mob_server_id);
            CREATE INDEX IF NOT EXISTS idx_kills_src ON kills(source_type);
            CREATE INDEX IF NOT EXISTS idx_drops_item ON drops(item_id);
            CREATE INDEX IF NOT EXISTS idx_drops_kill ON drops(kill_id);
        ]]);

        -- Migration: check existing kills columns in a single pass
        local kills_has = {};
        for row in db.conn:nrows('PRAGMA table_info(kills)') do
            kills_has[row.name] = true;
        end

        if (not kills_has.vana_weekday) then
            db.conn:exec('ALTER TABLE kills ADD COLUMN vana_weekday INTEGER DEFAULT -1;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN vana_hour INTEGER DEFAULT -1;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN moon_phase INTEGER DEFAULT -1;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN moon_percent INTEGER DEFAULT -1;');
        end

        if (not kills_has.killer_id) then
            db.conn:exec('ALTER TABLE kills ADD COLUMN killer_id INTEGER DEFAULT 0;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN th_action_type INTEGER DEFAULT 0;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN th_action_id INTEGER DEFAULT 0;');
        end

        if (not kills_has.weather) then
            db.conn:exec('ALTER TABLE kills ADD COLUMN weather INTEGER DEFAULT -1;');
        end

        if (not kills_has.battlefield) then
            db.conn:exec('ALTER TABLE kills ADD COLUMN battlefield TEXT DEFAULT NULL;');
            db.conn:exec('ALTER TABLE kills ADD COLUMN level_cap INTEGER DEFAULT NULL;');
        end

        if (not kills_has.killer_name) then
            db.conn:exec("ALTER TABLE kills ADD COLUMN killer_name TEXT DEFAULT '';");
        end

        if (not kills_has.is_distant) then
            db.conn:exec('ALTER TABLE kills ADD COLUMN is_distant INTEGER DEFAULT 0;');
        end

        -- Migration: add mob_server_id index if missing
        local has_sid_idx = false;
        for row in db.conn:nrows("PRAGMA index_list(kills)") do
            if (row.name == 'idx_kills_sid') then has_sid_idx = true; break; end
        end
        if (not has_sid_idx) then
            db.conn:exec('CREATE INDEX IF NOT EXISTS idx_kills_sid ON kills(mob_server_id);');
        end

        -- Migration: check existing drops columns in a single pass
        local drops_has = {};
        for row in db.conn:nrows('PRAGMA table_info(drops)') do
            drops_has[row.name] = true;
        end

        if (not drops_has.winner_id) then
            db.conn:exec("ALTER TABLE drops ADD COLUMN winner_id INTEGER DEFAULT 0;");
            db.conn:exec("ALTER TABLE drops ADD COLUMN winner_name TEXT DEFAULT '';");
            db.conn:exec("ALTER TABLE drops ADD COLUMN player_lot INTEGER DEFAULT 0;");
            db.conn:exec("ALTER TABLE drops ADD COLUMN player_action INTEGER DEFAULT 0;");
        end

        -- Migration: add missed_kills table for tracking distant party kills
        -- (msg_id=37 "too far from battle") where mob identity is unknown
        db.conn:exec([[
            CREATE TABLE IF NOT EXISTS missed_kills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                zone_id INTEGER NOT NULL,
                zone_name TEXT NOT NULL,
                timestamp INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_missed_zone ON missed_kills(zone_id);
        ]]);

        -- Migration: battlefield_sessions table for BCNM tracking
        db.conn:exec([[
            CREATE TABLE IF NOT EXISTS battlefield_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                battlefield_name TEXT,
                zone_id INTEGER NOT NULL,
                zone_name TEXT,
                level_cap INTEGER,
                entered_at INTEGER NOT NULL,
                exited_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_bf_zone ON battlefield_sessions(zone_id);
        ]]);

        -- Migration: chest_events table for tracking chest/coffer failures and gil
        db.conn:exec([[
            CREATE TABLE IF NOT EXISTS chest_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                zone_id INTEGER NOT NULL,
                zone_name TEXT NOT NULL,
                container_type INTEGER NOT NULL,
                result INTEGER NOT NULL,
                gil_amount INTEGER DEFAULT 0,
                vana_weekday INTEGER DEFAULT -1,
                vana_hour INTEGER DEFAULT -1,
                moon_phase INTEGER DEFAULT -1,
                moon_percent INTEGER DEFAULT -1,
                weather INTEGER DEFAULT -1,
                timestamp INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_chest_zone ON chest_events(zone_id);
            CREATE INDEX IF NOT EXISTS idx_chest_zone_ctype ON chest_events(zone_id, container_type);
            CREATE INDEX IF NOT EXISTS idx_chest_ts ON chest_events(timestamp);
        ]]);

        -- Initialize running counters from existing data
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM kills') do db._kill_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM drops') do db._drop_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM missed_kills') do db._missed_kill_count = row.c; end
        for row in db.conn:nrows('SELECT COUNT(*) as c FROM chest_events') do db._chest_event_count = row.c; end

        -- Close stale battlefield sessions (older than 4 hours).
        -- If the addon crashed during a zone change, end_battlefield_session() never ran,
        -- leaving orphaned rows with exited_at IS NULL that would poison future reconnects.
        local stale_cutoff = os_time() - (4 * 60 * 60);
        local stale_stmt = db.conn:prepare('UPDATE battlefield_sessions SET exited_at = entered_at WHERE exited_at IS NULL AND entered_at < ?');
        if (stale_stmt ~= nil) then
            stale_stmt:bind_values(stale_cutoff);
            stale_stmt:step();
            stale_stmt:finalize();
        end
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

    return true;
end

-------------------------------------------------------------------------------
-- Helpers: Cache Invalidation
-------------------------------------------------------------------------------

-- Full invalidation — only used by clear_data()
local function invalidate_all()
    db.kills_dirty = true;
    db.drops_dirty = true;
    db.stats_dirty = true;
    db.chest_events_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.mob_stats_cache = {};
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
    db.zone_list_cache = nil;
    db.spawn_stats_cache = {};
    db.spawn_item_cache = {};
    db.missed_zone_cache = {};
    db.chest_events_cache = nil;
    db.chest_stats_cache = nil;
end

-- Kill recorded: invalidates kill-related caches + stats
local function invalidate_kills()
    db.kills_dirty = true;
    db.stats_dirty = true;
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
    db.drops_dirty = true;
    db.stats_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
    db.mob_stats_cache = {};
    db.spawn_item_cache = {};
end

-- Lot result updated: invalidates feed/drop display and stats (won status affects computed stats)
local function invalidate_drop_status()
    db.drops_dirty = true;
    db.stats_dirty = true;
    db.recent_drops_cache = nil;
    db.recent_feed_cache = nil;
    db.mob_stats_cache = {};
    db.spawn_item_cache = {};
    db.all_mob_stats_cache = nil;
    db.all_mob_stats_cache_key = nil;
end

-------------------------------------------------------------------------------
-- Helpers: Transaction Batching
-------------------------------------------------------------------------------

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

local function maybe_commit()
    if (not db._in_transaction) then return; end
    db._batch_count = db._batch_count + 1;
    if (db._batch_count >= FLUSH_THRESHOLD or os.clock() - db._batch_start >= FLUSH_INTERVAL) then
        local ok = pcall(db.conn.exec, db.conn, 'COMMIT');
        if (ok) then
            db._in_transaction = false;
        end
    end
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

-------------------------------------------------------------------------------
-- Kill Recording
-------------------------------------------------------------------------------

function db.record_kill(mob_name, mob_server_id, zone_id, zone_name, th_level, source_type, vana_info, kill_info)
    if (db.conn == nil) then return nil; end

    begin_batch();

    local now = os_time();
    local vi = vana_info or {};
    local ki = kill_info or {};
    local stmt = db.conn:prepare([[
        INSERT INTO kills (mob_name, mob_server_id, zone_id, zone_name, th_level, source_type,
                           vana_weekday, vana_hour, moon_phase, moon_percent, timestamp,
                           killer_id, killer_name, th_action_type, th_action_id, weather,
                           battlefield, level_cap, is_distant)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]);
    if (stmt == nil) then maybe_commit(); return nil; end
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
        ki.is_distant or 0
    );
    stmt:step();
    stmt:finalize();

    db._kill_count = db._kill_count + 1;
    invalidate_kills();
    maybe_commit();

    return db.conn:last_insert_rowid();
end

-------------------------------------------------------------------------------
-- Drop Recording
-------------------------------------------------------------------------------

function db.record_drop(kill_id, pool_slot, item_id, item_name, quantity, won)
    if (db.conn == nil or kill_id == nil) then return nil; end

    begin_batch();

    local now = os_time();
    local stmt = db.conn:prepare([[
        INSERT INTO drops (kill_id, pool_slot, item_id, item_name, quantity, won, lot_value, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
    ]]);
    if (stmt == nil) then maybe_commit(); return nil; end
    stmt:bind_values(kill_id, pool_slot, item_id, item_name, quantity or 1, won or 0, now);
    stmt:step();
    stmt:finalize();

    db._drop_count = db._drop_count + 1;
    invalidate_drops();
    maybe_commit();

    return db.conn:last_insert_rowid();
end

-------------------------------------------------------------------------------
-- Find Pending Drop (reconnect pool items after addon reload)
-------------------------------------------------------------------------------

function db.find_pending_drop(pool_slot, item_id)
    if (db.conn == nil) then return nil; end

    local stmt = db.conn:prepare([[
        SELECT d.id, d.kill_id, d.item_name, d.quantity, d.won
        FROM drops d
        WHERE d.pool_slot = ? AND d.item_id = ? AND d.won IN (0, -2)
        ORDER BY d.timestamp DESC LIMIT 1
    ]]);
    if (stmt == nil) then return nil; end
    stmt:bind_values(pool_slot, item_id);

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

-------------------------------------------------------------------------------
-- Kill Name Update (retroactive mob name from chat when entity was out of range)
-------------------------------------------------------------------------------

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
    -- Also invalidate drops cache since get_recent_drops JOINs kills for mob_name
    db.drops_dirty = true;
    db.recent_drops_cache = nil;
    maybe_commit();
end

-------------------------------------------------------------------------------
-- Drop Update (lot result)
-------------------------------------------------------------------------------

function db.update_drop_won(kill_id, pool_slot, won, lot_value, lot_info)
    if (db.conn == nil) then return; end

    begin_batch();

    local li = lot_info or {};
    local stmt = db.conn:prepare([[
        UPDATE drops SET won = ?, lot_value = ?, winner_id = ?, winner_name = ?,
                         player_lot = ?, player_action = ?
        WHERE kill_id = ? AND pool_slot = ?
    ]]);
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(
        won, lot_value or 0,
        li.winner_id or 0, li.winner_name or '',
        li.player_lot or 0, li.player_action or 0,
        kill_id, pool_slot
    );
    stmt:step();
    stmt:finalize();

    invalidate_drop_status();
    maybe_commit();
end

-------------------------------------------------------------------------------
-- Queries (cached)
-------------------------------------------------------------------------------

function db.get_recent_drops(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.drops_dirty and db.recent_drops_cache ~= nil and db.recent_drops_limit == limit) then
        return db.recent_drops_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT d.*, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.zone_name, k.zone_id, k.th_level, k.source_type,
               k.timestamp as kill_ts,
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name
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
    db.drops_dirty = false;

    return results;
end

function db.get_recent_feed(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.drops_dirty and not db.kills_dirty and not db.chest_events_dirty
        and db.recent_feed_cache ~= nil and db.recent_feed_limit == limit) then
        return db.recent_feed_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT 'drop' as feed_type, d.timestamp as ts,
               COALESCE(k.battlefield, k.mob_name) as mob_name,
               k.zone_name, k.zone_id, k.th_level, k.source_type,
               d.item_name, d.item_id, d.quantity, d.won, d.pool_slot, d.kill_id,
               d.lot_value, d.winner_name,
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name,
               0 as container_type, 0 as chest_result, 0 as gil_amount
        FROM drops d
        JOIN kills k ON d.kill_id = k.id
        UNION ALL
        SELECT 'kill' as feed_type, k.timestamp as ts,
               COALESCE(k.battlefield, k.mob_name) as mob_name,
               k.zone_name, k.zone_id, k.th_level, k.source_type,
               NULL, 0, 0, 0, -1, k.id,
               0, '',
               k.mob_server_id, k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,
               k.weather, k.killer_name,
               0, 0, 0
        FROM kills k
        WHERE NOT EXISTS (SELECT 1 FROM drops d WHERE d.kill_id = k.id)
        UNION ALL
        SELECT 'chest' as feed_type, ce.timestamp as ts,
               '' as mob_name, ce.zone_name, ce.zone_id, 0 as th_level, ce.container_type as source_type,
               NULL, 0, 0, 0, -1, 0,
               0, '',
               0, ce.vana_weekday, ce.vana_hour, ce.moon_phase, ce.moon_percent,
               ce.weather, '' as killer_name,
               ce.container_type, ce.result, ce.gil_amount
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
    db.kills_dirty = false;
    db.drops_dirty = false;
    db.chest_events_dirty = false;

    return results;
end

function db.get_mob_stats(mob_name, zone_id, source_filter, level_cap)
    if (db.conn == nil) then return nil; end

    local key = (mob_name or '') .. '_' .. tostring(zone_id or 0) .. '_' .. tostring(source_filter or -1) .. '_' .. tostring(level_cap or 'nil');
    if (not db.stats_dirty and db.mob_stats_cache[key] ~= nil) then
        return db.mob_stats_cache[key];
    end

    local result = { kills = 0, distant_kills = 0, items = T{}, total_drops = 0 };

    -- BCNM mode: match by battlefield name instead of mob_name
    local is_bcnm = (source_filter == 2);
    local kill_query, item_query;

    if (is_bcnm) then
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE COALESCE(battlefield, \'Unknown BCNM\') = ? AND zone_id = ? AND source_type = 3';
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE COALESCE(k.battlefield, 'Unknown BCNM') = ? AND k.zone_id = ? AND k.source_type = 3
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
    else
        kill_query = 'SELECT COUNT(*) as c, SUM(CASE WHEN is_distant = 1 THEN 1 ELSE 0 END) as distant FROM kills WHERE mob_name = ? AND zone_id = ?';
        item_query = [[
            SELECT d.item_id, d.item_name,
                   COUNT(*) as times_dropped,
                   SUM(d.quantity) as total_qty,
                   SUM(CASE WHEN d.won = 1 THEN 1 ELSE 0 END) as times_won,
                   SUM(CASE WHEN k.is_distant = 0 THEN 1 ELSE 0 END) as nearby_times_dropped
            FROM drops d
            JOIN kills k ON d.kill_id = k.id
            WHERE k.mob_name = ? AND k.zone_id = ?
            GROUP BY d.item_id
            ORDER BY times_dropped DESC
        ]];
    end

    -- Kill count (from kills table)
    local stmt = db.conn:prepare(kill_query);
    if (stmt == nil) then return result; end
    if (is_bcnm and level_cap ~= nil) then
        stmt:bind_values(mob_name, zone_id, level_cap);
    else
        stmt:bind_values(mob_name, zone_id);
    end
    for row in stmt:nrows() do
        result.kills = row.c;
        result.distant_kills = row.distant or 0;
    end
    stmt:finalize();

    -- Chest/Coffer mode: add chest_events (failures + gil) as additional attempts.
    -- "Treasure Chest" → container_type 1, "Treasure Coffer" → container_type 2.
    if (source_filter == 1) then
        local ctype = nil;
        if (mob_name == 'Treasure Chest') then ctype = 1;
        elseif (mob_name == 'Treasure Coffer') then ctype = 2; end
        if (ctype ~= nil) then
            -- Exclude illusions (result=4) from attempt count — illusions aren't real chests
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
    if (is_bcnm and level_cap ~= nil) then
        stmt2:bind_values(mob_name, zone_id, level_cap);
    else
        stmt2:bind_values(mob_name, zone_id);
    end
    local nearby_kills = result.kills - result.distant_kills;
    for row in stmt2:nrows() do
        local nearby_dropped = row.nearby_times_dropped or row.times_dropped;
        -- Primary rate: nearby kills only (unbiased)
        row.drop_rate = (nearby_kills > 0) and (nearby_dropped / nearby_kills) * 100 or 0;
        -- Combined rate: all kills including distant (biased — distant kills are a self-selected sample with drops)
        row.combined_rate = (result.kills > 0) and (row.times_dropped / result.kills) * 100 or -1;
        -- Gil (item_id 65535) is shown in the breakdown but excluded from
        -- aggregate drop counts so it doesn't inflate item drop rates.
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

    -- Enhance mob gil entry with min/max/avg amount (same style as chest gil)
    for _, item in ipairs(result.items) do
        if (item.is_gil_drop and item.times_dropped > 0) then
            local gil_q;
            if (is_bcnm) then
                gil_q = [[
                    SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil
                    FROM drops d JOIN kills k ON d.kill_id = k.id
                    WHERE d.item_id = 65535 AND COALESCE(k.battlefield, 'Unknown BCNM') = ? AND k.zone_id = ? AND k.source_type = 3
                ]];
                if (level_cap ~= nil) then
                    gil_q = gil_q .. ' AND k.level_cap = ?';
                else
                    gil_q = gil_q .. ' AND k.level_cap IS NULL';
                end
            else
                gil_q = [[
                    SELECT MIN(d.quantity) as min_gil, MAX(d.quantity) as max_gil
                    FROM drops d JOIN kills k ON d.kill_id = k.id
                    WHERE d.item_id = 65535 AND k.mob_name = ? AND k.zone_id = ?
                ]];
            end
            local gs = db.conn:prepare(gil_q);
            if (gs ~= nil) then
                if (is_bcnm and level_cap ~= nil) then
                    gs:bind_values(mob_name, zone_id, level_cap);
                else
                    gs:bind_values(mob_name, zone_id);
                end
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

    -- Chest/Coffer mode: add chest event details (gil, failures) as synthetic "items"
    -- so they appear in the expanded per-item breakdown alongside pool drops.
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
    return result;
end

function db.get_all_mob_stats(source_filter)
    if (db.conn == nil) then return T{}; end

    -- Cache key includes source_filter to avoid stale results across views
    local cache_key = tostring(source_filter or -1);
    if (not db.stats_dirty and db.all_mob_stats_cache ~= nil
        and db.all_mob_stats_cache_key == cache_key) then
        return db.all_mob_stats_cache;
    end

    local results = T{};
    local where_clause = '';

    if (source_filter == 0) then
        where_clause = ' WHERE k.source_type = 0';
    elseif (source_filter == 1) then
        where_clause = ' WHERE k.source_type IN (1, 2)';
    elseif (source_filter == 2) then
        where_clause = ' WHERE k.source_type = 3';
    end

    -- BCNM view: group by battlefield name instead of mob_name (all are "Armoury Crate")
    -- Gil drops (item_id=65535) are excluded from drop_count/unique_items so they
    -- don't inflate item drop rates.
    local query;
    if (source_filter == 2) then
        query = [[
            SELECT COALESCE(k.battlefield, 'Unknown BCNM') as mob_name,
                   k.zone_name, k.zone_id, k.level_cap,
                   COUNT(DISTINCT k.id) as kill_count,
                   COUNT(DISTINCT CASE WHEN k.is_distant = 1 THEN k.id ELSE NULL END) as distant_kills,
                   COUNT(CASE WHEN d.item_id != 65535 THEN d.id ELSE NULL END) as drop_count,
                   COUNT(DISTINCT CASE WHEN d.item_id != 65535 THEN d.item_id ELSE NULL END) as unique_items,
                   COUNT(DISTINCT k.mob_server_id) as unique_spawns
            FROM kills k
            LEFT JOIN drops d ON d.kill_id = k.id
        ]] .. where_clause .. [[
            GROUP BY COALESCE(k.battlefield, 'Unknown BCNM'), k.zone_id, k.level_cap
            ORDER BY kill_count DESC
        ]];
    else
        query = [[
            SELECT k.mob_name, k.zone_name, k.zone_id,
                   COUNT(DISTINCT k.id) as kill_count,
                   COUNT(DISTINCT CASE WHEN k.is_distant = 1 THEN k.id ELSE NULL END) as distant_kills,
                   COUNT(CASE WHEN d.item_id != 65535 THEN d.id ELSE NULL END) as drop_count,
                   COUNT(DISTINCT CASE WHEN d.item_id != 65535 THEN d.item_id ELSE NULL END) as unique_items,
                   COUNT(DISTINCT k.mob_server_id) as unique_spawns
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
        row.avg_drops = row.kill_count > 0 and (row.drop_count / row.kill_count) or 0;
        results:append(row);
    end
    stmt:finalize();

    -- Chest/Coffer mode: add chest_events (failures + gil) as additional attempts.
    -- Without this, kill_count only reflects item drops → drop rate is always ~100%.
    if (source_filter == 1) then
        -- Build lookup: "mob_name|zone_id" → index in results
        local lookup = {};
        for i, row in ipairs(results) do
            lookup[row.mob_name .. '|' .. tostring(row.zone_id)] = i;
        end

        -- Map container_type to mob_name used in kills table
        local ctype_to_name = { [1] = 'Treasure Chest', [2] = 'Treasure Coffer' };

        -- Exclude illusions (result=4) from attempt count — illusions aren't real chests
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
    db.stats_dirty = false;

    return results;
end

-------------------------------------------------------------------------------
-- Counts (O(1) via running counters)
-------------------------------------------------------------------------------

function db.get_counts()
    if (db.conn == nil) then return 0, 0, 0, 0; end
    return db._kill_count, db._drop_count, db._missed_kill_count, db._chest_event_count;
end

-------------------------------------------------------------------------------
-- Missed Kills (distant party kills with no mob identity)
-------------------------------------------------------------------------------

function db.record_missed_kill(zone_id, zone_name)
    if (db.conn == nil) then return; end

    begin_batch();

    local stmt = db.conn:prepare('INSERT INTO missed_kills (zone_id, zone_name, timestamp) VALUES (?, ?, ?)');
    if (stmt == nil) then maybe_commit(); return; end
    stmt:bind_values(zone_id, zone_name, os_time());
    stmt:step();
    stmt:finalize();

    db._missed_kill_count = db._missed_kill_count + 1;
    db.missed_zone_cache = {};
    -- Zone missed kills are informational only (no mob identity) — they don't
    -- affect per-mob rate calculations, so no stats cache invalidation needed.

    maybe_commit();
end

function db.get_missed_kills_for_zone(zone_id)
    if (db.conn == nil) then return 0; end

    if (db.missed_zone_cache[zone_id] ~= nil) then
        return db.missed_zone_cache[zone_id];
    end

    local count = 0;
    local stmt = db.conn:prepare('SELECT COUNT(*) as c FROM missed_kills WHERE zone_id = ?');
    if (stmt ~= nil) then
        stmt:bind_values(zone_id);
        for row in stmt:nrows() do count = row.c; end
        stmt:finalize();
    end

    db.missed_zone_cache[zone_id] = count;
    return count;
end

-------------------------------------------------------------------------------
-- Zone List (for filter dropdowns)
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Per-Spawn Stats (by mob_server_id)
-------------------------------------------------------------------------------

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
        row.avg_drops = row.kill_count > 0 and (row.drop_count / row.kill_count) or 0;
        results:append(row);
    end
    stmt:finalize();

    db.spawn_stats_cache[key] = results;
    return results;
end

-------------------------------------------------------------------------------
-- Per-Spawn Item Breakdown
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Filtered Export: Shared filter builder
-------------------------------------------------------------------------------

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

    if (f.source_type_list ~= nil) then
        -- Multi-value source filter (e.g. Chest + Coffer)
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

-------------------------------------------------------------------------------
-- Chest Event UNION Builder (for filtered export)
-------------------------------------------------------------------------------

local function build_chest_event_union(filters)
    local f = filters or {};

    -- Include chest events when: source is All (nil), Chest/Coffer list, or explicit Chest(1)/Coffer(2)
    local is_all = (f.source_type == nil and f.source_type_list == nil);
    local is_chest_source = (f.source_type == 1 or f.source_type == 2);
    local is_chest_list = (f.source_type_list ~= nil);
    if (not is_all and not is_chest_source and not is_chest_list) then
        -- Source is Mob or BCNM — no chest events
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
    -- (e.g. "Gil", "Lockpick Failed", "Trapped!", "Mimic!", "Illusion")
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

-------------------------------------------------------------------------------
-- Filtered Export Query (for Export tab)
-------------------------------------------------------------------------------

function db.get_filtered_export(filters, limit)
    if (db.conn == nil) then return T{}, 0; end

    local conditions, params, _, join_type = build_export_filters(filters);

    local query = 'SELECT k.id AS kill_id, k.timestamp, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.mob_server_id,'
        .. ' k.zone_name, k.zone_id, k.th_level, k.source_type,'
        .. ' k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,'
        .. ' k.killer_id, k.killer_name, k.th_action_type, k.th_action_id, k.weather,'
        .. ' d.item_name, d.item_id, d.pool_slot, d.quantity, d.won, d.lot_value,'
        .. ' d.winner_id, d.winner_name, d.player_lot, d.player_action,'
        .. ' d.timestamp AS drop_timestamp'
        .. ' FROM kills k ' .. join_type .. ' JOIN drops d ON d.kill_id = k.id';

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

-------------------------------------------------------------------------------
-- Filtered Export Count
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Battlefield Sessions (BCNM tracking)
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Chest Event Recording
-------------------------------------------------------------------------------

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
    if (stmt == nil) then maybe_commit(); return nil; end
    stmt:bind_values(
        zone_id, zone_name, container_type, result, gil_amount or 0,
        vi.weekday or -1, vi.hour or -1,
        vi.moon_phase or -1, vi.moon_percent or -1,
        vi.weather or -1,
        now
    );
    stmt:step();
    stmt:finalize();

    db._chest_event_count = db._chest_event_count + 1;
    db.chest_events_dirty = true;
    db.chest_events_cache = nil;
    db.chest_stats_cache = nil;
    -- Also invalidate feed + stats caches since chest events appear in Live Feed and Statistics
    db.recent_feed_cache = nil;
    db.kills_dirty = true;
    db.stats_dirty = true;

    maybe_commit();

    return db.conn:last_insert_rowid();
end

-------------------------------------------------------------------------------
-- Chest Event Queries (cached)
-------------------------------------------------------------------------------

function db.get_recent_chest_events(limit)
    if (db.conn == nil) then return T{}; end

    limit = limit or 100;
    if (not db.chest_events_dirty and db.chest_events_cache ~= nil and db.chest_events_limit == limit) then
        return db.chest_events_cache;
    end

    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT * FROM chest_events ORDER BY id DESC LIMIT ?
    ]]);
    if (stmt == nil) then return results; end
    stmt:bind_values(limit);
    for row in stmt:nrows() do
        results:append(row);
    end
    stmt:finalize();

    db.chest_events_cache = results;
    db.chest_events_limit = limit;
    db.chest_events_dirty = false;
    return results;
end

function db.get_chest_stats()
    if (db.conn == nil) then return T{}; end

    if (db.chest_stats_cache ~= nil and not db.chest_events_dirty) then
        return db.chest_stats_cache;
    end

    local results = T{};
    -- total_events excludes illusions (result=4) — illusions aren't real chests.
    -- fail_illusion is still queried separately for display but not counted in totals.
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
    return results;
end

-------------------------------------------------------------------------------
-- Clear Data
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Export: Streaming (constant memory instead of loading entire DB)
-------------------------------------------------------------------------------

function db.stream_export_all(write_row)
    if (db.conn == nil) then return; end

    local current_kill = nil;
    local current_drops = {};

    local stmt = db.conn:prepare([[
        SELECT k.id AS kid, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.mob_server_id, k.zone_name, k.zone_id,
               k.th_level, k.source_type, k.vana_weekday, k.vana_hour,
               k.moon_phase, k.moon_percent, k.timestamp AS k_timestamp,
               k.killer_id, k.killer_name, k.th_action_type, k.th_action_id, k.weather,
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

    local query = 'SELECT k.id AS kill_id, k.timestamp, COALESCE(k.battlefield, k.mob_name) AS mob_name, k.mob_server_id,'
        .. ' k.zone_name, k.zone_id, k.th_level, k.source_type,'
        .. ' k.vana_weekday, k.vana_hour, k.moon_phase, k.moon_percent,'
        .. ' k.killer_id, k.killer_name, k.th_action_type, k.th_action_id, k.weather,'
        .. ' d.item_name, d.item_id, d.pool_slot, d.quantity, d.won, d.lot_value,'
        .. ' d.winner_id, d.winner_name, d.player_lot, d.player_action,'
        .. ' d.timestamp AS drop_timestamp'
        .. ' FROM kills k ' .. join_type .. ' JOIN drops d ON d.kill_id = k.id';

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

-------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------

function db.get_file_size()
    if (db.path == nil) then return 0; end
    local f = io.open(db.path, 'rb');
    if (f == nil) then return 0; end
    local size = f:seek('end');
    f:close();
    return size or 0;
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
end

return db;
