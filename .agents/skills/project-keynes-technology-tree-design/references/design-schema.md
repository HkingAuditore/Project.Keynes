# Auditable Design JSON

Use this schema when a technology-network proposal should be checked by `audit_technology_design.py`.

## Top Level

```json
{
  "eras": ["stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment", "steam", "electrical", "atomic", "information", "intelligent"],
  "nodes": [],
  "edges": []
}
```

Exactly eleven ordered eras are required.

The live catalog is schema v4. Its `nodes[]` remain researchable `tech.*` definitions only. When an
auditable design needs to describe a multi-knowledge production binding, add a top-level
`application_intersections[]` entry instead of a paid application node:

```json
{
  "id": "app.household_tuber_garden",
  "name": "家庭块茎试种圃",
  "description": "块茎繁育与家户生产共同成熟后的过渡方式",
  "era": "agrarian",
  "domain": "agriculture",
  "industry_chain_id": "potato",
  "layout_order": 12,
  "required_technology_ids": ["tech.potato_propagation", "tech.household_production"],
  "building_ids": ["household_tuber_garden"]
}
```

Intersection IDs use `app.*`, have zero cost, are automatically active when every requirement is
complete, and are static presentation/content data. They do not enter the research DAG, dense IDs,
queues, progress, Effect, Modifier, milestones, or save schemas. The requirement set must exactly
match the referenced building's primary ANY technology plus ALL support tags.

## Node

```json
{
  "id": "tech.terrace_farming",
  "name": "梯田农业",
  "era": "agrarian",
  "domain": "agriculture",
  "role": "branch",
  "branch_family": "highland_agriculture",
  "conditions": [
    {"kind": "TECH_COMPLETED", "id": "tech.composite_tools"},
    {"kind": "SIGNAL_PRESENT", "id": "landform.mountain"},
    {"kind": "SIGNAL_PRESENT", "id": "breakthrough.terrace_maintenance"}
  ],
  "condition_logic": "ALL_OF(tech, highland, water_or_practice)",
  "unlocks": [
    {"type": "building", "id": "terrace_farm", "status": "new_content"},
    {"type": "resource_access", "id": "arable_land", "status": "existing_binding"}
  ],
  "effects": [
    {
      "subject": "building.terrace_farm",
      "attribute": "grain_and_vegetable_base_output",
      "operation": "add_percent",
      "value": 40,
      "implementation": "building_profile_recipe",
      "status": "new_content"
    },
    {
      "subject": "country",
      "attribute": "country.construction.cost_factor",
      "operation": "multiply",
      "value": 0.96,
      "implementation": "modifier",
      "status": "modifier_only"
    }
  ],
  "tradeoffs": ["mountain_or_high_plateau_only", "uses_arable_land"],
  "terminal": false
}
```

Required node fields:

- `id`, `name`, `era`, `domain`, `role`
- `conditions` as a non-empty array
- at least one item across `unlocks` and `effects`

Recommended fields:

- `branch_family` for branch-chain audits
- `condition_logic`
- `tradeoffs`
- `terminal` and `terminal_reason` for intentional endpoints

Allowed roles: `backbone`, `branch`.

Allowed condition kinds:

- `TECH_COMPLETED`
- `SIGNAL_PRESENT`
- `SIGNAL_COUNT`
- `ALL_OF`
- `ANY_OF`
- `AT_LEAST`
- `NOT`

Allowed unlock types:

- `building`
- `method`
- `good`
- `profession`
- `resource_access`

Allowed statuses:

- `existing_binding`
- `catalog_rebind`
- `new_content`
- `modifier_only`
- `blocked`
- `new_runtime`

Every effect requires:

- `subject`
- `attribute`
- `operation`
- `value`
- `implementation`
- `status`

## Edge

```json
{
  "from": "tech.terrace_farming",
  "to": "tech.soil_experimentation",
  "kind": "alternative",
  "label": "field experience"
}
```

Allowed kinds:

- `hard`
- `alternative`
- `application`

Only `hard` and `alternative` edges participate in the research-prerequisite DAG audit. An
`application` edge in this proposal format is explanatory feedback only and must not be compiled as a
research prerequisite; live multi-knowledge building bindings belong in `application_intersections[]`.

## Audit Behavior

Errors include malformed schema, duplicate IDs, missing edge endpoints, prerequisite cycles, missing effects/unlocks, unclear effect fields, unsupported condition operators, and stranded nonterminal branches.

Warnings include technology-only branch conditions, thin late eras, missing branch-family metadata, weak branch-family era span, missing tradeoffs, blocked effects, and application edges that point backward without a label.

Use `--strict` to convert warnings into a failing exit code.
