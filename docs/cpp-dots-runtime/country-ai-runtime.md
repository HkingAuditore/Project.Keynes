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
- 财政上限：日预算再取 min(上式, 居民日均纳税 × `research_tax_share_bp` + 人口 ×
  `research_per_capita_budget`)；人口加权基本需求满意度低于 `research_essentials_floor_q16`
  时预算为 0。原因是科研采购直接用国库现金付给商人，而开局国库（约 2.5e12）比整个居民经济大
  几个数量级，按国库比例花钱等于持续印钞，物价跑赢收入后居民买不起必需品，见 §10 第 8 条。
  纳税必须是日均值：经济周期长度可变，2026-10-13 之前摘要给的是整周期合计，上限因此是真实日税的
  数倍，科研采购注入的钱又被征回来抬高上限，形成正反馈。
- 先温饱再科研：饥饿人口占比（`hungry_share_q16`，见 §5）达到 `research_hungry_share_max_q16`
  时预算为 0；人口加权负载 `carrying_load_q16` 不超过 `research_load_full_q16` 时全额，到
  `research_load_zero_q16` 线性降到 0。默认 catalog（2026-10-14 人口优先）把科研财政份额、
  负载/饥饿截止、开拓母国密度门槛与食物补贴拧得更紧：高负载时先停采购与开拓，再谈时代推进。

### 4.3 税收控制器

- 只管 `tax_kind_mask` 选中的国家默认税（默认为所得、消费、营业三类），且只在该税为 percent
  模式时调整。AI 不碰地块级税；覆盖税率只用于下面的食物补贴。
- 首次思考按性格 `tax_initial` 设初值，并夹在 `[tax_min, tax_max]` 内。
- 之后是离散 PI：`tax_pressure` 是 −8..8 的积分项。满意度低于 `floor − deadband` 时减税；
  储备天数低于目标且现金趋势为负时加税；储备充足、趋势非负且满意度不高时减税；否则压力回零。
  步长 = `tax_step_bp × |pressure|`，夹在 `[tax_step_bp, tax_max_step_bp]`。每次只调余量
  最大的一类税。满意度低于下限时禁止加税。
- 税率只在下一个经济周期生效，所以 `tax_days` 不应短于经济周期长度。

### 4.3a 食物补贴

- 每次思考（非首次）都评估，归在 TAX 模块。补贴是玩家同款命令：营业税（kind 2）覆盖
  `SET_TAX_OVERRIDE`（opcode 12），税率 `subsidy_food_rate_bp`（默认 −2000，即对生产商收入补
  20%），对象是摘要 `food_building_types` 标为 1 的建筑类型（有生存食物产出）；撤销用
  `CLEAR_TAX_OVERRIDE`（opcode 13）。`CountryAiCommand::tax_item` 承载建筑下标。
- 开关带滞回：关闭时饥饿占比 ≥ `subsidy_on_hungry_share_q16` 才打开，打开时 ≤
  `subsidy_off_hungry_share_q16` 才关闭。开关状态从已提交的 Country 覆盖税率读回（等于补贴税率的
  食物类型数 > 0 即视为打开），所以不占记忆、不改 PKAI 版本。打开时补齐缺失的类型。
- 资金走既有财政托管：本批补贴额度来自上一批的补贴请求、由国库预留，第一批没有历史时付 0；
  不铸币。`tax_kind_mask` 不含营业税或 `subsidy_food_rate_bp = 0` 时不补贴。
- 记录 CSV 的 `food_subsidy_bp` 是当时生效的补贴税率（0 = 未补贴）。

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
  储备天数低于 `colonize_min_reserve_days`、没有家族、人口不足
  （低于 `colonize_min_country_population`，或低于 `colonize_min_population_per_cell` × 领土格数，
  原因 `colonize_population_low`）、基本需求满意度低于 `colonize_essentials_floor_q16`
  （`colonize_essentials_low`）、饥饿人口占比高于 `colonize_hungry_share_max_q16`
  （`colonize_hungry`，已有殖民地还在挨饿时不再扩张）。远征会带走家族的一部分人口，母国太小或
  吃不饱时开拓只会让国家缩小。无边界格不再单独跳过——仍可对本国稀薄格补人。
