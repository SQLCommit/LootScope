# LootScope v1.4.2 - Loot Drop Tracker for Ashita v4.3

Loot drop tracker for Ashita v4.3 with statistics, Treasure Hunter monitoring, and a full dashboard UI.

---

## Features

- **Live Feed**: Real-time scrolling table of all loot drops with configurable columns. Tooltips show Mob ID, Vana'diel time, moon phase, and weather. Filterable: hide empty kills or mob gil drops.
- **Statistics**: Per-mob kill counts (nearby + distant), drop rates (nearby rate + combined rate with distant bias), unique items, per-item breakdowns, and per-spawn (Mob ID) breakdown with sortable columns. Two-row grouped filter: Row 1 selects a category (Field, Battlefields, Instances, Events, Chest/Coffer), Row 2 shows context-sensitive sub-filters (Battlefields: All/BCNM/HTBF; Instances: 14-type combo dropdown; Events: Voidwatch/Domain Invasion/Wildskeeper). Each category has a `(?)` tooltip explaining detection methods. Filter combo dropdown below for zone/battlefield selection. The "All" Battlefields view shows battlefield names with both Lv Cap and Difficulty columns, grouping by battlefield + zone + level cap + difficulty. Instance content types: Dynamis, Omen, Einherjar, Nyzul, Salvage, Limbus, Sortie, Vagary, Legion, Assault, Walk of Echoes, Skirmish, Meeble Burrows, Odyssey.
- **Slot Analysis**: Per-mob drop slot probability analysis. Wilson score 95% confidence intervals, slot count estimation (rate sum, empty kill model fit), items-per-kill distribution with Poisson Binomial expected values, co-occurrence analysis (deviation from independence), shared slot candidate detection (items that never co-occur), and drop arrival order tracking for drop table position inference. Battlefield mode (BCNM/HTBF/All Battlefields) automatically switches to specialized sections: Drop Structure (guaranteed vs variable items, items-per-encounter stats) and Inferred Drop Table (union-find grouping of co-occurrence data into probable slots). All data visible from the first kill — low-sample warnings shown when appropriate, but nothing gated behind minimum kill counts. Tooltips adapt to context (kills/runs, per-kill/per-encounter). Chest/Coffer excluded (independent slot model doesn't apply). Uses same category/zone/mob filter system as Statistics.
- **Treasure Hunter Tracking**: Detects TH procs from action packets and records TH level at time of kill. Gear-based TH estimation scans equipped items on every offensive action (handles mid-fight gear swaps). Two-layer detection: intrinsic TH from profile gear list + augmented TH parsed from item augment data. Configurable profiles for retail vs private server TH gear and job traits. THF, BLU spell-set trait, trust/pet TH+1, and Treasure Hound kupower all supported. TH Management window for full profile/item/trait CRUD.
- **Chest/Coffer Tracking**: Full chest and coffer event tracking via 0x002A (unlock/fail), 0x001E (gil inventory diff), and 0x0053 (system message). Four-layer gil detection with dedup. Records gil amount, container type, and failure reason (lockpick fail, trap, mimic, illusion).
- **BCNM Detection**: Captures battlefield name from chat ("Entering the battlefield for X!"), detects level cap via two methods (chat text parsing of "{Name}'s level is currently restricted to {N}" + `GetJobLevel()` vs `GetMainJobLevel()` memory comparison fallback), tracks battlefield sessions in SQLite, and reconnects on addon reload via buff icon 254. Stale sessions auto-cleaned after 4 hours.
- **Content Type Detection**: Classifies 21 content types. BCNM/HTBF via 0x0075 packet + chat detection. Dynamis via zone name prefix (14 zones). Voidwatch/Domain Invasion/Wildskeeper via buff detection at kill time. 14 instance types (Omen, Einherjar, Nyzul, Salvage, Limbus, Sortie, Vagary, Legion, Assault, Walk of Echoes, Skirmish, Meeble Burrows, Ambuscade) via zone ID lookup. Odyssey via source-zone tracking (Rabao entry). Walk of Echoes HTBFs (Odin/Cait Sith/Alexander/Lilith) via pending state that survives zone change from Selbina. Content type backfill migration retroactively tags old kills on DB open.
- **Compact Mode**: Minimal overlay with configurable opacity and columns
- **CSV Export**: Export all data or filtered subsets for external analysis
- **Advanced Export**: Filter by source (Field/Chest-Coffer/All BF/BCNM/HTBF/Dynamis/Voidwatch/Domain Invasion/Wildskeeper), zone, mob, TH level, date range, Vana'diel day/hour/moon/weather, item, status, and more. Source filter uses content_type so mob kills inside BCNMs are correctly grouped with their content. Preview updates automatically as filters change.
- **SQLite Storage**: All data persisted locally for cross-session analysis

## Requirements

- This release has only been tested with Ashita v4.3.1.2	

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
| `/loot thaugs` | Dump augment IDs from all equipped gear (debug) |
| `/loot bluspells` | Check BLU TH trait spell status - shows if required spells are set (debug) |
| `/loot help` | Show available commands |

### Data Flow

1. During combat, 0x0028 action packets track TH procs per mob and mark mobs the player has personally attacked (`engaged_mobs`)
2. Mob dies -> 0x0029 msg_id=6 is validated through a 3-tier kill attribution filter before recording: (1) player personally attacked the mob, (2) a party/alliance member or their pet landed the killing blow, or (3) Domain Invasion bypass (Elvorseal buff active in an Escha zone). Kills that don't match any tier are discarded. Entity index range guard also rejects trusts and PCs (index >= 1024) — only NPC/mob entities are recorded.
3. If the mob dropped gil, 0x0029 msg_id=565 arrives with the exact amount (FIFO queue handles AoE)
4. 0x00D2 packets arrive for each item drop, linking to the existing kill record via mob server ID
5. Containers/chests that don't send 0x0029 get kill records created on first 0x00D2
6. Chest/coffer interactions: 0x002A detects unlock/fail -> 0x001E or 0x0053 captures gil amount
7. When lots resolve, 0x00D3 updates the drop's status (Got/Full/Lost) with winner info
8. Voidwatch: Kill tagged as Voidwatch at defeat time via Voidwatcher buff (ID 475). Riftworn Pyxis interaction triggers 0x034 event with offered items. Three-layer selection tracking: (1) subsequent 0x034 param zeroing, (2) 0x01F stackable item delivery, (3) 0x020 equipment item delivery. Three-layer finalization: (1) C2S 0x05B EventEnd, (2) buff loss poll, (3) zone change.
9. Wildskeeper Reive: Kill tagged as Wildskeeper when Reive Mark buff (511) active + Naakual name match. Items delivered via 0x034 Event 2007 with item IDs in params[1-3]. All auto-obtained (won=1). Addon reload recovery via DB query for recent Wildskeeper kill in zone.
10. Zone changes mark any pending pool items as Zoned and clear in-memory tracking
11. Distant kills detected via msg_id=37 are counted for drop rate adjustment (see below)

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

## Other Edge Cases

### Addon Reload Mid-Treasure Pool

If LootScope is reloaded while items are still in the treasure pool, `scan_pool()` reads the client's active pool slots and attempts to reconnect each item with its existing database record via `find_pending_drop()`. Successfully reconnected items continue tracking normally with no impact on Statistics. Items that can't be matched (e.g., the original kill record was from a previous addon session) are created as `late_join` stubs -- they appear in Live Feed but do not create new kill or drop records, so Statistics are not inflated.

### Late Loot (Zoning In After a Kill)

When a player zones into an area where party members have active loot pools, the client receives 0x00D2 packets with `is_old=1` (pool refresh). LootScope handles these the same way as addon reload: it first tries to reconnect with existing database records, and falls back to `late_join` stubs if no match is found. Late-join items are visible in Live Feed but do not affect Statistics kill counts or drop rates.

## Multi-Boxing / Multi-Server

LootScope is fully safe for multi-boxing. Each Ashita instance detects the logged-in character name and opens a separate database. Two characters farming simultaneously will never conflict, even if using the same Ashita directory.

Different private servers with the same character name will also get separate databases (server ID is included in the folder path).

## Export

CSV export path: `config/addons/lootscope/exports/lootscope_<CharName>_YYYYMMDD_HHMMSS.csv`

Export options:
- **Export All**: Exports every kill and drop to CSV (available from the Export tab)
- **Advanced Export**: Filter window with auto-updating preview. Source filter: All, Field, Chest/Coffer, All BF, BCNM, HTBF, Dynamis, Voidwatch, Domain Invasion (uses content_type so mob kills inside instances are grouped correctly). Exports both `th_level` (server-confirmed) and `th_estimated` (gear-based) columns. Additional filters: zone, mob name, TH level, date range, Vana'diel time, moon phase, weather, item, status, winner, and more. Discrete filter changes (dropdowns, sliders) update instantly; text inputs debounce for 0.5 seconds.

## File Structure

```
lootscope/
  lootscope.lua   -- Main addon: metadata, events, commands, CSV export
  db.lua          -- SQLite schema, migrations, queries, dirty-flag caching, transaction batching
  tracker.lua     -- Packet parsing (0x0028/0x0029/0x002A/0x001E/0x001F/0x0020/0x0053/0x005B/0x005C/0x0075/0x0034/0x00D2/0x00D3), content detection, TH gear scanning, weather scan, DAT lookup, credit system, drop order tracking, Voidwatch Pyxis loot + Wildskeeper Reive loot + buff detection
  analysis.lua    -- Statistical engine: Wilson CI, Poisson Binomial, co-occurrence, shared slot detection, battlefield drop structure, union-find inferred slots
  datreader.lua   -- Zone dialog DAT reader: d_msg/event_msg parsing for HTBF battlefield name resolution
  ui.lua          -- ImGui dashboard with tabs, compact mode, advanced export, TH management, nearby/combined rates, slot analysis (field + battlefield modes)
  data/           -- Shared databases (auto-created)
    th_items.db   -- TH gear profiles, items, and job traits (shared across characters)
```

## Data Storage

Each character gets their own isolated database file, stored at `config/addons/lootscope/<CharName>_<ServerId>/lootscope.db` (SQLite with WAL mode). This matches Ashita's settings folder convention so the DB and settings live in the same folder. Prevents write contention when multi-boxing and keeps data separated across characters and servers.

Database initialization is deferred until the character is fully logged in.

### Tables

**kills**: One row per mob killed (or chest/coffer opened)
- `mob_name`, `mob_server_id`, `zone_id`, `zone_name`, `th_level`, `th_estimated` (gear-based TH estimate), `source_type`, `killer_id`, `killer_name`, `th_action_type`, `th_action_id`, `vana_weekday`, `vana_hour`, `moon_phase`, `moon_percent`, `weather`, `battlefield`, `level_cap`, `bf_name`, `bf_difficulty` (0=none, 1=VD, 2=D, 3=N, 4=E, 5=VE), `content_type` (Dynamis/Voidwatch/Domain Invasion/Wildskeeper/etc), `is_distant` (0=nearby, 1=distant kill with drops), `timestamp`

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

The database schema evolves automatically. Each migration checks for missing columns/tables before applying.
Old databases are upgraded transparently. Missing values default to -1 (time/weather/drop_order) or 0 (IDs/TH).

### TH Items Database

Shared (not per-character) database at `data/th_items.db` inside the addon folder. Contains TH gear profiles, items, and job traits. Pre-populated with a "Retail" profile on first run. Supports custom profiles for private servers.

## Version History

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

## Slot Analysis Methodology

See [SLOT_ANALYSIS.md](SLOT_ANALYSIS.md) for the statistical methodology behind the Slot Analysis tab — model assumptions, method choices, and alternatives considered.

## Thanks

- **Thorny** - Slot Analysis concept, drop order tracking idea, outgoing 0x1A chest pre-identification approach, and ongoing feedback
- **Chihiro** - Many suggestions and bug reports!
- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
