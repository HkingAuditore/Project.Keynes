# 综合满意度运行时（Composite Satisfaction Runtime）

本文件是 cohort 与家族分支满意度的当前公式说明。C++ 是唯一评分权威；GDScript 负责
内容编译、配置和展示，不进行第二套满意度结算。2026-11-08 消费模型 v2 在实际消费方案上
加入基本生活短板与舒适/奢侈高分条件；模型版本进入目录身份，保存列布局不变。

## 八个维度

| id | 枚举 | 语义与输入 |
| --- | --- | --- |
| 0 | `SAT_DIM_SUBSISTENCE` | 生存（survival，旧 UI 名「温饱」），既有热量与寒冷衣着生存满足率 |
| 1 | `SAT_DIM_BASIC` | 基本生活完整度：75% 的 basic 需求加权均值 + 25% 的适用基本需求最低满足率 |
| 2 | `SAT_DIM_COMFORT` | 舒适，comfort 需求实际消费 / 生活目标量的加权平均 |
| 3 | `SAT_DIM_LUXURY` | 奢侈，luxury 需求实际消费 / 生活目标量的加权平均 |
| 4 | `SAT_DIM_INCOME` | 收入增长，近期人均收入 EMA / 长期基线 EMA |
| 5 | `SAT_DIM_SAVINGS` | 储蓄，剩余存款能支撑的基础生活费月数 |
| 6 | `SAT_DIM_TAX` | 税负，净缴税占本期毛收入（含实物）的比例，反向归一 |
| 7 | `SAT_DIM_DEVELOPMENT` | 社会发展，冻结的聚落等级、国家科技进度、建成产业种类 |

**存款只直接计入储蓄。** 舒适与奢侈不再由存款月数推导；未适用维度不记满分。
死亡仍只由生存维度驱动；出生、家族分支评审、就业排序及社会压力继续使用 composite。

## 消费目标与适用性

`NeedProfile.satisfaction_tier` / `satisfaction_weight_q16` 编译为 dense catalog 列，
并进入 catalog hash。正式 need 资源均显式授权分档：

- 基本：主食、蛋白质、蔬果、油脂、衣着、居住维护、卫生、医疗、家庭能源、职业装备。
- 舒适：调味品、家庭用品、家用器皿、休闲、教育文化、交通、通信、耐用品。
- 奢侈：奢侈消费、身份消费。

生存维度仍由既有生存量独立计算；吃不上偏好的某种食物不直接等同于饥饿。
一个 need 至少有一种技术允许的消费方案，且目标基础量、冻结环境因子、族群系数与需求权重
均为正时，才形成生活目标。
目标不看库存，也不看某个高端 variant 的存款激活门槛。权重 0 的 need 不参与满意度。

```text
living_target = population × plan.base_qty_per_person × elapsed_days
                × frozen_environment_factor × ethnicity_need_factor
living_fill   = clamp(actual_filled_units / living_target, 0, 1)
tier_mean     = Σ(need_weight × living_fill) / Σ(need_weight)
basic_score   = (3 × basic_mean + min(applicable_positive_weight_basic_fill)) / 4
comfort_score = comfort_mean
luxury_score  = luxury_mean
```

目标量不乘财富、价格缩量、资金预算和商品偏好系数。正目标的整数下溢保留最小 1 单位；
环境因子恰为零时不形成目标与适用维度；正因子即使很小也保留最小 1 单位。
购买申请、预算排序、替代与生产者自留逻辑不变；
已消费自留品同样计入 actual_filled。由于评价目标独立，买到了全部“缩减后的申请量”仍可能生活不足。

`NeedState.living_target_units` 是市场调用内的临时量，不进入存档。已解锁但没有购买申请的
need 仍保留零消费的目标记录，因此没钱、缺货、价格缩量都不会删除评分分母。没有技术适用
方案的 need 不进入维度；没有适用 need 的维度对外返回 -1，内部存 0。
生存、商品需求 EMA、账本归约保留各自原有数量口径，不改用生活目标。

## 权重与约束

职业 `satisfaction_dimension_weights_q16` 保留职业偏好和显式零权重，按类别内部重新归一：

