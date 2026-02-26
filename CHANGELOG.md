# LootScope Changelog

## v1.1.1

### Added
- **Slot Analysis Tab** *(concept and drop order tracking idea by Thorny)*: Per-mob drop slot probability analysis with six sections:
  - **Confidence Intervals**: 95% Wilson score CIs with sortable table and reliability badges.
  - **Slot Count Estimation**: Estimated slot count from max items per kill and rate sum ceiling, with model fit indicator.
  - **Items-Per-Kill Distribution**: Observed vs Poisson Binomial expected histogram with deviation table.
  - **Co-occurrence Analysis**: Pairwise co-occurrence with independence deviation and drop arrival order.
  - **Shared Slot Candidates**: Items that never co-occur despite sufficient sample sizes.
  - **Battlefield Mode**: BCNM/HTBF/All BF content auto-switches to Drop Structure (guaranteed vs variable items) and Inferred Drop Table (union-find slot grouping). Tooltips adapt to "encounters"/"runs" terminology.
- **Content Type Detection**: Classifies BCNM, HTBF, and Dynamis via S2C 0x0075 battlefield packet. Dynamis (original + Divergence) detected by zone name prefix. Ambuscade/Omen/Sortie WIP.
- **Grouped Statistics Filters**: Two-row category system (Field, Battlefields, Instances, Chest/Coffer) with context-sensitive sub-filters and consolidated (?) tooltips.
- **All Battlefields View**: Battlefield names with BCNM level cap and HTBF difficulty columns. Grouped by battlefield + zone + level cap + difficulty.
- **Advanced Export Content-Type Filtering**: Source filter uses content_type so mob kills inside BCNMs/HTBFs/Dynamis are grouped with their content. Options: All, Field, Chest/Coffer, All BF, BCNM, HTBF, Dynamis. Added Distant and Level Cap columns to preview and CSV.
- **Drop Order Tracking**: `drop_order` column tracks 0x00D2 arrival sequence per kill for slot position inference.
- **Pet-to-Master Drop Attribution**: AOE pet kills attributed to master mob via `GetPetTargetIndex()`.
- **Per-Spawn Breakdown Always Visible**: Shows for all mobs including single-spawn.
- **BCNM Level Cap Detection**: Two-layer detection — chat text parsing ("level is currently restricted to N") with memory comparison fallback (`GetMainJobLevel()` vs `GetJobLevel()`).

### Fixed
- **Dirty Flag Cache Bugs**: `htbf_breakdown_dirty` and `mob_stats_dirty` were never reset, causing two of the heaviest queries to bypass their caches on every call.
- **Gil Query Ignored Source Filter**: Gil min/max/avg used unfiltered queries for HTBF, content types, and instance views. Added matching WHERE clauses for all source filter paths.
- **Server ID Reuse**: Stale dedup guard silently rejected kills from respawned mobs. Fixed with state cleanup and 5-second timestamp race guard for AoE scenarios.
- **False Distant Kill Correction**: 0x00D2 fallback kills marked distant are now patched when the 0x0029 defeat arrives later.
- **Chest/Coffer Entity Distance**: Used elevation instead of north/south for horizontal distance. Fixed to use X and Y.
- **Battlefield SQL Mismatches in Slot Analysis**: Fixed query patterns for All BF, HTBF, and BCNM selections that produced "No kill data" due to missing bf_difficulty, level_cap, or bf_name expressions.
- **CI Reliability Column Sort**: Was silently ignored; now sorts by confidence interval width.
- **Export Preview Column Count**: Hardcoded count replaced with `#export_col_defs`.

### Changed
- **Field Excludes Content Kills**: Field category shows only open-world mob kills (no content type tag).
- **Kill-Count Gates Removed**: Slot Analysis sections show data immediately with low-sample warnings instead of hard gates.
- **Ambuscade/Omen/Sortie Marked WIP**: Detection and UI disabled pending more packet research and testing.
- **Dead Code Removed**: Unused functions, write-only state fields, and redundant migrations cleaned up across all files.
- **Dynamis Unified**: Original Dynamis + Divergence merged under single "Dynamis" content type with zone name prefix detection.

## v1.1.0

