# Technology Gate Semantics Audit

Generated from `data/technology/technology_network.json` (schema 4).

## Summary

- Nodes: 380
- Nodes with reveal conditions: 281
- Nodes with research routes: 270
- Research routes fully implied by hard-prerequisite history: 0
- Reveal conditions fully implied by hard-prerequisite history: 12
- Nodes reusing a signal atom in reveal and a research route: 2
- Nodes whose reveal shares signal atoms with hard-prerequisite ancestors: 30
- Repeated reveal-formula groups: 69
- Unexplained repeated reveal-formula groups: 0
- Invalid/self/future route references: 0
- Nodes with non-distinct route types: 0
- Kingdom+ route coverage: 88.8%

A route is considered historically implied only when every atom required by its condition is already guaranteed by completed hard ancestors or their persistent discovery evidence. Disjunctions are treated conservatively: every branch must be guaranteed.

## Blocking Findings

### Fully Implied Reveal Conditions

- `tech.herd_management` - 畜群管理（stone）
- `tech.fire_control` - 火种控制（stone）
- `tech.fur_sewing` - 毛皮缝制（stone）
- `tech.felt_making` - 羊毛毡制（stone）
- `tech.charcoal_burning` - 木炭烧制（stone）
- `tech.bronze_casting` - 铜锡配比与铸造（agrarian）
- `tech.animal_traction` - 畜力牵引（agrarian）
- `tech.adobe_making` - 日晒土坯（agrarian）
- `tech.rainfed_maize_cultivation` - 雨养玉米田（agrarian）
- `tech.rainfed_wheat_cultivation` - 雨养小麦田（agrarian）
- `tech.dryland_wheat_cultivation` - 旱作小麦田（agrarian）
- `tech.timber_sawing` - 手工锯木（agrarian）

### Fully Implied Research Routes

- 无

### Reveal And Route Signal Reuse

- `tech.freshwater_fishing` / `research_route.freshwater_fishing.freshwater`：`1|resource.freshwater_fish|1`
- `tech.coastal_fishing` / `research_route.coastal_fishing.coast`：`1|resource.marine_fish|1`

### Invalid Route References

- 无

## Design Review Findings

### Reveal Signal Reused From Hard-Prerequisite Ancestors

- `tech.food_storage` 与祖先 `tech.gathering`：`1|resource.fertile_soil|1`
- `tech.herd_management` 与祖先 `tech.animal_husbandry`：`1|bio.sheep|1`, `1|bio.horse|1`, `1|bio.cattle|1`
- `tech.fire_control` 与祖先 `tech.deadwood_collection`：`1|resource.timber|1`
- `tech.controlled_burning` 与祖先 `tech.fire_control`：`1|resource.timber|1`
- `tech.controlled_burning` 与祖先 `tech.deadwood_collection`：`1|resource.timber|1`
- `tech.fiber_twisting` 与祖先 `tech.flax_identification`：`1|bio.flax|1`
- `tech.hide_scraping` 与祖先 `tech.hunting`：`1|resource.wild_game|1`
- `tech.fur_sewing` 与祖先 `tech.animal_husbandry`：`1|bio.sheep|1`
- `tech.fur_sewing` 与祖先 `tech.hunting`：`1|resource.wild_game|1`
- `tech.felt_making` 与祖先 `tech.animal_husbandry`：`1|bio.sheep|1`
- `tech.composite_tools` 与祖先 `tech.flint_identification`：`1|resource.flint|1`
- `tech.charcoal_burning` 与祖先 `tech.fire_control`：`1|resource.timber|1`
- `tech.charcoal_burning` 与祖先 `tech.deadwood_collection`：`1|resource.timber|1`
- `tech.bronze_casting` 与祖先 `tech.tin_identification`：`1|resource.tin_ore|1`, `1|contact.tin|1`
- `tech.animal_traction` 与祖先 `tech.animal_husbandry`：`1|bio.horse|1`, `1|bio.cattle|1`
- `tech.household_landholding` 与祖先 `tech.gathering`：`1|resource.fertile_soil|1`
- `tech.public_storehouses` 与祖先 `tech.gathering`：`1|resource.fertile_soil|1`
- `tech.adobe_making` 与祖先 `tech.clay_identification`：`1|resource.clay|1`
- `tech.rainfed_maize_cultivation` 与祖先 `tech.rainfed_field_system`：`1|breakthrough.rainfed_adaptation|1`
- `tech.rainfed_wheat_cultivation` 与祖先 `tech.rainfed_field_system`：`1|resource.arable_land|1`, `1|weather.drought|1`
- `tech.dryland_wheat_cultivation` 与祖先 `tech.dryland_water_retention`：`1|landform.loess_plain|1`
- `tech.upland_rice_propagation` 与祖先 `tech.rainfed_field_system`：`1|weather.drought|1`
- `tech.hand_spinning` 与祖先 `tech.fiber_twisting`：`1|bio.cotton|1`
- `tech.weaving` 与祖先 `tech.hand_spinning`：`1|resource.arable_land|1`
- `tech.timber_sawing` 与祖先 `tech.deadwood_collection`：`1|resource.timber|1`
- `tech.hide_tanning` 与祖先 `tech.hunting`：`1|resource.wild_game|1`
- `tech.meat_processing` 与祖先 `tech.hunting`：`1|resource.wild_game|1`
- `tech.fermentation` 与祖先 `tech.food_storage`：`1|resource.fertile_soil|1`
- `tech.fermentation` 与祖先 `tech.gathering`：`1|resource.fertile_soil|1`
- `tech.salt_preservation` 与祖先 `tech.brine_collection`：`1|resource.salt|1`

### Repeated Reveal Templates

- 无

## Gate Interpretation

- 核心知识只来自 hard_prerequisite_ids；揭示条件只描述观察到的问题或压力。
- 研究路线只描述解决问题所需能力，多个路线通过 ANY_OF 独立解释。
- route_exemption_reason 只允许用于真正的辨识节点或终端应用叶节点。

