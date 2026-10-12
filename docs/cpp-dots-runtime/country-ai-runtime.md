# Country AI 运行时

外国（`country.foreign.*`）的原生、确定性、数据驱动国家 AI。它是分层效用 AI
（Infinite Axis Utility System 风格），只和玩家一样提交命令，不直接改 SoA、不加资源、
不读迷雾外信息。玩家国家永远手动。

能力范围：科研与时代推进、国家默认税率、立族三选一、家族开拓。战争、外交、吞并、
国库赞助建造、意识形态不在本子系统内。

## 1. 文件与职责

| 文件 | 职责 |
| --- | --- |
| `gdext/src/country_ai_core.h/.cpp` | 纯整数内核：目录 IR、曲线、议程、科研/税收/开拓规划、记忆 hash。无 Godot 类型、无浮点、无时钟。 |
| `gdext/src/country_ai_runtime.h/.cpp` | 每国记忆 SoA、plan/commit 暂存、决策环、记录环、PKAI 编解码、报告计数。所有公共方法持 `_mutex`。 |
| `gdext/src/economy_runtime_country_ai.cpp` | 经济侧边界：`CountryAiEconomyDigest` 发布、开拓意图转 `START_FAMILY_EXPEDITION`、立族偏好打分。 |
| `gdext/src/world_ext_country_ai.cpp` | `DCWorldExt` 绑定、同步路径适配器、PKSV `pkai` 包装、原生自测。 |
| `scripts/country/country_ai_catalog.gd` + `data/country/default_country_ai.tres` | 数据目录（节奏、议程、性格、难度），`compile_native_catalog(seed)` 编译成原生字典。 |
| `scripts/country/country_ai_facade.gd` | 冷路径门面：配置、模式、报告、决策日志、记录行、存读档。 |
| `scripts/country/country_ai_csv_recorder.gd` | `country_ai_record` CSV 族。 |
| `tools/country_ai_tune/` + `Project/project-keynes/tools/country_ai_tune/apply_params.gd` | 离线 sep-CMA-ES 调参。 |
| `tests/runtime_country_ai_test.gd` | 集成测试：确定性、PROBE/ACTIVE 等价、存读档恢复、命令落地。 |

## 2. 命令来源与回执

- 来源标识 `COUNTRY_AI_PRODUCER_ID = 0x41494331`（"AIC1"），定义在 `country_ai_core.h`。
- `CountryAiRuntime::to_runtime_command(command, day, index)` 生成 `RuntimeCountryCommand`：
  `effective_day = day`，`sequence = (day << 16) | index`（按日主序，同日内按发射顺序）。
- 只使用玩家同样能提交的 opcode：`ENQUEUE_RESEARCH`(6)、`SET_RESEARCH_WEIGHTS`(5)、
  `SET_RESEARCH_BUDGET`(9)、`SET_TAX_DEFAULT`(11，仅 percent 模式)。
- 开拓不走 Country 命令。内核产出 `CountryAiColonizationIntent`，经济周期开启时由
  `process_country_ai_colonization_intents` 先做报价预检，再转成普通
  `COMMAND_START_FAMILY_EXPEDITION`。其 `sequence` 带
  `COUNTRY_AI_COLONIZATION_SEQUENCE_TAG = 1 << 62`，执行期拒绝回执（kind 7）据此归因给 AI。
- `publish_country_command_terminals` 跳过 AI 来源，玩家回执消费者不会看到 AI 的 REJECT。

## 3. 调度与挂载

### 3.1 Worker 路径（Country worker 权威）

在 `NativeSimulationHost::execute_country_worker_stage` 中：

1. 先把当天封存的玩家/系统命令入队。**来源为 AI 的旧包一律跳过**（见 3.3）。
2. `country_ai->due(day)` 为真时，从 D-1 已提交的 Country 权威快照和最新经济摘要规划
   day D，AI 命令单独记录 `ai_ids` 后入队。
