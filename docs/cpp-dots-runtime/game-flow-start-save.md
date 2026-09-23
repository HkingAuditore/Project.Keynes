# Formal Game Flow, Player Start, and PKSV

This document is the current contract for the player-facing startup path, the
multi-country opening bootstrap, and complete-game persistence. The legacy
`world_setup.tscn` remains a development tool and is not a product entry point.

## Session Authority

`GameFlowService` is the process-local session authority. It owns exactly one
pending `new_game` or `load_game` request and changes between
`main_menu.tscn` and `player_game.tscn`. Product code must not use `Engine`
metadata to move configuration between scenes.

`NewGameConfig v3` is the shared UI/generator/save schema. Its top-level groups
are `country`, `base`, `world_controls`, `climate`, and `research`. The
`country.foreign_count` field is persisted with range `0..12` and default `5`;
v2 loads migrate to `0` so existing saves retain their single-country opening.
`base.land_layout` is a player-facing preset id (`single` / `two` / `multiple` /
`archipelago` / `custom`). Named presets write `num_continents`, `continent_size`,
`sea_level`, plus `world_controls.continent_spacing` and `island_amount`; the
default is `two`, sized so the two cores stay separated instead of merging into
one Pangaea. Missing or unknown ids validate as `custom` and keep the stored
numeric knobs. `base.map_source` is `procedural` (default) or `pkmap`. When
`pkmap`, `base.pkmap_path` must point to an existing `.pkmap`; `validate()` peeks
the header, rejects a mismatched `generator_hash`, and stamps width, height,
sea level, and seed from the pack. Missing `map_source` / `pkmap_path` on older
v3 dictionaries remains procedural. Always validate through
`validate()` or `from_dictionary()` before generation. The resolved nonzero
seed, including a UI-generated random seed or a packed PKMAP seed, is the value
stored in PKSV. Author-map saves keep the file path as their terrain identity;
moving or deleting that `.pkmap` fails closed on load and does not regenerate
from seed.

## Generation and Bootstrap Order

The formal path has one fixed order:

1. Generate physical geography and bake the static world.
2. Generate natural-resource deposits and publish them to `MapData`, `DCWorld`,
   and `DCWorldExt`.
3. Select the player start, then deterministically select the configured foreign
   starts from cells whose natural deposits and visible geography already close the starter route.
4. Bootstrap PKCN once with `country.player` in slot 0 followed by
   `country.foreign.001` etc.; every country owns exactly its start cell and all
   remaining land stays unowned.
5. Build one aggregated production settlement packet with
   `StarterSettlementBootstrap`, including each capital's founder family and
   notable founder declarations.
6. Bootstrap PKEC and run its initial conservation checks.
7. Register `country_daily` before `economy_daily`, then register the remaining
   daily systems and build scheduler topology.
8. Publish UI state, select the start cell, and center it in the map safe area.

Do not call `EconomyTestBootstrap` from this path. It remains test/demo data.

## Start Policy

`StartLocationProfile` is gameplay configuration, independent of inspector
habitability presentation. A candidate must be passable land and satisfy the
temperature/moisture/elevation/vitality ranges. River, lake, and coastal
hydrology are classification signals, not admission gates. Climate-qualified
cells enter the pool; naturally placer-gold-bearing cells are preferred, then
survival score, then cell index. `select_and_prepare` only runs Vision plus
route closure on the cells it is about to choose, not on the whole map.

Opening selection may top up `fertile_soil`, `timber`, `wild_game`, `stone`,
`flint`, `pasture`, and `gold_ore`
to `StartLocationProfile` minimums. It does not invent fish, paddy land, or clay
on dry inland cells. Overlay reserves are virtual while scoring routes; only the
chosen player and foreign cells are written back to MapData. Generation fails
with a player-facing error when no climate-qualified cell can close food,
knowledge, placer-gold, and trade production even
after those minimum fills. Clothing production is required only on the cold
highland route. Construction materials are provisioned as bootstrap stock rather
than a completed opening industry. `evaluate_starter_route` still reads generated
geography only, so inspector/fixture probes do not apply top-ups; a silver-only
cell therefore fails the formal Stone-Age route probe.

