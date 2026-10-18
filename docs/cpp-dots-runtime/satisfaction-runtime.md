# 综合满意度运行时（Composite Satisfaction Runtime）

本文件是 cohort 与家族分支满意度的当前公式说明。C++ 是唯一评分权威；GDScript 负责
内容编译、配置和展示，不进行第二套满意度结算。2026-10-18 起采用实际消费方案，替代
2026-10-16 的舒适/奢侈存款购买力方案。

## 八个维度

| id | 枚举 | 语义与输入 |
| --- | --- | --- |
| 0 | `SAT_DIM_SUBSISTENCE` | 温饱，既有热量与寒冷衣着生存满足率 |
| 1 | `SAT_DIM_BASIC` | 基本生活，basic 需求实际消费 / 生活目标量的加权平均 |
| 2 | `SAT_DIM_COMFORT` | 舒适，comfort 需求实际消费 / 生活目标量的加权平均 |
| 3 | `SAT_DIM_LUXURY` | 奢侈，luxury 需求实际消费 / 生活目标量的加权平均 |
| 4 | `SAT_DIM_INCOME` | 收入增长，近期人均收入 EMA / 长期基线 EMA |
| 5 | `SAT_DIM_SAVINGS` | 储蓄，剩余存款能支撑的基础生活费月数 |
| 6 | `SAT_DIM_TAX` | 税负，净缴税占本期毛收入（含实物）的比例，反向归一 |
| 7 | `SAT_DIM_DEVELOPMENT` | 社会发展，冻结的聚落等级、国家科技进度、建成产业种类 |

**存款只直接计入储蓄。** 舒适与奢侈不再由存款月数推导；未适用维度不记满分。
死亡仍只由温饱驱动；出生、家族分支评审、就业排序及社会压力继续使用 composite。

## 消费目标与适用性

`NeedProfile.satisfaction_tier` / `satisfaction_weight_q16` 编译为 dense catalog 列，
并进入 catalog hash。正式 need 资源均显式授权分档：

- 基本：主食、蛋白质、蔬果、油脂、衣着、居住维护、卫生、医疗、家庭能源、职业装备。
- 舒适：调味品、家庭用品、家用器皿、休闲、教育文化、交通、通信、耐用品。
- 奢侈：奢侈消费、身份消费。

温饱仍由既有生存量独立计算；吃不上偏好的某种食物不直接等同于饥饿。
一个 need 至少有一种技术允许的消费方案、目标基础量与族群系数为正时，才形成生活目标。
目标不看库存，也不看某个高端 variant 的存款激活门槛。权重 0 的 need 不参与满意度。

```text
living_target = population × plan.base_qty_per_person × elapsed_days
                × frozen_environment_factor × ethnicity_need_factor
living_fill   = clamp(actual_filled_units / living_target, 0, 1)
tier_score    = Σ(need_weight × living_fill) / Σ(need_weight)
```

目标量不乘财富、价格缩量、资金预算和商品偏好系数。正目标的整数下溢保留最小 1 单位；
环境因子最小取 1/Q16，防止整档因取整消失。购买申请、预算排序、替代与生产者自留逻辑不变；
已消费自留品同样计入 actual_filled。由于评价目标独立，买到了全部“缩减后的申请量”仍可能生活不足。

`NeedState.living_target_units` 是市场调用内的临时量，不进入存档。已解锁但没有购买申请的
need 仍保留零消费的目标记录，因此没钱、缺货、价格缩量都不会删除评分分母。没有技术适用
方案的 need 不进入维度；没有适用 need 的维度对外返回 -1，内部存 0。
生存、商品需求 EMA、账本归约保留各自原有数量口径，不改用生活目标。

## 权重与约束

职业 `satisfaction_dimension_weights_q16` 保留职业偏好和显式零权重，按类别内部重新归一：

| 类别 | Q16 预算 | 约占 |
| --- | --- | --- |
| 温饱、基本、舒适、奢侈 | 45875 | 70% |
| 收入增长、储蓄 | 13107 | 20% |
| 税负 | 3277 | 5% |
| 社会发展 | 3277 | 5% |

未适用消费维度的权重在消费类别内部重分配，不能抬高财务的份额。类别被明确全部配置为
零权重时不参与合成；消费类别全部为零时保留温饱预算。整数分配用前缀商差，预算总和精确。

```text
raw              = Σ(effective_weight × dim) / Σ(effective_weight)
survival_ceiling = subsistence + (1 − subsistence) × survival_slack
basic_ceiling    = basic + (1 − basic) × basic_slack  // 基本档适用时
ceiling          = min(survival_ceiling, basic_ceiling)
composite        = min(raw, ceiling)
```

默认 survival_slack=6554/Q16（约10%），新增 basic_slack=13107/Q16（约20%）。
例如基本生活75%时，综合分上限约80%；84.2%时，上限约87.4%。
约束只影响综合分，不伪造其他维度的实际消费结果。存在约束封顶时，worst_dimension_id 指向
实际施加最严约束的温饱或基本维度；否则选 `(1−dim) × effective_weight` 最大项。

## 配置与其余维度

全部由 `EconomyProfile.to_native_profile()` → `configure_satisfaction_profile` 配置：

