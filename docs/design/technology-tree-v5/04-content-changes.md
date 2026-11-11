# 科技树 v5 设计方案 · 第四部分：内容增删改（建筑 / 物资 / 产业链 / 职业 / 兵种）

> 本部分是配套内容清单。所有条目都注明：**归属科技、归属产业链、由谁生产、由谁消费、实现状态**。
> 实现状态用 `runtime_status` 词汇：`existing_binding` / `catalog_rebind` / `new_content` / `modifier_only` / `blocked` / `new_runtime`。

---

## 1. P0 · 必须先修的数据错误（不改设计，只改数据）

这些是"解锁了但造不出来 / 产出了但没人要"的硬错，**必须在加内容之前修**，否则新内容会叠在坏地基上。

| # | 对象 | 现状 | 修正 | 落点 | 状态 |
|---|---|---|---|---|---|
| 1 | `engines_plant`（电气） | 必需输入 `aluminum`（原子代才有）→ **汽车链在电气代根本启动不了**，`automobiles_plant` 又依赖 `engines`，传递闭包确认 2 座建筑本代不可运行 | `aluminum` → `steel`；铝留给 `method_engines_plant_r10` | `input_good_ids[1]` | `catalog_rebind` |
| 2 | 7 座建筑建材槽 | `early_iron_mine` / `gold_mine` / `silver_mine` / `cement_plant` / `improved_smallholding` / `learned_society` / `silica_sand_collector` 的建材槽写 `structural_metal`，而该类别成员（steel/aluminum/stainless）全在蒸汽之后 → **造水泥的厂要先有钢** | 建材槽 `structural_metal` → `ferrous_stock`（含王国代 `wrought_iron`） | `construction_category_ids` | `catalog_rebind` |
| 3 | `cottage_weaving` / `improved_domestic_loom` | **`input_good_ids = []`，凭空造布** | 补纤维输入（类别槽 `natural_spinnable_fiber`） | `input_good_ids` + `input_category_ids` | `catalog_rebind` |
| 4 | `leather_goods_manufactory` | 输入 `industrial_chemicals`（蒸汽代才有） | → `lime` | `input_good_ids[2]` | `catalog_rebind` |
| 5 | `method_marine_fish_collector_r2` | 输入 `natural_rubber`（探索代） | → `bast_fiber` | `input_good_ids[1]` | `catalog_rebind` |
| 6 | `machine_parts_plant` | 输入 `lubricants`（电气代） | → `coke` | `input_good_ids[1]` | `catalog_rebind` |
| 7 | `horses` | `technology_tags` 里没有 `tech.animal_traction` | 补 | `GoodProfile.technology_tags` | `catalog_rebind` |
| 8 | `hide_armor` | 未绑 `tech.hide_tanning` | 补 | 同上 | `catalog_rebind` |
| 9 | `bronze_spearmen`（兵种） | `tech` 错绑 `tech.hide_tanning`（鞣皮造青铜矛兵） | → `tech.military.bronze_host` | `military_catalog.json units[].tech` | `catalog_rebind` |
| 10 | `mechanized_infantry` / `sp_artillery` | 装备槽 `mounts`（马匹） | → `armored_vehicles` | `units[].equipment[]` | `catalog_rebind` |
| 11 | `nitric_acid_plant` / `smokeless_powder_works` | `progression_step` 倒挂（5 晚于 6） | 交换 | `BuildingProfile.progression_step` | `catalog_rebind` |
| 12 | `potato_collector` | step 4（农耕）早于 step 3（王国） | → step 2 | 同上 | `catalog_rebind` |
| 13 | `bark_paper_workshop` / `plant_fiber_paper_workshop` / `parchment_workshop` | step 序错 | 改 1/2/3 | 同上 | `catalog_rebind` |
| 14 | `learned_society` / `industrial_research_laboratory` | `upgrade_tier` 6↔7 导致"tier 越大时代越早" | 对调 | `upgrade_tier` | `catalog_rebind` |
| 15 | `cloth` | `category_id = rag_paper_fiber`（把布当造纸原料类别） | → `textile` | `GoodProfile.category_id` | `catalog_rebind` |
| 16 | `bauxite` | `category_id = bauxite`（矿石自成一类） | → `metal_ore` | 同上 | `catalog_rebind` |
| 17 | 9 个 `industry.*` 标签 | 混在 `technology_tags` 里（`computing_research_center` 等 3 座建筑） | 迁到 `semantic_tags`，`technology_tags` 只留 `tech.*` | `BuildingProfile` / `GoodProfile` | `catalog_rebind` |
| 18 | `research_institution` 家族 tier 序 | 电气 tier 6 早于启蒙 tier 7 | 重排为家族内 1..n | `upgrade_tier` | `catalog_rebind` |
| 19 | `development.trade.partners_8` | 默认局总国家数 = 6，永远达不到 8 | 全局替换为 `partners_4`（污染 2 个 reveal + 1 条 route） | `technology_network.json` | `catalog_rebind` |
| 20 | `weather.heatwave` / `prolonged_wet_season` / `freeze_thaw` | 无发布规则 → **涉 11 个节点的条件永不成立** | 在 `weather_research_signal_publisher.gd` 补 rule 分支（枚举已存在，约 10 行） | `scripts/research/weather_research_signal_publisher.gd` | **`blocked`（需代码修复）** |
| 21 | `contact.bast_fiber` | `economy_runtime_trade.cpp:1758` 的 `bast_fiber‖flax_fiber → rule 5` 把 rule 10 完全吃掉 | 分离 rule 号 | `gdext/src/economy_runtime_trade.cpp` | **`blocked`（1 行）** |
| 22 | 9 个军事 stat | 无消费路径（见诊断 6.3），18/35 条军事 term 空转 | `attack/defense` 必须**同时**接进 `sum_lot_value` 与 `refresh_army_cache` | `gdext/src/military_core_war.cpp:147–165`、`military_core.cpp:1350–1384` | **`blocked`（bug fix）** |
| 23 | `local_defence()` | 只按 `era_index` 过滤，不查 `unlock_bit` → 任何高防御新兵种自动成为**所有国家**的城防 | 补 `unlocked()` 检查 | `military_core_war.cpp:186–203` | **`blocked`** |

