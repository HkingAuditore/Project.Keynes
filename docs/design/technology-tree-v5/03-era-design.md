# 科技树 v5 设计方案 · 第三部分：逐时代完整方案

> 本部分给出**全部 457 个节点**的处理方式：
> **保留**（不改数据）、**改**（给新字段值）、**新**（完整规格）、**删/并**（给理由与承接）。
> 每条效果写成 `<主体> -> <属性> <操作/数值>`，并给实现落点。
> 成本：`minor 0.55U / major 1.00U / breakthrough 1.80U`，每代 U 由该代原总成本反算（见 02 章 §3）。

## 图例

| 标记 | 含义 |
|---|---|
| 【保留】 | 数据不改；仅参与成本分档重算 |
| 【改】 | 给出被替换的 `modifier_terms` / `content_effects` / `reveal_condition` / `hard_prerequisite_ids` |
| 【新】 | 全新节点，给完整规格 |
| 【删】/【并】 | 删除或合并进某节点 |
| 通道 | `U`解锁 `C`构成 `L`岗位 `G`地理 `P`财政 `S`制度 `M`军事 |

---

# 时代 0 · stone 石器时代（56 → **55** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | 无（起始时代） |
| 出口里程碑 | `tech.settled_knowledge`（定居知识） |
| 非里程碑节点 | 55 |
| 推进要求 | **44 个**（⌈0.8×55⌉） |
| 可放弃 | 11 |
| 成本三档 | minor ≈1,800 / major ≈3,200 / breakthrough ≈5,800 |
| 本代问题 | ① 空条件率 48%（27/56）；② 6 个辨识根里 4 个是纯"资源清单"；③ 里程碑候选 4/8 是空条件 → **零证据即可跨代** |

## 本代设计要点

1. **辨识根收敛为 4 个**。现状 6 个（clay / spice / gold_placer / silver_vein / reed / flint）+ `natural_observation` 下挂 11 个作物辨识。合并为：
   - `tech.clay_identification` → **保留**（黏土是建材链与陶器链的起点，值得独立）
   - `tech.flint_identification` → **保留**（燧石=石器工具唯一入口）
   - `tech.gold_placer_identification` / `tech.silver_vein_identification` → **合并为 `tech.precious_metal_identification`**（两者 reveal 同为"贵金属露头"，行为完全同构）
   - `tech.spice_identification` → **保留**，但改为 `contact` 或 `bio.spice` 双重路径（热带专属）
   - `tech.reed_identification` → **删**，并入 `tech.reed_harvesting`
2. **`natural_observation` 不应垄断 11 个作物辨识**。现状它的唯一前置是 `early_knowledge_institution`（观测反被机构前置）。改为：11 个作物辨识（maize / wheat / rice / potato / cotton / flax / medicinal / rubber 等）**作为独立根**，各自用 `bio.*` 信号揭示；`natural_observation` 改挂"观测方法"，给 `country.research.science_efficiency +0.10`（S 通道）。
3. **把"开局恒真"的 5 个信号从 `ANY_OF` 里挪出去**（B 审 4.6）：`wild_game` / `fertile_soil` / `timber` / `gold_ore` / `silver_ore` 在开局恒为真。受影响的 21 个节点必须换条件。
4. **`tech.early_trade` 移出里程碑候选**（0 成本、无前置、免费计票）。

## 节点表

| ID | 名称 | 档 | 通道 | 处理 | 说明 / 变更 |
|---|---|---|---|---|---|
| `tech.hunting` | 狩猎 | minor | U | 【保留】 | 起始；reveal=`resource.wild_game`（起始校验保证，可接受） |
| `tech.gathering` | 采集 | minor | U | 【保留】 | 起始 |
| `tech.deadwood_collection` | 枯枝采集 | minor | U | 【保留】 | 起始 |
| `tech.early_trade` | 早期交换 | minor | P | 【改】 | 移出 stone 里程碑候选；效果补 `country.trade.capacity_factor +0.06`（现状仅解锁物资） |
| `tech.gold_panning` | 淘金 | minor | U | 【改】 | 补 reveal `resource.gold_ore`（现状空 → 恒真） |
| `tech.surface_silver_collection` | 地表银收集 | minor | U | 【改】 | 补 reveal `resource.silver_ore`（**运行时从未发放**，见 G 审） |
| `tech.hide_scraping` | 刮皮 | minor | U | 【保留】 | — |
| `tech.flint_identification` | 燧石辨识 | minor | U | 【保留】 | 根；reveal=`resource.flint` |
| `tech.clay_identification` | 黏土辨识 | minor | U | 【保留】 | 根；reveal=`resource.clay` |
| `tech.spice_identification` | 香料辨识 | minor | U | 【改】 | reveal 改 `ALL_OF(SIGNAL(bio.spice), ANY_OF(SIGNAL(landform.jungle), SIGNAL(contact.spice)))`；给 `country.output.good.spices_factor +0.10` |
| `tech.gold_placer_identification` | 砂金辨识 | — | — | 【并】 | 并入新 `tech.precious_metal_identification` |
| `tech.silver_vein_identification` | 银脉辨识 | — | — | 【并】 | 同上 |
| `tech.precious_metal_identification` | 贵金属辨识 | minor | U | 【新】 | 前置 `[]`；reveal `ANY_OF(SIGNAL(resource.gold_ore), SIGNAL(resource.silver_ore), SIGNAL(contact.ore_sample))`；解锁 `resource:gold_ore`、`resource:silver_ore`；承接原两节点的全部解锁 |
| `tech.reed_identification` | 芦苇辨识 | — | — | 【删】 | 零效果（3,400 点）。并入 `tech.reed_harvesting` |
| `tech.reed_harvesting` | 芦苇收割 | minor | U | 【改】 | 改为**根节点**（前置 `[]`），reveal=`SIGNAL(bio.reed)`；补解锁 `good:reed_bundle`（现状由它解锁建筑但不解锁物资）；给 `country.output.terrain.marsh.extractive_factor +0.15`（G：沼泽） |
| `tech.natural_observation` | 自然观察 | minor | S | 【改】 | 前置 `[]`；reveal 空（通用方法）；`country.research.science_efficiency +0.10`；**不再作为 11 个作物辨识的父节点** |
| `tech.early_knowledge_institution` | 早期知识机构 | minor | U | 【保留】 | 根；解锁首座研究建筑 |
| `tech.oral_memory_practice` | 口述记忆实践 | minor | U | 【保留】 | — |
| `tech.phenology_observation` | 物候观察 | minor | U | 【保留】 | — |
| `tech.tide_observation` | 潮汐观察 | minor | U | 【改】 | 建筑 `tide_observation_hut` 加放置条件 `terrain = coast`（现状内陆可建，见 G 审） |
| `tech.oral_tradition` | 口述传统 | minor | U | 【改】 | 补后继 `→ tech.record_keeping`（现状 agrarian 主干叶子） |
| `tech.seasonal_foraging` | 季节性觅食 | minor | U | 【保留】 | — |
| `tech.food_storage` | 食物储藏 | minor | U | 【改】 | reveal 从 `ANY_OF(fertile_soil, wild_game, freshwater_fish)`（开局恒真）改为 `ANY_OF(SIGNAL(bio.maize), SIGNAL(bio.wheat), SIGNAL(bio.rice), SIGNAL(bio.potato))` |
| `tech.hearth_preservation` | 火塘保存 | minor | U | 【保留】 | — |
| `tech.fire_control` | 火种控制 | minor | U | 【保留】 | 主干 |
| `tech.controlled_burning` | 控制燃烧 | minor | G | 【改】 | **全树唯一净负面节点**。`resource.timber.managed_generation_factor -0.08` → **+0.10**，并补 `country.output.terrain.grassland.extractive_factor +0.12`（烧荒后新生草场） |
| `tech.stone_knapping` | 打制石器 | minor | U | 【保留】 | 根（有 3 前置，其实非根） |
| `tech.ground_stone_tools` | 磨制石器 | minor | U | 【改】 | 把 `building:rubble_stone_working` + `resource:stone` 迁出，交给 `tech.stone_quarrying`（见 agrarian）；本节点只保留工具语义，给 `country.output.family.metal_toolmaking_factor +0.08` |
| `tech.composite_tools` | 复合工具 | major | C | 【改】 | 全局 +0.04 → **`country.production.input_factor -0.06`**（工具减少材料损耗），保留 `bowyer_camp` |
| `tech.hand_pottery` | 手工陶器 | major | U | 【保留】 | 承接 `tech.pottery` 删除后的 clay 相关 support |
| `tech.crop_domestication` | 作物驯化 | major | U | 【保留】 | 里程碑候选 |
| `tech.maize_identification` … `tech.rice_identification` | 8 个作物辨识 | minor | U | 【改】 | **全部改为根**（前置 `[]`），各自 reveal `SIGNAL(bio.<crop>)`；效果统一为「解锁该作物 + `country.output.good.<crop>_grain_factor +0.10`」 |
| `tech.wild_maize_collection` 等 8 个采集 | minor | U | 【保留】 | 前置改为对应辨识节点 |
| `tech.tuber_storage` | 块茎储藏 | minor | G | 【改】 | 全局 +0.08? 现状无 term → 补 `country.climate.cold_stress_factor -0.08`（S/G：窖藏抗寒） |
| `tech.fur_sewing` | 缝皮 | minor | U | 【改】 | reveal 从 `ANY_OF(raw_hide, wild_game)`（恒真）改 `SIGNAL(breakthrough.hide_working)` |
| `tech.hide_tanning`? | — | — | — | — | （在 kingdom，见下） |
| `tech.freshwater_fishing` | 淡水岸捕 | major | G | 【改】 | `country.output.agriculture_factor +0.10` → **`country.output.landform.lake.extractive_factor +0.20` + `country.output.landform.rift_valley.extractive_factor +0.10`** |
| `tech.coastal_fishing` | 潮间带采集 | major | G | 【改】 | `country.output.agriculture_factor +0.10` → **`country.output.terrain.coast.extractive_factor +0.20` + `country.output.terrain.reef.extractive_factor +0.15`**；前置删 `wild_flax_collection`，改 `← tech.tide_observation + tech.ground_stone_tools` |
| `tech.brine_collection` | 卤水采集 | minor | G | 【改】 | 补 `country.output.terrain.salt_flat.extractive_factor +0.18` |
| `tech.earth_building` | 土建筑 | major | U | 【改】 | 前置改为 `[]`（原 `clay_identification` 保留）；补 `country.output.family.construction_methods_factor +0.08` |
| `tech.turf_cutting` | 切草皮 | minor | G | 【改】 | 补 `country.output.terrain.tundra.extractive_factor +0.20` + `country.output.terrain.moor.extractive_factor +0.18` |
| `tech.settled_knowledge` | 定居知识 | breakthrough | — | 【保留】 | 里程碑；全局 +0.04 → **+0.025**（预算：6 里程碑共 +0.15） |
| `tech.military.war_bands` | 战团组织 | minor | M | 【改】 | 迁移至新家族 `branch.military_doctrine`；补 reveal `ANY_OF(SIGNAL(resource.wild_game), SIGNAL(landform.grassland))` |
| `tech.military.ambush_tactics` | 伏击战术 | minor | M | 【改】 | 迁移至 `branch.military_doctrine`；补 reveal `ANY_OF(SIGNAL(landform.forest), SIGNAL(landform.marsh))` |
| `tech.animal_tracking` | 兽迹追踪 | minor | U | 【保留】 | — |
| `tech.animal_husbandry` | 家畜驯养 | major | U | 【改】 | 全局? 现状无 → 补 `country.climate.cold_stress_factor -0.06`（毛皮/乳）|
| 其余 stone 节点 | — | minor | — | 【保留】 | 见 JSON 全表 |

## 本代新增

无（石器时代 56 节点已足够密）。

---

# 时代 1 · agrarian 农耕时代（51 → **55** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.settled_knowledge` |
| 出口里程碑 | `tech.agrarian_society` |
| 非里程碑 | 54 |
| 推进要求 | **44** |
| 可放弃 | 10 |
| 成本三档 | minor ≈3,900 / major ≈7,100 / breakthrough ≈12,800 |
| 本代问题 | ① 空条件 18/51；② 15 个纯百分比节点；③ **军事完全空白**；④ `plough_agriculture` 无 `animal_husbandry`（畜力在犁之后） |

## 本代设计要点

