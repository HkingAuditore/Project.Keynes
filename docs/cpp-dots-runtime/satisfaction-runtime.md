# 综合满意度运行时（Composite Satisfaction Runtime）

本文件是 cohort 与家族分支满意度的**唯一权威说明**。修改维度定义、权重契约、合成公式、
玩法接管点、溯源 API、社会压力事件或 PKEC v30 satisfaction 列时，必须同步这里、
[原生经济运行时](./native-economy-runtime.md)、
[定点/守恒/公式规范](./economy-fixed-point-ledger-formulas.md)、
[经济存档与迁移 SOP](./economy-save-migration-sop.md) 与
`project-keynes-economy-runtime` / `project-keynes-family-runtime` /
`project-keynes-modifier-runtime` 三套 Skill 中描述满意度语义的段落。

## 一句话结论

`_population.composite_satisfaction`（Q16，`uint16` 存储）是**权威**的多维度综合满意度，
由八个维度按 profession 数据驱动权重加权平均、再经生存闸门封顶得到。它取代旧的
`needs_satisfaction` 成为出生率、家族分支评审、就业流动和社会压力事件的输入；
`needs_satisfaction`（等价于 `SAT_DIM_SUBSISTENCE`）**只**继续驱动饥饿死亡。

## 维度枚举

`NativeEconomyRuntime::SatisfactionDimension`（[gdext/src/economy_runtime.h](../../gdext/src/economy_runtime.h)）：

| id | 枚举 | 语义 | 输入来源 |
| --- | --- | --- | --- |
| 0 | `SAT_DIM_SUBSISTENCE` | 温饱 | 既有 `survival_q16`（食品篮子与寒冷暴露衣着上限的较低值） |
| 1 | `SAT_DIM_BASIC` | 基本生活 | `Need.satisfaction_tier == 1` 的需求加权满足率 |
| 2 | `SAT_DIM_COMFORT` | 舒适 | `satisfaction_tier == 2` 的需求加权满足率 |
| 3 | `SAT_DIM_LUXURY` | 奢侈 | `satisfaction_tier == 3` 的需求加权满足率 |
| 4 | `SAT_DIM_INCOME` | 收入增长 | 人均 `income_ema` 相对人均 `income_baseline_ema` 的比值 |
| 5 | `SAT_DIM_SAVINGS` | 储蓄 | `funds` 能支撑的生活成本月数 |
| 6 | `SAT_DIM_TAX` | 税负 | 本期净税负占本期毛收入（含实物）的比重，反向归一 |
| 7 | `SAT_DIM_DEVELOPMENT` | 社会发展 | epoch 边界缓存的聚落等级 + 国家技术进度 + 本地建成建筑种类 |

前 `SAT_TIER_COUNT = 4` 个维度是需求档位，由 household market 清算直接喂养；
其余四个从 cohort 账本与冻结的 epoch 上下文推导。

**扩展方式**：在 `SAT_DIM_COUNT` 之前追加枚举项，同步加宽
`EconomyProfile.satisfaction_default_dimension_weights_q16` 与
`ProfessionProfile.satisfaction_dimension_weights_q16` 的授权列，
并把 PKEC 的 stride 常量与 `catalog_hash` 一起 bump。stride 之外的存储布局不变。

## 数据驱动契约

### 需求分档（冷路径 catalog 编译）

`NeedProfile` 新增两列，由
[economy_catalog.gd](../../Project/project-keynes/scripts/economy/economy_catalog.gd)
编译成与 `need_ids` 等长的 dense 列，并计入 `catalog_hash`：

- `satisfaction_tier`：`0..SAT_TIER_COUNT-1`，决定该需求落到哪个档位累加器。
- `satisfaction_weight_q16`：该需求在档位内的权重。

编译输出为 `need_satisfaction_tiers` 与 `need_satisfaction_weights_q16`。
C++ 侧不再用硬编码字符串匹配分档；`need_semantic_tags` 仍然只在 GDScript 侧存在。

### 阶层权重

`ProfessionProfile.satisfaction_dimension_weights_q16` 是长度为 `SAT_DIM_COUNT` 的
Q16 权重数组；留空则回退到
`EconomyProfile.satisfaction_default_dimension_weights_q16`。
catalog 编译成 `signature_satisfaction_dimension_weights_q16`
（`signature_keys.size() * SAT_DIM_COUNT` 的 dense 列），运行时按 signature 直接索引。

阶层差异由此自然表达：贫农的奢侈权重为 0，商人的收入增长权重高于农民。

### Profile 旋钮

