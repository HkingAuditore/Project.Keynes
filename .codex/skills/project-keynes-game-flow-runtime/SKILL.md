---
name: project-keynes-game-flow-runtime
description: Guide Project.Keynes formal startup, session routing, NewGameConfig, deterministic player/foreign start selection, one-cell country bootstrap, production starter settlements, PKSV complete saves, safe-boundary capture, and ordered restore. Use when changing the main menu, new/load game flow, GameFlowService, country spawn resources, StarterSettlementBootstrap, GameSaveCoordinator, SaveRepository, WorldClock persistence, environment persistence, PKCN/PKEC save ordering, autosave, pause/exit flow, or related tests and documentation.
---

# Project.Keynes Game Flow Runtime

Treat formal game flow and complete persistence as runtime architecture, not as
UI-only features. Preserve existing MapGenerator, DataCore, PKCN, PKEC, SUS,
WorldClock, and player-scene ownership boundaries.

## Ground Before Editing

Read these current sources before changing behavior:

- `references/system-map.md`
- `docs/cpp-dots-runtime/game-flow-start-save.md`
- `docs/cpp-dots-runtime/runtime-authority-matrix.md`
- `docs/cpp-dots-runtime/country-scheduling-save.md`
- `Project/project-keynes/project.godot`
- `Project/project-keynes/scripts/game/game_flow_service.gd`
- `Project/project-keynes/scripts/game/new_game_config.gd`
- `Project/project-keynes/scripts/game/game_save_coordinator.gd`
- `Project/project-keynes/scripts/game/save_repository.gd`
- `Project/project-keynes/scripts/game/world_runtime_host.gd`
- `Project/project-keynes/scripts/geography/map_generator.gd`

For native state changes also read `gdext/src/environment_runtime.{h,cpp}` and
the PKCN/PKEC facades and runtime sources. For UI changes also use the project UI
art-direction skill and inspect `UITokens`, `IconBadge`, and the current scenes.

## Preserve Session Authority

- Keep `main_menu.tscn` as the product main scene.
- Keep `world_setup.tscn` as a development tool only.
- Pass exactly one pending `new_game` or `load_game` request through
  `GameFlowService`; never add product-path `Engine` metadata.
- Validate all new-game inputs with versioned `NewGameConfig`.
- Persist the resolved nonzero seed and complete generation configuration.

## Preserve Generation Order

Use this sequence without reordering:

1. Physical/static world generation.
2. Natural-resource generation and publication.
3. Deterministic player/foreign start selection and resource top-up.
4. One-shot PKCN multi-country bootstrap with the player in slot 0.
5. Aggregated production starter-settlement packet construction.
6. PKEC economy bootstrap and conservation audit.
7. Country then economy scheduler registration.
8. UI, selection, and camera publication.

Fail generation with a structured, displayable error if no eligible start
exists. Do not fall back to an arbitrary tile.

## Enforce the Player Start Contract

- Use `StartLocationProfile`, not inspector habitability scores.
- Require passable land and profile climate/elevation/vitality ranges. Do not
  require river/lake or coastal hydrology.
- Prefer a naturally present gold or silver deposit, then survival score, then
  cell index. Close routes only for the cells about to be chosen.
- Top up fertile soil, timber, wild game, stone, flint, pasture, and one
  precious metal to profile minimums. Do not invent fish, paddy, or clay on dry
  inland cells. After MapData writes, republish reserves and resource research
  signals. `evaluate_starter_route` must not apply top-ups.
- Create stable country id `country.player` with exactly the player start cell.
- Select `NewGameConfig v3`'s `0..12` foreign countries using pairwise
  six-neighbor land distance, with disconnected land treated as infinitely far.
- Use stable foreign IDs `country.foreign.NNN`, unique resource-backed names,
  one start cell each, and keep all remaining cells unowned.

## Enforce the Settlement Contract

Use `StarterSettlementBootstrap`; never call `EconomyTestBootstrap` from the
formal path. Require exactly 20 people. Self-operated job slots follow the
survival-core buildings and stay at or below 20 per opening country. Remaining
people enter the unemployed pool for native job matching. Prefill owner operators
on opening food buildings (`gathering_ground` and `stone_age_hunting_camp`) so the
food plan runs; do not prefill knowledge, trade, or mine operators. Opening lots must remain operable from granted production/output/resource technologies. Formal starts always top up timber and grant/prebuild exactly one `deadwood_gathering_camp`; leftover construction-material techs (bast, reed, turf) gate later construction, not standing food camps. Allow employee roles only on `placer_gold_working` (1 miner)
and `surface_silver_working` (2 miners); do not prefill those slots. Other
Stone-Age starter buildings must remain owner-only. Require gathering and hunting
camps when local reserves exist, one deadwood camp, the matching precious-metal work site,
`early_merchant_post`, and hide scraping only on cold highland. Do not prebuild any
knowledge shed; reveal one geographically operable knowledge-practice technology,
seed its construction materials, and deposit 3000 authored technology points in
the treasury so the pending knowledge practice can complete without covering later
queued techs. Do not prebuild leftover fishing or bast camps. Aggregate all starts through EconomyFacade
catalog helpers and fixed-point packets, provide the 15-day local food bridge, and retain population/money/goods
conservation checks.
Require one native founder family per capital, conserving the gathering ground's two occupied
forager owners as its membership and ownership, and immediately promote exactly one of them as the
named notable founder with a traceable owner job and building handle. Do not lower ordinary family
formation thresholds to satisfy this opening contract.
Keep the explicit v3 founder columns, but require native fallback recognition from a forced-named
capital plus its actual gathering ground when a cached v2 packet omits them. Early-session repair is
bounded to days 0..30, requires filled matching owner posts, and must be idempotent.