---

## 2. 新增物资（13 种）

| # | ID | 名称 | 类别 / 品质 | 生产者建筑 | 消费者 | 归属科技 | 归属链 | 状态 |
|---|---|---|---|---|---|---|---|---|
| 1 | `silk_fiber` | 生丝 | `spinnable_fiber` q3 | `sericulture_shed`（王国） | `textile_mill` / `cloth_plant` / `household_loom` 的 `natural_spinnable_fiber` 类别槽（**零配方改动**） | `tech.sericulture`（新） | `textile_fibers` | `new_content` |
| 2 | `wood_tar` | 木焦油 | `industrial_chemicals` q2 | `wood_chemical_works`（启蒙） | `shipyard`（防水）、`industrial_chemistry` 系列的候选输入 | `tech.timber_chemical_industry`（新） | `chemical_industry` step 2 | `new_content` |
| 3 | `sugar` | 糖 | `luxury` q2 | `sugar_mill`（探索） | `refinery` → `beverages` / `processed_food`；家户 `luxury` 需求 | `tech.plantation_processing`（新） | `tropical_commodities` | `new_content` |
| 4 | `canned_food` | 罐头 | `processed_food` q2 | `cannery`（蒸汽） | 家户 `staple_food`；军队 `supply.ration` 候选 | `tech.industrial_food_preservation`（新） | `cold_chain` step 2 | `new_content` |
| 5 | `dyestuff` | 染料 | `dye` q1 | `dye_works`（蒸汽） | `textile_mill` / `cloth_plant` / `guild_weaving_house` 的**可选**槽（`input_required_q16 = 0`，类别 `dye`） | `tech.textile_manufacture`（新，或挂既有 `industrial_chemistry`） | `chemical_industry` step 2 | `new_content` |
| 6 | `refrigerated_food` | 冷藏食品 | `processed_food` q3 | `cold_storage`（电气） | 家户 `protein` / `staple_food` 变体；`processed_food_plant` | `tech.cold_chain_industry`（新） | `cold_chain` step 3 | `new_content` |
| 7 | `panel_wood` | 人造板 | `industrial_construction` q2 | `plywood_mill`（电气） | 电气及之后建筑的建材类别槽 | `tech.forest_products_industry`（新） | `forest_biomass` | `new_content` |
| 8 | `structural_steel` | 型钢 | `structural_metal` q2 | `steel_rolling_mill`（蒸汽） | **修复 `structural_metal` 类别缺前工业成员的问题**；蒸汽后建筑的建材槽 | `tech.structural_steel`（新） | `construction_materials` | `new_content` |
| 9 | `ammonia` | 氨 | `industrial_chemicals` q3 | `ammonia_plant`（原子） | `fertilizer_plant` **新增必需输入**（把磷肥厂变成真化肥厂）+ `explosives_plant` | `tech.ammonia_synthesis`（新） | `chemical_industry` step 3 | `new_content` |
| 10 | `antibiotics` | 抗生素 | `pharmaceuticals` q2 | `antibiotics_plant`（原子） | 家户 `healthcare` 需求；军队 `supply` | `tech.antibiotics_mass_production`（新） | `public_health` | `new_content` |
| 11 | `aircraft` | 飞机 | `aircraft` q2 | `aircraft_factory`（原子） | `equipment_categories.aircraft` → 兵种 `air_wing` | `tech.military.aviation`（新） | `military.vehicles` step 5 | `new_content` |
| 12 | `composite_material` | 复合材料 | `industrial_construction` q3 | `materials_recovery_plant`（智能） | 智能时代建筑建材槽；`aircraft_factory` 候选输入 | `tech.circular_materials`（新） | `construction_materials` | `new_content` |
| 13 | `synthetic_fuel` | 合成燃料 | `fuel` q3 | `carbon_capture_plant`（智能） | `refined_fuel` 的候选输入；火力发电 | `tech.carbon_capture_and_synthesis`（新） | `petroleum_materials` | `new_content` |