3. `plan_day(D)`。`plan_day` 遇到任一坏命令就让整天失败，所以失败时先
   `remove_pending_producer(COUNTRY_AI_PRODUCER_ID)` 剔除所有 AI 命令、`reject_staged`，再重试
   一次 `plan_day`。玩家命令不受 AI 拖累。
4. Country `commit_day` 成功后 `commit_country_ai_day`：提交 AI 记忆，并把立族偏好、开拓意图
   交给经济运行时。plan 失败走 `abort`，记忆不前进。

`country_ai_for_worker()` 只在 Host 为 ACTIVE、请求了 Country 权威、且 AI 为 ACTIVE 时返回实例。

### 3.2 同步路径（非 worker 权威 / 主线程）

`DCWorldExt::run_country_slice` 调用 `country_ai_sync_plan(day)` 和
`country_ai_sync_finish(day, ok, out)`。同一内核从 `export_pod_snapshot` 规划，以
`submit_country_ai_batch`（`producer = COUNTRY_AI_PRODUCER_ID`）提交。Country 已由 worker
权威时 `country_ai_sync_due` 返回 false，两条路径不会同时规划同一天。

### 3.3 AI 包不重放

同步路径在 worker 接管前提交的 AI 包可能还留在 Host 队列里。worker 会用同一状态重新规划那
一天，重放旧包只会重复或因 generation 过期被拒，进而拖垮整天的 `plan_day`。因此以下三处都
在 `country_ai_for_worker() != nullptr` 时跳过 `producer_id == COUNTRY_AI_PRODUCER_ID` 的包：
新入队循环、late-fold open-plan 循环、已提交日顺延到 `committed+1` 的循环。

### 3.4 节奏

每个受控槽位 `((day + slot) % think_days) == 0` 时思考，错峰分摊负载。思考时各模块再按自身周期
（`strategy_days`、`research_days`、`tax_days`、`colonize_days`）判断是否到期；首次思考
（`initialized == 0`）立即执行战略、科研、税收三个模块，开拓等到第一个 `colonize_days` 周期之后，
这时已经有经济摘要和家族了。难度通过 `cadence_scale` 缩放这些周期。

## 4. 决策模块

所有评分都是 Q16 定点整数。随机项来自 `country_ai_mix(seed, handle, day, salt)`
（SplitMix64），种子是世界种子，因此 PC、Android、Web(WASM) 逐位一致。

### 4.1 战略层（议程）

- 五个议程：`develop`、`expand`、`accumulate`、`era_push`、`stabilize`。
- 每个议程最多 4 个考量，每个考量是 `{input, curve, x0, x1, y0, y1}`。输入有 8 种：
  `reserve_days`、`satisfaction_q16`、`frontier_cells`、`milestone_gap`、`territory_cells`、
  `essentials_q16`、`expeditions`、`cash_trend_bp`。曲线有 5 种：linear、quadratic、
  inv_quadratic、smoothstep、step。
- `country_ai_combine_scores` 做 IAUS 补偿：先按缺口给每个因子补偿，再相乘，避免考量越多分越低。
  任何因子为 0 仍是一票否决。
- 最终分 = 组合分 × 性格 `agenda_bias` × 当前议程的惯性加成（`agenda_inertia_bp`）×
  (1 ± 确定性噪声 `decision_noise_bp`)。
- `agenda_min_days` 内不换议程（决策日志记 `agenda_locked`）。
- 议程参数：`research_share_bp`（科研占可支配现金的比例）、`expansion_slots`（额外开拓并发）、
  `tax_bias_bp`（储备目标偏移）、`satisfaction_floor_shift`、`era_focus`。

### 4.2 科研与时代

时代没有独立动作，`visual_era_index_for_slot` 取已完成里程碑的最高下标。所以"升级时代"就是
科研规划：

- `CountryAiTechIndex` 在 Country 目录 hash 变化时重建：里程碑列表、`is_milestone`、每个科技的
  传递前置闭包位集。它不入存档。
