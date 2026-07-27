---
name: project-keynes-game-flow-runtime
description: Guide Project.Keynes formal startup, session routing, NewGameConfig, deterministic player start selection, one-cell player-country bootstrap, production starter settlements, PKSV complete saves, safe-boundary capture, and ordered restore. Use when changing the main menu, new/load game flow, GameFlowService, player spawn resources, StarterSettlementBootstrap, GameSaveCoordinator, SaveRepository, WorldClock persistence, environment persistence, PKCN/PKEC save ordering, autosave, pause/exit flow, or related tests and documentation.
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
3. Deterministic start selection and resource top-up.
4. PKCN player-country bootstrap.
5. Production starter-settlement packet construction.
6. PKEC economy bootstrap and conservation audit.
7. Country then economy scheduler registration.
8. UI, selection, and camera publication.

Fail generation with a structured, displayable error if no eligible start
exists. Do not fall back to an arbitrary tile.

## Enforce the Player Start Contract

- Use `StartLocationProfile`, not inspector habitability scores.
- Require passable land, profile climate/elevation/vitality ranges, and local or
  neighboring river/lake freshwater.
- Sort by survival score and deterministically choose in the top quartile using
  the world seed and `player_start` purpose key.
- Prefer a naturally present gold or silver deposit.
- Top up fertile soil, timber, wild game, stone, flint, and one precious metal
  to profile minimums, then publish to MapData, DCWorld, and DCWorldExt.
- Create stable country id `country.player` with exactly the start cell in its
  territory CSR. Keep every other cell unowned.

## Enforce the Settlement Contract

Use `StarterSettlementBootstrap`; never call `EconomyTestBootstrap` from the
formal path. Require exactly 20 people: three foragers, two merchants, one gold
miner or two silver miners, and unemployed household members for the remainder.
Require one gathering ground, timber collector, merchant post, and matching
precious-metal work site. Use EconomyFacade catalog helpers and fixed-point
packets, provide the 60-day bridge, and retain population/money/goods
conservation checks.

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

## Validate Proportionally

Run at minimum:

- Headless project startup.
- `new_game_config_test.gd` and `save_repository_test.gd`.
- `gameplay_start_runtime_test.gd` for start resources, freshwater, one-cell
  ownership, 20 population, buildings, and production-bootstrap source.
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
