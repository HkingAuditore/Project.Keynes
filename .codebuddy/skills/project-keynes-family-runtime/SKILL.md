---
name: project-keynes-family-runtime
description: Guide Project.Keynes notable-family runtime development and review, covering deterministic family traits, authored FamilyEffect programs, per-cell prestige/influence, FamilyStore/NotablePersonStore, sparse membership/building ownership, conserved wealth and attribution, FAMILY_COMMIT/PERSON_COMMIT, PKEC v41, deterministic handles/hash, queries/UI, and sparse performance. Use when changing family traits/effects/prestige, family or important-person behavior, family-owned buildings, jobs/needs/wealth, Inspector/facade APIs, save/restore/tests, or family determinism and performance.
---

# Project.Keynes Notable-Family Runtime

Use this skill together with `project-keynes-economy-runtime`,
`cpp-dots-runtime-development`, and `project-keynes-runtime-architecture`. Also load
`project-keynes-tax-runtime` when changing taxable flows and `project-keynes-country-runtime` when
changing country identity, migration, treasury, or restore ordering.

## Ground the task

Read the current source before editing:

- Read `docs/cpp-dots-runtime/notable-family-runtime.md` completely for the authoritative model.
  Behavior preferences and FamilyEffect remain two pipes: conditions reuse Effect IR but freeze into
  CSR at `FAMILY_COMMIT`; conserved rewards are Economy opcodes, never Modifier stats.
- Read `docs/cpp-dots-runtime/notable-person-runtime.md` completely when important people, names,
  jobs, wealth, demand, lifecycle, queries, or PKEC v41 are in scope.
- Read `docs/cpp-dots-runtime/satisfaction-runtime.md` when branch `satisfaction_q16`, the
  promotion gate, or social-pressure events are in scope. Branch satisfaction is the
  population-weighted composite of member cohorts; it gates **promotion only** (a branch whose
  members live in the bottom pressure bands cannot rise) and never blocks decline. The
  25/35/40 prestige formula stays untouched.
- Read `gdext/src/economy_runtime.{h,cpp}` for `FamilyStore`, trait rolls, cell influence,
  relationship edges, employment, lifecycle, queries, hashing, and PKEC.
- Read `gdext/src/world_ext_economy.cpp`, `world_ext.h`, and `world_ext_bind_methods.cpp` for the
  public bridge.
- Read `Project/project-keynes/scripts/economy/economy_catalog.gd`, `economy_facade.gd`,
  `scripts/family/family_trait_catalog.gd`, trait definition/effect resources,
  `scripts/data/economy_profile.gd`, `family_surname_pack_profile.gd`,
  `person_given_name_pack_profile.gd`, and both default name packs for catalog, policy, and display
  boundaries.
- Read `Project/project-keynes/scripts/ui/cell_inspector_view_model.gd` and
  `scripts/game/world_runtime_host.gd` for player-visible read paths.
- Read `Project/project-keynes/tests/family_runtime_test.gd` before changing behavior or schemas.
- Read `docs/cpp-dots-runtime/economy-save-migration-sop.md` before changing persistence.

Use `rg` to locate all family policy, query, report, and schema call sites. Do not infer the current
contract from roadmap text or a previous chat.

## Preserve authority and identity

- Keep `NativeEconomyRuntime` as the sole mutable owner of families, trait rolls, cell influence,
  important people, membership, and building ownership. Keep GDScript limited to catalog/selector
  compilation, command packing, read-only queries, UI, and save orchestration.
- Model only notable families. Keep the anonymous majority implicit in `PopulationCohort`.
- Use generation-safe runtime handles and stable family IDs. Reuse the lowest free index and
  increment generation; never let an old handle resolve to a new family.
- Keep surnames as sorted stable IDs plus display text and weights. Include semantic surname changes
  in `family_catalog_hash`; never persist display text as identity.
- Keep given names as a second sorted stable catalog and include semantic changes in
  `person_catalog_hash`. Compose display names only at query/UI boundaries.
