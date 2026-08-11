# Runtime Grounding

Use the live source as authority. This reference records the current design boundaries that are easy to violate.

## Read Order

- `Project/project-keynes/scripts/economy/technology_catalog.gd`
- `Project/project-keynes/scripts/research/research_signal_catalog.gd`
- `Project/project-keynes/scripts/trigger/trigger_catalog.gd`
- `Project/project-keynes/scripts/data/building_profile.gd`
- `Project/project-keynes/scripts/economy/economy_catalog.gd`
- `Project/project-keynes/scripts/modifier/modifier_catalog.gd`
- `Project/project-keynes/data/economy/buildings/*.tres`
- `Project/project-keynes/data/goods/*.tres`
- `gdext/src/country_runtime.*`
- `gdext/src/economy_runtime*`
- `gdext/src/modifier_runtime.*`
- `docs/cpp-dots-runtime/technology-tree-runtime.md`
- `docs/cpp-dots-runtime/native-modifier-runtime.md`

## Authority Boundaries

- `TechnologyCatalog` owns stable technology definitions and compiled condition IR.
- `NativeCountryRuntime` owns discovery, queues, progress, completion, pending activation, policy, and technology treasury.
- Economy content compiles BuildingProfile, GoodProfile, recipes, resources, jobs, and technology tags; it does not synthesize technology IDs.
- Modifier Runtime owns normalized numeric modifiers; consumers read frozen effective factors.
- Technology effects must activate through the existing Effect/Modifier path before completion tags become visible.

## Active Research Conditions

Supported v1 predicates/operators:

- `TECH_COMPLETED`
- `SIGNAL_PRESENT`
- `SIGNAL_COUNT`
- `ALL_OF`
- `ANY_OF`
- `AT_LEAST`
- `NOT`

Declared but unsupported sources must not be used as if active: `COUNTRY_FLAG`, `COUNTRY_STAT`, `BUILDING_COUNT`, `CURRENT_STATE`, `EVENT_OCCURRED`, `SEQUENCE`, and `WITHIN_DAYS`.

Legacy `prerequisite_ids` remain an additional structural hard gate. An `ANY_OF` expression cannot bypass a technology that remains in that array.

## Existing Signal Vocabulary

The research signal catalog includes:

- crops and biological discoveries such as maize, wheat, rice, potato, cotton, flax, spice, rubber, and livestock;
- resources such as freshwater, fertile soil, arable/paddy/plantation land, coal, oil, natural gas, copper, iron, precious metals, salt, rare earth, bauxite, limestone, silica sand, phosphate, tin, lead, zinc, manganese, sulfur, and flint;
- landforms such as river valley, floodplain, delta, coast, marsh, forest, grassland, arid basin, mountain, high plateau, steep slope, tundra, and stable wind corridor;
- weather experience such as flood, drought, typhoon, monsoon, frost, freeze-thaw, heatwave, prolonged wet season, storm surge, and repeated crop failure;
- contact signals created by actual cross-country delivery of crop or ore samples;
- practice breakthroughs for seed saving, rainfed adaptation, paddy control, terrace maintenance, mine support, mine drainage, kiln temperature, steam sealing, motor winding, assembly line, digital control, automation, and related work.

Use exact IDs from the live catalog.

## Existing Technology Modifier Consumers

Confirm the live catalog before use. Current technology-facing country consumers include:

- research efficiencies: agriculture, engineering, science, society;
- research cost factor;
- research-institution output factor;
- sector output factors: agriculture, extractive, manufacturing, energy, knowledge;
- generated building-family output factors;
- generated exact-building-type output factors;
- construction cost and time factors;
- domestic trade capacity and speed factors;
- drought, flood, cold-stress, and heat-stress production-loss factors.

There is no generic energy-research or manufacturing-research efficiency. Do not invent them.

There is no arbitrary terrain-by-building-method Modifier. Use BuildingProfile conditions and recipes for effects such as “terrace farms on mountains produce more food”.

Do not use Modifier to mint or destroy money, goods, population, technology points, or natural-resource reserves.

## BuildingProfile Effect Surface

Use content data for:

- technology and required-technology tags;
- construction goods, quantities, and days;
- owner and employee professions, slots, wages, and policies;
- input goods and quantities;
- output goods and quantities;
- local natural-resource access, extraction, capacity use, and generation;
- production-climate profile;
- postfix placement/construction conditions including river and geographic signals;
- upgrade family and tier.

This is the correct surface for targeted output, labor replacement, new inputs, resource access, and terrain restrictions.

## Known Grounding Traps

### Explicit Economic Sectors

`BuildingProfile.economic_sector_id` is now mandatory and limited to agriculture, extractive,
manufacturing, energy, and knowledge. `EconomyCatalog` compiles that value directly to the existing
dense sector integer; it no longer infers every collector as extractive. Continue preferring targeted
building-family factors and content recipes, and audit the explicit field when adding a building.

### Dormant Practice Paths

A breakthrough can exist in TriggerCatalog but remain unreachable if no active building or method emits the corresponding technology-practice fact. Confirm the content binding before using a practice signal as a critical gate.

### Misleading Names

A building name does not prove its technology or placement binding. Example: a resource named “water-powered sawmill” may still be tagged to another technology and lack a river condition. Inspect the resource fields.

### Labor And Input Claims

There is no general labor-reduction technology Modifier. Express changes through employee slots and recipe differences. For example, compare `precision_farm.tres` and `automated_farm.tres` rather than claiming a generic “labor -30%” effect.

## Binding Status Vocabulary

- `existing_binding`: IDs, tags, content, and consumers already align.
- `catalog_rebind`: existing content needs technology tags or placement conditions changed.
- `new_content`: existing runtime fields can represent the proposal.
- `modifier_only`: existing stat and consumer are sufficient.
- `blocked`: a known bug or unsupported source prevents correct behavior.
- `new_runtime`: requires new packed state, consumer, scheduling, persistence, and tests.
