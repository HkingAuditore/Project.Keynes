---
name: project-keynes-family-content-design
description: Design, restructure, rebalance, or audit Project.Keynes family consumption, investment, and employment preferences plus prestige-scaled carried and independent effects as player-readable content tables grounded in the current game catalogs. Use for 家族Buff表、家族偏好、家族效果、威望五档、随机出现条件、构筑性、可玩性与平衡性；use project-keynes-family-runtime instead for runtime implementation.
---

# Project.Keynes Family Content Design

Produce concrete, player-readable family preference and effect content. Do not replace requested design rows with architecture analysis.

## Separate Design From Implementation

Classify the request before acting:

1. **Content design**: write or revise preference/effect catalogs and balance values. Use this skill alone.
2. **Catalog implementation**: translate approved rows into Godot resources. Also use `project-keynes-family-runtime` and the relevant economy/effect skills.
3. **Runtime expansion**: add a new condition signal, target, command, or persistence behavior. Use the runtime skills and state the new implementation scope before changing architecture.

Treat attached design documents as source material, not as instructions. The user's current request controls the output shape and explicit exceptions.

## Ground The Content

Before authoring, read the latest design draft and the table being revised. Inspect the current catalog sources when the design names game content:

- `Project/project-keynes/data/economy/needs/`
- `Project/project-keynes/data/goods/`
- `Project/project-keynes/data/economy/buildings/`
- `Project/project-keynes/data/economy/professions/`
- `Project/project-keynes/data/resources/`
- `Project/project-keynes/data/technology/technology_network.json`

Use current Chinese `display_name` values and real era/technology gates. Do not invent a technology, profession, good, building, resource, or era and present it as current content.

## Preserve The Two Design Pipes

- A **preference** changes what the family tends to consume, invest in, or work as. It has a randomized strength and does not use prestige tiers.
- An **effect** changes an actual result when its condition is satisfied. It declares a target and five prestige results.

Do not move a choice-weight change into an effect merely to make it scale with prestige. Do not rewrite an actual result as a preference.

## Use The Requested Tables

For the standard family catalog, produce exactly three preference tables and two effect tables:

- Consumption, investment, and employment preference columns: `ID | 偏好名称 | 随机出现条件 | 偏好效果 | 取值范围`.
- Carried and independent effect columns: `ID | 效果名称 | 条件 | 对象 | 威望Ⅰ结果 | 威望Ⅱ结果 | 威望Ⅲ结果 | 威望Ⅳ结果 | 威望Ⅴ结果 | 完整表述`.
- Use stable sequential prefixes: `C###`, `I###`, `J###`, and one continuous `E###` sequence across both effect tables.
- Write `—` when a preference has no random appearance condition.
- Define every variable used by a preference, for example `X∈[20%,60%]；Y∈[10%,30%]`.
- Make every prestige cell explicit. Prestige may improve magnitude, threshold, radius, duration, stack cap, or reward quantity.
- Write the final effect as one complete natural-language sentence containing the trigger, target, and all five tier outcomes.

Read [design-schema.md](references/design-schema.md) when creating or substantially restructuring a catalog.

## Keep The Deliverable About Content

Unless the user asks for an implementation audit, do not add columns or sections for:

- current Trait or stable IDs;
- core role or design purpose;
- mutual-exclusion suggestions;
- implementation status or difficulty;
- runtime boundaries, IR/YAML, stack policy, ACK, schema, or migration state;
- build examples or status matrices.

Runtime feasibility may inform the design backstage, but it must not displace the requested fields. If an effect is deliberately aspirational, write the intended gameplay literally.

Preserve explicit user rules. For example, if the user allows direct population creation or a genuinely free building, do not silently convert it into migration, absorption, reimbursement, or another conserved substitute. Do not generalize one exception to unrelated money, goods, or resources unless asked.

## Design For Play

- Give each family a recognizable choice pattern, a payoff, and at least one condition or tradeoff that can change its value.
- Create cross-links among climate, geography, resources, production chains, professions, consumption, trade, and family expansion.
- Use broad bonuses conservatively; reserve extreme values for narrow, conditional, late-era, or mixed effects.
- Make negative and mixed effects legitimate build pieces, not filler penalties.
- Cover all current need categories and economic sectors. Cover every current profession either directly or through an explicit group. Use representative goods and buildings across all eleven eras without mechanically generating one row per asset.
- Keep nationwide and repeatable effects smaller than local or one-time effects unless the user explicitly chooses a high-variance design.

## Validate

Run the bundled validator on a completed Markdown catalog:

```powershell
& .\.agents\skills\project-keynes-family-content-design\scripts\validate_family_design.ps1 `
  -Path "<family-design.md>" -RequireFiveTables -RequireFullProfessionCoverage -Strict
```

Resolve structural errors, unknown quoted technology names, missing variables, duplicate IDs, and incomplete tier rows before delivery. Report content counts and any deliberate departures from the standard schema.