- Do not confuse notable families with `BuildingProfile.upgrade_family_id`, which names a technology
  upgrade series and has unrelated semantics.

## Preserve the sparse data model

- Store family scalars in `FamilyStore` SoA.
- Store immutable core and mutable additional traits as sparse `FamilyTraitRoll` rows. Store local
  prestige and binding state as generation-safe sparse `FamilyCellInfluence` rows.
- Store important-person scalars in `NotablePersonStore` SoA. A person must reference a valid family,
  cohort, and membership; never duplicate the represented population unit.
- Represent membership as sparse `FamilyMembershipEdge` rows and industry as sparse
  `FamilyBuildingOwnership` rows.
- Rebuild family→cohort, cohort→membership, family→building, building→ownership, and cell→family CSR
  deterministically at structural commit/restore boundaries. Keep CSR transient and out of PKEC and
  state hash.
- Compile stable-ID/category/sector/substitution/tag selectors to dense IDs and CSR/bitsets at catalog
  bootstrap. Rebuild reverse `(event_type, cell)` Trigger indexes and frozen consumption/resource
  factor caches after restore; never persist these derived caches.
- Rebuild family/cohort/cell/building→person and person→need CSR at person commit/restore. Keep these
  caches transient too.
- Rebuild `FamilyCellInfluence` at founder bootstrap (after committed summaries) so branch handles
  exist before day 0. `FAMILY_COMMIT` also rebuilds when memberships exist but no influence rows;
  do not wait `FAMILY_INFLUENCE_REFRESH_EPOCHS` for ledger commands.
- Keep building aggregation keyed by `(cell, building_type, owner_signature)`. Attach family
  `owned_count` to the stable building handle; never add family ID to the building-group key.
- Keep hot loops free of Godot objects, Dictionaries, strings, allocations, and all-family scans.
  Iterate the current cell's sparse family edges, active trait edges, selector hits, and event bindings;
  never scan `cell × family catalog` or `building × family`.

## Preserve people, wealth, and employment semantics

- Enforce `sum(family people for cohort) <= cohort.population`.
- Enforce `sum(family cash_claim for cohort) <= cohort.funds`.
- Treat `cash_claim` as attribution inside cohort funds, not a second wallet. Production, wages,
  consumption, subsidies, tax, and migration must continue to mutate existing conserved ledgers.
- Treat building asset value as a read-only estimate. Do not add it to money conservation.
- Fill a family-owned building's owner jobs only from local members with the exact owner signature.
  Fill anonymous buildings only from anonymous cohort capacity. Leave unqualified owner jobs vacant.
- Do not add manager/proxy ownership without a new explicit design and migration.
- Derive per-profession people, owner-employed, and employee-employed counts from membership and
  committed building employment. Do not create an independent family labor ledger.
- Bind important people only to already committed aggregate owner/employee fills. Preserve exact
  profession and role constraints, building handle traceability, and job tenure; never materialize
  personal job slots or modify aggregate employment from the person layer.
- Treat person `cash_claim` as a subset of membership claim. Attribute realized job/business income,
  buyer outflow, tax components, and need satisfaction after aggregate settlement. Important people
  do not submit market orders, own goods inventory, or become independent taxpayers.
- Compute one-person desired needs through the same native actor-demand helper, allocate only a stable
  prefix share of actual cohort spend, and leave anonymous residual unassigned. Never let attribution
  feed back into price formation or ledger totals.
- Move membership people and cash claim proportionally when cohort population changes cell or
  signature. Allow branches to emerge from actual migration, not duplicated records.

## Change formation and lifecycle safely

Keep formation deterministic and based on realized economy state:

1. Require the configured settlement tier and population threshold.
2. Require an active building with stable identity and an anonymously owned unit.
3. Require actual filled owner slots, target realized margin, sufficient projected owner income,
   and the founders' living-reserve cash.
