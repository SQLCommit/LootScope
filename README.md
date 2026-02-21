# LootScope v1.0.0 - Loot Drop Tracker for Ashita v4.30

Loot drop tracker for Ashita v4.30 with statistics, Treasure Hunter monitoring, and a full dashboard UI.

---

## Features

- **Live Feed**: Real-time scrolling table of all loot drops with configurable columns. Tooltips show Mob ID, Vana'diel time, moon phase, and weather. Filterable: hide empty kills or mob gil drops.
- **Statistics**: Per-mob kill counts (nearby + distant), drop rates (nearby rate + combined rate with distant bias), unique items, per-item breakdowns, and per-spawn (Mob ID) breakdown with sortable columns. Source-type radio buttons (Mob, BCNM, Chest/Coffer) filter by kill source, each with a `(?)` tooltip explaining edge cases. Context-sensitive dropdown: zones for Mobs, battlefield names for BCNMs, entity names for Chests/Coffers.
- **Two-Tier Distant Kill Tracking**: Per-mob distant kills with drops (flagged `is_distant=1` via 0x00D2) shown as blue `(+N)` with separate combined rate. Zone-level missed kills (msg_id=37, no mob identity) informational count only in DB — not applied to per-mob rates.
- **Treasure Hunter Tracking**: Detects TH procs from action packets and records TH level at time of kill
- **Mob Gil Tracking**: Detects gil dropped by mobs via 0x0029 msg_id=565 (FIFO queue for AoE). Displayed in green with min/max/avg in Statistics. Gil is excluded from item drop rate calculations.
- **Chest/Coffer Tracking**: Full chest and coffer event tracking via 0x002A (unlock/fail), 0x001E (gil inventory diff), and 0x0053 (system message). Four-layer gil detection with dedup. Records gil amount, container type, and failure reason (lockpick fail, trap, mimic, illusion).
- **Vana'diel Time & Moon Phase**: Records Vana'diel weekday, hour, moon phase, and moon percentage at time of each kill
- **Weather Tracking**: Records weather at time of kill via client memory pattern scan (20 weather types)
- **Mob Name Resolution**: Three-tier system: entity memory, DAT file lookup, chat text fallback. Resolves mob names even when out of render range.
- **Mob Spawn ID Tracking**: Each kill records the mob's permanent server ID, enabling per-spawn point drop rate analysis. Gil-only spawns are hidden from the per-spawn breakdown.
- **Source Classification**: Distinguishes drops from mobs, chests, coffers, and BCNM crates using SpawnFlags
- **BCNM Detection**: Captures battlefield name from chat ("Entering the battlefield for X!"), detects level cap, tracks battlefield sessions in SQLite, and reconnects on addon reload via buff icon 254. Stale sessions auto-cleaned after 4 hours.
- **Compact Mode**: Minimal overlay with configurable opacity and columns
- **CSV Export**: Export all data or filtered subsets for external analysis
- **Advanced Export**: Filter by zone, mob, TH level, date range, Vana'diel day/hour/moon/weather, item, status, and more. Preview updates automatically as filters change.
- **SQLite Storage**: All data persisted locally for cross-session analysis
- **Configurable Columns**: Choose which columns are visible in Live Feed and Compact mode independently

## Requirements

- Ashita v4.30 (uses LuaSQLite3, ImGui Tables, bitreader)
	- This release has only been tested with Ashita v4.30

## Installation

1. Copy the `lootscope` folder to your Ashita `addons` directory
2. Load with `/addon load lootscope`

## Commands

| Command | Description |
|---------|-------------|
| `/loot` or `/lootscope` | Toggle the LootScope window |
| `/loot show` | Show the window |
| `/loot hide` | Hide the window |
| `/loot compact` | Toggle compact mode |
| `/loot resetui` | Reset window size and position |
| `/loot stats [mob]` | Print drop stats to chat window (nearby + combined rates) |
| `/loot help` | Show available commands |

## How It Works

### Packet Capture

LootScope passively monitors these incoming packets:

- **0x0028 (Action)**: Parsed via bitreader for Treasure Hunter proc messages (message ID 603) which contain the mob's new TH level.
- **0x0029 (Battle Message)**: Message ID 6 = "X defeats Y" creates kill records (nearby, `is_distant=0`). Message ID 37 = "too far from battle" records zone-level missed kills (informational, no mob identity). Message ID 565 = "obtains X gil" detects mob gil drops (exact amount from Data field at offset 0x0C).
- **0x002A (Message Special)**: Zone-specific message IDs for chest/coffer unlock, lockpick fail, trap, mimic, and illusion. Uses `CHEST_UNLOCKED` base offsets from LSB IDs.lua files.
- **0x001E (Item Quantity Update)**: Primary chest gil detection. Fires when `addGil()` updates the gil inventory slot. Compares snapshot from 0x002A time to new quantity.
- **0x0053 (System Message)**: MsgStd 19 = "Obtains X gil". Secondary chest gil detection (LSB uses `messageSystem(OBTAINS_GIL)` for chest gil distribution).
- **0x00D2 (Treasure Pool Item)**: Fired when a drop appears in the treasure pool. Contains item ID, quantity, mob server ID, and pool slot. Sent to ALL party members regardless of distance.
- **0x00D3 (Lot Result)**: Fired when a lot is resolved. Contains pool slot, winner name, lot value, and win/loss/error flag.

### Ashita SDK API

Beyond packet capture, LootScope uses these Ashita SDK interfaces for client-side data:

| Interface | Methods Used | Purpose |
|-----------|-------------|---------|
| **IEntity** | `GetName(idx)`, `GetSpawnFlags(idx)`, `GetLocalPositionX/Y(idx)` | Mob name resolution (primary), source classification (Monster vs Object flags), entity scanning for nearby containers |
| **IInventory** | `GetTreasurePoolItem(slot)`, `GetTreasurePoolStatus()`, `GetContainerItem(bag, slot)` | Pool scanning on addon reload/late join, pool active check, gil snapshot before/after chest opens |
| **IParty** | `GetMemberZone(0)` | Zone detection, character login gate (`zone > 0` = in-game) |
| **IPlayer** | `GetMainJobLevel()`, `GetBuffs()` | BCNM level cap detection, battlefield reconnect (buff ID 71/73) |
| **ITarget** | `GetTargetIndex(0)` | Container detection — checks if player is targeting a chest/coffer |
| **IResourceManager** | `GetItemById(id)`, `GetString('zones.names', id)` | Item name resolution from pool data, zone name lookup |
| **GetPlayerEntity()** | `.ServerId` | Character identity for per-character database selection |
| **AshitaCore** | `GetInstallPath()`, `GetMemoryManager()`, `GetResourceManager()` | File paths, access to memory interfaces above |