1. **修知识轴**：`plough_agriculture ← animal_husbandry`；链改为 `record_keeping → writing → celestial_calendars`（见 kingdom）。
2. **补军事空白**：新增 `tech.military.bronze_host`（青铜战团），并重绑 `bronze_spearmen`（现状错绑 `tech.hide_tanning`）。
3. **补采石环节**：新增 `tech.stone_quarrying`，承接 `ground_stone_tools` 让出的石料语义，修复 `masonry` 的"无石作祖先"缺环。
4. **补地理绑定**：`irrigation` / `rainfed_field_system` / `terrace_farming` 的前身都要有地形差异。
5. **开局恒真清理**：`food_storage` / `fur_sewing` / `fermentation` / `currency` 等 21 个节点的 `ANY_OF` 去掉 5 个恒真信号。

## 节点表（仅列变更与新增；其余见 JSON 全表）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.stone_quarrying` | 采石与琢石 | major | U+G | 【新】 | 前置 `[tech.ground_stone_tools]`；reveal `ANY_OF(SIGNAL(landform.mountain), SIGNAL(landform.hill), SIGNAL(resource.stone))`；解锁 `resource:stone`、`building:stone_quarry`、`building:rubble_stone_working`；`country.output.family.construction_methods_factor +0.08`；`country.output.landform.hill.extractive_factor +0.12` |
| `tech.masonry` | 砌体 | major | U+G | 【改】 | 前置 `[adobe_making, kiln_firing, stone_quarrying]`（删 `ground_stone_tools`）；`country.output.family.construction_methods_factor +0.10`；`country.construction.cost_factor -0.05` |
| `tech.plough_agriculture` | 犁耕农业 | major | C+G | 【改】 | 前置 `+= tech.animal_husbandry`；`country.output.agriculture_factor +0.18` → **`country.output.terrain.plain.agriculture_factor +0.18` + `country.output.terrain.loess.agriculture_factor`? 用 `terrain.floodplain.agriculture_factor +0.12`**；`country.production.input_factor -0.04` |
| `tech.animal_traction` | 畜力牵引 | major | G | 【改】 | 全局 +0.08 → **`country.output.terrain.plain.agriculture_factor +0.15` + `country.output.terrain.grassland.agriculture_factor +0.15`**（山区无效）；`country.output.family.livestock_husbandry_factor +0.08` |
| `tech.irrigation` | 灌溉 | major | G | 【改】 | `country.output.agriculture_factor +0.14` → **`country.output.terrain.floodplain.agriculture_factor +0.20` + `country.output.terrain.delta.agriculture_factor +0.20` + `country.output.landform.plain.agriculture_factor +0.12`**；吸收 `irrigation_surveying` 的内容 |
| `tech.rainfed_field_system` | 雨养田体系 | major | G | 【改】 | `agriculture_factor +0.12` → **`country.output.terrain.plain.agriculture_factor +0.15` + `country.output.terrain.steppe.agriculture_factor +0.18`**；`country.climate.drought_loss_factor -0.06` |
| `tech.seed_selection` | 留种选育 | breakthrough | C | 【改】 | `agriculture_factor +0.12` → **`country.output.good.grain_factor +0.12` + `country.output.good.wheat_grain_factor +0.10`**；保留 `medicinal_herb_garden` |
| `tech.agrarian_society` | 农耕社会 | breakthrough | — | 【保留】 | 里程碑；`agriculture_factor +0.08` → **+0.02**（里程碑只给象征值，改由 S：`country.population.death_factor -0.04`） |
| `tech.pastoral_transhumance` | 转场放牧 | major | G | 【新】 | 前置 `[tech.animal_husbandry, tech.animal_tracking]`；reveal `ANY_OF(SIGNAL(landform.grassland), SIGNAL(landform.steppe_plain), SIGNAL(resource.pasture))`；解锁 `building:transhumance_camp`（owner `pastoralist`，产 `livestock_products`/`wool`，消耗 `resource:pasture` 容量）；`country.output.family.livestock_husbandry_factor +0.10`；`country.output.landform.plateau.agriculture_factor +0.10`（垂直转场） |
| `tech.bronze_casting` | 青铜铸造 | breakthrough | U | 【保留】 | 里程碑候选 |
| `tech.copper_metallurgy` | 冶铜 | major | U | 【改】 | **吸收 `copper_ore_roasting`**；前置 `[natural_copper_identification, copper_annealing]`；`country.output.family.copper_extraction_factor +0.10` |
| `tech.natural_copper_working` | 自然铜加工 | minor | U | 【保留】 | — |
| `tech.copper_annealing` | 铜退火 | minor | U | 【改】 | 补 reveal `SIGNAL(breakthrough.metalworking)` |
| `tech.crucible_steel` | 坩埚钢 | major | C | 【改】 | 前置 `[iron_smelting, copper_metallurgy]`（删 `pottery`）；`country.output.family.steelmaking_factor +0.10` |
| `tech.writing` | 文字 | breakthrough | S+U | 【改】 | 前置 `[record_keeping]`（删 `celestial_calendars`）；解锁 `building:scribal_school`；`country.tax.income.scribe.rate_bp -200`（简化征管）；`country.research.society_efficiency +0.10` |
| `tech.record_keeping` | 记事制度 | major | U+S | 【改】 | 补后继 `→ writing`；`country.tax.business.<building>.rate_bp`? 用 `country.research.institution_output_factor +0.10` |
| `tech.celestial_calendars` | 天文历法 | major | G | 【改】 | 前置 `[writing]`（方向反转，恢复"文字→历法"） |
| `tech.commodity_money` | 商品货币 | major | P | 【改】 | 前置 `+= tech.record_keeping`（修整代缺环）；`country.trade.capacity_factor +0.08` |
| `tech.market_institutions` | 市场制度 | breakthrough | P | 【改】 | 前置 `[early_trade, commodity_money, record_keeping]`（删 `early_knowledge_institution`）；`country.trade.capacity_factor +0.10`；`country.tax.consumption.<good>.rate_bp +200` |
| `tech.military.bronze_host` | 青铜战团 | major | M+U | 【新】 | 前置 `[tech.bronze_casting, tech.military.war_bands]`；reveal `ALL_OF(SIGNAL(breakthrough.metalworking), ANY_OF(SIGNAL(resource.copper_ore), SIGNAL(resource.tin_ore)))`；解锁 `good:bronze_weapons`、`good:bronze_tools`、`building:bronze_armory`；兵种 `bronze_spearmen`（重绑）+ `shield_bearers`（新）；`country.military.rule.mutual_support 0.10`（密集队形：每支友军 +10% 防御）|
| `tech.sericulture` | 蚕桑 | major | U+G | 【新】 | 前置 `[tech.cotton_gardening, tech.weaving]`；reveal `ALL_OF(SIGNAL(bio.silkworm), ANY_OF(SIGNAL(landform.forest), SIGNAL(contact.silk)))`；解锁 `good:silk_fiber`、`building:sericulture_shed`；`country.output.good.silk_fiber_factor +0.15`；`country.trade.capacity_factor +0.06`（丝路） |
| `tech.fishing_boats` | 渔舟 | major | U | 【改】 | 成本 3,400 → major 档（现状是全代最低价却是海运/风能/近海运兵三线唯一入口） |
| `tech.fermentation` | 发酵 | minor | C | 【改】 | reveal 去掉 `ANY_OF(恒真)`，改 `SIGNAL(breakthrough.kiln_temperature)` |
| `tech.salt_preservation` | 盐渍保存 | minor | G | 【改】 | 补 `country.output.terrain.salt_flat.extractive_factor +0.15` |
| 其余 agrarian 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

## 本代新增小计：4（`stone_quarrying` / `pastoral_transhumance` / `military.bronze_host` / `sericulture`）

---

# 时代 2 · kingdom 王国时代（57 → **56** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.agrarian_society` |
| 出口里程碑 | `tech.kingdom_administration` |
| 非里程碑 | 55 |
| 推进要求 | **44** |
| 可放弃 | 11 |
| 成本三档 | minor ≈11,900 / major ≈21,600 / breakthrough ≈38,900 |
| 本代问题 | ① 代内成本极差 **7.69×**（3,900–30,000）；② 5 处整代缺环（`terrace_farming`/`celestial_calendars`/`market_institutions`/`iron_ore_identification`/`coal_outcrop_identification` 祖先全在石器）；③ 2 个重复节点（`pottery`/`loom_weaving`）；④ 2 个零效果节点 |

## 本代设计要点