**每代新增物资曲线（改造后）**：

```
29 / 19 / 27 / 14 / 9 / 6+1 / 17+1 / 20+1 / 24+2 / 5+1 / 4+2
```

→ 启蒙/信息/智能仍偏低。**这是可接受的**：真正的"新物质感"缺口在**建材**（见 B5 规则），已由 `structural_steel` / `panel_wood` / `composite_material` 修掉"蒸汽后 4 代 0 新建材"。
把 G4 规则从"每代 ≥10 新物资"改为"**每代 ≥6 新物资，且每 2 代至少 1 种新建材**"更符合实际。

---

## 3. 新增建筑（26 座）

| # | ID | 名称 | 时代 | 归属科技 | 产业链 | 关键字段 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | `stone_quarry` | 采石场 | agrarian | `tech.stone_quarrying` | `production.stone` | 产 `raw_stone`；条件 `landform ∈ {hill, mountain}` | `new_content` |
| 2 | `terrace_farm` | 梯田农场 | kingdom | `tech.terrace_farming` | `field_crop_farming` | 条件 `landform ∈ {hill, mountain, plateau}` 且 `has_river`；profile `highland_crop`（新） | `new_content` |
| 3 | `transhumance_camp` | 转场营地 | agrarian | `tech.pastoral_transhumance` | `livestock` | 消耗 `resource:pasture` 容量；owner `pastoralist` | `new_content` |
| 4 | `bronze_armory` | 青铜兵器坊 | agrarian | `tech.military.bronze_host` | `military.melee` | 产 `bronze_weapons`；`state_buildings` 追加 | `new_content` |
| 5 | `sericulture_shed` | 蚕室 | kingdom | `tech.sericulture` | `textile_fibers` | 产 `silk_fiber` | `new_content` |
| 6 | `tile_kiln` | 砖瓦窑 | kingdom | `tech.brick_and_tile` | `construction_materials` | 产 `bricks` | `new_content` |
| 7 | `harness_workshop` | 挽具作坊 | kingdom | `tech.horse_harness` | `production.tools` | 产 `tools` | `new_content` |
| 8 | `shield_workshop` | 盾甲坊 | kingdom | `tech.military.shield_wall` | `military.armor` | 产 `iron_armor` | `new_content` |
| 9 | `blast_furnace_works` | 高炉厂 | kingdom | `tech.blast_furnace` | `steelmaking` | 输入 `iron_ore`+`coke` → `wrought_iron` | `new_content` |
| 10 | `mountain_irrigation_works` | 山地灌溉工程 | empire | `tech.mountain_irrigation` | `water_wind` | 条件 `has_river` + `landform ∈ {hill, mountain, plateau}` | `new_content` |
| 11 | `mill_complex` | 磨坊群 | empire | `tech.mill_network` | `staple_preparation` | 输入 `grain`；产 `prepared_staples` | `new_content` |
| 12 | `survey_office` | 测量署 | empire | `tech.land_surveying` | `cadastral_institution` | owner `scribe`；提供地籍税基 | `new_content` |
| 13 | `windmill` | 风车 | empire | `tech.wind_power` | `energy` | 条件 `terrain ∈ {grassland, coast}` | `new_content` |
| 14 | `naraval_shipyard` → `naval_shipyard` | 船坞 | empire | `tech.military.coastal_transport` | `maritime_operations` | 产 `warship`；条件 `terrain = coast` 邻水 | `new_content` |
| 15 | `siege_park` | 攻城纵列 | empire | `tech.military.siege_train` | `military.ordnance` | 产 `siege_engines` | `new_content` |
| 16 | `chart_survey_office` | 海图测绘局 | exploration | `tech.cartography` | `geoscience` | owner `natural_philosopher`；产 `charts`（新物资，可选简化：不新增物资，只给 P 通道） | `new_content` |
| 17 | `sugar_mill` | 糖坊 | exploration | `tech.plantation_processing` | `tropical_commodities` | 产 `sugar`；条件 `terrain ∈ {jungle, savanna}` | `new_content` |
| 18 | `line_infantry_depot` | 线列步兵营 | exploration | `tech.military.line_infantry` | `military` | `state_buildings` role=barracks | `new_content` |
| 19 | `textile_manufactory` | 纺织工场 | enlightenment | `tech.textile_manufacture` | `cloth_weaving` | owner `industrialist`，雇 `industrial_worker` | `new_content` |
| 20 | `wood_chemical_works` | 木材化工厂 | enlightenment | `tech.timber_chemical_industry` | `chemical_industry` | 产 `wood_tar` | `new_content` |
| 21 | `polder_works` | 圩田工程 | enlightenment | `tech.polder_engineering` | `water_wind` | 条件 `terrain ∈ {marsh, swamp}` 或 `landform = delta` | `new_content` |
| 22 | `seed_drill_works` | 条播机坊 | enlightenment | `tech.seed_drill_and_thresher` | `production.tools` | 产 `tools`；`agricultural_worker` 槽位 −25% | `new_content` |
| 23 | `sewer_works` | 下水道工程 | steam | `tech.municipal_sanitation` | `public_health` | 提供 `hygiene` 需求满足 | `new_content` |
| 24 | `cannery` | 罐头厂 | steam | `tech.industrial_food_preservation` | `cold_chain` | 产 `canned_food` | `new_content` |
| 25 | `steel_rolling_mill` | 型钢轧机 | steam | `tech.structural_steel` | `construction_materials` | 产 `structural_steel` | `new_content` |
| 26 | `field_fortification` | 野战筑城 | steam | `tech.military.entrenchment` | `military.fortification` | `state_buildings` role=fortification | `new_content` |

