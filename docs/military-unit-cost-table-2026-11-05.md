# 全兵种生产成本 / 维护成本表（2026-11-05）

> 数据源：`Project/project-keynes/data/military/military_catalog.json`（24 单位，schema 1）、`data/goods/*.tres` 的 `default_price`、原生 `gdext/src/military_core*.cpp`。
> 全部为**目录数值**，非运行实测。金额单位：`default_price` 是 `MONEY_SCALE=10000` 的 subunit，表中 `money` = subunit/10000（`gdext/src/military_bridge.h:11, 20`）。
> 配套审查：`docs/military-content-design-review-2026-11-05.md`。
>
> **2026-11-05 二次修复**：§1 / §2 表格记录的是二次修复**前**的目录数值。现已把 `tribal_warriors.tech` 从空串改为 `tech.composite_tools`、把 `militia` 的 `supply_idle/combat.upkeep` 从 `0.05/0.15` 改为 `0`。详见 §7。
>
> **2026-11-05 三次修复**：§7 只处理 day 0；§8 把「兵种解锁 ⇒ 每件装备可生产」推广到全 24 兵种。`bronze_spearmen.tech` 亦已改为 `tech.hide_tanning`，§1 表 A 里青铜矛兵的解锁科技列已过时。

## 0. 口径（很重要：目录里没有「招募成本」字段）

`military_catalog.json` 的 unit 字段只有 `id/name/description/class/era/tech/militia/attack/defense/speed/fortification_ignore/training_days/equipment/supply_idle/supply_combat/icon`（`:3-1023`），**没有 `recruit_cost` / `build_cost`**。契约文档 `docs/plans/military-implementation-contract.md:99-103` 同样没有。

| 类别 | 目录里有什么 | 实际上是什么 |
|---|---|---|
| 一次性投入 | `equipment[].per_100` + `min_quality` + `weight` | 每 100 人需采购的装备件数，按下表单价折算成金额；由 `military_core_logistics.cpp:1040-1057` 生成训练订单 demand |
| 一次性投入 | `training_days` | **纯时间**（0–80 天），不扣资源；运行时还乘 `kind_factor`（同类 0.4 / 跨类 0.8 / 同兵种 0.25，`military_core.cpp:361-365`），目录 `defaults.training_kind_factor_q16` 是未被读取的死数据 |
| 招募 | 无字段 | `run_recruitment`（`military_core.cpp:1783-1924`）只做人口→士兵转移，无资源检查、无扣款、无科技闸；新兵 lot 一律 `militia_unit`（`:1887-1889`） |
| 兵营 | `state_buildings[].materials` / `capacity` / `upkeep` | 非兵种级；见 §3 |
| 持续维护 | `supply_idle` / `supply_combat` 五个键 `ration/fodder/ammunition/fuel/upkeep` | 每 100 人·日的 goods 单位，见 §2 与 §5 换算 |
| 持续维护 | 无字段 | 军饷 wage、口粮 ration 是**按人头的全局量**，24 兵种同价，见 §3 |

装备金额算法：每个 slot 按 `min_quality` 取 `equipment_categories[].goods` 中同 quality 的 good，金额 = `per_100 × default_price`。所有 slot 的 `min_quality` 都能精确匹配到档位，无近似。`horses` 无 `default_price`（动态定价），单列；`reference_max_price = 500000`（= 50 money/件）只作上限参考，**不是成交价**。

---

## 1. 表 A｜一次性投入（每 100 人）