- 从领土出发做六邻 BFS，半径为 `max(vision_radius, target_ring)`。拓荒候选是距离
  `1..colonize_target_ring` 的无主陆地格。评分 = 本国邻接 × Q16/6 + 陆地邻接 × Q16/12 +
  `cell_value_q16 × colonize_cell_value_weight_bp / 10000`，再乘 `2/(1+d)`，加确定性抖动。
  `cell_value_q16` 低于 `colonize_min_cell_value_q16` 的格子不作为目标。
  补人候选是本国陆地格且人口 `< colonize_min_population`，按缺口与宜居度打分。
- `cell_value_q16` 由 `CountryAiFacade.colonization_cell_values(map)` 在配置时计算，只读生成期
  字段（`is_water_arr`、`base_terrain_arr`、`elevation_arr`、`base_moisture_arr`、
  `temp_baseline_year_arr` 减海拔降温），所以读档重算结果一致，不需要入存档。水面和不可通行地形
  为 −Q16；温度、湿度、海拔超出开局选点范围（`start_location_profile.gd`）为 −Q16/2；其余按
  温度 0.40、湿度 0.35、海拔 0.25 加权的宜居度映射到 1..Q16。
- 意图附带 `vision_radius` 内的可见格列表。经济侧用它做 `family_colonization_quotes` 预检，
  所以 AI 不会看到迷雾外的报价。
- **补人优先于拓荒**：若本国领土 ≥ 2 格，且存在人口 `< colonize_min_population` 的本国陆地格，
  先对最稀薄格发 `reinforce_intent`（Economy `relocate`）；没有稀薄格时才对无主前沿发
  `colonize_intent`。无前沿时仍可补人，不再被 `colonize_no_frontier` 卡死。
- 经济侧在报价里选**派出人数最大**的家族（人数相同再比路线成本）：`maximum ≥ min_population`，
  目标未被占用，源格人口足够；人口取 `maximum × population_share_bp`，夹在
  `[min_population, maximum]`。默认 `population_share_bp=5000`（半数盈余）、
  `min_population=20`（对齐开局城规模）；经济 kit 硬下限仍是 3，但 AI 不再派三人死城。
  补人时额外要求源格在派出后仍 ≥ `min_population`，避免拆空首都。
- Digest 携带 `cell_population[]`（提交时每格存活人口），供补人选址；不入存档。
- 回执闭环：摘要行带 `ai_colonization_started/failures`。失败计数增长时设置
  `colonize_failure_cooldown_days` 冷却，并把上一次意图的目标格（`colonize_last_target`）写进
  记忆里的 4 格环形黑名单 `colonize_bad_targets`，之后选址跳过这些格子；成功计数增长时清掉
  `colonize_last_target`。每次只有一个意图在途，所以失败可以归到上一次目标。没有黑名单时，
  路线不通或报价为空的目标会在每次冷却结束后被重新选中，国家会永远开拓失败
  （era30b 里 1 格国家失败 44 次、成功 0 次）。

## 5. 经济摘要

`publish_country_ai_digest()` 在经济发布阶段运行，产出不可变的 `CountryAiEconomyDigest`
（按 handle 排序）。之后由 `shared_ptr` 原子交换，跨线程只读。每国一行，字段有：

- 人口，人口加权的综合满意度和基本需求满意度（Q16）；
- 饥饿人口占比 `hungry_share_q16`：基本需求满意度低于 `COUNTRY_AI_HUNGRY_ESSENTIALS_Q16`（0.9）
  的人口 ÷ 总人口。加权均值会把一个挨饿的格子摊平，占比不会；
- 日均纳税、补贴、收入、支出：每个人群的周期累计除以所在格的 `cell_elapsed_days`，与国家
  经济概览的 `*_day` 口径一致；