- 目标里程碑 = 下一个未完成里程碑。候选按"剩余闭包成本 ÷ 性格领域亲和度"升序，取
  `gap`（`era_focus` 时多取 1）个，反向 DFS 展开前置，遇到可研究节点即入队。
  DFS 访问数受 `research_frontier_visit_limit` 限制。
- 优先级：里程碑本体 0（插到队首），`era_focus` 路径 1，普通路径 2，无目标时的低价兜底 3。
- 每次评估最多入队 `research_max_enqueue_per_eval` 项，每域队列上限 8。
- 研究权重按各域已排队成本占比，用最大余数法归一到恰好 10000。与现值差异小于
  `research_weight_threshold_bp` 时不发命令。
- 日预算 = (现金 − 储备底线) × 议程 `research_share_bp` × (0.5 + risk) ÷
  `research_budget_horizon_days`，并受 min/max 限制。储备底线 = `reserve_floor_cash` +
  日均赤字 × `reserve_target_days` / 4。相对变化小于 `research_budget_change_bp` 时不发命令。

### 4.3 税收控制器

- 只管 `tax_kind_mask` 选中的国家默认税（默认为所得、消费、营业三类），且只在该税为 percent
  模式时调整。AI 不碰地块级税和覆盖税率。
- 首次思考按性格 `tax_initial` 设初值，并夹在 `[tax_min, tax_max]` 内。
- 之后是离散 PI：`tax_pressure` 是 −8..8 的积分项。满意度低于 `floor − deadband` 时减税；
  储备天数低于目标且现金趋势为负时加税；储备充足、趋势非负且满意度不高时减税；否则压力回零。
  步长 = `tax_step_bp × |pressure|`，夹在 `[tax_step_bp, tax_max_step_bp]`。每次只调余量
  最大的一类税。满意度低于下限时禁止加税。
- 税率只在下一个经济周期生效，所以 `tax_days` 不应短于经济周期长度。

### 4.4 立族偏好

- 提交时按性格 `family_pref` 生成 `CountryAiFamilyPreferenceRow{handle, weights[4]}`，四维分别是
  已实现利润率、营收、创始人数、hash 抖动。签名不变就不重发。
- 经济 `FAMILY_COMMIT` phase 1 对 AI 国家地块调用 `family_founding_ai_choice`：每张卡按建筑的
  `realized_profit_margin_q16`、`last_revenue`（按本次报价最大值归一）和 `founders` 加权打分，
  抖动由 `(seed, "AIFO", offer_id, index)` 决定。无主地块、非 AI 国家、或没有偏好表时返回 −1，
  沿用原有随机规则。
- 立族不需要往返交互，也没有模态锁。

### 4.5 开拓

- 跳过条件依次为：上限为 0、冷却中、进行中数量达到 `colonize_max_in_flight + expansion_slots`、
  储备天数低于 `colonize_min_reserve_days`、没有边界格、没有家族。
- 从领土出发做六邻 BFS，半径为 `max(vision_radius, target_ring)`。候选是距离
  `1..colonize_target_ring` 的无主陆地格。评分 = 本国邻接 × Q16/6 + 陆地邻接 × Q16/12 +
  `cell_value_q16`，再乘 `2/(1+d)`，加确定性抖动。
- 意图附带 `vision_radius` 内的可见格列表。经济侧用它做 `family_colonization_quotes` 预检，
  所以 AI 不会看到迷雾外的报价。
- 经济侧按报价选第一个满足以下条件的家族：`maximum ≥ min_population`，目标未被占用，源格人口
  足够；人口取 `maximum × population_share_bp`，夹在 `[min_population, maximum]`。
- 回执闭环：摘要行带 `ai_colonization_started/failures`。失败计数增长时设置
  `colonize_failure_cooldown_days` 冷却。

## 5. 经济摘要

`publish_country_ai_digest()` 在经济发布阶段运行，产出不可变的 `CountryAiEconomyDigest`
（按 handle 排序）。之后由 `shared_ptr` 原子交换，跨线程只读。每国一行，字段有：