Foreign starts use the same climate predicate and the same overlay closure.
Their minimum pairwise land
distance is `clamp(round(min(width, height) * 0.15), 4, 12)` over the map's
six-neighbor topology; disconnected landmasses count as infinitely distant.
Selection is deterministic and greedily orders candidates by distance from the
nearest selected start, natural placer gold, survival score, then cell index.
Generation fails rather than reducing the requested count or relaxing distance.
Display names are selected without replacement from the resource-backed Chinese
country-name pack, excluding the player's display name.

## Twenty-Person Settlements

Every opening country receives exactly 20 people. Self-operated job-capacity slots
follow the survival-core buildings and stay at or below 20; leftover people enter
the native unemployed pool for ordinary employment matching. The opening grant is
the survival core—gathering, hunting, early trade, one placer-gold working, one
deadwood gathering camp, and hide scraping only on cold highland—not every
visible zero-cost starter node. The physical food producer is
selected from the local gathering/hunting options. Opening timber is topped up to
the profile minimum, so the construction backbone is always `logs` from that camp.
Knowledge-shed materials remain bootstrap stock. The packet does not preassign the whole population to
professions: it prefills owner operators on the opening food buildings (gathering
and hunting) so the 110% food plan actually runs, places the remaining people in
the native unemployed pool, and lets normal employment matching choose later jobs
at economy boundaries. The founder family still binds to the gathering ground. Stone-Age buildings expose no employee roles except the
opening placer-gold working, which keeps its authored miner slot. That employee slot is extra capacity on top of the core self-operated
jobs; bootstrap does not prefill it, so opening `employee_employed` stays 0.
Their self-operated/co-operated
jobs use the runtime's owner-role lane because the catalog has only owner and employee lanes; this is
building capacity, not a landlord marker or a planner-owned population assignment. Fifteen days of the compiled `survival_household` food quantities are bridged
across every locally discovered, runnable food good in its matching substitute sub-basket; when a basket
has several discoveries, the bridge splits that quantity deterministically among them. All settlements are compiled
into one PKEC bootstrap packet. PKCN/PKEC and the economy
ledger remain the authorities; UI code does not own this state.
Each capital also starts with exactly one founder family: the two foragers who
operate its gathering ground become conserved family members, that building unit
becomes the family's first industry, and one of those occupied owner jobs becomes
the family's named notable founder. This explicit opening exception is created
inside native bootstrap, preserves total population, money, goods, and building
count, and is immediately queryable before the first daily settlement.
The v3 `founder_family_*` columns remain the preferred explicit contract. Native
bootstrap also derives the same declaration from `forced_named_cells` plus an
actual `gathering_ground` when those columns are absent, so a long-lived editor
emitting the older v2 packet cannot silently create a capital without founders.
For already-running early sessions, `FAMILY_COMMIT` repairs a still-empty forced
capital during days 0..30 once its occupied gathering-ground owner posts exist;
the normal `PERSON_COMMIT` then promotes and binds the representative.
The packet marks every opening-country start cell as `forced_named_cells`.
Native `SettlementStore` therefore assigns each capital a deterministic name
even though 20 people remain below the ordinary rural naming threshold. This is
a naming exception only: prosperity remains population-derived and the exact
20-person economy contract is unchanged.

## PKSV v1

`SaveRepository` writes one PKSV file for each fixed slot:
`manual_1.pksv`, `manual_2.pksv`, `manual_3.pksv`, and `autosave.pksv`.
The container has a JSON header, a section table, compressed payload blocks,
uncompressed lengths, and per-section SHA-256. Replacement is:

```text
write .tmp -> read/decompress/hash verify -> move final to .bak -> rename .tmp
```

Load ignores `.tmp`, prefers a valid final file, and falls back to a valid
backup. Incompatible generator/catalog/schema hashes are rejected rather than
guessed or migrated.

Required sections are `new_game_config`, `world_clock`, `dynamic_world`,
`environment`, `pkcm`, `pkcn`, `pkec`, `pkgp`, `pkef`, `pkid`, `pkfg`, `journal`, `pktr`, `player_context`,
`player_view`, and `preview`. Missing authority fails closed. `environment` uses
`PKEnvironmentRuntime v1` and includes native core SoA, weather ping-pong,
topology, dirty/active sets, round flags, stage cursors, and publish versions;
diagnostic counts alone are not a save provider.