| 单位 | id | era / 解锁科技 | 装备槽（类别 Q / good × 件） | 固定价金额 (money) | 动态价坐骑 | 按参考上限合计 | 训练天 | 攻/防 |
|---|---|---|---|---|---|---|---|---|
| 民兵 | `militia` | 0 / 无门槛 | 无 | **0.00** | — | 0.00 | **0** | 0.5/0.6 |
| 部落战士 | `tribal_warriors` | 0 / 无门槛 | melee_arms Q1 `stone_spears`×10 + missile_arms Q1 `bows`×6 | **21.00** | — | 21.00 | 20 | 1.0/1.0 |
| 青铜矛兵 | `bronze_spearmen` | 1 / `tech.bronze_casting` | melee_arms Q2 `bronze_weapons`×12 + body_armor Q1 `hide_armor`×6 + missile_arms Q1 `bows`×4 | 46.80 | — | 46.80 | 30 | 1.6/2.2 |
| 战车兵 | `chariot_troops` | 1 / `tech.military.chariot_warfare` | mounts Q1 `horses`×28 + melee_arms Q2 `bronze_weapons`×6 | 15.60 | horses×28 | 1415.60 | 40 | 2.6/1.2 |
| 铁甲步兵 | `iron_infantry` | 2 / `tech.military.standing_army` | melee_arms Q3 `iron_weapons`×12 + body_armor Q2 `iron_armor`×8 + missile_arms Q1 `bows`×6 | 86.60 | — | 86.60 | 30 | 2.4/3.2 |
| 骑兵 | `cavalry` | 2 / `tech.military.mounted_warfare` | mounts Q1 `horses`×25 + melee_arms Q3 `iron_weapons`×8 + body_armor Q1 `hide_armor`×4 | 40.00 | horses×25 | 1290.00 | 40 | 3.4/1.8 |
| 军团步兵 | `legionaries` | 3 / `tech.military.legion_logistics` | melee_arms Q3 `iron_weapons`×12 + body_armor Q3 `plate_armor`×12 + missile_arms Q1 `bows`×6 | 129.00 | — | 129.00 | 30 | 3.6/4.6 |
| 攻城营 | `siege_train` | 3 / `tech.military.siegecraft` | ordnance Q1 `siege_engines`×20 | 172.00 | — | 172.00 | 45 | 4.0/1.0 |
| 甲骑具装 | `heavy_cavalry` | 3 / `tech.military.heavy_cavalry` | mounts Q1 `horses`×30 + body_armor Q3 `plate_armor`×15 + melee_arms Q3 `iron_weapons`×8 | 120.60 | horses×30 | 1620.60 | 45 | 5.0/3.6 |
| 火枪兵 | `musketeers` | 4 / `tech.gunpowder_weapons` | firearms Q1 `matchlocks`×10 + melee_arms Q3 `iron_weapons`×4 | 62.80 | — | 62.80 | 35 | 6.0/4.0 |
| 野战炮兵 | `field_artillery` | 4 / `tech.military.field_artillery` | ordnance Q2 `bronze_cannon`×6 + mounts Q1 `horses`×10 | 88.80 | horses×10 | 588.80 | 50 | 8.5/2.0 |
| 线列步兵 | `line_infantry` | 5 / `tech.military.drill_regulations` | firearms Q2 `flintlocks`×12 | 74.40 | — | 74.40 | 35 | 8.0/6.5 |
| 龙骑兵 | `dragoons` | 5 / `tech.military.drill_regulations` | mounts Q1 `horses`×25 + firearms Q2 `flintlocks`×8 | 49.60 | horses×25 | 1299.60 | 45 | 8.5/5.0 |
| 步枪兵 | `riflemen` | 6 / `tech.military.rifled_weapons` | firearms Q3 `rifles`×10 | 88.00 | — | 88.00 | 40 | 12/10 |
| 重炮兵 | `heavy_artillery` | 6 / `tech.military.rifled_weapons` | ordnance Q3 `steel_artillery`×12 | 278.40 | — | 278.40 | 55 | 18/3 |
| 机枪步兵 | `machine_gunners` | 7 / `tech.military.machine_guns` | firearms Q4 `automatic_rifles`×14 | 193.20 | — | 193.20 | 45 | 16/16 |
| 早期装甲 | `early_armor` | 7 / `tech.military.armored_warfare` | armored_vehicles Q1 `early_tanks`×4 | 184.00 | — | 184.00 | 60 | 26/18 |
| 机械化步兵 | `mechanized_infantry` | 8 / `tech.military.mechanization` | firearms Q4 `automatic_rifles`×10 + mounts Q1 `horses`×6 + body_armor Q4 `ballistic_armor`×6 | 195.60 | horses×6 | 495.60 | 55 | 24/24 |
| 坦克部队 | `tank_corps` | 8 / `tech.military.main_battle_tanks` | armored_vehicles Q2 `modern_tanks`×8 | 624.00 | — | 624.00 | 65 | 40/32 |
| 自行火炮 | `sp_artillery` | 8 / `tech.military.mechanization` | ordnance Q4 `howitzers`×8 + mounts Q1 `horses`×4 | 304.00 | horses×4 | 504.00 | 65 | 45/12 |
| 合成部队 | `combined_arms` | 9 / `tech.military.network_centric` | armored_vehicles Q2 `modern_tanks`×4 + firearms Q4 `automatic_rifles`×8 + ammunition Q1 `powder_shot`×6 | 438.00 | — | 438.00 | 70 | 45/45 |
| 导弹炮兵 | `missile_artillery` | 9 / `tech.military.precision_guidance` | ordnance Q5 `missile_launchers`×4 + ammunition Q4 `guided_munitions`×4 | 323.20 | — | 323.20 | 75 | 60/15 |
| 外骨骼步兵 | `exo_infantry` | 10 / `tech.military.autonomous_warfare` | firearms Q5 `smart_rifles`×10 + body_armor Q4 `ballistic_armor`×10 + ammunition Q1 `powder_shot`×4 | 366.40 | — | 366.40 | 80 | 60/70 |
| 无人作战集群 | `drone_swarm` | 10 / `tech.military.autonomous_warfare` | drones Q1 `combat_drones`×10 | 320.00 | — | 320.00 | 80 | 80/50 |

固定价合计 4222.00 money/百人（24 单位一次全买齐）。装备件数/百人范围 0（民兵）～53（甲骑具装），**不随时代单调**：era5 线列步兵只要 12 件，era10 无人机只要 10 件。

---

## 2. 表 B｜持续维护（目录原值，每 100 人·日）

格式 `ration / fodder / ammunition / fuel / upkeep`；只列非零项。