4. Choose candidates with stable economic and ID tie-breaks.
5. Move one building unit, its actual owner operators, and a conserved household of
   owner-signature dependents (`owner_slots in the cell * family_household_people_per_owner_slot`,
   capped by `family_household_max_people`; defaults 256 per slot, 1024 cap, 8 families per
   cell) into the new family without changing total people, money, goods, or building count.
   Founders come from the owner signature only. Each FAMILY_COMMIT absorbs undersized
   branches after normalize (phase 0) and again after formation (phase 2) from remaining
   anonymous owner-signature people, leaving at least one anonymous person per cohort.
   All families in a cell together may not exceed half the local population; other
   professions stay anonymous so they can form their own families. Opening 20-person
   capitals therefore keep the two gathering-ground operators as the founder household.

The formal `StarterSettlementBootstrap v3` path is the only opening exception: it may declare one
founder building per capital so native bootstrap immediately creates one conserved founder family
and promotes one already-filled owner as its notable representative. Keep this declaration sparse,
validate exact cell/type/owner-signature columns, rebuild the normal family/person CSR, and never
lower the ordinary tier/population/profit/reserve thresholds to simulate an opening guarantee.
Treat `forced_named_cells` plus an actually bootstrapped `gathering_ground` as the native v2-packet
compatibility signature when explicit founder columns are absent. Repair an empty forced capital only
during days 0..30 and only after its exact owner posts are occupied; use authoritative membership edges
for idempotence and let the normal PERSON_COMMIT promotion path create and bind the representative.

Spread reviews by stable family/cell phase. Rebase `home_cell` to the largest branch. Dissolve zero-
population families immediately and apply configured consecutive decline reviews to weak families.
Keep genealogy, marriage, inheritance shares, family mergers, foreign remittance, and politics out of
scope unless their authority and save contracts are designed first.

## Preserve traits, prestige, and effects

- Roll 2–4 core traits without replacement from `world_seed + family_stable_id + catalog_version`.
  Validate weights, prerequisites, exclusions, and stepped Q16 strength. Core traits are immutable;
  grant/remove/set-strength for additional traits only through safely ordered commands.
- Behavior preference is intrinsic and does not scale with prestige. It may reweight legal building,
  profession, need, or good candidates, but must never bypass technology, capital, materials, resource,
  job, profitability, or conservation gates.
- A `(family, settlement cell)` branch exists only while local membership, attributed cash, or building
  ownership exists. Prestige score is `25% population share + 35% cash share + 40% building-asset share`;
  missing denominators contribute zero and are not renormalized.
- Revalue buildings with the same local replacement-capital basis as investment: frozen material prices
  plus standard operating reserve; include suspended buildings and exclude unfinished construction.
- Review every 30 days, staggered by stable branch ID. Promotion thresholds are 2/5/10/20/40 percent;
  demotion thresholds are 80 percent of each promotion threshold. Require two consecutive reviews in
  one direction, then jump directly to the computed target level.
- Coordinate branch Modifier/Trigger bindings only when traits, prestige, or branch existence changes.
  Multiple families stack without a family cap; stat bounds remain authoritative. Disable/remove clears
  Trigger accumulation immediately, and reward-origin facts must not recursively count.
- Compile authored FamilyEffect metadata and Trait-to-Effect CSR at the cold boundary. Keep the default
  family-effect catalog empty, route all six target classes through typed POD adapters, and arbitrate
  `REPLACE/REFRESH/ADD_STACK/MAX/MIN` in EffectRuntime by generation-safe target plus stack key.
- Revalidate producer `161` Family/Branch ENTITY handles at Modifier safe commit. Exact-good output must
  use shared-per-good plus sparse `(cell,good)` overrides; never allocate a cell-by-good matrix.
- Investment persists sponsor family and uses local attributed capital. Family population rewards add
  local membership; city rewards add the selected/default anonymous cohort. Both use explicit
  population-source ledger events. Free construction skips cash/material withdrawal but retains normal
  time, technology, cell, and resource legality. `i32_1` illegal falls back to payload `type_id`.

## Two pipes, not one VM