1. **删 2 个重复节点**（`pottery` → 并入 `hand_pottery`；`loom_weaving` → 并入 `weaving`），**删 2 个零效果节点**（`copper_ore_roasting` → 并入 `copper_metallurgy`；`irrigation_surveying` → 并入 `irrigation`）。
2. **成本重定价**：王国 4 个"石器价位"节点（`copper_mine_engineering` 3,900 / `copper_ore_roasting` 7,400 / `solar_evaporation` 8,160 / `copper_metallurgy` 9,360）全部抬到 major 档。
3. **修整代缺环**：`terrace_farming` 前置从石器块茎改为农耕 `ridge_tuber_cultivation`；`iron_ore_identification` 补农耕冶铜经验；`coal_outcrop_identification` 用农耕窑炉替代石器机构。
4. **补军事**：新增 `tech.military.shield_wall`（盾墙方阵）+ `tech.military.chariot_warfare` 补 reveal。
5. **补地理**：梯田/高地/旱作三条农业支线首次获得 `terrain/landform` 效果。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.pottery` | 陶器 | — | — | 【删】 | 与 `hand_pottery` 效果重复（同为"营造方法 +12%"）。`clay_pit` support 移交 `hand_pottery` |
| `tech.loom_weaving` | 织机织造 | — | — | 【删】 | 与 `weaving`/`hand_spinning` 重复。`plant_fiber_papermaking ← weaving + writing`；`guild_organization ← market_institutions + weaving` |
| `tech.copper_ore_roasting` | 铜矿焙烧 | — | — | 【删】 | 零效果 + 模板串代。并入 `copper_metallurgy` |
| `tech.irrigation_surveying` | 灌溉测量 | — | — | 【删】 | 零效果。并入 `irrigation`；`flood_recession_maize/wheat ← irrigation + dryland_farming` |
| `tech.terrace_farming` | 梯田农业 | breakthrough | G+U | 【改】 | 前置 `[ridge_tuber_cultivation, ground_stone_tools]`（删 `tuber_storage`）；全局 +0.08 → **`country.output.landform.plateau.agriculture_factor +0.25` + `country.output.landform.hill.agriculture_factor +0.20` + `country.output.terrain.mountain.agriculture_factor +0.15`**；解锁 `building:terrace_farm`（condition: landform ∈ {hill, mountain, plateau}）；route 增加 `geographic_evidence`（见 02 §4.2） |
| `tech.highland_tuber_farming` | 高地块茎农业 | major | G | 【保留】 | 已是全树唯一用 `landform.*` 的节点（plateau 0.32 / mountain 0.24），作为**范本保留** |
| `tech.dryland_farming` | 旱作农业 | major | G | 【改】 | 全局 +0.08 → **`country.output.terrain.steppe.agriculture_factor +0.18` + `country.climate.drought_loss_factor -0.08`** |
| `tech.dryland_water_retention` | 旱作保水 | major | G | 【改】 | 全局 +0.08 → **`country.output.terrain.salt_flat.agriculture_factor +0.15` + `country.output.terrain.cold_desert.agriculture_factor +0.15` + `country.climate.drought_loss_factor -0.10`** |
| `tech.crop_rotation` | 轮作 | breakthrough | C | 【改】 | `agriculture_factor +0.18` → **`country.production.input_factor -0.06` + `country.output.family.field_crop_farming_factor +0.20`**；保留 `composting_yard`（`fertilizer` 起点） |
| `tech.intensive_crop_rotation` | 集约轮作 | breakthrough | C | 【改】 | `agriculture_factor +0.22` → **`country.output.family.field_crop_farming_factor +0.28` + `country.production.input_factor -0.05`**；删除重复的 good unlock（grain/potatoes/vegetables 已在更早节点解锁） |
| `tech.tenant_cereal_farming` | 佃作谷物 | major | L+P | 【改】 | 全局? 现状 `agriculture_factor +0.08` → **`country.tax.income.tenant_farmer.rate_bp +300`（税基扩大）`+ economy.profession.tenant_farmer.tax_tolerance_factor +0.15`**；删除重复 good unlock |
| `tech.communal_field_coordination` | 共同田协调 | major | P+S | 【改】 | 全局 +0.08 → **`country.tax.income.household_farmer.rate_bp -300` + `economy.profession.household_farmer.tax_tolerance_factor +0.15`**（共同田降低征管摩擦） |
| `tech.surface_coal_use` | 地表煤利用 | major | P | 【改】 | 全局 +0.08 → **`country.construction.time_factor -0.08` + `country.input.good.bricks_factor -0.10`**（煤作窑燃料）；补后继 `→ tech.coal_mining` |
| `tech.state_bureaucracy` | 官僚行政 | breakthrough | S+P | 【改】 | 全局 +0.04 → **`country.tax.income.scholar.rate_bp +300` + `country.tax.business.<building>.rate_bp +200`（税基扩大）+ `country.research.society_efficiency +0.10`** |
| `tech.writing`/`record_keeping` | — | — | — | 见 agrarian | — |
| `tech.iron_ore_identification` | 铁矿辨识 | major | U | 【改】 | 前置 `[natural_observation, bronze_casting, stone_knapping]`（删 `early_knowledge_institution`，加农耕冶铜）；reveal 加 `SIGNAL(contact.ore_sample)` |
| `tech.coal_outcrop_identification` | 露头煤辨识 | major | U | 【改】 | 前置 `[fire_control, kiln_firing, stone_knapping]`（用农耕窑炉替代石器机构）；reveal `ANY_OF(SIGNAL(resource.coal), SIGNAL(landform.badlands), SIGNAL(landform.canyon))` |
| `tech.copper_mine_engineering` | 铜矿井开采 | major | G | 【改】 | 前置 `[bronze_casting]`（替代石器）；成本 3,900 → major；`country.output.landform.mountain.extractive_factor +0.15` |
| `tech.solar_evaporation` | 日晒蒸发 | major | G | 【改】 | 成本 8,160 → major；`country.output.terrain.salt_flat.extractive_factor +0.20` + `country.output.terrain.desert.extractive_factor +0.15` |
| `tech.blast_furnace` | 高炉 | breakthrough | U | 【改】 | **里程碑候选但零内容**。补解锁 `building:blast_furnace_works`（产 `wrought_iron`，输入 `iron_ore`+`coke`）；`country.output.family.steelmaking_factor +0.12` |
| `tech.manorial_cereal_farming` | 庄园谷物经营 | major | P+L | 【改】 | `agriculture_factor +0.08` → **`country.tax.income.landlord.rate_bp +400` + `economy.profession.serf.satisfaction_bp -300`**（制度代价：地主税基扩大、农奴不满） |
| `tech.serf_obligations` | 农奴义务 | major | L+P | 【改】 | 全局 +0.08 → **`economy.profession.serf.tax_tolerance_factor +0.20` + `country.tax.income.landlord.rate_bp +300`**（软互斥对 A：庄园制） |
| `tech.serf_obligations` 互斥对 | — | — | — | — | 与 agrarian 的 `household_landholding` / steam 的 `worker_cooperatives` 构成"谁组织生产"三选（T2 岗位竞争：`serf` vs `household_farmer` vs `cooperative_member`） |
| `tech.hide_tanning` | 皮革鞣制 | major | U+C | 【改】 | `manufacturing_factor +0.28` → **`country.output.family.hide_working_factor +0.28`**；补 `good:hide_armor` 的 tag（现状错绑） |
| `tech.early_glassmaking` | 早期玻璃烧制 | major | U+G | 【改】 | `manufacturing_factor +0.25` → **`country.output.family.glassmaking_factor +0.25` + `country.output.terrain.desert.extractive_factor +0.10`**（石英砂） |
| `tech.scholarly_academies` | 古典学院 | major | U | 【保留】 | 研究建筑台阶 |
| `tech.military.shield_wall` | 盾墙方阵 | major | M+U | 【新】 | 前置 `[tech.military.bronze_host, tech.iron_smelting]`；reveal `ALL_OF(SIGNAL(breakthrough.metalworking), SIGNAL(development.buildings.active_4_180d))`；解锁 `good:iron_armor`、`building:shield_workshop`；`country.military.rule.hold_the_line 0.12`（坚守姿态 +12% 防御）；`country.military.defense_factor +0.05` |
| `tech.military.chariot_warfare` | 战车战法 | major | M+U | 【改】 | 补 reveal `ALL_OF(SIGNAL(bio.horse), SIGNAL(breakthrough.metalworking))`；兵种 `war_chariots` 已有；`country.military.rule.blitz 0.10`（战车冲刺）|
| `tech.military.standing_army` | 常备军 | major | M+L | 【改】 | 补 reveal `ANY_OF(SIGNAL(development.population.2500_180d), SIGNAL(development.settlement.tier_3_360d))`；`training_time_factor +0.90` → **+0.20**（数值事故）；`country.military.rule.mutual_support 0.08` |
| `tech.military.earthen_ramparts` | 夯土城垣 | minor | M | 【改】 | 补 reveal `ANY_OF(SIGNAL(resource.clay), SIGNAL(landform.hill))`；`fortification_factor +0.10` → **+0.06** |
| `tech.horse_harness` | 挽具与颈轭 | major | C+L | 【新】 | 前置 `[tech.animal_traction]`；reveal `SIGNAL(breakthrough.metalworking)`；`country.output.terrain.plain.agriculture_factor +0.12`；解锁 `building:harness_workshop`（产 `tools`，替代部分人力）；使 `animal_traction` 不再是叶子 |
| `tech.brick_and_tile` | 砖瓦 | major | U+P | 【新】 | 前置 `[tech.kiln_firing, tech.stone_quarrying]`；reveal `SIGNAL(breakthrough.kiln_temperature)`；解锁 `good:bricks`、`building:tile_kiln`；`country.construction.cost_factor -0.06` + `country.construction.time_factor -0.06` |
| `tech.kingdom_administration` | 王国体系 | breakthrough | — | 【保留】 | 里程碑；全局 +0.04 → **+0.025** |
| 其余 kingdom 节点 | — | — | — | 【保留】 / 成本重定价 | 见 JSON 全表 |

## 本代新增小计：3（`military.shield_wall` / `horse_harness` / `brick_and_tile`）

---

# 时代 3 · empire 帝国时代（43 → **47** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.kingdom_administration` |
| 出口里程碑 | `tech.imperial_integration` |
| 非里程碑 | 46 |
| 推进要求 | **37** |
| 可放弃 | 9 |
| 成本三档 | minor ≈26,200 / major ≈47,600 / breakthrough ≈85,700 |
| 本代问题 | ① `magnetic_navigation`（里程碑候选）零效果；② 25 个节点只给 `economy_output_factor`；③ `branch.tuber_highland` 在此绝后；④ 军事 5 节点全无 reveal |

## 本代设计要点

1. **救活 `magnetic_navigation`**：补内容 + 使用它已存在的 `runtime_capability_tags: [research.observe_visible_foreign]`。
2. **补高地支线延续**：新增 `tech.mountain_irrigation`（帝国），让 `tuber_highland` 不死在第 3 代。
3. **补水利延续**：新增 `tech.mill_network`（磨坊网络），给 `water_wind` 一个中段节点。
4. **补测量链**：新增 `tech.land_surveying`，修复 `cartography` 的整代缺环。
5. **军事**：补 `siegecraft`/`mounted_warfare`/`legion_logistics`/`heavy_cavalry` 的 reveal；新增 `tech.military.siege_train` 拿到合围条令。
6. **`communal_field_coordination` 已在 kingdom 处理。**

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.magnetic_navigation` | 磁针导航 | minor | U+P | 【改】 | **不再零效果**：解锁 `good:compass`（新）、`building:navigation_school`；`country.trade.capacity_factor +0.10` + `country.military.supply_consumption_factor -0.08`；`effect_summary` 明确写「开放对可见外国格的研究观测（runtime capability）」；成本 47,600 → minor 档 |
| `tech.mountain_irrigation` | 山地灌溉 | breakthrough | G+U | 【新】 | 前置 `[tech.highland_tuber_farming, tech.canal_engineering]`；reveal `ALL_OF(SIGNAL(breakthrough.terrace_maintenance), ANY_OF(SIGNAL(landform.plateau), SIGNAL(landform.mountain)))`；解锁 `building:mountain_irrigation_works`（condition: landform ∈ {hill, mountain, plateau} 且 has_river）；`country.output.landform.plateau.agriculture_factor +0.25` + `country.output.landform.mountain.agriculture_factor +0.20` + `country.climate.drought_loss_factor -0.08` |
| `tech.mill_network` | 磨坊网络 | major | U+G | 【新】 | 前置 `[tech.water_power, tech.wind_power]`；reveal `ANY_OF(SIGNAL(landform.freshwater_access), SIGNAL(landform.rift_valley))`；解锁 `building:mill_complex`（产 `prepared_staples`，输入 `grain`+`tools`）；`country.output.family.staple_preparation_factor +0.15`；`country.production.input_factor -0.04` |
| `tech.land_surveying` | 土地测量 | major | U+P | 【新】 | 前置 `[tech.weights_and_measures, tech.road_engineering]`；reveal `SIGNAL(development.settlement.tier_2_180d)`；解锁 `building:survey_office`；`country.tax.business.<building>.rate_bp +200`（地籍→税基）；作为 `cartography` 的新前置 |
| `tech.manuscript_culture` | 手稿文化 | major | U+S | 【改】 | 全局 +0.08 → **`country.research.institution_output_factor +0.10`**；保留 `monastic_scriptorium` |
| `tech.woodblock_printing` | 木版印刷 | breakthrough | U+P | 【改】 | 全局 +0.08 → **`country.research.cost_factor -0.08`**（知识复制变便宜）；删伪前置 `composite_tools` |
| `tech.movable_type_printing` | 活字印刷 | breakthrough | U+P | 【改】 | 全局 +0.06 → **`country.research.cost_factor -0.10` + `country.research.society_efficiency +0.12`**；补 reveal `SIGNAL(breakthrough.printing)` |
| `tech.scholastic_method` | 经院研究法 | major | S | 【改】 | 全局 +0.08 → **`country.research.science_efficiency +0.12` + `country.research.cost_factor -0.05`** |
| `tech.urban_food_supply` | 城市食物供应 | major | C+G | 【改】 | 全局 +0.08 → **`country.output.family.staple_preparation_factor +0.15` + `country.consumption.good.grain_factor -0.08`**（城市粮食损耗下降） |
| `tech.regional_granaries` | 区域粮仓 | major | G | 【改】 | 补 `country.climate.flood_loss_factor -0.10` + `country.climate.drought_loss_factor -0.08`（储备缓冲） |
| `tech.wind_power` | 风力机械 | major | U | 【改】 | 全局 +0.08 → 解锁 `building:windmill`（若不存在）+ `country.output.terrain.coast.energy_factor +0.15` + `country.output.terrain.grassland.energy_factor +0.12`；补后继 `→ mill_network` |
| `tech.sharecropping` | 分成租佃 | major | P+L | 【改】 | 全局 +0.08 → **`country.tax.income.sharecropper.rate_bp +300` + `economy.profession.sharecropper.satisfaction_bp -200`** |
| `tech.manorial_jurisdiction` | 庄园司法 | major | S+P | 【改】 | 全局 +0.08 → **`economy.profession.serf.tax_tolerance_factor +0.20` + `country.tax.income.landlord.rate_bp +400`**；子节点改前置到 `customary_tenancy` |
| `tech.estate_accounting` | 庄园会计 | major | P | 【改】 | 补 `country.tax.business.<building>.rate_bp +300` |
| `tech.forest_management` | 森林管理 | major | G | 【改】 | `agriculture_factor +0.08` → **`country.output.terrain.forest.extractive_factor +0.20` + `country.output.terrain.taiga.extractive_factor +0.18` + `country.resource.timber.managed_generation_factor +0.15`** |
| `tech.imperial_integration` | 帝国网络 | breakthrough | — | 【保留】 | 里程碑；全局 +0.05 → **+0.025** |
| `tech.iron_smelting` | 冶铁 | breakthrough | U | 【保留】 | 里程碑候选 |
| `tech.coal_mining` | 煤矿开采 | breakthrough | G+U | 【改】 | `extractive_factor +0.12` → 保留 **+0.10**（identity 保留）；reveal 改 `ANY_OF(SIGNAL(resource.coal), SIGNAL(contact.coal_sample), SIGNAL(development.buildings.active_8_360d))` —— **消除"缺煤 −124 节点"的悬崖** |
| `tech.coal_adit_mining` | 煤矿平硐 | major | G | 【改】 | `extractive_factor +0.20` → **`country.output.landform.hill.extractive_factor +0.20` + `country.output.landform.mountain.extractive_factor +0.15`** |
| `tech.mine_ventilation` | 矿井通风 | major | G | 【改】 | `extractive_factor +0.14` → **`country.resource.lead_ore.use_factor -0.08` + `country.output.landform.mountain.extractive_factor +0.12`**；补 reveal `SIGNAL(breakthrough.mine_support)` |
| `tech.siegecraft` | 攻城术 | major | M+U | 【改】 | 补 reveal `SIGNAL(development.buildings.active_8_360d)`；`fortification_factor +0.15` → **+0.08**；`country.military.rule.encirclement 0.10` |
| `tech.military.siege_train` | 攻城纵列 | major | M+U | 【新】 | 前置 `[tech.military.siegecraft, tech.military.legion_logistics]`；reveal `SIGNAL(development.buildings.active_16_360d)`；解锁 `building:siege_park`；`country.military.rule.encirclement 0.15` + `country.military.supply_consumption_factor -0.10` |
| `tech.military.mounted_warfare` | 骑兵战术 | major | M | 【改】 | 补 reveal `ALL_OF(SIGNAL(bio.horse), ANY_OF(SIGNAL(landform.grassland), SIGNAL(landform.steppe_plain)))`；迁移至 `branch.military_doctrine`；`country.military.rule.blitz 0.12` |
| `tech.military.heavy_cavalry` | 重骑兵 | major | M | 【改】 | 补 reveal `ANY_OF(SIGNAL(resource.iron_ore), SIGNAL(breakthrough.metalworking))`；迁移至 `branch.military_doctrine`；`country.military.rule.last_stand 0.10` |
| `tech.military.legion_logistics` | 军需体系 | major | M+P | 【改】 | 补 reveal `ANY_OF(SIGNAL(development.trade.quantity_1000), SIGNAL(development.buildings.active_16_360d))`；`supply_consumption_factor +0.85` → **+0.20**（数值事故） |
| `tech.military.military_roads` | 军道 | minor | M+P | 【改】 | 补 reveal `ANY_OF(SIGNAL(development.trade.goods_2), SIGNAL(landform.river_valley))`；`logistics_move_factor +0.25` → **+0.12**；`supply_transport_factor +0.15` → **+0.10** |
| `tech.military.coastal_transport` | 近海运兵 | major | M+U | 【改】 | **不再零效果**：解锁 `good:warship`（新，q1）、`building:naval_shipyard`（condition: `has_water` + `terrain=coast`）；兵种 `frigate`（新）；reveal `ANY_OF(SIGNAL(landform.coast), SIGNAL(contact.maritime_vessel))` |
| `tech.chartered_universities` | 特许大学 | breakthrough | U+S | 【保留】 | 研究建筑台阶 |
| 其余 empire 节点 | — | — | — | 【保留】 / 成本重定价 | 见 JSON 全表 |

## 本代新增小计：4（`magnetic_navigation` 改；`mountain_irrigation` / `mill_network` / `land_surveying` / `military.siege_train`）

---

# 时代 4 · exploration 探索时代（35 → **40** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.imperial_integration` |
| 出口里程碑 | `tech.global_exchange` |
| 非里程碑 | 39 |
| 推进要求 | **32** |
| 可放弃 | 7 |
| 成本三档 | minor ≈59,800 / major ≈108,800 / breakthrough ≈195,800 |
| 本代问题 | ① `cartography`（池内最低价、4 个下游）零效果；② `branch.tropical_commodities` 在此绝后；③ tools 主干第一次断档（无节点）；④ 橡胶链 4 个节点是"帝国价位"（44k–55k）；⑤ 4 个空洞节点 |

