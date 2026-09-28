# 科技树 Wave 1 设计差异

本稿只记录提案，不修改生产 `technology_network.json`。当前硬前置与效果均从权威源复制。

- 覆盖节点：142（4 条主干、11 个时代里程碑与 6 条核心支线及其连接节点）。
- 明确变更提案：9；关系链：8。
- 拓扑边：175；硬前置 132，相关/应用边 43。
- 重要度层级：{"1": 32, "2": 42, "3": 64, "4": 4}
- 节点处理分类：{"rebind_prerequisite": 3, "repair_branch_continuity": 41, "repair_content_binding": 14, "repair_research_route": 1, "retain_then_review_binding": 77, "review_overloaded_prerequisites": 2, "strengthen_branch_continuity": 4}
- 所有 ID 保留；里程碑候选数量与门槛保持现状。

## 优先差异

| 科技 | 当前硬前置 | 拟议核心前置 | 决策 |
|---|---|---|---|
| `tech.urban_sanitation` | tech.salt_preservation | tech.permanent_settlements | rebind_prerequisite |
| `tech.wind_power` | tech.surface_coal_use | tech.composite_tools | rebind_prerequisite |
| `tech.coal_geology` | tech.chartered_companies | tech.coal_outcrop_identification | rebind_prerequisite |
| `tech.public_health_systems` | tech.modern_medicine, tech.public_education | tech.modern_medicine, tech.public_education | strengthen_branch_continuity |
| `tech.networked_computing` | tech.software_engineering, tech.telecommunications, tech.information_theory, tech.semiconductor_manufacturing, tech.solar_evaporation, tech.advanced_metallurgy, tech.deep_mining | tech.software_engineering, tech.telecommunications, tech.information_theory | review_overloaded_prerequisites |
| `tech.precision_irrigation` | tech.hydraulic_engineering, tech.electronic_control | tech.hydraulic_engineering, tech.electronic_control | strengthen_branch_continuity |
| `tech.digital_marketplaces` | tech.networked_computing | tech.networked_computing | strengthen_branch_continuity |
| `tech.machine_learning` | tech.semiconductor_manufacturing, tech.solar_evaporation, tech.systems_engineering, tech.mineral_spectral_survey, tech.precision_engineering | tech.systems_engineering, tech.digital_computing | review_overloaded_prerequisites |
| `tech.adaptive_irrigation` | tech.intelligent_breeding, tech.autonomous_logistics, tech.algorithmic_management | tech.precision_irrigation, tech.autonomous_systems | strengthen_branch_continuity |

## 关系链

- `tech.gathering` → `tech.food_storage` → `tech.public_storehouses` → `tech.urban_food_supply` → `tech.regional_granaries`
- `tech.composite_tools` → `tech.plough_agriculture` → `tech.machine_tools` → `tech.electronic_control` → `tech.digital_control` → `tech.autonomous_systems`
- `tech.natural_observation` → `tech.writing` → `tech.experimental_science` → `tech.industrial_research` → `tech.national_laboratories`
- `tech.early_trade` → `tech.market_institutions` → `tech.mercantile_networks` → `tech.digital_marketplaces`
- `tech.rice_identification` → `tech.rice_paddy_cultivation` → `tech.rice_water_control` → `tech.precision_irrigation` → `tech.adaptive_irrigation`
- `tech.coal_outcrop_identification` → `tech.coal_mining` → `tech.deep_mining` → `tech.industrial_coal_mining` → `tech.mechanized_mining` → `tech.autonomous_mining`
- `tech.urban_sanitation` → `tech.public_health` → `tech.modern_medicine` → `tech.public_health_systems`
- `tech.radio` → `tech.telecommunications` → `tech.networked_computing` → `tech.distributed_intelligence`

## 生产实施门槛

- verify proposed hard prerequisite acyclicity and topological order
- verify every building/good/resource unlock closure before catalog rebind
- verify research signal reachability and route independence
- verify catalog identity/save rejection behavior after production changes

`blocked` 提案仅表示还需先核对内容闭包，不是已经进入生产的硬前置变更。
关系链是解释性设计边；是否升级为硬前置由不可替代知识和闭包测试决定。
