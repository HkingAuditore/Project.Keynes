# Technology Runtime Architecture and Contracts

## Authority map

| Concern | Sole authority |
| --- | --- |
| Domains, eras, nodes, cost, prerequisites, layout, effect references | `TechnologyCatalog` |
| Discovery, completion, pending, sparse progress, queues, weights, policy, technology treasury | `NativeCountryRuntime` |
| Production, market stock, private purchase, domestic trade, government procurement | `NativeEconomyRuntime` |
| Permanent numerical technology effects | Country-domain `ModifierRuntime` |
| Display and command submission | `TechnologyWorkspace` through `CountryFacade` |

There is deliberately no independent `TechnologyRuntime`. `EconomyCatalog` receives the compiled
technology catalog and validates every `tech.*` reference. It must not invent IDs.

## Catalog contract

Current baseline:

- 81 definitions: four completed roots and 77 researchable technologies.
- 11 eras and four domains: agriculture, engineering, science, society.
- Normal nodes require all direct prerequisites.
- A new era also requires the preceding era milestone.
- Each era milestone requires any two of its four marked candidates.
- Discovery reveals only immediate successors after prerequisite completion; reveal never completes.
- Map occupancy (`cell.bio_occupancy_bits`) is current species presence, seeded as a full
  origin-habitat fill plus vacant habitat-class packing (cosmopolitan reed excepted)
  with a continent-scale food + fiber/livestock floor.
  Country research signals are permanent seen-knowledge; local extinction does not revoke
  evidence. Trade still yields `contact.*` only.

Compilation produces stable-ID lookup, dense IDs in topological order, prerequisite and milestone CSR,
reverse unlock indices, public definitions, Modifier definition keys, and a catalog hash. Validate
duplicate/missing IDs, cycles, backward era edges, unreachable milestones, missing Modifier references,
and invalid economy `tech.*` tags before native bootstrap.

Key files:

- `Project/project-keynes/scripts/economy/technology_catalog.gd`
- `Project/project-keynes/scripts/data/technology_domain_profile.gd`
- `Project/project-keynes/scripts/data/technology_era_profile.gd`
- `Project/project-keynes/scripts/data/technology_profile.gd`
- `Project/project-keynes/scripts/economy/economy_catalog.gd`

## Country research contract

`NativeCountryRuntime` owns per-country:

- discovered/completed/pending bitsets;
- sorted sparse `(technology_dense_id, progress)` entries for nonzero progress;
- four queues, each limited to eight entries;
- four basis-point weights whose sum is exactly 10,000;
- milestone carrier domain;
- automatic procurement enabled flag and daily cash limit;
- `deferred_unallocated_points`;
- monotonic purchased, consumed, progress, and completion counters.

Queue heads do not auto-skip when blocked. Removing or moving an item preserves progress. A normal
technology remains in its own domain; a milestone may be assigned to any carrier domain.

Research allocation uses integer largest remainder. It must produce exactly 7/3 for 10 points at
70%/30%, preserve minimum units deterministically, carry overflow to the next technology in the same
domain, and defer empty/blocked-domain shares without leaking them elsewhere. A weight change or new
queue entry releases deferred stock for redistribution.

Consumed technology points leave the country goods treasury at their physical quantity. Progress is
`consumed quantity × domain research-efficiency Modifier`, then research-cost effects are applied by the
defined contract. Keep physical consumption and virtual progress separately auditable.

Key files:

- `gdext/src/country_runtime.h`
- `gdext/src/country_runtime.cpp`
- `gdext/src/world_ext_country.cpp`
- `Project/project-keynes/scripts/country/country_facade.gd`

## Daily ordering and activation

The important boundary is:

1. Economy buildings reserve and consume production inputs.
2. Households and firms perform private purchases.
3. Government research procurement buys remaining domestic technology-points stock.
4. Remaining regional imbalances may enter domestic trade.
5. The next country research day consumes treasury technology points.
6. Completed research enters `pending` and immediately registers its stable
   Effect instance. Production scheduling runs Effect (85) before Country (255),
   so the instance must exist before the next Effect morning; waiting until the
   next country activation loop misses that slot and leaves the node pending.
   The country slice also raises `country_day_barrier` when Effect still has due
   work, so the continuation drain can ACK the same calendar day.