> **第四列的定义（修复后）**：指该兵种 `supply_*` 里的维护数值会不会变成一笔库存物资扣减——`military_core_logistics.cpp:1819` 的 `stock_add(..., -take)` 与 `:1825` 的 `MILITARY_INTENT_CONSUME_TREASURY_GOOD`。判定取决于该补给类在 `supply` 块里是否有非空的候选 goods 列表（`_catalog.supply_goods[cls]`）：候选为空 → 采购侧 `:1064` 与消费侧 `:1787-1809` 都跳过。
> **更正**：修复前这一列**全部应为「无」**，不只是本表初版写的 upkeep/ammunition。`_compile_supply` 原地修改 Array 内的 Packed 数组，GDScript 写时复制让修改落在临时副本上，**6 类候选表全部为空**（含 ration/fodder/fuel）。2026-11-05 已修，见 §5；下表按修复后行为列。
> 全局军饷、全局口粮与官营建筑现金维护始终按人头/按建筑结算，与这一列无关（§3）。

| 单位 | idle | combat | 修复后产生物资扣减的补给类 |
|---|---|---|---|
| 民兵 | upkeep 0.05 | upkeep 0.15 | upkeep |
| 部落战士 | upkeep 0.05 | upkeep 0.15 | upkeep |
| 青铜矛兵 | upkeep 0.05 | upkeep 0.15 | upkeep |
| 战车兵 | fodder 2, upkeep 0.05 | fodder 3, upkeep 0.20 | fodder, upkeep |
| 铁甲步兵 | upkeep 0.05 | upkeep 0.15 | upkeep |
| 骑兵 | fodder 2, upkeep 0.05 | fodder 3, upkeep 0.20 | fodder, upkeep |
| 军团步兵 | upkeep 0.05 | upkeep 0.15 | upkeep |
| 攻城营 | ammunition 0.1, upkeep 0.05 | ammunition 3, upkeep 0.25 | ammunition, upkeep |
| 甲骑具装 | fodder 2, upkeep 0.05 | fodder 3, upkeep 0.20 | fodder, upkeep |
| 火枪兵 | ammunition 0.05, upkeep 0.03 | ammunition 0.8, upkeep 0.13 | ammunition, upkeep |
| 野战炮兵 | fodder 0.5, ammunition 0.1, upkeep 0.05 | fodder 0.75, ammunition 3.5, upkeep 0.25 | fodder, ammunition, upkeep |
| 线列步兵 | ammunition 0.05, upkeep 0.03 | ammunition 1, upkeep 0.13 | ammunition, upkeep |
| 龙骑兵 | fodder 2, ammunition 0.05, upkeep 0.03 | fodder 3, ammunition 1, upkeep 0.18 | fodder, ammunition, upkeep |
| 步枪兵 | ammunition 0.05, upkeep 0.03 | ammunition 1.2, upkeep 0.13 | ammunition, upkeep |
| 重炮兵 | ammunition 0.1, upkeep 0.05 | ammunition 4, upkeep 0.25 | ammunition, upkeep |
| 机枪步兵 | ammunition 0.05, upkeep 0.03 | ammunition 1.4, upkeep 0.13 | ammunition, upkeep |
| 早期装甲 | fuel 1, upkeep 0.05 | ammunition 1.5, fuel 3, upkeep 0.25 | ammunition, fuel, upkeep |
| 机械化步兵 | fuel 1, upkeep 0.05 | ammunition 1.5, fuel 3, upkeep 0.25 | ammunition, fuel, upkeep |
| 坦克部队 | fuel 1, upkeep 0.05 | ammunition 1.5, fuel 3, upkeep 0.25 | ammunition, fuel, upkeep |
| 自行火炮 | ammunition 0.1, fuel 1, upkeep 0.05 | ammunition 4.5, fuel 2, upkeep 0.25 | ammunition, fuel, upkeep |
| 合成部队 | ammunition 0.05, fuel 0.5, upkeep 0.05 | ammunition 2, fuel 1.5, upkeep 0.25 | ammunition, fuel, upkeep |
| 导弹炮兵 | ammunition 0.1, fuel 0.5, upkeep 0.05 | ammunition 4, fuel 1, upkeep 0.25 | ammunition, fuel, upkeep |
| 外骨骼步兵 | ammunition 0.05, upkeep 0.05 | ammunition 1.5, upkeep 0.25 | ammunition, upkeep |
| 无人作战集群 | fuel 1, upkeep 0.05 | ammunition 0.5, fuel 2.5, upkeep 0.25 | ammunition, fuel, upkeep |

统计：
- `ration` 列 **24/24 全为 0**（真正口粮走全局 `ration_need_per_head_q16`）。
- `upkeep` idle 只有 **0.03 / 0.05** 两档，combat 只有 **0.13 / 0.15 / 0.18 / 0.20 / 0.25** 五档，**与 era 无关**：0.05 出现在 era0 民兵，也出现在 era10 无人机；0.03 反而给了 era4–7 的火器步兵。
- 有需求的单位数：`upkeep` 24、`ammunition` 16、`fuel` 7、`fodder` 5。
- **修复前**：6 类候选表全空，24/24 单位没有任何兵种专属物资扣减；**修复后**：24/24 至少结算 `upkeep`，按需叠加 ammunition / fodder / fuel（`equipment` 类走装备槽路径，不在此列）。
- `upkeep 0.05` 在 100 人规模经整数除法仍为 0（见下方换算），小部队实际扣减量可忽略——这是**数值量级**问题，不是候选表 bug。