Every authority is registered through `RuntimeStateProvider`, whose contract is
`provider_id()`, `schema_version()`, `can_save()`, `write_sections()`,
`restore_sections()`, and `state_hash()`. The PKSV header stores the ordered
provider manifest (id, schema, owned sections, and capture hash). Slot listing
and load preparation reject a missing or mismatched provider before rebuilding
the world. The current restore registry order is dynamic world, environment,
PKCM, clock, PKCN, PKEF, PKEC, PKGP, PKFG, journal, PKTR, PKID, then player
session/view/preview. PKEF precedes PKEC so Economy can cross-check every settling
cross-domain transaction against authoritative Effect state. `PKID v3` follows
`PKEF v11`: every active ideology must match its
durable external binding by identity, generation, level, location, template
signature, and Effect program hash. Missing/mismatched bindings or unknown
pending transitions fail restore; PKID and PKEF must also agree on the exact
country/ideology source of every pending transaction, with no extra PKEF
ideology transaction omitted by PKID. They are never repaired by replaying effects.
PKID v1 is accepted only when every ideology is inactive. Save capture waits for
`ideology_should_run(day)`, `effect_should_run(day)`, and every native
Country/Economy/Gameplay Effect ingress to be idle, so no cross-section snapshot
can span a preflight/commit/ACK boundary.

The background worker ideology mirror is an additional PKSR `IDP1` section,
restored transactionally only after the worker is stopped and its immutable
catalog/bootstrap are ready. `IDP1` has an independent ABI, catalog/state hash,
length limit, and checksum. Missing `IDP1` means bootstrap/default worker
ideology state; it is never inferred from synchronous `PKID`, and legacy
composite `PDP3` remains diagnostic-only for this purpose.
PKCM v1 saves Climate modifiers. PKCN v11 embeds Country modifiers, research,
tax policy, territory claim and native Effect ingress idempotency; PKEC v41 embeds Economy
modifiers, BuildingIdentityStore, family traits/cell influence,
production-climate state, and Economy Effect ingress idempotency. PKGP v1 saves
Gameplay identity/base SoA and modifiers; journal v4 saves native
`PUBLISH_EVENT` Effect idempotency evidence; PKTR v6 saves static/dynamic branch
and technology-practice Trigger accumulation. PKEF v11 saves Effect recipe/program
identity and pending ACK state. Old PKCN/PKEF/PKTR schemas or related catalog
identity changes are rejected with `catalog_hash_mismatch`.

`pkfg` is `PKFogOfWar v1` and persists exactly one array: the monotonic
`cell_explored` progress, plus the cell count it was captured at. Current
visibility and the blurred fog knowledge `fog_k` are pure functions of territory
and terrain, so they are never written; restore recomputes them. A cell-count
mismatch or a truncated array is rejected rather than padded. When fog has never
been solved (sandbox or fog disabled) the provider still writes a zero-filled
array so the section stays mandatory.

The load screen validates every section without retaining full payloads, and
loads the screenshot through a separately verified `preview` section. This
keeps corrupt or truncated slots visible with a reason while disabling load;
valid backups remain recoverable.

## Safe Boundary and Restore

A save request freezes the clock while rendering continues. If Trigger,
Ideology, Effect, Modifier, Gameplay Effect, Country, or Economy has pending
safe-boundary work, `GameSaveCoordinator` advances the native order
`Trigger -> Ideology -> Effect -> Modifier -> Gameplay -> Country -> Economy`
once per render frame until every owner is idle and Economy is committed. It
then captures all providers and restores the original pause and speed state.
Annual autosave runs once after the new year's first joint safe boundary.
Return-to-menu and exit await autosave success; failure offers retry, discard,
or cancel.

Restore order is strict:

1. Validate PKSV header, compatibility hash, section hashes, and required set.
2. Regenerate static terrain from the complete saved `NewGameConfig`. A `pkmap`
   source reloads that file through the generate bypass; it does not replay the
   original seed through procedural hydrology.