- 家族数，进行中远征数（PREPARING/OUTBOUND/SETTLING），AI 开拓的 started/failures；
- 领土格的食物流承载力合计 `carrying_k_eff` / `carrying_k_geo`（人数），以及按人口加权的平均负载
  `carrying_load_q16`（每格人口 ÷ `K_eff`，单格上限 4×Q16，`K_eff = 0` 的有人格记为上限）。负载超过
  约 0.9 时该格出生率降到更替水平。用加权而不是最大值，是因为一两个人的新殖民地常常没有食物产出，
  最大值会被它们顶满。记录 CSV 同名三列。逐格明细可用 `PK_HEADLESS_CARRYING_DUMP=1` 跑无界面
  对局，结束时每个领土格打印一行 `[headless-perf/carrying]`（人口、食物产出、库存、K、负载、
  肥沃土壤/旱地/野生动物的 MapData 储量、建筑），随后三行：`[headless-perf/savings]`（人均生活成本、
  各职业人数与存款折合天数）、`[headless-perf/prices]`（几种口粮价格，按价格×需求排前 6 的商品及库存）、
  `[headless-perf/groups]`（数量最多的 8 个建筑组的业主数、营业状态、计划/实际开工率、产出、收入、成本）。
  科技推进可用 `PK_HEADLESS_TECH_EVERY=<天数>`：每隔该天数和结束时每国打印 `[headless-perf/tech]`
  （当前时代、各时代 完成/已发现/可研究/总数、科研预算与点数、当前时代 ready 但未排队的科技）、
  `[headless-perf/tech-signals]`（按种类计的研究信号数和已得 `development.*` 列表）、
  `[headless-perf/tech-dev]`（农业时代发展目标的当前值/连续天数/完成）和一行事件/触发器 POD 计数。

摘要还带一张按 Country 营业税项下标排列的 `food_building_types`（建筑类型有任一产出属于生存
食物商品即为 1），供 §4.3a 使用；经济与 Country 的建筑类型下标同序（目录 hash 校验）。

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
  `CountryAiCsvRecorder` 写成 `country_ai_record_*.csv`。列见 `COLUMNS`；`tax_paid`、
  `household_income` 是居民日均纳税和收入，用来核对科研预算是否超过经济体量；
  `hungry_share_q16`、`food_subsidy_bp` 是饥饿占比和生效中的食物补贴税率。
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
- 评估 AI 好坏至少要跑 25 年并对照同种子 PROBE。前 10 年人口按固定出生率（年 20% 出生、2.5% 死亡）
  逼近理论上限，任何决策都只能打平或拖累，看不出差别。2026-10 的 50 年数据（种子 20260718，5 国合计）：
  PROBE 第 25 年 7206 人，当前 ACTIVE 1984；只保留税收 5938，税收+开拓 4811，税收+科研 4322，
  只开拓 3612，全关 6325（单局噪声约 ±20%）。科研拖累最大，开拓其次，税收最小。
  逐格明细（`PK_HEADLESS_CARRYING_DUMP`，第 15 年）显示机制：
  - 科研采购给科技点创造了市场需求，家族纷纷兴建知识机构、口传记忆圈；科研又解锁大量手工业建筑。
    劳动力从采集、狩猎流出，ACTIVE 母国约 60 种建筑、人均食物产出下降，负载 0.66–0.78，贴近 0.9 的
    出生抑制线；PROBE 母国只有 6 种石器时代食物建筑，负载 0.19–0.56。
  - PROBE 单格的 `K_eff` 随劳动力同步上涨（75 → 3709 人）。边际递减是有的（可再生资源安全产出、
    capacity 门闩），但单格按「湾区」约 5000 座早期建筑校准，开局 20 人按 17.5%/年 要约 30 年才碰到。
  - 殖民地承载力正常，但开局只有 2–3 人、5 年后仍是 2–12 人，对总人口几乎没有贡献。
  也就是说在现有经济规则下，税收、科研采购和开拓的长期回报都是负的，调 AI 之前先要让这些手段
  有正回报。