| 类别 | Q16 预算 | 约占 |
| --- | --- | --- |
| 生存、基本、舒适、奢侈 | 45875 | 70% |
| 收入增长、储蓄 | 13107 | 20% |
| 税负 | 3277 | 5% |
| 社会发展 | 3277 | 5% |

未适用消费维度的权重在消费类别内部重分配，不能抬高财务的份额。类别被明确全部配置为
零权重时不参与合成；消费类别全部为零时保留生存预算。整数分配用前缀商差，预算总和精确。

```text
raw_before_bias  = Σ(effective_weight × dim) / Σ(effective_weight)
raw              = clamp(raw_before_bias + profession_bias, 0, 1)
survival_ceiling = subsistence + (1 − subsistence) × survival_slack
basic_ceiling    = basic + (1 − basic) × basic_slack
comfort_ceiling  = 0.70 + 0.30 × comfort
luxury_ceiling   = 0.90 + 0.10 × luxury
ceiling          = min(survival_ceiling, applicable_basic_ceiling,
                       applicable_positive_weight_comfort_and_luxury_ceilings)
composite        = min(raw, ceiling)
```

默认 survival_slack=6554/Q16（约10%），basic_slack=13107/Q16（约20%）。
原生值上界为65535；生存与基本上限准确计算为
`dim + floor((65535-dim) × slack / 65536)`，舒适与奢侈上限分别为
`45875 + floor((65535-45875) × comfort / 65535)` 和
`58982 + floor((65535-58982) × luxury / 65535)`。
生存门槛始终执行，基本门槛只检查适用性，即使职业给基本维度配置零权重也仍限制综合分。
例如基本生活75%时，综合分上限约80%；84.2%时，上限约87.4%。
舒适需求适用但完全缺失时上限70%，满足一半时上限85%；奢侈需求适用但缺失时上限90%。
舒适和奢侈闸门只作用于职业明确给予正维度权重的适用维度，不把未形成需求算成短缺。
约束只影响综合分，不伪造其他维度的实际消费结果。仅在 `raw_q16 > ceiling_q16` 时认为上限
实际封顶；二者相等不算封顶。实际封顶时，worst_dimension_id 指向
实际施加最严约束的维度，平局按生存、基本、舒适、奢侈顺序；否则选
`(1−dim) × effective_weight` 最大项。

失业者的正式消费计划补齐衣着、居住维护、家庭用品、家用器皿、卫生、医疗和家庭能源，
与生存计划采用相同的12类需求和规范基础量，保留较保守的财富与存款激活门槛；职业装备
不在这两个计划中。
失业不再因计划只包含食物而天然绕过其他生活条件。

## 配置与其余维度

全部由 `EconomyProfile.to_native_profile()` → `configure_satisfaction_profile` 配置：

| 字段 | 默认 | 用途 |
| --- | --- | --- |
| `satisfaction_default_dimension_weights_q16` | `[65536,45875,26214,13107,19661,19661,16384,13107]` | 未配置职业的类别内部偏好 |
| `satisfaction_subsistence_gate_slack_q16` | 6554 | 生存约束松弛度 |
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
实际约束的 `ceiling_q16`、已存 `composite_q16`、`applicable_mask` 和
`consumption_semantics=realized_over_living_target_basic_completeness_v2`。另返回
`satisfaction_model_version=2`、`raw_before_bias_q16`、`bias_q16`、
`basic_average_weight_q16=49152` / `basic_worst_weight_q16=16384`、
`comfort_gate_floor_q16=45875` / `luxury_gate_floor_q16=58982`、最严上限来源 `ceiling_dimension_id`
及其是否实际封顶 `ceiling_is_binding`。
存款月数仅用于储蓄诊断；旧舒适/奢侈月份门槛不再返回。
查询在原生 slice 之间安全，只对需要展示的人口范围执行。

## 权威列与存储

`PopulationStore` 新增，全部进 `state_hash`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `composite_satisfaction` | `uint16` | 权威 composite（Q16） |
| `satisfaction_dims` | `uint16 × SAT_DIM_COUNT`（stride） | 八个维度值 |
| `worst_dimension_id` | `uint8` | 实际封顶的维度，否则为缺口贡献最大的维度；`0xFF` 表示未评估 |
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
- 上述是 v30 的历史布局接入；当前 writer 为 v60，reader 允许 v56～v60，并继续校验目录
  与内容身份。消费模型 v2 与本轮消费计划修改会改变 catalog hash，不能因保存列未变就认为
  旧内容存档可以加载。