## 本代设计要点

1. **救活 `cartography`**：海图/测绘 → 物资 + 建筑 + 贸易速度。
2. **补 tools 主干断档**：新增 `tech.precision_measurement`（精密测量）。
3. **延长热带支线**：新增 `tech.plantation_processing`（种植园加工）与 `tech.sugar_refining`（制糖），把 `tropical_commodities` 从 4 代延到 6 代。
4. **橡胶链重定价**：4 个节点从 44k–55k 抬到 major 档。
5. **补地理**：`cartography`/`oceanic_navigation`/`plantation_processing` 都给地形或气候。
6. **军事**：新增 `tech.military.line_infantry` 拿"坚守"条令。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.cartography` | 地图学 | major | U+P | 【改】 | **不再零效果**：解锁 `good:charts`（新）、`building:chart_survey_office`；`country.trade.speed_factor +0.12` + `country.trade.capacity_factor +0.06`；`effect_summary` 重写；成本 96,000 → major 档 |
| `tech.oceanic_charting` | 海图与远洋测绘 | major | G+U | 【新】 | 前置 `[tech.cartography, tech.celestial_navigation]`；reveal `ALL_OF(SIGNAL(landform.coast), SIGNAL(development.trade.value_1000))`；解锁 `building:hydrographic_office`；`country.trade.speed_factor +0.10`；`country.output.terrain.coast.extractive_factor +0.12`；作为 `geographic_information_systems` 的新前置 |
| `tech.precision_measurement` | 精密测量 | major | S | 【新】 | 前置 `[tech.mechanical_timekeeping, tech.weights_and_measures]`；放在 `backbone.tools_machinery`（修复该主干在 exploration 的空洞）；`country.research.science_efficiency +0.10` + `country.research.engineering_efficiency +0.08`；作为 `precision_engineering` 的新前置 |
| `tech.plantation_processing` | 种植园加工 | breakthrough | U+C+G | 【新】 | 前置 `[tech.estate_plantation_management, tech.commodity_crop_management]`；reveal `ALL_OF(SIGNAL(landform.jungle), SIGNAL(development.output.agriculture.1000_360d))`；解锁 `good:sugar`（新）、`building:sugar_mill`；`country.output.terrain.jungle.agriculture_factor +0.20` + `country.output.terrain.mangrove.agriculture_factor +0.15`；为 `tropical_commodities` 续命到 steam |
| `tech.sugar_refining` | 制糖与蒸馏 | major | C+P | 【新】 | 前置 `[tech.plantation_processing]`；解锁 `building:refinery`（`sugar` → `beverages`/`processed_food`）；`country.output.family.specialty_commodity_crops_factor +0.15`；`country.tax.consumption.beverages.rate_bp +300`（奢侈品税）|
| `tech.precision_engineering` | 精密工程 | breakthrough | U+S | 【改】 | 前置 `[precision_measurement]`；全局 +0.08 → **`country.research.engineering_efficiency +0.15` + `country.construction.time_factor -0.06`** |
| `tech.screw_press_printing` | 螺旋压印 | major | U+P | 【改】 | 全局 +0.08 → **`country.research.cost_factor -0.10`**；保留 `packaging_plant`/`printed_materials_plant` |
| `tech.deep_mining` | 深井采矿 | breakthrough | G | 【改】 | `extractive_factor +0.24` → **`country.output.landform.mountain.extractive_factor +0.25` + `country.output.landform.rift_valley.extractive_factor +0.20` + `country.resource.iron_ore.use_factor -0.06`** |
| `tech.shaft_sinking` | 竖井开凿 | major | G | 【改】 | 补 `country.output.landform.hill.extractive_factor +0.15` + `country.output.landform.badlands.extractive_factor +0.12` |
| `tech.mine_drainage` | 矿井排水 | major | G | 【改】 | 补 `country.output.landform.lowland.extractive_factor +0.12` + `country.climate.flood_loss_factor -0.06` |
| `tech.geological_prospecting` | 地质勘探 | breakthrough | U+G | 【改】 | `extractive_factor +0.18` → **`country.output.landform.mountain.extractive_factor +0.18` + `country.output.landform.volcano.extractive_factor +0.25`**（火山矿带）；`country.resource.*` 不新增储量（不铸造资源） |
| `tech.commodity_crop_management` | 商品作物管理 | breakthrough | C+P | 【改】 | `agriculture_factor +0.08` → **`country.output.family.specialty_commodity_crops_factor +0.15` + `country.tax.export.<good>.rate_bp`? 用 `country.trade.capacity_factor +0.08`**；删除重复 `latex` unlock |
| `tech.commercial_tenancy` | 商业租佃 | major | P+L | 【改】 | 全局 +0.08 → **`country.tax.income.tenant_farmer.rate_bp +400` + `economy.profession.tenant_farmer.tax_tolerance_factor +0.15`** |
| `tech.global_exchange` | 洲际网络 | breakthrough | — | 【保留】 | 里程碑；全局 +0.05 → **+0.025**；`capacity_factor +0.12` 保留 |
| `tech.double_entry_bookkeeping` | 复式记账 | major | P | 【保留】 | 里程碑候选 |
| `tech.actuarial_insurance` | 精算保险 | major | P+S | 【改】 | 补 reveal `SIGNAL(development.trade.partners_1)`；补 `country.trade.capacity_factor +0.10` |
| `tech.bills_of_exchange` | 汇票 | major | P | 【保留】 | — |
| `tech.mercantile_networks` | 商业网络 | major | P | 【改】 | 前置 `[currency, bills_of_exchange]`（修整代缺环） |
| `tech.rubber_identification` 等 4 个橡胶节点 | — | major | — | 【改】 | 成本 44,200/48,200/50,700/55,300 → **全部抬到 major 档**；`rubber_identification` reveal 改 `ANY_OF(SIGNAL(bio.rubber), SIGNAL(contact.latex))` |
| `tech.oceanic_navigation` | 远洋航行 | breakthrough | U+G | 【改】 | 补 `country.output.terrain.coast.extractive_factor +0.12` + `country.trade.speed_factor +0.10` |
| `tech.oceanic_ship_design` | 远洋船设计 | breakthrough | U+C | 【改】 | 补 `country.output.family.maritime_operations_factor +0.15`；`containerization` 将改写其配方 |
| `tech.military.line_infantry` | 线列步兵 | major | M+U | 【新】 | 前置 `[tech.military.drill_regulations, tech.military.corned_powder]`；reveal `SIGNAL(development.buildings.active_32_720d)`；解锁 `building:line_infantry_depot`；兵种 `line_infantry`（新）；`country.military.rule.hold_the_line 0.15` + `country.military.organization_recovery_factor +0.10` |
| `tech.military.corned_powder` | 粒状火药 | major | C | 【改】 | 补 reveal `SIGNAL(breakthrough.kiln_temperature)`；`country.input.good.industrial_chemicals_factor -0.08` |
| `tech.military.field_artillery` | 野战火炮 | major | M+U | 【改】 | 补 reveal `SIGNAL(development.employment.manufacturing.50_180d)`；补后继 `→ tech.military.siege_train`（消除叶子） |
| `tech.military.star_forts` | 棱堡 | major | M+G | 【改】 | 补 reveal `ANY_OF(SIGNAL(landform.coast), SIGNAL(terrain=plain))`；`fortification_factor +0.20` → **+0.10** |
| `tech.military.naval_transport` | 远洋运兵 | major | M+U | 【改】 | 补 reveal `ANY_OF(SIGNAL(landform.coast), SIGNAL(contact.maritime_vessel))`；补 `good:warship` 的 tier 2（q2）|
| `tech.military.nitre_beds` | 硝田制硝 | minor | G | 【改】 | 补 reveal `ANY_OF(SIGNAL(resource.saltpeter), SIGNAL(landform.arid_basin))` |
| 其余 exploration 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

**本代新增小计：5**（`oceanic_charting` / `precision_measurement` / `plantation_processing` / `sugar_refining` / `military.line_infantry`）

---

# 时代 5 · enlightenment 启蒙时代（31 → **37** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.global_exchange` |
| 出口里程碑 | `tech.enlightenment_institutions` |
| 非里程碑 | 36 |
| 推进要求 | **29** |
| 可放弃 | 7 |
| 成本三档 | minor ≈134,500 / major ≈244,800 / breakthrough ≈440,600 |
| **本代是全树最空的一代** | 内容密度 **0.77**（新内容/节点，全树最低）；48% 节点纯百分比；48.5% 研究点买不到任何新内容 |

## 本代设计要点（本代是改造重点）

