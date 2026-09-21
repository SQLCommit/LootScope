# Changelog

[Back to LootScope](README.md)

## v1.5.0 — Code Refactor

Reorganized the code into smaller, focused modules for easier maintenance and future updates. The UI, content detection, battlefield sessions, and database setup now have clearer separation.

### Added

- Walk of Echoes coffer reward tracking, grouped by walk, with offered, taken, and left items.
- Limbus chest reward entries in the Live Feed.
- Besieged feed labels and Colonization/Lair Reive end rewards.

### Changed

- Reorganized statistics categories into **Open World**, **Battlefields**, **Instances**, and **Chest/Coffer**. Legion is under Battlefields; Reives are under Open World.
- Instance lists now show only content with recorded data. Counts distinguish kills, opens, and runs.
- Ambuscade, Domain Invasion, Limbus, and Besieged are now feed-only.
- Shipped TH profiles use a separate default catalog. Editing one creates a custom copy; Reset restores the shipped values.
- Shorter category help and clearer explanations of Treasure Hunter filters, exports, and statistical estimates.

### Fixed

- Incorrect battlefield names, difficulty labels, and distant-kill indicators. Existing records receive supported corrections automatically.
- Different contents being combined in statistics when they shared a mob and zone.
- Missing or collapsed rows in the Live Feed and statistics, including gil-only kills when gil display was off.
- Recording stopping after a failed database initialization. Initialization now retries, and failed writes report an error.
- Crashes while displaying some battlefield rows and processing events.

## v1.4.2

### Fixed

- Missing Wildskeeper Reive boss loot when drops arrived before the defeat message.
- Doubled percent signs in Slot Analysis and the ignored "Open window when addon loads" setting.
- Augment-based Treasure Hunter estimation and `/loot thaugs` failing to load their item library.
- Old records remaining labeled Unknown Battlefield in zones with a single content type.
- Compact-mode render errors leaving the UI in an invalid state.

## v1.4.1

### Fixed

- Sortie, Vagary, Legion, and Ambuscade being confused in shared zones. Detection now uses the entry route.

## v1.4.0

### Added

- Content tracking for Omen, Einherjar, Nyzul, Salvage, Limbus, Sortie, Vagary, Legion, Assault, Walk of Echoes, Skirmish, Meeble Burrows, Odyssey, and Ambuscade.
- An All Instances view and automatic content labels for older records in known instance zones.

### Changed

- Instance selection moved to a dropdown, and statistics categories were consolidated.

### Fixed

- Odyssey being confused with Walk of Echoes HTBFs in shared zones.
- Distant kills missing content labels when drops arrived before the defeat message.
- Missing instance options and a content-filter error in Slot Analysis.

## v1.3.3

### Fixed

- Selbina-entry Walk of Echoes HTBFs losing their name and difficulty through the zone change.
- Floating-point noise in exported moon percentages.
- Missing Dynamis-Divergence zones when labeling older records.

## v1.3.2

### Fixed

- Tooltip corruption or crashes from text containing percent signs.
- Settings-tab errors and unreported compact-mode errors.
- Treasure Hunter profile cloning and first-run setup now write changes together, avoiding partial updates.
- More reliable mob-gil tracking during large bursts of kills and more focused chest/coffer detection.

### Changed

- Clearer error messages when TH estimation or optional modules are unavailable.
- Full CSV exports clearly separate chest/coffer events from loot rows.
- More consistent settings saves, statistics queries, and Slot Analysis rendering.

## v1.3.1

### Added

- Wildskeeper Reive loot tracking, statistics, and export filtering for Naakual rewards delivered directly to inventory.

### Fixed

- A kill-tracking error when resolving a pet's owner.

## v1.3.0

### Added

- **Treasure Hunter estimation (Beta):** job traits, equipped gear, augments, and mid-fight gear swaps. Confirmed and estimated TH are stored separately; the display uses the higher value and marks estimates with `*`.
- Editable TH profiles for retail and private servers, including gear and job traits, with create, clone, and delete controls.
- TH estimates from eligible trusts and pets, Treasure Hound with Signet, and the BLU spell-set trait. Added `/loot bluspells` for checking that trait.
- Domain Invasion tracking and more reliable HTBF detection after an addon reload.

### Fixed

- Unrelated kills, player deaths, and trust despawns being recorded as your kills.
- Kill tracking depending on TH estimation being enabled.
- Pet-owner detection considering unrelated entities.

## v1.2.1

### Added

- Voidwatch tracking for Riftworn Pyxis offers, taken items, and relinquished items, including Obtain All and Relinquish All.
- Voidwatch statistics and export filtering.
- Support for consecutive Voidwatch fights and rewards delivered as either equipment or stackable items.

## v1.1.1

### Added

- Slot Analysis with confidence intervals, slot-count estimates, items-per-kill distributions, co-occurrence, shared-slot candidates, and drop order. Battlefield views add an inferred drop table.
- Grouped content filters and battlefield details in statistics and exports.
- Pet-to-master drop attribution, per-spawn results, and BCNM level-cap detection.

### Fixed

- Statistics caches refreshing unnecessarily and gil summaries ignoring the selected content filter.
- Missing respawned kills and distant flags not clearing when a defeat message arrived later.
- Chest/coffer distance checks and battlefield filters in Slot Analysis.
- Confidence-interval sorting and export-preview column counts.

### Changed

- Open-world statistics exclude tagged content. Original Dynamis and Dynamis-Divergence share a category.
- Slot Analysis displays small samples with warnings instead of hiding their results.
- Incomplete Ambuscade, Omen, and Sortie detection was disabled pending further support.

## v1.1.0

### Added

- HTBF names, difficulty tracking, colored difficulty badges, and a separate HTBF statistics view.
- Earlier chest/coffer identification when interacting with a container.
- Battlefield names and difficulty in saved loot history, with automatic upgrades for existing databases.

## v1.0.0

Initial release.
