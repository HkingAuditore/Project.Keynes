---
name: project-keynes-military-runtime
description: Guide Project.Keynes native military runtime work covering MilitaryCore SoA stores (soldier lots, training, armies, paths, engagements, wars, truces, reparations, cell controller, military stocks and convoys), the D-day committed digest and D+1 Country/Economy intent bridge, military_daily scheduling and whole-graph ACTIVE catch-up, pathfinding/supply/threat fields, plan-then-replay battles, incremental fronts, peace/annex treaties, military AI, PKMI v1 save ordering, render snapshot and z5-11 map layers, events 40-47, performance and validation. Use when changing military_core*.cpp/.h, military_bridge.h, world_ext_military.cpp, MilitaryFacade, MilitaryCatalogCompiler, military_catalog.json, MilitaryDailySystem, military map layers/shaders, military UI commands, or military-related Country/Economy opcodes.
---

# Project.Keynes Military Runtime

Treat `pk::MilitaryCore` (owned by `DCWorldExt`) as the only authority for military state. It is a
main-thread synchronous runtime, not a worker domain. GDScript is orchestration, catalog compilation,
command packing and read-only UI/rendering.

## When to use

- Any edit to `gdext/src/military_*`, `world_ext_military.cpp`, `world_ext_economy_military.cpp`.
- Military catalog (`data/military/military_catalog.json`, `military_catalog_compiler.gd`), units,
  equipment categories, state buildings, supply classes.
- `military_daily` scheduling, `WorldRuntimeHost` military catch-up, PKMI save/restore.
- Military map layers (`scripts/rendering/military_*`, `shaders/military_*`) or military panel commands.
- Country opcodes 21/23/24/27 or Economy hooks used by Military.

Also load `project-keynes-runtime-architecture` (doc sync rules), `project-keynes-country-runtime`
and `project-keynes-economy-runtime` when touching their command surfaces.

## Mandatory grounding

Read before editing (code wins over plans):

1. `docs/cpp-dots-runtime/military-runtime.md` (current truth + known gaps §12).
2. `gdext/src/military_bridge.h`, `military_core.h` (frozen contract), the relevant `military_core_*.cpp`.
3. `gdext/src/world_ext_military.cpp` (digest capture, `translate_military_intent`, receipts, snapshots).
4. `scripts/military/military_facade.gd`, `scripts/simulation/systems/military_daily_system.gd`.
5. Wiring: `map_generator.gd` (`_configure_military_runtime`, `_maybe_register_military_system`),
   `world_runtime_host.gd` (`_drain_runtime_military_commits`), `game_save_coordinator.gd` (`pkmi`).
6. Plans only for intent: `docs/plans/military-system-design.md`, `military-implementation-contract.md`.

## Enlistment pipeline (soldiers = Economy cohorts)

Full write-up: `docs/cpp-dots-runtime/military-recruitment-pipeline.md`. Military never owns people. A
barracks post is filled by converting an Economy cohort in the **same cell** from
`(unemployed|employee, ethnicity)` to `(soldier, same ethnicity)`. The chain and where it used to break:

```text
MilitaryCore::run_recruitment          quota = posts - present - pending; deficit = target - soldiers
  -> MILITARY_INTENT_ENLIST / _LEVY    count = heads, source_id = cell
  -> DCWorldExt::translate_military_intent
       resolve source cohort handle   military_cohort_handle_any_ethnicity(cell, unemployed|levy)
       resolve target signature       military_signature_for_cell_ethnicity(cell, soldier)   <- OWNER side
       emit command opcode 24         payload0=heads, payload1=source sig, target_country=dest sig, cell
  -> submit_economy_commands           refused under whole-graph ACTIVE (economy_legacy_ingress_disabled)
  -> POD lane (submit_economy_pod_commands)
       admission                     opcode 24 must be in the admitted range (1..23 + 24)
       plan_day                      routes through _command_executor -> NativeEconomyRuntime::apply_pod_command
       command_from_pod lanes        i32_0=target_cell, i32_1=target_country, i64_0=payload0, i64_1=payload1
  -> NativeEconomyRuntime::apply_command case COMMAND_MILITARY_CONVERT_COHORT
       find(source sig) / find-or-allocate(dest sig) in the SAME store, move heads, no cross-cell transfer
  -> receipt fold (world_ext_economy_military.cpp)
       POD rows carry request_id == 0 and settle on the committed-day boundary, reading back
       military_soldier_heads(cell) so Military books only what Economy actually holds
  -> MilitaryCore::reconcile_receipts  creates the garrison lot (never a slot id in the command)
```

