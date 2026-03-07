# LootScope v1.2.1 - Loot Drop Tracker for Ashita v4.3

Loot drop tracker for Ashita v4.3 with statistics, Treasure Hunter monitoring, and a full dashboard UI.

---

## Features

- **Live Feed**: Real-time scrolling table of all loot drops with configurable columns. Tooltips show Mob ID, Vana'diel time, moon phase, and weather. Filterable: hide empty kills or mob gil drops.
- **Statistics**: Per-mob kill counts (nearby + distant), drop rates (nearby rate + combined rate with distant bias), unique items, per-item breakdowns, and per-spawn (Mob ID) breakdown with sortable columns. Two-row grouped filter: Row 1 selects a category (Field, Battlefields, Instances, Chest/Coffer, Voidwatch), Row 2 shows context-sensitive sub-filters (Battlefields: All/BCNM/HTBF; Instances: Dynamis — Ambuscade/Omen/Sortie WIP). Each category has a `(?)` tooltip explaining detection methods and edge cases. Filter combo dropdown below for zone/battlefield selection. The "All" Battlefields view shows battlefield names with both Lv Cap and Difficulty columns, grouping by battlefield + zone + level cap + difficulty.
- **Slot Analysis**: Per-mob drop slot probability analysis. Wilson score 95% confidence intervals, slot count estimation (rate sum, empty kill model fit), items-per-kill distribution with Poisson Binomial expected values, co-occurrence analysis (deviation from independence), shared slot candidate detection (items that never co-occur), and drop arrival order tracking for drop table position inference. Battlefield mode (BCNM/HTBF/All Battlefields) automatically switches to specialized sections: Drop Structure (guaranteed vs variable items, items-per-encounter stats) and Inferred Drop Table (union-find grouping of co-occurrence data into probable slots). All data visible from the first kill — low-sample warnings shown when appropriate, but nothing gated behind minimum kill counts. Tooltips adapt to context (kills/runs, per-kill/per-encounter). Chest/Coffer excluded (independent slot model doesn't apply). Uses same category/zone/mob filter system as Statistics.
- **Two-Tier Distant Kill Tracking**: Per-mob distant kills with drops (flagged `is_distant=1` via 0x00D2) shown as blue `(+N)` with separate combined rate. Zone-level missed kills (msg_id=37, no mob identity) informational count only in DB — not applied to per-mob rates.
- **Treasure Hunter Tracking**: Detects TH procs from action packets and records TH level at time of kill
- **Mob Gil Tracking**: Detects gil dropped by mobs via 0x0029 msg_id=565 (FIFO queue for AoE). Displayed in green with min/max/avg in Statistics. Gil is excluded from item drop rate calculations.
- **Chest/Coffer Tracking**: Full chest and coffer event tracking via 0x002A (unlock/fail), 0x001E (gil inventory diff), and 0x0053 (system message). Four-layer gil detection with dedup. Records gil amount, container type, and failure reason (lockpick fail, trap, mimic, illusion).
- **Vana'diel Time & Moon Phase**: Records Vana'diel weekday, hour, moon phase, and moon percentage at time of each kill
- **Weather Tracking**: Records weather at time of kill via client memory pattern scan (20 weather types)
- **Mob Name Resolution**: Three-tier system: entity memory, DAT file lookup, chat text fallback. Resolves mob names even when out of render range.
- **Mob Spawn ID Tracking**: Each kill records the mob's permanent server ID, enabling per-spawn point drop rate analysis. Gil-only spawns are hidden from the per-spawn breakdown.
- **Source Classification**: Distinguishes drops from mobs, chests, coffers, and BCNM crates using SpawnFlags
- **BCNM Detection**: Captures battlefield name from chat ("Entering the battlefield for X!"), detects level cap via two methods (chat text parsing of "{Name}'s level is currently restricted to {N}" + `GetJobLevel()` vs `GetMainJobLevel()` memory comparison fallback), tracks battlefield sessions in SQLite, and reconnects on addon reload via buff icon 254. Stale sessions auto-cleaned after 4 hours.
- **Content Type Detection**: Classifies endgame content (BCNM, HTBF, Dynamis, Voidwatch). BCNM/HTBF detected via S2C 0x0075 battlefield packet (mode 0x0001 = countdown timer). Dynamis (original + Divergence) detected by zone name prefix — covers all 14 zones without packet dependency. Voidwatch tagged retroactively when Riftworn Pyxis delivers items (does not use persistent content_info — VW occurs in open-world zones). Crash-resilient. Ambuscade, Omen, and Sortie are WIP — more packet research needed.
- **Voidwatch Loot Tracking**: Tracks loot from Riftworn Pyxis after VW NM kills. VW bypasses the treasure pool entirely — items are delivered via S2C 0x034 event params. Up to 8 offered items per Pyxis interaction are recorded as drops. Selection tracking: taken items marked as won, untaken items marked as relinquished. Dedicated Voidwatch statistics category with per-NM/zone grouping.
- **HTBF Difficulty Tracking**: Detects High-Tier Battlefield entry via S2C 0x005C packet (`num[0]==2`). Records difficulty level (VD/D/N/E/VE) and resolves battlefield name from zone dialog DAT files. Separate HTBF tab in Statistics with per-difficulty grouping. Color-coded `[VD]`/`[D]`/`[N]`/`[E]`/`[VE]` badges in Live Feed and Compact mode. Mob kills inside battlefields show `[BCNM]`/`[HTBF]` prefix. Difficulty range guard (1-5) prevents BCNMs from setting false HTBF info.
- **Chest Interaction Pre-identification**: Tracks outgoing C2S 0x1A (Talk/Interact) packets to pre-identify chest/coffer targets before 0x00D2 drops arrive. Improves container name resolution when the entity despawns before drops are processed.
- **Compact Mode**: Minimal overlay with configurable opacity and columns
- **CSV Export**: Export all data or filtered subsets for external analysis
- **Advanced Export**: Filter by source (Field/Chest-Coffer/All BF/BCNM/HTBF/Dynamis), zone, mob, TH level, date range, Vana'diel day/hour/moon/weather, item, status, and more. Source filter uses content_type so mob kills inside BCNMs are correctly grouped with their content. Preview updates automatically as filters change.
- **SQLite Storage**: All data persisted locally for cross-session analysis
- **Configurable Columns**: Choose which columns are visible in Live Feed and Compact mode independently

## Requirements

- Ashita v4.3.0.2 (uses LuaSQLite3, ImGui Tables, bitreader)
	- This release has only been tested with Ashita v4.3.0.2	

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

LootScope passively monitors these packets:

**Incoming (S2C):**
- **0x0028 (Action)**: Parsed via bitreader for Treasure Hunter proc messages (message ID 603) which contain the mob's new TH level.
- **0x0029 (Battle Message)**: Message ID 6 = "X defeats Y" creates kill records (nearby, `is_distant=0`). Message ID 37 = "too far from battle" records zone-level missed kills (informational, no mob identity). Message ID 565 = "obtains X gil" detects mob gil drops (exact amount from Data field at offset 0x0C).
- **0x002A (Message Special)**: Zone-specific message IDs for chest/coffer unlock, lockpick fail, trap, mimic, and illusion. Uses `CHEST_UNLOCKED` base offsets from LSB IDs.lua files.
- **0x001E (Item Quantity Update)**: Primary chest gil detection. Fires when `addGil()` updates the gil inventory slot. Compares snapshot from 0x002A time to new quantity.
- **0x0053 (System Message)**: MsgStd 19 = "Obtains X gil". Secondary chest gil detection (LSB uses `messageSystem(OBTAINS_GIL)` for chest gil distribution).
- **0x005C (GP_SERV_COMMAND_PENDINGNUM)**: HTBF entry detection. 8 x int32 params: `num[0]==2` = HTBF entry, `num[1]` = bit position (battlefield name index), `num[2]` = difficulty (1=VD, 2=D, 3=N, 4=E, 5=VE). Difficulty range guard rejects values outside 1-5 (BCNMs send 0). Battlefield name resolved from zone dialog DAT files.
- **0x0075 (GP_SERV_COMMAND_BATTLEFIELD)**: Content type detection. Mode field at offset 0x04 (uint16 LE): 0x0001=countdown timer (all battlefields), 0xFFFF=progress bars, 0x1000=scoreboard. Currently maps 0x0001 to BCNM (HTBF distinguished by bf_difficulty). NOT sent for original Dynamis. Dynamis detected by zone name prefix. Ambuscade/Omen/Sortie detection via this packet is WIP — more packet research needed.
- **0x0034 (GP_SERV_COMMAND_EVENTNUM)**: NPC event begin. Used for Voidwatch Riftworn Pyxis loot detection. Params[0-7] (int32) contain offered item IDs when interacting with a Pyxis. First event records all offered items; subsequent events detect which items were taken (param zeroed out) vs relinquished.
- **0x001F (GP_SERV_COMMAND_ITEM_LIST)**: Inventory item assign. Used for Voidwatch stackable item delivery (materials, seals). ItemNo at offset 0x08 (uint16). Matched against offered Pyxis items.
- **0x0020 (GP_SERV_COMMAND_ITEM_ATTR)**: Item full info with augments. Used for Voidwatch equipment/augmented item delivery. ItemNo at offset 0x0C (uint16). Matched against offered Pyxis items.
- **0x00D2 (Treasure Pool Item)**: Fired when a drop appears in the treasure pool. Contains item ID, quantity, mob server ID, and pool slot. Sent to ALL party members regardless of distance.
- **0x00D3 (Lot Result)**: Fired when a lot is resolved. Contains pool slot, winner name, lot value, and win/loss/error flag.

**Outgoing (C2S):**
- **0x1A (GP_CLI_COMMAND_ACTION)**: Tracks NPC interactions (ActionID=0x00 = Talk/Interact). Pre-identifies chest/coffer targets before 0x00D2 drops arrive. Also detects Voidwatch context when interacting with Riftworn Pyxis entities.
- **0x5B (GP_CLI_COMMAND_EVENTEND)**: Event end. Used for Voidwatch Pyxis finalization. EndPara values: 1-8 = item selection, 9 = exit/leave, 10 = obtain all. EndPara=9 marks remaining items as relinquished (won=-1). EndPara=10 marks remaining items as obtained (won=1). Fires before delivery packets (0x01F/0x020), so won status must be set here.

### Ashita SDK API

Beyond packet capture, LootScope uses these Ashita SDK interfaces for client-side data:

| Interface | Methods Used | Purpose |
|-----------|-------------|---------|
| **IEntity** | `GetName(idx)`, `GetSpawnFlags(idx)`, `GetLocalPositionX/Y(idx)` | Mob name resolution (primary), source classification (Monster vs Object flags), entity scanning for nearby containers |
| **IInventory** | `GetTreasurePoolItem(slot)`, `GetTreasurePoolStatus()`, `GetContainerItem(bag, slot)` | Pool scanning on addon reload/late join, pool active check, gil snapshot before/after chest opens |
| **IParty** | `GetMemberZone(0)` | Zone detection, character login gate (`zone > 0` = in-game) |
| **IPlayer** | `GetMainJob()`, `GetMainJobLevel()`, `GetJobLevel(id)`, `GetBuffs()` | BCNM level cap detection (`GetMainJobLevel()` capped vs `GetJobLevel()` uncapped), battlefield reconnect (buff ID 71/73), Voidwatch kill tagging (buff ID 475) |
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
8. Voidwatch: Kill tagged as Voidwatch at defeat time via Voidwatcher buff (ID 475). Riftworn Pyxis interaction triggers 0x034 event with offered items. Three-layer selection tracking: (1) subsequent 0x034 param zeroing, (2) 0x01F stackable item delivery, (3) 0x020 equipment item delivery. Three-layer finalization: (1) C2S 0x05B EventEnd, (2) buff loss poll, (3) zone change.
9. Zone changes mark any pending pool items as Zoned and clear in-memory tracking
10. Distant kills detected via msg_id=37 are counted for drop rate adjustment (see below)

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
| BCNM | 3 | SpawnFlags `0x0020` (Object) + name contains chest entity name or "Sturdy Pyxis" |

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
- **Advanced Export**: Filter window with auto-updating preview. Source filter: All, Field, Chest/Coffer, All BF, BCNM, HTBF, Dynamis (uses content_type so mob kills inside instances are grouped correctly). Additional filters: zone, mob name, TH level, date range, Vana'diel time, moon phase, weather, item, status, winner, and more. Discrete filter changes (dropdowns, sliders) update instantly; text inputs debounce for 0.5 seconds.

## File Structure

```
lootscope/
  lootscope.lua   -- Main addon: metadata, events, commands, CSV export
  db.lua          -- SQLite schema, migrations, queries, dirty-flag caching, transaction batching
  tracker.lua     -- Packet parsing (0x0028/0x0029/0x002A/0x001E/0x001F/0x0020/0x0053/0x005B/0x005C/0x0075/0x0034/0x00D2/0x00D3), content detection, weather scan, DAT lookup, credit system, drop order tracking, Voidwatch Pyxis loot + buff detection
  analysis.lua    -- Statistical engine: Wilson CI, Poisson Binomial, co-occurrence, shared slot detection, battlefield drop structure, union-find inferred slots
  datreader.lua   -- Zone dialog DAT reader: d_msg/event_msg parsing for HTBF battlefield name resolution
  ui.lua          -- ImGui dashboard with tabs, compact mode, advanced export, nearby/combined rates, slot analysis (field + battlefield modes)
```

## Data Storage

Each character gets their own isolated database file, stored at `config/addons/lootscope/<CharName>_<ServerId>/lootscope.db` (SQLite with WAL mode). This matches Ashita's settings folder convention so the DB and settings live in the same folder. Prevents write contention when multi-boxing and keeps data separated across characters and servers.

Database initialization is deferred until the character is fully logged in.

### Tables

**kills**: One row per mob killed (or chest/coffer opened)
- `mob_name`, `mob_server_id`, `zone_id`, `zone_name`, `th_level`, `source_type`, `killer_id`, `killer_name`, `th_action_type`, `th_action_id`, `vana_weekday`, `vana_hour`, `moon_phase`, `moon_percent`, `weather`, `battlefield`, `level_cap`, `is_distant` (0=nearby, 1=distant kill with drops), `timestamp`

**drops**: One row per item that appeared in the treasure pool (or mob gil drop)
- `kill_id` (FK to kills), `pool_slot` (internal slot index used for lot matching; -1 for mob gil), `item_id` (65535 for gil), `item_name`, `quantity`, `won`, `lot_value`, `winner_id`, `winner_name`, `player_lot`, `player_action`, `drop_order` (arrival sequence per kill, -1 for pre-v1.1.1 data), `timestamp`

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
9. **Drop order**: Added `drop_order` (INTEGER, default -1) to drops — tracks arrival sequence per kill for slot analysis ordering queries. Legacy rows excluded via `drop_order >= 0` filter.

Old databases are upgraded transparently. Missing values default to -1 (time/weather/drop_order) or 0 (IDs).

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
- **DAT loading**: Zone entity names loaded once per zone change, not per-frame.
- **HTBF DAT cache**: Zone dialog DATs are read once per zone and cached for battlefield name resolution.

## Database Schema

### kills table (new columns in v1.1.0)

| Column | Type | Default | Description |
|--------|------|---------|-------------|
| bf_name | TEXT | '' | HTBF battlefield name (resolved from zone dialog DAT) |
| bf_difficulty | INTEGER | 0 | HTBF difficulty: 0=none, 1=VD, 2=D, 3=N, 4=E, 5=VE |

These columns are added via automatic schema migration when loading the addon with an existing database.

## Version History

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

## Slot Analysis Methodology

See [SLOT_ANALYSIS.md](SLOT_ANALYSIS.md) for the statistical methodology behind the Slot Analysis tab — model assumptions, method choices, and alternatives considered.

## Thanks

- **Thorny** - Slot Analysis concept, drop order tracking idea, outgoing 0x1A chest pre-identification approach, and ongoing feedback
- **Chihiro** - HTBF difficulty and VW tracking suggestion
- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