**电气及以后（12 座）**：`fish_farm`（`aquaculture`）、`pulp_mill` / `plywood_mill`（`forest_products_industry`）、`cold_storage`（`cold_chain_industry`）、`servo_works`（`servomechanism`）、`cooperative_workshop`（`worker_cooperatives`，owner `cooperative_member`，**启用 0 引用职业**）、`ammonia_plant`、`antibiotics_plant`、`aircraft_factory`、`container_port`、`desalination_plant`、`robot_cell_works`、`biopolymer_plant`、`precision_medicine_center`、`vertical_farm`、`carbon_capture_plant`、`materials_recovery_plant`、`offshore_fish_farm`、`bioreactor_works`。

---

## 4. 新增职业（4 个）+ 启用闲置职业（3 个）

| # | ID | 名称 | 首现时代 | 归属科技 / 建筑 | 说明 | 状态 |
|---|---|---|---|---|---|---|
| 1 | `agronomist` | 农艺师 | information | `precision_agriculture` → `precision_farm` / `method_*_farm_r8` | 替换部分 `agricultural_worker` 岗位；补"农业技师"缺口 | `new_content` |
| 2 | `ship_officer` | 船政官 | exploration | `oceanic_ship_design` → `oceanic_shipyard` | 与 `merchant` 分工：船政=运力，商人=交易 | `new_content` |
| 3 | `aquaculturist` | 养殖员 | electrical | `aquaculture` → `fish_farm` | — | `new_content` |
| 4 | `dye_worker` | 染工 | steam | `textile_manufacture` → `dye_works` | 可选；若不新增则 `artisan` 兼任 | `new_content` |
| — | `cooperative_member` | 合作社成员 | steam | `worker_cooperatives` → `cooperative_workshop` | **现状全树 0 引用**，由新建筑启用 | `new_content` |
| — | `transport_worker` | 运输工 | steam | `rail_logistics` / `containerization` | **现状全树 0 引用** | `catalog_rebind` |
| — | `unemployed` | 失业者 | — | — | 系统职业，非科技解锁，保持 | `existing_binding` |

