# 科技目录审计报告

> 自动生成文件，请勿手工编辑。权威来源为 `TechnologyCatalog`；内容解锁来自已编译的 `EconomyCatalog` 反向绑定。

## 总览

| 项目 | 数量 |
| --- | ---: |
| 科技 | 361 |
| 时代 | 11 |
| 领域 | 4 |
| 里程碑 | 11 |
| 硬前置边 | 462 |
| 应用交汇边 | 505 |
| 替代说明边 | 0 |
| 里程碑候选边 | 176 |

## 时代目录

- [石器时代](#era-1)（76 项，成本 0-5000）
- [农耕时代](#era-2)（59 项，成本 7200-12000）
- [王国时代](#era-3)（30 项，成本 18000-30000）
- [帝国时代](#era-4)（28 项，成本 42000-70000）
- [探索时代](#era-5)（25 项，成本 96000-160000）
- [启蒙时代](#era-6)（26 项，成本 216000-360000）
- [蒸汽时代](#era-7)（25 项，成本 480000-800000）
- [电气时代](#era-8)（24 项，成本 1080000-1800000）
- [原子时代](#era-9)（24 项，成本 2400000-4000000）
- [信息时代](#era-10)（23 项，成本 5400000-9000000）
- [智能时代](#era-11)（21 项，成本 12000000-20000000）

<a id="era-1"></a>
## 石器时代

共 76 项科技，研究成本范围 0-5000；时代里程碑：定居知识 (`tech.settled_knowledge`)。

### 狩猎 (`tech.hunting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hunting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「草原」（landform.grassland）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁物资：野味；解锁物资：生皮；解锁建筑：狩猎营地；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 野味 (`game_meat`)；生皮 (`raw_hide`)
- **建筑 / 生产方式：** 狩猎营地 (`stone_age_hunting_camp`)
- **自然资源：** 野生动物 (`wild_game`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 生皮刮制棚 (`hide_scraping_shelter`)；小型陷阱线 (`small_game_trapline`)

#### 结构化内容效果

- **野味**（`good`）：`good.game_meat` → `production_access` `unlock` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `production_access` `unlock` `1.0`；`existing_binding`
- **狩猎营地**（`building`）：`building.stone_age_hunting_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **野味**（`good`）：`good.game_meat` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 畜牧驯养 (`tech.animal_husbandry`)

#### 同路线后继

无

#### 应用交汇目标

- 纤维捻制 (`tech.fiber_twisting`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 全部路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「森林」（landform.forest）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁物资：采集植物食物；解锁建筑：采集营地；开放通用职业阶层岗位；可利用资源：肥沃土壤

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 采集植物食物 (`gathered_plants`)
- **建筑 / 生产方式：** 采集营地 (`gathering_ground`)
- **自然资源：** 肥沃土壤 (`fertile_soil`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 商栈 (`merchant_post`)

#### 结构化内容效果

- **采集植物食物**（`good`）：`good.gathered_plants` → `production_access` `unlock` `1.0`；`existing_binding`
- **采集营地**（`building`）：`building.gathering_ground` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 季节性采集 (`tech.seasonal_foraging`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 打制石器 (`tech.stone_knapping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.stone_knapping` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「山地」（landform.mountain）

#### 效果摘要

解锁物资：打制石器；解锁建筑：燧石采掘场；开放通用职业阶层岗位；解锁建筑：改良燧石矿坑

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 打制石器 (`chipped_stone_tools`)
- **建筑 / 生产方式：** 燧石采掘场 (`flint_quarry`)；改良燧石矿坑 (`method_flint_quarry_r1`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 露天黏土坑 (`early_clay_pit`)；石器打制工坊 (`knapping_workshop`)；自然铜冷锤工坊 (`natural_copper_workshop`)；毛石整理场 (`rubble_stone_working`)

#### 结构化内容效果

- **打制石器**（`good`）：`good.chipped_stone_tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **燧石采掘场**（`building`）：`building.flint_quarry` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **燧石原料**（`good`）：`good.flint` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **改良燧石矿坑**（`building`）：`building.method_flint_quarry_r1` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 黏土辨识 (`tech.clay_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 火种控制 (`tech.fire_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fire_control` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 火 (\`route.energy.fire\`) |
| 全部路线 | 能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「干旱经验」（weather.drought）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁建筑：公共火塘；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共火塘 (`communal_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 覆土木炭窑 (`charcoal_pit`)；砂金淘洗精炼棚 (`gold_washing_refinery`)；乳胶烟熏凝固棚 (`latex_smoking_shelter`)；传知者议事圈 (`lorekeeper_circle`)；露天陶器烧造 (`open_pottery_hearth`)；银矿火试炉 (`silver_fire_assay_hearth`)

#### 结构化内容效果

- **公共火塘**（`building`）：`building.communal_hearth` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **加工食品**（`good`）：`good.processed_food` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `input_method_access` `enable` `1.0`；`existing_binding`
- **野味**（`good`）：`good.game_meat` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 自然铜冷锤 (`tech.natural_copper_working`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 生态 · 野生植物 (\`route.ecology.plants\`) |
| 全部路线 | 生态 · 野生植物 (\`route.ecology.plants\`)；制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

- 采集 (`tech.gathering`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主粮加工产出 +10%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+10%

#### 直接后继（硬前置关系）

- 种子与繁育观察 (`tech.crop_domestication`)

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：石器打制工坊；开放通用职业阶层岗位；解锁建筑：组织化伐木场；开放通用职业阶层岗位；石器打制工坊产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石器打制工坊 (`knapping_workshop`)；组织化伐木场 (`method_timber_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 木槽溜洗场 (`primitive_gold_sluice`)；野生割胶营地 (`rubber_tapping_camp`)；木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **石器打制工坊**（`building`）：`building.knapping_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **打制石器**（`good`）：`good.chipped_stone_tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **燧石原料**（`good`）：`good.flint` → `input_method_access` `enable` `1.0`；`existing_binding`
- **组织化伐木场**（`building`）：`building.method_timber_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 石器打制工坊：`country.output.building.knapping_workshop_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 犁耕农业 (`tech.plough_agriculture`)

#### 应用交汇目标

- 犁耕农业 (`tech.plough_agriculture`)

#### 作为候选参与的里程碑

无

### 自然观察 (`tech.natural_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 全部路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁物资：药材；可利用资源：硝石；可利用资源：硅砂；科研机构产出 +11%；国家协同能力 +3%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 药材 (`medicinal_herbs`)
- **建筑 / 生产方式：** 无
- **自然资源：** 硝石 (`saltpeter`)；硅砂 (`silica_sand`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药材**（`good`）：`good.medicinal_herbs` → `production_access` `unlock` `1.0`；`existing_binding`
- **硝石**（`resource`）：`resource.saltpeter` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **硅砂**（`resource`）：`resource.silica_sand` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 科研机构：`country.output.family.research_institution_factor`：+11%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

- 口述传统 (`tech.oral_tradition`)

#### 同路线后继

- 天文历法 (`tech.celestial_calendars`)

#### 应用交汇目标

- 天文历法 (`tech.celestial_calendars`)

#### 作为候选参与的里程碑

无

### 口述传统 (`tech.oral_tradition`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oral_tradition` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 全部路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 自然观察 (`tech.natural_observation`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：传知者议事圈；开放通用职业阶层岗位；开放科技职业阶层岗位；传知者议事圈产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 传知者议事圈 (`lorekeeper_circle`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **传知者议事圈**（`building`）：`building.lorekeeper_circle` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 传知者议事圈：`country.output.building.lorekeeper_circle_factor`：+20%

#### 直接后继（硬前置关系）

- 季节历 (`tech.seasonal_calendar`)

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；气候 · 火 (\`route.climate.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

金属工具业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 刀耕火种玉米地 (`swidden_maize_plot`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+12%
- `country.output.agriculture_factor`：+3%

#### 直接后继（硬前置关系）

- 窑烧控制 (`tech.kiln_firing`)

#### 同路线后继

- 窑烧控制 (`tech.kiln_firing`)

#### 应用交汇目标

- 窑烧控制 (`tech.kiln_firing`)
- 自然铜冷锤 (`tech.natural_copper_working`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 渔舟 (`tech.fishing_boats`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fishing_boats` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | fishing |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「淡水鱼群」（resource.freshwater\_fish）
  - 已发现信号「海洋鱼类」（resource.marine\_fish）
  - 已发现信号「海岸」（landform.coast）

#### 效果摘要

解锁建筑：帆船渔场；开放通用职业阶层岗位；开放通用职业阶层岗位；帆船渔场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 帆船渔场 (`method_marine_fish_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **帆船渔场**（`building`）：`building.method_marine_fish_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **鱼类**（`good`）：`good.fish` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 帆船渔场：`country.output.building.method_marine_fish_collector_r2_factor`：+25%

#### 直接后继（硬前置关系）

- 陶器容器体系 (`tech.pottery`)

#### 同路线后继

- 陶器容器体系 (`tech.pottery`)

#### 应用交汇目标

- 陶器容器体系 (`tech.pottery`)
- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 种子与繁育观察 (`tech.crop_domestication`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_domestication` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 季节性采集 (`tech.seasonal_foraging`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)；菜蔬农场 (`fertile_soil_collector`)；亚麻农场 (`flax_collector`)；林下遮阴香料园 (`spice_shade_garden`)；自给农庄 (`subsistence_farm`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 打制石器 (`tech.stone_knapping`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

可利用资源：黏土；黏土采掘产出 +10%

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

- 黏土采掘：`country.output.family.clay_extraction_factor`：+10%

#### 直接后继（硬前置关系）

- 磨制石器 (`tech.ground_stone_tools`)

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 自然铜辨识 (`tech.natural_copper_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_copper_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

可利用资源：铜矿；铜业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 铜矿 (`copper_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)；自然铜冷锤工坊 (`natural_copper_workshop`)

#### 结构化内容效果

- **铜矿**（`resource`）：`resource.copper_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铜业：`country.output.family.copper_extraction_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 铜矿焙烧 (`tech.copper_ore_roasting`)

#### 作为候选参与的里程碑

无

### 自然铜冷锤 (`tech.natural_copper_working`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_copper_working` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁建筑：自然铜冷锤工坊；开放通用职业阶层岗位；自然铜冷锤工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自然铜冷锤工坊 (`natural_copper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自然铜冷锤工坊**（`building`）：`building.natural_copper_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自然铜冷锤工坊：`country.output.building.natural_copper_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 铜退火 (`tech.copper_annealing`)
- 木炭坩埚炼铜 (`tech.copper_metallurgy`)
- 铜锡配比与铸造 (`tech.bronze_casting`)

#### 同路线后继

- 铜锡配比与铸造 (`tech.bronze_casting`)

#### 应用交汇目标

- 铜锡配比与铸造 (`tech.bronze_casting`)
- 铜矿焙烧 (`tech.copper_ore_roasting`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 铜退火 (`tech.copper_annealing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_annealing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 自然铜冷锤 (`tech.natural_copper_working`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁建筑：露天青铜作坊；开放通用职业阶层岗位；露天青铜作坊产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露天青铜作坊 (`ore_bronzesmith_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)

#### 结构化内容效果

- **露天青铜作坊**（`building`）：`building.ore_bronzesmith_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **青铜工具**（`good`）：`good.bronze_tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜矿石**（`good`）：`good.copper_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锡矿石**（`good`）：`good.tin_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 露天青铜作坊：`country.output.building.ore_bronzesmith_camp_factor`：+20%

#### 直接后继（硬前置关系）

- 锡矿辨识 (`tech.tin_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 铜矿焙烧 (`tech.copper_ore_roasting`)

#### 作为候选参与的里程碑

无

### 锡矿辨识 (`tech.tin_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tin_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 锡 (\`route.resource.tin\`) |
| 全部路线 | 资源 · 锡 (\`route.resource.tin\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 铜退火 (`tech.copper_annealing`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「锡矿贸易接触」（contact.tin）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：锡矿石；可利用资源：锡矿；锡业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锡矿石 (`tin_ore`)
- **建筑 / 生产方式：** 无
- **自然资源：** 锡矿 (`tin_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 土法炼锡炉 (`early_tin_smelter`)；露天青铜作坊 (`ore_bronzesmith_camp`)；锡矿 (`tin_ore_collector`)

#### 结构化内容效果

- **锡矿石**（`good`）：`good.tin_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **锡矿**（`resource`）：`resource.tin_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 锡业：`country.output.family.tin_extraction_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 铜矿焙烧 (`tech.copper_ore_roasting`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 狩猎 (`tech.hunting`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

畜牧业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 游牧营地 (`pastoral_camp`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+10%

#### 直接后继（硬前置关系）

- 动物追踪 (`tech.animal_tracking`)

#### 同路线后继

无

#### 应用交汇目标

- 纤维捻制 (`tech.fiber_twisting`)

#### 作为候选参与的里程碑

无

### 纤维捻制 (`tech.fiber_twisting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fiber_twisting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：布料；解锁建筑：家庭织造棚；开放通用职业阶层岗位；家庭织造棚产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)
- **建筑 / 生产方式：** 家庭织造棚 (`household_weaving_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)；植物纤维抄纸坊 (`plant_fiber_paper_workshop`)

#### 结构化内容效果

- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`existing_binding`
- **家庭织造棚**（`building`）：`building.household_weaving_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家庭织造棚：`country.output.building.household_weaving_shelter_factor`：+25%

#### 直接后继（硬前置关系）

- 亚麻与韧皮辨识 (`tech.flax_identification`)
- 织造 (`tech.weaving`)
- 织机织造 (`tech.loom_weaving`)

#### 同路线后继

- 织机织造 (`tech.loom_weaving`)

#### 应用交汇目标

- 织机织造 (`tech.loom_weaving`)
- 畜群管理 (`tech.herd_management`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 食物储藏 (`tech.food_storage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.food_storage` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主粮加工产出 +11%；国家协同能力 +3%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+11%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 炉火保存 (`tech.hearth_preservation`)
- 留种选育 (`tech.seed_selection`)

#### 同路线后继

- 发酵保存 (`tech.fermentation`)

#### 应用交汇目标

- 发酵保存 (`tech.fermentation`)

#### 作为候选参与的里程碑

无

### 早期贸易 (`tech.early_trade`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.early_trade` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | \`starter.trade\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

解锁建筑：早期商栈；开放通用职业阶层岗位

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 早期商栈 (`early_merchant_post`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **早期商栈**（`building`）：`building.early_merchant_post` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 共同体分工 (`tech.communal_specialization`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 共同体分工 (`tech.communal_specialization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.communal_specialization` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 3000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 早期贸易 (`tech.early_trade`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁建筑：商栈；开放通用职业阶层岗位；商栈产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商栈 (`merchant_post`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 传知者议事圈 (`lorekeeper_circle`)

#### 结构化内容效果

- **商栈**（`building`）：`building.merchant_post` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 商栈：`country.output.building.merchant_post_factor`：+25%

#### 直接后继（硬前置关系）

- 家庭生产 (`tech.household_production`)

#### 同路线后继

- 永久聚落 (`tech.permanent_settlements`)

#### 应用交汇目标

- 永久聚落 (`tech.permanent_settlements`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

- 畜牧驯养 (`tech.animal_husbandry`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁建筑：商业狩猎与毛皮站；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：小型陷阱线；商业狩猎与毛皮站产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商业狩猎与毛皮站 (`method_stone_age_hunting_camp_r4`)；小型陷阱线 (`small_game_trapline`)
- **自然资源：** 野生动物 (`wild_game`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **商业狩猎与毛皮站**（`building`）：`building.method_stone_age_hunting_camp_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **野味**（`good`）：`good.game_meat` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **毛皮**（`good`）：`good.fur` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **小型陷阱线**（`building`）：`building.small_game_trapline` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 商业狩猎与毛皮站：`country.output.building.method_stone_age_hunting_camp_r4_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 纤维捻制 (`tech.fiber_twisting`)

#### 作为候选参与的里程碑

无

### 淡水岸捕 (`tech.freshwater_fishing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.freshwater_fishing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「淡水鱼群」（resource.freshwater\_fish）
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁物资：鱼类；解锁建筑：淡水捕鱼营地；开放通用职业阶层岗位；可利用资源：淡水鱼群

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 淡水捕鱼营地 (`freshwater_fishing_camp`)
- **自然资源：** 淡水鱼群 (`freshwater_fish`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`existing_binding`
- **淡水捕鱼营地**（`building`）：`building.freshwater_fishing_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **鱼类**（`good`）：`good.fish` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **淡水鱼群**（`resource`）：`resource.freshwater_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 砂金辨识 (`tech.gold_placer_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 野生稻采集 (`tech.wild_rice_collection`)

#### 作为候选参与的里程碑

无

### 潮间带采集 (`tech.coastal_fishing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coastal_fishing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海洋鱼类」（resource.marine\_fish）
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）

#### 效果摘要

解锁物资：鱼类；解锁建筑：沿岸渔场；开放通用职业阶层岗位；可利用资源：海洋鱼类

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鱼类 (`fish`)
- **建筑 / 生产方式：** 沿岸渔场 (`marine_fish_collector`)
- **自然资源：** 海洋鱼类 (`marine_fish`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **鱼类**（`good`）：`good.fish` → `production_access` `unlock` `1.0`；`existing_binding`
- **沿岸渔场**（`building`）：`building.marine_fish_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **鱼类**（`good`）：`good.fish` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **海洋鱼类**（`resource`）：`resource.marine_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 磨制石器 (`tech.ground_stone_tools`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.ground_stone_tools` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 黏土辨识 (`tech.clay_identification`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：原石；解锁建筑：毛石整理场；开放通用职业阶层岗位；解锁建筑：采石场；毛石整理场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原石 (`raw_stone`)
- **建筑 / 生产方式：** 毛石整理场 (`rubble_stone_working`)；采石场 (`stone_collector`)
- **自然资源：** 石料 (`stone`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石灰石采石场 (`limestone_collector`)；石料场 (`method_stone_collector_r2`)；毛石整理场 (`rubble_stone_working`)；浅坑银矿作业 (`shallow_silver_working`)；露头煤采集场 (`surface_coal_gathering`)

#### 结构化内容效果

- **原石**（`good`）：`good.raw_stone` → `production_access` `unlock` `1.0`；`existing_binding`
- **毛石整理场**（`building`）：`building.rubble_stone_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **采石场**（`building`）：`building.stone_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **石料**（`resource`）：`resource.stone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 毛石整理场：`country.output.building.rubble_stone_working_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 土建筑 (`tech.earth_building`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.earth_building` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「干旱盆地」（landform.arid\_basin）
  - 已发现信号「黄土平原」（landform.loess\_plain）

#### 效果摘要

解锁物资：黏土；解锁建筑：土料挖掘坑；开放通用职业阶层岗位；解锁建筑：原始黏土坑

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黏土 (`clay`)
- **建筑 / 生产方式：** 土料挖掘坑 (`earth_digging_pit`)；原始黏土坑 (`primitive_clay_pit`)
- **自然资源：** 黏土 (`clay`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 日晒土坯场 (`adobe_yard`)；制砖厂 (`bricks_plant`)；露天黏土坑 (`early_clay_pit`)；原始黏土坑 (`primitive_clay_pit`)

#### 结构化内容效果

- **黏土**（`good`）：`good.clay` → `production_access` `unlock` `1.0`；`existing_binding`
- **土料挖掘坑**（`building`）：`building.earth_digging_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原始黏土坑**（`building`）：`building.primitive_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **黏土**（`resource`）：`resource.clay` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

- 燧石辨识 (`tech.flint_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 季节历 (`tech.seasonal_calendar`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.seasonal_calendar` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 口述传统 (`tech.oral_tradition`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

科研机构产出 +10%

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

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

- 地表银脉辨识 (`tech.silver_vein_identification`)

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 食物储藏 (`tech.food_storage`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：熟制主食；解锁建筑：主食厨房；开放通用职业阶层岗位；开放通用职业阶层岗位；主食厨房产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 熟制主食 (`prepared_staples`)
- **建筑 / 生产方式：** 主食厨房 (`staple_kitchen`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **熟制主食**（`good`）：`good.prepared_staples` → `production_access` `unlock` `1.0`；`existing_binding`
- **主食厨房**（`building`）：`building.staple_kitchen` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **熟制主食**（`good`）：`good.prepared_staples` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 主食厨房：`country.output.building.staple_kitchen_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 共同体分工 (`tech.communal_specialization`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

科研机构产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)；家庭玉米园圃 (`maize_garden`)；林下遮阴香料园 (`spice_shade_garden`)；自给农庄 (`subsistence_farm`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原」（landform.grassland）
  - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：畜牧产品；解锁建筑：游牧营地；开放通用职业阶层岗位；可利用资源：牧场承载力；游牧营地产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 畜牧产品 (`livestock_products`)
- **建筑 / 生产方式：** 游牧营地 (`pastoral_camp`)
- **自然资源：** 牧场承载力 (`pasture`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **畜牧产品**（`good`）：`good.livestock_products` → `production_access` `unlock` `1.0`；`existing_binding`
- **游牧营地**（`building`）：`building.pastoral_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **牧场承载力**（`resource`）：`resource.pasture` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 游牧营地：`country.output.building.pastoral_camp_factor`：+25%

#### 直接后继（硬前置关系）

- 游牧放牧 (`tech.pastoralism`)
- 马匹驯化 (`tech.horse_domestication`)

#### 同路线后继

- 马匹驯化 (`tech.horse_domestication`)

#### 应用交汇目标

- 马匹驯化 (`tech.horse_domestication`)
- 纤维捻制 (`tech.fiber_twisting`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 野生玉米采集地 (`wild_maize_stand`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

解锁物资：玉米；解锁建筑：野生玉米采集地；开放通用职业阶层岗位；野生玉米采集地产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 野生玉米采集地 (`wild_maize_stand`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生玉米采集地**（`building`）：`building.wild_maize_stand` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 野生玉米采集地：`country.output.building.wild_maize_stand_factor`：+25%

#### 直接后继（硬前置关系）

- 玉米留种 (`tech.maize_seed_saving`)
- 玉米选育 (`tech.maize_selection`)
- 玉米园圃 (`tech.maize_garden_horticulture`)

#### 同路线后继

- 玉米园圃 (`tech.maize_garden_horticulture`)

#### 应用交汇目标

- 玉米园圃 (`tech.maize_garden_horticulture`)
- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生玉米采集 (`tech.wild_maize_collection`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

大田作物农业产出 +10%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

- 玉米繁育 (`tech.maize_propagation`)

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 玉米留种 (`tech.maize_seed_saving`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 退水玉米地 (`floodplain_maize_plot`)；玉米庄园 (`landed_estate`)；家庭玉米园圃 (`maize_garden`)；雨养玉米田 (`rainfed_maize_field`)；刀耕火种玉米地 (`swidden_maize_plot`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 野生谷穗采集地 (`wild_wheat_stand`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

无

### 野生谷穗采集 (`tech.wild_wheat_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_wheat_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁物资：小麦；解锁建筑：野生谷穗采集地；开放通用职业阶层岗位；野生谷穗采集地产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 野生谷穗采集地 (`wild_wheat_stand`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生谷穗采集地**（`building`）：`building.wild_wheat_stand` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 野生谷穗采集地：`country.output.building.wild_wheat_stand_factor`：+25%

#### 直接后继（硬前置关系）

- 小麦留种 (`tech.wheat_seed_saving`)
- 旱作农业 (`tech.dryland_farming`)
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 同路线后继

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)
- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 小麦留种 (`tech.wheat_seed_saving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wheat_seed_saving` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生谷穗采集 (`tech.wild_wheat_collection`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

大田作物农业产出 +10%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

- 小麦繁育 (`tech.wheat_propagation`)

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 小麦留种 (`tech.wheat_seed_saving`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)；退水小麦地 (`floodplain_wheat_plot`)；雨养小麦地 (`rainfed_wheat_plot`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)；小麦农场 (`wheat_farm`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 野生稻沼泽 (`wild_rice_marsh`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 芦苇辨识 (`tech.reed_identification`)

#### 作为候选参与的里程碑

无

### 野生稻采集 (`tech.wild_rice_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_rice_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁物资：稻米；解锁建筑：野生稻沼泽；开放通用职业阶层岗位；野生稻沼泽产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 野生稻沼泽 (`wild_rice_marsh`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生稻沼泽**（`building`）：`building.wild_rice_marsh` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 野生稻沼泽：`country.output.building.wild_rice_marsh_factor`：+25%

#### 直接后继（硬前置关系）

- 稻种留存 (`tech.rice_seed_saving`)
- 水田畦埂 (`tech.paddy_bunding`)
- 水田稻作 (`tech.rice_paddy_cultivation`)

#### 同路线后继

- 水田稻作 (`tech.rice_paddy_cultivation`)

#### 应用交汇目标

- 水田稻作 (`tech.rice_paddy_cultivation`)
- 芦苇辨识 (`tech.reed_identification`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 稻种留存 (`tech.rice_seed_saving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rice_seed_saving` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生稻采集 (`tech.wild_rice_collection`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

大田作物农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)；稻作农场 (`rice_collector`)；旱稻田 (`upland_rice_plot`)；湿地稻园 (`wetland_rice_garden`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 芦苇辨识 (`tech.reed_identification`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

高地农业产出 +10%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

无

### 野生块茎挖掘 (`tech.wild_tuber_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_tuber_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「山地」（landform.mountain）

#### 效果摘要

解锁物资：马铃薯；解锁建筑：野生块茎采集地；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 野生块茎采集地 (`wild_tuber_patch`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生块茎采集地**（`building`）：`building.wild_tuber_patch` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **马铃薯**（`good`）：`good.potatoes` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

无

### 块茎保存 (`tech.tuber_storage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tuber_storage` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

高地农业产出 +12%；国家协同能力 +3%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+12%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 块茎繁育 (`tech.potato_propagation`)
- 梯田农业 (`tech.terrace_farming`)
- 高地块茎农业 (`tech.highland_tuber_farming`)

#### 同路线后继

- 高地块茎农业 (`tech.highland_tuber_farming`)

#### 应用交汇目标

- 高地块茎农业 (`tech.highland_tuber_farming`)
- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 块茎繁育 (`tech.potato_propagation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.potato_propagation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁物资：马铃薯；高地农业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马铃薯 (`potatoes`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)；马铃薯农场 (`potato_collector`)

#### 结构化内容效果

- **马铃薯**（`good`）：`good.potatoes` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 高地农业：`country.output.family.highland_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）
  - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

织布业产出 +10%

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

- 织布业：`country.output.family.cloth_weaving_factor`：+10%

#### 直接后继（硬前置关系）

- 野生棉铃采集 (`tech.wild_cotton_collection`)

#### 同路线后继

无

#### 应用交汇目标

- 渔舟 (`tech.fishing_boats`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

- 棉花辨识 (`tech.cotton_identification`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）
  - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

织布业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 手工轧棉棚 (`cotton_ginning_shelter`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 织布业：`country.output.family.cloth_weaving_factor`：+10%

#### 直接后继（硬前置关系）

- 香料植物辨识 (`tech.spice_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 渔舟 (`tech.fishing_boats`)

#### 作为候选参与的里程碑

无

### 亚麻与韧皮辨识 (`tech.flax_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flax_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 纤维捻制 (`tech.fiber_twisting`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

织布业产出 +10%

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

- 织布业：`country.output.family.cloth_weaving_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 畜群管理 (`tech.herd_management`)

#### 作为候选参与的里程碑

无

### 野生韧皮采集 (`tech.wild_flax_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_flax_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「草原」（landform.grassland）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁物资：韧皮纤维；解锁物资：衣物；解锁建筑：野生韧皮纤维营地；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 韧皮纤维 (`bast_fiber`)；衣物 (`clothing`)
- **建筑 / 生产方式：** 野生韧皮纤维营地 (`bast_fiber_camp`)；韧皮裹衣棚 (`bast_wrap_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 亚麻农场 (`flax_collector`)；沤麻池 (`flax_retting_pit`)

#### 结构化内容效果

- **韧皮纤维**（`good`）：`good.bast_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生韧皮纤维营地**（`building`）：`building.bast_fiber_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **韧皮纤维**（`good`）：`good.bast_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **韧皮裹衣棚**（`building`）：`building.bast_wrap_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **韧皮纤维**（`good`）：`good.bast_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 畜群管理 (`tech.herd_management`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 野生棉铃采集 (`tech.wild_cotton_collection`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）
  - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

专用商品作物农业产出 +10%

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

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 渔舟 (`tech.fishing_boats`)

#### 作为候选参与的里程碑

无

### 野生香料采集 (`tech.wild_spice_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_spice_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）
  - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

解锁物资：香料；专用商品作物农业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 香料 (`spices`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 林下遮阴香料园 (`spice_shade_garden`)

#### 结构化内容效果

- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+12%
- `country.output.agriculture_factor`：+3%

#### 直接后继（硬前置关系）

- 橡胶树辨识 (`tech.rubber_identification`)
- 香料栽培 (`tech.spice_cultivation`)
- 遮阴香料园 (`tech.spice_shade_gardening`)

#### 同路线后继

- 遮阴香料园 (`tech.spice_shade_gardening`)

#### 应用交汇目标

- 遮阴香料园 (`tech.spice_shade_gardening`)
- 渔舟 (`tech.fishing_boats`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 橡胶树辨识 (`tech.rubber_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rubber_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 野生香料采集 (`tech.wild_spice_collection`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

化学工业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 野生割胶营地 (`rubber_tapping_camp`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 化学工业：`country.output.family.chemical_industry_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 渔舟 (`tech.fishing_boats`)

#### 作为候选参与的里程碑

无

### 野生割胶 (`tech.wild_latex_tapping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wild_latex_tapping` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁物资：天然乳胶；解锁建筑：野生割胶营地；开放通用职业阶层岗位；适应温度条件；野生割胶营地产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 天然乳胶 (`latex`)
- **建筑 / 生产方式：** 野生割胶营地 (`rubber_tapping_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 乳胶烟熏凝固棚 (`latex_smoking_shelter`)

#### 结构化内容效果

- **天然乳胶**（`good`）：`good.latex` → `production_access` `unlock` `1.0`；`existing_binding`
- **野生割胶营地**（`building`）：`building.rubber_tapping_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 野生割胶营地：`country.output.building.rubber_tapping_camp_factor`：+25%

#### 直接后继（硬前置关系）

- 天然橡胶加工 (`tech.rubber_working`)

#### 同路线后继

- 天然橡胶加工 (`tech.rubber_working`)

#### 应用交汇目标

- 天然橡胶加工 (`tech.rubber_working`)
- 卤水采集 (`tech.brine_collection`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 砂金辨识 (`tech.gold_placer_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gold_placer_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.water\_wind |
| 主要路线 | 资源 · 黄金 (\`route.resource.gold\`) |
| 全部路线 | 资源 · 黄金 (\`route.resource.gold\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 淡水岸捕 (`tech.freshwater_fishing`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

解锁建筑：木槽溜洗场；开放通用职业阶层岗位；需要河流地块条件；木槽溜洗场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 木槽溜洗场 (`primitive_gold_sluice`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **木槽溜洗场**（`building`）：`building.primitive_gold_sluice` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **含金砂矿**（`good`）：`good.gold_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 木槽溜洗场：`country.output.building.primitive_gold_sluice_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 野生稻采集 (`tech.wild_rice_collection`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 资源 · 黄金 (\`route.resource.gold\`) |
| 全部路线 | 资源 · 黄金 (\`route.resource.gold\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.precious\_metal\` |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁物资：黄金；解锁物资：含金砂矿；解锁建筑：河滩淘金场；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 黄金 (`gold`)；含金砂矿 (`gold_ore`)
- **建筑 / 生产方式：** 河滩淘金场 (`placer_gold_working`)
- **自然资源：** 金矿 (`gold_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 砂金淘洗精炼棚 (`gold_washing_refinery`)；木槽溜洗场 (`primitive_gold_sluice`)

#### 结构化内容效果

- **黄金**（`good`）：`good.gold` → `production_access` `unlock` `1.0`；`existing_binding`
- **含金砂矿**（`good`）：`good.gold_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **河滩淘金场**（`building`）：`building.placer_gold_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **含金砂矿**（`good`）：`good.gold_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金矿**（`resource`）：`resource.gold_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 野生稻采集 (`tech.wild_rice_collection`)

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 全部路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 季节历 (`tech.seasonal_calendar`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

解锁建筑：浅坑银矿作业；开放通用职业阶层岗位；需要高海拔地块条件；浅坑银矿作业产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅坑银矿作业 (`shallow_silver_working`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅坑银矿作业**（`building`）：`building.shallow_silver_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **含银矿石**（`good`）：`good.silver_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **高海拔**（`tile`）：`tile.elevation` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 浅坑银矿作业：`country.output.building.shallow_silver_working_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 全部路线 | 资源 · 白银 (\`route.resource.silver\`) |
| 开局能力标签 | \`starter.precious\_metal\` |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「银矿」（resource.silver\_ore）
  - 已发现信号「山地」（landform.mountain）
  - 已发现信号「高原」（landform.high\_plateau）

#### 效果摘要

解锁物资：白银；解锁物资：含银矿石；解锁建筑：露天银矿；开放通用职业阶层岗位

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 白银 (`silver`)；含银矿石 (`silver_ore`)
- **建筑 / 生产方式：** 露天银矿 (`surface_silver_working`)
- **自然资源：** 银矿 (`silver_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅坑银矿作业 (`shallow_silver_working`)；银矿火试炉 (`silver_fire_assay_hearth`)

#### 结构化内容效果

- **白银**（`good`）：`good.silver` → `production_access` `unlock` `1.0`；`existing_binding`
- **含银矿石**（`good`）：`good.silver_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **露天银矿**（`building`）：`building.surface_silver_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **含银矿石**（`good`）：`good.silver_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **银矿**（`resource`）：`resource.silver_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 枯枝采集 (`tech.deadwood_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deadwood_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「森林」（landform.forest）
  - 已发现信号「针叶林」（landform.conifer\_forest）

#### 效果摘要

解锁物资：原木；解锁建筑：枯枝采集营地；开放通用职业阶层岗位；解锁建筑：伐木场

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原木 (`logs`)
- **建筑 / 生产方式：** 枯枝采集营地 (`deadwood_gathering_camp`)；伐木场 (`timber_collector`)
- **自然资源：** 木材 (`timber`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)；覆土木炭窑 (`charcoal_pit`)；露天黏土坑 (`early_clay_pit`)；商栈 (`merchant_post`)

#### 结构化内容效果

- **原木**（`good`）：`good.logs` → `production_access` `unlock` `1.0`；`existing_binding`
- **枯枝采集营地**（`building`）：`building.deadwood_gathering_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **伐木场**（`building`）：`building.timber_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木材**（`resource`）：`resource.timber` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 手制陶器 (`tech.hand_pottery`)

#### 作为候选参与的里程碑

无

### 芦苇辨识 (`tech.reed_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.reed_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | identification |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「芦苇」（bio.reed）
  - 已发现信号「沼泽」（landform.marsh）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

科研机构产出 +12%；国家协同能力 +3%

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

- 科研机构：`country.output.family.research_institution_factor`：+12%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

- 灌溉 (`tech.irrigation`)

#### 同路线后继

- 灌溉 (`tech.irrigation`)

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)
- 野生稻采集 (`tech.wild_rice_collection`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 芦苇收割 (`tech.reed_harvesting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.reed_harvesting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「芦苇」（bio.reed）
  - 已发现信号「沼泽」（landform.marsh）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

解锁物资：芦苇束；解锁建筑：芦苇收割营地；开放通用职业阶层岗位；适用于沼泽地形

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 芦苇束 (`reed_bundle`)
- **建筑 / 生产方式：** 芦苇收割营地 (`reed_cutting_camp`)
- **自然资源：** 水田承载力 (`paddy_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **芦苇束**（`good`）：`good.reed_bundle` → `production_access` `unlock` `1.0`；`existing_binding`
- **芦苇收割营地**（`building`）：`building.reed_cutting_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **芦苇束**（`good`）：`good.reed_bundle` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **沼泽**（`terrain`）：`terrain.swamp` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **洪泛平原**（`terrain`）：`terrain.floodplain` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 野生稻采集 (`tech.wild_rice_collection`)

#### 作为候选参与的里程碑

无

### 草皮切割 (`tech.turf_cutting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.turf_cutting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 全部路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「苔原」（landform.tundra）
  - 已发现信号「高原」（landform.high\_plateau）

#### 效果摘要

解锁物资：草皮块；解锁建筑：草皮切割场；开放通用职业阶层岗位；适用于苔原地形

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 草皮块 (`turf_block`)
- **建筑 / 生产方式：** 草皮切割场 (`turf_cutting_ground`)
- **自然资源：** 牧场承载力 (`pasture`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **草皮块**（`good`）：`good.turf_block` → `production_access` `unlock` `1.0`；`existing_binding`
- **草皮切割场**（`building`）：`building.turf_cutting_ground` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **草皮块**（`good`）：`good.turf_block` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **苔原**（`terrain`）：`terrain.tundra` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **泥炭湿原**（`terrain`）：`terrain.moor` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **高海拔**（`tile`）：`tile.elevation` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **牧场承载力**（`resource`）：`resource.pasture` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 卤水采集 (`tech.brine_collection`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「草原」（landform.grassland）
  - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁物资：衣物；解锁建筑：生皮刮制棚；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)
- **建筑 / 生产方式：** 生皮刮制棚 (`hide_scraping_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **生皮刮制棚**（`building`）：`building.hide_scraping_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 纤维捻制 (`tech.fiber_twisting`)

#### 作为候选参与的里程碑

无

### 毛皮缝制 (`tech.fur_sewing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fur_sewing` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「苔原」（landform.tundra）
  - 已发现信号「针叶林」（landform.conifer\_forest）

#### 效果摘要

解锁物资：衣物；解锁物资：毛皮；解锁建筑：毛皮缝制棚；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)；毛皮 (`fur`)
- **建筑 / 生产方式：** 毛皮缝制棚 (`fur_sewing_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **毛皮**（`good`）：`good.fur` → `production_access` `unlock` `1.0`；`existing_binding`
- **毛皮缝制棚**（`building`）：`building.fur_sewing_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **毛皮**（`good`）：`good.fur` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 畜群管理 (`tech.herd_management`)

#### 作为候选参与的里程碑

无

### 羊毛毡制 (`tech.felt_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.felt_making` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁物资：衣物；解锁建筑：毡制帐篷；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 衣物 (`clothing`)
- **建筑 / 生产方式：** 毡制帐篷 (`felt_making_tent`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **毡制帐篷**（`building`）：`building.felt_making_tent` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **羊毛**（`good`）：`good.wool` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 畜群管理 (`tech.herd_management`)

#### 作为候选参与的里程碑

无

### 口述记忆实践 (`tech.oral_memory_practice`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oral_memory_practice` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 全部路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）
  - 已发现信号「洪水经验」（weather.major\_flood）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁物资：科技值；解锁建筑：口述记忆圈；开放科技职业阶层岗位

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 口述记忆圈 (`oral_memory_circle`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`existing_binding`
- **口述记忆圈**（`building`）：`building.oral_memory_circle` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 物候观察实践 (`tech.phenology_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.phenology_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 全部路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁物资：科技值；解锁建筑：物候观察棚；开放科技职业阶层岗位

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 物候观察棚 (`seasonal_observation_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`existing_binding`
- **物候观察棚**（`building`）：`building.seasonal_observation_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 洪水历法实践 (`tech.flood_calendar_practice`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flood_calendar_practice` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁物资：科技值；解锁建筑：洪水历法祭所；开放科技职业阶层岗位

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 洪水历法祭所 (`flood_calendar_shrine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`existing_binding`
- **洪水历法祭所**（`building`）：`building.flood_calendar_shrine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 牧群路线记忆 (`tech.pastoral_route_memory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoral_route_memory` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「牧场承载力」（resource.pasture）
  - 已发现信号「草原」（landform.grassland）
  - 已发现信号「草原平原」（landform.steppe\_plain）

#### 效果摘要

解锁物资：科技值；解锁建筑：牧群路线议事帐；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 牧群路线议事帐 (`pastoral_council_tent`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`existing_binding`
- **牧群路线议事帐**（`building`）：`building.pastoral_council_tent` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 纤维捻制 (`tech.fiber_twisting`)

#### 作为候选参与的里程碑

无

### 潮汐与航向记忆 (`tech.tide_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.tide_observation` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「风暴潮经验」（weather.storm\_surge）

#### 效果摘要

解锁物资：科技值；解锁建筑：潮汐观察屋；开放通用职业阶层岗位

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 科技值 (`technology_points`)
- **建筑 / 生产方式：** 潮汐观察屋 (`tide_observation_hut`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **科技值**（`good`）：`good.technology_points` → `production_access` `unlock` `1.0`；`existing_binding`
- **潮汐观察屋**（`building`）：`building.tide_observation_hut` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

#### 作为候选参与的里程碑

无

### 木炭烧制 (`tech.charcoal_burning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.charcoal_burning` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 能源 · 火 (\`route.energy.fire\`) |
| 全部路线 | 能源 · 火 (\`route.energy.fire\`)；生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「森林」（landform.forest）
  - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：木炭；解锁建筑：覆土木炭窑；开放通用职业阶层岗位；覆土木炭窑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 木炭 (`charcoal`)
- **建筑 / 生产方式：** 覆土木炭窑 (`charcoal_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 块炼炉 (`bloomery`)；土法炼铜炉 (`early_copper_smelter`)；烧砖窑 (`fired_brick_kiln`)；升焰陶窑 (`pottery_kiln`)

#### 结构化内容效果

- **木炭**（`good`）：`good.charcoal` → `production_access` `unlock` `1.0`；`existing_binding`
- **覆土木炭窑**（`building`）：`building.charcoal_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **木炭**（`good`）：`good.charcoal` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 覆土木炭窑：`country.output.building.charcoal_pit_factor`：+25%

#### 直接后继（硬前置关系）

- 手工锯木 (`tech.timber_sawing`)

#### 同路线后继

- 手工锯木 (`tech.timber_sawing`)

#### 应用交汇目标

- 手工锯木 (`tech.timber_sawing`)
- 手制陶器 (`tech.hand_pottery`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 铜矿焙烧 (`tech.copper_ore_roasting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_ore_roasting` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铜矿石；解锁建筑：铜矿；开放通用职业阶层岗位；开放通用职业阶层岗位；铜矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铜矿石 (`copper_ore`)
- **建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)

#### 结构化内容效果

- **铜矿石**（`good`）：`good.copper_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **铜矿**（`building`）：`building.copper_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铜矿石**（`good`）：`good.copper_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铜矿：`country.output.building.copper_ore_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 畜力牵引 (`tech.animal_traction`)

#### 同路线后继

- 畜力牵引 (`tech.animal_traction`)

#### 应用交汇目标

- 畜力牵引 (`tech.animal_traction`)
- 自然铜冷锤 (`tech.natural_copper_working`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 卤水采集 (`tech.brine_collection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.brine_collection` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「盐」（resource.salt）
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：卤水；解锁建筑：卤水采集池；开放通用职业阶层岗位；可利用资源：盐；卤水采集池产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 卤水 (`brine`)
- **建筑 / 生产方式：** 卤水采集池 (`brine_gathering_basin`)
- **自然资源：** 盐 (`salt`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 日晒盐田 (`solar_salt_pan`)

#### 结构化内容效果

- **卤水**（`good`）：`good.brine` → `production_access` `unlock` `1.0`；`existing_binding`
- **卤水采集池**（`building`）：`building.brine_gathering_basin` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **卤水**（`good`）：`good.brine` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **盐**（`resource`）：`resource.salt` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 卤水采集池：`country.output.building.brine_gathering_basin_factor`：+25%

#### 直接后继（硬前置关系）

- 盐渍保存 (`tech.salt_preservation`)

#### 同路线后继

- 盐渍保存 (`tech.salt_preservation`)

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)
- 野生玉米采集 (`tech.wild_maize_collection`)

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

### 燧石辨识 (`tech.flint_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flint_identification` |
| 时代 | 石器时代 (`stone`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3900 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 土建筑 (`tech.earth_building`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：燧石原料；可利用资源：燧石；金属工具业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 燧石原料 (`flint`)
- **建筑 / 生产方式：** 无
- **自然资源：** 燧石 (`flint`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石器打制工坊 (`knapping_workshop`)；改良燧石矿坑 (`method_flint_quarry_r1`)

#### 结构化内容效果

- **燧石原料**（`good`）：`good.flint` → `production_access` `unlock` `1.0`；`existing_binding`
- **燧石**（`resource`）：`resource.flint` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+10%

#### 直接后继（硬前置关系）

- 黏土调制 (`tech.clay_preparation`)

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 燧石辨识 (`tech.flint_identification`)

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：砖块；解锁建筑：黏土坑；开放通用职业阶层岗位；开放通用职业阶层岗位；黏土坑产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 砖块 (`bricks`)
- **建筑 / 生产方式：** 黏土坑 (`clay_collector`)；露天黏土坑 (`early_clay_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制砖厂 (`bricks_plant`)；烧砖窑 (`fired_brick_kiln`)；露天陶器烧造 (`open_pottery_hearth`)；升焰陶窑 (`pottery_kiln`)；原始黏土坑 (`primitive_clay_pit`)

#### 结构化内容效果

- **砖块**（`good`）：`good.bricks` → `production_access` `unlock` `1.0`；`existing_binding`
- **黏土坑**（`building`）：`building.clay_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **露天黏土坑**（`building`）：`building.early_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 黏土坑：`country.output.building.clay_collector_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 木炭烧制 (`tech.charcoal_burning`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：陶器；解锁建筑：露天陶器烧造；开放通用职业阶层岗位；露天陶器烧造产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 陶器 (`pottery`)
- **建筑 / 生产方式：** 露天陶器烧造 (`open_pottery_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 露天陶器烧造 (`open_pottery_hearth`)；升焰陶窑 (`pottery_kiln`)

#### 结构化内容效果

- **陶器**（`good`）：`good.pottery` → `production_access` `unlock` `1.0`；`existing_binding`
- **露天陶器烧造**（`building`）：`building.open_pottery_hearth` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **陶器**（`good`）：`good.pottery` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 露天陶器烧造：`country.output.building.open_pottery_hearth_factor`：+25%

#### 直接后继（硬前置关系）

- 日晒土坯 (`tech.adobe_making`)

#### 同路线后继

- 日晒土坯 (`tech.adobe_making`)

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)
- 木炭烧制 (`tech.charcoal_burning`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

科研机构产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 控制性用火 (`tech.controlled_burning`)
- 渔舟 (`tech.fishing_boats`)
- 自然铜冷锤 (`tech.natural_copper_working`)
- 纤维捻制 (`tech.fiber_twisting`)
- 畜群管理 (`tech.herd_management`)
- 野生玉米采集 (`tech.wild_maize_collection`)
- 野生谷穗采集 (`tech.wild_wheat_collection`)
- 野生稻采集 (`tech.wild_rice_collection`)
- 块茎保存 (`tech.tuber_storage`)
- 野生香料采集 (`tech.wild_spice_collection`)
- 野生割胶 (`tech.wild_latex_tapping`)
- 芦苇辨识 (`tech.reed_identification`)
- 木炭烧制 (`tech.charcoal_burning`)
- 铜矿焙烧 (`tech.copper_ore_roasting`)
- 卤水采集 (`tech.brine_collection`)
- 手制陶器 (`tech.hand_pottery`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

- 陶器容器体系 (`tech.pottery`)
- 永久聚落 (`tech.permanent_settlements`)
- 灌溉 (`tech.irrigation`)
- 马匹驯化 (`tech.horse_domestication`)
- 犁耕农业 (`tech.plough_agriculture`)
- 天然橡胶加工 (`tech.rubber_working`)
- 铜锡配比与铸造 (`tech.bronze_casting`)
- 天文历法 (`tech.celestial_calendars`)
- 窑烧控制 (`tech.kiln_firing`)
- 织机织造 (`tech.loom_weaving`)
- 畜力牵引 (`tech.animal_traction`)
- 日晒土坯 (`tech.adobe_making`)
- 玉米园圃 (`tech.maize_garden_horticulture`)
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)
- 水田稻作 (`tech.rice_paddy_cultivation`)
- 高地块茎农业 (`tech.highland_tuber_farming`)
- 遮阴香料园 (`tech.spice_shade_gardening`)
- 手工锯木 (`tech.timber_sawing`)
- 发酵保存 (`tech.fermentation`)
- 盐渍保存 (`tech.salt_preservation`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-2"></a>
## 农耕时代

共 59 项科技，研究成本范围 7200-12000；时代里程碑：农耕社会 (`tech.agrarian_society`)。

### 陶器容器体系 (`tech.pottery`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pottery` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 渔舟 (`tech.fishing_boats`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「黏土」（resource.clay）
    - 已发现信号「硅砂」（resource.silica\_sand）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：行会陶窑；开放通用职业阶层岗位；开放通用职业阶层岗位；行会陶窑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)；活字印刷坊 (`movable_type_print_shop`)

#### 结构化内容效果

- **行会陶窑**（`building`）：`building.method_pottery_kiln_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **陶器**（`good`）：`good.pottery` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 行会陶窑：`country.output.building.method_pottery_kiln_r3_factor`：+25%

#### 直接后继（硬前置关系）

- 河运 (`tech.river_transport`)

#### 同路线后继

- 河运 (`tech.river_transport`)

#### 应用交汇目标

- 河运 (`tech.river_transport`)
- 天然橡胶加工 (`tech.rubber_working`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 留种选育 (`tech.seed_selection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.seed_selection` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 食物储藏 (`tech.food_storage`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：亚麻庄园；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：改良轮作小麦庄园；亚麻庄园产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 亚麻庄园 (`method_flax_collector_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **亚麻庄园**（`building`）：`building.method_flax_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **改良轮作小麦庄园**（`building`）：`building.method_wheat_farm_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 亚麻庄园：`country.output.building.method_flax_collector_r3_factor`：+20%

#### 直接后继（硬前置关系）

- 雨养田体系 (`tech.rainfed_field_system`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 永久聚落 (`tech.permanent_settlements`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.permanent_settlements` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁建筑：定居采集营地；开放通用职业阶层岗位；开放通用职业阶层岗位；定居采集营地产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 定居采集营地 (`method_gathering_ground_r1`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自给农庄 (`subsistence_farm`)

#### 结构化内容效果

- **定居采集营地**（`building`）：`building.method_gathering_ground_r1` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 定居采集营地：`country.output.building.method_gathering_ground_r1_factor`：+25%

#### 直接后继（硬前置关系）

- 记事制度 (`tech.record_keeping`)

#### 同路线后继

- 官僚行政 (`tech.state_bureaucracy`)

#### 应用交汇目标

- 官僚行政 (`tech.state_bureaucracy`)

#### 作为候选参与的里程碑

无

### 灌溉 (`tech.irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.irrigation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 芦苇辨识 (`tech.reed_identification`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 稻作农场 (`rice_collector`)；湿地稻园 (`wetland_rice_garden`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造：`country.output.family.construction_methods_factor`：+12%
- `country.output.energy_factor`：+3%

#### 直接后继（硬前置关系）

- 灌溉测量 (`tech.irrigation_surveying`)
- 运河工程 (`tech.canal_engineering`)

#### 同路线后继

- 运河工程 (`tech.canal_engineering`)

#### 应用交汇目标

- 运河工程 (`tech.canal_engineering`)
- 日晒土坯 (`tech.adobe_making`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 游牧放牧 (`tech.pastoralism`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoralism` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；生态 · 草原 (\`route.ecology.steppe\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 畜群管理 (`tech.herd_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

畜牧业产出 +10%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 作为候选参与的里程碑

无

### 马匹驯化 (`tech.horse_domestication`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.horse_domestication` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 草原 (\`route.ecology.steppe\`) |
| 全部路线 | 生态 · 草原 (\`route.ecology.steppe\`)；动物 · 马匹 (\`route.animal.horse\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 畜群管理 (`tech.herd_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：马匹；解锁建筑：养马场；开放通用职业阶层岗位；开放通用职业阶层岗位；养马场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 马匹 (`horses`)
- **建筑 / 生产方式：** 养马场 (`horse_breeder`)；马匹繁育营地 (`horse_breeding_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **马匹**（`good`）：`good.horses` → `production_access` `unlock` `1.0`；`existing_binding`
- **养马场**（`building`）：`building.horse_breeder` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **马匹**（`good`）：`good.horses` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **马匹繁育营地**（`building`）：`building.horse_breeding_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 养马场：`country.output.building.horse_breeder_factor`：+25%

#### 直接后继（硬前置关系）

- 乳品加工 (`tech.dairy_processing`)
- 皮纸制作 (`tech.parchment_making`)

#### 同路线后继

- 皮纸制作 (`tech.parchment_making`)

#### 应用交汇目标

- 皮纸制作 (`tech.parchment_making`)
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 犁耕农业 (`tech.plough_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plough_agriculture` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「燧石」（resource.flint）
    - 已发现信号「石料」（resource.stone）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

金属工具业产出 +11%；国家协同能力 +3%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+11%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 度量衡 (`tech.weights_and_measures`)

#### 应用交汇目标

- 度量衡 (`tech.weights_and_measures`)

#### 作为候选参与的里程碑

无

### 玉米选育 (`tech.maize_selection`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_selection` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生玉米采集 (`tech.wild_maize_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

大田作物农业产出 +10%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

无

### 旱作农业 (`tech.dryland_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dryland_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 全部路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生谷穗采集 (`tech.wild_wheat_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「旱地承载力」（resource.arable\_land）
    - 已发现信号「干旱盆地」（landform.arid\_basin）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

大田作物农业产出 +10%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

- 旱作保水 (`tech.dryland_water_retention`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

无

### 梯田农业 (`tech.terrace_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.terrace_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 地理 · 高地 (\`route.geography.highland\`) |
| 全部路线 | 地理 · 高地 (\`route.geography.highland\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「山地」（landform.mountain）
    - 已发现信号「高原」（landform.high\_plateau）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

高地农业产出 +10%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

- 垄作块茎 (`tech.ridge_tuber_cultivation`)

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 野生香料采集 (`tech.wild_spice_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「香料作物」（bio.spice）
    - 已发现信号「香料样本接触」（contact.spice）
    - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

专用商品作物农业产出 +10%

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

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+10%

#### 直接后继（硬前置关系）

- 棉花园圃 (`tech.cotton_gardening`)

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

无

### 天然橡胶加工 (`tech.rubber_working`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rubber_working` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 野生割胶 (`tech.wild_latex_tapping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「橡胶树」（bio.rubber）
    - 已发现信号「橡胶样本接触」（contact.rubber）
    - 已发现信号「森林」（landform.forest）

#### 效果摘要

化学工业产出 +12%；国家协同能力 +3%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+12%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 自然哲学 (`tech.natural_philosophy`)

#### 同路线后继

- 自然哲学 (`tech.natural_philosophy`)

#### 应用交汇目标

- 自然哲学 (`tech.natural_philosophy`)
- 陶器容器体系 (`tech.pottery`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 织造 (`tech.weaving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.weaving` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 纤维捻制 (`tech.fiber_twisting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：布料；解锁建筑：家用织机；开放通用职业阶层岗位；家用织机产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 布料 (`cloth`)
- **建筑 / 生产方式：** 家用织机 (`household_loom`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **布料**（`good`）：`good.cloth` → `production_access` `unlock` `1.0`；`existing_binding`
- **家用织机**（`building`）：`building.household_loom` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家用织机：`country.output.building.household_loom_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

无

### 木炭坩埚炼铜 (`tech.copper_metallurgy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.copper_metallurgy` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 自然铜冷锤 (`tech.natural_copper_working`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铜；解锁建筑：土法炼铜炉；开放通用职业阶层岗位；开放通用职业阶层岗位；土法炼铜炉产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铜 (`copper`)
- **建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)；土法炼锡炉 (`early_tin_smelter`)

#### 结构化内容效果

- **铜**（`good`）：`good.copper` → `production_access` `unlock` `1.0`；`existing_binding`
- **土法炼铜炉**（`building`）：`building.early_copper_smelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜矿石**（`good`）：`good.copper_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木炭**（`good`）：`good.charcoal` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 土法炼铜炉：`country.output.building.early_copper_smelter_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 窑烧控制 (`tech.kiln_firing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铜 (\`route.resource.copper\`) |
| 全部路线 | 资源 · 铜 (\`route.resource.copper\`)；资源 · 锡 (\`route.resource.tin\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 自然铜冷锤 (`tech.natural_copper_working`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：青铜工具；解锁物资：锡；解锁建筑：青铜工具工坊；开放通用职业阶层岗位；青铜工具工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 青铜工具 (`bronze_tools`)；锡 (`tin`)
- **建筑 / 生产方式：** 青铜工具工坊 (`bronze_tool_workshop`)；土法炼锡炉 (`early_tin_smelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层锡矿 (`early_tin_mine`)；露天青铜作坊 (`ore_bronzesmith_camp`)；锡矿 (`tin_ore_collector`)

#### 结构化内容效果

- **青铜工具**（`good`）：`good.bronze_tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `production_access` `unlock` `1.0`；`existing_binding`
- **青铜工具工坊**（`building`）：`building.bronze_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **青铜工具**（`good`）：`good.bronze_tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `input_method_access` `enable` `1.0`；`existing_binding`
- **土法炼锡炉**（`building`）：`building.early_tin_smelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **锡矿石**（`good`）：`good.tin_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 青铜工具工坊：`country.output.building.bronze_tool_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 货币 (`tech.currency`)

#### 同路线后继

- 货币 (`tech.currency`)

#### 应用交汇目标

- 货币 (`tech.currency`)
- 窑烧控制 (`tech.kiln_firing`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 天文历法 (`tech.celestial_calendars`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.celestial_calendars` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 7200 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

科研机构产出 +11%；国家协同能力 +3%

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

- 科研机构：`country.output.family.research_institution_factor`：+11%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 文字 (`tech.writing`)

#### 应用交汇目标

- 文字 (`tech.writing`)

#### 作为候选参与的里程碑

无

### 记事制度 (`tech.record_keeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.record_keeping` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 记录 (\`route.institution.records\`) |
| 全部路线 | 制度 · 记录 (\`route.institution.records\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 永久聚落 (`tech.permanent_settlements`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：书记学校；开放通用职业阶层岗位；开放科技职业阶层岗位；书记学校产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 书记学校 (`scribal_school`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **书记学校**（`building`）：`building.scribal_school` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **陶器**（`good`）：`good.pottery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 书记学校：`country.output.building.scribal_school_factor`：+20%

#### 直接后继（硬前置关系）

- 家庭土地占有 (`tech.household_landholding`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 雨养田体系 (`tech.rainfed_field_system`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rainfed_field_system` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 留种选育 (`tech.seed_selection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「旱地承载力」（resource.arable\_land）
    - 已发现信号「干旱经验」（weather.drought）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

可利用资源：肥沃土壤；可利用资源：旱地承载力；大田作物农业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 肥沃土壤 (`fertile_soil`)；旱地承载力 (`arable_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)；亚麻农场 (`flax_collector`)；玉米庄园 (`landed_estate`)；雨养玉米田 (`rainfed_maize_field`)；雨养小麦地 (`rainfed_wheat_plot`)；自给农庄 (`subsistence_farm`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)；旱稻田 (`upland_rice_plot`)；小麦农场 (`wheat_farm`)

#### 结构化内容效果

- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **旱地承载力**（`resource`）：`resource.arable_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+10%

#### 直接后继（硬前置关系）

- 公共仓储 (`tech.public_storehouses`)

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 野生稻采集 (`tech.wild_rice_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「水田承载力」（resource.paddy\_land）
    - 已发现信号「洪泛平原」（landform.floodplain）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

主粮加工产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)；分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 主粮加工：`country.output.family.staple_preparation_factor`：+10%

#### 直接后继（硬前置关系）

- 旱稻繁育 (`tech.upland_rice_propagation`)

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 全部路线 | 气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 旱作农业 (`tech.dryland_farming`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「旱地承载力」（resource.arable\_land）
    - 已发现信号「干旱经验」（weather.drought）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

公共营造产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

- 谷物脱粒 (`tech.grain_threshing`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

无

### 灌溉测量 (`tech.irrigation_surveying`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.irrigation_surveying` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 灌溉 (`tech.irrigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 退水玉米地 (`floodplain_maize_plot`)；退水小麦地 (`floodplain_wheat_plot`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

#### 作为候选参与的里程碑

无

### 窑烧控制 (`tech.kiln_firing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.kiln_firing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 控制性用火 (`tech.controlled_burning`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「黏土」（resource.clay）
    - 已发现信号「硅砂」（resource.silica\_sand）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：烧砖窑；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：升焰陶窑；烧砖窑产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 烧砖窑 (`fired_brick_kiln`)；升焰陶窑 (`pottery_kiln`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制砖厂 (`bricks_plant`)；土法炼锡炉 (`early_tin_smelter`)；烧砖窑 (`fired_brick_kiln`)；行会陶窑 (`method_pottery_kiln_r3`)；锡矿 (`tin_ore_collector`)

#### 结构化内容效果

- **烧砖窑**（`building`）：`building.fired_brick_kiln` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **砖块**（`good`）：`good.bricks` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木炭**（`good`）：`good.charcoal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **升焰陶窑**（`building`）：`building.pottery_kiln` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **陶器**（`good`）：`good.pottery` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 烧砖窑：`country.output.building.fired_brick_kiln_factor`：+25%

#### 直接后继（硬前置关系）

- 地表煤利用 (`tech.surface_coal_use`)

#### 同路线后继

- 地表煤利用 (`tech.surface_coal_use`)

#### 应用交汇目标

- 地表煤利用 (`tech.surface_coal_use`)
- 畜力牵引 (`tech.animal_traction`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 织机织造 (`tech.loom_weaving`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.loom_weaving` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 纤维捻制 (`tech.fiber_twisting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁建筑：行会织造坊；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：羊毛行会作坊；行会织造坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会织造坊 (`guild_weaving_house`)；羊毛行会作坊 (`method_wool_shed_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **行会织造坊**（`building`）：`building.guild_weaving_house` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **羊毛行会作坊**（`building`）：`building.method_wool_shed_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **羊毛**（`good`）：`good.wool` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 行会织造坊：`country.output.building.guild_weaving_house_factor`：+25%

#### 直接后继（硬前置关系）

- 沤麻 (`tech.flax_retting`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

#### 同路线后继

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

#### 应用交汇目标

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)
- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 畜力牵引 (`tech.animal_traction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.animal_traction` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 铜矿焙烧 (`tech.copper_ore_roasting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「野生动物」（resource.wild\_game）
    - 已发现信号「羊」（bio.sheep）
    - 已发现信号「草原」（landform.grassland）

#### 效果摘要

畜牧业产出 +12%；国家协同能力 +3%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 块炼铁 (`tech.iron_smelting`)

#### 同路线后继

- 块炼铁 (`tech.iron_smelting`)

#### 应用交汇目标

- 块炼铁 (`tech.iron_smelting`)
- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 家庭土地占有 (`tech.household_landholding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.household_landholding` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 全部路线 | 制度 · 聚落 (\`route.institution.settlement\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 记事制度 (`tech.record_keeping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁物资：混合谷物；解锁物资：蔬菜；解锁建筑：菜蔬农场；开放通用职业阶层岗位；菜蔬农场产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 混合谷物 (`grain`)；蔬菜 (`vegetables`)
- **建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)；自给农庄 (`subsistence_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)；冷凉高地块茎田 (`highland_tuber_plot`)

#### 结构化内容效果

- **混合谷物**（`good`）：`good.grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `production_access` `unlock` `1.0`；`existing_binding`
- **菜蔬农场**（`building`）：`building.fertile_soil_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **自给农庄**（`building`）：`building.subsistence_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 菜蔬农场：`country.output.building.fertile_soil_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 共同田协调 (`tech.communal_field_coordination`)

#### 同路线后继

无

#### 应用交汇目标

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 家庭土地占有 (`tech.household_landholding`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

科研机构产出 +10%

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

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 雨养田体系 (`tech.rainfed_field_system`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

科研机构产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 庄园水田 (`estate_paddy`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 手制陶器 (`tech.hand_pottery`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「黏土」（resource.clay）
    - 已发现信号「硅砂」（resource.silica\_sand）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：日晒土坯；解锁物资：建筑构件；解锁建筑：日晒土坯场；开放通用职业阶层岗位；日晒土坯场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 日晒土坯 (`adobe_brick`)；建筑构件 (`construction_components`)
- **建筑 / 生产方式：** 日晒土坯场 (`adobe_yard`)；制砖厂 (`bricks_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；烧砖窑 (`fired_brick_kiln`)

#### 结构化内容效果

- **日晒土坯**（`good`）：`good.adobe_brick` → `production_access` `unlock` `1.0`；`existing_binding`
- **建筑构件**（`good`）：`good.construction_components` → `production_access` `unlock` `1.0`；`existing_binding`
- **日晒土坯场**（`building`）：`building.adobe_yard` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **日晒土坯**（`good`）：`good.adobe_brick` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `input_method_access` `enable` `1.0`；`existing_binding`
- **制砖厂**（`building`）：`building.bricks_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **砖块**（`good`）：`good.bricks` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 日晒土坯场：`country.output.building.adobe_yard_factor`：+25%

#### 直接后继（硬前置关系）

- 早期玻璃烧制 (`tech.early_glassmaking`)
- 砌体建筑 (`tech.masonry`)

#### 同路线后继

- 砌体建筑 (`tech.masonry`)

#### 应用交汇目标

- 砌体建筑 (`tech.masonry`)
- 畜力牵引 (`tech.animal_traction`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 玉米园圃 (`tech.maize_garden_horticulture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.maize_garden_horticulture` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 野生玉米采集 (`tech.wild_maize_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

解锁物资：玉米；解锁建筑：家庭玉米园圃；开放通用职业阶层岗位；家庭玉米园圃产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玉米 (`corn_grain`)
- **建筑 / 生产方式：** 家庭玉米园圃 (`maize_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玉米**（`good`）：`good.corn_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **家庭玉米园圃**（`building`）：`building.maize_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家庭玉米园圃：`country.output.building.maize_garden_factor`：+25%

#### 直接后继（硬前置关系）

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)
- 习惯佃作 (`tech.customary_tenancy`)

#### 同路线后继

- 习惯佃作 (`tech.customary_tenancy`)

#### 应用交汇目标

- 习惯佃作 (`tech.customary_tenancy`)
- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 刀耕火种玉米 (`tech.swidden_maize_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.swidden_maize_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`)；气候 · 火 (\`route.climate.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 玉米园圃 (`tech.maize_garden_horticulture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：刀耕火种玉米地；开放通用职业阶层岗位；适应温度条件；适应水分条件；刀耕火种玉米地产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 刀耕火种玉米地 (`swidden_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **刀耕火种玉米地**（`building`）：`building.swidden_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 刀耕火种玉米地：`country.output.building.swidden_maize_plot_factor`：+20%

#### 直接后继（硬前置关系）

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「旱地承载力」（resource.arable\_land）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：雨养玉米田；开放通用职业阶层岗位；适应温度条件；适应水分条件；雨养玉米田产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 雨养玉米田 (`rainfed_maize_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **雨养玉米田**（`building`）：`building.rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 雨养玉米田：`country.output.building.rainfed_maize_field_factor`：+20%

#### 直接后继（硬前置关系）

- 退水玉米地 (`tech.flood_recession_maize`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 玉米 (\`route.crop.maize\`) |
| 全部路线 | 作物 · 玉米 (\`route.crop.maize\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「洪泛平原」（landform.floodplain）
    - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁建筑：退水玉米地；开放通用职业阶层岗位；需要河流地块条件；退水玉米地产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 退水玉米地 (`floodplain_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水玉米地**（`building`）：`building.floodplain_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 退水玉米地：`country.output.building.floodplain_maize_plot_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 旱作保水 (`tech.dryland_water_retention`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

主粮加工产出 +10%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

无

### 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rainfed_wheat_cultivation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | applied\_method |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 野生谷穗采集 (`tech.wild_wheat_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「黄土平原」（landform.loess\_plain）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁物资：小麦；解锁建筑：雨养小麦地；开放通用职业阶层岗位；适应温度条件；雨养小麦地产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 小麦 (`wheat_grain`)
- **建筑 / 生产方式：** 雨养小麦地 (`rainfed_wheat_plot`)；小麦农场 (`wheat_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **小麦**（`good`）：`good.wheat_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **雨养小麦地**（`building`）：`building.rainfed_wheat_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **小麦农场**（`building`）：`building.wheat_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 雨养小麦地：`country.output.building.rainfed_wheat_plot_factor`：+25%

#### 直接后继（硬前置关系）

- 退水小麦地 (`tech.flood_recession_wheat`)
- 轮作 (`tech.crop_rotation`)

#### 同路线后继

- 轮作 (`tech.crop_rotation`)

#### 应用交汇目标

- 轮作 (`tech.crop_rotation`)
- 灌溉 (`tech.irrigation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 退水小麦地 (`tech.flood_recession_wheat`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flood_recession_wheat` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「洪泛平原」（landform.floodplain）
    - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁建筑：退水小麦地；开放通用职业阶层岗位；需要河流地块条件；退水小麦地产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 退水小麦地 (`floodplain_wheat_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水小麦地**（`building`）：`building.floodplain_wheat_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 退水小麦地：`country.output.building.floodplain_wheat_plot_factor`：+20%

#### 直接后继（硬前置关系）

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；气候 · 干旱 (\`route.climate.drought\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 退水小麦地 (`tech.flood_recession_wheat`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「干旱盆地」（landform.arid\_basin）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：旱作保水小麦田；开放通用职业阶层岗位；适应水分条件；需要高海拔地块条件；旱作保水小麦田产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱作保水小麦田**（`building`）：`building.dryland_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **高海拔**（`tile`）：`tile.elevation` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 旱作保水小麦田：`country.output.building.dryland_wheat_field_factor`：+20%

#### 直接后继（硬前置关系）

- 谷物烘焙 (`tech.grain_baking`)

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 水田畦埂 (`tech.paddy_bunding`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「稻」（bio.rice）
    - 已发现信号「高原」（landform.high\_plateau）
    - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁建筑：旱稻田；开放通用职业阶层岗位；适应温度条件；适应水分条件；旱稻田产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 旱稻田 (`upland_rice_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱稻田**（`building`）：`building.upland_rice_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 旱稻田：`country.output.building.upland_rice_plot_factor`：+20%

#### 直接后继（硬前置关系）

- 湿地稻园 (`tech.wetland_rice_gardening`)

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 旱稻繁育 (`tech.upland_rice_propagation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「稻」（bio.rice）
    - 已发现信号「沼泽」（landform.marsh）
    - 已发现信号「水田承载力」（resource.paddy\_land）

#### 效果摘要

解锁物资：稻米；解锁建筑：稻作农场；开放通用职业阶层岗位；解锁建筑：湿地稻园；稻作农场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 稻作农场 (`rice_collector`)；湿地稻园 (`wetland_rice_garden`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)

#### 结构化内容效果

- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **稻作农场**（`building`）：`building.rice_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **湿地稻园**（`building`）：`building.wetland_rice_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 稻作农场：`country.output.building.rice_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 稻田水位控制 (`tech.rice_water_control`)

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 湿地稻园 (`tech.wetland_rice_gardening`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「水田承载力」（resource.paddy\_land）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：畦埂水稻田；开放农民阶层岗位；开放通用职业阶层岗位；需要河流地块条件；畦埂水稻田产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 庄园水田 (`estate_paddy`)；分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)

#### 结构化内容效果

- **畦埂水稻田**（`building`）：`building.bunded_rice_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **农民阶层**（`class`）：`class.farmer` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 畦埂水稻田：`country.output.building.bunded_rice_field_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | applied\_method |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 野生稻采集 (`tech.wild_rice_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「稻」（bio.rice）
    - 已发现信号「稻种样本接触」（contact.rice）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁物资：稻米；解锁建筑：佃作稻庄；开放通用职业阶层岗位；开放通用职业阶层岗位；佃作稻庄产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 佃作稻庄 (`method_rice_collector_r3`)
- **自然资源：** 水田承载力 (`paddy_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **佃作稻庄**（`building`）：`building.method_rice_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 佃作稻庄：`country.output.building.method_rice_collector_r3_factor`：+25%

#### 直接后继（硬前置关系）

- 佃作水田 (`tech.tenant_paddy_management`)

#### 同路线后继

- 佃作水田 (`tech.tenant_paddy_management`)

#### 应用交汇目标

- 佃作水田 (`tech.tenant_paddy_management`)
- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 梯田农业 (`tech.terrace_farming`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「块茎样本接触」（contact.potato）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁建筑：马铃薯农场；开放通用职业阶层岗位；马铃薯农场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 马铃薯农场 (`potato_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **马铃薯农场**（`building`）：`building.potato_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **马铃薯**（`good`）：`good.potatoes` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 马铃薯农场：`country.output.building.potato_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 防霜窖藏 (`tech.frost_protected_storage`)

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 垄作块茎 (`tech.ridge_tuber_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「块茎样本接触」（contact.potato）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

主粮加工产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 主粮加工：`country.output.family.staple_preparation_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 日晒土坯 (`tech.adobe_making`)

#### 作为候选参与的里程碑

无

### 高地块茎农业 (`tech.highland_tuber_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.highland_tuber_farming` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`)；地理 · 高地 (\`route.geography.highland\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 块茎保存 (`tech.tuber_storage`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「高原」（landform.high\_plateau）
    - 已发现信号「山地」（landform.mountain）

#### 效果摘要

解锁建筑：冷凉高地块茎田；开放农民阶层岗位；适用于山地地貌；适用于高原地貌；冷凉高地块茎田产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)

#### 结构化内容效果

- **冷凉高地块茎田**（`building`）：`building.highland_tuber_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **农民阶层**（`class`）：`class.farmer` → `ownership_access` `enable` `1.0`；`existing_binding`
- **马铃薯**（`good`）：`good.potatoes` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **山地**（`landform`）：`landform.mountain` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **高原**（`landform`）：`landform.plateau` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **高海拔**（`tile`）：`tile.elevation` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 冷凉高地块茎田：`country.output.building.highland_tuber_plot_factor`：+25%

#### 直接后继（硬前置关系）

- 分成租佃 (`tech.sharecropping`)

#### 同路线后继

- 分成租佃 (`tech.sharecropping`)

#### 应用交汇目标

- 分成租佃 (`tech.sharecropping`)
- 日晒土坯 (`tech.adobe_making`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 沤麻 (`tech.flax_retting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.flax_retting` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 织机织造 (`tech.loom_weaving`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：亚麻纤维；解锁建筑：亚麻农场；开放通用职业阶层岗位；解锁建筑：沤麻池；亚麻农场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻纤维 (`flax_fiber`)
- **建筑 / 生产方式：** 亚麻农场 (`flax_collector`)；沤麻池 (`flax_retting_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)

#### 结构化内容效果

- **亚麻纤维**（`good`）：`good.flax_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **亚麻农场**（`building`）：`building.flax_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **沤麻池**（`building`）：`building.flax_retting_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **韧皮纤维**（`good`）：`good.bast_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 亚麻农场：`country.output.building.flax_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 手工纺纱 (`tech.hand_spinning`)

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 沤麻 (`tech.flax_retting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁建筑：家庭纺织坊；开放通用职业阶层岗位；家庭纺织坊产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家用织机 (`household_loom`)

#### 结构化内容效果

- **家庭纺织坊**（`building`）：`building.cottage_weaving` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家庭纺织坊：`country.output.building.cottage_weaving_factor`：+20%

#### 直接后继（硬前置关系）

- 棉花去籽 (`tech.cotton_ginning`)

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 手工纺纱 (`tech.hand_spinning`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「棉花样本接触」（contact.cotton）
    - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

解锁物资：棉纤维；解锁建筑：手工轧棉棚；开放通用职业阶层岗位；手工轧棉棚产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 棉纤维 (`cotton_fiber`)
- **建筑 / 生产方式：** 手工轧棉棚 (`cotton_ginning_shelter`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)

#### 结构化内容效果

- **棉纤维**（`good`）：`good.cotton_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **手工轧棉棚**（`building`）：`building.cotton_ginning_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **棉纤维**（`good`）：`good.cotton_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 手工轧棉棚：`country.output.building.cotton_ginning_shelter_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

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
| 锚点类型 | support |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 香料栽培 (`tech.spice_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「棉花样本接触」（contact.cotton）
    - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

解锁物资：棉纤维；解锁物资：籽棉；解锁建筑：家庭棉花园圃；开放通用职业阶层岗位；家庭棉花园圃产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 棉纤维 (`cotton_fiber`)；籽棉 (`seed_cotton`)
- **建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 棉花农场 (`cotton_collector`)

#### 结构化内容效果

- **棉纤维**（`good`）：`good.cotton_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`existing_binding`
- **家庭棉花园圃**（`building`）：`building.cotton_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家庭棉花园圃：`country.output.building.cotton_garden_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

无

### 遮阴香料园 (`tech.spice_shade_gardening`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.spice_shade_gardening` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | applied\_method |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 野生香料采集 (`tech.wild_spice_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「香料作物」（bio.spice）
    - 已发现信号「香料样本接触」（contact.spice）
    - 已发现信号「种植园承载力」（resource.plantation\_land）

#### 效果摘要

解锁物资：香料；解锁建筑：林下遮阴香料园；开放通用职业阶层岗位；适应温度条件；林下遮阴香料园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 香料 (`spices`)
- **建筑 / 生产方式：** 林下遮阴香料园 (`spice_shade_garden`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 香料种植园 (`spice_plants_collector`)

#### 结构化内容效果

- **香料**（`good`）：`good.spices` → `production_access` `unlock` `1.0`；`existing_binding`
- **林下遮阴香料园**（`building`）：`building.spice_shade_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **香料**（`good`）：`good.spices` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 林下遮阴香料园：`country.output.building.spice_shade_garden_factor`：+25%

#### 直接后继（硬前置关系）

- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)
- 市场制度 (`tech.market_institutions`)

#### 同路线后继

- 市场制度 (`tech.market_institutions`)

#### 应用交汇目标

- 市场制度 (`tech.market_institutions`)
- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.latex_smoke_coagulation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 遮阴香料园 (`tech.spice_shade_gardening`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「橡胶树」（bio.rubber）
    - 已发现信号「橡胶样本接触」（contact.rubber）
    - 已发现信号「森林」（landform.forest）

#### 效果摘要

解锁物资：凝固天然橡胶；解锁建筑：乳胶烟熏凝固棚；开放通用职业阶层岗位；可利用资源：种植园承载力；乳胶烟熏凝固棚产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 凝固天然橡胶 (`natural_rubber`)
- **建筑 / 生产方式：** 乳胶烟熏凝固棚 (`latex_smoking_shelter`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 橡胶种植园 (`rubber_tree_collector`)

#### 结构化内容效果

- **凝固天然橡胶**（`good`）：`good.natural_rubber` → `production_access` `unlock` `1.0`；`existing_binding`
- **乳胶烟熏凝固棚**（`building`）：`building.latex_smoking_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **凝固天然橡胶**（`good`）：`good.natural_rubber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 乳胶烟熏凝固棚：`country.output.building.latex_smoking_shelter_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 盐渍保存 (`tech.salt_preservation`)

#### 作为候选参与的里程碑

无

### 手工锯木 (`tech.timber_sawing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.timber_sawing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；工艺 · 工具 (\`route.craft.tools\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 木炭烧制 (`tech.charcoal_burning`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：木材；解锁建筑：锯木场；开放通用职业阶层岗位；解锁建筑：改良锯木场；锯木场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 木材 (`lumber`)
- **建筑 / 生产方式：** 锯木场 (`lumber_plant`)；改良锯木场 (`method_lumber_plant_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)

#### 结构化内容效果

- **木材**（`good`）：`good.lumber` → `production_access` `unlock` `1.0`；`existing_binding`
- **锯木场**（`building`）：`building.lumber_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **改良锯木场**（`building`）：`building.method_lumber_plant_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 锯木场：`country.output.building.lumber_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 树皮纸 (`tech.bark_paper_making`)

#### 同路线后继

- 树皮纸 (`tech.bark_paper_making`)

#### 应用交汇目标

- 树皮纸 (`tech.bark_paper_making`)
- 陶器容器体系 (`tech.pottery`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 乳品加工 (`tech.dairy_processing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.dairy_processing` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 马匹驯化 (`tech.horse_domestication`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：乳制品；解锁建筑：乳品工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；乳品工坊产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 乳制品 (`dairy_products`)
- **建筑 / 生产方式：** 乳品工坊 (`creamery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **乳制品**（`good`）：`good.dairy_products` → `production_access` `unlock` `1.0`；`existing_binding`
- **乳品工坊**（`building`）：`building.creamery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **乳制品**（`good`）：`good.dairy_products` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 乳品工坊：`country.output.building.creamery_factor`：+20%

#### 直接后继（硬前置关系）

- 皮革鞣制 (`tech.hide_tanning`)

#### 同路线后继

无

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 野生动物 (\`route.ecology.game\`) |
| 全部路线 | 生态 · 野生动物 (\`route.ecology.game\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 乳品加工 (`tech.dairy_processing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「野生动物」（resource.wild\_game）
    - 已发现信号「羊」（bio.sheep）
    - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁物资：鞋履；解锁物资：皮革；解锁建筑：鞋匠铺；开放通用职业阶层岗位；鞋匠铺产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鞋履 (`footwear`)；皮革 (`leather`)
- **建筑 / 生产方式：** 鞋匠铺 (`cobbler_shop`)；制革工坊 (`tannery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 皮纸工坊 (`parchment_workshop`)

#### 结构化内容效果

- **鞋履**（`good`）：`good.footwear` → `production_access` `unlock` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `production_access` `unlock` `1.0`；`existing_binding`
- **鞋匠铺**（`building`）：`building.cobbler_shop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **鞋履**（`good`）：`good.footwear` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **制革工坊**（`building`）：`building.tannery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 鞋匠铺：`country.output.building.cobbler_shop_factor`：+20%

#### 直接后继（硬前置关系）

- 毛用畜牧 (`tech.wool_husbandry`)

#### 同路线后继

无

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 皮革鞣制 (`tech.hide_tanning`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：羊毛；解锁建筑：精梳羊毛作坊；开放通用职业阶层岗位；开放通用职业阶层岗位；精梳羊毛作坊产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 羊毛 (`wool`)
- **建筑 / 生产方式：** 精梳羊毛作坊 (`method_wool_shed_r5`)；羊毛棚 (`wool_shed`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **羊毛**（`good`）：`good.wool` → `production_access` `unlock` `1.0`；`existing_binding`
- **精梳羊毛作坊**（`building`）：`building.method_wool_shed_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **羊毛**（`good`）：`good.wool` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **羊毛棚**（`building`）：`building.wool_shed` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 精梳羊毛作坊：`country.output.building.method_wool_shed_r5_factor`：+20%

#### 直接后继（硬前置关系）

- 屠宰分割 (`tech.meat_processing`)

#### 同路线后继

无

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 毛用畜牧 (`tech.wool_husbandry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：肉类；解锁建筑：工业屠宰场；开放通用职业阶层岗位；开放通用职业阶层岗位；工业屠宰场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肉类 (`meat`)
- **建筑 / 生产方式：** 工业屠宰场 (`mechanized_slaughterhouse`)；屠宰场 (`slaughterhouse`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **肉类**（`good`）：`good.meat` → `production_access` `unlock` `1.0`；`existing_binding`
- **工业屠宰场**（`building`）：`building.mechanized_slaughterhouse` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **肉类**（`good`）：`good.meat` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **屠宰场**（`building`）：`building.slaughterhouse` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 工业屠宰场：`country.output.building.mechanized_slaughterhouse_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

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
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：酒饮；解锁建筑：酿酒坊；开放通用职业阶层岗位；开放通用职业阶层岗位；酿酒坊产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 酒饮 (`beverages`)
- **建筑 / 生产方式：** 酿酒坊 (`brewery`)；蒸馏酒坊 (`distillery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **酒饮**（`good`）：`good.beverages` → `production_access` `unlock` `1.0`；`existing_binding`
- **酿酒坊**（`building`）：`building.brewery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **酒饮**（`good`）：`good.beverages` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸馏酒坊**（`building`）：`building.distillery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **陶器**（`good`）：`good.pottery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 酿酒坊：`country.output.building.brewery_factor`：+25%

#### 直接后继（硬前置关系）

- 佃作谷物 (`tech.tenant_cereal_farming`)

#### 同路线后继

- 城市食物供应 (`tech.urban_food_supply`)

#### 应用交汇目标

- 城市食物供应 (`tech.urban_food_supply`)

#### 作为候选参与的里程碑

无

### 盐渍保存 (`tech.salt_preservation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.salt_preservation` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 8160 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`)；资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 定居知识 (`tech.settled_knowledge`)
- 卤水采集 (`tech.brine_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「盐」（resource.salt）
    - 已发现信号「硝石」（resource.saltpeter）
    - 已发现信号「硫磺」（resource.sulfur）

#### 效果摘要

解锁物资：食盐；解锁建筑：盐场；开放通用职业阶层岗位；开放通用职业阶层岗位；盐场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 食盐 (`salt`)
- **建筑 / 生产方式：** 盐场 (`salt_collector`)；日晒盐田 (`solar_salt_pan`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **食盐**（`good`）：`good.salt` → `production_access` `unlock` `1.0`；`existing_binding`
- **盐场**（`building`）：`building.salt_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **日晒盐田**（`building`）：`building.solar_salt_pan` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **卤水**（`good`）：`good.brine` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 盐场：`country.output.building.salt_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 城市卫生 (`tech.urban_sanitation`)

#### 同路线后继

- 城市卫生 (`tech.urban_sanitation`)

#### 应用交汇目标

- 城市卫生 (`tech.urban_sanitation`)
- 天然橡胶加工 (`tech.rubber_working`)

#### 作为候选参与的里程碑

- 农耕社会 (`tech.agrarian_society`)

### 谷物烘焙 (`tech.grain_baking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.grain_baking` |
| 时代 | 农耕时代 (`agrarian`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 9360 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 小麦 (\`route.crop.wheat\`) |
| 全部路线 | 作物 · 小麦 (\`route.crop.wheat\`)；制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁物资：面包；解锁建筑：面包坊；开放通用职业阶层岗位；开放通用职业阶层岗位；面包坊产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 面包 (`bread`)
- **建筑 / 生产方式：** 面包坊 (`bakery`)；面包厂 (`bread_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **面包**（`good`）：`good.bread` → `production_access` `unlock` `1.0`；`existing_binding`
- **面包坊**（`building`）：`building.bakery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **面包**（`good`）：`good.bread` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `input_method_access` `enable` `1.0`；`existing_binding`
- **面包厂**（`building`）：`building.bread_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 面包坊：`country.output.building.bakery_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 灌溉 (`tech.irrigation`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`)；能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 日晒土坯 (`tech.adobe_making`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「定居知识」（tech.settled\_knowledge）
  - 满足其一：
    - 已发现信号「硅砂」（resource.silica\_sand）
    - 已发现信号「石灰岩」（resource.limestone）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：玻璃；解锁物资：硅砂；解锁建筑：玻璃窑；开放通用职业阶层岗位；玻璃窑产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 玻璃 (`glass`)；硅砂 (`silica_sand`)
- **建筑 / 生产方式：** 玻璃窑 (`classical_glass_kiln`)；硅砂矿坑 (`classical_silica_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玻璃**（`good`）：`good.glass` → `production_access` `unlock` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `production_access` `unlock` `1.0`；`existing_binding`
- **玻璃窑**（`building`）：`building.classical_glass_kiln` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硅砂矿坑**（`building`）：`building.classical_silica_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 玻璃窑：`country.output.building.classical_glass_kiln_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 畜力牵引 (`tech.animal_traction`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

科研机构产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 陶器容器体系 (`tech.pottery`)
- 灌溉 (`tech.irrigation`)
- 马匹驯化 (`tech.horse_domestication`)
- 天然橡胶加工 (`tech.rubber_working`)
- 铜锡配比与铸造 (`tech.bronze_casting`)
- 窑烧控制 (`tech.kiln_firing`)
- 织机织造 (`tech.loom_weaving`)
- 畜力牵引 (`tech.animal_traction`)
- 日晒土坯 (`tech.adobe_making`)
- 玉米园圃 (`tech.maize_garden_horticulture`)
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)
- 水田稻作 (`tech.rice_paddy_cultivation`)
- 高地块茎农业 (`tech.highland_tuber_farming`)
- 遮阴香料园 (`tech.spice_shade_gardening`)
- 手工锯木 (`tech.timber_sawing`)
- 盐渍保存 (`tech.salt_preservation`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 科研机构：`country.output.family.research_institution_factor`：+10%

#### 直接后继（硬前置关系）

- 文字 (`tech.writing`)
- 砌体建筑 (`tech.masonry`)
- 块炼铁 (`tech.iron_smelting`)
- 度量衡 (`tech.weights_and_measures`)
- 市场制度 (`tech.market_institutions`)
- 货币 (`tech.currency`)
- 运河工程 (`tech.canal_engineering`)
- 河运 (`tech.river_transport`)
- 轮作 (`tech.crop_rotation`)
- 城市卫生 (`tech.urban_sanitation`)
- 自然哲学 (`tech.natural_philosophy`)
- 地表煤利用 (`tech.surface_coal_use`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)
- 树皮纸 (`tech.bark_paper_making`)
- 皮纸制作 (`tech.parchment_making`)
- 官僚行政 (`tech.state_bureaucracy`)
- 习惯佃作 (`tech.customary_tenancy`)
- 分成租佃 (`tech.sharecropping`)
- 佃作水田 (`tech.tenant_paddy_management`)
- 城市食物供应 (`tech.urban_food_supply`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-3"></a>
## 王国时代

共 30 项科技，研究成本范围 18000-30000；时代里程碑：王国体系 (`tech.kingdom_administration`)。

### 文字 (`tech.writing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.writing` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 18000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁物资：手抄本；解锁建筑：城邦抄写室；开放通用职业阶层岗位；开放通用职业阶层岗位；城邦抄写室产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 手抄本 (`manuscripts`)
- **建筑 / 生产方式：** 城邦抄写室 (`classical_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)；皮纸工坊 (`parchment_workshop`)；植物纤维抄纸坊 (`plant_fiber_paper_workshop`)

#### 结构化内容效果

- **手抄本**（`good`）：`good.manuscripts` → `production_access` `unlock` `1.0`；`existing_binding`
- **城邦抄写室**（`building`）：`building.classical_scriptorium` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **手抄本**（`good`）：`good.manuscripts` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **采集植物食物**（`good`）：`good.gathered_plants` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 城邦抄写室：`country.output.building.classical_scriptorium_factor`：+25%

#### 直接后继（硬前置关系）

- 学术机构 (`tech.scholarly_academies`)
- 木版印刷 (`tech.woodblock_printing`)

#### 同路线后继

- 经院研究法 (`tech.scholastic_method`)

#### 应用交汇目标

- 经院研究法 (`tech.scholastic_method`)

#### 作为候选参与的里程碑

无

### 砌体建筑 (`tech.masonry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.masonry` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 日晒土坯 (`tech.adobe_making`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「石料」（resource.stone）
    - 已发现信号「燧石」（resource.flint）
    - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：石灰；解锁物资：石灰岩；解锁建筑：石灰厂；开放通用职业阶层岗位；石灰厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石灰 (`lime`)；石灰岩 (`limestone`)
- **建筑 / 生产方式：** 石灰厂 (`lime_plant`)
- **自然资源：** 石灰岩 (`limestone`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；煤层平硐 (`coal_adit`)；石灰石采石场 (`limestone_collector`)；石料场 (`method_stone_collector_r2`)

#### 结构化内容效果

- **石灰**（`good`）：`good.lime` → `production_access` `unlock` `1.0`；`existing_binding`
- **石灰岩**（`good`）：`good.limestone` → `production_access` `unlock` `1.0`；`existing_binding`
- **石灰厂**（`building`）：`building.lime_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **石灰**（`good`）：`good.lime` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石灰岩**（`good`）：`good.limestone` → `input_method_access` `enable` `1.0`；`existing_binding`
- **石灰岩**（`resource`）：`resource.limestone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 石灰厂：`country.output.building.lime_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 城市水务 (`tech.urban_waterworks`)

#### 同路线后继

- 城市水务 (`tech.urban_waterworks`)

#### 应用交汇目标

- 城市水务 (`tech.urban_waterworks`)
- 运河工程 (`tech.canal_engineering`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 块炼铁 (`tech.iron_smelting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.iron_smelting` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 畜力牵引 (`tech.animal_traction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：锻铁；解锁建筑：块炼炉；开放通用职业阶层岗位；开放通用职业阶层岗位；块炼炉产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锻铁 (`wrought_iron`)
- **建筑 / 生产方式：** 块炼炉 (`bloomery`)；铁制工具工坊 (`iron_tool_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 浅层铁矿 (`early_iron_mine`)

#### 结构化内容效果

- **锻铁**（`good`）：`good.wrought_iron` → `production_access` `unlock` `1.0`；`existing_binding`
- **块炼炉**（`building`）：`building.bloomery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **锻铁**（`good`）：`good.wrought_iron` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木炭**（`good`）：`good.charcoal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铁制工具工坊**（`building`）：`building.iron_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **锻铁**（`good`）：`good.wrought_iron` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 块炼炉：`country.output.building.bloomery_factor`：+25%

#### 直接后继（硬前置关系）

- 铁矿辨识 (`tech.iron_ore_identification`)
- 高炉冶炼 (`tech.blast_furnace`)

#### 同路线后继

- 高炉冶炼 (`tech.blast_furnace`)

#### 应用交汇目标

- 高炉冶炼 (`tech.blast_furnace`)
- 自然哲学 (`tech.natural_philosophy`)

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
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁建筑：砂金淘洗精炼棚；开放通用职业阶层岗位；解锁建筑：银矿火试炉；砂金淘洗精炼棚产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 砂金淘洗精炼棚 (`gold_washing_refinery`)；银矿火试炉 (`silver_fire_assay_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **砂金淘洗精炼棚**（`building`）：`building.gold_washing_refinery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **黄金**（`good`）：`good.gold` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **含金砂矿**（`good`）：`good.gold_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木炭**（`good`）：`good.charcoal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **银矿火试炉**（`building`）：`building.silver_fire_assay_hearth` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **白银**（`good`）：`good.silver` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **含银矿石**（`good`）：`good.silver_ore` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 砂金淘洗精炼棚：`country.output.building.gold_washing_refinery_factor`：+25%

#### 直接后继（硬前置关系）

- 道路工程 (`tech.road_engineering`)

#### 同路线后继

- 活字印刷 (`tech.movable_type_printing`)

#### 应用交汇目标

- 活字印刷 (`tech.movable_type_printing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 遮阴香料园 (`tech.spice_shade_gardening`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

科研机构产出 +12%；国家协同能力 +3%

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

- 科研机构：`country.output.family.research_institution_factor`：+12%
- `country.trade.capacity_factor`：+3%

#### 直接后继（硬前置关系）

- 农奴义务 (`tech.serf_obligations`)

#### 同路线后继

- 农奴义务 (`tech.serf_obligations`)

#### 应用交汇目标

- 农奴义务 (`tech.serf_obligations`)
- 自然哲学 (`tech.natural_philosophy`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 铜锡配比与铸造 (`tech.bronze_casting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁物资：珠宝；解锁建筑：金银器工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；金银器工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 珠宝 (`jewelry`)
- **建筑 / 生产方式：** 金银器工坊 (`goldsmith_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **珠宝**（`good`）：`good.jewelry` → `production_access` `unlock` `1.0`；`existing_binding`
- **金银器工坊**（`building`）：`building.goldsmith_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **珠宝**（`good`）：`good.jewelry` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黄金**（`good`）：`good.gold` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 金银器工坊：`country.output.building.goldsmith_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 坩埚钢 (`tech.crucible_steel`)

#### 同路线后继

- 坩埚钢 (`tech.crucible_steel`)

#### 应用交汇目标

- 坩埚钢 (`tech.crucible_steel`)
- 砌体建筑 (`tech.masonry`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 道路工程 (`tech.road_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.road_engineering` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 地理 · 内陆 (\`route.geography.inland\`) |
| 全部路线 | 地理 · 内陆 (\`route.geography.inland\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 度量衡 (`tech.weights_and_measures`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁建筑：石作工场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：规模化采石场；石作工场产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；规模化采石场 (`method_stone_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **石作工场**（`building`）：`building.classical_masonry_yard` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **建筑构件**（`good`）：`good.construction_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **规模化采石场**（`building`）：`building.method_stone_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 石作工场：`country.output.building.classical_masonry_yard_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 运河工程 (`tech.canal_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.canal_engineering` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 灌溉 (`tech.irrigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：石灰石采石场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：石料场；石灰石采石场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石灰石采石场 (`limestone_collector`)；石料场 (`method_stone_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **石灰石采石场**（`building`）：`building.limestone_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **石灰岩**（`good`）：`good.limestone` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石料场**（`building`）：`building.method_stone_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 石灰石采石场：`country.output.building.limestone_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 水力机械 (`tech.water_power`)

#### 同路线后继

- 水力机械 (`tech.water_power`)

#### 应用交汇目标

- 水力机械 (`tech.water_power`)
- 地表煤利用 (`tech.surface_coal_use`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 河运 (`tech.river_transport`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.river_transport` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 陶器容器体系 (`tech.pottery`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

科研机构产出 +12%；国家协同能力 +3%

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

- 科研机构：`country.output.family.research_institution_factor`：+12%
- `country.trade.capacity_factor`：+3%

#### 直接后继（硬前置关系）

- 磁针导航 (`tech.magnetic_navigation`)

#### 同路线后继

- 磁针导航 (`tech.magnetic_navigation`)

#### 应用交汇目标

- 磁针导航 (`tech.magnetic_navigation`)
- 地表煤利用 (`tech.surface_coal_use`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 轮作 (`tech.crop_rotation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_rotation` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁物资：食用油；解锁建筑：堆肥场；开放通用职业阶层岗位；开放通用职业阶层岗位；堆肥场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 食用油 (`edible_oil`)
- **建筑 / 生产方式：** 堆肥场 (`composting_yard`)；榨油坊 (`edible_oil_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业榨油厂 (`method_edible_oil_plant_r6`)

#### 结构化内容效果

- **食用油**（`good`）：`good.edible_oil` → `production_access` `unlock` `1.0`；`existing_binding`
- **堆肥场**（`building`）：`building.composting_yard` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **榨油坊**（`building`）：`building.edible_oil_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **食用油**（`good`）：`good.edible_oil` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 堆肥场：`country.output.building.composting_yard_factor`：+25%

#### 直接后继（硬前置关系）

- 集约轮作 (`tech.intensive_crop_rotation`)

#### 同路线后继

- 集约轮作 (`tech.intensive_crop_rotation`)

#### 应用交汇目标

- 集约轮作 (`tech.intensive_crop_rotation`)
- 块炼铁 (`tech.iron_smelting`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 城市卫生 (`tech.urban_sanitation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.urban_sanitation` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 盐渍保存 (`tech.salt_preservation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「盐」（resource.salt）
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：肥皂；解锁建筑：工业制皂厂；开放通用职业阶层岗位；开放通用职业阶层岗位；工业制皂厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥皂 (`soap`)
- **建筑 / 生产方式：** 工业制皂厂 (`method_soap_plant_r6`)；制皂工坊 (`soap_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **肥皂**（`good`）：`good.soap` → `production_access` `unlock` `1.0`；`existing_binding`
- **工业制皂厂**（`building`）：`building.method_soap_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **肥皂**（`good`）：`good.soap` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **食用油**（`good`）：`good.edible_oil` → `input_method_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **制皂工坊**（`building`）：`building.soap_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 工业制皂厂：`country.output.building.method_soap_plant_r6_factor`：+25%

#### 直接后继（硬前置关系）

- 火药配制 (`tech.gunpowder_formulation`)

#### 同路线后继

- 火药配制 (`tech.gunpowder_formulation`)

#### 应用交汇目标

- 火药配制 (`tech.gunpowder_formulation`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 自然哲学 (`tech.natural_philosophy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.natural_philosophy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 天然橡胶加工 (`tech.rubber_working`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

造纸业产出 +12%；国家协同能力 +3%

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

- 造纸业：`country.output.family.paper_making_factor`：+12%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

- 煤矿开采 (`tech.coal_mining`)

#### 同路线后继

- 煤矿开采 (`tech.coal_mining`)

#### 应用交汇目标

- 煤矿开采 (`tech.coal_mining`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 学术机构 (`tech.scholarly_academies`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scholarly_academies` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 文字 (`tech.writing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：古典学院；开放通用职业阶层岗位；开放科技职业阶层岗位；古典学院产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 古典学院 (`classical_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **古典学院**（`building`）：`building.classical_academy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **手抄本**（`good`）：`good.manuscripts` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 古典学院：`country.output.building.classical_academy_factor`：+20%

#### 直接后继（硬前置关系）

- 手稿文化 (`tech.manuscript_culture`)

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`)；能源 · 热能 (\`route.energy.thermal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 窑烧控制 (`tech.kiln_firing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：煤炭；铁矿业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿业：`country.output.family.iron_extraction_factor`：+12%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 风力机械 (`tech.wind_power`)

#### 同路线后继

- 风力机械 (`tech.wind_power`)

#### 应用交汇目标

- 风力机械 (`tech.wind_power`)
- 运河工程 (`tech.canal_engineering`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plant_fiber_papermaking` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 织机织造 (`tech.loom_weaving`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：纸张；解锁建筑：植物纤维抄纸坊；开放通用职业阶层岗位；开放通用职业阶层岗位；植物纤维抄纸坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 植物纤维抄纸坊 (`plant_fiber_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`existing_binding`
- **植物纤维抄纸坊**（`building`）：`building.plant_fiber_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **韧皮纤维**（`good`）：`good.bast_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 植物纤维抄纸坊：`country.output.building.plant_fiber_paper_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 破布纸 (`tech.rag_paper_making`)

#### 同路线后继

- 破布纸 (`tech.rag_paper_making`)

#### 应用交汇目标

- 破布纸 (`tech.rag_paper_making`)
- 地表煤利用 (`tech.surface_coal_use`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 树皮纸 (`tech.bark_paper_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bark_paper_making` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 手工锯木 (`tech.timber_sawing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：纸张；解锁建筑：树皮纸工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；树皮纸工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 树皮纸工坊 (`bark_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`existing_binding`
- **树皮纸工坊**（`building`）：`building.bark_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 树皮纸工坊：`country.output.building.bark_paper_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 森林管理 (`tech.forest_management`)

#### 同路线后继

- 森林管理 (`tech.forest_management`)

#### 应用交汇目标

- 森林管理 (`tech.forest_management`)
- 城市卫生 (`tech.urban_sanitation`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 皮纸制作 (`tech.parchment_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.parchment_making` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 马匹驯化 (`tech.horse_domestication`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁物资：纸张；解锁建筑：皮纸工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；皮纸工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 皮纸工坊 (`parchment_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`existing_binding`
- **皮纸工坊**（`building`）：`building.parchment_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 皮纸工坊：`country.output.building.parchment_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 牧业网络 (`tech.pastoral_networks`)

#### 同路线后继

- 牧业网络 (`tech.pastoral_networks`)

#### 应用交汇目标

- 牧业网络 (`tech.pastoral_networks`)
- 河运 (`tech.river_transport`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 手稿文化 (`tech.manuscript_culture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manuscript_culture` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 全部路线 | 制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 学术机构 (`tech.scholarly_academies`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「霜冻经验」（weather.frost）
    - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：公共营造场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：修道院抄写室；公共营造场产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共营造场 (`classical_public_works`)；修道院抄写室 (`monastic_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 活字印刷坊 (`movable_type_print_shop`)；印刷厂 (`printed_materials_plant`)；木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **公共营造场**（`building`）：`building.classical_public_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **建筑构件**（`good`）：`good.construction_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **砖块**（`good`）：`good.bricks` → `input_method_access` `enable` `1.0`；`existing_binding`
- **石灰**（`good`）：`good.lime` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **修道院抄写室**（`building`）：`building.monastic_scriptorium` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **手抄本**（`good`）：`good.manuscripts` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 公共营造场：`country.output.building.classical_public_works_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

海运业产出 +11%；国家协同能力 +3%

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

- 海运业：`country.output.family.maritime_operations_factor`：+11%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 庄园核算 (`tech.estate_accounting`)

#### 同路线后继

- 行业组织 (`tech.guild_organization`)

#### 应用交汇目标

- 行业组织 (`tech.guild_organization`)

#### 作为候选参与的里程碑

无

### 习惯佃作 (`tech.customary_tenancy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.customary_tenancy` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 玉米园圃 (`tech.maize_garden_horticulture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

海运业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作水田 (`tenant_paddy`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运业：`country.output.family.maritime_operations_factor`：+12%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 庄园谷物经营 (`tech.manorial_cereal_farming`)

#### 同路线后继

- 庄园谷物经营 (`tech.manorial_cereal_farming`)

#### 应用交汇目标

- 庄园谷物经营 (`tech.manorial_cereal_farming`)
- 块炼铁 (`tech.iron_smelting`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 分成租佃 (`tech.sharecropping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.sharecropping` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 20400 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 高地块茎农业 (`tech.highland_tuber_farming`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

海运业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 分成水田 (`sharecrop_paddy`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运业：`country.output.family.maritime_operations_factor`：+12%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 庄园谷物核算 (`tech.estate_cereal_management`)

#### 同路线后继

- 庄园谷物核算 (`tech.estate_cereal_management`)

#### 应用交汇目标

- 庄园谷物核算 (`tech.estate_cereal_management`)
- 地表煤利用 (`tech.surface_coal_use`)

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

### 庄园核算 (`tech.estate_accounting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_accounting` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 官僚行政 (`tech.state_bureaucracy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

海运业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 庄园水田 (`estate_paddy`)；玉米庄园 (`landed_estate`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运业：`country.output.family.maritime_operations_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 发酵保存 (`tech.fermentation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：佃作雨养玉米田；开放通用职业阶层岗位；开放通用职业阶层岗位；适应温度条件；佃作雨养玉米田产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作雨养玉米田**（`building`）：`building.tenant_rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **温度**（`climate`）：`climate.temperature` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水分**（`climate`）：`climate.moisture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **佃作雨养小麦田**（`building`）：`building.tenant_rainfed_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **农民阶层**（`class`）：`class.farmer` → `employment_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 佃作雨养玉米田：`country.output.building.tenant_rainfed_maize_field_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)
- 水田稻作 (`tech.rice_paddy_cultivation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「水田承载力」（resource.paddy\_land）
    - 已发现信号「洪泛平原」（landform.floodplain）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：分成水田；开放通用职业阶层岗位；开放农民阶层岗位；需要河流地块条件；分成水田产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **分成水田**（`building`）：`building.sharecrop_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **农民阶层**（`class`）：`class.farmer` → `employment_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **佃作水田**（`building`）：`building.tenant_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 分成水田：`country.output.building.sharecrop_paddy_factor`：+25%

#### 直接后继（硬前置关系）

- 庄园水田核算 (`tech.estate_paddy_management`)

#### 同路线后继

- 庄园水田核算 (`tech.estate_paddy_management`)

#### 应用交汇目标

- 庄园水田核算 (`tech.estate_paddy_management`)
- 地表煤利用 (`tech.surface_coal_use`)

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
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 块炼铁 (`tech.iron_smelting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：铁矿石；解锁建筑：铁矿；开放通用职业阶层岗位；开放通用职业阶层岗位；铁矿产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铁矿石 (`iron_ore`)
- **建筑 / 生产方式：** 铁矿 (`iron_ore_collector`)
- **自然资源：** 铁矿 (`iron_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铁矿石**（`good`）：`good.iron_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **铁矿**（`building`）：`building.iron_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铁矿**（`resource`）：`resource.iron_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿：`country.output.building.iron_ore_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 地表铁矿采集 (`tech.surface_iron_collection`)

#### 同路线后继

无

#### 应用交汇目标

- 自然哲学 (`tech.natural_philosophy`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 铁矿辨识 (`tech.iron_ore_identification`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：金属工具；解锁建筑：浅层铁矿；开放通用职业阶层岗位；开放通用职业阶层岗位；浅层铁矿产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 金属工具 (`tools`)
- **建筑 / 生产方式：** 浅层铁矿 (`early_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 块炼炉 (`bloomery`)；铁制工具工坊 (`iron_tool_workshop`)

#### 结构化内容效果

- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **浅层铁矿**（`building`）：`building.early_iron_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **青铜工具**（`good`）：`good.bronze_tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 浅层铁矿：`country.output.building.early_iron_mine_factor`：+20%

#### 直接后继（硬前置关系）

- 露头煤辨识 (`tech.coal_outcrop_identification`)

#### 同路线后继

无

#### 应用交汇目标

- 自然哲学 (`tech.natural_philosophy`)

#### 作为候选参与的里程碑

无

### 露头煤辨识 (`tech.coal_outcrop_identification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_outcrop_identification` |
| 时代 | 王国时代 (`kingdom`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 23400 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | identification |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 地表铁矿采集 (`tech.surface_iron_collection`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

可利用资源：煤炭；铁矿业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 煤炭 (`coal`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 露头煤采集场 (`surface_coal_gathering`)

#### 结构化内容效果

- **煤炭**（`resource`）：`resource.coal` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿业：`country.output.family.iron_extraction_factor`：+10%

#### 直接后继（硬前置关系）

- 地表煤采集 (`tech.surface_coal_collection`)

#### 同路线后继

无

#### 应用交汇目标

- 自然哲学 (`tech.natural_philosophy`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 露头煤辨识 (`tech.coal_outcrop_identification`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：露头煤采集场；开放通用职业阶层岗位；露头煤采集场产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露头煤采集场 (`surface_coal_gathering`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 煤层平硐 (`coal_adit`)

#### 结构化内容效果

- **露头煤采集场**（`building`）：`building.surface_coal_gathering` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 露头煤采集场：`country.output.building.surface_coal_gathering_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 自然哲学 (`tech.natural_philosophy`)

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
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 农耕社会 (`tech.agrarian_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「农耕社会」（tech.agrarian\_society）
  - 满足其一：
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

海运业产出 +11%；国家协同能力 +3%

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

- 海运业：`country.output.family.maritime_operations_factor`：+11%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 区域粮仓 (`tech.regional_granaries`)

#### 应用交汇目标

- 区域粮仓 (`tech.regional_granaries`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

海运业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 砌体建筑 (`tech.masonry`)
- 块炼铁 (`tech.iron_smelting`)
- 市场制度 (`tech.market_institutions`)
- 货币 (`tech.currency`)
- 运河工程 (`tech.canal_engineering`)
- 河运 (`tech.river_transport`)
- 轮作 (`tech.crop_rotation`)
- 城市卫生 (`tech.urban_sanitation`)
- 自然哲学 (`tech.natural_philosophy`)
- 地表煤利用 (`tech.surface_coal_use`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)
- 树皮纸 (`tech.bark_paper_making`)
- 皮纸制作 (`tech.parchment_making`)
- 习惯佃作 (`tech.customary_tenancy`)
- 分成租佃 (`tech.sharecropping`)
- 佃作水田 (`tech.tenant_paddy_management`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运业：`country.output.family.maritime_operations_factor`：+10%

#### 直接后继（硬前置关系）

- 森林管理 (`tech.forest_management`)
- 牧业网络 (`tech.pastoral_networks`)
- 集约轮作 (`tech.intensive_crop_rotation`)
- 水力机械 (`tech.water_power`)
- 风力机械 (`tech.wind_power`)
- 行业组织 (`tech.guild_organization`)
- 高炉冶炼 (`tech.blast_furnace`)
- 坩埚钢 (`tech.crucible_steel`)
- 煤矿开采 (`tech.coal_mining`)
- 破布纸 (`tech.rag_paper_making`)
- 活字印刷 (`tech.movable_type_printing`)
- 火药配制 (`tech.gunpowder_formulation`)
- 磁针导航 (`tech.magnetic_navigation`)
- 城市水务 (`tech.urban_waterworks`)
- 经院研究法 (`tech.scholastic_method`)
- 农奴义务 (`tech.serf_obligations`)
- 庄园谷物经营 (`tech.manorial_cereal_farming`)
- 区域粮仓 (`tech.regional_granaries`)
- 庄园谷物核算 (`tech.estate_cereal_management`)
- 庄园水田核算 (`tech.estate_paddy_management`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-4"></a>
## 帝国时代

共 28 项科技，研究成本范围 42000-70000；时代里程碑：帝国网络 (`tech.imperial_integration`)。

### 森林管理 (`tech.forest_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.forest_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 树皮纸 (`tech.bark_paper_making`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁建筑：水力锯木场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：商营伐木场；水力锯木场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 水力锯木场 (`method_lumber_plant_r4`)；商营伐木场 (`method_timber_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)

#### 结构化内容效果

- **水力锯木场**（`building`）：`building.method_lumber_plant_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **商营伐木场**（`building`）：`building.method_timber_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 水力锯木场：`country.output.building.method_lumber_plant_r4_factor`：+25%

#### 直接后继（硬前置关系）

- 螺旋压印 (`tech.screw_press_printing`)

#### 同路线后继

- 螺旋压印 (`tech.screw_press_printing`)

#### 应用交汇目标

- 螺旋压印 (`tech.screw_press_printing`)
- 水力机械 (`tech.water_power`)
- 经院研究法 (`tech.scholastic_method`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 牧业网络 (`tech.pastoral_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.pastoral_networks` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；生态 · 草原 (\`route.ecology.steppe\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 皮纸制作 (`tech.parchment_making`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁建筑：庄园牧场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：机械化牧场；庄园牧场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 庄园牧场 (`manorial_pasture`)；机械化牧场 (`ranching_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园牧场**（`building`）：`building.manorial_pasture` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **机械化牧场**（`building`）：`building.ranching_station` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 庄园牧场：`country.output.building.manorial_pasture_factor`：+25%

#### 直接后继（硬前置关系）

- 商业农庄 (`tech.commercial_estates`)

#### 同路线后继

- 商业农庄 (`tech.commercial_estates`)

#### 应用交汇目标

- 商业农庄 (`tech.commercial_estates`)
- 城市水务 (`tech.urban_waterworks`)
- 区域粮仓 (`tech.regional_granaries`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 集约轮作 (`tech.intensive_crop_rotation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.intensive_crop_rotation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 轮作 (`tech.crop_rotation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：佃作小麦庄园；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：三圃制小农场；佃作小麦庄园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作小麦庄园 (`method_wheat_farm_r3`)；三圃制小农场 (`three_field_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作小麦庄园**（`building`）：`building.method_wheat_farm_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **小麦**（`good`）：`good.wheat_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **三圃制小农场**（`building`）：`building.three_field_smallholding` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 佃作小麦庄园：`country.output.building.method_wheat_farm_r3_factor`：+25%

#### 直接后继（硬前置关系）

- 作物移植适应 (`tech.crop_transplantation`)

#### 同路线后继

- 作物移植适应 (`tech.crop_transplantation`)

#### 应用交汇目标

- 作物移植适应 (`tech.crop_transplantation`)
- 破布纸 (`tech.rag_paper_making`)
- 活字印刷 (`tech.movable_type_printing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；能源 · 水力 (\`route.energy.water\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 运河工程 (`tech.canal_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：河流水力发电站；开放通用职业阶层岗位；开放通用职业阶层岗位；需要河流地块条件；河流水力发电站产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 河流水力发电站 (`hydropower_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **河流水力发电站**（`building`）：`building.hydropower_station` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 河流水力发电站：`country.output.building.hydropower_station_factor`：+25%

#### 直接后继（硬前置关系）

- 矿井排水 (`tech.mine_drainage`)

#### 同路线后继

- 矿井排水 (`tech.mine_drainage`)

#### 应用交汇目标

- 矿井排水 (`tech.mine_drainage`)
- 磁针导航 (`tech.magnetic_navigation`)
- 经院研究法 (`tech.scholastic_method`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 风力机械 (`tech.wind_power`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wind_power` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；能源 · 风力 (\`route.energy.wind\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 地表煤利用 (`tech.surface_coal_use`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
    - 已发现信号「季风经验」（weather.monsoon）
    - 已发现信号「台风经验」（weather.typhoon）

#### 效果摘要

可再生能源业产出 +12%；国家协同能力 +3%

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

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+12%
- `country.output.energy_factor`：+3%

#### 直接后继（硬前置关系）

- 天文导航 (`tech.celestial_navigation`)

#### 同路线后继

- 天文导航 (`tech.celestial_navigation`)

#### 应用交汇目标

- 天文导航 (`tech.celestial_navigation`)
- 煤矿开采 (`tech.coal_mining`)
- 行业组织 (`tech.guild_organization`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 行业组织 (`tech.guild_organization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.guild_organization` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 全部路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：衣物；解锁物资：家具；解锁建筑：家具行会工坊；开放通用职业阶层岗位；家具行会工坊产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 衣物 (`clothing`)；家具 (`furniture`)
- **建筑 / 生产方式：** 家具行会工坊 (`guild_hall`)；裁缝铺 (`tailor_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)；包装材料厂 (`packaging_plant`)；印刷厂 (`printed_materials_plant`)

#### 结构化内容效果

- **衣物**（`good`）：`good.clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **家具**（`good`）：`good.furniture` → `production_access` `unlock` `1.0`；`existing_binding`
- **家具行会工坊**（`building`）：`building.guild_hall` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **家具**（`good`）：`good.furniture` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **裁缝铺**（`building`）：`building.tailor_shop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家具行会工坊：`country.output.building.guild_hall_factor`：+25%

#### 直接后继（硬前置关系）

- 特许大学 (`tech.chartered_universities`)

#### 同路线后继

- 复式记账 (`tech.double_entry_bookkeeping`)

#### 应用交汇目标

- 复式记账 (`tech.double_entry_bookkeeping`)

#### 作为候选参与的里程碑

无

### 高炉冶炼 (`tech.blast_furnace`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.blast_furnace` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 块炼铁 (`tech.iron_smelting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「野生动物」（resource.wild\_game）
    - 已发现信号「羊」（bio.sheep）
    - 已发现信号「草原」（landform.grassland）

#### 效果摘要

解锁物资：钢材；解锁建筑：焦炭炼钢厂；开放通用职业阶层岗位；开放通用职业阶层岗位；焦炭炼钢厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 钢材 (`steel`)
- **建筑 / 生产方式：** 焦炭炼钢厂 (`steam_steel_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`existing_binding`
- **焦炭炼钢厂**（`building`）：`building.steam_steel_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **焦炭**（`good`）：`good.coke` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 焦炭炼钢厂：`country.output.building.steam_steel_works_factor`：+25%

#### 直接后继（硬前置关系）

- 煤矿平硐 (`tech.coal_adit_mining`)
- 深井采矿 (`tech.deep_mining`)

#### 同路线后继

- 深井采矿 (`tech.deep_mining`)

#### 应用交汇目标

- 深井采矿 (`tech.deep_mining`)
- 磁针导航 (`tech.magnetic_navigation`)
- 行业组织 (`tech.guild_organization`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 坩埚钢 (`tech.crucible_steel`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crucible_steel` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 铁 (\`route.resource.iron\`) |
| 全部路线 | 资源 · 铁 (\`route.resource.iron\`)；资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 货币 (`tech.currency`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：金属工具；钢铁业产出 +12%；国家协同能力 +3%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 金属工具 (`tools`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 钢铁业：`country.output.family.steelmaking_factor`：+12%
- `country.output.manufacturing_factor`：+3%

#### 直接后继（硬前置关系）

- 井筒开掘 (`tech.shaft_sinking`)

#### 同路线后继

- 井筒开掘 (`tech.shaft_sinking`)

#### 应用交汇目标

- 井筒开掘 (`tech.shaft_sinking`)
- 火药配制 (`tech.gunpowder_formulation`)
- 经院研究法 (`tech.scholastic_method`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 煤矿开采 (`tech.coal_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_mining` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 自然哲学 (`tech.natural_philosophy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：煤炭；解锁建筑：煤矿；开放通用职业阶层岗位；开放通用职业阶层岗位；煤矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 煤矿 (`coal_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`existing_binding`
- **煤矿**（`building`）：`building.coal_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 煤矿：`country.output.building.coal_mine_factor`：+25%

#### 直接后继（硬前置关系）

- 特许商社 (`tech.chartered_companies`)

#### 同路线后继

- 特许商社 (`tech.chartered_companies`)

#### 应用交汇目标

- 特许商社 (`tech.chartered_companies`)
- 风力机械 (`tech.wind_power`)
- 活字印刷 (`tech.movable_type_printing`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 破布纸 (`tech.rag_paper_making`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rag_paper_making` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；制度 · 文字 (\`route.institution.writing\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：纸张；解锁建筑：碎布造纸工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；碎布造纸工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 纸张 (`paper`)
- **建筑 / 生产方式：** 碎布造纸工坊 (`rag_paper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **纸张**（`good`）：`good.paper` → `production_access` `unlock` `1.0`；`existing_binding`
- **碎布造纸工坊**（`building`）：`building.rag_paper_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 碎布造纸工坊：`country.output.building.rag_paper_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 商品作物管理 (`tech.commodity_crop_management`)

#### 同路线后继

- 商品作物管理 (`tech.commodity_crop_management`)

#### 应用交汇目标

- 商品作物管理 (`tech.commodity_crop_management`)
- 磁针导航 (`tech.magnetic_navigation`)
- 区域粮仓 (`tech.regional_granaries`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 木版印刷 (`tech.woodblock_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.woodblock_printing` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 文字 (`tech.writing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：印刷品；解锁建筑：木版印刷坊；开放通用职业阶层岗位；开放通用职业阶层岗位；木版印刷坊产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 木版印刷坊 (`woodblock_printing_house`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`existing_binding`
- **木版印刷坊**（`building`）：`building.woodblock_printing_house` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 木版印刷坊：`country.output.building.woodblock_printing_house_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 活字印刷 (`tech.movable_type_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.movable_type_printing` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：印刷品；解锁建筑：活字印刷坊；开放通用职业阶层岗位；开放通用职业阶层岗位；活字印刷坊产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 活字印刷坊 (`movable_type_print_shop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`existing_binding`
- **活字印刷坊**（`building`）：`building.movable_type_print_shop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 活字印刷坊：`country.output.building.movable_type_print_shop_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 机械计时 (`tech.mechanical_timekeeping`)

#### 应用交汇目标

- 机械计时 (`tech.mechanical_timekeeping`)

#### 作为候选参与的里程碑

无

### 火药配制 (`tech.gunpowder_formulation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gunpowder_formulation` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 硝石 (\`route.resource.saltpeter\`) |
| 全部路线 | 资源 · 硝石 (\`route.resource.saltpeter\`)；资源 · 硫 (\`route.resource.sulfur\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 城市卫生 (`tech.urban_sanitation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）
    - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：炸药；解锁物资：硝石；解锁建筑：硝石矿；开放通用职业阶层岗位；硝石矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 炸药 (`explosives`)；硝石 (`saltpeter`)
- **建筑 / 生产方式：** 硝石矿 (`saltpeter_collector`)；硫矿 (`sulfur_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **炸药**（`good`）：`good.explosives` → `production_access` `unlock` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `production_access` `unlock` `1.0`；`existing_binding`
- **硝石矿**（`building`）：`building.saltpeter_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硫矿**（`building`）：`building.sulfur_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 硝石矿：`country.output.building.saltpeter_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 火药武器 (`tech.gunpowder_weapons`)

#### 同路线后继

- 火药武器 (`tech.gunpowder_weapons`)

#### 应用交汇目标

- 火药武器 (`tech.gunpowder_weapons`)
- 城市水务 (`tech.urban_waterworks`)
- 区域粮仓 (`tech.regional_granaries`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 河运 (`tech.river_transport`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运业产出 +12%；国家协同能力 +3%

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

- 海运业：`country.output.family.maritime_operations_factor`：+12%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

- 远洋航海 (`tech.oceanic_navigation`)

#### 同路线后继

- 远洋航海 (`tech.oceanic_navigation`)

#### 应用交汇目标

- 远洋航海 (`tech.oceanic_navigation`)
- 农奴义务 (`tech.serf_obligations`)
- 行业组织 (`tech.guild_organization`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 砌体建筑 (`tech.masonry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +12%；国家协同能力 +3%

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

- 公共营造：`country.output.family.construction_methods_factor`：+12%
- `country.output.energy_factor`：+3%

#### 直接后继（硬前置关系）

- 海岸船厂 (`tech.coastal_shipyards`)

#### 同路线后继

- 海岸船厂 (`tech.coastal_shipyards`)

#### 应用交汇目标

- 海岸船厂 (`tech.coastal_shipyards`)
- 风力机械 (`tech.wind_power`)
- 活字印刷 (`tech.movable_type_printing`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 经院研究法 (`tech.scholastic_method`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scholastic_method` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 42000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +11%；国家协同能力 +3%

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

- 造纸业：`country.output.family.paper_making_factor`：+11%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 地图学 (`tech.cartography`)

#### 应用交汇目标

- 地图学 (`tech.cartography`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 大学 (\`route.institution.university\`) |
| 全部路线 | 制度 · 大学 (\`route.institution.university\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 行业组织 (`tech.guild_organization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：特许大学；开放通用职业阶层岗位；开放科技职业阶层岗位；解锁建筑：印刷学社；特许大学产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 特许大学 (`chartered_university`)；印刷学社 (`printing_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **特许大学**（`building`）：`building.chartered_university` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **手抄本**（`good`）：`good.manuscripts` → `input_method_access` `enable` `1.0`；`existing_binding`
- **印刷学社**（`building`）：`building.printing_academy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 特许大学：`country.output.building.chartered_university_factor`：+20%

#### 直接后继（硬前置关系）

- 庄园司法 (`tech.manorial_jurisdiction`)

#### 同路线后继

无

#### 应用交汇目标

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 特许大学 (`tech.chartered_universities`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运业产出 +10%

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

- 海运业：`country.output.family.maritime_operations_factor`：+10%

#### 直接后继（硬前置关系）

- 行会学徒制 (`tech.guild_apprenticeship`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 农奴义务 (`tech.serf_obligations`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.serf_obligations` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 市场制度 (`tech.market_institutions`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 庄园水田 (`estate_paddy`)；玉米庄园 (`landed_estate`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运业：`country.output.family.maritime_operations_factor`：+12%

#### 直接后继（硬前置关系）

- 种植园庄园管理 (`tech.estate_plantation_management`)

#### 同路线后继

- 种植园庄园管理 (`tech.estate_plantation_management`)

#### 应用交汇目标

- 种植园庄园管理 (`tech.estate_plantation_management`)
- 破布纸 (`tech.rag_paper_making`)
- 活字印刷 (`tech.movable_type_printing`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 庄园谷物经营 (`tech.manorial_cereal_farming`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.manorial_cereal_farming` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 习惯佃作 (`tech.customary_tenancy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

主粮加工产出 +12%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+12%

#### 直接后继（硬前置关系）

- 农艺交换 (`tech.agronomic_exchange`)

#### 同路线后继

- 农艺交换 (`tech.agronomic_exchange`)

#### 应用交汇目标

- 农艺交换 (`tech.agronomic_exchange`)
- 农奴义务 (`tech.serf_obligations`)
- 区域粮仓 (`tech.regional_granaries`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 行会学徒制 (`tech.guild_apprenticeship`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.guild_apprenticeship` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 全部路线 | 制度 · 行会 (\`route.institution.guild\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 庄园司法 (`tech.manorial_jurisdiction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：华服；解锁物资：精美家具；解锁建筑：细木家具工坊；开放通用职业阶层岗位；细木家具工坊产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 华服 (`fine_clothing`)；精美家具 (`fine_furniture`)
- **建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；宫廷裁缝坊 (`court_tailor`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；活字印刷坊 (`movable_type_print_shop`)

#### 结构化内容效果

- **华服**（`good`）：`good.fine_clothing` → `production_access` `unlock` `1.0`；`existing_binding`
- **精美家具**（`good`）：`good.fine_furniture` → `production_access` `unlock` `1.0`；`existing_binding`
- **细木家具工坊**（`building`）：`building.cabinetmaker_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **精美家具**（`good`）：`good.fine_furniture` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **宫廷裁缝坊**（`building`）：`building.court_tailor` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **华服**（`good`）：`good.fine_clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **毛皮**（`good`）：`good.fur` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 细木家具工坊：`country.output.building.cabinetmaker_workshop_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运业产出 +11%

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

- 海运业：`country.output.family.maritime_operations_factor`：+11%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 远洋补给 (`tech.oceanic_provisioning`)

#### 应用交汇目标

- 远洋补给 (`tech.oceanic_provisioning`)

#### 作为候选参与的里程碑

无

### 煤矿平硐 (`tech.coal_adit_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_adit_mining` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 54600 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 高炉冶炼 (`tech.blast_furnace`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：煤层平硐；开放通用职业阶层岗位；开放通用职业阶层岗位；煤层平硐产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 煤层平硐 (`coal_adit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤层平硐**（`building`）：`building.coal_adit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 煤层平硐：`country.output.building.coal_adit_factor`：+20%

#### 直接后继（硬前置关系）

- 矿井木支护 (`tech.mine_timbering`)

#### 同路线后继

无

#### 应用交汇目标

- 磁针导航 (`tech.magnetic_navigation`)
- 行业组织 (`tech.guild_organization`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 煤矿平硐 (`tech.coal_adit_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁建筑：浅层铜矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：浅层锡矿；浅层铜矿产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)；浅层锡矿 (`early_tin_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅层铜矿**（`building`）：`building.early_copper_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铜矿石**（`good`）：`good.copper_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **浅层锡矿**（`building`）：`building.early_tin_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锡矿石**（`good`）：`good.tin_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 浅层铜矿：`country.output.building.early_copper_mine_factor`：+20%

#### 直接后继（硬前置关系）

- 矿井通风 (`tech.mine_ventilation`)

#### 同路线后继

无

#### 应用交汇目标

- 磁针导航 (`tech.magnetic_navigation`)
- 行业组织 (`tech.guild_organization`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 矿井木支护 (`tech.mine_timbering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：铅矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：锌矿；铅矿产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铅矿 (`lead_ore_collector`)；锌矿 (`zinc_ore_collector`)
- **自然资源：** 铅矿 (`lead_ore`)；锌矿 (`zinc_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铅矿**（`building`）：`building.lead_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铅矿石**（`good`）：`good.lead_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锌矿**（`building`）：`building.zinc_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锌矿石**（`good`）：`good.zinc_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铅矿**（`resource`）：`resource.lead_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锌矿**（`resource`）：`resource.zinc_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铅矿：`country.output.building.lead_ore_collector_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 磁针导航 (`tech.magnetic_navigation`)
- 行业组织 (`tech.guild_organization`)

#### 作为候选参与的里程碑

无

### 庄园谷物核算 (`tech.estate_cereal_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_cereal_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 分成租佃 (`tech.sharecropping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：玉米庄园；开放通用职业阶层岗位；开放通用职业阶层岗位；玉米庄园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玉米庄园 (`landed_estate`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玉米庄园**（`building`）：`building.landed_estate` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 玉米庄园：`country.output.building.landed_estate_factor`：+25%

#### 直接后继（硬前置关系）

- 作物驯化移植 (`tech.crop_acclimatization`)

#### 同路线后继

- 作物驯化移植 (`tech.crop_acclimatization`)

#### 应用交汇目标

- 作物驯化移植 (`tech.crop_acclimatization`)
- 牧业网络 (`tech.pastoral_networks`)
- 行业组织 (`tech.guild_organization`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

### 庄园水田核算 (`tech.estate_paddy_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_paddy_management` |
| 时代 | 帝国时代 (`empire`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 47600 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 水稻 (\`route.crop.rice\`) |
| 全部路线 | 作物 · 水稻 (\`route.crop.rice\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 王国体系 (`tech.kingdom_administration`)
- 佃作水田 (`tech.tenant_paddy_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「王国体系」（tech.kingdom\_administration）
  - 满足其一：
    - 已发现信号「水田承载力」（resource.paddy\_land）
    - 已发现信号「洪泛平原」（landform.floodplain）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：庄园水田；开放通用职业阶层岗位；开放通用职业阶层岗位；开放劳动者阶层岗位；庄园水田产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 庄园水田 (`estate_paddy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园水田**（`building`）：`building.estate_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **劳动者阶层**（`class`）：`class.worker` → `employment_access` `enable` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 庄园水田：`country.output.building.estate_paddy_factor`：+25%

#### 直接后继（硬前置关系）

- 跨区域植物学 (`tech.interregional_botany`)

#### 同路线后继

- 跨区域植物学 (`tech.interregional_botany`)

#### 应用交汇目标

- 跨区域植物学 (`tech.interregional_botany`)
- 磁针导航 (`tech.magnetic_navigation`)
- 经院研究法 (`tech.scholastic_method`)

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

造纸业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 森林管理 (`tech.forest_management`)
- 牧业网络 (`tech.pastoral_networks`)
- 集约轮作 (`tech.intensive_crop_rotation`)
- 水力机械 (`tech.water_power`)
- 风力机械 (`tech.wind_power`)
- 高炉冶炼 (`tech.blast_furnace`)
- 坩埚钢 (`tech.crucible_steel`)
- 煤矿开采 (`tech.coal_mining`)
- 破布纸 (`tech.rag_paper_making`)
- 火药配制 (`tech.gunpowder_formulation`)
- 磁针导航 (`tech.magnetic_navigation`)
- 城市水务 (`tech.urban_waterworks`)
- 农奴义务 (`tech.serf_obligations`)
- 庄园谷物经营 (`tech.manorial_cereal_farming`)
- 庄园谷物核算 (`tech.estate_cereal_management`)
- 庄园水田核算 (`tech.estate_paddy_management`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 造纸业：`country.output.family.paper_making_factor`：+10%

#### 直接后继（硬前置关系）

- 地图学 (`tech.cartography`)
- 天文导航 (`tech.celestial_navigation`)
- 远洋航海 (`tech.oceanic_navigation`)
- 海岸船厂 (`tech.coastal_shipyards`)
- 螺旋压印 (`tech.screw_press_printing`)
- 火药武器 (`tech.gunpowder_weapons`)
- 深井采矿 (`tech.deep_mining`)
- 复式记账 (`tech.double_entry_bookkeeping`)
- 商业农庄 (`tech.commercial_estates`)
- 作物驯化移植 (`tech.crop_acclimatization`)
- 跨区域植物学 (`tech.interregional_botany`)
- 机械计时 (`tech.mechanical_timekeeping`)
- 井筒开掘 (`tech.shaft_sinking`)
- 矿井排水 (`tech.mine_drainage`)
- 特许商社 (`tech.chartered_companies`)
- 种植园庄园管理 (`tech.estate_plantation_management`)
- 商品作物管理 (`tech.commodity_crop_management`)
- 远洋补给 (`tech.oceanic_provisioning`)
- 农艺交换 (`tech.agronomic_exchange`)
- 作物移植适应 (`tech.crop_transplantation`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-5"></a>
## 探索时代

共 25 项科技，研究成本范围 96000-160000；时代里程碑：洲际网络 (`tech.global_exchange`)。

### 地图学 (`tech.cartography`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cartography` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +11%

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

- 造纸业：`country.output.family.paper_making_factor`：+11%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 实验科学 (`tech.experimental_science`)

#### 应用交汇目标

- 实验科学 (`tech.experimental_science`)

#### 作为候选参与的里程碑

无

### 天文导航 (`tech.celestial_navigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.celestial_navigation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 历法 (\`route.institution.calendar\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 风力机械 (`tech.wind_power`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运业产出 +12%

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

- 海运业：`country.output.family.maritime_operations_factor`：+12%

#### 直接后继（硬前置关系）

- 蒸汽密封 (`tech.steam_sealing`)

#### 同路线后继

- 蒸汽密封 (`tech.steam_sealing`)

#### 应用交汇目标

- 蒸汽密封 (`tech.steam_sealing`)
- 井筒开掘 (`tech.shaft_sinking`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 远洋航海 (`tech.oceanic_navigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oceanic_navigation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 磁针导航 (`tech.magnetic_navigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：远洋船舶；解锁建筑：远洋造船厂；开放通用职业阶层岗位；开放通用职业阶层岗位；远洋造船厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 远洋船舶 (`oceanic_vessels`)
- **建筑 / 生产方式：** 远洋造船厂 (`oceanic_shipyard`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 远洋渔场 (`method_marine_fish_collector_r4`)；蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

- **远洋船舶**（`good`）：`good.oceanic_vessels` → `production_access` `unlock` `1.0`；`existing_binding`
- **远洋造船厂**（`building`）：`building.oceanic_shipyard` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 远洋造船厂：`country.output.building.oceanic_shipyard_factor`：+25%

#### 直接后继（硬前置关系）

- 远洋船舶设计 (`tech.oceanic_ship_design`)
- 精密仪器 (`tech.precision_instruments`)

#### 同路线后继

- 精密仪器 (`tech.precision_instruments`)

#### 应用交汇目标

- 精密仪器 (`tech.precision_instruments`)
- 螺旋压印 (`tech.screw_press_printing`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 远洋船舶设计 (`tech.oceanic_ship_design`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.oceanic_ship_design` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 远洋航海 (`tech.oceanic_navigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

运输装备业产出 +10%

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

- 运输装备业：`country.output.family.railway_equipment_making_factor`：+10%

#### 直接后继（硬前置关系）

- 商业网络 (`tech.mercantile_networks`)

#### 同路线后继

无

#### 应用交汇目标

- 螺旋压印 (`tech.screw_press_printing`)

#### 作为候选参与的里程碑

无

### 海岸船厂 (`tech.coastal_shipyards`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coastal_shipyards` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 城市水务 (`tech.urban_waterworks`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：蒸汽航运船坞；开放通用职业阶层岗位；开放通用职业阶层岗位；蒸汽航运船坞产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽航运船坞**（`building`）：`building.method_steam_shipping` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 蒸汽航运船坞：`country.output.building.method_steam_shipping_factor`：+25%

#### 直接后继（硬前置关系）

- 地产测绘 (`tech.property_cadastre`)

#### 同路线后继

- 地产测绘 (`tech.property_cadastre`)

#### 应用交汇目标

- 地产测绘 (`tech.property_cadastre`)
- 螺旋压印 (`tech.screw_press_printing`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 螺旋压印 (`tech.screw_press_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.screw_press_printing` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 森林管理 (`tech.forest_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：包装材料；解锁物资：印刷品；解锁建筑：包装材料厂；开放通用职业阶层岗位；包装材料厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 包装材料 (`packaging`)；印刷品 (`printed_materials`)
- **建筑 / 生产方式：** 包装材料厂 (`packaging_plant`)；印刷厂 (`printed_materials_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 印刷学社 (`printing_academy`)

#### 结构化内容效果

- **包装材料**（`good`）：`good.packaging` → `production_access` `unlock` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `production_access` `unlock` `1.0`；`existing_binding`
- **包装材料厂**（`building`）：`building.packaging_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **印刷厂**（`building`）：`building.printed_materials_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 包装材料厂：`country.output.building.packaging_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 学术社团 (`tech.learned_societies`)

#### 同路线后继

- 学术社团 (`tech.learned_societies`)

#### 应用交汇目标

- 学术社团 (`tech.learned_societies`)
- 海岸船厂 (`tech.coastal_shipyards`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 火药武器 (`tech.gunpowder_weapons`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.gunpowder_weapons` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 硝石 (\`route.resource.saltpeter\`) |
| 全部路线 | 资源 · 硝石 (\`route.resource.saltpeter\`)；资源 · 硫 (\`route.resource.sulfur\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 火药配制 (`tech.gunpowder_formulation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）
    - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：炸药；解锁物资：硫磺；解锁建筑：炸药厂；开放通用职业阶层岗位；炸药厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 炸药 (`explosives`)；硫磺 (`sulfur`)
- **建筑 / 生产方式：** 炸药厂 (`explosives_plant`)；自动化炸药厂 (`method_explosives_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)

#### 结构化内容效果

- **炸药**（`good`）：`good.explosives` → `production_access` `unlock` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `production_access` `unlock` `1.0`；`existing_binding`
- **炸药厂**（`building`）：`building.explosives_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化炸药厂**（`building`）：`building.method_explosives_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 炸药厂：`country.output.building.explosives_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 公共卫生 (`tech.public_health`)

#### 同路线后继

- 公共卫生 (`tech.public_health`)

#### 应用交汇目标

- 公共卫生 (`tech.public_health`)
- 农艺交换 (`tech.agronomic_exchange`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 深井采矿 (`tech.deep_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deep_mining` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 高炉冶炼 (`tech.blast_furnace`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：铅矿石；解锁物资：锌矿石；铁矿业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铅矿石 (`lead_ore`)；锌矿石 (`zinc_ore`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 金矿 (`gold_mine`)；深井盐矿 (`industrial_salt_mine`)；铅矿 (`lead_ore_collector`)；硅砂矿 (`silica_sand_collector`)；银矿 (`silver_mine`)；锌矿 (`zinc_ore_collector`)

#### 结构化内容效果

- **铅矿石**（`good`）：`good.lead_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **锌矿石**（`good`）：`good.zinc_ore` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿业：`country.output.family.iron_extraction_factor`：+12%

#### 直接后继（硬前置关系）

- 大气式蒸汽机 (`tech.atmospheric_engine`)

#### 同路线后继

- 大气式蒸汽机 (`tech.atmospheric_engine`)

#### 应用交汇目标

- 大气式蒸汽机 (`tech.atmospheric_engine`)
- 井筒开掘 (`tech.shaft_sinking`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 复式记账 (`tech.double_entry_bookkeeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.double_entry_bookkeeping` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

公共营造产出 +11%

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

- 公共营造：`country.output.family.construction_methods_factor`：+11%

#### 直接后继（硬前置关系）

- 商业租佃 (`tech.commercial_tenancy`)
- 政治经济学 (`tech.political_economy`)

#### 同路线后继

- 合作社组织 (`tech.cooperative_association`)

#### 应用交汇目标

- 合作社组织 (`tech.cooperative_association`)

#### 作为候选参与的里程碑

无

### 商业农庄 (`tech.commercial_estates`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commercial_estates` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 牧业网络 (`tech.pastoral_networks`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：药材种植园；开放通用职业阶层岗位；开放通用职业阶层岗位；药材种植园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 药材种植园 (`medicinal_herbs_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药材种植园**（`building`）：`building.medicinal_herbs_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **药材**（`good`）：`good.medicinal_herbs` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 药材种植园：`country.output.building.medicinal_herbs_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 畜种改良 (`tech.livestock_breeding`)

#### 同路线后继

- 畜种改良 (`tech.livestock_breeding`)

#### 应用交汇目标

- 畜种改良 (`tech.livestock_breeding`)
- 商品作物管理 (`tech.commodity_crop_management`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 作物驯化移植 (`tech.crop_acclimatization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_acclimatization` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 庄园谷物核算 (`tech.estate_cereal_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「块茎样本接触」（contact.potato）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

可利用资源：种植园承载力；主粮加工产出 +12%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+12%

#### 直接后继（硬前置关系）

- 系统育种 (`tech.crop_breeding`)

#### 同路线后继

- 系统育种 (`tech.crop_breeding`)

#### 应用交汇目标

- 系统育种 (`tech.crop_breeding`)
- 火药武器 (`tech.gunpowder_weapons`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 跨区域植物学 (`tech.interregional_botany`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.interregional_botany` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`)；制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 庄园水田核算 (`tech.estate_paddy_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +12%

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

- 造纸业：`country.output.family.paper_making_factor`：+12%

#### 直接后继（硬前置关系）

- 农业合作社 (`tech.agricultural_cooperatives`)

#### 同路线后继

- 农业合作社 (`tech.agricultural_cooperatives`)

#### 应用交汇目标

- 农业合作社 (`tech.agricultural_cooperatives`)
- 矿井排水 (`tech.mine_drainage`)

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
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 远洋船舶设计 (`tech.oceanic_ship_design`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +10%

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

- 造纸业：`country.output.family.paper_making_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 螺旋压印 (`tech.screw_press_printing`)

#### 作为候选参与的里程碑

无

### 机械计时 (`tech.mechanical_timekeeping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_timekeeping` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 96000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「金属加工突破」（breakthrough.metalworking）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
    - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

金属工具业产出 +11%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+11%

#### 直接后继（硬前置关系）

- 精密工程 (`tech.precision_engineering`)

#### 同路线后继

- 标准化 (`tech.standardization`)

#### 应用交汇目标

- 标准化 (`tech.standardization`)

#### 作为候选参与的里程碑

无

### 井筒开掘 (`tech.shaft_sinking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.shaft_sinking` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 坩埚钢 (`tech.crucible_steel`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：金矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：银矿；金矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金矿 (`gold_mine`)；银矿 (`silver_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **金矿**（`building`）：`building.gold_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **黄金**（`good`）：`good.gold` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **银矿**（`building`）：`building.silver_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **白银**（`good`）：`good.silver` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 金矿：`country.output.building.gold_mine_factor`：+25%

#### 直接后继（硬前置关系）

- 地质勘探 (`tech.geological_prospecting`)

#### 同路线后继

- 地质勘探 (`tech.geological_prospecting`)

#### 应用交汇目标

- 地质勘探 (`tech.geological_prospecting`)
- 深井采矿 (`tech.deep_mining`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 矿井排水 (`tech.mine_drainage`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mine_drainage` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 水力机械 (`tech.water_power`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：深井盐矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：锡矿；深井盐矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 深井盐矿 (`industrial_salt_mine`)；锡矿 (`tin_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 硅砂矿 (`silica_sand_collector`)

#### 结构化内容效果

- **深井盐矿**（`building`）：`building.industrial_salt_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锡矿**（`building`）：`building.tin_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锡矿石**（`good`）：`good.tin_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 深井盐矿：`country.output.building.industrial_salt_mine_factor`：+25%

#### 直接后继（硬前置关系）

- 水利工程 (`tech.hydraulic_engineering`)

#### 同路线后继

- 水利工程 (`tech.hydraulic_engineering`)

#### 应用交汇目标

- 水利工程 (`tech.hydraulic_engineering`)
- 跨区域植物学 (`tech.interregional_botany`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 商业租佃 (`tech.commercial_tenancy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.commercial_tenancy` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 124800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 复式记账 (`tech.double_entry_bookkeeping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

公共营造产出 +10%

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

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

- 契约劳工制度 (`tech.indentured_contracts`)

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 煤矿开采 (`tech.coal_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

公共营造产出 +12%

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

- 公共营造：`country.output.family.construction_methods_factor`：+12%

#### 直接后继（硬前置关系）

- 煤层地质 (`tech.coal_geology`)

#### 同路线后继

- 煤层地质 (`tech.coal_geology`)

#### 应用交汇目标

- 煤层地质 (`tech.coal_geology`)
- 火药武器 (`tech.gunpowder_weapons`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 种植园庄园管理 (`tech.estate_plantation_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.estate_plantation_management` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 农奴义务 (`tech.serf_obligations`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：棉花农场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：香料种植园；棉花农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；香料种植园 (`spice_plants_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 橡胶种植园 (`rubber_tree_collector`)

#### 结构化内容效果

- **棉花农场**（`building`）：`building.cotton_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **香料种植园**（`building`）：`building.spice_plants_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **香料**（`good`）：`good.spices` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 棉花农场：`country.output.building.cotton_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 科学分类 (`tech.scientific_classification`)

#### 同路线后继

- 科学分类 (`tech.scientific_classification`)

#### 应用交汇目标

- 科学分类 (`tech.scientific_classification`)
- 远洋航海 (`tech.oceanic_navigation`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 破布纸 (`tech.rag_paper_making`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁建筑：专用商品作物种植园；开放通用职业阶层岗位；开放通用职业阶层岗位；可利用资源：种植园承载力；专用商品作物种植园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)；橡胶种植园 (`rubber_tree_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)；香料种植园 (`spice_plants_collector`)

#### 结构化内容效果

- **专用商品作物种植园**（`building`）：`building.method_specialty_commodity_plantation` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **香料**（`good`）：`good.spices` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **橡胶种植园**（`building`）：`building.rubber_tree_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 专用商品作物种植园：`country.output.building.method_specialty_commodity_plantation_factor`：+25%

#### 直接后继（硬前置关系）

- 工资契约 (`tech.wage_contracts`)

#### 同路线后继

- 工资契约 (`tech.wage_contracts`)

#### 应用交汇目标

- 工资契约 (`tech.wage_contracts`)
- 商业农庄 (`tech.commercial_estates`)

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
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 全部路线 | 贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：远洋渔场；开放通用职业阶层岗位；开放通用职业阶层岗位；远洋渔场产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 远洋渔场 (`method_marine_fish_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **远洋渔场**（`building`）：`building.method_marine_fish_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **鱼类**（`good`）：`good.fish` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 远洋渔场：`country.output.building.method_marine_fish_collector_r4_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 罐藏 (`tech.canning`)

#### 应用交汇目标

- 罐藏 (`tech.canning`)

#### 作为候选参与的里程碑

无

### 农艺交换 (`tech.agronomic_exchange`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agronomic_exchange` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 庄园谷物经营 (`tech.manorial_cereal_farming`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

公共营造产出 +12%

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

- 公共营造：`country.output.family.construction_methods_factor`：+12%

#### 直接后继（硬前置关系）

- 土壤实验 (`tech.soil_experimentation`)

#### 同路线后继

- 土壤实验 (`tech.soil_experimentation`)

#### 应用交汇目标

- 土壤实验 (`tech.soil_experimentation`)
- 火药武器 (`tech.gunpowder_weapons`)

#### 作为候选参与的里程碑

- 洲际网络 (`tech.global_exchange`)

### 作物移植适应 (`tech.crop_transplantation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_transplantation` |
| 时代 | 探索时代 (`exploration`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 108800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 帝国网络 (`tech.imperial_integration`)
- 集约轮作 (`tech.intensive_crop_rotation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

主粮加工产出 +12%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+12%

#### 直接后继（硬前置关系）

- 农业改良 (`tech.agricultural_improvement`)

#### 同路线后继

- 农业改良 (`tech.agricultural_improvement`)

#### 应用交汇目标

- 农业改良 (`tech.agricultural_improvement`)
- 火药武器 (`tech.gunpowder_weapons`)

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
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 商业租佃 (`tech.commercial_tenancy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「帝国网络」（tech.imperial\_integration）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

公共营造产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；橡胶种植园 (`rubber_tree_collector`)；香料种植园 (`spice_plants_collector`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

公共营造产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 天文导航 (`tech.celestial_navigation`)
- 远洋航海 (`tech.oceanic_navigation`)
- 海岸船厂 (`tech.coastal_shipyards`)
- 螺旋压印 (`tech.screw_press_printing`)
- 火药武器 (`tech.gunpowder_weapons`)
- 深井采矿 (`tech.deep_mining`)
- 商业农庄 (`tech.commercial_estates`)
- 作物驯化移植 (`tech.crop_acclimatization`)
- 跨区域植物学 (`tech.interregional_botany`)
- 井筒开掘 (`tech.shaft_sinking`)
- 矿井排水 (`tech.mine_drainage`)
- 特许商社 (`tech.chartered_companies`)
- 种植园庄园管理 (`tech.estate_plantation_management`)
- 商品作物管理 (`tech.commodity_crop_management`)
- 农艺交换 (`tech.agronomic_exchange`)
- 作物移植适应 (`tech.crop_transplantation`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

- 科学分类 (`tech.scientific_classification`)
- 系统育种 (`tech.crop_breeding`)
- 农业改良 (`tech.agricultural_improvement`)
- 实验科学 (`tech.experimental_science`)
- 标准化 (`tech.standardization`)
- 公共卫生 (`tech.public_health`)
- 水利工程 (`tech.hydraulic_engineering`)
- 地质勘探 (`tech.geological_prospecting`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)
- 学术社团 (`tech.learned_societies`)
- 土壤实验 (`tech.soil_experimentation`)
- 畜种改良 (`tech.livestock_breeding`)
- 工资契约 (`tech.wage_contracts`)
- 合作社组织 (`tech.cooperative_association`)
- 农业合作社 (`tech.agricultural_cooperatives`)
- 精密仪器 (`tech.precision_instruments`)
- 地产测绘 (`tech.property_cadastre`)
- 煤层地质 (`tech.coal_geology`)
- 蒸汽密封 (`tech.steam_sealing`)
- 罐藏 (`tech.canning`)

#### 同路线后继

无

#### 应用交汇目标

- 远洋航海 (`tech.oceanic_navigation`)

#### 作为候选参与的里程碑

无

<a id="era-6"></a>
## 启蒙时代

共 26 项科技，研究成本范围 216000-360000；时代里程碑：启蒙制度 (`tech.enlightenment_institutions`)。

### 科学分类 (`tech.scientific_classification`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scientific_classification` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 种植园庄园管理 (`tech.estate_plantation_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：洗涤剂；解锁建筑：洗涤剂厂；开放通用职业阶层岗位；开放通用职业阶层岗位；洗涤剂厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 洗涤剂 (`detergent`)
- **建筑 / 生产方式：** 洗涤剂厂 (`detergent_plant`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **洗涤剂**（`good`）：`good.detergent` → `production_access` `unlock` `1.0`；`existing_binding`
- **洗涤剂厂**（`building`）：`building.detergent_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **洗涤剂**（`good`）：`good.detergent` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化洗涤剂厂**（`building`）：`building.method_detergent_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 洗涤剂厂：`country.output.building.detergent_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 管理层级 (`tech.managerial_hierarchy`)

#### 同路线后继

- 管理层级 (`tech.managerial_hierarchy`)

#### 应用交汇目标

- 管理层级 (`tech.managerial_hierarchy`)
- 公共卫生 (`tech.public_health`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 系统育种 (`tech.crop_breeding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_breeding` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 作物驯化移植 (`tech.crop_acclimatization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「块茎样本接触」（contact.potato）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁建筑：改良亚麻庄园；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：精耕稻庄；改良亚麻庄园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良亚麻庄园 (`method_flax_collector_r5`)；精耕稻庄 (`method_rice_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良亚麻庄园**（`building`）：`building.method_flax_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精耕稻庄**（`building`）：`building.method_rice_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **稻米**（`good`）：`good.rice_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 改良亚麻庄园：`country.output.building.method_flax_collector_r5_factor`：+25%

#### 直接后继（硬前置关系）

- 肥料加工 (`tech.fertilizer_processing`)

#### 同路线后继

- 肥料加工 (`tech.fertilizer_processing`)

#### 应用交汇目标

- 肥料加工 (`tech.fertilizer_processing`)
- 地产测绘 (`tech.property_cadastre`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 农业改良 (`tech.agricultural_improvement`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agricultural_improvement` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 作物移植适应 (`tech.crop_transplantation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：改良小农场；开放通用职业阶层岗位；解锁建筑：工业榨油厂；开放通用职业阶层岗位；改良小农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良小农场 (`improved_smallholding`)；工业榨油厂 (`method_edible_oil_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良小农场**（`building`）：`building.improved_smallholding` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业榨油厂**（`building`）：`building.method_edible_oil_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **食用油**（`good`）：`good.edible_oil` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 改良小农场：`country.output.building.improved_smallholding_factor`：+25%

#### 直接后继（硬前置关系）

- 机械脱粒 (`tech.mechanical_threshing`)

#### 同路线后继

- 机械脱粒 (`tech.mechanical_threshing`)

#### 应用交汇目标

- 机械脱粒 (`tech.mechanical_threshing`)
- 水利工程 (`tech.hydraulic_engineering`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 精密工程 (`tech.precision_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_engineering` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 机械计时 (`tech.mechanical_timekeeping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「金属加工突破」（breakthrough.metalworking）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
    - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁物资：精密工具；解锁建筑：精密工具厂；开放通用职业阶层岗位；开放通用职业阶层岗位；精密工具厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 精密工具 (`precision_tools`)
- **建筑 / 生产方式：** 精密工具厂 (`method_precision_tool_workshop_r8`)；精密工具工坊 (`precision_tool_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 罐头工坊 (`canning_workshop`)

#### 结构化内容效果

- **精密工具**（`good`）：`good.precision_tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **精密工具厂**（`building`）：`building.method_precision_tool_workshop_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具工坊**（`building`）：`building.precision_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 精密工具厂：`country.output.building.method_precision_tool_workshop_r8_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 实验科学 (`tech.experimental_science`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.experimental_science` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +11%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 罐头工坊 (`canning_workshop`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 造纸业：`country.output.family.paper_making_factor`：+11%

#### 直接后继（硬前置关系）

- 概率与统计 (`tech.probability_statistics`)

#### 同路线后继

- 热力学 (`tech.thermodynamics`)

#### 应用交汇目标

- 热力学 (`tech.thermodynamics`)

#### 作为候选参与的里程碑

无

### 政治经济学 (`tech.political_economy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.political_economy` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 复式记账 (`tech.double_entry_bookkeeping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

公共营造产出 +10%

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

- 公共营造：`country.output.family.construction_methods_factor`：+10%

#### 直接后继（硬前置关系）

- 长期租约 (`tech.long_term_leases`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 概率与统计 (`tech.probability_statistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.probability_statistics` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 实验科学 (`tech.experimental_science`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

造纸业产出 +10%

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

- 造纸业：`country.output.family.paper_making_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「金属加工突破」（breakthrough.metalworking）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
    - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁建筑：电气化包装厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：电气印刷厂；电气化包装厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化包装厂 (`method_packaging_plant_r7`)；电气印刷厂 (`method_printed_materials_plant_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)；包装材料厂 (`packaging_plant`)

#### 结构化内容效果

- **电气化包装厂**（`building`）：`building.method_packaging_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气印刷厂**（`building`）：`building.method_printed_materials_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电气化包装厂：`country.output.building.method_packaging_plant_r7_factor`：+25%

#### 直接后继（硬前置关系）

- 机械工坊 (`tech.mechanical_workshops`)

#### 同路线后继

- 机床 (`tech.machine_tools`)

#### 应用交汇目标

- 机床 (`tech.machine_tools`)

#### 作为候选参与的里程碑

无

### 公共卫生 (`tech.public_health`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_health` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 火药武器 (`tech.gunpowder_weapons`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「硝石」（resource.saltpeter）
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

化学工业产出 +12%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+12%

#### 直接后继（硬前置关系）

- 工业化学 (`tech.industrial_chemistry`)

#### 同路线后继

- 工业化学 (`tech.industrial_chemistry`)

#### 应用交汇目标

- 工业化学 (`tech.industrial_chemistry`)
- 煤层地质 (`tech.coal_geology`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 气候 · 洪水 (\`route.climate.flood\`) |
| 全部路线 | 气候 · 洪水 (\`route.climate.flood\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 矿井排水 (`tech.mine_drainage`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁物资：水泥；解锁建筑：水泥厂；开放通用职业阶层岗位；开放通用职业阶层岗位；水泥厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 水泥 (`cement`)
- **建筑 / 生产方式：** 水泥厂 (`cement_plant`)；自动化水泥厂 (`method_cement_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 混凝土厂 (`concrete_plant`)；河流水力发电站 (`hydropower_station`)；流域治理中心 (`watershed_governance_center`)

#### 结构化内容效果

- **水泥**（`good`）：`good.cement` → `production_access` `unlock` `1.0`；`existing_binding`
- **水泥厂**（`building`）：`building.cement_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **水泥**（`good`）：`good.cement` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石灰**（`good`）：`good.lime` → `input_method_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化水泥厂**（`building`）：`building.method_cement_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 水泥厂：`country.output.building.cement_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 蒸汽抽水 (`tech.steam_pumping`)

#### 同路线后继

- 蒸汽抽水 (`tech.steam_pumping`)

#### 应用交汇目标

- 蒸汽抽水 (`tech.steam_pumping`)
- 地产测绘 (`tech.property_cadastre`)

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
| 锚点类型 | support |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 标准化 (`tech.standardization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「金属加工突破」（breakthrough.metalworking）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
    - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁物资：机器零件；解锁建筑：建筑构件厂；开放通用职业阶层岗位；开放通用职业阶层岗位；建筑构件厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 机器零件 (`machine_parts`)
- **建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)；改良家用织机 (`improved_domestic_loom`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机器零件**（`good`）：`good.machine_parts` → `production_access` `unlock` `1.0`；`existing_binding`
- **建筑构件厂**（`building`）：`building.construction_components_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **建筑构件**（`good`）：`good.construction_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **混凝土**（`good`）：`good.concrete` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **改良家用织机**（`building`）：`building.improved_domestic_loom` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 建筑构件厂：`country.output.building.construction_components_plant_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 井筒开掘 (`tech.shaft_sinking`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：锰矿石；解锁建筑：自动化铅矿；开放通用职业阶层岗位；开放通用职业阶层岗位；自动化铅矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锰矿石 (`manganese_ore`)
- **建筑 / 生产方式：** 自动化铅矿 (`method_lead_ore_collector_r9`)；硅砂矿 (`silica_sand_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)

#### 结构化内容效果

- **锰矿石**（`good`）：`good.manganese_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **自动化铅矿**（`building`）：`building.method_lead_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铅矿石**（`good`）：`good.lead_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硅砂矿**（`building`）：`building.silica_sand_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化铅矿：`country.output.building.method_lead_ore_collector_r9_factor`：+25%

#### 直接后继（硬前置关系）

- 焦炭冶炼 (`tech.coke_smelting`)

#### 同路线后继

- 焦炭冶炼 (`tech.coke_smelting`)

#### 应用交汇目标

- 焦炭冶炼 (`tech.coke_smelting`)
- 蒸汽密封 (`tech.steam_sealing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 深井采矿 (`tech.deep_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁物资：蒸汽机；解锁建筑：大气式蒸汽机工坊；开放通用职业阶层岗位；开放通用职业阶层岗位；大气式蒸汽机工坊产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 大气式蒸汽机工坊 (`atmospheric_engine_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`existing_binding`
- **大气式蒸汽机工坊**（`building`）：`building.atmospheric_engine_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 大气式蒸汽机工坊：`country.output.building.atmospheric_engine_workshop_factor`：+25%

#### 直接后继（硬前置关系）

- 工业采煤 (`tech.industrial_coal_mining`)

#### 同路线后继

- 工业采煤 (`tech.industrial_coal_mining`)

#### 应用交汇目标

- 工业采煤 (`tech.industrial_coal_mining`)
- 公共卫生 (`tech.public_health`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 学术社团 (`tech.learned_societies`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.learned_societies` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 制度 · 学术 (\`route.institution.academic\`) |
| 全部路线 | 制度 · 学术 (\`route.institution.academic\`)；制度 · 印刷 (\`route.institution.printing\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 螺旋压印 (`tech.screw_press_printing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：博学学会；开放通用职业阶层岗位；开放科技职业阶层岗位；解锁建筑：工业石灰岩矿场；博学学会产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 博学学会 (`learned_society`)；工业石灰岩矿场 (`method_limestone_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **博学学会**（`building`）：`building.learned_society` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **印刷品**（`good`）：`good.printed_materials` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业石灰岩矿场**（`building`）：`building.method_limestone_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **石灰岩**（`good`）：`good.limestone` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 博学学会：`country.output.building.learned_society_factor`：+25%

#### 直接后继（硬前置关系）

- 蒸汽锯木 (`tech.steam_sawmilling`)

#### 同路线后继

- 蒸汽锯木 (`tech.steam_sawmilling`)

#### 应用交汇目标

- 蒸汽锯木 (`tech.steam_sawmilling`)
- 精密仪器 (`tech.precision_instruments`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 土壤实验 (`tech.soil_experimentation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.soil_experimentation` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 农艺交换 (`tech.agronomic_exchange`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

可利用资源：磷矿石；造纸业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 磷矿石 (`phosphate_rock`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **磷矿石**（`resource`）：`resource.phosphate_rock` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 造纸业：`country.output.family.paper_making_factor`：+12%

#### 直接后继（硬前置关系）

- 机械化农业 (`tech.mechanized_agriculture`)

#### 同路线后继

- 机械化农业 (`tech.mechanized_agriculture`)

#### 应用交汇目标

- 机械化农业 (`tech.mechanized_agriculture`)
- 水利工程 (`tech.hydraulic_engineering`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 畜种改良 (`tech.livestock_breeding`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.livestock_breeding` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 商业农庄 (`tech.commercial_estates`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

畜牧业产出 +12%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+12%

#### 直接后继（硬前置关系）

- 劳工组织 (`tech.labor_organization`)

#### 同路线后继

- 劳工组织 (`tech.labor_organization`)

#### 应用交汇目标

- 劳工组织 (`tech.labor_organization`)
- 农业改良 (`tech.agricultural_improvement`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 工资契约 (`tech.wage_contracts`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.wage_contracts` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 商品作物管理 (`tech.commodity_crop_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

家具行会工坊产出 +25%；国家协同能力 +3%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 纺织机械 (`tech.textile_machinery`)

#### 同路线后继

- 纺织机械 (`tech.textile_machinery`)

#### 应用交汇目标

- 纺织机械 (`tech.textile_machinery`)
- 公共卫生 (`tech.public_health`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 长期租约 (`tech.long_term_leases`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.long_term_leases` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 280800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 政治经济学 (`tech.political_economy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

玉米庄园产出 +20%；国家协同能力 +3%

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

- 玉米庄园：`country.output.building.landed_estate_factor`：+20%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 合作社组织 (`tech.cooperative_association`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cooperative_association` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

家具行会工坊产出 +25%；国家协同能力 +3%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 工厂制 (`tech.factory_system`)

#### 应用交汇目标

- 工厂制 (`tech.factory_system`)

#### 作为候选参与的里程碑

无

### 农业合作社 (`tech.agricultural_cooperatives`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.agricultural_cooperatives` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 跨区域植物学 (`tech.interregional_botany`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

电气化集约农场产出 +25%；国家协同能力 +3%

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

- 电气化集约农场：`country.output.building.intensive_farm_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 机械收割 (`tech.mechanical_reaping`)

#### 同路线后继

- 机械收割 (`tech.mechanical_reaping`)

#### 应用交汇目标

- 机械收割 (`tech.mechanical_reaping`)
- 地产测绘 (`tech.property_cadastre`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 精密仪器 (`tech.precision_instruments`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_instruments` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 远洋航海 (`tech.oceanic_navigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

金属工具业产出 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+12%

#### 直接后继（硬前置关系）

- 铁路物流 (`tech.rail_logistics`)

#### 同路线后继

- 铁路物流 (`tech.rail_logistics`)

#### 应用交汇目标

- 铁路物流 (`tech.rail_logistics`)
- 煤层地质 (`tech.coal_geology`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 地产测绘 (`tech.property_cadastre`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.property_cadastre` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 海岸船厂 (`tech.coastal_shipyards`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「印刷突破」（breakthrough.printing）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

玉米庄园产出 +25%；国家协同能力 +3%

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

- 玉米庄园：`country.output.building.landed_estate_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 互换零件 (`tech.interchangeable_parts`)

#### 同路线后继

- 互换零件 (`tech.interchangeable_parts`)

#### 应用交汇目标

- 互换零件 (`tech.interchangeable_parts`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 煤层地质 (`tech.coal_geology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coal_geology` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | identification |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 特许商社 (`tech.chartered_companies`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：现代硝石矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：现代硫矿；现代硝石矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)；现代硫矿 (`method_sulfur_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **现代硝石矿**（`building`）：`building.method_saltpeter_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `input_method_access` `enable` `1.0`；`existing_binding`
- **现代硫矿**（`building`）：`building.method_sulfur_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 现代硝石矿：`country.output.building.method_saltpeter_collector_r8_factor`：+25%

#### 直接后继（硬前置关系）

- 蒸汽动力 (`tech.steam_power`)

#### 同路线后继

- 蒸汽动力 (`tech.steam_power`)

#### 应用交汇目标

- 蒸汽动力 (`tech.steam_power`)
- 精密仪器 (`tech.precision_instruments`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 蒸汽密封 (`tech.steam_sealing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_sealing` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)
- 天文导航 (`tech.celestial_navigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

可再生能源业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+12%

#### 直接后继（硬前置关系）

- 流水线组织 (`tech.assembly_line`)

#### 同路线后继

- 流水线组织 (`tech.assembly_line`)

#### 应用交汇目标

- 流水线组织 (`tech.assembly_line`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)

#### 作为候选参与的里程碑

- 启蒙制度 (`tech.enlightenment_institutions`)

### 罐藏 (`tech.canning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.canning` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 216000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 储藏 (\`route.institution.storage\`) |
| 全部路线 | 制度 · 储藏 (\`route.institution.storage\`)；工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | craft |

#### 前置科技（决定研发资格）

- 洲际网络 (`tech.global_exchange`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「洲际网络」（tech.global\_exchange）
  - 满足其一：
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：鱼罐头；解锁建筑：鱼类罐头厂；开放通用职业阶层岗位；开放通用职业阶层岗位；鱼类罐头厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 鱼罐头 (`canned_fish`)
- **建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)；罐头工坊 (`canning_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **鱼罐头**（`good`）：`good.canned_fish` → `production_access` `unlock` `1.0`；`existing_binding`
- **鱼类罐头厂**（`building`）：`building.canned_fish_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **鱼罐头**（`good`）：`good.canned_fish` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **鱼类**（`good`）：`good.fish` → `input_method_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `input_method_access` `enable` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **罐头工坊**（`building`）：`building.canning_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 鱼类罐头厂：`country.output.building.canned_fish_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 工业组织 (`tech.industrial_organization`)

#### 应用交汇目标

- 工业组织 (`tech.industrial_organization`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

造纸业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 科学分类 (`tech.scientific_classification`)
- 系统育种 (`tech.crop_breeding`)
- 农业改良 (`tech.agricultural_improvement`)
- 公共卫生 (`tech.public_health`)
- 水利工程 (`tech.hydraulic_engineering`)
- 地质勘探 (`tech.geological_prospecting`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)
- 学术社团 (`tech.learned_societies`)
- 土壤实验 (`tech.soil_experimentation`)
- 畜种改良 (`tech.livestock_breeding`)
- 工资契约 (`tech.wage_contracts`)
- 农业合作社 (`tech.agricultural_cooperatives`)
- 精密仪器 (`tech.precision_instruments`)
- 地产测绘 (`tech.property_cadastre`)
- 煤层地质 (`tech.coal_geology`)
- 蒸汽密封 (`tech.steam_sealing`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 造纸业：`country.output.family.paper_making_factor`：+10%

#### 直接后继（硬前置关系）

- 工业采煤 (`tech.industrial_coal_mining`)
- 焦炭冶炼 (`tech.coke_smelting`)
- 热力学 (`tech.thermodynamics`)
- 蒸汽动力 (`tech.steam_power`)
- 机械化农业 (`tech.mechanized_agriculture`)
- 工业组织 (`tech.industrial_organization`)
- 蒸汽抽水 (`tech.steam_pumping`)
- 纺织机械 (`tech.textile_machinery`)
- 机床 (`tech.machine_tools`)
- 铁路物流 (`tech.rail_logistics`)
- 工业化学 (`tech.industrial_chemistry`)
- 肥料加工 (`tech.fertilizer_processing`)
- 劳工组织 (`tech.labor_organization`)
- 机械收割 (`tech.mechanical_reaping`)
- 机械脱粒 (`tech.mechanical_threshing`)
- 工厂制 (`tech.factory_system`)
- 管理层级 (`tech.managerial_hierarchy`)
- 互换零件 (`tech.interchangeable_parts`)
- 流水线组织 (`tech.assembly_line`)
- 蒸汽锯木 (`tech.steam_sawmilling`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-7"></a>
## 蒸汽时代

共 25 项科技，研究成本范围 480000-800000；时代里程碑：工业化 (`tech.industrialization`)。

### 工业采煤 (`tech.industrial_coal_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_coal_mining` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：煤炭；铁矿业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 煤炭 (`coal`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤炭**（`good`）：`good.coal` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁矿业：`country.output.family.iron_extraction_factor`：+12%

#### 直接后继（硬前置关系）

- 公司矿山 (`tech.corporate_mining`)
- 石油钻探 (`tech.petroleum_drilling`)

#### 同路线后继

- 石油钻探 (`tech.petroleum_drilling`)

#### 应用交汇目标

- 石油钻探 (`tech.petroleum_drilling`)
- 蒸汽动力 (`tech.steam_power`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 焦炭冶炼 (`tech.coke_smelting`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.coke_smelting` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 煤炭 (\`route.resource.coal\`) |
| 全部路线 | 资源 · 煤炭 (\`route.resource.coal\`)；资源 · 铁 (\`route.resource.iron\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 地质勘探 (`tech.geological_prospecting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：焦炭；解锁物资：钢材；解锁建筑：焦化厂；开放通用职业阶层岗位；焦化厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 焦炭 (`coke`)；钢材 (`steel`)
- **建筑 / 生产方式：** 焦化厂 (`coke_ovens`)；电弧炉炼钢厂 (`steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化焦化厂 (`method_coke_ovens_r9`)

#### 结构化内容效果

- **焦炭**（`good`）：`good.coke` → `production_access` `unlock` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`existing_binding`
- **焦化厂**（`building`）：`building.coke_ovens` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **焦炭**（`good`）：`good.coke` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电弧炉炼钢厂**（`building`）：`building.steel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 焦化厂：`country.output.building.coke_ovens_factor`：+25%

#### 直接后继（硬前置关系）

- 电磁感应 (`tech.electromagnetic_induction`)

#### 同路线后继

- 电磁感应 (`tech.electromagnetic_induction`)

#### 应用交汇目标

- 电磁感应 (`tech.electromagnetic_induction`)
- 互换零件 (`tech.interchangeable_parts`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 热力学 (`tech.thermodynamics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.thermodynamics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 能源 · 热能 (\`route.energy.thermal\`) |
| 全部路线 | 能源 · 热能 (\`route.energy.thermal\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

造纸业产出 +11%

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

- 造纸业：`country.output.family.paper_making_factor`：+11%

#### 直接后继（硬前置关系）

- 机械印刷 (`tech.mechanized_printing`)

#### 同路线后继

- 工业研究 (`tech.industrial_research`)

#### 应用交汇目标

- 工业研究 (`tech.industrial_research`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 煤炭 (\`route.resource.coal\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 煤层地质 (`tech.coal_geology`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
    - 已发现信号「蒸汽密封突破」（breakthrough.steam\_sealing）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：蒸汽机；解锁建筑：自动化蒸汽机厂；开放通用职业阶层岗位；开放通用职业阶层岗位；自动化蒸汽机厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 自动化蒸汽机厂 (`method_steam_engine_works_r9`)；蒸汽机工厂 (`steam_engine_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)；蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`existing_binding`
- **自动化蒸汽机厂**（`building`）：`building.method_steam_engine_works_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **焦炭**（`good`）：`good.coke` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机工厂**（`building`）：`building.steam_engine_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化蒸汽机厂：`country.output.building.method_steam_engine_works_r9_factor`：+25%

#### 直接后继（硬前置关系）

- 石油开采 (`tech.petroleum_extraction`)
- 内燃机 (`tech.internal_combustion`)

#### 同路线后继

- 内燃机 (`tech.internal_combustion`)

#### 应用交汇目标

- 内燃机 (`tech.internal_combustion`)
- 纺织机械 (`tech.textile_machinery`)

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
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 土壤实验 (`tech.soil_experimentation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

解锁物资：农业机械；解锁建筑：农业机械厂；开放通用职业阶层岗位；开放通用职业阶层岗位；农业机械厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 农业机械 (`agricultural_machinery`)
- **建筑 / 生产方式：** 农业机械厂 (`agricultural_machinery_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)；机械化棉花农场 (`method_cotton_collector_r6`)；机械化玉米农场 (`method_landed_estate_r6`)；机械化马铃薯农场 (`method_potato_collector_r6`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)

#### 结构化内容效果

- **农业机械**（`good`）：`good.agricultural_machinery` → `production_access` `unlock` `1.0`；`existing_binding`
- **农业机械厂**（`building`）：`building.agricultural_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 农业机械厂：`country.output.building.agricultural_machinery_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 合成肥料 (`tech.synthetic_fertilizer`)

#### 同路线后继

- 合成肥料 (`tech.synthetic_fertilizer`)

#### 应用交汇目标

- 合成肥料 (`tech.synthetic_fertilizer`)
- 工业采煤 (`tech.industrial_coal_mining`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 工业组织 (`tech.industrial_organization`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_organization` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：工业砖厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：工业石灰厂；工业砖厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业砖厂 (`method_bricks_plant_r6`)；工业石灰厂 (`method_lime_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 面包厂 (`bread_plant`)；鱼类罐头厂 (`canned_fish_plant`)；乳制品厂 (`dairy_products_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；工业榨油厂 (`method_edible_oil_plant_r6`)；工业石灰岩矿场 (`method_limestone_collector_r6`)；综合工学院 (`polytechnic_institute`)

#### 结构化内容效果

- **工业砖厂**（`building`）：`building.method_bricks_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **砖块**（`good`）：`good.bricks` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黏土**（`good`）：`good.clay` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业石灰厂**（`building`）：`building.method_lime_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **石灰**（`good`）：`good.lime` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石灰岩**（`good`）：`good.limestone` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 工业砖厂：`country.output.building.method_bricks_plant_r6_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 大规模生产 (`tech.mass_production`)

#### 应用交汇目标

- 大规模生产 (`tech.mass_production`)

#### 作为候选参与的里程碑

无

### 蒸汽抽水 (`tech.steam_pumping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_pumping` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | applied\_method |
| 布局路线 | branch.water\_wind |
| 主要路线 | 能源 · 蒸汽 (\`route.energy.steam\`) |
| 全部路线 | 能源 · 蒸汽 (\`route.energy.steam\`)；资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 水利工程 (`tech.hydraulic_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「流域治理突破」（breakthrough.watershed\_management）

#### 效果摘要

解锁建筑：蒸汽动力煤矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：蒸汽动力铁矿；蒸汽动力煤矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽动力煤矿 (`steam_coal_mine`)；蒸汽动力铁矿 (`steam_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽动力煤矿**（`building`）：`building.steam_coal_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蒸汽动力铁矿**（`building`）：`building.steam_iron_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **铁矿石**（`good`）：`good.iron_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 蒸汽动力煤矿：`country.output.building.steam_coal_mine_factor`：+25%

#### 直接后继（硬前置关系）

- 发电机 (`tech.electric_generation`)

#### 同路线后继

- 发电机 (`tech.electric_generation`)

#### 应用交汇目标

- 发电机 (`tech.electric_generation`)
- 流水线组织 (`tech.assembly_line`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 工资契约 (`tech.wage_contracts`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁建筑：制衣厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：蒸汽纺织厂；制衣厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制衣厂 (`clothing_plant`)；蒸汽纺织厂 (`textile_mill`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；改良家用织机 (`improved_domestic_loom`)；制革厂 (`leather_plant`)

#### 结构化内容效果

- **制衣厂**（`building`）：`building.clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **衣物**（`good`）：`good.clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽纺织厂**（`building`）：`building.textile_mill` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 制衣厂：`country.output.building.clothing_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 公司管理 (`tech.corporate_management`)

#### 同路线后继

- 公司管理 (`tech.corporate_management`)

#### 应用交汇目标

- 公司管理 (`tech.corporate_management`)
- 流水线组织 (`tech.assembly_line`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机床 (`tech.machine_tools`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.machine_tools` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽密封突破」（breakthrough.steam\_sealing）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁物资：金属工具；解锁建筑：机械零件厂；开放通用职业阶层岗位；开放通用职业阶层岗位；机械零件厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 金属工具 (`tools`)
- **建筑 / 生产方式：** 机械零件厂 (`machine_parts_plant`)；钢制工具厂 (`tools_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业机械厂 (`industrial_machinery_plant`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)

#### 结构化内容效果

- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **机械零件厂**（`building`）：`building.machine_parts_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **机器零件**（`good`）：`good.machine_parts` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **润滑剂**（`good`）：`good.lubricants` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢制工具厂**（`building`）：`building.tools_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 机械零件厂：`country.output.building.machine_parts_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 工业质量控制 (`tech.industrial_quality_control`)

#### 应用交汇目标

- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

无

### 铁路物流 (`tech.rail_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rail_logistics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 全部路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 精密仪器 (`tech.precision_instruments`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：铁路设备；解锁建筑：铁路设备厂；开放通用职业阶层岗位；开放通用职业阶层岗位；铁路设备厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铁路设备 (`railway_equipment`)
- **建筑 / 生产方式：** 铁路设备厂 (`railway_equipment_plant`)；铁路设备工场 (`steam_rail_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铁路设备**（`good`）：`good.railway_equipment` → `production_access` `unlock` `1.0`；`existing_binding`
- **铁路设备厂**（`building`）：`building.railway_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铁路设备**（`good`）：`good.railway_equipment` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铁路设备工场**（`building`）：`building.steam_rail_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铁路设备厂：`country.output.building.railway_equipment_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 电信 (`tech.telecommunications`)

#### 同路线后继

- 电信 (`tech.telecommunications`)

#### 应用交汇目标

- 电信 (`tech.telecommunications`)
- 流水线组织 (`tech.assembly_line`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 公共卫生 (`tech.public_health`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）
    - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：工业化学品；解锁建筑：玻璃厂；开放通用职业阶层岗位；开放通用职业阶层岗位；玻璃厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 工业化学品 (`industrial_chemicals`)
- **建筑 / 生产方式：** 玻璃厂 (`glass_plant`)；化学工场 (`industrial_chemicals_plant`)
- **自然资源：** 硫磺矿 (`sulfur`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 炸药厂 (`explosives_plant`)；工业制皂厂 (`method_soap_plant_r6`)；造纸厂 (`paper_plant`)

#### 结构化内容效果

- **工业化学品**（`good`）：`good.industrial_chemicals` → `production_access` `unlock` `1.0`；`existing_binding`
- **玻璃厂**（`building`）：`building.glass_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **化学工场**（`building`）：`building.industrial_chemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `input_method_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硫磺矿**（`resource`）：`resource.sulfur` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 玻璃厂：`country.output.building.glass_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 现代医学 (`tech.modern_medicine`)

#### 同路线后继

- 现代医学 (`tech.modern_medicine`)

#### 应用交汇目标

- 现代医学 (`tech.modern_medicine`)
- 纺织机械 (`tech.textile_machinery`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`)；资源 · 磷矿 (\`route.resource.phosphate\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 系统育种 (`tech.crop_breeding`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）
    - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：肥料；解锁物资：磷矿石；解锁建筑：磷矿；开放通用职业阶层岗位；磷矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥料 (`fertilizer`)；磷矿石 (`phosphate_rock`)
- **建筑 / 生产方式：** 磷矿 (`phosphate_rock_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **肥料**（`good`）：`good.fertilizer` → `production_access` `unlock` `1.0`；`existing_binding`
- **磷矿石**（`good`）：`good.phosphate_rock` → `production_access` `unlock` `1.0`；`existing_binding`
- **磷矿**（`building`）：`building.phosphate_rock_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **磷矿石**（`good`）：`good.phosphate_rock` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 磷矿：`country.output.building.phosphate_rock_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 冷链 (`tech.cold_chain`)

#### 同路线后继

- 冷链 (`tech.cold_chain`)

#### 应用交汇目标

- 冷链 (`tech.cold_chain`)
- 流水线组织 (`tech.assembly_line`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械印刷 (`tech.mechanized_printing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanized_printing` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 前置科技（决定研发资格）

- 热力学 (`tech.thermodynamics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

解锁建筑：造纸厂；开放通用职业阶层岗位；开放通用职业阶层岗位；造纸厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 造纸厂 (`paper_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **造纸厂**（`building`）：`building.paper_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **纸张**（`good`）：`good.paper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 造纸厂：`country.output.building.paper_plant_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 畜种改良 (`tech.livestock_breeding`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

家具行会工坊产出 +25%；国家协同能力 +3%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 现代畜牧 (`tech.modern_husbandry`)

#### 同路线后继

- 现代畜牧 (`tech.modern_husbandry`)

#### 应用交汇目标

- 现代畜牧 (`tech.modern_husbandry`)
- 铁路物流 (`tech.rail_logistics`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械收割 (`tech.mechanical_reaping`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_reaping` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 农业合作社 (`tech.agricultural_cooperatives`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「稻」（bio.rice）
    - 已发现信号「稻种样本接触」（contact.rice）
    - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：机械化农场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：机械化玉米农场；机械化农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)；机械化玉米农场 (`method_landed_estate_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化农场**（`building`）：`building.mechanized_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **机械化玉米农场**（`building`）：`building.method_landed_estate_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **玉米**（`good`）：`good.corn_grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 机械化农场：`country.output.building.mechanized_farm_factor`：+25%

#### 直接后继（硬前置关系）

- 电动机 (`tech.electric_motors`)

#### 同路线后继

- 电动机 (`tech.electric_motors`)

#### 应用交汇目标

- 电动机 (`tech.electric_motors`)
- 流水线组织 (`tech.assembly_line`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 机械脱粒 (`tech.mechanical_threshing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanical_threshing` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 农业改良 (`tech.agricultural_improvement`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：机械化棉花农场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：机械化马铃薯农场；机械化棉花农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化棉花农场 (`method_cotton_collector_r6`)；机械化马铃薯农场 (`method_potato_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化棉花农场**（`building`）：`building.method_cotton_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **机械化马铃薯农场**（`building`）：`building.method_potato_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **马铃薯**（`good`）：`good.potatoes` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 机械化棉花农场：`country.output.building.method_cotton_collector_r6_factor`：+25%

#### 直接后继（硬前置关系）

- 机动农业 (`tech.motorized_agriculture`)

#### 同路线后继

- 机动农业 (`tech.motorized_agriculture`)

#### 应用交汇目标

- 机动农业 (`tech.motorized_agriculture`)
- 工业采煤 (`tech.industrial_coal_mining`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 工厂制 (`tech.factory_system`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.factory_system` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 480000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁物资：工业机械；解锁建筑：工业机械厂；开放通用职业阶层岗位；开放通用职业阶层岗位；工业机械厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 工业机械 (`industrial_machinery`)
- **建筑 / 生产方式：** 工业机械厂 (`industrial_machinery_plant`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 造纸厂 (`paper_plant`)；主食加工厂 (`staple_food_plant`)

#### 结构化内容效果

- **工业机械**（`good`）：`good.industrial_machinery` → `production_access` `unlock` `1.0`；`existing_binding`
- **工业机械厂**（`building`）：`building.industrial_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **机器零件**（`good`）：`good.machine_parts` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **数字化工业机械厂**（`building`）：`building.method_industrial_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 工业机械厂：`country.output.building.industrial_machinery_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 工业统计 (`tech.industrial_statistics`)

#### 同路线后继

- 公共教育 (`tech.public_education`)

#### 应用交汇目标

- 公共教育 (`tech.public_education`)

#### 作为候选参与的里程碑

无

### 管理层级 (`tech.managerial_hierarchy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.managerial_hierarchy` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 科学分类 (`tech.scientific_classification`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：高级家具厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：家具厂；高级家具厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高级家具厂 (`fine_furniture_plant`)；家具厂 (`furniture_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **高级家具厂**（`building`）：`building.fine_furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **精美家具**（`good`）：`good.fine_furniture` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **家具厂**（`building`）：`building.furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **家具**（`good`）：`good.furniture` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 高级家具厂：`country.output.building.fine_furniture_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 机械制冷 (`tech.refrigeration`)

#### 同路线后继

- 机械制冷 (`tech.refrigeration`)

#### 应用交汇目标

- 机械制冷 (`tech.refrigeration`)
- 蒸汽动力 (`tech.steam_power`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 工业统计 (`tech.industrial_statistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_statistics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 工厂制 (`tech.factory_system`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

解锁建筑：珠宝厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：电气化造船厂；珠宝厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 珠宝厂 (`jewelry_plant`)；电气化造船厂 (`method_oceanic_shipyard_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **珠宝厂**（`building`）：`building.jewelry_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **珠宝**（`good`）：`good.jewelry` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **黄金**（`good`）：`good.gold` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气化造船厂**（`building`）：`building.method_oceanic_shipyard_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **木材**（`good`）：`good.lumber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 珠宝厂：`country.output.building.jewelry_plant_factor`：+20%

#### 直接后继（硬前置关系）

- 工人合作工场 (`tech.worker_cooperatives`)

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 全部路线 | 工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 地产测绘 (`tech.property_cadastre`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「黏土」（resource.clay）
    - 已发现信号「石料」（resource.stone）
    - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：制鞋厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：制革厂；制鞋厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；制革厂 (`leather_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **制鞋厂**（`building`）：`building.footwear_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **鞋履**（`good`）：`good.footwear` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **制革厂**（`building`）：`building.leather_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **生皮**（`good`）：`good.raw_hide` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 制鞋厂：`country.output.building.footwear_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 电气化 (`tech.electrification`)

#### 同路线后继

- 电气化 (`tech.electrification`)

#### 应用交汇目标

- 电气化 (`tech.electrification`)
- 蒸汽抽水 (`tech.steam_pumping`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 蒸汽密封 (`tech.steam_sealing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
    - 已发现信号「蒸汽密封突破」（breakthrough.steam\_sealing）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：家用电器；解锁建筑：家用电器厂；开放通用职业阶层岗位；开放通用职业阶层岗位；家用电器厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 家用电器 (`household_appliances`)
- **建筑 / 生产方式：** 家用电器厂 (`household_appliances_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 面包厂 (`bread_plant`)；乳制品厂 (`dairy_products_plant`)

#### 结构化内容效果

- **家用电器**（`good`）：`good.household_appliances` → `production_access` `unlock` `1.0`；`existing_binding`
- **家用电器厂**（`building`）：`building.household_appliances_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **家用电器**（`good`）：`good.household_appliances` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 家用电器厂：`country.output.building.household_appliances_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 电网 (`tech.electric_grid`)

#### 同路线后继

- 电网 (`tech.electric_grid`)

#### 应用交汇目标

- 电网 (`tech.electric_grid`)
- 蒸汽抽水 (`tech.steam_pumping`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 蒸汽锯木 (`tech.steam_sawmilling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.steam_sawmilling` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | applied\_method |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`)；能源 · 蒸汽 (\`route.energy.steam\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 启蒙制度 (`tech.enlightenment_institutions`)
- 学术社团 (`tech.learned_societies`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

精细木作产出 +12%

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

- 精细木作：`country.output.family.fine_furniture_making_factor`：+12%

#### 直接后继（硬前置关系）

- 电化学 (`tech.electrochemistry`)

#### 同路线后继

- 电化学 (`tech.electrochemistry`)

#### 应用交汇目标

- 电化学 (`tech.electrochemistry`)
- 工业化学 (`tech.industrial_chemistry`)

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

### 公司矿山 (`tech.corporate_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.corporate_mining` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 624000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`)；制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 工业采煤 (`tech.industrial_coal_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

铁矿业产出 +10%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 蒸汽动力 (`tech.steam_power`)

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 社群 (\`route.institution.community\`) |
| 全部路线 | 制度 · 社群 (\`route.institution.community\`)；制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 工业统计 (`tech.industrial_statistics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「启蒙制度」（tech.enlightenment\_institutions）
  - 满足其一：
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
    - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

家具行会工坊产出 +20%；国家协同能力 +3%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+20%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

珠宝业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 工业采煤 (`tech.industrial_coal_mining`)
- 焦炭冶炼 (`tech.coke_smelting`)
- 蒸汽动力 (`tech.steam_power`)
- 机械化农业 (`tech.mechanized_agriculture`)
- 蒸汽抽水 (`tech.steam_pumping`)
- 纺织机械 (`tech.textile_machinery`)
- 铁路物流 (`tech.rail_logistics`)
- 工业化学 (`tech.industrial_chemistry`)
- 肥料加工 (`tech.fertilizer_processing`)
- 劳工组织 (`tech.labor_organization`)
- 机械收割 (`tech.mechanical_reaping`)
- 机械脱粒 (`tech.mechanical_threshing`)
- 管理层级 (`tech.managerial_hierarchy`)
- 互换零件 (`tech.interchangeable_parts`)
- 流水线组织 (`tech.assembly_line`)
- 蒸汽锯木 (`tech.steam_sawmilling`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 珠宝业：`country.output.family.jewelry_making_factor`：+10%

#### 直接后继（硬前置关系）

- 合成肥料 (`tech.synthetic_fertilizer`)
- 电气化 (`tech.electrification`)
- 电化学 (`tech.electrochemistry`)
- 公共教育 (`tech.public_education`)
- 大规模生产 (`tech.mass_production`)
- 内燃机 (`tech.internal_combustion`)
- 电网 (`tech.electric_grid`)
- 冷链 (`tech.cold_chain`)
- 现代医学 (`tech.modern_medicine`)
- 电信 (`tech.telecommunications`)
- 电磁感应 (`tech.electromagnetic_induction`)
- 发电机 (`tech.electric_generation`)
- 电动机 (`tech.electric_motors`)
- 机动农业 (`tech.motorized_agriculture`)
- 现代畜牧 (`tech.modern_husbandry`)
- 公司管理 (`tech.corporate_management`)
- 工业研究 (`tech.industrial_research`)
- 石油钻探 (`tech.petroleum_drilling`)
- 工业质量控制 (`tech.industrial_quality_control`)
- 机械制冷 (`tech.refrigeration`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-8"></a>
## 电气时代

共 24 项科技，研究成本范围 1080000-1800000；时代里程碑：电气社会 (`tech.electrical_society`)。

### 合成肥料 (`tech.synthetic_fertilizer`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.synthetic_fertilizer` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 机械化农业 (`tech.mechanized_agriculture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「硫磺」（resource.sulfur）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）
    - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：肥料；解锁建筑：化肥厂；开放通用职业阶层岗位；开放通用职业阶层岗位；化肥厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥料 (`fertilizer`)
- **建筑 / 生产方式：** 化肥厂 (`fertilizer_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **肥料**（`good`）：`good.fertilizer` → `production_access` `unlock` `1.0`；`existing_binding`
- **化肥厂**（`building`）：`building.fertilizer_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **磷矿石**（`good`）：`good.phosphate_rock` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然气**（`good`）：`good.natural_gas` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 化肥厂：`country.output.building.fertilizer_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 工业农学 (`tech.industrial_agronomy`)

#### 同路线后继

- 工业农学 (`tech.industrial_agronomy`)

#### 应用交汇目标

- 工业农学 (`tech.industrial_agronomy`)
- 机械制冷 (`tech.refrigeration`)
- 大规模生产 (`tech.mass_production`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 互换零件 (`tech.interchangeable_parts`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：电气设备；解锁建筑：早期电气设备厂；开放通用职业阶层岗位；开放通用职业阶层岗位；早期电气设备厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电气设备 (`electrical_equipment`)
- **建筑 / 生产方式：** 早期电气设备厂 (`basic_electrical_equipment_works`)；电气设备厂 (`electrical_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电气设备**（`good`）：`good.electrical_equipment` → `production_access` `unlock` `1.0`；`existing_binding`
- **早期电气设备厂**（`building`）：`building.basic_electrical_equipment_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气设备厂**（`building`）：`building.electrical_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属线材**（`good`）：`good.wire` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 早期电气设备厂：`country.output.building.basic_electrical_equipment_works_factor`：+25%

#### 直接后继（硬前置关系）

- 塑料工程 (`tech.plastics_engineering`)

#### 同路线后继

- 塑料工程 (`tech.plastics_engineering`)

#### 应用交汇目标

- 塑料工程 (`tech.plastics_engineering`)
- 电网 (`tech.electric_grid`)
- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电化学 (`tech.electrochemistry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electrochemistry` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`)；制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 蒸汽锯木 (`tech.steam_sawmilling`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「木材」（resource.timber）
    - 已发现信号「森林」（landform.forest）
    - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁物资：锌；解锁建筑：电化工厂；开放通用职业阶层岗位；开放通用职业阶层岗位；电化工厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锌 (`zinc`)
- **建筑 / 生产方式：** 电化工厂 (`electrochemical_works`)；炼锌厂 (`zinc_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **锌**（`good`）：`good.zinc` → `production_access` `unlock` `1.0`；`existing_binding`
- **电化工厂**（`building`）：`building.electrochemical_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **食盐**（`good`）：`good.salt` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炼锌厂**（`building`）：`building.zinc_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锌**（`good`）：`good.zinc` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **锌矿石**（`good`）：`good.zinc_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电化工厂：`country.output.building.electrochemical_works_factor`：+25%

#### 直接后继（硬前置关系）

- 合成材料 (`tech.synthetic_materials`)

#### 同路线后继

- 合成材料 (`tech.synthetic_materials`)

#### 应用交汇目标

- 合成材料 (`tech.synthetic_materials`)
- 发电机 (`tech.electric_generation`)
- 工业研究 (`tech.industrial_research`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 公共教育 (`tech.public_education`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_education` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 教育 (\`route.institution.education\`) |
| 全部路线 | 制度 · 教育 (\`route.institution.education\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁建筑：工业研究实验室；开放通用职业阶层岗位；开放科技职业阶层岗位；开放通用职业阶层岗位；工业研究实验室产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业研究实验室 (`industrial_research_laboratory`)；综合工学院 (`polytechnic_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **工业研究实验室**（`building`）：`building.industrial_research_laboratory` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **综合工学院**（`building`）：`building.polytechnic_institute` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 工业研究实验室：`country.output.building.industrial_research_laboratory_factor`：+25%

#### 直接后继（硬前置关系）

- 无线电 (`tech.radio`)

#### 同路线后继

- 运筹学 (`tech.operations_research`)

#### 应用交汇目标

- 运筹学 (`tech.operations_research`)

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 全部路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 公共教育 (`tech.public_education`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：电子元件；解锁物资：无线电设备；解锁建筑：电子元件厂；开放通用职业阶层岗位；电子元件厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 电子元件 (`electronic_components`)；无线电设备 (`radio_equipment`)
- **建筑 / 生产方式：** 电子元件厂 (`electronic_components_plant`)；无线电设备厂 (`radio_equipment_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化无线电设备厂 (`method_radio_equipment_works_r10`)

#### 结构化内容效果

- **电子元件**（`good`）：`good.electronic_components` → `production_access` `unlock` `1.0`；`existing_binding`
- **无线电设备**（`good`）：`good.radio_equipment` → `production_access` `unlock` `1.0`；`existing_binding`
- **电子元件厂**（`building`）：`building.electronic_components_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锌**（`good`）：`good.zinc` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **无线电设备厂**（`building`）：`building.radio_equipment_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **无线电设备**（`good`）：`good.radio_equipment` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电子元件厂：`country.output.building.electronic_components_plant_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 大规模生产 (`tech.mass_production`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mass_production` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
    - 已发现信号「肥沃土壤」（resource.fertile\_soil）
    - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：酿造厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：主食加工厂；酿造厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 酿造厂 (`beverages_plant`)；主食加工厂 (`staple_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电力纺织厂 (`cloth_plant`)；混凝土厂 (`concrete_plant`)；高级成衣厂 (`fine_clothing_plant`)；高级家具厂 (`fine_furniture_plant`)；家具厂 (`furniture_plant`)；家用电器厂 (`household_appliances_plant`)；珠宝厂 (`jewelry_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；智能化汽车厂 (`method_automobiles_plant_r10`)；电气化造船厂 (`method_oceanic_shipyard_r7`)；电气化包装厂 (`method_packaging_plant_r7`)；电气印刷厂 (`method_printed_materials_plant_r7`)；工业制皂厂 (`method_soap_plant_r6`)；综合食品厂 (`processed_food_plant`)

#### 结构化内容效果

- **酿造厂**（`building`）：`building.beverages_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **酒饮**（`good`）：`good.beverages` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `input_method_access` `enable` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **主食加工厂**（`building`）：`building.staple_food_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **熟制主食**（`good`）：`good.prepared_staples` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 酿造厂：`country.output.building.beverages_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 工业生态 (`tech.industrial_ecology`)

#### 应用交汇目标

- 工业生态 (`tech.industrial_ecology`)

#### 作为候选参与的里程碑

无

### 石油开采 (`tech.petroleum_extraction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_extraction` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1404000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 蒸汽动力 (`tech.steam_power`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：原油；解锁建筑：油田；开放通用职业阶层岗位；开放通用职业阶层岗位；油田产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 原油 (`crude_oil`)
- **建筑 / 生产方式：** 油田 (`oil_collector`)
- **自然资源：** 石油 (`oil`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)

#### 结构化内容效果

- **原油**（`good`）：`good.crude_oil` → `production_access` `unlock` `1.0`；`existing_binding`
- **油田**（`building`）：`building.oil_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **原油**（`good`）：`good.crude_oil` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **石油**（`resource`）：`resource.oil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 油田：`country.output.building.oil_collector_factor`：+20%

#### 直接后继（硬前置关系）

- 石油炼制 (`tech.petroleum_refining`)

#### 同路线后继

无

#### 应用交汇目标

- 电网 (`tech.electric_grid`)
- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

无

### 石油炼制 (`tech.petroleum_refining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_refining` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1404000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 石油开采 (`tech.petroleum_extraction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：精炼燃料；解锁建筑：智能炼油厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能炼油厂产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 精炼燃料 (`refined_fuel`)
- **建筑 / 生产方式：** 智能炼油厂 (`method_refined_fuel_plant_r10`)；炼油厂 (`refined_fuel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **精炼燃料**（`good`）：`good.refined_fuel` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能炼油厂**（`building`）：`building.method_refined_fuel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **精炼燃料**（`good`）：`good.refined_fuel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原油**（`good`）：`good.crude_oil` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炼油厂**（`building`）：`building.refined_fuel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能炼油厂：`country.output.building.method_refined_fuel_plant_r10_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 电网 (`tech.electric_grid`)
- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

无

### 内燃机 (`tech.internal_combustion`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.internal_combustion` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 能源 · 内燃 (\`route.energy.combustion\`) |
| 全部路线 | 能源 · 内燃 (\`route.energy.combustion\`)；资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 蒸汽动力 (`tech.steam_power`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：汽车；解锁物资：发动机；解锁建筑：汽车厂；开放通用职业阶层岗位；汽车厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 汽车 (`automobiles`)；发动机 (`engines`)
- **建筑 / 生产方式：** 汽车厂 (`automobiles_plant`)；发动机厂 (`engines_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 燃气发电厂 (`gas_power_plant`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)

#### 结构化内容效果

- **汽车**（`good`）：`good.automobiles` → `production_access` `unlock` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `production_access` `unlock` `1.0`；`existing_binding`
- **汽车厂**（`building`）：`building.automobiles_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **汽车**（`good`）：`good.automobiles` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **发动机厂**（`building`）：`building.engines_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铝**（`good`）：`good.aluminum` → `input_method_access` `enable` `1.0`；`existing_binding`
- **机器零件**（`good`）：`good.machine_parts` → `input_method_access` `enable` `1.0`；`existing_binding`
- **润滑剂**（`good`）：`good.lubricants` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 汽车厂：`country.output.building.automobiles_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 石油化工 (`tech.petrochemical_industry`)

#### 同路线后继

- 石油化工 (`tech.petrochemical_industry`)

#### 应用交汇目标

- 石油化工 (`tech.petrochemical_industry`)
- 电网 (`tech.electric_grid`)
- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 电网 (`tech.electric_grid`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_grid` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 流水线组织 (`tech.assembly_line`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：绝缘电缆；解锁建筑：绝缘电缆厂；开放通用职业阶层岗位；开放通用职业阶层岗位；绝缘电缆厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 绝缘电缆 (`insulated_cable`)
- **建筑 / 生产方式：** 绝缘电缆厂 (`insulated_cable_plant`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 燃气发电厂 (`gas_power_plant`)；河流水力发电站 (`hydropower_station`)；自动化港口船舶中心 (`method_automated_port`)；燃油发电厂 (`oil_power_plant`)

#### 结构化内容效果

- **绝缘电缆**（`good`）：`good.insulated_cable` → `production_access` `unlock` `1.0`；`existing_binding`
- **绝缘电缆厂**（`building`）：`building.insulated_cable_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属线材**（`good`）：`good.wire` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化绝缘电缆厂**（`building`）：`building.method_insulated_cable_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 绝缘电缆厂：`country.output.building.insulated_cable_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 核裂变 (`tech.nuclear_fission`)
- 核能 (`tech.nuclear_energy`)

#### 同路线后继

- 核能 (`tech.nuclear_energy`)

#### 应用交汇目标

- 核能 (`tech.nuclear_energy`)
- 内燃机 (`tech.internal_combustion`)
- 公共教育 (`tech.public_education`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 冷链 (`tech.cold_chain`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.cold_chain` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 肥料加工 (`tech.fertilizer_processing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「马铃薯」（bio.potato）
    - 已发现信号「块茎样本接触」（contact.potato）
    - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁物资：加工食品；解锁建筑：乳制品厂；开放通用职业阶层岗位；开放通用职业阶层岗位；乳制品厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 加工食品 (`processed_food`)
- **建筑 / 生产方式：** 乳制品厂 (`dairy_products_plant`)；综合食品厂 (`processed_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **加工食品**（`good`）：`good.processed_food` → `production_access` `unlock` `1.0`；`existing_binding`
- **乳制品厂**（`building`）：`building.dairy_products_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **乳制品**（`good`）：`good.dairy_products` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `input_method_access` `enable` `1.0`；`existing_binding`
- **包装材料**（`good`）：`good.packaging` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **综合食品厂**（`building`）：`building.processed_food_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **加工食品**（`good`）：`good.processed_food` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **熟制主食**（`good`）：`good.prepared_staples` → `input_method_access` `enable` `1.0`；`existing_binding`
- **肉类**（`good`）：`good.meat` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `input_method_access` `enable` `1.0`；`existing_binding`
- **食用油**（`good`）：`good.edible_oil` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 乳制品厂：`country.output.building.dairy_products_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 国营企业 (`tech.state_enterprises`)

#### 同路线后继

- 国营企业 (`tech.state_enterprises`)

#### 应用交汇目标

- 国营企业 (`tech.state_enterprises`)
- 现代畜牧 (`tech.modern_husbandry`)
- 公共教育 (`tech.public_education`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 现代医学 (`tech.modern_medicine`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.modern_medicine` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 工业化学 (`tech.industrial_chemistry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）

#### 效果摘要

解锁物资：药品；解锁建筑：受控环境药材农场；开放通用职业阶层岗位；开放通用职业阶层岗位；受控环境药材农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 药品 (`pharmaceuticals`)
- **建筑 / 生产方式：** 受控环境药材农场 (`method_medicinal_herbs_collector_r7`)；制药厂 (`pharmaceuticals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药品**（`good`）：`good.pharmaceuticals` → `production_access` `unlock` `1.0`；`existing_binding`
- **受控环境药材农场**（`building`）：`building.method_medicinal_herbs_collector_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **药材**（`good`）：`good.medicinal_herbs` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **制药厂**（`building`）：`building.pharmaceuticals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **药品**（`good`）：`good.pharmaceuticals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **药材**（`good`）：`good.medicinal_herbs` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 受控环境药材农场：`country.output.building.method_medicinal_herbs_collector_r7_factor`：+25%

#### 直接后继（硬前置关系）

- 石化裂解 (`tech.petrochemical_cracking`)

#### 同路线后继

- 石化裂解 (`tech.petrochemical_cracking`)

#### 应用交汇目标

- 石化裂解 (`tech.petrochemical_cracking`)
- 电气化 (`tech.electrification`)
- 大规模生产 (`tech.mass_production`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 全部路线 | 制度 · 通信 (\`route.institution.communication\`)；制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 铁路物流 (`tech.rail_logistics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

无线电设备厂产出 +25%；国家协同能力 +3%

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

- 无线电设备厂：`country.output.building.radio_equipment_works_factor`：+25%
- `country.trade.capacity_factor`：+3%

#### 直接后继（硬前置关系）

- 全球物流 (`tech.global_logistics`)

#### 同路线后继

- 全球物流 (`tech.global_logistics`)

#### 应用交汇目标

- 全球物流 (`tech.global_logistics`)
- 机械制冷 (`tech.refrigeration`)
- 公共教育 (`tech.public_education`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 焦炭冶炼 (`tech.coke_smelting`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：金属线材；解锁建筑：智能化线材厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能化线材厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 金属线材 (`wire`)
- **建筑 / 生产方式：** 智能化线材厂 (`method_wire_plant_r10`)；线材厂 (`wire_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **金属线材**（`good`）：`good.wire` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能化线材厂**（`building`）：`building.method_wire_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **金属线材**（`good`）：`good.wire` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **线材厂**（`building`）：`building.wire_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化线材厂：`country.output.building.method_wire_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 先进冶金 (`tech.advanced_metallurgy`)
- 特种合金 (`tech.specialty_alloys`)

#### 同路线后继

- 特种合金 (`tech.specialty_alloys`)

#### 应用交汇目标

- 特种合金 (`tech.specialty_alloys`)
- 现代医学 (`tech.modern_medicine`)
- 工业研究 (`tech.industrial_research`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.water\_wind |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 蒸汽抽水 (`tech.steam_pumping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：电力；解锁建筑：燃煤发电厂；开放通用职业阶层岗位；开放通用职业阶层岗位；燃煤发电厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电力 (`electricity`)
- **建筑 / 生产方式：** 燃煤发电厂 (`electricity_plant`)；燃气发电厂 (`gas_power_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 河流水力发电站 (`hydropower_station`)

#### 结构化内容效果

- **电力**（`good`）：`good.electricity` → `production_access` `unlock` `1.0`；`existing_binding`
- **燃煤发电厂**（`building`）：`building.electricity_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **燃气发电厂**（`building`）：`building.gas_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **天然气**（`good`）：`good.natural_gas` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 燃煤发电厂：`country.output.building.electricity_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 深层地球物理 (`tech.deep_geophysics`)

#### 同路线后继

- 深层地球物理 (`tech.deep_geophysics`)

#### 应用交汇目标

- 深层地球物理 (`tech.deep_geophysics`)
- 电信 (`tech.telecommunications`)
- 工业研究 (`tech.industrial_research`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 机械收割 (`tech.mechanical_reaping`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：电动机；解锁建筑：电动机厂；开放通用职业阶层岗位；开放通用职业阶层岗位；电动机厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电动机 (`electric_motor`)
- **建筑 / 生产方式：** 电动机厂 (`electric_motor_plant`)；智能化电动机厂 (`method_electric_motor_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家用电器厂 (`household_appliances_plant`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)

#### 结构化内容效果

- **电动机**（`good`）：`good.electric_motor` → `production_access` `unlock` `1.0`；`existing_binding`
- **电动机厂**（`building`）：`building.electric_motor_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化电动机厂**（`building`）：`building.method_electric_motor_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电动机厂：`country.output.building.electric_motor_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 系统工程 (`tech.systems_engineering`)

#### 同路线后继

- 系统工程 (`tech.systems_engineering`)

#### 应用交汇目标

- 系统工程 (`tech.systems_engineering`)
- 电信 (`tech.telecommunications`)
- 工业研究 (`tech.industrial_research`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 全部路线 | 作物 · 机械化 (\`route.crop.mechanized\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 机械脱粒 (`tech.mechanical_threshing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「小麦」（bio.wheat）
    - 已发现信号「小麦样本接触」（contact.wheat）
    - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

解锁建筑：机械化橡胶种植园；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：机械化香料种植园；机械化橡胶种植园产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化橡胶种植园**（`building`）：`building.method_rubber_tree_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **机械化香料种植园**（`building`）：`building.method_spice_plants_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **香料**（`good`）：`good.spices` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 机械化橡胶种植园：`country.output.building.method_rubber_tree_collector_r6_factor`：+25%

#### 直接后继（硬前置关系）

- 集体农业 (`tech.collective_agriculture`)

#### 同路线后继

- 集体农业 (`tech.collective_agriculture`)

#### 应用交汇目标

- 集体农业 (`tech.collective_agriculture`)
- 公司管理 (`tech.corporate_management`)
- 工业质量控制 (`tech.industrial_quality_control`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | 无 |
| 效果配置 | livestock |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 劳工组织 (`tech.labor_organization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「牧场承载力」（resource.pasture）
    - 已发现信号「草原」（landform.grassland）
    - 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁建筑：智能牧业站；开放通用职业阶层岗位；开放通用职业阶层岗位；可利用资源：牧场承载力；智能牧业站产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能牧业站 (`method_smart_husbandry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能牧业站**（`building`）：`building.method_smart_husbandry` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **畜牧产品**（`good`）：`good.livestock_products` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **牧场承载力**（`resource`）：`resource.pasture` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能牧业站：`country.output.building.method_smart_husbandry_factor`：+25%

#### 直接后继（硬前置关系）

- 公司农业 (`tech.corporate_agribusiness`)

#### 同路线后继

- 公司农业 (`tech.corporate_agribusiness`)

#### 应用交汇目标

- 公司农业 (`tech.corporate_agribusiness`)
- 电气化 (`tech.electrification`)
- 大规模生产 (`tech.mass_production`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 纺织机械 (`tech.textile_machinery`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁建筑：电力纺织厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：高级成衣厂；电力纺织厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电力纺织厂 (`cloth_plant`)；高级成衣厂 (`fine_clothing_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电力纺织厂**（`building`）：`building.cloth_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **亚麻纤维**（`good`）：`good.flax_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **高级成衣厂**（`building`）：`building.fine_clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **华服**（`good`）：`good.fine_clothing` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电力纺织厂：`country.output.building.cloth_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)

#### 同路线后继

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)

#### 应用交汇目标

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)
- 电信 (`tech.telecommunications`)
- 大规模生产 (`tech.mass_production`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 工业研究 (`tech.industrial_research`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_research` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁物资：科学仪器；解锁建筑：智能仪器厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能仪器厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 科学仪器 (`scientific_instruments`)
- **建筑 / 生产方式：** 智能仪器厂 (`method_scientific_instrument_works_r10`)；科学仪器工坊 (`scientific_instrument_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 精密仪器厂 (`method_scientific_instrument_works_r8`)

#### 结构化内容效果

- **科学仪器**（`good`）：`good.scientific_instruments` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能仪器厂**（`building`）：`building.method_scientific_instrument_works_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科学仪器工坊**（`building`）：`building.scientific_instrument_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能仪器厂：`country.output.building.method_scientific_instrument_works_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 国家实验室 (`tech.national_laboratories`)

#### 应用交汇目标

- 国家实验室 (`tech.national_laboratories`)

#### 作为候选参与的里程碑

无

### 石油钻探 (`tech.petroleum_drilling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petroleum_drilling` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 工业采煤 (`tech.industrial_coal_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：蒸汽钻井场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：燃油发电厂；蒸汽钻井场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)；燃油发电厂 (`oil_power_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽钻井场**（`building`）：`building.early_oil_well` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **原油**（`good`）：`good.crude_oil` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **燃油发电厂**（`building`）：`building.oil_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **精炼燃料**（`good`）：`good.refined_fuel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 蒸汽钻井场：`country.output.building.early_oil_well_factor`：+25%

#### 直接后继（硬前置关系）

- 机械化采矿 (`tech.mechanized_mining`)

#### 同路线后继

- 机械化采矿 (`tech.mechanized_mining`)

#### 应用交汇目标

- 机械化采矿 (`tech.mechanized_mining`)
- 电信 (`tech.telecommunications`)
- 公共教育 (`tech.public_education`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

### 工业质量控制 (`tech.industrial_quality_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_quality_control` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1080000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁建筑：现代炸药厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：精密仪器厂；现代炸药厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)；精密仪器厂 (`method_scientific_instrument_works_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业屠宰场 (`mechanized_slaughterhouse`)；自动化水泥厂 (`method_cement_plant_r9`)；自动化焦化厂 (`method_coke_ovens_r9`)；工业榨油厂 (`method_edible_oil_plant_r6`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；自动化润滑油厂 (`method_lubricants_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；精密工具厂 (`method_precision_tool_workshop_r8`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)；综合食品厂 (`processed_food_plant`)；主食加工厂 (`staple_food_plant`)

#### 结构化内容效果

- **现代炸药厂**（`building`）：`building.method_explosives_plant_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密仪器厂**（`building`）：`building.method_scientific_instrument_works_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **玻璃**（`good`）：`good.glass` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 现代炸药厂：`country.output.building.method_explosives_plant_r8_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 电子控制 (`tech.electronic_control`)

#### 应用交汇目标

- 电子控制 (`tech.electronic_control`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 工业化 (`tech.industrialization`)
- 管理层级 (`tech.managerial_hierarchy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「工业化」（tech.industrialization）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

可再生能源业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 乳制品厂 (`dairy_products_plant`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+12%

#### 直接后继（硬前置关系）

- 公共卫生体系 (`tech.public_health_systems`)

#### 同路线后继

- 公共卫生体系 (`tech.public_health_systems`)

#### 应用交汇目标

- 公共卫生体系 (`tech.public_health_systems`)
- 公司管理 (`tech.corporate_management`)
- 工业质量控制 (`tech.industrial_quality_control`)

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

可再生能源业产出 +10%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 合成肥料 (`tech.synthetic_fertilizer`)
- 电气化 (`tech.electrification`)
- 电化学 (`tech.electrochemistry`)
- 内燃机 (`tech.internal_combustion`)
- 电网 (`tech.electric_grid`)
- 冷链 (`tech.cold_chain`)
- 现代医学 (`tech.modern_medicine`)
- 电信 (`tech.telecommunications`)
- 电磁感应 (`tech.electromagnetic_induction`)
- 发电机 (`tech.electric_generation`)
- 电动机 (`tech.electric_motors`)
- 机动农业 (`tech.motorized_agriculture`)
- 现代畜牧 (`tech.modern_husbandry`)
- 公司管理 (`tech.corporate_management`)
- 石油钻探 (`tech.petroleum_drilling`)
- 机械制冷 (`tech.refrigeration`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+10%

#### 直接后继（硬前置关系）

- 工业农学 (`tech.industrial_agronomy`)
- 国家实验室 (`tech.national_laboratories`)
- 深层地球物理 (`tech.deep_geophysics`)
- 运筹学 (`tech.operations_research`)
- 石油化工 (`tech.petrochemical_industry`)
- 合成材料 (`tech.synthetic_materials`)
- 机械化采矿 (`tech.mechanized_mining`)
- 公共卫生体系 (`tech.public_health_systems`)
- 核能 (`tech.nuclear_energy`)
- 电子控制 (`tech.electronic_control`)
- 全球物流 (`tech.global_logistics`)
- 特种合金 (`tech.specialty_alloys`)
- 石化裂解 (`tech.petrochemical_cracking`)
- 塑料工程 (`tech.plastics_engineering`)
- 公司农业 (`tech.corporate_agribusiness`)
- 集体农业 (`tech.collective_agriculture`)
- 国营企业 (`tech.state_enterprises`)
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)
- 工业生态 (`tech.industrial_ecology`)
- 系统工程 (`tech.systems_engineering`)

#### 同路线后继

无

#### 应用交汇目标

- 内燃机 (`tech.internal_combustion`)
- 公共教育 (`tech.public_education`)

#### 作为候选参与的里程碑

无

<a id="era-9"></a>
## 原子时代

共 24 项科技，研究成本范围 2400000-4000000；时代里程碑：原子现代化 (`tech.atomic_modernity`)。

### 工业农学 (`tech.industrial_agronomy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_agronomy` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 合成肥料 (`tech.synthetic_fertilizer`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

解锁建筑：电气化集约农场；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：自动化磷矿；电气化集约农场产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化集约农场 (`intensive_farm`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电气化集约农场**（`building`）：`building.intensive_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化磷矿**（`building`）：`building.method_phosphate_rock_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **磷矿石**（`good`）：`good.phosphate_rock` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电气化集约农场：`country.output.building.intensive_farm_factor`：+25%

#### 直接后继（硬前置关系）

- 精准农业 (`tech.precision_agriculture`)

#### 同路线后继

- 精准农业 (`tech.precision_agriculture`)

#### 应用交汇目标

- 精准农业 (`tech.precision_agriculture`)
- 石化裂解 (`tech.petrochemical_cracking`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 先进冶金 (`tech.advanced_metallurgy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.advanced_metallurgy` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 全部路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铅；解锁物资：钢材；解锁建筑：炼铜厂；开放通用职业阶层岗位；炼铜厂产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铅 (`lead`)；钢材 (`steel`)
- **建筑 / 生产方式：** 炼铜厂 (`copper_plant`)；炼锡厂 (`tin_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 炼铅厂 (`lead_plant`)；智能冶铝厂 (`method_aluminum_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)

#### 结构化内容效果

- **铅**（`good`）：`good.lead` → `production_access` `unlock` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`existing_binding`
- **炼铜厂**（`building`）：`building.copper_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜矿石**（`good`）：`good.copper_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炼锡厂**（`building`）：`building.tin_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **锡矿石**（`good`）：`good.tin_ore` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 炼铜厂：`country.output.building.copper_plant_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 机械化采矿 (`tech.mechanized_mining`)

#### 作为候选参与的里程碑

无

### 核裂变 (`tech.nuclear_fission`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.nuclear_fission` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 电网 (`tech.electric_grid`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：核燃料；解锁物资：反应堆部件；解锁建筑：核燃料厂；开放通用职业阶层岗位；核燃料厂产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 核燃料 (`nuclear_fuel`)；反应堆部件 (`reactor_components`)
- **建筑 / 生产方式：** 核燃料厂 (`nuclear_fuel_plant`)；核医学制药中心 (`nuclear_medicine_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **核燃料**（`good`）：`good.nuclear_fuel` → `production_access` `unlock` `1.0`；`existing_binding`
- **反应堆部件**（`good`）：`good.reactor_components` → `production_access` `unlock` `1.0`；`existing_binding`
- **核燃料厂**（`building`）：`building.nuclear_fuel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **核燃料**（`good`）：`good.nuclear_fuel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **核医学制药中心**（`building`）：`building.nuclear_medicine_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **药品**（`good`）：`good.pharmaceuticals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **核燃料**（`good`）：`good.nuclear_fuel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **反应堆部件**（`good`）：`good.reactor_components` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 核燃料厂：`country.output.building.nuclear_fuel_plant_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 特种合金 (`tech.specialty_alloys`)

#### 作为候选参与的里程碑

无

### 国家实验室 (`tech.national_laboratories`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.national_laboratories` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 全部路线 | 制度 · 实验室 (\`route.institution.laboratory\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：国家实验室；开放通用职业阶层岗位；开放科技职业阶层岗位；开放通用职业阶层岗位；国家实验室产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 国家实验室 (`national_laboratory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **国家实验室**（`building`）：`building.national_laboratory` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 国家实验室：`country.output.building.national_laboratory_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 数字计算 (`tech.digital_computing`)

#### 应用交汇目标

- 数字计算 (`tech.digital_computing`)

#### 作为候选参与的里程碑

无

### 深层地球物理 (`tech.deep_geophysics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.deep_geophysics` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 发电机 (`tech.electric_generation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「流域治理突破」（breakthrough.watershed\_management）

#### 效果摘要

解锁物资：铝土矿；解锁建筑：铝土矿；开放通用职业阶层岗位；开放通用职业阶层岗位；铝土矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝土矿 (`bauxite`)
- **建筑 / 生产方式：** 铝土矿 (`bauxite_collector`)；炼铅厂 (`lead_plant`)
- **自然资源：** 铝土矿 (`bauxite`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 天然气田 (`natural_gas_collector`)；战略矿山 (`rare_earth_collector`)

#### 结构化内容效果

- **铝土矿**（`good`）：`good.bauxite` → `production_access` `unlock` `1.0`；`existing_binding`
- **铝土矿**（`building`）：`building.bauxite_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铝土矿**（`good`）：`good.bauxite` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炼铅厂**（`building`）：`building.lead_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **铅**（`good`）：`good.lead` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铅矿石**（`good`）：`good.lead_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铝土矿**（`resource`）：`resource.bauxite` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 铝土矿：`country.output.building.bauxite_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 水文遥感 (`tech.hydrological_remote_sensing`)

#### 同路线后继

- 水文遥感 (`tech.hydrological_remote_sensing`)

#### 应用交汇目标

- 水文遥感 (`tech.hydrological_remote_sensing`)
- 系统工程 (`tech.systems_engineering`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 运筹学 (`tech.operations_research`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.operations_research` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

金属工具业产出 +11%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+11%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 知识经济 (`tech.knowledge_economy`)

#### 应用交汇目标

- 知识经济 (`tech.knowledge_economy`)

#### 作为候选参与的里程碑

无

### 石油化工 (`tech.petrochemical_industry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petrochemical_industry` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 内燃机 (`tech.internal_combustion`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「石油」（resource.oil）

#### 效果摘要

解锁物资：石化产品；解锁建筑：智能石油化工厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能石油化工厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 石化产品 (`petrochemicals`)
- **建筑 / 生产方式：** 智能石油化工厂 (`method_petrochemicals_plant_r10`)；石油化工厂 (`petrochemicals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)

#### 结构化内容效果

- **石化产品**（`good`）：`good.petrochemicals` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能石油化工厂**（`building`）：`building.method_petrochemicals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原油**（`good`）：`good.crude_oil` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然气**（`good`）：`good.natural_gas` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **石油化工厂**（`building`）：`building.petrochemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能石油化工厂：`country.output.building.method_petrochemicals_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 半导体制造 (`tech.semiconductor_manufacturing`)

#### 同路线后继

- 半导体制造 (`tech.semiconductor_manufacturing`)

#### 应用交汇目标

- 半导体制造 (`tech.semiconductor_manufacturing`)
- 石化裂解 (`tech.petrochemical_cracking`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 合成材料 (`tech.synthetic_materials`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.synthetic_materials` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电化学 (`tech.electrochemistry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：混凝土；解锁物资：合成橡胶；解锁建筑：混凝土厂；开放通用职业阶层岗位；混凝土厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 混凝土 (`concrete`)；合成橡胶 (`synthetic_rubber`)
- **建筑 / 生产方式：** 混凝土厂 (`concrete_plant`)；合成橡胶厂 (`synthetic_rubber_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)

#### 结构化内容效果

- **混凝土**（`good`）：`good.concrete` → `production_access` `unlock` `1.0`；`existing_binding`
- **合成橡胶**（`good`）：`good.synthetic_rubber` → `production_access` `unlock` `1.0`；`existing_binding`
- **混凝土厂**（`building`）：`building.concrete_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **混凝土**（`good`）：`good.concrete` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **水泥**（`good`）：`good.cement` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **合成橡胶厂**（`building`）：`building.synthetic_rubber_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **合成橡胶**（`good`）：`good.synthetic_rubber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 混凝土厂：`country.output.building.concrete_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 卫星观测 (`tech.satellite_observation`)

#### 同路线后继

- 卫星观测 (`tech.satellite_observation`)

#### 应用交汇目标

- 卫星观测 (`tech.satellite_observation`)
- 塑料工程 (`tech.plastics_engineering`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 石油钻探 (`tech.petroleum_drilling`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：锰矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能锰矿；锰矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 锰矿 (`manganese_ore_collector`)；智能锰矿 (`method_manganese_ore_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)；现代硫矿 (`method_sulfur_collector_r8`)

#### 结构化内容效果

- **锰矿**（`building`）：`building.manganese_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **锰矿石**（`good`）：`good.manganese_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能锰矿**（`building`）：`building.method_manganese_ore_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 锰矿：`country.output.building.manganese_ore_collector_factor`：+25%

#### 直接后继（硬前置关系）

- 传感器网络 (`tech.sensor_networks`)

#### 同路线后继

- 传感器网络 (`tech.sensor_networks`)

#### 应用交汇目标

- 传感器网络 (`tech.sensor_networks`)
- 特种合金 (`tech.specialty_alloys`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 全部路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 机械制冷 (`tech.refrigeration`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「香料作物」（bio.spice）
    - 已发现信号「橡胶树」（bio.rubber）
    - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

化学工业产出 +12%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+12%

#### 直接后继（硬前置关系）

- 数值天气预报 (`tech.numerical_weather_prediction`)

#### 同路线后继

- 数值天气预报 (`tech.numerical_weather_prediction`)

#### 应用交汇目标

- 数值天气预报 (`tech.numerical_weather_prediction`)
- 全球物流 (`tech.global_logistics`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电网 (`tech.electric_grid`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁建筑：核电站；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：核反应堆设备厂；核电站产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 核电站 (`nuclear_power_plant`)；核反应堆设备厂 (`reactor_component_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **核电站**（`building`）：`building.nuclear_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **核燃料**（`good`）：`good.nuclear_fuel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **反应堆部件**（`good`）：`good.reactor_components` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **核反应堆设备厂**（`building`）：`building.reactor_component_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **反应堆部件**（`good`）：`good.reactor_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 核电站：`country.output.building.nuclear_power_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 核燃料循环 (`tech.nuclear_fuel_cycle`)
- 信息论 (`tech.information_theory`)

#### 同路线后继

- 信息论 (`tech.information_theory`)

#### 应用交汇目标

- 信息论 (`tech.information_theory`)
- 特种合金 (`tech.specialty_alloys`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 电子控制 (`tech.electronic_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electronic_control` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：电池；解锁建筑：电池厂；开放通用职业阶层岗位；开放通用职业阶层岗位；电池厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 电池 (`batteries`)
- **建筑 / 生产方式：** 电池厂 (`batteries_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化润滑油厂 (`method_lubricants_plant_r9`)；精密工具厂 (`method_precision_tool_workshop_r8`)；精密仪器厂 (`method_scientific_instrument_works_r8`)

#### 结构化内容效果

- **电池**（`good`）：`good.batteries` → `production_access` `unlock` `1.0`；`existing_binding`
- **电池厂**（`building`）：`building.batteries_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铅**（`good`）：`good.lead` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电池厂：`country.output.building.batteries_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 数字控制 (`tech.digital_control`)

#### 应用交汇目标

- 数字控制 (`tech.digital_control`)

#### 作为候选参与的里程碑

无

### 全球物流 (`tech.global_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.global_logistics` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电信 (`tech.telecommunications`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

运输装备业产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化港口船舶中心 (`method_automated_port`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 运输装备业：`country.output.family.railway_equipment_making_factor`：+12%

#### 直接后继（硬前置关系）

- 自动化物流 (`tech.automated_logistics`)

#### 同路线后继

- 自动化物流 (`tech.automated_logistics`)

#### 应用交汇目标

- 自动化物流 (`tech.automated_logistics`)
- 合成材料 (`tech.synthetic_materials`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 特种合金 (`tech.specialty_alloys`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.specialty_alloys` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 全部路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电磁感应 (`tech.electromagnetic_induction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「铜矿」（resource.copper\_ore）
    - 已发现信号「锡矿」（resource.tin\_ore）
    - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铝；解锁物资：不锈钢；解锁建筑：电解铝厂；开放通用职业阶层岗位；电解铝厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铝 (`aluminum`)；不锈钢 (`stainless_steel`)
- **建筑 / 生产方式：** 电解铝厂 (`aluminum_plant`)；不锈钢厂 (`stainless_steel_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)

#### 结构化内容效果

- **铝**（`good`）：`good.aluminum` → `production_access` `unlock` `1.0`；`existing_binding`
- **不锈钢**（`good`）：`good.stainless_steel` → `production_access` `unlock` `1.0`；`existing_binding`
- **电解铝厂**（`building`）：`building.aluminum_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铝**（`good`）：`good.aluminum` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铝土矿**（`good`）：`good.bauxite` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **不锈钢厂**（`building`）：`building.stainless_steel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **不锈钢**（`good`）：`good.stainless_steel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锰矿石**（`good`）：`good.manganese_ore` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 电解铝厂：`country.output.building.aluminum_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)

#### 同路线后继

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)

#### 应用交汇目标

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)
- 机械化采矿 (`tech.mechanized_mining`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 石化裂解 (`tech.petrochemical_cracking`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petrochemical_cracking` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 现代医学 (`tech.modern_medicine`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「磷矿石」（resource.phosphate\_rock）

#### 效果摘要

解锁物资：天然气；解锁建筑：智能天然气田；开放通用职业阶层岗位；开放通用职业阶层岗位；智能天然气田产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 天然气 (`natural_gas`)
- **建筑 / 生产方式：** 智能天然气田 (`method_natural_gas_collector_r10`)；天然气田 (`natural_gas_collector`)
- **自然资源：** 天然气 (`natural_gas`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 燃气发电厂 (`gas_power_plant`)

#### 结构化内容效果

- **天然气**（`good`）：`good.natural_gas` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能天然气田**（`building`）：`building.method_natural_gas_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **天然气**（`good`）：`good.natural_gas` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然气田**（`building`）：`building.natural_gas_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **天然气**（`resource`）：`resource.natural_gas` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能天然气田：`country.output.building.method_natural_gas_collector_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 软件工程 (`tech.software_engineering`)

#### 同路线后继

- 软件工程 (`tech.software_engineering`)

#### 应用交汇目标

- 软件工程 (`tech.software_engineering`)
- 工业农学 (`tech.industrial_agronomy`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 塑料工程 (`tech.plastics_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.plastics_engineering` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 全部路线 | 材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电气化 (`tech.electrification`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：塑料；解锁建筑：智能化塑料厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能化塑料厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 塑料 (`plastics`)
- **建筑 / 生产方式：** 智能化塑料厂 (`method_plastics_plant_r10`)；塑料厂 (`plastics_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **塑料**（`good`）：`good.plastics` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能化塑料厂**（`building`）：`building.method_plastics_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料厂**（`building`）：`building.plastics_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化塑料厂：`country.output.building.method_plastics_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 地理信息系统 (`tech.geographic_information_systems`)

#### 同路线后继

- 地理信息系统 (`tech.geographic_information_systems`)

#### 应用交汇目标

- 地理信息系统 (`tech.geographic_information_systems`)
- 合成材料 (`tech.synthetic_materials`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 公司农业 (`tech.corporate_agribusiness`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.corporate_agribusiness` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 现代畜牧 (`tech.modern_husbandry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

精准农场产出 +25%；国家协同能力 +3%

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

- 精准农场：`country.output.building.precision_farm_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 生物信息学 (`tech.bioinformatics`)

#### 同路线后继

- 生物信息学 (`tech.bioinformatics`)

#### 应用交汇目标

- 生物信息学 (`tech.bioinformatics`)
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 集体农业 (`tech.collective_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.collective_agriculture` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`)；制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 机动农业 (`tech.motorized_agriculture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

机械化农场产出 +25%；国家协同能力 +3%

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

- 机械化农场：`country.output.building.mechanized_farm_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 作物遥感 (`tech.crop_remote_sensing`)

#### 同路线后继

- 作物遥感 (`tech.crop_remote_sensing`)

#### 应用交汇目标

- 作物遥感 (`tech.crop_remote_sensing`)
- 石化裂解 (`tech.petrochemical_cracking`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 冷链 (`tech.cold_chain`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
    - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

燃煤发电厂产出 +25%；国家协同能力 +3%

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

- 燃煤发电厂：`country.output.building.electricity_plant_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

- 生物技术 (`tech.biotechnology`)

#### 同路线后继

- 生物技术 (`tech.biotechnology`)

#### 应用交汇目标

- 生物技术 (`tech.biotechnology`)
- 石化裂解 (`tech.petrochemical_cracking`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 核燃料循环 (`tech.nuclear_fuel_cycle`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.nuclear_fuel_cycle` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 3120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | support |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 核能 (`tech.nuclear_energy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「石油」（resource.oil）
    - 已发现信号「天然气」（resource.natural\_gas）
    - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：智能化核燃料厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能化核燃料厂产出 +20%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化核燃料厂**（`building`）：`building.method_nuclear_fuel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **核燃料**（`good`）：`good.nuclear_fuel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化核燃料厂：`country.output.building.method_nuclear_fuel_plant_r10_factor`：+20%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 特种合金 (`tech.specialty_alloys`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 公司管理 (`tech.corporate_management`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「亚麻」（bio.flax）
    - 已发现信号「棉花」（bio.cotton）
    - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：合成纤维；解锁建筑：合成纤维厂；开放通用职业阶层岗位；开放通用职业阶层岗位；合成纤维厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 合成纤维 (`synthetic_fiber`)
- **建筑 / 生产方式：** 合成纤维厂 (`synthetic_fiber_plant`)；合成纤维织造厂 (`synthetic_textile_mill`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；合成纤维织造厂 (`synthetic_textile_mill`)

#### 结构化内容效果

- **合成纤维**（`good`）：`good.synthetic_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **合成纤维厂**（`building`）：`building.synthetic_fiber_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **合成纤维**（`good`）：`good.synthetic_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **合成纤维织造厂**（`building`）：`building.synthetic_textile_mill` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **布料**（`good`）：`good.cloth` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **合成纤维**（`good`）：`good.synthetic_fiber` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 合成纤维厂：`country.output.building.synthetic_fiber_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 网络计算 (`tech.networked_computing`)

#### 同路线后继

- 网络计算 (`tech.networked_computing`)

#### 应用交汇目标

- 网络计算 (`tech.networked_computing`)
- 公司农业 (`tech.corporate_agribusiness`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

### 工业生态 (`tech.industrial_ecology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_ecology` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：润滑剂；解锁建筑：润滑油厂；开放通用职业阶层岗位；开放通用职业阶层岗位；润滑油厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 润滑剂 (`lubricants`)
- **建筑 / 生产方式：** 润滑油厂 (`lubricants_plant`)；自动化润滑油厂 (`method_lubricants_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **润滑剂**（`good`）：`good.lubricants` → `production_access` `unlock` `1.0`；`existing_binding`
- **润滑油厂**（`building`）：`building.lubricants_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **润滑剂**（`good`）：`good.lubricants` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **原油**（`good`）：`good.crude_oil` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化润滑油厂**（`building`）：`building.method_lubricants_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 润滑油厂：`country.output.building.lubricants_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 平台协调 (`tech.platform_coordination`)

#### 应用交汇目标

- 平台协调 (`tech.platform_coordination`)

#### 作为候选参与的里程碑

无

### 系统工程 (`tech.systems_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.systems_engineering` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 电气社会 (`tech.electrical_society`)
- 电动机 (`tech.electric_motors`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「电气社会」（tech.electrical\_society）
  - 满足其一：
    - 已发现信号「电气化突破」（breakthrough.electrification）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：战略矿物材料；解锁物资：战略矿石；解锁建筑：智能战略金属冶炼厂；开放通用职业阶层岗位；智能战略金属冶炼厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 战略矿物材料 (`rare_earth_metals`)；战略矿石 (`rare_earth_ore`)
- **建筑 / 生产方式：** 智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；战略金属冶炼厂 (`rare_earth_metals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `production_access` `unlock` `1.0`；`existing_binding`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **智能战略金属冶炼厂**（`building`）：`building.method_rare_earth_metals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略金属冶炼厂**（`building`）：`building.rare_earth_metals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能战略金属冶炼厂：`country.output.building.method_rare_earth_metals_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 精准灌溉 (`tech.precision_irrigation`)

#### 同路线后继

- 精准灌溉 (`tech.precision_irrigation`)

#### 应用交汇目标

- 精准灌溉 (`tech.precision_irrigation`)
- 深层地球物理 (`tech.deep_geophysics`)

#### 作为候选参与的里程碑

- 原子现代化 (`tech.atomic_modernity`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

珠宝业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 工业农学 (`tech.industrial_agronomy`)
- 深层地球物理 (`tech.deep_geophysics`)
- 石油化工 (`tech.petrochemical_industry`)
- 合成材料 (`tech.synthetic_materials`)
- 机械化采矿 (`tech.mechanized_mining`)
- 公共卫生体系 (`tech.public_health_systems`)
- 核能 (`tech.nuclear_energy`)
- 全球物流 (`tech.global_logistics`)
- 特种合金 (`tech.specialty_alloys`)
- 石化裂解 (`tech.petrochemical_cracking`)
- 塑料工程 (`tech.plastics_engineering`)
- 公司农业 (`tech.corporate_agribusiness`)
- 集体农业 (`tech.collective_agriculture`)
- 国营企业 (`tech.state_enterprises`)
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)
- 系统工程 (`tech.systems_engineering`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 珠宝业：`country.output.family.jewelry_making_factor`：+10%

#### 直接后继（硬前置关系）

- 精准农业 (`tech.precision_agriculture`)
- 数字计算 (`tech.digital_computing`)
- 信息论 (`tech.information_theory`)
- 知识经济 (`tech.knowledge_economy`)
- 软件工程 (`tech.software_engineering`)
- 网络计算 (`tech.networked_computing`)
- 半导体制造 (`tech.semiconductor_manufacturing`)
- 卫星观测 (`tech.satellite_observation`)
- 自动化物流 (`tech.automated_logistics`)
- 生物技术 (`tech.biotechnology`)
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)
- 数值天气预报 (`tech.numerical_weather_prediction`)
- 数字控制 (`tech.digital_control`)
- 作物遥感 (`tech.crop_remote_sensing`)
- 水文遥感 (`tech.hydrological_remote_sensing`)
- 平台协调 (`tech.platform_coordination`)
- 精准灌溉 (`tech.precision_irrigation`)
- 地理信息系统 (`tech.geographic_information_systems`)
- 传感器网络 (`tech.sensor_networks`)
- 生物信息学 (`tech.bioinformatics`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-10"></a>
## 信息时代

共 23 项科技，研究成本范围 5400000-9000000；时代里程碑：信息社会 (`tech.information_society`)。

### 精准农业 (`tech.precision_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_agriculture` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 工业农学 (`tech.industrial_agronomy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「玉米」（bio.maize）
    - 已发现信号「玉米样本接触」（contact.maize）
    - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

解锁建筑：数字化农业机械厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：精准农场；数字化农业机械厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 数字化农业机械厂 (`method_agricultural_machinery_plant_r9`)；精准农场 (`precision_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)；专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

- **数字化农业机械厂**（`building`）：`building.method_agricultural_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **蒸汽机**（`good`）：`good.steam_engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精准农场**（`building`）：`building.precision_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 数字化农业机械厂：`country.output.building.method_agricultural_machinery_plant_r9_factor`：+25%

#### 直接后继（硬前置关系）

- 智能育种 (`tech.intelligent_breeding`)

#### 同路线后继

- 智能育种 (`tech.intelligent_breeding`)

#### 应用交汇目标

- 智能育种 (`tech.intelligent_breeding`)
- 水文遥感 (`tech.hydrological_remote_sensing`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数字计算 (`tech.digital_computing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.digital_computing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：计算机；解锁建筑：计算机厂；开放通用职业阶层岗位；开放通用职业阶层岗位；计算机厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 计算机 (`computers`)
- **建筑 / 生产方式：** 计算机厂 (`computers_plant`)；早期计算机工场 (`digital_computer_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 早期半导体厂 (`basic_semiconductor_fab`)

#### 结构化内容效果

- **计算机**（`good`）：`good.computers` → `production_access` `unlock` `1.0`；`existing_binding`
- **计算机厂**（`building`）：`building.computers_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **半导体**（`good`）：`good.semiconductors` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **早期计算机工场**（`building`）：`building.digital_computer_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 计算机厂：`country.output.building.computers_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 机器学习 (`tech.machine_learning`)

#### 应用交汇目标

- 机器学习 (`tech.machine_learning`)

#### 作为候选参与的里程碑

无

### 信息论 (`tech.information_theory`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.information_theory` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 核能 (`tech.nuclear_energy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

金属工具业产出 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+12%

#### 直接后继（硬前置关系）

- 智能电网 (`tech.smart_grid`)

#### 同路线后继

- 智能电网 (`tech.smart_grid`)

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)
- 传感器网络 (`tech.sensor_networks`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 知识经济 (`tech.knowledge_economy`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.knowledge_economy` |
| 时代 | 信息时代 (`information`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

金属工具业产出 +11%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+11%

#### 直接后继（硬前置关系）

- 开放科学网络 (`tech.open_science_networks`)

#### 同路线后继

- 人机共治 (`tech.human_machine_cogovernance`)

#### 应用交汇目标

- 人机共治 (`tech.human_machine_cogovernance`)

#### 作为候选参与的里程碑

无

### 软件工程 (`tech.software_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.software_engineering` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 石化裂解 (`tech.petrochemical_cracking`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：计算研究中心；开放通用职业阶层岗位；开放科技职业阶层岗位；开放通用职业阶层岗位；计算研究中心产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 计算研究中心 (`computing_research_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **计算研究中心**（`building`）：`building.computing_research_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **通信设备**（`good`）：`good.telecom_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 计算研究中心：`country.output.building.computing_research_center_factor`：+25%

#### 直接后继（硬前置关系）

- 神经网络 (`tech.neural_networks`)

#### 同路线后继

- 神经网络 (`tech.neural_networks`)

#### 应用交汇目标

- 神经网络 (`tech.neural_networks`)
- 半导体制造 (`tech.semiconductor_manufacturing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：通信设备；解锁建筑：通信设备厂；开放通用职业阶层岗位；开放通用职业阶层岗位；通信设备厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 通信设备 (`telecom_equipment`)
- **建筑 / 生产方式：** 通信设备厂 (`telecom_equipment_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **通信设备**（`good`）：`good.telecom_equipment` → `production_access` `unlock` `1.0`；`existing_binding`
- **通信设备厂**（`building`）：`building.telecom_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通信设备**（`good`）：`good.telecom_equipment` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **半导体**（`good`）：`good.semiconductors` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属线材**（`good`）：`good.wire` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 通信设备厂：`country.output.building.telecom_equipment_plant_factor`：+25%

#### 直接后继（硬前置关系）

- 算法管理 (`tech.algorithmic_management`)

#### 同路线后继

- 算法管理 (`tech.algorithmic_management`)

#### 应用交汇目标

- 算法管理 (`tech.algorithmic_management`)
- 软件工程 (`tech.software_engineering`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 稀土 (\`route.resource.rare\_earth\`) |
| 全部路线 | 资源 · 稀土 (\`route.resource.rare\_earth\`)；制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 石油化工 (`tech.petrochemical_industry`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁物资：先进芯片；解锁物资：半导体；解锁建筑：早期半导体厂；开放通用职业阶层岗位；早期半导体厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 先进芯片 (`advanced_chips`)；半导体 (`semiconductors`)
- **建筑 / 生产方式：** 早期半导体厂 (`basic_semiconductor_fab`)；半导体厂 (`semiconductors_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化电子元件厂 (`method_electronic_components_plant_r10`)

#### 结构化内容效果

- **先进芯片**（`good`）：`good.advanced_chips` → `production_access` `unlock` `1.0`；`existing_binding`
- **半导体**（`good`）：`good.semiconductors` → `production_access` `unlock` `1.0`；`existing_binding`
- **早期半导体厂**（`building`）：`building.basic_semiconductor_fab` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **半导体**（`good`）：`good.semiconductors` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硅砂**（`good`）：`good.silica_sand` → `input_method_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **半导体厂**（`building`）：`building.semiconductors_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 早期半导体厂：`country.output.building.basic_semiconductor_fab_factor`：+25%

#### 直接后继（硬前置关系）

- 分布式智能 (`tech.distributed_intelligence`)

#### 同路线后继

- 分布式智能 (`tech.distributed_intelligence`)

#### 应用交汇目标

- 分布式智能 (`tech.distributed_intelligence`)
- 自动化物流 (`tech.automated_logistics`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 卫星观测 (`tech.satellite_observation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.satellite_observation` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 合成材料 (`tech.synthetic_materials`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：森林遥感经营站；开放通用职业阶层岗位；开放通用职业阶层岗位；开放科技职业阶层岗位；森林遥感经营站产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)

#### 结构化内容效果

- **森林遥感经营站**（`building`）：`building.method_forest_remote_sensing` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木材**（`resource`）：`resource.timber` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 森林遥感经营站：`country.output.building.method_forest_remote_sensing_factor`：+25%

#### 直接后继（硬前置关系）

- 智能科学代理 (`tech.scientific_agents`)

#### 同路线后继

- 智能科学代理 (`tech.scientific_agents`)

#### 应用交汇目标

- 智能科学代理 (`tech.scientific_agents`)
- 自动化物流 (`tech.automated_logistics`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 全球物流 (`tech.global_logistics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：自动化港口船舶中心；开放通用职业阶层岗位；开放通用职业阶层岗位；自动化港口船舶中心产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化港口船舶中心 (`method_automated_port`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化港口船舶中心**（`building`）：`building.method_automated_port` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化港口船舶中心：`country.output.building.method_automated_port_factor`：+25%

#### 直接后继（硬前置关系）

- 自主物流 (`tech.autonomous_logistics`)

#### 同路线后继

- 自主物流 (`tech.autonomous_logistics`)

#### 应用交汇目标

- 自主物流 (`tech.autonomous_logistics`)
- 半导体制造 (`tech.semiconductor_manufacturing`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 国营企业 (`tech.state_enterprises`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：高地精准块茎农业；开放通用职业阶层岗位；开放通用职业阶层岗位；需要高海拔地块条件；高地精准块茎农业产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

- **高地精准块茎农业**（`building`）：`building.method_highland_precision_agriculture` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **马铃薯**（`good`）：`good.potatoes` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **高海拔**（`tile`）：`tile.elevation` → `specialized_building_placement` `enable` `1.0`；`existing_binding`
- **旱地承载力**（`resource`）：`resource.arable_land` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 高地精准块茎农业：`country.output.building.method_highland_precision_agriculture_factor`：+25%

#### 直接后继（硬前置关系）

- 计算生物学 (`tech.computational_biology`)

#### 同路线后继

- 计算生物学 (`tech.computational_biology`)

#### 应用交汇目标

- 计算生物学 (`tech.computational_biology`)
- 地理信息系统 (`tech.geographic_information_systems`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 矿物光谱遥感 (`tech.mineral_spectral_survey`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mineral_spectral_survey` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 特种合金 (`tech.specialty_alloys`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：自动化铝土矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：战略矿山；自动化铝土矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化铝土矿 (`method_bauxite_collector_r9`)；战略矿山 (`rare_earth_collector`)
- **自然资源：** 稀土 (`rare_earth`)；锰矿 (`manganese_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化铅矿 (`method_lead_ore_collector_r9`)；智能锰矿 (`method_manganese_ore_collector_r10`)；智能天然气田 (`method_natural_gas_collector_r10`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)；自动化锌矿 (`method_zinc_ore_collector_r9`)

#### 结构化内容效果

- **自动化铝土矿**（`building`）：`building.method_bauxite_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铝土矿**（`good`）：`good.bauxite` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿山**（`building`）：`building.rare_earth_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **稀土**（`resource`）：`resource.rare_earth` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锰矿**（`resource`）：`resource.manganese_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化铝土矿：`country.output.building.method_bauxite_collector_r9_factor`：+25%

#### 直接后继（硬前置关系）

- 自主采矿 (`tech.autonomous_mining`)

#### 同路线后继

- 自主采矿 (`tech.autonomous_mining`)

#### 应用交汇目标

- 自主采矿 (`tech.autonomous_mining`)
- 信息论 (`tech.information_theory`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 公共卫生体系 (`tech.public_health_systems`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

金属工具业产出 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+12%

#### 直接后继（硬前置关系）

- 知识合作社 (`tech.knowledge_cooperatives`)

#### 同路线后继

- 知识合作社 (`tech.knowledge_cooperatives`)

#### 应用交汇目标

- 知识合作社 (`tech.knowledge_cooperatives`)
- 软件工程 (`tech.software_engineering`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 数字控制 (`tech.digital_control`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.digital_control` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 5400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：自动化焦化厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：自动化机械零件厂；自动化焦化厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化焦化厂 (`method_coke_ovens_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；自动化港口船舶中心 (`method_automated_port`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化电池厂 (`method_batteries_plant_r10`)；自动化水泥厂 (`method_cement_plant_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化润滑油厂 (`method_lubricants_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)；智能化线材厂 (`method_wire_plant_r10`)；自动化炼锌厂 (`method_zinc_plant_r9`)

#### 结构化内容效果

- **自动化焦化厂**（`building`）：`building.method_coke_ovens_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **焦炭**（`good`）：`good.coke` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化机械零件厂**（`building`）：`building.method_machine_parts_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **机器零件**（`good`）：`good.machine_parts` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **润滑剂**（`good`）：`good.lubricants` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化焦化厂：`country.output.building.method_coke_ovens_r9_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 自主系统 (`tech.autonomous_systems`)

#### 应用交汇目标

- 自主系统 (`tech.autonomous_systems`)

#### 作为候选参与的里程碑

无

### 作物遥感 (`tech.crop_remote_sensing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.crop_remote_sensing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 集体农业 (`tech.collective_agriculture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

金属工具业产出 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+12%

#### 直接后继（硬前置关系）

- 气候建模 (`tech.climate_modeling`)

#### 同路线后继

- 气候建模 (`tech.climate_modeling`)

#### 应用交汇目标

- 气候建模 (`tech.climate_modeling`)
- 水文遥感 (`tech.hydrological_remote_sensing`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 水文遥感 (`tech.hydrological_remote_sensing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hydrological_remote_sensing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 深层地球物理 (`tech.deep_geophysics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：流域治理中心；开放通用职业阶层岗位；开放科技职业阶层岗位；开放通用职业阶层岗位；流域治理中心产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 流域治理中心 (`watershed_governance_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **流域治理中心**（`building`）：`building.watershed_governance_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 流域治理中心：`country.output.building.watershed_governance_center_factor`：+25%

#### 直接后继（硬前置关系）

- 算法治理 (`tech.algorithmic_governance`)

#### 同路线后继

- 算法治理 (`tech.algorithmic_governance`)

#### 应用交汇目标

- 算法治理 (`tech.algorithmic_governance`)
- 地理信息系统 (`tech.geographic_information_systems`)

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
| 锚点类型 | support |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 知识经济 (`tech.knowledge_economy`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：自动化炼铅厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：自动化炼锌厂；自动化炼铅厂产出 +20%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化炼铅厂 (`method_lead_plant_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化炼铅厂**（`building`）：`building.method_lead_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铅**（`good`）：`good.lead` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铅矿石**（`good`）：`good.lead_ore` → `input_method_access` `enable` `1.0`；`existing_binding`
- **煤炭**（`good`）：`good.coal` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化炼锌厂**（`building`）：`building.method_zinc_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锌**（`good`）：`good.zinc` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **锌矿石**（`good`）：`good.zinc_ore` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化炼铅厂：`country.output.building.method_lead_plant_r9_factor`：+20%

#### 直接后继（硬前置关系）

- 数字市场 (`tech.digital_marketplaces`)

#### 同路线后继

无

#### 应用交汇目标

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

计算研究中心产出 +25%；国家协同能力 +3%

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

- 计算研究中心：`country.output.building.computing_research_center_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

- 自动化农业 (`tech.automated_agriculture`)

#### 应用交汇目标

- 自动化农业 (`tech.automated_agriculture`)

#### 作为候选参与的里程碑

无

### 精准灌溉 (`tech.precision_irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.precision_irrigation` |
| 时代 | 信息时代 (`information`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 系统工程 (`tech.systems_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

运输装备业产出 +12%

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

- 运输装备业：`country.output.family.railway_equipment_making_factor`：+12%

#### 直接后继（硬前置关系）

- 自适应灌溉 (`tech.adaptive_irrigation`)

#### 同路线后继

- 自适应灌溉 (`tech.adaptive_irrigation`)

#### 应用交汇目标

- 自适应灌溉 (`tech.adaptive_irrigation`)
- 地理信息系统 (`tech.geographic_information_systems`)

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
| 网络角色 | backbone |
| 锚点类型 | support |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 前置科技（决定研发资格）

- 开放科学网络 (`tech.open_science_networks`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

计算机厂产出 +20%；国家协同能力 +3%

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

- 计算机厂：`country.output.building.computers_plant_factor`：+20%
- `country.trade.capacity_factor`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 塑料工程 (`tech.plastics_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：智能战略矿山；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：自动化锌矿；智能战略矿山产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能战略矿山 (`method_rare_earth_collector_r10`)；自动化锌矿 (`method_zinc_ore_collector_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)；高地精准块茎农业 (`method_highland_precision_agriculture`)；流域治理中心 (`watershed_governance_center`)

#### 结构化内容效果

- **智能战略矿山**（`building`）：`building.method_rare_earth_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **炸药**（`good`）：`good.explosives` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自动化锌矿**（`building`）：`building.method_zinc_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锌矿石**（`good`）：`good.zinc_ore` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能战略矿山：`country.output.building.method_rare_earth_collector_r10_factor`：+25%

#### 直接后继（硬前置关系）

- 机器人制造 (`tech.robotic_manufacturing`)

#### 同路线后继

- 机器人制造 (`tech.robotic_manufacturing`)

#### 应用交汇目标

- 机器人制造 (`tech.robotic_manufacturing`)
- 传感器网络 (`tech.sensor_networks`)

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 传感器网络 (`tech.sensor_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.sensor_networks` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 机械化采矿 (`tech.mechanized_mining`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：自动化混凝土厂；开放通用职业阶层岗位；开放通用职业阶层岗位；自动化混凝土厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化混凝土厂 (`method_concrete_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化水泥厂 (`method_cement_plant_r9`)；自动化焦化厂 (`method_coke_ovens_r9`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；智能牧业站 (`method_smart_husbandry`)

#### 结构化内容效果

- **自动化混凝土厂**（`building`）：`building.method_concrete_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **混凝土**（`good`）：`good.concrete` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **水泥**（`good`）：`good.cement` → `input_method_access` `enable` `1.0`；`existing_binding`
- **原石**（`good`）：`good.raw_stone` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化混凝土厂：`country.output.building.method_concrete_plant_r9_factor`：+25%

#### 直接后继（硬前置关系）

- 自主劳动协调 (`tech.autonomous_labor_coordination`)

#### 同路线后继

- 自主劳动协调 (`tech.autonomous_labor_coordination`)

#### 应用交汇目标

- 自主劳动协调 (`tech.autonomous_labor_coordination`)
- 软件工程 (`tech.software_engineering`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 原子现代化 (`tech.atomic_modernity`)
- 公司农业 (`tech.corporate_agribusiness`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「原子现代化」（tech.atomic\_modernity）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

计算研究中心产出 +25%；国家协同能力 +3%

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

- 计算研究中心：`country.output.building.computing_research_center_factor`：+25%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

- 人机协作 (`tech.human_machine_collaboration`)

#### 同路线后继

- 人机协作 (`tech.human_machine_collaboration`)

#### 应用交汇目标

- 人机协作 (`tech.human_machine_collaboration`)
- 作物遥感 (`tech.crop_remote_sensing`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

金属工具业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 精准农业 (`tech.precision_agriculture`)
- 信息论 (`tech.information_theory`)
- 软件工程 (`tech.software_engineering`)
- 网络计算 (`tech.networked_computing`)
- 半导体制造 (`tech.semiconductor_manufacturing`)
- 卫星观测 (`tech.satellite_observation`)
- 自动化物流 (`tech.automated_logistics`)
- 生物技术 (`tech.biotechnology`)
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)
- 数值天气预报 (`tech.numerical_weather_prediction`)
- 作物遥感 (`tech.crop_remote_sensing`)
- 水文遥感 (`tech.hydrological_remote_sensing`)
- 精准灌溉 (`tech.precision_irrigation`)
- 地理信息系统 (`tech.geographic_information_systems`)
- 传感器网络 (`tech.sensor_networks`)
- 生物信息学 (`tech.bioinformatics`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+10%

#### 直接后继（硬前置关系）

- 机器学习 (`tech.machine_learning`)
- 自动化农业 (`tech.automated_agriculture`)
- 神经网络 (`tech.neural_networks`)
- 人机协作 (`tech.human_machine_collaboration`)
- 自主系统 (`tech.autonomous_systems`)
- 机器人制造 (`tech.robotic_manufacturing`)
- 自主采矿 (`tech.autonomous_mining`)
- 计算生物学 (`tech.computational_biology`)
- 气候建模 (`tech.climate_modeling`)
- 智能电网 (`tech.smart_grid`)
- 算法治理 (`tech.algorithmic_governance`)
- 分布式智能 (`tech.distributed_intelligence`)
- 智能育种 (`tech.intelligent_breeding`)
- 自主物流 (`tech.autonomous_logistics`)
- 智能科学代理 (`tech.scientific_agents`)
- 人机共治 (`tech.human_machine_cogovernance`)
- 算法管理 (`tech.algorithmic_management`)
- 自适应灌溉 (`tech.adaptive_irrigation`)
- 知识合作社 (`tech.knowledge_cooperatives`)
- 自主劳动协调 (`tech.autonomous_labor_coordination`)

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

<a id="era-11"></a>
## 智能时代

共 21 项科技，研究成本范围 12000000-20000000；时代里程碑：认知自动化 (`tech.cognitive_automation`)。

### 机器学习 (`tech.machine_learning`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.machine_learning` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：高端芯片厂；开放通用职业阶层岗位；开放通用职业阶层岗位；开放科技职业阶层岗位；高端芯片厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；智能研究院 (`machine_intelligence_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)

#### 结构化内容效果

- **高端芯片厂**（`building`）：`building.advanced_chip_fab` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **先进芯片**（`good`）：`good.advanced_chips` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **半导体**（`good`）：`good.semiconductors` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能研究院**（`building`）：`building.machine_intelligence_institute` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **先进芯片**（`good`）：`good.advanced_chips` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 高端芯片厂：`country.output.building.advanced_chip_fab_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 自动化农业 (`tech.automated_agriculture`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.automated_agriculture` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 全部路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：自动化农场；开放通用职业阶层岗位；开放通用职业阶层岗位；自动化农场产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化农场 (`automated_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

- **自动化农场**（`building`）：`building.automated_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **混合谷物**（`good`）：`good.grain` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **蔬菜**（`good`）：`good.vegetables` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **肥料**（`good`）：`good.fertilizer` → `input_method_access` `enable` `1.0`；`existing_binding`
- **农业机械**（`good`）：`good.agricultural_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自动化农场：`country.output.building.automated_farm_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 神经网络 (`tech.neural_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.neural_networks` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 软件工程 (`tech.software_engineering`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

智能研究院产出 +25%；国家协同能力 +3%

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

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+25%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 算法管理 (`tech.algorithmic_management`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 生物信息学 (`tech.bioinformatics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁建筑：智能化家用电器厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能工具厂；智能化家用电器厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能工具厂 (`method_precision_tool_workshop_r10`)

#### 结构化内容效果

- **智能化家用电器厂**（`building`）：`building.method_household_appliances_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **家用电器**（`good`）：`good.household_appliances` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能工具厂**（`building`）：`building.method_precision_tool_workshop_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **科学仪器**（`good`）：`good.scientific_instruments` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化家用电器厂：`country.output.building.method_household_appliances_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 自主物流 (`tech.autonomous_logistics`)

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 自主系统 (`tech.autonomous_systems`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_systems` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 全部路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁物资：自主系统；解锁建筑：自主控制系统厂；开放通用职业阶层岗位；开放通用职业阶层岗位；自主控制系统厂产出 +25%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 自主系统 (`autonomous_systems`)
- **建筑 / 生产方式：** 自主控制系统厂 (`autonomous_systems_plant`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)；自主航运调度港 (`method_autonomous_shipping`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能牧业站 (`method_smart_husbandry`)；智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **自主系统**（`good`）：`good.autonomous_systems` → `production_access` `unlock` `1.0`；`existing_binding`
- **自主控制系统厂**（`building`）：`building.autonomous_systems_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **先进芯片**（`good`）：`good.advanced_chips` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电动机**（`good`）：`good.electric_motor` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `input_method_access` `enable` `1.0`；`existing_binding`
- **精密工具**（`good`）：`good.precision_tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化核反应堆设备厂**（`building`）：`building.method_reactor_component_works_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **反应堆部件**（`good`）：`good.reactor_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电气设备**（`good`）：`good.electrical_equipment` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自主控制系统厂：`country.output.building.autonomous_systems_plant_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 机器人制造 (`tech.robotic_manufacturing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.robotic_manufacturing` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 全部路线 | 人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 地理信息系统 (`tech.geographic_information_systems`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：智能化汽车厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能化发动机厂；智能化汽车厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化汽车厂 (`method_automobiles_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化电池厂 (`method_batteries_plant_r10`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)；智能化线材厂 (`method_wire_plant_r10`)

#### 结构化内容效果

- **智能化汽车厂**（`building`）：`building.method_automobiles_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **汽车**（`good`）：`good.automobiles` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `input_method_access` `enable` `1.0`；`existing_binding`
- **天然乳胶**（`good`）：`good.latex` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化发动机厂**（`building`）：`building.method_engines_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铝**（`good`）：`good.aluminum` → `input_method_access` `enable` `1.0`；`existing_binding`
- **机器零件**（`good`）：`good.machine_parts` → `input_method_access` `enable` `1.0`；`existing_binding`
- **润滑剂**（`good`）：`good.lubricants` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化汽车厂：`country.output.building.method_automobiles_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 算法治理 (`tech.algorithmic_governance`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.nonferrous\_metals |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「铁矿」（resource.iron\_ore）
    - 已发现信号「煤炭」（resource.coal）
    - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：智能硝石矿；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能硫矿；智能硝石矿产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能硝石矿 (`method_saltpeter_collector_r10`)；智能硫矿 (`method_sulfur_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能锰矿 (`method_manganese_ore_collector_r10`)；智能天然气田 (`method_natural_gas_collector_r10`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能硝石矿 (`method_saltpeter_collector_r10`)；智能硫矿 (`method_sulfur_collector_r10`)

#### 结构化内容效果

- **智能硝石矿**（`building`）：`building.method_saltpeter_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **硝石**（`good`）：`good.saltpeter` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能硫矿**（`building`）：`building.method_sulfur_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `output_recipe_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能硝石矿：`country.output.building.method_saltpeter_collector_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 机器人制造 (`tech.robotic_manufacturing`)

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 计算生物学 (`tech.computational_biology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.computational_biology` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 生物技术 (`tech.biotechnology`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

国家实验室产出 +25%；国家协同能力 +3%

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

- 国家实验室：`country.output.building.national_laboratory_factor`：+25%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 气候建模 (`tech.climate_modeling`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.climate_modeling` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 气候 · 建模 (\`route.climate.modeling\`) |
| 全部路线 | 气候 · 建模 (\`route.climate.modeling\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 作物遥感 (`tech.crop_remote_sensing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

国家实验室产出 +25%；国家协同能力 +3%

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

- 国家实验室：`country.output.building.national_laboratory_factor`：+25%
- `country.research.science_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 自主劳动协调 (`tech.autonomous_labor_coordination`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 信息论 (`tech.information_theory`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：智能化电池厂；开放通用职业阶层岗位；开放通用职业阶层岗位；智能化电池厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电池厂 (`method_batteries_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)；自主航运调度港 (`method_autonomous_shipping`)；智能化电池厂 (`method_batteries_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能牧业站 (`method_smart_husbandry`)；智能化线材厂 (`method_wire_plant_r10`)；智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **智能化电池厂**（`building`）：`building.method_batteries_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **电池**（`good`）：`good.batteries` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铅**（`good`）：`good.lead` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业化学品**（`good`）：`good.industrial_chemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化电池厂：`country.output.building.method_batteries_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 算法治理 (`tech.algorithmic_governance`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.water\_wind |
| 主要路线 | 制度 · 国家治理 (\`route.institution.state\`) |
| 全部路线 | 制度 · 国家治理 (\`route.institution.state\`)；人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 水文遥感 (`tech.hydrological_remote_sensing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁建筑：智能水网控制中心；开放通用职业阶层岗位；开放科技职业阶层岗位；开放通用职业阶层岗位；智能水网控制中心产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能水网控制中心 (`smart_water_network`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能水网控制中心**（`building`）：`building.smart_water_network` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **河流**（`tile`）：`tile.river` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能水网控制中心：`country.output.building.smart_water_network_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 半导体制造 (`tech.semiconductor_manufacturing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：智能化电子元件厂；开放通用职业阶层岗位；开放通用职业阶层岗位；开放科技职业阶层岗位；智能化电子元件厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)；智能仪器厂 (`method_scientific_instrument_works_r10`)

#### 结构化内容效果

- **智能化电子元件厂**（`building`）：`building.method_electronic_components_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铜**（`good`）：`good.copper` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锡**（`good`）：`good.tin` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锌**（`good`）：`good.zinc` → `input_method_access` `enable` `1.0`；`existing_binding`
- **塑料**（`good`）：`good.plastics` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化无线电设备厂**（`building`）：`building.method_radio_equipment_works_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **无线电设备**（`good`）：`good.radio_equipment` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **绝缘电缆**（`good`）：`good.insulated_cable` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电子元件**（`good`）：`good.electronic_components` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化电子元件厂：`country.output.building.method_electronic_components_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 算法管理 (`tech.algorithmic_management`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 全部路线 | 作物 · 生物技术 (\`route.crop.biotechnology\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 精准农业 (`tech.precision_agriculture`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

精准农场产出 +25%；国家协同能力 +3%

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

- 精准农场：`country.output.building.precision_farm_factor`：+25%
- `country.research.agriculture_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 自主劳动协调 (`tech.autonomous_labor_coordination`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 自动化物流 (`tech.automated_logistics`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「海岸」（landform.coast）
    - 已发现信号「海洋鱼类」（resource.marine\_fish）
    - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：自主航运调度港；开放通用职业阶层岗位；开放通用职业阶层岗位；开放科技职业阶层岗位；自主航运调度港产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自主航运调度港**（`building`）：`building.method_autonomous_shipping` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **远洋船舶**（`good`）：`good.oceanic_vessels` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **发动机**（`good`）：`good.engines` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自主航运调度港：`country.output.building.method_autonomous_shipping_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 智能科学代理 (`tech.scientific_agents`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.scientific_agents` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 全部路线 | 人工智能 · 机器学习 (\`route.ai.learning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 卫星观测 (`tech.satellite_observation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「稀土」（resource.rare\_earth）

#### 效果摘要

解锁建筑：自主林业经营站；开放通用职业阶层岗位；开放通用职业阶层岗位；开放科技职业阶层岗位；自主林业经营站产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能仪器厂 (`method_scientific_instrument_works_r10`)

#### 结构化内容效果

- **自主林业经营站**（`building`）：`building.method_autonomous_forestry` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **科技职业阶层**（`class`）：`class.technology` → `employment_access` `enable` `1.0`；`existing_binding`
- **原木**（`good`）：`good.logs` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **计算机**（`good`）：`good.computers` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **科技值**（`good`）：`good.technology_points` → `input_method_access` `enable` `1.0`；`existing_binding`
- **木材**（`resource`）：`resource.timber` → `specialized_building_placement` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 自主林业经营站：`country.output.building.method_autonomous_forestry_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 神经网络 (`tech.neural_networks`)

#### 作为候选参与的里程碑

- 认知自动化 (`tech.cognitive_automation`)

### 人机共治 (`tech.human_machine_cogovernance`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.human_machine_cogovernance` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 12000000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone\_anchor |
| 节点角色 | institution |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

运输装备业产出 +11%

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

- 运输装备业：`country.output.family.railway_equipment_making_factor`：+11%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无

### 算法管理 (`tech.algorithmic_management`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.algorithmic_management` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 时代关键 |
| 网络角色 | branch |
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 网络计算 (`tech.networked_computing`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁建筑：智能化合成纤维厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能化合成橡胶厂；智能化合成纤维厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)

#### 结构化内容效果

- **智能化合成纤维厂**（`building`）：`building.method_synthetic_fiber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **合成纤维**（`good`）：`good.synthetic_fiber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **石化产品**（`good`）：`good.petrochemicals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化合成橡胶厂**（`building`）：`building.method_synthetic_rubber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **合成橡胶**（`good`）：`good.synthetic_rubber` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **硫磺**（`good`）：`good.sulfur` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能化合成纤维厂：`country.output.building.method_synthetic_fiber_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | power\_scale |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 全部路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 精准灌溉 (`tech.precision_irrigation`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「河湖水系」（landform.freshwater\_access）
    - 已发现信号「河谷」（landform.river\_valley）
    - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

可再生能源业产出 +12%

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

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+12%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 智能电网 (`tech.smart_grid`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 数值天气预报 (`tech.numerical_weather_prediction`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

智能研究院产出 +25%；国家协同能力 +3%

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

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+25%
- `country.research.society_efficiency`：+3%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 分布式智能 (`tech.distributed_intelligence`)

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
| 锚点类型 | route\_anchor |
| 节点角色 | institution |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 前置科技（决定研发资格）

- 信息社会 (`tech.information_society`)
- 传感器网络 (`tech.sensor_networks`)

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已完成科技「信息社会」（tech.information\_society）
  - 满足其一：
    - 已发现信号「数字控制突破」（breakthrough.digital\_control）
    - 已发现信号「自动化突破」（breakthrough.automation）
    - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁建筑：智能冶铝厂；开放通用职业阶层岗位；开放通用职业阶层岗位；解锁建筑：智能化不锈钢厂；智能冶铝厂产出 +25%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能冶铝厂**（`building`）：`building.method_aluminum_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `ownership_access` `enable` `1.0`；`existing_binding`
- **通用职业阶层**（`class`）：`class.general` → `employment_access` `enable` `1.0`；`existing_binding`
- **铝**（`good`）：`good.aluminum` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **铝土矿**（`good`）：`good.bauxite` → `input_method_access` `enable` `1.0`；`existing_binding`
- **电力**（`good`）：`good.electricity` → `input_method_access` `enable` `1.0`；`existing_binding`
- **金属工具**（`good`）：`good.tools` → `input_method_access` `enable` `1.0`；`existing_binding`
- **工业机械**（`good`）：`good.industrial_machinery` → `input_method_access` `enable` `1.0`；`existing_binding`
- **自主系统**（`good`）：`good.autonomous_systems` → `input_method_access` `enable` `1.0`；`existing_binding`
- **智能化不锈钢厂**（`building`）：`building.method_stainless_steel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **不锈钢**（`good`）：`good.stainless_steel` → `output_recipe_access` `enable` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `input_method_access` `enable` `1.0`；`existing_binding`
- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `input_method_access` `enable` `1.0`；`existing_binding`
- **锰矿石**（`good`）：`good.manganese_ore` → `input_method_access` `enable` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 智能冶铝厂：`country.output.building.method_aluminum_plant_r10_factor`：+25%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

- 分布式智能 (`tech.distributed_intelligence`)

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

#### 前置科技（决定研发资格）

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

珠宝业产出 +10%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 16 项候选中的任意 5 项：
- 神经网络 (`tech.neural_networks`)
- 人机协作 (`tech.human_machine_collaboration`)
- 机器人制造 (`tech.robotic_manufacturing`)
- 自主采矿 (`tech.autonomous_mining`)
- 计算生物学 (`tech.computational_biology`)
- 气候建模 (`tech.climate_modeling`)
- 智能电网 (`tech.smart_grid`)
- 算法治理 (`tech.algorithmic_governance`)
- 分布式智能 (`tech.distributed_intelligence`)
- 智能育种 (`tech.intelligent_breeding`)
- 自主物流 (`tech.autonomous_logistics`)
- 智能科学代理 (`tech.scientific_agents`)
- 算法管理 (`tech.algorithmic_management`)
- 自适应灌溉 (`tech.adaptive_irrigation`)
- 知识合作社 (`tech.knowledge_cooperatives`)
- 自主劳动协调 (`tech.autonomous_labor_coordination`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 珠宝业：`country.output.family.jewelry_making_factor`：+10%

#### 直接后继（硬前置关系）

无

#### 同路线后继

无

#### 应用交汇目标

无

#### 作为候选参与的里程碑

无
