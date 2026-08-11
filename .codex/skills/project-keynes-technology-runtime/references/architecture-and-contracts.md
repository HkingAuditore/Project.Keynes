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

- 360 definitions: 22 regional-start processing nodes and 338 researchable technologies.
- 11 eras, four domains, four backbones, and sixteen specialist lanes.
- Each era has exactly sixteen lane anchors and requires any five for its milestone.
- Completed hard prerequisites are the sole research-eligibility gate.
- Nonstone specialist anchors require the previous milestone and previous same-lane anchor;
  backbone anchors require the previous milestone.
- Geography, resource, contact and practice evidence appears only in reveal-condition IR. It may
  inspire and reveal a node but never bypass a prerequisite or complete research.

`Project/project-keynes/data/technology/technology_network.json` is the sole authoring source.
`TechnologyCatalog` strictly parses it and remains the sole compiled/runtime authority. The authoring
file includes explicit hard prerequisites, reveal conditions, Modifier terms, content bindings and
the static visual edge kinds: hard, application, and milestone_candidate. `alternative` remains a
recognized format value for compatibility but the current catalog emits none.

Compilation produces stable-ID lookup, dense IDs in topological order, prerequisite/milestone and
Modifier-term CSR, unique Effect recipe identity, route/condition IR, reverse unlock indices and public
definitions. Economy adds reverse Good/Building/Resource bindings and Trigger definition identity.
Validate duplicate/missing IDs, cycles, backward era edges, unreachable milestones, empty consumers,
missing Modifier references, direct profession gates, and invalid economy `tech.*` tags before bootstrap.

The native catalog keeps Chinese player-facing authoring text in the exact catalog identity.
`public_definitions()` exposes those names and summaries plus Chinese `route_display_names` beside
stable `route.*` tags. Internal IDs remain hidden from players; catalog text changes intentionally
invalidate strict PKCN saves in this no-migration rebuild.

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
6. Completed research enters `pending`.
7. On the following activation boundary, apply its permanent `UNIQUE_SOURCE` Modifier.
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
economic-sector outputs, every production-family output, generated exact-building-type output stats,
four climate-loss factors, construction cost/time, and domestic-trade capacity/speed. Economy freezes
country×family, country×building-type, and climate factors at epoch capture rather than creating one
Country Modifier per building instance.

Modifiers may alter production results, consumed-points-to-progress conversion, construction
parameters, or trade capacity. They must not directly mutate ledger quantities.

## UI contract

`TechnologyWorkspace` is a full-screen section mounted by the lightweight `CountryPanel` shell, which
owns nothing but a section title bar and the content area. The tree is a single self-drawn
`TechnologyTreeView`; `GraphEdit` is no longer used and no per-technology child node is created.
Geometry is baked once by the pure-function `TechnologyTreeLayout` and never moves.

Fog clips drawing to the discovered set plus its immediate unknown frontier, and the pan/zoom range
equals the visible bounding box, so neither the catalog size nor the remaining era count is
observable. Unknown nodes must not leak semantic content through any visible or assistive channel.
Domain color is only supplemental; pair states with icon, border, and text.

All revealed technology names, effect summaries, route badges, prerequisite names, and research-signal
evidence are Chinese presentation strings. UI code resolves those labels from public definitions and
signal metadata; it never displays stable IDs or native authoring text as the normal player-facing label.

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

- `NewGameConfig` v3: foreign-country count, starting cash, procurement budget, four weights,
  automatic-purchase flag; v2 migrates with zero foreign countries.
- PKCN v11: catalog/content/Trigger identity, all research/signal state, queues, policy, deferred stock,
  pending items, evidence provenance and counters.
- PKEF v9: unique technology recipes, transactions/ACK and era-reward plans.
- PKTR v4: Trigger accumulation and pending effects.
- PKEC v34: procurement/practice state, technology-points market/in-transit state and audit baselines.

Restore PKCN before PKEC. Reject old PKCN/PKEF/PKTR schemas and any related catalog identity change
with `catalog_hash_mismatch`. Do not silently migrate IDs or populate defaults during restore.