- 2026-10 规则审计（`tools/food_yield_audit.gd` 输出食物建筑人均口粮与科技修正项；按国家年拆分增长）：
  - 出生乘数 = `clamp(综合满足度 / 0.70, 0.125, 1.0)`，负载 < 0.9 时不受食物影响；死亡率固定，
    饥饿死亡仅在温饱维度 < 0.5 时线性加到最高 0.5%/日。满足度 ≥ 0.70 的「不作为」国家已经以最高速度增长，
    发展只会让增长更慢、不会更快。
  - 各局国家平均出生乘数都在 0.99–1.00；ACTIVE 与 PROBE 的差距几乎全是额外死亡或外流：PROBE 理论 17.5%、
    实际 16.4–16.8%；ACTIVE（50 年种子 18）缺口 8.6%/年，22% 的国家年生存品最低值 < 0.9；
    开科研的局 22–33%，只开开拓的局缺口 4.1% 但饥荒年仅 7.5%（殖民者死在小殖民点）。
  - 目录名义人均口粮（每个劳动力养活人数）：采集营地 4.54、狩猎营 1.97、野生作物 2.61；农耕时代玉米园 3.31、
    旱作小麦 4.53、自耕农场 2.75；王国佃农田约 3.6；帝国庄园 13.6；启蒙改良小农 36.7。农耕/王国建筑人均
    不高于采集，农业转型不释放劳动力。实测石器母格每个食物劳动力约养 1.85 人，约 64% 人口在产食物。
  - 科技产出修正（商品级 × 行业级 × 产业族 × 建筑级，层内 1+Σ）叠满石器+农耕玉米线约 5.6 倍，
    但增长不受食物驱动，额外食物不转化为人口。
  - 补贴即负税率（所得/消费/营业，可按职业/商品/建筑覆盖，预算来自上批税收）；AI 税收控制器只调
    5 个基础税率、默认区间 1–25%，从不使用补贴或覆盖。
  - 资源不稀缺：第 11–15 年主格沃土/可耕地/野味储量仍为开局的 85–95%。PROBE 各职业存款为 1000–30000 天
    生活成本；ACTIVE 饥荒格采集者只有 0–70 天，个别商人数十万天。
  - ACTIVE 饥荒是科技解锁后的劳动力错配，不是缺地（种子 20260718 第 11 年，转储里的
    `[headless-perf/prices]` 与 `[headless-perf/groups]` 两行）：
    - 公共火塘（`tech.fire_control`）每座每日吃 5240 原木 + 1053 食物当量，产 2115 食物当量；连同约 0.75 个
      伐木者，1.75 个劳动力只净增约 0.29 个采集者的口粮。熟食主粮的消费偏好是采集植物的 2 倍。
    - 原木需求 10–17 万/日把木价从约 1 推到 6.6 万，猎人和采集者转去伐木、打石器、烧炭；cell 1688 的 40 座
      狩猎营地 0 人停业，野味价格 281 万。打制石器解锁后所有采集/狩猎建筑把 `tools` 当软投入采购，石器价格
      12 万–860 万且库存为 0。
    - 只要熟食主粮还有 2–3 个库存，`_cell_living_cost_per_capita` 就按它 36 万–970 万的价格算主粮，
      生活成本涨到 1–32 万（PROBE 约 800–1800）。采集地按利润计划只开 21%（PROBE 100%）。
    - 同一局 cell 789 的火塘有人经营，熟食主粮跌到 7576，食物 152 万当量/日、负载 0.03。价格信号最终能
      把劳动力拉回来，但调整期里人口已经饿死。
- 2026-10 规则调整（AI 决策逻辑未动）：
  - 31 座食物建筑按目标人均口粮提产（农耕约 6.5、王国佃农约 9.5、庄园 12–18、近代 24）；公共火塘原木
    5240 → 1500、产出 2115 → 2000 食物当量。烧炭坑 27% 的出炭率符合实际，没有改。
  - `_cell_living_cost_per_capita` 按可购买量加权（见 `satisfaction-runtime.md`）。
  - 删除知识部门 30% 人口上限；向上转职改为绝对存款门槛 `entry_savings_days`（见
    `native-economy-runtime.md`）。
  - 基础自然死亡 7.5%/年，12 项科技经 `country.population.death_factor` 降到最低 2.5%；出生乘数在综合满足度
    0.85 时升到 1.15，负载 0.9→1.0 渐退。