| 字段 | 默认 | 用途 |
| --- | --- | --- |
| `satisfaction_default_dimension_weights_q16` | `[65536,45875,26214,13107,19661,19661,16384,13107]` | 未配置职业的类别内部偏好 |
| `satisfaction_subsistence_gate_slack_q16` | 6554 | 温饱约束松弛度 |
| `satisfaction_basic_gate_slack_q16` | 13107 | 基本生活约束松弛度 |
| `satisfaction_income_growth_floor_q16` / `_ceiling_q16` | 58982 / 78643 | 收入比值0.9至1.2线性归一 |
| `satisfaction_income_baseline_alpha_q16` | 1024 | 慢收入 EMA；快 EMA 为8192 |
| `satisfaction_savings_target_months_q16` | 393216 | 六个月基础生活费使储蓄满分 |
| `satisfaction_tax_tolerance_q16` | 22938 | 净税负达到毛收入35%时税负分归零 |
| `satisfaction_development_weights_q16` | `[26214,26214,13107]` | 聚落 / 科技 / 产业权重 |
| `satisfaction_development_variety_target` | 12 | 产业种类饱和点 |
| `satisfaction_birth_reference_q16` / `_bonus_reference_q16` | 45875 / 55706 | 出生乘数1.0 / 最高奖励参考 |
| `satisfaction_pressure_thresholds_q16` | `[13107,26214,39322,52429]` | 社会压力五档分界 |

四个 `satisfaction_comfort_*_months_q16` / `satisfaction_luxury_*_months_q16` 已移除。
储蓄继续使用本地基础篮子成本；缺少有效估价时不再自动取满分，而记0并在 explain 中
返回 `purchasing_power_basis_valid=false`。基础篮子当前仍受可购库存覆盖率影响，后续的
稳定缺货估价、经营资金扣除、实际收入指数与时代化发展评分尚未实施。

收入、税负、社会发展公式延用原实现。本轮没有改其权威列或出生、家族、社会压力阈值；
采用70%实际生活权重后，正常生活仍能越过0.70出生参考，饥饿约束仍使严重不足者低于参考。
应以正式开局长跑继续校准，不能仅用零出生的公式测试声称人口平衡已经完成。

## 计算位置与查询

`economy_runtime_market.cpp` 在既有 need 归约中累计三档生活满足率；科技适用性在同一市场
调用内按 need 懒缓存，避免每个 cohort 重扫所有 variant。没有新增全世界循环、持久化列或资金流。
`refresh_epoch_development()` 的 epoch 边界缓存、市场周期 N/P/I、发布与调度契约保持不变。

`explain_cohort_satisfaction` 返回八维、归一后的有效权重、缺口贡献、`raw_q16`、
实际双重约束的 `ceiling_q16`、已存 `composite_q16`、`applicable_mask` 和
`consumption_semantics=realized_over_living_target_v1`。存款月数仅用于储蓄诊断，
另返回 `basic_gate_slack_q16`；旧舒适/奢侈月份门槛不再返回。
查询在原生 slice 之间安全，只对需要展示的人口范围执行。

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

- **出生率**：格级 `sat_cell` 进入承载力 `K_eff`；cohort 只乘
  `cohort_sat_residual = clamp(rescale(cohort) / sat_cell)`。
  `rescale` 仍按 `satisfaction_birth_reference_q16` 重标定，否则早期 cohort
  （按构造在奢侈、储蓄、发展上必然得零分）会自己掐死自己的出生率。composite 在 0.70–0.85
  之间线性升到 1.15，负载超过 `carrying_soft_start_q16` 后超出 1 的部分渐退。
  贴上 `K_eff` 后 `fertility_land` 落到更替，未解锁 need 不进物资族分母。
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
   储蓄诊断另返回 `purchasing_power_basis_valid / purchasing_power_months_q16 /
   purchasing_power_reference_days`（固定30），以及 `basic_gate_slack_q16` 与消费适用性 mask。
   `dim_weights_q16` 为类别归一与未适用过滤后的有效权重；不再返回舒适/奢侈月份门槛。
   原始存款/成本和购买力是查询时诊断，八维值是最近一次结算结果；结算间发生资金变化时
   二者不保证逐位重算相等。
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

历史接入：PKEC `SCHEMA_VERSION` 29 → 30，**扩展现有 section 而不新增 section**（END 仍为 23）：

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
读取原生综合值与维度分解。生活水平改为独立的实际消费档位：温饱不足 50% / 80% / 95%
分别处于赤贫 / 挣扎 / 贫困；基本生活不足 50% 至多贫困，不足 90% 至多温饱。
温饱与基本生活充分时，舒适未适用或不足 50% 仍为温饱，舒适 50%～90% 为小康，
90% 以上为富裕；另有适用的奢侈消费且满足率达到 80% 才能达到奢华。
存款与综合满意度不直接提升此档位。该七档规则目前用于 cohort snapshot、explain 和 welfare trace；
旧的格级建筑视觉社会分档仍沿用原有 presentation 规则，不在本轮改动范围。

对外 `satisfaction_dims_by_cohort_q16` / `dim_values_q16` 中 -1 表示该消费维度不适用；
存储列仍为 uint16，未适用的内部值为 0。适用性按职业计划、族群需求系数与冻结科技可用性派生，
不依赖库存、资金、价格弹性和维度权重是否为零。尚未形成需求显示“不适用”，缺货显示实际低分。
适用性是查询时冻结上下文的诊断，维度值是最近已完成的市场结算值。
人口聚合只对该维度适用的人口取平均；职业页另返回 `satisfaction_dims_population` 作为其分母。
雷达对不适用的轴留空，条形显示“不适用”；悬停解释消费与存款的口径。

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
explain 与 attractiveness API、PKEC v41 往返与 state_hash）、
`tests/goods_storage_schema_test.gd` 的 `_test_satisfaction_driven_births`、
`tests/economy_birth_runtime_test.gd`、`tests/inspector_live_patch_test.gd`。