### 运行时的数值换算

`_supply_vector`（`scripts/military/military_catalog_compiler.gd:489-498`）把原值转成 6 元素 float 向量；`read_supply`（`gdext/src/world_ext_military.cpp:395-419`）用 `goods_from_units()` 乘 `MILITARY_GOODS_SCALE=1000`（`military_bridge.h:21`），例如 `upkeep 0.05 → 50`。消费侧 `military_core_logistics.cpp:1769`：

```
goods = (heads * per_100) / (100 * MILITARY_GOODS_SCALE)
```

即 100 人 × 0.05 → 0.05 goods → 整数除法 **0**；约 2000 人以上才产生 1 个 goods 单位。小部队的维护费率在整数运算下基本归零。

---

## 3. 表 C｜非兵种级共用成本（所有 24 兵种同价）

| 成本 | 公式 / 数值 | 周期 | 证据 |
|---|---|---|---|
| 军饷 wage | `wage_mode=ABSOLUTE` → 政策值；`AUTO` → `country_soldier_living_cost × MSTAT_WAGE`（默认 `wage_factor_q16 = 85197` ≈ 1.30，可被 modifier 覆盖）；乘 `_lots.count[i]` | 每天 | `military_core.cpp:2384-2393, 2412-2419`；`military_catalog.json:1571` |
| 口粮 ration | 全局 `ration_need_per_head_q16 × heads`（由 `soldier_household` 消费计划的 `staple_food/protein` 推导），战时 ×1.25（`combat_ratio_q16=81920`） | 每天 | `military_core_logistics.cpp:904-905, 947-952, 1749-1761`；`military_catalog.json:1495-1501` |
| 征兵 levy | `levy_cap = pop × levy_rate_bp/10000`，默认 `levy_rate_bp = 300`（3%） | 每 5 天采样 | `military_core.cpp:1863, 1899`；`military_catalog.json:1570` |
| 官营建筑现金维护 | `upkeep_per_day` 0.02（战士营地）～ 15（训练中心），**每 5 天**扣一次 × 建筑数 | 每 5 天 | `military_core.cpp:2534-2567`；`military_catalog.json:1192-1440` |
| 官营建筑建材 | 例：战士营地 logs 20 + turf_block 10、capacity 4、10 天工期；训练中心 concrete 150 + computers 10 + telecom_equipment 10 | 一次性 | `military_catalog.json:1192-1208, 1424-1440` |
| 装备采购 | 训练订单生成 demand，`qty = count × per_100 / 100`；但训练下单瞬间 `transfer_garrison` 已把 lot 改成目标兵种，`equipment_ready` 只 gate 计时 | 训练时 | `military_core_logistics.cpp:1040-1057, 1518-1523`；`military_core.cpp:2057, 3195-3197` |
| 军事预算信封 | `budget_share_bp / budget_wage_bp / budget_upkeep_bp / procurement_share_bp` 三通道切**现金**上限 | 每天 | `military_core_budget.cpp:55` |

官营建筑 `upkeep_per_day` 全量：`warrior_lodge 0.02`、`palisade_barracks 0.05`、`garrison_barracks 0.15`、`legion_fort 0.4`、`drill_depot 1`、`army_depot 2.5`、`military_base 6`、`training_complex 15`、`earthen_rampart 0.05`、`stone_walls 0.15`、`citadel 0.3`、`star_fort 0.5`、`bunker_line 1`、`hardened_defense_network 3`、`martial_academy 0.2`、`military_academy 0.5`、`war_simulation_center 8`。

---

## 4. 表 D｜装备物资单价（`data/goods/*.tres` 的 `default_price`，subunit）

| 类别 | Q1 | Q2 | Q3 | Q4 | Q5 |
|---|---|---|---|---|---|
| 兵器 melee_arms | stone_spears 12000 | bronze_weapons 26000 | iron_weapons 42000 | steel_blades 68000 | — |
| 弓箭 missile_arms | bows 15000 | — | — | — | — |
| 护具 body_armor | hide_armor 16000 | iron_armor 34000 | plate_armor 58000 | ballistic_armor 96000 | — |
| 火器 firearms | matchlocks 46000 | flintlocks 62000 | rifles 88000 | automatic_rifles 138000 | smart_rifles 260000 |
| 火炮 ordnance | siege_engines 86000 | bronze_cannon 148000 | steel_artillery 232000 | howitzers 380000 | missile_launchers 640000 |
| 坐骑 / 战车 mounts | horses **动态价** | war_chariots 52000 | — | — | — |
| 装甲车辆 armored_vehicles | early_tanks 460000 | modern_tanks 780000 | — | — | — |
| 弹药 ammunition | powder_shot 26000 | cartridges 44000 | modern_munitions 76000 | guided_munitions 168000 | — |
| 作战无人机 drones | combat_drones 320000 | — | — | — | — |