### Added
- **HTBF Difficulty Tracking** *(suggestion by Chihiro)*: Detects High-Tier Battlefield entry via S2C 0x005C packet. Records difficulty level (1=VD, 2=D, 3=N, 4=E, 5=VE) and battlefield name (resolved from zone dialog DAT files via FTABLE/VTABLE lookup).
- **Battlefield Name Resolution**: New `datreader.lua` module reads zone dialog DAT files (d_msg format) to extract battlefield name templates (`[Name1/Name2/.../NameN]`) and index by bit position from 0x005C. Cached per-zone.
- **Chest Interaction Pre-identification** *(approach suggested by Thorny)*: Tracks outgoing C2S 0x1A (Talk/Interact) to pre-identify chest/coffer targets. Uses 5-second window to match against subsequent 0x00D2 drops when entity has despawned.
- **Difficulty Badges**: Color-coded `[VD]`/`[D]`/`[N]`/`[E]`/`[VE]` badges in Live Feed and Compact mode (red/orange/yellow/green/blue). Tooltips show full difficulty name and battlefield name.
- **Battlefield Prefix on Mob Kills**: Mob kills inside an active BCNM/HTBF now show a `[BCNM]` or `[HTBF]` prefix in the Live Feed and Compact mode. The battlefield name is stored on the kill record and shown in tooltips.
- **Separate HTBF Statistics Tab**: HTBF content has its own radio button in Statistics, separate from BCNM. Groups by battlefield name, zone, and difficulty level. BCNM tab now excludes HTBF kills for clean separation.
- **Schema Migration**: Adds `bf_name` (TEXT) and `bf_difficulty` (INTEGER) columns to kills table. Existing kills default to empty/0. Compatible with existing databases.
- **New Packet Handlers**: `packet_in` 0x005C for HTBF detection, `packet_out` 0x1A for chest interaction tracking.

## v1.0.0

### Added
- **Live Feed** with configurable columns, row tooltips (mob ID, Vana'diel time, moon, weather), and color-coded rows by source type
- **Statistics** tab with nested mob/item/per-spawn tree, sortable columns, per-spawn item breakdowns, and source-type filter categories with `(?)` tooltips
- **Treasure Hunter** tracking via 0x0028 action packet parsing with TH action type/ID recording
- **Mob Gil Tracking** via 0x0029 msg_id=565 with FIFO queue for AoE kills. Gil displayed in green with min/max/avg amounts. Excluded from item drop rate calculations. Gil-only spawns hidden from per-spawn breakdown. FoV/GoV regime rewards disambiguated by checking the FIFO queue.
- **Chest/Coffer Tracking**: Full event tracking via 0x002A (unlock/fail), 0x001E (gil inventory diff), and 0x0053 (system message). Four-layer gil detection with dedup. Records gil amount, container type, and failure reason (lockpick fail, trap, mimic, illusion).
- **BCNM Battlefield Detection**: Captures name from chat, detects level cap, persists sessions to SQLite, reconnects on reload via buff icon 254. Stale sessions auto-cleaned after 4 hours.
- **Vana'diel Time** recording: weekday, hour, moon phase, and moon percentage per kill
- **Weather Tracking** via client memory pattern scan (20 weather types)
- **Three-Tier Mob Name Resolution**: entity memory, DAT file lookup, chat text fallback
- **Two-Tier Distant Kill Tracking**: per-mob `is_distant` flag for kills with drops + zone-level missed kills (informational) via credit/debit system
- **SpawnFlags-Based Source Classification** (Mob, Chest, Coffer, BCNM)
- **TreasurePoolStatus Guard** for safe pool scanning on addon reload
- **Mob Server ID Tracking** for per-spawn analysis with unique spawn count
- **Lot Result Tracking**: winner name/ID, player lot value, player action (lot/pass), color-coded status (Got/Full/Lost/Zoned/Pending)
- **Compact Mode** with independent column settings, optional title bar, and background opacity slider
- **Full CSV Export** with streamed writes for large datasets
- **Advanced Export** with 14+ filter dimensions: zone, source type, TH level, mob spawn ID, date range, Vana'diel weekday, hour range (wrap-around), moon phase range, weather, item name/ID, winner name/ID, player action, status, empty kills toggle
- **Live Export Preview** with auto-update on discrete changes and debounced text input (0.5s)
- **Settings**: Live Feed max entries, show/hide empty kills, show/hide mob gil drops, compact background opacity, compact title bar toggle, show on load toggle, column visibility popups
- **Commands**: `/loot` toggle, `/loot compact`, `/loot resetui`, `/loot stats [mob]`, `/loot help`
- **Reset Confirmation** dialog requiring "CONFIRM" text input (3-step process)
- **SQLite Storage** with WAL mode, dirty-flag caching, and automatic schema migration chain
- **Per-Character Database** isolation (multi-box safe). DB stored at `<CharName>_<ServerId>/lootscope.db` with automatic folder migration from legacy `<CharName>/` path
- **Transaction Batching** for write performance
- **pcall Safety** around all packet parsing, memory reads, and database operations
- **Pool Reconnection** on addon reload
- **Thousand Separators** in count displays, database file size display in export tab