**One raw memory access**: Weather is read via `ashita.memory.find('FFXiMain.dll', ...)` pattern scan because no SDK API exposes weather data. See [Weather Tracking](#weather-tracking) below.

### Data Flow

1. During combat, 0x0028 action packets track TH procs per mob
2. Mob dies -> 0x0029 msg_id=6 creates a "kill" record with accumulated TH level, Vana'diel time, and weather
3. If the mob dropped gil, 0x0029 msg_id=565 arrives with the exact amount (FIFO queue handles AoE)
4. 0x00D2 packets arrive for each item drop, linking to the existing kill record via mob server ID
5. Containers/chests that don't send 0x0029 get kill records created on first 0x00D2
6. Chest/coffer interactions: 0x002A detects unlock/fail -> 0x001E or 0x0053 captures gil amount
7. When lots resolve, 0x00D3 updates the drop's status (Got/Full/Lost) with winner info
8. Zone changes mark any pending pool items as Zoned and clear in-memory tracking
9. Distant kills detected via msg_id=37 are counted for drop rate adjustment (see below)

### Mob Name Resolution

LootScope uses a three-tier name resolution chain:

1. **Entity Memory** (primary): `GetEntity():GetName(target_index)` -- works when mob is in client render range
2. **DAT File Lookup** (fallback): Loads mob names from FFXI's DAT files per zone. Format is 32-byte entries (28 bytes name + 4 bytes ID). Target index extracted via `bit.band(id, 0x0FFF)`. Validated against atom0s's [watchdog](https://github.com/AshitaXI/Ashita-v4beta/tree/main/addons/watchdog) addon which uses the identical approach.
3. **Chat Text Fallback**: Parses "X defeats the MobName." and "You find [item] on the MobName." messages. Queue-based with FIFO ordering and per-kill expected message counts.

If all three fail, the kill is recorded as "Unknown" and retroactively updated if a chat message arrives within 30 seconds.

### Source Classification

Source type is determined using entity SpawnFlags from client memory:

| Type | Value | Detection |
|------|-------|-----------|
| Mob | 0 | SpawnFlags `0x0010` (Monster), or default when is_container=0 |
| Chest | 1 | SpawnFlags `0x0020` (Object) + generic name |
| Coffer | 2 | SpawnFlags `0x0020` (Object) + name contains "Coffer" |
| BCNM | 3 | SpawnFlags `0x0020` (Object) + name contains "Armoury Crate" or "Sturdy Pyxis" |

Falls back to name-based classification if SpawnFlags are unavailable.

### Weather Tracking

Weather is read from client memory using a pattern scan:
- Pattern: `66A1????????663D????72` in FFXiMain.dll
- Read pointer at scan address + 0x02 (absolute pointer to weather byte)
- Values 0-19: Clear, Sunny, Cloudy, Fog, Hot Spell, Heat Wave, Rain, Squall, Dust Storm, Sand Storm, Wind, Gales, Snow, Blizzard, Thunder, Thunderstorm, Auroras, Stellar Glare, Gloom, Darkness
- Initialized once on character login, pcall-wrapped for safety

## The Distant Kill Problem

### The Problem

When farming mobs in a party, the player tracking loot may be far from where kills happen.
This means **distant kills that produce no drops are invisible** to the tracking player. The kill count denominator is undercounted, inflating apparent drop rates.

**Example**: A party kills 9 Nightmare Weapons. The tracker sees 3 kills with drops and 6 "too far" messages. Without correction: 3 drops / 3 kills = 100%. With correction: 3 drops / 9 kills = 33%.

### The Solution: Two-Tier Distant Kill Tracking

LootScope uses a **two-tier system** to handle distant kills accurately:

**Tier 1 — Per-mob distant kills WITH drops** (`is_distant=1` in kills table):
When 0x00D2 creates a kill record WITHOUT a prior defeat message (msg_id=6), it's a distant kill that produced drops. These are flagged with `is_distant=1` and attributed to the specific mob (because 0x00D2 contains the mob's entity data). However, these kills are a **biased sample** — you only see them *because* they dropped loot. Mixing them into the main rate would inflate it upward.

**Tier 2 — Zone-level missed kills WITHOUT drops** (`missed_kills` table):
When msg_id=37 fires with no matching credit, it's a distant kill that produced no drops. These can only be counted per-zone. They are **informational only** and are NOT applied to any mob's rate calculation.

**Credit/debit system** (prevents double-counting):
1. When 0x00D2 creates a new kill record WITHOUT a prior defeat message (msg_id=6), it's a distant kill with drops. **Grant 1 credit** (`tracker.distant_kill_credits++`).
2. When msg_id=37 arrives: if credits > 0, **consume 1 credit** (this kill was already tracked via 0x00D2). If credits = 0, **record as missed kill** in the `missed_kills` database table.
3. Credits reset on zone change.

**Why the math works regardless of packet ordering**: The server processes mob death in order: `DropItems()` (sends 0x00D2) then `DistributeExperiencePoints()` (sends msg_id=37). Even if packets arrive interleaved for multiple simultaneous kills, the NET credit balance always equals the correct count because every distant-kill-with-drops produces exactly one 0x00D2 and one msg_id=37.

**Drop rate formulas:**
```
nearby_kills = total_kills - distant_kills
nearby_rate = nearby_drops / nearby_kills * 100      (unbiased — main rate, white text)
combined_rate = all_drops / total_kills * 100         (biased — includes distant, blue text)
```

The **nearby rate** is the primary statistic — it only counts kills where you witnessed the defeat (msg_id=6), giving an unbiased sample. The **combined rate** includes distant-with-drops kills for reference, but is biased upward because distant kills without drops are invisible at the per-mob level.

**Why the selection bias matters**: Imagine 100 distant kills. 30 drop loot (visible via 0x00D2), 70 drop nothing (invisible per-mob). If you count all 30 as kills, the rate looks like 30/30 = 100%. The combined rate (30/30) is better than nothing but still inflated. Only the nearby rate from witnessed kills is truly unbiased.

### How It Looks in the UI

- **Toolbar**: `[CHAR] 10 kills | 3 drops | 6 missed`
- **Statistics kill count**: `7` with blue `(+3)` annotation showing per-mob distant kills with drops. Tooltip explains the biased sample.
- **Per-item drop rate**: `28.6%` (nearby: 2/7) with blue `(20.0%)` combined rate (2/10). Tooltip: "Nearby: 2/7 = 28.6%, Combined: 2/10 = 20.0%. Includes 3 distant kill(s) with drops."
- **Chat command**: `/loot stats Nightmare Weapon` shows `7 nearby + 3 distant = 10 kills` and `28.6% | combined: 20.0%` per item
- **Zone missed kills**: Informational count in the DB, not applied to any mob's rate

## Other Edge Cases

### Addon Reload Mid-Treasure Pool

If LootScope is reloaded while items are still in the treasure pool, `scan_pool()` reads the client's active pool slots and attempts to reconnect each item with its existing database record via `find_pending_drop()`. Successfully reconnected items continue tracking normally with no impact on Statistics. Items that can't be matched (e.g., the original kill record was from a previous addon session) are created as `late_join` stubs -- they appear in Live Feed but do not create new kill or drop records, so Statistics are not inflated.

### Late Loot (Zoning In After a Kill)

When a player zones into an area where party members have active loot pools, the client receives 0x00D2 packets with `is_old=1` (pool refresh). LootScope handles these the same way as addon reload: it first tries to reconnect with existing database records, and falls back to `late_join` stubs if no match is found. Late-join items are visible in Live Feed but do not affect Statistics kill counts or drop rates.

## Vana'diel Time Data

Each kill records the current Vana'diel game state:

| Field | Values | Description |
|-------|--------|-------------|
| `vana_weekday` | 0-7 | Firesday(0), Earthsday(1), Watersday(2), Windsday(3), Iceday(4), Lightningday(5), Lightsday(6), Darksday(7) |
| `vana_hour` | 0-23 | Vana'diel hour at time of kill |
| `moon_phase` | 0-11 | New Moon(0) through Waning Crescent(11), 12 segments of the 84-day cycle |
| `moon_percent` | 0-100 | Moon illumination percentage |
| `weather` | 0-19 | Clear(0) through Darkness(19), read from client memory |

This data is visible in Live Feed columns (or tooltips when hovering the time column) and included in CSV exports. A value of -1 indicates the data was not available (e.g. kills recorded before the feature was added, or memory scan failure).

## Multi-Boxing / Multi-Server

LootScope is fully safe for multi-boxing. Each Ashita instance detects the logged-in character name and opens a separate database. Two characters farming simultaneously will never conflict, even if using the same Ashita directory.

Different private servers with the same character name will also get separate databases (server ID is included in the folder path).

## Export

CSV export path: `config/addons/lootscope/exports/lootscope_<CharName>_YYYYMMDD_HHMMSS.csv`

Export options:
- **Export All**: Exports every kill and drop to CSV (available from the Export tab)
- **Advanced Export**: Filter window with auto-updating preview. Narrow down by zone, mob name, TH level, date range, Vana'diel time, moon phase, weather, item, status, winner, and more. Discrete filter changes (dropdowns, sliders) update instantly; text inputs debounce for 0.5 seconds.

## File Structure

```
lootscope/
  lootscope.lua   -- Main addon: metadata, events, commands, CSV export
  db.lua          -- SQLite schema, migrations, queries, dirty-flag caching, transaction batching
  tracker.lua     -- Packet parsing (0x0028/0x0029/0x002A/0x001E/0x0053/0x00D2/0x00D3), weather scan, DAT lookup, credit system
  ui.lua          -- ImGui dashboard with tabs, compact mode, advanced export, nearby/combined rates
```

## Data Storage

Each character gets their own isolated database file, stored at `config/addons/lootscope/<CharName>_<ServerId>/lootscope.db` (SQLite with WAL mode). This matches Ashita's settings folder convention so the DB and settings live in the same folder. Prevents write contention when multi-boxing and keeps data separated across characters and servers.

Database initialization is deferred until the character is fully logged in.

### Tables

**kills**: One row per mob killed (or chest/coffer opened)
- `mob_name`, `mob_server_id`, `zone_id`, `zone_name`, `th_level`, `source_type`, `killer_id`, `killer_name`, `th_action_type`, `th_action_id`, `vana_weekday`, `vana_hour`, `moon_phase`, `moon_percent`, `weather`, `battlefield`, `level_cap`, `is_distant` (0=nearby, 1=distant kill with drops), `timestamp`

**drops**: One row per item that appeared in the treasure pool (or mob gil drop)
- `kill_id` (FK to kills), `pool_slot` (internal slot index used for lot matching; -1 for mob gil), `item_id` (65535 for gil), `item_name`, `quantity`, `won`, `lot_value`, `winner_id`, `winner_name`, `player_lot`, `player_action`, `timestamp`

**missed_kills**: One row per distant party kill with no mob identity and no drops (msg_id=37 with no matching credit). Informational only — not used in per-mob rate calculations.
- `zone_id`, `zone_name`, `timestamp`

**chest_events**: One row per chest/coffer interaction (gil or failure)
- `zone_id`, `zone_name`, `container_type` (1=chest, 2=coffer), `result` (0=gil, 1-4=failures), `gil_amount`, `vana_weekday`, `vana_hour`, `moon_phase`, `moon_percent`, `weather`, `timestamp`

**battlefield_sessions**: One row per BCNM entry (for reconnect on addon reload)
- `battlefield_name`, `zone_id`, `zone_name`, `level_cap`, `entered_at`, `exited_at`
- Stale sessions (older than 4 hours with no exit) are auto-cleaned on addon load

### Migrations

The database schema evolves automatically. Each migration checks for missing columns/tables before applying:

1. **Vana'diel time**: Added `vana_weekday`, `vana_hour`, `moon_phase`, `moon_percent` to kills
2. **Killer info**: Added `killer_id`, `th_action_type`, `th_action_id` to kills
3. **Winner info**: Added `winner_id`, `winner_name`, `player_lot`, `player_action` to drops
4. **Weather**: Added `weather` to kills
5. **Missed kills**: Created `missed_kills` table with zone index
6. **Distant flag**: Added `is_distant` (INTEGER, default 0) to kills — flags kills created from 0x00D2 without prior defeat
7. **Battlefield**: Added `battlefield` (TEXT) and `level_cap` (INTEGER) to kills
7. **Battlefield sessions**: Created `battlefield_sessions` table for BCNM reconnect tracking
8. **Chest events**: Created `chest_events` table for chest/coffer gil and failure tracking
Old databases are upgraded transparently. Missing values default to -1 (time/weather) or 0 (IDs).

## Settings

Settings are saved per-character via Ashita's settings library.

### Columns
- Independent column visibility for Live Feed and Compact mode
- Available columns: Time, Mob, Zone, Source, Item, Qty, TH, Status, Lot, Winner, Vana Day, Vana Hour, Moon Phase, Moon %, Weather, Kill ID, Mob ID

### Live Feed
- Maximum feed entries (default 100)
- Show/hide empty kills (mobs with no drops)
- Show/hide mob gil drops (reduce noise when farming for items)

### Compact Mode
- Background opacity (0-100%)
- Show/hide title bar

### Startup
- Open window when addon loads

### Actions
- Export all data to CSV
- Clear all tracked data (requires CONFIRM typed confirmation)

## Technical Notes

### Performance
- **Dirty-flag caching**: All database queries are cached and only re-executed when data changes. The UI never hits SQLite on frames where nothing changed.
- **Transaction batching**: Writes are batched into transactions (flush every 1s or 20 operations) to amortize fsync overhead during burst kills.
- **Running counters**: Kill/drop/missed counts use O(1) in-memory counters instead of COUNT(*) scans.
- **Streamed export**: CSV export processes one kill at a time (constant memory) instead of loading the entire database.
- **Zone-cached missed kills**: `get_missed_kills_for_zone()` caches per zone ID, only requeried on mutation. Used for informational display only (not in rate calculations).
- **DAT loading**: Zone entity names loaded once per zone change, not per-frame.

## Version History

### v1.0.0
- Initial release
- **Live Feed** with configurable columns, row tooltips (mob ID, Vana'diel time, moon, weather), and color-coded rows by source type
- **Statistics** tab with nested mob/item/per-spawn tree, sortable columns, per-spawn item breakdowns, and source-type radio buttons (Mob, BCNM, Chest/Coffer) with `(?)` tooltips
- **Treasure Hunter** tracking via 0x0028 action packet parsing with TH action type/ID recording
- **Mob gil tracking** via 0x0029 msg_id=565 with FIFO queue for AoE kills. Gil displayed in green with min/max/avg amounts. Excluded from item drop rate calculations. Gil-only spawns hidden from per-spawn breakdown.
- **Chest/Coffer tracking**: Full event tracking via 0x002A (unlock/fail), 0x001E (gil inventory diff), and 0x0053 (system message). Four-layer gil detection with dedup. Records gil amount, container type, and failure reason (lockpick fail, trap, mimic, illusion).
- **BCNM battlefield detection**: Captures name from chat, detects level cap, persists sessions to SQLite, reconnects on reload via buff icon 254. Stale sessions auto-cleaned after 4 hours.
- **Vana'diel time** recording: weekday, hour, moon phase, and moon percentage per kill
- **Weather tracking** via client memory pattern scan (20 weather types)
- **Three-tier mob name resolution**: entity memory -> DAT file lookup -> chat text fallback
- **Two-tier distant kill tracking**: per-mob `is_distant` flag for kills with drops + zone-level missed kills (informational) via credit/debit system
- **SpawnFlags-based source classification** (Mob, Chest, Coffer, BCNM)
- **TreasurePoolStatus guard** for safe pool scanning on addon reload
- **Mob server ID tracking** for per-spawn analysis with unique spawn count
- **Lot result tracking**: winner name/ID, player lot value, player action (lot/pass), color-coded status (Got/Full/Lost/Zoned/Pending)
- **Compact mode** with independent column settings, optional title bar, and background opacity slider
- **Full CSV export** with streamed writes for large datasets
- **Advanced Export** with 14+ filter dimensions: zone, source type, TH level, mob spawn ID, date range, Vana'diel weekday, hour range (wrap-around), moon phase range, weather, item name/ID, winner name/ID, player action, status, empty kills toggle
- **Live export preview** with auto-update on discrete changes and debounced text input (0.5s)
- **Settings**: Live Feed max entries, show/hide empty kills, show/hide mob gil drops, compact background opacity, compact title bar toggle, column visibility popups
- **Commands**: `/loot` toggle, `/loot compact`, `/loot resetui`, `/loot stats [mob]`, `/loot help`
- **Reset confirmation** dialog requiring "CONFIRM" text input (3-step process)
- **SQLite storage** with WAL mode, dirty-flag caching, and 8-step migration chain
- **Per-character database** isolation (multi-box safe)
- **Transaction batching** for write performance
- **pcall safety** around all packet parsing, memory reads, and database operations
- **Pool reconnection** on addon reload
- **Thousand separators** in count displays, database file size display in export tab

## Thanks

- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