1. **新增 6 个节点**，把内容密度从 0.77 拉到 ~1.2。
2. **救活三个里程碑候选**：`experimental_science`（只 +6% 全局）、`public_health`（零内容）、`political_economy`（只 +? ）。
3. **补全三条中期死亡支线**：`forest_biomass`（补木材化学）、`water_wind`（补圩田工程）、`textile_fibers`（补工场化）。
4. **补公共卫生支线**（全树最薄，6 节点）：新增 `tech.urban_water_and_sewer`。
5. **补地理**：本代现状只有 1 个 `landform` 引用。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.experimental_science` | 实验科学 | breakthrough | S | 【改】 | 全局 +0.06 → **`country.research.science_efficiency +0.15` + `country.research.cost_factor -0.08`**；与 `scholastic_method` 形成"经院→实验"的方法论链条 |
| `tech.public_health` | 公共卫生 | breakthrough | S+U | 【改】 | 全局 +0.04 → **解锁 `building:public_bathhouse`（产 `soap` 需求满足）；`country.population.death_factor -0.06` + `economy.profession.worker.satisfaction_bp +300`** |
| `tech.urban_water_and_sewer` | 上下水工程 | major | G+S | 【新】 | 前置 `[tech.public_health, tech.urban_waterworks]`；reveal `ALL_OF(SIGNAL(development.settlement.tier_3_360d), SIGNAL(breakthrough.watershed_management))`；`country.climate.profile.paddy_crop.flood_loss_factor -0.12` + `country.climate.profile.dryland_crop.flood_loss_factor -0.12` + `country.population.death_factor -0.05` |
| `tech.timber_chemical_industry` | 木材化学 | breakthrough | U+C+G | 【新】 | 前置 `[tech.forest_management, tech.industrial_chemistry? 不—在 steam]` → `[tech.forest_management, tech.charcoal_burning]`；reveal `SIGNAL(breakthrough.chemical_process_control)`；解锁 `good:wood_tar`（新）、`building:wood_chemical_works`；`country.output.terrain.forest.extractive_factor +0.18` + `country.output.terrain.taiga.extractive_factor +0.15`；为 `industrial_chemistry` 提供有机碳源（修复 `charcoal` 无化工下游的断链）|
| `tech.seed_drill_and_thresher` | 条播与脱粒机 | major | C+L | 【新】 | 前置 `[tech.agricultural_improvement, tech.mechanical_workshops]`；reveal `SIGNAL(breakthrough.rainfed_adaptation)`；解锁 `building:seed_drill_works`；`country.output.terrain.plain.agriculture_factor +0.15` + `country.output.family.field_crop_farming_factor +0.12`；岗位：`agricultural_worker` 槽位 −25%（用 `employee_slots` 表达，非 labor 魔法）|
| `tech.polder_engineering` | 圩田与海岸工程 | breakthrough | G+U | 【新】 | 前置 `[tech.canal_engineering, tech.hydraulic_engineering]`；reveal `ALL_OF(SIGNAL(landform.coast), ANY_OF(SIGNAL(landform.marsh), SIGNAL(weather.major_flood)))`；解锁 `building:polder_works`（condition: `terrain ∈ {marsh, swamp}` 或 `landform=delta`）；`country.output.terrain.marsh.agriculture_factor +0.25` + `country.output.terrain.swamp.agriculture_factor +0.25` + `country.climate.flood_loss_factor -0.10` |
| `tech.textile_manufacture` | 纺织工场化 | major | L+C | 【新】 | 前置 `[tech.weaving, tech.guild_organization]`；reveal `SIGNAL(breakthrough.industrial_organization)`；解锁 `building:textile_manufactory`（owner `industrialist`，雇 `industrial_worker`）；`country.output.family.cloth_weaving_factor +0.15`；作为 `textile_machinery` 的新前置（消除 `weaving→textile_machinery` 的 4 代跳跃）|
| `tech.agricultural_improvement` | 农业改良 | breakthrough | C+G | 【改】 | `agriculture_factor +0.08` → **`country.output.family.field_crop_farming_factor +0.15` + `country.output.terrain.plain.agriculture_factor +0.12`**；删除重复 good unlock |
| `tech.agricultural_cooperatives` | 农业合作社 | major | L+P | 【改】 | `agriculture_factor +0.08` → **`country.tax.income.household_farmer.rate_bp -400` + `country.tax.income.cooperative_member.rate_bp -200`? → 用 `economy.profession.cooperative_member.satisfaction_bp +400`**（软互斥对 A 的另一侧：合作社制）|
| `tech.wage_contracts` | 工资契约 | major | L+P | 【改】 | 全局 +0.08 → **`economy.profession.industrial_worker.satisfaction_bp -200` + `country.tax.income.industrial_worker.rate_bp +300`**（工资劳动=可征所得税）|
| `tech.standardization` | 标准化 | breakthrough | C+P | 【改】 | 补 `country.construction.cost_factor -0.08` + `country.construction.time_factor -0.08` + `country.production.input_factor -0.04` |
| `tech.political_economy` | 政治经济学 | major | S+P | 【改】 | 补 `country.tax.business.<building>.rate_bp +300` |
| `tech.microbiology` | 微生物学 | major | U+S | 【改】 | 补 reveal `SIGNAL(breakthrough.chemical_process_control)`；补 `country.population.death_factor -0.04` |
| `tech.cooperative_association` | 合作社组织 | major | L+P | 【改】 | 全局 +0.04 → **`economy.profession.cooperative_member.satisfaction_bp +300` + `country.tax.income.cooperative_member.rate_bp -200`** |
| `tech.learned_societies` | 博学学会 | major | U+S | 【改】 | 补后继 `→ tech.national_laboratories`（消除叶子） |
| `tech.hydraulic_engineering` | 水利工程 | breakthrough | G | 【改】 | 前置 `[canal_engineering, urban_waterworks]`（修整代缺环）；补 `country.output.landform.rift_valley.agriculture_factor +0.15` + `country.climate.flood_loss_factor -0.08` |
| `tech.military.chasseur` | 散兵战术 | major | M | 【新】 | 前置 `[tech.military.drill_regulations, tech.textile_manufacture? 不—]` → `[tech.military.drill_regulations]`；reveal `ANY_OF(SIGNAL(landform.forest), SIGNAL(landform.hill))`；`country.military.rule.blitz 0.15` + `country.military.speed_factor +0.05`；兵种 `skirmishers`（新）|
| `tech.military.drill_regulations` | 操典 | major | M | 【改】 | 补前置 `+= tech.military.corned_powder`（修火药链断裂）；`training_time_factor +0.80` → **+0.20**；`country.military.rule.mutual_support 0.10` |
| `tech.military.powder_milling` | 机械制药 | minor | C | 【改】 | 补 reveal `SIGNAL(breakthrough.kiln_temperature)` |
| `tech.military.military_cartography` | 军事测绘 | major | M+G | 【改】 | 补 reveal `SIGNAL(landform.hill)`；`vision_add +10` → **+4**；`attrition_factor +0.70` → **+0.20** |
| `tech.military.military_medicine` | 军医制度 | major | M+S | 【改】 | 补 reveal `SIGNAL(development.population.2500_180d)`；`casualty_factor +0.85` → **+0.20** |
| `tech.enlightenment_institutions` | 启蒙制度 | breakthrough | — | 【保留】 | 里程碑；全局 +0.04 → **+0.025** |
| 其余 enlightenment 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

**本代新增小计：6**（`urban_water_and_sewer` / `timber_chemical_industry` / `seed_drill_and_thresher` / `polder_engineering` / `textile_manufacture` / `military.chasseur`）

---

# 时代 6 · steam 蒸汽时代（33 → **37** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.enlightenment_institutions` |
| 出口里程碑 | `tech.industrialization` |
| 非里程碑 | 36 |
| 推进要求 | **29** |
| 可放弃 | 7 |
| 成本三档 | minor ≈299,000 / major ≈544,000 / breakthrough ≈979,000 |
| 本代问题 | ① **授予的研究效率净增量 = 0**（正好撞 ×2.22 成本墙）；② 无新增研究建筑；③ 52 座新建筑一次涌入（37 座制造业）；④ `food_storage` 主干在此断档前的最后一站 |

## 本代设计要点

1. **给本代一个科研节奏节点**：让 `industrial_organization` 或新节点提供 `research.institution_output_factor`。
2. **补食品工业**（`food_storage` 主干在 atomic/information 断档的起点）：新增 `tech.industrial_food_preservation`。
3. **补建材换代**（蒸汽代之后 4 代 0 新建材的起点）：新增 `tech.structural_steel`。
4. **补公共卫生中段**：新增 `tech.municipal_sanitation`。
5. **军事**：新增 `tech.military.entrenchment` 拿"死守"条令；修 5 处数值事故。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.industrial_food_preservation` | 食品工业保存 | breakthrough | U+C+G | 【新】 | 前置 `[tech.industrial_canning? 已存在]` → `[tech.industrial_canning, tech.industrial_chemistry]`；reveal `SIGNAL(breakthrough.chemical_process_control)`；解锁 `good:canned_food`（新）、`building:cannery`；`country.output.family.staple_preparation_factor +0.20` + `country.climate.profile.dryland_crop.heat_stress_loss_factor -0.10`；成为 atomic 的 `cold_chain` 前身 |
| `tech.structural_steel` | 型钢与预制 | breakthrough | U+P | 【新】 | 前置 `[tech.coke_smelting, tech.reinforced_concrete]`；reveal `SIGNAL(breakthrough.industrial_organization)`；解锁 `good:structural_steel`（新，建材类别 `structural_metal` 的**前工业成员修复**）；`country.construction.cost_factor -0.08` + `country.construction.time_factor -0.10` |
| `tech.municipal_sanitation` | 市政下水道 | major | S+G | 【新】 | 前置 `[tech.public_health, tech.industrial_chemistry]`；reveal `ALL_OF(SIGNAL(development.settlement.tier_4_720d), SIGNAL(breakthrough.watershed_management))`；`country.population.death_factor -0.06` + `country.climate.profile.dryland_crop.flood_loss_factor -0.10`；解锁 `building:sewer_works` |
| `tech.industrial_organization` | 工业组织 | breakthrough | S+P | 【改】 | `manufacturing_factor +0.08` → **`country.research.institution_output_factor +0.15`（本代唯一科研加速）+ `country.tax.business.<building>.rate_bp +300`** |
| `tech.factory_system` | 工厂制 | breakthrough | L | 【改】 | `manufacturing_factor +0.06` → **`country.output.family.manufacturing_generic_factor`? 用 `country.production.input_factor -0.05` + `economy.profession.industrial_worker.satisfaction_bp -300`**（工厂制的社会代价）|
| `tech.steam_power` | 蒸汽动力 | breakthrough | U+G | 【改】 | `manufacturing_factor +0.12` → **保留 +0.08**；补 `country.output.terrain.hill.energy_factor +0.15`（煤近山）+ `country.input.good.coal_factor -0.06` |
| `tech.assembly_line` | 流水线组织 | breakthrough | L+P | 【改】 | `manufacturing_factor +0.22` → **`country.output.family.manufacturing_generic_factor +0.25`? 用 `country.production.input_factor -0.08` + `country.output.good.prepared_staples_factor +0.15`**；`economy.profession.industrial_worker.satisfaction_bp -200` |
| `tech.labor_organization` | 劳工组织 | major | L+S | 【改】 | `manufacturing_factor +0.08` → **`economy.profession.industrial_worker.tax_tolerance_factor +0.20` + `economy.profession.industrial_worker.satisfaction_bp +200`** |
| `tech.worker_cooperatives` | 工人合作工场 | major | L+P | 【改】 | 全局 +0.08 → **`economy.profession.cooperative_member.satisfaction_bp +400` + `country.tax.income.cooperative_member.rate_bp -400`**；解锁 `building:cooperative_workshop`（owner `cooperative_member`）——**启用全树 0 引用的 `cooperative_member` 职业** |
| `tech.industrialization` | 工业化 | breakthrough | — | 【保留】 | 里程碑；全局 +0.12 → **+0.025** |
| `tech.coke_smelting` | 焦炭冶炼 | breakthrough | U+C | 【改】 | 从 `branch.nonferrous_metals` **迁移到 `branch.heavy_industry`**（跨家族错位）；reveal 从 `development.employment.manufacturing.250_360d` 改为 `ANY_OF(SIGNAL(resource.coal), SIGNAL(breakthrough.kiln_temperature))`；前置 `[blast_furnace, industrial_coal_mining]` |
| `tech.industrial_coal_mining` | 工业采煤 | breakthrough | G | 【改】 | `extractive_factor +0.18` → **保留 +0.10**；补 `country.output.landform.hill.extractive_factor +0.15` |
| `tech.corporate_mining` | 公司矿山 | major | G+P | 【改】 | `extractive_factor +0.28` → **`country.output.landform.mountain.extractive_factor +0.20`**；`country.tax.business.<building>.rate_bp +300` |
| `tech.steam_sawmilling` | 蒸汽锯木 | major | G | 【改】 | 补 `country.output.terrain.forest.extractive_factor +0.18` + `country.output.terrain.taiga.extractive_factor +0.15` |
| `tech.textile_machinery` | 纺织机械 | breakthrough | C+L | 【改】 | 前置 `[textile_manufacture]`（修 4 代跳）；补 `country.output.family.cloth_weaving_factor +0.18` + `country.input.good.bast_fiber_factor -0.08` |
| `tech.mechanized_printing` | 机械印刷 | major | U+P | 【改】 | 补 `country.research.cost_factor -0.08` |
| `tech.industrial_statistics` | 工业统计 | major | S+P | 【改】 | 补 `country.tax.business.<building>.rate_bp +300` + `country.research.society_efficiency +0.10` |
| `tech.reinforced_concrete` | 钢筋混凝土 | breakthrough | U+P | 【改】 | 补 `country.construction.cost_factor -0.08` + `country.construction.time_factor -0.08`（F 审 R5 建议）|
| `tech.industrial_canning` | 工业罐头 | major | U | 【改】 | 补 reveal `SIGNAL(breakthrough.industrial_organization)`；作为新 `industrial_food_preservation` 的前置 |
| `tech.military.entrenchment` | 野战筑城 | major | M+U | 【新】 | 前置 `[tech.military.rifled_weapons]`；reveal `SIGNAL(development.buildings.active_32_720d)`；解锁 `building:field_fortification`；`country.military.rule.last_stand 0.15` + `country.military.fortification_factor +0.06` |
| `tech.military.rifled_weapons` | 线膛枪炮 | breakthrough | U | 【改】 | 补前置 `+= tech.military.powder_milling`（修火药链） |
| `tech.military.smokeless_powder` | 无烟火药 | breakthrough | U+C | 【改】 | 补前置 `+= tech.military.powder_milling` |
| `tech.military.rail_mobilization` | 铁路动员 | major | M+P | 【改】 | `supply_transport_factor +2.00` → **+0.30**（数值事故）；`logistics_move_factor +0.50` → **+0.20** |
| `tech.military.general_staff` | 总参谋部 | major | M+S | 【改】 | `frontage_factor +0.25` → **+0.15**；`organization_recovery_factor +0.10` 保留；`country.military.rule.mutual_support 0.08` |
| 其余 steam 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

**本代新增小计：4**（`industrial_food_preservation` / `structural_steel` / `municipal_sanitation` / `military.entrenchment`）

---

# 时代 7 · electrical 电气时代（30 → **36** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.industrialization` |
| 出口里程碑 | `tech.electrical_society` |
| 非里程碑 | 35 |
| 推进要求 | **28** |
| 可放弃 | 7 |
| 成本三档 | minor ≈673,000 / major ≈1,224,000 / breakthrough ≈2,203,000 |
| 本代问题 | ① 6 个新物资（倒数）；② 5 座电厂清一色"燃料→电"，无效率差异；③ `petroleum_materials` 只活 2 代；④ 无 galvanic 电学基础（`electromagnetic_induction` 直接接 `experimental_science`，跨 2 代）|