Non-obvious rules that cost real debugging time:

- **Never pass a cohort slot id across the bridge.** POD mirror slots and live-runtime slots are different
  index spaces; a stale slot silently no-ops or faults. Always name cohorts by `(cell, signature)`.
- **A signature id is not a profession id.** Resolve with the economy runtime's own table
  (`military_signature_for_cell_ethnicity`), never by using the dense profession index.
- **Every bridge row must carry its requested `count`** (`row.count`), because the receipt fold settles
  `min(applied, row.count)`; a zero there silently refunds every enlistment.
- **Convert through the economy's structural path, never by writing `population`.** A direct write skips the
  slot/page bookkeeping and eventually fails `validate_shape_and_values()`
  (`economy_pod_ledger_shape_invalid` → worker fault, clock paused) around day 70.
- **The same conversion reaches the switch twice** (POD plan and epoch drain): dedupe by `sequence`, or
  Economy converts twice as many people as asked (economy 15 vs military 12).
- **Enlist is pre-applied like discharge** (emit → add to garrison lot immediately, receipt refunds the
  shortfall). Booking only on the receipt leaves the roster a day behind, keeps the quota open, and
  over-recruits (economy 19 vs military 6).
- **Roster reconcile must not trim in-flight enlistments**: the trim ceiling is `economy heads + pending_enlist`,
  and a cell only participates when its digest actually carries population (a busy read view reports zeros and
  would wipe the roster).
- **State-service professions are exempt from the local labour gates.** `profession_available()` must be
  skipped and the `non_unemployed_cohort_has_idle_population` audit must skip them: a barracks is a
  Military building and never appears as an Economy job seat.
- **Army-scoped commands may omit the country**; `MilitaryCore::submit` derives it from the army owner
  *before* the `country == 0` gate, otherwise `command_missing_country` reaches the map layer.
- **`military_should_run` must return true while a bridge row is open** (`receipt_pending == 1`). Otherwise the
  core looks idle, the day never steps, and the row can only be settled by that day — a deadlock
  (`last_step_day` frozen while `pending_intents` stays > 0).

## Invariants

- Read the **committed day-D** Country/Economy digest; mutate only Military stores; every Country/Economy
  change is a `MilitaryIntent` translated to a **D+1** command batch. Never write another domain directly.
- One step per day: `run_military_daily` must refuse `day <= _military_last_step_day` (double-submit guard).
- Integer state only (q16 / MONEY_SCALE 10000 / GOODS_SCALE 1000); RNG only `mil::rng(seed, key, day)`;
  iteration orders are slot/cell/edge-key order so worker vs scalar hashes match.
- Hot loops: no Dictionary/Variant/String/allocation; reuse `thread_local`/stamp scratch.
- Peace with no work → `should_run=false` → zero slices.
- Armies are generational handles (`gen<<32|slot`); countries are stored by handle only.
- Controller lives in Military (PKMI); ownership changes only via Country commands (`country_committed`).
- Derived structures (cell index, supply/threat fields, front set, cell_state index) are never saved or
  hashed; rebuild them on restore.
- PKMI restore is transactional (decode to temp, validate, swap); PKMI provider stays after `pkcn` and
  before `pkef`/`ecp2`.
- Military layers stay below fog z12; foreign armies/battles/convoys are fog-gated.
- `military_daily` registers before the native/legacy fork in `_setup_sus`; in whole-graph ACTIVE its
  `should_run` is false and the host replays committed days (≤4/frame).

## Extension SOPs

**Add a unit type**
1. Add the row to `data/military/military_catalog.json` (`class`, `era`, `tech`, stats, `equipment` ≤ 4,
   `supply_idle/combat` in the 6-class ABI order). Exactly one `militia: true`.
2. Make sure `MilitaryCatalogCompiler` resolves its tech/goods; units stay sorted by stable id (PKMI identity).
3. Catalog hash changes → old PKMI is rejected (`pkmi_catalog_mismatch`); note "new game only" in docs.
4. Respect `MILITARY_MAX_UNIT_TYPES=64`; update UI icon keys if a new class appears (class enum is ABI).