`horses.tres` 无 `default_price`，只有 `reference_max_price = 500000`（50 money）、`price_adjust_q16 = 922`、`demand_price_elasticity_q16 = 29491`。表 A 的「按参考上限合计」只是把动态 goods 按上限代入，用于数量级比较，**不代表真实成交价**。

---

## 5. 根因与修复（2026-11-05）

**两个叠加的 bug**：

1. **数据层**：`supply.ammunition` 被写成 Dictionary（契约 `docs/plans/military-implementation-contract.md:107` 规定应为 `"@ammunition"`，编译器有专用分支）；`supply.upkeep` 被写成未实现的字符串 `"primary_equipment_slot"`（设计文档 `military-system-design.md:591` 的意图是「该兵种主装备槽所在类别的物资」，但现有 ABI 是按补给类全局索引的 `supply_goods[6]`，无法逐兵种表达）。编译器对这两种类型直接 `continue`，静默产出空候选。
2. **编译器层（更根本）**：`_compile_supply` 用 `(supply_goods[cls] as PackedInt32Array).append(...)` 原地修改 Array 内的 Packed 数组；GDScript 的写时复制让修改落在临时副本上，**6 类候选表全部为空**，包括原本以为有效的 ration / fodder / fuel。headless 探针实测：原地 append 后 `size=0`，整体赋值后 `size=2`。生产路径走 `compile()` 而非 `validate()`（后者只由 tools/tests 调用），所以空表一路进了原生。

**修复**：

- `data/military/military_catalog.json`：`ammunition` 改回 `"@ammunition"`（原 efficiency 表移到 `ammunition_efficiency_q16` 保留设计资料）；`upkeep` 改为 12 个明确的装备物资候选——原生 `military_core_logistics.cpp:1790-1792` 每类最多遍历 `MILITARY_MAX_SUPPLY_CLASSES * 2 = 12` 个候选，故取 12 个覆盖各时代的代表性装备。
- `scripts/military/military_catalog_compiler.gd`：改为「局部构建 PackedInt32Array → 整体赋值回 Array」，绕开写时复制；未知字符串标记与非法类型不再静默跳过而是 `_fail`；`equipment` 类显式豁免（走装备槽路径）；候选数超过 12 直接报错；`validate()` 新增「有单位需求但候选为空」硬校验。
- `tests/military/military_supply_catalog_test.gd`：钉死四类候选非空、非法值被拒、空需求行被 validate 拒绝。

**验证**：`godot --headless --path Project/project-keynes -s res://tests/military/military_supply_catalog_test.gd` → `=== military supply catalog: ok ===`；既有 `military_roster_gate_test.gd` → `=== military roster gate: ok ===`。

**已知限制 / 风险**：

- `catalog_hash` 把 `supply_goods` 每行混入（`military_catalog_compiler.gd:926-933`），候选表从空变非空 → hash 改变 → **旧 PKMI 存档会 hash mismatch**，需迁移或作废旧档。
- `upkeep` 从设计里的「主装备槽」退化为「12 个全局装备物资」近似，且 C++ 按 yield 排序优先扣列表靠前、库存里有的货；要忠实实现逐兵种主槽需改 `MilitaryUnitType` + ABI + 存档。
- 修复后首次新增一条持续的物资流出（24 兵种 upkeep + 16 兵种弹药），国库曲线、`per_soldier_cost`、AI 预算与 selftest 补给平衡需重标。
- `ration` 候选若超过 12 个仍会被原生截断（本次未改，属既有上限）。

---

## 6. 一眼能看出的数值设计问题

1. **民兵 = 0 装备 / 0 训练 / 0 差异化维护**；部落战士 21 money + 20 天换 +82% 战力，但两者 `supply_*` 完全相同（0.05/0.15）。
2. **`upkeep` 无时代梯度**：era0 与 era10 同为 0.05；0.03 反而给中期火器步兵，与科技成本梯度（8160 → 3200000 RP）完全脱钩。
3. **装备金额与战力不成比例**：坦克部队 624 money 换 40/32，自行火炮 504 money 换 45/12，而线列步兵 74.4 money 就有 8/6.5。
4. **含坐骑单位金额被动态价 dominate**：战车兵固定价只有 15.60，加上 28 匹马才 1415.60；这一列的数值完全由动态市场决定，目录数值几乎不表达设计意图。
5. **修复前 24/24 单位没有任何兵种专属物资扣减**（6 类候选表全空，不只是初版判断的 11 个）；修复后才恢复，但 `upkeep 0.05` 从 era0 到 era10 无梯度的问题仍在（§2 统计）。
6. 详见配套审查报告 §2 与 §6 的修复方向（`supply.upkeep` 改 Array、装备接进实战公式、按 era 拉开维护成本）。

---

## 7. 开局兵种 / 物资解锁对齐（2026-11-05 二次修复）

**问题**：§1 / §2 的表格是本次修复前的目录数值。`tech: ""` 的两个兵种在 day 0 恒解锁，但物资侧的 `GoodProfile.technology_tags`（运行时 ANY，任一命中即解锁）与开局科技集合无交集：