## 本代设计要点

1. **补电学基础**：新增 `tech.galvanic_science`（A 审 R7#2）。
2. **补 tools 主干**：新增 `tech.servomechanism`（A 审 R5#3）。
3. **救活三条垂死支线**：`forest_biomass`（补林产工业）、`maritime_logistics`（补水产养殖）、`food_storage`（补冷链）。
4. **补新物资**：`refrigerated_food`、`panel_wood`。
5. **军事**：新增 `tech.military.levee_en_masse` 拿"本土作战"条令。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.galvanic_science` | 电学基础 | major | S | 【新】 | 前置 `[tech.experimental_science, tech.industrial_research]`；reveal `SIGNAL(breakthrough.electrification)`；`country.output.energy_factor +0.08` + `country.research.science_efficiency +0.10`；作为 `electromagnetic_induction` 的新前置（消除 2 代跳跃）|
| `tech.servomechanism` | 伺服机构 | major | U+C | 【新】 | 放在 `backbone.tools_machinery`（修复该主干在 information 的空洞）；前置 `[tech.electric_motors, tech.industrial_quality_control]`；reveal `SIGNAL(breakthrough.motor_winding)`；解锁 `building:servo_works`；`country.output.family.metal_toolmaking_factor +0.15` + `country.production.input_factor -0.04`；作为 `robotic_control` 的新前置 |
| `tech.aquaculture` | 水产养殖 | breakthrough | U+G | 【新】 | 前置 `[tech.coastal_fishing? 不—]` → `[tech.fish_meal? 用 tech.oceanic_ship_design]` + `[tech.refrigeration]`；简化：前置 `[tech.motorized_fishing? 用 tech.food_storage 链末]` → **`[tech.oceanic_provisioning, tech.refrigeration]`**；reveal `ALL_OF(SIGNAL(landform.coast), SIGNAL(bio.freshwater_fish))`；解锁 `good:aquaculture_fish`（新）、`building:fish_farm`（condition: `terrain ∈ {coast, lake}`）；`country.output.terrain.coast.extractive_factor +0.20` + `country.output.landform.lake.extractive_factor +0.15` |
| `tech.forest_products_industry` | 林产工业 | breakthrough | U+G | 【新】 | 前置 `[tech.steam_sawmilling, tech.industrial_chemistry]`；reveal `SIGNAL(breakthrough.forest_management)`；解锁 `good:panel_wood`（新）、`building:pulp_mill`（`lumber`→`paper`）、`building:plywood_mill`；`country.output.terrain.forest.extractive_factor +0.20` + `country.output.terrain.taiga.extractive_factor +0.18`；把 `forest_biomass` 从 steam 延到 information |
| `tech.cold_chain_industry` | 冷链 | major | U+S | 【新】 | 前置 `[tech.refrigeration, tech.industrial_food_preservation]`；reveal `SIGNAL(development.trade.quantity_1000)`；解锁 `good:refrigerated_food`（新）、`building:cold_storage`；`country.output.family.staple_preparation_factor +0.20` + `country.climate.profile.dryland_crop.heat_stress_loss_factor -0.12`；延续 `food_storage` 主干 |
| `tech.electrical_society` | 电气社会 | breakthrough | — | 【保留】 | 里程碑；全局 +0.06 → **+0.025**；`energy_factor +0.15` → **+0.08** |
| `tech.electrification` | 电气化 | breakthrough | U+G | 【改】 | 全局 +0.03 → **`country.output.energy_factor +0.10` + `country.output.terrain.coast.energy_factor +0.10`（水电/潮汐）**；解锁 `good:batteries`、`building:basic_electrical_equipment_works` 保留 |
| `tech.electric_motors` | 电动机 | breakthrough | C+L | 【改】 | 补 `country.production.input_factor -0.05` + `economy.profession.electrician.satisfaction_bp +200` |
| `tech.petroleum_extraction` | 石油开采 | major | G | 【改】 | 补 `country.output.terrain.desert.extractive_factor +0.18` + `country.output.landform.lowland.extractive_factor +0.12` |
| `tech.petroleum_refining` | 石油精炼 | breakthrough | U+C | 【改】 | 补 `country.input.good.crude_oil_factor -0.06` |
| `tech.industrial_research` | 工业研究 | breakthrough | S | 【改】 | 全局 +0.06 → **`country.research.institution_output_factor +0.20` + `country.research.engineering_efficiency +0.10`** |
| `tech.refrigeration` | 机械制冷 | breakthrough | U+G+S | 【改】 | 全局 +0.08 → **解锁 `building:cold_storage`（若非由 `cold_chain_industry`）`+ country.climate.profile.pasture_livestock.heat_stress_loss_factor -0.15` + `country.population.death_factor -0.03`** |
| `tech.public_education` | 公共教育 | breakthrough | U+S | 【改】 | 补 `country.research.cost_factor -0.08` + `economy.profession.worker.satisfaction_bp +200` |
| `tech.modern_medicine` | 现代医学 | breakthrough | U+S | 【改】 | 补 `country.population.death_factor -0.06`；解锁 `building:pharmaceuticals_plant` 已有 |
| `tech.modern_husbandry` | 现代畜牧 | major | G+C | 【改】 | 补 `country.output.terrain.grassland.agriculture_factor +0.15` + `country.output.family.livestock_husbandry_factor +0.15`；补后继（消除叶子）|
| `tech.electromagnetic_induction` | 电磁感应 | major | S | 【改】 | 前置 `[galvanic_science]`；补 `country.output.energy_factor +0.08` |
| `tech.genetics` | 遗传学 | major | S | 【改】 | 补 reveal `SIGNAL(breakthrough.seed_saving)`；补 `country.output.good.grain_factor +0.10` |
| `tech.synthetic_fertilizer` | 合成肥料 | breakthrough | U+C | 【改】 | 补 `country.output.agriculture_factor +0.08`（identity 保留）+ `country.production.input_factor -0.05`；`ammonia_synthesis` 将改写其配方 |
| `tech.motorized_agriculture` | 机动农业 | breakthrough | C+L | 【改】 | `agriculture_factor +0.08` → **`country.output.family.field_crop_farming_factor +0.18`**；岗位 `agricultural_worker` 槽位 −30%（`employee_slots`）；输入加 `agricultural_machinery` |
| `tech.industrial_quality_control` | 工业质检 | major | C+P | 【改】 | 补 `country.production.input_factor -0.06` + `country.construction.time_factor -0.04` |
| `tech.central_banking` | 中央银行 | major | P | 【改】 | 补 reveal `SIGNAL(development.trade.value_100000)`；`country.tax.business.<building>.rate_bp +400` |
| `tech.military.machine_guns` | 机枪 | breakthrough | M+U | 【改】 | 补前置 `+= tech.military.smokeless_powder`；`attack_factor +0.10` → **+0.06** |
| `tech.military.armored_warfare` | 装甲战 | breakthrough | M+U | 【改】 | `attack_factor +0.08` → **+0.05**；`country.military.rule.blitz 0.12` |
| `tech.military.radio_command` | 无线电指挥 | major | M+S | 【改】 | `attack_factor +0.10` → **+0.05**；`convoy_escort_factor +0.25` → **+0.12**；`country.military.organization_recovery_factor +0.15` |
| `tech.military.continuous_nitration` | 连续硝化 | major | C | 【改】 | 补 `country.input.good.sulfur_factor -0.10` |
| `tech.military.levee_en_masse` | 全民动员 | major | M+S | 【新】 | 前置 `[tech.military.standing_army, tech.public_education]`；reveal `SIGNAL(development.population.62500_720d)`；`country.military.rule.home_ground 0.15` + `country.military.levy_rate +0.06` + `country.military.militia_factor +0.10` |
| 其余 electrical 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

**本代新增小计：6**（`galvanic_science` / `servomechanism` / `aquaculture` / `forest_products_industry` / `cold_chain_industry` / `military.levee_en_masse`）

---

# 时代 8 · atomic 原子时代（30 → **34** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.electrical_society` |
| 出口里程碑 | `tech.atomic_modernity` |
| 非里程碑 | 33 |
| 推进要求 | **27** |
| 可放弃 | 6 |
| 成本三档 | minor ≈1,495,000 / major ≈2,720,000 / breakthrough ≈4,896,000 |
| 本代问题 | ① **4 个纯泛经济节点（全树最多）**，全部是里程碑候选；② `nuclear_fission` 只 +8% 全局；③ `food_storage` 主干在此断档；④ **空军/海军 0 单位**；⑤ 化工无氨（`fertilizer_plant` 无氮源）|

## 本代设计要点