- restore 校验维度值与 `worst_dimension_id` 的范围；越界即拒绝整个存档。
- 全部新权威列进 `state_hash`；need 分档/权重与 signature 权重列进 `catalog_hash`。

`game_save_coordinator.gd` 通过 `get_economy_checkpoint_format()` 查询当前原生 schema，
不再固定使用满意度最初接入时的 v30。

## UI

[cell_inspector_view_model.gd](../../Project/project-keynes/scripts/ui/cell_inspector_view_model.gd)
读取原生综合值与维度分解。生活水平改为独立的实际消费档位：生存不足 50% / 80% / 95%
分别处于赤贫 / 挣扎 / 贫困；基本生活不足 50% 至多贫困，不足 90% 至多温饱。
生存与基本生活充分时，舒适未适用或不足 50% 仍为温饱，舒适 50%～90% 为小康，
90% 以上为富裕；另有适用的奢侈消费且满足率达到 80% 才能达到奢华。
存款与综合满意度不直接提升此档位。该七档规则目前用于 cohort snapshot、explain 和 welfare trace；
旧的格级建筑视觉社会分档仍沿用原有 presentation 规则，不在本轮改动范围。

对外 `satisfaction_dims_by_cohort_q16` / `dim_values_q16` 中 -1 表示该消费维度不适用；
存储列仍为 uint16，未适用的内部值为 0。适用性按职业计划、正需求权重、族群需求系数、
冻结环境因子与科技可用性派生，
不依赖库存、资金、价格弹性和维度权重是否为零。尚未形成需求显示“不适用”，缺货显示实际低分。
适用性是查询时冻结上下文的诊断，维度值是最近已完成的市场结算值。
人口聚合只对该维度适用的人口取平均；职业页另返回 `satisfaction_dims_population` 作为其分母。
雷达对不适用的轴留空，条形显示“不适用”；悬停解释消费与存款的口径。

### 口径统一（2026-10-30）

八维的第 0 维在界面上显示为「生存」（旧名「温饱」）：生活水平七档里已经有一个「温饱」档
（赤贫/挣扎/贫困/温饱/小康/富裕/奢华），同词会被读成档位。枚举、字段名与公式不变。

玩家界面上写「满意度」的地方一律是**人口加权的 composite**，含地块档案页头四格、全国经济
总览/阶层/城市、顶栏人口悬浮卡、时代指标、年度报告、地图「阶层不满」图标。页头通过
`get_cell_satisfaction_attractiveness`（`ReadQuery::CELL_SATISFACTION_ATTRACTIVENESS`，
同一已提交状态内由 read view 缓存）取本格 composite；读不到时沿用上次成功值，仍无读数才退回
cell summary 的生存值，并在悬停提示里注明口径。`common_hash` 同时纳入 composite，避免
「生存没变、综合变了」时不刷新页头。

生存（survival）只在明确写出口径的位置出现：人口页「口粮保障」、阶层八维的生存轴、
全国经济阶层页的「生存」列、时代告警「生存满意度不足」、年度报告「基本需求满足」，
以及家族名人的「生存满足」（成员 cohort 的 survival）。家族分支条是成员人口加权的 composite。
缺少读数时一律显示「—」，不得用常量兜底。

## 性能与验收

计算复用既有 need 归约循环与 epoch 边界缓存，没有新增全世界遍历，评分热循环不使用字符串
或 Dictionary。基本短板增加每个当前市场 cohort 8 字节的线程临时向量，容量增长时可分配，
之后复用；不增加保存列。

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

2026-11-08 覆盖测试：`tests/economy/satisfaction_runtime_test.gd` 与
`tests/economy/consumption_satisfaction_runtime_test.gd` 各77项通过，覆盖八维度、基本完整度、
舒适/奢侈渐进门槛、职业零权重、环境零值/极小正值、失业者冷暖衣物需求、守恒、
worker/scalar 一致性，以及 PKEC v60 往返；完整入口同时验证次轮完整 state_hash。
`tests/economy/consumption_satisfaction_ui_test.gd` 覆盖详情行、雷达与不适用人口分母。
出生与 Inspector 其他回归分别见当前 `tests/` 下对应专项测试。