- 规则调整后 25 年长跑（5 个外国，种子 20260718 / 20260719 / 3；旧规则数据取 50 年长跑的前 25 年）：

  | 种子 | PROBE 旧 → 新 | ACTIVE 旧 → 新 | ACTIVE/PROBE 旧 → 新 | ACTIVE 饥荒年 旧 → 新 |
  |---|---|---|---|---|
  | 20260718 | 7194 → 4483 | 1980 → 1365 | 0.28 → 0.30 | 24.6% → 31.0% |
  | 20260719 | 6241 → 4326 | 1252 → 1172 | 0.20 → 0.27 | 17.5% → 39.7% |
  | 3 | 6739 → 4408 | 1214 → 1719 | 0.18 → 0.39 | 38.9% → 28.6% |

  - PROBE 不研究科技，自然死亡停在 7.5%，下降约 35% 是基础死亡上调的直接结果。
  - ACTIVE 相对 PROBE 的比例三局都改善，但饥荒没有消失。种子 20260719 第 25 年的饥荒主格：cell 1680
    有 62 座狩猎营地和 29 座打制石器作坊 0 人经营，石器价格 186 万、库存 0；cell 1851 狩猎营地全部停业，
    野味 401 万，141 个采集者存款 0 天、家庭食物购买量为 0。猎人门槛为 0，采集者的存款也够进工匠，
    所以存款门槛没有卡住这些转职；知识建筑多数空置。剩下的问题是空置的狩猎营地和石器作坊招不回人。
- 招不回人的根因是 ACTIVE 组经营计划的两处偏差，把食物组锁在生存下限开工率上（细节见
  [原生经济运行时](./native-economy-runtime.md)「软投入与生存生产」和 `last_observed_capacity_days_q16` 段）：
  - 计划成本按市价全额计入软投入工具。石器库存 0、价格约 90 万时，采集地每座每天被记约 9 万工具成本，
    而业主生活成本约 1.2 万，于是判亏损。生产端其实只在增产价值超过成本时才买工具。
  - 回款按只含到岗率的产能日归一，没除掉上期计划开工率。停在 28% 下限的组把自己的限产读成低价，
    下一期仍判亏损。狩猎营地不用工具，也一直停在下限，就是这个原因。
  - 业主转职报价本来是对的（采集地 17 万–120 万/天），狩猎营地的事实收入却被锁死在约 2.4 万，于是猎人
    流向采集地，两边都只按下限产粮。
