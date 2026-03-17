# LootScope Changelog

## v1.3.1

### Added
- **Wildskeeper Reive Loot Tracking**: Tracks items from Naakual boss kills (Colkhab, Tchakka, Achuka, Yumcax, Hurkan, Kumhau). Wildskeeper Reives bypass the treasure pool — items are delivered directly to inventory via S2C 0x034 Event 2007 with item IDs in params[1-3]. All items are auto-obtained (won=1). Detection: Reive Mark buff (ID 511) + Naakual boss name match at defeat time.
- **Wildskeeper Statistics Category**: New "Wildskeeper" radio button in Statistics tab (6th category). Groups by Naakual boss per zone. Source filter value sf=12, content_type='Wildskeeper'.
- **Advanced Export Wildskeeper Filter**: Wildskeeper option in the Advanced Export Source filter combo.

### Fixed
- **find_pet_owner Forward Reference Bug**: `is_party_or_alliance_kill()` (added in v1.3.0) called `find_pet_owner()` before it was defined, causing "attempt to call global 'find_pet_owner' a nil value" on 0x0029 packets. Added forward declaration.

## v1.3.0

### Added

- **TH Gear Estimation (Beta)**: Gear-based Treasure Hunter estimation for jobs and servers where server-confirmed TH messages (msg 603) don't fire. Produces `th_estimated` stored alongside the existing `th_level`. Combined display shows the higher of the two values.
  - **Gear Scanning**: Continuously scans equipped TH gear during combat. Two-layer detection: intrinsic TH from profile gear list + augmented TH parsed from item augment data (augment ID 147). Scans on every offensive action (cached until gear swap via 0x0050). Supports mid-fight gear swaps (LuAshitacast/Ashitacast) with max-tracking per mob.
  - **Job Trait Profiles**: Shared `th_items.db` with profile system. Pre-populated "Retail" profile with 25 TH gear items and THF/BLU job traits. Profiles support custom private server TH configurations. Job traits have enable/disable checkboxes for toggling without deletion.
  - **Management Window**: Full CRUD UI for TH profiles, gear items, and job traits. Profile selector with New/Clone/Delete. Searchable item table with auto-fill from game data. Add Trait popup with job/role/level/value fields. Comprehensive tooltips throughout.
  - **THF Trust/Pet TH+1 Detection**: Scans party trusts and BST jug pets for THF (main or sub) job. Adds TH+1 minimum when detected. Checked once per mob per trust.
  - **Treasure Hound Kupower Detection**: Detects zone-in chat message for TH+1 kupower. Cached per-zone, checked live against Signet buff (ID 253).
  - **BLU Spell-Set TH Trait**: Reads BLU set spells from memory to detect TH+1 trait (requires Charged Whisker + Everyone's Grudge + Amorphic Spikes). Debug command `/loot bluspells` to verify.
  - **Display**: Combined TH in live feed and tables shows `math.max(th_level, th_estimated)`. Asterisk (*) suffix indicates estimated (no server confirmation). Both columns in CSV/JSON export.
- **Domain Invasion Tracking**: Kills during Domain Invasion (Elvorseal buff ID 603) tagged as `content_type='Domain Invasion'`. Dedicated statistics category and export filter (sf=11).
- **HTBF Fallback Detection**: Three-layer HTBF detection: (1) 0x005C packet (primary), (2) star prefix in "Entering the battlefield" chat text (fallback for addon reload), (3) "Current difficulty level" chat text (refines fallback difficulty).

### Fixed
- **False Kill Recording (Trusts, PCs, Unrelated Mobs)**: Previously `handle_defeat` recorded ANY mob defeat the client witnessed, including other players' kills, trust despawns, and PC deaths. Replaced with a 3-tier kill attribution filter:
  - **Tier 1**: Player personally attacked this mob (`engaged_mobs` hash lookup, O(1)).
  - **Tier 2**: Party/alliance member (or their pet) landed the killing blow. New `is_party_or_alliance_kill()` checks all 18 party/alliance slots + resolves pet owners via `find_pet_owner()`.
  - **Tier 3**: Domain Invasion bypass (Elvorseal buff active in an Escha zone).
  - Kills that don't match any tier are silently discarded. Entity index range guard (>= 1024) also rejects trusts and PCs before the attribution check runs.
- **`engaged_mobs` Decoupled from TH**: Mob engagement tracking was gated behind TH estimation settings. Now always active so kill attribution works regardless of TH configuration.
- **Pet Owner Scan Too Broad**: `find_pet_owner` scanned all 2304 entity slots including NPCs and trusts. Narrowed to PC range (1024-1791) since only player characters own combat pets.

### Changed
- **Content Type Map Consolidated**: Hoisted `content_type_map` to module-level `db.CONTENT_TYPE_MAP` constant. `get_all_mob_stats` elseif chain replaced with single lookup. `analysis.lua` uses matching local copy with sync note. Adding new content types now requires updating one table instead of 5+ locations.
- **Party SID Helper Extracted**: Duplicated 18-slot party/alliance SID comparison loop unified into `party_has_sid()` helper.
- **Unsigned SID Helper Consolidated**: Moved `unsigned_sid()` to top of tracker.lua, replaced 5 inline `+ 4294967296` patterns.
- **Inline Buff Check Consolidated**: `check_battlefield_reconnect` replaced 12-line inline buff scan with `has_buff(254)`.

## v1.2.1

### Added
- **Voidwatch Loot Tracking** *(suggestion by Chihiro)*: Tracks loot from Riftworn Pyxis after VW NM kills. VW bypasses the treasure pool entirely — items are delivered via S2C 0x034 (GP_SERV_COMMAND_EVENTNUM) event params. Up to 8 offered items per Pyxis are recorded as drops.
- **Voidwatch Selection Tracking**: Three-layer detection for taken items: (1) subsequent 0x034 events where param is zeroed out, (2) S2C 0x01F for stackable items delivered to inventory, (3) S2C 0x020 for equipment/augmented items delivered to inventory. Obtain All (won=1) and Relinquish All (won=-1) tracked via C2S 0x05B EventEnd (EndPara=10 and 9 respectively).
- **Voidwatch Statistics Category**: New "Voidwatch" radio button in Statistics tab (5th category). Groups by NM name per zone, same pattern as Dynamis/Omen. Source filter value sf=10, content_type='Voidwatch'.
- **Advanced Export Voidwatch Filter**: Voidwatch option in the Advanced Export Source filter combo. Filters exported data to `content_type='Voidwatch'` kills only.

### Design Notes
- **Buff-Based VW Kill Tagging**: `handle_defeat` checks for Voidwatcher buff (ID 475) and tags the kill as `content_type='Voidwatch'` immediately at defeat time. No retroactive tagging needed — the buff is active during the entire VW cycle and prevents attacking non-VW mobs, so there's no risk of false positives. Unlike BCNM/Dynamis, VW does NOT set `content_info` on the tracker.
- **Direct Kill Linkage**: `last_vw_kill` reference set in `handle_defeat` links Pyxis drops to the correct kill. No time-window scanning needed.
- **Three-Layer Finalization Redundancy**: (1) C2S 0x05B EventEnd (immediate), (2) Voidwatcher buff loss poll in d3d_present (safety net), (3) zone change / new Pyxis interaction (ultimate fallback). All idempotent via `finalize_vw_interaction()`.
- **Consecutive VW Cycle Support**: Riftworn Pyxis reuses the same server_id across VW cycles. Same-Pyxis guard compares `last_vw_kill` against stored `kill_id` to detect new cycles and reset state.
- VW item delivery uses **two different packets** depending on item type: stackable items (materials, seals) arrive via S2C 0x01F (ItemNo at offset 0x08), while equipment/augmented items arrive via S2C 0x020 (ItemNo at offset 0x0C). The subsequent 0x034 zeroing serves as a third fallback for both types. Verified via retail packet captures (Kaggen, Gugalanna).

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
