# 科技目录审计报告

> 自动生成文件，请勿手工编辑。权威来源为 `TechnologyCatalog`；内容解锁来自已编译的 `EconomyCatalog` 反向绑定。

## 总览

| 项目 | 数量 |
| --- | ---: |
| 科技 | 361 |
| 时代 | 11 |
| 领域 | 4 |
| 里程碑 | 11 |
| 硬前置边 | 544 |
| 应用交汇边 | 19 |
| 替代说明边 | 21 |
| 里程碑候选边 | 88 |

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

解锁物资：野味；解锁物资：生皮；解锁建筑：狩猎营地；可利用资源：野生动物

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
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 畜牧驯养 (`tech.animal_husbandry`)：狩猎提供畜群驯养、育种与畜产品处理能力中的操作与材料处理方法，畜牧驯养直接使用这一能力完成其工艺或组织设计

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

解锁物资：采集植物食物；解锁建筑：采集营地；可利用资源：肥沃土壤

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
- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 季节性采集 (`tech.seasonal_foraging`)：采集提供粮食处理、保存与农艺组织能力中的操作与材料处理方法，季节性采集直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「石料」（resource.stone）

#### 效果摘要

解锁物资：打制石器；解锁建筑：燧石采掘场；解锁建筑：改良燧石矿坑

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
- **改良燧石矿坑**（`building`）：`building.method_flint_quarry_r1` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 磨制石器 (`tech.ground_stone_tools`)：打制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，磨制石器直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 能源 · 火 (\`route.energy.fire\`) |
| 全部路线 | 能源 · 火 (\`route.energy.fire\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：公共火塘

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共火塘 (`communal_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 覆土木炭窑 (`charcoal_pit`)；砂金淘洗精炼棚 (`gold_washing_refinery`)；乳胶烟熏凝固棚 (`latex_smoking_shelter`)；传知者议事圈 (`lorekeeper_circle`)；露天陶器烧造 (`open_pottery_hearth`)；银矿火试炉 (`silver_fire_assay_hearth`)

#### 结构化内容效果

- **公共火塘**（`building`）：`building.communal_hearth` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 窑烧控制 (`tech.kiln_firing`)：火种控制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，窑烧控制直接使用这一能力完成其工艺或组织设计

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

- 采集 (`tech.gathering`)：采集提供粮食处理、保存与农艺组织能力中的操作与材料处理方法，季节性采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主粮加工产出 +18%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：石器打制工坊；解锁建筑：组织化伐木场；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石器打制工坊 (`knapping_workshop`)；组织化伐木场 (`method_timber_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 木槽溜洗场 (`primitive_gold_sluice`)；野生割胶营地 (`rubber_tapping_camp`)；木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **石器打制工坊**（`building`）：`building.knapping_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **组织化伐木场**（`building`）：`building.method_timber_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 共同体分工 (`tech.communal_specialization`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，共同体分工直接使用这一能力完成其工艺或组织设计
- 犁耕农业 (`tech.plough_agriculture`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，犁耕农业直接使用这一能力完成其工艺或组织设计
- 活字印刷 (`tech.movable_type_printing`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，活字印刷直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

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

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：药材；可利用资源：硝石；可利用资源：硅砂；科研机构产出 +25%；知识部门产出 +15%

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

- 科研机构：`country.output.family.research_institution_factor`：+25%
- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 口述传统 (`tech.oral_tradition`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，口述传统直接使用这一能力完成其工艺或组织设计
- 天文历法 (`tech.celestial_calendars`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，天文历法直接使用这一能力完成其工艺或组织设计
- 自然哲学 (`tech.natural_philosophy`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，自然哲学直接使用这一能力完成其工艺或组织设计

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

- 自然观察 (`tech.natural_observation`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，口述传统直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

解锁建筑：传知者议事圈

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 传知者议事圈 (`lorekeeper_circle`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **传知者议事圈**（`building`）：`building.lorekeeper_circle` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 季节历 (`tech.seasonal_calendar`)：口述传统提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，季节历直接使用这一能力完成其工艺或组织设计

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

金属工具业产出 +28%；能源部门产出 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+28%
- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 渔舟 (`tech.fishing_boats`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.fishing_boats` |
| 时代 | 石器时代 (`stone`) |
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

解锁建筑：帆船渔场；贸易速度 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 帆船渔场 (`method_marine_fish_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **帆船渔场**（`building`）：`building.method_marine_fish_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 留种选育 (`tech.seed_selection`)：种子与繁育观察提供粮食处理、保存与农艺组织能力中的成套生产流程，留种选育直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

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

可利用资源：黏土；黏土采掘产出 +18%

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

- 黏土采掘：`country.output.family.clay_extraction_factor`：+18%

#### 被以下科技作为硬前置

- 黏土调制 (`tech.clay_preparation`)：黏土辨识提供土石、陶瓷、玻璃和工程构件制造能力中的识别与证据标准，黏土调制直接使用这一能力完成其工艺或组织设计

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
| 时代 | 石器时代 (`stone`) |
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

可利用资源：铜矿；铜业产出 +18%

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

- 铜业：`country.output.family.copper_extraction_factor`：+18%

#### 被以下科技作为硬前置

- 自然铜冷锤 (`tech.natural_copper_working`)：自然铜辨识提供矿物识别、有色冶炼与合金配制能力中的识别与证据标准，自然铜冷锤直接使用这一能力完成其工艺或组织设计

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
| 时代 | 石器时代 (`stone`) |
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

- 自然铜辨识 (`tech.natural_copper_identification`)：自然铜辨识提供矿物识别、有色冶炼与合金配制能力中的识别与证据标准，自然铜冷锤直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「铜矿」（resource.copper\_ore）

#### 效果摘要

解锁建筑：自然铜冷锤工坊；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自然铜冷锤工坊 (`natural_copper_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自然铜冷锤工坊**（`building`）：`building.natural_copper_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 铜退火 (`tech.copper_annealing`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，铜退火直接使用这一能力完成其工艺或组织设计
- 木炭坩埚炼铜 (`tech.copper_metallurgy`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，木炭坩埚炼铜直接使用这一能力完成其工艺或组织设计
- 铜锡配比与铸造 (`tech.bronze_casting`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，铜锡配比与铸造直接使用这一能力完成其工艺或组织设计

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
| 时代 | 石器时代 (`stone`) |
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

- 自然铜冷锤 (`tech.natural_copper_working`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，铜退火直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁建筑：露天青铜作坊

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露天青铜作坊 (`ore_bronzesmith_camp`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 铜矿 (`copper_ore_collector`)

#### 结构化内容效果

- **露天青铜作坊**（`building`）：`building.ore_bronzesmith_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 锡矿辨识 (`tech.tin_identification`)：铜退火提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，锡矿辨识直接使用这一能力完成其工艺或组织设计
- 铜矿焙烧 (`tech.copper_ore_roasting`)：铜退火提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，铜矿焙烧直接使用这一能力完成其工艺或组织设计

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
| 时代 | 石器时代 (`stone`) |
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

- 铜退火 (`tech.copper_annealing`)：铜退火提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，锡矿辨识直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「锡矿贸易接触」（contact.tin）

#### 效果摘要

解锁物资：锡矿石；可利用资源：锡矿；锡业产出 +18%

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

- 锡业：`country.output.family.tin_extraction_factor`：+18%

#### 被以下科技作为硬前置

无

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

- 狩猎 (`tech.hunting`)：狩猎提供畜群驯养、育种与畜产品处理能力中的操作与材料处理方法，畜牧驯养直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

畜牧业产出 +18%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+18%

#### 被以下科技作为硬前置

- 动物追踪 (`tech.animal_tracking`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，动物追踪直接使用这一能力完成其工艺或组织设计
- 畜力牵引 (`tech.animal_traction`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，畜力牵引直接使用这一能力完成其工艺或组织设计
- 现代畜牧 (`tech.modern_husbandry`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，现代畜牧直接使用这一能力完成其工艺或组织设计

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）

#### 效果摘要

解锁物资：布料；解锁建筑：家庭织造棚；制造部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 织造 (`tech.weaving`)：纤维捻制提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，织造直接使用这一能力完成其工艺或组织设计
- 织机织造 (`tech.loom_weaving`)：纤维捻制提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，织机织造直接使用这一能力完成其工艺或组织设计

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主粮加工产出 +25%；农业部门产出 +15%

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

- 主粮加工：`country.output.family.staple_preparation_factor`：+25%
- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

- 炉火保存 (`tech.hearth_preservation`)：食物储藏提供粮食处理、保存与农艺组织能力中的操作与材料处理方法，炉火保存直接使用这一能力完成其工艺或组织设计

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

- **早期商栈**（`building`）：`building.early_merchant_post` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 市场制度 (`tech.market_institutions`)：早期贸易提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，市场制度直接使用这一能力完成其工艺或组织设计

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

- 复合工具 (`tech.composite_tools`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，共同体分工直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：商栈；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商栈 (`merchant_post`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 传知者议事圈 (`lorekeeper_circle`)

#### 结构化内容效果

- **商栈**（`building`）：`building.merchant_post` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 家庭生产 (`tech.household_production`)：共同体分工提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，家庭生产直接使用这一能力完成其工艺或组织设计
- 永久聚落 (`tech.permanent_settlements`)：共同体分工提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，永久聚落直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

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

- 畜牧驯养 (`tech.animal_husbandry`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，动物追踪直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「野生动物」（resource.wild\_game）

#### 效果摘要

解锁建筑：商业狩猎与毛皮站；解锁建筑：小型陷阱线；可利用资源：野生动物

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 商业狩猎与毛皮站 (`method_stone_age_hunting_camp_r4`)；小型陷阱线 (`small_game_trapline`)
- **自然资源：** 野生动物 (`wild_game`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **商业狩猎与毛皮站**（`building`）：`building.method_stone_age_hunting_camp_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **小型陷阱线**（`building`）：`building.small_game_trapline` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **野生动物**（`resource`）：`resource.wild_game` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「淡水鱼群」（resource.freshwater\_fish）

#### 效果摘要

解锁物资：鱼类；解锁建筑：淡水捕鱼营地；可利用资源：淡水鱼群

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
- **淡水鱼群**（`resource`）：`resource.freshwater_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | fishing |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「海洋鱼类」（resource.marine\_fish）

#### 效果摘要

解锁物资：鱼类；解锁建筑：沿岸渔场；可利用资源：海洋鱼类

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
- **海洋鱼类**（`resource`）：`resource.marine_fish` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 打制石器 (`tech.stone_knapping`)：打制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，磨制石器直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：原石；解锁建筑：毛石整理场；解锁建筑：采石场；可利用资源：石料

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
- **采石场**（`building`）：`building.stone_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **石料**（`resource`）：`resource.stone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 灌溉 (`tech.irrigation`)：磨制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，灌溉直接使用这一能力完成其工艺或组织设计
- 梯田农业 (`tech.terrace_farming`)：磨制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，梯田农业直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 全部路线 | 材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：黏土；解锁建筑：土料挖掘坑；解锁建筑：原始黏土坑；可利用资源：黏土

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
- **原始黏土坑**（`building`）：`building.primitive_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **黏土**（`resource`）：`resource.clay` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 水田畦埂 (`tech.paddy_bunding`)：土建筑提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，水田畦埂直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 口述传统 (`tech.oral_tradition`)：口述传统提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，季节历直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「河谷」（landform.river\_valley）

#### 效果摘要

科研机构产出 +18%

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

- 科研机构：`country.output.family.research_institution_factor`：+18%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 定居知识 (`tech.settled_knowledge`)

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

- 食物储藏 (`tech.food_storage`)：食物储藏提供粮食处理、保存与农艺组织能力中的操作与材料处理方法，炉火保存直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：熟制主食；解锁建筑：主食厨房

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 共同体分工 (`tech.communal_specialization`)：共同体分工提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，家庭生产直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

家用织机产出 +35%

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

- 家用织机：`country.output.building.household_loom_factor`：+35%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

解锁物资：畜牧产品；解锁建筑：游牧营地；可利用资源：牧场承载力；热害损失 -8%

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
- **牧场承载力**（`resource`）：`resource.pasture` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 游牧放牧 (`tech.pastoralism`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，游牧放牧直接使用这一能力完成其工艺或组织设计
- 马匹驯化 (`tech.horse_domestication`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，马匹驯化直接使用这一能力完成其工艺或组织设计
- 乳品加工 (`tech.dairy_processing`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，乳品加工直接使用这一能力完成其工艺或组织设计
- 皮革鞣制 (`tech.hide_tanning`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，皮革鞣制直接使用这一能力完成其工艺或组织设计
- 毛用畜牧 (`tech.wool_husbandry`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，毛用畜牧直接使用这一能力完成其工艺或组织设计
- 屠宰分割 (`tech.meat_processing`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，屠宰分割直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 野生玉米采集 (`tech.wild_maize_collection`)：玉米辨识提供玉米栽培、选育与田间管理经验中的识别与证据标准，野生玉米采集直接使用这一能力完成其工艺或组织设计

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

- 玉米辨识 (`tech.maize_identification`)：玉米辨识提供玉米栽培、选育与田间管理经验中的识别与证据标准，野生玉米采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

解锁物资：玉米；解锁建筑：野生玉米采集地；旱灾损失 -8%

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

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 玉米留种 (`tech.maize_seed_saving`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米留种直接使用这一能力完成其工艺或组织设计
- 玉米选育 (`tech.maize_selection`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米选育直接使用这一能力完成其工艺或组织设计
- 玉米园圃 (`tech.maize_garden_horticulture`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米园圃直接使用这一能力完成其工艺或组织设计

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

- 野生玉米采集 (`tech.wild_maize_collection`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米留种直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 玉米繁育 (`tech.maize_propagation`)：玉米留种提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米繁育直接使用这一能力完成其工艺或组织设计

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

- 玉米留种 (`tech.maize_seed_saving`)：玉米留种提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米繁育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 野生谷穗采集 (`tech.wild_wheat_collection`)：小麦辨识提供谷物旱作、轮作与收获工艺中的识别与证据标准，野生谷穗采集直接使用这一能力完成其工艺或组织设计

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

- 小麦辨识 (`tech.wheat_identification`)：小麦辨识提供谷物旱作、轮作与收获工艺中的识别与证据标准，野生谷穗采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

解锁物资：小麦；解锁建筑：野生谷穗采集地；旱灾损失 -8%

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

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 小麦留种 (`tech.wheat_seed_saving`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，小麦留种直接使用这一能力完成其工艺或组织设计
- 旱作农业 (`tech.dryland_farming`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，旱作农业直接使用这一能力完成其工艺或组织设计
- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，雨养小麦田直接使用这一能力完成其工艺或组织设计

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

- 野生谷穗采集 (`tech.wild_wheat_collection`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，小麦留种直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 小麦繁育 (`tech.wheat_propagation`)：小麦留种提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，小麦繁育直接使用这一能力完成其工艺或组织设计

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

- 小麦留种 (`tech.wheat_seed_saving`)：小麦留种提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，小麦繁育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

大田作物农业产出 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)；退水小麦地 (`floodplain_wheat_plot`)；佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)；雨养小麦地 (`rainfed_wheat_plot`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)；小麦农场 (`wheat_farm`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 野生稻采集 (`tech.wild_rice_collection`)：稻类辨识提供水田整备、水位控制与稻作管理方法中的识别与证据标准，野生稻采集直接使用这一能力完成其工艺或组织设计

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

- 稻类辨识 (`tech.rice_identification`)：稻类辨识提供水田整备、水位控制与稻作管理方法中的识别与证据标准，野生稻采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

解锁物资：稻米；解锁建筑：野生稻沼泽；洪灾损失 -8%

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

#### 永久 Modifier 条款

- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 稻种留存 (`tech.rice_seed_saving`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，稻种留存直接使用这一能力完成其工艺或组织设计
- 水田畦埂 (`tech.paddy_bunding`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，水田畦埂直接使用这一能力完成其工艺或组织设计
- 水田稻作 (`tech.rice_paddy_cultivation`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，水田稻作直接使用这一能力完成其工艺或组织设计

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

- 野生稻采集 (`tech.wild_rice_collection`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，稻种留存直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

高地农业产出 +18%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 块茎保存 (`tech.tuber_storage`)：块茎辨识提供块茎繁育、坡地耕作与低温保存经验中的识别与证据标准，块茎保存直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 全部路线 | 作物 · 块茎作物 (\`route.crop.tuber\`) |
| 开局能力标签 | \`starter.food\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

解锁物资：马铃薯；解锁建筑：野生块茎采集地

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

#### 永久 Modifier 条款

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

- 块茎辨识 (`tech.potato_identification`)：块茎辨识提供块茎繁育、坡地耕作与低温保存经验中的识别与证据标准，块茎保存直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

高地农业产出 +28%；寒冷损失 -8%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+28%
- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 块茎繁育 (`tech.potato_propagation`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，块茎繁育直接使用这一能力完成其工艺或组织设计
- 梯田农业 (`tech.terrace_farming`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，梯田农业直接使用这一能力完成其工艺或组织设计
- 垄作块茎 (`tech.ridge_tuber_cultivation`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，垄作块茎直接使用这一能力完成其工艺或组织设计
- 高地块茎农业 (`tech.highland_tuber_farming`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，高地块茎农业直接使用这一能力完成其工艺或组织设计

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

- 块茎保存 (`tech.tuber_storage`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，块茎繁育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

解锁物资：马铃薯；高地农业产出 +18%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）

#### 效果摘要

织布业产出 +18%

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

- 织布业：`country.output.family.cloth_weaving_factor`：+18%

#### 被以下科技作为硬前置

- 野生棉铃采集 (`tech.wild_cotton_collection`)：棉花辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生棉铃采集直接使用这一能力完成其工艺或组织设计

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

- 棉花辨识 (`tech.cotton_identification`)：棉花辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生棉铃采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）

#### 效果摘要

织布业产出 +18%

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

- 织布业：`country.output.family.cloth_weaving_factor`：+18%

#### 被以下科技作为硬前置

- 棉花去籽 (`tech.cotton_ginning`)：野生棉铃采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，棉花去籽直接使用这一能力完成其工艺或组织设计
- 棉花园圃 (`tech.cotton_gardening`)：野生棉铃采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，棉花园圃直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | identification |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

织布业产出 +18%

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

- 织布业：`country.output.family.cloth_weaving_factor`：+18%

#### 被以下科技作为硬前置

- 沤麻 (`tech.flax_retting`)：亚麻与韧皮辨识提供纤维处理、纺纱、织造与服装生产工艺中的识别与证据标准，沤麻直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：韧皮纤维；解锁物资：衣物；解锁建筑：野生韧皮纤维营地；解锁建筑：韧皮裹衣棚

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
- **韧皮裹衣棚**（`building`）：`building.bast_wrap_shelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

专用商品作物农业产出 +18%

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

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+18%

#### 被以下科技作为硬前置

- 野生香料采集 (`tech.wild_spice_collection`)：香料植物辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生香料采集直接使用这一能力完成其工艺或组织设计

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

- 香料植物辨识 (`tech.spice_identification`)：香料植物辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生香料采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

解锁物资：香料；专用商品作物农业产出 +28%；热害损失 -8%

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

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+28%
- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 香料栽培 (`tech.spice_cultivation`)：野生香料采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，香料栽培直接使用这一能力完成其工艺或组织设计
- 遮阴香料园 (`tech.spice_shade_gardening`)：野生香料采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，遮阴香料园直接使用这一能力完成其工艺或组织设计

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

化学工业产出 +18%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+18%

#### 被以下科技作为硬前置

- 野生割胶 (`tech.wild_latex_tapping`)：橡胶树辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生割胶直接使用这一能力完成其工艺或组织设计

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

- 橡胶树辨识 (`tech.rubber_identification`)：橡胶树辨识提供热带作物栽培、采收与商品化处理能力中的识别与证据标准，野生割胶直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）

#### 效果摘要

解锁物资：天然乳胶；解锁建筑：野生割胶营地；采掘部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 天然橡胶加工 (`tech.rubber_working`)：野生割胶提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，天然橡胶加工直接使用这一能力完成其工艺或组织设计

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

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

黄金采掘产出 +18%

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

- 黄金采掘：`country.output.family.gold_extraction_factor`：+18%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「金矿」（resource.gold\_ore）

#### 效果摘要

解锁物资：含金砂矿；解锁建筑：河滩淘金场；解锁建筑：木槽溜洗场；可利用资源：金矿

#### 机会成本

转入该路线需补齐历史锚点；时代 1 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 含金砂矿 (`gold_ore`)
- **建筑 / 生产方式：** 河滩淘金场 (`placer_gold_working`)；木槽溜洗场 (`primitive_gold_sluice`)
- **自然资源：** 金矿 (`gold_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 砂金淘洗精炼棚 (`gold_washing_refinery`)

#### 结构化内容效果

- **含金砂矿**（`good`）：`good.gold_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **河滩淘金场**（`building`）：`building.placer_gold_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **木槽溜洗场**（`building`）：`building.primitive_gold_sluice` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
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

解锁建筑：浅坑银矿作业

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅坑银矿作业 (`shallow_silver_working`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅坑银矿作业**（`building`）：`building.shallow_silver_working` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

解锁物资：白银；解锁物资：含银矿石；解锁建筑：露天银矿；可利用资源：银矿

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

解锁物资：原木；解锁建筑：枯枝采集营地；解锁建筑：伐木场；可利用资源：木材

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
- **伐木场**（`building`）：`building.timber_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **木材**（`resource`）：`resource.timber` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

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

- 满足其一：
  - 已发现信号「芦苇」（bio.reed）
  - 已发现信号「沼泽」（landform.marsh）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

科研机构产出 +28%

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

- 科研机构：`country.output.family.research_institution_factor`：+28%

#### 被以下科技作为硬前置

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「芦苇」（bio.reed）
  - 已发现信号「沼泽」（landform.marsh）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

解锁物资：芦苇束；解锁建筑：芦苇收割营地；可利用资源：水田承载力

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
- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 全部路线 | 气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.construction\` |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「牧场承载力」（resource.pasture）

#### 效果摘要

解锁物资：草皮块；解锁建筑：草皮切割场；可利用资源：牧场承载力

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「野生动物」（resource.wild\_game）

#### 效果摘要

解锁物资：衣物；解锁建筑：生皮刮制棚

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

#### 永久 Modifier 条款

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；气候 · 寒冷 (\`route.climate.cold\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「野生动物」（resource.wild\_game）

#### 效果摘要

解锁物资：衣物；解锁物资：毛皮；解锁建筑：毛皮缝制棚

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

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`)；生态 · 牧场 (\`route.ecology.pasture\`) |
| 开局能力标签 | \`starter.clothing\` |
| 效果配置 | craft |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「羊」（bio.sheep）

#### 效果摘要

解锁物资：衣物；解锁建筑：毡制帐篷

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

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 全部路线 | 制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）
  - 已发现信号「洪水经验」（weather.major\_flood）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁物资：科技值；解锁建筑：口述记忆圈

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

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 全部路线 | 制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

解锁物资：科技值；解锁建筑：物候观察棚

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

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 历法 (\`route.institution.calendar\`) |
| 全部路线 | 制度 · 历法 (\`route.institution.calendar\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

解锁物资：科技值；解锁建筑：洪水历法祭所

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 灌溉 (`tech.irrigation`)：洪水历法实践提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，灌溉直接使用这一能力完成其工艺或组织设计

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.pastoral\_livestock |
| 主要路线 | 生态 · 牧场 (\`route.ecology.pasture\`) |
| 全部路线 | 生态 · 牧场 (\`route.ecology.pasture\`)；制度 · 口述传承 (\`route.institution.oral\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 已发现信号「牧场承载力」（resource.pasture）

#### 效果摘要

解锁物资：科技值；解锁建筑：牧群路线议事帐

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

#### 永久 Modifier 条款

无

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
| 研究成本 | 0 科技点（`technology_points`） |
| 节点标记 | 开局科技、区域开局候选 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；制度 · 观察 (\`route.institution.observation\`) |
| 开局能力标签 | \`starter.knowledge\` |
| 效果配置 | starter |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「风暴潮经验」（weather.storm\_surge）

#### 效果摘要

解锁物资：科技值；解锁建筑：潮汐观察屋

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

#### 永久 Modifier 条款

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：木炭；解锁建筑：覆土木炭窑；国家建设成本 -10%

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

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 块炼铁 (`tech.iron_smelting`)：木炭烧制提供林木管理、木材加工与生物质利用工艺中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计

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
| 时代 | 石器时代 (`stone`) |
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

- 铜退火 (`tech.copper_annealing`)：铜退火提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，铜矿焙烧直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 全部满足：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铜矿石；解锁建筑：铜矿；采掘部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「盐」（resource.salt）
  - 已发现信号「硫磺」（resource.sulfur）

#### 效果摘要

解锁物资：卤水；解锁建筑：卤水采集池；可利用资源：盐；制造部门产出 +12%

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
- **盐**（`resource`）：`resource.salt` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 盐渍保存 (`tech.salt_preservation`)：卤水采集提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，盐渍保存直接使用这一能力完成其工艺或组织设计
- 火药配制 (`tech.gunpowder_formulation`)：卤水采集提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，火药配制直接使用这一能力完成其工艺或组织设计

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

解锁物资：燧石原料；可利用资源：燧石；金属工具业产出 +18%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+18%

#### 被以下科技作为硬前置

无

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

- 黏土辨识 (`tech.clay_identification`)：黏土辨识提供土石、陶瓷、玻璃和工程构件制造能力中的识别与证据标准，黏土调制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：砖块；解锁建筑：黏土坑；解锁建筑：露天黏土坑

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
- **露天黏土坑**（`building`）：`building.early_clay_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 手制陶器 (`tech.hand_pottery`)：黏土调制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，手制陶器直接使用这一能力完成其工艺或组织设计
- 窑烧控制 (`tech.kiln_firing`)：黏土调制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，窑烧控制直接使用这一能力完成其工艺或组织设计

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

- 黏土调制 (`tech.clay_preparation`)：黏土调制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，手制陶器直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：陶器；解锁建筑：露天陶器烧造；国家建设成本 -10%

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

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 陶器容器体系 (`tech.pottery`)：手制陶器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，陶器容器体系直接使用这一能力完成其工艺或组织设计

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

科研机构产出 +25%；社会领域研究效率 +15%

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

- 科研机构：`country.output.family.research_institution_factor`：+25%
- `country.research.society_efficiency`：+15%

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

共 59 项科技，研究成本范围 7200-12000；时代里程碑：农耕社会 (`tech.agrarian_society`)。

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

- 种子与繁育观察 (`tech.crop_domestication`)：种子与繁育观察提供粮食处理、保存与农艺组织能力中的成套生产流程，留种选育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 亚麻庄园 (`method_flax_collector_r3`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 香料栽培 (`tech.spice_cultivation`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，香料栽培直接使用这一能力完成其工艺或组织设计
- 雨养田体系 (`tech.rainfed_field_system`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，雨养田体系直接使用这一能力完成其工艺或组织设计
- 轮作 (`tech.crop_rotation`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，轮作直接使用这一能力完成其工艺或组织设计
- 佃作谷物 (`tech.tenant_cereal_farming`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，佃作谷物直接使用这一能力完成其工艺或组织设计
- 系统育种 (`tech.crop_breeding`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，系统育种直接使用这一能力完成其工艺或组织设计

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

- 共同体分工 (`tech.communal_specialization`)：共同体分工提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，永久聚落直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：定居采集营地；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 定居采集营地 (`method_gathering_ground_r1`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自给农庄 (`subsistence_farm`)

#### 结构化内容效果

- **定居采集营地**（`building`）：`building.method_gathering_ground_r1` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 灌溉 (`tech.irrigation`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，灌溉直接使用这一能力完成其工艺或组织设计
- 记事制度 (`tech.record_keeping`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，记事制度直接使用这一能力完成其工艺或组织设计
- 文字 (`tech.writing`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，文字直接使用这一能力完成其工艺或组织设计
- 道路工程 (`tech.road_engineering`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，道路工程直接使用这一能力完成其工艺或组织设计
- 官僚行政 (`tech.state_bureaucracy`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，官僚行政直接使用这一能力完成其工艺或组织设计

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

- 永久聚落 (`tech.permanent_settlements`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，灌溉直接使用这一能力完成其工艺或组织设计
- 洪水历法实践 (`tech.flood_calendar_practice`)：洪水历法实践提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，灌溉直接使用这一能力完成其工艺或组织设计
- 磨制石器 (`tech.ground_stone_tools`)：磨制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，灌溉直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +28%；洪灾损失 -8%

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

- 公共营造：`country.output.family.construction_methods_factor`：+28%
- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 灌溉测量 (`tech.irrigation_surveying`)：灌溉提供水流、风力、输配水和流域工程能力中的成套生产流程，灌溉测量直接使用这一能力完成其工艺或组织设计
- 运河工程 (`tech.canal_engineering`)：灌溉提供水流、风力、输配水和流域工程能力中的成套生产流程，运河工程直接使用这一能力完成其工艺或组织设计

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，游牧放牧直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

畜牧业产出 +18%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+18%

#### 被以下科技作为硬前置

无

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，马匹驯化直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「马匹」（bio.horse）

#### 效果摘要

解锁物资：马匹；解锁建筑：养马场；解锁建筑：马匹繁育营地；热害损失 -8%

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
- **马匹繁育营地**（`building`）：`building.horse_breeding_camp` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 皮纸制作 (`tech.parchment_making`)：马匹驯化提供畜群驯养、育种与畜产品处理能力中的成套生产流程，皮纸制作直接使用这一能力完成其工艺或组织设计

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

- 复合工具 (`tech.composite_tools`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，犁耕农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

大田作物农业产出 +25%；工程领域研究效率 +15%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+25%
- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 畜力牵引 (`tech.animal_traction`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，畜力牵引直接使用这一能力完成其工艺或组织设计
- 道路工程 (`tech.road_engineering`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，道路工程直接使用这一能力完成其工艺或组织设计
- 轮作 (`tech.crop_rotation`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，轮作直接使用这一能力完成其工艺或组织设计

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

- 野生玉米采集 (`tech.wild_maize_collection`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米选育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

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

- 野生谷穗采集 (`tech.wild_wheat_collection`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，旱作农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱盆地」（landform.arid\_basin）
  - 已发现信号「干旱经验」（weather.drought）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 旱作保水 (`tech.dryland_water_retention`)：旱作农业提供谷物旱作、轮作与收获工艺中的成套生产流程，旱作保水直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 地理 · 高地 (\`route.geography.highland\`) |
| 全部路线 | 地理 · 高地 (\`route.geography.highland\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 块茎保存 (`tech.tuber_storage`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，梯田农业直接使用这一能力完成其工艺或组织设计
- 磨制石器 (`tech.ground_stone_tools`)：磨制石器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，梯田农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「山地」（landform.mountain）
  - 已发现信号「高原」（landform.high\_plateau）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

高地农业产出 +18%

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

- 高地农业：`country.output.family.highland_crop_farming_factor`：+18%

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

- 野生香料采集 (`tech.wild_spice_collection`)：野生香料采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，香料栽培直接使用这一能力完成其工艺或组织设计
- 留种选育 (`tech.seed_selection`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，香料栽培直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

专用商品作物农业产出 +18%

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

- 专用商品作物农业：`country.output.family.specialty_commodity_crops_factor`：+18%

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

- 野生割胶 (`tech.wild_latex_tapping`)：野生割胶提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，天然橡胶加工直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）

#### 效果摘要

化学工业产出 +28%；采掘部门产出 +12%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+28%
- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 乳胶烟熏凝固 (`tech.latex_smoke_coagulation`)：天然橡胶加工提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，乳胶烟熏凝固直接使用这一能力完成其工艺或组织设计
- 合成材料 (`tech.synthetic_materials`)：天然橡胶加工提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计

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

- 纤维捻制 (`tech.fiber_twisting`)：纤维捻制提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，织造直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）

#### 效果摘要

解锁物资：布料；解锁建筑：家用织机

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

#### 永久 Modifier 条款

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
| 时代 | 农耕时代 (`agrarian`) |
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

- 自然铜冷锤 (`tech.natural_copper_working`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，木炭坩埚炼铜直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铜；解锁建筑：土法炼铜炉

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 自然铜冷锤 (`tech.natural_copper_working`)：自然铜冷锤提供矿物识别、有色冶炼与合金配制能力中的操作与材料处理方法，铜锡配比与铸造直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「锡矿贸易接触」（contact.tin）

#### 效果摘要

解锁物资：青铜工具；解锁物资：锡；解锁建筑：青铜工具工坊；解锁建筑：土法炼锡炉；采掘部门产出 +12%

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
- **土法炼锡炉**（`building`）：`building.early_tin_smelter` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 货币 (`tech.currency`)：铜锡配比与铸造提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，货币直接使用这一能力完成其工艺或组织设计

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

- 自然观察 (`tech.natural_observation`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，天文历法直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

科研机构产出 +25%；知识部门产出 +15%

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

- 科研机构：`country.output.family.research_institution_factor`：+25%
- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 文字 (`tech.writing`)：天文历法提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，文字直接使用这一能力完成其工艺或组织设计
- 地图学 (`tech.cartography`)：天文历法提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，地图学直接使用这一能力完成其工艺或组织设计

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

- 永久聚落 (`tech.permanent_settlements`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，记事制度直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：书记学校

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 书记学校 (`scribal_school`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **书记学校**（`building`）：`building.scribal_school` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 家庭土地占有 (`tech.household_landholding`)：记事制度提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，家庭土地占有直接使用这一能力完成其工艺或组织设计
- 市场制度 (`tech.market_institutions`)：记事制度提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，市场制度直接使用这一能力完成其工艺或组织设计

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

- 留种选育 (`tech.seed_selection`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，雨养田体系直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱经验」（weather.drought）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

可利用资源：肥沃土壤；可利用资源：旱地承载力；大田作物农业产出 +18%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 肥沃土壤 (`fertile_soil`)；旱地承载力 (`arable_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 菜蔬农场 (`fertile_soil_collector`)；亚麻农场 (`flax_collector`)；玉米庄园 (`landed_estate`)；佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)；雨养玉米田 (`rainfed_maize_field`)；雨养小麦地 (`rainfed_wheat_plot`)；自给农庄 (`subsistence_farm`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)；旱稻田 (`upland_rice_plot`)；小麦农场 (`wheat_farm`)

#### 结构化内容效果

- **肥沃土壤**（`resource`）：`resource.fertile_soil` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **旱地承载力**（`resource`）：`resource.arable_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 公共仓储 (`tech.public_storehouses`)：雨养田体系提供粮食处理、保存与农艺组织能力中的成套生产流程，公共仓储直接使用这一能力完成其工艺或组织设计

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

- 野生稻采集 (`tech.wild_rice_collection`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，水田畦埂直接使用这一能力完成其工艺或组织设计
- 土建筑 (`tech.earth_building`)：土建筑提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，水田畦埂直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

#### 被以下科技作为硬前置

- 旱稻繁育 (`tech.upland_rice_propagation`)：水田畦埂提供水田整备、水位控制与稻作管理方法中的成套生产流程，旱稻繁育直接使用这一能力完成其工艺或组织设计

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

- 旱作农业 (`tech.dryland_farming`)：旱作农业提供谷物旱作、轮作与收获工艺中的成套生产流程，旱作保水直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「干旱经验」（weather.drought）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

公共营造产出 +18%

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

- 公共营造：`country.output.family.construction_methods_factor`：+18%

#### 被以下科技作为硬前置

- 谷物脱粒 (`tech.grain_threshing`)：旱作保水提供谷物旱作、轮作与收获工艺中的成套生产流程，谷物脱粒直接使用这一能力完成其工艺或组织设计

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

- 灌溉 (`tech.irrigation`)：灌溉提供水流、风力、输配水和流域工程能力中的成套生产流程，灌溉测量直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +18%

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

- 公共营造：`country.output.family.construction_methods_factor`：+18%

#### 被以下科技作为硬前置

- 水利工程 (`tech.hydraulic_engineering`)：灌溉测量提供坡降、流量和高程测定方法

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

- 火种控制 (`tech.fire_control`)：火种控制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，窑烧控制直接使用这一能力完成其工艺或组织设计
- 黏土调制 (`tech.clay_preparation`)：黏土调制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，窑烧控制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：烧砖窑；解锁建筑：升焰陶窑；能源部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 烧砖窑 (`fired_brick_kiln`)；升焰陶窑 (`pottery_kiln`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制砖厂 (`bricks_plant`)；土法炼锡炉 (`early_tin_smelter`)；烧砖窑 (`fired_brick_kiln`)；行会陶窑 (`method_pottery_kiln_r3`)；锡矿 (`tin_ore_collector`)

#### 结构化内容效果

- **烧砖窑**（`building`）：`building.fired_brick_kiln` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **升焰陶窑**（`building`）：`building.pottery_kiln` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 陶器容器体系 (`tech.pottery`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，陶器容器体系直接使用这一能力完成其工艺或组织设计
- 早期玻璃烧制 (`tech.early_glassmaking`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，早期玻璃烧制直接使用这一能力完成其工艺或组织设计
- 地表煤利用 (`tech.surface_coal_use`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，地表煤利用直接使用这一能力完成其工艺或组织设计
- 块炼铁 (`tech.iron_smelting`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计
- 火药配制 (`tech.gunpowder_formulation`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，火药配制直接使用这一能力完成其工艺或组织设计

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

- 手制陶器 (`tech.hand_pottery`)：手制陶器提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，陶器容器体系直接使用这一能力完成其工艺或组织设计
- 窑烧控制 (`tech.kiln_firing`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，陶器容器体系直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁建筑：行会陶窑；贸易速度 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会陶窑 (`method_pottery_kiln_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 土法炼铜炉 (`early_copper_smelter`)；活字印刷坊 (`movable_type_print_shop`)

#### 结构化内容效果

- **行会陶窑**（`building`）：`building.method_pottery_kiln_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 河运 (`tech.river_transport`)：陶器容器体系提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，河运直接使用这一能力完成其工艺或组织设计

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

- 纤维捻制 (`tech.fiber_twisting`)：纤维捻制提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，织机织造直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）

#### 效果摘要

解锁建筑：行会织造坊；解锁建筑：羊毛行会作坊；制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 行会织造坊 (`guild_weaving_house`)；羊毛行会作坊 (`method_wool_shed_r3`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **行会织造坊**（`building`）：`building.guild_weaving_house` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **羊毛行会作坊**（`building`）：`building.method_wool_shed_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：织机织造提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，植物纤维抄纸直接使用这一能力完成其工艺或组织设计
- 纺织机械 (`tech.textile_machinery`)：织机织造提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，纺织机械直接使用这一能力完成其工艺或组织设计

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

- 畜牧驯养 (`tech.animal_husbandry`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，畜力牵引直接使用这一能力完成其工艺或组织设计
- 犁耕农业 (`tech.plough_agriculture`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，畜力牵引直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

畜牧业产出 +28%；采掘部门产出 +12%

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
- `country.output.extractive_factor`：+12%

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

- 记事制度 (`tech.record_keeping`)：记事制度提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，家庭土地占有直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁物资：混合谷物；解锁物资：蔬菜；解锁建筑：菜蔬农场；解锁建筑：自给农庄

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
- **自给农庄**（`building`）：`building.subsistence_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 共同田协调 (`tech.communal_field_coordination`)：家庭土地占有提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，共同田协调直接使用这一能力完成其工艺或组织设计

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

- 家庭土地占有 (`tech.household_landholding`)：家庭土地占有提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，共同田协调直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

自给农庄产出 +35%

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

- 自给农庄：`country.output.building.subsistence_farm_factor`：+35%

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

- 雨养田体系 (`tech.rainfed_field_system`)：雨养田体系提供粮食处理、保存与农艺组织能力中的成套生产流程，公共仓储直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

主食厨房产出 +35%

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

- 主食厨房：`country.output.building.staple_kitchen_factor`：+35%

#### 被以下科技作为硬前置

无

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：日晒土坯；解锁物资：建筑构件；解锁建筑：日晒土坯场；解锁建筑：制砖厂；国家建设成本 -10%

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
- **制砖厂**（`building`）：`building.bricks_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 砌体建筑 (`tech.masonry`)：日晒土坯提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，砌体建筑直接使用这一能力完成其工艺或组织设计

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

- 野生玉米采集 (`tech.wild_maize_collection`)：野生玉米采集提供玉米栽培、选育与田间管理经验中的操作与材料处理方法，玉米园圃直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

解锁物资：玉米；解锁建筑：家庭玉米园圃；旱灾损失 -8%

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

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)：玉米园圃提供玉米栽培、选育与田间管理经验中的成套生产流程，刀耕火种玉米直接使用这一能力完成其工艺或组织设计
- 习惯佃作 (`tech.customary_tenancy`)：玉米园圃提供玉米栽培、选育与田间管理经验中的成套生产流程，习惯佃作直接使用这一能力完成其工艺或组织设计

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

- 玉米园圃 (`tech.maize_garden_horticulture`)：玉米园圃提供玉米栽培、选育与田间管理经验中的成套生产流程，刀耕火种玉米直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

解锁建筑：刀耕火种玉米地

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 刀耕火种玉米地 (`swidden_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **刀耕火种玉米地**（`building`）：`building.swidden_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)：刀耕火种玉米提供玉米栽培、选育与田间管理经验中的专门知识，雨养玉米田直接使用这一能力完成其工艺或组织设计

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

- 刀耕火种玉米 (`tech.swidden_maize_cultivation`)：刀耕火种玉米提供玉米栽培、选育与田间管理经验中的专门知识，雨养玉米田直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

解锁建筑：雨养玉米田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 雨养玉米田 (`rainfed_maize_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **雨养玉米田**（`building`）：`building.rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 退水玉米地 (`tech.flood_recession_maize`)：雨养玉米田提供玉米栽培、选育与田间管理经验中的专门知识，退水玉米地直接使用这一能力完成其工艺或组织设计

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

- 雨养玉米田 (`tech.rainfed_maize_cultivation`)：雨养玉米田提供玉米栽培、选育与田间管理经验中的专门知识，退水玉米地直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「玉米样本接触」（contact.maize）

#### 效果摘要

解锁建筑：退水玉米地

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 退水玉米地 (`floodplain_maize_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水玉米地**（`building`）：`building.floodplain_maize_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 旱作保水 (`tech.dryland_water_retention`)：旱作保水提供谷物旱作、轮作与收获工艺中的成套生产流程，谷物脱粒直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「稻」（bio.rice）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

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

- 野生谷穗采集 (`tech.wild_wheat_collection`)：野生谷穗采集提供谷物旱作、轮作与收获工艺中的操作与材料处理方法，雨养小麦田直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

解锁物资：小麦；解锁建筑：雨养小麦地；解锁建筑：小麦农场；旱灾损失 -8%

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
- **小麦农场**（`building`）：`building.wheat_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 退水小麦地 (`tech.flood_recession_wheat`)：雨养小麦田提供谷物旱作、轮作与收获工艺中的专门知识，退水小麦地直接使用这一能力完成其工艺或组织设计

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

- 雨养小麦田 (`tech.rainfed_wheat_cultivation`)：雨养小麦田提供谷物旱作、轮作与收获工艺中的专门知识，退水小麦地直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

解锁建筑：退水小麦地

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 退水小麦地 (`floodplain_wheat_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **退水小麦地**（`building`）：`building.floodplain_wheat_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)：退水小麦地提供谷物旱作、轮作与收获工艺中的成套生产流程，旱作小麦田直接使用这一能力完成其工艺或组织设计

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

- 退水小麦地 (`tech.flood_recession_wheat`)：退水小麦地提供谷物旱作、轮作与收获工艺中的成套生产流程，旱作小麦田直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

解锁建筑：旱作保水小麦田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 旱作保水小麦田 (`dryland_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱作保水小麦田**（`building`）：`building.dryland_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 谷物烘焙 (`tech.grain_baking`)：旱作小麦田提供谷物旱作、轮作与收获工艺中的专门知识，谷物烘焙直接使用这一能力完成其工艺或组织设计

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

- 水田畦埂 (`tech.paddy_bunding`)：水田畦埂提供水田整备、水位控制与稻作管理方法中的成套生产流程，旱稻繁育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

解锁建筑：旱稻田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 旱稻田 (`upland_rice_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **旱稻田**（`building`）：`building.upland_rice_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 湿地稻园 (`tech.wetland_rice_gardening`)：旱稻繁育提供水田整备、水位控制与稻作管理方法中的成套生产流程，湿地稻园直接使用这一能力完成其工艺或组织设计

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

- 旱稻繁育 (`tech.upland_rice_propagation`)：旱稻繁育提供水田整备、水位控制与稻作管理方法中的成套生产流程，湿地稻园直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

解锁物资：稻米；解锁建筑：稻作农场；解锁建筑：湿地稻园

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
- **湿地稻园**（`building`）：`building.wetland_rice_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 稻田水位控制 (`tech.rice_water_control`)：湿地稻园提供水田整备、水位控制与稻作管理方法中的专门知识，稻田水位控制直接使用这一能力完成其工艺或组织设计

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

- 湿地稻园 (`tech.wetland_rice_gardening`)：湿地稻园提供水田整备、水位控制与稻作管理方法中的专门知识，稻田水位控制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：畦埂水稻田

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 畦埂水稻田 (`bunded_rice_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 庄园水田 (`estate_paddy`)；佃作稻庄 (`method_rice_collector_r3`)；精耕稻庄 (`method_rice_collector_r5`)；分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)

#### 结构化内容效果

- **畦埂水稻田**（`building`）：`building.bunded_rice_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 野生稻采集 (`tech.wild_rice_collection`)：野生稻采集提供水田整备、水位控制与稻作管理方法中的操作与材料处理方法，水田稻作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）

#### 效果摘要

解锁物资：稻米；可利用资源：水田承载力；洪灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 稻米 (`rice_grain`)
- **建筑 / 生产方式：** 无
- **自然资源：** 水田承载力 (`paddy_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作稻庄 (`method_rice_collector_r3`)

#### 结构化内容效果

- **稻米**（`good`）：`good.rice_grain` → `production_access` `unlock` `1.0`；`existing_binding`
- **水田承载力**（`resource`）：`resource.paddy_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 佃作水田 (`tech.tenant_paddy_management`)：水田稻作提供水田整备、水位控制与稻作管理方法中的专门知识，佃作水田直接使用这一能力完成其工艺或组织设计

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

- 块茎保存 (`tech.tuber_storage`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，垄作块茎直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

解锁建筑：马铃薯农场

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 马铃薯农场 (`potato_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **马铃薯农场**（`building`）：`building.potato_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 防霜窖藏 (`tech.frost_protected_storage`)：垄作块茎提供块茎繁育、坡地耕作与低温保存经验中的专门知识，防霜窖藏直接使用这一能力完成其工艺或组织设计

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

- 垄作块茎 (`tech.ridge_tuber_cultivation`)：垄作块茎提供块茎繁育、坡地耕作与低温保存经验中的专门知识，防霜窖藏直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

大田作物农业产出 +18%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+18%

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

- 块茎保存 (`tech.tuber_storage`)：块茎保存提供块茎繁育、坡地耕作与低温保存经验中的操作与材料处理方法，高地块茎农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）

#### 效果摘要

解锁建筑：冷凉高地块茎田；寒冷损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 冷凉高地块茎田 (`highland_tuber_plot`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)；机械化马铃薯农场 (`method_potato_collector_r6`)

#### 结构化内容效果

- **冷凉高地块茎田**（`building`）：`building.highland_tuber_plot` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 分成租佃 (`tech.sharecropping`)：高地块茎农业提供块茎繁育、坡地耕作与低温保存经验中的成套生产流程，分成租佃直接使用这一能力完成其工艺或组织设计

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

- 亚麻与韧皮辨识 (`tech.flax_identification`)：亚麻与韧皮辨识提供纤维处理、纺纱、织造与服装生产工艺中的识别与证据标准，沤麻直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁物资：亚麻纤维；解锁建筑：亚麻农场；解锁建筑：沤麻池

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 亚麻纤维 (`flax_fiber`)
- **建筑 / 生产方式：** 亚麻农场 (`flax_collector`)；沤麻池 (`flax_retting_pit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)；亚麻庄园 (`method_flax_collector_r3`)；改良亚麻庄园 (`method_flax_collector_r5`)

#### 结构化内容效果

- **亚麻纤维**（`good`）：`good.flax_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **亚麻农场**（`building`）：`building.flax_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **沤麻池**（`building`）：`building.flax_retting_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 手工纺纱 (`tech.hand_spinning`)：沤麻提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，手工纺纱直接使用这一能力完成其工艺或组织设计

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

- 沤麻 (`tech.flax_retting`)：沤麻提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，手工纺纱直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）

#### 效果摘要

解锁建筑：家庭纺织坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 家庭纺织坊 (`cottage_weaving`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家用织机 (`household_loom`)

#### 结构化内容效果

- **家庭纺织坊**（`building`）：`building.cottage_weaving` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 野生棉铃采集 (`tech.wild_cotton_collection`)：野生棉铃采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，棉花去籽直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）

#### 效果摘要

解锁物资：棉纤维；解锁建筑：手工轧棉棚

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

#### 永久 Modifier 条款

无

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

- 野生棉铃采集 (`tech.wild_cotton_collection`)：野生棉铃采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，棉花园圃直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「棉花样本接触」（contact.cotton）

#### 效果摘要

解锁物资：棉纤维；解锁物资：籽棉；解锁建筑：家庭棉花园圃；可利用资源：种植园承载力

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 棉纤维 (`cotton_fiber`)；籽棉 (`seed_cotton`)
- **建筑 / 生产方式：** 家庭棉花园圃 (`cotton_garden`)
- **自然资源：** 种植园承载力 (`plantation_land`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；机械化棉花农场 (`method_cotton_collector_r6`)

#### 结构化内容效果

- **棉纤维**（`good`）：`good.cotton_fiber` → `production_access` `unlock` `1.0`；`existing_binding`
- **籽棉**（`good`）：`good.seed_cotton` → `production_access` `unlock` `1.0`；`existing_binding`
- **家庭棉花园圃**（`building`）：`building.cotton_garden` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 商品作物管理 (`tech.commodity_crop_management`)：棉花园圃提供热带作物栽培、采收与商品化处理能力中的专门知识，商品作物管理直接使用这一能力完成其工艺或组织设计

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

- 野生香料采集 (`tech.wild_spice_collection`)：野生香料采集提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，遮阴香料园直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

解锁物资：香料；解锁建筑：林下遮阴香料园；可利用资源：种植园承载力；热害损失 -8%

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
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 商品作物管理 (`tech.commodity_crop_management`)：遮阴香料园提供热带作物栽培、采收与商品化处理能力中的专门知识，商品作物管理直接使用这一能力完成其工艺或组织设计

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

- 天然橡胶加工 (`tech.rubber_working`)：天然橡胶加工提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，乳胶烟熏凝固直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「橡胶样本接触」（contact.rubber）

#### 效果摘要

解锁物资：凝固天然橡胶；解锁建筑：乳胶烟熏凝固棚；可利用资源：种植园承载力

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
- **种植园承载力**（`resource`）：`resource.plantation_land` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

无

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：木材；解锁建筑：锯木场；解锁建筑：改良锯木场；国家建设成本 -10%

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 木材 (`lumber`)
- **建筑 / 生产方式：** 锯木场 (`lumber_plant`)；改良锯木场 (`method_lumber_plant_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 细木家具工坊 (`cabinetmaker_workshop`)；蒸汽锯木厂 (`method_lumber_plant_r6`)

#### 结构化内容效果

- **木材**（`good`）：`good.lumber` → `production_access` `unlock` `1.0`；`existing_binding`
- **锯木场**（`building`）：`building.lumber_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **改良锯木场**（`building`）：`building.method_lumber_plant_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 树皮纸 (`tech.bark_paper_making`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，树皮纸直接使用这一能力完成其工艺或组织设计
- 海岸船厂 (`tech.coastal_shipyards`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，海岸船厂直接使用这一能力完成其工艺或组织设计
- 螺旋压印 (`tech.screw_press_printing`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，螺旋压印直接使用这一能力完成其工艺或组织设计
- 蒸汽锯木 (`tech.steam_sawmilling`)：手工锯木确立锯切、定尺和木料分级工艺，蒸汽锯木是在该工艺上的动力升级

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，乳品加工直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「牛」（bio.cattle）

#### 效果摘要

解锁物资：乳制品；解锁建筑：乳品工坊

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

#### 永久 Modifier 条款

无

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，皮革鞣制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「羊」（bio.sheep）

#### 效果摘要

解锁物资：鞋履；解锁物资：皮革；解锁建筑：鞋匠铺；解锁建筑：制革工坊

#### 机会成本

转入该路线需补齐历史锚点；时代 2 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 鞋履 (`footwear`)；皮革 (`leather`)
- **建筑 / 生产方式：** 鞋匠铺 (`cobbler_shop`)；制革工坊 (`tannery`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；制革厂 (`leather_plant`)；皮纸工坊 (`parchment_workshop`)

#### 结构化内容效果

- **鞋履**（`good`）：`good.footwear` → `production_access` `unlock` `1.0`；`existing_binding`
- **皮革**（`good`）：`good.leather` → `production_access` `unlock` `1.0`；`existing_binding`
- **鞋匠铺**（`building`）：`building.cobbler_shop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **制革工坊**（`building`）：`building.tannery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，毛用畜牧直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「羊」（bio.sheep）

#### 效果摘要

解锁物资：羊毛；解锁建筑：精梳羊毛作坊；解锁建筑：羊毛棚

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
- **羊毛棚**（`building`）：`building.wool_shed` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 畜群管理 (`tech.herd_management`)：畜群管理提供畜群驯养、育种与畜产品处理能力中的成套生产流程，屠宰分割直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「牛」（bio.cattle）
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「猪」（bio.pig）

#### 效果摘要

解锁物资：肉类；解锁建筑：工业屠宰场；解锁建筑：屠宰场

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
- **屠宰场**（`building`）：`building.slaughterhouse` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：酒饮；解锁建筑：酿酒坊；解锁建筑：蒸馏酒坊；农业部门产出 +15%

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
- **蒸馏酒坊**（`building`）：`building.distillery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

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

- 卤水采集 (`tech.brine_collection`)：卤水采集提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，盐渍保存直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「盐」（resource.salt）
  - 已发现信号「硝石」（resource.saltpeter）
  - 已发现信号「硫磺」（resource.sulfur）

#### 效果摘要

解锁物资：食盐；解锁建筑：盐场；解锁建筑：日晒盐田；制造部门产出 +12%

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
- **日晒盐田**（`building`）：`building.solar_salt_pan` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 城市卫生 (`tech.urban_sanitation`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，城市卫生直接使用这一能力完成其工艺或组织设计
- 远洋补给 (`tech.oceanic_provisioning`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，远洋补给直接使用这一能力完成其工艺或组织设计
- 罐藏 (`tech.canning`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，罐藏直接使用这一能力完成其工艺或组织设计

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

- 旱作小麦田 (`tech.dryland_wheat_cultivation`)：旱作小麦田提供谷物旱作、轮作与收获工艺中的专门知识，谷物烘焙直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）

#### 效果摘要

解锁物资：面包；解锁建筑：面包坊；解锁建筑：面包厂

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
- **面包厂**（`building`）：`building.bread_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 窑烧控制 (`tech.kiln_firing`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，早期玻璃烧制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硅砂」（resource.silica\_sand）
  - 已发现信号「石灰岩」（resource.limestone）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：玻璃；解锁物资：硅砂；解锁建筑：玻璃窑；解锁建筑：硅砂矿坑

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
- **硅砂矿坑**（`building`）：`building.classical_silica_pit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

商栈产出 +25%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 留种选育 (`tech.seed_selection`)
- 犁耕农业 (`tech.plough_agriculture`)
- 天文历法 (`tech.celestial_calendars`)
- 永久聚落 (`tech.permanent_settlements`)
- 水田稻作 (`tech.rice_paddy_cultivation`)
- 铜锡配比与铸造 (`tech.bronze_casting`)
- 灌溉测量 (`tech.irrigation_surveying`)
- 记事制度 (`tech.record_keeping`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 商栈：`country.output.family.merchant_post_factor`：+25%
- `country.research.society_efficiency`：+15%

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

共 30 项科技，研究成本范围 18000-30000；时代里程碑：王国体系 (`tech.kingdom_administration`)。

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

- 天文历法 (`tech.celestial_calendars`)：天文历法提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，文字直接使用这一能力完成其工艺或组织设计
- 永久聚落 (`tech.permanent_settlements`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，文字直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：手抄本；解锁建筑：城邦抄写室；知识部门产出 +15%

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

#### 永久 Modifier 条款

- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 学术机构 (`tech.scholarly_academies`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，学术机构直接使用这一能力完成其工艺或组织设计
- 自然哲学 (`tech.natural_philosophy`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，自然哲学直接使用这一能力完成其工艺或组织设计
- 官僚行政 (`tech.state_bureaucracy`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，官僚行政直接使用这一能力完成其工艺或组织设计
- 木版印刷 (`tech.woodblock_printing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，木版印刷直接使用这一能力完成其工艺或组织设计
- 活字印刷 (`tech.movable_type_printing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，活字印刷直接使用这一能力完成其工艺或组织设计
- 经院研究法 (`tech.scholastic_method`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，经院研究法直接使用这一能力完成其工艺或组织设计
- 地图学 (`tech.cartography`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，地图学直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，复式记账直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.construction\_materials |
| 主要路线 | 材料 · 石材 (\`route.material.stone\`) |
| 全部路线 | 材料 · 石材 (\`route.material.stone\`)；材料 · 黏土 (\`route.material.clay\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 日晒土坯 (`tech.adobe_making`)：日晒土坯提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，砌体建筑直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「燧石」（resource.flint）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：石灰；解锁物资：石灰岩；解锁建筑：石灰厂；可利用资源：石灰岩；国家建设成本 -10%

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
- **石灰岩**（`resource`）：`resource.limestone` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 城市水务 (`tech.urban_waterworks`)：砌体建筑提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，城市水务直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）
  - 已发现信号「石料」（resource.stone）

#### 效果摘要

解锁物资：黄金；解锁建筑：砂金淘洗精炼棚；解锁建筑：银矿火试炉；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 黄金 (`gold`)
- **建筑 / 生产方式：** 砂金淘洗精炼棚 (`gold_washing_refinery`)；银矿火试炉 (`silver_fire_assay_hearth`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)

#### 结构化内容效果

- **黄金**（`good`）：`good.gold` → `production_access` `unlock` `1.0`；`existing_binding`
- **砂金淘洗精炼棚**（`building`）：`building.gold_washing_refinery` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **银矿火试炉**（`building`）：`building.silver_fire_assay_hearth` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 火药配制 (`tech.gunpowder_formulation`)：度量衡提供测量基准、统计方法与精密仪器能力中的稳定的组织与制度载体，火药配制直接使用这一能力完成其工艺或组织设计
- 地产测绘 (`tech.property_cadastre`)：度量衡提供测量基准、统计方法与精密仪器能力中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计

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

- 早期贸易 (`tech.early_trade`)：早期贸易提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，市场制度直接使用这一能力完成其工艺或组织设计
- 记事制度 (`tech.record_keeping`)：记事制度提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，市场制度直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

商栈产出 +50%；热害损失 -8%

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

- 商栈：`country.output.building.merchant_post_factor`：+50%
- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 农奴义务 (`tech.serf_obligations`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，农奴义务直接使用这一能力完成其工艺或组织设计
- 商业网络 (`tech.mercantile_networks`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计
- 数字市场 (`tech.digital_marketplaces`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，数字市场直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 制度 · 市场 (\`route.institution.market\`) |
| 全部路线 | 制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 铜锡配比与铸造 (`tech.bronze_casting`)：铜锡配比与铸造提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，货币直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金矿」（resource.gold\_ore）
  - 已发现信号「银矿」（resource.silver\_ore）

#### 效果摘要

解锁物资：珠宝；解锁建筑：金银器工坊；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 珠宝 (`jewelry`)
- **建筑 / 生产方式：** 金银器工坊 (`goldsmith_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 珠宝厂 (`jewelry_plant`)

#### 结构化内容效果

- **珠宝**（`good`）：`good.jewelry` → `production_access` `unlock` `1.0`；`existing_binding`
- **金银器工坊**（`building`）：`building.goldsmith_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 坩埚钢 (`tech.crucible_steel`)：货币提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，坩埚钢直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 永久聚落 (`tech.permanent_settlements`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，道路工程直接使用这一能力完成其工艺或组织设计
- 犁耕农业 (`tech.plough_agriculture`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，道路工程直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：石作工场；解锁建筑：规模化采石场

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石作工场 (`classical_masonry_yard`)；规模化采石场 (`method_stone_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **石作工场**（`building`）：`building.classical_masonry_yard` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **规模化采石场**（`building`）：`building.method_stone_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 行业组织 (`tech.guild_organization`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，行业组织直接使用这一能力完成其工艺或组织设计
- 地图学 (`tech.cartography`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，地图学直接使用这一能力完成其工艺或组织设计
- 机械计时 (`tech.mechanical_timekeeping`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，机械计时直接使用这一能力完成其工艺或组织设计
- 铁路物流 (`tech.rail_logistics`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，铁路物流直接使用这一能力完成其工艺或组织设计

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

- 灌溉 (`tech.irrigation`)：灌溉提供水流、风力、输配水和流域工程能力中的成套生产流程，运河工程直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：石灰石采石场；解锁建筑：石料场；洪灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 石灰石采石场 (`limestone_collector`)；石料场 (`method_stone_collector_r2`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **石灰石采石场**（`building`）：`building.limestone_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **石料场**（`building`）：`building.method_stone_collector_r2` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 水力机械 (`tech.water_power`)：运河工程提供水流、风力、输配水和流域工程能力中的成套生产流程，水力机械直接使用这一能力完成其工艺或组织设计
- 水利工程 (`tech.hydraulic_engineering`)：运河工程提供大尺度渠道、闸门和水位调度经验

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

- 陶器容器体系 (`tech.pottery`)：陶器容器体系提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，河运直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「洪水经验」（weather.major\_flood）

#### 效果摘要

公共营造场产出 +50%；贸易速度 +12%

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

- 公共营造场：`country.output.building.classical_public_works_factor`：+50%
- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 磁针导航 (`tech.magnetic_navigation`)：河运提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，磁针导航直接使用这一能力完成其工艺或组织设计
- 远洋航海 (`tech.oceanic_navigation`)：河运提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋航海直接使用这一能力完成其工艺或组织设计

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

- 留种选育 (`tech.seed_selection`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，轮作直接使用这一能力完成其工艺或组织设计
- 犁耕农业 (`tech.plough_agriculture`)：犁耕农业提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，轮作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：食用油；解锁建筑：堆肥场；解锁建筑：榨油坊；旱灾损失 -8%

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
- **榨油坊**（`building`）：`building.edible_oil_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 集约轮作 (`tech.intensive_crop_rotation`)：轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，集约轮作直接使用这一能力完成其工艺或组织设计

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

- 盐渍保存 (`tech.salt_preservation`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，城市卫生直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「盐」（resource.salt）
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「黏土」（resource.clay）

#### 效果摘要

解锁物资：肥皂；解锁建筑：工业制皂厂；解锁建筑：制皂工坊；制造部门产出 +12%

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
- **制皂工坊**（`building`）：`building.soap_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 公共卫生 (`tech.public_health`)：城市卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生直接使用这一能力完成其工艺或组织设计
- 公共卫生体系 (`tech.public_health_systems`)：城市卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，学术机构直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：古典学院

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 古典学院 (`classical_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **古典学院**（`building`）：`building.classical_academy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 自然哲学 (`tech.natural_philosophy`)：学术机构提供记录、验证、计算与知识传播方法中的操作与材料处理方法，自然哲学直接使用这一能力完成其工艺或组织设计
- 手稿文化 (`tech.manuscript_culture`)：学术机构提供记录、验证、计算与知识传播方法中的操作与材料处理方法，手稿文化直接使用这一能力完成其工艺或组织设计

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

- 自然观察 (`tech.natural_observation`)：自然观察提供观察、分类、实验与生物育种知识中的操作与材料处理方法，自然哲学直接使用这一能力完成其工艺或组织设计
- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，自然哲学直接使用这一能力完成其工艺或组织设计
- 学术机构 (`tech.scholarly_academies`)：学术机构提供记录、验证、计算与知识传播方法中的操作与材料处理方法，自然哲学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「霜冻经验」（weather.frost）
  - 已发现信号「山地」（landform.mountain）

#### 效果摘要

古典学院产出 +50%；采掘部门产出 +12%

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

- 古典学院：`country.output.building.classical_academy_factor`：+50%
- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 跨区域植物学 (`tech.interregional_botany`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，跨区域植物学直接使用这一能力完成其工艺或组织设计
- 科学分类 (`tech.scientific_classification`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，科学分类直接使用这一能力完成其工艺或组织设计
- 地质勘探 (`tech.geological_prospecting`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 王国体系 (`tech.kingdom_administration`)

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

- 窑烧控制 (`tech.kiln_firing`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，地表煤利用直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：煤炭；铁矿业产出 +28%；能源部门产出 +12%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+28%
- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 风力机械 (`tech.wind_power`)：地表煤利用提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，风力机械直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 织机织造 (`tech.loom_weaving`)：织机织造提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，植物纤维抄纸直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「韧皮纤维植物」（bio.bast\_fiber）

#### 效果摘要

解锁物资：纸张；解锁建筑：植物纤维抄纸坊；制造部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 破布纸 (`tech.rag_paper_making`)：植物纤维抄纸提供纤维处理、纺纱、织造与服装生产工艺中的稳定的组织与制度载体，破布纸直接使用这一能力完成其工艺或组织设计

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

- 手工锯木 (`tech.timber_sawing`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，树皮纸直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：纸张；解锁建筑：树皮纸工坊；国家建设成本 -10%

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

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+10%

#### 被以下科技作为硬前置

- 森林管理 (`tech.forest_management`)：树皮纸提供林木管理、木材加工与生物质利用工艺中的稳定的组织与制度载体，森林管理直接使用这一能力完成其工艺或组织设计

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

- 马匹驯化 (`tech.horse_domestication`)：马匹驯化提供畜群驯养、育种与畜产品处理能力中的成套生产流程，皮纸制作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「野生动物」（resource.wild\_game）
  - 已发现信号「羊」（bio.sheep）

#### 效果摘要

解锁物资：纸张；解锁建筑：皮纸工坊；热害损失 -8%

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

#### 永久 Modifier 条款

- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 牧业网络 (`tech.pastoral_networks`)：皮纸制作提供畜群驯养、育种与畜产品处理能力中的稳定的组织与制度载体，牧业网络直接使用这一能力完成其工艺或组织设计

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

- 学术机构 (`tech.scholarly_academies`)：学术机构提供记录、验证、计算与知识传播方法中的操作与材料处理方法，手稿文化直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁建筑：公共营造场；解锁建筑：修道院抄写室

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 公共营造场 (`classical_public_works`)；修道院抄写室 (`monastic_scriptorium`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 活字印刷坊 (`movable_type_print_shop`)；印刷厂 (`printed_materials_plant`)；木版印刷坊 (`woodblock_printing_house`)

#### 结构化内容效果

- **公共营造场**（`building`）：`building.classical_public_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **修道院抄写室**（`building`）：`building.monastic_scriptorium` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，官僚行政直接使用这一能力完成其工艺或组织设计
- 永久聚落 (`tech.permanent_settlements`)：永久聚落提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，官僚行政直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商栈产出 +25%；社会领域研究效率 +15%

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

- 商栈：`country.output.family.merchant_post_factor`：+25%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 庄园核算 (`tech.estate_accounting`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，庄园核算直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，行业组织直接使用这一能力完成其工艺或组织设计
- 经院研究法 (`tech.scholastic_method`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，经院研究法直接使用这一能力完成其工艺或组织设计
- 特许商社 (`tech.chartered_companies`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国家实验室直接使用这一能力完成其工艺或组织设计
- 国营企业 (`tech.state_enterprises`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计

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

- 玉米园圃 (`tech.maize_garden_horticulture`)：玉米园圃提供玉米栽培、选育与田间管理经验中的成套生产流程，习惯佃作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

三圃制小农场产出 +50%；旱灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作稻庄 (`method_rice_collector_r3`)；佃作水田 (`tenant_paddy`)；佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 三圃制小农场：`country.output.building.three_field_smallholding_factor`：+50%
- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 庄园谷物经营 (`tech.manorial_cereal_farming`)：习惯佃作提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，庄园谷物经营直接使用这一能力完成其工艺或组织设计

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

- 高地块茎农业 (`tech.highland_tuber_farming`)：高地块茎农业提供块茎繁育、坡地耕作与低温保存经验中的成套生产流程，分成租佃直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

改良小农场产出 +50%；寒冷损失 -8%

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

- 改良小农场：`country.output.building.improved_smallholding_factor`：+50%
- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 庄园谷物核算 (`tech.estate_cereal_management`)：分成租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，庄园谷物核算直接使用这一能力完成其工艺或组织设计

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

- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，庄园核算直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)；庄园水田 (`estate_paddy`)；玉米庄园 (`landed_estate`)；亚麻庄园 (`method_flax_collector_r3`)；改良亚麻庄园 (`method_flax_collector_r5`)；精耕稻庄 (`method_rice_collector_r5`)；佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 商品作物管理 (`tech.commodity_crop_management`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，商品作物管理直接使用这一能力完成其工艺或组织设计
- 种植园庄园管理 (`tech.estate_plantation_management`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，种植园庄园管理直接使用这一能力完成其工艺或组织设计
- 地产测绘 (`tech.property_cadastre`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计

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

- 留种选育 (`tech.seed_selection`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，佃作谷物直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「稻」（bio.rice）

#### 效果摘要

解锁建筑：佃作雨养玉米田；解锁建筑：佃作雨养小麦田

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作雨养玉米田 (`tenant_rainfed_maize_field`)；佃作雨养小麦田 (`tenant_rainfed_wheat_field`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **佃作雨养玉米田**（`building`）：`building.tenant_rainfed_maize_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **佃作雨养小麦田**（`building`）：`building.tenant_rainfed_wheat_field` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 水田稻作 (`tech.rice_paddy_cultivation`)：水田稻作提供水田整备、水位控制与稻作管理方法中的专门知识，佃作水田直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：分成水田；解锁建筑：佃作水田；解锁建筑：佃作稻庄

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 佃作稻庄 (`method_rice_collector_r3`)；分成水田 (`sharecrop_paddy`)；佃作水田 (`tenant_paddy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **分成水田**（`building`）：`building.sharecrop_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **佃作水田**（`building`）：`building.tenant_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **佃作稻庄**（`building`）：`building.method_rice_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 庄园水田核算 (`tech.estate_paddy_management`)：佃作水田提供水田整备、水位控制与稻作管理方法中的成套生产流程，庄园水田核算直接使用这一能力完成其工艺或组织设计

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

解锁物资：铁矿石；解锁建筑：铁矿；可利用资源：铁矿

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
- **铁矿**（`resource`）：`resource.iron_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 地表铁矿采集 (`tech.surface_iron_collection`)：铁矿辨识提供矿井、钢铁、蒸汽机械与重型设备能力中的识别与证据标准，地表铁矿采集直接使用这一能力完成其工艺或组织设计

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

- 铁矿辨识 (`tech.iron_ore_identification`)：铁矿辨识提供矿井、钢铁、蒸汽机械与重型设备能力中的识别与证据标准，地表铁矿采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁物资：金属工具；解锁建筑：浅层铁矿

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 块炼铁 (`tech.iron_smelting`)：地表铁矿采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计

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

- 地表铁矿采集 (`tech.surface_iron_collection`)：地表铁矿采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计
- 木炭烧制 (`tech.charcoal_burning`)：木炭烧制提供林木管理、木材加工与生物质利用工艺中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计
- 窑烧控制 (`tech.kiln_firing`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，块炼铁直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：锻铁；解锁建筑：块炼炉；解锁建筑：铁制工具工坊；采掘部门产出 +12%

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
- **铁制工具工坊**（`building`）：`building.iron_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 高炉冶炼 (`tech.blast_furnace`)：块炼铁提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，高炉冶炼直接使用这一能力完成其工艺或组织设计
- 煤矿开采 (`tech.coal_mining`)：块炼铁提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，煤矿开采直接使用这一能力完成其工艺或组织设计

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

可利用资源：煤炭；铁矿业产出 +18%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+18%

#### 被以下科技作为硬前置

- 地表煤采集 (`tech.surface_coal_collection`)：露头煤辨识提供矿井、钢铁、蒸汽机械与重型设备能力中的识别与证据标准，地表煤采集直接使用这一能力完成其工艺或组织设计

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

- 露头煤辨识 (`tech.coal_outcrop_identification`)：露头煤辨识提供矿井、钢铁、蒸汽机械与重型设备能力中的识别与证据标准，地表煤采集直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：露头煤采集场

#### 机会成本

转入该路线需补齐历史锚点；时代 3 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 露头煤采集场 (`surface_coal_gathering`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 煤层平硐 (`coal_adit`)

#### 结构化内容效果

- **露头煤采集场**（`building`）：`building.surface_coal_gathering` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 煤矿开采 (`tech.coal_mining`)：地表煤采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，煤矿开采直接使用这一能力完成其工艺或组织设计
- 煤矿平硐 (`tech.coal_adit_mining`)：地表煤采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，煤矿平硐直接使用这一能力完成其工艺或组织设计

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主食厨房产出 +50%；农业部门产出 +15%

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

- 主食厨房：`country.output.building.staple_kitchen_factor`：+50%
- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

无

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

商栈产出 +25%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 轮作 (`tech.crop_rotation`)
- 道路工程 (`tech.road_engineering`)
- 文字 (`tech.writing`)
- 官僚行政 (`tech.state_bureaucracy`)
- 佃作水田 (`tech.tenant_paddy_management`)
- 块炼铁 (`tech.iron_smelting`)
- 自然哲学 (`tech.natural_philosophy`)
- 市场制度 (`tech.market_institutions`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 商栈：`country.output.family.merchant_post_factor`：+25%
- `country.research.society_efficiency`：+15%

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
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.forest\_biomass |
| 主要路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 全部路线 | 生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | foraging |

#### 硬前置（决定研发资格）

- 树皮纸 (`tech.bark_paper_making`)：树皮纸提供林木管理、木材加工与生物质利用工艺中的稳定的组织与制度载体，森林管理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「林业经营突破」（breakthrough.forest\_management）

#### 效果摘要

解锁建筑：水力锯木场；解锁建筑：商营伐木场

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 水力锯木场 (`method_lumber_plant_r4`)；商营伐木场 (`method_timber_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)

#### 结构化内容效果

- **水力锯木场**（`building`）：`building.method_lumber_plant_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **商营伐木场**（`building`）：`building.method_timber_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 皮纸制作 (`tech.parchment_making`)：皮纸制作提供畜群驯养、育种与畜产品处理能力中的稳定的组织与制度载体，牧业网络直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

解锁建筑：庄园牧场；解锁建筑：机械化牧场；热害损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 庄园牧场 (`manorial_pasture`)；机械化牧场 (`ranching_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园牧场**（`building`）：`building.manorial_pasture` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **机械化牧场**（`building`）：`building.ranching_station` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.heat_stress_factor`：+8%

#### 被以下科技作为硬前置

- 商业农庄 (`tech.commercial_estates`)：牧业网络提供畜群驯养、育种与畜产品处理能力中的成套生产流程，商业农庄直接使用这一能力完成其工艺或组织设计

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

- 轮作 (`tech.crop_rotation`)：轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，集约轮作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：三圃制小农场；旱灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 三圃制小农场 (`three_field_smallholding`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)

#### 结构化内容效果

- **三圃制小农场**（`building`）：`building.three_field_smallholding` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 农艺交换 (`tech.agronomic_exchange`)：集约轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，农艺交换直接使用这一能力完成其工艺或组织设计
- 作物移植适应 (`tech.crop_transplantation`)：集约轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，作物移植适应直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 河流 (\`route.geography.river\`) |
| 全部路线 | 地理 · 河流 (\`route.geography.river\`)；能源 · 水力 (\`route.energy.water\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 运河工程 (`tech.canal_engineering`)：运河工程提供水流、风力、输配水和流域工程能力中的成套生产流程，水力机械直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：河流水力发电站；洪灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 河流水力发电站 (`hydropower_station`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **河流水力发电站**（`building`）：`building.hydropower_station` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 矿井排水 (`tech.mine_drainage`)：水力机械提供水流、风力、输配水和流域工程能力中的动力与规模化能力，矿井排水直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 地表煤利用 (`tech.surface_coal_use`)：地表煤利用提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，风力机械直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
  - 已发现信号「季风经验」（weather.monsoon）
  - 已发现信号「台风经验」（weather.typhoon）

#### 效果摘要

可再生能源业产出 +28%；能源部门产出 +12%

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

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+28%
- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 天文导航 (`tech.celestial_navigation`)：风力机械提供水流、风力、输配水和流域工程能力中的动力与规模化能力，天文导航直接使用这一能力完成其工艺或组织设计

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

- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，行业组织直接使用这一能力完成其工艺或组织设计
- 道路工程 (`tech.road_engineering`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，行业组织直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：衣物；解锁物资：家具；解锁建筑：家具行会工坊；解锁建筑：裁缝铺；社会领域研究效率 +15%

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
- **裁缝铺**（`building`）：`building.tailor_shop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 特许大学 (`tech.chartered_universities`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，特许大学直接使用这一能力完成其工艺或组织设计
- 海岸船厂 (`tech.coastal_shipyards`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，海岸船厂直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，复式记账直接使用这一能力完成其工艺或组织设计
- 农艺交换 (`tech.agronomic_exchange`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，农艺交换直接使用这一能力完成其工艺或组织设计
- 合作社组织 (`tech.cooperative_association`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，合作社组织直接使用这一能力完成其工艺或组织设计
- 工业组织 (`tech.industrial_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业组织直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，机床直接使用这一能力完成其工艺或组织设计

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

- 块炼铁 (`tech.iron_smelting`)：块炼铁提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，高炉冶炼直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「煤炭」（resource.coal）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：钢材；解锁建筑：焦炭炼钢厂；采掘部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 深井采矿 (`tech.deep_mining`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，深井采矿直接使用这一能力完成其工艺或组织设计
- 大气式蒸汽机 (`tech.atmospheric_engine`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，大气式蒸汽机直接使用这一能力完成其工艺或组织设计
- 焦炭冶炼 (`tech.coke_smelting`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，焦炭冶炼直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，先进冶金直接使用这一能力完成其工艺或组织设计

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

- 货币 (`tech.currency`)：货币提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，坩埚钢直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：金属工具；钢铁业产出 +28%；采掘部门产出 +12%

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

- 钢铁业：`country.output.family.steelmaking_factor`：+28%
- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 井筒开掘 (`tech.shaft_sinking`)：坩埚钢提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，井筒开掘直接使用这一能力完成其工艺或组织设计

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

- 地表煤采集 (`tech.surface_coal_collection`)：地表煤采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，煤矿开采直接使用这一能力完成其工艺或组织设计
- 块炼铁 (`tech.iron_smelting`)：块炼铁提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，煤矿开采直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：煤炭；解锁建筑：煤矿；采掘部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 工业采煤 (`tech.industrial_coal_mining`)：煤矿开采提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，工业采煤直接使用这一能力完成其工艺或组织设计

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

- 植物纤维抄纸 (`tech.plant_fiber_papermaking`)：植物纤维抄纸提供纤维处理、纺纱、织造与服装生产工艺中的稳定的组织与制度载体，破布纸直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：纸张；解锁建筑：碎布造纸工坊；制造部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；生态 · 森林 (\`route.ecology.forest\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，木版印刷直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：印刷品；解锁建筑：木版印刷坊

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，活字印刷直接使用这一能力完成其工艺或组织设计
- 复合工具 (`tech.composite_tools`)：复合工具提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，活字印刷直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：印刷品；解锁建筑：活字印刷坊；工程领域研究效率 +15%

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

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 螺旋压印 (`tech.screw_press_printing`)：活字印刷提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，螺旋压印直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

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

- 窑烧控制 (`tech.kiln_firing`)：窑烧控制提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，火药配制直接使用这一能力完成其工艺或组织设计
- 度量衡 (`tech.weights_and_measures`)：度量衡提供测量基准、统计方法与精密仪器能力中的稳定的组织与制度载体，火药配制直接使用这一能力完成其工艺或组织设计
- 卤水采集 (`tech.brine_collection`)：卤水采集提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，火药配制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）
  - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：炸药；解锁物资：硝石；解锁建筑：硝石矿；解锁建筑：硫矿；制造部门产出 +12%

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
- **硫矿**（`building`）：`building.sulfur_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 火药武器 (`tech.gunpowder_weapons`)：火药配制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，火药武器直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：火药配制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 河运 (`tech.river_transport`)：河运提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，磁针导航直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「外国舰船或远洋船体接触」（contact.maritime\_vessel）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运作业产出 +28%；贸易速度 +12%

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

- 海运作业：`country.output.family.maritime_operations_factor`：+28%
- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

无

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 地理 · 城市 (\`route.geography.urban\`) |
| 全部路线 | 地理 · 城市 (\`route.geography.urban\`)；气候 · 洪水 (\`route.climate.flood\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 砌体建筑 (`tech.masonry`)：砌体建筑提供土石、陶瓷、玻璃和工程构件制造能力中的成套生产流程，城市水务直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +28%

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

- 公共营造：`country.output.family.construction_methods_factor`：+28%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，经院研究法直接使用这一能力完成其工艺或组织设计
- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，经院研究法直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

古典学院产出 +50%；知识部门产出 +15%

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

- 古典学院：`country.output.building.classical_academy_factor`：+50%
- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 机械计时 (`tech.mechanical_timekeeping`)：经院研究法提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机械计时直接使用这一能力完成其工艺或组织设计
- 实验科学 (`tech.experimental_science`)：经院研究法提供记录、验证、计算与知识传播方法中的操作与材料处理方法，实验科学直接使用这一能力完成其工艺或组织设计
- 学术社团 (`tech.learned_societies`)：经院研究法提供论证、注释和公开争辩的学术规范

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 帝国网络 (`tech.imperial_integration`)

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

- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，特许大学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

解锁建筑：特许大学；解锁建筑：印刷学社

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 特许大学 (`chartered_university`)；印刷学社 (`printing_academy`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **特许大学**（`building`）：`building.chartered_university` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **印刷学社**（`building`）：`building.printing_academy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 庄园司法 (`tech.manorial_jurisdiction`)：特许大学提供制度协调、公共组织与交换规则中的操作与材料处理方法，庄园司法直接使用这一能力完成其工艺或组织设计
- 学术社团 (`tech.learned_societies`)：特许大学提供稳定的学者共同体、章程和人才来源

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

- 特许大学 (`tech.chartered_universities`)：特许大学提供制度协调、公共组织与交换规则中的操作与材料处理方法，庄园司法直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

提供后续科技与内容的知识基础

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

- 行会学徒制 (`tech.guild_apprenticeship`)：庄园司法提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，行会学徒制直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

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

- 市场制度 (`tech.market_institutions`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，农奴义务直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

提供后续科技与内容的知识基础

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

无

#### 被以下科技作为硬前置

无

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

- 习惯佃作 (`tech.customary_tenancy`)：习惯佃作提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，庄园谷物经营直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「稻」（bio.rice）

#### 效果摘要

佃作雨养玉米田产出 +18%；佃作雨养小麦田产出 +18%

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

- 佃作雨养玉米田：`country.output.building.tenant_rainfed_maize_field_factor`：+18%
- 佃作雨养小麦田：`country.output.building.tenant_rainfed_wheat_field_factor`：+18%

#### 被以下科技作为硬前置

无

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

- 庄园司法 (`tech.manorial_jurisdiction`)：庄园司法提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，行会学徒制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

解锁物资：华服；解锁物资：精美家具；解锁建筑：细木家具工坊；解锁建筑：宫廷裁缝坊

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
- **宫廷裁缝坊**（`building`）：`building.court_tailor` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

主食加工厂产出 +50%；农业部门产出 +15%

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

- 主食加工厂：`country.output.building.staple_food_plant_factor`：+50%
- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

- 远洋补给 (`tech.oceanic_provisioning`)：区域粮仓提供粮食处理、保存与农艺组织能力中的稳定的组织与制度载体，远洋补给直接使用这一能力完成其工艺或组织设计

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

- 地表煤采集 (`tech.surface_coal_collection`)：地表煤采集提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，煤矿平硐直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：煤层平硐

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 煤层平硐 (`coal_adit`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **煤层平硐**（`building`）：`building.coal_adit` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 矿井木支护 (`tech.mine_timbering`)：煤矿平硐提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井木支护直接使用这一能力完成其工艺或组织设计

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

- 煤矿平硐 (`tech.coal_adit_mining`)：煤矿平硐提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井木支护直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：浅层铜矿；解锁建筑：浅层锡矿

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 浅层铜矿 (`early_copper_mine`)；浅层锡矿 (`early_tin_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **浅层铜矿**（`building`）：`building.early_copper_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **浅层锡矿**（`building`）：`building.early_tin_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 矿井通风 (`tech.mine_ventilation`)：矿井木支护提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井通风直接使用这一能力完成其工艺或组织设计
- 工业采煤 (`tech.industrial_coal_mining`)：矿井木支护提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，工业采煤直接使用这一能力完成其工艺或组织设计

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

- 矿井木支护 (`tech.mine_timbering`)：矿井木支护提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井通风直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：铅矿；解锁建筑：锌矿；可利用资源：铅矿；可利用资源：锌矿

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 铅矿 (`lead_ore_collector`)；锌矿 (`zinc_ore_collector`)
- **自然资源：** 铅矿 (`lead_ore`)；锌矿 (`zinc_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **铅矿**（`building`）：`building.lead_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锌矿**（`building`）：`building.zinc_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **铅矿**（`resource`）：`resource.lead_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锌矿**（`resource`）：`resource.zinc_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 深井采矿 (`tech.deep_mining`)：矿井通风提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深井采矿直接使用这一能力完成其工艺或组织设计

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
| 布局路线 | branch.tuber\_highland |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 国家治理 (\`route.institution.state\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 分成租佃 (`tech.sharecropping`)：分成租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，庄园谷物核算直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「稻」（bio.rice）

#### 效果摘要

解锁建筑：玉米庄园；解锁建筑：佃作小麦庄园；解锁建筑：改良轮作小麦庄园

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 玉米庄园 (`landed_estate`)；佃作小麦庄园 (`method_wheat_farm_r3`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **玉米庄园**（`building`）：`building.landed_estate` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **佃作小麦庄园**（`building`）：`building.method_wheat_farm_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **改良轮作小麦庄园**（`building`）：`building.method_wheat_farm_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

- 佃作水田 (`tech.tenant_paddy_management`)：佃作水田提供水田整备、水位控制与稻作管理方法中的成套生产流程，庄园水田核算直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「水田承载力」（resource.paddy\_land）
  - 已发现信号「洪泛平原」（landform.floodplain）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：庄园水田；解锁建筑：精耕稻庄

#### 机会成本

转入该路线需补齐历史锚点；时代 4 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 庄园水田 (`estate_paddy`)；精耕稻庄 (`method_rice_collector_r5`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **庄园水田**（`building`）：`building.estate_paddy` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **精耕稻庄**（`building`）：`building.method_rice_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

公共营造场产出 +50%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 集约轮作 (`tech.intensive_crop_rotation`)
- 活字印刷 (`tech.movable_type_printing`)
- 经院研究法 (`tech.scholastic_method`)
- 行业组织 (`tech.guild_organization`)
- 森林管理 (`tech.forest_management`)
- 高炉冶炼 (`tech.blast_furnace`)
- 磁针导航 (`tech.magnetic_navigation`)
- 区域粮仓 (`tech.regional_granaries`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 公共营造场：`country.output.building.classical_public_works_factor`：+50%
- `country.research.society_efficiency`：+15%

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

共 25 项科技，研究成本范围 96000-160000；时代里程碑：洲际网络 (`tech.global_exchange`)。

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，地图学直接使用这一能力完成其工艺或组织设计
- 道路工程 (`tech.road_engineering`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，地图学直接使用这一能力完成其工艺或组织设计
- 天文历法 (`tech.celestial_calendars`)：天文历法提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，地图学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

书记学校产出 +50%；知识部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)；地理空间分析中心 (`geospatial_analysis_center`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 书记学校：`country.output.building.scribal_school_factor`：+50%
- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 远洋航海 (`tech.oceanic_navigation`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，远洋航海直接使用这一能力完成其工艺或组织设计
- 标准化 (`tech.standardization`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，标准化直接使用这一能力完成其工艺或组织设计
- 地质勘探 (`tech.geological_prospecting`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计
- 地产测绘 (`tech.property_cadastre`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地产测绘直接使用这一能力完成其工艺或组织设计
- 地理信息系统 (`tech.geographic_information_systems`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地理信息系统直接使用这一能力完成其工艺或组织设计

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

- 风力机械 (`tech.wind_power`)：风力机械提供水流、风力、输配水和流域工程能力中的动力与规模化能力，天文导航直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运作业产出 +28%；能源部门产出 +12%

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

- 海运作业：`country.output.family.maritime_operations_factor`：+28%
- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

无

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 地图学 (`tech.cartography`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，远洋航海直接使用这一能力完成其工艺或组织设计
- 河运 (`tech.river_transport`)：河运提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋航海直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 满足其一：
  - 已完成科技「磁针导航」（tech.magnetic\_navigation）
  - 已完成科技「天文导航」（tech.celestial\_navigation）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「外国舰船或远洋船体接触」（contact.maritime\_vessel）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁物资：远洋船舶；解锁建筑：远洋造船厂；贸易速度 +12%

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

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 远洋船舶设计 (`tech.oceanic_ship_design`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋船舶设计直接使用这一能力完成其工艺或组织设计
- 商业网络 (`tech.mercantile_networks`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计
- 远洋补给 (`tech.oceanic_provisioning`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋补给直接使用这一能力完成其工艺或组织设计
- 跨区域植物学 (`tech.interregional_botany`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，跨区域植物学直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，精密仪器直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 远洋航海 (`tech.oceanic_navigation`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋船舶设计直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「外国舰船或远洋船体接触」（contact.maritime\_vessel）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运作业产出 +18%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电气化造船厂 (`method_oceanic_shipyard_r7`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运作业：`country.output.family.maritime_operations_factor`：+18%

#### 被以下科技作为硬前置

- 海岸船厂 (`tech.coastal_shipyards`)：远洋船舶设计提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，海岸船厂直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 地理 · 沿海 (\`route.geography.coast\`) |
| 全部路线 | 地理 · 沿海 (\`route.geography.coast\`)；贸易 · 海运 (\`route.trade.maritime\`) |
| 开局能力标签 | 无 |
| 效果配置 | construction |

#### 硬前置（决定研发资格）

- 远洋船舶设计 (`tech.oceanic_ship_design`)：远洋船舶设计提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，海岸船厂直接使用这一能力完成其工艺或组织设计
- 手工锯木 (`tech.timber_sawing`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，海岸船厂直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，海岸船厂直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「外国舰船或远洋船体接触」（contact.maritime\_vessel）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

海运作业产出 +28%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电气化造船厂 (`method_oceanic_shipyard_r7`)；蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 海运作业：`country.output.family.maritime_operations_factor`：+28%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 活字印刷 (`tech.movable_type_printing`)：活字印刷提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，螺旋压印直接使用这一能力完成其工艺或组织设计
- 手工锯木 (`tech.timber_sawing`)：手工锯木提供林木管理、木材加工与生物质利用工艺中的成套生产流程，螺旋压印直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
  - 已发现信号「木材」（resource.timber）

#### 效果摘要

解锁物资：包装材料；解锁物资：印刷品；解锁建筑：包装材料厂；解锁建筑：印刷厂

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
- **印刷厂**（`building`）：`building.printed_materials_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 学术社团 (`tech.learned_societies`)：螺旋压印使论文、目录与通信材料能够低成本复制和跨地传播
- 机械印刷 (`tech.mechanized_printing`)：螺旋压印提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，机械印刷直接使用这一能力完成其工艺或组织设计

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

- 火药配制 (`tech.gunpowder_formulation`)：火药配制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，火药武器直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）
  - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：炸药；解锁物资：硫磺；解锁建筑：炸药厂；解锁建筑：自动化炸药厂；制造部门产出 +12%

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
- **自动化炸药厂**（`building`）：`building.method_explosives_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

无

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

- 文字 (`tech.writing`)：文字提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，复式记账直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，复式记账直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

商栈产出 +50%；社会领域研究效率 +15%

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

- 商栈：`country.output.building.merchant_post_factor`：+50%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 商业网络 (`tech.mercantile_networks`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计
- 商业租佃 (`tech.commercial_tenancy`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业租佃直接使用这一能力完成其工艺或组织设计
- 特许商社 (`tech.chartered_companies`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计
- 政治经济学 (`tech.political_economy`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，政治经济学直接使用这一能力完成其工艺或组织设计
- 合作社组织 (`tech.cooperative_association`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，合作社组织直接使用这一能力完成其工艺或组织设计
- 工业组织 (`tech.industrial_organization`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，工业组织直接使用这一能力完成其工艺或组织设计
- 管理层级 (`tech.managerial_hierarchy`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计
- 公司管理 (`tech.corporate_management`)：复式记账提供资产、负债、成本和利润的统一核算，使公司能够跨业务配置资本

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.commerce\_finance |
| 主要路线 | 作物 · 热带作物 (\`route.crop.tropical\`) |
| 全部路线 | 作物 · 热带作物 (\`route.crop.tropical\`)；制度 · 市场 (\`route.institution.market\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 牧业网络 (`tech.pastoral_networks`)：牧业网络提供畜群驯养、育种与畜产品处理能力中的成套生产流程，商业农庄直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

解锁建筑：药材种植园

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 药材种植园 (`medicinal_herbs_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **药材种植园**（`building`）：`building.medicinal_herbs_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 畜种改良 (`tech.livestock_breeding`)：商业农庄提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，畜种改良直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 市场制度 (`tech.market_institutions`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计
- 远洋航海 (`tech.oceanic_navigation`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业网络直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）
  - 已发现信号「印刷突破」（breakthrough.printing）

#### 效果摘要

商栈产出 +35%

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

- 商栈：`country.output.building.merchant_post_factor`：+35%

#### 被以下科技作为硬前置

- 特许商社 (`tech.chartered_companies`)：商业网络提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计
- 全球物流 (`tech.global_logistics`)：商业网络提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，全球物流直接使用这一能力完成其工艺或组织设计

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

- 道路工程 (`tech.road_engineering`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，机械计时直接使用这一能力完成其工艺或组织设计
- 经院研究法 (`tech.scholastic_method`)：经院研究法提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机械计时直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

金属工具业产出 +25%；工程领域研究效率 +15%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+25%
- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 精密工程 (`tech.precision_engineering`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，精密工程直接使用这一能力完成其工艺或组织设计
- 实验科学 (`tech.experimental_science`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，实验科学直接使用这一能力完成其工艺或组织设计
- 标准化 (`tech.standardization`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，标准化直接使用这一能力完成其工艺或组织设计
- 热力学 (`tech.thermodynamics`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，热力学直接使用这一能力完成其工艺或组织设计

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

- 坩埚钢 (`tech.crucible_steel`)：坩埚钢提供矿物识别、有色冶炼与合金配制能力中的成套生产流程，井筒开掘直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：金矿；解锁建筑：银矿；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 金矿 (`gold_mine`)；银矿 (`silver_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **金矿**（`building`）：`building.gold_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **银矿**（`building`）：`building.silver_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 深井采矿 (`tech.deep_mining`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深井采矿直接使用这一能力完成其工艺或组织设计
- 矿井排水 (`tech.mine_drainage`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井排水直接使用这一能力完成其工艺或组织设计
- 地质勘探 (`tech.geological_prospecting`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计

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

- 井筒开掘 (`tech.shaft_sinking`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深井采矿直接使用这一能力完成其工艺或组织设计
- 矿井通风 (`tech.mine_ventilation`)：矿井通风提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深井采矿直接使用这一能力完成其工艺或组织设计
- 高炉冶炼 (`tech.blast_furnace`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，深井采矿直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁物资：铅矿石；解锁物资：锌矿石；铁矿业产出 +28%；采掘部门产出 +12%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+28%
- `country.output.extractive_factor`：+12%

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

- 水力机械 (`tech.water_power`)：水力机械提供水流、风力、输配水和流域工程能力中的动力与规模化能力，矿井排水直接使用这一能力完成其工艺或组织设计
- 井筒开掘 (`tech.shaft_sinking`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，矿井排水直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「矿井支护突破」（breakthrough.mine\_support）
  - 已发现信号「河湖水系」（landform.freshwater\_access）

#### 效果摘要

解锁建筑：深井盐矿；解锁建筑：锡矿；洪灾损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 深井盐矿 (`industrial_salt_mine`)；锡矿 (`tin_ore_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 硅砂矿 (`silica_sand_collector`)

#### 结构化内容效果

- **深井盐矿**（`building`）：`building.industrial_salt_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **锡矿**（`building`）：`building.tin_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 大气式蒸汽机 (`tech.atmospheric_engine`)：矿井排水提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，大气式蒸汽机直接使用这一能力完成其工艺或组织设计
- 蒸汽抽水 (`tech.steam_pumping`)：矿井排水定义扬程、井下积水和连续排放需求，是蒸汽抽水的直接应用问题
- 深层地球物理 (`tech.deep_geophysics`)：矿井排水提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计

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

- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，商业租佃直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「旱地承载力」（resource.arable\_land）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

生计农业产出 +18%

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

- 生计农业：`country.output.family.subsistence_food_factor`：+18%

#### 被以下科技作为硬前置

- 种植园庄园管理 (`tech.estate_plantation_management`)：商业租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，种植园庄园管理直接使用这一能力完成其工艺或组织设计
- 契约劳工制度 (`tech.indentured_contracts`)：商业租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，契约劳工制度直接使用这一能力完成其工艺或组织设计

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

- 商业网络 (`tech.mercantile_networks`)：商业网络提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计
- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，特许商社直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）
  - 已发现信号「印刷突破」（breakthrough.printing）

#### 效果摘要

商栈产出 +50%；采掘部门产出 +12%

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

- 商栈：`country.output.building.merchant_post_factor`：+50%
- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 煤层地质 (`tech.coal_geology`)：特许商社提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，煤层地质直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.tropical\_commodities |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 棉花园圃 (`tech.cotton_gardening`)：棉花园圃提供热带作物栽培、采收与商品化处理能力中的专门知识，商品作物管理直接使用这一能力完成其工艺或组织设计
- 遮阴香料园 (`tech.spice_shade_gardening`)：遮阴香料园提供热带作物栽培、采收与商品化处理能力中的专门知识，商品作物管理直接使用这一能力完成其工艺或组织设计
- 庄园核算 (`tech.estate_accounting`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，商品作物管理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「亚麻样本接触」（contact.flax）

#### 效果摘要

解锁建筑：专用商品作物种植园；解锁建筑：橡胶种植园；制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)；橡胶种植园 (`rubber_tree_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)；香料种植园 (`spice_plants_collector`)

#### 结构化内容效果

- **专用商品作物种植园**（`building`）：`building.method_specialty_commodity_plantation` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **橡胶种植园**（`building`）：`building.rubber_tree_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 种植园庄园管理 (`tech.estate_plantation_management`)：商品作物管理提供热带作物栽培、采收与商品化处理能力中的成套生产流程，种植园庄园管理直接使用这一能力完成其工艺或组织设计
- 工资契约 (`tech.wage_contracts`)：商品作物管理提供热带作物栽培、采收与商品化处理能力中的成套生产流程，工资契约直接使用这一能力完成其工艺或组织设计

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

- 商业租佃 (`tech.commercial_tenancy`)：商业租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，种植园庄园管理直接使用这一能力完成其工艺或组织设计
- 商品作物管理 (`tech.commodity_crop_management`)：商品作物管理提供热带作物栽培、采收与商品化处理能力中的成套生产流程，种植园庄园管理直接使用这一能力完成其工艺或组织设计
- 庄园核算 (`tech.estate_accounting`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，种植园庄园管理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「棉花」（bio.cotton）

#### 效果摘要

解锁建筑：棉花农场；解锁建筑：香料种植园；解锁建筑：亚麻庄园；解锁建筑：改良亚麻庄园

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 棉花农场 (`cotton_collector`)；亚麻庄园 (`method_flax_collector_r3`)；改良亚麻庄园 (`method_flax_collector_r5`)；香料种植园 (`spice_plants_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 橡胶种植园 (`rubber_tree_collector`)

#### 结构化内容效果

- **棉花农场**（`building`）：`building.cotton_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **香料种植园**（`building`）：`building.spice_plants_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **亚麻庄园**（`building`）：`building.method_flax_collector_r3` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **改良亚麻庄园**（`building`）：`building.method_flax_collector_r5` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 远洋航海 (`tech.oceanic_navigation`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，远洋补给直接使用这一能力完成其工艺或组织设计
- 盐渍保存 (`tech.salt_preservation`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，远洋补给直接使用这一能力完成其工艺或组织设计
- 区域粮仓 (`tech.regional_granaries`)：区域粮仓提供粮食处理、保存与农艺组织能力中的稳定的组织与制度载体，远洋补给直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「海岸」（landform.coast）
  - 已发现信号「海岸河口」（landform.coastal\_estuary）
  - 已发现信号「外国舰船或远洋船体接触」（contact.maritime\_vessel）
  - 已发现信号「航运运营突破」（breakthrough.maritime\_operations）

#### 效果摘要

解锁建筑：远洋渔场；农业部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 远洋渔场 (`method_marine_fish_collector_r4`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **远洋渔场**（`building`）：`building.method_marine_fish_collector_r4` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

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
| 网络角色 | backbone |
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | backbone.food\_storage |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 集约轮作 (`tech.intensive_crop_rotation`)：集约轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，农艺交换直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，农艺交换直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

电气化集约农场产出 +50%；旱灾损失 -8%

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

- 电气化集约农场：`country.output.building.intensive_farm_factor`：+50%
- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 跨区域植物学 (`tech.interregional_botany`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，跨区域植物学直接使用这一能力完成其工艺或组织设计
- 农业改良 (`tech.agricultural_improvement`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，农业改良直接使用这一能力完成其工艺或组织设计
- 土壤实验 (`tech.soil_experimentation`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，土壤实验直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 交流 (\`route.crop.exchange\`) |
| 全部路线 | 作物 · 交流 (\`route.crop.exchange\`)；制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然哲学 (`tech.natural_philosophy`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，跨区域植物学直接使用这一能力完成其工艺或组织设计
- 农艺交换 (`tech.agronomic_exchange`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，跨区域植物学直接使用这一能力完成其工艺或组织设计
- 远洋航海 (`tech.oceanic_navigation`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，跨区域植物学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「玉米」（bio.maize）
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

电气化集约农场产出 +50%；洪灾损失 -8%

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

- 电气化集约农场：`country.output.building.intensive_farm_factor`：+50%
- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

- 作物驯化移植 (`tech.crop_acclimatization`)：跨区域植物学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，作物驯化移植直接使用这一能力完成其工艺或组织设计
- 农业合作社 (`tech.agricultural_cooperatives`)：跨区域植物学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，农业合作社直接使用这一能力完成其工艺或组织设计

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

- 集约轮作 (`tech.intensive_crop_rotation`)：集约轮作提供谷物旱作、轮作与收获工艺中的成套生产流程，作物移植适应直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

大田作物农业产出 +28%；旱灾损失 -8%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+28%
- `country.climate.drought_loss_factor`：+8%

#### 被以下科技作为硬前置

- 作物驯化移植 (`tech.crop_acclimatization`)：作物移植适应提供观察、分类、实验与生物育种知识中的成套生产流程，作物驯化移植直接使用这一能力完成其工艺或组织设计

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

- 跨区域植物学 (`tech.interregional_botany`)：跨区域植物学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，作物驯化移植直接使用这一能力完成其工艺或组织设计
- 作物移植适应 (`tech.crop_transplantation`)：作物移植适应提供观察、分类、实验与生物育种知识中的成套生产流程，作物驯化移植直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

可利用资源：种植园承载力；大田作物农业产出 +28%；寒冷损失 -8%

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

- 大田作物农业：`country.output.family.field_crop_farming_factor`：+28%
- `country.climate.cold_stress_factor`：+8%

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

- 商业租佃 (`tech.commercial_tenancy`)：商业租佃提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，契约劳工制度直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

商栈产出 +18%

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

- 商栈：`country.output.family.merchant_post_factor`：+18%

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

商栈产出 +50%；热害损失 -8%；社会领域研究效率 +15%

#### 机会成本

转入该路线需补齐历史锚点；时代 5 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 农艺交换 (`tech.agronomic_exchange`)
- 机械计时 (`tech.mechanical_timekeeping`)
- 地图学 (`tech.cartography`)
- 复式记账 (`tech.double_entry_bookkeeping`)
- 作物驯化移植 (`tech.crop_acclimatization`)
- 远洋船舶设计 (`tech.oceanic_ship_design`)
- 跨区域植物学 (`tech.interregional_botany`)
- 特许商社 (`tech.chartered_companies`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 商栈：`country.output.building.merchant_post_factor`：+50%
- `country.climate.heat_stress_factor`：+8%
- `country.research.society_efficiency`：+15%

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
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.natural\_history |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 自然哲学 (`tech.natural_philosophy`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，科学分类直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 至少满足 2 项：
  - 已完成科技「实验科学」（tech.experimental\_science）
  - 已完成科技「跨区域植物学」（tech.interregional\_botany）
  - 已完成科技「学术社团」（tech.learned\_societies）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

博学学会产出 +18%

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

- 博学学会：`country.output.building.learned_society_factor`：+18%

#### 被以下科技作为硬前置

- 系统育种 (`tech.crop_breeding`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，系统育种直接使用这一能力完成其工艺或组织设计
- 生物技术 (`tech.biotechnology`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计
- 生物信息学 (`tech.bioinformatics`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物信息学直接使用这一能力完成其工艺或组织设计
- 计算生物学 (`tech.computational_biology`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.natural\_history |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 留种选育 (`tech.seed_selection`)：留种选育提供粮食处理、保存与农艺组织能力中的成套生产流程，系统育种直接使用这一能力完成其工艺或组织设计
- 科学分类 (`tech.scientific_classification`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，系统育种直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 至少满足 2 项：
  - 已完成科技「土壤实验」（tech.soil\_experimentation）
  - 已完成科技「跨区域植物学」（tech.interregional\_botany）
  - 已完成科技「农业改良」（tech.agricultural\_improvement）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

寒冷损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 改良亚麻庄园 (`method_flax_collector_r5`)；精耕稻庄 (`method_rice_collector_r5`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 智能育种 (`tech.intelligent_breeding`)：系统育种提供观察、分类、实验与生物育种知识中的成套生产流程，智能育种直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.wheat\_rainfed |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 农艺交换 (`tech.agronomic_exchange`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，农业改良直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：改良小农场；解锁建筑：工业榨油厂

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 改良小农场 (`improved_smallholding`)；工业榨油厂 (`method_edible_oil_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **改良小农场**（`building`）：`building.improved_smallholding` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **工业榨油厂**（`building`）：`building.method_edible_oil_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 机械化农业 (`tech.mechanized_agriculture`)：农业改良提供谷物旱作、轮作与收获工艺中的成套生产流程，机械化农业直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.tools\_machinery |
| 主要路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 全部路线 | 工艺 · 精准 (\`route.craft.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | tools |

#### 硬前置（决定研发资格）

- 机械计时 (`tech.mechanical_timekeeping`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，精密工程直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
  - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁物资：精密工具；解锁建筑：精密工具厂；解锁建筑：精密工具工坊

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
- **精密工具工坊**（`building`）：`building.precision_tool_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 蒸汽密封 (`tech.steam_sealing`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，蒸汽密封直接使用这一能力完成其工艺或组织设计
- 罐藏 (`tech.canning`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，罐藏直接使用这一能力完成其工艺或组织设计
- 内燃机 (`tech.internal_combustion`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

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

- 经院研究法 (`tech.scholastic_method`)：经院研究法提供记录、验证、计算与知识传播方法中的操作与材料处理方法，实验科学直接使用这一能力完成其工艺或组织设计
- 机械计时 (`tech.mechanical_timekeeping`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，实验科学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

博学学会产出 +50%；知识部门产出 +15%

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

- 博学学会：`country.output.building.learned_society_factor`：+50%
- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 概率与统计 (`tech.probability_statistics`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，概率与统计直接使用这一能力完成其工艺或组织设计
- 公共卫生 (`tech.public_health`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，公共卫生直接使用这一能力完成其工艺或组织设计
- 热力学 (`tech.thermodynamics`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，热力学直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计
- 现代医学 (`tech.modern_medicine`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电磁感应直接使用这一能力完成其工艺或组织设计
- 电化学 (`tech.electrochemistry`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计
- 无线电 (`tech.radio`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，无线电直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业研究直接使用这一能力完成其工艺或组织设计
- 核裂变 (`tech.nuclear_fission`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计

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

- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，政治经济学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

商栈产出 +18%

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

- 商栈：`country.output.family.merchant_post_factor`：+18%

#### 被以下科技作为硬前置

- 长期租约 (`tech.long_term_leases`)：政治经济学提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，长期租约直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

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
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.measurement\_instruments |
| 主要路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 全部路线 | 制度 · 实验 (\`route.institution.experimental\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，概率与统计直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

博学学会产出 +35%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地理空间分析中心 (`geospatial_analysis_center`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 博学学会：`country.output.building.learned_society_factor`：+35%

#### 被以下科技作为硬前置

- 深层地球物理 (`tech.deep_geophysics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，运筹学直接使用这一能力完成其工艺或组织设计
- 信息论 (`tech.information_theory`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，信息论直接使用这一能力完成其工艺或组织设计
- 数值天气预报 (`tech.numerical_weather_prediction`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，数值天气预报直接使用这一能力完成其工艺或组织设计
- 地理信息系统 (`tech.geographic_information_systems`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，地理信息系统直接使用这一能力完成其工艺或组织设计
- 计算生物学 (`tech.computational_biology`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计
- 气候建模 (`tech.climate_modeling`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计

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

- 地图学 (`tech.cartography`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，标准化直接使用这一能力完成其工艺或组织设计
- 机械计时 (`tech.mechanical_timekeeping`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，标准化直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：电气化包装厂；解锁建筑：电气印刷厂；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化包装厂 (`method_packaging_plant_r7`)；电气印刷厂 (`method_printed_materials_plant_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 建筑构件厂 (`construction_components_plant`)；包装材料厂 (`packaging_plant`)

#### 结构化内容效果

- **电气化包装厂**（`building`）：`building.method_packaging_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **电气印刷厂**（`building`）：`building.method_printed_materials_plant_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 水利工程 (`tech.hydraulic_engineering`)：标准化统一管径、构件和测量基准，使跨区域水利设施能够协同建设
- 机械工坊 (`tech.mechanical_workshops`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机械工坊直接使用这一能力完成其工艺或组织设计
- 机械化农业 (`tech.mechanized_agriculture`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机械化农业直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机床直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工厂制直接使用这一能力完成其工艺或组织设计
- 互换零件 (`tech.interchangeable_parts`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，互换零件直接使用这一能力完成其工艺或组织设计
- 电网 (`tech.electric_grid`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，电网直接使用这一能力完成其工艺或组织设计
- 工业质量控制 (`tech.industrial_quality_control`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计

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

- 城市卫生 (`tech.urban_sanitation`)：城市卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生直接使用这一能力完成其工艺或组织设计
- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，公共卫生直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硝石」（resource.saltpeter）
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

化学工业产出 +28%；制造部门产出 +12%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+28%
- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 现代医学 (`tech.modern_medicine`)：公共卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计
- 公共卫生体系 (`tech.public_health_systems`)：公共卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 水利工程 (`tech.hydraulic_engineering`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.hydraulic_engineering` |
| 时代 | 启蒙时代 (`enlightenment`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 244800 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.water\_wind |
| 主要路线 | 气候 · 洪水 (\`route.climate.flood\`) |
| 全部路线 | 气候 · 洪水 (\`route.climate.flood\`)；地理 · 河流 (\`route.geography.river\`) |
| 开局能力标签 | 无 |
| 效果配置 | hydraulic |

#### 硬前置（决定研发资格）

- 运河工程 (`tech.canal_engineering`)：运河工程提供大尺度渠道、闸门和水位调度经验
- 灌溉测量 (`tech.irrigation_surveying`)：灌溉测量提供坡降、流量和高程测定方法
- 标准化 (`tech.standardization`)：标准化统一管径、构件和测量基准，使跨区域水利设施能够协同建设

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁物资：水泥；解锁建筑：水泥厂；解锁建筑：自动化水泥厂

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
- **自动化水泥厂**（`building`）：`building.method_cement_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 精准灌溉 (`tech.precision_irrigation`)：水利工程提供水流、风力、输配水和流域工程能力中的成套生产流程，精准灌溉直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

- 发电机 (`tech.electric_generation`)：水利工程为水轮发电提供流量控制、坝体与引水设施
- 精准灌溉 (`tech.precision_irrigation`)：精准灌溉把水利工程的输配水体系接入数字控制

#### 作为候选参与的里程碑

无

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

- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机械工坊直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）
  - 已发现信号「铁矿」（resource.iron\_ore）

#### 效果摘要

解锁物资：机器零件；解锁建筑：建筑构件厂；解锁建筑：改良家用织机

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
- **改良家用织机**（`building`）：`building.improved_domestic_loom` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 大气式蒸汽机 (`tech.atmospheric_engine`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，大气式蒸汽机直接使用这一能力完成其工艺或组织设计
- 蒸汽密封 (`tech.steam_sealing`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，蒸汽密封直接使用这一能力完成其工艺或组织设计
- 内燃机 (`tech.internal_combustion`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，内燃机直接使用这一能力完成其工艺或组织设计

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

- 自然哲学 (`tech.natural_philosophy`)：自然哲学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计
- 地图学 (`tech.cartography`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计
- 井筒开掘 (`tech.shaft_sinking`)：井筒开掘提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，地质勘探直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「锡矿」（resource.tin\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：锰矿石；解锁建筑：自动化铅矿；解锁建筑：硅砂矿；解锁建筑：工业石灰岩矿场；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锰矿石 (`manganese_ore`)
- **建筑 / 生产方式：** 自动化铅矿 (`method_lead_ore_collector_r9`)；工业石灰岩矿场 (`method_limestone_collector_r6`)；硅砂矿 (`silica_sand_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代硝石矿 (`method_saltpeter_collector_r8`)；现代硫矿 (`method_sulfur_collector_r8`)

#### 结构化内容效果

- **锰矿石**（`good`）：`good.manganese_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **自动化铅矿**（`building`）：`building.method_lead_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硅砂矿**（`building`）：`building.silica_sand_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **工业石灰岩矿场**（`building`）：`building.method_limestone_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 肥料加工 (`tech.fertilizer_processing`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计
- 石油开采 (`tech.petroleum_extraction`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，石油开采直接使用这一能力完成其工艺或组织设计
- 深层地球物理 (`tech.deep_geophysics`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 矿井排水 (`tech.mine_drainage`)：矿井排水提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，大气式蒸汽机直接使用这一能力完成其工艺或组织设计
- 机械工坊 (`tech.mechanical_workshops`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，大气式蒸汽机直接使用这一能力完成其工艺或组织设计
- 高炉冶炼 (`tech.blast_furnace`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，大气式蒸汽机直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁物资：蒸汽机；解锁建筑：大气式蒸汽机工坊

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 大气式蒸汽机工坊 (`atmospheric_engine_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **大气式蒸汽机工坊**（`building`）：`building.atmospheric_engine_workshop` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 工业采煤 (`tech.industrial_coal_mining`)：大气式蒸汽机提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，工业采煤直接使用这一能力完成其工艺或组织设计
- 蒸汽动力 (`tech.steam_power`)：大气式蒸汽机证明蒸汽驱动活塞做功的可行结构，是通用蒸汽动力的工程原型

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

- 经院研究法 (`tech.scholastic_method`)：经院研究法提供论证、注释和公开争辩的学术规范
- 特许大学 (`tech.chartered_universities`)：特许大学提供稳定的学者共同体、章程和人才来源
- 螺旋压印 (`tech.screw_press_printing`)：螺旋压印使论文、目录与通信材料能够低成本复制和跨地传播

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

解锁建筑：博学学会

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 博学学会 (`learned_society`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **博学学会**（`building`）：`building.learned_society` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 开放科学网络 (`tech.open_science_networks`)：学术社团提供观察、分类、实验与生物育种知识中的操作与材料处理方法，开放科学网络直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

- 科学分类 (`tech.scientific_classification`)：学术社团提供分类学所需的标本交流、同行讨论与知识编目网络

#### 跨领域应用

- 实验科学 (`tech.experimental_science`)：学术社团为可重复实验提供交流、评议与结果传播机构
- 工业研究 (`tech.industrial_research`)：工业研究机构沿用学术社团形成的同行评议和知识传播规范

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

- 农艺交换 (`tech.agronomic_exchange`)：农艺交换提供粮食处理、保存与农艺组织能力中的成套生产流程，土壤实验直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

可利用资源：磷矿石；堆肥场产出 +50%

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

- 堆肥场：`country.output.building.composting_yard_factor`：+50%

#### 被以下科技作为硬前置

- 肥料加工 (`tech.fertilizer_processing`)：土壤实验提供观察、分类、实验与生物育种知识中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计

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

- 商业农庄 (`tech.commercial_estates`)：商业农庄提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，畜种改良直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

畜牧业产出 +28%

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

- 畜牧业：`country.output.family.livestock_husbandry_factor`：+28%

#### 被以下科技作为硬前置

无

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

- 商品作物管理 (`tech.commodity_crop_management`)：商品作物管理提供热带作物栽培、采收与商品化处理能力中的成套生产流程，工资契约直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）

#### 效果摘要

家具行会工坊产出 +50%；制造部门产出 +12%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+50%
- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 劳工组织 (`tech.labor_organization`)：工资契约提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计

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

- 政治经济学 (`tech.political_economy`)：政治经济学提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，长期租约直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「旱地承载力」（resource.arable\_land）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)；改良亚麻庄园 (`method_flax_collector_r5`)；精耕稻庄 (`method_rice_collector_r5`)；改良轮作小麦庄园 (`method_wheat_farm_r5`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 地产测绘 (`tech.property_cadastre`)：长期租约提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

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

- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，合作社组织直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，合作社组织直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

家具行会工坊产出 +50%；社会领域研究效率 +15%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+50%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 工厂制 (`tech.factory_system`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，工厂制直接使用这一能力完成其工艺或组织设计
- 公共教育 (`tech.public_education`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，公共教育直接使用这一能力完成其工艺或组织设计
- 国营企业 (`tech.state_enterprises`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计
- 知识合作社 (`tech.knowledge_cooperatives`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，知识合作社直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 通用农艺 (\`route.crop.general\`) |
| 全部路线 | 作物 · 通用农艺 (\`route.crop.general\`)；制度 · 社群 (\`route.institution.community\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 跨区域植物学 (`tech.interregional_botany`)：跨区域植物学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，农业合作社直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

电气化集约农场产出 +50%；洪灾损失 -8%

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

- 电气化集约农场：`country.output.building.intensive_farm_factor`：+50%
- `country.climate.flood_loss_factor`：+8%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 远洋航海 (`tech.oceanic_navigation`)：远洋航海提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，精密仪器直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「金属加工突破」（breakthrough.metalworking）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

金属工具业产出 +28%；贸易速度 +12%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+28%
- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 铁路物流 (`tech.rail_logistics`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，铁路物流直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，电磁感应直接使用这一能力完成其工艺或组织设计
- 核能 (`tech.nuclear_energy`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 卫星观测 (`tech.satellite_observation`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，卫星观测直接使用这一能力完成其工艺或组织设计
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计

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

- 地图学 (`tech.cartography`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地产测绘直接使用这一能力完成其工艺或组织设计
- 长期租约 (`tech.long_term_leases`)：长期租约提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计
- 庄园核算 (`tech.estate_accounting`)：庄园核算提供地权、租佃、登记与乡村治理制度中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计
- 度量衡 (`tech.weights_and_measures`)：度量衡提供测量基准、统计方法与精密仪器能力中的稳定的组织与制度载体，地产测绘直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「旱地承载力」（resource.arable\_land）

#### 效果摘要

解锁建筑：地籍管理局；国家建设成本 -6%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 地籍管理局 (`cadastral_office`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **地籍管理局**（`building`）：`building.cadastral_office` → `construction_and_production_access` `unlock` `1.0`；`new_content`

#### 永久 Modifier 条款

- `country.construction.cost_factor`：+6%

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

- 特许商社 (`tech.chartered_companies`)：特许商社提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，煤层地质直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

提供后续科技与内容的知识基础

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

无

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

- 精密工程 (`tech.precision_engineering`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，蒸汽密封直接使用这一能力完成其工艺或组织设计
- 机械工坊 (`tech.mechanical_workshops`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，蒸汽密封直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「稳定风廊」（landform.stable\_wind\_corridor）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：蒸汽航运船坞；能源部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 6 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽航运船坞 (`method_steam_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽航运船坞**（`building`）：`building.method_steam_shipping` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 蒸汽动力 (`tech.steam_power`)：蒸汽密封降低汽缸、阀门和管路泄漏，使压力和效率可稳定维持

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

- 盐渍保存 (`tech.salt_preservation`)：盐渍保存提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，罐藏直接使用这一能力完成其工艺或组织设计
- 精密工程 (`tech.precision_engineering`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，罐藏直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁物资：鱼罐头；解锁建筑：鱼类罐头厂；解锁建筑：罐头工坊；农业部门产出 +15%

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
- **罐头工坊**（`building`）：`building.canning_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

无

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

特许大学产出 +50%；知识部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 农业改良 (`tech.agricultural_improvement`)
- 标准化 (`tech.standardization`)
- 实验科学 (`tech.experimental_science`)
- 合作社组织 (`tech.cooperative_association`)
- 系统育种 (`tech.crop_breeding`)
- 大气式蒸汽机 (`tech.atmospheric_engine`)
- 科学分类 (`tech.scientific_classification`)
- 地产测绘 (`tech.property_cadastre`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 特许大学：`country.output.building.chartered_university_factor`：+50%
- `country.output.knowledge_factor`：+15%

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

共 25 项科技，研究成本范围 480000-800000；时代里程碑：工业化 (`tech.industrialization`)。

### 工业采煤 (`tech.industrial_coal_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_coal_mining` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
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

- 煤矿开采 (`tech.coal_mining`)：煤矿开采提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，工业采煤直接使用这一能力完成其工艺或组织设计
- 矿井木支护 (`tech.mine_timbering`)：矿井木支护提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，工业采煤直接使用这一能力完成其工艺或组织设计
- 大气式蒸汽机 (`tech.atmospheric_engine`)：大气式蒸汽机提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，工业采煤直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：煤炭；铁矿业产出 +28%；采掘部门产出 +12%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+28%
- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 焦炭冶炼 (`tech.coke_smelting`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，焦炭冶炼直接使用这一能力完成其工艺或组织设计
- 公司矿山 (`tech.corporate_mining`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，公司矿山直接使用这一能力完成其工艺或组织设计
- 机械化采矿 (`tech.mechanized_mining`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，机械化采矿直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 高炉冶炼 (`tech.blast_furnace`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，焦炭冶炼直接使用这一能力完成其工艺或组织设计
- 工业采煤 (`tech.industrial_coal_mining`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，焦炭冶炼直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「煤炭」（resource.coal）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：焦炭；解锁物资：钢材；解锁建筑：焦化厂；解锁建筑：电弧炉炼钢厂；采掘部门产出 +12%

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
- **电弧炉炼钢厂**（`building`）：`building.steel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，热力学直接使用这一能力完成其工艺或组织设计
- 机械计时 (`tech.mechanical_timekeeping`)：机械计时提供测量基准、统计方法与精密仪器能力中的动力与规模化能力，热力学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

蒸汽机工厂产出 +50%；科学领域研究效率 +20%；能源部门产出 +15%

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

- 蒸汽机工厂：`country.output.building.steam_engine_works_factor`：+50%
- `country.research.science_efficiency`：+20%
- `country.output.energy_factor`：+15%

#### 被以下科技作为硬前置

- 电气化 (`tech.electrification`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电气化直接使用这一能力完成其工艺或组织设计
- 内燃机 (`tech.internal_combustion`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计
- 机动农业 (`tech.motorized_agriculture`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机动农业直接使用这一能力完成其工艺或组织设计
- 机械制冷 (`tech.refrigeration`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机械制冷直接使用这一能力完成其工艺或组织设计
- 石化裂解 (`tech.petrochemical_cracking`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计

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

- 农业改良 (`tech.agricultural_improvement`)：农业改良提供谷物旱作、轮作与收获工艺中的成套生产流程，机械化农业直接使用这一能力完成其工艺或组织设计
- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机械化农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：农业机械；解锁建筑：农业机械厂；解锁建筑：机械化棉花农场；解锁建筑：机械化马铃薯农场

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 农业机械 (`agricultural_machinery`)
- **建筑 / 生产方式：** 农业机械厂 (`agricultural_machinery_plant`)；机械化棉花农场 (`method_cotton_collector_r6`)；机械化马铃薯农场 (`method_potato_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)；机械化玉米农场 (`method_landed_estate_r6`)；机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)

#### 结构化内容效果

- **农业机械**（`good`）：`good.agricultural_machinery` → `production_access` `unlock` `1.0`；`existing_binding`
- **农业机械厂**（`building`）：`building.agricultural_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **机械化棉花农场**（`building`）：`building.method_cotton_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **机械化马铃薯农场**（`building`）：`building.method_potato_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 机械收割 (`tech.mechanical_reaping`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机械收割直接使用这一能力完成其工艺或组织设计
- 机械脱粒 (`tech.mechanical_threshing`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机械脱粒直接使用这一能力完成其工艺或组织设计
- 机动农业 (`tech.motorized_agriculture`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机动农业直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业组织直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，工业组织直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：工业砖厂；解锁建筑：工业石灰厂

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业砖厂 (`method_bricks_plant_r6`)；工业石灰厂 (`method_lime_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 面包厂 (`bread_plant`)；鱼类罐头厂 (`canned_fish_plant`)；乳制品厂 (`dairy_products_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；工业榨油厂 (`method_edible_oil_plant_r6`)；工业石灰岩矿场 (`method_limestone_collector_r6`)；综合工学院 (`polytechnic_institute`)

#### 结构化内容效果

- **工业砖厂**（`building`）：`building.method_bricks_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **工业石灰厂**（`building`）：`building.method_lime_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 劳工组织 (`tech.labor_organization`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计
- 管理层级 (`tech.managerial_hierarchy`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计
- 流水线组织 (`tech.assembly_line`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，流水线组织直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，运筹学直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，机床直接使用这一能力完成其工艺或组织设计
- 行业组织 (`tech.guild_organization`)：行业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，机床直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：金属工具；解锁建筑：机械零件厂；解锁建筑：钢制工具厂；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 金属工具 (`tools`)
- **建筑 / 生产方式：** 机械零件厂 (`machine_parts_plant`)；钢制工具厂 (`tools_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 工业机械厂 (`industrial_machinery_plant`)；蒸汽锯木厂 (`method_lumber_plant_r6`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)

#### 结构化内容效果

- **金属工具**（`good`）：`good.tools` → `production_access` `unlock` `1.0`；`existing_binding`
- **机械零件厂**（`building`）：`building.machine_parts_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **钢制工具厂**（`building`）：`building.tools_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 蒸汽动力 (`tech.steam_power`)：机床提供精密汽缸、活塞、阀门和传动件的批量制造能力
- 蒸汽抽水 (`tech.steam_pumping`)：机床保证泵缸、活塞、阀门与连杆的精度和可维修性
- 机械印刷 (`tech.mechanized_printing`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械印刷直接使用这一能力完成其工艺或组织设计
- 机械收割 (`tech.mechanical_reaping`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械收割直接使用这一能力完成其工艺或组织设计
- 机械脱粒 (`tech.mechanical_threshing`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械脱粒直接使用这一能力完成其工艺或组织设计
- 纺织机械 (`tech.textile_machinery`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，纺织机械直接使用这一能力完成其工艺或组织设计
- 互换零件 (`tech.interchangeable_parts`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，互换零件直接使用这一能力完成其工艺或组织设计
- 蒸汽锯木 (`tech.steam_sawmilling`)：机床提供耐用、可互换的轴承、锯架与传动零件，使高速锯切设备可制造和维护
- 电气化 (`tech.electrification`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，电气化直接使用这一能力完成其工艺或组织设计
- 电动机 (`tech.electric_motors`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，电动机直接使用这一能力完成其工艺或组织设计
- 石油钻探 (`tech.petroleum_drilling`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，石油钻探直接使用这一能力完成其工艺或组织设计
- 机械制冷 (`tech.refrigeration`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械制冷直接使用这一能力完成其工艺或组织设计
- 机械化采矿 (`tech.mechanized_mining`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械化采矿直接使用这一能力完成其工艺或组织设计
- 机器人制造 (`tech.robotic_manufacturing`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机器人制造直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

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

- 大气式蒸汽机 (`tech.atmospheric_engine`)：大气式蒸汽机证明蒸汽驱动活塞做功的可行结构，是通用蒸汽动力的工程原型
- 蒸汽密封 (`tech.steam_sealing`)：蒸汽密封降低汽缸、阀门和管路泄漏，使压力和效率可稳定维持
- 机床 (`tech.machine_tools`)：机床提供精密汽缸、活塞、阀门和传动件的批量制造能力

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
  - 已发现信号「蒸汽密封突破」（breakthrough.steam\_sealing）

#### 效果摘要

解锁物资：蒸汽机；解锁建筑：自动化蒸汽机厂；解锁建筑：蒸汽机工厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 蒸汽机 (`steam_engines`)
- **建筑 / 生产方式：** 自动化蒸汽机厂 (`method_steam_engine_works_r9`)；蒸汽机工厂 (`steam_engine_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 鱼类罐头厂 (`canned_fish_plant`)；蒸汽锯木厂 (`method_lumber_plant_r6`)；蒸汽航运船坞 (`method_steam_shipping`)

#### 结构化内容效果

- **蒸汽机**（`good`）：`good.steam_engines` → `production_access` `unlock` `1.0`；`existing_binding`
- **自动化蒸汽机厂**（`building`）：`building.method_steam_engine_works_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **蒸汽机工厂**（`building`）：`building.steam_engine_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 蒸汽抽水 (`tech.steam_pumping`)：蒸汽动力提供不依赖河流的连续泵送功率
- 铁路物流 (`tech.rail_logistics`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，铁路物流直接使用这一能力完成其工艺或组织设计
- 机械印刷 (`tech.mechanized_printing`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，机械印刷直接使用这一能力完成其工艺或组织设计
- 蒸汽锯木 (`tech.steam_sawmilling`)：蒸汽动力提供连续旋转机械功，直接驱动锯框、进料与传动机构
- 石油开采 (`tech.petroleum_extraction`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，石油开采直接使用这一能力完成其工艺或组织设计
- 发电机 (`tech.electric_generation`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，发电机直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

- 蒸汽抽水 (`tech.steam_pumping`)：稳定蒸汽动力使矿井抽水从试验机械转为可持续生产系统

#### 跨领域应用

- 铁路物流 (`tech.rail_logistics`)：铁路牵引把稳定蒸汽动力应用于陆上大宗运输
- 机械印刷 (`tech.mechanized_printing`)：机械印刷把蒸汽动力应用于连续压印与纸张输送

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

- 矿井排水 (`tech.mine_drainage`)：矿井排水定义扬程、井下积水和连续排放需求，是蒸汽抽水的直接应用问题
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供不依赖河流的连续泵送功率
- 机床 (`tech.machine_tools`)：机床保证泵缸、活塞、阀门与连杆的精度和可维修性

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「流域治理突破」（breakthrough.watershed\_management）

#### 效果摘要

解锁建筑：蒸汽动力煤矿；解锁建筑：蒸汽动力铁矿

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽动力煤矿 (`steam_coal_mine`)；蒸汽动力铁矿 (`steam_iron_mine`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽动力煤矿**（`building`）：`building.steam_coal_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **蒸汽动力铁矿**（`building`）：`building.steam_iron_mine` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 铁路物流 (`tech.rail_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.rail_logistics` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 全部路线 | 贸易 · 铁路 (\`route.trade.rail\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，铁路物流直接使用这一能力完成其工艺或组织设计
- 道路工程 (`tech.road_engineering`)：道路工程提供工具制造、机械加工与设备控制能力中的稳定的组织与制度载体，铁路物流直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，铁路物流直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁物资：铁路设备；解锁建筑：铁路设备厂；解锁建筑：铁路设备工场；贸易速度 +12%

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
- **铁路设备工场**（`building`）：`building.steam_rail_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 冷链 (`tech.cold_chain`)：铁路物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，冷链直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计
- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计
- 火药配制 (`tech.gunpowder_formulation`)：火药配制提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，工业化学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）
  - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：工业化学品；解锁建筑：玻璃厂；解锁建筑：化学工场；可利用资源：硫磺矿；制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 工业化学品 (`industrial_chemicals`)
- **建筑 / 生产方式：** 玻璃厂 (`glass_plant`)；化学工场 (`industrial_chemicals_plant`)
- **自然资源：** 硫磺矿 (`sulfur`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 洗涤剂厂 (`detergent_plant`)；炸药厂 (`explosives_plant`)；制革厂 (`leather_plant`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；现代硝石矿 (`method_saltpeter_collector_r8`)；工业制皂厂 (`method_soap_plant_r6`)；现代硫矿 (`method_sulfur_collector_r8`)；造纸厂 (`paper_plant`)

#### 结构化内容效果

- **工业化学品**（`good`）：`good.industrial_chemicals` → `production_access` `unlock` `1.0`；`existing_binding`
- **玻璃厂**（`building`）：`building.glass_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **化学工场**（`building`）：`building.industrial_chemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **硫磺矿**（`resource`）：`resource.sulfur` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 肥料加工 (`tech.fertilizer_processing`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计
- 现代医学 (`tech.modern_medicine`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计
- 电化学 (`tech.electrochemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，先进冶金直接使用这一能力完成其工艺或组织设计
- 石油化工 (`tech.petrochemical_industry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计
- 合成材料 (`tech.synthetic_materials`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计
- 公共卫生体系 (`tech.public_health_systems`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计
- 石化裂解 (`tech.petrochemical_cracking`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计
- 塑料工程 (`tech.plastics_engineering`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，塑料工程直接使用这一能力完成其工艺或组织设计
- 核燃料循环 (`tech.nuclear_fuel_cycle`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，核燃料循环直接使用这一能力完成其工艺或组织设计
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：工业化学提供聚合、溶剂、温度和纯度控制，是合成纤维成形的反应基础
- 工业生态 (`tech.industrial_ecology`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

- 电化学 (`tech.electrochemistry`)：工业化学的反应控制与纯度标准可扩展到电解反应体系

#### 跨领域应用

- 石油化工 (`tech.petrochemical_industry`)：石油化工直接采用工业化学的反应器、分离和纯度控制
- 现代医学 (`tech.modern_medicine`)：现代药品与消毒品生产采用工业化学的标准反应与质量控制
- 合成肥料 (`tech.synthetic_fertilizer`)：合成肥料可沿工业化学反应工程路线实现

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

- 土壤实验 (`tech.soil_experimentation`)：土壤实验提供观察、分类、实验与生物育种知识中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计
- 地质勘探 (`tech.geological_prospecting`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，肥料加工直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）
  - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：肥料；解锁物资：磷矿石；解锁建筑：磷矿；寒冷损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 肥料 (`fertilizer`)；磷矿石 (`phosphate_rock`)
- **建筑 / 生产方式：** 磷矿 (`phosphate_rock_collector`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化磷矿 (`method_phosphate_rock_collector_r9`)

#### 结构化内容效果

- **肥料**（`good`）：`good.fertilizer` → `production_access` `unlock` `1.0`；`existing_binding`
- **磷矿石**（`good`）：`good.phosphate_rock` → `production_access` `unlock` `1.0`；`existing_binding`
- **磷矿**（`building`）：`building.phosphate_rock_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 合成肥料 (`tech.synthetic_fertilizer`)：肥料加工提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，合成肥料直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | backbone |
| 节点角色 | institution |
| 布局路线 | backbone.knowledge\_computation |
| 主要路线 | 制度 · 印刷 (\`route.institution.printing\`) |
| 全部路线 | 制度 · 印刷 (\`route.institution.printing\`)；工艺 · 机械 (\`route.craft.machinery\`) |
| 开局能力标签 | 无 |
| 效果配置 | knowledge |

#### 硬前置（决定研发资格）

- 螺旋压印 (`tech.screw_press_printing`)：螺旋压印提供记录、验证、计算与知识传播方法中的稳定的组织与制度载体，机械印刷直接使用这一能力完成其工艺或组织设计
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，机械印刷直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械印刷直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「印刷突破」（breakthrough.printing）
  - 已发现信号「印刷校准突破」（breakthrough.print\_calibration）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：造纸厂

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 造纸厂 (`paper_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **造纸厂**（`building`）：`building.paper_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械收割直接使用这一能力完成其工艺或组织设计
- 机械化农业 (`tech.mechanized_agriculture`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机械收割直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「稻」（bio.rice）
  - 已发现信号「稻种样本接触」（contact.rice）
  - 已发现信号「水田控制突破」（breakthrough.paddy\_control）

#### 效果摘要

解锁建筑：机械化农场；解锁建筑：机械化玉米农场

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化农场 (`mechanized_farm`)；机械化玉米农场 (`method_landed_estate_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 机械化马铃薯农场 (`method_potato_collector_r6`)

#### 结构化内容效果

- **机械化农场**（`building`）：`building.mechanized_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **机械化玉米农场**（`building`）：`building.method_landed_estate_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械脱粒直接使用这一能力完成其工艺或组织设计
- 机械化农业 (`tech.mechanized_agriculture`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机械脱粒直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「小麦」（bio.wheat）
  - 已发现信号「小麦样本接触」（contact.wheat）
  - 已发现信号「雨养适应突破」（breakthrough.rainfed\_adaptation）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 机械化棉花农场 (`method_cotton_collector_r6`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工厂制直接使用这一能力完成其工艺或组织设计
- 合作社组织 (`tech.cooperative_association`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，工厂制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：工业机械；解锁建筑：工业机械厂；解锁建筑：数字化工业机械厂；解锁建筑：制鞋厂；解锁建筑：制革厂；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 工业机械 (`industrial_machinery`)
- **建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；工业机械厂 (`industrial_machinery_plant`)；制革厂 (`leather_plant`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 造纸厂 (`paper_plant`)；主食加工厂 (`staple_food_plant`)

#### 结构化内容效果

- **工业机械**（`good`）：`good.industrial_machinery` → `production_access` `unlock` `1.0`；`existing_binding`
- **工业机械厂**（`building`）：`building.industrial_machinery_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **数字化工业机械厂**（`building`）：`building.method_industrial_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **制鞋厂**（`building`）：`building.footwear_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **制革厂**（`building`）：`building.leather_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 纺织机械 (`tech.textile_machinery`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，纺织机械直接使用这一能力完成其工艺或组织设计
- 劳工组织 (`tech.labor_organization`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计
- 管理层级 (`tech.managerial_hierarchy`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计
- 工业统计 (`tech.industrial_statistics`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业统计直接使用这一能力完成其工艺或组织设计
- 流水线组织 (`tech.assembly_line`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，流水线组织直接使用这一能力完成其工艺或组织设计
- 公共教育 (`tech.public_education`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，公共教育直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业研究直接使用这一能力完成其工艺或组织设计
- 国营企业 (`tech.state_enterprises`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计

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

- 织机织造 (`tech.loom_weaving`)：织机织造提供纤维处理、纺纱、织造与服装生产工艺中的操作与材料处理方法，纺织机械直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，纺织机械直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，纺织机械直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「棉花」（bio.cotton）
  - 已发现信号「亚麻」（bio.flax）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁建筑：制衣厂；解锁建筑：蒸汽纺织厂；制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 制衣厂 (`clothing_plant`)；蒸汽纺织厂 (`textile_mill`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电力纺织厂 (`cloth_plant`)；高级成衣厂 (`fine_clothing_plant`)；制鞋厂 (`footwear_plant`)；改良家用织机 (`improved_domestic_loom`)

#### 结构化内容效果

- **制衣厂**（`building`）：`building.clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **蒸汽纺织厂**（`building`）：`building.textile_mill` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：纺织机械提供纺丝后的牵伸、卷绕和织造设备，使材料能够进入规模化纺织生产

#### 主题路线后继

- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：纺织机械给合成纤维提供可规模化纺丝、牵伸与织造的设备基础

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

- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计
- 工资契约 (`tech.wage_contracts`)：工资契约提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计
- 工业组织 (`tech.industrial_organization`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，劳工组织直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

家具行会工坊产出 +50%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+50%

#### 被以下科技作为硬前置

- 人机协作 (`tech.human_machine_collaboration`)：劳工组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，人机协作直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 工业化 (`tech.industrialization`)

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

- 工业组织 (`tech.industrial_organization`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计
- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，管理层级直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：高级家具厂；解锁建筑：家具厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高级家具厂 (`fine_furniture_plant`)；家具厂 (`furniture_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **高级家具厂**（`building`）：`building.fine_furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **家具厂**（`building`）：`building.furniture_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 公司管理 (`tech.corporate_management`)：管理层级建立跨部门授权与责任链，是公司级治理不可替代的组织基础

#### 主题路线后继

- 公司管理 (`tech.corporate_management`)：管理层级发展为跨厂区的公司预算、统计与责任中心体系

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

- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业统计直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电气化造船厂 (`method_oceanic_shipyard_r7`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 工人合作工场 (`tech.worker_cooperatives`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工人合作工场直接使用这一能力完成其工艺或组织设计
- 公司管理 (`tech.corporate_management`)：工业统计提供跨工厂绩效比较和计划控制所需的量化资料
- 工业质量控制 (`tech.industrial_quality_control`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，运筹学直接使用这一能力完成其工艺或组织设计
- 工业生态 (`tech.industrial_ecology`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计
- 系统工程 (`tech.systems_engineering`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，系统工程直接使用这一能力完成其工艺或组织设计

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

- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，互换零件直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，互换零件直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「黏土」（resource.clay）
  - 已发现信号「石料」（resource.stone）
  - 已发现信号「炉温控制突破」（breakthrough.kiln\_temperature）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 制鞋厂 (`footwear_plant`)；制革厂 (`leather_plant`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 流水线组织 (`tech.assembly_line`)：互换零件提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，流水线组织直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 流水线组织 (`tech.assembly_line`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.assembly_line` |
| 时代 | 蒸汽时代 (`steam`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 544000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

- 互换零件 (`tech.interchangeable_parts`)：互换零件提供土石、陶瓷、玻璃和工程构件制造能力中的操作与材料处理方法，流水线组织直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，流水线组织直接使用这一能力完成其工艺或组织设计
- 工业组织 (`tech.industrial_organization`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，流水线组织直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁物资：家用电器；解锁建筑：家用电器厂；能源部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 手工锯木 (`tech.timber_sawing`)：手工锯木确立锯切、定尺和木料分级工艺，蒸汽锯木是在该工艺上的动力升级
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供连续旋转机械功，直接驱动锯框、进料与传动机构
- 机床 (`tech.machine_tools`)：机床提供耐用、可互换的轴承、锯架与传动零件，使高速锯切设备可制造和维护

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「木材」（resource.timber）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁建筑：蒸汽锯木厂

#### 机会成本

转入该路线需补齐历史锚点；时代 7 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽锯木厂 (`method_lumber_plant_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽锯木厂**（`building`）：`building.method_lumber_plant_r6` → `construction_and_production_access` `unlock` `1.0`；`new_content`

#### 永久 Modifier 条款

无

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

- 工业采煤 (`tech.industrial_coal_mining`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，公司矿山直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

铁矿业产出 +18%

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

- 铁矿业：`country.output.family.iron_extraction_factor`：+18%

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

- 工业统计 (`tech.industrial_statistics`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工人合作工场直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

家具行会工坊产出 +35%

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

- 家具行会工坊：`country.output.building.guild_hall_factor`：+35%

#### 被以下科技作为硬前置

无

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

焦炭炼钢厂产出 +50%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 机械化农业 (`tech.mechanized_agriculture`)
- 机床 (`tech.machine_tools`)
- 热力学 (`tech.thermodynamics`)
- 工厂制 (`tech.factory_system`)
- 肥料加工 (`tech.fertilizer_processing`)
- 蒸汽动力 (`tech.steam_power`)
- 工业化学 (`tech.industrial_chemistry`)
- 劳工组织 (`tech.labor_organization`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 焦炭炼钢厂：`country.output.building.steam_steel_works_factor`：+50%
- `country.research.society_efficiency`：+15%

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

共 24 项科技，研究成本范围 1080000-1800000；时代里程碑：电气社会 (`tech.electrical_society`)。

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

- 肥料加工 (`tech.fertilizer_processing`)：肥料加工提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，合成肥料直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 满足其一：
  - 已完成科技「工业化学」（tech.industrial\_chemistry）
  - 已完成科技「电化学」（tech.electrochemistry）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「硫磺」（resource.sulfur）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）
  - 已发现信号「硝石」（resource.saltpeter）

#### 效果摘要

解锁物资：肥料；解锁建筑：化肥厂

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

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 热力学 (`tech.thermodynamics`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电气化直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，电气化直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：电气设备；解锁建筑：早期电气设备厂；解锁建筑：电气设备厂

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
- **电气设备厂**（`building`）：`building.electrical_equipment_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 电网 (`tech.electric_grid`)：电气化提供发电、电机、电网与能源控制能力中的动力与规模化能力，电网直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电气化提供发电、电机、电网与能源控制能力中的动力与规模化能力，电子控制直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 电气社会 (`tech.electrical_society`)

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

- 合作社组织 (`tech.cooperative_association`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，公共教育直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，公共教育直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：工业研究实验室；解锁建筑：综合工学院；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 工业研究实验室 (`industrial_research_laboratory`)；综合工学院 (`polytechnic_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **工业研究实验室**（`building`）：`building.industrial_research_laboratory` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **综合工学院**（`building`）：`building.polytechnic_institute` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 国家实验室 (`tech.national_laboratories`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，国家实验室直接使用这一能力完成其工艺或组织设计
- 知识经济 (`tech.knowledge_economy`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，知识经济直接使用这一能力完成其工艺或组织设计
- 开放科学网络 (`tech.open_science_networks`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，开放科学网络直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 全部路线 | 制度 · 工厂 (\`route.institution.factory\`) |
| 开局能力标签 | 无 |
| 效果配置 | manufacturing |

#### 硬前置（决定研发资格）

无

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）
  - 已发现信号「肥沃土壤」（resource.fertile\_soil）
  - 已发现信号「连续歉收经验」（weather.repeated\_crop\_failure）

#### 效果摘要

解锁建筑：酿造厂；解锁建筑：主食加工厂；解锁建筑：珠宝厂；解锁建筑：电力纺织厂；解锁建筑：高级成衣厂；农业部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 酿造厂 (`beverages_plant`)；电力纺织厂 (`cloth_plant`)；高级成衣厂 (`fine_clothing_plant`)；珠宝厂 (`jewelry_plant`)；主食加工厂 (`staple_food_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 混凝土厂 (`concrete_plant`)；高级家具厂 (`fine_furniture_plant`)；家具厂 (`furniture_plant`)；家用电器厂 (`household_appliances_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；智能化汽车厂 (`method_automobiles_plant_r10`)；电气化造船厂 (`method_oceanic_shipyard_r7`)；电气化包装厂 (`method_packaging_plant_r7`)；电气印刷厂 (`method_printed_materials_plant_r7`)；工业制皂厂 (`method_soap_plant_r6`)；综合食品厂 (`processed_food_plant`)

#### 结构化内容效果

- **酿造厂**（`building`）：`building.beverages_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **主食加工厂**（`building`）：`building.staple_food_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **珠宝厂**（`building`）：`building.jewelry_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **电力纺织厂**（`building`）：`building.cloth_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **高级成衣厂**（`building`）：`building.fine_clothing_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | resource |

#### 硬前置（决定研发资格）

- 地质勘探 (`tech.geological_prospecting`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，石油开采直接使用这一能力完成其工艺或组织设计
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，石油开采直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：原油；解锁建筑：油田；可利用资源：石油

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
- **石油**（`resource`）：`resource.oil` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 石油炼制 (`tech.petroleum_refining`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油炼制直接使用这一能力完成其工艺或组织设计
- 石油钻探 (`tech.petroleum_drilling`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油钻探直接使用这一能力完成其工艺或组织设计
- 石油化工 (`tech.petrochemical_industry`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油开采 (`tech.petroleum_extraction`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油炼制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：精炼燃料；解锁建筑：智能炼油厂；解锁建筑：炼油厂

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
- **炼油厂**（`building`）：`building.refined_fuel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 内燃机 (`tech.internal_combustion`)：石油炼制提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计
- 石油化工 (`tech.petrochemical_industry`)：石油炼制提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计

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

- 石油炼制 (`tech.petroleum_refining`)：石油炼制提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计
- 精密工程 (`tech.precision_engineering`)：精密工程提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计
- 热力学 (`tech.thermodynamics`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，内燃机直接使用这一能力完成其工艺或组织设计
- 机械工坊 (`tech.mechanical_workshops`)：机械工坊提供工具制造、机械加工与设备控制能力中的动力与规模化能力，内燃机直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：汽车；解锁物资：发动机；解锁建筑：汽车厂；解锁建筑：发动机厂；采掘部门产出 +12%

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
- **发动机厂**（`building`）：`building.engines_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 机械化采矿 (`tech.mechanized_mining`)：内燃机提供油气开采、炼制与高分子原料能力中的动力与规模化能力，机械化采矿直接使用这一能力完成其工艺或组织设计

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

- 公共卫生 (`tech.public_health`)：公共卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计
- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，现代医学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）

#### 效果摘要

解锁物资：药品；解锁建筑：受控环境药材农场；解锁建筑：制药厂；制造部门产出 +12%

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
- **制药厂**（`building`）：`building.pharmaceuticals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 公共卫生体系 (`tech.public_health_systems`)：现代医学提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计
- 生物技术 (`tech.biotechnology`)：现代医学提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电磁感应直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，电磁感应直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「电气化突破」（breakthrough.electrification）

#### 效果摘要

解锁物资：金属线材；解锁建筑：智能化线材厂；解锁建筑：线材厂；采掘部门产出 +12%

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
- **线材厂**（`building`）：`building.wire_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 电化学 (`tech.electrochemistry`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计
- 无线电 (`tech.radio`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，无线电直接使用这一能力完成其工艺或组织设计
- 发电机 (`tech.electric_generation`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，发电机直接使用这一能力完成其工艺或组织设计
- 电动机 (`tech.electric_motors`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，电动机直接使用这一能力完成其工艺或组织设计
- 核裂变 (`tech.nuclear_fission`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计
- 深层地球物理 (`tech.deep_geophysics`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，半导体制造直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，电化学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
  - 已发现信号「硫磺」（resource.sulfur）

#### 效果摘要

解锁物资：锌；解锁建筑：电化工厂；解锁建筑：炼锌厂；解锁建筑：电池厂

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 锌 (`zinc`)
- **建筑 / 生产方式：** 电池厂 (`batteries_plant`)；电化工厂 (`electrochemical_works`)；炼锌厂 (`zinc_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 洗涤剂厂 (`detergent_plant`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)

#### 结构化内容效果

- **锌**（`good`）：`good.zinc` → `production_access` `unlock` `1.0`；`existing_binding`
- **电化工厂**（`building`）：`building.electrochemical_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **炼锌厂**（`building`）：`building.zinc_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **电池厂**（`building`）：`building.batteries_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 石油化工 (`tech.petrochemical_industry`)：电化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

- 合成肥料 (`tech.synthetic_fertilizer`)：电化学提供另一条合成肥料反应与原料转化路线
- 石油化工 (`tech.petrochemical_industry`)：电解与电化学分离用于石化原料和添加剂生产

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

- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，无线电直接使用这一能力完成其工艺或组织设计
- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，无线电直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「电气化突破」（breakthrough.electrification）

#### 效果摘要

解锁物资：电子元件；解锁物资：无线电设备；解锁建筑：电子元件厂；解锁建筑：无线电设备厂

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
- **无线电设备厂**（`building`）：`building.radio_equipment_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 电信 (`tech.telecommunications`)：无线电提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，电信直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 发电机 (`tech.electric_generation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_generation` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，发电机直接使用这一能力完成其工艺或组织设计
- 蒸汽动力 (`tech.steam_power`)：蒸汽动力提供矿井、钢铁、蒸汽机械与重型设备能力中的动力与规模化能力，发电机直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「蒸汽动力突破」（breakthrough.steam\_power）

#### 效果摘要

解锁物资：电力；解锁建筑：燃煤发电厂；解锁建筑：燃气发电厂

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
- **燃气发电厂**（`building`）：`building.gas_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 电网 (`tech.electric_grid`)：发电机提供发电、电机、电网与能源控制能力中的动力与规模化能力，电网直接使用这一能力完成其工艺或组织设计
- 电动机 (`tech.electric_motors`)：发电机提供发电、电机、电网与能源控制能力中的动力与规模化能力，电动机直接使用这一能力完成其工艺或组织设计

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

- 发电机 (`tech.electric_generation`)：发电机提供发电、电机、电网与能源控制能力中的动力与规模化能力，电网直接使用这一能力完成其工艺或组织设计
- 电气化 (`tech.electrification`)：电气化提供发电、电机、电网与能源控制能力中的动力与规模化能力，电网直接使用这一能力完成其工艺或组织设计
- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，电网直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：绝缘电缆；解锁建筑：绝缘电缆厂；解锁建筑：智能化绝缘电缆厂；能源部门产出 +12%

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
- **智能化绝缘电缆厂**（`building`）：`building.method_insulated_cable_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 电信 (`tech.telecommunications`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，电信直接使用这一能力完成其工艺或组织设计
- 核能 (`tech.nuclear_energy`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，核能直接使用这一能力完成其工艺或组织设计
- 智能电网 (`tech.smart_grid`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 通信 (\`route.institution.communication\`) |
| 全部路线 | 制度 · 通信 (\`route.institution.communication\`)；制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | trade |

#### 硬前置（决定研发资格）

- 无线电 (`tech.radio`)：无线电提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，电信直接使用这一能力完成其工艺或组织设计
- 电网 (`tech.electric_grid`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，电信直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

无线电设备厂产出 +50%；贸易速度 +12%

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

- 无线电设备厂：`country.output.building.radio_equipment_works_factor`：+50%
- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 信息论 (`tech.information_theory`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，信息论直接使用这一能力完成其工艺或组织设计
- 网络计算 (`tech.networked_computing`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，网络计算直接使用这一能力完成其工艺或组织设计
- 卫星观测 (`tech.satellite_observation`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，卫星观测直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，传感器网络直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 电动机 (`tech.electric_motors`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.electric_motors` |
| 时代 | 电气时代 (`electrical`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 1224000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，电动机直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，电动机直接使用这一能力完成其工艺或组织设计
- 发电机 (`tech.electric_generation`)：发电机提供发电、电机、电网与能源控制能力中的动力与规模化能力，电动机直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「电机绕组突破」（breakthrough.motor\_winding）

#### 效果摘要

解锁物资：电动机；解锁建筑：电动机厂；解锁建筑：智能化电动机厂；解锁建筑：电气化造船厂

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 电动机 (`electric_motor`)
- **建筑 / 生产方式：** 电动机厂 (`electric_motor_plant`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；电气化造船厂 (`method_oceanic_shipyard_r7`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 家用电器厂 (`household_appliances_plant`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)

#### 结构化内容效果

- **电动机**（`good`）：`good.electric_motor` → `production_access` `unlock` `1.0`；`existing_binding`
- **电动机厂**（`building`）：`building.electric_motor_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化电动机厂**（`building`）：`building.method_electric_motor_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **电气化造船厂**（`building`）：`building.method_oceanic_shipyard_r7` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 机械化农业 (`tech.mechanized_agriculture`)：机械化农业提供工具制造、机械加工与设备控制能力中的成套生产流程，机动农业直接使用这一能力完成其工艺或组织设计
- 热力学 (`tech.thermodynamics`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机动农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：机械化橡胶种植园；解锁建筑：机械化香料种植园

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 机械化橡胶种植园 (`method_rubber_tree_collector_r6`)；机械化香料种植园 (`method_spice_plants_collector_r6`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **机械化橡胶种植园**（`building`）：`building.method_rubber_tree_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **机械化香料种植园**（`building`）：`building.method_spice_plants_collector_r6` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 工业农学 (`tech.industrial_agronomy`)：机动农业提供谷物旱作、轮作与收获工艺中的成套生产流程，工业农学直接使用这一能力完成其工艺或组织设计

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

- 畜牧驯养 (`tech.animal_husbandry`)：畜牧驯养提供畜群驯养、育种与畜产品处理能力中的成套生产流程，现代畜牧直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 满足其一：
  - 已完成科技「畜种改良」（tech.livestock\_breeding）
  - 已完成科技「公共卫生」（tech.public\_health）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「羊」（bio.sheep）
  - 已发现信号「马匹」（bio.horse）
  - 已发现信号「牛」（bio.cattle）

#### 效果摘要

解锁建筑：智能牧业站

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能牧业站 (`method_smart_husbandry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能牧业站**（`building`）：`building.method_smart_husbandry` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 管理层级 (`tech.managerial_hierarchy`)：管理层级建立跨部门授权与责任链，是公司级治理不可替代的组织基础
- 复式记账 (`tech.double_entry_bookkeeping`)：复式记账提供资产、负债、成本和利润的统一核算，使公司能够跨业务配置资本
- 工业统计 (`tech.industrial_statistics`)：工业统计提供跨工厂绩效比较和计划控制所需的量化资料

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 电力纺织厂 (`cloth_plant`)；高级成衣厂 (`fine_clothing_plant`)；珠宝厂 (`jewelry_plant`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 公司农业 (`tech.corporate_agribusiness`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，公司农业直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，平台协调直接使用这一能力完成其工艺或组织设计
- 算法管理 (`tech.algorithmic_management`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，算法管理直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

- 算法管理 (`tech.algorithmic_management`)：公司管理形成的指标、责任与资源配置体系可进一步算法化

#### 跨领域应用

- 运筹学 (`tech.operations_research`)：公司预算和部门统计为运筹模型提供可度量的决策对象

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

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业研究直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，工业研究直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：科学仪器；解锁建筑：智能仪器厂；解锁建筑：科学仪器工坊；知识部门产出 +15%

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
- **科学仪器工坊**（`building`）：`building.scientific_instrument_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 工业质量控制 (`tech.industrial_quality_control`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计
- 工业农学 (`tech.industrial_agronomy`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业农学直接使用这一能力完成其工艺或组织设计
- 核裂变 (`tech.nuclear_fission`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，国家实验室直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电子控制直接使用这一能力完成其工艺或组织设计
- 生物技术 (`tech.biotechnology`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计

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

- 石油开采 (`tech.petroleum_extraction`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油钻探直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，石油钻探直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：蒸汽钻井场；解锁建筑：燃油发电厂；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 蒸汽钻井场 (`early_oil_well`)；燃油发电厂 (`oil_power_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **蒸汽钻井场**（`building`）：`building.early_oil_well` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **燃油发电厂**（`building`）：`building.oil_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

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

- 标准化 (`tech.standardization`)：标准化提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计
- 工业统计 (`tech.industrial_statistics`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业质量控制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁建筑：现代炸药厂；解锁建筑：精密仪器厂；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)；精密仪器厂 (`method_scientific_instrument_works_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 珠宝厂 (`jewelry_plant`)；工业屠宰场 (`mechanized_slaughterhouse`)；自动化水泥厂 (`method_cement_plant_r9`)；自动化焦化厂 (`method_coke_ovens_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)；工业榨油厂 (`method_edible_oil_plant_r6`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化润滑油厂 (`method_lubricants_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；精密工具厂 (`method_precision_tool_workshop_r8`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)；综合食品厂 (`processed_food_plant`)；主食加工厂 (`staple_food_plant`)

#### 结构化内容效果

- **现代炸药厂**（`building`）：`building.method_explosives_plant_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **精密仪器厂**（`building`）：`building.method_scientific_instrument_works_r8` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 核能 (`tech.nuclear_energy`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 特种合金 (`tech.specialty_alloys`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，特种合金直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，半导体制造直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.public\_health |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 热力学 (`tech.thermodynamics`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机械制冷直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械制冷直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 已发现信号「电气化突破」（breakthrough.electrification）

#### 效果摘要

可再生能源业产出 +28%

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

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+28%

#### 被以下科技作为硬前置

- 冷链 (`tech.cold_chain`)：机械制冷提供卫生、疾病控制与医疗组织能力中的动力与规模化能力，冷链直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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
| 布局路线 | branch.public\_health |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 机械制冷 (`tech.refrigeration`)：机械制冷提供卫生、疾病控制与医疗组织能力中的动力与规模化能力，冷链直接使用这一能力完成其工艺或组织设计
- 铁路物流 (`tech.rail_logistics`)：铁路物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，冷链直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「马铃薯」（bio.potato）
  - 已发现信号「块茎样本接触」（contact.potato）
  - 已发现信号「梯田维护突破」（breakthrough.terrace\_maintenance）

#### 效果摘要

解锁物资：加工食品；解锁建筑：乳制品厂；解锁建筑：综合食品厂；寒冷损失 -8%

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
- **综合食品厂**（`building`）：`building.processed_food_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

无

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

可再生能源业产出 +25%；能源部门产出 +15%

#### 机会成本

转入该路线需补齐历史锚点；时代 8 后的生产方式依赖专用资本、岗位或地理条件

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 机动农业 (`tech.motorized_agriculture`)
- 电气化 (`tech.electrification`)
- 工业研究 (`tech.industrial_research`)
- 公共教育 (`tech.public_education`)
- 现代畜牧 (`tech.modern_husbandry`)
- 电网 (`tech.electric_grid`)
- 现代医学 (`tech.modern_medicine`)
- 公司管理 (`tech.corporate_management`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 可再生能源业：`country.output.family.renewable_power_generation_factor`：+25%
- `country.output.energy_factor`：+15%

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
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 全部路线 | 作物 · 工业农业 (\`route.crop.industrial\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 机动农业 (`tech.motorized_agriculture`)：机动农业提供谷物旱作、轮作与收获工艺中的成套生产流程，工业农学直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，工业农学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：电气化集约农场

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 电气化集约农场 (`intensive_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **电气化集约农场**（`building`）：`building.intensive_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 公司农业 (`tech.corporate_agribusiness`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，公司农业直接使用这一能力完成其工艺或组织设计
- 集体农业 (`tech.collective_agriculture`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，集体农业直接使用这一能力完成其工艺或组织设计
- 精准农业 (`tech.precision_agriculture`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，精准农业直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | production\_system |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 全部路线 | 资源 · 合金 (\`route.resource.alloys\`) |
| 开局能力标签 | 无 |
| 效果配置 | metallurgy |

#### 硬前置（决定研发资格）

- 高炉冶炼 (`tech.blast_furnace`)：高炉冶炼提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，先进冶金直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，先进冶金直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 至少满足 2 项：
  - 已完成科技「焦炭冶炼」（tech.coke\_smelting）
  - 已完成科技「电磁感应」（tech.electromagnetic\_induction）
  - 已完成科技「工业质量控制」（tech.industrial\_quality\_control）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铅；解锁物资：钢材；解锁建筑：炼铜厂；解锁建筑：炼锡厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 铅 (`lead`)；钢材 (`steel`)
- **建筑 / 生产方式：** 炼铜厂 (`copper_plant`)；炼锡厂 (`tin_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 炼铅厂 (`lead_plant`)；智能冶铝厂 (`method_aluminum_plant_r10`)；自动化炼铅厂 (`method_lead_plant_r9`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；自动化炼锌厂 (`method_zinc_plant_r9`)

#### 结构化内容效果

- **铅**（`good`）：`good.lead` → `production_access` `unlock` `1.0`；`existing_binding`
- **钢材**（`good`）：`good.steel` → `production_access` `unlock` `1.0`；`existing_binding`
- **炼铜厂**（`building`）：`building.copper_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **炼锡厂**（`building`）：`building.tin_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 核能 (`tech.nuclear_energy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，核能直接使用这一能力完成其工艺或组织设计
- 特种合金 (`tech.specialty_alloys`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，特种合金直接使用这一能力完成其工艺或组织设计
- 核燃料循环 (`tech.nuclear_fuel_cycle`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，核燃料循环直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，半导体制造直接使用这一能力完成其工艺或组织设计
- 机器人制造 (`tech.robotic_manufacturing`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，机器人制造直接使用这一能力完成其工艺或组织设计
- 自主采矿 (`tech.autonomous_mining`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，自主采矿直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 全部路线 | 能源 · 核能 (\`route.energy.nuclear\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 实验科学 (`tech.experimental_science`)：实验科学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核裂变直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

解锁物资：核燃料；解锁物资：反应堆部件；解锁建筑：核燃料厂；解锁建筑：核医学制药中心

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
- **核医学制药中心**（`building`）：`building.nuclear_medicine_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 核能 (`tech.nuclear_energy`)：核裂变提供发电、电机、电网与能源控制能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，国家实验室直接使用这一能力完成其工艺或组织设计
- 公共教育 (`tech.public_education`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，国家实验室直接使用这一能力完成其工艺或组织设计
- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国家实验室直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：国家实验室；知识部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 国家实验室 (`national_laboratory`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **国家实验室**（`building`）：`building.national_laboratory` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 核能 (`tech.nuclear_energy`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 核燃料循环 (`tech.nuclear_fuel_cycle`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核燃料循环直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，数字计算直接使用这一能力完成其工艺或组织设计
- 知识经济 (`tech.knowledge_economy`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，知识经济直接使用这一能力完成其工艺或组织设计
- 机器学习 (`tech.machine_learning`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机器学习直接使用这一能力完成其工艺或组织设计

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

- 地质勘探 (`tech.geological_prospecting`)：地质勘探提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计
- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计
- 矿井排水 (`tech.mine_drainage`)：矿井排水提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，深层地球物理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「流域治理突破」（breakthrough.watershed\_management）

#### 效果摘要

解锁物资：铝土矿；解锁建筑：铝土矿；解锁建筑：炼铅厂；可利用资源：铝土矿

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
- **炼铅厂**（`building`）：`building.lead_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **铝土矿**（`resource`）：`resource.bauxite` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 卫星观测 (`tech.satellite_observation`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，卫星观测直接使用这一能力完成其工艺或组织设计
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计
- 水文遥感 (`tech.hydrological_remote_sensing`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，水文遥感直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | backbone |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | backbone.institutions\_exchange |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，运筹学直接使用这一能力完成其工艺或组织设计
- 工业统计 (`tech.industrial_statistics`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，运筹学直接使用这一能力完成其工艺或组织设计
- 工业组织 (`tech.industrial_organization`)：工业组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，运筹学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

工业研究实验室产出 +50%；社会领域研究效率 +15%

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

- 工业研究实验室：`country.output.building.industrial_research_laboratory_factor`：+50%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 系统工程 (`tech.systems_engineering`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，系统工程直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，平台协调直接使用这一能力完成其工艺或组织设计
- 算法治理 (`tech.algorithmic_governance`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，算法治理直接使用这一能力完成其工艺或组织设计
- 算法管理 (`tech.algorithmic_management`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，算法管理直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 石油化工 (`tech.petrochemical_industry`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.petrochemical_industry` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.petroleum\_materials |
| 主要路线 | 资源 · 石油 (\`route.resource.oil\`) |
| 全部路线 | 资源 · 石油 (\`route.resource.oil\`)；材料 · 合成材料 (\`route.material.materials\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 石油开采 (`tech.petroleum_extraction`)：石油开采提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计
- 石油炼制 (`tech.petroleum_refining`)：石油炼制提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计
- 电化学 (`tech.electrochemistry`)：电化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石油化工直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「石油」（resource.oil）

#### 效果摘要

解锁物资：石化产品；解锁建筑：石油化工厂；解锁建筑：智能石油化工厂；解锁物资：洗涤剂；解锁建筑：洗涤剂厂；解锁建筑：智能化洗涤剂厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 洗涤剂 (`detergent`)；石化产品 (`petrochemicals`)
- **建筑 / 生产方式：** 洗涤剂厂 (`detergent_plant`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；石油化工厂 (`petrochemicals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 现代炸药厂 (`method_explosives_plant_r8`)

#### 结构化内容效果

- **石化产品**（`good`）：`good.petrochemicals` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **石油化工厂**（`building`）：`building.petrochemicals_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能石油化工厂**（`building`）：`building.method_petrochemicals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **洗涤剂**（`good`）：`good.detergent` → `production_access` `unlock` `1.0`；`catalog_rebind`
- **洗涤剂厂**（`building`）：`building.detergent_plant` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **智能化洗涤剂厂**（`building`）：`building.method_detergent_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 合成材料 (`tech.synthetic_materials`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计
- 石化裂解 (`tech.petrochemical_cracking`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计
- 塑料工程 (`tech.plastics_engineering`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，塑料工程直接使用这一能力完成其工艺或组织设计
- 合成纤维工程 (`tech.synthetic_fiber_engineering`)：石油化工稳定供应合成纤维所需单体与中间体

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计
- 石油化工 (`tech.petrochemical_industry`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计
- 天然橡胶加工 (`tech.rubber_working`)：天然橡胶加工提供热带作物栽培、采收与商品化处理能力中的操作与材料处理方法，合成材料直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：混凝土；解锁物资：合成橡胶；解锁建筑：混凝土厂；解锁建筑：合成橡胶厂

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
- **合成橡胶厂**（`building`）：`building.synthetic_rubber_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 机械化采矿 (`tech.mechanized_mining`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.mechanized_mining` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
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

- 工业采煤 (`tech.industrial_coal_mining`)：工业采煤提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，机械化采矿直接使用这一能力完成其工艺或组织设计
- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机械化采矿直接使用这一能力完成其工艺或组织设计
- 内燃机 (`tech.internal_combustion`)：内燃机提供油气开采、炼制与高分子原料能力中的动力与规模化能力，机械化采矿直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「矿井支护突破」（breakthrough.mine\_support）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

解锁建筑：锰矿；解锁建筑：智能锰矿；解锁建筑：现代硝石矿；解锁建筑：现代硫矿；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 锰矿 (`manganese_ore_collector`)；智能锰矿 (`method_manganese_ore_collector_r10`)；现代硝石矿 (`method_saltpeter_collector_r8`)；现代硫矿 (`method_sulfur_collector_r8`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化磷矿 (`method_phosphate_rock_collector_r9`)；自动化锌矿 (`method_zinc_ore_collector_r9`)

#### 结构化内容效果

- **锰矿**（`building`）：`building.manganese_ore_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能锰矿**（`building`）：`building.method_manganese_ore_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **现代硝石矿**（`building`）：`building.method_saltpeter_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **现代硫矿**（`building`）：`building.method_sulfur_collector_r8` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 自主采矿 (`tech.autonomous_mining`)：机械化采矿提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，自主采矿直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 公共卫生体系 (`tech.public_health_systems`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.public_health_systems` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 2720000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.public\_health |
| 主要路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 全部路线 | 制度 · 卫生 (\`route.institution.health\`) |
| 开局能力标签 | 无 |
| 效果配置 | health |

#### 硬前置（决定研发资格）

- 公共卫生 (`tech.public_health`)：公共卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计
- 现代医学 (`tech.modern_medicine`)：现代医学提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计
- 城市卫生 (`tech.urban_sanitation`)：城市卫生提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，公共卫生体系直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「香料作物」（bio.spice）
  - 已发现信号「橡胶树」（bio.rubber）
  - 已发现信号「香料样本接触」（contact.spice）

#### 效果摘要

化学工业产出 +28%

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

- 化学工业：`country.output.family.chemical_industry_factor`：+28%

#### 被以下科技作为硬前置

- 工业生态 (`tech.industrial_ecology`)：公共卫生体系提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 核裂变 (`tech.nuclear_fission`)：核裂变提供发电、电机、电网与能源控制能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，核能直接使用这一能力完成其工艺或组织设计
- 电网 (`tech.electric_grid`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，核能直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计
- 工业质量控制 (`tech.industrial_quality_control`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，核能直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

解锁建筑：核电站；解锁建筑：核反应堆设备厂；能源部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 核电站 (`nuclear_power_plant`)；核反应堆设备厂 (`reactor_component_works`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化核反应堆设备厂 (`method_reactor_component_works_r10`)

#### 结构化内容效果

- **核电站**（`building`）：`building.nuclear_power_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **核反应堆设备厂**（`building`）：`building.reactor_component_works` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

- 核燃料循环 (`tech.nuclear_fuel_cycle`)：核能提供发电、电机、电网与能源控制能力中的动力与规模化能力，核燃料循环直接使用这一能力完成其工艺或组织设计

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

- 电气化 (`tech.electrification`)：电气化提供发电、电机、电网与能源控制能力中的动力与规模化能力，电子控制直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，电子控制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：电池；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 电池 (`batteries`)
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化润滑油厂 (`method_lubricants_plant_r9`)；精密工具厂 (`method_precision_tool_workshop_r8`)；精密仪器厂 (`method_scientific_instrument_works_r8`)

#### 结构化内容效果

- **电池**（`good`）：`good.batteries` → `production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 系统工程 (`tech.systems_engineering`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，系统工程直接使用这一能力完成其工艺或组织设计
- 精准农业 (`tech.precision_agriculture`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，精准农业直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，数字计算直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，半导体制造直接使用这一能力完成其工艺或组织设计
- 卫星观测 (`tech.satellite_observation`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，卫星观测直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，数字控制直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，传感器网络直接使用这一能力完成其工艺或组织设计
- 机器人制造 (`tech.robotic_manufacturing`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计

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

- 商业网络 (`tech.mercantile_networks`)：商业网络提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，全球物流直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 至少满足 2 项：
  - 已完成科技「铁路物流」（tech.rail\_logistics）
  - 已完成科技「电信」（tech.telecommunications）
  - 已完成科技「远洋航海」（tech.oceanic\_navigation）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

海运作业产出 +28%；贸易速度 +12%

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

- 海运作业：`country.output.family.maritime_operations_factor`：+28%
- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 公司农业 (`tech.corporate_agribusiness`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，公司农业直接使用这一能力完成其工艺或组织设计
- 自动化物流 (`tech.automated_logistics`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，自动化物流直接使用这一能力完成其工艺或组织设计
- 数字市场 (`tech.digital_marketplaces`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，数字市场直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

- 数字市场 (`tech.digital_marketplaces`)：全球物流网络为数字市场的跨区域履约提供实体运输能力

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

- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，特种合金直接使用这一能力完成其工艺或组织设计
- 工业质量控制 (`tech.industrial_quality_control`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，特种合金直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「铜矿」（resource.copper\_ore）
  - 已发现信号「金属加工突破」（breakthrough.metalworking）

#### 效果摘要

解锁物资：铝；解锁物资：不锈钢；解锁建筑：电解铝厂；解锁建筑：不锈钢厂；采掘部门产出 +12%

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
- **不锈钢厂**（`building`）：`building.stainless_steel_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

无

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

- 石油化工 (`tech.petrochemical_industry`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计
- 热力学 (`tech.thermodynamics`)：热力学提供记录、验证、计算与知识传播方法中的操作与材料处理方法，石化裂解直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「磷矿石」（resource.phosphate\_rock）

#### 效果摘要

解锁物资：天然气；解锁建筑：智能天然气田；解锁建筑：天然气田；可利用资源：天然气；制造部门产出 +12%

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
- **天然气田**（`building`）：`building.natural_gas_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **天然气**（`resource`）：`resource.natural_gas` → `local_resource_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

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

- 石油化工 (`tech.petrochemical_industry`)：石油化工提供油气开采、炼制与高分子原料能力中的操作与材料处理方法，塑料工程直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，塑料工程直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁物资：塑料；解锁建筑：智能化塑料厂；解锁建筑：塑料厂

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
- **塑料厂**（`building`）：`building.plastics_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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

- 公司管理 (`tech.corporate_management`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，公司农业直接使用这一能力完成其工艺或组织设计
- 工业农学 (`tech.industrial_agronomy`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，公司农业直接使用这一能力完成其工艺或组织设计
- 全球物流 (`tech.global_logistics`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，公司农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

精准农场产出 +50%

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

- 精准农场：`country.output.building.precision_farm_factor`：+50%

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

- 官僚行政 (`tech.state_bureaucracy`)：官僚行政提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计
- 工厂制 (`tech.factory_system`)：工厂制提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计
- 合作社组织 (`tech.cooperative_association`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，国营企业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

燃煤发电厂产出 +50%；寒冷损失 -8%

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

- 燃煤发电厂：`country.output.building.electricity_plant_factor`：+50%
- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 集体农业 (`tech.collective_agriculture`)：国营企业提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，集体农业直接使用这一能力完成其工艺或组织设计

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

- 国营企业 (`tech.state_enterprises`)：国营企业提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，集体农业直接使用这一能力完成其工艺或组织设计
- 工业农学 (`tech.industrial_agronomy`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，集体农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「电气化突破」（breakthrough.electrification）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

机械化农场产出 +50%

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

- 机械化农场：`country.output.building.mechanized_farm_factor`：+50%

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

- 核能 (`tech.nuclear_energy`)：核能提供发电、电机、电网与能源控制能力中的动力与规模化能力，核燃料循环直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，核燃料循环直接使用这一能力完成其工艺或组织设计
- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，核燃料循环直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，核燃料循环直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「天然气」（resource.natural\_gas）
  - 已发现信号「煤炭」（resource.coal）

#### 效果摘要

解锁建筑：智能化核燃料厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能化核燃料厂**（`building`）：`building.method_nuclear_fuel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.textile\_fibers |
| 主要路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 全部路线 | 工艺 · 纺织 (\`route.craft.textiles\`) |
| 开局能力标签 | 无 |
| 效果配置 | chemistry |

#### 硬前置（决定研发资格）

- 工业化学 (`tech.industrial_chemistry`)：工业化学提供聚合、溶剂、温度和纯度控制，是合成纤维成形的反应基础
- 石油化工 (`tech.petrochemical_industry`)：石油化工稳定供应合成纤维所需单体与中间体
- 纺织机械 (`tech.textile_machinery`)：纺织机械提供纺丝后的牵伸、卷绕和织造设备，使材料能够进入规模化纺织生产

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「石油」（resource.oil）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

解锁物资：合成纤维；解锁建筑：合成纤维厂；解锁建筑：合成纤维织造厂

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
- **合成纤维织造厂**（`building`）：`building.synthetic_textile_mill` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 工业生态 (`tech.industrial_ecology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.industrial_ecology` |
| 时代 | 原子时代 (`atomic`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 2400000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | backbone |
| 节点角色 | handling |
| 布局路线 | branch.industrial\_chemistry |
| 主要路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 全部路线 | 制度 · 规划 (\`route.institution.planning\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 工业化学 (`tech.industrial_chemistry`)：工业化学提供反应控制、配方、分离与化工质量标准中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计
- 公共卫生体系 (`tech.public_health_systems`)：公共卫生体系提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计
- 工业统计 (`tech.industrial_statistics`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，工业生态直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

解锁物资：润滑剂；解锁建筑：润滑油厂；解锁建筑：自动化润滑油厂；农业部门产出 +15%

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
- **自动化润滑油厂**（`building`）：`building.method_lubricants_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 运筹学 (`tech.operations_research`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，系统工程直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，系统工程直接使用这一能力完成其工艺或组织设计
- 工业统计 (`tech.industrial_statistics`)：工业统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，系统工程直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁物资：战略矿物材料；解锁物资：战略矿石；解锁建筑：战略金属冶炼厂

#### 机会成本

转入该路线需补齐历史锚点；时代 9 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 战略矿物材料 (`rare_earth_metals`)；战略矿石 (`rare_earth_ore`)
- **建筑 / 生产方式：** 战略金属冶炼厂 (`rare_earth_metals_plant`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)

#### 结构化内容效果

- **战略矿物材料**（`good`）：`good.rare_earth_metals` → `production_access` `unlock` `1.0`；`existing_binding`
- **战略矿石**（`good`）：`good.rare_earth_ore` → `production_access` `unlock` `1.0`；`existing_binding`
- **战略金属冶炼厂**（`building`）：`building.rare_earth_metals_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

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

国家实验室产出 +50%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 工业农学 (`tech.industrial_agronomy`)
- 电子控制 (`tech.electronic_control`)
- 国家实验室 (`tech.national_laboratories`)
- 国营企业 (`tech.state_enterprises`)
- 公司农业 (`tech.corporate_agribusiness`)
- 核能 (`tech.nuclear_energy`)
- 深层地球物理 (`tech.deep_geophysics`)
- 全球物流 (`tech.global_logistics`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 国家实验室：`country.output.building.national_laboratory_factor`：+50%
- `country.research.society_efficiency`：+15%

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
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.maize\_horticulture |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 工业农学 (`tech.industrial_agronomy`)：工业农学提供玉米栽培、选育与田间管理经验中的成套生产流程，精准农业直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，精准农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：数字化农业机械厂；解锁建筑：精准农场；解锁建筑：高地精准块茎农业

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 数字化农业机械厂 (`method_agricultural_machinery_plant_r9`)；高地精准块茎农业 (`method_highland_precision_agriculture`)；精准农场 (`precision_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

- **数字化农业机械厂**（`building`）：`building.method_agricultural_machinery_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **精准农场**（`building`）：`building.precision_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **高地精准块茎农业**（`building`）：`building.method_highland_precision_agriculture` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 作物遥感 (`tech.crop_remote_sensing`)：精准农业提供玉米栽培、选育与田间管理经验中的成套生产流程，作物遥感直接使用这一能力完成其工艺或组织设计
- 自动化农业 (`tech.automated_agriculture`)：精准农业提供玉米栽培、选育与田间管理经验中的成套生产流程，自动化农业直接使用这一能力完成其工艺或组织设计

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

- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，数字计算直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，数字计算直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：计算机；解锁建筑：计算机厂；解锁建筑：早期计算机工场；知识部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 计算机 (`computers`)
- **建筑 / 生产方式：** 计算机厂 (`computers_plant`)；早期计算机工场 (`digital_computer_workshop`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 早期半导体厂 (`basic_semiconductor_fab`)；地理空间分析中心 (`geospatial_analysis_center`)

#### 结构化内容效果

- **计算机**（`good`）：`good.computers` → `production_access` `unlock` `1.0`；`existing_binding`
- **计算机厂**（`building`）：`building.computers_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **早期计算机工场**（`building`）：`building.digital_computer_workshop` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 信息论 (`tech.information_theory`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，信息论直接使用这一能力完成其工艺或组织设计
- 软件工程 (`tech.software_engineering`)：数字计算提供可编程处理器、存储与执行模型，软件工程必须以此作为实现对象
- 网络计算 (`tech.networked_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，网络计算直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，半导体制造直接使用这一能力完成其工艺或组织设计
- 数值天气预报 (`tech.numerical_weather_prediction`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，数值天气预报直接使用这一能力完成其工艺或组织设计
- 地理信息系统 (`tech.geographic_information_systems`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，地理信息系统直接使用这一能力完成其工艺或组织设计
- 生物信息学 (`tech.bioinformatics`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，生物信息学直接使用这一能力完成其工艺或组织设计
- 机器学习 (`tech.machine_learning`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器学习直接使用这一能力完成其工艺或组织设计
- 自主系统 (`tech.autonomous_systems`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主系统直接使用这一能力完成其工艺或组织设计
- 计算生物学 (`tech.computational_biology`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，计算生物学直接使用这一能力完成其工艺或组织设计
- 气候建模 (`tech.climate_modeling`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，气候建模直接使用这一能力完成其工艺或组织设计
- 算法治理 (`tech.algorithmic_governance`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，算法治理直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | handling |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | research |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，信息论直接使用这一能力完成其工艺或组织设计
- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，信息论直接使用这一能力完成其工艺或组织设计
- 电信 (`tech.telecommunications`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，信息论直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

提供后续科技与内容的知识基础

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

无

#### 被以下科技作为硬前置

- 软件工程 (`tech.software_engineering`)：信息论提供编码、复杂度与可靠传输的形式化基础，使软件接口和数据处理可以被系统设计
- 智能电网 (`tech.smart_grid`)：信息论提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能电网直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 公共教育 (`tech.public_education`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，知识经济直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，知识经济直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

计算研究中心产出 +50%；社会领域研究效率 +15%

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

- 计算研究中心：`country.output.building.computing_research_center_factor`：+50%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

- 人机共治 (`tech.human_machine_cogovernance`)：知识经济提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，人机共治直接使用这一能力完成其工艺或组织设计
- 知识合作社 (`tech.knowledge_cooperatives`)：知识经济提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，知识合作社直接使用这一能力完成其工艺或组织设计

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 数字计算 (`tech.digital_computing`)：数字计算提供可编程处理器、存储与执行模型，软件工程必须以此作为实现对象
- 信息论 (`tech.information_theory`)：信息论提供编码、复杂度与可靠传输的形式化基础，使软件接口和数据处理可以被系统设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：计算研究中心

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 计算研究中心 (`computing_research_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **计算研究中心**（`building`）：`building.computing_research_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 网络计算 (`tech.networked_computing`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，网络计算直接使用这一能力完成其工艺或组织设计
- 神经网络 (`tech.neural_networks`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，神经网络直接使用这一能力完成其工艺或组织设计
- 智能科学代理 (`tech.scientific_agents`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能科学代理直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

- 网络计算 (`tech.networked_computing`)：可靠的软件模块、接口和测试方法是网络化计算服务的同主题后继

#### 跨领域应用

- 数字控制 (`tech.digital_control`)：数字控制需要经过测试的软件模块承载控制逻辑
- 平台协调 (`tech.platform_coordination`)：平台协调依赖可维护的软件服务、接口与数据契约

#### 作为候选参与的里程碑

无

### 网络计算 (`tech.networked_computing`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.networked_computing` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 软件工程 (`tech.software_engineering`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，网络计算直接使用这一能力完成其工艺或组织设计
- 电信 (`tech.telecommunications`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，网络计算直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，网络计算直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁物资：通信设备；解锁建筑：通信设备厂；制造部门产出 +12%

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

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 开放科学网络 (`tech.open_science_networks`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，开放科学网络直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，平台协调直接使用这一能力完成其工艺或组织设计
- 数字市场 (`tech.digital_marketplaces`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，数字市场直接使用这一能力完成其工艺或组织设计
- 分布式智能 (`tech.distributed_intelligence`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，分布式智能直接使用这一能力完成其工艺或组织设计
- 算法管理 (`tech.algorithmic_management`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，算法管理直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，半导体制造直接使用这一能力完成其工艺或组织设计
- 电磁感应 (`tech.electromagnetic_induction`)：电磁感应提供发电、电机、电网与能源控制能力中的操作与材料处理方法，半导体制造直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，半导体制造直接使用这一能力完成其工艺或组织设计
- 工业质量控制 (`tech.industrial_quality_control`)：工业质量控制提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，半导体制造直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，半导体制造直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「能源控制突破」（breakthrough.energy\_control）

#### 效果摘要

解锁物资：先进芯片；解锁物资：半导体；解锁建筑：早期半导体厂；解锁建筑：半导体厂；采掘部门产出 +12%

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
- **半导体厂**（`building`）：`building.semiconductors_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 传感器网络 (`tech.sensor_networks`)：半导体制造提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，传感器网络直接使用这一能力完成其工艺或组织设计
- 分布式智能 (`tech.distributed_intelligence`)：半导体制造提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，分布式智能直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

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
| 锚点类型 | era\_candidate |
| 节点角色 | handling |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 全部路线 | 制度 · 测绘 (\`route.institution.survey\`) |
| 开局能力标签 | 无 |
| 效果配置 | observation |

#### 硬前置（决定研发资格）

- 电信 (`tech.telecommunications`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，卫星观测直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，卫星观测直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，卫星观测直接使用这一能力完成其工艺或组织设计
- 深层地球物理 (`tech.deep_geophysics`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，卫星观测直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「气候建模突破」（breakthrough.climate\_modeling）

#### 效果摘要

解锁建筑：森林遥感经营站

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)

#### 结构化内容效果

- **森林遥感经营站**（`building`）：`building.method_forest_remote_sensing` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计
- 数值天气预报 (`tech.numerical_weather_prediction`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，数值天气预报直接使用这一能力完成其工艺或组织设计
- 作物遥感 (`tech.crop_remote_sensing`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，作物遥感直接使用这一能力完成其工艺或组织设计
- 水文遥感 (`tech.hydrological_remote_sensing`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，水文遥感直接使用这一能力完成其工艺或组织设计
- 气候建模 (`tech.climate_modeling`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

- 气候建模 (`tech.climate_modeling`)：卫星观测为气候模型提供连续的大尺度边界与校验数据

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 自动化物流 (`tech.automated_logistics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.automated_logistics` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 全球物流 (`tech.global_logistics`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，自动化物流直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「自动化突破」（breakthrough.automation）
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）

#### 效果摘要

解锁建筑：自动化港口船舶中心；贸易速度 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化港口船舶中心 (`method_automated_port`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自动化港口船舶中心**（`building`）：`building.method_automated_port` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

- 自主物流 (`tech.autonomous_logistics`)：自动化物流提供船舶、导航、港口与运输组织能力中的动力与规模化能力，自主物流直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 生物技术 (`tech.biotechnology`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.biotechnology` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
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

- 科学分类 (`tech.scientific_classification`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计
- 现代医学 (`tech.modern_medicine`)：现代医学提供卫生、疾病控制与医疗组织能力中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计
- 工业研究 (`tech.industrial_research`)：工业研究提供记录、验证、计算与知识传播方法中的操作与材料处理方法，生物技术直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

寒冷损失 -8%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 高地精准块茎农业 (`method_highland_precision_agriculture`)；专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.climate.cold_stress_factor`：+8%

#### 被以下科技作为硬前置

- 生物信息学 (`tech.bioinformatics`)：生物技术提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物信息学直接使用这一能力完成其工艺或组织设计
- 计算生物学 (`tech.computational_biology`)：生物技术提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 卫星观测 (`tech.satellite_observation`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计
- 深层地球物理 (`tech.deep_geophysics`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计
- 精密仪器 (`tech.precision_instruments`)：精密仪器提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，矿物光谱遥感直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「铁矿」（resource.iron\_ore）
  - 已发现信号「煤炭」（resource.coal）
  - 已发现信号「矿井支护突破」（breakthrough.mine\_support）

#### 效果摘要

解锁建筑：自动化铝土矿；解锁建筑：战略矿山；可利用资源：稀土；可利用资源：锰矿；解锁建筑：自动化锌矿；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化铝土矿 (`method_bauxite_collector_r9`)；自动化锌矿 (`method_zinc_ore_collector_r9`)；战略矿山 (`rare_earth_collector`)
- **自然资源：** 稀土 (`rare_earth`)；锰矿 (`manganese_ore`)
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化铅矿 (`method_lead_ore_collector_r9`)；自动化炼铅厂 (`method_lead_plant_r9`)；智能锰矿 (`method_manganese_ore_collector_r10`)；智能天然气田 (`method_natural_gas_collector_r10`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；自动化炼锌厂 (`method_zinc_plant_r9`)

#### 结构化内容效果

- **自动化铝土矿**（`building`）：`building.method_bauxite_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **战略矿山**（`building`）：`building.rare_earth_collector` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **稀土**（`resource`）：`resource.rare_earth` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **锰矿**（`resource`）：`resource.manganese_ore` → `local_resource_access` `unlock` `1.0`；`existing_binding`
- **自动化锌矿**（`building`）：`building.method_zinc_ore_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 自主采矿 (`tech.autonomous_mining`)：矿物光谱遥感提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，自主采矿直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 数值天气预报 (`tech.numerical_weather_prediction`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.numerical_weather_prediction` |
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

- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，数值天气预报直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，数值天气预报直接使用这一能力完成其工艺或组织设计
- 卫星观测 (`tech.satellite_observation`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，数值天气预报直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「气候建模突破」（breakthrough.climate\_modeling）

#### 效果摘要

国家实验室产出 +50%

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

- 国家实验室：`country.output.building.national_laboratory_factor`：+50%

#### 被以下科技作为硬前置

- 气候建模 (`tech.climate_modeling`)：数值天气预报提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，数字控制直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自动化焦化厂；解锁建筑：自动化机械零件厂；解锁建筑：自动化炼铅厂；解锁建筑：自动化炼锌厂；解锁建筑：自动化磷矿；解锁建筑：自动化混凝土厂；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化焦化厂 (`method_coke_ovens_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)；自动化炼铅厂 (`method_lead_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；自动化磷矿 (`method_phosphate_rock_collector_r9`)；自动化炼锌厂 (`method_zinc_plant_r9`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；自动化港口船舶中心 (`method_automated_port`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化电池厂 (`method_batteries_plant_r10`)；自动化水泥厂 (`method_cement_plant_r9`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；自动化润滑油厂 (`method_lubricants_plant_r9`)；自动化机械零件厂 (`method_machine_parts_plant_r9`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；智能战略矿山 (`method_rare_earth_collector_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；自动化蒸汽机厂 (`method_steam_engine_works_r9`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)；智能化线材厂 (`method_wire_plant_r10`)

#### 结构化内容效果

- **自动化焦化厂**（`building`）：`building.method_coke_ovens_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自动化机械零件厂**（`building`）：`building.method_machine_parts_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自动化炼铅厂**（`building`）：`building.method_lead_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自动化炼锌厂**（`building`）：`building.method_zinc_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自动化磷矿**（`building`）：`building.method_phosphate_rock_collector_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`
- **自动化混凝土厂**（`building`）：`building.method_concrete_plant_r9` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 精准灌溉 (`tech.precision_irrigation`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，精准灌溉直接使用这一能力完成其工艺或组织设计
- 自动化农业 (`tech.automated_agriculture`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自动化农业直接使用这一能力完成其工艺或组织设计
- 自主系统 (`tech.autonomous_systems`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主系统直接使用这一能力完成其工艺或组织设计
- 机器人制造 (`tech.robotic_manufacturing`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计
- 智能电网 (`tech.smart_grid`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计
- 人机共治 (`tech.human_machine_cogovernance`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，人机共治直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

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

- 卫星观测 (`tech.satellite_observation`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，作物遥感直接使用这一能力完成其工艺或组织设计
- 精准农业 (`tech.precision_agriculture`)：精准农业提供玉米栽培、选育与田间管理经验中的成套生产流程，作物遥感直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「气候建模突破」（breakthrough.climate\_modeling）

#### 效果摘要

精准农场产出 +50%

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

- 精准农场：`country.output.building.precision_farm_factor`：+50%

#### 被以下科技作为硬前置

- 气候建模 (`tech.climate_modeling`)：作物遥感提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计

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

- 卫星观测 (`tech.satellite_observation`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，水文遥感直接使用这一能力完成其工艺或组织设计
- 深层地球物理 (`tech.deep_geophysics`)：深层地球物理提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，水文遥感直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

解锁建筑：流域治理中心

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 流域治理中心 (`watershed_governance_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **流域治理中心**（`building`）：`building.watershed_governance_center` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 网络计算 (`tech.networked_computing`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，开放科学网络直接使用这一能力完成其工艺或组织设计
- 公共教育 (`tech.public_education`)：公共教育提供制度协调、公共组织与交换规则中的操作与材料处理方法，开放科学网络直接使用这一能力完成其工艺或组织设计
- 学术社团 (`tech.learned_societies`)：学术社团提供观察、分类、实验与生物育种知识中的操作与材料处理方法，开放科学网络直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「印刷突破」（breakthrough.printing）

#### 效果摘要

提供后续科技与内容的知识基础

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

- 智能科学代理 (`tech.scientific_agents`)：开放科学网络提供制度协调、公共组织与交换规则中的操作与材料处理方法，智能科学代理直接使用这一能力完成其工艺或组织设计
- 知识合作社 (`tech.knowledge_cooperatives`)：开放科学网络提供制度协调、公共组织与交换规则中的操作与材料处理方法，知识合作社直接使用这一能力完成其工艺或组织设计

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

- 网络计算 (`tech.networked_computing`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，平台协调直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，平台协调直接使用这一能力完成其工艺或组织设计
- 公司管理 (`tech.corporate_management`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，平台协调直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

计算研究中心产出 +50%；农业部门产出 +15%

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

- 计算研究中心：`country.output.building.computing_research_center_factor`：+50%
- `country.output.agriculture_factor`：+15%

#### 被以下科技作为硬前置

- 人机协作 (`tech.human_machine_collaboration`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，人机协作直接使用这一能力完成其工艺或组织设计
- 智能电网 (`tech.smart_grid`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，智能电网直接使用这一能力完成其工艺或组织设计
- 算法治理 (`tech.algorithmic_governance`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，算法治理直接使用这一能力完成其工艺或组织设计

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

- 网络计算 (`tech.networked_computing`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，数字市场直接使用这一能力完成其工艺或组织设计
- 市场制度 (`tech.market_institutions`)：市场制度提供市场、会计、金融与商业网络组织能力中的稳定的组织与制度载体，数字市场直接使用这一能力完成其工艺或组织设计
- 全球物流 (`tech.global_logistics`)：全球物流提供船舶、导航、港口与运输组织能力中的稳定的组织与制度载体，数字市场直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

计算机厂产出 +35%

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

- 计算机厂：`country.output.building.computers_plant_factor`：+35%

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.geoscience\_gis |
| 主要路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 全部路线 | 制度 · 计算 (\`route.institution.computing\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 地图学 (`tech.cartography`)：地图学提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，地理信息系统直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，地理信息系统直接使用这一能力完成其工艺或组织设计
- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，地理信息系统直接使用这一能力完成其工艺或组织设计

#### 额外研发条件

- 满足其一：
  - 已完成科技「卫星观测」（tech.satellite\_observation）
  - 已完成科技「水文遥感」（tech.hydrological\_remote\_sensing）
  - 已完成科技「矿物光谱遥感」（tech.mineral\_spectral\_survey）

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：地理空间分析中心

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 地理空间分析中心 (`geospatial_analysis_center`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 森林遥感经营站 (`method_forest_remote_sensing`)；高地精准块茎农业 (`method_highland_precision_agriculture`)；流域治理中心 (`watershed_governance_center`)

#### 结构化内容效果

- **地理空间分析中心**（`building`）：`building.geospatial_analysis_center` → `construction_and_production_access` `unlock` `1.0`；`new_content`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

- 精准灌溉 (`tech.precision_irrigation`)：地理信息系统提供制图、地质、遥感与空间分析能力中的动力与规模化能力，精准灌溉直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

- 精准农业 (`tech.precision_agriculture`)：GIS 把地块、作物与传感数据转化为差异化农艺决策
- 精准灌溉 (`tech.precision_irrigation`)：GIS 为分区供水和管网调度提供空间数据模型
- 自主采矿 (`tech.autonomous_mining`)：GIS 为矿区设备路径、矿体边界和作业区约束提供空间底图

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
| 锚点类型 | era\_candidate |
| 节点角色 | production\_system |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 全部路线 | 作物 · 精准 (\`route.crop.precision\`) |
| 开局能力标签 | 无 |
| 效果配置 | crop |

#### 硬前置（决定研发资格）

- 水利工程 (`tech.hydraulic_engineering`)：水利工程提供水流、风力、输配水和流域工程能力中的成套生产流程，精准灌溉直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，精准灌溉直接使用这一能力完成其工艺或组织设计
- 地理信息系统 (`tech.geographic_information_systems`)：地理信息系统提供制图、地质、遥感与空间分析能力中的动力与规模化能力，精准灌溉直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

金属工具业产出 +28%

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

- 金属工具业：`country.output.family.metal_toolmaking_factor`：+28%

#### 被以下科技作为硬前置

- 自适应灌溉 (`tech.adaptive_irrigation`)：精准灌溉提供水田整备、水位控制与稻作管理方法中的成套生产流程，自适应灌溉直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

- 信息社会 (`tech.information_society`)

### 传感器网络 (`tech.sensor_networks`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.sensor_networks` |
| 时代 | 信息时代 (`information`) |
| 领域 | 工程 (`engineering`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，传感器网络直接使用这一能力完成其工艺或组织设计
- 电信 (`tech.telecommunications`)：电信提供数字计算、软件、网络与自动控制能力中的稳定的组织与制度载体，传感器网络直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：半导体制造提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，传感器网络直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「电气化突破」（breakthrough.electrification）

#### 效果摘要

采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 10 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自动化水泥厂 (`method_cement_plant_r9`)；自动化焦化厂 (`method_coke_ovens_r9`)；自动化混凝土厂 (`method_concrete_plant_r9`)；数字化工业机械厂 (`method_industrial_machinery_plant_r9`)；自动化炼铅厂 (`method_lead_plant_r9`)；智能牧业站 (`method_smart_husbandry`)；自动化炼锌厂 (`method_zinc_plant_r9`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

- 自主采矿 (`tech.autonomous_mining`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主采矿直接使用这一能力完成其工艺或组织设计
- 智能电网 (`tech.smart_grid`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计
- 分布式智能 (`tech.distributed_intelligence`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，分布式智能直接使用这一能力完成其工艺或组织设计
- 自主劳动协调 (`tech.autonomous_labor_coordination`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主劳动协调直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 生物信息学 (`tech.bioinformatics`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.bioinformatics` |
| 时代 | 信息时代 (`information`) |
| 领域 | 科学 (`science`) |
| 研究成本 | 6120000 科技点（`technology_points`） |
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

- 生物技术 (`tech.biotechnology`)：生物技术提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物信息学直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，生物信息学直接使用这一能力完成其工艺或组织设计
- 科学分类 (`tech.scientific_classification`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，生物信息学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

计算研究中心产出 +50%

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

- 计算研究中心：`country.output.building.computing_research_center_factor`：+50%

#### 被以下科技作为硬前置

- 计算生物学 (`tech.computational_biology`)：生物信息学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计
- 智能育种 (`tech.intelligent_breeding`)：生物信息学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，智能育种直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

计算研究中心产出 +50%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 精准农业 (`tech.precision_agriculture`)
- 数字控制 (`tech.digital_control`)
- 数字计算 (`tech.digital_computing`)
- 知识经济 (`tech.knowledge_economy`)
- 精准灌溉 (`tech.precision_irrigation`)
- 半导体制造 (`tech.semiconductor_manufacturing`)
- 卫星观测 (`tech.satellite_observation`)
- 平台协调 (`tech.platform_coordination`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 计算研究中心：`country.output.building.computing_research_center_factor`：+50%
- `country.research.society_efficiency`：+15%

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

共 21 项科技，研究成本范围 12000000-20000000；时代里程碑：认知自动化 (`tech.cognitive_automation`)。

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

- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器学习直接使用这一能力完成其工艺或组织设计
- 国家实验室 (`tech.national_laboratories`)：国家实验室提供记录、验证、计算与知识传播方法中的操作与材料处理方法，机器学习直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：高端芯片厂；解锁建筑：智能研究院；知识部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 高端芯片厂 (`advanced_chip_fab`)；智能研究院 (`machine_intelligence_institute`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)

#### 结构化内容效果

- **高端芯片厂**（`building`）：`building.advanced_chip_fab` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能研究院**（`building`）：`building.machine_intelligence_institute` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.knowledge_factor`：+15%

#### 被以下科技作为硬前置

- 神经网络 (`tech.neural_networks`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，神经网络直接使用这一能力完成其工艺或组织设计
- 人机协作 (`tech.human_machine_collaboration`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，人机协作直接使用这一能力完成其工艺或组织设计
- 智能育种 (`tech.intelligent_breeding`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能育种直接使用这一能力完成其工艺或组织设计
- 智能科学代理 (`tech.scientific_agents`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能科学代理直接使用这一能力完成其工艺或组织设计
- 算法管理 (`tech.algorithmic_management`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，算法管理直接使用这一能力完成其工艺或组织设计

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

- 精准农业 (`tech.precision_agriculture`)：精准农业提供玉米栽培、选育与田间管理经验中的成套生产流程，自动化农业直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自动化农业直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁建筑：自动化农场；农业部门产出 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自动化农场 (`automated_farm`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 专用商品作物种植园 (`method_specialty_commodity_plantation`)

#### 结构化内容效果

- **自动化农场**（`building`）：`building.automated_farm` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.agriculture_factor`：+15%

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

- 机器学习 (`tech.machine_learning`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，神经网络直接使用这一能力完成其工艺或组织设计
- 软件工程 (`tech.software_engineering`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，神经网络直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

智能研究院产出 +50%；制造部门产出 +12%

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

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+50%
- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 人机协作 (`tech.human_machine_collaboration`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.human_machine_collaboration` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 劳工组织 (`tech.labor_organization`)：劳工组织提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，人机协作直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，人机协作直接使用这一能力完成其工艺或组织设计
- 机器学习 (`tech.machine_learning`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，人机协作直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：智能化家用电器厂；解锁建筑：智能工具厂

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能工具厂 (`method_precision_tool_workshop_r10`)

#### 结构化内容效果

- **智能化家用电器厂**（`building`）：`building.method_household_appliances_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能工具厂**（`building`）：`building.method_precision_tool_workshop_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主系统直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主系统直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

解锁物资：自主系统；解锁建筑：自主控制系统厂；解锁建筑：自主林业经营站；工程领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 内容解锁

- **物资：** 自主系统 (`autonomous_systems`)
- **建筑 / 生产方式：** 自主控制系统厂 (`autonomous_systems_plant`)；自主林业经营站 (`method_autonomous_forestry`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能牧业站 (`method_smart_husbandry`)；智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **自主系统**（`good`）：`good.autonomous_systems` → `production_access` `unlock` `1.0`；`existing_binding`
- **自主控制系统厂**（`building`）：`building.autonomous_systems_plant` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **自主林业经营站**（`building`）：`building.method_autonomous_forestry` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.research.engineering_efficiency`：+15%

#### 被以下科技作为硬前置

- 机器人制造 (`tech.robotic_manufacturing`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计
- 自主采矿 (`tech.autonomous_mining`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主采矿直接使用这一能力完成其工艺或组织设计
- 自主劳动协调 (`tech.autonomous_labor_coordination`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主劳动协调直接使用这一能力完成其工艺或组织设计

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

- 机床 (`tech.machine_tools`)：机床提供工具制造、机械加工与设备控制能力中的操作与材料处理方法，机器人制造直接使用这一能力完成其工艺或组织设计
- 电子控制 (`tech.electronic_control`)：电子控制提供工具制造、机械加工与设备控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计
- 自主系统 (`tech.autonomous_systems`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，机器人制造直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，机器人制造直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）
  - 已发现信号「流水线组织突破」（breakthrough.assembly\_line）

#### 效果摘要

解锁建筑：智能化汽车厂；解锁建筑：智能化发动机厂；解锁建筑：智能化合成纤维厂；解锁建筑：智能化合成橡胶厂；解锁建筑：智能冶铝厂；解锁建筑：智能化不锈钢厂；解锁建筑：智能化核反应堆设备厂；解锁建筑：智能战略金属冶炼厂

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能化电池厂 (`method_batteries_plant_r10`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化电子元件厂 (`method_electronic_components_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能化核燃料厂 (`method_nuclear_fuel_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能工具厂 (`method_precision_tool_workshop_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能仪器厂 (`method_scientific_instrument_works_r10`)；智能化线材厂 (`method_wire_plant_r10`)

#### 结构化内容效果

- **智能化汽车厂**（`building`）：`building.method_automobiles_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化发动机厂**（`building`）：`building.method_engines_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化合成纤维厂**（`building`）：`building.method_synthetic_fiber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化合成橡胶厂**（`building`）：`building.method_synthetic_rubber_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能冶铝厂**（`building`）：`building.method_aluminum_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化不锈钢厂**（`building`）：`building.method_stainless_steel_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化核反应堆设备厂**（`building`）：`building.method_reactor_component_works_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能战略金属冶炼厂**（`building`）：`building.method_rare_earth_metals_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

无

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.heavy\_industry |
| 主要路线 | 资源 · 矿产 (\`route.resource.minerals\`) |
| 全部路线 | 资源 · 矿产 (\`route.resource.minerals\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 机械化采矿 (`tech.mechanized_mining`)：机械化采矿提供矿井、钢铁、蒸汽机械与重型设备能力中的操作与材料处理方法，自主采矿直接使用这一能力完成其工艺或组织设计
- 矿物光谱遥感 (`tech.mineral_spectral_survey`)：矿物光谱遥感提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，自主采矿直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主采矿直接使用这一能力完成其工艺或组织设计
- 自主系统 (`tech.autonomous_systems`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主采矿直接使用这一能力完成其工艺或组织设计
- 先进冶金 (`tech.advanced_metallurgy`)：先进冶金提供矿井、钢铁、蒸汽机械与重型设备能力中的成套生产流程，自主采矿直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「矿井支护突破」（breakthrough.mine\_support）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：智能硝石矿；解锁建筑：智能硫矿；解锁建筑：智能战略矿山；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能战略矿山 (`method_rare_earth_collector_r10`)；智能硝石矿 (`method_saltpeter_collector_r10`)；智能硫矿 (`method_sulfur_collector_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能锰矿 (`method_manganese_ore_collector_r10`)；智能天然气田 (`method_natural_gas_collector_r10`)；智能硝石矿 (`method_saltpeter_collector_r10`)；智能硫矿 (`method_sulfur_collector_r10`)

#### 结构化内容效果

- **智能硝石矿**（`building`）：`building.method_saltpeter_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能硫矿**（`building`）：`building.method_sulfur_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能战略矿山**（`building`）：`building.method_rare_earth_collector_r10` → `construction_and_production_access` `unlock` `1.0`；`catalog_rebind`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 科学分类 (`tech.scientific_classification`)：科学分类提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计
- 生物技术 (`tech.biotechnology`)：生物技术提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计
- 生物信息学 (`tech.bioinformatics`)：生物信息学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，计算生物学直接使用这一能力完成其工艺或组织设计
- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，计算生物学直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「化工过程控制突破」（breakthrough.chemical\_process\_control）

#### 效果摘要

国家实验室产出 +50%

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

- 国家实验室：`country.output.building.national_laboratory_factor`：+50%

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

- 数值天气预报 (`tech.numerical_weather_prediction`)：数值天气预报提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计
- 卫星观测 (`tech.satellite_observation`)：卫星观测提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计
- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，气候建模直接使用这一能力完成其工艺或组织设计
- 概率与统计 (`tech.probability_statistics`)：概率与统计提供测量基准、统计方法与精密仪器能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计
- 作物遥感 (`tech.crop_remote_sensing`)：作物遥感提供制图、地质、遥感与空间分析能力中的操作与材料处理方法，气候建模直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「气候建模突破」（breakthrough.climate\_modeling）

#### 效果摘要

国家实验室产出 +50%

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

- 国家实验室：`country.output.building.national_laboratory_factor`：+50%

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.electric\_intelligent\_energy |
| 主要路线 | 能源 · 电力 (\`route.energy.electric\`) |
| 全部路线 | 能源 · 电力 (\`route.energy.electric\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | energy |

#### 硬前置（决定研发资格）

- 电网 (`tech.electric_grid`)：电网提供发电、电机、电网与能源控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计
- 信息论 (`tech.information_theory`)：信息论提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能电网直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能电网直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，智能电网直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「能源控制突破」（breakthrough.energy\_control）
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）

#### 效果摘要

解锁建筑：智能化电池厂；能源部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电池厂 (`method_batteries_plant_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)；自主航运调度港 (`method_autonomous_shipping`)；智能化电池厂 (`method_batteries_plant_r10`)；智能化电动机厂 (`method_electric_motor_plant_r10`)；智能化绝缘电缆厂 (`method_insulated_cable_plant_r10`)；智能牧业站 (`method_smart_husbandry`)；智能化线材厂 (`method_wire_plant_r10`)；智能水网控制中心 (`smart_water_network`)

#### 结构化内容效果

- **智能化电池厂**（`building`）：`building.method_batteries_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.energy_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 数字计算 (`tech.digital_computing`)：数字计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，算法治理直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，算法治理直接使用这一能力完成其工艺或组织设计
- 平台协调 (`tech.platform_coordination`)：平台协调提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，算法治理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：智能水网控制中心

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能水网控制中心 (`smart_water_network`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **智能水网控制中心**（`building`）：`building.smart_water_network` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

无

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.computation\_control |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 网络计算 (`tech.networked_computing`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，分布式智能直接使用这一能力完成其工艺或组织设计
- 半导体制造 (`tech.semiconductor_manufacturing`)：半导体制造提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，分布式智能直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，分布式智能直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

解锁建筑：智能化电子元件厂；解锁建筑：智能化无线电设备厂；采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 智能化电子元件厂 (`method_electronic_components_plant_r10`)；智能化无线电设备厂 (`method_radio_equipment_works_r10`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)；智能仪器厂 (`method_scientific_instrument_works_r10`)

#### 结构化内容效果

- **智能化电子元件厂**（`building`）：`building.method_electronic_components_plant_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`
- **智能化无线电设备厂**（`building`）：`building.method_radio_equipment_works_r10` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 系统育种 (`tech.crop_breeding`)：系统育种提供观察、分类、实验与生物育种知识中的成套生产流程，智能育种直接使用这一能力完成其工艺或组织设计
- 生物信息学 (`tech.bioinformatics`)：生物信息学提供观察、分类、实验与生物育种知识中的操作与材料处理方法，智能育种直接使用这一能力完成其工艺或组织设计
- 机器学习 (`tech.machine_learning`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能育种直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「玉米选育突破」（breakthrough.maize\_selection）
  - 已发现信号「留种实践突破」（breakthrough.seed\_saving）

#### 效果摘要

精准农场产出 +50%

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

- 精准农场：`country.output.building.precision_farm_factor`：+50%

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.maritime\_logistics |
| 主要路线 | 制度 · 网络 (\`route.institution.network\`) |
| 全部路线 | 制度 · 网络 (\`route.institution.network\`)；人工智能 · 自主系统 (\`route.ai.autonomy\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 自动化物流 (`tech.automated_logistics`)：自动化物流提供船舶、导航、港口与运输组织能力中的动力与规模化能力，自主物流直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「自动化突破」（breakthrough.automation）
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）

#### 效果摘要

解锁建筑：自主航运调度港；贸易速度 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 自主航运调度港 (`method_autonomous_shipping`)
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

- **自主航运调度港**（`building`）：`building.method_autonomous_shipping` → `construction_and_production_access` `unlock` `1.0`；`existing_binding`

#### 永久 Modifier 条款

- `country.trade.speed_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

- 机器学习 (`tech.machine_learning`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，智能科学代理直接使用这一能力完成其工艺或组织设计
- 开放科学网络 (`tech.open_science_networks`)：开放科学网络提供制度协调、公共组织与交换规则中的操作与材料处理方法，智能科学代理直接使用这一能力完成其工艺或组织设计
- 软件工程 (`tech.software_engineering`)：软件工程提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，智能科学代理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

提供后续科技与内容的知识基础

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 自主林业经营站 (`method_autonomous_forestry`)；智能仪器厂 (`method_scientific_instrument_works_r10`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

无

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

- 知识经济 (`tech.knowledge_economy`)：知识经济提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，人机共治直接使用这一能力完成其工艺或组织设计
- 数字控制 (`tech.digital_control`)：数字控制提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，人机共治直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

无

#### 效果摘要

智能研究院产出 +50%；社会领域研究效率 +15%

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

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+50%
- `country.research.society_efficiency`：+15%

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
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 公司管理 (`tech.corporate_management`)：公司管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，算法管理直接使用这一能力完成其工艺或组织设计
- 运筹学 (`tech.operations_research`)：运筹学提供制度协调、公共组织与交换规则中的操作与材料处理方法，算法管理直接使用这一能力完成其工艺或组织设计
- 网络计算 (`tech.networked_computing`)：网络计算提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，算法管理直接使用这一能力完成其工艺或组织设计
- 机器学习 (`tech.machine_learning`)：机器学习提供数字计算、软件、网络与自动控制能力中的操作与材料处理方法，算法管理直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

制造部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化汽车厂 (`method_automobiles_plant_r10`)；智能化洗涤剂厂 (`method_detergent_plant_r10`)；智能化发动机厂 (`method_engines_plant_r10`)；自动化炸药厂 (`method_explosives_plant_r10`)；智能化家用电器厂 (`method_household_appliances_plant_r10`)；智能石油化工厂 (`method_petrochemicals_plant_r10`)；智能化塑料厂 (`method_plastics_plant_r10`)；智能战略金属冶炼厂 (`method_rare_earth_metals_plant_r10`)；智能化核反应堆设备厂 (`method_reactor_component_works_r10`)；智能炼油厂 (`method_refined_fuel_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)；智能化合成纤维厂 (`method_synthetic_fiber_plant_r10`)；智能化合成橡胶厂 (`method_synthetic_rubber_plant_r10`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.output.manufacturing_factor`：+12%

#### 被以下科技作为硬前置

- 自主劳动协调 (`tech.autonomous_labor_coordination`)：算法管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，自主劳动协调直接使用这一能力完成其工艺或组织设计

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自适应灌溉 (`tech.adaptive_irrigation`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.adaptive_irrigation` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 农业 (`agriculture`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | power\_scale |
| 布局路线 | branch.rice\_irrigation |
| 主要路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 全部路线 | 作物 · 自动化 (\`route.crop.automated\`) |
| 开局能力标签 | 无 |
| 效果配置 | automation |

#### 硬前置（决定研发资格）

- 精准灌溉 (`tech.precision_irrigation`)：精准灌溉提供水田整备、水位控制与稻作管理方法中的成套生产流程，自适应灌溉直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「河湖水系」（landform.freshwater\_access）
  - 已发现信号「河谷」（landform.river\_valley）
  - 已发现信号「水利工程突破」（breakthrough.hydraulic\_engineering）

#### 效果摘要

公共营造产出 +28%

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

- 公共营造：`country.output.family.construction_methods_factor`：+28%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 知识合作社 (`tech.knowledge_cooperatives`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.knowledge_cooperatives` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 全部路线 | 制度 · 知识 (\`route.institution.knowledge\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 开放科学网络 (`tech.open_science_networks`)：开放科学网络提供制度协调、公共组织与交换规则中的操作与材料处理方法，知识合作社直接使用这一能力完成其工艺或组织设计
- 合作社组织 (`tech.cooperative_association`)：合作社组织提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，知识合作社直接使用这一能力完成其工艺或组织设计
- 知识经济 (`tech.knowledge_economy`)：知识经济提供制度协调、公共组织与交换规则中的稳定的组织与制度载体，知识合作社直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「自动化突破」（breakthrough.automation）

#### 效果摘要

智能研究院产出 +50%

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

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+50%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

### 自主劳动协调 (`tech.autonomous_labor_coordination`)

| 字段 | 内容 |
| --- | --- |
| 稳定 ID | `tech.autonomous_labor_coordination` |
| 时代 | 智能时代 (`intelligent`) |
| 领域 | 社会 (`society`) |
| 研究成本 | 13600000 科技点（`technology_points`） |
| 节点标记 | 无 |
| 网络角色 | branch |
| 锚点类型 | branch |
| 节点角色 | institution |
| 布局路线 | branch.labor\_management |
| 主要路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 全部路线 | 人工智能 · 人机协作 (\`route.ai.collaboration\`) |
| 开局能力标签 | 无 |
| 效果配置 | organization |

#### 硬前置（决定研发资格）

- 算法管理 (`tech.algorithmic_management`)：算法管理提供岗位分工、工厂组织与管理决策能力中的稳定的组织与制度载体，自主劳动协调直接使用这一能力完成其工艺或组织设计
- 传感器网络 (`tech.sensor_networks`)：传感器网络提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主劳动协调直接使用这一能力完成其工艺或组织设计
- 自主系统 (`tech.autonomous_systems`)：自主系统提供数字计算、软件、网络与自动控制能力中的动力与规模化能力，自主劳动协调直接使用这一能力完成其工艺或组织设计

#### 发现启发（仅用于揭示）

- 满足其一：
  - 已发现信号「数字控制突破」（breakthrough.digital\_control）
  - 已发现信号「工业组织突破」（breakthrough.industrial\_organization）

#### 效果摘要

采掘部门产出 +12%

#### 机会成本

转入该路线需补齐历史锚点；时代 11 后的生产方式依赖专用资本、岗位或地理条件

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 智能冶铝厂 (`method_aluminum_plant_r10`)；智能化不锈钢厂 (`method_stainless_steel_plant_r10`)

#### 结构化内容效果

无

#### 永久 Modifier 条款

- `country.output.extractive_factor`：+12%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无

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

无

#### 发现启发（仅用于揭示）

无

#### 效果摘要

智能研究院产出 +50%；社会领域研究效率 +15%

#### 机会成本

占用通用研究预算，延后同代专业路线锚点

#### 里程碑候选

需要完成下列 8 项候选中的任意 4 项：
- 自动化农业 (`tech.automated_agriculture`)
- 自主系统 (`tech.autonomous_systems`)
- 机器学习 (`tech.machine_learning`)
- 人机共治 (`tech.human_machine_cogovernance`)
- 智能育种 (`tech.intelligent_breeding`)
- 机器人制造 (`tech.robotic_manufacturing`)
- 气候建模 (`tech.climate_modeling`)
- 算法治理 (`tech.algorithmic_governance`)

#### 内容解锁

- **物资：** 无
- **建筑 / 生产方式：** 无
- **自然资源：** 无
- **作为 ALL 支撑条件参与的建筑 / 生产方式：** 无

#### 结构化内容效果

无

#### 永久 Modifier 条款

- 智能研究院：`country.output.building.machine_intelligence_institute_factor`：+50%
- `country.research.society_efficiency`：+15%

#### 被以下科技作为硬前置

无

#### 主题路线后继

无

#### 跨领域应用

无

#### 作为候选参与的里程碑

无