- 人口，人口加权的综合满意度和基本需求满意度（Q16）；
- 周期纳税、补贴、收入、支出；
- 家族数，进行中远征数（PREPARING/OUTBOUND/SETTLING），AI 开拓的 started/failures。

AI 不使用 `get_country_economy_overview` 这类遍历格子构建 Dictionary 的冷路径。摘要不进入
PKEC 和经济状态 hash。

## 6. 存档 `pkai`

- PKSV provider `pkai` 在 `game_save_coordinator.gd` 中注册在 `pkfg` 之后、`journal` 之前，
  属于必需段。没有 AI 的世界写空段。
- 外层包装 `PKAW` 依次写入：
  1. 内层 `PKAI`（magic `0x49414b50`、版本、目录 hash、Country 目录 hash、排除 handle、记忆行、
     记忆 hash）；
  2. 经济侧待处理的开拓意图；
  3. 开拓统计；
  4. 回执游标。
- 恢复时会校验 magic、版本、长度和记忆 hash。目录 hash 不一致时以 `catalog_hash_mismatch` 拒绝，
  不做迁移。恢复后重推立族偏好，并清掉同步路径的日标记。
- 玩家 handle 随 `pkai` 一起恢复。在 handle 设置或恢复之前运行时处于未 armed 状态，从不规划，
  所以缺失的玩家 handle 不会把玩家国家交给 AI。

## 7. 诊断

- 决策环（2048 条）：`CountryAiDecision`，记录模块、结果（EMITTED/REJECTED/SKIPPED/PROBE）、
  主体、得分、前三名备选和原因字符串。读取方式：
  `CountryAiFacade.decision_log(handle, after_id, limit)` / `poll_new_decisions`。
- 记录环（16384 行）：每个受控国家每次思考一行 `CountryAiRecordRow`，由
  `CountryAiCsvRecorder` 写成 `country_ai_record_*.csv`。列见 `COLUMNS`。
- 报告 `get_country_ai_report()` 的字段：`mode`、`armed`、`controlled`、`plans`、
  `countries_thought`、`commands_emitted`、`commands_rejected`、`retries`、
  `colonization_intents`、`plan_ms_max/total`、`state_hash`、`command_hash`、
  `restored_catalog_mismatch`。
- 无界面跑分：`run_headless_perf.ps1 -CountryAi OFF|PROBE|ACTIVE -CountryAiDifficulty easy|normal|hard`。
  结束时打印 `[headless-perf/country-ai]` 汇总和每国一行 `[headless-perf/country-ai/country]`。
- 环境变量：`PK_COUNTRY_AI_MODE`、`PK_COUNTRY_AI_DIFFICULTY`，以及仅供离线调参用的
  `PK_COUNTRY_AI_CATALOG`。最后一个会改变目录 hash，用它做的存档不能在默认目录下恢复。

## 8. 模式与难度

- `OFF`：不规划。`PROBE`：完整规划并记录决策（outcome=PROBE），不提交命令，用于 A/B 对照。
  `ACTIVE`：提交命令。
- 难度只调三个旋钮：噪声倍率（easy 2.5、hard 0.4）、节奏倍率（easy 1.5、hard 0.75）、储备
  保守度（easy 1.5、hard 0.75）。任何难度都不给 AI 额外资源。

## 9. 验证

- 原生自测 `runtime_country_ai_self_test()` 覆盖以下内容：
  - 曲线中点与夹取，组合一票否决，权重恰好归一到 10000；
  - 未 armed 时不规划，玩家国家不受控；
  - 科研目标路径确实入队，同输入两次规划结果一致；
  - 编解码后 hash 一致，目录 hash 不一致时拒绝恢复；
  - 恢复后继续规划与不中断的结果一致。
- `tests/runtime_country_ai_test.gd`（18 项检查）：同种子决策 hash 一致；PROBE 与 ACTIVE 决策
  序列一致；中途存读档后决策 hash 与不中断一致；命令确实进入 Country 队列。
