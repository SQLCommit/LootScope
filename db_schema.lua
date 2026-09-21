-- Additive schema creation and migrations. Historical-row changes belong in db_backfill.

local schema = {};

--- Base tables + indexes. Idempotent.
function schema.create_tables(conn)
        conn:exec([[
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
            CREATE INDEX IF NOT EXISTS idx_drops_kill_item ON drops(kill_id, item_id);
        ]]);
end

--- Additive column migrations, probed via PRAGMA table_info. Idempotent.
function schema.migrate_columns(conn)
        -- Migration: check existing kills columns in a single pass
        local kills_has = {};
        for row in conn:nrows('PRAGMA table_info(kills)') do
            kills_has[row.name] = true;
        end

        if (not kills_has.vana_weekday) then
            conn:exec('ALTER TABLE kills ADD COLUMN vana_weekday INTEGER DEFAULT -1;');
            conn:exec('ALTER TABLE kills ADD COLUMN vana_hour INTEGER DEFAULT -1;');
            conn:exec('ALTER TABLE kills ADD COLUMN moon_phase INTEGER DEFAULT -1;');
            conn:exec('ALTER TABLE kills ADD COLUMN moon_percent INTEGER DEFAULT -1;');
        end

        if (not kills_has.killer_id) then
            conn:exec('ALTER TABLE kills ADD COLUMN killer_id INTEGER DEFAULT 0;');
            conn:exec('ALTER TABLE kills ADD COLUMN th_action_type INTEGER DEFAULT 0;');
            conn:exec('ALTER TABLE kills ADD COLUMN th_action_id INTEGER DEFAULT 0;');
        end

        if (not kills_has.weather) then
            conn:exec('ALTER TABLE kills ADD COLUMN weather INTEGER DEFAULT -1;');
        end

        if (not kills_has.battlefield) then
            conn:exec('ALTER TABLE kills ADD COLUMN battlefield TEXT DEFAULT NULL;');
            conn:exec('ALTER TABLE kills ADD COLUMN level_cap INTEGER DEFAULT NULL;');
        end

        if (not kills_has.killer_name) then
            conn:exec("ALTER TABLE kills ADD COLUMN killer_name TEXT DEFAULT '';");
        end

        if (not kills_has.is_distant) then
            conn:exec('ALTER TABLE kills ADD COLUMN is_distant INTEGER DEFAULT 0;');
        end

        if (not kills_has.bf_name) then
            conn:exec("ALTER TABLE kills ADD COLUMN bf_name TEXT DEFAULT '';");
            conn:exec('ALTER TABLE kills ADD COLUMN bf_difficulty INTEGER DEFAULT 0;');
        end

        if (not kills_has.content_type) then
            conn:exec("ALTER TABLE kills ADD COLUMN content_type TEXT DEFAULT '';");
        end
        conn:exec("CREATE INDEX IF NOT EXISTS idx_kills_content ON kills(content_type, zone_id);");

        if (not kills_has.th_estimated) then
            conn:exec('ALTER TABLE kills ADD COLUMN th_estimated INTEGER DEFAULT 0;');
        end

        if (not kills_has.app_version) then
            conn:exec("ALTER TABLE kills ADD COLUMN app_version TEXT DEFAULT '';");
        end
        -- How the BCNM/HTBF classification was reached: 'packet' (0x005C, authoritative),
        -- 'star' (chat fallback, only when the packet never arrived), 'woe' (Walk of Echoes
        -- pending entry), '' (not a battlefield / legacy row).
        if (not kills_has.bf_source) then
            conn:exec("ALTER TABLE kills ADD COLUMN bf_source TEXT DEFAULT '';");
        end

        -- Content-axis provenance + the raw inputs behind it.
        if (not kills_has.previous_zone_id) then
            conn:exec("ALTER TABLE kills ADD COLUMN previous_zone_id INTEGER DEFAULT 0;");
        end
        if (not kills_has.entry_zone_id) then
            conn:exec("ALTER TABLE kills ADD COLUMN entry_zone_id INTEGER DEFAULT 0;");
        end
        -- Which evidence slot answered: 'session'/'chat'/'zone'/'source'/'packet'/'battlefield',
        -- or '' when nothing classified it. Mirrors bf_source on the content axis.
        if (not kills_has.content_source) then
            conn:exec("ALTER TABLE kills ADD COLUMN content_source TEXT DEFAULT '';");
        end

        -- Migration: check existing drops columns in a single pass
        local drops_has = {};
        for row in conn:nrows('PRAGMA table_info(drops)') do
            drops_has[row.name] = true;
        end

        if (not drops_has.winner_id) then
            conn:exec("ALTER TABLE drops ADD COLUMN winner_id INTEGER DEFAULT 0;");
            conn:exec("ALTER TABLE drops ADD COLUMN winner_name TEXT DEFAULT '';");
            conn:exec("ALTER TABLE drops ADD COLUMN player_lot INTEGER DEFAULT 0;");
            conn:exec("ALTER TABLE drops ADD COLUMN player_action INTEGER DEFAULT 0;");
        end

        if (not drops_has.drop_order) then
            conn:exec("ALTER TABLE drops ADD COLUMN drop_order INTEGER DEFAULT -1;");
        end
end

--- Index replacement (composite subsumes the old single-column index).
function schema.migrate_indexes(conn)
        -- Migration: composite idx_drops_kill_item (subsumes old idx_drops_kill)
        conn:exec("DROP INDEX IF EXISTS idx_drops_kill;");
        conn:exec("CREATE INDEX IF NOT EXISTS idx_drops_kill_item ON drops(kill_id, item_id);");

        -- Migration: kills.zone_id was unindexed despite nearly every stats query filtering on it
        -- (indexes existed on mob_name, timestamp, mob_server_id, source_type, content_type).
        conn:exec("CREATE INDEX IF NOT EXISTS idx_kills_zone ON kills(zone_id);");
end

--- Auxiliary tables added after the original schema. Idempotent.
function schema.create_aux_tables(conn)
        -- Migration: missed_kills table (distant party kills with no mob identity)
        conn:exec([[
            CREATE TABLE IF NOT EXISTS missed_kills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                zone_id INTEGER NOT NULL,
                zone_name TEXT NOT NULL,
                timestamp INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_missed_zone ON missed_kills(zone_id);
        ]]);

        -- Migration: battlefield_sessions table for BCNM tracking
        conn:exec([[
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
        conn:exec([[
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
end

return schema;