**Add an intent kind**
1. Append to `MilitaryIntentKind` in `military_bridge.h` (never renumber; Economy <20, Country ≥20).
2. Emit it from the owning stage into the `intents` vector (not directly to another runtime).
3. Add a `case` in `DCWorldExt::translate_military_intent` with explicit authority (1 Country / 2 Economy),
   `receipt_pending`, and command encoding; extend `reconcile_receipts` if Military must reconcile it.
4. Update the mapping table in `military-runtime.md` §5 and this skill.

**Add a Country opcode for Military**
1. Implement it in `country_runtime.h` enum and in both the sync path and the shared/worker kernel
   (validation + apply + event), keeping batch atomicity; update `effect_runtime` opcode caps if gated.
2. Mirror it in `country_facade.gd` `Opcode` and, if it moves territory, in the territory-evidence filter.
3. Add the `MCOUNTRY_*` constant and translation in `world_ext_military.cpp`.
4. Update authority matrix, `military-runtime.md`, and Country docs/skill.

**Add a map layer**
1. Create `scripts/rendering/military_<name>_layer.gd` with `const Z_INDEX` < 12, `set_enabled`,
   `set_player_slot`, `debug_snapshot`.
2. Register it in `MilitaryMapLayers.LAYER_NODES`, `_all_layers()`, and `_push_layers()`; feed data only
   from `MilitaryRenderFeed` (one native poll per frame; rebuild on revision change).
3. If it needs new snapshot fields, add them to `get_military_render_snapshot` as Packed SoA.
4. Apply fog gating for foreign information; update z table in `military-runtime.md` §9 and
   `vision-fog-and-borders.md`. Verify shaders on a real renderer (headless does not compile them).

## Verification

1. Static: `rg` for changed op names/intents/fields across C++, GDScript and docs; `git diff --check`.
2. Build the GDExtension (debug **and** release) after C++ changes; `military_core_selftest.cpp` must link.
   Bump `DOTS_EXT_OUTPUT_BASENAME` instead of overwriting a DLL Godot has loaded, then repoint
   `dots_ext.gdextension` (`template_debug` / `template_release`, exact file names).
3. `godot --headless --path Project/project-keynes -s res://tests/military/military_native_binding_test.gd`
   (self test, bench p95 ≤ 0.5 ms @ 2400/400 — met; the 100k/2048/4096 budget of 2 ms is **not** met,
   ~7 ms avg / ~18 ms p95, dominated by market-index cold start and consumption).
4. `res://tests/military/military_runtime_smoke_test.gd` — full-world acceptance (must end `0 failures`):
   barracks, recruitment, army.create, war declare, movement, and a PKMI round trip **after** the seasonal
   terrain refresh (day 31). This is the test that proves the enlistment pipeline above.
5. `res://tests/military/military_living_world_probe.gd` (`-- --days=N`) — reporting probe, not assertions:
   per-5-day JSON of military report, country/cell snapshots and the capital's profession populations. Use it
   to see soldiers accumulate (day 60: `soldier=12`) and to reproduce in the running game (drop `--headless`).
6. `res://tests/military/economy_day_progress_probe.gd` — proves whether the Economy day (and therefore a POD
   command's plan) actually advances: prints `last_committed_day`, epoch/busy state and military
   `pending_intents`. Use it before blaming the bridge when nothing lands.
7. For schedule changes: run a session in both legacy/domain ACTIVE and whole-graph ACTIVE and confirm one
   military step per committed day (`last_step_day`, no `military_day_already_stepped` storms).
8. Sync docs: `military-runtime.md`, `runtime-authority-matrix.md`, `scheduling-and-job-graph.md`,
   `vision-fog-and-borders.md`, `game-flow-start-save.md`, `references/system-map.md`, this skill.
   Report unrun gates explicitly.

## Debugging playbook (order matters)

1. `pending_intents` stuck high → the bridge queued rows nobody resolved: check the receipt fold and whether
   the authority actually ran the day (`economy_day_progress_probe.gd`).
2. `pending_intents` falls to 0 but soldiers stay 0 → the command is being settled as *not applied*: check
   the destination signature resolution and `row.count`.
3. Economy faults with an audit error right after recruitment → a state-service cohort is being judged by a
   labour invariant; exempt it on the owner side, never by writing Economy from the bridge.
4. Never add a temporary "assume applied" shortcut to the receipt fold: it silently inflates the roster
   (military 12 vs economy 10 was exactly that) — read the committed cohort back instead.