- `tests/game_save_roundtrip_test.gd`：AI 为 ACTIVE 时允许读档后 generation 继续前进
  （AI 会改外国状态）。
- 长跑验收（`-Days 3650 -ForeignCount 5 -CountryAi ACTIVE`）：
  - 不出现经济 fatal 和 `money_conservation_failed`；
  - 没有国家现金长期为负；
  - 外国推进里程碑，领土增长；
  - 命令拒绝率低；
  - `plan_ms_max` 远低于 1 ms。

## 10. AI 长跑暴露并修复的经济问题

AI 第一次让外国真正收税、开拓，因此暴露了几处原有的守恒/调度漏洞：

1. **投入品交易税在信贷失败后不回滚**（`economy_runtime_building_production.cpp`）。
   `quote_transaction(..., settle=true)` 当场记税。之后如果商人信贷不足而放弃购买，税仍留在
   税道上；商人资金也可能只被部分扣走。现在会先 `snapshot_fiscal_lane`，失败时
   `restore_fiscal_lane`，并通过 `credit_local_merchants` 退回部分扣款。
2. **结算格之外的税款丢失**（`economy_runtime_fiscal.cpp::commit_fiscal`）。
   税可能落在本周期滚动工作集之外的格子上，例如跨格贸易在目的地征收的交易税。所有税道在周期
   开启时清零，原来只汇总 `_epoch_settlement_cells`，这部分已扣付款方的钱就凭空消失。现在会把
   非结算格的流量合计并入同国汇总和托管，但不改它们的请求历史。
3. **资产背压原因被误判为 fatal**（`runtime_economy_pod.cpp::run_bound_stage`）。
   POD 手写的"对端暂停"列表漏了 `country_economy_asset_country_plan_pending` 和
   `country_economy_asset_territory_claim_pending`。Host 把这两个原因当作可重试暂停，POD 却置了
   `_replay.fatal`，于是 `commit_epoch` 以 `economy_pod_fatal` 失败。现在统一调用
   `runtime_country_asset_pending_reason`。
4. **同步路径遗留 AI 包拖垮 worker 的 `plan_day`**：见 3.3。
5. **并行市场写生产者补贴台账的数据竞争**（`economy_runtime_market.cpp`）。
   `process_market_cell` 在 `run_markets` 的并行任务里执行。供给剩余分支原来直接累加
   `_production_output_supported/_stock`、`_producer_support_money_issued`、
   `_explicit_money_mint`、`_producer_revenue` 以及 bullion/gold/silver 台账，并发时会丢失更新，
   表现为居民阶段偶发的商品 +n、货币 +m 守恒误差。现在先写进 `MarketResult` 的同名字段，再在
   `economy_runtime.cpp` 的串行汇总里合并。
6. **取消备货中的远征时丢掉在途采购腿**（`economy_runtime_colonization.cpp::abort_preparing_family_expedition`）。
   远征备货的续接每次只有一笔 Country 请求在途：第 1 阶段 `GOOD_FROM_MARKET`，第 5 阶段
   `TREASURY_SPEND`，都被标记为自结算。原来取消时会 `release` 推迟标记并丢弃续接，之后普通刷新
   仍会提交 Country 那一腿：
   - 采购腿：国库得到 +q 商品、扣掉 −c 现金，市场库存已被服务端扣掉，但给商人付款的第 4 阶段
     丢了，于是货币 −c。
   - 转移腿：国库扣掉 −q，货物却没进货舱，也不会随取消退回市场，于是商品 −q。

   误差在下一次定向结算（常见于科研采购的 `finish_worker_country_asset`）时一起暴露，所以看起来像
   科研阶段的问题。现在在途的续接会转入 `_family_expedition_procurement_orphans`，仍然保持推迟。
   `process_due_family_expeditions` 每次先调用 `settle_family_expedition_procurement_orphans`：
   等终态到达后，采购腿补上商人付款，货留在国库；转移腿把货退回来源市场；被拒绝的终态直接确认
   丢弃。读档恢复时清空这个列表（旧会话的请求不会再有终态）。