7. On the following activation boundary, apply its permanent `UNIQUE_SOURCE` Modifier
   after the Effect transaction ACKs, or accept the Modifier if that UNIQUE_SOURCE is
   already present. Pending nodes re-queue unacked Effect instances each country day
   so a missed Effect morning cannot leave them pending forever.
8. Only after successful application expose the completed tag and economic unlocks.

This keeps market settlement one day ahead of research and makes effects/unlocks visible atomically.
GM reveal changes discovery only. GM grant must use the same pending/activation path.

## Technology-points economy

`technology_points` is a stock good using the normal goods scale and domestic trade. Research
institutions are ordinary `industrial` buildings in the `research_institution` upgrade family. Their
output depends on real employment and ordinary inputs, enters the local merchant market, and does not
teleport into the country treasury.

Government procurement:

- executes after private demand;
- scans owned markets in stable `(price, cell_id)` order;
- is limited by budget, country cash, market stock, and remaining queued research demand;
- debits country cash, pays local merchants, removes market stock, and credits country goods treasury;
- participates in demand EMA, prices, authoritative hashes, and cash/goods conservation;
- does not perform cross-country purchases in v1.

Modern technical households consume a small amount through the education/culture bundle. Early
scholarly households do not create premature modern knowledge demand. Selected mid/late buildings use
explicit technology-points soft inputs; never infer them dynamically in a hot loop.

## Modifier contract

Each researchable technology maps to a permanent country Modifier definition:

- source type `TECH`;
- source ID `technology dense ID + 1`;
- lifecycle permanent;
- stacking `UNIQUE_SOURCE`.

Consumers include four domain research efficiencies, research cost, research-institution output, five
economic-sector outputs, construction cost/time, and domestic-trade capacity/speed. Building catalogs
compile one main sector dense ID; production queries a frozen country factor rather than creating one
Modifier per building instance.

Modifiers may alter production results, consumed-points-to-progress conversion, construction
parameters, or trade capacity. They must not directly mutate ledger quantities.

## UI contract

`TechnologyWorkspace` is a full-screen section mounted by the lightweight `CountryPanel` shell, which
owns nothing but a section title bar and the content area. The tree is a single self-drawn
`TechnologyTreeView`; `GraphEdit` is no longer used and no per-technology child node is created.
Geometry is baked once by the pure-function `TechnologyTreeLayout` and never moves.

Fog clips drawing to the researchable set plus its immediate unknown frontier. Revealed-but-locked
nodes (hard prerequisites incomplete) stay unnamed like undiscovered ones. The pan/zoom range
equals the visible bounding box, so neither the catalog size nor the remaining era count is
observable. Unknown nodes must not leak semantic content through any visible or assistive channel.
Domain color is only supplemental; pair states with icon, border, and text.

Every policy control commits on release and there is no submit button: the weight dial renormalises
the other three domains and uses largest-remainder rounding to keep `sum == 10000`; the budget slider
is expressed as a treasury share per day with "off" at the far-left stop. Queue drag/drop submits
country commands and never mutates authoritative state locally.

Key files:

- `Project/project-keynes/scripts/ui/technology_tree_layout.gd`
- `Project/project-keynes/scripts/ui/components/technology_workspace.gd`
- `Project/project-keynes/scripts/ui/components/technology_tree_view.gd`
- `Project/project-keynes/scripts/ui/components/research_weight_dial.gd`
- `Project/project-keynes/scripts/ui/components/procurement_budget_slider.gd`
- `Project/project-keynes/scripts/ui/components/technology_detail_card.gd`
- `Project/project-keynes/scripts/ui/components/technology_queue_row.gd`
- `Project/project-keynes/scripts/ui/components/technology_queue_drop_zone.gd`
- `Project/project-keynes/scripts/ui/components/country_panel.gd`
- `Project/project-keynes/scripts/ui/components/section_placeholder_screen.gd`
- `Project/project-keynes/scripts/ui/country_view_model.gd`

## Save and startup contract

Current versions:

- `NewGameConfig` v2: starting cash, procurement budget, four weights, automatic-purchase flag.
- PKCN v3: catalog hash, all research state, queues, policy, deferred stock, pending items, counters.
- PKEC v21: procurement stage/counters, technology-points market/in-transit state, audit baselines.

Restore PKCN before PKEC. Reject old technology-tree schemas with
`legacy_technology_tree_save_unsupported`; reject catalog or Modifier hash mismatch. Do not silently
migrate or populate defaults during restore.