| 引用 | 物资 | 解锁科技 | day 0 |
|---|---|---|---|
| `tribal_warriors.equipment` Q1 | `stone_spears` | `tech.stone_knapping` | 锁 |
| `tribal_warriors.equipment` Q1 | `bows` | `tech.composite_tools` / `legion_logistics` / `standing_army` | 锁 |
| `supply.upkeep`（两兵种 `0.05/0.15`） | 12 个装备物资 | 全部中后期科技 | 锁 |
| `supply.fodder` | `gathered_plants` | `tech.gathering` | 开（但两兵种 `fodder` 均为 0） |

开局科技集合 = `technology_network.json` 中 7 个 `is_starter_eligible` 节点（采集 / 狩猎 / 早期贸易 / 淘金 / 刮皮 / 枯枝 / 地表银）经 `start_location_policy.gd` 按出生点挑选的子集；`data/goods/*.tres` 167/167 都有非空 `technology_tags`，`initial_stock` 全为 0，开局也没有预建的军工产能。于是「兵种可见、可点」与「一件货都拿不到」同时成立。

**修复**（`data/military/military_catalog.json`）：

| 字段 | 修复前 | 修复后 |
|---|---|---|
| `tribal_warriors.tech` | `""`（恒解锁） | `"tech.composite_tools"` |
| `militia.supply_idle.upkeep` | `0.05` | `0.0` |
| `militia.supply_combat.upkeep` | `0.15` | `0.0` |

选 `tech.composite_tools` 而非 `tech.stone_knapping` 或审查报告 §6 A5 建议的 `tech.military.war_bands`：它是**能同时解锁石矛与弓的最早节点**——其硬前置闭包含 `stone_knapping`（→ `stone_spears`），本身又是 `bows` 三个 tag 里最早可研究的一个；`war_bands` 还额外要求 `communal_specialization`，更晚。民兵是唯一保留恒解锁的兵种，与「不需要装备」的描述一致，不再有任何兵种专属物资需求；开局唯一相关成本仍是全局军饷与口粮（§3，按人头，与兵种无关）。

**结构性防线**：`tests/military/military_unit_unlock_consistency_test.gd` 同时加载正式军事目录、`EconomyCatalog.compile_native_catalog()` 的 `good_technology_tags`、科技树的 `hard_prerequisite_ids` 闭包，断言「恒解锁兵种不得引用开局未解锁物资」，并用一个把 `tech` 改回空串的负例证明校验不是假 PASS。`tests/military/military_roster_gate_test.gd` 同步改为只把民兵当恒解锁兵种，并新增「研究 `composite_tools` 才解锁部落战士」的断言。

**验证**：三个 headless 测试均 `ok`（新增一致性测试、`military_supply_catalog_test`、`military_roster_gate_test`）。`military_native_binding_test` 除已知的 `bench big p95 <= 2ms`（实测 19.85 ms，军事运行时 Skill 已记录为未达标项）外全 PASS，含 PKMI round trip 与 determinism。

**影响与遗留**：

- `units[].tech` 与 `supply_*.upkeep` 都进 `catalog_hash`（`military_catalog_compiler.gd`），叠加 §5 的补给候选修复后，旧 PKMI 存档会 hash mismatch，需新开局。
- 名册 UI 现在把部落战士显示为锁定并标出《复合工具》；开局军事侧仍是零兵（审查报告 §4.1 的 `posts_for_cell=0` 未改）。本次只解决「解锁与物资」的一致性，不解决开局兵额与装备产能。
- 当时另有 13 个有科技门的兵种存在同类闭包缺口，已在三次修复中全量解决，见 §8。

---

## 8. 全兵种装备链对齐（2026-11-05 三次修复）

**两条诉求**：① §7 遗留的「13 个有科技门兵种，部分装备物资不在其 `tech` 硬前置闭包内」很严重；② 只要有一件装备没解锁、玩家无法生产，即便兵种已解锁仍然严重——例如火枪兵的「兵器」类别里石矛很早就解锁，但它指定的 Q3 是铁兵器，而真正的核心装备是火枪。

**判据（比 §7 更严）**：对每个 `tech != ""` 的兵种、每个 `equipment[]` 槽，**只认 `min_quality` 指定的那一档 goods**（运行时采购只按 `category_of_good` 匹配，允许同类别低档货替代，但那不是作者指定的装备），要求同时满足：

1. 该 goods 的 `technology_tags` 至少一个命中 `tech` 的硬前置闭包（含 `tech` 自身）→ 生产许可；
2. 至少一个产出建筑的 `technology_tags`(ANY) 与 `required_technology_tags`(ALL) 也在闭包内 → 产能许可。

实测 28/28 个装备物资的 `technology_tags` 与其产出建筑的标签完全一致，所以补齐「物资解锁科技」通常同步补齐产能。全库 24 兵种共 46 个有科技门的装备槽，修复前 13 个兵种存在缺口。

**修复**（纯数据，不动 C++ / ABI）：