7. **无主格人群的遗产/余额转国库直接致命**（`economy_runtime.cpp::coordinate_country_cohort_cash`）。
   结构排序在清除空人群（`STRUCTURAL_REMOVE_EMPTY`）或迁移后余额归零时，会按所在格查国家，把钱
   转进国库。开拓定居时人口可能先落到目标格，而 Country 认领尚未提交，这时国家句柄为 0。原来
   句柄校验排在 `amount == 0` 之前，即使没有钱也会以 `country_cohort_cash_request_invalid` 致命。
   现在 0 金额直接放行；金额大于 0 时返回软原因 `country_cohort_cash_treasury_unowned`，两个结构
   调用点按“闸门关闭”同样处理：钱留在人群上，以后再转，不销毁也不致命。

**未解决：偶发原生崩溃。** 4 局并行长跑时，大约每 6 局有 1 局出现访问违例（signal 11 /
`0xc0000005`），日期没有规律（启动时，第 369、819、2400 天都出现过）。崩溃前没有守恒或致命日志。
有一份 dump 显示在 `dots_ext` 内对空指针写入。挂在 `cdb` 下跑 4 局都没能复现，带符号的崩溃栈
仍待获取。下一步：用带 `debug_symbols=yes` 的构建配合 WER LocalDumps，或在调试器下多跑几批。
不要把它当作 AI 决策问题来处理：AI 只经由 Country 命令写状态。

## 11. 离线调参

`tools/country_ai_tune/cmaes_tune.py` 只用 Python 标准库，实现 sep-CMA-ES（对角协方差）：

- 搜索空间在 `tools/country_ai_tune/param_space.json` 中定义，每个参数是 `{path, min, max}`，
  优化在归一化的 `[0,1]` 盒内进行。越界样本裁剪后加二次惩罚。
- 每个候选先由 `apply_params.gd` 写成 `.tres`（写前用 `compile_native_catalog` 校验），再通过
  `PK_COUNTRY_AI_CATALOG` 注入，按多个种子跑正式无界面对局。
- 目标函数读每局的 `country_ai_record` CSV，按以下加权和计算：
  - 生存：人口 > 0，且现金为负的天数占比低；
  - 发展：里程碑和领土增长，相对目标值；
  - 均衡：各国发展分的 1 − 变异系数；
  - 差异度：不同性格议程分布两两之间的总变差距离；
  - 减去命令拒绝率。

  经济 fatal 或缺 CSV 的对局记为 `failed_run_score`。
- `state.json` 支持 `--resume`，`history.jsonl` 记录每个候选。`--baseline-only` 只给当前目录打分。
  `--write-back` 把最优解写回 `data/country/default_country_ai.tres`。

```text
python tools/country_ai_tune/cmaes_tune.py --generations 6 --days 1825 --seeds 20260718 20260719 --jobs 2
python tools/country_ai_tune/cmaes_tune.py --resume --generations 12 --write-back
```

调参产出的只是目录参数，运行时依然确定性、带 hash 校验。改了默认目录会改变目录 hash，
旧存档会以 `catalog_hash_mismatch` 拒绝恢复。

## 12. 扩展规则

- 新的决策维度先加到 `CountryAiCatalog`（原生）和 `country_ai_catalog.gd`，并纳入
  `country_ai_catalog_hash` 与校验。新输入要追加到 `CountryAiInput` 和 `INPUT_IDS` 的末尾，
  不能重排。
- 新动作必须是玩家同样可提交的命令，或经济侧现有命令。不得新增"AI 专用"的状态写口。
- 改 `CountryAiMemory` 布局要升级 `PKAI_VERSION`。
- 外国目前拿不到时代奖励（Offer Planner 只绑定玩家国家），这是已知的发展速度差距，另立方案处理。
