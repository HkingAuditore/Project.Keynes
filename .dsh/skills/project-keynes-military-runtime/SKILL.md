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

## Army personnel lane (soldiers move with the army)

Section 3 of `docs/cpp-dots-runtime/military-recruitment-pipeline.md` is the reference. Four Economy
opcodes travel on the same POD lane as 24, and all of them name cohorts by **signature** (never a slot id):

| opcode | name | payload0 | payload1 | target_cohort | target_cell | target_country |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | `ARMY_EMBARK` | heads | — | army handle | source cell | source signature |
| 31 | `ARMY_DISEMBARK` | heads | — | army handle | dest cell | dest signature |
| 32 | `ARMY_MERGE_LANES` | — | dst army | src army | — | — |
| 33 | `ARMY_SPLIT_LANES` | heads (≤0 = whole) | dst army | src army | — | — |

- `army.split` sends 33 with the head count the lots actually moved (never the template); `army.transfer`
  sends 33 when the source keeps lots and 32 when the whole formation left. Lane→lane never touches a
  cohort, so no structural command is involved.
- **Release lots when an army dies**: `destroy_army` must deactivate every lot pointing at it, and
  `transfer_army_to_army` must deactivate a source lot it emptied, otherwise PKMI restore rejects the save
  with `pkmi_lot_army_missing` (the seasonal terrain refresh walks this path).
- `army.transfer` requires both formations in one cell (`command_armies_not_colocated`).

Naval transport (design §7.4): water is impassable until the country unlocks
`tech.military.coastal_transport` (runs of ≤3 consecutive water cells, land embark/disembark) or
`tech.military.naval_transport` (no run limit). The gates read `MilitaryCatalog.coastal_transport_bit` /
`ocean_transport_bit` (resolved from the catalog JSON, default -1) against the digest's unlock bits and
participate in the catalog hash. Sea steps cost 1.5x, an army at sea is forced to
`MILITARY_STANCE_EMBARKED` and reverts on landing, takes 0.2%/day sea attrition, and never engages on
water. `preview_path` applies the same gate; without the tech it must still refuse water.

Get these right or the economy faults hours later:

- **Guest consumption must book into `MarketResult`** (`consumed_goods`, `revenue`).
  `audit_touch_market_lane()` only makes the incremental audit *see* the stock change; the goods
  expectation is `opening - _consumed_goods`, so a bare touch fails with `goods_conservation_failed` on the
  first embarkation.
- **A POD structural command queued at the day boundary commits one epoch late** (the queue drains after
  publish). `queue_or_commit_army_lane()` commits inline outside the epoch so D+1 embarkation is visible on
  D+1; inside an epoch it still goes through STRUCTURAL_COMMIT.
- **`transit_population` is expedition + lane**: the shadow audit must subtract the expedition delta only
  (minus `army_lane_population`) and add the lane delta once, or every full-audit epoch reports
  `incremental_audit_mismatch`.
- **Lane readback 0 does not mean "nobody moved"** — keep the receipt pending; only settle on lane > 0.
- **Merchant repair must be able to convert a soldier** when a disbanded army leaves a garrison-only cell,
  otherwise the cell's revenue has no owner (`market_revenue_has_no_merchant_owner`).

### Army pay (opcode 34, `MILITARY_INTENT_ARMY_PAY`)