3. Restore dynamic `DCWorld` and the full native environment provider.
4. Restore PKCM, then `WorldClock`.
5. Restore PKCN v11, including Country modifiers, research state, national/cell tax policy,
   and native Country Effect ingress idempotency.
6. Restore PKEF v11, then PKEC v41 after trade topology has been configured, including Economy
   modifiers, building identities, notable families, active family expeditions, and production-climate state.
7. Restore PKGP, then commit PKFG `explored_arr` without solving. After the later
   player-session provider restores `start_cell`, finalize scheduling, rebind
   the player country, re-solve vision, and republish `enum_lut.a` and the border
   mesh through `WorldRuntimeHost.finalize_save_restore_visuals()`. That call fails
   the load when fog is enabled but the player country slot cannot be rebound;
   a silently unexplored map would be persisted by the next autosave.
8. Restore journal v4 and PKTR v6, then PKID v3
   ideology state. PKID verifies its active PKEF bindings before the session is
   allowed to resume.
9. Rebuild derived views/render resources and scheduler topology.
10. Restore selected cell, camera position/zoom, pause, and speed.

PKCM must follow environment; PKCN and PKEF must precede PKEC; PKGP follows Economy
base/identity restore. PKFG must follow PKCN. Its provider commits monotonic
exploration first, but visibility solving waits until `player_context.start_cell`
is restored; solving earlier resolves player slot `-1` and can publish an
all-unexplored map. Native restore rejects crossed
generations or catalog hashes.

While regenerating a load target, `MapGenerator` enters restore-preparation
mode: it configures the native country catalog but does not bootstrap a
temporary player country or settlement. After PKCN restore makes the country
authority available, the coordinator configures the economy catalog and trade
topology, then restores PKEC. Because native PKEC restore clears transient
topology state, finalization recaptures the same normalized topology before it
registers `country_daily`/`economy_daily` and rebuilds the existing scheduler
topology. This preserves the required
`PKCN -> economy configure -> PKEC -> topology recapture -> scheduler`
sequence.

PKEC restore must also reconstruct every building-group transient span before
daily scheduling resumes. In particular, the inspector-only selected-input lane
is allocated from each restored building type's input count and initialized to
`-1`; it is neither serialized nor included in the state hash. Restore
finalization validates the span shape so a missing cache fails during load
instead of surfacing later in `BUILDING_PRODUCTION`.

The PKSV `pkec` section is a byte-for-byte concatenation of native framed PKEC
chunks. `EconomyFacade.restore_bytes()` must recover each frame from its
16-byte header and feed exact frame boundaries to native restore; a fixed-size
slice is not a valid framing rule. Native journal restore returns the same
structured success contract as the other providers (`ok=true`,
`fallback=false`) so the coordinator can distinguish a restored journal from
an unavailable fallback.

## Headless save replay and the save-dir override (2026-09-22)

`tests/headless_save_replay.gd` loads a slot through the production
`GameFlow.begin_load_game` path and advances the authoritative clock for N days
headlessly. It is the reproduction entry point for player-reported stops: hand
over a save, get a forensics JSON. Drive it with
`tools/runtime/Invoke-SaveReplay.ps1`; see the "存档复现入口" section of
`authority-migration.md` for the environment variables.

`SaveRepository._init()` honours `PK_SAVE_DIR` **in debug builds only**. The
wrapper uses it to stage an arbitrary `.pksv` under a scratch directory as one of
the four known slot ids, so replaying a save never overwrites the player's own
slots. Exported release builds always use `user://saves`.

## Save/load under worker authority (fixed 2026-09-23)

Saving and loading a game whose domains are owned by the background worker was
broken end to end. The chain below was fixed in one pass; each link was hidden
by the previous one, so a fix that stops early simply exposes the next.
`game_save_roundtrip_test.gd` now covers the whole chain: it saves before the
first settlement (must be rejected cleanly), enables a 10% income tax, advances
20 days so Country state really changes on the worker, saves, loads, compares
the capital's country summary and tax policy, and runs a full settlement cycle
after the load.

**Save side**

- A save before the first Economy commit has no restorable committed ledger.
  It used to fault the worker inside `build_save_bundle`; now `_can_save()`
  returns `save_requires_first_settlement` and the host records the same reason
  without faulting.
