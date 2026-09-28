# 科技目录审计报告

> 自动生成文件，请勿手工编辑。权威来源为 `TechnologyCatalog`；内容解锁来自已编译的 `EconomyCatalog` 反向绑定。

## 总览

| 项目 | 数量 |
| --- | ---: |
| 研究科技 (`tech.*`) | 380 |
| 自动应用 (`app.*`) | 260 |
| 时代 | 11 |
| 领域 | 4 |
| 里程碑 | 11 |
| 硬前置边 | 547 |
| 应用交汇边 | 697 |
| 替代说明边 | 578 |
| 分支关系边 | 8 |
| 里程碑候选边 | 143 |

## 时代目录

- [石器时代](#era-1)（73 项科技、15 项自动应用，科技成本 0-5000）
- [农耕时代](#era-2)（65 项科技、26 项自动应用，科技成本 3400-12000）
- [王国时代](#era-3)（33 项科技、22 项自动应用，科技成本 3900-30000）
- [帝国时代](#era-4)（29 项科技、17 项自动应用，科技成本 42000-70000）
- [探索时代](#era-5)（26 项科技、13 项自动应用，科技成本 96000-160000）
- [启蒙时代](#era-6)（27 项科技、10 项自动应用，科技成本 216000-360000）
- [蒸汽时代](#era-7)（29 项科技、18 项自动应用，科技成本 480000-800000）
- [电气时代](#era-8)（26 项科技、38 项自动应用，科技成本 1080000-1800000）
- [原子时代](#era-9)（26 项科技、23 项自动应用，科技成本 2400000-4000000）
- [信息时代](#era-10)（24 项科技、34 项自动应用，科技成本 5400000-9000000）
- [智能时代](#era-11)（22 项科技、44 项自动应用，科技成本 12000000-20000000）

<a id="era-1"></a>
## 石器时代

共 73 项研究科技、15 项自动应用，科技研究成本范围 0-5000；时代里程碑：定居知识 (`tech.settled_knowledge`)。

### 狩猎 (`tech.hunting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hunting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「野生动物」（resource.wild\_game）

#### 效果摘要

解锁建筑：狩猎营地；解锁物资：毛皮；解锁物资：野味；解锁物资：生皮；可利用资源：野生动物

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 毛皮 (`fur`)；野味 (`game_meat`)；生皮 (`raw_hide`)
- **建筑 / 生产方式：** 狩猎营地 (`stone_age_hunting_camp`)
- **自然资源：** 野生动物 (`wild_game`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 宫廷裁缝坊 (`court_tailor`)；制革厂 (`leather_plant`)

#### 结构化内容效果

- **狩猎营地**（`building`）：`building.stone_age_hunting_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **毛皮**（`good`）：`good.fur` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **野味**（`good`）：`good.game_meat` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「狩猎」。
- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「狩猎」。
- 生皮刮制 (`tech.hide_scraping`)：该科技需要先掌握 「狩猎」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 采集 (`tech.gathering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gathering` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 全部路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「肥沃土壤」（resource.fertile\_soil）

#### 效果摘要

解锁建筑：采集营地；解锁物资：采集植物食物；可利用资源：肥沃土壤；作为必要支撑：日晒土坯场、野生香料林

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 采集植物食物 (`gathered_plants`)
- **建筑 / 生产方式：** 采集营地 (`gathering_ground`)
- **自然资源：** 肥沃土壤 (`fertile_soil`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 日晒土坯场 (`adobe_yard`)；野生香料林 (`wild_spice_grove`)

#### 结构化内容效果

- **采集营地**（`building`）：`building.gathering_ground` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **采集植物食物**（`good`）：`good.gathered_plants` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「采集」。
- 季节性采集 (`tech.seasonal_foraging`)：该科技需要先掌握 「采集」。
- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「采集」。
- 卤水采集 (`tech.brine_collection`)：该科技需要先掌握 「采集」。
- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期贸易 (`tech.early_trade`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.early_trade` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选、时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | \`starter.trade\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

解锁建筑：早期商栈

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期商栈 (`early_merchant_post`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **早期商栈**（`building`）：`building.early_merchant_post` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 商品货币与集市 (`tech.commodity_money`)：集市把零散的以物易物固定为定期交易。
- 市场制度 (`tech.market_institutions`)：该科技需要先掌握 「早期贸易」。
- 货币 (`tech.currency`)：该科技需要先掌握 「早期贸易」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 枯枝采集 (`tech.deadwood_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deadwood_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：枯枝采集营地；解锁建筑：伐木场；解锁物资：原木；可利用资源：木材；作为必要支撑：煮盐灶、野生割胶营地

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原木 (`logs`)
- **建筑 / 生产方式：** 枯枝采集营地 (`deadwood_gathering_camp`)；伐木场 (`timber_collector`)
- **自然资源：** 木材 (`timber`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 煮盐灶 (`brine_boiling_hearth`)；行会陶窑 (`method_pottery_kiln_r3`)；野生割胶营地 (`rubber_tapping_camp`)

#### 结构化内容效果

- **枯枝采集营地**（`building`）：`building.deadwood_gathering_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **伐木场**（`building`）：`building.timber_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **木材**（`resource`）：`resource.timber` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「枯枝采集」。
- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「枯枝采集」。
- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「枯枝采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期知识机构 (`tech.early_knowledge_institution`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.early_knowledge_institution` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`)；地理 · 沿海 (\`route.geography.coast\`) |
| 开局能力标签 | 无 |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 采集 (`tech.gathering`)：该科技需要先掌握 「采集」。
- 枯枝采集 (`tech.deadwood_collection`)：该科技需要先掌握 「枯枝采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：早期知识机构；解锁物资：科技值；作为必要支撑：书记学校

#### 机会成本

统一知识机构占用早期建材与劳动力，但为后续区域知识分支提供入口。

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 早期知识机构 (`early_knowledge_institution`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 书记学校 (`scribal_school`)

#### 结构化内容效果

- **早期知识机构**（`building`）：`building.early_knowledge_institution` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「早期知识机构」。
- 口述记忆实践 (`tech.oral_memory_practice`)：该科技需要先掌握 「早期知识机构」。
- 物候观察实践 (`tech.phenology_observation`)：该科技需要先掌握 「早期知识机构」。
- 洪水历法实践 (`tech.flood_calendar_practice`)：该科技需要先掌握 「早期知识机构」。
- 牧群路线记忆 (`tech.pastoral_route_memory`)：该科技需要先掌握 「早期知识机构」。
- 潮汐与航向记忆 (`tech.tide_observation`)：该科技需要先掌握 「早期知识机构」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 季节性采集 (`tech.seasonal_foraging`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.seasonal_foraging` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 全部路线 | 生态 · 野生植物 (\`route.ecology.plants\`)；制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 采集 (`tech.gathering`)：该科技需要先掌握 「采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「采集植物食物」产量 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 采集植物食物：`country.output.good.gathered_plants_factor`：+12%
  - 效果机制：季节性采集提高采集植物食物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 食物储藏 (`tech.food_storage`)：该科技需要先掌握 「季节性采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 黏土辨识 (`tech.clay_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.clay_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

可利用资源：黏土

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 黏土 (`clay`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **黏土**（`resource`）：`resource.clay` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 土建筑 (`tech.earth_building`)：该科技需要先掌握 「黏土辨识」。
- 黏土调制 (`tech.clay_preparation`)：该科技需要先掌握 「黏土辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 畜牧驯养 (`tech.animal_husbandry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.animal_husbandry` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 狩猎 (`tech.hunting`)：该科技需要先掌握 「狩猎」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：畜牧驯养提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 动物追踪 (`tech.animal_tracking`)：该科技需要先掌握 「畜牧驯养」。
- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜牧驯养」。
- 毛皮缝制 (`tech.fur_sewing`)：该科技需要先掌握 「畜牧驯养」。
- 羊毛毡制 (`tech.felt_making`)：该科技需要先掌握 「畜牧驯养」。
- 畜力牵引 (`tech.animal_traction`)：该科技需要先掌握 「畜牧驯养」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 食物储藏 (`tech.food_storage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.food_storage` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 季节性采集 (`tech.seasonal_foraging`)：该科技需要先掌握 「季节性采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「淡水鱼群」（resource.freshwater\_fish）

#### 效果摘要

商品「加工主食」产量 +12%；「主粮加工」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 加工主食：`country.output.good.prepared_staples_factor`：+12%
- 主粮加工：`country.output.family.staple_preparation_factor`：+12%
  - 效果机制：食物储藏减少储藏损耗，提高加工主食有效供给。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：食物储藏提高主粮加工与仓储相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 炉火保存 (`tech.hearth_preservation`)：该科技需要先掌握 「食物储藏」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 动物追踪 (`tech.animal_tracking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.animal_tracking` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「畜牧驯养」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：小型陷阱线；可利用资源：野生动物；「狩猎」生产家族建筑产出 +28%；作为必要支撑：狩猎营地

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 毛皮 (`fur`)；野味 (`game_meat`)；生皮 (`raw_hide`)
- **建筑 / 生产方式：** 小型陷阱线 (`small_game_trapline`)
- **自然资源：** 野生动物 (`wild_game`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 商业狩猎与毛皮站 (`method_stone_age_hunting_camp_r4`)；修道院抄写室 (`monastic_scriptorium`)；狩猎营地 (`stone_age_hunting_camp`)

#### 结构化内容效果

- **小型陷阱线**（`building`）：`building.small_game_trapline` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **毛皮**（`good`）：`good.fur` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **野味**（`good`）：`good.game_meat` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 狩猎：`country.output.family.hunting_factor`：+28%
  - 效果机制：动物追踪提高狩猎建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 土建筑 (`tech.earth_building`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.earth_building` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 黏土辨识 (`tech.clay_identification`)：该科技需要先掌握 「黏土辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：土料挖掘坑；解锁建筑：原始黏土坑；解锁物资：黏土；可利用资源：黏土

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黏土 (`clay`)
- **建筑 / 生产方式：** 土料挖掘坑 (`earth_digging_pit`)；原始黏土坑 (`primitive_clay_pit`)
- **自然资源：** 黏土 (`clay`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)

#### 结构化内容效果

- **土料挖掘坑**（`building`）：`building.earth_digging_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原始黏土坑**（`building`）：`building.primitive_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黏土**（`good`）：`good.clay` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **黏土**（`resource`）：`resource.clay` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 水田畦埂 (`tech.paddy_bunding`)：该科技需要先掌握 「土建筑」。
- 日晒土坯 (`tech.adobe_making`)：该科技需要先掌握 「土建筑」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 炉火保存 (`tech.hearth_preservation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hearth_preservation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 食物储藏 (`tech.food_storage`)：该科技需要先掌握 「食物储藏」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

「主粮加工」生产家族建筑产出 +25%；作为必要支撑：公共火塘

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 公共火塘 (`communal_hearth`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 主粮加工：`country.output.family.staple_preparation_factor`：+25%
  - 效果机制：炉火保存提高主粮加工建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 发酵保存 (`tech.fermentation`)：该科技需要先掌握 「炉火保存」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 畜群管理 (`tech.herd_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.herd_management` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「畜牧驯养」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

解锁建筑：游牧营地；解锁物资：畜牧产品；可利用资源：牧场承载力；「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 畜牧产品 (`livestock_products`)
- **建筑 / 生产方式：** 游牧营地 (`pastoral_camp`)
- **自然资源：** 牧场承载力 (`pasture`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 堆肥场 (`composting_yard`)；乳制品厂 (`dairy_products_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；智能牧业站 (`method_smart_husbandry`)；工业制皂厂 (`method_soap_plant_r6`)；羊毛行会作坊 (`method_wool_shed_r3`)；精梳羊毛作坊 (`method_wool_shed_r5`)；制皂工坊 (`soap_plant`)

#### 结构化内容效果

- **游牧营地**（`building`）：`building.pastoral_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **畜牧产品**（`good`）：`good.livestock_products` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **牧场承载力**（`resource`）：`resource.pasture` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：畜群管理提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 游牧放牧 (`tech.pastoralism`)：该科技需要先掌握 「畜群管理」。
- 马匹驯化 (`tech.horse_domestication`)：该科技需要先掌握 「畜群管理」。
- 乳品加工 (`tech.dairy_processing`)：该科技需要先掌握 「畜群管理」。
- 皮革鞣制 (`tech.hide_tanning`)：该科技需要先掌握 「畜群管理」。
- 毛用畜牧 (`tech.wool_husbandry`)：该科技需要先掌握 「畜群管理」。
- 屠宰分割 (`tech.meat_processing`)：该科技需要先掌握 「畜群管理」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 香料植物辨识 (`tech.spice_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.spice_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：香料植物辨识提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 野生香料采集 (`tech.wild_spice_collection`)：该科技需要先掌握 「香料植物辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生香料采集 (`tech.wild_spice_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_spice_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 香料植物辨识 (`tech.spice_identification`)：该科技需要先掌握 「香料植物辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生香料林；解锁物资：香料；「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 香料 (`spices`)
- **建筑 / 生产方式：** 野生香料林 (`wild_spice_grove`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)；机械化香料种植园 (`method_spice_plants_collector_r6`)；商品香料园 (`spice_managed_garden`)

#### 结构化内容效果

- **野生香料林**（`building`）：`building.wild_spice_grove` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：野生香料采集提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 香料栽培 (`tech.spice_cultivation`)：该科技需要先掌握 「野生香料采集」。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该科技需要先掌握 「野生香料采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 橡胶树辨识 (`tech.rubber_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rubber_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）

#### 效果摘要

「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：橡胶树辨识提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 野生割胶 (`tech.wild_latex_tapping`)：该科技需要先掌握 「橡胶树辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生割胶 (`tech.wild_latex_tapping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_latex_tapping` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 橡胶树辨识 (`tech.rubber_identification`)：该科技需要先掌握 「橡胶树辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：野生割胶提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 天然橡胶加工 (`tech.rubber_working`)：该科技需要先掌握 「野生割胶」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 砂金辨识 (`tech.gold_placer_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gold_placer_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 黄金 (\`route.resource.gold\`) |
| 全部路线 | 资源 · 黄金 (\`route.resource.gold\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「金矿」（resource.gold\_ore）

#### 效果摘要

「金矿采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 金矿采掘：`country.output.family.gold_extraction_factor`：+12%
  - 效果机制：砂金辨识提高金矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 粗陶淘金 (`tech.gold_panning`)：该科技需要先掌握 「砂金辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 粗陶淘金 (`tech.gold_panning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gold_panning` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 黄金 (\`route.resource.gold\`) |
| 全部路线 | 资源 · 黄金 (\`route.resource.gold\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.precious\_metal\` |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 砂金辨识 (`tech.gold_placer_identification`)：该科技需要先掌握 「砂金辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：河滩淘金场；解锁物资：黄金；可利用资源：金矿；作为必要支撑：金银器工坊

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黄金 (`gold`)
- **建筑 / 生产方式：** 河滩淘金场 (`placer_gold_working`)
- **自然资源：** 金矿 (`gold_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 金矿 (`gold_mine`)；金银器工坊 (`goldsmith_workshop`)；珠宝厂 (`jewelry_plant`)；木槽溜洗场 (`primitive_gold_sluice`)

#### 结构化内容效果

- **河滩淘金场**（`building`）：`building.placer_gold_working` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黄金**（`good`）：`good.gold` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金矿**（`resource`）：`resource.gold_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地表银脉辨识 (`tech.silver_vein_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.silver_vein_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 全部路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

「银矿采掘」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 银矿采掘：`country.output.family.silver_extraction_factor`：+12%
  - 效果机制：地表银脉辨识提高银矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 地表银矿拣采 (`tech.surface_silver_collection`)：该科技需要先掌握 「地表银脉辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地表银矿拣采 (`tech.surface_silver_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.surface_silver_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 全部路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 开局能力标签 | \`starter.precious\_metal\` |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地表银脉辨识 (`tech.silver_vein_identification`)：该科技需要先掌握 「地表银脉辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：浅坑银矿作业；解锁建筑：露天银矿；解锁物资：白银；可利用资源：银矿

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 白银 (`silver`)
- **建筑 / 生产方式：** 浅坑银矿作业 (`shallow_silver_working`)；露天银矿 (`surface_silver_working`)
- **自然资源：** 银矿 (`silver_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 银矿 (`silver_mine`)

#### 结构化内容效果

- **浅坑银矿作业**（`building`）：`building.shallow_silver_working` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **露天银矿**（`building`）：`building.surface_silver_working` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **白银**（`good`）：`good.silver` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **银矿**（`resource`）：`resource.silver_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 火种控制 (`tech.fire_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fire_control` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 能源 · 火 (\`route.energy.fire\`) |
| 全部路线 | 能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 枯枝采集 (`tech.deadwood_collection`)：该科技需要先掌握 「枯枝采集」。
- 采集 (`tech.gathering`)：该科技需要先掌握 「采集」。
- 狩猎 (`tech.hunting`)：该科技需要先掌握 「狩猎」。

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：公共火塘；解锁物资：熟制主食；作为必要支撑：主食厨房

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 熟制主食 (`prepared_staples`)
- **建筑 / 生产方式：** 公共火塘 (`communal_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 主食厨房 (`staple_kitchen`)

#### 结构化内容效果

- **公共火塘**（`building`）：`building.communal_hearth` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **熟制主食**（`good`）：`good.prepared_staples` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 控制性用火 (`tech.controlled_burning`)：该科技需要先掌握 「火种控制」。
- 木炭烧制 (`tech.charcoal_burning`)：该科技需要先掌握 「火种控制」。
- 窑烧控制 (`tech.kiln_firing`)：该科技需要先掌握 「火种控制」。
- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)：该科技需要先掌握 「火种控制」。
- 太阳蒸发制盐 (`tech.solar_evaporation`)：该科技需要先掌握 「火种控制」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自然观察 (`tech.natural_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 全部路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

可利用资源：硝石；可利用资源：硅砂；农业领域研究效率 +8%；作为必要支撑：硅砂矿坑

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 硝石 (`saltpeter`)；硅砂 (`silica_sand`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 硅砂矿坑 (`classical_silica_pit`)；硝石矿 (`saltpeter_collector`)

#### 结构化内容效果

- **硝石**（`resource`）：`resource.saltpeter` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **硅砂**（`resource`）：`resource.silica_sand` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 口述传统 (`tech.oral_tradition`)：该科技需要先掌握 「自然观察」。
- 种子与繁育观察 (`tech.crop_domestication`)：该科技需要先掌握 「自然观察」。
- 玉米辨识 (`tech.maize_identification`)：该科技需要先掌握 「自然观察」。
- 小麦辨识 (`tech.wheat_identification`)：该科技需要先掌握 「自然观察」。
- 稻类辨识 (`tech.rice_identification`)：该科技需要先掌握 「自然观察」。
- 块茎辨识 (`tech.potato_identification`)：该科技需要先掌握 「自然观察」。
- 棉花辨识 (`tech.cotton_identification`)：该科技需要先掌握 「自然观察」。
- 亚麻辨识 (`tech.flax_identification`)：该科技需要先掌握 「自然观察」。
- 野生药草辨识 (`tech.medicinal_herb_identification`)：该科技需要先掌握 「自然观察」。
- 天文历法 (`tech.celestial_calendars`)：该科技需要先掌握 「自然观察」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 口述传统 (`tech.oral_tradition`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oral_tradition` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 全部路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：传知者议事圈；「研究机构」生产家族建筑产出 +12%；知识部门产出 +12%；作为必要支撑：早期知识机构

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 传知者议事圈 (`lorekeeper_circle`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 早期知识机构 (`early_knowledge_institution`)

#### 结构化内容效果

- **传知者议事圈**（`building`）：`building.lorekeeper_circle` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 研究机构：`country.output.family.research_institution_factor`：+12%
- 知识部门产出：`country.output.knowledge_factor`：+12%
  - 效果机制：口述传统提高研究与知识机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：口述传统提高知识部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 季节历 (`tech.seasonal_calendar`)：该科技需要先掌握 「口述传统」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 控制性用火 (`tech.controlled_burning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.controlled_burning` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；气候 · 火 (\`route.climate.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「火种控制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

木材 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 木材：`country.resource.timber.managed_generation_factor`：+8%
  - 效果机制：控制燃烧短期损失木本存量。
  - 运行时消费者：`NativeEconomyRuntime::effective_managed_resource_generation`

#### 被以下科技作为硬前置

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)：该科技需要先掌握 「控制性用火」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 种子与繁育观察 (`tech.crop_domestication`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_domestication` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「马铃薯」（bio.potato）

#### 效果摘要

农业部门产出 +4%；作为必要支撑：野生韧皮纤维营地、野生药草采集地

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 野生韧皮纤维营地 (`bast_fiber_camp`)；药材商品园 (`medicinal_herb_estate`)；药材种植园 (`medicinal_herbs_collector`)；改良亚麻庄园 (`method_flax_collector_r5`)；受控环境药材农场 (`method_medicinal_herbs_collector_r7`)；野生药草采集地 (`wild_medicinal_herb_patch`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+4%
  - 效果机制：种子与繁育观察提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 留种选育 (`tech.seed_selection`)：该科技需要先掌握 「种子与繁育观察」。
- 棉花园圃 (`tech.cotton_gardening`)：该科技需要先掌握 「种子与繁育观察」。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该科技需要先掌握 「种子与繁育观察」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 季节历 (`tech.seasonal_calendar`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.seasonal_calendar` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 口述传统 (`tech.oral_tradition`)：该科技需要先掌握 「口述传统」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

工程领域研究效率 +20%；旱灾损失 -4%；洪灾损失 -4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 工程领域研究效率：`country.research.engineering_efficiency`：+20%
- 旱灾损失：`country.climate.drought_loss_factor`：+4%
- 洪灾损失：`country.climate.flood_loss_factor`：+4%
  - 效果机制：计时、测量与统计提高工程研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：季节历降低全国气候型生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：季节历降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 玉米辨识 (`tech.maize_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

商品「玉米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+12%
  - 效果机制：玉米辨识提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 野生玉米采集 (`tech.wild_maize_collection`)：该科技需要先掌握 「玉米辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生玉米采集 (`tech.wild_maize_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_maize_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 玉米辨识 (`tech.maize_identification`)：该科技需要先掌握 「玉米辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生玉米采集地；解锁物资：玉米；商品「玉米」产量 +8%；作为必要支撑：酿酒坊

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 野生玉米采集地 (`wild_maize_stand`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 酿造厂 (`beverages_plant`)；面包厂 (`bread_plant`)；酿酒坊 (`brewery`)；蒸馏酒坊 (`distillery`)；榨油坊 (`edible_oil_plant`)；玉米庄园 (`landed_estate`)；工业榨油厂 (`method_edible_oil_plant_r6`)；机械化玉米农场 (`method_landed_estate_r6`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)

#### 结构化内容效果

- **野生玉米采集地**（`building`）：`building.wild_maize_stand` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+8%
  - 效果机制：野生玉米采集提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 玉米留种 (`tech.maize_seed_saving`)：该科技需要先掌握 「野生玉米采集」。
- 玉米选育 (`tech.maize_selection`)：该科技需要先掌握 「野生玉米采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 玉米留种 (`tech.maize_seed_saving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_seed_saving` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生玉米采集 (`tech.wild_maize_collection`)：该科技需要先掌握 「野生玉米采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「玉米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+12%
  - 效果机制：玉米留种提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 玉米繁育 (`tech.maize_propagation`)：该科技需要先掌握 「玉米留种」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玉米繁育 (`tech.maize_propagation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_propagation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 玉米留种 (`tech.maize_seed_saving`)：该科技需要先掌握 「玉米留种」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「玉米」产量 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+25%
  - 效果机制：玉米繁育提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 玉米园圃 (`tech.maize_garden_horticulture`)：该科技需要先掌握 「玉米繁育」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 小麦辨识 (`tech.wheat_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wheat_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：小麦辨识提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 野生谷穗采集 (`tech.wild_wheat_collection`)：该科技需要先掌握 「小麦辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生谷穗采集 (`tech.wild_wheat_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_wheat_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 小麦辨识 (`tech.wheat_identification`)：该科技需要先掌握 「小麦辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生谷穗采集地；解锁物资：小麦；商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 野生谷穗采集地 (`wild_wheat_stand`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)；机械化小麦农场 (`method_wheat_farm_r6`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)

#### 结构化内容效果

- **野生谷穗采集地**（`building`）：`building.wild_wheat_stand` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：野生谷穗采集提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 小麦留种 (`tech.wheat_seed_saving`)：该科技需要先掌握 「野生谷穗采集」。
- 旱作农业 (`tech.dryland_farming`)：该科技需要先掌握 「野生谷穗采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 小麦留种 (`tech.wheat_seed_saving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wheat_seed_saving` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生谷穗采集 (`tech.wild_wheat_collection`)：该科技需要先掌握 「野生谷穗采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：小麦留种提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 小麦繁育 (`tech.wheat_propagation`)：该科技需要先掌握 「小麦留种」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 小麦繁育 (`tech.wheat_propagation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wheat_propagation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 小麦留种 (`tech.wheat_seed_saving`)：该科技需要先掌握 「小麦留种」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「小麦」产量 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+28%
  - 效果机制：小麦繁育提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)：该科技需要先掌握 「小麦繁育」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 稻类辨识 (`tech.rice_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rice_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

商品「稻米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+12%
  - 效果机制：稻类辨识提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 野生稻采集 (`tech.wild_rice_collection`)：该科技需要先掌握 「稻类辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 块茎辨识 (`tech.potato_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.potato_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

商品「马铃薯」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 马铃薯：`country.output.good.potatoes_factor`：+12%
  - 效果机制：块茎辨识提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 野生块茎挖掘 (`tech.wild_tuber_collection`)：该科技需要先掌握 「块茎辨识」。
- 块茎保存 (`tech.tuber_storage`)：该科技需要先掌握 「块茎辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生块茎挖掘 (`tech.wild_tuber_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_tuber_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 块茎辨识 (`tech.potato_identification`)：该科技需要先掌握 「块茎辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生块茎采集地；解锁物资：马铃薯；作为必要支撑：家庭块茎试种圃

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 野生块茎采集地 (`wild_tuber_patch`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭块茎试种圃 (`household_tuber_garden`)

#### 结构化内容效果

- **野生块茎采集地**（`building`）：`building.wild_tuber_patch` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 块茎保存 (`tech.tuber_storage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tuber_storage` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 块茎辨识 (`tech.potato_identification`)：该科技需要先掌握 「块茎辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「马铃薯」产量 +12%；商品「加工主食」产量 +12%；「主粮加工」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 马铃薯：`country.output.good.potatoes_factor`：+12%
- 加工主食：`country.output.good.prepared_staples_factor`：+12%
- 主粮加工：`country.output.family.staple_preparation_factor`：+12%
  - 效果机制：块茎保存提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：块茎保存减少储藏损耗，提高加工主食有效供给。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：块茎保存提高主粮加工与仓储相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 块茎繁育 (`tech.potato_propagation`)：该科技需要先掌握 「块茎保存」。
- 梯田农业 (`tech.terrace_farming`)：该科技需要先掌握 「块茎保存」。
- 高地块茎农业 (`tech.highland_tuber_farming`)：该科技需要先掌握 「块茎保存」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 块茎繁育 (`tech.potato_propagation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.potato_propagation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)：该科技需要先掌握 「块茎保存」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：家庭块茎试种圃；解锁物资：马铃薯；商品「马铃薯」产量 +12%；作为必要支撑：冷凉高地块茎田、野生块茎采集地

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 家庭块茎试种圃 (`household_tuber_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)；机械化马铃薯农场 (`method_potato_collector_r6`)；改良轮作马铃薯庄园 (`method_potato_farm_r5`)；马铃薯庄园 (`potato_estate`)；佃作马铃薯田 (`tenant_potato_field`)；野生块茎采集地 (`wild_tuber_patch`)

#### 结构化内容效果

- **家庭块茎试种圃**（`building`）：`building.household_tuber_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 马铃薯：`country.output.good.potatoes_factor`：+12%
  - 效果机制：块茎繁育提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 垄作块茎 (`tech.ridge_tuber_cultivation`)：该科技需要先掌握 「块茎繁育」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 棉花辨识 (`tech.cotton_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cotton_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）

#### 效果摘要

「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：棉花辨识提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 野生棉铃采集 (`tech.wild_cotton_collection`)：该科技需要先掌握 「棉花辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生棉铃采集 (`tech.wild_cotton_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_cotton_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 棉花辨识 (`tech.cotton_identification`)：该科技需要先掌握 「棉花辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生棉丛；解锁物资：籽棉；「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 籽棉 (`seed_cotton`)
- **建筑 / 生产方式：** 野生棉丛 (`wild_cotton_stand`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作棉花田 (`cotton_smallholding`)；机械轧棉厂 (`mechanized_cotton_gin`)；机械化棉花农场 (`method_cotton_collector_r6`)

#### 结构化内容效果

- **野生棉丛**（`building`）：`building.wild_cotton_stand` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：野生棉铃采集提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 棉花去籽 (`tech.cotton_ginning`)：该科技需要先掌握 「野生棉铃采集」。
- 棉花园圃 (`tech.cotton_gardening`)：该科技需要先掌握 「野生棉铃采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 亚麻辨识 (`tech.flax_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flax_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

「布匹织造」生产家族建筑产出 +12%；「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：亚麻辨识提高麻纤维织造相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：亚麻辨识提高亚麻等专用作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 野生韧皮采集 (`tech.wild_flax_collection`)：该科技需要先掌握 「亚麻辨识」。
- 沤麻 (`tech.flax_retting`)：该科技需要先掌握 「亚麻辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生韧皮采集 (`tech.wild_flax_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_flax_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 亚麻辨识 (`tech.flax_identification`)：该科技需要先掌握 「亚麻辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生韧皮纤维营地；解锁物资：亚麻秆/韧皮原料；作为必要支撑：亚麻农场、家庭亚麻试种圃

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)
- **建筑 / 生产方式：** 野生韧皮纤维营地 (`bast_fiber_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 亚麻农场 (`flax_collector`)；家庭亚麻试种圃 (`household_flax_plot`)

#### 结构化内容效果

- **野生韧皮纤维营地**（`building`）：`building.bast_fiber_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 纤维捻制 (`tech.fiber_twisting`)：该科技需要先掌握 「野生韧皮采集」。
- 淡水岸捕 (`tech.freshwater_fishing`)：该科技需要先掌握 「野生韧皮采集」。
- 潮间带采集 (`tech.coastal_fishing`)：该科技需要先掌握 「野生韧皮采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 纤维捻制 (`tech.fiber_twisting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fiber_twisting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 野生韧皮采集 (`tech.wild_flax_collection`)：该科技需要先掌握 「野生韧皮采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）
  - 已发现信号「韧皮纤维实物接触」（contact.bast\_fiber）

#### 效果摘要

解锁建筑：韧皮裹衣棚；解锁物资：衣物；商品「衣物」产量 +12%；「布匹织造」生产家族建筑产出 +12%；作为必要支撑：毛皮缝制棚、生皮刮制棚

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)
- **建筑 / 生产方式：** 韧皮裹衣棚 (`bast_wrap_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 毛皮缝制棚 (`fur_sewing_shelter`)；生皮刮制棚 (`hide_scraping_shelter`)；裁缝铺 (`tailor_shop`)

#### 结构化内容效果

- **韧皮裹衣棚**（`building`）：`building.bast_wrap_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+12%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
  - 效果机制：纤维捻制提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：纤维捻制提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 织机织造 (`tech.loom_weaving`)：该科技需要先掌握 「纤维捻制」。
- 手工纺纱 (`tech.hand_spinning`)：该科技需要先掌握 「纤维捻制」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 淡水岸捕 (`tech.freshwater_fishing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.freshwater_fishing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 硬前置（决定研发资格）

- 野生韧皮采集 (`tech.wild_flax_collection`)：该科技需要先掌握 「野生韧皮采集」。

#### 发现启发（仅用于揭示）

- 已发现信号「淡水鱼群」（resource.freshwater\_fish）

#### 效果摘要

解锁建筑：淡水捕鱼营地；解锁物资：鱼类；可利用资源：淡水鱼群；农业部门产出 +10%；作为必要支撑：沿岸渔场

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 淡水捕鱼营地 (`freshwater_fishing_camp`)
- **自然资源：** 淡水鱼群 (`freshwater_fish`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)；罐头工坊 (`canning_workshop`)；沿岸渔场 (`marine_fish_collector`)

#### 结构化内容效果

- **淡水捕鱼营地**（`building`）：`building.freshwater_fishing_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **淡水鱼群**（`resource`）：`resource.freshwater_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+10%
  - 效果机制：淡水岸捕提高淡水渔获相关产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 潮间带采集 (`tech.coastal_fishing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coastal_fishing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 硬前置（决定研发资格）

- 野生韧皮采集 (`tech.wild_flax_collection`)：该科技需要先掌握 「野生韧皮采集」。

#### 发现启发（仅用于揭示）

- 已发现信号「海洋鱼类」（resource.marine\_fish）

#### 效果摘要

解锁建筑：沿岸渔场；解锁物资：鱼类；可利用资源：海洋鱼类；「海上作业」生产家族建筑产出 +10%；农业部门产出 +10%；作为必要支撑：淡水捕鱼营地、帆船渔场

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 沿岸渔场 (`marine_fish_collector`)
- **自然资源：** 海洋鱼类 (`marine_fish`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 淡水捕鱼营地 (`freshwater_fishing_camp`)；帆船渔场 (`method_marine_fish_collector_r2`)；远洋渔场 (`method_marine_fish_collector_r4`)

#### 结构化内容效果

- **沿岸渔场**（`building`）：`building.marine_fish_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **海洋鱼类**（`resource`）：`resource.marine_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+10%
- 农业部门产出：`country.output.agriculture_factor`：+10%
  - 效果机制：潮间带采集提高海上作业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：潮间带采集提高渔业相关农业产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生药草辨识 (`tech.medicinal_herb_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.medicinal_herb_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 药草 (\`route.crop.medicinal\_herb\`) |
| 全部路线 | 作物 · 药草 (\`route.crop.medicinal\_herb\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生药草」（bio.medicinal\_herb）
  - 已发现信号「药草样本接触」（contact.medicinal\_herb）

#### 效果摘要

无

#### 机会成本

需要持续观察药性、毒性与生境，延后其他自然辨识路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 野生药草采集 (`tech.wild_medicinal_herb_collection`)：该科技需要先掌握 「野生药草辨识」。

#### 主题路线后继

- 野生药草采集 (`tech.wild_medicinal_herb_collection`)：该知识继续发展为 「野生药草采集」。

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生药草采集 (`tech.wild_medicinal_herb_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_medicinal_herb_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 药草 (\`route.crop.medicinal\_herb\`) |
| 全部路线 | 作物 · 药草 (\`route.crop.medicinal\_herb\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 野生药草辨识 (`tech.medicinal_herb_identification`)：该科技需要先掌握 「野生药草辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生药草采集地；解锁物资：药材

#### 机会成本

需要专门的采集、分拣与安全处理劳动。

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)
- **建筑 / 生产方式：** 野生药草采集地 (`wild_medicinal_herb_patch`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **野生药草采集地**（`building`）：`building.wild_medicinal_herb_patch` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 芦苇辨识 (`tech.reed_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.reed_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「芦苇」（bio.reed）

#### 效果摘要

无

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 芦苇收割 (`tech.reed_harvesting`)：该科技需要先掌握 「芦苇辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 芦苇收割 (`tech.reed_harvesting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.reed_harvesting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 芦苇辨识 (`tech.reed_identification`)：该科技需要先掌握 「芦苇辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：芦苇收割营地；解锁物资：芦苇束；可利用资源：水田承载力

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 芦苇束 (`reed_bundle`)
- **建筑 / 生产方式：** 芦苇收割营地 (`reed_cutting_camp`)
- **自然资源：** 水田承载力 (`paddy_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化稻作农场 (`method_rice_collector_r10`)；精耕稻庄 (`method_rice_collector_r5`)；机械化稻作农场 (`method_rice_collector_r6`)；精准稻作农场 (`method_rice_collector_r8`)

#### 结构化内容效果

- **芦苇收割营地**（`building`）：`building.reed_cutting_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **芦苇束**（`good`）：`good.reed_bundle` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 野生稻采集 (`tech.wild_rice_collection`)：该科技需要先掌握 「芦苇收割」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生稻采集 (`tech.wild_rice_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_rice_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 稻类辨识 (`tech.rice_identification`)：该科技需要先掌握 「稻类辨识」。
- 芦苇收割 (`tech.reed_harvesting`)：该科技需要先掌握 「芦苇收割」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：野生稻沼泽；解锁物资：稻米；商品「稻米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 野生稻沼泽 (`wild_rice_marsh`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 精耕稻庄 (`method_rice_collector_r5`)；机械化稻作农场 (`method_rice_collector_r6`)

#### 结构化内容效果

- **野生稻沼泽**（`building`）：`building.wild_rice_marsh` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+12%
  - 效果机制：野生稻采集提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 稻种留存 (`tech.rice_seed_saving`)：该科技需要先掌握 「野生稻采集」。
- 水田畦埂 (`tech.paddy_bunding`)：该科技需要先掌握 「野生稻采集」。
- 水田稻作 (`tech.rice_paddy_cultivation`)：该科技需要先掌握 「野生稻采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 稻种留存 (`tech.rice_seed_saving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rice_seed_saving` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生稻采集 (`tech.wild_rice_collection`)：该科技需要先掌握 「野生稻采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「稻米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+12%
  - 效果机制：稻种留存提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 旱稻繁育 (`tech.upland_rice_propagation`)：该科技需要先掌握 「稻种留存」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 生皮刮制 (`tech.hide_scraping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hide_scraping` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 狩猎 (`tech.hunting`)：该科技需要先掌握 「狩猎」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「生皮处理实践」（breakthrough.hide\_working）

#### 效果摘要

解锁建筑：生皮刮制棚；解锁物资：衣物；作为必要支撑：毡制帐篷

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)
- **建筑 / 生产方式：** 生皮刮制棚 (`hide_scraping_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 毡制帐篷 (`felt_making_tent`)

#### 结构化内容效果

- **生皮刮制棚**（`building`）：`building.hide_scraping_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 毛皮缝制 (`tech.fur_sewing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fur_sewing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「畜牧驯养」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「野生动物」（resource.wild\_game）

#### 效果摘要

解锁建筑：毛皮缝制棚；解锁物资：衣物；商品「衣物」产量 +5%；「布匹织造」生产家族建筑产出 +5%；作为必要支撑：韧皮裹衣棚

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)
- **建筑 / 生产方式：** 毛皮缝制棚 (`fur_sewing_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 韧皮裹衣棚 (`bast_wrap_shelter`)

#### 结构化内容效果

- **毛皮缝制棚**（`building`）：`building.fur_sewing_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+5%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+5%
  - 效果机制：毛皮缝制提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：毛皮缝制提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 羊毛毡制 (`tech.felt_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.felt_making` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「畜牧驯养」。

#### 发现启发（仅用于揭示）

- 已发现信号「羊」（bio.sheep）

#### 效果摘要

商品「衣物」产量 +4%；「布匹织造」生产家族建筑产出 +4%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+4%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+4%
  - 效果机制：羊毛毡制提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：羊毛毡制提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 口述记忆实践 (`tech.oral_memory_practice`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oral_memory_practice` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 全部路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：口述记忆圈；社会领域研究效率 +3%；「研究机构」生产家族建筑产出 +12%；知识部门产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 口述记忆圈 (`oral_memory_circle`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **口述记忆圈**（`building`）：`building.oral_memory_circle` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+3%
- 研究机构：`country.output.family.research_institution_factor`：+12%
- 知识部门产出：`country.output.knowledge_factor`：+12%
  - 效果机制：口述复核与代际传承提高社会知识积累效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：口述记忆实践提高研究与知识机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：口述记忆实践提高知识部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 物候观察实践 (`tech.phenology_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.phenology_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 全部路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：物候观察棚；农业领域研究效率 +3%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 物候观察棚 (`seasonal_observation_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **物候观察棚**（`building`）：`building.seasonal_observation_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+3%
  - 效果机制：连续物候记录提高农业知识积累效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 洪水历法实践 (`tech.flood_calendar_practice`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flood_calendar_practice` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：洪水历法祭所；洪灾损失 -6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 洪水历法祭所 (`flood_calendar_shrine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **洪水历法祭所**（`building`）：`building.flood_calendar_shrine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 洪灾损失：`country.climate.flood_loss_factor`：+6%
  - 效果机制：洪水历法实践降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「洪水历法实践」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 牧群路线记忆 (`tech.pastoral_route_memory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoral_route_memory` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：牧群路线议事帐；农业领域研究效率 +3%；「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 牧群路线议事帐 (`pastoral_council_tent`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **牧群路线议事帐**（`building`）：`building.pastoral_council_tent` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+3%
- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：牧道、季节与水草记忆提高农业知识积累效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：牧群路线记忆提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 潮汐与航向记忆 (`tech.tide_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tide_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 早期知识机构 (`tech.early_knowledge_institution`)：该科技需要先掌握 「早期知识机构」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：潮汐观察屋；全社会贸易运输速度 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 潮汐观察屋 (`tide_observation_hut`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **潮汐观察屋**（`building`）：`building.tide_observation_hut` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会贸易运输速度：`country.trade.speed_factor`：+3%
  - 效果机制：潮汐时序经验改善沿岸运输周转。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 卤水采集 (`tech.brine_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.brine_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 采集 (`tech.gathering`)：该科技需要先掌握 「采集」。

#### 发现启发（仅用于揭示）

- 已发现信号「盐」（resource.salt）

#### 效果摘要

解锁建筑：卤水采集池；解锁物资：卤水；可利用资源：盐；「制盐」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 卤水 (`brine`)
- **建筑 / 生产方式：** 卤水采集池 (`brine_gathering_basin`)
- **自然资源：** 盐 (`salt`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 深井盐矿 (`industrial_salt_mine`)

#### 结构化内容效果

- **卤水采集池**（`building`）：`building.brine_gathering_basin` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **卤水**（`good`）：`good.brine` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **盐**（`resource`）：`resource.salt` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 制盐：`country.output.family.salt_extraction_factor`：+12%
  - 效果机制：卤水采集提高制盐建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 盐渍保存 (`tech.salt_preservation`)：该科技需要先掌握 「卤水采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 燧石辨识 (`tech.flint_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flint_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「燧石」（resource.flint）

#### 效果摘要

可利用资源：燧石

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 燧石 (`flint`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **燧石**（`resource`）：`resource.flint` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「燧石辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 打制石器 (`tech.stone_knapping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.stone_knapping` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

- 燧石辨识 (`tech.flint_identification`)：该科技需要先掌握 「燧石辨识」。
- 枯枝采集 (`tech.deadwood_collection`)：该科技需要先掌握 「枯枝采集」。
- 采集 (`tech.gathering`)：该科技需要先掌握 「采集」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：燧石采掘场；解锁建筑：石器打制工坊；解锁物资：打制石器；解锁物资：燧石原料

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 打制石器 (`chipped_stone_tools`)；燧石原料 (`flint`)
- **建筑 / 生产方式：** 燧石采掘场 (`flint_quarry`)；石器打制工坊 (`knapping_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **燧石采掘场**（`building`）：`building.flint_quarry` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石器打制工坊**（`building`）：`building.knapping_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **打制石器**（`good`）：`good.chipped_stone_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **燧石原料**（`good`）：`good.flint` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 复合工具 (`tech.composite_tools`)：该科技需要先掌握 「打制石器」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「打制石器」。
- 草皮切割 (`tech.turf_cutting`)：该科技需要先掌握 「打制石器」。
- 木炭烧制 (`tech.charcoal_burning`)：该科技需要先掌握 「打制石器」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 复合工具 (`tech.composite_tools`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.composite_tools` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「打制石器」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「燧石」（resource.flint）

#### 效果摘要

全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：复合工具提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 共同体分工 (`tech.communal_specialization`)：该科技需要先掌握 「复合工具」。
- 犁耕农业 (`tech.plough_agriculture`)：该科技需要先掌握 「复合工具」。
- 手工锯木 (`tech.timber_sawing`)：该科技需要先掌握 「复合工具」。
- 木版印刷 (`tech.woodblock_printing`)：该科技需要先掌握 「复合工具」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 共同体分工 (`tech.communal_specialization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.communal_specialization` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 复合工具 (`tech.composite_tools`)：该科技需要先掌握 「复合工具」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：商栈；社会领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商栈 (`merchant_post`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **商栈**（`building`）：`building.merchant_post` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+8%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 家庭生产 (`tech.household_production`)：该科技需要先掌握 「共同体分工」。
- 永久聚落 (`tech.permanent_settlements`)：该科技需要先掌握 「共同体分工」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 磨制石器 (`tech.ground_stone_tools`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.ground_stone_tools` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「打制石器」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：金银器工坊；解锁建筑：改良燧石矿坑；解锁建筑：毛石整理场；解锁建筑：采石场；解锁物资：珠宝；解锁物资：原石；可利用资源：石料；「营造方法」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 燧石原料 (`flint`)；珠宝 (`jewelry`)；原石 (`raw_stone`)
- **建筑 / 生产方式：** 金银器工坊 (`goldsmith_workshop`)；改良燧石矿坑 (`method_flint_quarry_r1`)；毛石整理场 (`rubble_stone_working`)；采石场 (`stone_collector`)
- **自然资源：** 石料 (`stone`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 规模化采石场 (`method_stone_collector_r4`)

#### 结构化内容效果

- **金银器工坊**（`building`）：`building.goldsmith_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **改良燧石矿坑**（`building`）：`building.method_flint_quarry_r1` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **毛石整理场**（`building`）：`building.rubble_stone_working` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **采石场**（`building`）：`building.stone_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **燧石原料**（`good`）：`good.flint` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **珠宝**（`good`）：`good.jewelry` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **原石**（`good`）：`good.raw_stone` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石料**（`resource`）：`resource.stone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 营造方法：`country.output.family.construction_methods_factor`：+12%
  - 效果机制：磨制石器提高石器与营造相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自然铜冷锤 (`tech.natural_copper_working`)：该科技需要先掌握 「磨制石器」。
- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「磨制石器」。
- 马匹驯化 (`tech.horse_domestication`)：该科技需要先掌握 「磨制石器」。
- 梯田农业 (`tech.terrace_farming`)：该科技需要先掌握 「磨制石器」。
- 铜矿井开采 (`tech.copper_mine_engineering`)：该科技需要先掌握 「磨制石器」。
- 地表煤采集 (`tech.surface_coal_collection`)：该科技需要先掌握 「磨制石器」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭生产 (`tech.household_production`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.household_production` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 共同体分工 (`tech.communal_specialization`)：该科技需要先掌握 「共同体分工」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

社会领域研究效率 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+20%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 玉米园圃 (`tech.maize_garden_horticulture`)：该科技需要先掌握 「家庭生产」。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该科技需要先掌握 「家庭生产」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 草皮切割 (`tech.turf_cutting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.turf_cutting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 全部路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「打制石器」。

#### 发现启发（仅用于揭示）

- 已发现信号「牧场承载力」（resource.pasture）

#### 效果摘要

解锁建筑：草皮切割场；解锁物资：草皮块；可利用资源：牧场承载力

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 草皮块 (`turf_block`)
- **建筑 / 生产方式：** 草皮切割场 (`turf_cutting_ground`)
- **自然资源：** 牧场承载力 (`pasture`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **草皮切割场**（`building`）：`building.turf_cutting_ground` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **草皮块**（`good`）：`good.turf_block` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **牧场承载力**（`resource`）：`resource.pasture` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 木炭烧制 (`tech.charcoal_burning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.charcoal_burning` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 能源 · 火 (\`route.energy.fire\`) |
| 全部路线 | 能源 · 火 (\`route.energy.fire\`)；生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「火种控制」。
- 打制石器 (`tech.stone_knapping`)：该科技需要先掌握 「打制石器」。

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：覆土木炭窑；解锁物资：木炭；木材 -8%；作为必要支撑：烧砖窑、露天陶器烧造、露天青铜作坊、升焰陶窑

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 木炭 (`charcoal`)
- **建筑 / 生产方式：** 覆土木炭窑 (`charcoal_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 烧砖窑 (`fired_brick_kiln`)；露天陶器烧造 (`open_pottery_hearth`)；露天青铜作坊 (`ore_bronzesmith_camp`)；升焰陶窑 (`pottery_kiln`)

#### 结构化内容效果

- **覆土木炭窑**（`building`）：`building.charcoal_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **木炭**（`good`）：`good.charcoal` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 木材：`country.resource.timber.use_factor`：+8%
  - 效果机制：炭窑控制提高木材转化效率并减少原料耗用。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`

#### 被以下科技作为硬前置

- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：该科技需要先掌握 「木炭烧制」。
- 块炼铁 (`tech.iron_smelting`)：块炼炉以木炭为燃料与还原剂。
- 火药配制 (`tech.gunpowder_formulation`)：木炭是火药三组分之一。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 黏土调制 (`tech.clay_preparation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.clay_preparation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 黏土辨识 (`tech.clay_identification`)：该科技需要先掌握 「黏土辨识」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：露天黏土坑；解锁物资：黏土；「营造方法」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黏土 (`clay`)
- **建筑 / 生产方式：** 露天黏土坑 (`early_clay_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **露天黏土坑**（`building`）：`building.early_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黏土**（`good`）：`good.clay` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 营造方法：`country.output.family.construction_methods_factor`：+12%
  - 效果机制：黏土调制提高营造方法建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 手制陶器 (`tech.hand_pottery`)：该科技需要先掌握 「黏土调制」。
- 窑烧控制 (`tech.kiln_firing`)：该科技需要先掌握 「黏土调制」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 手制陶器 (`tech.hand_pottery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hand_pottery` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 黏土调制 (`tech.clay_preparation`)：该科技需要先掌握 「黏土调制」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：露天陶器烧造；解锁物资：陶器；「营造方法」生产家族建筑产出 +12%；作为必要支撑：升焰陶窑、书记学校

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 陶器 (`pottery`)
- **建筑 / 生产方式：** 露天陶器烧造 (`open_pottery_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)；升焰陶窑 (`pottery_kiln`)；书记学校 (`scribal_school`)

#### 结构化内容效果

- **露天陶器烧造**（`building`）：`building.open_pottery_hearth` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **陶器**（`good`）：`good.pottery` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 营造方法：`country.output.family.construction_methods_factor`：+12%
  - 效果机制：手制陶器提高窑作与营造相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 陶器容器体系 (`tech.pottery`)：该科技需要先掌握 「手制陶器」。
- 发酵保存 (`tech.fermentation`)：该科技需要先掌握 「手制陶器」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 定居知识 (`tech.settled_knowledge`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.settled_knowledge` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 5000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 种子与繁育观察 (`tech.crop_domestication`)
- 复合工具 (`tech.composite_tools`)
- 自然观察 (`tech.natural_observation`)
- 共同体分工 (`tech.communal_specialization`)
- 野生玉米采集 (`tech.wild_maize_collection`)
- 手制陶器 (`tech.hand_pottery`)
- 季节历 (`tech.seasonal_calendar`)
- 早期贸易 (`tech.early_trade`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 狩猎营地 (`app.stone_age_hunting_camp`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.stone_age_hunting_camp` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 狩猎 (`tech.hunting`)：该知识是此产业交汇自动生效的必要条件。
- 动物追踪 (`tech.animal_tracking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 狩猎营地 (`stone_age_hunting_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期知识机构 (`app.early_knowledge_institution`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_knowledge_institution` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 早期知识机构 (`tech.early_knowledge_institution`)：该知识是此产业交汇自动生效的必要条件。
- 口述传统 (`tech.oral_tradition`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期知识机构 (`early_knowledge_institution`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公共火塘 (`app.communal_hearth`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.communal_hearth` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 火种控制 (`tech.fire_control`)：该知识是此产业交汇自动生效的必要条件。
- 炉火保存 (`tech.hearth_preservation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共火塘 (`communal_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 韧皮裹衣棚 (`app.bast_wrap_shelter`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bast_wrap_shelter` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 纤维捻制 (`tech.fiber_twisting`)：该知识是此产业交汇自动生效的必要条件。
- 毛皮缝制 (`tech.fur_sewing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 韧皮裹衣棚 (`bast_wrap_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 淡水捕鱼营地 (`app.freshwater_fishing_camp`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.freshwater_fishing_camp` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 淡水岸捕 (`tech.freshwater_fishing`)：该知识是此产业交汇自动生效的必要条件。
- 潮间带采集 (`tech.coastal_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 淡水捕鱼营地 (`freshwater_fishing_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 沿岸渔场 (`app.marine_fish_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.marine_fish_collector` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 潮间带采集 (`tech.coastal_fishing`)：该知识是此产业交汇自动生效的必要条件。
- 淡水岸捕 (`tech.freshwater_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 沿岸渔场 (`marine_fish_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 金银器工坊 (`app.goldsmith_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.goldsmith_workshop` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 磨制石器 (`tech.ground_stone_tools`)：该知识是此产业交汇自动生效的必要条件。
- 粗陶淘金 (`tech.gold_panning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金银器工坊 (`goldsmith_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生块茎采集地 (`app.wild_tuber_patch`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.wild_tuber_patch` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 野生块茎挖掘 (`tech.wild_tuber_collection`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 野生块茎采集地 (`wild_tuber_patch`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭块茎试种圃 (`app.household_tuber_garden`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.household_tuber_garden` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。
- 野生块茎挖掘 (`tech.wild_tuber_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭块茎试种圃 (`household_tuber_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生韧皮纤维营地 (`app.bast_fiber_camp`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bast_fiber_camp` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 野生韧皮采集 (`tech.wild_flax_collection`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 野生韧皮纤维营地 (`bast_fiber_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生香料林 (`app.wild_spice_grove`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.wild_spice_grove` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 野生香料采集 (`tech.wild_spice_collection`)：该知识是此产业交汇自动生效的必要条件。
- 采集 (`tech.gathering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 野生香料林 (`wild_spice_grove`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生药草采集地 (`app.wild_medicinal_herb_patch`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.wild_medicinal_herb_patch` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 野生药草采集 (`tech.wild_medicinal_herb_collection`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 野生药草采集地 (`wild_medicinal_herb_patch`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 生皮刮制棚 (`app.hide_scraping_shelter`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.hide_scraping_shelter` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 生皮刮制 (`tech.hide_scraping`)：该知识是此产业交汇自动生效的必要条件。
- 纤维捻制 (`tech.fiber_twisting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 生皮刮制棚 (`hide_scraping_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 毛皮缝制棚 (`app.fur_sewing_shelter`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.fur_sewing_shelter` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 毛皮缝制 (`tech.fur_sewing`)：该知识是此产业交汇自动生效的必要条件。
- 纤维捻制 (`tech.fiber_twisting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 毛皮缝制棚 (`fur_sewing_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 露天陶器烧造 (`app.open_pottery_hearth`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.open_pottery_hearth` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手制陶器 (`tech.hand_pottery`)：该知识是此产业交汇自动生效的必要条件。
- 木炭烧制 (`tech.charcoal_burning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露天陶器烧造 (`open_pottery_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-2"></a>
## 农耕时代

共 65 项研究科技、26 项自动应用，科技研究成本范围 3400-12000；时代里程碑：农耕社会 (`tech.agrarian_society`)。

### 渔舟 (`tech.fishing_boats`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fishing_boats` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | fishing |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「淡水鱼群」（resource.freshwater\_fish）
  - 已发现信号「海洋鱼类」（resource.marine\_fish）

#### 效果摘要

解锁建筑：帆船渔场；「海上作业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 帆船渔场 (`method_marine_fish_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **帆船渔场**（`building`）：`building.method_marine_fish_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+28%
  - 效果机制：渔舟提高海上渔获与作业产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 河运 (`tech.river_transport`)：河运由渔舟造船经验放大为载货船只与航道组织。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自然铜辨识 (`tech.natural_copper_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_copper_identification` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「铜矿」（resource.copper\_ore）

#### 效果摘要

可利用资源：铜矿；「铜矿采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 铜矿 (`copper_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)

#### 结构化内容效果

- **铜矿**（`resource`）：`resource.copper_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+12%
  - 效果机制：自然铜辨识提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自然铜冷锤 (`tech.natural_copper_working`)：该科技需要先掌握 「自然铜辨识」。
- 铜矿井开采 (`tech.copper_mine_engineering`)：该科技需要先掌握 「自然铜辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自然铜冷锤 (`tech.natural_copper_working`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_copper_working` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 自然铜辨识 (`tech.natural_copper_identification`)：该科技需要先掌握 「自然铜辨识」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自然铜冷锤工坊；解锁物资：铜；「铜矿采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铜 (`copper`)
- **建筑 / 生产方式：** 自然铜冷锤工坊 (`natural_copper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 大气式蒸汽机工坊 (`atmospheric_engine_workshop`)；早期半导体厂 (`basic_semiconductor_fab`)；炼铜厂 (`copper_plant`)；早期计算机工场 (`digital_computer_workshop`)；电动机厂 (`electric_motor_plant`)；电子元件厂 (`electronic_components_plant`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；电气化造船厂 (`method_oceanic_shipyard_r7`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；精密仪器厂 (`method_scientific_instrument_works_r8`)；智能化线材厂 (`method_wire_plant_r10`)；远洋造船厂 (`oceanic_shipyard`)；科学仪器工坊 (`scientific_instrument_works`)；线材厂 (`wire_plant`)

#### 结构化内容效果

- **自然铜冷锤工坊**（`building`）：`building.natural_copper_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铜**（`good`）：`good.copper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+12%
  - 效果机制：自然铜冷锤提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 铜退火 (`tech.copper_annealing`)：该科技需要先掌握 「自然铜冷锤」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铜退火 (`tech.copper_annealing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_annealing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 自然铜冷锤 (`tech.natural_copper_working`)：该科技需要先掌握 「自然铜冷锤」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：铜器工坊；解锁建筑：露天青铜作坊；解锁物资：青铜工具；解锁物资：铜工具；「铜矿采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 青铜工具 (`bronze_tools`)；铜工具 (`copper_tools`)
- **建筑 / 生产方式：** 铜器工坊 (`copper_tool_workshop`)；露天青铜作坊 (`ore_bronzesmith_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铜器工坊**（`building`）：`building.copper_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **露天青铜作坊**（`building`）：`building.ore_bronzesmith_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **青铜工具**（`good`）：`good.bronze_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铜工具**（`good`）：`good.copper_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+12%
  - 效果机制：铜退火提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 锡矿辨识 (`tech.tin_identification`)：该科技需要先掌握 「铜退火」。
- 铜矿焙烧 (`tech.copper_ore_roasting`)：该科技需要先掌握 「铜退火」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 锡矿辨识 (`tech.tin_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tin_identification` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 锡 (\`route.resource.tin\`) |
| 全部路线 | 资源 · 锡 (\`route.resource.tin\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 铜退火 (`tech.copper_annealing`)：该科技需要先掌握 「铜退火」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「锡矿贸易接触」（contact.tin）

#### 效果摘要

解锁建筑：浅层锡矿；解锁物资：锡矿石；可利用资源：锡矿；「锡矿采掘」生产家族建筑产出 +12%；作为必要支撑：土法炼锡炉

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锡矿石 (`tin_ore`)
- **建筑 / 生产方式：** 浅层锡矿 (`early_tin_mine`)
- **自然资源：** 锡矿 (`tin_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 土法炼锡炉 (`early_tin_smelter`)；锡矿 (`tin_ore_collector`)

#### 结构化内容效果

- **浅层锡矿**（`building`）：`building.early_tin_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **锡矿石**（`good`）：`good.tin_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锡矿**（`resource`）：`resource.tin_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 锡矿采掘：`country.output.family.tin_extraction_factor`：+12%
  - 效果机制：锡矿辨识提高锡矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 铜锡配比与铸造 (`tech.bronze_casting`)：该科技需要先掌握 「锡矿辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铜矿焙烧 (`tech.copper_ore_roasting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_ore_roasting` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 铜退火 (`tech.copper_annealing`)：该科技需要先掌握 「铜退火」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

无

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：该科技需要先掌握 「铜矿焙烧」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 留种选育 (`tech.seed_selection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.seed_selection` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 种子与繁育观察 (`tech.crop_domestication`)：该科技需要先掌握 「种子与繁育观察」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

农业部门产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+12%
  - 效果机制：留种选育提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 香料栽培 (`tech.spice_cultivation`)：该科技需要先掌握 「留种选育」。
- 雨养田体系 (`tech.rainfed_field_system`)：该科技需要先掌握 「留种选育」。
- 轮作 (`tech.crop_rotation`)：该科技需要先掌握 「留种选育」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 永久聚落 (`tech.permanent_settlements`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.permanent_settlements` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 共同体分工 (`tech.communal_specialization`)：该科技需要先掌握 「共同体分工」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：定居采集营地；全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 采集植物食物 (`gathered_plants`)
- **建筑 / 生产方式：** 定居采集营地 (`method_gathering_ground_r1`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **定居采集营地**（`building`）：`building.method_gathering_ground_r1` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **采集植物食物**（`good`）：`good.gathered_plants` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：永久聚落提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「永久聚落」。
- 记事制度 (`tech.record_keeping`)：该科技需要先掌握 「永久聚落」。
- 商品货币与集市 (`tech.commodity_money`)：定期集市依托长期聚落形成。
- 道路工程 (`tech.road_engineering`)：道路网络连接长期聚落与市场。
- 城市卫生 (`tech.urban_sanitation`)：只有长期聚居的城镇才会面对集中排污与饮水污染问题。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 灌溉 (`tech.irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.irrigation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 永久聚落 (`tech.permanent_settlements`)：该科技需要先掌握 「永久聚落」。
- 洪水历法实践 (`tech.flood_calendar_practice`)：该科技需要先掌握 「洪水历法实践」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

水田生产·旱灾损失 -10%；商品「稻米」产量 +14%；农业部门产出 +14%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 水田生产·旱灾损失：`country.climate.profile.paddy_crop.drought_loss_factor`：+10%
- 稻米：`country.output.good.rice_grain_factor`：+14%
- 农业部门产出：`country.output.agriculture_factor`：+14%
  - 效果机制：灌溉降低水田生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：灌溉提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：灌溉提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 灌溉测量 (`tech.irrigation_surveying`)：该科技需要先掌握 「灌溉」。
- 湿地稻园 (`tech.wetland_rice_gardening`)：该科技需要先掌握 「灌溉」。
- 运河工程 (`tech.canal_engineering`)：该科技需要先掌握 「灌溉」。
- 水力机械 (`tech.water_power`)：水车最早用于提水灌溉，随后才转为磨坊与鼓风动力。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 游牧放牧 (`tech.pastoralism`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoralism` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；生态 · 草原 (\`route.ecology.steppe\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原平原」（landform.steppe\_plain）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

「畜牧业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%
  - 效果机制：游牧放牧提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 牧业网络 (`tech.pastoral_networks`)：牧业网络把游牧放牧扩展为跨区域的转场体系。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 马匹驯化 (`tech.horse_domestication`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.horse_domestication` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 草原 (\`route.ecology.steppe\`) |
| 全部路线 | 生态 · 草原 (\`route.ecology.steppe\`)；动物 · 马匹 (\`route.animal.horse\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原平原」（landform.steppe\_plain）

#### 效果摘要

解锁建筑：养马场；解锁建筑：马匹繁育营地；解锁物资：马匹；「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马匹 (`horses`)
- **建筑 / 生产方式：** 养马场 (`horse_breeder`)；马匹繁育营地 (`horse_breeding_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **养马场**（`building`）：`building.horse_breeder` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马匹繁育营地**（`building`）：`building.horse_breeding_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马匹**（`good`）：`good.horses` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：马匹驯化提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 犁耕农业 (`tech.plough_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plough_agriculture` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 复合工具 (`tech.composite_tools`)：该科技需要先掌握 「复合工具」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「小麦」产量 +18%；商品「玉米」产量 +18%；商品「谷物」产量 +18%；农业部门产出 +18%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+18%
- 玉米：`country.output.good.corn_grain_factor`：+18%
- 谷物：`country.output.good.grain_factor`：+18%
- 农业部门产出：`country.output.agriculture_factor`：+18%
  - 效果机制：犁耕农业提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：犁耕农业提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：犁耕农业提高谷物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：犁耕农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 畜力牵引 (`tech.animal_traction`)：该科技需要先掌握 「犁耕农业」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 玉米选育 (`tech.maize_selection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_selection` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生玉米采集 (`tech.wild_maize_collection`)：该科技需要先掌握 「野生玉米采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

商品「玉米」产量 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+18%
  - 效果机制：玉米选育提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 旱作农业 (`tech.dryland_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dryland_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 全部路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生谷穗采集 (`tech.wild_wheat_collection`)：该科技需要先掌握 「野生谷穗采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱盆地」（landform.arid\_basin）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

农业部门产出 +8%；旱作生产·旱灾损失 -12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+12%
  - 效果机制：旱作农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：旱作农业降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 旱作保水 (`tech.dryland_water_retention`)：该科技需要先掌握 「旱作农业」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 梯田农业 (`tech.terrace_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.terrace_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 地理 · 高地 (\`route.geography.highland\`) |
| 全部路线 | 地理 · 高地 (\`route.geography.highland\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)：该科技需要先掌握 「块茎保存」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「山地」（landform.mountain）
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：梯田农业提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 香料栽培 (`tech.spice_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.spice_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生香料采集 (`tech.wild_spice_collection`)：该科技需要先掌握 「野生香料采集」。
- 留种选育 (`tech.seed_selection`)：该科技需要先掌握 「留种选育」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「种植园承载力」（resource.plantation\_land）
  - 已发现信号「连续湿季经验」（weather.prolonged\_wet\_season）

#### 效果摘要

解锁建筑：药草园；「专用商品作物」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)
- **建筑 / 生产方式：** 药草园 (`medicinal_herb_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药草园**（`building`）：`building.medicinal_herb_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+28%
  - 效果机制：香料栽培提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 天然橡胶加工 (`tech.rubber_working`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rubber_working` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 野生割胶 (`tech.wild_latex_tapping`)：该科技需要先掌握 「野生割胶」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「种植园承载力」（resource.plantation\_land）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁建筑：野生割胶营地；解锁物资：天然乳胶；「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 天然乳胶 (`latex`)
- **建筑 / 生产方式：** 野生割胶营地 (`rubber_tapping_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)

#### 结构化内容效果

- **野生割胶营地**（`building`）：`building.rubber_tapping_camp` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：天然橡胶加工提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)：该科技需要先掌握 「天然橡胶加工」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铜锡配比与铸造 (`tech.bronze_casting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bronze_casting` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；资源 · 锡 (\`route.resource.tin\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 锡矿辨识 (`tech.tin_identification`)：该科技需要先掌握 「锡矿辨识」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「锡矿贸易接触」（contact.tin）

#### 效果摘要

解锁建筑：青铜工具工坊；「铜矿采掘」生产家族建筑产出 +12%；「锡矿采掘」生产家族建筑产出 +12%；作为必要支撑：露天青铜作坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 青铜工具 (`bronze_tools`)
- **建筑 / 生产方式：** 青铜工具工坊 (`bronze_tool_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 露天青铜作坊 (`ore_bronzesmith_camp`)

#### 结构化内容效果

- **青铜工具工坊**（`building`）：`building.bronze_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **青铜工具**（`good`）：`good.bronze_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+12%
- 锡矿采掘：`country.output.family.tin_extraction_factor`：+12%
  - 效果机制：铜锡配比与铸造提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：铜锡配比与铸造提高锡矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 火药武器 (`tech.gunpowder_weapons`)：早期火炮以青铜铸造炮管。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 天文历法 (`tech.celestial_calendars`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.celestial_calendars` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然观察 (`tech.natural_observation`)：该科技需要先掌握 「自然观察」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

工程领域研究效率 +8%；寒冷损失 -5%；热害损失 -5%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 工程领域研究效率：`country.research.engineering_efficiency`：+8%
- 寒冷损失：`country.climate.cold_stress_factor`：+5%
- 热害损失：`country.climate.heat_stress_factor`：+5%
  - 效果机制：计时、测量与统计提高工程研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：天文历法降低全国气候型生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：天文历法降低全国气候型生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 文字 (`tech.writing`)：该科技需要先掌握 「天文历法」。
- 天文导航 (`tech.celestial_navigation`)：天文导航沿用天文历法的星位观测。
- 机械计时 (`tech.mechanical_timekeeping`)：计时需要以天文历法校准。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 记事制度 (`tech.record_keeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.record_keeping` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 记录 (\`route.institution.records\`) |
| 全部路线 | 制度 · 记录 (\`route.institution.records\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 永久聚落 (`tech.permanent_settlements`)：该科技需要先掌握 「永久聚落」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：书记学校；社会领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 书记学校 (`scribal_school`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **书记学校**（`building`）：`building.scribal_school` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+8%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 家庭土地占有 (`tech.household_landholding`)：该科技需要先掌握 「记事制度」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 雨养田体系 (`tech.rainfed_field_system`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rainfed_field_system` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 留种选育 (`tech.seed_selection`)：该科技需要先掌握 「留种选育」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱经验」（weather.drought）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：家庭亚麻试种圃；可利用资源：旱地承载力；可利用资源：肥沃土壤；农业部门产出 +12%；作为必要支撑：家庭纺织坊、家庭棉花园圃、佃作棉花田、菜蔬农场、亚麻农场、冷凉高地块茎田、家庭玉米园圃、垄作马铃薯田、自给农庄

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)
- **建筑 / 生产方式：** 家庭亚麻试种圃 (`household_flax_plot`)
- **自然资源：** 肥沃土壤 (`fertile_soil`)；旱地承载力 (`arable_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化农场 (`automated_farm`)；家庭纺织坊 (`cottage_weaving`)；棉花农场 (`cotton_collector`)；家庭棉花园圃 (`cotton_garden`)；佃作棉花田 (`cotton_smallholding`)；菜蔬农场 (`fertile_soil_collector`)；亚麻农场 (`flax_collector`)；冷凉高地块茎田 (`highland_tuber_plot`)；改良家用织机 (`improved_domestic_loom`)；改良小农场 (`improved_smallholding`)；电气化集约农场 (`intensive_farm`)；玉米庄园 (`landed_estate`)；家庭玉米园圃 (`maize_garden`)；机械化农场 (`mechanized_farm`)；自动化棉花农场 (`method_cotton_collector_r10`)；机械化棉花农场 (`method_cotton_collector_r6`)；精准棉花农场 (`method_cotton_collector_r8`)；自动化亚麻农场 (`method_flax_collector_r10`)；亚麻庄园 (`method_flax_collector_r3`)；改良亚麻庄园 (`method_flax_collector_r5`)；机械化亚麻农场 (`method_flax_collector_r6`)；精准亚麻农场 (`method_flax_collector_r8`)；高地精准块茎农业 (`method_highland_precision_agriculture`)；机械化玉米农场 (`method_landed_estate_r6`)；自动化玉米农场 (`method_maize_farm_r10`)；精准玉米农场 (`method_maize_farm_r8`)；机械化马铃薯农场 (`method_potato_collector_r6`)；自动化马铃薯农场 (`method_potato_farm_r10`)；改良轮作马铃薯庄园 (`method_potato_farm_r5`)；精准马铃薯农场 (`method_potato_farm_r8`)；自动化小麦农场 (`method_wheat_farm_r10`)；佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)；机械化小麦农场 (`method_wheat_farm_r6`)；精准小麦农场 (`method_wheat_farm_r8`)；垄作马铃薯田 (`potato_collector`)；马铃薯庄园 (`potato_estate`)；精准农场 (`precision_farm`)；自给农庄 (`subsistence_farm`)；三圃制小农场 (`three_field_smallholding`)

#### 结构化内容效果

- **家庭亚麻试种圃**（`building`）：`building.household_flax_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **旱地承载力**（`resource`）：`resource.arable_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+12%
  - 效果机制：雨养田体系提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公共仓储 (`tech.public_storehouses`)：该科技需要先掌握 「雨养田体系」。
- 雨养玉米田 (`tech.rainfed_maize_cultivation`)：该科技需要先掌握 「雨养田体系」。
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)：该科技需要先掌握 「雨养田体系」。
- 旱稻繁育 (`tech.upland_rice_propagation`)：该科技需要先掌握 「雨养田体系」。
- 佃作谷物 (`tech.tenant_cereal_farming`)：佃户耕作的是成片雨养田。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 水田畦埂 (`tech.paddy_bunding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.paddy_bunding` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 野生稻采集 (`tech.wild_rice_collection`)：该科技需要先掌握 「野生稻采集」。
- 土建筑 (`tech.earth_building`)：该科技需要先掌握 「土建筑」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

商品「稻米」产量 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+22%
  - 效果机制：水田畦埂提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 旱稻繁育 (`tech.upland_rice_propagation`)：该科技需要先掌握 「水田畦埂」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 旱作保水 (`tech.dryland_water_retention`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dryland_water_retention` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 全部路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 旱作农业 (`tech.dryland_farming`)：该科技需要先掌握 「旱作农业」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）
  - 已发现信号「黄土平原」（landform.loess\_plain）

#### 效果摘要

农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：旱作保水提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 谷物脱粒 (`tech.grain_threshing`)：该科技需要先掌握 「旱作保水」。
- 旱作小麦田 (`tech.dryland_wheat_cultivation`)：该科技需要先掌握 「旱作保水」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 灌溉测量 (`tech.irrigation_surveying`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.irrigation_surveying` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「灌溉」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「三角洲」（landform.delta）
  - 已发现信号「聚落等级 1」（development.settlement.tier\_1\_90d）

#### 效果摘要

无

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 退水玉米地 (`tech.flood_recession_maize`)：该科技需要先掌握 「灌溉测量」。
- 退水小麦地 (`tech.flood_recession_wheat`)：该科技需要先掌握 「灌溉测量」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 窑烧控制 (`tech.kiln_firing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.kiln_firing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「火种控制」。
- 黏土调制 (`tech.clay_preparation`)：该科技需要先掌握 「黏土调制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：土法炼锡炉；解锁建筑：烧砖窑；解锁建筑：升焰陶窑；解锁物资：砖块；解锁物资：锡；「锡矿采掘」生产家族建筑产出 +12%；作为必要支撑：制砖厂、青铜工具工坊、露天青铜作坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 砖块 (`bricks`)；陶器 (`pottery`)；锡 (`tin`)
- **建筑 / 生产方式：** 土法炼锡炉 (`early_tin_smelter`)；烧砖窑 (`fired_brick_kiln`)；升焰陶窑 (`pottery_kiln`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制砖厂 (`bricks_plant`)；青铜工具工坊 (`bronze_tool_workshop`)；露天青铜作坊 (`ore_bronzesmith_camp`)

#### 结构化内容效果

- **土法炼锡炉**（`building`）：`building.early_tin_smelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **烧砖窑**（`building`）：`building.fired_brick_kiln` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **升焰陶窑**（`building`）：`building.pottery_kiln` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **砖块**（`good`）：`good.bricks` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **陶器**（`good`）：`good.pottery` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锡**（`good`）：`good.tin` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 锡矿采掘：`country.output.family.tin_extraction_factor`：+12%
  - 效果机制：窑烧控制提高锡矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 陶器容器体系 (`tech.pottery`)：该科技需要先掌握 「窑烧控制」。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该科技需要先掌握 「窑烧控制」。
- 地表煤利用 (`tech.surface_coal_use`)：窑炉控温经验让煤的高温燃烧可控。
- 火药配制 (`tech.gunpowder_formulation`)：硝石提纯与加热配料依赖窑炉控温经验。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 陶器容器体系 (`tech.pottery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pottery` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 手制陶器 (`tech.hand_pottery`)：该科技需要先掌握 「手制陶器」。
- 窑烧控制 (`tech.kiln_firing`)：该科技需要先掌握 「窑烧控制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「冻融经验」（weather.freeze\_thaw）

#### 效果摘要

解锁建筑：黏土坑；「营造方法」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黏土 (`clay`)
- **建筑 / 生产方式：** 黏土坑 (`clay_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **黏土坑**（`building`）：`building.clay_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黏土**（`good`）：`good.clay` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 营造方法：`country.output.family.construction_methods_factor`：+12%
  - 效果机制：陶器容器体系提高窑作与营造相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：该科技需要先掌握 「陶器容器体系」。
- 坩埚钢 (`tech.crucible_steel`)：耐高温的陶质坩埚来自成熟的陶器容器工艺。
- 活字印刷 (`tech.movable_type_printing`)：泥活字需要烧制稳定的陶字。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 织机织造 (`tech.loom_weaving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.loom_weaving` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 纤维捻制 (`tech.fiber_twisting`)：该科技需要先掌握 「纤维捻制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「人口规模 100」（development.population.100\_90d）
  - 已发现信号「牧场承载力」（resource.pasture）

#### 效果摘要

解锁建筑：行会织造坊；解锁物资：布料；「布匹织造」生产家族建筑产出 +12%；作为必要支撑：家庭纺织坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)
- **建筑 / 生产方式：** 行会织造坊 (`guild_weaving_house`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)；家具厂 (`furniture_plant`)

#### 结构化内容效果

- **行会织造坊**（`building`）：`building.guild_weaving_house` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
  - 效果机制：织机织造提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该科技需要先掌握 「织机织造」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 畜力牵引 (`tech.animal_traction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.animal_traction` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)：该科技需要先掌握 「畜牧驯养」。
- 犁耕农业 (`tech.plough_agriculture`)：该科技需要先掌握 「犁耕农业」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：畜力牵引提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭土地占有 (`tech.household_landholding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.household_landholding` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 记事制度 (`tech.record_keeping`)：该科技需要先掌握 「记事制度」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：菜蔬农场；解锁建筑：自给农庄；解锁物资：混合谷物；解锁物资：蔬菜；全社会经济产出 +8%；作为必要支撑：主食厨房

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 混合谷物 (`grain`)；蔬菜 (`vegetables`)
- **建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)；自给农庄 (`subsistence_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 综合食品厂 (`processed_food_plant`)；主食加工厂 (`staple_food_plant`)；主食厨房 (`staple_kitchen`)；三圃制小农场 (`three_field_smallholding`)

#### 结构化内容效果

- **菜蔬农场**（`building`）：`building.fertile_soil_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自给农庄**（`building`）：`building.subsistence_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：家庭土地占有提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 共同田协调 (`tech.communal_field_coordination`)：该科技需要先掌握 「家庭土地占有」。
- 习惯佃作 (`tech.customary_tenancy`)：佃作以家庭占有与耕作土地的习惯权利为前提。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 共同田协调 (`tech.communal_field_coordination`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.communal_field_coordination` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 家庭土地占有 (`tech.household_landholding`)：该科技需要先掌握 「家庭土地占有」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「人口规模 100」（development.population.100\_90d）
  - 已发现信号「旱地承载力」（resource.arable\_land）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：共同田协调提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公共仓储 (`tech.public_storehouses`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_storehouses` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 雨养田体系 (`tech.rainfed_field_system`)：该科技需要先掌握 「雨养田体系」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

商品「加工主食」产量 +25%；「主粮加工」生产家族建筑产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 加工主食：`country.output.good.prepared_staples_factor`：+25%
- 主粮加工：`country.output.family.staple_preparation_factor`：+25%
  - 效果机制：公共仓储减少储藏损耗，提高加工主食有效供给。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：公共仓储提高主粮加工与仓储相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 城市食物供应 (`tech.urban_food_supply`)：该科技需要先掌握 「公共仓储」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 日晒土坯 (`tech.adobe_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.adobe_making` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 土建筑 (`tech.earth_building`)：该科技需要先掌握 「土建筑」。

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁建筑：日晒土坯场；解锁建筑：制砖厂；解锁物资：日晒土坯；解锁物资：砖块；「营造方法」生产家族建筑产出 +12%；作为必要支撑：公共营造场、烧砖窑

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 日晒土坯 (`adobe_brick`)；砖块 (`bricks`)
- **建筑 / 生产方式：** 日晒土坯场 (`adobe_yard`)；制砖厂 (`bricks_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 公共营造场 (`classical_public_works`)；烧砖窑 (`fired_brick_kiln`)

#### 结构化内容效果

- **日晒土坯场**（`building`）：`building.adobe_yard` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **制砖厂**（`building`）：`building.bricks_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **日晒土坯**（`good`）：`good.adobe_brick` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **砖块**（`good`）：`good.bricks` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 营造方法：`country.output.family.construction_methods_factor`：+12%
  - 效果机制：日晒土坯提高营造方法建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 砌体建筑 (`tech.masonry`)：该科技需要先掌握 「日晒土坯」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玉米园圃 (`tech.maize_garden_horticulture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_garden_horticulture` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 玉米繁育 (`tech.maize_propagation`)：该科技需要先掌握 「玉米繁育」。
- 家庭生产 (`tech.household_production`)：该科技需要先掌握 「家庭生产」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：家庭玉米园圃；商品「玉米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 家庭玉米园圃 (`maize_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **家庭玉米园圃**（`building`）：`building.maize_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+12%
  - 效果机制：玉米园圃提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)：该科技需要先掌握 「玉米园圃」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 刀耕火种玉米 (`tech.swidden_maize_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.swidden_maize_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`)；气候 · 火 (\`route.climate.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 玉米园圃 (`tech.maize_garden_horticulture`)：该科技需要先掌握 「玉米园圃」。
- 控制性用火 (`tech.controlled_burning`)：该科技需要先掌握 「控制性用火」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁建筑：刀耕火种玉米地；商品「玉米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 刀耕火种玉米地 (`swidden_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **刀耕火种玉米地**（`building`）：`building.swidden_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 玉米：`country.output.good.corn_grain_factor`：+12%
  - 效果机制：刀耕火种玉米提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)：该科技需要先掌握 「刀耕火种玉米」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 雨养玉米田 (`tech.rainfed_maize_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rainfed_maize_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)：该科技需要先掌握 「刀耕火种玉米」。
- 雨养田体系 (`tech.rainfed_field_system`)：该科技需要先掌握 「雨养田体系」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：雨养玉米田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 雨养玉米田 (`rainfed_maize_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **雨养玉米田**（`building`）：`building.rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 退水玉米地 (`tech.flood_recession_maize`)：该科技需要先掌握 「雨养玉米田」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 退水玉米地 (`tech.flood_recession_maize`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flood_recession_maize` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)：该科技需要先掌握 「雨养玉米田」。
- 灌溉测量 (`tech.irrigation_surveying`)：该科技需要先掌握 「灌溉测量」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁建筑：退水玉米地；地理专长「terrain.floodplain.agriculture」产出 +25%；商品「玉米」产量 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 退水玉米地 (`floodplain_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水玉米地**（`building`）：`building.floodplain_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- terrain.floodplain.agriculture：`country.output.terrain.floodplain.agriculture_factor`：+25%
- 玉米：`country.output.good.corn_grain_factor`：+25%
  - 效果机制：退水玉米利用洪泛水肥。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：退水玉米地提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 谷物脱粒 (`tech.grain_threshing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.grain_threshing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 旱作保水 (`tech.dryland_water_retention`)：该科技需要先掌握 「旱作保水」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「稻」（bio.rice）

#### 效果摘要

解锁建筑：主食厨房；商品「小麦」产量 +18%；商品「稻米」产量 +18%；商品「玉米」产量 +18%；「主粮加工」生产家族建筑产出 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 熟制主食 (`prepared_staples`)
- **建筑 / 生产方式：** 主食厨房 (`staple_kitchen`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **主食厨房**（`building`）：`building.staple_kitchen` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **熟制主食**（`good`）：`good.prepared_staples` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+18%
- 稻米：`country.output.good.rice_grain_factor`：+18%
- 玉米：`country.output.good.corn_grain_factor`：+18%
- 主粮加工：`country.output.family.staple_preparation_factor`：+18%
  - 效果机制：谷物脱粒提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物脱粒提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物脱粒提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物脱粒提高主粮加工建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rainfed_wheat_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 小麦繁育 (`tech.wheat_propagation`)：该科技需要先掌握 「小麦繁育」。
- 雨养田体系 (`tech.rainfed_field_system`)：该科技需要先掌握 「雨养田体系」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：雨养小麦地；解锁建筑：小麦农场；商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 雨养小麦地 (`rainfed_wheat_plot`)；小麦农场 (`wheat_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **雨养小麦地**（`building`）：`building.rainfed_wheat_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦农场**（`building`）：`building.wheat_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：雨养小麦田提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 退水小麦地 (`tech.flood_recession_wheat`)：该科技需要先掌握 「雨养小麦田」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 退水小麦地 (`tech.flood_recession_wheat`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flood_recession_wheat` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)：该科技需要先掌握 「雨养小麦田」。
- 灌溉测量 (`tech.irrigation_surveying`)：该科技需要先掌握 「灌溉测量」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁建筑：退水小麦地；地理专长「terrain.floodplain.agriculture」产出 +25%；商品「小麦」产量 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 退水小麦地 (`floodplain_wheat_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水小麦地**（`building`）：`building.floodplain_wheat_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- terrain.floodplain.agriculture：`country.output.terrain.floodplain.agriculture_factor`：+25%
- 小麦：`country.output.good.wheat_grain_factor`：+25%
  - 效果机制：退水播种利用洪泛沉积。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：退水小麦地提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)：该科技需要先掌握 「退水小麦地」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 旱作小麦田 (`tech.dryland_wheat_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dryland_wheat_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 退水小麦地 (`tech.flood_recession_wheat`)：该科技需要先掌握 「退水小麦地」。
- 旱作保水 (`tech.dryland_water_retention`)：该科技需要先掌握 「旱作保水」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黄土平原」（landform.loess\_plain）

#### 效果摘要

解锁建筑：旱作保水小麦田；商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱作保水小麦田**（`building`）：`building.dryland_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：旱作小麦田提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 谷物烘焙 (`tech.grain_baking`)：该科技需要先掌握 「旱作小麦田」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 旱稻繁育 (`tech.upland_rice_propagation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.upland_rice_propagation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 水田畦埂 (`tech.paddy_bunding`)：该科技需要先掌握 「水田畦埂」。
- 稻种留存 (`tech.rice_seed_saving`)：该科技需要先掌握 「稻种留存」。
- 雨养田体系 (`tech.rainfed_field_system`)：该科技需要先掌握 「雨养田体系」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：旱稻田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 旱稻田 (`upland_rice_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱稻田**（`building`）：`building.upland_rice_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 湿地稻园 (`tech.wetland_rice_gardening`)：该科技需要先掌握 「旱稻繁育」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 湿地稻园 (`tech.wetland_rice_gardening`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wetland_rice_gardening` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 旱稻繁育 (`tech.upland_rice_propagation`)：该科技需要先掌握 「旱稻繁育」。
- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「灌溉」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「三角洲」（landform.delta）
  - 已发现信号「连续湿季经验」（weather.prolonged\_wet\_season）

#### 效果摘要

解锁建筑：稻作农场；解锁建筑：湿地稻园；商品「稻米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 稻作农场 (`rice_collector`)；湿地稻园 (`wetland_rice_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **稻作农场**（`building`）：`building.rice_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **湿地稻园**（`building`）：`building.wetland_rice_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+12%
  - 效果机制：湿地稻园提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 稻田水位控制 (`tech.rice_water_control`)：该科技需要先掌握 「湿地稻园」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 稻田水位控制 (`tech.rice_water_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rice_water_control` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 湿地稻园 (`tech.wetland_rice_gardening`)：该科技需要先掌握 「湿地稻园」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁建筑：畦埂水稻田；水田生产·洪灾损失 -10%；商品「稻米」产量 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **畦埂水稻田**（`building`）：`building.bunded_rice_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 水田生产·洪灾损失：`country.climate.profile.paddy_crop.flood_loss_factor`：+10%
- 稻米：`country.output.good.rice_grain_factor`：+22%
  - 效果机制：稻田水位控制降低水田生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：稻田水位控制提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 水田稻作 (`tech.rice_paddy_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rice_paddy_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | applied\_method |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生稻采集 (`tech.wild_rice_collection`)：该科技需要先掌握 「野生稻采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「三角洲」（landform.delta）

#### 效果摘要

可利用资源：水田承载力；商品「稻米」产量 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 水田承载力 (`paddy_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+25%
  - 效果机制：水田稻作提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 佃作水田 (`tech.tenant_paddy_management`)：佃作水田以成熟的水田稻作为耕作对象。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 垄作块茎 (`tech.ridge_tuber_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.ridge_tuber_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 块茎繁育 (`tech.potato_propagation`)：该科技需要先掌握 「块茎繁育」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「霜冻经验」（weather.frost）

#### 效果摘要

解锁建筑：垄作马铃薯田；商品「马铃薯」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 垄作马铃薯田 (`potato_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **垄作马铃薯田**（`building`）：`building.potato_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 马铃薯：`country.output.good.potatoes_factor`：+12%
  - 效果机制：垄作块茎提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 防霜窖藏 (`tech.frost_protected_storage`)：该科技需要先掌握 「垄作块茎」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 防霜窖藏 (`tech.frost_protected_storage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.frost_protected_storage` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 垄作块茎 (`tech.ridge_tuber_cultivation`)：该科技需要先掌握 「垄作块茎」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）

#### 效果摘要

旱作生产·寒冷损失 -10%；商品「加工主食」产量 +25%；「主粮加工」生产家族建筑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+10%
- 加工主食：`country.output.good.prepared_staples_factor`：+25%
- 主粮加工：`country.output.family.staple_preparation_factor`：+25%
  - 效果机制：防霜窖藏降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：防霜窖藏减少储藏损耗，提高加工主食有效供给。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：防霜窖藏提高主粮加工与仓储相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 高地块茎农业 (`tech.highland_tuber_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.highland_tuber_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；地理 · 高地 (\`route.geography.highland\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)：该科技需要先掌握 「块茎保存」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁建筑：冷凉高地块茎田；地理专长「landform.plateau.agriculture」产出 +32%；地理专长「landform.mountain.agriculture」产出 +24%；商品「马铃薯」产量 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **冷凉高地块茎田**（`building`）：`building.highland_tuber_plot` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- landform.plateau.agriculture：`country.output.landform.plateau.agriculture_factor`：+32%
- landform.mountain.agriculture：`country.output.landform.mountain.agriculture_factor`：+24%
- 马铃薯：`country.output.good.potatoes_factor`：+28%
  - 效果机制：块茎体系适应高原短季。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：畦作稳定山地农业。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：高地块茎农业提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 沤麻 (`tech.flax_retting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flax_retting` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 亚麻辨识 (`tech.flax_identification`)：该科技需要先掌握 「亚麻辨识」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「连续湿季经验」（weather.prolonged\_wet\_season）

#### 效果摘要

解锁建筑：亚麻农场；解锁建筑：沤麻池；解锁物资：亚麻纤维；「布匹织造」生产家族建筑产出 +12%；「专用商品作物」生产家族建筑产出 +12%；作为必要支撑：行会织造坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)；亚麻纤维 (`flax_fiber`)
- **建筑 / 生产方式：** 亚麻农场 (`flax_collector`)；沤麻池 (`flax_retting_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 行会织造坊 (`guild_weaving_house`)

#### 结构化内容效果

- **亚麻农场**（`building`）：`building.flax_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **沤麻池**（`building`）：`building.flax_retting_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：沤麻提高麻纤维织造相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：沤麻提高亚麻等专用作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 手工纺纱 (`tech.hand_spinning`)：该科技需要先掌握 「沤麻」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 手工纺纱 (`tech.hand_spinning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hand_spinning` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 沤麻 (`tech.flax_retting`)：该科技需要先掌握 「沤麻」。
- 纤维捻制 (`tech.fiber_twisting`)：该科技需要先掌握 「纤维捻制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「旱地承载力」（resource.arable\_land）

#### 效果摘要

解锁建筑：家庭纺织坊；解锁物资：布料；「布匹织造」生产家族建筑产出 +25%；作为必要支撑：行会织造坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)
- **建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；宫廷裁缝坊 (`court_tailor`)；行会织造坊 (`guild_weaving_house`)；电气化造船厂 (`method_oceanic_shipyard_r7`)；远洋造船厂 (`oceanic_shipyard`)；裁缝铺 (`tailor_shop`)

#### 结构化内容效果

- **家庭纺织坊**（`building`）：`building.cottage_weaving` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+25%
  - 效果机制：手工纺纱提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 织造 (`tech.weaving`)：该科技需要先掌握 「手工纺纱」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 织造 (`tech.weaving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.weaving` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 手工纺纱 (`tech.hand_spinning`)：该科技需要先掌握 「手工纺纱」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「人口规模 100」（development.population.100\_90d）

#### 效果摘要

解锁建筑：家用织机；解锁建筑：家庭织造棚；「布匹织造」生产家族建筑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)
- **建筑 / 生产方式：** 家用织机 (`household_loom`)；家庭织造棚 (`household_weaving_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **家用织机**（`building`）：`building.household_loom` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **家庭织造棚**（`building`）：`building.household_weaving_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+25%
  - 效果机制：织造提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 纺织机械 (`tech.textile_machinery`)：纺织机械把手工纺纱与织造的动作机械化（动力织机 ← 飞梭）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 棉花去籽 (`tech.cotton_ginning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cotton_ginning` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 野生棉铃采集 (`tech.wild_cotton_collection`)：该科技需要先掌握 「野生棉铃采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「人口规模 100」（development.population.100\_90d）

#### 效果摘要

解锁建筑：手工轧棉棚；解锁物资：棉纤维；「专用商品作物」生产家族建筑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 棉纤维 (`cotton_fiber`)
- **建筑 / 生产方式：** 手工轧棉棚 (`cotton_ginning_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 机械轧棉厂 (`mechanized_cotton_gin`)

#### 结构化内容效果

- **手工轧棉棚**（`building`）：`building.cotton_ginning_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **棉纤维**（`good`）：`good.cotton_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+25%
  - 效果机制：棉花去籽提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 棉花园圃 (`tech.cotton_gardening`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cotton_gardening` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生棉铃采集 (`tech.wild_cotton_collection`)：该科技需要先掌握 「野生棉铃采集」。
- 种子与繁育观察 (`tech.crop_domestication`)：该科技需要先掌握 「种子与繁育观察」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「热浪经验」（weather.heatwave）

#### 效果摘要

解锁建筑：家庭棉花园圃；可利用资源：种植园承载力；「专用商品作物」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 籽棉 (`seed_cotton`)
- **建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 药材种植园 (`medicinal_herbs_collector`)；自动化药材农场 (`method_medicinal_herbs_collector_r10`)；受控环境药材农场 (`method_medicinal_herbs_collector_r7`)；精准药材农场 (`method_medicinal_herbs_collector_r8`)；自动化橡胶种植园 (`method_rubber_tree_collector_r10`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；精准橡胶种植园 (`method_rubber_tree_collector_r8`)；专用商品作物种植园 (`method_specialty_commodity_plantation`)；自动化香料种植园 (`method_spice_plants_collector_r10`)；机械化香料种植园 (`method_spice_plants_collector_r6`)；精准香料种植园 (`method_spice_plants_collector_r8`)

#### 结构化内容效果

- **家庭棉花园圃**（`building`）：`building.cotton_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+12%
  - 效果机制：棉花园圃提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 商品作物管理 (`tech.commodity_crop_management`)：棉花是最早规模化的商品作物之一。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 遮阴香料园 (`tech.spice_shade_gardening`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.spice_shade_gardening` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 野生香料采集 (`tech.wild_spice_collection`)：该科技需要先掌握 「野生香料采集」。
- 种子与繁育观察 (`tech.crop_domestication`)：该科技需要先掌握 「种子与繁育观察」。
- 家庭生产 (`tech.household_production`)：该科技需要先掌握 「家庭生产」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「种植园承载力」（resource.plantation\_land）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁建筑：林下遮阴香料园；可利用资源：种植园承载力；种植园生产·热害损失 -12%；「专用商品作物」生产家族建筑产出 +24%；作为必要支撑：药材商品园、药草园、商品香料园

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 香料 (`spices`)
- **建筑 / 生产方式：** 林下遮阴香料园 (`spice_shade_garden`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 药材商品园 (`medicinal_herb_estate`)；药草园 (`medicinal_herb_garden`)；商品香料园 (`spice_managed_garden`)

#### 结构化内容效果

- **林下遮阴香料园**（`building`）：`building.spice_shade_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 种植园生产·热害损失：`country.climate.profile.plantation_crop.heat_stress_loss_factor`：+12%
- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+24%
  - 效果机制：遮阴香料园降低种植园生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：遮阴香料园提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.latex_smoke_coagulation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 天然橡胶加工 (`tech.rubber_working`)：该科技需要先掌握 「天然橡胶加工」。
- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「火种控制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「连续湿季经验」（weather.prolonged\_wet\_season）

#### 效果摘要

解锁建筑：乳胶烟熏凝固棚；解锁物资：凝固天然橡胶；可利用资源：种植园承载力；「专用商品作物」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 凝固天然橡胶 (`natural_rubber`)
- **建筑 / 生产方式：** 乳胶烟熏凝固棚 (`latex_smoking_shelter`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；智能化汽车厂 (`method_automobiles_plant_r10`)

#### 结构化内容效果

- **乳胶烟熏凝固棚**（`building`）：`building.latex_smoking_shelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **凝固天然橡胶**（`good`）：`good.natural_rubber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 专用商品作物：`country.output.family.specialty_commodity_crops_factor`：+28%
  - 效果机制：乳胶烟熏凝固提高专用商品作物建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 手工锯木 (`tech.timber_sawing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.timber_sawing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 复合工具 (`tech.composite_tools`)：该科技需要先掌握 「复合工具」。

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：锯木场；解锁建筑：改良锯木场；解锁建筑：组织化伐木场；解锁物资：木材；木材 -10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原木 (`logs`)；木材 (`lumber`)
- **建筑 / 生产方式：** 锯木场 (`lumber_plant`)；改良锯木场 (`method_lumber_plant_r2`)；组织化伐木场 (`method_timber_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；家具厂 (`furniture_plant`)；家具行会工坊 (`guild_hall`)；远洋造船厂 (`oceanic_shipyard`)；钢制工具厂 (`tools_plant`)

#### 结构化内容效果

- **锯木场**（`building`）：`building.lumber_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **改良锯木场**（`building`）：`building.method_lumber_plant_r2` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **组织化伐木场**（`building`）：`building.method_timber_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **木材**（`good`）：`good.lumber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 木材：`country.resource.timber.use_factor`：+10%
  - 效果机制：锯切提高原木得材率。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`

#### 被以下科技作为硬前置

- 树皮纸 (`tech.bark_paper_making`)：该科技需要先掌握 「手工锯木」。
- 森林管理 (`tech.forest_management`)：森林经营是为持续供应锯材而进行的轮伐与育林。
- 矿井木支护 (`tech.mine_timbering`)：支护需要成批锯制的立柱与横梁。
- 蒸汽锯木 (`tech.steam_sawmilling`)：该科技需要先掌握 「手工锯木」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 乳品加工 (`tech.dairy_processing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dairy_processing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁建筑：乳品工坊；解锁物资：乳制品；「畜牧业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 乳制品 (`dairy_products`)
- **建筑 / 生产方式：** 乳品工坊 (`creamery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 乳制品厂 (`dairy_products_plant`)

#### 结构化内容效果

- **乳品工坊**（`building`）：`building.creamery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **乳制品**（`good`）：`good.dairy_products` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%
  - 效果机制：乳品加工提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 皮革鞣制 (`tech.hide_tanning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hide_tanning` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「牧场承载力」（resource.pasture）

#### 效果摘要

解锁建筑：鞋匠铺；解锁建筑：皮革制品小作坊；解锁建筑：制革工坊；解锁物资：鞋履；解锁物资：皮革；解锁物资：皮革制品；制造部门产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鞋履 (`footwear`)；皮革 (`leather`)；皮革制品 (`leather_goods`)
- **建筑 / 生产方式：** 鞋匠铺 (`cobbler_shop`)；皮革制品小作坊 (`leather_goods_workshop`)；制革工坊 (`tannery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；皮革制品工厂 (`leather_goods_factory`)；皮革制品工场 (`leather_goods_manufactory`)；制革厂 (`leather_plant`)；智能皮革制品工厂 (`smart_leather_goods_factory`)

#### 结构化内容效果

- **鞋匠铺**（`building`）：`building.cobbler_shop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品小作坊**（`building`）：`building.leather_goods_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **制革工坊**（`building`）：`building.tannery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鞋履**（`good`）：`good.footwear` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革**（`good`）：`good.leather` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品**（`good`）：`good.leather_goods` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+28%
  - 效果机制：皮革鞣制提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 皮纸制作 (`tech.parchment_making`)：皮纸制作沿用生皮去毛、浸灰与绷晾的鞣制工艺。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 毛用畜牧 (`tech.wool_husbandry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wool_husbandry` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原平原」（landform.steppe\_plain）

#### 效果摘要

解锁建筑：毡制帐篷；解锁建筑：羊毛棚；解锁物资：羊毛；「畜牧业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)；羊毛 (`wool`)
- **建筑 / 生产方式：** 毡制帐篷 (`felt_making_tent`)；羊毛棚 (`wool_shed`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 羊毛行会作坊 (`method_wool_shed_r3`)；精梳羊毛作坊 (`method_wool_shed_r5`)

#### 结构化内容效果

- **毡制帐篷**（`building`）：`building.felt_making_tent` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **羊毛棚**（`building`）：`building.wool_shed` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **羊毛**（`good`）：`good.wool` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%
  - 效果机制：毛用畜牧提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 屠宰分割 (`tech.meat_processing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.meat_processing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 畜群管理 (`tech.herd_management`)：该科技需要先掌握 「畜群管理」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「猪」（bio.pig）

#### 效果摘要

解锁建筑：屠宰场；解锁物资：肉类；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肉类 (`meat`)；生皮 (`raw_hide`)
- **建筑 / 生产方式：** 屠宰场 (`slaughterhouse`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业屠宰场 (`mechanized_slaughterhouse`)

#### 结构化内容效果

- **屠宰场**（`building`）：`building.slaughterhouse` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **肉类**（`good`）：`good.meat` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：屠宰分割提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 发酵保存 (`tech.fermentation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fermentation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 炉火保存 (`tech.hearth_preservation`)：该科技需要先掌握 「炉火保存」。
- 手制陶器 (`tech.hand_pottery`)：该科技需要先掌握 「手制陶器」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：酿酒坊；解锁物资：酒饮；「主粮加工」生产家族建筑产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 酒饮 (`beverages`)
- **建筑 / 生产方式：** 酿酒坊 (`brewery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 酿造厂 (`beverages_plant`)；蒸馏酒坊 (`distillery`)

#### 结构化内容效果

- **酿酒坊**（`building`）：`building.brewery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **酒饮**（`good`）：`good.beverages` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 主粮加工：`country.output.family.staple_preparation_factor`：+25%
  - 效果机制：发酵保存提高主粮加工建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 盐渍保存 (`tech.salt_preservation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.salt_preservation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`)；资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 卤水采集 (`tech.brine_collection`)：该科技需要先掌握 「卤水采集」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「盐」（resource.salt）
  - 已发现信号「硝石」（resource.saltpeter）
  - 已发现信号「热浪经验」（weather.heatwave）

#### 效果摘要

解锁建筑：煮盐灶；解锁建筑：盐场；解锁物资：食盐；商品「加工食品」家庭消费 -8%；「制盐」生产家族建筑产出 +12%；作为必要支撑：制皂工坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 食盐 (`salt`)
- **建筑 / 生产方式：** 煮盐灶 (`brine_boiling_hearth`)；盐场 (`salt_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 化学工场 (`industrial_chemicals_plant`)；深井盐矿 (`industrial_salt_mine`)；工业制皂厂 (`method_soap_plant_r6`)；制皂工坊 (`soap_plant`)

#### 结构化内容效果

- **煮盐灶**（`building`）：`building.brine_boiling_hearth` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **盐场**（`building`）：`building.salt_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **食盐**（`good`）：`good.salt` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 加工食品：`country.consumption.good.processed_food_factor`：+8%
- 制盐：`country.output.family.salt_extraction_factor`：+12%
  - 效果机制：盐藏减少加工食品的腐败损失。
  - 运行时消费者：`NativeEconomyRuntime::effective_household_good_quantity`
  - 效果机制：盐渍保存提高制盐建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 太阳蒸发制盐 (`tech.solar_evaporation`)：该科技需要先掌握 「盐渍保存」。
- 远洋补给 (`tech.oceanic_provisioning`)：远洋补给以盐渍食物为主要储备。
- 罐藏 (`tech.canning`)：罐藏延续了隔绝腐败的食物保存思路。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 谷物烘焙 (`tech.grain_baking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.grain_baking` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)：该科技需要先掌握 「旱作小麦田」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「人口规模 100」（development.population.100\_90d）

#### 效果摘要

解锁建筑：面包坊；解锁物资：面包；商品「小麦」产量 +28%；商品「稻米」产量 +28%；商品「玉米」产量 +28%；「主粮加工」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 面包 (`bread`)
- **建筑 / 生产方式：** 面包坊 (`bakery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 面包厂 (`bread_plant`)

#### 结构化内容效果

- **面包坊**（`building`）：`building.bakery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **面包**（`good`）：`good.bread` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 小麦：`country.output.good.wheat_grain_factor`：+28%
- 稻米：`country.output.good.rice_grain_factor`：+28%
- 玉米：`country.output.good.corn_grain_factor`：+28%
- 主粮加工：`country.output.family.staple_preparation_factor`：+28%
  - 效果机制：谷物烘焙提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物烘焙提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物烘焙提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：谷物烘焙提高主粮加工建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期玻璃烧制 (`tech.early_glassmaking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.early_glassmaking` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 窑烧控制 (`tech.kiln_firing`)：该科技需要先掌握 「窑烧控制」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石灰岩」（resource.limestone）
  - 已发现信号「冻融经验」（weather.freeze\_thaw）

#### 效果摘要

解锁建筑：玻璃窑；解锁建筑：硅砂矿坑；解锁建筑：玻璃器皿小作坊；解锁物资：玻璃；解锁物资：玻璃器皿；解锁物资：硅砂；制造部门产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玻璃 (`glass`)；玻璃器皿 (`glassware`)；硅砂 (`silica_sand`)
- **建筑 / 生产方式：** 玻璃窑 (`classical_glass_kiln`)；硅砂矿坑 (`classical_silica_pit`)；玻璃器皿小作坊 (`glassware_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 早期电气设备厂 (`basic_electrical_equipment_works`)；早期半导体厂 (`basic_semiconductor_fab`)；玻璃厂 (`glass_plant`)；玻璃器皿工厂 (`glassware_factory`)；玻璃器皿工场 (`glassware_manufactory`)；电气化造船厂 (`method_oceanic_shipyard_r7`)；电气化包装厂 (`method_packaging_plant_r7`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；精密仪器厂 (`method_scientific_instrument_works_r8`)；远洋造船厂 (`oceanic_shipyard`)；包装材料厂 (`packaging_plant`)；科学仪器工坊 (`scientific_instrument_works`)；半导体厂 (`semiconductors_plant`)；硅砂矿 (`silica_sand_collector`)；智能玻璃器皿工厂 (`smart_glassware_factory`)

#### 结构化内容效果

- **玻璃窑**（`building`）：`building.classical_glass_kiln` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **硅砂矿坑**（`building`）：`building.classical_silica_pit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿小作坊**（`building`）：`building.glassware_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃**（`good`）：`good.glass` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿**（`good`）：`good.glassware` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硅砂**（`good`）：`good.silica_sand` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+25%
  - 效果机制：早期玻璃烧制提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 商品货币与集市 (`tech.commodity_money`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commodity_money` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 交流 (\`route.trade.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 早期贸易 (`tech.early_trade`)：集市把零散的以物易物固定为定期交易。
- 永久聚落 (`tech.permanent_settlements`)：定期集市依托长期聚落形成。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

国内贸易容量 +5%

#### 机会成本

占用社会研究预算，推迟专业生产路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+5%
  - 效果机制：谷物、贝币等商品货币降低了以物易物的撮合成本。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 农耕社会 (`tech.agrarian_society`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agrarian_society` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 12000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 9 项候选中的任意 4 项：
- 留种选育 (`tech.seed_selection`)
- 犁耕农业 (`tech.plough_agriculture`)
- 天文历法 (`tech.celestial_calendars`)
- 永久聚落 (`tech.permanent_settlements`)
- 水田稻作 (`tech.rice_paddy_cultivation`)
- 铜锡配比与铸造 (`tech.bronze_casting`)
- 灌溉测量 (`tech.irrigation_surveying`)
- 记事制度 (`tech.record_keeping`)
- 旱作农业 (`tech.dryland_farming`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 帆船渔场 (`app.method_marine_fish_collector_r2`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_marine_fish_collector_r2` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 渔舟 (`tech.fishing_boats`)：该知识是此产业交汇自动生效的必要条件。
- 潮间带采集 (`tech.coastal_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 帆船渔场 (`method_marine_fish_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 露天青铜作坊 (`app.ore_bronzesmith_camp`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.ore_bronzesmith_camp` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 铜退火 (`tech.copper_annealing`)：该知识是此产业交汇自动生效的必要条件。
- 木炭烧制 (`tech.charcoal_burning`)：该知识是此产业交汇自动生效的必要条件。
- 铜锡配比与铸造 (`tech.bronze_casting`)：该知识是此产业交汇自动生效的必要条件。
- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露天青铜作坊 (`ore_bronzesmith_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 药草园 (`app.medicinal_herb_garden`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.medicinal_herb_garden` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 香料栽培 (`tech.spice_cultivation`)：该知识是此产业交汇自动生效的必要条件。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 药草园 (`medicinal_herb_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 野生割胶营地 (`app.rubber_tapping_camp`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.rubber_tapping_camp` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 天然橡胶加工 (`tech.rubber_working`)：该知识是此产业交汇自动生效的必要条件。
- 枯枝采集 (`tech.deadwood_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 野生割胶营地 (`rubber_tapping_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 青铜工具工坊 (`app.bronze_tool_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bronze_tool_workshop` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 铜锡配比与铸造 (`tech.bronze_casting`)：该知识是此产业交汇自动生效的必要条件。
- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 青铜工具工坊 (`bronze_tool_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 书记学校 (`app.scribal_school`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.scribal_school` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 记事制度 (`tech.record_keeping`)：该知识是此产业交汇自动生效的必要条件。
- 早期知识机构 (`tech.early_knowledge_institution`)：该知识是此产业交汇自动生效的必要条件。
- 手制陶器 (`tech.hand_pottery`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 书记学校 (`scribal_school`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭亚麻试种圃 (`app.household_flax_plot`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.household_flax_plot` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。
- 野生韧皮采集 (`tech.wild_flax_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭亚麻试种圃 (`household_flax_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 土法炼锡炉 (`app.early_tin_smelter`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_tin_smelter` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。
- 锡矿辨识 (`tech.tin_identification`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 土法炼锡炉 (`early_tin_smelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 烧砖窑 (`app.fired_brick_kiln`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.fired_brick_kiln` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。
- 木炭烧制 (`tech.charcoal_burning`)：该知识是此产业交汇自动生效的必要条件。
- 日晒土坯 (`tech.adobe_making`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 烧砖窑 (`fired_brick_kiln`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 升焰陶窑 (`app.pottery_kiln`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.pottery_kiln` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。
- 木炭烧制 (`tech.charcoal_burning`)：该知识是此产业交汇自动生效的必要条件。
- 手制陶器 (`tech.hand_pottery`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 升焰陶窑 (`pottery_kiln`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 行会织造坊 (`app.guild_weaving_house`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.guild_weaving_house` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 织机织造 (`tech.loom_weaving`)：该知识是此产业交汇自动生效的必要条件。
- 沤麻 (`tech.flax_retting`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会织造坊 (`guild_weaving_house`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 菜蔬农场 (`app.fertile_soil_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.fertile_soil_collector` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自给农庄 (`app.subsistence_farm`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.subsistence_farm` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自给农庄 (`subsistence_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 日晒土坯场 (`app.adobe_yard`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.adobe_yard` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 日晒土坯 (`tech.adobe_making`)：该知识是此产业交汇自动生效的必要条件。
- 采集 (`tech.gathering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 日晒土坯场 (`adobe_yard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 制砖厂 (`app.bricks_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bricks_plant` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 日晒土坯 (`tech.adobe_making`)：该知识是此产业交汇自动生效的必要条件。
- 窑烧控制 (`tech.kiln_firing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制砖厂 (`bricks_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭玉米园圃 (`app.maize_garden`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.maize_garden` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 玉米园圃 (`tech.maize_garden_horticulture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭玉米园圃 (`maize_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 主食厨房 (`app.staple_kitchen`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.staple_kitchen` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 谷物脱粒 (`tech.grain_threshing`)：该知识是此产业交汇自动生效的必要条件。
- 火种控制 (`tech.fire_control`)：该知识是此产业交汇自动生效的必要条件。
- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 主食厨房 (`staple_kitchen`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 垄作马铃薯田 (`app.potato_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.potato_collector` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 垄作块茎 (`tech.ridge_tuber_cultivation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 垄作马铃薯田 (`potato_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 冷凉高地块茎田 (`app.highland_tuber_plot`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.highland_tuber_plot` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 高地块茎农业 (`tech.highland_tuber_farming`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 亚麻农场 (`app.flax_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.flax_collector` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 沤麻 (`tech.flax_retting`)：该知识是此产业交汇自动生效的必要条件。
- 野生韧皮采集 (`tech.wild_flax_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 亚麻农场 (`flax_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭纺织坊 (`app.cottage_weaving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cottage_weaving` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。
- 织机织造 (`tech.loom_weaving`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家庭棉花园圃 (`app.cotton_garden`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cotton_garden` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 毡制帐篷 (`app.felt_making_tent`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.felt_making_tent` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 毛用畜牧 (`tech.wool_husbandry`)：该知识是此产业交汇自动生效的必要条件。
- 生皮刮制 (`tech.hide_scraping`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 毡制帐篷 (`felt_making_tent`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 酿酒坊 (`app.brewery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.brewery` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 发酵保存 (`tech.fermentation`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 酿酒坊 (`brewery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 煮盐灶 (`app.brine_boiling_hearth`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.brine_boiling_hearth` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 盐渍保存 (`tech.salt_preservation`)：该知识是此产业交汇自动生效的必要条件。
- 枯枝采集 (`tech.deadwood_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 煮盐灶 (`brine_boiling_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 硅砂矿坑 (`app.classical_silica_pit`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.classical_silica_pit` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。
- 自然观察 (`tech.natural_observation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 硅砂矿坑 (`classical_silica_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-3"></a>
## 王国时代

共 33 项研究科技、22 项自动应用，科技研究成本范围 3900-30000；时代里程碑：王国体系 (`tech.kingdom_administration`)。

### 铜矿井开采 (`tech.copper_mine_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_mine_engineering` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然铜辨识 (`tech.natural_copper_identification`)：该科技需要先掌握 「自然铜辨识」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：铜矿；解锁物资：铜矿石；作为必要支撑：浅层铜矿、土法炼铜炉

#### 机会成本

自然铜辨识与打制石器汇合后，才能把矿物观察转化为铜矿开采。

#### 内容解锁

- **物资：** 铜矿石 (`copper_ore`)
- **建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 炼铜厂 (`copper_plant`)；浅层铜矿 (`early_copper_mine`)；土法炼铜炉 (`early_copper_smelter`)

#### 结构化内容效果

- **铜矿**（`building`）：`building.copper_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铜矿石**（`good`）：`good.copper_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 木炭坩埚炼铜 (`tech.copper_metallurgy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_metallurgy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 铜矿焙烧 (`tech.copper_ore_roasting`)：该科技需要先掌握 「铜矿焙烧」。
- 木炭烧制 (`tech.charcoal_burning`)：该科技需要先掌握 「木炭烧制」。
- 陶器容器体系 (`tech.pottery`)：该科技需要先掌握 「陶器容器体系」。

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁建筑：土法炼铜炉；「铜矿采掘」生产家族建筑产出 +28%；作为必要支撑：铜矿

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铜 (`copper`)
- **建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)

#### 结构化内容效果

- **土法炼铜炉**（`building`）：`building.early_copper_smelter` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铜**（`good`）：`good.copper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+28%
  - 效果机制：木炭坩埚炼铜提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 太阳蒸发制盐 (`tech.solar_evaporation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.solar_evaporation` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`)；资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 盐渍保存 (`tech.salt_preservation`)：该科技需要先掌握 「盐渍保存」。
- 火种控制 (`tech.fire_control`)：该科技需要先掌握 「火种控制」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：日晒盐田；「制盐」生产家族建筑产出 +18%

#### 机会成本

多条知识路线汇合为一个可见应用节点，避免建筑条件隐式叠加。

#### 内容解锁

- **物资：** 食盐 (`salt`)
- **建筑 / 生产方式：** 日晒盐田 (`solar_salt_pan`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **日晒盐田**（`building`）：`building.solar_salt_pan` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **食盐**（`good`）：`good.salt` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制盐：`country.output.family.salt_extraction_factor`：+18%
  - 效果机制：太阳蒸发制盐提高制盐建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 文字 (`tech.writing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.writing` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 18000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 天文历法 (`tech.celestial_calendars`)：该科技需要先掌握 「天文历法」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 500」（development.population.500\_90d）

#### 效果摘要

解锁建筑：城邦抄写室；解锁物资：手抄本；「研究机构」生产家族建筑产出 +4%；知识部门产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 手抄本 (`manuscripts`)
- **建筑 / 生产方式：** 城邦抄写室 (`classical_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **城邦抄写室**（`building`）：`building.classical_scriptorium` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **手抄本**（`good`）：`good.manuscripts` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 研究机构：`country.output.family.research_institution_factor`：+4%
- 知识部门产出：`country.output.knowledge_factor`：+4%
  - 效果机制：文字提高研究与知识机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：文字提高知识部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 度量衡 (`tech.weights_and_measures`)：该科技需要先掌握 「文字」。
- 学术机构 (`tech.scholarly_academies`)：该科技需要先掌握 「文字」。
- 自然哲学 (`tech.natural_philosophy`)：系统的自然哲学需要文字记录、传抄与辩论。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该科技需要先掌握 「文字」。
- 树皮纸 (`tech.bark_paper_making`)：该科技需要先掌握 「文字」。
- 皮纸制作 (`tech.parchment_making`)：皮纸是为书写而加工的载体。
- 官僚行政 (`tech.state_bureaucracy`)：该科技需要先掌握 「文字」。
- 地图学 (`tech.cartography`)：地图需要文字标注与抄绘传承。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 砌体建筑 (`tech.masonry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.masonry` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 日晒土坯 (`tech.adobe_making`)：该科技需要先掌握 「日晒土坯」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 2」（development.settlement.tier\_2\_180d）

#### 效果摘要

解锁建筑：石灰厂；解锁物资：石灰；可利用资源：石灰岩；全社会经济产出 +8%；作为必要支撑：公共营造场

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石灰 (`lime`)
- **建筑 / 生产方式：** 石灰厂 (`lime_plant`)
- **自然资源：** 石灰岩 (`limestone`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 公共营造场 (`classical_public_works`)

#### 结构化内容效果

- **石灰厂**（`building`）：`building.lime_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石灰**（`good`）：`good.lime` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石灰岩**（`resource`）：`resource.limestone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：砌体建筑提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 道路工程 (`tech.road_engineering`)：铺石路面、桥涵与路基需要砌筑技术。
- 运河工程 (`tech.canal_engineering`)：该科技需要先掌握 「砌体建筑」。
- 城市卫生 (`tech.urban_sanitation`)：排水沟渠与暗渠依赖砌体结构（参照印度河流域城市排污与罗马大下水道）。
- 城市水务 (`tech.urban_waterworks`)：该科技需要先掌握 「砌体建筑」。
- 煤矿平硐 (`tech.coal_adit_mining`)：该科技需要先掌握 「砌体建筑」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 度量衡 (`tech.weights_and_measures`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.weights_and_measures` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 18000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：该科技需要先掌握 「文字」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 4」（development.buildings.active\_4\_180d）

#### 效果摘要

解锁建筑：木槽溜洗场；全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 黄金 (`gold`)
- **建筑 / 生产方式：** 木槽溜洗场 (`primitive_gold_sluice`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **木槽溜洗场**（`building`）：`building.primitive_gold_sluice` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黄金**（`good`）：`good.gold` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：度量衡提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 货币 (`tech.currency`)：该科技需要先掌握 「度量衡」。
- 地图学 (`tech.cartography`)：按比例绘图依赖统一的长度度量与测量。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 市场制度 (`tech.market_institutions`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.market_institutions` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 早期贸易 (`tech.early_trade`)：该科技需要先掌握 「早期贸易」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 10」（development.employment.agriculture.10\_90d）

#### 效果摘要

解锁建筑：商业狩猎与毛皮站；国内贸易容量 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 毛皮 (`fur`)；野味 (`game_meat`)；生皮 (`raw_hide`)
- **建筑 / 生产方式：** 商业狩猎与毛皮站 (`method_stone_age_hunting_camp_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **商业狩猎与毛皮站**（`building`）：`building.method_stone_age_hunting_camp_r4` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **毛皮**（`good`）：`good.fur` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **野味**（`good`）：`good.game_meat` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 行业组织 (`tech.guild_organization`)：行会是城市手工业者在市场制度中的自我组织。
- 汇票与票据 (`tech.bills_of_exchange`)：票据在既有市场制度中流通与背书。
- 商业网络 (`tech.mercantile_networks`)：商业网络连接各地市场。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 货币 (`tech.currency`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.currency` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 早期贸易 (`tech.early_trade`)：该科技需要先掌握 「早期贸易」。
- 度量衡 (`tech.weights_and_measures`)：该科技需要先掌握 「度量衡」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 10」（development.employment.manufacturing.10\_90d）

#### 效果摘要

国内贸易容量 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 汇票与票据 (`tech.bills_of_exchange`)：汇票以统一铸币计价兑付。
- 商业网络 (`tech.mercantile_networks`)：跨区域结算依赖通用货币。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 道路工程 (`tech.road_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.road_engineering` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 地理 · 内陆 (\`route.geography.inland\`) |
| 全部路线 | 地理 · 内陆 (\`route.geography.inland\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 永久聚落 (`tech.permanent_settlements`)：道路网络连接长期聚落与市场。
- 砌体建筑 (`tech.masonry`)：铺石路面、桥涵与路基需要砌筑技术。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 10」（development.employment.knowledge.10\_90d）

#### 效果摘要

解锁建筑：石作工场；解锁建筑：规模化采石场；解锁物资：建筑构件；全社会贸易运输速度 +4%；作为必要支撑：公共营造场

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 建筑构件 (`construction_components`)；原石 (`raw_stone`)
- **建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；规模化采石场 (`method_stone_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 公共营造场 (`classical_public_works`)

#### 结构化内容效果

- **石作工场**（`building`）：`building.classical_masonry_yard` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **规模化采石场**（`building`）：`building.method_stone_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **建筑构件**（`good`）：`good.construction_components` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **原石**（`good`）：`good.raw_stone` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会贸易运输速度：`country.trade.speed_factor`：+4%
  - 效果机制：道路标准改善全社会陆路周转。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 区域粮仓 (`tech.regional_granaries`)：该科技需要先掌握 「道路工程」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 运河工程 (`tech.canal_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.canal_engineering` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 灌溉 (`tech.irrigation`)：该科技需要先掌握 「灌溉」。
- 砌体建筑 (`tech.masonry`)：该科技需要先掌握 「砌体建筑」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 100」（development.output.agriculture.100\_180d）

#### 效果摘要

解锁建筑：石灰石采石场；解锁建筑：石料场；解锁物资：石灰岩；全社会经济产出 +8%；洪灾损失 -8%；作为必要支撑：石灰厂

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石灰岩 (`limestone`)；原石 (`raw_stone`)
- **建筑 / 生产方式：** 石灰石采石场 (`limestone_collector`)；石料场 (`method_stone_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石灰厂 (`lime_plant`)；工业石灰厂 (`method_lime_plant_r6`)；工业石灰岩矿场 (`method_limestone_collector_r6`)

#### 结构化内容效果

- **石灰石采石场**（`building`）：`building.limestone_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石料场**（`building`）：`building.method_stone_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石灰岩**（`good`）：`good.limestone` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **原石**（`good`）：`good.raw_stone` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
- 洪灾损失：`country.climate.flood_loss_factor`：+8%
  - 效果机制：运河工程提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：运河工程降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 水利工程 (`tech.hydraulic_engineering`)：该科技需要先掌握 「运河工程」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 河运 (`tech.river_transport`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.river_transport` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 渔舟 (`tech.fishing_boats`)：河运由渔舟造船经验放大为载货船只与航道组织。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100」（development.output.manufacturing.100\_180d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **河运与湖泊走廊**（`runtime`）：`NativeEconomyRuntime.water_capability` → `river_and_lake_corridor` `unlock` `1.0`；`runtime_consumed`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：河运提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 磁针导航 (`tech.magnetic_navigation`)：该科技需要先掌握 「河运」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 轮作 (`tech.crop_rotation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_rotation` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 留种选育 (`tech.seed_selection`)：该科技需要先掌握 「留种选育」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 50%」（development.satisfaction.50\_180d）

#### 效果摘要

解锁建筑：堆肥场；解锁建筑：榨油坊；解锁物资：食用油；解锁物资：肥料；农业部门产出 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 食用油 (`edible_oil`)；肥料 (`fertilizer`)
- **建筑 / 生产方式：** 堆肥场 (`composting_yard`)；榨油坊 (`edible_oil_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业榨油厂 (`method_edible_oil_plant_r6`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；综合食品厂 (`processed_food_plant`)

#### 结构化内容效果

- **堆肥场**（`building`）：`building.composting_yard` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **榨油坊**（`building`）：`building.edible_oil_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **食用油**（`good`）：`good.edible_oil` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **肥料**（`good`）：`good.fertilizer` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+18%
  - 效果机制：轮作提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 集约轮作 (`tech.intensive_crop_rotation`)：该科技需要先掌握 「轮作」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 城市卫生 (`tech.urban_sanitation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.urban_sanitation` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.public\_health |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 永久聚落 (`tech.permanent_settlements`)：只有长期聚居的城镇才会面对集中排污与饮水污染问题。
- 砌体建筑 (`tech.masonry`)：排水沟渠与暗渠依赖砌体结构（参照印度河流域城市排污与罗马大下水道）。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 500」（development.population.500\_90d）

#### 效果摘要

解锁建筑：制皂工坊；解锁物资：肥皂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥皂 (`soap`)
- **建筑 / 生产方式：** 制皂工坊 (`soap_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业制皂厂 (`method_soap_plant_r6`)

#### 结构化内容效果

- **制皂工坊**（`building`）：`building.soap_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **肥皂**（`good`）：`good.soap` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：城市卫生提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公共卫生 (`tech.public_health`)：公共卫生由城市排污与供水治理发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 学术机构 (`tech.scholarly_academies`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scholarly_academies` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：该科技需要先掌握 「文字」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 2」（development.settlement.tier\_2\_180d）

#### 效果摘要

解锁建筑：古典学院；「研究机构」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 古典学院 (`classical_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **古典学院**（`building`）：`building.classical_academy` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 研究机构：`country.output.family.research_institution_factor`：+12%
  - 效果机制：学术机构提高研究机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 手稿文化 (`tech.manuscript_culture`)：该科技需要先掌握 「学术机构」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自然哲学 (`tech.natural_philosophy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_philosophy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：系统的自然哲学需要文字记录、传抄与辩论。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 4」（development.buildings.active\_4\_180d）

#### 效果摘要

农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 跨区域植物学 (`tech.interregional_botany`)：该科技需要先掌握 「自然哲学」。
- 地质勘探 (`tech.geological_prospecting`)：地质勘探需要自然哲学的成因解释。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plant_fiber_papermaking` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 织机织造 (`tech.loom_weaving`)：该科技需要先掌握 「织机织造」。
- 文字 (`tech.writing`)：该科技需要先掌握 「文字」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 10」（development.employment.manufacturing.10\_90d）

#### 效果摘要

解锁建筑：植物纤维抄纸坊；解锁物资：纸张；「造纸」生产家族建筑产出 +12%；作为必要支撑：树皮纸工坊、活字印刷坊、皮纸工坊、木版印刷坊

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 植物纤维抄纸坊 (`plant_fiber_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)；电气印刷厂 (`method_printed_materials_plant_r7`)；活字印刷坊 (`movable_type_print_shop`)；造纸厂 (`paper_plant`)；皮纸工坊 (`parchment_workshop`)；印刷厂 (`printed_materials_plant`)；木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **植物纤维抄纸坊**（`building`）：`building.plant_fiber_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 造纸：`country.output.family.paper_making_factor`：+12%
  - 效果机制：植物纤维抄纸提高造纸建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 破布纸 (`tech.rag_paper_making`)：该科技需要先掌握 「植物纤维抄纸」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 树皮纸 (`tech.bark_paper_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bark_paper_making` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 手工锯木 (`tech.timber_sawing`)：该科技需要先掌握 「手工锯木」。
- 文字 (`tech.writing`)：该科技需要先掌握 「文字」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 10」（development.employment.knowledge.10\_90d）

#### 效果摘要

解锁建筑：树皮纸工坊；解锁物资：纸张；「造纸」生产家族建筑产出 +12%；作为必要支撑：植物纤维抄纸坊

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 植物纤维抄纸坊 (`plant_fiber_paper_workshop`)

#### 结构化内容效果

- **树皮纸工坊**（`building`）：`building.bark_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 造纸：`country.output.family.paper_making_factor`：+12%
  - 效果机制：树皮纸提高造纸建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 皮纸制作 (`tech.parchment_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.parchment_making` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：皮纸是为书写而加工的载体。
- 皮革鞣制 (`tech.hide_tanning`)：皮纸制作沿用生皮去毛、浸灰与绷晾的鞣制工艺。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 100」（development.output.agriculture.100\_180d）

#### 效果摘要

解锁建筑：皮纸工坊；解锁物资：纸张；「造纸」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 皮纸工坊 (`parchment_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **皮纸工坊**（`building`）：`building.parchment_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 造纸：`country.output.family.paper_making_factor`：+12%
  - 效果机制：皮纸制作提高造纸建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 手稿文化 (`tech.manuscript_culture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manuscript_culture` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 学术机构 (`tech.scholarly_academies`)：该科技需要先掌握 「学术机构」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100」（development.output.manufacturing.100\_180d）

#### 效果摘要

解锁建筑：公共营造场；解锁建筑：修道院抄写室；解锁物资：建筑构件；全社会经济产出 +8%；作为必要支撑：石作工场、城邦抄写室

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 建筑构件 (`construction_components`)；手抄本 (`manuscripts`)
- **建筑 / 生产方式：** 公共营造场 (`classical_public_works`)；修道院抄写室 (`monastic_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；城邦抄写室 (`classical_scriptorium`)

#### 结构化内容效果

- **公共营造场**（`building`）：`building.classical_public_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **修道院抄写室**（`building`）：`building.monastic_scriptorium` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **建筑构件**（`good`）：`good.construction_components` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **手抄本**（`good`）：`good.manuscripts` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：手稿文化提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 特许大学 (`tech.chartered_universities`)：该科技需要先掌握 「手稿文化」。
- 木版印刷 (`tech.woodblock_printing`)：该科技需要先掌握 「手稿文化」。
- 经院研究法 (`tech.scholastic_method`)：经院研究法建立在手稿抄传与注疏传统之上。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 官僚行政 (`tech.state_bureaucracy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.state_bureaucracy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 18000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：该科技需要先掌握 「文字」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 50%」（development.satisfaction.50\_180d）

#### 效果摘要

全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：官僚行政提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 庄园核算 (`tech.estate_accounting`)：该科技需要先掌握 「官僚行政」。
- 公共教育 (`tech.public_education`)：义务教育由国家行政统一推行。
- 国营企业 (`tech.state_enterprises`)：国营企业由国家行政直接出资与任命。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 习惯佃作 (`tech.customary_tenancy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.customary_tenancy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 家庭土地占有 (`tech.household_landholding`)：佃作以家庭占有与耕作土地的习惯权利为前提。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 500」（development.population.500\_90d）

#### 效果摘要

解锁建筑：佃作棉花田；解锁建筑：药材商品园；解锁建筑：商品香料园；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)；籽棉 (`seed_cotton`)；香料 (`spices`)
- **建筑 / 生产方式：** 佃作棉花田 (`cotton_smallholding`)；药材商品园 (`medicinal_herb_estate`)；商品香料园 (`spice_managed_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作棉花田**（`building`）：`building.cotton_smallholding` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材商品园**（`building`）：`building.medicinal_herb_estate` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **商品香料园**（`building`）：`building.spice_managed_garden` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：习惯佃作提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 分成租佃 (`tech.sharecropping`)：分成租佃是在习惯佃作上约定产量分配的租佃形式。
- 佃作谷物 (`tech.tenant_cereal_farming`)：佃作谷物依赖已成形的租佃关系。
- 佃作水田 (`tech.tenant_paddy_management`)：水田的租佃分配依赖习惯佃作。
- 商业租佃 (`tech.commercial_tenancy`)：商业租佃由习惯佃作契约化而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 分成租佃 (`tech.sharecropping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.sharecropping` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 习惯佃作 (`tech.customary_tenancy`)：分成租佃是在习惯佃作上约定产量分配的租佃形式。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 2」（development.settlement.tier\_2\_180d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：分成租佃提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 庄园谷物核算 (`tech.estate_cereal_management`)：玉米与小麦庄园以分成租佃组织劳动。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 庄园核算 (`tech.estate_accounting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_accounting` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 官僚行政 (`tech.state_bureaucracy`)：该科技需要先掌握 「官僚行政」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 4」（development.buildings.active\_4\_180d）

#### 效果摘要

「地籍制度」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 地籍制度：`country.output.family.cadastral_institution_factor`：+12%
  - 效果机制：庄园核算提高地籍制度建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 城市食物供应 (`tech.urban_food_supply`)：该科技需要先掌握 「庄园核算」。
- 牧业网络 (`tech.pastoral_networks`)：庄园牧场需要以账簿管理畜群与草场。
- 庄园司法 (`tech.manorial_jurisdiction`)：庄园司法以庄园核算所确立的领主—佃户账目为依据。
- 庄园谷物核算 (`tech.estate_cereal_management`)：庄园谷物核算把粮食产量纳入庄园账簿。
- 庄园水田核算 (`tech.estate_paddy_management`)：水田产量要纳入庄园账簿统一核算。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作谷物 (`tech.tenant_cereal_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tenant_cereal_farming` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 习惯佃作 (`tech.customary_tenancy`)：佃作谷物依赖已成形的租佃关系。
- 雨养田体系 (`tech.rainfed_field_system`)：佃户耕作的是成片雨养田。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 10」（development.employment.agriculture.10\_90d）

#### 效果摘要

解锁建筑：佃作马铃薯田；解锁建筑：佃作雨养玉米田；解锁建筑：佃作雨养小麦田；农业部门产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)；马铃薯 (`potatoes`)；小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 佃作马铃薯田 (`tenant_potato_field`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作马铃薯田**（`building`）：`building.tenant_potato_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **佃作雨养玉米田**（`building`）：`building.tenant_rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **佃作雨养小麦田**（`building`）：`building.tenant_rainfed_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：佃作谷物提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作水田 (`tech.tenant_paddy_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tenant_paddy_management` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 水田稻作 (`tech.rice_paddy_cultivation`)：佃作水田以成熟的水田稻作为耕作对象。
- 习惯佃作 (`tech.customary_tenancy`)：水田的租佃分配依赖习惯佃作。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 10」（development.employment.manufacturing.10\_90d）

#### 效果摘要

解锁建筑：佃作稻庄；解锁建筑：分成水田；解锁建筑：佃作水田；商品「稻米」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 佃作稻庄 (`method_rice_collector_r3`)；分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作稻庄**（`building`）：`building.method_rice_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **分成水田**（`building`）：`building.sharecrop_paddy` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **佃作水田**（`building`）：`building.tenant_paddy` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+12%
  - 效果机制：佃作水田提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 庄园水田核算 (`tech.estate_paddy_management`)：庄园水田核算建立在佃作水田之上。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 铁矿辨识 (`tech.iron_ore_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.iron_ore_identification` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

可利用资源：铁矿；「铁矿采掘」生产家族建筑产出 +12%；作为必要支撑：浅层铁矿

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 铁矿 (`iron_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层铁矿 (`early_iron_mine`)；蒸汽动力铁矿 (`steam_iron_mine`)

#### 结构化内容效果

- **铁矿**（`resource`）：`resource.iron_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+12%
  - 效果机制：铁矿辨识提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 地表铁矿采集 (`tech.surface_iron_collection`)：该科技需要先掌握 「铁矿辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地表铁矿采集 (`tech.surface_iron_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.surface_iron_collection` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 铁矿辨识 (`tech.iron_ore_identification`)：该科技需要先掌握 「铁矿辨识」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 100」（development.output.agriculture.100\_180d）

#### 效果摘要

解锁建筑：地表铁矿采集场；解锁物资：铁矿石；「铁矿采掘」生产家族建筑产出 +12%；作为必要支撑：浅层铁矿

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铁矿石 (`iron_ore`)
- **建筑 / 生产方式：** 地表铁矿采集场 (`iron_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层铁矿 (`early_iron_mine`)

#### 结构化内容效果

- **地表铁矿采集场**（`building`）：`building.iron_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铁矿石**（`good`）：`good.iron_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+12%
  - 效果机制：地表铁矿采集提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 块炼铁 (`tech.iron_smelting`)：先能拣采地表铁矿才有块炼原料。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 块炼铁 (`tech.iron_smelting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.iron_smelting` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 地表铁矿采集 (`tech.surface_iron_collection`)：先能拣采地表铁矿才有块炼原料。
- 木炭烧制 (`tech.charcoal_burning`)：块炼炉以木炭为燃料与还原剂。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100」（development.output.manufacturing.100\_180d）

#### 效果摘要

解锁建筑：块炼炉；解锁建筑：铁制工具工坊；解锁建筑：金属家用器皿小作坊；解锁物资：金属家用器皿；解锁物资：金属工具；解锁物资：锻铁；「铁矿采掘」生产家族建筑产出 +12%；「金属工具」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 金属家用器皿 (`metal_housewares`)；金属工具 (`tools`)；锻铁 (`wrought_iron`)
- **建筑 / 生产方式：** 块炼炉 (`bloomery`)；铁制工具工坊 (`iron_tool_workshop`)；金属家用器皿小作坊 (`metal_housewares_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 金属家用器皿工厂 (`metal_housewares_factory`)；金属家用器皿工场 (`metal_housewares_manufactory`)；智能金属家用器皿工厂 (`smart_metal_housewares_factory`)；钢制工具厂 (`tools_plant`)

#### 结构化内容效果

- **块炼炉**（`building`）：`building.bloomery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铁制工具工坊**（`building`）：`building.iron_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿小作坊**（`building`）：`building.metal_housewares_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿**（`good`）：`good.metal_housewares` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锻铁**（`good`）：`good.wrought_iron` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+12%
- 金属工具：`country.output.family.metal_toolmaking_factor`：+12%
  - 效果机制：块炼铁提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：块炼铁提高金属工具建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 高炉冶炼 (`tech.blast_furnace`)：高炉是块炼炉在炉高与温度上的放大。
- 坩埚钢 (`tech.crucible_steel`)：坩埚钢以块炼铁为原料再行渗碳熔炼。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 露头煤辨识 (`tech.coal_outcrop_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_outcrop_identification` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

可利用资源：煤炭

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 煤炭 (`coal`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤炭**（`resource`）：`resource.coal` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 地表煤采集 (`tech.surface_coal_collection`)：该科技需要先掌握 「露头煤辨识」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地表煤采集 (`tech.surface_coal_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.surface_coal_collection` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 露头煤辨识 (`tech.coal_outcrop_identification`)：该科技需要先掌握 「露头煤辨识」。
- 磨制石器 (`tech.ground_stone_tools`)：该科技需要先掌握 「磨制石器」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 500」（development.population.500\_90d）

#### 效果摘要

解锁建筑：露头煤采集场；解锁物资：煤炭；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 露头煤采集场 (`surface_coal_gathering`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **露头煤采集场**（`building`）：`building.surface_coal_gathering` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：地表煤采集提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 地表煤利用 (`tech.surface_coal_use`)：先要能稳定拣采露头煤，才谈得上把煤用作燃料。
- 煤矿平硐 (`tech.coal_adit_mining`)：该科技需要先掌握 「地表煤采集」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地表煤利用 (`tech.surface_coal_use`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.surface_coal_use` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`)；能源 · 热能 (\`route.energy.thermal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地表煤采集 (`tech.surface_coal_collection`)：先要能稳定拣采露头煤，才谈得上把煤用作燃料。
- 窑烧控制 (`tech.kiln_firing`)：窑炉控温经验让煤的高温燃烧可控。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 10」（development.employment.agriculture.10\_90d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：地表煤利用提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 城市食物供应 (`tech.urban_food_supply`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.urban_food_supply` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 18000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 公共仓储 (`tech.public_storehouses`)：该科技需要先掌握 「公共仓储」。
- 庄园核算 (`tech.estate_accounting`)：该科技需要先掌握 「庄园核算」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 2」（development.settlement.tier\_2\_180d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：城市食物供应提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 区域粮仓 (`tech.regional_granaries`)：该科技需要先掌握 「城市食物供应」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 王国体系 (`tech.kingdom_administration`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.kingdom_administration` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 30000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 10 项候选中的任意 4 项：
- 轮作 (`tech.crop_rotation`)
- 道路工程 (`tech.road_engineering`)
- 文字 (`tech.writing`)
- 官僚行政 (`tech.state_bureaucracy`)
- 佃作水田 (`tech.tenant_paddy_management`)
- 块炼铁 (`tech.iron_smelting`)
- 自然哲学 (`tech.natural_philosophy`)
- 市场制度 (`tech.market_institutions`)
- 砌体建筑 (`tech.masonry`)
- 货币 (`tech.currency`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铜矿 (`app.copper_ore_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.copper_ore_collector` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 铜矿井开采 (`tech.copper_mine_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 土法炼铜炉 (`app.early_copper_smelter`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_copper_smelter` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：该知识是此产业交汇自动生效的必要条件。
- 铜矿井开采 (`tech.copper_mine_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 城邦抄写室 (`app.classical_scriptorium`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.classical_scriptorium` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 文字 (`tech.writing`)：该知识是此产业交汇自动生效的必要条件。
- 手稿文化 (`tech.manuscript_culture`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 城邦抄写室 (`classical_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 石灰厂 (`app.lime_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.lime_plant` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 砌体建筑 (`tech.masonry`)：该知识是此产业交汇自动生效的必要条件。
- 运河工程 (`tech.canal_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石灰厂 (`lime_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 木槽溜洗场 (`app.primitive_gold_sluice`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.primitive_gold_sluice` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 度量衡 (`tech.weights_and_measures`)：该知识是此产业交汇自动生效的必要条件。
- 粗陶淘金 (`tech.gold_panning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 木槽溜洗场 (`primitive_gold_sluice`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 商业狩猎与毛皮站 (`app.method_stone_age_hunting_camp_r4`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_stone_age_hunting_camp_r4` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 市场制度 (`tech.market_institutions`)：该知识是此产业交汇自动生效的必要条件。
- 动物追踪 (`tech.animal_tracking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商业狩猎与毛皮站 (`method_stone_age_hunting_camp_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 石作工场 (`app.classical_masonry_yard`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.classical_masonry_yard` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 道路工程 (`tech.road_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 手稿文化 (`tech.manuscript_culture`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 规模化采石场 (`app.method_stone_collector_r4`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_stone_collector_r4` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 道路工程 (`tech.road_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 磨制石器 (`tech.ground_stone_tools`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 规模化采石场 (`method_stone_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 堆肥场 (`app.composting_yard`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.composting_yard` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 轮作 (`tech.crop_rotation`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 堆肥场 (`composting_yard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 榨油坊 (`app.edible_oil_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.edible_oil_plant` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 轮作 (`tech.crop_rotation`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 榨油坊 (`edible_oil_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 制皂工坊 (`app.soap_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.soap_plant` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 城市卫生 (`tech.urban_sanitation`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 盐渍保存 (`tech.salt_preservation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制皂工坊 (`soap_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 植物纤维抄纸坊 (`app.plant_fiber_paper_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.plant_fiber_paper_workshop` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。
- 树皮纸 (`tech.bark_paper_making`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 植物纤维抄纸坊 (`plant_fiber_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 树皮纸工坊 (`app.bark_paper_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bark_paper_workshop` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 树皮纸 (`tech.bark_paper_making`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 皮纸工坊 (`app.parchment_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.parchment_workshop` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 皮纸制作 (`tech.parchment_making`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 皮纸工坊 (`parchment_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公共营造场 (`app.classical_public_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.classical_public_works` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手稿文化 (`tech.manuscript_culture`)：该知识是此产业交汇自动生效的必要条件。
- 日晒土坯 (`tech.adobe_making`)：该知识是此产业交汇自动生效的必要条件。
- 砌体建筑 (`tech.masonry`)：该知识是此产业交汇自动生效的必要条件。
- 道路工程 (`tech.road_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共营造场 (`classical_public_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 修道院抄写室 (`app.monastic_scriptorium`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.monastic_scriptorium` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手稿文化 (`tech.manuscript_culture`)：该知识是此产业交汇自动生效的必要条件。
- 动物追踪 (`tech.animal_tracking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 修道院抄写室 (`monastic_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作棉花田 (`app.cotton_smallholding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cotton_smallholding` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 习惯佃作 (`tech.customary_tenancy`)：该知识是此产业交汇自动生效的必要条件。
- 野生棉铃采集 (`tech.wild_cotton_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作棉花田 (`cotton_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 药材商品园 (`app.medicinal_herb_estate`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.medicinal_herb_estate` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 习惯佃作 (`tech.customary_tenancy`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 药材商品园 (`medicinal_herb_estate`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 商品香料园 (`app.spice_managed_garden`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.spice_managed_garden` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 习惯佃作 (`tech.customary_tenancy`)：该知识是此产业交汇自动生效的必要条件。
- 野生香料采集 (`tech.wild_spice_collection`)：该知识是此产业交汇自动生效的必要条件。
- 遮阴香料园 (`tech.spice_shade_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商品香料园 (`spice_managed_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作马铃薯田 (`app.tenant_potato_field`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tenant_potato_field` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 佃作谷物 (`tech.tenant_cereal_farming`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作马铃薯田 (`tenant_potato_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作雨养玉米田 (`app.tenant_rainfed_maize_field`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tenant_rainfed_maize_field` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 佃作谷物 (`tech.tenant_cereal_farming`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作雨养玉米田 (`tenant_rainfed_maize_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作雨养小麦田 (`app.tenant_rainfed_wheat_field`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tenant_rainfed_wheat_field` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 佃作谷物 (`tech.tenant_cereal_farming`)：该知识是此产业交汇自动生效的必要条件。
- 野生谷穗采集 (`tech.wild_wheat_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作雨养小麦田 (`tenant_rainfed_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-4"></a>
## 帝国时代

共 29 项研究科技、17 项自动应用，科技研究成本范围 42000-70000；时代里程碑：帝国网络 (`tech.imperial_integration`)。

### 森林管理 (`tech.forest_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.forest_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 手工锯木 (`tech.timber_sawing`)：森林经营是为持续供应锯材而进行的轮伐与育林。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 8」（development.buildings.active\_8\_360d）

#### 效果摘要

解锁建筑：水力锯木场；解锁建筑：商营伐木场；农业部门产出 +8%；木材 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原木 (`logs`)；木材 (`lumber`)
- **建筑 / 生产方式：** 水力锯木场 (`method_lumber_plant_r4`)；商营伐木场 (`method_timber_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **水力锯木场**（`building`）：`building.method_lumber_plant_r4` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **商营伐木场**（`building`）：`building.method_timber_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **木材**（`good`）：`good.lumber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 木材：`country.resource.timber.managed_generation_factor`：+28%
  - 效果机制：森林管理提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：轮伐补植提高林木恢复。
  - 运行时消费者：`NativeEconomyRuntime::effective_managed_resource_generation`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 牧业网络 (`tech.pastoral_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoral_networks` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；生态 · 草原 (\`route.ecology.steppe\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 游牧放牧 (`tech.pastoralism`)：牧业网络把游牧放牧扩展为跨区域的转场体系。
- 庄园核算 (`tech.estate_accounting`)：庄园牧场需要以账簿管理畜群与草场。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 50」（development.employment.agriculture.50\_180d）

#### 效果摘要

解锁建筑：庄园牧场；「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 畜牧产品 (`livestock_products`)
- **建筑 / 生产方式：** 庄园牧场 (`manorial_pasture`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园牧场**（`building`）：`building.manorial_pasture` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **畜牧产品**（`good`）：`good.livestock_products` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：牧业网络提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 畜种改良 (`tech.livestock_breeding`)：畜种改良需要成规模、可追踪系谱的畜群。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 集约轮作 (`tech.intensive_crop_rotation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.intensive_crop_rotation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 轮作 (`tech.crop_rotation`)：该科技需要先掌握 「轮作」。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 50」（development.employment.extractive.50\_180d）

#### 效果摘要

解锁建筑：马铃薯庄园；解锁建筑：三圃制小农场；农业部门产出 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 混合谷物 (`grain`)；马铃薯 (`potatoes`)；蔬菜 (`vegetables`)
- **建筑 / 生产方式：** 马铃薯庄园 (`potato_estate`)；三圃制小农场 (`three_field_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **马铃薯庄园**（`building`）：`building.potato_estate` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **三圃制小农场**（`building`）：`building.three_field_smallholding` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+22%
  - 效果机制：集约轮作提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 庄园谷物经营 (`tech.manorial_cereal_farming`)：庄园普遍采用三圃制集约轮作。
- 农艺交换 (`tech.agronomic_exchange`)：农艺交换比较各地轮作与耕作经验。
- 作物移植适应 (`tech.crop_transplantation`)：该科技需要先掌握 「集约轮作」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 水力机械 (`tech.water_power`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.water_power` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；能源 · 水力 (\`route.energy.water\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 灌溉 (`tech.irrigation`)：水车最早用于提水灌溉，随后才转为磨坊与鼓风动力。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 50」（development.employment.manufacturing.50\_180d）

#### 效果摘要

商品「电力」产量 +20%；能源部门产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 电力：`country.output.good.electricity_factor`：+20%
- 能源部门产出：`country.output.energy_factor`：+20%
  - 效果机制：水力机械提高电力产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：水力机械提高能源部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 风力机械 (`tech.wind_power`)：风车沿用水磨的齿轮传动与磨盘机构（风车晚于水车出现）。
- 高炉冶炼 (`tech.blast_furnace`)：高炉持续高温依赖水力鼓风。
- 机械计时 (`tech.mechanical_timekeeping`)：机械钟沿用水力机械的齿轮系与擒纵思想。
- 矿井排水 (`tech.mine_drainage`)：早期排水泵由水轮驱动。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 风力机械 (`tech.wind_power`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wind_power` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；能源 · 风力 (\`route.energy.wind\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 水力机械 (`tech.water_power`)：风车沿用水磨的齿轮传动与磨盘机构（风车晚于水车出现）。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 1000」（development.output.agriculture.1000\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：风力机械提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 行业组织 (`tech.guild_organization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.guild_organization` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 全部路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 市场制度 (`tech.market_institutions`)：行会是城市手工业者在市场制度中的自我组织。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 1000」（development.output.manufacturing.1000\_360d）

#### 效果摘要

解锁建筑：蒸馏酒坊；解锁建筑：家具行会工坊；解锁建筑：行会陶窑；解锁建筑：羊毛行会作坊；解锁建筑：裁缝铺；解锁物资：家具；商品「衣物」产量 +8%；「布匹织造」生产家族建筑产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 酒饮 (`beverages`)；衣物 (`clothing`)；家具 (`furniture`)；陶器 (`pottery`)；羊毛 (`wool`)
- **建筑 / 生产方式：** 蒸馏酒坊 (`distillery`)；家具行会工坊 (`guild_hall`)；行会陶窑 (`method_pottery_kiln_r3`)；羊毛行会作坊 (`method_wool_shed_r3`)；裁缝铺 (`tailor_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸馏酒坊**（`building`）：`building.distillery` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **家具行会工坊**（`building`）：`building.guild_hall` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **行会陶窑**（`building`）：`building.method_pottery_kiln_r3` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **羊毛行会作坊**（`building`）：`building.method_wool_shed_r3` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **裁缝铺**（`building`）：`building.tailor_shop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **酒饮**（`good`）：`good.beverages` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **家具**（`good`）：`good.furniture` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **陶器**（`good`）：`good.pottery` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **羊毛**（`good`）：`good.wool` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+8%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+8%
  - 效果机制：行业组织提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：行业组织提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 特许大学 (`tech.chartered_universities`)：该科技需要先掌握 「行业组织」。
- 行会学徒制 (`tech.guild_apprenticeship`)：学徒制是行会传承技艺与限制入行的制度。
- 工业组织 (`tech.industrial_organization`)：工业组织由行会生产组织转变而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 高炉冶炼 (`tech.blast_furnace`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.blast_furnace` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 块炼铁 (`tech.iron_smelting`)：高炉是块炼炉在炉高与温度上的放大。
- 水力机械 (`tech.water_power`)：高炉持续高温依赖水力鼓风。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 2500」（development.population.2500\_180d）

#### 效果摘要

「炼钢」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；早期电气设备厂 (`basic_electrical_equipment_works`)；建筑构件厂 (`construction_components_plant`)；蒸汽钻井场 (`early_oil_well`)；电动机厂 (`electric_motor_plant`)；电气设备厂 (`electrical_equipment_plant`)；发动机厂 (`engines_plant`)；家用电器厂 (`household_appliances_plant`)；机械零件厂 (`machine_parts_plant`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)；蒸汽航运船坞 (`method_steam_shipping`)；铁路设备厂 (`railway_equipment_plant`)；核反应堆设备厂 (`reactor_component_works`)；蒸汽机工厂 (`steam_engine_works`)；电弧炉炼钢厂 (`steel_plant`)；钢制工具厂 (`tools_plant`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 炼钢：`country.output.family.steelmaking_factor`：+12%
  - 效果机制：高炉冶炼提高炼钢建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 焦炭冶炼 (`tech.coke_smelting`)：焦炭炼铁把高炉燃料由木炭改为焦炭（焦炭炼铁 ← 高炉、焦炭）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 坩埚钢 (`tech.crucible_steel`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crucible_steel` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`)；资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 块炼铁 (`tech.iron_smelting`)：坩埚钢以块炼铁为原料再行渗碳熔炼。
- 陶器容器体系 (`tech.pottery`)：耐高温的陶质坩埚来自成熟的陶器容器工艺。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_2\_count\_2\_180d）

#### 效果摘要

「炼钢」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 炼钢：`country.output.family.steelmaking_factor`：+12%
  - 效果机制：坩埚钢提高炼钢建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 火药配制 (`tech.gunpowder_formulation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gunpowder_formulation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 硝石 (\`route.resource.saltpeter\`) |
| 全部路线 | 资源 · 硝石 (\`route.resource.saltpeter\`)；资源 · 硫 (\`route.resource.sulfur\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 窑烧控制 (`tech.kiln_firing`)：硝石提纯与加热配料依赖窑炉控温经验。
- 木炭烧制 (`tech.charcoal_burning`)：木炭是火药三组分之一。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 50」（development.employment.manufacturing.50\_180d）

#### 效果摘要

解锁建筑：硝石矿；解锁建筑：硫矿；解锁物资：硝石；解锁物资：硫磺；可利用资源：硫矿；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 硝石 (`saltpeter`)；硫磺 (`sulfur`)
- **建筑 / 生产方式：** 硝石矿 (`saltpeter_collector`)；硫矿 (`sulfur_collector`)
- **自然资源：** 硫磺矿 (`sulfur`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 化学工场 (`industrial_chemicals_plant`)；自动化炸药厂 (`method_explosives_plant_r10`)；现代炸药厂 (`method_explosives_plant_r8`)；智能硝石矿 (`method_saltpeter_collector_r10`)；现代硝石矿 (`method_saltpeter_collector_r8`)；智能硫矿 (`method_sulfur_collector_r10`)；现代硫矿 (`method_sulfur_collector_r8`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)；合成橡胶厂 (`synthetic_rubber_plant`)

#### 结构化内容效果

- **硝石矿**（`building`）：`building.saltpeter_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **硫矿**（`building`）：`building.sulfur_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **硝石**（`good`）：`good.saltpeter` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硫磺**（`good`）：`good.sulfur` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硫矿**（`resource`）：`resource.sulfur` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：火药配制提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 火药武器 (`tech.gunpowder_weapons`)：火器以稳定配方的火药为推进剂。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 特许大学 (`tech.chartered_universities`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.chartered_universities` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 大学 (\`route.institution.university\`) |
| 全部路线 | 制度 · 大学 (\`route.institution.university\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 行业组织 (`tech.guild_organization`)：该科技需要先掌握 「行业组织」。
- 手稿文化 (`tech.manuscript_culture`)：该科技需要先掌握 「手稿文化」。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_2\_count\_2\_180d）

#### 效果摘要

解锁建筑：特许大学；解锁建筑：印刷学社；社会领域研究效率 +8%；「研究机构」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 特许大学 (`chartered_university`)；印刷学社 (`printing_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **特许大学**（`building`）：`building.chartered_university` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷学社**（`building`）：`building.printing_academy` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+8%
- 研究机构：`country.output.family.research_institution_factor`：+12%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：特许大学提高研究机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 庄园司法 (`tech.manorial_jurisdiction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manorial_jurisdiction` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 庄园核算 (`tech.estate_accounting`)：庄园司法以庄园核算所确立的领主—佃户账目为依据。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：庄园司法提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 农奴义务 (`tech.serf_obligations`)：农奴劳役由庄园司法强制执行。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 行会学徒制 (`tech.guild_apprenticeship`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.guild_apprenticeship` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 全部路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 行业组织 (`tech.guild_organization`)：学徒制是行会传承技艺与限制入行的制度。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 50」（development.employment.extractive.50\_180d）

#### 效果摘要

解锁建筑：细木家具工坊；解锁建筑：宫廷裁缝坊；解锁物资：华服；解锁物资：精美家具；商品「衣物」产量 +22%；「布匹织造」生产家族建筑产出 +22%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 华服 (`fine_clothing`)；精美家具 (`fine_furniture`)
- **建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；宫廷裁缝坊 (`court_tailor`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高级成衣厂 (`fine_clothing_plant`)；高级家具厂 (`fine_furniture_plant`)

#### 结构化内容效果

- **细木家具工坊**（`building`）：`building.cabinetmaker_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **宫廷裁缝坊**（`building`）：`building.court_tailor` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **华服**（`good`）：`good.fine_clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **精美家具**（`good`）：`good.fine_furniture` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+22%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+22%
  - 效果机制：行会学徒制提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：行会学徒制提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 手工工场 (`tech.manufactory_system`)：工场集中雇用出师的行会工匠，按工序分工。
- 工资契约 (`tech.wage_contracts`)：工资契约取代学徒期满后的行会雇佣关系。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 破布纸 (`tech.rag_paper_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rag_paper_making` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该科技需要先掌握 「植物纤维抄纸」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 8」（development.buildings.active\_8\_360d）

#### 效果摘要

解锁建筑：碎布造纸工坊；「造纸」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 碎布造纸工坊 (`rag_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **碎布造纸工坊**（`building`）：`building.rag_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 造纸：`country.output.family.paper_making_factor`：+12%
  - 效果机制：破布纸提高造纸建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 木版印刷 (`tech.woodblock_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.woodblock_printing` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 手稿文化 (`tech.manuscript_culture`)：该科技需要先掌握 「手稿文化」。
- 复合工具 (`tech.composite_tools`)：该科技需要先掌握 「复合工具」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 50」（development.employment.agriculture.50\_180d）

#### 效果摘要

解锁建筑：木版印刷坊；解锁物资：印刷品；全社会经济产出 +8%；作为必要支撑：印刷学社

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 木版印刷坊 (`woodblock_printing_house`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)；印刷学社 (`printing_academy`)

#### 结构化内容效果

- **木版印刷坊**（`building`）：`building.woodblock_printing_house` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：木版印刷提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 活字印刷 (`tech.movable_type_printing`)：活字印刷继承雕版的刷墨、覆纸与版面工艺（金属活字 ← 雕版印刷）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 活字印刷 (`tech.movable_type_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.movable_type_printing` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 陶器容器体系 (`tech.pottery`)：泥活字需要烧制稳定的陶字。
- 木版印刷 (`tech.woodblock_printing`)：活字印刷继承雕版的刷墨、覆纸与版面工艺（金属活字 ← 雕版印刷）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：活字印刷坊；全社会经济产出 +6%；作为必要支撑：木版印刷坊

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 活字印刷坊 (`movable_type_print_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **活字印刷坊**（`building`）：`building.movable_type_print_shop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：活字印刷提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 螺旋压印 (`tech.screw_press_printing`)：该科技需要先掌握 「活字印刷」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 磁针导航 (`tech.magnetic_navigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.magnetic_navigation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 河运 (`tech.river_transport`)：该科技需要先掌握 「河运」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 1000」（development.output.agriculture.1000\_360d）

#### 效果摘要

无

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 天文导航 (`tech.celestial_navigation`)：远离海岸时需要罗盘与天测共同定向。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 城市水务 (`tech.urban_waterworks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.urban_waterworks` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 砌体建筑 (`tech.masonry`)：该科技需要先掌握 「砌体建筑」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 1000」（development.output.manufacturing.1000\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：城市水务提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 经院研究法 (`tech.scholastic_method`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scholastic_method` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 手稿文化 (`tech.manuscript_culture`)：经院研究法建立在手稿抄传与注疏传统之上。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 2500」（development.population.2500\_180d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：经院研究法提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 实验科学 (`tech.experimental_science`)：实验科学由经院研究法的论证传统发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 农奴义务 (`tech.serf_obligations`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.serf_obligations` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 庄园司法 (`tech.manorial_jurisdiction`)：农奴劳役由庄园司法强制执行。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 8」（development.buildings.active\_8\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：农奴义务提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 庄园谷物经营 (`tech.manorial_cereal_farming`)：庄园谷物经营依赖农奴的周工劳役。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 庄园谷物经营 (`tech.manorial_cereal_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manorial_cereal_farming` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 农奴义务 (`tech.serf_obligations`)：庄园谷物经营依赖农奴的周工劳役。
- 集约轮作 (`tech.intensive_crop_rotation`)：庄园普遍采用三圃制集约轮作。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 50」（development.employment.agriculture.50\_180d）

#### 效果摘要

农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：庄园谷物经营提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 区域粮仓 (`tech.regional_granaries`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.regional_granaries` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 城市食物供应 (`tech.urban_food_supply`)：该科技需要先掌握 「城市食物供应」。
- 道路工程 (`tech.road_engineering`)：该科技需要先掌握 「道路工程」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 50」（development.employment.manufacturing.50\_180d）

#### 效果摘要

商品「加工主食」产量 +12%；「主粮加工」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 加工主食：`country.output.good.prepared_staples_factor`：+12%
- 主粮加工：`country.output.family.staple_preparation_factor`：+12%
  - 效果机制：区域粮仓减少储藏损耗，提高加工主食有效供给。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：区域粮仓提高主粮加工与仓储相关建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 煤矿平硐 (`tech.coal_adit_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_adit_mining` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地表煤采集 (`tech.surface_coal_collection`)：该科技需要先掌握 「地表煤采集」。
- 砌体建筑 (`tech.masonry`)：该科技需要先掌握 「砌体建筑」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 1000」（development.output.agriculture.1000\_360d）

#### 效果摘要

解锁建筑：煤层平硐；煤 -8%；采掘部门产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 煤层平硐 (`coal_adit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤层平硐**（`building`）：`building.coal_adit` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 煤：`country.resource.coal.use_factor`：+8%
- 采掘部门产出：`country.output.extractive_factor`：+20%
  - 效果机制：平硐提高煤层回收率。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：煤矿平硐提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 煤矿开采 (`tech.coal_mining`)：竖井煤矿是在平硐采煤之上向深处延伸。
- 矿井木支护 (`tech.mine_timbering`)：木支护首先用于加固平硐巷道。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 煤矿开采 (`tech.coal_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_mining` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 煤矿平硐 (`tech.coal_adit_mining`)：竖井煤矿是在平硐采煤之上向深处延伸。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

解锁建筑：煤矿；煤 -8%；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 煤矿 (`coal_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤矿**（`building`）：`building.coal_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 煤：`country.resource.coal.use_factor`：+8%
- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：系统采煤减少煤层损失。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：煤矿开采提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 焦炭冶炼 (`tech.coke_smelting`)：炼焦需要稳定供应的矿井煤。
- 工业采煤 (`tech.industrial_coal_mining`)：工业采煤是竖井煤矿的规模化。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 矿井木支护 (`tech.mine_timbering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mine_timbering` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 煤矿平硐 (`tech.coal_adit_mining`)：木支护首先用于加固平硐巷道。
- 手工锯木 (`tech.timber_sawing`)：支护需要成批锯制的立柱与横梁。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 1000」（development.output.manufacturing.1000\_360d）

#### 效果摘要

解锁建筑：浅层铜矿；解锁建筑：浅层铁矿；「铁矿采掘」生产家族建筑产出 +14%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铜矿石 (`copper_ore`)；铁矿石 (`iron_ore`)
- **建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)；浅层铁矿 (`early_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅层铜矿**（`building`）：`building.early_copper_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **浅层铁矿**（`building`）：`building.early_iron_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铜矿石**（`good`）：`good.copper_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铁矿石**（`good`）：`good.iron_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+14%
  - 效果机制：矿井木支护提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 矿井通风 (`tech.mine_ventilation`)：该科技需要先掌握 「矿井木支护」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 矿井通风 (`tech.mine_ventilation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mine_ventilation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 矿井木支护 (`tech.mine_timbering`)：该科技需要先掌握 「矿井木支护」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 2500」（development.population.2500\_180d）

#### 效果摘要

可利用资源：铅矿；可利用资源：锌矿；采掘部门产出 +14%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 铅矿 (`lead_ore`)；锌矿 (`zinc_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铅矿**（`resource`）：`resource.lead_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锌矿**（`resource`）：`resource.zinc_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+14%
  - 效果机制：矿井通风提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 深井采矿 (`tech.deep_mining`)：该科技需要先掌握 「矿井通风」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 庄园谷物核算 (`tech.estate_cereal_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_cereal_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 庄园核算 (`tech.estate_accounting`)：庄园谷物核算把粮食产量纳入庄园账簿。
- 分成租佃 (`tech.sharecropping`)：玉米与小麦庄园以分成租佃组织劳动。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_2\_count\_2\_180d）

#### 效果摘要

解锁建筑：玉米庄园；解锁建筑：佃作小麦庄园；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)；小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 玉米庄园 (`landed_estate`)；佃作小麦庄园 (`method_wheat_farm_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玉米庄园**（`building`）：`building.landed_estate` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **佃作小麦庄园**（`building`）：`building.method_wheat_farm_r3` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：庄园谷物核算提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 商业农庄 (`tech.commercial_estates`)：商业农庄由庄园谷物核算转向商品化经营。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 庄园水田核算 (`tech.estate_paddy_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_paddy_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 佃作水田 (`tech.tenant_paddy_management`)：庄园水田核算建立在佃作水田之上。
- 庄园核算 (`tech.estate_accounting`)：水田产量要纳入庄园账簿统一核算。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

解锁建筑：庄园水田；商品「稻米」产量 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 庄园水田 (`estate_paddy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园水田**（`building`）：`building.estate_paddy` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 稻米：`country.output.good.rice_grain_factor`：+28%
  - 效果机制：庄园水田核算提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 汇票与票据 (`tech.bills_of_exchange`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bills_of_exchange` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 交流 (\`route.trade.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 货币 (`tech.currency`)：汇票以统一铸币计价兑付。
- 市场制度 (`tech.market_institutions`)：票据在既有市场制度中流通与背书。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会贸易运输速度 +5%

#### 机会成本

占用社会研究预算，推迟庄园与行会路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会贸易运输速度：`country.trade.speed_factor`：+5%
  - 效果机制：远程结算不再需要押运现钱，商路周转加快（汇票与可转让票据 1200）。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 复式记账 (`tech.double_entry_bookkeeping`)：意大利银行家为汇兑往来发展出复式账簿（复式记账 1300）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 帝国网络 (`tech.imperial_integration`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.imperial_integration` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 70000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 11 项候选中的任意 4 项：
- 集约轮作 (`tech.intensive_crop_rotation`)
- 活字印刷 (`tech.movable_type_printing`)
- 经院研究法 (`tech.scholastic_method`)
- 行业组织 (`tech.guild_organization`)
- 森林管理 (`tech.forest_management`)
- 高炉冶炼 (`tech.blast_furnace`)
- 磁针导航 (`tech.magnetic_navigation`)
- 区域粮仓 (`tech.regional_granaries`)
- 水力机械 (`tech.water_power`)
- 木版印刷 (`tech.woodblock_printing`)
- 城市水务 (`tech.urban_waterworks`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 马铃薯庄园 (`app.potato_estate`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.potato_estate` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 集约轮作 (`tech.intensive_crop_rotation`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 马铃薯庄园 (`potato_estate`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 三圃制小农场 (`app.three_field_smallholding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.three_field_smallholding` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 集约轮作 (`tech.intensive_crop_rotation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。
- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 三圃制小农场 (`three_field_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸馏酒坊 (`app.distillery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.distillery` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行业组织 (`tech.guild_organization`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 发酵保存 (`tech.fermentation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸馏酒坊 (`distillery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家具行会工坊 (`app.guild_hall`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.guild_hall` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行业组织 (`tech.guild_organization`)：该知识是此产业交汇自动生效的必要条件。
- 手工锯木 (`tech.timber_sawing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家具行会工坊 (`guild_hall`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 行会陶窑 (`app.method_pottery_kiln_r3`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_pottery_kiln_r3` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行业组织 (`tech.guild_organization`)：该知识是此产业交汇自动生效的必要条件。
- 枯枝采集 (`tech.deadwood_collection`)：该知识是此产业交汇自动生效的必要条件。
- 土建筑 (`tech.earth_building`)：该知识是此产业交汇自动生效的必要条件。
- 手制陶器 (`tech.hand_pottery`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 羊毛行会作坊 (`app.method_wool_shed_r3`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wool_shed_r3` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行业组织 (`tech.guild_organization`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 毛用畜牧 (`tech.wool_husbandry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 羊毛行会作坊 (`method_wool_shed_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 裁缝铺 (`app.tailor_shop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tailor_shop` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行业组织 (`tech.guild_organization`)：该知识是此产业交汇自动生效的必要条件。
- 纤维捻制 (`tech.fiber_twisting`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 裁缝铺 (`tailor_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 木版印刷坊 (`app.woodblock_printing_house`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.woodblock_printing_house` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 木版印刷 (`tech.woodblock_printing`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。
- 活字印刷 (`tech.movable_type_printing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 木版印刷坊 (`woodblock_printing_house`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 活字印刷坊 (`app.movable_type_print_shop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.movable_type_print_shop` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 活字印刷 (`tech.movable_type_printing`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 活字印刷坊 (`movable_type_print_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 硝石矿 (`app.saltpeter_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.saltpeter_collector` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。
- 自然观察 (`tech.natural_observation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 硝石矿 (`saltpeter_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 印刷学社 (`app.printing_academy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.printing_academy` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 特许大学 (`tech.chartered_universities`)：该知识是此产业交汇自动生效的必要条件。
- 木版印刷 (`tech.woodblock_printing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 印刷学社 (`printing_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 细木家具工坊 (`app.cabinetmaker_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cabinetmaker_workshop` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行会学徒制 (`tech.guild_apprenticeship`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。
- 手工锯木 (`tech.timber_sawing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 宫廷裁缝坊 (`app.court_tailor`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.court_tailor` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 行会学徒制 (`tech.guild_apprenticeship`)：该知识是此产业交汇自动生效的必要条件。
- 狩猎 (`tech.hunting`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 宫廷裁缝坊 (`court_tailor`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 浅层铜矿 (`app.early_copper_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_copper_mine` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿井木支护 (`tech.mine_timbering`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜辨识 (`tech.natural_copper_identification`)：该知识是此产业交汇自动生效的必要条件。
- 铜矿井开采 (`tech.copper_mine_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 浅层铁矿 (`app.early_iron_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_iron_mine` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿井木支护 (`tech.mine_timbering`)：该知识是此产业交汇自动生效的必要条件。
- 铁矿辨识 (`tech.iron_ore_identification`)：该知识是此产业交汇自动生效的必要条件。
- 地表铁矿采集 (`tech.surface_iron_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅层铁矿 (`early_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玉米庄园 (`app.landed_estate`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.landed_estate` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 庄园谷物核算 (`tech.estate_cereal_management`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玉米庄园 (`landed_estate`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 佃作小麦庄园 (`app.method_wheat_farm_r3`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wheat_farm_r3` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 庄园谷物核算 (`tech.estate_cereal_management`)：该知识是此产业交汇自动生效的必要条件。
- 野生谷穗采集 (`tech.wild_wheat_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作小麦庄园 (`method_wheat_farm_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-5"></a>
## 探索时代

共 26 项研究科技、13 项自动应用，科技研究成本范围 96000-160000；时代里程碑：洲际网络 (`tech.global_exchange`)。

### 地图学 (`tech.cartography`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cartography` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：地图需要文字标注与抄绘传承。
- 度量衡 (`tech.weights_and_measures`)：按比例绘图依赖统一的长度度量与测量。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易价值 1000」（development.trade.value\_1000）

#### 效果摘要

无

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 远洋航海 (`tech.oceanic_navigation`)：远洋航行依赖航海图。
- 地产测绘 (`tech.property_cadastre`)：该科技需要先掌握 「地图学」。
- 地理信息系统 (`tech.geographic_information_systems`)：地理信息系统把地图学的空间表达数字化。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 天文导航 (`tech.celestial_navigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.celestial_navigation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 天文历法 (`tech.celestial_calendars`)：天文导航沿用天文历法的星位观测。
- 磁针导航 (`tech.magnetic_navigation`)：远离海岸时需要罗盘与天测共同定向。

#### 发现启发（仅用于揭示）

- 已发现信号「两类商品作物形成产出」（development.commodity\_crop\_variety\_2）

#### 效果摘要

无

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅海运输走廊**（`runtime`）：`NativeEconomyRuntime.water_capability` → `shallow_sea_corridor` `unlock` `1.0`；`runtime_consumed`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 远洋航海 (`tech.oceanic_navigation`)：远洋定位依赖天文导航。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 远洋航海 (`tech.oceanic_navigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oceanic_navigation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 地图学 (`tech.cartography`)：远洋航行依赖航海图。
- 天文导航 (`tech.celestial_navigation`)：远洋定位依赖天文导航。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 250」（development.employment.agriculture.250\_360d）

#### 效果摘要

解锁建筑：远洋造船厂；解锁物资：远洋船舶；「海上作业」生产家族建筑产出 +16%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 远洋船舶 (`oceanic_vessels`)
- **建筑 / 生产方式：** 远洋造船厂 (`oceanic_shipyard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

- **远海运输走廊**（`runtime`）：`NativeEconomyRuntime.water_capability` → `far_sea_corridor` `unlock` `1.0`；`runtime_consumed`
- **远洋造船厂**（`building`）：`building.oceanic_shipyard` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+16%
  - 效果机制：远洋航海提高海上作业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 远洋船舶设计 (`tech.oceanic_ship_design`)：该科技需要先掌握 「远洋航海」。
- 远洋补给 (`tech.oceanic_provisioning`)：远洋补给服务于长距离航行。
- 精密仪器 (`tech.precision_instruments`)：六分仪与航海钟为远洋定位而改进。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 远洋船舶设计 (`tech.oceanic_ship_design`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oceanic_ship_design` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 远洋航海 (`tech.oceanic_navigation`)：该科技需要先掌握 「远洋航海」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 250」（development.employment.knowledge.250\_360d）

#### 效果摘要

「海上作业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **深海运输走廊**（`runtime`）：`NativeEconomyRuntime.water_capability` → `deep_sea_corridor` `unlock` `1.0`；`runtime_consumed`

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+12%
  - 效果机制：远洋船舶设计提高海上作业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 海岸船厂 (`tech.coastal_shipyards`)：该科技需要先掌握 「远洋船舶设计」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 海岸船厂 (`tech.coastal_shipyards`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coastal_shipyards` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 远洋船舶设计 (`tech.oceanic_ship_design`)：该科技需要先掌握 「远洋船舶设计」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 55%」（development.satisfaction.55\_360d）

#### 效果摘要

「海上作业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+28%
  - 效果机制：海岸船厂提高海上作业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 螺旋压印 (`tech.screw_press_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.screw_press_printing` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 活字印刷 (`tech.movable_type_printing`)：该科技需要先掌握 「活字印刷」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 12500」（development.population.12500\_360d）

#### 效果摘要

解锁建筑：包装材料厂；解锁建筑：印刷厂；解锁物资：包装材料；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 包装材料 (`packaging`)；印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 包装材料厂 (`packaging_plant`)；印刷厂 (`printed_materials_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 面包厂 (`bread_plant`)

#### 结构化内容效果

- **包装材料厂**（`building`）：`building.packaging_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷厂**（`building`）：`building.printed_materials_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **包装材料**（`good`）：`good.packaging` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：螺旋压印提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 实验科学 (`tech.experimental_science`)：实验报告依靠印刷快速传播与复核。
- 机械印刷 (`tech.mechanized_printing`)：机械印刷由螺旋压印机发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 火药武器 (`tech.gunpowder_weapons`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gunpowder_weapons` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 硝石 (\`route.resource.saltpeter\`) |
| 全部路线 | 资源 · 硝石 (\`route.resource.saltpeter\`)；资源 · 硫 (\`route.resource.sulfur\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 火药配制 (`tech.gunpowder_formulation`)：火器以稳定配方的火药为推进剂。
- 铜锡配比与铸造 (`tech.bronze_casting`)：早期火炮以青铜铸造炮管。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 2 类」（development.trade.goods\_2）

#### 效果摘要

解锁建筑：炸药厂；解锁物资：炸药；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 炸药 (`explosives`)
- **建筑 / 生产方式：** 炸药厂 (`explosives_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铝土矿 (`bauxite_collector`)；深井盐矿 (`industrial_salt_mine`)；铅矿 (`lead_ore_collector`)；锰矿 (`manganese_ore_collector`)；自动化铝土矿 (`method_bauxite_collector_r9`)；现代炸药厂 (`method_explosives_plant_r8`)；自动化铅矿 (`method_lead_ore_collector_r9`)；智能锰矿 (`method_manganese_ore_collector_r10`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)；智能战略矿山 (`method_rare_earth_collector_r10`)；自动化锌矿 (`method_zinc_ore_collector_r9`)；磷矿 (`phosphate_rock_collector`)；战略矿山 (`rare_earth_collector`)；锌矿 (`zinc_ore_collector`)

#### 结构化内容效果

- **炸药厂**（`building`）：`building.explosives_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **炸药**（`good`）：`good.explosives` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：火药武器提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 深井采矿 (`tech.deep_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deep_mining` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 矿井通风 (`tech.mine_ventilation`)：该科技需要先掌握 「矿井通风」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 250」（development.employment.knowledge.250\_360d）

#### 效果摘要

铁矿石 -8%；采掘部门产出 +24%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 铁矿石：`country.resource.iron_ore.use_factor`：+8%
- 采掘部门产出：`country.output.extractive_factor`：+24%
  - 效果机制：深井开拓提高铁矿回采率。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：深井采矿提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 井筒开掘 (`tech.shaft_sinking`)：井筒开掘是深井采矿的竖向通道工程。
- 矿井排水 (`tech.mine_drainage`)：深井首先遇到地下水淹井问题。
- 地质勘探 (`tech.geological_prospecting`)：深井揭露的岩层剖面是地层学的直接材料。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 复式记账 (`tech.double_entry_bookkeeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.double_entry_bookkeeping` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 汇票与票据 (`tech.bills_of_exchange`)：意大利银行家为汇兑往来发展出复式账簿（复式记账 1300）。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 1 个」（development.trade.partners\_1）

#### 效果摘要

全社会生产投入 -2%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+2%
  - 效果机制：复式记账揭示跨行业库存、损耗与成本浪费。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 商业农庄 (`tech.commercial_estates`)：面向市场的农庄以复式账簿核算盈亏。
- 商业租佃 (`tech.commercial_tenancy`)：商业租佃以货币地租和账簿结算。
- 特许商社 (`tech.chartered_companies`)：股份商社需要复式账簿向股东核算（股份公司 ← 近代银行与保险）。
- 政治经济学 (`tech.political_economy`)：该科技需要先掌握 「复式记账」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 商业农庄 (`tech.commercial_estates`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commercial_estates` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 复式记账 (`tech.double_entry_bookkeeping`)：面向市场的农庄以复式账簿核算盈亏。
- 庄园谷物核算 (`tech.estate_cereal_management`)：商业农庄由庄园谷物核算转向商品化经营。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易量 100」（development.trade.quantity\_100）

#### 效果摘要

解锁建筑：药材种植园；国内贸易容量 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)
- **建筑 / 生产方式：** 药材种植园 (`medicinal_herbs_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药材种植园**（`building`）：`building.medicinal_herbs_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 商业网络 (`tech.mercantile_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mercantile_networks` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 市场制度 (`tech.market_institutions`)：商业网络连接各地市场。
- 货币 (`tech.currency`)：跨区域结算依赖通用货币。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易价值 1000」（development.trade.value\_1000）

#### 效果摘要

国内贸易容量 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 特许商社 (`tech.chartered_companies`)：特许商社经营既有的远程商业网络。
- 商品作物管理 (`tech.commodity_crop_management`)：商品作物面向远程市场出售。
- 手工工场 (`tech.manufactory_system`)：商人资本为工场垫付原料并包销产品（分散/集中手工工场）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械计时 (`tech.mechanical_timekeeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_timekeeping` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 水力机械 (`tech.water_power`)：机械钟沿用水力机械的齿轮系与擒纵思想。
- 天文历法 (`tech.celestial_calendars`)：计时需要以天文历法校准。

#### 发现启发（仅用于揭示）

- 已发现信号「两类商品作物形成产出」（development.commodity\_crop\_variety\_2）

#### 效果摘要

工程领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 工程领域研究效率：`country.research.engineering_efficiency`：+8%
  - 效果机制：计时、测量与统计提高工程研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 精密工程 (`tech.precision_engineering`)：该科技需要先掌握 「机械计时」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 井筒开掘 (`tech.shaft_sinking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.shaft_sinking` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 深井采矿 (`tech.deep_mining`)：井筒开掘是深井采矿的竖向通道工程。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 250」（development.employment.agriculture.250\_360d）

#### 效果摘要

解锁建筑：金矿；解锁建筑：银矿；「金矿采掘」生产家族建筑产出 +12%；「银矿采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黄金 (`gold`)；白银 (`silver`)
- **建筑 / 生产方式：** 金矿 (`gold_mine`)；银矿 (`silver_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **金矿**（`building`）：`building.gold_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **银矿**（`building`）：`building.silver_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **黄金**（`good`）：`good.gold` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **白银**（`good`）：`good.silver` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 金矿采掘：`country.output.family.gold_extraction_factor`：+12%
- 银矿采掘：`country.output.family.silver_extraction_factor`：+12%
  - 效果机制：井筒开掘提高金矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：井筒开掘提高银矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 矿井排水 (`tech.mine_drainage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mine_drainage` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 深井采矿 (`tech.deep_mining`)：深井首先遇到地下水淹井问题。
- 水力机械 (`tech.water_power`)：早期排水泵由水轮驱动。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 55%」（development.satisfaction.55\_360d）

#### 效果摘要

解锁建筑：锡矿；「制盐」生产家族建筑产出 +16%；「锡矿采掘」生产家族建筑产出 +16%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锡矿石 (`tin_ore`)
- **建筑 / 生产方式：** 锡矿 (`tin_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **锡矿**（`building`）：`building.tin_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **锡矿石**（`good`）：`good.tin_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制盐：`country.output.family.salt_extraction_factor`：+16%
- 锡矿采掘：`country.output.family.tin_extraction_factor`：+16%
  - 效果机制：矿井排水提高制盐建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：矿井排水提高锡矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 大气式蒸汽机 (`tech.atmospheric_engine`)：该科技需要先掌握 「矿井排水」。
- 蒸汽抽水 (`tech.steam_pumping`)：蒸汽抽水替代水轮承担矿井排水。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 商业租佃 (`tech.commercial_tenancy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commercial_tenancy` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 复式记账 (`tech.double_entry_bookkeeping`)：商业租佃以货币地租和账簿结算。
- 习惯佃作 (`tech.customary_tenancy`)：商业租佃由习惯佃作契约化而来。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 12500」（development.population.12500\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：商业租佃提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 契约劳工制度 (`tech.indentured_contracts`)：契约劳工沿用商业租佃的书面契约形式。
- 长期租约 (`tech.long_term_leases`)：长期租约是商业租佃在期限与改良投资上的延伸。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 特许商社 (`tech.chartered_companies`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.chartered_companies` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 商业网络 (`tech.mercantile_networks`)：特许商社经营既有的远程商业网络。
- 复式记账 (`tech.double_entry_bookkeeping`)：股份商社需要复式账簿向股东核算（股份公司 ← 近代银行与保险）。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 2 类」（development.trade.goods\_2）

#### 效果摘要

国内贸易容量 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 保险与精算 (`tech.actuarial_insurance`)：海运保险最早为特许商社的远洋货物承保。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 商品作物管理 (`tech.commodity_crop_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commodity_crop_management` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 棉花园圃 (`tech.cotton_gardening`)：棉花是最早规模化的商品作物之一。
- 商业网络 (`tech.mercantile_networks`)：商品作物面向远程市场出售。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 1 个」（development.trade.partners\_1）

#### 效果摘要

解锁建筑：橡胶种植园；农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 天然乳胶 (`latex`)
- **建筑 / 生产方式：** 橡胶种植园 (`rubber_tree_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **橡胶种植园**（`building`）：`building.rubber_tree_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：商品作物管理提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 契约劳工制度 (`tech.indentured_contracts`)：契约劳工主要服务于商品作物种植。
- 种植园庄园管理 (`tech.estate_plantation_management`)：该科技需要先掌握 「商品作物管理」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 远洋补给 (`tech.oceanic_provisioning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oceanic_provisioning` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 远洋航海 (`tech.oceanic_navigation`)：远洋补给服务于长距离航行。
- 盐渍保存 (`tech.salt_preservation`)：远洋补给以盐渍食物为主要储备。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：远洋渔场；「海上作业」生产家族建筑产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 远洋渔场 (`method_marine_fish_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **远洋渔场**（`building`）：`building.method_marine_fish_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 海上作业：`country.output.family.maritime_operations_factor`：+25%
  - 效果机制：远洋补给提高海上作业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 跨区域植物学 (`tech.interregional_botany`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.interregional_botany` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`)；制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然哲学 (`tech.natural_philosophy`)：该科技需要先掌握 「自然哲学」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 250」（development.employment.agriculture.250\_360d）

#### 效果摘要

农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 农艺交换 (`tech.agronomic_exchange`)：跨区域植物学提供了作物与农艺的比较对象。
- 作物驯化移植 (`tech.crop_acclimatization`)：该科技需要先掌握 「跨区域植物学」。
- 科学分类 (`tech.scientific_classification`)：林奈分类建立在跨区域植物采集与比较之上。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 农艺交换 (`tech.agronomic_exchange`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agronomic_exchange` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 集约轮作 (`tech.intensive_crop_rotation`)：农艺交换比较各地轮作与耕作经验。
- 跨区域植物学 (`tech.interregional_botany`)：跨区域植物学提供了作物与农艺的比较对象。

#### 发现启发（仅用于揭示）

- 已发现信号「两类商品作物形成产出」（development.commodity\_crop\_variety\_2）

#### 效果摘要

农业部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+12%
  - 效果机制：农艺交换提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 农业改良 (`tech.agricultural_improvement`)：该科技需要先掌握 「农艺交换」。
- 土壤实验 (`tech.soil_experimentation`)：土壤实验比较不同农艺的产量差异。
- 畜种改良 (`tech.livestock_breeding`)：选育引入了跨区域交换的优良畜种与经验。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 作物移植适应 (`tech.crop_transplantation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_transplantation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 集约轮作 (`tech.intensive_crop_rotation`)：该科技需要先掌握 「集约轮作」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 250」（development.employment.knowledge.250\_360d）

#### 效果摘要

农业部门产出 +8%；农业领域研究效率 +8%；种植园生产·寒冷损失 -10%；种植园生产·热害损失 -10%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
- 种植园生产·寒冷损失：`country.climate.profile.plantation_crop.cold_stress_loss_factor`：+10%
- 种植园生产·热害损失：`country.climate.profile.plantation_crop.heat_stress_loss_factor`：+10%
  - 效果机制：作物移植适应提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：作物移植适应降低种植园生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：作物移植适应降低种植园生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 作物驯化移植 (`tech.crop_acclimatization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_acclimatization` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 跨区域植物学 (`tech.interregional_botany`)：该科技需要先掌握 「跨区域植物学」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 55%」（development.satisfaction.55\_360d）

#### 效果摘要

可利用资源：种植园承载力；农业领域研究效率 +22%；旱作生产·旱灾损失 -8%；旱作生产·寒冷损失 -8%；旱作生产·热害损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+22%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+8%
- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+8%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：作物驯化移植降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：作物驯化移植降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：作物驯化移植降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 契约劳工制度 (`tech.indentured_contracts`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.indentured_contracts` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 商业租佃 (`tech.commercial_tenancy`)：契约劳工沿用商业租佃的书面契约形式。
- 商品作物管理 (`tech.commodity_crop_management`)：契约劳工主要服务于商品作物种植。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 2 类」（development.trade.goods\_2）

#### 效果摘要

解锁建筑：亚麻庄园；社会领域研究效率 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)
- **建筑 / 生产方式：** 亚麻庄园 (`method_flax_collector_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **亚麻庄园**（`building`）：`building.method_flax_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+20%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 种植园庄园管理 (`tech.estate_plantation_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_plantation_management` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 商品作物管理 (`tech.commodity_crop_management`)：该科技需要先掌握 「商品作物管理」。

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已发现信号「两类商品作物形成产出」（development.commodity\_crop\_variety\_2）
  - 已发现信号「商品作物设施稳定经营」（development.commodity\_crop\_facilities\_4\_180d）

#### 效果摘要

解锁建筑：棉花农场；解锁建筑：商业香料种植园；解锁建筑：香料种植园；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 籽棉 (`seed_cotton`)；香料 (`spices`)
- **建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；商业香料种植园 (`spice_commercial_plantation`)；香料种植园 (`spice_plants_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **棉花农场**（`building`）：`building.cotton_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **商业香料种植园**（`building`）：`building.spice_commercial_plantation` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **香料种植园**（`building`）：`building.spice_plants_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：种植园庄园管理提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 手工工场 (`tech.manufactory_system`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manufactory_system` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 全部路线 | 制度 · 行会 (\`route.institution.guild\`)；工艺 · 工厂 (\`route.craft.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 行会学徒制 (`tech.guild_apprenticeship`)：工场集中雇用出师的行会工匠，按工序分工。
- 商业网络 (`tech.mercantile_networks`)：商人资本为工场垫付原料并包销产品（分散/集中手工工场）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：玻璃器皿工场；解锁建筑：皮革制品工场；解锁建筑：金属家用器皿工场

#### 机会成本

占用社会研究预算，工场需要稳定的原料供应与商人资本。

#### 内容解锁

- **物资：** 玻璃器皿 (`glassware`)；皮革制品 (`leather_goods`)；金属家用器皿 (`metal_housewares`)
- **建筑 / 生产方式：** 玻璃器皿工场 (`glassware_manufactory`)；皮革制品工场 (`leather_goods_manufactory`)；金属家用器皿工场 (`metal_housewares_manufactory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玻璃器皿工场**（`building`）：`building.glassware_manufactory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品工场**（`building`）：`building.leather_goods_manufactory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿工场**（`building`）：`building.metal_housewares_manufactory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿**（`good`）：`good.glassware` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品**（`good`）：`good.leather_goods` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿**（`good`）：`good.metal_housewares` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 洲际网络 (`tech.global_exchange`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.global_exchange` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 160000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | branch |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 12 项候选中的任意 5 项：
- 农艺交换 (`tech.agronomic_exchange`)
- 机械计时 (`tech.mechanical_timekeeping`)
- 地图学 (`tech.cartography`)
- 复式记账 (`tech.double_entry_bookkeeping`)
- 作物驯化移植 (`tech.crop_acclimatization`)
- 远洋船舶设计 (`tech.oceanic_ship_design`)
- 跨区域植物学 (`tech.interregional_botany`)
- 特许商社 (`tech.chartered_companies`)
- 远洋航海 (`tech.oceanic_navigation`)
- 海岸船厂 (`tech.coastal_shipyards`)
- 商业农庄 (`tech.commercial_estates`)
- 商品作物管理 (`tech.commodity_crop_management`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 远洋造船厂 (`app.oceanic_shipyard`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.oceanic_shipyard` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 远洋航海 (`tech.oceanic_navigation`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。
- 手工锯木 (`tech.timber_sawing`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 远洋造船厂 (`oceanic_shipyard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 包装材料厂 (`app.packaging_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.packaging_plant` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 螺旋压印 (`tech.screw_press_printing`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 包装材料厂 (`packaging_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 印刷厂 (`app.printed_materials_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.printed_materials_plant` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 螺旋压印 (`tech.screw_press_printing`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 印刷厂 (`printed_materials_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 药材种植园 (`app.medicinal_herbs_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.medicinal_herbs_collector` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 商业农庄 (`tech.commercial_estates`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 药材种植园 (`medicinal_herbs_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玻璃器皿工场 (`app.glassware_manufactory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.glassware_manufactory` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手工工场 (`tech.manufactory_system`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玻璃器皿工场 (`glassware_manufactory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 皮革制品工场 (`app.leather_goods_manufactory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.leather_goods_manufactory` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手工工场 (`tech.manufactory_system`)：该知识是此产业交汇自动生效的必要条件。
- 皮革鞣制 (`tech.hide_tanning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 皮革制品工场 (`leather_goods_manufactory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 金属家用器皿工场 (`app.metal_housewares_manufactory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.metal_housewares_manufactory` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 手工工场 (`tech.manufactory_system`)：该知识是此产业交汇自动生效的必要条件。
- 块炼铁 (`tech.iron_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金属家用器皿工场 (`metal_housewares_manufactory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 金矿 (`app.gold_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.gold_mine` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 井筒开掘 (`tech.shaft_sinking`)：该知识是此产业交汇自动生效的必要条件。
- 粗陶淘金 (`tech.gold_panning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金矿 (`gold_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 银矿 (`app.silver_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.silver_mine` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 井筒开掘 (`tech.shaft_sinking`)：该知识是此产业交汇自动生效的必要条件。
- 地表银矿拣采 (`tech.surface_silver_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 银矿 (`silver_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 锡矿 (`app.tin_ore_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tin_ore_collector` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿井排水 (`tech.mine_drainage`)：该知识是此产业交汇自动生效的必要条件。
- 锡矿辨识 (`tech.tin_identification`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 锡矿 (`tin_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 棉花农场 (`app.cotton_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cotton_collector` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 种植园庄园管理 (`tech.estate_plantation_management`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 棉花农场 (`cotton_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 远洋渔场 (`app.method_marine_fish_collector_r4`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_marine_fish_collector_r4` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 远洋补给 (`tech.oceanic_provisioning`)：该知识是此产业交汇自动生效的必要条件。
- 潮间带采集 (`tech.coastal_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 远洋渔场 (`method_marine_fish_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 亚麻庄园 (`app.method_flax_collector_r3`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_flax_collector_r3` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 契约劳工制度 (`tech.indentured_contracts`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 亚麻庄园 (`method_flax_collector_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-6"></a>
## 启蒙时代

共 27 项研究科技、10 项自动应用，科技研究成本范围 216000-360000；时代里程碑：启蒙制度 (`tech.enlightenment_institutions`)。

### 科学分类 (`tech.scientific_classification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scientific_classification` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 跨区域植物学 (`tech.interregional_botany`)：林奈分类建立在跨区域植物采集与比较之上。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 1000」（development.output.knowledge.1000\_360d）

#### 效果摘要

农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 系统育种 (`tech.crop_breeding`)：按性状系统选育需要物种与品种分类。
- 煤层地质 (`tech.coal_geology`)：按化石与岩性分类地层（威廉·史密斯 1815 年地层图）是识别含煤层位的方法基础。
- 微生物学 (`tech.microbiology`)：微生物学把分类方法延伸到显微镜下的生物。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 政治经济学 (`tech.political_economy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.political_economy` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 复式记账 (`tech.double_entry_bookkeeping`)：该科技需要先掌握 「复式记账」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

社会领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+8%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 长期租约 (`tech.long_term_leases`)：长期租约鼓励承租人改良土地的经济论证。
- 工资契约 (`tech.wage_contracts`)：政治经济学把劳动作为按价格交易的生产要素。
- 合作社组织 (`tech.cooperative_association`)：合作社以互助经营回应市场经济中的小生产者处境。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 长期租约 (`tech.long_term_leases`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.long_term_leases` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 商业租佃 (`tech.commercial_tenancy`)：长期租约是商业租佃在期限与改良投资上的延伸。
- 政治经济学 (`tech.political_economy`)：长期租约鼓励承租人改良土地的经济论证。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：改良亚麻庄园；全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)
- **建筑 / 生产方式：** 改良亚麻庄园 (`method_flax_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良亚麻庄园**（`building`）：`building.method_flax_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：长期租约提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 农业改良 (`tech.agricultural_improvement`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agricultural_improvement` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 农艺交换 (`tech.agronomic_exchange`)：该科技需要先掌握 「农艺交换」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

解锁建筑：改良小农场；解锁建筑：改良轮作马铃薯庄园；农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 混合谷物 (`grain`)；马铃薯 (`potatoes`)；蔬菜 (`vegetables`)
- **建筑 / 生产方式：** 改良小农场 (`improved_smallholding`)；改良轮作马铃薯庄园 (`method_potato_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良小农场**（`building`）：`building.improved_smallholding` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **改良轮作马铃薯庄园**（`building`）：`building.method_potato_farm_r5` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：农业改良提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 系统育种 (`tech.crop_breeding`)：系统育种是农业改良运动的核心手段。
- 农业合作社 (`tech.agricultural_cooperatives`)：合作社集中推广改良农法与共用设施。
- 机械化农业 (`tech.mechanized_agriculture`)：机械化农业服务于改良后的规模化农场。
- 现代畜牧 (`tech.modern_husbandry`)：该科技需要先掌握 「农业改良」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 精密工程 (`tech.precision_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_engineering` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 机械计时 (`tech.mechanical_timekeeping`)：该科技需要先掌握 「机械计时」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 16」（development.buildings.active\_16\_360d）

#### 效果摘要

解锁建筑：精密工具工坊；解锁物资：精密工具；全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 精密工具 (`precision_tools`)
- **建筑 / 生产方式：** 精密工具工坊 (`precision_tool_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **精密工具工坊**（`building`）：`building.precision_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精密工具**（`good`）：`good.precision_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：精密工程提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 标准化 (`tech.standardization`)：工业标准化以精密加工能达到的公差为基础（惠氏螺纹 ← 全金属螺纹车床）。
- 精密仪器 (`tech.precision_instruments`)：精密仪器需要精密加工的刻度与齿轮。
- 蒸汽密封 (`tech.steam_sealing`)：汽缸镗削与活塞配合依赖精密工程。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 实验科学 (`tech.experimental_science`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.experimental_science` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 经院研究法 (`tech.scholastic_method`)：实验科学由经院研究法的论证传统发展而来。
- 螺旋压印 (`tech.screw_press_printing`)：实验报告依靠印刷快速传播与复核。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 250」（development.employment.manufacturing.250\_360d）

#### 效果摘要

全社会经济产出 +6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：实验科学提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 概率与统计 (`tech.probability_statistics`)：该科技需要先掌握 「实验科学」。
- 公共卫生 (`tech.public_health`)：疫情调查与死亡统计依靠实验与观察方法。
- 学术社团 (`tech.learned_societies`)：学术社团以交流与复核实验为核心活动。
- 土壤实验 (`tech.soil_experimentation`)：对照试验来自实验科学方法。
- 罐藏 (`tech.canning`)：阿佩尔的加热密封法来自反复实验（罐头食品 1810）。
- 热力学 (`tech.thermodynamics`)：热力学定律来自量热与气体实验。
- 工业化学 (`tech.industrial_chemistry`)：该科技需要先掌握 「实验科学」。
- 微生物学 (`tech.microbiology`)：巴斯德的曲颈瓶实验否定了自然发生说（病菌学说 1861）。
- 电磁感应 (`tech.electromagnetic_induction`)：该科技需要先掌握 「实验科学」。
- 工业研究 (`tech.industrial_research`)：该科技需要先掌握 「实验科学」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 概率与统计 (`tech.probability_statistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.probability_statistics` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：该科技需要先掌握 「实验科学」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 55%」（development.satisfaction.55\_360d）

#### 效果摘要

工程领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 工程领域研究效率：`country.research.engineering_efficiency`：+8%
  - 效果机制：计时、测量与统计提高工程研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 保险与精算 (`tech.actuarial_insurance`)：精算以概率与死亡率统计定价风险（保险精算 1762）。
- 工业统计 (`tech.industrial_statistics`)：工业统计应用概率与统计方法。
- 数值天气预报 (`tech.numerical_weather_prediction`)：观测资料同化与预报检验依赖统计方法。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 标准化 (`tech.standardization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.standardization` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 精密工程 (`tech.precision_engineering`)：工业标准化以精密加工能达到的公差为基础（惠氏螺纹 ← 全金属螺纹车床）。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 250」（development.employment.knowledge.250\_360d）

#### 效果摘要

全社会生产投入 -4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+4%
  - 效果机制：统一规格减少返工和材料浪费。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 机械工坊 (`tech.mechanical_workshops`)：该科技需要先掌握 「标准化」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 公共卫生 (`tech.public_health`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_health` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.public\_health |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 城市卫生 (`tech.urban_sanitation`)：公共卫生由城市排污与供水治理发展而来。
- 实验科学 (`tech.experimental_science`)：疫情调查与死亡统计依靠实验与观察方法。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 1000」（development.output.knowledge.1000\_360d）

#### 效果摘要

全社会经济产出 +4%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：公共卫生提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 现代医学 (`tech.modern_medicine`)：现代医学在公共卫生的疫病调查基础上发展。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 水利工程 (`tech.hydraulic_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hydraulic_engineering` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 气候 · 洪水 (\`route.climate.flood\`) |
| 全部路线 | 气候 · 洪水 (\`route.climate.flood\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 运河工程 (`tech.canal_engineering`)：该科技需要先掌握 「运河工程」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：水泥厂；解锁物资：水泥；全社会经济产出 +8%；旱灾损失 -10%；洪灾损失 -10%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 水泥 (`cement`)
- **建筑 / 生产方式：** 水泥厂 (`cement_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化水泥厂 (`method_cement_plant_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)

#### 结构化内容效果

- **水泥厂**（`building`）：`building.cement_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **水泥**（`good`）：`good.cement` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
- 旱灾损失：`country.climate.drought_loss_factor`：+10%
- 洪灾损失：`country.climate.flood_loss_factor`：+10%
  - 效果机制：水利工程提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：水利工程降低全国气候型生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：水利工程降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 钢筋混凝土 (`tech.reinforced_concrete`)：钢筋混凝土以水硬性水泥为胶结料（钢筋混凝土 1867 ← 波特兰水泥）。
- 精准灌溉 (`tech.precision_irrigation`)：精准灌溉沿用水利工程的输配水系统。

#### 主题路线后继

无

#### 跨领域应用

- 发电机 (`tech.electric_generation`)：该知识参与形成 「发电机」。
- 精准灌溉 (`tech.precision_irrigation`)：该知识参与形成 「精准灌溉」。

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 机械工坊 (`tech.mechanical_workshops`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_workshops` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 标准化 (`tech.standardization`)：该科技需要先掌握 「标准化」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

解锁建筑：精梳羊毛作坊；「布匹织造」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 羊毛 (`wool`)
- **建筑 / 生产方式：** 精梳羊毛作坊 (`method_wool_shed_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **精梳羊毛作坊**（`building`）：`building.method_wool_shed_r5` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **羊毛**（`good`）：`good.wool` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
  - 效果机制：机械工坊提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业组织 (`tech.industrial_organization`)：机械工坊把工序集中到同一厂房。
- 纺织机械 (`tech.textile_machinery`)：纺纱机与织机的齿轮、锭子由机械工坊制造。
- 机床 (`tech.machine_tools`)：机床由机械工坊的车削与镗削工具发展而来（全金属螺纹车床 1800）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地质勘探 (`tech.geological_prospecting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.geological_prospecting` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 自然哲学 (`tech.natural_philosophy`)：地质勘探需要自然哲学的成因解释。
- 深井采矿 (`tech.deep_mining`)：深井揭露的岩层剖面是地层学的直接材料。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 16」（development.buildings.active\_16\_360d）

#### 效果摘要

解锁建筑：硅砂矿；采掘部门产出 +18%；作为必要支撑：铅矿

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 硅砂 (`silica_sand`)
- **建筑 / 生产方式：** 硅砂矿 (`silica_sand_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铅矿 (`lead_ore_collector`)

#### 结构化内容效果

- **硅砂矿**（`building`）：`building.silica_sand_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **硅砂**（`good`）：`good.silica_sand` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+18%
  - 效果机制：地质勘探提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 石油开采 (`tech.petroleum_extraction`)：找油依赖地质勘探。
- 深层地球物理 (`tech.deep_geophysics`)：深层地球物理延伸地质勘探的地下探测。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 大气式蒸汽机 (`tech.atmospheric_engine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.atmospheric_engine` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 矿井排水 (`tech.mine_drainage`)：该科技需要先掌握 「矿井排水」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 250」（development.employment.manufacturing.250\_360d）

#### 效果摘要

解锁建筑：大气式蒸汽机工坊；解锁物资：蒸汽机；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 大气式蒸汽机工坊 (`atmospheric_engine_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **大气式蒸汽机工坊**（`building`）：`building.atmospheric_engine_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：大气式蒸汽机提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 蒸汽密封 (`tech.steam_sealing`)：蒸汽密封要解决大气式蒸汽机汽缸漏气问题。
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力由大气式蒸汽机改进而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 学术社团 (`tech.learned_societies`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.learned_societies` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`)；制度 · 印刷 (\`route.institution.printing\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：学术社团以交流与复核实验为核心活动。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

解锁建筑：博学学会；农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 博学学会 (`learned_society`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **博学学会**（`building`）：`building.learned_society` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

无

#### 主题路线后继

- 科学分类 (`tech.scientific_classification`)：该知识继续发展为 「科学分类」。

#### 跨领域应用

- 实验科学 (`tech.experimental_science`)：该知识参与形成 「实验科学」。
- 工业研究 (`tech.industrial_research`)：该知识参与形成 「工业研究」。

#### 作为候选参与的里程碑

无

### 土壤实验 (`tech.soil_experimentation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.soil_experimentation` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 农艺交换 (`tech.agronomic_exchange`)：土壤实验比较不同农艺的产量差异。
- 实验科学 (`tech.experimental_science`)：对照试验来自实验科学方法。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 55%」（development.satisfaction.55\_360d）

#### 效果摘要

可利用资源：磷矿石；农业领域研究效率 +8%；旱作生产·旱灾损失 -6%；水田生产·洪灾损失 -6%；采掘部门产出 +14%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 磷矿石 (`phosphate_rock`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化磷矿 (`method_phosphate_rock_collector_r9`)

#### 结构化内容效果

- **磷矿石**（`resource`）：`resource.phosphate_rock` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+6%
- 水田生产·洪灾损失：`country.climate.profile.paddy_crop.flood_loss_factor`：+6%
- 采掘部门产出：`country.output.extractive_factor`：+14%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：土壤实验降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：土壤实验降低水田生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：土壤实验提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 肥料加工 (`tech.fertilizer_processing`)：该科技需要先掌握 「土壤实验」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 畜种改良 (`tech.livestock_breeding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.livestock_breeding` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 牧业网络 (`tech.pastoral_networks`)：畜种改良需要成规模、可追踪系谱的畜群。
- 农艺交换 (`tech.agronomic_exchange`)：选育引入了跨区域交换的优良畜种与经验。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 250」（development.employment.knowledge.250\_360d）

#### 效果摘要

牧业生产·寒冷损失 -10%；牧业生产·热害损失 -10%；「畜牧业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 牧业生产·寒冷损失：`country.climate.profile.pasture_livestock.cold_stress_loss_factor`：+10%
- 牧业生产·热害损失：`country.climate.profile.pasture_livestock.heat_stress_loss_factor`：+10%
- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%
  - 效果机制：畜种改良降低牧业生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：畜种改良降低牧业生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：畜种改良提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 现代畜牧 (`tech.modern_husbandry`)：该科技需要先掌握 「畜种改良」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工资契约 (`tech.wage_contracts`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wage_contracts` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 行会学徒制 (`tech.guild_apprenticeship`)：工资契约取代学徒期满后的行会雇佣关系。
- 政治经济学 (`tech.political_economy`)：政治经济学把劳动作为按价格交易的生产要素。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 1000」（development.output.knowledge.1000\_360d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：工资契约提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 劳工组织 (`tech.labor_organization`)：工会以集体谈判工资契约为核心诉求。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 系统育种 (`tech.crop_breeding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_breeding` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 农业改良 (`tech.agricultural_improvement`)：系统育种是农业改良运动的核心手段。
- 科学分类 (`tech.scientific_classification`)：按性状系统选育需要物种与品种分类。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：改良轮作小麦庄园；旱作生产·寒冷损失 -10%；旱作生产·热害损失 -10%；商品「小麦」产量 +12%；商品「稻米」产量 +12%；商品「玉米」产量 +12%；商品「马铃薯」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 改良轮作小麦庄园 (`method_wheat_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良轮作小麦庄园**（`building`）：`building.method_wheat_farm_r5` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+10%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+10%
- 小麦：`country.output.good.wheat_grain_factor`：+12%
- 稻米：`country.output.good.rice_grain_factor`：+12%
- 玉米：`country.output.good.corn_grain_factor`：+12%
- 马铃薯：`country.output.good.potatoes_factor`：+12%
  - 效果机制：系统育种降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：系统育种降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：系统育种提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：系统育种提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：系统育种提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：系统育种提高马铃薯产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

- 遗传学 (`tech.genetics`)：孟德尔定律的再发现直接服务于系统育种（1900）。
- 工业农学 (`tech.industrial_agronomy`)：高产品种来自系统育种（绿色革命 ← 矮秆品种、合成氨）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 合作社组织 (`tech.cooperative_association`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cooperative_association` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 政治经济学 (`tech.political_economy`)：合作社以互助经营回应市场经济中的小生产者处境。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 3」（development.settlement.tier\_3\_360d）

#### 效果摘要

制造部门产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+4%
  - 效果机制：合作社组织提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 农业合作社 (`tech.agricultural_cooperatives`)：农业合作社是合作社组织在农村的应用。
- 工人合作工场 (`tech.worker_cooperatives`)：工人合作工场沿用合作社的共有与分配规则。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 农业合作社 (`tech.agricultural_cooperatives`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agricultural_cooperatives` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 合作社组织 (`tech.cooperative_association`)：农业合作社是合作社组织在农村的应用。
- 农业改良 (`tech.agricultural_improvement`)：合作社集中推广改良农法与共用设施。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 16」（development.buildings.active\_16\_360d）

#### 效果摘要

解锁建筑：精耕稻庄；农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 精耕稻庄 (`method_rice_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **精耕稻庄**（`building`）：`building.method_rice_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：农业合作社提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 精密仪器 (`tech.precision_instruments`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_instruments` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 远洋航海 (`tech.oceanic_navigation`)：六分仪与航海钟为远洋定位而改进。
- 精密工程 (`tech.precision_engineering`)：精密仪器需要精密加工的刻度与齿轮。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 250」（development.employment.manufacturing.250\_360d）

#### 效果摘要

工程领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 工程领域研究效率：`country.research.engineering_efficiency`：+8%
  - 效果机制：计时、测量与统计提高工程研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地产测绘 (`tech.property_cadastre`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.property_cadastre` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.land\_institutions |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 地图学 (`tech.cartography`)：该科技需要先掌握 「地图学」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

解锁建筑：地籍管理局；「地籍制度」生产家族建筑产出 +25%；「地理分析机构」生产家族建筑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **地籍管理局**（`building`）：`building.cadastral_office` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 地籍制度：`country.output.family.cadastral_institution_factor`：+25%
- 地理分析机构：`country.output.family.geospatial_analysis_institution_factor`：+25%
  - 效果机制：地产测绘提高地籍制度建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：地产测绘提高地理分析机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 煤层地质 (`tech.coal_geology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_geology` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 科学分类 (`tech.scientific_classification`)：按化石与岩性分类地层（威廉·史密斯 1815 年地层图）是识别含煤层位的方法基础。

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

煤 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 煤：`country.resource.coal.use_factor`：+8%
  - 效果机制：煤田地质调查减少无效掘进与煤层损失。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽密封 (`tech.steam_sealing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_sealing` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 大气式蒸汽机 (`tech.atmospheric_engine`)：蒸汽密封要解决大气式蒸汽机汽缸漏气问题。
- 精密工程 (`tech.precision_engineering`)：汽缸镗削与活塞配合依赖精密工程。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商品「煤」生产投入 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 煤：`country.input.good.coal_factor`：+8%
  - 效果机制：密封减少蒸汽系统煤耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 蒸汽动力 (`tech.steam_power`)：分离冷凝与高压运行都依赖可靠的蒸汽密封。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 罐藏 (`tech.canning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.canning` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

- 盐渍保存 (`tech.salt_preservation`)：罐藏延续了隔绝腐败的食物保存思路。
- 实验科学 (`tech.experimental_science`)：阿佩尔的加热密封法来自反复实验（罐头食品 1810）。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 1000」（development.output.knowledge.1000\_360d）

#### 效果摘要

解锁建筑：罐头工坊；解锁物资：鱼罐头；商品「加工食品」家庭消费 -8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 鱼罐头 (`canned_fish`)
- **建筑 / 生产方式：** 罐头工坊 (`canning_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **罐头工坊**（`building`）：`building.canning_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼罐头**（`good`）：`good.canned_fish` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 加工食品：`country.consumption.good.processed_food_factor`：+8%
  - 效果机制：罐藏延长加工食品保存期。
  - 运行时消费者：`NativeEconomyRuntime::effective_household_good_quantity`

#### 被以下科技作为硬前置

- 罐头工业化 (`tech.industrial_canning`)：罐头工业化把罐藏工艺搬进工厂（罐头工业化 ← 罐头食品）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 保险与精算 (`tech.actuarial_insurance`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.actuarial_insurance` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 交流 (\`route.trade.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 特许商社 (`tech.chartered_companies`)：海运保险最早为特许商社的远洋货物承保。
- 概率与统计 (`tech.probability_statistics`)：精算以概率与死亡率统计定价风险（保险精算 1762）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

国内贸易容量 +8%

#### 机会成本

占用社会研究预算，推迟工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：风险可以定价与分摊后，商人愿意承运更多货物。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 有限责任公司 (`tech.limited_liability`)：有限责任建立在可以量化与分摊的商业风险之上。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 启蒙制度 (`tech.enlightenment_institutions`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.enlightenment_institutions` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 360000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 13 项候选中的任意 5 项：
- 农业改良 (`tech.agricultural_improvement`)
- 标准化 (`tech.standardization`)
- 实验科学 (`tech.experimental_science`)
- 合作社组织 (`tech.cooperative_association`)
- 系统育种 (`tech.crop_breeding`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)
- 科学分类 (`tech.scientific_classification`)
- 地产测绘 (`tech.property_cadastre`)
- 精密工程 (`tech.precision_engineering`)
- 公共卫生 (`tech.public_health`)
- 水利工程 (`tech.hydraulic_engineering`)
- 农业合作社 (`tech.agricultural_cooperatives`)
- 地质勘探 (`tech.geological_prospecting`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 改良轮作小麦庄园 (`app.method_wheat_farm_r5`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wheat_farm_r5` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 系统育种 (`tech.crop_breeding`)：该知识是此产业交汇自动生效的必要条件。
- 野生谷穗采集 (`tech.wild_wheat_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良轮作小麦庄园 (`method_wheat_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 改良小农场 (`app.improved_smallholding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.improved_smallholding` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 农业改良 (`tech.agricultural_improvement`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良小农场 (`improved_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 改良轮作马铃薯庄园 (`app.method_potato_farm_r5`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_potato_farm_r5` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 农业改良 (`tech.agricultural_improvement`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良轮作马铃薯庄园 (`method_potato_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精梳羊毛作坊 (`app.method_wool_shed_r5`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wool_shed_r5` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机械工坊 (`tech.mechanical_workshops`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 毛用畜牧 (`tech.wool_husbandry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精梳羊毛作坊 (`method_wool_shed_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 硅砂矿 (`app.silica_sand_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.silica_sand_collector` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 地质勘探 (`tech.geological_prospecting`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 硅砂矿 (`silica_sand_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 大气式蒸汽机工坊 (`app.atmospheric_engine_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.atmospheric_engine_workshop` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大气式蒸汽机 (`tech.atmospheric_engine`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 大气式蒸汽机工坊 (`atmospheric_engine_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 改良亚麻庄园 (`app.method_flax_collector_r5`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_flax_collector_r5` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 长期租约 (`tech.long_term_leases`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良亚麻庄园 (`method_flax_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精耕稻庄 (`app.method_rice_collector_r5`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rice_collector_r5` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 农业合作社 (`tech.agricultural_cooperatives`)：该知识是此产业交汇自动生效的必要条件。
- 芦苇收割 (`tech.reed_harvesting`)：该知识是此产业交汇自动生效的必要条件。
- 野生稻采集 (`tech.wild_rice_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精耕稻庄 (`method_rice_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地籍管理局 (`app.cadastral_office`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.cadastral_office` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 地产测绘 (`tech.property_cadastre`)：该知识是此产业交汇自动生效的必要条件。
- 木版印刷 (`tech.woodblock_printing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 罐头工坊 (`app.canning_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.canning_workshop` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 罐藏 (`tech.canning`)：该知识是此产业交汇自动生效的必要条件。
- 淡水岸捕 (`tech.freshwater_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 罐头工坊 (`canning_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-7"></a>
## 蒸汽时代

共 29 项研究科技、18 项自动应用，科技研究成本范围 480000-800000；时代里程碑：工业化 (`tech.industrialization`)。

### 焦炭冶炼 (`tech.coke_smelting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coke_smelting` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`)；资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 高炉冶炼 (`tech.blast_furnace`)：焦炭炼铁把高炉燃料由木炭改为焦炭（焦炭炼铁 ← 高炉、焦炭）。
- 煤矿开采 (`tech.coal_mining`)：炼焦需要稳定供应的矿井煤。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 250」（development.employment.manufacturing.250\_360d）

#### 效果摘要

解锁建筑：焦化厂；解锁建筑：焦炭炼钢厂；解锁物资：焦炭；解锁物资：钢材；「炼钢」生产家族建筑产出 +12%；作为必要支撑：蒸汽钻井场、蒸汽航运船坞、蒸汽机工厂、钢制工具厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 焦炭 (`coke`)；钢材 (`steel`)
- **建筑 / 生产方式：** 焦化厂 (`coke_ovens`)；焦炭炼钢厂 (`steam_steel_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)；家用电器厂 (`household_appliances_plant`)；自动化焦化厂 (`method_coke_ovens_r9`)；蒸汽航运船坞 (`method_steam_shipping`)；蒸汽机工厂 (`steam_engine_works`)；钢制工具厂 (`tools_plant`)

#### 结构化内容效果

- **焦化厂**（`building`）：`building.coke_ovens` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **焦炭炼钢厂**（`building`）：`building.steam_steel_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **焦炭**（`good`）：`good.coke` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 炼钢：`country.output.family.steelmaking_factor`：+12%
  - 效果机制：焦炭冶炼提高炼钢建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 钢筋混凝土 (`tech.reinforced_concrete`)：受拉钢筋来自焦炭冶炼提供的廉价钢材。
- 铁路物流 (`tech.rail_logistics`)：铁轨与车轮需要焦炭冶炼提供的大量钢铁。
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金建立在大规模钢铁冶炼之上。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 钢筋混凝土 (`tech.reinforced_concrete`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.reinforced_concrete` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；材料 · 铁 (\`route.material.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | materials |

#### 硬前置（决定研发资格）

- 水利工程 (`tech.hydraulic_engineering`)：钢筋混凝土以水硬性水泥为胶结料（钢筋混凝土 1867 ← 波特兰水泥）。
- 焦炭冶炼 (`tech.coke_smelting`)：受拉钢筋来自焦炭冶炼提供的廉价钢材。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：混凝土厂；解锁物资：混凝土

#### 机会成本

占用工程研究预算，混凝土厂需要持续的水泥与钢筋投入。

#### 内容解锁

- **物资：** 混凝土 (`concrete`)
- **建筑 / 生产方式：** 混凝土厂 (`concrete_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)；自动化混凝土厂 (`method_concrete_plant_r9`)

#### 结构化内容效果

- **混凝土厂**（`building`）：`building.concrete_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **混凝土**（`good`）：`good.concrete` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽动力 (`tech.steam_power`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_power` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 大气式蒸汽机 (`tech.atmospheric_engine`)：蒸汽动力由大气式蒸汽机改进而来。
- 蒸汽密封 (`tech.steam_sealing`)：分离冷凝与高压运行都依赖可靠的蒸汽密封。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易量 1000」（development.trade.quantity\_1000）

#### 效果摘要

解锁建筑：蒸汽航运船坞；解锁建筑：蒸汽机工厂；制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 远洋船舶 (`oceanic_vessels`)；蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)；蒸汽机工厂 (`steam_engine_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽航运船坞**（`building`）：`building.method_steam_shipping` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽机工厂**（`building`）：`building.steam_engine_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+12%
  - 效果机制：蒸汽动力提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 热力学 (`tech.thermodynamics`)：卡诺的热机理论直接分析蒸汽机效率。
- 罐头工业化 (`tech.industrial_canning`)：蒸汽杀菌锅与制罐机由蒸汽动力驱动。
- 蒸汽抽水 (`tech.steam_pumping`)：蒸汽抽水使用通用蒸汽动力机。
- 铁路物流 (`tech.rail_logistics`)：蒸汽机车是铁路运输的牵引动力。
- 机械印刷 (`tech.mechanized_printing`)：滚筒印刷机由蒸汽动力驱动（1814 年蒸汽印刷机）。
- 蒸汽锯木 (`tech.steam_sawmilling`)：该科技需要先掌握 「蒸汽动力」。

#### 主题路线后继

- 蒸汽抽水 (`tech.steam_pumping`)：该知识继续发展为 「蒸汽抽水」。

#### 跨领域应用

- 铁路物流 (`tech.rail_logistics`)：该知识参与形成 「铁路物流」。
- 机械印刷 (`tech.mechanized_printing`)：该知识参与形成 「机械印刷」。

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 热力学 (`tech.thermodynamics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.thermodynamics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 能源 · 热能 (\`route.energy.thermal\`) |
| 全部路线 | 能源 · 热能 (\`route.energy.thermal\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：热力学定律来自量热与气体实验。
- 蒸汽动力 (`tech.steam_power`)：卡诺的热机理论直接分析蒸汽机效率。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 250」（development.employment.extractive.250\_360d）

#### 效果摘要

商品「煤」生产投入 -8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 煤：`country.input.good.coal_factor`：+8%
  - 效果机制：热力学减少动力煤耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 发电机 (`tech.electric_generation`)：该科技需要先掌握 「热力学」。
- 机械制冷 (`tech.refrigeration`)：该科技需要先掌握 「热力学」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 罐头工业化 (`tech.industrial_canning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_canning` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 工艺 · 储藏 (\`route.craft.storage\`) |
| 全部路线 | 工艺 · 储藏 (\`route.craft.storage\`)；工艺 · 蒸汽 (\`route.craft.steam\`) |
| 开局能力标签 | 无 |
| 效果配置 | food |

#### 硬前置（决定研发资格）

- 罐藏 (`tech.canning`)：罐头工业化把罐藏工艺搬进工厂（罐头工业化 ← 罐头食品）。
- 蒸汽动力 (`tech.steam_power`)：蒸汽杀菌锅与制罐机由蒸汽动力驱动。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：鱼类罐头厂

#### 机会成本

占用工程研究预算，罐头厂依赖稳定的渔获与包装材料供应。

#### 内容解锁

- **物资：** 鱼罐头 (`canned_fish`)
- **建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **鱼类罐头厂**（`building`）：`building.canned_fish_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鱼罐头**（`good`）：`good.canned_fish` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业组织 (`tech.industrial_organization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_organization` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 行业组织 (`tech.guild_organization`)：工业组织由行会生产组织转变而来。
- 机械工坊 (`tech.mechanical_workshops`)：机械工坊把工序集中到同一厂房。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

制造部门产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+8%
  - 效果机制：工业组织提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工厂制 (`tech.factory_system`)：工厂制把工业组织固定为集中厂房与工时纪律。
- 管理层级 (`tech.managerial_hierarchy`)：该科技需要先掌握 「工业组织」。
- 有限责任公司 (`tech.limited_liability`)：工业企业需要向众多股东募集长期资本（公司法与有限责任 1856）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 蒸汽抽水 (`tech.steam_pumping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_pumping` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 矿井排水 (`tech.mine_drainage`)：蒸汽抽水替代水轮承担矿井排水。
- 蒸汽动力 (`tech.steam_power`)：蒸汽抽水使用通用蒸汽动力机。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 2 个」（development.trade.partners\_2）

#### 效果摘要

解锁建筑：铅矿；解锁建筑：蒸汽动力煤矿；解锁建筑：蒸汽动力铁矿；解锁建筑：锌矿；解锁物资：铅矿石；解锁物资：锌矿石；「铁矿采掘」生产家族建筑产出 +12%；作为必要支撑：炼铅厂、炼锌厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)；铁矿石 (`iron_ore`)；铅矿石 (`lead_ore`)；锌矿石 (`zinc_ore`)
- **建筑 / 生产方式：** 铅矿 (`lead_ore_collector`)；蒸汽动力煤矿 (`steam_coal_mine`)；蒸汽动力铁矿 (`steam_iron_mine`)；锌矿 (`zinc_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 炼铅厂 (`lead_plant`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化锌矿 (`method_zinc_ore_collector_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)；炼锌厂 (`zinc_plant`)

#### 结构化内容效果

- **铅矿**（`building`）：`building.lead_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽动力煤矿**（`building`）：`building.steam_coal_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽动力铁矿**（`building`）：`building.steam_iron_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **锌矿**（`building`）：`building.zinc_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铁矿石**（`good`）：`good.iron_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铅矿石**（`good`）：`good.lead_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锌矿石**（`good`）：`good.zinc_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+12%
  - 效果机制：蒸汽抽水提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业采煤 (`tech.industrial_coal_mining`)：深部工业煤矿依赖蒸汽抽水排水。
- 石油开采 (`tech.petroleum_extraction`)：早期油井用蒸汽机带动顿钻与抽油（德雷克油井 1859）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业采煤 (`tech.industrial_coal_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_coal_mining` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 煤矿开采 (`tech.coal_mining`)：工业采煤是竖井煤矿的规模化。
- 蒸汽抽水 (`tech.steam_pumping`)：深部工业煤矿依赖蒸汽抽水排水。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

煤 -12%；商品「工具」生产投入 +5%；采掘部门产出 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 煤：`country.resource.coal.use_factor`：+12%
- 工具：`country.input.good.tools_factor`：+5%
- 采掘部门产出：`country.output.extractive_factor`：+18%
  - 效果机制：工业矿井降低煤层损失。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：工业矿井增加工具维护负担。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`
  - 效果机制：工业采煤提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公司矿山 (`tech.corporate_mining`)：该科技需要先掌握 「工业采煤」。
- 机械化采矿 (`tech.mechanized_mining`)：机械化采矿承接工业采煤的深井体系。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 纺织机械 (`tech.textile_machinery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.textile_machinery` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 织造 (`tech.weaving`)：纺织机械把手工纺纱与织造的动作机械化（动力织机 ← 飞梭）。
- 机械工坊 (`tech.mechanical_workshops`)：纺纱机与织机的齿轮、锭子由机械工坊制造。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易量 1000」（development.trade.quantity\_1000）

#### 效果摘要

解锁建筑：制衣厂；解锁建筑：改良家用织机；解锁建筑：机械轧棉厂；解锁建筑：蒸汽纺织厂；商品「煤」生产投入 +4%；商品「衣物」产量 +20%；「布匹织造」生产家族建筑产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)；衣物 (`clothing`)；棉纤维 (`cotton_fiber`)
- **建筑 / 生产方式：** 制衣厂 (`clothing_plant`)；改良家用织机 (`improved_domestic_loom`)；机械轧棉厂 (`mechanized_cotton_gin`)；蒸汽纺织厂 (`textile_mill`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **制衣厂**（`building`）：`building.clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **改良家用织机**（`building`）：`building.improved_domestic_loom` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械轧棉厂**（`building`）：`building.mechanized_cotton_gin` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽纺织厂**（`building`）：`building.textile_mill` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **棉纤维**（`good`）：`good.cotton_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 煤：`country.input.good.coal_factor`：+4%
- 衣物：`country.output.good.clothing_factor`：+20%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+20%
  - 效果机制：早期纺机增加煤动力需求。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`
  - 效果机制：纺织机械提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：纺织机械提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工厂制 (`tech.factory_system`)：最早的工厂是集中安装纺织机械的纺纱厂。
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：合成纤维沿用纺织机械纺丝织造。

#### 主题路线后继

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：该知识继续发展为 「合成纤维工程」。

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 工厂制 (`tech.factory_system`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.factory_system` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 工业组织 (`tech.industrial_organization`)：工厂制把工业组织固定为集中厂房与工时纪律。
- 纺织机械 (`tech.textile_machinery`)：最早的工厂是集中安装纺织机械的纺纱厂。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 10000」（development.output.energy.10000\_720d）

#### 效果摘要

解锁建筑：制革厂；制造部门产出 +6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 皮革 (`leather`)
- **建筑 / 生产方式：** 制革厂 (`leather_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **制革厂**（`building`）：`building.leather_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革**（`good`）：`good.leather` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+6%
  - 效果机制：工厂制提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业统计 (`tech.industrial_statistics`)：工业统计以工厂产量与工时记录为对象。
- 劳工组织 (`tech.labor_organization`)：劳工组织在集中工厂中形成。
- 流水线组织 (`tech.assembly_line`)：流水线是工厂内部工序的重新排布。
- 工人合作工场 (`tech.worker_cooperatives`)：工人合作工场以工厂生产为对象。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机床 (`tech.machine_tools`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.machine_tools` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 机械工坊 (`tech.mechanical_workshops`)：机床由机械工坊的车削与镗削工具发展而来（全金属螺纹车床 1800）。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 10000」（development.output.energy.10000\_720d）

#### 效果摘要

解锁建筑：钢制工具厂；「金属工具」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 金属工具 (`tools`)
- **建筑 / 生产方式：** 钢制工具厂 (`tools_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化机械零件厂 (`method_machine_parts_plant_r9`)

#### 结构化内容效果

- **钢制工具厂**（`building`）：`building.tools_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 金属工具：`country.output.family.metal_toolmaking_factor`：+12%
  - 效果机制：机床提高金属工具建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 机械化农业 (`tech.mechanized_agriculture`)：农业机械的铁制零件由机床批量加工。
- 机械收割 (`tech.mechanical_reaping`)：该科技需要先掌握 「机床」。
- 互换零件 (`tech.interchangeable_parts`)：互换零件要求机床稳定加工同一公差（互换性零件 ← 全金属螺纹车床）。
- 蒸汽锯木 (`tech.steam_sawmilling`)：该科技需要先掌握 「机床」。
- 内燃机 (`tech.internal_combustion`)：汽缸、曲轴需要机床精密加工。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械化农业 (`tech.mechanized_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanized_agriculture` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 农业改良 (`tech.agricultural_improvement`)：机械化农业服务于改良后的规模化农场。
- 机床 (`tech.machine_tools`)：农业机械的铁制零件由机床批量加工。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 250」（development.employment.energy.250\_360d）

#### 效果摘要

农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 数字化农业机械厂 (`method_agricultural_machinery_plant_r9`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：机械化农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 机械收割 (`tech.mechanical_reaping`)：该科技需要先掌握 「机械化农业」。
- 机械脱粒 (`tech.mechanical_threshing`)：机械脱粒是农业机械化的一部分。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 铁路物流 (`tech.rail_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rail_logistics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 全部路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 蒸汽动力 (`tech.steam_power`)：蒸汽机车是铁路运输的牵引动力。
- 焦炭冶炼 (`tech.coke_smelting`)：铁轨与车轮需要焦炭冶炼提供的大量钢铁。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 62500」（development.population.62500\_720d）

#### 效果摘要

解锁建筑：铁路设备工场；解锁物资：铁路设备；「铁矿采掘」生产家族建筑产出 +12%；作为必要支撑：铁路设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铁路设备 (`railway_equipment`)
- **建筑 / 生产方式：** 铁路设备工场 (`steam_rail_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铁路设备厂 (`railway_equipment_plant`)

#### 结构化内容效果

- **铁路设备工场**（`building`）：`building.steam_rail_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铁路设备**（`good`）：`good.railway_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿采掘：`country.output.family.iron_extraction_factor`：+12%
  - 效果机制：铁路物流提高铁矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 冷链 (`tech.cold_chain`)：冷藏车厢把冷库连成运输链（冷链 ← 制冷技术、冷藏车厢）。
- 全球物流 (`tech.global_logistics`)：全球物流把铁路与港口联运组织起来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 工业化学 (`tech.industrial_chemistry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_chemistry` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：该科技需要先掌握 「实验科学」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 16」（development.buildings.active\_16\_360d）

#### 效果摘要

解锁建筑：玻璃厂；解锁建筑：化学工场；解锁建筑：深井盐矿；解锁物资：工业化学品；可利用资源：硫磺矿；采掘部门产出 +12%；作为必要支撑：高级成衣厂、高级家具厂、制革厂、造纸厂、制药厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玻璃 (`glass`)；工业化学品 (`industrial_chemicals`)；食盐 (`salt`)
- **建筑 / 生产方式：** 玻璃厂 (`glass_plant`)；化学工场 (`industrial_chemicals_plant`)；深井盐矿 (`industrial_salt_mine`)
- **自然资源：** 硫磺矿 (`sulfur`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；早期半导体厂 (`basic_semiconductor_fab`)；高级成衣厂 (`fine_clothing_plant`)；高级家具厂 (`fine_furniture_plant`)；制革厂 (`leather_plant`)；智能化电池厂 (`method_batteries_plant_r10`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；造纸厂 (`paper_plant`)；制药厂 (`pharmaceuticals_plant`)；半导体厂 (`semiconductors_plant`)

#### 结构化内容效果

- **玻璃厂**（`building`）：`building.glass_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **化学工场**（`building`）：`building.industrial_chemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **深井盐矿**（`building`）：`building.industrial_salt_mine` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃**（`good`）：`good.glass` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **食盐**（`good`）：`good.salt` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硫磺矿**（`resource`）：`resource.sulfur` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：工业化学提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 合成肥料 (`tech.synthetic_fertilizer`)：合成氨需要高温高压的工业化学工艺（哈伯法 1909）。
- 电化学 (`tech.electrochemistry`)：该科技需要先掌握 「工业化学」。
- 石油化工 (`tech.petrochemical_industry`)：裂解、合成等单元操作来自工业化学。
- 工业生态 (`tech.industrial_ecology`)：该科技需要先掌握 「工业化学」。

#### 主题路线后继

- 电化学 (`tech.electrochemistry`)：该知识继续发展为 「电化学」。

#### 跨领域应用

- 石油化工 (`tech.petrochemical_industry`)：该知识参与形成 「石油化工」。
- 现代医学 (`tech.modern_medicine`)：该知识参与形成 「现代医学」。
- 合成肥料 (`tech.synthetic_fertilizer`)：该知识参与形成 「合成肥料」。

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 肥料加工 (`tech.fertilizer_processing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fertilizer_processing` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`)；资源 · 磷矿 (\`route.resource.phosphate\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 土壤实验 (`tech.soil_experimentation`)：该科技需要先掌握 「土壤实验」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：磷矿；解锁物资：磷矿石；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 磷矿石 (`phosphate_rock`)
- **建筑 / 生产方式：** 磷矿 (`phosphate_rock_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化磷矿 (`method_phosphate_rock_collector_r9`)

#### 结构化内容效果

- **磷矿**（`building`）：`building.phosphate_rock_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **磷矿石**（`good`）：`good.phosphate_rock` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：肥料加工提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 合成肥料 (`tech.synthetic_fertilizer`)：合成肥料接续肥料加工的施肥体系。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械收割 (`tech.mechanical_reaping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_reaping` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 机床 (`tech.machine_tools`)：该科技需要先掌握 「机床」。
- 机械化农业 (`tech.mechanized_agriculture`)：该科技需要先掌握 「机械化农业」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：机械收割提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 机动农业 (`tech.motorized_agriculture`)：机动农业把机械收割机改由拖拉机牵引。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械印刷 (`tech.mechanized_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanized_printing` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 螺旋压印 (`tech.screw_press_printing`)：机械印刷由螺旋压印机发展而来。
- 蒸汽动力 (`tech.steam_power`)：滚筒印刷机由蒸汽动力驱动（1814 年蒸汽印刷机）。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 250」（development.employment.extractive.250\_360d）

#### 效果摘要

解锁建筑：造纸厂；「造纸」生产家族建筑产出 +22%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 造纸厂 (`paper_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **造纸厂**（`building`）：`building.paper_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 造纸：`country.output.family.paper_making_factor`：+22%
  - 效果机制：机械印刷提高造纸建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公共教育 (`tech.public_education`)：普及教育依赖廉价批量印刷的课本。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械脱粒 (`tech.mechanical_threshing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_threshing` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 机械化农业 (`tech.mechanized_agriculture`)：机械脱粒是农业机械化的一部分。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

商品「煤」生产投入 +4%；商品「小麦」产量 +20%；商品「稻米」产量 +20%；商品「玉米」产量 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 煤：`country.input.good.coal_factor`：+4%
- 小麦：`country.output.good.wheat_grain_factor`：+20%
- 稻米：`country.output.good.rice_grain_factor`：+20%
- 玉米：`country.output.good.corn_grain_factor`：+20%
  - 效果机制：早期动力脱粒增加煤耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`
  - 效果机制：机械脱粒提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：机械脱粒提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：机械脱粒提高玉米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 管理层级 (`tech.managerial_hierarchy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.managerial_hierarchy` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 工业组织 (`tech.industrial_organization`)：该科技需要先掌握 「工业组织」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 62500」（development.population.62500\_720d）

#### 效果摘要

解锁建筑：家具厂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 家具 (`furniture`)
- **建筑 / 生产方式：** 家具厂 (`furniture_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **家具厂**（`building`）：`building.furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **家具**（`good`）：`good.furniture` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：管理层级提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公司管理 (`tech.corporate_management`)：公司管理建立在职业经理层级之上。

#### 主题路线后继

- 公司管理 (`tech.corporate_management`)：该知识继续发展为 「公司管理」。

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业统计 (`tech.industrial_statistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_statistics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工厂制 (`tech.factory_system`)：工业统计以工厂产量与工时记录为对象。
- 概率与统计 (`tech.probability_statistics`)：工业统计应用概率与统计方法。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会生产投入 -3%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+3%
  - 效果机制：工业统计减少跨厂物料计划偏差。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 公司管理 (`tech.corporate_management`)：公司管理依靠产量与成本统计决策。
- 工业质量控制 (`tech.industrial_quality_control`)：该科技需要先掌握 「工业统计」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 互换零件 (`tech.interchangeable_parts`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.interchangeable_parts` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 机床 (`tech.machine_tools`)：互换零件要求机床稳定加工同一公差（互换性零件 ← 全金属螺纹车床）。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 250」（development.employment.manufacturing.250\_360d）

#### 效果摘要

全社会生产投入 -5%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+5%
  - 效果机制：互换件降低修配和备件投入。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 流水线组织 (`tech.assembly_line`)：流水线依赖可直接装配的互换零件。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 劳工组织 (`tech.labor_organization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.labor_organization` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 工厂制 (`tech.factory_system`)：劳工组织在集中工厂中形成。
- 工资契约 (`tech.wage_contracts`)：工会以集体谈判工资契约为核心诉求。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 2 个」（development.trade.partners\_2）

#### 效果摘要

解锁建筑：制鞋厂；制造部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鞋履 (`footwear`)
- **建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **制鞋厂**（`building`）：`building.footwear_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **鞋履**（`good`）：`good.footwear` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+8%
  - 效果机制：劳工组织提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 流水线组织 (`tech.assembly_line`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.assembly_line` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 互换零件 (`tech.interchangeable_parts`)：流水线依赖可直接装配的互换零件。
- 工厂制 (`tech.factory_system`)：流水线是工厂内部工序的重新排布。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 250」（development.employment.extractive.250\_360d）

#### 效果摘要

解锁建筑：面包厂；制造部门产出 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 面包 (`bread`)
- **建筑 / 生产方式：** 面包厂 (`bread_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化家用电器厂 (`method_household_appliances_plant_r10`)

#### 结构化内容效果

- **面包厂**（`building`）：`building.bread_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **面包**（`good`）：`good.bread` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 制造部门产出：`country.output.manufacturing_factor`：+22%
  - 效果机制：流水线组织提高制造部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 大规模生产 (`tech.mass_production`)：大规模生产以流水线组织为核心。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 蒸汽锯木 (`tech.steam_sawmilling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_sawmilling` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；能源 · 蒸汽 (\`route.energy.steam\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 手工锯木 (`tech.timber_sawing`)：该科技需要先掌握 「手工锯木」。
- 蒸汽动力 (`tech.steam_power`)：该科技需要先掌握 「蒸汽动力」。
- 机床 (`tech.machine_tools`)：该科技需要先掌握 「机床」。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 250」（development.employment.energy.250\_360d）

#### 效果摘要

解锁建筑：蒸汽锯木厂；全社会经济产出 +8%；木材 -8%；商品「煤」生产投入 +5%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 木材 (`lumber`)
- **建筑 / 生产方式：** 蒸汽锯木厂 (`method_lumber_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽锯木厂**（`building`）：`building.method_lumber_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **木材**（`good`）：`good.lumber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
- 木材：`country.resource.timber.use_factor`：+8%
- 煤：`country.input.good.coal_factor`：+5%
  - 效果机制：蒸汽锯木提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：动力锯切减少锯路损耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：蒸汽锯木以煤耗换取吞吐。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公司矿山 (`tech.corporate_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.corporate_mining` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`)；制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 工业采煤 (`tech.industrial_coal_mining`)：该科技需要先掌握 「工业采煤」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

采掘部门产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+28%
  - 效果机制：公司矿山提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工人合作工场 (`tech.worker_cooperatives`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.worker_cooperatives` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`)；制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 合作社组织 (`tech.cooperative_association`)：工人合作工场沿用合作社的共有与分配规则。
- 工厂制 (`tech.factory_system`)：工人合作工场以工厂生产为对象。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：工人合作工场提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 有限责任公司 (`tech.limited_liability`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.limited_liability` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；工艺 · 工厂 (\`route.craft.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 保险与精算 (`tech.actuarial_insurance`)：有限责任建立在可以量化与分摊的商业风险之上。
- 工业组织 (`tech.industrial_organization`)：工业企业需要向众多股东募集长期资本（公司法与有限责任 1856）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

国内贸易容量 +8%

#### 机会成本

占用社会研究预算，推迟工业技术路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+8%
  - 效果机制：股份募资扩大了商号与运输企业的资本规模。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 中央银行体系 (`tech.central_banking`)：中央银行监管的是由股份公司组成的银行体系。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 微生物学 (`tech.microbiology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.microbiology` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 工艺 · 实验 (\`route.craft.experimental\`) |
| 全部路线 | 工艺 · 实验 (\`route.craft.experimental\`)；工艺 · 储藏 (\`route.craft.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | science |

#### 硬前置（决定研发资格）

- 科学分类 (`tech.scientific_classification`)：微生物学把分类方法延伸到显微镜下的生物。
- 实验科学 (`tech.experimental_science`)：巴斯德的曲颈瓶实验否定了自然发生说（病菌学说 1861）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

「主粮加工」生产家族建筑产出 +12%

#### 机会成本

占用科学研究预算，推迟蒸汽工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 主粮加工：`country.output.family.staple_preparation_factor`：+12%
  - 效果机制：控制发酵与杀菌减少了主粮加工中的腐败损耗。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 现代医学 (`tech.modern_medicine`)：病菌学说是消毒、疫苗与抗菌治疗的理论基础。
- 遗传学 (`tech.genetics`)：遗传学沿用微生物学的显微与细胞观察方法。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业化 (`tech.industrialization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrialization` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 800000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 14 项候选中的任意 5 项：
- 机械化农业 (`tech.mechanized_agriculture`)
- 机床 (`tech.machine_tools`)
- 热力学 (`tech.thermodynamics`)
- 工厂制 (`tech.factory_system`)
- 肥料加工 (`tech.fertilizer_processing`)
- 蒸汽动力 (`tech.steam_power`)
- 工业化学 (`tech.industrial_chemistry`)
- 劳工组织 (`tech.labor_organization`)
- 工业组织 (`tech.industrial_organization`)
- 铁路物流 (`tech.rail_logistics`)
- 机械印刷 (`tech.mechanized_printing`)
- 流水线组织 (`tech.assembly_line`)
- 纺织机械 (`tech.textile_machinery`)
- 工业采煤 (`tech.industrial_coal_mining`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽航运船坞 (`app.method_steam_shipping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_steam_shipping` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 蒸汽动力 (`tech.steam_power`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 远洋航海 (`tech.oceanic_navigation`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽机工厂 (`app.steam_engine_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.steam_engine_works` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 蒸汽动力 (`tech.steam_power`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽机工厂 (`steam_engine_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 鱼类罐头厂 (`app.canned_fish_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.canned_fish_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 罐头工业化 (`tech.industrial_canning`)：该知识是此产业交汇自动生效的必要条件。
- 淡水岸捕 (`tech.freshwater_fishing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铅矿 (`app.lead_ore_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.lead_ore_collector` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 地质勘探 (`tech.geological_prospecting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铅矿 (`lead_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽动力铁矿 (`app.steam_iron_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.steam_iron_mine` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。
- 铁矿辨识 (`tech.iron_ore_identification`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽动力铁矿 (`steam_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 锌矿 (`app.zinc_ore_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.zinc_ore_collector` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 锌矿 (`zinc_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 改良家用织机 (`app.improved_domestic_loom`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.improved_domestic_loom` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 纺织机械 (`tech.textile_machinery`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良家用织机 (`improved_domestic_loom`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械轧棉厂 (`app.mechanized_cotton_gin`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.mechanized_cotton_gin` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 纺织机械 (`tech.textile_machinery`)：该知识是此产业交汇自动生效的必要条件。
- 野生棉铃采集 (`tech.wild_cotton_collection`)：该知识是此产业交汇自动生效的必要条件。
- 棉花去籽 (`tech.cotton_ginning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械轧棉厂 (`mechanized_cotton_gin`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 钢制工具厂 (`app.tools_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.tools_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机床 (`tech.machine_tools`)：该知识是此产业交汇自动生效的必要条件。
- 手工锯木 (`tech.timber_sawing`)：该知识是此产业交汇自动生效的必要条件。
- 块炼铁 (`tech.iron_smelting`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 钢制工具厂 (`tools_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玻璃厂 (`app.glass_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.glass_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玻璃厂 (`glass_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 化学工场 (`app.industrial_chemicals_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.industrial_chemicals_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 盐渍保存 (`tech.salt_preservation`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 化学工场 (`industrial_chemicals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 深井盐矿 (`app.industrial_salt_mine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.industrial_salt_mine` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 卤水采集 (`tech.brine_collection`)：该知识是此产业交汇自动生效的必要条件。
- 盐渍保存 (`tech.salt_preservation`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 深井盐矿 (`industrial_salt_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 磷矿 (`app.phosphate_rock_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.phosphate_rock_collector` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 肥料加工 (`tech.fertilizer_processing`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 磷矿 (`phosphate_rock_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 造纸厂 (`app.paper_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.paper_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机械印刷 (`tech.mechanized_printing`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 造纸厂 (`paper_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 制鞋厂 (`app.footwear_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.footwear_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 劳工组织 (`tech.labor_organization`)：该知识是此产业交汇自动生效的必要条件。
- 野生割胶 (`tech.wild_latex_tapping`)：该知识是此产业交汇自动生效的必要条件。
- 天然橡胶加工 (`tech.rubber_working`)：该知识是此产业交汇自动生效的必要条件。
- 皮革鞣制 (`tech.hide_tanning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 制革厂 (`app.leather_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.leather_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工厂制 (`tech.factory_system`)：该知识是此产业交汇自动生效的必要条件。
- 狩猎 (`tech.hunting`)：该知识是此产业交汇自动生效的必要条件。
- 皮革鞣制 (`tech.hide_tanning`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制革厂 (`leather_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家具厂 (`app.furniture_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.furniture_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 管理层级 (`tech.managerial_hierarchy`)：该知识是此产业交汇自动生效的必要条件。
- 织机织造 (`tech.loom_weaving`)：该知识是此产业交汇自动生效的必要条件。
- 手工锯木 (`tech.timber_sawing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家具厂 (`furniture_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 面包厂 (`app.bread_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bread_plant` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 流水线组织 (`tech.assembly_line`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 谷物烘焙 (`tech.grain_baking`)：该知识是此产业交汇自动生效的必要条件。
- 螺旋压印 (`tech.screw_press_printing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 面包厂 (`bread_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-8"></a>
## 电气时代

共 26 项研究科技、38 项自动应用，科技研究成本范围 1080000-1800000；时代里程碑：电气社会 (`tech.electrical_society`)。

### 合成肥料 (`tech.synthetic_fertilizer`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.synthetic_fertilizer` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 肥料加工 (`tech.fertilizer_processing`)：合成肥料接续肥料加工的施肥体系。
- 工业化学 (`tech.industrial_chemistry`)：合成氨需要高温高压的工业化学工艺（哈伯法 1909）。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：化肥厂；农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥料 (`fertilizer`)
- **建筑 / 生产方式：** 化肥厂 (`fertilizer_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **化肥厂**（`building`）：`building.fertilizer_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **肥料**（`good`）：`good.fertilizer` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：合成肥料提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业农学 (`tech.industrial_agronomy`)：化肥投入是工业农学增产的核心。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公共教育 (`tech.public_education`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_education` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 教育 (\`route.institution.education\`) |
| 全部路线 | 制度 · 教育 (\`route.institution.education\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 机械印刷 (`tech.mechanized_printing`)：普及教育依赖廉价批量印刷的课本。
- 官僚行政 (`tech.state_bureaucracy`)：义务教育由国家行政统一推行。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 32」（development.buildings.active\_32\_720d）

#### 效果摘要

解锁建筑：工业研究实验室；解锁建筑：综合工学院；「研究机构」生产家族建筑产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 工业研究实验室 (`industrial_research_laboratory`)；综合工学院 (`polytechnic_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **工业研究实验室**（`building`）：`building.industrial_research_laboratory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **综合工学院**（`building`）：`building.polytechnic_institute` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 研究机构：`country.output.family.research_institution_factor`：+4%
  - 效果机制：公共教育提高研究机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业研究 (`tech.industrial_research`)：该科技需要先掌握 「公共教育」。
- 公共卫生体系 (`tech.public_health_systems`)：该科技需要先掌握 「公共教育」。
- 知识经济 (`tech.knowledge_economy`)：知识经济依赖普及教育培养的知识劳动者。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 石油开采 (`tech.petroleum_extraction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_extraction` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1404000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地质勘探 (`tech.geological_prospecting`)：找油依赖地质勘探。
- 蒸汽抽水 (`tech.steam_pumping`)：早期油井用蒸汽机带动顿钻与抽油（德雷克油井 1859）。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 1250」（development.employment.energy.1250\_720d）

#### 效果摘要

解锁建筑：蒸汽钻井场；解锁物资：原油；可利用资源：石油；「石油采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原油 (`crude_oil`)
- **建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)
- **自然资源：** 石油 (`oil`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽钻井场**（`building`）：`building.early_oil_well` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原油**（`good`）：`good.crude_oil` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石油**（`resource`）：`resource.oil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 石油采掘：`country.output.family.oil_extraction_factor`：+12%
  - 效果机制：石油开采提高石油采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 石油炼制 (`tech.petroleum_refining`)：该科技需要先掌握 「石油开采」。
- 石油钻探 (`tech.petroleum_drilling`)：该科技需要先掌握 「石油开采」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 石油炼制 (`tech.petroleum_refining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_refining` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1404000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油开采 (`tech.petroleum_extraction`)：该科技需要先掌握 「石油开采」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 1250」（development.employment.manufacturing.1250\_720d）

#### 效果摘要

解锁建筑：炼油厂；解锁物资：精炼燃料；「石油采掘」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 精炼燃料 (`refined_fuel`)
- **建筑 / 生产方式：** 炼油厂 (`refined_fuel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能炼油厂 (`method_refined_fuel_plant_r10`)

#### 结构化内容效果

- **炼油厂**（`building`）：`building.refined_fuel_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精炼燃料**（`good`）：`good.refined_fuel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 石油采掘：`country.output.family.oil_extraction_factor`：+12%
  - 效果机制：石油炼制提高石油采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 内燃机 (`tech.internal_combustion`)：内燃机以石油炼制的轻质燃料为能源。
- 合成材料 (`tech.synthetic_materials`)：该科技需要先掌握 「石油炼制」。
- 石油化工 (`tech.petrochemical_industry`)：石油化工以炼厂馏分为原料。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 内燃机 (`tech.internal_combustion`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.internal_combustion` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 能源 · 内燃 (\`route.energy.combustion\`) |
| 全部路线 | 能源 · 内燃 (\`route.energy.combustion\`)；资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 石油炼制 (`tech.petroleum_refining`)：内燃机以石油炼制的轻质燃料为能源。
- 机床 (`tech.machine_tools`)：汽缸、曲轴需要机床精密加工。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 1250」（development.employment.knowledge.1250\_720d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化汽车厂 (`method_automobiles_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：内燃机提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 机动农业 (`tech.motorized_agriculture`)：拖拉机以内燃机为动力。
- 全球物流 (`tech.global_logistics`)：卡车与柴油船使集装箱联运成为可能（集装箱运输 1956）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 现代医学 (`tech.modern_medicine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.modern_medicine` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.public\_health |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 公共卫生 (`tech.public_health`)：现代医学在公共卫生的疫病调查基础上发展。
- 微生物学 (`tech.microbiology`)：病菌学说是消毒、疫苗与抗菌治疗的理论基础。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 10000」（development.output.energy.10000\_720d）

#### 效果摘要

解锁建筑：受控环境药材农场；解锁建筑：制药厂；解锁物资：药品；全社会经济产出 +4%；作为必要支撑：核医学制药中心

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)；药品 (`pharmaceuticals`)
- **建筑 / 生产方式：** 受控环境药材农场 (`method_medicinal_herbs_collector_r7`)；制药厂 (`pharmaceuticals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 核医学制药中心 (`nuclear_medicine_center`)

#### 结构化内容效果

- **受控环境药材农场**（`building`）：`building.method_medicinal_herbs_collector_r7` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **制药厂**（`building`）：`building.pharmaceuticals_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **药品**（`good`）：`good.pharmaceuticals` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：现代医学提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公共卫生体系 (`tech.public_health_systems`)：该科技需要先掌握 「现代医学」。
- 生物技术 (`tech.biotechnology`)：早期生物技术产品首先是药物与疫苗。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电磁感应 (`tech.electromagnetic_induction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electromagnetic_induction` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：该科技需要先掌握 「实验科学」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 10000」（development.output.manufacturing.10000\_720d）

#### 效果摘要

解锁建筑：线材厂；解锁物资：金属线材；全社会经济产出 +8%；作为必要支撑：绝缘电缆厂

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 金属线材 (`wire`)
- **建筑 / 生产方式：** 线材厂 (`wire_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 绝缘电缆厂 (`insulated_cable_plant`)

#### 结构化内容效果

- **线材厂**（`building`）：`building.wire_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属线材**（`good`）：`good.wire` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：电磁感应提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 发电机 (`tech.electric_generation`)：该科技需要先掌握 「电磁感应」。
- 无线电 (`tech.radio`)：无线电基于电磁感应与电磁波理论。
- 电动机 (`tech.electric_motors`)：该科技需要先掌握 「电磁感应」。
- 深层地球物理 (`tech.deep_geophysics`)：电法与磁法勘探以电磁感应为原理。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 发电机 (`tech.electric_generation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_generation` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)：该科技需要先掌握 「电磁感应」。
- 热力学 (`tech.thermodynamics`)：该科技需要先掌握 「热力学」。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 32」（development.buildings.active\_32\_720d）

#### 效果摘要

解锁建筑：燃煤发电厂；解锁建筑：河流水力发电站；解锁物资：电力；商品「电力」产量 +10%；能源部门产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电力 (`electricity`)
- **建筑 / 生产方式：** 燃煤发电厂 (`electricity_plant`)；河流水力发电站 (`hydropower_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **燃煤发电厂**（`building`）：`building.electricity_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **河流水力发电站**（`building`）：`building.hydropower_station` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电力**（`good`）：`good.electricity` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 电力：`country.output.good.electricity_factor`：+10%
- 能源部门产出：`country.output.energy_factor`：+10%
  - 效果机制：发电机提高电力产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：发电机提高能源部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 电气化 (`tech.electrification`)：电气化以发电机稳定供电为前提。
- 电网 (`tech.electric_grid`)：该科技需要先掌握 「发电机」。
- 核能 (`tech.nuclear_energy`)：核电站以汽轮发电机组输出电力。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电气化 (`tech.electrification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electrification` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 发电机 (`tech.electric_generation`)：电气化以发电机稳定供电为前提。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_4\_count\_8\_720d）

#### 效果摘要

解锁建筑：早期电气设备厂；解锁建筑：电气化包装厂；解锁建筑：电气印刷厂；解锁建筑：电弧炉炼钢厂；解锁物资：电气设备；全社会经济产出 +4%；商品「铜」生产投入 +5%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电气设备 (`electrical_equipment`)；包装材料 (`packaging`)；印刷品 (`printed_materials`)；钢材 (`steel`)
- **建筑 / 生产方式：** 早期电气设备厂 (`basic_electrical_equipment_works`)；电气化包装厂 (`method_packaging_plant_r7`)；电气印刷厂 (`method_printed_materials_plant_r7`)；电弧炉炼钢厂 (`steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **早期电气设备厂**（`building`）：`building.basic_electrical_equipment_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电气化包装厂**（`building`）：`building.method_packaging_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电气印刷厂**（`building`）：`building.method_printed_materials_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电弧炉炼钢厂**（`building`）：`building.steel_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电气设备**（`good`）：`good.electrical_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **包装材料**（`good`）：`good.packaging` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
- 铜：`country.input.good.copper_factor`：+5%
  - 效果机制：电气化提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：电气化扩大铜线需求。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 电化学 (`tech.electrochemistry`)：该科技需要先掌握 「电气化」。
- 无线电 (`tech.radio`)：电子管与发射机需要稳定的电力供应（真空管 ← 白炽灯、发电机）。
- 电网 (`tech.electric_grid`)：该科技需要先掌握 「电气化」。
- 电动机 (`tech.electric_motors`)：该科技需要先掌握 「电气化」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电化学 (`tech.electrochemistry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electrochemistry` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`)；制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 电气化 (`tech.electrification`)：该科技需要先掌握 「电气化」。
- 工业化学 (`tech.industrial_chemistry`)：该科技需要先掌握 「工业化学」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：电化工厂；解锁建筑：炼铅厂；解锁建筑：炼锌厂；解锁物资：铅；解锁物资：锌；「化学工业」生产家族建筑产出 +12%；作为必要支撑：电子元件厂

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 工业化学品 (`industrial_chemicals`)；铅 (`lead`)；锌 (`zinc`)
- **建筑 / 生产方式：** 电化工厂 (`electrochemical_works`)；炼铅厂 (`lead_plant`)；炼锌厂 (`zinc_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；自主控制系统厂 (`autonomous_systems_plant`)；电子元件厂 (`electronic_components_plant`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化电池厂 (`method_batteries_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)；通信设备厂 (`telecom_equipment_plant`)

#### 结构化内容效果

- **电化工厂**（`building`）：`building.electrochemical_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **炼铅厂**（`building`）：`building.lead_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **炼锌厂**（`building`）：`building.zinc_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铅**（`good`）：`good.lead` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锌**（`good`）：`good.zinc` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 化学工业：`country.output.family.chemical_industry_factor`：+12%
  - 效果机制：电化学提高化学工业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 合成材料 (`tech.synthetic_materials`)：该科技需要先掌握 「电化学」。
- 先进冶金 (`tech.advanced_metallurgy`)：电解精炼与合金成分控制来自电化学。
- 核裂变 (`tech.nuclear_fission`)：铀的提纯与分离依赖电化学工艺。

#### 主题路线后继

无

#### 跨领域应用

- 合成肥料 (`tech.synthetic_fertilizer`)：该知识参与形成 「合成肥料」。
- 石油化工 (`tech.petrochemical_industry`)：该知识参与形成 「石油化工」。

#### 作为候选参与的里程碑

无

### 无线电 (`tech.radio`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.radio` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1404000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 全部路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)：无线电基于电磁感应与电磁波理论。
- 电气化 (`tech.electrification`)：电子管与发射机需要稳定的电力供应（真空管 ← 白炽灯、发电机）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

科学领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+8%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 电信 (`tech.telecommunications`)：该科技需要先掌握 「无线电」。
- 电子控制 (`tech.electronic_control`)：电子控制以电子管/晶体管放大与反馈电路为核心。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电网 (`tech.electric_grid`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_grid` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 发电机 (`tech.electric_generation`)：该科技需要先掌握 「发电机」。
- 电气化 (`tech.electrification`)：该科技需要先掌握 「电气化」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 60%」（development.satisfaction.60\_720d）

#### 效果摘要

全社会经济产出 +8%；作为必要支撑：绝缘电缆厂、无线电设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 绝缘电缆厂 (`insulated_cable_plant`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；无线电设备厂 (`radio_equipment_works`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：电网提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 智能电网 (`tech.smart_grid`)：智能电网改造既有输配电网（智能电网 ← 电网、微处理器、互联网）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电信 (`tech.telecommunications`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.telecommunications` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 全部路线 | 制度 · 通信 (\`route.institution.communication\`)；制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 无线电 (`tech.radio`)：该科技需要先掌握 「无线电」。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 1250」（development.employment.energy.1250\_720d）

#### 效果摘要

科学领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+8%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 信息论 (`tech.information_theory`)：香农信息论直接研究电信信道容量。
- 网络计算 (`tech.networked_computing`)：计算机网络以电信线路为物理通道。
- 卫星观测 (`tech.satellite_observation`)：卫星观测依赖星地无线电遥测链路。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电动机 (`tech.electric_motors`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_motors` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)：该科技需要先掌握 「电磁感应」。
- 电气化 (`tech.electrification`)：该科技需要先掌握 「电气化」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 1250」（development.employment.manufacturing.1250\_720d）

#### 效果摘要

解锁建筑：电动机厂；解锁建筑：电气化造船厂；解锁物资：电动机；商品「煤」生产投入 -4%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电动机 (`electric_motor`)；远洋船舶 (`oceanic_vessels`)
- **建筑 / 生产方式：** 电动机厂 (`electric_motor_plant`)；电气化造船厂 (`method_oceanic_shipyard_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化电动机厂 (`method_electric_motor_plant_r10`)

#### 结构化内容效果

- **电动机厂**（`building`）：`building.electric_motor_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电气化造船厂**（`building`）：`building.method_oceanic_shipyard_r7` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电动机**（`good`）：`good.electric_motor` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 煤：`country.input.good.coal_factor`：+4%
  - 效果机制：电传动替代分散蒸汽煤耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 大规模生产 (`tech.mass_production`)：单机电动机驱动使流水线可以灵活布置（流水线 ← 输送带、发电机）。
- 机械化采矿 (`tech.mechanized_mining`)：截煤机、电铲与运输机由电动机驱动。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 大规模生产 (`tech.mass_production`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mass_production` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 流水线组织 (`tech.assembly_line`)：大规模生产以流水线组织为核心。
- 电动机 (`tech.electric_motors`)：单机电动机驱动使流水线可以灵活布置（流水线 ← 输送带、发电机）。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 60%」（development.satisfaction.60\_720d）

#### 效果摘要

解锁建筑：农业机械厂；解锁建筑：电力纺织厂；解锁建筑：高级家具厂；解锁建筑：玻璃器皿工厂；解锁建筑：工业机械厂；解锁建筑：皮革制品工厂；解锁建筑：机械零件厂；解锁建筑：工业屠宰场；解锁建筑：金属家用器皿工厂；解锁建筑：工业砖厂；解锁建筑：工业榨油厂；解锁建筑：工业石灰厂；解锁建筑：工业制皂厂；解锁建筑：铁路设备厂；解锁建筑：主食加工厂；解锁物资：农业机械；解锁物资：工业机械；解锁物资：机器零件；全社会家庭消费 +3%；「布匹织造」生产家族建筑产出 +12%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 农业机械 (`agricultural_machinery`)；砖块 (`bricks`)；布料 (`cloth`)；食用油 (`edible_oil`)；精美家具 (`fine_furniture`)；玻璃器皿 (`glassware`)；工业机械 (`industrial_machinery`)；皮革制品 (`leather_goods`)；石灰 (`lime`)；机器零件 (`machine_parts`)；肉类 (`meat`)；金属家用器皿 (`metal_housewares`)；熟制主食 (`prepared_staples`)；铁路设备 (`railway_equipment`)；生皮 (`raw_hide`)；肥皂 (`soap`)
- **建筑 / 生产方式：** 农业机械厂 (`agricultural_machinery_plant`)；电力纺织厂 (`cloth_plant`)；高级家具厂 (`fine_furniture_plant`)；玻璃器皿工厂 (`glassware_factory`)；工业机械厂 (`industrial_machinery_plant`)；皮革制品工厂 (`leather_goods_factory`)；机械零件厂 (`machine_parts_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；金属家用器皿工厂 (`metal_housewares_factory`)；工业砖厂 (`method_bricks_plant_r6`)；工业榨油厂 (`method_edible_oil_plant_r6`)；工业石灰厂 (`method_lime_plant_r6`)；工业制皂厂 (`method_soap_plant_r6`)；铁路设备厂 (`railway_equipment_plant`)；主食加工厂 (`staple_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **农业机械厂**（`building`）：`building.agricultural_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电力纺织厂**（`building`）：`building.cloth_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **高级家具厂**（`building`）：`building.fine_furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿工厂**（`building`）：`building.glassware_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业机械厂**（`building`）：`building.industrial_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品工厂**（`building`）：`building.leather_goods_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械零件厂**（`building`）：`building.machine_parts_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业屠宰场**（`building`）：`building.mechanized_slaughterhouse` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿工厂**（`building`）：`building.metal_housewares_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业砖厂**（`building`）：`building.method_bricks_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业榨油厂**（`building`）：`building.method_edible_oil_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业石灰厂**（`building`）：`building.method_lime_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业制皂厂**（`building`）：`building.method_soap_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铁路设备厂**（`building`）：`building.railway_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **主食加工厂**（`building`）：`building.staple_food_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **农业机械**（`good`）：`good.agricultural_machinery` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **砖块**（`good`）：`good.bricks` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **食用油**（`good`）：`good.edible_oil` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **精美家具**（`good`）：`good.fine_furniture` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿**（`good`）：`good.glassware` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **工业机械**（`good`）：`good.industrial_machinery` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品**（`good`）：`good.leather_goods` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石灰**（`good`）：`good.lime` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **机器零件**（`good`）：`good.machine_parts` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **肉类**（`good`）：`good.meat` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿**（`good`）：`good.metal_housewares` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **熟制主食**（`good`）：`good.prepared_staples` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铁路设备**（`good`）：`good.railway_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **肥皂**（`good`）：`good.soap` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会家庭消费：`country.household.consumption_factor`：+3%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+12%
  - 效果机制：廉价标准品诱发消费反弹。
  - 运行时消费者：`NativeEconomyRuntime::family_consumption_factor_q16`
  - 效果机制：大规模生产提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 消费信贷 (`tech.consumer_credit`)：分期付款面向大规模生产的耐用消费品（信用卡 1950）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 机动农业 (`tech.motorized_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.motorized_agriculture` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 机械收割 (`tech.mechanical_reaping`)：机动农业把机械收割机改由拖拉机牵引。
- 内燃机 (`tech.internal_combustion`)：拖拉机以内燃机为动力。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：机械化农场；解锁建筑：机械化棉花农场；解锁建筑：机械化亚麻农场；解锁建筑：机械化玉米农场；解锁建筑：机械化马铃薯农场；解锁建筑：机械化稻作农场；解锁建筑：机械化橡胶种植园；解锁建筑：机械化香料种植园；解锁建筑：机械化小麦农场；农业部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)；玉米 (`corn_grain`)；混合谷物 (`grain`)；天然乳胶 (`latex`)；马铃薯 (`potatoes`)；稻米 (`rice_grain`)；籽棉 (`seed_cotton`)；香料 (`spices`)；蔬菜 (`vegetables`)；小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)；机械化棉花农场 (`method_cotton_collector_r6`)；机械化亚麻农场 (`method_flax_collector_r6`)；机械化玉米农场 (`method_landed_estate_r6`)；机械化马铃薯农场 (`method_potato_collector_r6`)；机械化稻作农场 (`method_rice_collector_r6`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)；机械化小麦农场 (`method_wheat_farm_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化农场**（`building`）：`building.mechanized_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化棉花农场**（`building`）：`building.method_cotton_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化亚麻农场**（`building`）：`building.method_flax_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化玉米农场**（`building`）：`building.method_landed_estate_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化马铃薯农场**（`building`）：`building.method_potato_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化稻作农场**（`building`）：`building.method_rice_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化橡胶种植园**（`building`）：`building.method_rubber_tree_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化香料种植园**（`building`）：`building.method_spice_plants_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化小麦农场**（`building`）：`building.method_wheat_farm_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
  - 效果机制：机动农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业农学 (`tech.industrial_agronomy`)：工业农学以拖拉机化的农场为作业对象。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 现代畜牧 (`tech.modern_husbandry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.modern_husbandry` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 硬前置（决定研发资格）

- 畜种改良 (`tech.livestock_breeding`)：该科技需要先掌握 「畜种改良」。
- 农业改良 (`tech.agricultural_improvement`)：该科技需要先掌握 「农业改良」。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 10000」（development.output.energy.10000\_720d）

#### 效果摘要

解锁建筑：机械化牧场；牧业生产·寒冷损失 -14%；牧业生产·热害损失 -14%；「畜牧业」生产家族建筑产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 畜牧产品 (`livestock_products`)
- **建筑 / 生产方式：** 机械化牧场 (`ranching_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化牧场**（`building`）：`building.ranching_station` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **畜牧产品**（`good`）：`good.livestock_products` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 牧业生产·寒冷损失：`country.climate.profile.pasture_livestock.cold_stress_loss_factor`：+14%
- 牧业生产·热害损失：`country.climate.profile.pasture_livestock.heat_stress_loss_factor`：+14%
- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%
  - 效果机制：现代畜牧降低牧业生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：现代畜牧降低牧业生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：现代畜牧提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 公司管理 (`tech.corporate_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.corporate_management` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 管理层级 (`tech.managerial_hierarchy`)：公司管理建立在职业经理层级之上。
- 工业统计 (`tech.industrial_statistics`)：公司管理依靠产量与成本统计决策。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：酿造厂；解锁建筑：高级成衣厂；商品「衣物」产量 +4%；「布匹织造」生产家族建筑产出 +4%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 酒饮 (`beverages`)；华服 (`fine_clothing`)
- **建筑 / 生产方式：** 酿造厂 (`beverages_plant`)；高级成衣厂 (`fine_clothing_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **酿造厂**（`building`）：`building.beverages_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **高级成衣厂**（`building`）：`building.fine_clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **酒饮**（`good`）：`good.beverages` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **华服**（`good`）：`good.fine_clothing` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 衣物：`country.output.good.clothing_factor`：+4%
- 布匹织造：`country.output.family.cloth_weaving_factor`：+4%
  - 效果机制：公司管理提高衣物产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：公司管理提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 中央银行体系 (`tech.central_banking`)：统一清算依赖现代公司的账务与报表制度（中央银行体系 1913）。
- 公司农业 (`tech.corporate_agribusiness`)：该科技需要先掌握 「公司管理」。
- 国营企业 (`tech.state_enterprises`)：国营企业沿用现代公司的管理结构。

#### 主题路线后继

- 算法管理 (`tech.algorithmic_management`)：该知识继续发展为 「算法管理」。

#### 跨领域应用

- 运筹学 (`tech.operations_research`)：该知识参与形成 「运筹学」。

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 工业研究 (`tech.industrial_research`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_research` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：该科技需要先掌握 「实验科学」。
- 公共教育 (`tech.public_education`)：该科技需要先掌握 「公共教育」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 4 类」（development.trade.goods\_4）

#### 效果摘要

解锁建筑：科学仪器工坊；解锁物资：科学仪器；全社会经济产出 +6%；作为必要支撑：精密仪器厂

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科学仪器 (`scientific_instruments`)
- **建筑 / 生产方式：** 科学仪器工坊 (`scientific_instrument_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 精密仪器厂 (`method_scientific_instrument_works_r8`)

#### 结构化内容效果

- **科学仪器工坊**（`building`）：`building.scientific_instrument_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科学仪器**（`good`）：`good.scientific_instruments` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：工业研究提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 工业质量控制 (`tech.industrial_quality_control`)：该科技需要先掌握 「工业研究」。
- 核裂变 (`tech.nuclear_fission`)：核裂变的发现来自工业研究体系支撑的原子物理实验。
- 国家实验室 (`tech.national_laboratories`)：国家实验室把工业研究体系提升为国家级大科学。
- 分子生物学 (`tech.molecular_biology`)：X 射线衍射等大型实验依赖工业研究体系（DNA 双螺旋 1953）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 石油钻探 (`tech.petroleum_drilling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_drilling` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 石油开采 (`tech.petroleum_extraction`)：该科技需要先掌握 「石油开采」。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_4\_count\_8\_720d）

#### 效果摘要

解锁建筑：油田；解锁建筑：燃油发电厂；解锁物资：电力；oil -10%；「石油采掘」生产家族建筑产出 +12%；作为必要支撑：蒸汽钻井场

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原油 (`crude_oil`)；电力 (`electricity`)
- **建筑 / 生产方式：** 油田 (`oil_collector`)；燃油发电厂 (`oil_power_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)

#### 结构化内容效果

- **油田**（`building`）：`building.oil_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **燃油发电厂**（`building`）：`building.oil_power_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原油**（`good`）：`good.crude_oil` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **电力**（`good`）：`good.electricity` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- oil：`country.resource.oil.use_factor`：+10%
- 石油采掘：`country.output.family.oil_extraction_factor`：+12%
  - 效果机制：井控提高可采原油比例。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：石油钻探提高石油采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业质量控制 (`tech.industrial_quality_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_quality_control` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 工业统计 (`tech.industrial_statistics`)：该科技需要先掌握 「工业统计」。
- 工业研究 (`tech.industrial_research`)：该科技需要先掌握 「工业研究」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：珠宝厂；全社会生产投入 -4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 珠宝 (`jewelry`)
- **建筑 / 生产方式：** 珠宝厂 (`jewelry_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **珠宝厂**（`building`）：`building.jewelry_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **珠宝**（`good`）：`good.jewelry` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+4%
  - 效果机制：过程检验减少废品。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

- 运筹学 (`tech.operations_research`)：运筹学由工业质量控制中的统计优化发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械制冷 (`tech.refrigeration`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.refrigeration` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 热力学 (`tech.thermodynamics`)：该科技需要先掌握 「热力学」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 60%」（development.satisfaction.60\_720d）

#### 效果摘要

全社会经济产出 +8%；商品「肉类」家庭消费 -8%；牧业生产·热害损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
- 肉类：`country.consumption.good.meat_factor`：+8%
- 牧业生产·热害损失：`country.climate.profile.pasture_livestock.heat_stress_loss_factor`：+8%
  - 效果机制：机械制冷提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：冷藏减少家庭肉类腐败。
  - 运行时消费者：`NativeEconomyRuntime::effective_household_good_quantity`
  - 效果机制：机械制冷降低牧业生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 冷链 (`tech.cold_chain`)：冷链以机械制冷为核心设备。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 冷链 (`tech.cold_chain`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cold_chain` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 机械制冷 (`tech.refrigeration`)：冷链以机械制冷为核心设备。
- 铁路物流 (`tech.rail_logistics`)：冷藏车厢把冷库连成运输链（冷链 ← 制冷技术、冷藏车厢）。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 1250」（development.employment.energy.1250\_720d）

#### 效果摘要

解锁建筑：乳制品厂；解锁建筑：综合食品厂；解锁物资：加工食品；商品「鱼」家庭消费 -10%；商品「肉类」家庭消费 -10%；「畜牧业」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 乳制品 (`dairy_products`)；加工食品 (`processed_food`)
- **建筑 / 生产方式：** 乳制品厂 (`dairy_products_plant`)；综合食品厂 (`processed_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **乳制品厂**（`building`）：`building.dairy_products_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **综合食品厂**（`building`）：`building.processed_food_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **乳制品**（`good`）：`good.dairy_products` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **加工食品**（`good`）：`good.processed_food` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 鱼：`country.consumption.good.fish_factor`：+10%
- 肉类：`country.consumption.good.meat_factor`：+10%
- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
  - 效果机制：冷链减少鱼类运输和家庭损耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_household_good_quantity`
  - 效果机制：冷链减少肉类运输和家庭损耗。
  - 运行时消费者：`NativeEconomyRuntime::effective_household_good_quantity`
  - 效果机制：冷链提高畜牧业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 中央银行体系 (`tech.central_banking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.central_banking` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 交流 (\`route.trade.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 有限责任公司 (`tech.limited_liability`)：中央银行监管的是由股份公司组成的银行体系。
- 公司管理 (`tech.corporate_management`)：统一清算依赖现代公司的账务与报表制度（中央银行体系 1913）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会贸易运输速度 +6%

#### 机会成本

占用社会研究预算，推迟电气工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会贸易运输速度：`country.trade.speed_factor`：+6%
  - 效果机制：统一清算与最后贷款人减少了结算延误与挤兑。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

- 消费信贷 (`tech.consumer_credit`)：消费信贷依托中央银行管理下的银行信用。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 遗传学 (`tech.genetics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.genetics` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；工艺 · 实验 (\`route.craft.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | science |

#### 硬前置（决定研发资格）

- 微生物学 (`tech.microbiology`)：遗传学沿用微生物学的显微与细胞观察方法。
- 系统育种 (`tech.crop_breeding`)：孟德尔定律的再发现直接服务于系统育种（1900）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

农业部门产出 +6%

#### 机会成本

占用科学研究预算，推迟电气工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+6%
  - 效果机制：按遗传规律选配亲本提高了作物与牲畜的产量。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 分子生物学 (`tech.molecular_biology`)：分子生物学寻找遗传因子的化学实体。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气社会 (`tech.electrical_society`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electrical_society` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1800000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | branch |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 15 项候选中的任意 6 项：
- 机动农业 (`tech.motorized_agriculture`)
- 电气化 (`tech.electrification`)
- 工业研究 (`tech.industrial_research`)
- 公共教育 (`tech.public_education`)
- 现代畜牧 (`tech.modern_husbandry`)
- 电网 (`tech.electric_grid`)
- 现代医学 (`tech.modern_medicine`)
- 公司管理 (`tech.corporate_management`)
- 大规模生产 (`tech.mass_production`)
- 发电机 (`tech.electric_generation`)
- 电动机 (`tech.electric_motors`)
- 电信 (`tech.telecommunications`)
- 电磁感应 (`tech.electromagnetic_induction`)
- 石油开采 (`tech.petroleum_extraction`)
- 机械制冷 (`tech.refrigeration`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期电气设备厂 (`app.basic_electrical_equipment_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.basic_electrical_equipment_works` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电气化 (`tech.electrification`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期电气设备厂 (`basic_electrical_equipment_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气化包装厂 (`app.method_packaging_plant_r7`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_packaging_plant_r7` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电气化 (`tech.electrification`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化包装厂 (`method_packaging_plant_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气印刷厂 (`app.method_printed_materials_plant_r7`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_printed_materials_plant_r7` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电气化 (`tech.electrification`)：该知识是此产业交汇自动生效的必要条件。
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气印刷厂 (`method_printed_materials_plant_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电弧炉炼钢厂 (`app.steel_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.steel_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电气化 (`tech.electrification`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电弧炉炼钢厂 (`steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 炼铅厂 (`app.lead_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.lead_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 炼铅厂 (`lead_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 炼锌厂 (`app.zinc_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.zinc_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 炼锌厂 (`zinc_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 高级家具厂 (`app.fine_furniture_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.fine_furniture_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 行会学徒制 (`tech.guild_apprenticeship`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高级家具厂 (`fine_furniture_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 玻璃器皿工厂 (`app.glassware_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.glassware_factory` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玻璃器皿工厂 (`glassware_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 皮革制品工厂 (`app.leather_goods_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.leather_goods_factory` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 皮革鞣制 (`tech.hide_tanning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 皮革制品工厂 (`leather_goods_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械零件厂 (`app.machine_parts_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.machine_parts_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械零件厂 (`machine_parts_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业屠宰场 (`app.mechanized_slaughterhouse`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.mechanized_slaughterhouse` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 屠宰分割 (`tech.meat_processing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业屠宰场 (`mechanized_slaughterhouse`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 金属家用器皿工厂 (`app.metal_housewares_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.metal_housewares_factory` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 块炼铁 (`tech.iron_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金属家用器皿工厂 (`metal_housewares_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业榨油厂 (`app.method_edible_oil_plant_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_edible_oil_plant_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 轮作 (`tech.crop_rotation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业榨油厂 (`method_edible_oil_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业石灰厂 (`app.method_lime_plant_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_lime_plant_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 运河工程 (`tech.canal_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业石灰厂 (`method_lime_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业制皂厂 (`app.method_soap_plant_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_soap_plant_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 盐渍保存 (`tech.salt_preservation`)：该知识是此产业交汇自动生效的必要条件。
- 城市卫生 (`tech.urban_sanitation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业制皂厂 (`method_soap_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铁路设备厂 (`app.railway_equipment_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.railway_equipment_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 铁路物流 (`tech.rail_logistics`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铁路设备厂 (`railway_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 主食加工厂 (`app.staple_food_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.staple_food_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 大规模生产 (`tech.mass_production`)：该知识是此产业交汇自动生效的必要条件。
- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 主食加工厂 (`staple_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 蒸汽钻井场 (`app.early_oil_well`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.early_oil_well` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 石油开采 (`tech.petroleum_extraction`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。
- 石油钻探 (`tech.petroleum_drilling`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 乳制品厂 (`app.dairy_products_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.dairy_products_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 冷链 (`tech.cold_chain`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。
- 乳品加工 (`tech.dairy_processing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 乳制品厂 (`dairy_products_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 综合食品厂 (`app.processed_food_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.processed_food_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 冷链 (`tech.cold_chain`)：该知识是此产业交汇自动生效的必要条件。
- 家庭土地占有 (`tech.household_landholding`)：该知识是此产业交汇自动生效的必要条件。
- 轮作 (`tech.crop_rotation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 综合食品厂 (`processed_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 受控环境药材农场 (`app.method_medicinal_herbs_collector_r7`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_medicinal_herbs_collector_r7` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 现代医学 (`tech.modern_medicine`)：该知识是此产业交汇自动生效的必要条件。
- 种子与繁育观察 (`tech.crop_domestication`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 受控环境药材农场 (`method_medicinal_herbs_collector_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 制药厂 (`app.pharmaceuticals_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.pharmaceuticals_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 现代医学 (`tech.modern_medicine`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制药厂 (`pharmaceuticals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 线材厂 (`app.wire_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.wire_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电磁感应 (`tech.electromagnetic_induction`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 线材厂 (`wire_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电动机厂 (`app.electric_motor_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.electric_motor_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电动机 (`tech.electric_motors`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电动机厂 (`electric_motor_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气化造船厂 (`app.method_oceanic_shipyard_r7`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_oceanic_shipyard_r7` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电动机 (`tech.electric_motors`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 手工纺纱 (`tech.hand_spinning`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化造船厂 (`method_oceanic_shipyard_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化农场 (`app.mechanized_farm`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.mechanized_farm` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化棉花农场 (`app.method_cotton_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_cotton_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 野生棉铃采集 (`tech.wild_cotton_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化棉花农场 (`method_cotton_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化亚麻农场 (`app.method_flax_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_flax_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化亚麻农场 (`method_flax_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化玉米农场 (`app.method_landed_estate_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_landed_estate_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化玉米农场 (`method_landed_estate_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化马铃薯农场 (`app.method_potato_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_potato_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 块茎繁育 (`tech.potato_propagation`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化马铃薯农场 (`method_potato_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化稻作农场 (`app.method_rice_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rice_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 芦苇收割 (`tech.reed_harvesting`)：该知识是此产业交汇自动生效的必要条件。
- 野生稻采集 (`tech.wild_rice_collection`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化稻作农场 (`method_rice_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化橡胶种植园 (`app.method_rubber_tree_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rubber_tree_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 野生割胶 (`tech.wild_latex_tapping`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化橡胶种植园 (`method_rubber_tree_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化香料种植园 (`app.method_spice_plants_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_spice_plants_collector_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 野生香料采集 (`tech.wild_spice_collection`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化香料种植园 (`method_spice_plants_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化小麦农场 (`app.method_wheat_farm_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wheat_farm_r6` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机动农业 (`tech.motorized_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 野生谷穗采集 (`tech.wild_wheat_collection`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化小麦农场 (`method_wheat_farm_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 酿造厂 (`app.beverages_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.beverages_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 公司管理 (`tech.corporate_management`)：该知识是此产业交汇自动生效的必要条件。
- 野生玉米采集 (`tech.wild_maize_collection`)：该知识是此产业交汇自动生效的必要条件。
- 发酵保存 (`tech.fermentation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 酿造厂 (`beverages_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 高级成衣厂 (`app.fine_clothing_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.fine_clothing_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 公司管理 (`tech.corporate_management`)：该知识是此产业交汇自动生效的必要条件。
- 行会学徒制 (`tech.guild_apprenticeship`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高级成衣厂 (`fine_clothing_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 科学仪器工坊 (`app.scientific_instrument_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.scientific_instrument_works` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业研究 (`tech.industrial_research`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 科学仪器工坊 (`scientific_instrument_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 珠宝厂 (`app.jewelry_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.jewelry_plant` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业质量控制 (`tech.industrial_quality_control`)：该知识是此产业交汇自动生效的必要条件。
- 粗陶淘金 (`tech.gold_panning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 珠宝厂 (`jewelry_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-9"></a>
## 原子时代

共 26 项研究科技、23 项自动应用，科技研究成本范围 2400000-4000000；时代里程碑：原子现代化 (`tech.atomic_modernity`)。

### 合成材料 (`tech.synthetic_materials`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.synthetic_materials` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油炼制 (`tech.petroleum_refining`)：该科技需要先掌握 「石油炼制」。
- 电化学 (`tech.electrochemistry`)：该科技需要先掌握 「电化学」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100000」（development.output.manufacturing.100000\_1095d）

#### 效果摘要

解锁建筑：建筑构件厂；解锁建筑：合成橡胶厂；解锁物资：合成橡胶；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 建筑构件 (`construction_components`)；合成橡胶 (`synthetic_rubber`)
- **建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)；合成橡胶厂 (`synthetic_rubber_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)

#### 结构化内容效果

- **建筑构件厂**（`building`）：`building.construction_components_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **合成橡胶厂**（`building`）：`building.synthetic_rubber_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **建筑构件**（`good`）：`good.construction_components` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **合成橡胶**（`good`）：`good.synthetic_rubber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：合成材料提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：尼龙、涤纶是高分子合成材料（尼龙 1935）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业农学 (`tech.industrial_agronomy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_agronomy` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 机动农业 (`tech.motorized_agriculture`)：工业农学以拖拉机化的农场为作业对象。
- 合成肥料 (`tech.synthetic_fertilizer`)：化肥投入是工业农学增产的核心。
- 系统育种 (`tech.crop_breeding`)：高产品种来自系统育种（绿色革命 ← 矮秆品种、合成氨）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：电气化集约农场；农业部门产出 +8%；旱作生产·旱灾损失 -8%；旱作生产·热害损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 混合谷物 (`grain`)；蔬菜 (`vegetables`)
- **建筑 / 生产方式：** 电气化集约农场 (`intensive_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电气化集约农场**（`building`）：`building.intensive_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+8%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+8%
  - 效果机制：工业农学提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：工业农学降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：工业农学降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 集体农业 (`tech.collective_agriculture`)：该科技需要先掌握 「工业农学」。
- 精准农业 (`tech.precision_agriculture`)：该科技需要先掌握 「工业农学」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 先进冶金 (`tech.advanced_metallurgy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.advanced_metallurgy` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 全部路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 焦炭冶炼 (`tech.coke_smelting`)：先进冶金建立在大规模钢铁冶炼之上。
- 电化学 (`tech.electrochemistry`)：电解精炼与合金成分控制来自电化学。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 100000」（development.output.energy.100000\_1095d）

#### 效果摘要

解锁建筑：电池厂；解锁建筑：炼铜厂；解锁建筑：炼锡厂；解锁物资：电池；「铜矿采掘」生产家族建筑产出 +12%；「锡矿采掘」生产家族建筑产出 +12%；作为必要支撑：汽车厂、通信设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电池 (`batteries`)；铜 (`copper`)；锡 (`tin`)
- **建筑 / 生产方式：** 电池厂 (`batteries_plant`)；炼铜厂 (`copper_plant`)；炼锡厂 (`tin_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；自主控制系统厂 (`autonomous_systems_plant`)；智能化汽车厂 (`method_automobiles_plant_r10`)；通信设备厂 (`telecom_equipment_plant`)

#### 结构化内容效果

- **电池厂**（`building`）：`building.batteries_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **炼铜厂**（`building`）：`building.copper_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **炼锡厂**（`building`）：`building.tin_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电池**（`good`）：`good.batteries` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铜**（`good`）：`good.copper` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锡**（`good`）：`good.tin` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铜矿采掘：`country.output.family.copper_extraction_factor`：+12%
- 锡矿采掘：`country.output.family.tin_extraction_factor`：+12%
  - 效果机制：先进冶金提高铜矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：先进冶金提高锡矿采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 特种合金 (`tech.specialty_alloys`)：该科技需要先掌握 「先进冶金」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 核裂变 (`tech.nuclear_fission`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.nuclear_fission` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工业研究 (`tech.industrial_research`)：核裂变的发现来自工业研究体系支撑的原子物理实验。
- 电化学 (`tech.electrochemistry`)：铀的提纯与分离依赖电化学工艺。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 8 类」（development.trade.goods\_8）

#### 效果摘要

解锁建筑：核医学制药中心；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药品 (`pharmaceuticals`)
- **建筑 / 生产方式：** 核医学制药中心 (`nuclear_medicine_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)

#### 结构化内容效果

- **核医学制药中心**（`building`）：`building.nuclear_medicine_center` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **药品**（`good`）：`good.pharmaceuticals` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：核裂变提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 国家实验室 (`tech.national_laboratories`)：国家实验室最初围绕核物理与核工程建立。
- 核能 (`tech.nuclear_energy`)：核能利用可控链式裂变。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 深层地球物理 (`tech.deep_geophysics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deep_geophysics` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地质勘探 (`tech.geological_prospecting`)：深层地球物理延伸地质勘探的地下探测。
- 电磁感应 (`tech.electromagnetic_induction`)：电法与磁法勘探以电磁感应为原理。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 312500」（development.population.312500\_1095d）

#### 效果摘要

解锁建筑：铝土矿；解锁建筑：战略矿山；解锁物资：铝土矿；解锁物资：战略矿石；可利用资源：铝土矿；可利用资源：锰矿；可利用资源：稀土；采掘部门产出 +18%；作为必要支撑：电解铝厂、锰矿、战略金属冶炼厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝土矿 (`bauxite`)；战略矿石 (`rare_earth_ore`)
- **建筑 / 生产方式：** 铝土矿 (`bauxite_collector`)；战略矿山 (`rare_earth_collector`)
- **自然资源：** 稀土 (`rare_earth`)；铝土矿 (`bauxite`)；锰矿 (`manganese_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电解铝厂 (`aluminum_plant`)；锰矿 (`manganese_ore_collector`)；智能冶铝厂 (`method_aluminum_plant_r10`)；智能锰矿 (`method_manganese_ore_collector_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；战略金属冶炼厂 (`rare_earth_metals_plant`)

#### 结构化内容效果

- **铝土矿**（`building`）：`building.bauxite_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **战略矿山**（`building`）：`building.rare_earth_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铝土矿**（`good`）：`good.bauxite` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铝土矿**（`resource`）：`resource.bauxite` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锰矿**（`resource`）：`resource.manganese_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **稀土**（`resource`）：`resource.rare_earth` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+18%
  - 效果机制：深层地球物理提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：矿物光谱判读需要地球物理的成矿认识。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 运筹学 (`tech.operations_research`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.operations_research` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工业质量控制 (`tech.industrial_quality_control`)：运筹学由工业质量控制中的统计优化发展而来。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 5」（development.settlement.tier\_5\_1095d）

#### 效果摘要

社会领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 社会领域研究效率：`country.research.society_efficiency`：+8%
  - 效果机制：制度记录与组织经验提高社会领域研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 系统工程 (`tech.systems_engineering`)：系统工程由运筹学的整体优化方法发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 石油化工 (`tech.petrochemical_industry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petrochemical_industry` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油炼制 (`tech.petroleum_refining`)：石油化工以炼厂馏分为原料。
- 工业化学 (`tech.industrial_chemistry`)：裂解、合成等单元操作来自工业化学。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：洗涤剂厂；解锁建筑：现代炸药厂；解锁建筑：石油化工厂；解锁物资：洗涤剂；解锁物资：石化产品；「石油采掘」生产家族建筑产出 +12%；「化学工业」生产家族建筑产出 +12%；作为必要支撑：合成纤维厂、合成橡胶厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 洗涤剂 (`detergent`)；炸药 (`explosives`)；石化产品 (`petrochemicals`)
- **建筑 / 生产方式：** 洗涤剂厂 (`detergent_plant`)；现代炸药厂 (`method_explosives_plant_r8`)；石油化工厂 (`petrochemicals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)；合成纤维厂 (`synthetic_fiber_plant`)；合成橡胶厂 (`synthetic_rubber_plant`)

#### 结构化内容效果

- **洗涤剂厂**（`building`）：`building.detergent_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **现代炸药厂**（`building`）：`building.method_explosives_plant_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石油化工厂**（`building`）：`building.petrochemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **洗涤剂**（`good`）：`good.detergent` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **炸药**（`good`）：`good.explosives` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石化产品**（`good`）：`good.petrochemicals` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 石油采掘：`country.output.family.oil_extraction_factor`：+12%
- 化学工业：`country.output.family.chemical_industry_factor`：+12%
  - 效果机制：石油化工提高石油采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：石油化工提高化学工业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 石化裂解 (`tech.petrochemical_cracking`)：该科技需要先掌握 「石油化工」。
- 塑料工程 (`tech.plastics_engineering`)：该科技需要先掌握 「石油化工」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 国家实验室 (`tech.national_laboratories`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.national_laboratories` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 全部路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工业研究 (`tech.industrial_research`)：国家实验室把工业研究体系提升为国家级大科学。
- 核裂变 (`tech.nuclear_fission`)：国家实验室最初围绕核物理与核工程建立。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 4 个」（development.trade.partners\_4）

#### 效果摘要

解锁建筑：国家实验室；「研究机构」生产家族建筑产出 +7%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 国家实验室 (`national_laboratory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **国家实验室**（`building`）：`building.national_laboratory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 研究机构：`country.output.family.research_institution_factor`：+7%
  - 效果机制：国家实验室提高研究机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 核燃料循环 (`tech.nuclear_fuel_cycle`)：该科技需要先掌握 「国家实验室」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 机械化采矿 (`tech.mechanized_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanized_mining` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 工业采煤 (`tech.industrial_coal_mining`)：机械化采矿承接工业采煤的深井体系。
- 电动机 (`tech.electric_motors`)：截煤机、电铲与运输机由电动机驱动。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 1250」（development.employment.knowledge.1250\_720d）

#### 效果摘要

解锁建筑：锰矿；解锁物资：锰矿石；铁矿石 -10%；煤 -10%；采掘部门产出 +18%；作为必要支撑：不锈钢厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锰矿石 (`manganese_ore`)
- **建筑 / 生产方式：** 锰矿 (`manganese_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；不锈钢厂 (`stainless_steel_plant`)

#### 结构化内容效果

- **锰矿**（`building`）：`building.manganese_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **锰矿石**（`good`）：`good.manganese_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿石：`country.resource.iron_ore.use_factor`：+10%
- 煤：`country.resource.coal.use_factor`：+10%
- 采掘部门产出：`country.output.extractive_factor`：+18%
  - 效果机制：机械采矿提高铁矿回采。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：机械采矿提高煤层回采。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：机械化采矿提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自主采矿 (`tech.autonomous_mining`)：自主采矿是机械化矿山的无人化。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 公共卫生体系 (`tech.public_health_systems`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_health_systems` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.public\_health |
| 主要路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 全部路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 现代医学 (`tech.modern_medicine`)：该科技需要先掌握 「现代医学」。
- 公共教育 (`tech.public_education`)：该科技需要先掌握 「公共教育」。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100000」（development.output.manufacturing.100000\_1095d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：公共卫生体系提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 核能 (`tech.nuclear_energy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.nuclear_energy` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 核裂变 (`tech.nuclear_fission`)：核能利用可控链式裂变。
- 发电机 (`tech.electric_generation`)：核电站以汽轮发电机组输出电力。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 100000」（development.output.knowledge.100000\_1095d）

#### 效果摘要

解锁建筑：核电站；解锁建筑：核反应堆设备厂；解锁物资：反应堆部件；商品「电力」产量 +10%；能源部门产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电力 (`electricity`)；反应堆部件 (`reactor_components`)
- **建筑 / 生产方式：** 核电站 (`nuclear_power_plant`)；核反应堆设备厂 (`reactor_component_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化核反应堆设备厂 (`method_reactor_component_works_r10`)

#### 结构化内容效果

- **核电站**（`building`）：`building.nuclear_power_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **核反应堆设备厂**（`building`）：`building.reactor_component_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电力**（`good`）：`good.electricity` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **反应堆部件**（`good`）：`good.reactor_components` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 电力：`country.output.good.electricity_factor`：+10%
- 能源部门产出：`country.output.energy_factor`：+10%
  - 效果机制：核能提高电力产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：核能提高能源部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 电子控制 (`tech.electronic_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electronic_control` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 无线电 (`tech.radio`)：电子控制以电子管/晶体管放大与反馈电路为核心。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 8 类」（development.trade.goods\_8）

#### 效果摘要

解锁建筑：电气设备厂；解锁建筑：电子元件厂；解锁建筑：精密工具厂；解锁建筑：精密仪器厂；解锁建筑：无线电设备厂；解锁物资：电子元件；解锁物资：无线电设备；全社会经济产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 电气设备 (`electrical_equipment`)；电子元件 (`electronic_components`)；精密工具 (`precision_tools`)；无线电设备 (`radio_equipment`)；科学仪器 (`scientific_instruments`)
- **建筑 / 生产方式：** 电气设备厂 (`electrical_equipment_plant`)；电子元件厂 (`electronic_components_plant`)；精密工具厂 (`method_precision_tool_workshop_r8`)；精密仪器厂 (`method_scientific_instrument_works_r8`)；无线电设备厂 (`radio_equipment_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电气设备厂**（`building`）：`building.electrical_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电子元件厂**（`building`）：`building.electronic_components_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精密工具厂**（`building`）：`building.method_precision_tool_workshop_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精密仪器厂**（`building`）：`building.method_scientific_instrument_works_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **无线电设备厂**（`building`）：`building.radio_equipment_works` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电气设备**（`good`）：`good.electrical_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **电子元件**（`good`）：`good.electronic_components` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **精密工具**（`good`）：`good.precision_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **无线电设备**（`good`）：`good.radio_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **科学仪器**（`good`）：`good.scientific_instruments` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：电子控制提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 系统工程 (`tech.systems_engineering`)：大型系统依赖电子控制与反馈。
- 精准农业 (`tech.precision_agriculture`)：该科技需要先掌握 「电子控制」。
- 数字计算 (`tech.digital_computing`)：该科技需要先掌握 「电子控制」。
- 传感器网络 (`tech.sensor_networks`)：传感器网络由电子控制的测量回路组成。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 全球物流 (`tech.global_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.global_logistics` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 铁路物流 (`tech.rail_logistics`)：全球物流把铁路与港口联运组织起来。
- 内燃机 (`tech.internal_combustion`)：卡车与柴油船使集装箱联运成为可能（集装箱运输 1956）。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 4 个」（development.trade.partners\_4）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：全球物流提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 公司农业 (`tech.corporate_agribusiness`)：该科技需要先掌握 「全球物流」。
- 自动化物流 (`tech.automated_logistics`)：自动化物流升级既有的全球联运网络。

#### 主题路线后继

无

#### 跨领域应用

- 数字市场 (`tech.digital_marketplaces`)：该知识参与形成 「数字市场」。

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 特种合金 (`tech.specialty_alloys`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.specialty_alloys` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 全部路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 先进冶金 (`tech.advanced_metallurgy`)：该科技需要先掌握 「先进冶金」。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 312500」（development.population.312500\_1095d）

#### 效果摘要

解锁建筑：电解铝厂；解锁建筑：战略金属冶炼厂；解锁建筑：不锈钢厂；解锁物资：铝；解锁物资：战略矿物材料；解锁物资：不锈钢；「炼钢」生产家族建筑产出 +28%；作为必要支撑：发动机厂、核反应堆设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝 (`aluminum`)；战略矿物材料 (`rare_earth_metals`)；不锈钢 (`stainless_steel`)
- **建筑 / 生产方式：** 电解铝厂 (`aluminum_plant`)；战略金属冶炼厂 (`rare_earth_metals_plant`)；不锈钢厂 (`stainless_steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；发动机厂 (`engines_plant`)；智能冶铝厂 (`method_aluminum_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；核反应堆设备厂 (`reactor_component_works`)

#### 结构化内容效果

- **电解铝厂**（`building`）：`building.aluminum_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **战略金属冶炼厂**（`building`）：`building.rare_earth_metals_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **不锈钢厂**（`building`）：`building.stainless_steel_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铝**（`good`）：`good.aluminum` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **不锈钢**（`good`）：`good.stainless_steel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 炼钢：`country.output.family.steelmaking_factor`：+28%
  - 效果机制：特种合金提高炼钢建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 核燃料循环 (`tech.nuclear_fuel_cycle`)：该科技需要先掌握 「特种合金」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 石化裂解 (`tech.petrochemical_cracking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petrochemical_cracking` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油化工 (`tech.petrochemical_industry`)：该科技需要先掌握 「石油化工」。

#### 发现启发（仅用于揭示）

- 已发现信号「聚落等级 5」（development.settlement.tier\_5\_1095d）

#### 效果摘要

解锁建筑：燃气发电厂；解锁建筑：天然气田；解锁物资：天然气；可利用资源：天然气；全社会经济产出 +8%；商品「原油」生产投入 +6%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电力 (`electricity`)；天然气 (`natural_gas`)
- **建筑 / 生产方式：** 燃气发电厂 (`gas_power_plant`)；天然气田 (`natural_gas_collector`)
- **自然资源：** 天然气 (`natural_gas`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能天然气田 (`method_natural_gas_collector_r10`)

#### 结构化内容效果

- **燃气发电厂**（`building`）：`building.gas_power_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **天然气田**（`building`）：`building.natural_gas_collector` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电力**（`good`）：`good.electricity` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然气**（`good`）：`good.natural_gas` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然气**（`resource`）：`resource.natural_gas` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
- 原油：`country.input.good.crude_oil_factor`：+6%
  - 效果机制：石化裂解提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：高吞吐裂解扩大原油需求。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 塑料工程 (`tech.plastics_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plastics_engineering` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油化工 (`tech.petrochemical_industry`)：该科技需要先掌握 「石油化工」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 1250」（development.employment.knowledge.1250\_720d）

#### 效果摘要

解锁建筑：家用电器厂；解锁建筑：绝缘电缆厂；解锁建筑：塑料厂；解锁物资：家用电器；解锁物资：绝缘电缆；解锁物资：塑料；全社会经济产出 +8%；作为必要支撑：计算机厂、电气设备厂、电子元件厂、无线电设备厂、通信设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 家用电器 (`household_appliances`)；绝缘电缆 (`insulated_cable`)；塑料 (`plastics`)
- **建筑 / 生产方式：** 家用电器厂 (`household_appliances_plant`)；绝缘电缆厂 (`insulated_cable_plant`)；塑料厂 (`plastics_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 计算机厂 (`computers_plant`)；电气设备厂 (`electrical_equipment_plant`)；电子元件厂 (`electronic_components_plant`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；无线电设备厂 (`radio_equipment_works`)；通信设备厂 (`telecom_equipment_plant`)

#### 结构化内容效果

- **家用电器厂**（`building`）：`building.household_appliances_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **绝缘电缆厂**（`building`）：`building.insulated_cable_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **塑料厂**（`building`）：`building.plastics_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **家用电器**（`good`）：`good.household_appliances` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **塑料**（`good`）：`good.plastics` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：塑料工程提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公司农业 (`tech.corporate_agribusiness`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.corporate_agribusiness` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 全球物流 (`tech.global_logistics`)：该科技需要先掌握 「全球物流」。
- 公司管理 (`tech.corporate_management`)：该科技需要先掌握 「公司管理」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 100000」（development.output.agriculture.100000\_1095d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：公司农业提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 国营企业 (`tech.state_enterprises`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.state_enterprises` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 公司管理 (`tech.corporate_management`)：国营企业沿用现代公司的管理结构。
- 官僚行政 (`tech.state_bureaucracy`)：国营企业由国家行政直接出资与任命。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 1250」（development.employment.knowledge.1250\_720d）

#### 效果摘要

解锁建筑：现代硝石矿；解锁建筑：现代硫矿；采掘部门产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 硝石 (`saltpeter`)；硫磺 (`sulfur`)
- **建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)；现代硫矿 (`method_sulfur_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **现代硝石矿**（`building`）：`building.method_saltpeter_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **现代硫矿**（`building`）：`building.method_sulfur_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **硝石**（`good`）：`good.saltpeter` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硫磺**（`good`）：`good.sulfur` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+8%
  - 效果机制：国营企业提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 集体农业 (`tech.collective_agriculture`)：该科技需要先掌握 「国营企业」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 集体农业 (`tech.collective_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.collective_agriculture` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`)；制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 国营企业 (`tech.state_enterprises`)：该科技需要先掌握 「国营企业」。
- 工业农学 (`tech.industrial_agronomy`)：该科技需要先掌握 「工业农学」。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 1250」（development.employment.agriculture.1250\_720d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：集体农业提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 核燃料循环 (`tech.nuclear_fuel_cycle`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.nuclear_fuel_cycle` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 国家实验室 (`tech.national_laboratories`)：该科技需要先掌握 「国家实验室」。
- 特种合金 (`tech.specialty_alloys`)：该科技需要先掌握 「特种合金」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：核燃料厂；解锁物资：核燃料；全社会经济产出 +8%；作为必要支撑：核反应堆设备厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 核燃料 (`nuclear_fuel`)
- **建筑 / 生产方式：** 核燃料厂 (`nuclear_fuel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；核反应堆设备厂 (`reactor_component_works`)

#### 结构化内容效果

- **核燃料厂**（`building`）：`building.nuclear_fuel_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **核燃料**（`good`）：`good.nuclear_fuel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：核燃料循环提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 合成纤维工程 (`tech.synthetic_fiber_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.synthetic_fiber_engineering` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 合成材料 (`tech.synthetic_materials`)：尼龙、涤纶是高分子合成材料（尼龙 1935）。
- 纺织机械 (`tech.textile_machinery`)：合成纤维沿用纺织机械纺丝织造。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 8 类」（development.trade.goods\_8）

#### 效果摘要

解锁建筑：合成纤维厂；解锁建筑：合成纤维织造厂；解锁物资：合成纤维；「布匹织造」生产家族建筑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)；合成纤维 (`synthetic_fiber`)
- **建筑 / 生产方式：** 合成纤维厂 (`synthetic_fiber_plant`)；合成纤维织造厂 (`synthetic_textile_mill`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)

#### 结构化内容效果

- **合成纤维厂**（`building`）：`building.synthetic_fiber_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **合成纤维织造厂**（`building`）：`building.synthetic_textile_mill` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **合成纤维**（`good`）：`good.synthetic_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 布匹织造：`country.output.family.cloth_weaving_factor`：+25%
  - 效果机制：合成纤维工程提高布匹织造建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 工业生态 (`tech.industrial_ecology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_ecology` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工业化学 (`tech.industrial_chemistry`)：该科技需要先掌握 「工业化学」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 4 个」（development.trade.partners\_4）

#### 效果摘要

全社会经济产出 +4%；全社会自然资源耗用 -8%；作为必要支撑：发动机厂、润滑油厂、自动化润滑油厂

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 发动机厂 (`engines_plant`)；润滑油厂 (`lubricants_plant`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化润滑油厂 (`method_lubricants_plant_r9`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
- 全社会自然资源耗用：`country.resource.use_factor`：+8%
  - 效果机制：工业生态提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：闭环利用降低原生资源耗用。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 系统工程 (`tech.systems_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.systems_engineering` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 运筹学 (`tech.operations_research`)：系统工程由运筹学的整体优化方法发展而来。
- 电子控制 (`tech.electronic_control`)：大型系统依赖电子控制与反馈。

#### 发现启发（仅用于揭示）

- 已发现信号「人口规模 312500」（development.population.312500\_1095d）

#### 效果摘要

全社会生产投入 -3%；采掘部门产出 +12%；作为必要支撑：核燃料厂、核反应堆设备厂、不锈钢厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 核燃料厂 (`nuclear_fuel_plant`)；核反应堆设备厂 (`reactor_component_works`)；不锈钢厂 (`stainless_steel_plant`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+3%
- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：接口管理减少复杂工程浪费。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`
  - 效果机制：系统工程提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 软件工程 (`tech.software_engineering`)：该科技需要先掌握 「系统工程」。
- 数字控制 (`tech.digital_control`)：该科技需要先掌握 「系统工程」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 消费信贷 (`tech.consumer_credit`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.consumer_credit` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 交流 (\`route.trade.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | institution |

#### 硬前置（决定研发资格）

- 中央银行体系 (`tech.central_banking`)：消费信贷依托中央银行管理下的银行信用。
- 大规模生产 (`tech.mass_production`)：分期付款面向大规模生产的耐用消费品（信用卡 1950）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

居民消费 +4%

#### 机会成本

占用社会研究预算，推迟原子工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 居民消费：`country.household.consumption_factor`：+4%
  - 效果机制：分期付款让家庭提前购买耐用消费品。
  - 运行时消费者：`NativeEconomyRuntime::family_consumption_factor_q16`

#### 被以下科技作为硬前置

- 数字市场 (`tech.digital_marketplaces`)：网上购物依赖信用卡等消费信贷结算。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 分子生物学 (`tech.molecular_biology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.molecular_biology` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`)；制度 · 实验室 (\`route.institution.laboratory\`) |
| 开局能力标签 | 无 |
| 效果配置 | science |

#### 硬前置（决定研发资格）

- 遗传学 (`tech.genetics`)：分子生物学寻找遗传因子的化学实体。
- 工业研究 (`tech.industrial_research`)：X 射线衍射等大型实验依赖工业研究体系（DNA 双螺旋 1953）。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

农业领域研究效率 +6%

#### 机会成本

占用科学研究预算，推迟原子工业路线。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+6%
  - 效果机制：在分子层面理解遗传加快了农业与医药研究。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 生物技术 (`tech.biotechnology`)：生物技术直接操作分子生物学揭示的基因。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 原子现代化 (`tech.atomic_modernity`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.atomic_modernity` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 4000000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 全部路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 6 项：
- 工业农学 (`tech.industrial_agronomy`)
- 电子控制 (`tech.electronic_control`)
- 国家实验室 (`tech.national_laboratories`)
- 国营企业 (`tech.state_enterprises`)
- 公司农业 (`tech.corporate_agribusiness`)
- 核能 (`tech.nuclear_energy`)
- 深层地球物理 (`tech.deep_geophysics`)
- 全球物流 (`tech.global_logistics`)
- 先进冶金 (`tech.advanced_metallurgy`)
- 核裂变 (`tech.nuclear_fission`)
- 运筹学 (`tech.operations_research`)
- 机械化采矿 (`tech.mechanized_mining`)
- 公共卫生体系 (`tech.public_health_systems`)
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)
- 工业生态 (`tech.industrial_ecology`)
- 石油化工 (`tech.petrochemical_industry`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气化集约农场 (`app.intensive_farm`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.intensive_farm` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 工业农学 (`tech.industrial_agronomy`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化集约农场 (`intensive_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 炼铜厂 (`app.copper_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.copper_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 先进冶金 (`tech.advanced_metallurgy`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 铜矿井开采 (`tech.copper_mine_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 炼铜厂 (`copper_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 核医学制药中心 (`app.nuclear_medicine_center`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.nuclear_medicine_center` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 核裂变 (`tech.nuclear_fission`)：该知识是此产业交汇自动生效的必要条件。
- 现代医学 (`tech.modern_medicine`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 核医学制药中心 (`nuclear_medicine_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铝土矿 (`app.bauxite_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.bauxite_collector` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铝土矿 (`bauxite_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 战略矿山 (`app.rare_earth_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.rare_earth_collector` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 战略矿山 (`rare_earth_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 现代炸药厂 (`app.method_explosives_plant_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_explosives_plant_r8` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 建筑构件厂 (`app.construction_components_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.construction_components_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 合成材料 (`tech.synthetic_materials`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 钢筋混凝土 (`tech.reinforced_concrete`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 合成橡胶厂 (`app.synthetic_rubber_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.synthetic_rubber_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 合成材料 (`tech.synthetic_materials`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 合成橡胶厂 (`synthetic_rubber_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 锰矿 (`app.manganese_ore_collector`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.manganese_ore_collector` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机械化采矿 (`tech.mechanized_mining`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 锰矿 (`manganese_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 核反应堆设备厂 (`app.reactor_component_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.reactor_component_works` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 核能 (`tech.nuclear_energy`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 核燃料循环 (`tech.nuclear_fuel_cycle`)：该知识是此产业交汇自动生效的必要条件。
- 系统工程 (`tech.systems_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 核反应堆设备厂 (`reactor_component_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电气设备厂 (`app.electrical_equipment_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.electrical_equipment_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电子控制 (`tech.electronic_control`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气设备厂 (`electrical_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电子元件厂 (`app.electronic_components_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.electronic_components_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电子控制 (`tech.electronic_control`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电子元件厂 (`electronic_components_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精密仪器厂 (`app.method_scientific_instrument_works_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_scientific_instrument_works_r8` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电子控制 (`tech.electronic_control`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。
- 工业研究 (`tech.industrial_research`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精密仪器厂 (`method_scientific_instrument_works_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 无线电设备厂 (`app.radio_equipment_works`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.radio_equipment_works` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 电子控制 (`tech.electronic_control`)：该知识是此产业交汇自动生效的必要条件。
- 电网 (`tech.electric_grid`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无线电设备厂 (`radio_equipment_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电解铝厂 (`app.aluminum_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.aluminum_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电解铝厂 (`aluminum_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 战略金属冶炼厂 (`app.rare_earth_metals_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.rare_earth_metals_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 战略金属冶炼厂 (`rare_earth_metals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 不锈钢厂 (`app.stainless_steel_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.stainless_steel_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 机械化采矿 (`tech.mechanized_mining`)：该知识是此产业交汇自动生效的必要条件。
- 系统工程 (`tech.systems_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 不锈钢厂 (`stainless_steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 家用电器厂 (`app.household_appliances_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.household_appliances_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家用电器厂 (`household_appliances_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 绝缘电缆厂 (`app.insulated_cable_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.insulated_cable_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 电磁感应 (`tech.electromagnetic_induction`)：该知识是此产业交汇自动生效的必要条件。
- 电网 (`tech.electric_grid`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 绝缘电缆厂 (`insulated_cable_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 现代硝石矿 (`app.method_saltpeter_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_saltpeter_collector_r8` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 国营企业 (`tech.state_enterprises`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 现代硫矿 (`app.method_sulfur_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_sulfur_collector_r8` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 国营企业 (`tech.state_enterprises`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代硫矿 (`method_sulfur_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 核燃料厂 (`app.nuclear_fuel_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.nuclear_fuel_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 核燃料循环 (`tech.nuclear_fuel_cycle`)：该知识是此产业交汇自动生效的必要条件。
- 系统工程 (`tech.systems_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 核燃料厂 (`nuclear_fuel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 合成纤维厂 (`app.synthetic_fiber_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.synthetic_fiber_plant` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 合成纤维厂 (`synthetic_fiber_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-10"></a>
## 信息时代

共 24 项研究科技、34 项自动应用，科技研究成本范围 5400000-9000000；时代里程碑：信息社会 (`tech.information_society`)。

### 精准农业 (`tech.precision_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_agriculture` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 工业农学 (`tech.industrial_agronomy`)：该科技需要先掌握 「工业农学」。
- 电子控制 (`tech.electronic_control`)：该科技需要先掌握 「电子控制」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 65%」（development.satisfaction.65\_1095d）

#### 效果摘要

解锁建筑：精准棉花农场；解锁建筑：精准亚麻农场；解锁建筑：精准玉米农场；解锁建筑：精准药材农场；解锁建筑：精准马铃薯农场；解锁建筑：精准稻作农场；解锁建筑：精准橡胶种植园；解锁建筑：精准香料种植园；解锁建筑：精准小麦农场；解锁建筑：精准农场；农业部门产出 +8%；旱作生产·旱灾损失 -10%；旱作生产·热害损失 -10%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)；玉米 (`corn_grain`)；混合谷物 (`grain`)；天然乳胶 (`latex`)；药材 (`medicinal_herbs`)；马铃薯 (`potatoes`)；稻米 (`rice_grain`)；籽棉 (`seed_cotton`)；香料 (`spices`)；蔬菜 (`vegetables`)；小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 精准棉花农场 (`method_cotton_collector_r8`)；精准亚麻农场 (`method_flax_collector_r8`)；精准玉米农场 (`method_maize_farm_r8`)；精准药材农场 (`method_medicinal_herbs_collector_r8`)；精准马铃薯农场 (`method_potato_farm_r8`)；精准稻作农场 (`method_rice_collector_r8`)；精准橡胶种植园 (`method_rubber_tree_collector_r8`)；精准香料种植园 (`method_spice_plants_collector_r8`)；精准小麦农场 (`method_wheat_farm_r8`)；精准农场 (`precision_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **精准棉花农场**（`building`）：`building.method_cotton_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准亚麻农场**（`building`）：`building.method_flax_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准玉米农场**（`building`）：`building.method_maize_farm_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准药材农场**（`building`）：`building.method_medicinal_herbs_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准马铃薯农场**（`building`）：`building.method_potato_farm_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准稻作农场**（`building`）：`building.method_rice_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准橡胶种植园**（`building`）：`building.method_rubber_tree_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准香料种植园**（`building`）：`building.method_spice_plants_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准小麦农场**（`building`）：`building.method_wheat_farm_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **精准农场**（`building`）：`building.precision_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+10%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+10%
  - 效果机制：精准农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：精准农业降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：精准农业降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 高地精准农业 (`tech.highland_precision_agriculture`)：高地精准农业是精准农业在山地的专门化。
- 自动化农业 (`tech.automated_agriculture`)：自动化农业在精准农业的数据与作业体系上运行。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数字计算 (`tech.digital_computing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.digital_computing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 电子控制 (`tech.electronic_control`)：该科技需要先掌握 「电子控制」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识就业 6250」（development.employment.knowledge.6250\_1095d）

#### 效果摘要

解锁建筑：计算机厂；解锁建筑：早期计算机工场；解锁物资：计算机；全社会经济产出 +6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 计算机 (`computers`)
- **建筑 / 生产方式：** 计算机厂 (`computers_plant`)；早期计算机工场 (`digital_computer_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **计算机厂**（`building`）：`building.computers_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **早期计算机工场**（`building`）：`building.digital_computer_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **计算机**（`good`）：`good.computers` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：数字计算提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 信息论 (`tech.information_theory`)：信息论与数字计算共同奠定编码与处理基础。
- 知识经济 (`tech.knowledge_economy`)：知识经济以计算机处理信息为生产手段。
- 软件工程 (`tech.software_engineering`)：该科技需要先掌握 「数字计算」。
- 半导体制造 (`tech.semiconductor_manufacturing`)：该科技需要先掌握 「数字计算」。
- 数字控制 (`tech.digital_control`)：该科技需要先掌握 「数字计算」。
- 地理信息系统 (`tech.geographic_information_systems`)：空间数据的存储与分析需要计算机（GIS 1963）。
- 卫星观测 (`tech.satellite_observation`)：卫星轨道计算与图像处理需要计算机。
- 数值天气预报 (`tech.numerical_weather_prediction`)：数值天气预报需要电子计算机求解大气方程（1950 ← 电子计算机）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 信息论 (`tech.information_theory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.information_theory` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：信息论与数字计算共同奠定编码与处理基础。
- 电信 (`tech.telecommunications`)：香农信息论直接研究电信信道容量。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 6250」（development.employment.manufacturing.6250\_1095d）

#### 效果摘要

科学领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+8%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 生物信息学 (`tech.bioinformatics`)：该科技需要先掌握 「信息论」。
- 机器学习 (`tech.machine_learning`)：学习算法以信息论与统计推断为理论基础。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 知识经济 (`tech.knowledge_economy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.knowledge_economy` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：知识经济以计算机处理信息为生产手段。
- 公共教育 (`tech.public_education`)：知识经济依赖普及教育培养的知识劳动者。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 100000」（development.output.knowledge.100000\_1095d）

#### 效果摘要

全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：知识经济提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 算法治理 (`tech.algorithmic_governance`)：算法治理面向知识经济下的公共服务。
- 人机共治 (`tech.human_machine_cogovernance`)：人机共治面向知识经济的组织形态。
- 知识合作社 (`tech.knowledge_cooperatives`)：该科技需要先掌握 「知识经济」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 软件工程 (`tech.software_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.software_engineering` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：该科技需要先掌握 「数字计算」。
- 系统工程 (`tech.systems_engineering`)：该科技需要先掌握 「系统工程」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 16 类」（development.trade.goods\_16）

#### 效果摘要

解锁建筑：计算研究中心；全社会经济产出 +4%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 计算研究中心 (`computing_research_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **计算研究中心**（`building`）：`building.computing_research_center` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：软件工程提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 网络计算 (`tech.networked_computing`)：网络协议与服务需要软件工程。

#### 主题路线后继

- 网络计算 (`tech.networked_computing`)：该知识继续发展为 「网络计算」。

#### 跨领域应用

- 数字控制 (`tech.digital_control`)：该知识参与形成 「数字控制」。
- 平台协调 (`tech.platform_coordination`)：该知识参与形成 「平台协调」。

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 半导体制造 (`tech.semiconductor_manufacturing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.semiconductor_manufacturing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 资源 · 稀土 (\`route.resource.rare\_earth\`) |
| 全部路线 | 资源 · 稀土 (\`route.resource.rare\_earth\`)；制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：该科技需要先掌握 「数字计算」。

#### 发现启发（仅用于揭示）

- 已发现信号「累计贸易量 100000」（development.trade.quantity\_100000）

#### 效果摘要

解锁建筑：早期半导体厂；解锁建筑：半导体厂；解锁物资：半导体；全社会经济产出 +5%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 半导体 (`semiconductors`)
- **建筑 / 生产方式：** 早期半导体厂 (`basic_semiconductor_fab`)；半导体厂 (`semiconductors_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **早期半导体厂**（`building`）：`building.basic_semiconductor_fab` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **半导体厂**（`building`）：`building.semiconductors_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **半导体**（`good`）：`good.semiconductors` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+5%
  - 效果机制：半导体制造提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 网络计算 (`tech.networked_computing`)：路由与终端设备依赖半导体芯片。
- 传感器网络 (`tech.sensor_networks`)：廉价传感节点依赖半导体芯片。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 网络计算 (`tech.networked_computing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.networked_computing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 软件工程 (`tech.software_engineering`)：网络协议与服务需要软件工程。
- 电信 (`tech.telecommunications`)：计算机网络以电信线路为物理通道。
- 半导体制造 (`tech.semiconductor_manufacturing`)：路由与终端设备依赖半导体芯片。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 8 个」（development.trade.partners\_8）

#### 效果摘要

解锁建筑：通信设备厂；解锁物资：通信设备；全社会经济产出 +4%；作为必要支撑：地理空间分析中心

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 通信设备 (`telecom_equipment`)
- **建筑 / 生产方式：** 通信设备厂 (`telecom_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地理空间分析中心 (`geospatial_analysis_center`)

#### 结构化内容效果

- **通信设备厂**（`building`）：`building.telecom_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **通信设备**（`good`）：`good.telecom_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：网络计算提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 开放科学网络 (`tech.open_science_networks`)：该科技需要先掌握 「网络计算」。
- 平台协调 (`tech.platform_coordination`)：该科技需要先掌握 「网络计算」。
- 数字市场 (`tech.digital_marketplaces`)：数字市场运行在计算机网络上。
- 机器学习 (`tech.machine_learning`)：机器学习依赖网络汇聚的大数据与算力（深度学习 ← 大数据、GPU）。
- 智能电网 (`tech.smart_grid`)：分布式计量与调度依赖计算机网络。
- 分布式智能 (`tech.distributed_intelligence`)：分布式智能运行在计算机网络上。
- 算法管理 (`tech.algorithmic_management`)：该科技需要先掌握 「网络计算」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数字控制 (`tech.digital_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.digital_control` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：该科技需要先掌握 「数字计算」。
- 系统工程 (`tech.systems_engineering`)：该科技需要先掌握 「系统工程」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 100000」（development.output.knowledge.100000\_1095d）

#### 效果摘要

解锁建筑：汽车厂；解锁建筑：发动机厂；解锁建筑：润滑油厂；解锁建筑：数字化农业机械厂；解锁建筑：自动化水泥厂；解锁建筑：自动化炼铅厂；解锁建筑：自动化润滑油厂；解锁建筑：自动化机械零件厂；解锁建筑：自动化蒸汽机厂；解锁物资：汽车；解锁物资：发动机；解锁物资：润滑剂；科学领域研究效率 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 农业机械 (`agricultural_machinery`)；汽车 (`automobiles`)；水泥 (`cement`)；发动机 (`engines`)；铅 (`lead`)；润滑剂 (`lubricants`)；机器零件 (`machine_parts`)；蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；发动机厂 (`engines_plant`)；润滑油厂 (`lubricants_plant`)；数字化农业机械厂 (`method_agricultural_machinery_plant_r9`)；自动化水泥厂 (`method_cement_plant_r9`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化润滑油厂 (`method_lubricants_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **汽车厂**（`building`）：`building.automobiles_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **发动机厂**（`building`）：`building.engines_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **润滑油厂**（`building`）：`building.lubricants_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **数字化农业机械厂**（`building`）：`building.method_agricultural_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化水泥厂**（`building`）：`building.method_cement_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化炼铅厂**（`building`）：`building.method_lead_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化润滑油厂**（`building`）：`building.method_lubricants_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化机械零件厂**（`building`）：`building.method_machine_parts_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化蒸汽机厂**（`building`）：`building.method_steam_engine_works_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **农业机械**（`good`）：`good.agricultural_machinery` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **汽车**（`good`）：`good.automobiles` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **水泥**（`good`）：`good.cement` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **发动机**（`good`）：`good.engines` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铅**（`good`）：`good.lead` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **润滑剂**（`good`）：`good.lubricants` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **机器零件**（`good`）：`good.machine_parts` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+8%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 自动化物流 (`tech.automated_logistics`)：自动化港口与仓储依赖数字控制。
- 自主系统 (`tech.autonomous_systems`)：该科技需要先掌握 「数字控制」。
- 机器人制造 (`tech.robotic_manufacturing`)：工业机器人以数字控制为运动基础（工业机器人 ← 数值控制）。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 自动化物流 (`tech.automated_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.automated_logistics` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 全球物流 (`tech.global_logistics`)：自动化物流升级既有的全球联运网络。
- 数字控制 (`tech.digital_control`)：自动化港口与仓储依赖数字控制。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 64」（development.buildings.active\_64\_1095d）

#### 效果摘要

解锁建筑：自动化港口船舶中心；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 远洋船舶 (`oceanic_vessels`)
- **建筑 / 生产方式：** 自动化港口船舶中心 (`method_automated_port`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化港口船舶中心**（`building`）：`building.method_automated_port` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：自动化物流提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自主物流 (`tech.autonomous_logistics`)：自主物流在自动化物流上去掉人工调度。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 生物技术 (`tech.biotechnology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.biotechnology` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 分子生物学 (`tech.molecular_biology`)：生物技术直接操作分子生物学揭示的基因。
- 现代医学 (`tech.modern_medicine`)：早期生物技术产品首先是药物与疫苗。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 65%」（development.satisfaction.65\_1095d）

#### 效果摘要

解锁建筑：专用商品作物种植园；农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 天然乳胶 (`latex`)；香料 (`spices`)
- **建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **专用商品作物种植园**（`building`）：`building.method_specialty_commodity_plantation` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 生物信息学 (`tech.bioinformatics`)：该科技需要先掌握 「生物技术」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 开放科学网络 (`tech.open_science_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.open_science_networks` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 7020000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：该科技需要先掌握 「网络计算」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全社会经济产出 +6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：开放科学网络提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 智能科学代理 (`tech.scientific_agents`)：科学代理从开放科学网络获取数据与文献。
- 知识合作社 (`tech.knowledge_cooperatives`)：该科技需要先掌握 「开放科学网络」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 平台协调 (`tech.platform_coordination`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.platform_coordination` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：该科技需要先掌握 「网络计算」。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_5\_count\_16\_1095d）

#### 效果摘要

解锁建筑：数字化工业机械厂；「石油采掘」生产家族建筑产出 +8%；「化学工业」生产家族建筑产出 +8%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 工业机械 (`industrial_machinery`)
- **建筑 / 生产方式：** 数字化工业机械厂 (`method_industrial_machinery_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **数字化工业机械厂**（`building`）：`building.method_industrial_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业机械**（`good`）：`good.industrial_machinery` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 石油采掘：`country.output.family.oil_extraction_factor`：+8%
- 化学工业：`country.output.family.chemical_industry_factor`：+8%
  - 效果机制：平台协调提高石油采掘建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：平台协调提高化学工业建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 人机协作 (`tech.human_machine_collaboration`)：该科技需要先掌握 「平台协调」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数字市场 (`tech.digital_marketplaces`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.digital_marketplaces` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 7020000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：数字市场运行在计算机网络上。
- 消费信贷 (`tech.consumer_credit`)：网上购物依赖信用卡等消费信贷结算。

#### 发现启发（仅用于揭示）

- 已发现信号「活跃产业规模 64」（development.buildings.active\_64\_1095d）

#### 效果摘要

国内贸易容量 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国内贸易容量：`country.trade.capacity_factor`：+20%
  - 效果机制：市场组织与结算网络扩大国内贸易容量。
  - 运行时消费者：`NativeEconomyRuntime::capture_country_epoch`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地理信息系统 (`tech.geographic_information_systems`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.geographic_information_systems` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 地图学 (`tech.cartography`)：地理信息系统把地图学的空间表达数字化。
- 数字计算 (`tech.digital_computing`)：空间数据的存储与分析需要计算机（GIS 1963）。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 65%」（development.satisfaction.65\_1095d）

#### 效果摘要

解锁建筑：地理空间分析中心；解锁建筑：工业石灰岩矿场；「地理分析机构」生产家族建筑产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石灰岩 (`limestone`)；科技值 (`technology_points`)
- **建筑 / 生产方式：** 地理空间分析中心 (`geospatial_analysis_center`)；工业石灰岩矿场 (`method_limestone_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **地理空间分析中心**（`building`）：`building.geospatial_analysis_center` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **工业石灰岩矿场**（`building`）：`building.method_limestone_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石灰岩**（`good`）：`good.limestone` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 地理分析机构：`country.output.family.geospatial_analysis_institution_factor`：+12%
  - 效果机制：地理信息系统提高地理分析机构产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 高地精准农业 (`tech.highland_precision_agriculture`)：坡度、朝向与小气候制图依赖地理信息系统。

#### 主题路线后继

无

#### 跨领域应用

- 精准农业 (`tech.precision_agriculture`)：该知识参与形成 「精准农业」。
- 精准灌溉 (`tech.precision_irrigation`)：该知识参与形成 「精准灌溉」。
- 自主采矿 (`tech.autonomous_mining`)：该知识参与形成 「自主采矿」。

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 高地精准农业 (`tech.highland_precision_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.highland_precision_agriculture` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 精准农业 (`tech.precision_agriculture`)：高地精准农业是精准农业在山地的专门化。
- 地理信息系统 (`tech.geographic_information_systems`)：坡度、朝向与小气候制图依赖地理信息系统。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：高地精准块茎农业；旱作生产·寒冷损失 -16%

#### 机会成本

多条知识路线汇合为一个可见应用节点，避免建筑条件隐式叠加。

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **高地精准块茎农业**（`building`）：`building.method_highland_precision_agriculture` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+16%
  - 效果机制：应用：高地精准块茎农业降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 卫星观测 (`tech.satellite_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.satellite_observation` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 电信 (`tech.telecommunications`)：卫星观测依赖星地无线电遥测链路。
- 数字计算 (`tech.digital_computing`)：卫星轨道计算与图像处理需要计算机。

#### 发现启发（仅用于揭示）

- 已发现信号「多聚落体系」（development.settlements.tier\_5\_count\_16\_1095d）

#### 效果摘要

解锁建筑：森林遥感经营站

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原木 (`logs`)
- **建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **森林遥感经营站**（`building`）：`building.method_forest_remote_sensing` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：光谱遥感以卫星平台获取影像。
- 作物遥感 (`tech.crop_remote_sensing`)：该科技需要先掌握 「卫星观测」。
- 水文遥感 (`tech.hydrological_remote_sensing`)：该科技需要先掌握 「卫星观测」。
- 自主林业经营 (`tech.autonomous_forestry_operations`)：林分监测与采伐规划依赖卫星观测。

#### 主题路线后继

无

#### 跨领域应用

- 气候建模 (`tech.climate_modeling`)：该知识参与形成 「气候建模」。

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数值天气预报 (`tech.numerical_weather_prediction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.numerical_weather_prediction` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：数值天气预报需要电子计算机求解大气方程（1950 ← 电子计算机）。
- 概率与统计 (`tech.probability_statistics`)：观测资料同化与预报检验依赖统计方法。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 6250」（development.employment.manufacturing.6250\_1095d）

#### 效果摘要

旱灾损失 -8%；洪灾损失 -8%；寒冷损失 -8%；热害损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 旱灾损失：`country.climate.drought_loss_factor`：+8%
- 洪灾损失：`country.climate.flood_loss_factor`：+8%
- 寒冷损失：`country.climate.cold_stress_factor`：+8%
- 热害损失：`country.climate.heat_stress_factor`：+8%
  - 效果机制：数值天气预报降低全国气候型生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：数值天气预报降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：数值天气预报降低全国气候型生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：数值天气预报降低全国气候型生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

- 气候建模 (`tech.climate_modeling`)：该科技需要先掌握 「数值天气预报」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 矿物光谱遥感 (`tech.mineral_spectral_survey`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mineral_spectral_survey` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 卫星观测 (`tech.satellite_observation`)：光谱遥感以卫星平台获取影像。
- 深层地球物理 (`tech.deep_geophysics`)：矿物光谱判读需要地球物理的成矿认识。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘产出规模 100000」（development.output.extractive.100000\_1095d）

#### 效果摘要

解锁建筑：自动化铝土矿；解锁建筑：自动化铅矿；解锁建筑：自动化磷矿；可利用资源：锰矿；可利用资源：稀土；采掘部门产出 +25%；作为必要支撑：高端芯片厂、智能化核燃料厂、智能战略矿山、智能战略金属冶炼厂、智能化核反应堆设备厂、智能化不锈钢厂

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝土矿 (`bauxite`)；铅矿石 (`lead_ore`)；磷矿石 (`phosphate_rock`)
- **建筑 / 生产方式：** 自动化铝土矿 (`method_bauxite_collector_r9`)；自动化铅矿 (`method_lead_ore_collector_r9`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)
- **自然资源：** 稀土 (`rare_earth`)；锰矿 (`manganese_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)

#### 结构化内容效果

- **自动化铝土矿**（`building`）：`building.method_bauxite_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化铅矿**（`building`）：`building.method_lead_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化磷矿**（`building`）：`building.method_phosphate_rock_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铝土矿**（`good`）：`good.bauxite` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **铅矿石**（`good`）：`good.lead_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **磷矿石**（`good`）：`good.phosphate_rock` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锰矿**（`resource`）：`resource.manganese_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **稀土**（`resource`）：`resource.rare_earth` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 采掘部门产出：`country.output.extractive_factor`：+25%
  - 效果机制：矿物光谱遥感提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 作物遥感 (`tech.crop_remote_sensing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_remote_sensing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 卫星观测 (`tech.satellite_observation`)：该科技需要先掌握 「卫星观测」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易商品 16 类」（development.trade.goods\_16）

#### 效果摘要

旱作生产·旱灾损失 -10%；种植园生产·热害损失 -12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+10%
- 种植园生产·热害损失：`country.climate.profile.plantation_crop.heat_stress_loss_factor`：+12%
  - 效果机制：作物遥感降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：作物遥感降低种植园生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 水文遥感 (`tech.hydrological_remote_sensing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hydrological_remote_sensing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 卫星观测 (`tech.satellite_observation`)：该科技需要先掌握 「卫星观测」。

#### 发现启发（仅用于揭示）

- 已发现信号「贸易伙伴 8 个」（development.trade.partners\_8）

#### 效果摘要

解锁建筑：流域治理中心；旱灾损失 -12%；洪灾损失 -12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 流域治理中心 (`watershed_governance_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **流域治理中心**（`building`）：`building.watershed_governance_center` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 旱灾损失：`country.climate.drought_loss_factor`：+12%
- 洪灾损失：`country.climate.flood_loss_factor`：+12%
  - 效果机制：水文遥感降低全国气候型生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：水文遥感降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 传感器网络 (`tech.sensor_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.sensor_networks` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 电子控制 (`tech.electronic_control`)：传感器网络由电子控制的测量回路组成。
- 半导体制造 (`tech.semiconductor_manufacturing`)：廉价传感节点依赖半导体芯片。

#### 发现启发（仅用于揭示）

- 已发现信号「制造就业 6250」（development.employment.manufacturing.6250\_1095d）

#### 效果摘要

解锁建筑：自动化焦化厂；解锁建筑：自动化混凝土厂；解锁建筑：自动化炼锌厂；科学领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 焦炭 (`coke`)；混凝土 (`concrete`)；锌 (`zinc`)
- **建筑 / 生产方式：** 自动化焦化厂 (`method_coke_ovens_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化焦化厂**（`building`）：`building.method_coke_ovens_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化混凝土厂**（`building`）：`building.method_concrete_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化炼锌厂**（`building`）：`building.method_zinc_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **焦炭**（`good`）：`good.coke` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **混凝土**（`good`）：`good.concrete` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锌**（`good`）：`good.zinc` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+8%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 精准灌溉 (`tech.precision_irrigation`)：按墒情精确配水依赖土壤传感器网络。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 精准灌溉 (`tech.precision_irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_irrigation` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 水利工程 (`tech.hydraulic_engineering`)：精准灌溉沿用水利工程的输配水系统。
- 传感器网络 (`tech.sensor_networks`)：按墒情精确配水依赖土壤传感器网络。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

水田生产·旱灾损失 -14%；水田生产·洪灾损失 -14%；商品「稻米」产量 +20%；农业部门产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 水田生产·旱灾损失：`country.climate.profile.paddy_crop.drought_loss_factor`：+14%
- 水田生产·洪灾损失：`country.climate.profile.paddy_crop.flood_loss_factor`：+14%
- 稻米：`country.output.good.rice_grain_factor`：+20%
- 农业部门产出：`country.output.agriculture_factor`：+20%
  - 效果机制：精准灌溉降低水田生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：精准灌溉降低水田生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：精准灌溉提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：精准灌溉提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自适应灌溉 (`tech.adaptive_irrigation`)：自适应灌溉在精准灌溉上实现闭环自调。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 生物信息学 (`tech.bioinformatics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bioinformatics` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 生物技术 (`tech.biotechnology`)：该科技需要先掌握 「生物技术」。
- 信息论 (`tech.information_theory`)：该科技需要先掌握 「信息论」。

#### 发现启发（仅用于揭示）

- 已发现信号「知识产出规模 100000」（development.output.knowledge.100000\_1095d）

#### 效果摘要

农业领域研究效率 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+8%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 计算生物学 (`tech.computational_biology`)：该科技需要先掌握 「生物信息学」。
- 智能育种 (`tech.intelligent_breeding`)：智能育种依赖基因组数据分析。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 信息社会 (`tech.information_society`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.information_society` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9000000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 17 项候选中的任意 7 项：
- 精准农业 (`tech.precision_agriculture`)
- 数字控制 (`tech.digital_control`)
- 数字计算 (`tech.digital_computing`)
- 知识经济 (`tech.knowledge_economy`)
- 精准灌溉 (`tech.precision_irrigation`)
- 半导体制造 (`tech.semiconductor_manufacturing`)
- 卫星观测 (`tech.satellite_observation`)
- 平台协调 (`tech.platform_coordination`)
- 信息论 (`tech.information_theory`)
- 软件工程 (`tech.software_engineering`)
- 网络计算 (`tech.networked_computing`)
- 地理信息系统 (`tech.geographic_information_systems`)
- 数值天气预报 (`tech.numerical_weather_prediction`)
- 生物技术 (`tech.biotechnology`)
- 传感器网络 (`tech.sensor_networks`)
- 自动化物流 (`tech.automated_logistics`)
- 生物信息学 (`tech.bioinformatics`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准棉花农场 (`app.method_cotton_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_cotton_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准棉花农场 (`method_cotton_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准亚麻农场 (`app.method_flax_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_flax_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准亚麻农场 (`method_flax_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准玉米农场 (`app.method_maize_farm_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_maize_farm_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准玉米农场 (`method_maize_farm_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准药材农场 (`app.method_medicinal_herbs_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_medicinal_herbs_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准药材农场 (`method_medicinal_herbs_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准马铃薯农场 (`app.method_potato_farm_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_potato_farm_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准马铃薯农场 (`method_potato_farm_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准稻作农场 (`app.method_rice_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rice_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 芦苇收割 (`tech.reed_harvesting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准稻作农场 (`method_rice_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准橡胶种植园 (`app.method_rubber_tree_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rubber_tree_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准橡胶种植园 (`method_rubber_tree_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准香料种植园 (`app.method_spice_plants_collector_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_spice_plants_collector_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准香料种植园 (`method_spice_plants_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准小麦农场 (`app.method_wheat_farm_r8`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wheat_farm_r8` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准小麦农场 (`method_wheat_farm_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 精准农场 (`app.precision_farm`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.precision_farm` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 精准农业 (`tech.precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 精准农场 (`precision_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 高地精准块茎农业 (`app.method_highland_precision_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_highland_precision_agriculture` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 高地精准农业 (`tech.highland_precision_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 计算机厂 (`app.computers_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.computers_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字计算 (`tech.digital_computing`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 计算机厂 (`computers_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期计算机工场 (`app.digital_computer_workshop`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.digital_computer_workshop` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字计算 (`tech.digital_computing`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期计算机工场 (`digital_computer_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 通信设备厂 (`app.telecom_equipment_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.telecom_equipment_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 网络计算 (`tech.networked_computing`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 先进冶金 (`tech.advanced_metallurgy`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 通信设备厂 (`telecom_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 早期半导体厂 (`app.basic_semiconductor_fab`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.basic_semiconductor_fab` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 半导体制造 (`tech.semiconductor_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期半导体厂 (`basic_semiconductor_fab`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 半导体厂 (`app.semiconductors_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.semiconductors_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 半导体制造 (`tech.semiconductor_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 半导体厂 (`semiconductors_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 专用商品作物种植园 (`app.method_specialty_commodity_plantation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_specialty_commodity_plantation` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 生物技术 (`tech.biotechnology`)：该知识是此产业交汇自动生效的必要条件。
- 野生香料采集 (`tech.wild_spice_collection`)：该知识是此产业交汇自动生效的必要条件。
- 野生割胶 (`tech.wild_latex_tapping`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化铝土矿 (`app.method_bauxite_collector_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_bauxite_collector_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化铝土矿 (`method_bauxite_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化铅矿 (`app.method_lead_ore_collector_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_lead_ore_collector_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化铅矿 (`method_lead_ore_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化磷矿 (`app.method_phosphate_rock_collector_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_phosphate_rock_collector_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 土壤实验 (`tech.soil_experimentation`)：该知识是此产业交汇自动生效的必要条件。
- 肥料加工 (`tech.fertilizer_processing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化磷矿 (`method_phosphate_rock_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 汽车厂 (`app.automobiles_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.automobiles_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 先进冶金 (`tech.advanced_metallurgy`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 发动机厂 (`app.engines_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.engines_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 工业生态 (`tech.industrial_ecology`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 发动机厂 (`engines_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 润滑油厂 (`app.lubricants_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.lubricants_plant` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 工业生态 (`tech.industrial_ecology`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 润滑油厂 (`lubricants_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 数字化农业机械厂 (`app.method_agricultural_machinery_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_agricultural_machinery_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 机械化农业 (`tech.mechanized_agriculture`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 数字化农业机械厂 (`method_agricultural_machinery_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化水泥厂 (`app.method_cement_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_cement_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 水利工程 (`tech.hydraulic_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化水泥厂 (`method_cement_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化炼铅厂 (`app.method_lead_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_lead_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化炼铅厂 (`method_lead_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化润滑油厂 (`app.method_lubricants_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_lubricants_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 工业生态 (`tech.industrial_ecology`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化润滑油厂 (`method_lubricants_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化机械零件厂 (`app.method_machine_parts_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_machine_parts_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 轮作 (`tech.crop_rotation`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 机床 (`tech.machine_tools`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化机械零件厂 (`method_machine_parts_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化蒸汽机厂 (`app.method_steam_engine_works_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_steam_engine_works_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 数字控制 (`tech.digital_control`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化蒸汽机厂 (`method_steam_engine_works_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 地理空间分析中心 (`app.geospatial_analysis_center`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.geospatial_analysis_center` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 地理信息系统 (`tech.geographic_information_systems`)：该知识是此产业交汇自动生效的必要条件。
- 网络计算 (`tech.networked_computing`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 地理空间分析中心 (`geospatial_analysis_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业石灰岩矿场 (`app.method_limestone_collector_r6`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_limestone_collector_r6` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 地理信息系统 (`tech.geographic_information_systems`)：该知识是此产业交汇自动生效的必要条件。
- 运河工程 (`tech.canal_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业石灰岩矿场 (`method_limestone_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化焦化厂 (`app.method_coke_ovens_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_coke_ovens_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 传感器网络 (`tech.sensor_networks`)：该知识是此产业交汇自动生效的必要条件。
- 焦炭冶炼 (`tech.coke_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化焦化厂 (`method_coke_ovens_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化混凝土厂 (`app.method_concrete_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_concrete_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 传感器网络 (`tech.sensor_networks`)：该知识是此产业交汇自动生效的必要条件。
- 水利工程 (`tech.hydraulic_engineering`)：该知识是此产业交汇自动生效的必要条件。
- 钢筋混凝土 (`tech.reinforced_concrete`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化混凝土厂 (`method_concrete_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化炼锌厂 (`app.method_zinc_plant_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_zinc_plant_r9` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 传感器网络 (`tech.sensor_networks`)：该知识是此产业交汇自动生效的必要条件。
- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化炼锌厂 (`method_zinc_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

<a id="era-11"></a>
## 智能时代

共 22 项研究科技、44 项自动应用，科技研究成本范围 12000000-20000000；时代里程碑：认知自动化 (`tech.cognitive_automation`)。

### 机器学习 (`tech.machine_learning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.machine_learning` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：机器学习依赖网络汇聚的大数据与算力（深度学习 ← 大数据、GPU）。
- 信息论 (`tech.information_theory`)：学习算法以信息论与统计推断为理论基础。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：高端芯片厂；解锁建筑：智能研究院；解锁物资：先进芯片；全社会经济产出 +5%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 先进芯片 (`advanced_chips`)；科技值 (`technology_points`)
- **建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；智能研究院 (`machine_intelligence_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **高端芯片厂**（`building`）：`building.advanced_chip_fab` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能研究院**（`building`）：`building.machine_intelligence_institute` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **先进芯片**（`good`）：`good.advanced_chips` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+5%
  - 效果机制：机器学习提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自主系统 (`tech.autonomous_systems`)：该科技需要先掌握 「机器学习」。
- 神经网络 (`tech.neural_networks`)：该科技需要先掌握 「机器学习」。
- 人机协作 (`tech.human_machine_collaboration`)：该科技需要先掌握 「机器学习」。
- 计算生物学 (`tech.computational_biology`)：该科技需要先掌握 「机器学习」。
- 算法治理 (`tech.algorithmic_governance`)：算法治理以机器学习模型辅助公共决策。
- 分布式智能 (`tech.distributed_intelligence`)：各节点的智能来自机器学习模型。
- 智能育种 (`tech.intelligent_breeding`)：基因组选择模型来自机器学习。
- 智能科学代理 (`tech.scientific_agents`)：智能科学代理以机器学习模型提出与筛选假设。
- 人机共治 (`tech.human_machine_cogovernance`)：共治中的机器一方以机器学习模型参与决策。
- 算法管理 (`tech.algorithmic_management`)：该科技需要先掌握 「机器学习」。
- 认知自动化 (`tech.cognitive_automation`)：该科技需要先掌握 「机器学习」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自主系统 (`tech.autonomous_systems`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_systems` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 全部路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 数字控制 (`tech.digital_control`)：该科技需要先掌握 「数字控制」。
- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自主控制系统厂；解锁物资：自主系统；全社会经济产出 +6%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 自主系统 (`autonomous_systems`)
- **建筑 / 生产方式：** 自主控制系统厂 (`autonomous_systems_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自主控制系统厂**（`building`）：`building.autonomous_systems_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自主系统**（`good`）：`good.autonomous_systems` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+6%
  - 效果机制：自主系统提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自动化农业 (`tech.automated_agriculture`)：无人农机依赖自主系统。
- 自主采矿 (`tech.autonomous_mining`)：无人矿卡与钻机依赖自主系统。
- 自主物流 (`tech.autonomous_logistics`)：无人船舶与车辆依赖自主系统。
- 自主林业经营 (`tech.autonomous_forestry_operations`)：无人林业机械依赖自主系统。
- 自适应灌溉 (`tech.adaptive_irrigation`)：闭环配水依赖自主控制系统。
- 自主劳动协调 (`tech.autonomous_labor_coordination`)：协调对象包括自主运行的机器。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自动化农业 (`tech.automated_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.automated_agriculture` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 全部路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 精准农业 (`tech.precision_agriculture`)：自动化农业在精准农业的数据与作业体系上运行。
- 自主系统 (`tech.autonomous_systems`)：无人农机依赖自主系统。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自动化农场；解锁建筑：自动化棉花农场；解锁建筑：自动化亚麻农场；解锁建筑：自动化玉米农场；解锁建筑：自动化药材农场；解锁建筑：自动化马铃薯农场；解锁建筑：自动化稻作农场；解锁建筑：自动化橡胶种植园；解锁建筑：智能牧业站；解锁建筑：自动化香料种植园；解锁建筑：自动化小麦农场；农业部门产出 +8%；旱作生产·旱灾损失 -10%；旱作生产·洪灾损失 -10%；旱作生产·寒冷损失 -10%；旱作生产·热害损失 -10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 亚麻秆/韧皮原料 (`bast_fiber`)；玉米 (`corn_grain`)；混合谷物 (`grain`)；天然乳胶 (`latex`)；畜牧产品 (`livestock_products`)；药材 (`medicinal_herbs`)；马铃薯 (`potatoes`)；稻米 (`rice_grain`)；籽棉 (`seed_cotton`)；香料 (`spices`)；蔬菜 (`vegetables`)；小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 自动化农场 (`automated_farm`)；自动化棉花农场 (`method_cotton_collector_r10`)；自动化亚麻农场 (`method_flax_collector_r10`)；自动化玉米农场 (`method_maize_farm_r10`)；自动化药材农场 (`method_medicinal_herbs_collector_r10`)；自动化马铃薯农场 (`method_potato_farm_r10`)；自动化稻作农场 (`method_rice_collector_r10`)；自动化橡胶种植园 (`method_rubber_tree_collector_r10`)；智能牧业站 (`method_smart_husbandry`)；自动化香料种植园 (`method_spice_plants_collector_r10`)；自动化小麦农场 (`method_wheat_farm_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化农场**（`building`）：`building.automated_farm` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化棉花农场**（`building`）：`building.method_cotton_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化亚麻农场**（`building`）：`building.method_flax_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化玉米农场**（`building`）：`building.method_maize_farm_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化药材农场**（`building`）：`building.method_medicinal_herbs_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化马铃薯农场**（`building`）：`building.method_potato_farm_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化稻作农场**（`building`）：`building.method_rice_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化橡胶种植园**（`building`）：`building.method_rubber_tree_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能牧业站**（`building`）：`building.method_smart_husbandry` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化香料种植园**（`building`）：`building.method_spice_plants_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化小麦农场**（`building`）：`building.method_wheat_farm_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **亚麻秆/韧皮原料**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **畜牧产品**（`good`）：`good.livestock_products` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 农业部门产出：`country.output.agriculture_factor`：+8%
- 旱作生产·旱灾损失：`country.climate.profile.dryland_crop.drought_loss_factor`：+10%
- 旱作生产·洪灾损失：`country.climate.profile.dryland_crop.flood_loss_factor`：+10%
- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+10%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+10%
  - 效果机制：自动化农业提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`
  - 效果机制：自动化农业降低旱作生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：自动化农业降低旱作生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：自动化农业降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：自动化农业降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 神经网络 (`tech.neural_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.neural_networks` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 70%」（development.satisfaction.70\_1095d）

#### 效果摘要

解锁建筑：智能化洗涤剂厂；解锁建筑：智能战略金属冶炼厂；科学领域研究效率 +22%；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 洗涤剂 (`detergent`)；战略矿物材料 (`rare_earth_metals`)
- **建筑 / 生产方式：** 智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化洗涤剂厂**（`building`）：`building.method_detergent_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能战略金属冶炼厂**（`building`）：`building.method_rare_earth_metals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **洗涤剂**（`good`）：`good.detergent` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+22%
- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：神经网络提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 人机协作 (`tech.human_machine_collaboration`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.human_machine_collaboration` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 平台协调 (`tech.platform_coordination`)：该科技需要先掌握 「平台协调」。
- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：智能化家用电器厂；解锁建筑：智能工具厂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 家用电器 (`household_appliances`)；精密工具 (`precision_tools`)
- **建筑 / 生产方式：** 智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化家用电器厂**（`building`）：`building.method_household_appliances_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能工具厂**（`building`）：`building.method_precision_tool_workshop_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **家用电器**（`good`）：`good.household_appliances` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **精密工具**（`good`）：`good.precision_tools` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：人机协作提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 机器人制造 (`tech.robotic_manufacturing`)：智能工厂中的机器人与工人协作作业。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 机器人制造 (`tech.robotic_manufacturing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.robotic_manufacturing` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 全部路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 数字控制 (`tech.digital_control`)：工业机器人以数字控制为运动基础（工业机器人 ← 数值控制）。
- 人机协作 (`tech.human_machine_collaboration`)：智能工厂中的机器人与工人协作作业。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 6250」（development.employment.energy.6250\_1095d）

#### 效果摘要

解锁建筑：智能化汽车厂；解锁建筑：智能化发动机厂；解锁建筑：自动化炸药厂；解锁建筑：智能化核燃料厂；解锁建筑：智能化核反应堆设备厂；解锁建筑：智能玻璃器皿工厂；解锁建筑：智能皮革制品工厂；解锁建筑：智能金属家用器皿工厂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 汽车 (`automobiles`)；发动机 (`engines`)；炸药 (`explosives`)；玻璃器皿 (`glassware`)；皮革制品 (`leather_goods`)；金属家用器皿 (`metal_housewares`)；核燃料 (`nuclear_fuel`)；反应堆部件 (`reactor_components`)
- **建筑 / 生产方式：** 智能化汽车厂 (`method_automobiles_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能玻璃器皿工厂 (`smart_glassware_factory`)；智能皮革制品工厂 (`smart_leather_goods_factory`)；智能金属家用器皿工厂 (`smart_metal_housewares_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化汽车厂**（`building`）：`building.method_automobiles_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化发动机厂**（`building`）：`building.method_engines_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化炸药厂**（`building`）：`building.method_explosives_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化核燃料厂**（`building`）：`building.method_nuclear_fuel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化核反应堆设备厂**（`building`）：`building.method_reactor_component_works_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能玻璃器皿工厂**（`building`）：`building.smart_glassware_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能皮革制品工厂**（`building`）：`building.smart_leather_goods_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能金属家用器皿工厂**（`building`）：`building.smart_metal_housewares_factory` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **汽车**（`good`）：`good.automobiles` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **发动机**（`good`）：`good.engines` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **炸药**（`good`）：`good.explosives` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **玻璃器皿**（`good`）：`good.glassware` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **皮革制品**（`good`）：`good.leather_goods` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金属家用器皿**（`good`）：`good.metal_housewares` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **核燃料**（`good`）：`good.nuclear_fuel` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **反应堆部件**（`good`）：`good.reactor_components` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：机器人制造提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自主采矿 (`tech.autonomous_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_mining` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 机械化采矿 (`tech.mechanized_mining`)：自主采矿是机械化矿山的无人化。
- 自主系统 (`tech.autonomous_systems`)：无人矿卡与钻机依赖自主系统。

#### 发现启发（仅用于揭示）

- 已发现信号「采掘就业 6250」（development.employment.extractive.6250\_1095d）

#### 效果摘要

解锁建筑：智能锰矿；解锁建筑：智能天然气田；解锁建筑：智能战略矿山；解锁建筑：智能硝石矿；铁矿石 -12%；采掘部门产出 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锰矿石 (`manganese_ore`)；天然气 (`natural_gas`)；战略矿石 (`rare_earth_ore`)；硝石 (`saltpeter`)
- **建筑 / 生产方式：** 智能锰矿 (`method_manganese_ore_collector_r10`)；智能天然气田 (`method_natural_gas_collector_r10`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能硝石矿 (`method_saltpeter_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能锰矿**（`building`）：`building.method_manganese_ore_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能天然气田**（`building`）：`building.method_natural_gas_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能战略矿山**（`building`）：`building.method_rare_earth_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能硝石矿**（`building`）：`building.method_saltpeter_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **锰矿石**（`good`）：`good.manganese_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **天然气**（`good`）：`good.natural_gas` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硝石**（`good`）：`good.saltpeter` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 铁矿石：`country.resource.iron_ore.use_factor`：+12%
- 采掘部门产出：`country.output.extractive_factor`：+22%
  - 效果机制：传感调度减少贫化遗漏。
  - 运行时消费者：`NativeEconomyRuntime::effective_resource_use_quantity`
  - 效果机制：自主采矿提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 计算生物学 (`tech.computational_biology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.computational_biology` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 生物信息学 (`tech.bioinformatics`)：该科技需要先掌握 「生物信息学」。
- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

农业领域研究效率 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+22%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 气候建模 (`tech.climate_modeling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.climate_modeling` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 数值天气预报 (`tech.numerical_weather_prediction`)：该科技需要先掌握 「数值天气预报」。

#### 发现启发（仅用于揭示）

- 已发现信号「能源产出规模 100000」（development.output.energy.100000\_1095d）

#### 效果摘要

旱灾损失 -12%；洪灾损失 -12%；寒冷损失 -12%；热害损失 -12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 旱灾损失：`country.climate.drought_loss_factor`：+12%
- 洪灾损失：`country.climate.flood_loss_factor`：+12%
- 寒冷损失：`country.climate.cold_stress_factor`：+12%
- 热害损失：`country.climate.heat_stress_factor`：+12%
  - 效果机制：气候建模降低全国气候型生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：气候建模降低全国气候型生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：气候建模降低全国气候型生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：气候建模降低全国气候型生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 智能电网 (`tech.smart_grid`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.smart_grid` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电网 (`tech.electric_grid`)：智能电网改造既有输配电网（智能电网 ← 电网、微处理器、互联网）。
- 网络计算 (`tech.networked_computing`)：分布式计量与调度依赖计算机网络。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：智能化电池厂；解锁建筑：智能化电动机厂；解锁建筑：智能化绝缘电缆厂；解锁建筑：智能化线材厂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电池 (`batteries`)；电动机 (`electric_motor`)；绝缘电缆 (`insulated_cable`)；金属线材 (`wire`)
- **建筑 / 生产方式：** 智能化电池厂 (`method_batteries_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能化线材厂 (`method_wire_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化电池厂**（`building`）：`building.method_batteries_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化电动机厂**（`building`）：`building.method_electric_motor_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化绝缘电缆厂**（`building`）：`building.method_insulated_cable_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化线材厂**（`building`）：`building.method_wire_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电池**（`good`）：`good.batteries` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **电动机**（`good`）：`good.electric_motor` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **金属线材**（`good`）：`good.wire` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：智能电网提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 算法治理 (`tech.algorithmic_governance`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.algorithmic_governance` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`)；人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 机器学习 (`tech.machine_learning`)：算法治理以机器学习模型辅助公共决策。
- 知识经济 (`tech.knowledge_economy`)：算法治理面向知识经济下的公共服务。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：智能水网控制中心；全社会生产投入 -3%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 智能水网控制中心 (`smart_water_network`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能水网控制中心**（`building`）：`building.smart_water_network` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会生产投入：`country.production.input_factor`：+3%
  - 效果机制：算法治理减少跨部门配置与采购浪费。
  - 运行时消费者：`NativeEconomyRuntime::effective_production_input_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 分布式智能 (`tech.distributed_intelligence`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.distributed_intelligence` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：分布式智能运行在计算机网络上。
- 机器学习 (`tech.machine_learning`)：各节点的智能来自机器学习模型。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 70%」（development.satisfaction.70\_1095d）

#### 效果摘要

解锁建筑：智能化电子元件厂；解锁建筑：智能化无线电设备厂；科学领域研究效率 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电子元件 (`electronic_components`)；无线电设备 (`radio_equipment`)
- **建筑 / 生产方式：** 智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化电子元件厂**（`building`）：`building.method_electronic_components_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化无线电设备厂**（`building`）：`building.method_radio_equipment_works_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **电子元件**（`good`）：`good.electronic_components` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **无线电设备**（`good`）：`good.radio_equipment` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+22%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`

#### 被以下科技作为硬前置

- 认知自动化 (`tech.cognitive_automation`)：该科技需要先掌握 「分布式智能」。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 智能育种 (`tech.intelligent_breeding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.intelligent_breeding` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 生物信息学 (`tech.bioinformatics`)：智能育种依赖基因组数据分析。
- 机器学习 (`tech.machine_learning`)：基因组选择模型来自机器学习。

#### 发现启发（仅用于揭示）

- 已发现信号「农业产出规模 100000」（development.output.agriculture.100000\_1095d）

#### 效果摘要

农业领域研究效率 +22%；旱作生产·寒冷损失 -16%；旱作生产·热害损失 -16%；牧业生产·寒冷损失 -16%；牧业生产·热害损失 -16%；商品「小麦」产量 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 农业领域研究效率：`country.research.agriculture_efficiency`：+22%
- 旱作生产·寒冷损失：`country.climate.profile.dryland_crop.cold_stress_loss_factor`：+16%
- 旱作生产·热害损失：`country.climate.profile.dryland_crop.heat_stress_loss_factor`：+16%
- 牧业生产·寒冷损失：`country.climate.profile.pasture_livestock.cold_stress_loss_factor`：+16%
- 牧业生产·热害损失：`country.climate.profile.pasture_livestock.heat_stress_loss_factor`：+16%
- 小麦：`country.output.good.wheat_grain_factor`：+12%
  - 效果机制：自然观察、生物分类与育种方法提高农业研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：智能育种降低旱作生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：智能育种降低旱作生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：智能育种降低牧业生产建筑的寒冷损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：智能育种降低牧业生产建筑的热害损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：智能育种提高小麦产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自主物流 (`tech.autonomous_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_logistics` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 自动化物流 (`tech.automated_logistics`)：自主物流在自动化物流上去掉人工调度。
- 自主系统 (`tech.autonomous_systems`)：无人船舶与车辆依赖自主系统。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自主航运调度港；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 远洋船舶 (`oceanic_vessels`)
- **建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自主航运调度港**（`building`）：`building.method_autonomous_shipping` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：自主物流提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 智能科学代理 (`tech.scientific_agents`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scientific_agents` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 机器学习 (`tech.machine_learning`)：智能科学代理以机器学习模型提出与筛选假设。
- 开放科学网络 (`tech.open_science_networks`)：科学代理从开放科学网络获取数据与文献。

#### 发现启发（仅用于揭示）

- 已发现信号「能源就业 6250」（development.employment.energy.6250\_1095d）

#### 效果摘要

解锁建筑：智能仪器厂；解锁建筑：智能硫矿；解锁建筑：自动化锌矿；科学领域研究效率 +22%；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科学仪器 (`scientific_instruments`)；硫磺 (`sulfur`)；锌矿石 (`zinc_ore`)
- **建筑 / 生产方式：** 智能仪器厂 (`method_scientific_instrument_works_r10`)；智能硫矿 (`method_sulfur_collector_r10`)；自动化锌矿 (`method_zinc_ore_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能仪器厂**（`building`）：`building.method_scientific_instrument_works_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能硫矿**（`building`）：`building.method_sulfur_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化锌矿**（`building`）：`building.method_zinc_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **科学仪器**（`good`）：`good.scientific_instruments` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **硫磺**（`good`）：`good.sulfur` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **锌矿石**（`good`）：`good.zinc_ore` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 科学领域研究效率：`country.research.science_efficiency`：+22%
- 采掘部门产出：`country.output.extractive_factor`：+12%
  - 效果机制：通信、计算与控制方法提高科学研究效率。
  - 运行时消费者：`NativeCountryRuntime::process_research_day`
  - 效果机制：智能科学代理提高采掘部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自主林业经营 (`tech.autonomous_forestry_operations`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_forestry_operations` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | applied\_method |
| 布局路线 | branch.computation\_control |
| 主要路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 全部路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 自主系统 (`tech.autonomous_systems`)：无人林业机械依赖自主系统。
- 卫星观测 (`tech.satellite_observation`)：林分监测与采伐规划依赖卫星观测。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自主林业经营站；全社会经济产出 +8%

#### 机会成本

多条知识路线汇合为一个可见应用节点，避免建筑条件隐式叠加。

#### 内容解锁

- **物资：** 原木 (`logs`)
- **建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自主林业经营站**（`building`）：`building.method_autonomous_forestry` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：自主林业经营提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 人机共治 (`tech.human_machine_cogovernance`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.human_machine_cogovernance` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | era\_candidate |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 知识经济 (`tech.knowledge_economy`)：人机共治面向知识经济的组织形态。
- 机器学习 (`tech.machine_learning`)：共治中的机器一方以机器学习模型参与决策。

#### 发现启发（仅用于揭示）

- 已发现信号「制造产出规模 100000」（development.output.manufacturing.100000\_1095d）

#### 效果摘要

全社会经济产出 +4%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+4%
  - 效果机制：人机共治提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 算法管理 (`tech.algorithmic_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.algorithmic_management` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：该科技需要先掌握 「网络计算」。
- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：智能石油化工厂；解锁建筑：智能化塑料厂；解锁建筑：智能炼油厂；解锁建筑：智能化合成纤维厂；解锁建筑：智能化合成橡胶厂；全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石化产品 (`petrochemicals`)；塑料 (`plastics`)；精炼燃料 (`refined_fuel`)；合成纤维 (`synthetic_fiber`)；合成橡胶 (`synthetic_rubber`)
- **建筑 / 生产方式：** 智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能石油化工厂**（`building`）：`building.method_petrochemicals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化塑料厂**（`building`）：`building.method_plastics_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能炼油厂**（`building`）：`building.method_refined_fuel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化合成纤维厂**（`building`）：`building.method_synthetic_fiber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化合成橡胶厂**（`building`）：`building.method_synthetic_rubber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **石化产品**（`good`）：`good.petrochemicals` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **塑料**（`good`）：`good.plastics` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **精炼燃料**（`good`）：`good.refined_fuel` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **合成纤维**（`good`）：`good.synthetic_fiber` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **合成橡胶**（`good`）：`good.synthetic_rubber` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：算法管理提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

- 自主劳动协调 (`tech.autonomous_labor_coordination`)：自主劳动协调由算法管理的派工系统发展而来。

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自适应灌溉 (`tech.adaptive_irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.adaptive_irrigation` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 全部路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 精准灌溉 (`tech.precision_irrigation`)：自适应灌溉在精准灌溉上实现闭环自调。
- 自主系统 (`tech.autonomous_systems`)：闭环配水依赖自主控制系统。

#### 发现启发（仅用于揭示）

- 已发现信号「农业就业 6250」（development.employment.agriculture.6250\_1095d）

#### 效果摘要

水田生产·旱灾损失 -20%；水田生产·洪灾损失 -20%；商品「稻米」产量 +28%；农业部门产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 水田生产·旱灾损失：`country.climate.profile.paddy_crop.drought_loss_factor`：+20%
- 水田生产·洪灾损失：`country.climate.profile.paddy_crop.flood_loss_factor`：+20%
- 稻米：`country.output.good.rice_grain_factor`：+28%
- 农业部门产出：`country.output.agriculture_factor`：+28%
  - 效果机制：自适应灌溉降低水田生产建筑的旱灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：自适应灌溉降低水田生产建筑的洪灾损失。
  - 运行时消费者：`NativeEconomyRuntime::production_climate_capacity_q16`
  - 效果机制：自适应灌溉提高稻米产量。
  - 运行时消费者：`NativeEconomyRuntime::effective_building_output_quantity`
  - 效果机制：自适应灌溉提高农业部门产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 知识合作社 (`tech.knowledge_cooperatives`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.knowledge_cooperatives` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 开放科学网络 (`tech.open_science_networks`)：该科技需要先掌握 「开放科学网络」。
- 知识经济 (`tech.knowledge_economy`)：该科技需要先掌握 「知识经济」。

#### 发现启发（仅用于揭示）

- 已发现信号「综合满意度 70%」（development.satisfaction.70\_1095d）

#### 效果摘要

全社会经济产出 +8%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 全社会经济产出：`country.economy_output_factor`：+8%
  - 效果机制：知识合作社提高全社会经济产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自主劳动协调 (`tech.autonomous_labor_coordination`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_labor_coordination` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 算法管理 (`tech.algorithmic_management`)：自主劳动协调由算法管理的派工系统发展而来。
- 自主系统 (`tech.autonomous_systems`)：协调对象包括自主运行的机器。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：智能冶铝厂；解锁建筑：智能化不锈钢厂；「炼钢」生产家族建筑产出 +22%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝 (`aluminum`)；不锈钢 (`stainless_steel`)
- **建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能冶铝厂**（`building`）：`building.method_aluminum_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化不锈钢厂**（`building`）：`building.method_stainless_steel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **铝**（`good`）：`good.aluminum` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **不锈钢**（`good`）：`good.stainless_steel` → `production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- 炼钢：`country.output.family.steelmaking_factor`：+22%
  - 效果机制：自主劳动协调提高炼钢建筑产出。
  - 运行时消费者：`NativeEconomyRuntime::refresh_building_modifier_factors`

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 认知自动化 (`tech.cognitive_automation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cognitive_automation` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20000000 科技点（`technology_points`） |
| 节点标记 | 时代里程碑 |
| 网络角色 | backbone |
| 锚点类型 | milestone |
| 节点角色 | milestone |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | milestone |

#### 硬前置（决定研发资格）

- 机器学习 (`tech.machine_learning`)：该科技需要先掌握 「机器学习」。
- 分布式智能 (`tech.distributed_intelligence`)：该科技需要先掌握 「分布式智能」。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

完成时代里程碑并开放下一时代

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 18 项候选中的任意 7 项：
- 自动化农业 (`tech.automated_agriculture`)
- 自主系统 (`tech.autonomous_systems`)
- 机器学习 (`tech.machine_learning`)
- 人机共治 (`tech.human_machine_cogovernance`)
- 智能育种 (`tech.intelligent_breeding`)
- 机器人制造 (`tech.robotic_manufacturing`)
- 气候建模 (`tech.climate_modeling`)
- 算法治理 (`tech.algorithmic_governance`)
- 神经网络 (`tech.neural_networks`)
- 自主采矿 (`tech.autonomous_mining`)
- 智能电网 (`tech.smart_grid`)
- 自适应灌溉 (`tech.adaptive_irrigation`)
- 分布式智能 (`tech.distributed_intelligence`)
- 自主劳动协调 (`tech.autonomous_labor_coordination`)
- 知识合作社 (`tech.knowledge_cooperatives`)
- 算法管理 (`tech.algorithmic_management`)
- 自主物流 (`tech.autonomous_logistics`)
- 人机协作 (`tech.human_machine_collaboration`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 高端芯片厂 (`app.advanced_chip_fab`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.advanced_chip_fab` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器学习 (`tech.machine_learning`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化农场 (`app.automated_farm`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.automated_farm` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化农场 (`automated_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化棉花农场 (`app.method_cotton_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_cotton_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化棉花农场 (`method_cotton_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化亚麻农场 (`app.method_flax_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_flax_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化亚麻农场 (`method_flax_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化玉米农场 (`app.method_maize_farm_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_maize_farm_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化玉米农场 (`method_maize_farm_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化药材农场 (`app.method_medicinal_herbs_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_medicinal_herbs_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化药材农场 (`method_medicinal_herbs_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化马铃薯农场 (`app.method_potato_farm_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_potato_farm_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化马铃薯农场 (`method_potato_farm_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化稻作农场 (`app.method_rice_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rice_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 芦苇收割 (`tech.reed_harvesting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化稻作农场 (`method_rice_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化橡胶种植园 (`app.method_rubber_tree_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rubber_tree_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化橡胶种植园 (`method_rubber_tree_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能牧业站 (`app.method_smart_husbandry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_smart_husbandry` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 畜群管理 (`tech.herd_management`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能牧业站 (`method_smart_husbandry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化香料种植园 (`app.method_spice_plants_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_spice_plants_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 棉花园圃 (`tech.cotton_gardening`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化香料种植园 (`method_spice_plants_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化小麦农场 (`app.method_wheat_farm_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wheat_farm_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自动化农业 (`tech.automated_agriculture`)：该知识是此产业交汇自动生效的必要条件。
- 雨养田体系 (`tech.rainfed_field_system`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化小麦农场 (`method_wheat_farm_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化洗涤剂厂 (`app.method_detergent_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_detergent_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 神经网络 (`tech.neural_networks`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化洗涤剂厂 (`method_detergent_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能战略金属冶炼厂 (`app.method_rare_earth_metals_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rare_earth_metals_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 神经网络 (`tech.neural_networks`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化家用电器厂 (`app.method_household_appliances_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_household_appliances_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 人机协作 (`tech.human_machine_collaboration`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 流水线组织 (`tech.assembly_line`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化家用电器厂 (`method_household_appliances_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自主控制系统厂 (`app.autonomous_systems_plant`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.autonomous_systems_plant` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主系统 (`tech.autonomous_systems`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 先进冶金 (`tech.advanced_metallurgy`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自主控制系统厂 (`autonomous_systems_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化汽车厂 (`app.method_automobiles_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_automobiles_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 内燃机 (`tech.internal_combustion`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 先进冶金 (`tech.advanced_metallurgy`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化汽车厂 (`method_automobiles_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化发动机厂 (`app.method_engines_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_engines_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 内燃机 (`tech.internal_combustion`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 工业生态 (`tech.industrial_ecology`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化发动机厂 (`method_engines_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化炸药厂 (`app.method_explosives_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_explosives_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化炸药厂 (`method_explosives_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化核燃料厂 (`app.method_nuclear_fuel_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_nuclear_fuel_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 核裂变 (`tech.nuclear_fission`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 核燃料循环 (`tech.nuclear_fuel_cycle`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化核反应堆设备厂 (`app.method_reactor_component_works_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_reactor_component_works_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 核能 (`tech.nuclear_energy`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化核反应堆设备厂 (`method_reactor_component_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能玻璃器皿工厂 (`app.smart_glassware_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.smart_glassware_factory` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能玻璃器皿工厂 (`smart_glassware_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能皮革制品工厂 (`app.smart_leather_goods_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.smart_leather_goods_factory` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 皮革鞣制 (`tech.hide_tanning`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能皮革制品工厂 (`smart_leather_goods_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能金属家用器皿工厂 (`app.smart_metal_housewares_factory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.smart_metal_housewares_factory` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 机器人制造 (`tech.robotic_manufacturing`)：该知识是此产业交汇自动生效的必要条件。
- 块炼铁 (`tech.iron_smelting`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能金属家用器皿工厂 (`smart_metal_housewares_factory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能锰矿 (`app.method_manganese_ore_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_manganese_ore_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主采矿 (`tech.autonomous_mining`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能锰矿 (`method_manganese_ore_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能天然气田 (`app.method_natural_gas_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_natural_gas_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主采矿 (`tech.autonomous_mining`)：该知识是此产业交汇自动生效的必要条件。
- 石化裂解 (`tech.petrochemical_cracking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能天然气田 (`method_natural_gas_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能战略矿山 (`app.method_rare_earth_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_rare_earth_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主采矿 (`tech.autonomous_mining`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能战略矿山 (`method_rare_earth_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能硝石矿 (`app.method_saltpeter_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_saltpeter_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主采矿 (`tech.autonomous_mining`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能硝石矿 (`method_saltpeter_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化电池厂 (`app.method_batteries_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_batteries_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能电网 (`tech.smart_grid`)：该知识是此产业交汇自动生效的必要条件。
- 工业化学 (`tech.industrial_chemistry`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电池厂 (`method_batteries_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化电动机厂 (`app.method_electric_motor_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_electric_motor_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能电网 (`tech.smart_grid`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 电动机 (`tech.electric_motors`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电动机厂 (`method_electric_motor_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化绝缘电缆厂 (`app.method_insulated_cable_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_insulated_cable_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能电网 (`tech.smart_grid`)：该知识是此产业交汇自动生效的必要条件。
- 合成材料 (`tech.synthetic_materials`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化线材厂 (`app.method_wire_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_wire_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能电网 (`tech.smart_grid`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化线材厂 (`method_wire_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化电子元件厂 (`app.method_electronic_components_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_electronic_components_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 分布式智能 (`tech.distributed_intelligence`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 电化学 (`tech.electrochemistry`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电子元件厂 (`method_electronic_components_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化无线电设备厂 (`app.method_radio_equipment_works_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_radio_equipment_works_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 分布式智能 (`tech.distributed_intelligence`)：该知识是此产业交汇自动生效的必要条件。
- 电网 (`tech.electric_grid`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化无线电设备厂 (`method_radio_equipment_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能仪器厂 (`app.method_scientific_instrument_works_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_scientific_instrument_works_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能科学代理 (`tech.scientific_agents`)：该知识是此产业交汇自动生效的必要条件。
- 自然铜冷锤 (`tech.natural_copper_working`)：该知识是此产业交汇自动生效的必要条件。
- 早期玻璃烧制 (`tech.early_glassmaking`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能仪器厂 (`method_scientific_instrument_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能硫矿 (`app.method_sulfur_collector_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_sulfur_collector_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能科学代理 (`tech.scientific_agents`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能硫矿 (`method_sulfur_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自动化锌矿 (`app.method_zinc_ore_collector_r9`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_zinc_ore_collector_r9` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 智能科学代理 (`tech.scientific_agents`)：该知识是此产业交汇自动生效的必要条件。
- 火药武器 (`tech.gunpowder_weapons`)：该知识是此产业交汇自动生效的必要条件。
- 蒸汽抽水 (`tech.steam_pumping`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化锌矿 (`method_zinc_ore_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能石油化工厂 (`app.method_petrochemicals_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_petrochemicals_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 算法管理 (`tech.algorithmic_management`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能石油化工厂 (`method_petrochemicals_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化塑料厂 (`app.method_plastics_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_plastics_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 算法管理 (`tech.algorithmic_management`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。
- 塑料工程 (`tech.plastics_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化塑料厂 (`method_plastics_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能炼油厂 (`app.method_refined_fuel_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_refined_fuel_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 算法管理 (`tech.algorithmic_management`)：该知识是此产业交汇自动生效的必要条件。
- 石油炼制 (`tech.petroleum_refining`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能炼油厂 (`method_refined_fuel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化合成纤维厂 (`app.method_synthetic_fiber_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_synthetic_fiber_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 算法管理 (`tech.algorithmic_management`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化合成橡胶厂 (`app.method_synthetic_rubber_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_synthetic_rubber_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 算法管理 (`tech.algorithmic_management`)：该知识是此产业交汇自动生效的必要条件。
- 火药配制 (`tech.gunpowder_formulation`)：该知识是此产业交汇自动生效的必要条件。
- 合成材料 (`tech.synthetic_materials`)：该知识是此产业交汇自动生效的必要条件。
- 石油化工 (`tech.petrochemical_industry`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能冶铝厂 (`app.method_aluminum_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_aluminum_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主劳动协调 (`tech.autonomous_labor_coordination`)：该知识是此产业交汇自动生效的必要条件。
- 深层地球物理 (`tech.deep_geophysics`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 智能化不锈钢厂 (`app.method_stainless_steel_plant_r10`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `app.method_stainless_steel_plant_r10` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |
| 节点标记 | 零成本自动应用 |
| 网络角色 | application |
| 锚点类型 | application\_intersection |
| 节点角色 | automatic\_application |
| 布局路线 | 无 |
| 主要路线 | 无 |
| 全部路线 | 无 |
| 开局能力标签 | 无 |
| 效果配置 | 无 |

#### 所需科技（ALL，决定自动应用）

- 自主劳动协调 (`tech.autonomous_labor_coordination`)：该知识是此产业交汇自动生效的必要条件。
- 高炉冶炼 (`tech.blast_furnace`)：该知识是此产业交汇自动生效的必要条件。
- 机械化采矿 (`tech.mechanized_mining`)：该知识是此产业交汇自动生效的必要条件。
- 特种合金 (`tech.specialty_alloys`)：该知识是此产业交汇自动生效的必要条件。
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：该知识是此产业交汇自动生效的必要条件。

#### 发现启发（仅用于揭示）

无

#### 效果摘要

全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。

#### 机会成本

无需研究点。

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化不锈钢厂 (`method_stainless_steel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无