---

## 5. 新增兵种（6 个，数据驱动 `new_content`）

| # | ID | 名称 | class | era | 绑定科技 | attack / defense / speed | 装备需求 | 备注 |
|---|---|---|---|---|---|---|---|---|
| 1 | `shield_bearers` | 盾兵 | line | 1 | `tech.military.bronze_host` | 1.4 / 3.0 / 0.9 | `melee_arms` q1 + `armor` q1 | 补 agrarian 空白；def 压在 30 以下（避免 `local_defence` 副作用） |
| 2 | `frigate` | 巡防舰 | line | 4 | `tech.military.coastal_transport` | 2.6 / 2.8 / 2.2 | `naval` q1 | 首个海军单位；装备由 `warship` 支撑 |
| 3 | `ironclad` | 铁甲舰 | line | 6 | `tech.military.naval_transport` | 4.2 / 4.6 / 1.8 | `naval` q2 | 需要 `structural_steel` |
| 4 | `destroyer` | 驱逐舰 | line | 7 | `tech.military.naval_transport` | 5.4 / 4.8 / 3.0 | `naval` q3 | — |
| 5 | `air_wing` | 航空队 | artillery | 8 | `tech.military.aviation` | 6.0 / 3.2 / 4.0 | `aircraft` q1 | 首个空军单位；`fortification_ignore 0.5` |
| 6 | `drone_swarm` | 无人机集群 | artillery | 10 | `tech.military.autonomous_warfare` | 5.0 / 3.0 / 3.5 | `aircraft` q2 + `muntions` q4 | — |