## Enforce PKSV Boundaries

- Save only after country is idle and economy is committed.
- Freeze new clock advancement but continue rendered frames while draining an
  already-open continuation.
- Fail closed when any required provider or section is absent.
- Register every persisted authority through `RuntimeStateProvider`; require
  `provider_id()`, `schema_version()`, `can_save()`, `write_sections()`,
  `restore_sections()`, and `state_hash()` and persist the provider manifest in
  the PKSV header.
- Preserve `.tmp -> verify -> .bak -> final rename` replacement and backup
  recovery.
- Require version, generator/schema/catalog compatibility before restore.
- Persist complete authority, not diagnostic counters. Native environment state
  includes SoA vectors, weather ping-pong, topology, dirty/active sets, round
  flags, all stage cursors, and deterministic versions/RNG where owned.
- Restore regenerated static world, dynamic world/environment, WorldClock,
  PKCN, PKEC, PKFG, journal/session, derived resources, then player view.
- Always restore PKCN before PKEC, and PKFG after PKCN. Re-solving visibility
  reads the restored territory.
- `pkfg` (`PKFogOfWar v1`) persists only the monotonic `cell_explored` array plus
  its cell count. Current visibility and `fog_k` are derived and must be
  recomputed through `WorldRuntimeHost.refresh_country_visuals()` on restore,
  never saved. Reject a cell-count mismatch or truncation rather than padding.

## Headless Save Replay and Known Save/Restore Blockers (2026-09-22)

Reproduce a player-reported stop with
`tools\runtime\Invoke-SaveReplay.ps1 -Slot autosave -Days 60` (or `-SavePath <file.pksv>`).
It drives `tests/headless_save_replay.gd` through the production
`GameFlow.begin_load_game` restore path and writes a forensics JSON on fatal, stall, or
failed restore. `SaveRepository` honours `PK_SAVE_DIR` in debug builds, so an arbitrary
`.pksv` can be staged into a scratch directory without overwriting the player's slots.

A replay that reaches the target day is not a pass on its own: also assert country/economy
are bootstrapped, the host is not STOPPED/FAULTED, and `newest_state_day` advanced. A failed
PKSR restore lets the clock free-run with nothing simulating.

Save/load under worker authority was repaired end to end on 2026-09-23; the full chain
is in `docs/cpp-dots-runtime/game-flow-start-save.md` ("Save/load under worker
authority"). The rules that fell out of it:

- Under worker Country authority the main-thread `NativeCountryRuntime` is stale (never
  written after bootstrap). Anything that persists or reports Country state must read
  `country_query_runtime()`; saves use `capture_worker_committed_checkpoint()`, and Economy
  save headers are stamped with that checkpoint's identity (`set_save_country_identity`).
- A restore start is granted its requested domain mask immediately, and
  `sync_runtime_domain_ownership()` mirrors the grant to the main-thread peers. Do not
  reintroduce a path where a loaded game's first day runs before the grant.
- Every restore path must end in `publish_restored_country_territory()`; restore must size
  every per-country lane (including Economy asset reservations) to the restored count.
- Validate cross-section references (e.g. fiscal peer `country_slot`) in `end_restore`,
  after the epoch they refer to is captured, not while parsing the section.
- New PKEC sections need an ECP2 domain mapping **and** must fall inside the restore section
  loop, or they are dropped silently while the header still counts them.
- `build_save_bundle` failures must publish a save failure (`_save_failed_request_id`,
  `_save_failure_reason`) and must not be overwritten back to PAUSED/RUNNING.

Test it with `PK_SAVE_DIR=<scratch> PK_GAME_SAVE_ROUNDTRIP_TEST=1` (the test refuses to run
against `user://saves` because it writes `manual_1..3`). It enables a tax and advances 20
days before saving so the Country state really changes on the worker; keep that property if
you edit it, otherwise a stale-state save passes by coincidence.

## Validate Proportionally

Run at minimum:

- Headless project startup.
- `new_game_config_test.gd` and `save_repository_test.gd`.
- `gameplay_start_runtime_test.gd` for deterministic starts, pairwise distance,
  unique identity, one-cell ownership, 20 population per country, buildings,
  and production-bootstrap source.
- `environment_runtime_smoke_test.gd` for byte-exact native state round-trip.
- `game_save_roundtrip_test.gd`, which hashes `explored_arr` across save/load.
  It runs as a real session via `PK_GAME_SAVE_ROUNDTRIP_TEST=1`, not with
  `--script` (that mode does not register autoloads).
- Country and economy focused tests.
- Debug and release GDExtension builds after native changes.
- Desktop and narrow UI checks after menu or pause-flow changes.

For changes that can affect settlement outcomes, run 60-day, two-year, and
ten-year economy soaks and require zero population, money, and goods
conservation error. Update `game-flow-start-save.md`, the authority matrix, and
the system map whenever ownership, ordering, sections, or compatibility changes.
When a change touches the vision/fog provider, also update
`docs/cpp-dots-runtime/vision-fog-and-borders.md`.