- 修复后 25 年长跑（同样设置）：

  | 种子 | PROBE 修前 → 修后 | ACTIVE 修前 → 修后 | ACTIVE/PROBE | ACTIVE 饥荒年 修前 → 修后 |
  |---|---|---|---|---|
  | 20260718 | 4483 → 4041 | 1365 → 1435 | 0.30 → 0.36 | 31.0% → 27.8% |
  | 20260719 | 4326 → 3919 | 1172 → 1859 | 0.27 → 0.47 | 39.7% → 18.3% |
  | 3 | 4408 → 4349 | 1719 → 2452 | 0.39 → 0.56 | 28.6% → 12.7% |

  - 长跑结果不可复现，PROBE 也一样。同种子同代码重跑的第 25 年人口：ACTIVE 曾得到 1172 和 2449；
    种子 20260719 的 PROBE 修前三次 4326 / 4296 / 3745，修后四次 3919 / 4618 / 4979 / 4581。单次差 10–25%，
    表中单局 PROBE 的升降都在噪声内；按多次均值，该种子修后 PROBE 约高 10%。
    比较规则改动至少要同种子跑 3 次取均值。
  - 不可复现的根源（2026-10-13 用 `PK_SIM_DAY_TRACE` 对比两次并行运行）：主线程最多领先 worker 3 天，
    每天打包环境快照时从 DataCore 镜像复制数据，而镜像要等主线程应用 worker 的回写才更新，停在 worker
    的哪一天取决于机器快慢。同一输入日两次运行的快照内容从第 5–8 天起就不同。已知四条通道：
    1. 经济的气候输入（温度、湿度、可用水、降水、积雪、天气强度、地形、植被）。已修：气候在本 worker
       已提交当天时，`capture_worker_day_input` 改读 `_climate_authority.store()`。
    2. worker 气候读主线程按时机更新的状态。已修（2026-10-13）：season refresh 改在捕获时、先把回写追到
       上一捕获日再一次跑完；土壤湿度、日照、热输入、地形改读 worker 上一日提交态；`refresh_convergence`
       按捕获日取、天气过渡 dt 固定 1 天、热赤道由内核用 worker 温度重算；stage_b 节拍与 season refresh
       边沿对同日重试幂等；Climate 授权从第二次捕获起等 worker 提交上一捕获日，切换日固定在第 2 天；
       ACTIVE 请求了 Climate 而 worker 首日尚未提交时，主线程的 Climate 日程也抑制
       （`climate_main_thread_suppressed`），否则主线程那一跑落在首次捕获前还是后取决于时机，约 1/30 次
       运行在第 1 天就分叉（清单见 climate runtime skill `current-status.md` 第 18 条）。
    3. 资源储量。原先经济每次捕获都用主线程槽位重置储量（储量 + 待处理差额），而采集差额的排空和自然再生
       都跟着主线程帧节奏走，锁步下第 3 天就分叉。已修（2026-10-13）：worker 经济自己持有储量，只在首次
       worker 捕获时从槽位（读档时从存档储量）播种一次；之后采集在提交时并入 worker 通道，自然再生在每次
       捕获时用 worker 气候按天结算（详见 `native-economy-runtime.md`「worker 自持资源储量」）。
       修后锁步 64 天 `[econ-data]` 全部字段一致。
    4. 经济自适应节拍（保留，不修）。市场/计划/投资周期天数由工作量估计除以实测每刀毫秒（EMA）决定，
       实测值随机器快慢变，周期一旦选得不同，结算工作集就不同。`[econ-cadence]` 行记录每次周期变化。
       负载越高周期越长，增长越慢：12 局并发时每局第 5 年人口都低于少量并发。做 A/B 比较时设
       `PK_ECONOMY_FORCE_CADENCE=1,5,10`（市场/计划/投资天数，`EconomyFacade._apply_forced_cadence_env`
       写入测试用的 `economy_cadence_force_*` 键），重复运行逐字节一致（负载下验证到第 1400 天），
       不同批次、不同并发数的结果可以直接比较。正式对局不设此变量。
    修后验证（种子 20260719、5 国 PROBE）：临时固定经济周期时，三次流水线和一次锁步 365 天的气候输出与
    `[econ-data]` 逐日一致，锁步与流水线也等价。不固定周期时（加上首日抑制后）：六次并发流水线 136 天气候
    与经济全部一致；三次锁步里两次完全一致，且气候与流水线一致，第三次经济在第 2 天分叉（那天是否做
    经济输入捕获不同，即周期相位已经不同），气候随后在第 29 天跟着分叉，因为 round 输入里的 landform/cover
    来自经济建设。也就是说气候自身不再引入分叉，但长跑会被经济节拍带偏；比较规则改动仍要同种子多跑几次
    取均值。
    另外 ACTIVE 的 AI 读的是经济系统最近一次发布的摘要，第 D 天读到哪个 `commit_day` 同样取决于墙钟，未修。
  - `PK_SIM_DAY_TRACE=<文件>`：worker 每天写一行 `[sim-day-trace]`（各域哈希）和 `[econ-data]`（经济人口、
    存款、库存、价格、资源储量的纯数据哈希；`econ_hash` 混入了代计数，不能单独用来判定分叉），每次捕获写
    `[input-capture]`、`[env-fields]`（快照逐字段哈希）、`[economy-input]`（经济输入逐项哈希）。
    ACTIVE 下气候不每天算哈希，`climate_hash` 是旧值。气候内核每天写 `[climate-round-in]`（round 输入
    逐 lane 哈希）和 `[climate-out]`（每个 stage 之后温度、湿度、积雪、cover、水量平衡、PAW、天气强度/降水/
    类型、水汽的短哈希，标签是 `RuntimeClimateStage` 序号，`round`/`end` 为 round 散射后与当天结束）；
    两次运行比 `[climate-out]` 就能定位从哪个 stage 开始分叉。`[climate-round-in]` 的 `season_moist`（只在
    season refresh 当天消费）和 `[economy-input]` 的 `r*`/`c*`（资源镜像，只用于首次播种）不同是正常的。

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