- `data/technology/technology_network.json`：给 13 个兵种科技补 20 条 `hard_prerequisite_ids`，每条选同代或更早、最早可研究的产业链科技（骑兵补 `hide_tanning`/`iron_smelting`、火枪兵补 `iron_smelting`、机械化步兵补 `machine_guns`/`synthetic_fiber_engineering` 等），并同步补 20 条 `prerequisite_rationales`（`technology_network_design_test.gd:186` 强制两者数量相等）。全部满足 dense id 拓扑序（前置索引必须更小），无环、无时代倒挂。
- `data/military/military_catalog.json`：`bronze_spearmen.tech` 从 `tech.bronze_casting` 改为 `tech.hide_tanning`。它的三件装备分属三条链，而 `hide_tanning` 的 dense id 129 大于 `bronze_casting` 的 90，不能反向挂前置（会触发 `technology_catalog_not_topological`；重排节点又会毁掉科技 dense id 与存档）。给 `hide_tanning` 补 `tech.bronze_casting` 前置后，它成为「能同时覆盖青铜兵器 / 皮甲 / 弓」的最早节点。UI 名册会显示「需《皮革鞣制》」。
- `military_roster_gate_test.gd` 夹具同步改为 `tech.hide_tanning`，保留「只研究该科技 → 青铜矛兵可用、铁甲步兵仍锁」的断言。

**火枪兵细账**（用户举的例子，修复后）：

| 槽 | 作者指定 goods | 解锁科技 | 产出建筑 | 在 `tech.gunpowder_weapons` 闭包内 |
|---|---|---|---|---|
| `firearms` Q1 ×10/百人 | `matchlocks` | `tech.gunpowder_weapons`（兵种科技自身） | `gunsmithy` | ✅ |
| `melee_arms` Q3 ×4/百人 | `iron_weapons` | `tech.iron_smelting`（本次新增前置） | `armory` | ✅ |

运行时允许用同类别的 `stone_spears` 顶替 `melee_arms`（`military_core_logistics.cpp:1110` 只比类别），因此校验器**不能**按「类别里有货」判通过；必须逐件核对指定档位。`tests/military/military_unit_unlock_consistency_test.gd` 已按此实现，并带负例：删掉 `tech.gunpowder_weapons` 的 `tech.iron_smelting` 前置，防线必须报出 `musketeers/iron_weapons`。

**尝试过并回滚的写法**：给 `hide_armorer.tres` 追加第二个 `technology_tags` 被 `building_technology_binding_must_be_single` 拒绝（建筑只允许一个科技绑定），并会让 design test 的 agrarian 建筑解锁计数越界；两个 `.tres` 已恢复原状。

**验证**：

- 精确档逐件核对：46/46 装备槽「许可 + 产能」全部成立，缺口 0。
- headless：`military_unit_unlock_consistency_test` / `military_supply_catalog_test` / `military_roster_gate_test` 全 `ok`；`military_native_binding_test` 仅 `bench big p95 <= 2ms`（24.28 ms）这一既有未达标项 FAIL，其余含 PKMI round trip / determinism 全 PASS。
- 科技树四组校验器做了**改动前基线对照**：失败集合与 HEAD 完全相同（`agrarian building unlock load 67`、`tech.composite_tools support_only`、若干 authoring binding drift、`technology_catalog_test:127`），均为仓库既有漂移，本次改动未引入新失败。
- `committed visual_edges` 本来就是 stale（`technology_authoring_model_test.gd` 对该差异只打印 info），未为 20 条新 hard 边重写 1425 条布局边。

**影响**：

- `units[].tech` 进 `catalog_hash`，叠加 §7 后旧 PKMI 存档仍需新开局。
- 科技树 `hard_prerequisite_ids` 变化只改研究可达性，**节点数仍 416、dense id 未重排**，旧存档的科技位图不会错位；但旧档可能出现「已研究某兵种科技却没研究新前置」，建议一并新开局。
- 名册 UI：部落战士《复合工具》、青铜矛兵《皮革鞣制》，其余按各自科技显示。

**校验边界与遗留（不是本次的解锁死锁）**：

- 装备槽决定训练订单能否完成（`equipment_ready` 门槛）；`supply.*` 是持续消耗、按候选 OR 结算，影响补给率 / 战力，不阻断训练。测试以 info 形式报告 9 处补给类缺口：`combined_arms/fuel`、`dragoons/ammunition`、`early_armor/ammunition`、`line_infantry/ammunition`、`machine_gunners/ammunition`、`missile_artillery/fuel`、`siege_train/ammunition`、`tank_corps/fuel`、`tank_corps/ammunition`。其中 `siege_train/ammunition`（empire）无法靠硬前置解决：最早弹药 `powder_shot` 需要 exploration 的 `tech.gunpowder_weapons`，补进去会时代倒挂；要么给 `supply.ammunition` 加一个火药前可生产的物资，要么把该兵种的弹药消耗归零，属独立数值决策。
- 校验保证「科技许可 + 产出建筑许可」，不保证建筑已建成（建材 / 工期 / 岗位）、市场已有库存或落在 3 格市场环内——这些是玩家经营层面的时间成本。
- 开局零兵（`posts_for_cell=0`）与装备实际产能仍未解决（审查报告 §4.1 / §6 A2）。