Keep trait **behavior preferences** (investment/hiring/consumption scoring) and `family.effect.*`
(Modifier / `EVENT_COMMAND`) as separate pipes. Reuse `EffectCondition` IR, metric slab, ACK, and
stack from EffectRuntime. Do not invent a family script VM. Evaluate behavior conditions only at
`FAMILY_COMMIT` / metric revision and freeze Q16 factors into CSR. Investment-day loops must not call
EffectRuntime per candidate.

## Preserve the frozen behavior CSR

- Compile `FamilyBehaviorPreference.conditions` and `score_term` into packed catalog columns.
- Freeze family→`(cell, score_term, axis, dense_id)` + Q16 at `FAMILY_COMMIT`. Unconditional edges
  use `cell=-1`. Failed conditions contribute factor 1 for that round.
- `family_trait_behavior_factor_q16` must look up that CSR. Never scan every trait roll or
  `cell × catalog`.
- Keep the product cap at 4× unless the catalog documents a different bound.

## Append family metrics only at the end

Dense ids 0–9 are occupied: magnitude, family population/cash, branch prestige/population, cell
temperature/precipitation/shortage/trade events/population. Current appended ids, still immutable
once shipped: 10 `cell.landform`, 11 `cell.essentials_shortage_q16`, 12
`branch.is_local_prestige_max`, 13 `cell.rain_event`, 14 `cell.resource_abundance_q16`. Further
signals append after 14. Publish through `metric_mask` and the existing branch/cell reverse
indexes. Missing metrics read 0. Do not reorder old ids.

## Score axes are packed columns

Tax sensitivity, local resource abundance, `upgrade_tier`, local popularity, and career mobility are
catalog `score_term` columns plus frozen scalars, not per-building Dictionaries. They may not bypass
technology, capital, resource, or profitability gates. Negative career mobility must reduce people
moved, not only drop hiring preference.

## Conserved rewards are Economy commands

`family.absorb_anonymous`, `family.purchase_discount`, payload-copied `family.free_building`, and
optional SETTLE `population_reward` (`i32_1` / Effect payload[3]) mutate existing ledgers:
`POPULATION_SOURCE`, membership absorption, consumption subsidy/escrow. Never register cash,
population, or goods as Modifier stats. Never create a family wallet. Buyer discounts with no fiscal
budget are zero and must still conserve. Opcode 20 remains canal-only and is not an Effect command.
`family.population_reward` with `i32_0=-1` freezes the next SETTLE payload[3] and does not mint.
Day 0 `FAMILY_COMMIT` may still absorb anonymous people into the household, so tests must assert
unchanged cell population and zero ledger error, not family-snapshot equality.

## Trait technology gate

Compile `prerequisite_technology_keys` on `FamilyTraitDefinition` the same way FamilyEffect does.
`assign_core_family_traits` filters with origin/home `cell_has_technology`. Additional-trait commands
may still grant a locked trait. Catalog hash mismatch rejects old saves; do not bump PKEC for this.

## Extend in this order

1. New condition signal → append a metric, then write the behavior/effect.
2. New scoring semantic → add an axis/`score_term` column, then touch investment/employment loops.
3. New conserved reward → add a typed Economy opcode/adapter, then wire `EVENT_COMMAND`.
Keep `default_family_effects.tres` empty. Do not put Buff-table examples in the default catalog.

## Keep scheduling and queries bounded

- Keep `FAMILY_COMMIT` after `BUILDING_COMMIT` and before `AGGREGATE_PUBLISH`. That stage freezes
  behavior CSR and publishes FamilyEffect metrics; it does not evaluate effect programs.
- Keep `PERSON_COMMIT` after `FAMILY_COMMIT` and before `AGGREGATE_PUBLISH`. Worker market ranges may
  emit person attribution into `MarketResult`; they must not mutate person authority directly.
- Keep half-computed family structure invisible to gameplay and save.
- Use `family_cells_per_slice` only for formation scan continuation. Bound edge growth with
  `family_max_per_cell`; do not expose unused tuning knobs.
- Preserve `OFF`, `PROBE`, and `ACTIVE` semantics. `OFF` with no historical families must remain a
  constant-time skip.
