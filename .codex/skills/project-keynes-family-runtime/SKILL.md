---
name: project-keynes-family-runtime
description: Guide Project.Keynes notable-family and important-person runtime development and review, covering FamilyStore/NotablePersonStore, membership and building-ownership edges, surname/given-name catalogs, family and person lifecycle/migration, exact owner/employee job attribution, conserved wealth and realized consumption attribution, read-only queries/UI, FAMILY_COMMIT/PERSON_COMMIT scheduling, PKEC v27, deterministic handles/hash, and sparse performance. Use when changing family or important-person data/behavior, family-owned buildings, person jobs/profession/needs/wealth, family economy policy/names, Inspector/facade APIs, save/restore/migration/tests, or diagnosing family/person conservation, determinism, and performance.
---

# Project.Keynes Notable-Family Runtime

Use this skill together with `project-keynes-economy-runtime`,
`cpp-dots-runtime-development`, and `project-keynes-runtime-architecture`. Also load
`project-keynes-tax-runtime` when changing taxable flows and `project-keynes-country-runtime` when
changing country identity, migration, treasury, or restore ordering.

## Ground the task

Read the current source before editing:

- Read `docs/cpp-dots-runtime/notable-family-runtime.md` completely for the authoritative model.
- Read `docs/cpp-dots-runtime/notable-person-runtime.md` completely when important people, names,
  jobs, wealth, demand, lifecycle, queries, or PKEC v27 are in scope.
- Read `gdext/src/economy_runtime.{h,cpp}` for `FamilyStore`, relationship edges, employment,
  lifecycle, queries, hashing, and PKEC.
- Read `gdext/src/world_ext_economy.cpp`, `world_ext.h`, and `world_ext_bind_methods.cpp` for the
  public bridge.
- Read `Project/project-keynes/scripts/economy/economy_catalog.gd`, `economy_facade.gd`,
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

- Keep `NativeEconomyRuntime` as the sole mutable owner of families, important people, membership,
  and building ownership. Keep GDScript limited to catalog compilation, policy packing, read-only
  queries, UI, and save orchestration.
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
- Store important-person scalars in `NotablePersonStore` SoA. A person must reference a valid family,
  cohort, and membership; never duplicate the represented population unit.
- Represent membership as sparse `FamilyMembershipEdge` rows and industry as sparse
  `FamilyBuildingOwnership` rows.
- Rebuild family→cohort, cohort→membership, family→building, building→ownership, and cell→family CSR
  deterministically at structural commit/restore boundaries. Keep CSR transient and out of PKEC and
  state hash.
- Rebuild family/cohort/cell/building→person and person→need CSR at person commit/restore. Keep these
  caches transient too.
- Keep building aggregation keyed by `(cell, building_type, owner_signature)`. Attach family
  `owned_count` to the stable building handle; never add family ID to the building-group key.
- Keep hot loops free of Godot objects, Dictionaries, strings, allocations, and all-family scans.
  Iterate active building cells and their local sparse ownership/membership edges.

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
5. Move one building unit and its actual owner operators into the new family without changing total
   people, money, goods, or building count.

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

## Keep scheduling and queries bounded

- Keep `FAMILY_COMMIT` after `BUILDING_COMMIT` and before `AGGREGATE_PUBLISH`.
- Keep `PERSON_COMMIT` after `FAMILY_COMMIT` and before `AGGREGATE_PUBLISH`. Worker market ranges may
  emit person attribution into `MarketResult`; they must not mutate person authority directly.
- Keep half-computed family structure invisible to gameplay and save.
- Use `family_cells_per_slice` only for formation scan continuation. Bound edge growth with
  `family_max_per_cell`; do not expose unused tuning knobs.
- Preserve `OFF`, `PROBE`, and `ACTIVE` semantics. `OFF` with no historical families must remain a
  constant-time skip.
- Bound the overlay with max-per-family, max-per-cell, max-total, and plan need-count caps. Complexity
  must scale with sparse people/local buildings/need edges, not total population.
- Keep `get_family_cell_snapshot`, `get_family_snapshot`, `get_family_branches`, and
  `get_family_industries` read-only, paginated, and safe only between native slices.
- Keep family-person, person snapshot, person needs, and building-person reverse queries read-only and
  paginated. Attach display names and stable catalog IDs in `EconomyFacade`.
- Add display IDs/text in `EconomyFacade`; never copy a global family/cohort/building matrix into
  GDScript or UI state.

## Evolve PKEC deliberately

Current PKEC v27 uses sections 15–17 for family records, memberships, and ownership, sections 18–19
for important-person records and need attribution, and section 20 as END. Persist inactive tombstone
generations, semantic family/person policy, both name catalog hashes, person job/wealth/welfare state,
and construction sponsor handles. Do not persist continuation budgets, CSR caches, worker results, or
other reconstructed scratch.

On restore, validate handles, unique stable identities/names, nonnegative rows, membership/person
claim subset constraints, owned count against building count, exact person building/role references,
sorted unique person needs, sponsor handles, and exact section completion before bootstrapping. Rebuild
CSR only after validation. Preserve v26 as `v26_empty_notable_person_bootstrap` and v25 as
`v25_empty_family_bootstrap`.

Include every authoritative family/person scalar and stable edge in state hash. Exclude display text,
pagination, reports, CSR offsets, and other reconstructed caches. Test cold-bootstrap and committed
round trips; zero-length and zero-filled logical state must hash equivalently when PKEC treats them as
equivalent.

## Verify

From the repository root, run static checks first:

```powershell
rg -n "FamilyStore|NotablePersonStore|FamilyMembershipEdge|PersonNeedState|FAMILY_COMMIT|PERSON_COMMIT|person_catalog_hash|get_notable_person" gdext\src Project\project-keynes docs\cpp-dots-runtime
git diff --check
```

Build C++ changes in both configurations:

```powershell
Push-Location gdext
python -m SCons platform=windows target=template_debug dev_build=no -j6
python -m SCons platform=windows target=template_release dev_build=no -j6
Pop-Location
```

Run `family_runtime_test.gd`, `settlement_runtime_test.gd`, and the affected economy/tax/save tests.
Run the existing economy verifier for broad changes:

```powershell
& .\.codex\skills\project-keynes-economy-runtime\scripts\verify_economy_runtime.ps1
```

For performance-sensitive changes, run at least 50 production-path days with
`project-keynes-headless-perf`. Report family/edge counts, economy avg/p95/max, ledger failures,
fatal state, and the largest changed stage. Require population, money, and goods errors to remain zero.

## Report completion

Report native/GDScript authority, changed family/person ownership/employment/attribution semantics,
PKEC compatibility, conservation and deterministic-hash evidence, query/UI changes, family/person/edge
scale, avg/p95/max, and intentional non-goals.