---

## 9. 原生 v3：把实际到货装备接进战力（2026-11-05 四次修复）

**触发**：用户追问「没解锁火枪也可能生产出火枪兵吗」。核实后发现比物资解锁更严重：训练下单瞬间 `transfer_garrison` 就把 garrison lot 改成目标兵种，`equipment_ready` 只 gate `days_done`，而 `sum_lot_value` 直接按 lot 的 `unit_type` 满攻防算战力；`MCMD_TRAIN` 手动链还没有科技闸。装备一件未到货，兵已按火枪兵参战。用户选择「完全」档。

**改动**（`gdext/src/`，debug + release 均已重编为 `dots_ext_equip_v1`，`dots_ext.gdextension` 已换名）：

| 层 | 文件 | 改动 |
|---|---|---|
| 结构 / 版本 | `military_core.h` | `PKMI_VERSION` 2 → 3；`MilitaryTrainingOrder` 加 `delivered_quality_q8` / `equipped_slot_mask`；`MilitaryShipment` 加 `real_good` / `quality` |
| 共享计算 | `military_core_internal.h` | 新增 inline `equip_good_quality` / `equipment_slot_mask` / `equip_factor_q16`（从 `military_core.cpp` 匿名 namespace 提升为全 TU 共享） |
| 训练归属 | `military_core.cpp` | **下单不再把 lot 改成目标兵种**（人留在来源兵种，训练期按民兵/来源兵种战力）；完成时才 `transfer_garrison(from → to)` 并写入实际到货档位；`militia_heads` / `source_heads` / 手动 `have` 减去同格在训人数，避免重复下单 |
| 装备到货 | `military_core_logistics.cpp` | DELIVER 保留真实 good id 与 quality 档（伪 id 仍用于 stock / intent）；新增 `note_training_delivery` 按**订单稳定 id** 逐 category 累计，全部槽齐才置 `equipment_ready`；顺带修好同格采购从不置 ready、以及到货 stock 的 holder_kind 不一致 |
| 实战战力 | `military_core_war.cpp` | `sum_lot_value` 乘 `equip_factor_q16`，与 `refresh_army_cache` 的 UI / AI 口径统一 |
| 存档 | `military_core_save.cpp` | v3 读写新字段；v2 及更早（除 v1 兼容分支）因 schema 语义变化被 `pkmi_bad_version` 拒绝 |
| 命令闸 | `player_controller.gd` | `military.train` 加兵种科技闸（与 `state.build` 一致）；原生 `apply_command` 无 digest，闸门放在唯一命令入口 |

**效果**：没有火枪（或任一个装备槽未到齐）时，那批人始终是来源兵种、按民兵战力参战；只有全部装备送达 + 训练天数走完，才变成目标兵种，且 lot 质量取**实际买到最弱的那一档**（短板决定），`equip_factor_q16` 据此给出 1.0~2.10 的系数并同时作用于 UI 显示与实战伤害。

**验证**：

- `scons` debug / release 均 `done building targets`，无编译错误；DLL 换名 `dots_ext_equip_v1`，避免编辑器占用旧句柄。
- `military_native_binding_test`：原生 selftest 全 PASS，含 `PKMI restore -> identical state_hash`、`PKMI re-encode byte-identical`、`PKMI round trip after peace`、ledger reconcile、determinism；唯一 FAIL 仍是既有的 `bench big p95 <= 2ms`（23.65 ms）。
- `military_runtime_smoke_test` 的 8 个失败（根因「目录里没有无科技兵营」）与 `player_controller_contract_test` 的 3 个失败，均用**改动前 DLL / 改动前脚本**做了基线对照，失败集合完全一致 → 既有问题，非本次回归。
- 三个军事 GDScript 测试（解锁一致性 / 补给目录 / 名册门）全 `ok`；`git diff --check` 通过。

**平衡变化（需要后续重标）**：`military_native_binding_test` 的 1500 天 AI soak 从 `soldiers=[520,325,100] targets=[520,325,130]` 变为 `soldiers=[150,1625,100] targets=[2600,1625,130]`。原因是装备未齐的订单不再提前改变兵种、且现在要求**所有**装备槽到齐，训练吞吐下降；战斗基线、AI 强度与训练时长需按新链路重新标定。

**遗留**：

- UI 训练队列仍只导出 `quality_q8`（策略期望档），未导出 `delivered_quality_q8` / `equipped_slot_mask`；玩家看不到「已到几类装备、实际档位」。
- 装备永远不齐时订单无限期挂起（无超时 / 退款）；这是新设计下「不能成军」的表现，但需要 UI 给出卡在哪一类装备。
- `quality_multiplier_q16` 仍是 JSON / C++ 双份常量（§6 第 6 点 / 审查报告 §2.3）：本次只把 C++ 那份接进实战，JSON 那份仍未消费。
- 未新增专门的「缺装 lot 战力」断言测试；新不变量目前由 selftest 的招募 / 战争 / PKMI 往返与 AI soak 间接覆盖。
- §8 列出的 9 处 `supply.*` 缺口、开局零兵与装备产能仍未处理。