- `build_save_bundle` failures used to be invisible: `set_fault()` moved the
  worker to FAULTED, then the save admission block overwrote that with
  PAUSED/RUNNING, so the worker looked alive while owning nothing and the
  coordinator polled 1800 frames into `runtime_save_timeout`. The admission block
  now keeps FAULTED, publishes `_save_failed_request_id` plus a dedicated
  `_save_failure_reason`, and `poll_runtime_save` returns
  `{ok:false, code:runtime_save_failed, reason}` immediately.
- **The saved Country was the day-0 Country.** Under worker authority the
  main-thread `NativeCountryRuntime` is never written after bootstrap (the read
  view only repairs MapData territory), and `request_runtime_save` captured the
  checkpoint from it. Every territory, research, and treasury change made on the
  worker was lost on save. The checkpoint now comes from
  `country_query_runtime()` via `capture_worker_committed_checkpoint()`, which
  drops the stale command/peer state the replica was copied from.
  `build_save_bundle` rejects the save with `save_country_checkpoint_day_mismatch`
  if the checkpoint day ever disagrees with the bundle day.
- Both ECP2 captures (the PKSR bundle and the PKSV `ecp2` provider section) now
  stamp the Economy header with that checkpoint's generation and business hash
  (`set_save_country_identity`), so restore's Country binding check matches.
- Worker-routed fiscal/research requests never set `peer_generation`, so every
  completed fiscal record failed PKEC restore. `block_or_enqueue_country_worker_asset`
  now stamps `_committed_generation`, as the sync cohort-cash path always did.
- `SAVE_SECTION_D7_PEER_EXT` (schema 53) had no ECP2 domain mapping and fell
  outside the restore section loop, so it was dropped on capture while the header
  still counted its rows. It now maps to the FISCAL domain and the loop runs to it.
- ENSO basin state restores lazily; `capture_climate_modes_state` now exports the
  pending copy until it is applied, so a save made right after a load keeps it.

**Load side**

- PKSR's IDP1 ideology section was dry-run against a catalog that only exists
  after PKCN. `restore_bundle` still checks checksum and marker, and defers the
  catalog-dependent check to worker start (which faults before any day on
  failure, with `ideology_pod_catalog_missing_at_worker_start`).
- The CPD2 checkpoint restore path never published `cell_country_slot`, so the
  player-country binding failed. Both restore paths now end in
  `publish_restored_country_territory()`.
- PKCN restore left the per-country Economy asset reservation lanes at the empty
  size `reset()` gave them; the first fiscal commit after a load wrote through a
  null base (0xC0000005 in `commit_economy_asset_transaction`).
  `decode_save_in_place` now sizes them.
- The fiscal peer record upper-bound check ran before the Country epoch it
  refers to was captured, rejecting every save with a completed tax transaction;
  it moved to `end_restore`.
- The ECP2 rollback backup reused the player-save gate "Country must be idle",
  which a restored Country with due commands fails; `ECP2_CAPTURE_ROLLBACK_BACKUP`
  skips only that gate.
- The first environment input after a load restarted at generation 1 below the
  restored Climate authority (`climate_input_generation_not_monotonic`): the host
  now publishes the saved environment generation in `restore_bundle`, and
  `map_generator.gd` reads the key the thread report actually exports
  (`simulation_environment_generation`; the old key never existed).
- A restore start is granted its requested mask immediately. Waiting for the
  first committed day left Economy routing (which reads the grant) on the sync
  Country peer — on the worker thread — for that day. `sync_runtime_domain_ownership()`
  mirrors the grant into the main-thread peers right after start and on every
  pulse, including when the runtime graph is not configured.
- The StageOps day machine reset to `Prelude` on every new day, which sent a
  fiscal continuation that had soft-completed across a day into `PlanEpoch`
  against its still-open epoch (`economy_pod_epoch_busy`). An open epoch now keeps
  advancing.

Several restore checks that combined many conditions under one reason now name
the failing rule (`save_catalog_scale_or_capacity_mismatch:<field>`,
`save_fiscal_peer_record_invalid:<field>`,
`save_fiscal_peer_completed_record_invalid:<field>`,
`restore_section_incomplete first=<section>`,
`ecp2_owned_state_capture_invalid:<rule>`).