**新增装备类别 2 个**：`naval`（`warship` q1–3）、`aircraft`（`aircraft` q1–2）。
**已存在但孤立的档位**：`war_chariots`（q2 mounts）与 `steel_blades`（q4 melee_arms）无任何兵种设为 `min_quality` → 建议让 `horse_archers` 用 `war_chariots`、`rifle_skirmishers` 用 `steel_blades`。

---

## 6. 新增气候档案（2 个）+ 拆分 `dryland_crop`

| 档案 | 覆盖 | 现状 | 建议 |
|---|---|---|---|
| `dryland_crop` | 49 座建筑（含土豆/玉米/旱稻/棉花/亚麻/高地作物混装） | 独占 **20/38 条**档案修正 | **拆分**：把高地作物迁到 `highland_crop`，把绿洲/灌区作物迁到 `oasis_irrigation` |
| `highland_crop`（新） | 梯田农场、高地块茎、山地灌溉 | 不存在 | 新增；`modifier_catalog.gd:362–374` 会自动生成 8 个新 stat key，`new_content` |
| `oasis_irrigation`（新） | 绿洲/坎儿井/干旱灌区 | 不存在 | 新增 |
| `foraging_plants` / `phenology_observation` | 9 座 / 1 座 | **各 0 条档案修正** | 至少各给 1 条（前者给采集类，后者给观测类） |
| `paddy_crop` / `pasture_livestock` / `plantation_crop` | 13 / 7 / 20 座 | 各只覆盖 2/4 灾害通道 | 补齐 4 个灾害通道 |

**注**：`weather_type` 的 `STORM` / `MONSOON` 不产生任何 hazard 位 → **台风/风暴潮在经济上零损失表达**。若要给它们真实的损失通道，需要给 `production_climate_capacity` 增加第 5/6 通道，属 `new_runtime`，**本方案不做**。

---

## 7. 产业链修复与深化

### 7.1 现状体检

- 165 条链里 **117 条只有 1–2 座建筑**（32 条只有 1 座），**71% 的链太浅**。
- 104 条是"一物资一链"的 `production.*` 命名，与 61 条语义工序链**互斥共存**（建筑只能挂一个 `chain_id`）。
- `category_id` **107/167 是单成员**（64% 等于唯一身份）。
- **维修机制 4/459**：`maintenance_good_ids` 几乎没人用 —— 这是最省力的"需求出口"。

### 7.2 修复清单

| # | 动作 | 对象 | 说明 | 状态 |
|---|---|---|---|---|
| 1 | 挂维修 | 高价值资本品 `oceanic_vessels` / `machine_parts` / `tools` / `electrical_equipment` / `autonomous_systems` / `aircraft` / `warship` | 目标 `maintenance_good_ids` 覆盖从 4/459 → ≥60 | `catalog_rebind` |
| 2 | 合并浅链 | 117 条 1–2 环链标 `progression_role = entry` 并并入更大工序链 | 消除"一物资一链" | `catalog_rebind` |
| 3 | 拆伞形物资 | `industrial_chemicals` 保留为 q2 中间品；`ammonia`(q3)、`dyestuff`(q1) 独立 | 避免继续往伞里塞 | `new_content` |
| 4 | 复制 `charcoal` 模板 | `charcoal` 是全树唯一做对的独占物资：1 个独占生产者 + **17 个下游消费者** | 给 10 条零独占物资的支线各补 1 个"独占生产者 + ≥5 下游" | `new_content` |
| 5 | 补三条整链缺失 | ① 空军（`aircraft` + `aircraft_factory` + `air_wing`）② 海军（`warship` + `naval_shipyard` + 3 兵种）③ 医疗（`antibiotics` + `antibiotics_plant` + `general_hospital`）④ 金融（`financial_services`，`cycle_flow` 物资，挂 `central_banking`） | `storage_mode = cycle_flow` 是**已存在**枚举（当前只有 `electricity` 用它），非新运行时 | `new_content` |
| 6 | 压克隆 | 114 座 `method_*`（信息代 69%、智能代 79% 的新建筑）必须异构化：至少 1 项输入/岗位/放置条件与基底不同 | 现状中位产出 ×7.78，最高 ×522 | `catalog_rebind` |
| 7 | 建材分层 | `structural_metal` 补 `structural_steel`；蒸汽后每 2 代至少 1 种新建材 | 修"4 代 0 新建材" | `new_content` |