8. **AI 自己的决策把小国饿死**（`country_ai_core.cpp` 的 `think_research` / `think_colonize`）。
   开局外国约 20 人，默认 ACTIVE 长跑 10 年后 5 国人口只剩 2–33，而 PROBE（只规划不提交）是
   108–124。消融实验定位到三处：
   - 科研预算按国库比例算，每天约 3500 万，是全国居民日收入（约 150 万）的 20 多倍。采购款直接
     付给商人，相当于持续印钞，物价跑赢收入，居民买不起必需品。关掉科研采购后人口回到 98–128。
     修复：§4.2 的财政上限，科研最多花掉本周期居民纳税的一半，必需品不足时停采购。
   - 开拓不看母国大小：20 人就派远征，每次带走家族 25% 人口，目标格也不看能否养活人。领地扩到
     3–5 格后总人口反而只有单格国家的一半。修复：§4.5 的人口/人均/必需品门槛和
     `cell_value_q16` 宜居度过滤。门槛 60/40 时仍明显拖慢，100/60 才接近 PROBE。
   - 把科研改成花掉全部税收（`research_tax_share_bp = 10000`）会再次明显拖慢增长，所以默认保持 5000。

   修复后 3 个种子 × 5 国 10 年：人口 90–118（PROBE 115–133），里程碑 0–2，领地 1–2。
   部分开局格本身在 PROBE 下也会周期性饥荒死光（如种子 1 的 1 号国），那不是 AI 决策问题。

9. **主线程查询改写 worker 的活跃格列表**（`economy_runtime_cadence.cpp::economy_live_cells_query`）。
   这是之前"偶发原生崩溃"（约每 6 局 1 次 signal 11，日期无规律）最可能的根因。自然资源每日系统
   在主线程调用 `get_economy_live_cells`，原实现会当场 `rebuild_economy_live_cells()`：清空并重写
   `_economy_live_cells` 和 `_cell_population_total`，同时遍历人口存储和在建列表。worker 在同一
   周期内遍历 `_economy_live_cells` 征税（`economy_runtime.cpp` 税道构建）和做投资评估，于是可能
   读到被重新分配的容器（访问违例），或只遍历到一部分格子（税和资金对不上，表现为崩溃后紧跟的
   `money_conservation_failed`）。现在每次重建末尾发布一份不可变快照
   `_economy_live_cells_published`（互斥锁保护），查询只复制快照，不再改动 worker 数据。快照最多
   晚一个经济周期；首次重建前返回空表，自然资源系统会把所有格子按野外节奏处理。
10. **负资金的遗产/余额转国库直接致命**（`coordinate_country_cohort_cash`）。结构排序清除空人群或
    迁空后转余额时直接传 `funds`，负数（负债）会以 `country_cohort_cash_request_invalid` 致命
    （50 年长跑第 17933 天出现）。现在负金额返回软原因 `country_cohort_cash_negative_balance`，两个
    结构调用点像"闸门关闭"一样保留人群和负债，不增发也不销毁货币。

修复 9、10 后 4 局 10 年并行长跑和 50 年长跑均未再出现崩溃或致命错误。不要把这类问题当作 AI
决策问题来处理：AI 只经由 Country 命令写状态。

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