全部位于 [economy_profile.gd](../../Project/project-keynes/scripts/data/economy_profile.gd)，
经 `configure_satisfaction_profile` 读入：

| 字段 | 默认 | 作用 |
| --- | --- | --- |
| `satisfaction_default_dimension_weights_q16` | `[65536, 45875, 26214, 13107, 19661, 19661, 16384, 13107]` | 未授权职业的回退权重 |
| `satisfaction_subsistence_gate_slack_q16` | `6554`（0.10） | 生存闸门松弛度；0 把 composite 钉死在生存维度，65536 关闭闸门 |
| `satisfaction_income_growth_floor_q16` / `_ceiling_q16` | `58982` / `78643` | 收入比值 0.90 得零分、1.20 得满分 |
| `satisfaction_income_baseline_alpha_q16` | `1024`（1/64 每日） | 慢基线 EMA 的 alpha；快 `income_ema` 为 1/8，两者相差八倍才构成增长信号 |
| `satisfaction_savings_target_months_q16` | `393216`（6 个月） | 储蓄维度满分所需的生活成本月数 |
| `satisfaction_tax_tolerance_q16` | `22938`（0.35） | 净税负占毛收入达到该比例时税负维度归零 |
| `satisfaction_development_weights_q16` | `[26214, 26214, 13107]` | 聚落等级 / 国家技术 / 本地产业种类三项权重 |
| `satisfaction_development_variety_target` | `12` | 本地建成建筑种类数的饱和点 |
| `satisfaction_birth_reference_q16` | `45875`（0.70） | 出生率视为「完全满意」的 composite 参考值 |
| `satisfaction_pressure_thresholds_q16` | `[13107, 26214, 39322, 52429]` | 五档社会压力等级的分界 |

## 计算位置与预算

### epoch 边界：社会发展缓存

`refresh_epoch_development()` 在 `capture_country_epoch` 之后、结构提交边界之后各算一次，
产出两个只读缓存：

- `_epoch_country_technology_progress_q16[country]`：
  `popcount(_epoch_country_technologies)` 对科技总数归一。
- `_epoch_cell_development_q16[cell]`：聚落等级（对 `_prosperity_thresholds.size() - 1` 归一）、
  所属国技术进度、本地建成建筑种类数（对 `variety_target` 归一）三项按权重合成。
  种类数利用 `_building_cell_offsets` CSR 中 `(cell, type, owner)` 的稳定序，
  数 type 跳变次数即可，无需集合。

热循环只读这两个数组，是 O(1) 访问。

### 热循环：四档累加器

四个需求档位在**既有的** `for (const NeedState &state : need_states)` 归约循环里
用四对 `Σ(weight × satisfaction)` / `Σweight` 累加器算出，**零额外遍历**。
plan 内不含某档需求时，该档的分母为 0，维度取满分并从合成分母中剔除——
贫农的 plan 里没有奢侈需求，不应因此被扣分。

### 合成

```text
raw_q16     = Σ(w_i × dim_i) / Σ(w_i)                    // w 来自 signature（阶层）
ceiling_q16 = subsistence + (Q16 - 1 - subsistence) × gate_slack_q16 / Q16
composite   = clamp(min(raw_q16, ceiling_q16), 0, Q16 - 1)
worst_dimension_id = argmax_i((Q16 - 1 - dim_i) × w_i)   // 缺口贡献最大者
```

生存闸门保证「吃不上饭的农民不会因为存款高而满意」。默认 slack 收得很紧：
吃饱的 cohort 感觉不到闸门（`subsistence ≈ Q16` 时 `ceiling ≈ Q16`），
而完全饥饿的 cohort 上限只有 0.10，稳稳落在出生率参考值之下。

各维度的具体公式：

```text
INCOME:      growth = 人均 income_ema × Q16 / 人均 income_baseline_ema
             dim    = normalize_band(growth, income_growth_floor, income_growth_ceiling)
             基线为 0 时（新播种或刚清空的 cohort）不臆造比值：
             有收入取满分，无收入取 0.5
SAVINGS:     months = funds × Q16 / (人均日生活成本 × 人口 × 30)
             dim    = normalize_band(months, 0, savings_target_months_q16)
             生活成本为 0 时储蓄无法表达焦虑，取满分
TAX:         net    = epoch_tax_paid - epoch_subsidy_received
             net <= 0 → 满分；net > 0 且毛收入为 0 → 0（无收入还被课税是最坏情形）
             否则 dim = Q16 - 1 - normalize_band(net × Q16 / 毛收入, 0, tax_tolerance_q16)
DEVELOPMENT: dim    = _epoch_cell_development_q16[cell]
```