1. **给 4 个泛经济里程碑候选真实内容**：`nuclear_fission` / `corporate_agribusiness` / `global_logistics` / `collective_agriculture`。
2. **补化工氮源**：新增 `tech.ammonia_synthesis`。
3. **补两座"整链缺失"**：医疗（`antibiotics_mass_production`）、航空（`military.aviation`）。
4. **补物流跃迁**：`containerization`（C 通道改写船配方 + P 通道）。
5. **补 food_storage 主干**：由 electrical 的 `cold_chain_industry` 延续，本代给 `nuclear_fission` 的副产品（辐照保鲜）或直接用 `antibiotics` 链。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.ammonia_synthesis` | 合成氨 | breakthrough | U+C | 【新】 | 前置 `[tech.synthetic_fertilizer, tech.petrochemical_industry]`；reveal `ALL_OF(SIGNAL(resource.natural_gas), SIGNAL(breakthrough.chemical_process_control))`；解锁 `good:ammonia`（新）、`building:ammonia_plant`（`natural_gas`+`industrial_chemicals`+`electricity` → `ammonia`）；改写 `fertilizer_plant` 配方：新增必需输入 `ammonia`（把"磷肥厂"变成真"化肥厂"）；`country.output.agriculture_factor +0.08` + `country.output.good.fertilizer_factor +0.20` |
| `tech.containerization` | 集装箱化 | breakthrough | C+P | 【新】 | 前置 `[tech.global_logistics? 同代—改 tech.rail_logistics, tech.oceanic_ship_design]`；reveal `SIGNAL(development.trade.quantity_10000)`；**C 通道**：`oceanic_vessels` 配方从 `lumber` 改为 `structural_steel`（集装箱船是钢船）；解锁 `good:container`（新）、`building:container_port`；`country.trade.capacity_factor +0.12` + `country.trade.speed_factor +0.10` |
| `tech.antibiotics_mass_production` | 抗生素量产 | breakthrough | U+S | 【新】 | 前置 `[tech.microbiology, tech.petrochemical_industry]`；reveal `ALL_OF(SIGNAL(breakthrough.chemical_process_control), SIGNAL(development.satisfaction.55_360d))`；解锁 `good:antibiotics`（新）、`building:antibiotics_plant`；`country.population.death_factor -0.08` + `economy.profession.worker.satisfaction_bp +300`；医疗链首个"有建筑"的节点 |
| `tech.military.aviation` | 航空兵 | breakthrough | M+U | 【新】 | 前置 `[tech.military.mechanization, tech.advanced_metallurgy]`；reveal `ALL_OF(SIGNAL(development.output.manufacturing.10000_720d), SIGNAL(breakthrough.chemical_process_control))`；解锁 `good:aircraft`（新）、`building:aircraft_factory`（`aluminum`+`engines`+`electronic_components`+`military_electronics`）；`equipment_categories.aircraft`；兵种 `air_wing`（新）；`country.military.rule.blitz 0.12` + `country.military.vision_add +6` |
| `tech.nuclear_fission` | 核裂变 | breakthrough | U+S | 【改】 | 全局 +0.08 → **解锁 `good:nuclear_fuel`（已有）+ `building:reactor_works`；`country.output.energy_factor +0.15` + `country.output.family.electric_generation_factor +0.20`**；`nuclear_fission` 不再作为 `national_laboratories` 的前置（方向反转）|
| `tech.corporate_agribusiness` | 公司农业 | breakthrough | C+L+G | 【改】 | 全局 +0.08 → **`country.output.family.field_crop_farming_factor +0.20` + `country.output.terrain.plain.agriculture_factor +0.12` + `economy.profession.agricultural_worker.satisfaction_bp -200`**（规模化农业的社会代价）；与 `collective_agriculture` 构成软互斥（`industrialist` vs `cooperative_member` 岗位）|
| `tech.collective_agriculture` | 集体农业 | breakthrough | L+P+G | 【改】 | 全局 +0.08 → **`economy.profession.cooperative_member.satisfaction_bp +400` + `country.tax.income.cooperative_member.rate_bp -400` + `country.output.terrain.steppe.agriculture_factor +0.15`**；与上条构成软互斥 |
| `tech.global_logistics` | 全球物流 | breakthrough | P | 【改】 | 全局 +0.08 → **`country.trade.capacity_factor +0.15` + `country.trade.speed_factor +0.12` + `country.military.supply_transport_factor +0.15`** |
| `tech.public_health_systems` | 公共卫生体系 | breakthrough | S+U | 【改】 | 全局 +0.08 → **`country.population.death_factor -0.06` + `economy.profession.worker.satisfaction_bp +300`**；解锁 `building:general_hospital` |
| `tech.electronic_control` | 电子控制 | breakthrough | U+C | 【改】 | 全局 +0.08 → **`country.production.input_factor -0.06` + `country.output.family.metal_toolmaking_factor +0.15`**；作为 `servomechanism`→`robotic_control` 的中间 |
| `tech.industrial_ecology` | 工业生态 | major | G+P | 【改】 | 全局 +0.04 → **`country.resource.coal.use_factor -0.10` + `country.resource.oil.use_factor -0.10` + `country.climate.profile.dryland_crop.heat_stress_loss_factor -0.08`** |
| `tech.advanced_metallurgy` | 先进冶金 | breakthrough | G+C | 【改】 | 前置 `+= tech.copper_metallurgy`（原为"铜矿井开采"6 代跳）；`extractive_factor` 保留 +0.08；补 `country.output.family.steelmaking_factor +0.15` |
| `tech.mechanized_mining` | 机械化采矿 | breakthrough | G | 【改】 | `extractive_factor +0.18` → **保留 +0.10**；补 `country.output.landform.mountain.extractive_factor +0.15` |
| `tech.deep_geophysics` | 深层地球物理 | major | G+U | 【改】 | `extractive_factor +0.18` → **`country.output.landform.volcano.extractive_factor +0.25` + `country.output.landform.peak.extractive_factor +0.20`** |
| `tech.state_enterprises` | 国营企业 | major | P+S | 【改】 | `extractive_factor +0.08` → **`country.tax.business.<building>.rate_bp +400` + `economy.profession.manager.satisfaction_bp +200`**（软互斥对 G：国家企业 vs 平台市场）|
| `tech.synthetic_fiber_engineering` | 合成纤维工程 | breakthrough | C | 【改】 | 补 `country.output.good.cotton_fiber_factor -0.15` + `country.output.good.wool_factor -0.15`（替代关系）+ `country.output.family.cloth_weaving_factor +0.15` |
| `tech.military.mechanization` | 机械化 | breakthrough | M+U | 【改】 | 删伪前置 `horse_domestication`；补前置 `+= tech.military.continuous_nitration`；`speed_factor +0.15` → **+0.08** |
| `tech.military.main_battle_tanks` | 主战坦克 | breakthrough | M+U | 【改】 | `defense_factor +0.10` → **+0.06**；`country.military.rule.encirclement 0.10` |
| `tech.military.combat_medicine` | 战地医疗体系 | major | M+S | 【改】 | `casualty_factor +0.85` → **+0.20**；补后继 `→ antibiotics` 链 |
| `tech.military.modern_propellants` | 现代发射药 | major | C | 【改】 | 补 `country.input.good.nitric_acid_factor -0.10` |
| `tech.atomic_modernity` | 原子现代 | breakthrough | — | 【保留】 | 里程碑；全局 +0.05 → **+0.025** |
| 其余 atomic 节点 | — | — | — | 【保留】 | 见 JSON 全表 |

**本代新增小计：4**（`ammonia_synthesis` / `containerization` / `antibiotics_mass_production` / `military.aviation`）

---

# 时代 9 · information 信息时代（26 → **31** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.atomic_modernity` |
| 出口里程碑 | `tech.information_society` |
| 非里程碑 | 30 |
| 推进要求 | **24** |
| 可放弃 | 6 |
| 成本三档 | minor ≈3,366,000 / major ≈6,120,000 / breakthrough ≈11,016,000 |
| 本代问题 | ① 新物资 6（倒数）；② 42 座新建筑里 29 座是 `method_*` 克隆；③ 7 个节点被知识部门 route 垄断；④ `nuclear_fission`/`knowledge_economy` 只给全局百分比 |

## 本代设计要点