---

## 8. 应用交叉点（`app.*`）强化

301 个 `app.*` 是全树唯一的"两线相乘 > 各自相加"机制（91% 跨家族，每个给 1 座不重复建筑）。三个问题：**不可见、不可选、只奖励广度**。

| 动作 | 做法 | 状态 |
|---|---|---|
| 可见化 | 方法建筑加 `semantic_tags += "method.synergy"`；`display_name` 统一加"（协同）"前缀 | `catalog_rebind` |
| 深度化 | 挑 30–40 个 app，把 `required_technology_ids` 改成**同支线 2 个深节点**（从"广度奖励"变"深度奖励"） | `catalog_rebind` |
| 补孤儿 | 178/416 个科技从不参与任何 app；至少让每个里程碑候选参与 1 个 app | `catalog_rebind` |
| 命名 | 199/301 用普通命名，与基底建筑混淆；统一 `method_<chain>_r<tier>` 命名 | `catalog_rebind` |

---

## 9. 出生点差异化（内容侧）

| # | 动作 | 做法 | 状态 |
|---|---|---|---|
| 1 | 起手科技差异化 | `is_starter_eligible` + `starter_capability_tags` 现有 11 个节点、5 种 tag，但**没有任何发放器读取**。建议：按出生点生态发放 2 个"生态起手"（如 `coastal → tide_observation`、`floodplain → flood_calendar_practice`、`arid → pastoral_route_memory`、`tropical → phenology_observation`），其余仍用通用 starter | `new_content`（配置层） |
| 2 | 复用死代码 | `starter_economy_planner.gd:255–278 _preferred_knowledge_for_region()` 已写好按地域选科技，但被 `select_pending_knowledge()` 覆盖为"永远返回通用机构" | **`blocked`（代码修复）** |
| 3 | 资源 top-up 收敛 | `start_location_profile.gd:30–37` 无条件给首都 fertile_soil 350k / timber 300k / wild_game 120k / stone 180k / flint 120k / pasture 160k / gold 15k → **抹平首都生态稀缺性**。建议保留保底但下调 50%，并让 1–2 项按生态不同 | `catalog_rebind` |
| 4 | 出生过滤放宽 | 现状 `temp ∈ [0.24, 0.82]`、`moisture ∈ [0.24, 0.90]` → **苔原与极干旱不能开局**。建议扩到 `temp ∈ [0.12, 0.90]`、`moisture ∈ [0.12, 0.94]`，让"六生态"名副其实 | `catalog_rebind` |

---

## 10. 内容改动汇总

| 类别 | 新增 | 修改 | 删除/合并 |
|---|---|---|---|
| 科技节点 | **46** | ~150 | **5** |
| 物资 | 13 | ~18（配方/类别/质量） | 0 |
| 建筑 | 26（+18 电气后细项） | ~40（配方/条件/岗位） | 0 |
| 产业链 | 3（`cold_chain`/`public_health`/`military.vehicles` 实质化） | ~30 | 0 |
| 职业 | 4 | 3（启用闲置） | 0（建议合并 `researcher`→`scientist`、`household_farmer`→`tenant_farmer`） |
| 兵种 | 6 | 2（装备槽修正）+ 1（重绑） | 0 |
| 装备类别 | 2（`naval` / `aircraft`） | 0 | 0 |
| 气候档案 | 2（`highland_crop` / `oasis_irrigation`） | 4（补灾害通道） | 0 |

**需要代码修复（`blocked`）才能生效的 5 项**：天气信号发布（3 个）、`contact.bast_fiber`、军事攻防 stat 解算、`local_defence` 的 unlock 检查、`_preferred_knowledge_for_region` 复活。