人均日生活成本来自 `compute_cell_living_costs_from_basis` 已经算好的
`_cell_living_cost_per_capita`，是纯诊断派生量，**不搬运任何货币**。

### per-cohort 税负累加器

`PopulationStore` 新增 `epoch_tax_paid` 与 `epoch_subsidy_received`（i64），
在工资预扣、消费税以及其余 cohort 侧 `apply_fiscal_tax` 调用点累加，
epoch 起始清零。`record_fiscal` 自身会先调用 `touch_accounting_slot`，
避免 epoch 语义下的先写后清。它们只是满意度的输入，
不参与任何货币守恒等式，审计结果与接入前逐位一致。

## 权威列与存储

`PopulationStore` 新增，全部进 `state_hash`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `composite_satisfaction` | `uint16` | 权威 composite（Q16） |
| `satisfaction_dims` | `uint16 × SAT_DIM_COUNT`（stride） | 八个维度值 |
| `worst_dimension_id` | `uint8` | 缺口贡献最大的维度；`0xFF` 表示未评估 |
| `income_baseline_ema` | `int64` | 慢收入基线 EMA |
| `epoch_tax_paid` | `int64` | 本期已缴税 |
| `epoch_subsidy_received` | `int64` | 本期已收补贴 |

`FamilyCellInfluenceStore` 新增 `satisfaction_q16`（成员 cohort composite 按 membership
人口加权）。`_cell_social_pressure_level`（`uint8`/格）记录上次发布的压力等级，
持久化以避免重载后重放已经发过的等级跨越事件。

合计约 43 B/slot。

## 玩法接管

- **出生率**：`birth_input = clamp(composite × Q16 / satisfaction_birth_reference_q16)`，
  `birth_factor = 1 - satisfaction_birth_weight × (1 - birth_input)`。
  先按参考值重标定，否则早期 cohort（按构造在奢侈、储蓄、发展上必然得零分）
  会自己掐死自己的出生率。
- **饥饿死亡只读 `SAT_DIM_SUBSISTENCE`**，代码里写成显式不变量与注释：
  饿死是生理事实，税重、囊中羞涩或聚落落后都不得致死。
- **同格就业流动**：`run_building_employment_cell` 的 `hire_order` 排序在利润相同时，
  以业主 cohort **上一 epoch** 的 composite 作为次级键。就业跑在市场之前，
  读到的必然是上期已发布值，不引入同期循环依赖。
- **家族分支评审**：`update_family_influences` 记录 `satisfaction_q16`，
  并在分支存续评审中把「成员满意度低于压力阈值 1」作为**晋升**的否决条件；
  降级永不被阻塞，所以这只会减慢晋升。**25/35/40 威望公式一字未改。**
- **跨格迁移**：本轮只提供 `cell_satisfaction_attractiveness` 只读查询与社会压力事件，
  **不实现跨格搬迁决策**（涉及 slot 分配、家族分支迁移、贸易拓扑，属独立设计）。

## 溯源（三层）

1. **权威 dense 列**：`satisfaction_dims` + `worst_dimension_id` 全格全 cohort 可读，
   经 `get_population_cell_snapshot` 发布为
   `overall_satisfaction_by_cohort_q16`、`satisfaction_dims_by_cohort_q16`、
   `worst_satisfaction_dimension_by_cohort`、`satisfaction_dimension_count`，
   不再依赖 trace 过滤。
2. **冷路径 explain**：`DCWorldExt.explain_cohort_satisfaction(cohort_handle)` 返回
   `dim_ids / dim_values_q16 / dim_weights_q16 / dim_contributions_q16 /
   raw_q16 / ceiling_q16 / composite_q16`，外加各维度的原始输入
   （`income_ema`、`income_baseline_ema`、`funds`、`epoch_income`、`epoch_tax_paid`、
   `living_cost_per_capita`、`settlement_tier`、`development_q16` 与三个归一参考量）。
   `DCWorldExt.get_cell_satisfaction_attractiveness(cell_idx)` 返回同一批列的
   人口加权聚合与已发布压力等级。两者都是纯读，**只在原生 slice 之间安全**，
   Inspector 打开时才调用。GDScript 侧包装见
   [economy_facade.gd](../../Project/project-keynes/scripts/economy/economy_facade.gd)，
   会附带 `dimension_names`。
3. **per-need 明细**：继续走 `CohortWelfareEntry` + `welfare_need_*` CSR，
   分档改为数据驱动。

## 社会压力事件