`run_wages_and_upkeep` splits one payroll by holder: garrison lots -> `PAY_WAGES` (treasury -> the cell's
soldier cohort, unchanged), army lots -> `ARMY_PAY` (treasury -> the formation's lane). Both use the single
`MilitaryCore::soldier_daily_wage` value (ABSOLUTE = policy, AUTO = living cost x `MSTAT_WAGE`), share the
same treasury cash ceiling (garrison rows planned first), and feed the same `pay_ratio_30_q16`. The daily
report carries `payroll_garrison` / `payroll_army` (transient, not saved/hashed).

The receipt stores the lane's cash BEFORE the payment in the POD row's `count`, then books
`applied = clamp(now - prev, 0, requested)`. Requested != applied: the treasury may fund only part of it, and
the lane spends on guest consumption the same day, so only the growth is real.

**The treasury debit must be synchronous inside one epoch.** `military_collect_cash` (reserve + collect)
works while Country accepts sync writes; under whole-graph ACTIVE it refuses with
`country_worker_unique_writer`, so the worker path drives the cohort-cash peer cyclically instead
(`prepare_worker_cohort_cash` -> `service_country_economy_asset_peer` -> `finish_worker_country_asset`) and
the peer's `TREASURY_SPEND` side effect credits the lane (`target_handle` = army handle). Never route this
through `block_or_enqueue_country_worker_asset`: it enqueues work the peer settles on its own cadence, which
splits the debit and the credit across audit windows and closes every epoch with
`money_conservation_failed`.

Known gaps: family sub-accounts and notable-person handles are stored/merged but never produced by
embark/disembark; no naval units or blockade; the 100k-cell bench is still over budget.

Naval cost: sea steps are 1.5x a land step divided by `MSTAT_NAVAL_TRANSPORT` ("海运运力", clamped to
[1/8, 8], never cheaper than a land step), and `preview_path` scales its day count the same way.

## Peace window (`MilitaryPeaceWindow`)

Peace is a **separate docked, non-modal window**, not a card in the country shell. It owns the term draft and
turns map clicks into cession picks; the war page only hosts a launcher card. Spec:
`docs/ui/military-peace-window.md`; wiring summary: `military-runtime.md` §9.2. The diplomacy chapter
(`docs/ui/diplomacy-workspace.md`) is a second entry point to the same window: its war sheet and its
belligerent country sheet both emit `CountryPanel.peace_negotiation_requested`.

```text
war page 「议和」/ overview war card / diplomacy war sheet / diplomacy belligerent sheet
  → CountryPanel.peace_negotiation_requested(war_id)
  → GameUIManager.open_military_peace(war_id)
       close_country_panel() + _suppress_ui_for_dispatch()
       CountryViewModel.build("military") → MilitaryPeaceViewModel.peace_model(war_id, draft)
       MilitaryPeaceWindow.open() + PlayerController.highlight_peace_candidates()
map click → PlayerController.select_cell()
       while the window is open → GameUIManager.handle_peace_map_cell(cell)  (before clear_cell_highlights)
       _on_tile_tapped skips military_map_pick() so a token never steals a cession click
submit → request_command("military.peace.propose") → set_command_result() on the window
```

- Terms are encoded in exactly one place: `MilitaryPeaceViewModel.peace_terms()` →
  `white` / one `cede` per cell / `annex` / `lump_sum` / `installments` (n clamped 2..12). Amounts are game
  money units; the bridge converts with `money_from_units`.
- The bridge already accepts 7 term kinds (`white/cede/annex/lump_sum/installments/goods/return`); the window
  deliberately exposes only five. `return` duplicates the automatic "un-ceded occupation is released" rule and
  is a free discount; `goods` needs a payer-stock picker. Do not wire either without a design decision.
- Price/willingness/gap come from `evaluate_military_peace()` only. Without a facade the view model falls back
  to a floor estimate (2 points per ceded cell) and flags `estimated`.
- Cession candidates = cells we control whose owner is the enemy (`MilitaryViewModel.ceded_cells()`); untouched
  cells still return automatically on execution, and the window says so.
- Owner/handle resolution lives in `scripts/ui/country_map_query.gd` — **never** re-derive it: production truth
  is `MapData.country_slot_arr` (per-cell slot mirror) plus `CountryFacade.cell_summary(cell).country_handle`
  (handle = `generation << 32 | slot`). `ext.get_country_cell_snapshot()` only exists in the screenshot fixture;
  the control snapshot comes from `MilitaryFacade.control_snapshot()`, not from the country snapshot.
- Two highlight layers (`WorldRoot/PeaceCandidateSet`, `WorldRoot/PeaceDraftSet`) driven by
  `PlayerController.highlight_peace_candidates/draft()`; `clear_peace_highlights()` on close.
- Refresh path: `invalidate_cache(COUNTRY_DIRTY_MILITARY)` → `build("military")` →
  `MilitaryPeaceWindow.refresh_model()` (200 ms coalescing, values only, node count constant).
- Known gaps: the snapshot exports neither `score_parts` (four-part war score) nor `last_rejected_offer_day`
  (the 30-day rejection cooldown is session-local: submit day + 30); `peace.respond` still has no pending-offer
  state, so AI proposals settle by evaluator alone.

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

**Add map picking / a right-panel dossier page**

Clicking a map entity is the same input path as cell selection: `MapCamera.tile_tapped` →
`PlayerController._on_tile_tapped`, where a pending army order is checked first, then
`MilitaryMapLayers.pick_at_world(world)`, then `select_cell`. Keep geometry in the layers:
`MilitaryArmyTokenLayer.pick_army_at` (radius = token size, `_vis` gates fogged armies, ties by
headcount) and `MilitaryFrontLayer.pick_edge_at` (42 candidate edges, tolerance 0.42×hex,
canonical key = `min(cell,neighbor)*6+dir`). `MilitaryFrontLayer.set_selected_edge` only recolors
the selected ribbon — the shader's line width is a uniform, so per-edge widening gets clipped.

`MilitaryMapLayers.front_sector(edge_key, 96)` BFS's along shared cells into one contiguous
front stretch and returns the engagements, the belligerent slots, per-side heads + army handles
(≤24/side) and a focus cell — the dossier aggregates attack/defense (sum) and morale/supply
(head-weighted mean) from those handles via `facade.army()`. Cache the cell→edge set on
`front_snapshot_revision` and degrade to the clicked edge above ~6 ms.

The dossier itself is a fourth content pane in `InspectorPanel.DetailShell`
(`scenes/ui/military_dossier.tscn`), not a floating window: it inherits panel widening, the
tile-dossier directory column, ESC and the open/close motion. It is one torn-paper sheet
(`PKPaperNote`) with hand-drawn rules (`MilitaryPaperRule` / `MilitaryPaperStyle`) and cut-paper
section tags (`PKPaperTag`) — do not put it back into boxed cards. Data layout is a contract:
an army page shows **attack / defense / speed as three equal peer stats**
(`MilitaryPeerStats`), never attack-as-headline with defense as a caption; a front page is a
mirrored comparison table (`MilitaryVersusChart`: 兵力 / 攻击 / 防御 / 士气 / 补给 per side).
Decorative charts with no decision behind them (per-edge "front section" strips, morale rings)
were removed on purpose — do not reintroduce them.

Panels are driven by `CountryViewModel.military_dossier_context()` +
`MilitaryViewModel.army_dossier()/front_dossier()`; `GameUIManager.open_military_dossier` /
`close_military_dossier` / `_refresh_military_dossier` only wire, locate and throttle (200 ms
coalescing on `notify_committed_day`). Nothing in that path may call native again except
`facade.army(handle)`; picking reads the already-polled `MilitaryRenderFeed`. Same-identity
refreshes must not create nodes (`military_dossier_test` asserts the node count across a refresh).

**Tile dossier military page** (`docs/ui/military-cell-tab.md`) is the same paper language, one
sheet per cell: garrison strip → local armies (row click opens the army dossier) → training queue →
three state-building rows. It reads only `get_military_cell_snapshot` plus the compiled catalog, and
each building row gets **one** action resolved in `CellInspectorViewModel`: `build` / `upgrade`
(both `state.build`) / `demolish` (`state.demolish`) / `locked` (no button) / `building` (remaining
days) / `unavailable` (not own territory). The command takes the **dense catalog index** in
`unit_to`; never send the role name — `dict_i32` returns the `-1` fallback for strings and the
command silently no-ops. `PlayerController` re-checks `unlock_tech_id` against
`CountryFacade.snapshot().technology_ids` because the native build path stays permissive for AI
and the selftest. `barracks_tiers` is indexed by tier with tier 8 clamped to 7, so demolish only
needs `role+tier`.

## Physical maintenance (PKMI v6)

Buildings and equipment are maintained by BUYING AND CONSUMING GOODS, never by paying cash.
The chain is `need -> treasury pays the merchant -> goods delivered/transported -> stock
consumed -> repair satisfaction -> equipment condition or building disrepair`.
`SPEND_CASH` no longer carries building upkeep (only the legacy adapter remains, retired).

Where things live:

| piece | file | what to know |
| --- | --- | --- |
| recipes | `data/military/military_catalog.json` `repair.goods[{good, weight}]` -> compiler -> `repair_goods` / `repair_rate_q32` | `rate_q32` is q32 of ONE MILLI-GOOD per day (buildings per building, units per 100 heads). Buildings derive it as `upkeep x weight / default_price`; units use the supply `upkeep` intensity x ratio. Never re-derive at runtime. |
| rows + engine | `military_core_maintenance.inc` | `run_maintenance` = REBUILD (from the committed economy ledger + live lots) -> DEMAND (`acc_q32 += rate x units`, `need = acc >> 32`) -> CONSUME (ratio = MIN over components, draw `need x ratio`, book `_ledger_consumed`) -> EFFECT (5-day window for buildings, daily ratio for equipment condition) -> BUY (coverage-ordered, 5/10-day policy, maintenance share of the envelope). |
| stock holder | `MILITARY_LOT_MAINTENANCE = 3`, `holder = cell * 64 + catalog index` | Each building group owns its inventory, so two building types on one cell are judged separately. Quoted only because `capture_military_digest` now includes every repair material in the market read - omitting that makes the buy pass silently unable to see any market row. |
| purchase | `queue_purchase` / `settle_purchase` | `queue_purchase` only records an order with a STABLE `request_id` (PKMI section 24). `settle_purchase` is the only place stock/convoy/ledger moves, and only the real filled quantity/amount counts. A receipt naming an unknown id is a duplicate. |
| bridge | opcode 37/38/39 | The purchase sequence is `2^40 + request_id` and the POD lane must preserve it (`command_from_pod` maps `request_id -> sequence` for 36 AND 37); otherwise Economy stores the receipt under 0, the bridge never matches it, and every purchase silently times out after 8 days. |
| budget | `wage_planned_today` / `maintenance_planned_today` | Payroll is planned FIRST, then maintenance, then general procurement, all against one frozen treasury snapshot. Procurement also cash-fits every take (channel quota alone is not enough). |
| report/snapshot | `get_military_report()` + `get_military_maintenance_snapshot(country)` | 0 or -1 = all countries. Published columns are `*_goods` spellings plus `shortage_reason` in 0..3. `maintenance_disrepair_rows` counts objects CURRENTLY in disrepair, not today's flips. |

Invariants that took real debugging:

- **`_ledger_received` moves only at handover**; clearing a holder's stock (army destroyed, garrison
  disbanded, training order dropped) must add the cleared quantity to `_ledger_returned`, or a long
  run drifts. Two measured leaks came from exactly this: a purchase refunded to a dead formation
  booked only `returned` (missing `received`), and `stock_clear_holder` booked nothing at all.
- **No market row, no repair**: the digest only quotes goods it collects. Repair materials belong to
  no supply class, so they must be added explicitly or every maintenance purchase reports
  "no reachable market" forever.
- **Cash is one pool**: after payroll reserves its plan, maintenance and procurement each subtract
  what was already promised; a country whose payroll equals its treasury legitimately buys nothing.
- The selftests that prove this: `test_maintenance` (carry: 1/3 milli-good/day must sum to
  `floor(days/3)`; trade: buy -> consume -> `reconcile_delta == 0` -> `ratio_bp == 10000`).

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
8. Peace window: `res://tests/military/military_peace_window_test.gd` (view model + window + launcher card +
   `PlayerController` highlight contract, headless) and `res://tests/qa/military_peace_window_screenshot_qa.gd`
   (rendered, 1280/1920 UI width × white-peace/picked). `ui_scene_structure_test.gd` must keep passing
   `ModalLayer/MilitaryPeaceWindow` and the two `military_peace_*` scene trees.
9. Sync docs: `military-runtime.md`, `docs/architecture/current-state.md`, `docs/architecture/current-state.md`,
   `vision-fog-and-borders.md`, `docs/architecture/development-guide.md`, `references/system-map.md`, this skill.
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