1. **补 tools 主干**：新增 `tech.robotic_control`（A 审 R5#3）。
2. **补地理大杀器**：新增 `tech.desalination_and_water_reuse`（干旱/海岸生态的翻身节点）。
3. **补两条"整链缺失"**：金融（`financial_services` 已由 E 建议挂在 `central_banking`）与生物材料。
4. **压 `method_*` 克隆**：把 29 座克隆改为"异构化"（B4 规则），至少每座改 1 项输入或岗位。
5. **修 route 垄断**：本代 7 个节点的 route 全是知识部门 → 各加 1 条非知识 route。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.robotic_control` | 机器人控制 | breakthrough | U+C | 【新】 | 放在 `backbone.tools_machinery`；前置 `[tech.servomechanism, tech.digital_control]`；reveal `SIGNAL(breakthrough.automation)`；解锁 `building:robot_cell_works`；`country.output.family.metal_toolmaking_factor +0.20` + `country.production.input_factor -0.06`；作为 `robotic_manufacturing` 与 `automated_agriculture` 的新前置 |
| `tech.desalination_and_water_reuse` | 海水淡化与水回用 | breakthrough | G+U | 【新】 | 前置 `[tech.hydraulic_engineering, tech.semiconductor_manufacturing? 用 tech.electrification]`；简化 `[tech.hydraulic_engineering, tech.electrification]`；reveal `ALL_OF(SIGNAL(landform.coast), ANY_OF(SIGNAL(landform.salt_flat), SIGNAL(landform.arid_basin)))`；解锁 `building:desalination_plant`（产 `salt`，condition `terrain=coast`）；`country.output.terrain.desert.agriculture_factor +0.30` + `country.output.terrain.salt_flat.agriculture_factor +0.25` + `country.output.terrain.oasis.agriculture_factor +0.25` + `country.climate.drought_loss_factor -0.12` —— **干旱生态的翻身节点** |
| `tech.biomaterial_engineering` | 生物基材料 | major | U+C | 【新】 | 前置 `[tech.biotechnology, tech.petrochemical_industry]`；reveal `SIGNAL(bio.rubber)`（或 `SIGNAL(bio.cotton)`）；解锁 `good:biopolymer`（新）、`building:biopolymer_plant`；改写 `plastics` 配方：加 `biopolymer` 为候选输入（`input_candidate_good_ids`）；`country.resource.oil.use_factor -0.08` |
| `tech.environmental_monitoring` | 环境监测 | major | G+P+S | 【新】 | 前置 `[tech.sensor_networks, tech.industrial_ecology]`；reveal `SIGNAL(breakthrough.climate_modeling)`；`country.climate.drought_loss_factor -0.08` + `country.climate.flood_loss_factor -0.08` + `country.resource.coal.use_factor -0.08` |
| `tech.precision_medicine` | 精准医疗 | major | U+S | 【新】 | 前置 `[tech.biotechnology, tech.antibiotics_mass_production]`；reveal `SIGNAL(bio.dye_plant)`（染色/示踪，**启用 0 引用信号**）；解锁 `building:precision_medicine_center`；`country.population.death_factor -0.05` + `economy.profession.researcher.satisfaction_bp +300` |
| `tech.knowledge_economy` | 知识经济 | breakthrough | S+P | 【改】 | 全局 +0.04 → **`country.research.institution_output_factor +0.20` + `country.research.cost_factor -0.08` + `country.tax.income.researcher.rate_bp +300`** |
| `tech.open_science_networks` | 开放科学网络 | major | S | 【改】 | 全局 +0.06 → **`country.research.cost_factor -0.12` + `country.research.science_efficiency +0.10`**；把 `development.trade.partners_8`（不可达）改成 `partners_4` |
| `tech.networked_computing` | 网络计算 | breakthrough | U+P | 【改】 | 全局 +0.04 → **`country.trade.speed_factor +0.10` + `country.research.cost_factor -0.08`**；`partners_8` → `partners_4` |
| `tech.information_society` | 信息社会 | breakthrough | — | 【保留】 | 里程碑；全局 +0.08 → **+0.025** |
| `tech.precision_agriculture` | 精准农业 | breakthrough | C+G | 【改】 | `agriculture_factor +0.08` → **`country.output.family.field_crop_farming_factor +0.20` + `country.output.good.grain_factor +0.15`**；删除 11 条重复 good unlock |
| `tech.satellite_observation` | 卫星观测 | breakthrough | G+U | 【改】 | 补 `country.resource.coal.use_factor -0.08` + `country.output.landform.mountain.extractive_factor +0.12` |
| `tech.automated_logistics` | 自动化物流 | breakthrough | P | 【改】 | 补 `country.trade.capacity_factor +0.12` + `country.trade.speed_factor +0.10` |
| `tech.software_engineering` | 软件工程 | major | U+S | 【改】 | 补 `country.research.engineering_efficiency +0.10` |
| `tech.geographic_information_systems` | 地理信息系统 | major | G+U | 【改】 | 补 `country.output.landform.plateau.agriculture_factor +0.10` + `country.output.terrain.floodplain.agriculture_factor +0.10` |
| `tech.military.network_centric` | 网络中心战 | breakthrough | M+S | 【改】 | 删伪前置 `gunpowder_weapons`；补 `+= tech.military.radio_command`；成本 2,048,000 → **major 档**（消除 29.8× 倒挂）；`frontage_factor +0.15` → **+0.10** |
| `tech.military.precision_guidance` | 精确制导 | breakthrough | M+U | 【改】 | 删伪前置；补 `+= tech.military.modern_propellants`；成本 → major；`attack_factor +0.12` → **+0.06** |
| 其余 information 节点 | — | — | — | 【保留】 / 克隆异构化 | 见 JSON 全表 |

**本代新增小计：5**（`robotic_control` / `desalination_and_water_reuse` / `biomaterial_engineering` / `environmental_monitoring` / `precision_medicine`）

---

# 时代 10 · intelligent 智能时代（24 → **29** 节点）

## 时代定位

| 项 | 值 |
|---|---|
| 入口 | `tech.information_society` |
| 出口 | 无（终局） |
| 成本三档 | minor ≈7,480,000 / major ≈13,600,000 / breakthrough ≈24,480,000 |
| 本代问题 | ① 19/24 是叶子（断头）；② 52 座新建筑里 41 座是 `method_*_r10` 克隆（×7.78 中位倍率，最高 ×522）；③ 只新增 1 个职业（`ai_researcher`）；④ 无新物资（4 个）|

## 本代设计要点

1. **补终局玩法**：新增 5 个"终局生产方式"节点（垂直农业、碳捕集、循环材料、自主水产、精密生物制造），每个都改变配方或岗位，而不是 +%。
2. **补新物资**：`synthetic_fuel`、`composite_material`、`carbon_fiber`。
3. **补终局社会形态**：`human_machine_cogovernance` / `knowledge_cooperatives` 从"全局 +4/8%"改为意识形态与人机治理通道。
4. **压克隆**：41 座 `method_*_r10` 必须异构化。
5. **军事**：`autonomous_warfare` / `ai_defense_grid` 改为条令 + 兵种，而非 +攻防。

## 节点表（变更与新增）

| ID | 名称 | 档 | 通道 | 处理 | 变更 |
|---|---|---|---|---|---|
| `tech.vertical_farming` | 垂直农业 | breakthrough | U+G | 【新】 | 前置 `[tech.precision_agriculture, tech.distributed_intelligence]`；reveal `ALL_OF(SIGNAL(development.settlement.tier_5_1095d), SIGNAL(breakthrough.automation))`；解锁 `good:controlled_crops`（新）、`building:vertical_farm`（condition: `landform ∈ {plain, lowland}`）；新增 `production_climate_profile: controlled_environment`；`country.output.landform.plain.agriculture_factor +0.20` + `country.output.terrain.desert.agriculture_factor +0.20`（不依赖土地）；`country.resource.arable_land.use_factor -0.15` |
| `tech.carbon_capture_and_synthesis` | 碳捕集与合成燃料 | breakthrough | C+G | 【新】 | 前置 `[tech.petrochemical_industry, tech.climate_modeling]`；reveal `SIGNAL(breakthrough.climate_modeling)`；解锁 `good:synthetic_fuel`（新）、`building:carbon_capture_plant`；改写 `refined_fuel` 配方：`synthetic_fuel` 成为候选输入；`country.output.terrain.desert.extractive_factor +0.10`；`country.resource.oil.use_factor -0.12` |
| `tech.circular_materials` | 循环材料 | major | U+P | 【新】 | 前置 `[tech.industrial_ecology, tech.manufacturing? 用 tech.industrial_chemistry]`；解锁 `good:composite_material`（新）、`building:materials_recovery_plant`；`country.production.input_factor -0.06` + `country.resource.limestone.use_factor -0.10` + `country.construction.cost_factor -0.06` |
| `tech.autonomous_aquaculture` | 自主水产 | major | U+L+G | 【新】 | 前置 `[tech.aquaculture, tech.autonomous_systems]`；reveal `SIGNAL(landform.coast)`；解锁 `building:offshore_fish_farm`（condition `terrain=coast`，owner `cooperative_member` 或 `industrialist`，employees `aquaculturist`+`technician`）；`country.output.terrain.coast.extractive_factor +0.20`；`country.output.family.fishing_factor +0.20` |
| `tech.precision_biomanufacturing` | 精密生物制造 | major | U+C | 【新】 | 前置 `[tech.bioinformatics, tech.precision_medicine]`；解锁 `good:carbon_fiber`（新）、`building:bioreactor_works`；改写 `pharmaceuticals` 配方候选；`country.output.family.chemical_industry_factor +0.15` |
| `tech.cognitive_automation` | 认知自动化 | breakthrough | — | 【保留】 | 里程碑；全局 +0.10 → **+0.025**；`science_efficiency +0.20` 保留；**不要在里程碑节点上写硬前置**（运行时被跳过，见 A 审 P1-11）|
| `tech.human_machine_cogovernance` | 人机共治 | breakthrough | S | 【改】 | 全局 +0.04 → **`country.ideology.point_gain_factor +0.15` + `country.ideology.offer_choice_bonus +1` + `country.ideology.era_decay_floor_bp +1500`**（`new_content` 级别的意识形态通道，全树唯一）|
| `tech.knowledge_cooperatives` | 知识合作社 | breakthrough | L+P | 【改】 | 全局 +0.08 → **`economy.profession.cooperative_member.satisfaction_bp +500` + `country.tax.income.cooperative_member.rate_bp -400` + `country.research.cost_factor -0.08`** |
| `tech.algorithmic_governance` | 算法治理 | major | S+P | 【改】 | 补 `country.tax.business.<building>.rate_bp +300` + `country.tax.income.manager.rate_bp +200` |
| `tech.algorithmic_management` | 算法管理 | major | L+S | 【改】 | 补 `economy.profession.manager.satisfaction_bp -200` + `country.production.input_factor -0.04` |
| `tech.human_machine_collaboration` | 人机协作 | major | L | 【改】 | 补 `economy.profession.technician.satisfaction_bp +300` + `country.output.family.manufacturing_generic_factor +0.15` |
| `tech.autonomous_labor_coordination` | 自主劳动协调 | major | L+P | 【改】 | 补 `country.production.input_factor -0.06` + `economy.profession.industrial_worker.satisfaction_bp -300` |
| `tech.autonomous_systems` | 自主系统 | breakthrough | U+C | 【改】 | 补 `country.production.input_factor -0.06`；解锁 `good:autonomous_systems` 已有 |
| `tech.machine_learning` | 机器学习 | breakthrough | S | 【改】 | 补 `country.research.cost_factor -0.10` + `country.research.science_efficiency +0.10` |
| `tech.neural_networks` | 神经网络 | major | S | 【改】 | `extractive_factor +0.12` → **`country.research.engineering_efficiency +0.10` + `country.output.family.metal_toolmaking_factor +0.10`** |
| `tech.scientific_agents` | 智能科学代理 | major | S | 【改】 | `extractive_factor +0.12` → **`country.research.cost_factor -0.12`** |
| `tech.intelligent_breeding` | 智能育种 | breakthrough | U+C | 【改】 | `agriculture_factor` 若有 → **`country.output.good.grain_factor +0.15` + `country.output.good.potatoes_factor +0.15`**；解锁 `good:elite_seed`（可选）|
| `tech.autonomous_mining` | 自主采矿 | breakthrough | G+L | 【改】 | `extractive_factor +0.22` → **保留 +0.10**；`country.output.landform.mountain.extractive_factor +0.20`；`economy.profession.miner` 槽位 −50%（`employee_slots`）|
| `tech.smart_grid` | 智能电网 | major | G+P | 【改】 | 补 `country.output.energy_factor +0.08` + `country.resource.coal.use_factor -0.06` |
| `tech.military.autonomous_warfare` | 自主作战 | breakthrough | M+U | 【改】 | 删伪前置 `gunpowder_weapons`；成本 3,200,000 → **major 档**（消除 30.4× 倒挂）；`attack_factor +0.10` → **+0.05**；`country.military.rule.blitz 0.10`；兵种 `drone_swarm`（新）|
| `tech.military.ai_defense_grid` | 智能防御网 | breakthrough | M+S | 【改】 | `defense_factor +0.10` → **+0.05**；`country.military.rule.home_ground 0.12` + `country.military.rule.mutual_support 0.10` |
| 其余 intelligent 节点 | — | — | — | 【保留】 / 克隆异构化 | 见 JSON 全表 |

**本代新增小计：5**（`vertical_farming` / `carbon_capture_and_synthesis` / `circular_materials` / `autonomous_aquaculture` / `precision_biomanufacturing`）

---

# 全树汇总

| 时代 | 原节点 | 新增 | 删除 | 新节点数 | 非里程碑 | 推进要求(80%) | 可放弃 |
|---|---|---|---|---|---|---|---|
| stone | 56 | 0 | 1（`reed_identification`）| **55** | 54 | 44 | 10 |
| agrarian | 51 | 4 | 0 | **55** | 54 | 44 | 10 |
| kingdom | 57 | 3 | 4（`pottery`/`loom_weaving`/`copper_ore_roasting`/`irrigation_surveying`）| **56** | 55 | 44 | 11 |
| empire | 43 | 4 | 0 | **47** | 46 | 37 | 9 |
| exploration | 35 | 5 | 0 | **40** | 39 | 32 | 7 |
| enlightenment | 31 | 6 | 0 | **37** | 36 | 29 | 7 |
| steam | 33 | 4 | 0 | **37** | 36 | 29 | 7 |
| electrical | 30 | 6 | 0 | **36** | 35 | 28 | 7 |
| atomic | 30 | 4 | 0 | **34** | 33 | 27 | 6 |
| information | 26 | 5 | 0 | **31** | 30 | 24 | 6 |
| intelligent | 24 | 5 | 0 | **29** | 28 | 23 | 5 |
| **合计** | **416** | **46** | **5** | **457** | **447** | **361** | **85** |

**节点增加 41 个（+9.9%）**，全部落在中后段；后期"节点少、内容多"的失衡被抹平（后 4 代从 110 增到 130）。
**可放弃节点从 73 增到 85**（80% 规则不变时，节点变多 → 绝对放弃空间略增）。

## 支线健康度改善

| 支线 | 改造前终止时代 | 改造后 | 关键补链 |
|---|---|---|---|
| 块茎高地农业 | kingdom | **intelligent**（经 `mountain_irrigation` → `vertical_farming`）| empire +1、intelligent +1 |
| 热带商品农业 | exploration | **steam**（经 `plantation_processing` → `sugar_refining` → `biomass_engineering`）| exploration +2、information +1 |
| 森林木材生物质 | steam | **intelligent**（经 `forest_products_industry` → `circular_materials`）| electrical +1、intelligent +1 |
| 建材公共工程 | steam | **intelligent**（经 `structural_steel` → `circular_materials`）| steam +1、intelligent +1 |
| 水风水务 | empire | **information**（经 `polder_engineering` → `desalination_and_water_reuse`）| enlightenment +1、information +1 |
| 土地制度 | enlightenment | **intelligent**（经 `collective_agriculture` → `knowledge_cooperatives`）| atomic/intelligent 内容化 |
| 石油石化 | atomic | **intelligent**（经 `biomaterial_engineering` → `carbon_capture_and_synthesis`）| information +1、intelligent +1 |
| 公共卫生 | atomic（6 节点）| **information**（6 → 11 节点）| enlightenment +1、steam +1、atomic +1、information +1 |
| 军工（新 `branch.military_doctrine`） | — | 12 节点跨 9 代 | agrarian +1、kingdom +1、empire +1、exploration +1、enlightenment +1、steam +1、electrical +1、atomic +1 |
