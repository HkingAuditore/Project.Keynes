# Family Preference And Effect Design Schema

Use this reference for full-catalog authoring or structural reviews.

## Preference Rows

Use one table for each axis: consumption, investment, and employment.

| ID | 偏好名称 | 随机出现条件 | 偏好效果 | 取值范围 |
| --- | --- | --- | --- | --- |
| I001 | 小农思想 | 国家已解锁“雨养田体系” | 投资小农农业建筑的可能性增加 X%，投资大型农业建筑的可能性减少 Y% | X∈[100%,500%]；Y∈[20%,70%] |

Field rules:

- **偏好名称**: a memorable family attitude, tradition, or identity rather than an internal selector name.
- **随机出现条件**: prerequisites for entering the random pool, such as an era, unlocked technology, origin climate, landform, or discoverable local resource. This is not the preference's moment-to-moment activation condition.
- **偏好效果**: state the affected need, good, building class, building, profession group, profession, or decision score in player language. Conditional behavior belongs in this cell, for example “当地寒冷时……”.
- **取值范围**: define every symbol once and include units. Do not mix `+50%` with an undefined bare `50`.

Recommended strength bands are starting points, not hard laws:

| Target width | Typical positive range | Typical negative range |
| --- | --- | --- |
| All choices or a broad system | 10%–40% | 5%–25% |
| Need, sector, profession group, or industry | 20%–100% | 10%–60% |
| Specific good, building family, or profession | 30%–200% | 20%–80% |
| Signature narrow build with a real drawback | 100%–500% | 20%–90% |

## Effect Rows

Use separate carried and independent effect tables, with one continuous `E###` sequence.

| ID | 效果名称 | 条件 | 对象 | 威望Ⅰ结果 | 威望Ⅱ结果 | 威望Ⅲ结果 | 威望Ⅳ结果 | 威望Ⅴ结果 | 完整表述 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E001 | 扩张主义 | 该家族成功开拓一个新地块 | 新开拓的地块 | 初始人口+20 | 初始人口+30 | 初始人口+40 | 初始人口+60 | 初始人口+80 | 当该家族每开拓一个地块时，新地块的初始人口按威望Ⅰ—Ⅴ分别直接增加20、30、40、60和80。 |

Field rules:

- **条件**: write `无条件` or a concrete event/environment/economy/country predicate. Avoid vague phrases such as “情况良好”.
- **对象**: name the exact scope—this family, this branch, the local cell, cells within distance N, every branch cell, or every national cell.
- **威望结果**: fill all five cells. Each tier must be observably distinct through magnitude, threshold, radius, duration, stack cap, affected subjects, or reward quantity.
- **完整表述**: write a full sentence, not a formula fragment. It must agree with every tier cell and explicitly identify condition, object, result, and tier sequence.

An effect may have multiple results when they form one coherent choice, such as “consumption rises while production falls”. Split unrelated triggers, targets, or themes into separate rows.

## Coverage Matrix

For a comprehensive catalog, verify these families without mechanically enumerating every asset:

- Consumption: all 17 current needs plus strategically meaningful goods from early, middle, industrial, and late eras.
- Investment: agriculture, extractive, manufacturing, energy, and knowledge sectors; gathering, hunting, fishing, pastoralism, farming, forestry, mining, saltmaking, textile, pottery, metalworking, construction, food, trade, and knowledge chains.
- Employment: all 45 current professions, grouped only when the group has a coherent social or industrial identity.
- Conditions: unconditional, events, weather/climate, terrain/resources, settlement economy, family state, and country progression.
- Targets: local cell, bounded neighbors, all branch cells, national cells, and the family itself.
- Results: production, consumption, investment, employment, trade, resource regeneration/decay, resource conversion, population, duration, stacking, and derived values.

Use `technology_network.json` for the eleven real eras and technology display names. Use resource files for current content display names.

## Buildcraft And Balance Review

Review combinations, not only isolated rows:

1. Identify which preference steers the family's choices.
2. Identify which effect rewards successful execution.
3. Identify a climate, resource, technology, demand, labor, timing, or concentration condition that changes the build's value.
4. Test two to four compatible preferences together; broad multiplicative tendencies should not erase all alternative choices.
5. Test repeated triggers and nationwide effects for runaway growth. If runaway growth is explicitly intended, preserve it and make the cadence visible in the row.
6. Keep all five prestige tiers attractive. Avoid tiers that repeat identical result text.

Do not silently “fix” an authored direct reward by changing its semantics. Balance it through magnitude, threshold, duration, target scope, or prestige placement unless the user requests a different resource model.

## Presentation Exclusions

The standard content artifact should contain a short introduction and the five tables. Do not add architecture prose, implementation status, current Trait fields, IR examples, stack policies, compatibility matrices, or migration plans unless explicitly requested as a separate deliverable.

