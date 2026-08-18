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

- 361 definitions: 23 regional-start processing nodes and 338 researchable technologies.
- 11 eras, four domains, four backbones, and sixteen specialist lanes.
- Each era has exactly sixteen lane anchors and requires any five for its milestone.
- Completed hard prerequisites are the sole research-eligibility gate.
- Nonstone specialist anchors require the previous milestone and previous same-lane anchor;
  backbone anchors require the previous milestone.
- Geography, resource, contact and practice evidence appears only in reveal-condition IR. It may
  inspire and reveal a node but never bypass a prerequisite or complete research.
- Rivers, lakes and wetlands publish `landform.freshwater_access`; there is no
  `resource.freshwater` deposit. Keep hydrology evidence separate from extractable
  `freshwater_fish` and other `ResourceProfile` entries.
- Map occupancy (`cell.bio_occupancy_bits`) answers “what lives here now”. Generation seeds each
  UNIQUE_HEARTH species by filling envelope∩carrier on one origin landmass, then packs vacant
  `habitat_class` niches on other continent-scale landmasses. Reed is `COSMOPOLITAN`.
  Continent-scale landmasses keep a playable food + fiber/livestock floor.
  Satellite islets are skipped unless they are the unique argmax
  endemic pocket. Runtime neighbor diffusion stays inside a province. Country research signals
  answer “has this country seen it”; extinction does not revoke evidence. Inspector local species
  read occupancy; `SIGNAL_PRESENT` / `SIGNAL_COUNT` and start-location routes read country knowledge.
- `tech.early_trade` is a zero-cost regional-start node revealed by visible natural gold or silver.
  It unlocks `early_merchant_post`; every formal opening route grants it and prebuilds that service.

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
6. Completed research enters `pending` and immediately registers its stable
   Effect instance. Production scheduling runs Effect (85) before Country (255),
   so the instance must exist before the next Effect morning; waiting until the
   next country activation loop misses that slot and leaves the node pending.
   The country slice also raises `country_day_barrier` when Effect still has due
   work, so the continuation drain can ACK the same calendar day.
7. On the following activation boundary, apply its permanent `UNIQUE_SOURCE` Modifier
   after the Effect transaction ACKs, or accept the Modifier if that UNIQUE_SOURCE is
   already present. If the Effect instance exists but still has not ACKed, the country
   day applies the same UNIQUE_SOURCE directly (idempotent replace) so a missed Effect
   morning, incomplete continuation drain, or wedged Effect slice cannot leave the node
   pending forever. Pending nodes also re-queue unacked Effect instances each country day.
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
owns nothing but a section title bar and the content area. `GraphEdit` is not used and no
per-technology child node is created. `TechnologyTreeLayout.build()` bakes the immutable full DAG;
`build_focus()` derives a bounded one-domain, three-era working set for the self-drawn
`TechnologyTreeView`. The four authoritative research domains own top-level navigation; `main_lane`
only orders nodes inside dependency layers and remains visible route metadata. Cross-domain hard
relations become selected-node navigation portals while same-domain out-of-window links use era navigation; selected application relations use dashed
lines, and milestone candidates collapse into a progress summary.

The separate self-drawn `TechnologyOverviewView` is a domain-by-visible-era navigation map. Its four
rows are stable while columns exist only for discovered eras, and activation returns to focus mode.
Policy is a permanent 280px left column. Detail is a 384px right drawer below 1600 px and may be pinned
only on wider screens; its content wraps within the drawer and scrolls vertically. Opening focus prefers
the queue head of the highest-weight non-empty domain, otherwise the deepest available frontier.

Fog clips focus drawing to the researchable set plus its immediate unknown frontier. Revealed-but-locked
nodes stay unnamed like undiscovered ones. Overview omits
undiscovered route names and future era columns, so neither the catalog size nor the remaining era count
is observable. Unknown nodes must not leak semantic content through any visible or assistive channel.
Domain color is only supplemental; pair states with icon, border, and text.

All revealed technology names, effect summaries, route badges, prerequisite names, and research-signal
evidence are Chinese presentation strings. UI code resolves those labels from public definitions and
signal metadata; it never displays stable IDs or native authoring text as the normal player-facing label.

Every policy control commits on release and there is no submit button: the weight dial renormalises
the other three domains and uses largest-remainder rounding to keep `sum == 10000`; the budget slider
is expressed as a treasury share per day with "off" at the far-left stop. Queue drag/drop submits
country commands and never mutates authoritative state locally.

Daily refreshes do not rebuild focused geometry when only progress changes. Hidden overview geometry
is not refreshed; relation rows rebuild only after selected or related technology states change.

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