`GAMEPLAY_FACT_SOCIAL_PRESSURE = 3` 经既有 `drain_committed_gameplay_facts` 通路，
在 [world_ext_economy.cpp](../../gdext/src/world_ext_economy.cpp) 映射为
`PK_EVENT_ECONOMY_SOCIAL_PRESSURE = 8` / `PK_PAYLOAD_SOCIAL_PRESSURE_V1 = 5`，
GDScript 侧常量见
[gameplay_event_bus.gd](../../Project/project-keynes/scripts/data_core/gameplay_event_bus.gd)。

payload 布局：`i0` 新等级、`i1` 最差维度、`i2` 最差需求、`i3` 上一等级；
`value` 为人口加权 composite（Q16），`entity_id` 为人口，`flags=1` 表示等级下降。

`publish_social_pressure_facts()` 只遍历 `_epoch_settlement_cells`，
**只在等级跨越时发布**（沿用 `_settlements.prosperity_generation` 的 level-change 去重模式），
每 epoch 的事件量以滚动 workset 为上界。等级由
`social_pressure_level_for()` 按 `satisfaction_pressure_thresholds_q16` 判定，
0 最紧张、4 最满足。示例 trigger 见
`data/triggers/default_trigger_catalog.tres` 的 `economy.social_pressure_relief`。

## 持久化

PKEC `SCHEMA_VERSION` 29 → 30，**扩展现有 section 而不新增 section**（END 仍为 23）：

- `SAVE_SECTION_PAGES` 的 cohort 记录追加 `composite_satisfaction`(u16)、
  `worst_dimension_id`(u8)、`satisfaction_dims[8]`(u16)、`income_baseline_ema`(i64)、
  `epoch_tax_paid`(i64)、`epoch_subsidy_received`(i64)。
- `SAVE_SECTION_FAMILY_INFLUENCES` 追加 `satisfaction_q16`。
- `SAVE_SECTION_CELLS` 追加已发布的社会压力等级。
- reader 只接受 v30；v29 及更早返回 `economy_save_v29_or_earlier_unsupported`
  （与既有 v28 策略一致，本项目不做旧档迁移）。
- restore 校验维度值与 `worst_dimension_id` 的范围；越界即拒绝整个存档。
- 全部新权威列进 `state_hash`；need 分档/权重与 signature 权重列进 `catalog_hash`。

`game_save_coordinator.gd` 的 `pkec` provider schema 同步为 30。

## UI

[cell_inspector_view_model.gd](../../Project/project-keynes/scripts/ui/cell_inspector_view_model.gd)
直接读权威 composite 与维度分解，不再依赖 trace。生活水平 7 档阈值按新 composite 重定为
`0.12 / 0.22 / 0.33 / 0.45 / 0.58 / 0.72`——吃得饱但一无所有、住在小村的 cohort
大约落在 0.45，所以档位整体低于接管前。维度分解与「最短板」在
`object_detail_dialog`（满意度维度卡片）与 `demand_detail_dialog`
（需求明细上方的满意度小节）展示，让「为什么不满意」和「买不起什么」在同一屏内可对照。

## 性能与验收

计算全部寄生在既有循环与 epoch 边界缓存上：无新增遍历、无字符串、无 Dictionary、无分配。

2026-08-04 验收（60×40、`population_scale=100`、50 天生产路径、debug DLL、
各跑三次取中位数）：

| 指标 | 基线 | 接入后 | 判定 |
| --- | --- | --- | --- |
| `bd_economy_scan_steps_stage_household_market` 总量 | 10012942 | 9998441 | −0.14% |
| `bd_economy_scan_steps_stage_building_employment` 总量 | 17319750 | 17272596 | −0.27% |
| `bd_economy_scan_steps_find_signature` 总量 | 180009004 | 179577124 | −0.24% |
| `j_economy_daily_ms` avg / p95 / max | 2.534 / 3.362 / 5.652 | 2.746 / 3.435 / 5.629 | 落在 ±15% 墙钟噪声内 |
| `population_error` / `money_error` / `goods_error` | 0 | 0 | 守恒无回归 |

墙钟在这台机器上的 run-to-run 抖动本身就有 ±20%（基线三次 run_ms 为
1707 / 2308 / 1774），因此结论以确定性 `scan_steps_*` 计数器为准。

覆盖测试：`tests/satisfaction_runtime_test.gd`（八维度、生存闸门、阶层权重差异、
explain 与 attractiveness API、PKEC v30 往返与 state_hash）、
`tests/goods_storage_schema_test.gd` 的 `_test_satisfaction_driven_births`、
`tests/economy_birth_runtime_test.gd`、`tests/inspector_live_patch_test.gd`。