- Bound the overlay with max-per-family, max-per-cell, max-total, and plan need-count caps. Complexity
  must scale with sparse people/local buildings/need edges, not total population.
- Keep `get_family_cell_snapshot`, `get_family_snapshot`, `get_family_traits`,
  `get_family_branches`, `get_family_branch_effects`, and `get_family_industries` read-only,
  paginated where applicable, and safe only between native slices.
- Route additional-trait mutations through `queue_family_trait_mutation`; order by effective day,
  priority, sequence, and submission order at the normal safe boundary.
- Keep family-person, person snapshot, person needs, and building-person reverse queries read-only and
  paginated. Attach display names and stable catalog IDs in `EconomyFacade`.
- Add display IDs/text in `EconomyFacade`; never copy a global family/cohort/building matrix into
  GDScript or UI state.

## Evolve PKEC deliberately

Current writer/reader is exact-version PKEC v41. Sections 15–17 store family records, memberships, and ownership;
18–19 store important people and need attribution; 20 stores trait rolls; 21 stores family-cell
influence (including the branch `satisfaction_q16` added in v30); 22 stores ordered future trait
mutations; 23 is END. Persist tombstone generations,
semantic family/person/trait catalog identity, person state, construction sponsor handles, prestige
review state, stable branch IDs, immutable origin/culture/split identity, and the fixed split threshold
100. The cell record carries seven frozen environment lanes, including precipitation. PKTR v6 persists
dynamic branch Trigger accumulation, PKEF v11 persists FamilyEffect lifecycle/stack/transaction state,
and Modifier schema v3 persists magnitude. Do not persist continuation budgets, FamilyEffect bindings,
stack groups, selector/CSR/reverse indexes,
frozen factor caches, worker results, or other reconstructed scratch.

On restore, reject every non-v41 schema. Validate handles, unique stable identities/names, nonnegative rows, membership/person
claim subset constraints, owned count against building count, exact person building/role references,
sorted unique person needs, sponsor handles, and exact section completion before bootstrapping. Rebuild
CSR and derived bindings only after validation. PKEC v29 and earlier are explicitly incompatible;
there is no empty-family/person migration path in the v30 reader.

Include every authoritative family/person scalar and stable edge in state hash. Exclude display text,
pagination, reports, CSR offsets, and other reconstructed caches. Test cold-bootstrap and committed
round trips; zero-length and zero-filled logical state must hash equivalently when PKEC treats them as
equivalent.

## Verify

From the repository root, run static checks first:

```powershell
rg -n "FamilyStore|FamilyTraitRoll|FamilyCellInfluence|NotablePersonStore|FAMILY_COMMIT|PERSON_COMMIT|get_family_branch_effects|family_trait_catalog_hash" gdext\src Project\project-keynes docs\cpp-dots-runtime
git diff --check
```

Build C++ changes in both configurations:

```powershell
Push-Location gdext
python -m SCons platform=windows target=template_debug dev_build=no -j6
python -m SCons platform=windows target=template_release dev_build=no -j6
Pop-Location
```

Run `family_runtime_test.gd`, `family_behavior_effect_runtime_test.gd`,
`family_effect_output_runtime_test.gd`, `family_effect_stack_runtime_test.gd`,
`trigger_family_branch_test.gd`, `modifier_runtime_test.gd`,
`natural_resource_pass_test.gd`, `settlement_runtime_test.gd`, and affected economy/tax/save tests.
Run the existing economy verifier for broad changes:

```powershell
& .\.codex\skills\project-keynes-economy-runtime\scripts\verify_economy_runtime.ps1
```

For performance-sensitive changes, run at least 50 production-path days with
`project-keynes-headless-perf`. Report family/branch/trait/binding and edge counts,
economy avg/p95/max, ledger failures,
fatal state, and the largest changed stage. Require population, money, and goods errors to remain zero.

## Report completion

Report native/GDScript authority, trait/prestige/effect and family/person semantics,
PKEC/PKTR/Modifier compatibility, conservation and deterministic-hash evidence, query/UI changes,
sparse work counts, avg/p95/max, and intentional non-goals.