Saves written before the 2026-09-20 content change are rejected with
`save_catalog_scale_or_capacity_mismatch:catalog_hash`; that is a genuine catalog
incompatibility, not a restore defect.

`game_save_roundtrip_test.gd` writes `manual_1..3`, so it refuses to run against
`user://saves`: run it with `PK_SAVE_DIR` pointing at a scratch directory.

## Validation

Minimum gates are configuration and repository tests; deterministic multi-start
tests across representative seeds/sizes; one-cell ownership, pairwise land
distance, unique names, resource, population,
and building assertions; `EnvironmentRuntime` byte-exact round-trip; PKCN/PKEC
focused tests; four Modifier domain round-trips; a PKFG round-trip that hashes `explored_arr` across save/load,
proves a wiped fog state is never persisted as empty exploration progress,
and then advances the restored runtime through at least one complete five-phase
economy settlement cycle (`game_save_roundtrip_test.gd`); debug/release GDExtension builds; and
desktop/narrow UI checks.
For economy changes, retain 60-day, two-year, and ten-year conservation soaks.

## Regional technology/economy bootstrap v9

Formal new games no longer grant four universal technologies or a universal settlement bundle.
`StartLocationPolicy` classifies each capital from the capital ring's Bio/resource/landform/climate
evidence and grants only the survival-core technologies: gathering, hunting, early trade, gold-panning,
deadwood collection, and hide scraping on cold highland. It does not grant a knowledge
practice and does not prebuild a knowledge shed. Remaining Stone-Age handling/knowledge nodes stay
in the catalog as ordinary researchable technologies; empty-prerequisite Stone-Age nodes require any
one completed knowledge practice before they can enter a research queue.
`MapGenerator` grants that core plus recursive structural prerequisites, including the zero-cost
`tech.early_trade`, writes `discovered_technology_*` for the one geographically chosen knowledge
practice, and deposits 3000 authored technology points in the country treasury.
`StarterSettlementBootstrap` prebuilds gathering and hunting camps when the
local reserves exist, one `deadwood_gathering_camp`, one placer-gold work site, an
`early_merchant_post`, and a hide-scraping shelter only on cold highland. It stocks the selected
knowledge-shed construction recipe so automatic investment can seed the first research
building after that practice completes. The planner emits parallel `starter_building_ids`/`starter_building_counts`;
the placer-gold site, merchant, and deadwood camp remain exactly one building. The supported families are coastal,
floodplain, cold highland, tropical forest, arid highland and temperate.

The bootstrap validates direct/required-technology tags and the food-seed construction contract.
Opening lots operate from granted production, output, and resource technologies. Formal starts always
top up timber, so the opening construction producer is deadwood. Other stone-age
`starter.construction` collectors (earth pit, reed, turf, rubble) keep a zero-bill
recipe so researching those leftovers can plant the camp without a prior extra material industry.
Other buildings still pay construction goods; bootstrap stock covers the prebuilt food core.
Formal `select_and_prepare` may fill missing
opening reserves to profile minimums as described in Start Policy; `evaluate_starter_route`
and inspector probes still fail closed on generated geography. Starting
buildings cannot require steel, coal, industrial chemicals, industrialists, managers,
landlords, serfs or indentured labor. The food bridge is 15 days of every locally granted, runnable
food sub-basket as authored by `survival_household`, split across multiple substitutes when present;
`processed_food` receives no fixed grant. Every generated country starts with exactly one
territory cell, one survival-core bundle, 20 population, core self-operated job-capacity slots at or below 20, employee
slots only on the placer-gold working and left unfilled, a founder operator cohort plus a native unemployed pool, one founder family and one notable
founder. The first economy cycles may reassign the unemployed cohort into the planned self-operated roles;
that is ordinary native employment matching and does not introduce employee relationships.

Save flow requires `PKTR v6` after journal/domain state. Missing/older PKTR, older PKCN/PKEF,
every non-v41 PKEC, and incompatible catalog hashes reject restore; no empty-trigger or technology
ID migration is provided.

