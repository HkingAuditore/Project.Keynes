# Market V2 冻结周期、错峰与调度契约

高速档稳定合批和 `executed_stage` 归因规则见
[运行时性能优化契约](runtime-performance-optimization-2026-07.md)。

## 为什么不再每日全量

10M cohort × 16 needs 等于每轮约 1.6 亿条需求。旧实现虽然是 C++/SoA/WTP，仍要求
每天在 20 个 slice 内完成整图，单 slice 约处理 50 万 cohort，因此 p95 约 89ms。
瓶颈是固定点除法、need/bundle 展开和内存带宽，不是跨语言 Dictionary。

Market V2 / Price V3 现采用 `production_income_consumption_v12`：周期起点冻结价格、科技、环境、
资源和企业价格信号；建筑生产会在居民清算前改变资金与库存，使本期收入和新商品可参与本期消费。
在 N 个模拟日内按地块连续 range 错峰计算，需求量一次性乘 N；所有地块与
结构命令完成后，最早在周期截止日统一发布 N 日交易总量。

## v16 阶段归属

没有新增调度阶段。恢复候选与商人敞口在 `epoch_begin/building_plan` 冻结；贷款提款、投入购买、
销售、基础工资、偿债和奖金在 `building_production` 完成；自产消费价值在 household clearing
归属来源建筑；恢复转态、10 日失败审查、清算和建设竣工在 `building_commit` 完成。所有阶段仍
使用现有滚动五相 continuation 和同日 barrier。

## 周期选择

`EconomyProfile` 提供：

- `market_cycle_days`：生产默认 0，按市场、cohort 与建筑工作量自动；其他正数强制 N。
- `market_min_cycle_days`：自动周期下限，默认 5。
- `market_max_cycle_days`：自动周期上限，默认 365。
- `market_target_cohorts_per_slice`：0 为规模自动；小/中/大世界分别使用
  4k/12k/30k cohort。

自动公式先计算 `raw = max(market ranges, cohort ranges) + 4 * building ranges + 4`，
再对超过五日基础周期的部分增加 50% 的确定性 scheduler availability slack，最后 clamp 到周期上限。
cell range 同时受计划 `markets_per_slice` 和实际 cohort 数约束，因此人口分布不均时不会
静默生成超长 slice；若周期上限导致工作未完成，截止日进入 same-day catchup。

生产默认使用确定性工作量自动周期。显式正数保留固定周期：200k cohort 的旧纯市场档得到 50 日，
10M cohort 得到 334 日。周期越长，平均与 p95 越低，但价格、财富和环境反馈延迟/误差
越大。固定 5 日在极端 10M 档无法于五个普通 slice 内完成，会在截止日进入有界
same-day catchup；若目标是极限规模流畅快进，应把 profile 改为 0 自动。

## 图阶段

1. `trade_planning`：上次发布后以确定工作单元扫描稀疏信号并有界寻路；路线 heap 与目标状态可跨
   native slice 续跑，每片全局最多推进 256 次有效 Dijkstra 扩展；是无屏障软任务。
   report/性能 CSV 将该调用细分为 scan body/finalize、route prepare/expand/finalize 和 other，
   但这些墙钟诊断不参与预算或确定性推进。
2. `epoch_begin`：校验 matrix/merchant 索引，捕获 sample day 环境并冻结输入。
3. `building_plan`：按 active-cell CSR 分片推进建筑严重亏损/恢复、利用率计划；第二遍按同一
   cursor 分片重建生产投入 reserve。两遍完成前不进入账本或生产阶段。
4. `trade_settle`：结算到期货物/卖方托管，货物可参与当期本地市场。
5. `ledger_apply`：只消费 `effective_day <= sample_day` 的命令；周期中提交的命令等下轮。
6. `building_employment`：按周期开始时仍存活人口分配 owner/employee 岗位并计算合同工资。
7. `building_production`：先算受就业/资金/资源约束的采购意图，再用本地输入库存得到实际产能；购买投入、生产并出售产出，分配基础工资/奖金，最后更新企业意图、实际出库、供给与成本信号。
8. `household_market`：每天最多一个 cohort-budgeted market range，先保护 ACTIVE owner 下一周期投入现金，使用本期收入和新库存计算 N 日总需求/交易；自产食物可补足总生存热量池，再计算食品与气候衣着生存满足，以 Q32 residual 结算死亡，并按人数、满足率和职业/民族率聚合预期出生。
9. `trade_dispatch`：在全部本地 household 清算完成后，ACTIVE 按本地需求/投入 reserve 稳定裁剪并
   托管发运；PROBE 只报告候选。
10. `structural_commit`：稳定提交本轮结构 ECB；先处理死亡清空与迁移，最后把每个
    `cell×ethnicity` 的出生人口合并到 `unemployed|eth`。受影响建筑岗位只做存活人口夹紧和指标
    对账，不在同周期招聘新生人口。
11. `wait_commit`：若提前算完，保持内部结果不可见，等待 `sample_day + N - 1`。
12. `building_commit`：按 review prepare、special reset、recovery review、construction commit、
    investment prepare、investment、finalize 七个确定子阶段推进。恢复复核使用按 `cell % investment_review_days`
    烘焙的 group CSR，每片最多 4096 group；review prepare 先生成升序的实际到期 cell 列表，
    investment prepare 在竣工提交后只为该列表聚合 merchant、pending construction、
    resource commitment 和 existing type；投资评估随后使用独立 96-cell batch。
    价格驱动的内生资本评估遍历全部已解锁 building type；
    collector/service 仍必须通过各自资源、可销售产出、材料、利润和 sponsor gate；
    随后重建稀疏岗位范围，并保留既有 employee fill。
    投资目录另以 market active-good bitset 和 output-good→building-type CSR 做保守候选闭包；
    既有/在建类型及其施工物资始终保留。默认 ACTIVE，周期完整复核发现任何遗漏时会自动退回
    全目录扫描；该缓存不改变固定五日滚动语义。
13. `aggregate_publish`：独占一个或多个 native slice，以确定工作量子阶段推进 summaries、精确
    守恒审计、水位线、贸易 EMA/响应诊断和下一轮贸易计划初始化。人口/市场/在途/国家审计及
    贸易响应诊断每片
    最多 131072 条，cell 水位线及贸易工作区每片最多 4096 条；最后校验成功后才交换 committed
    summaries、推进 generation、发布 trace 并解除 active boundary。

`EconomyDailySystem` 把自己的 `slice_budget_ms` 传给原生图。`building_commit` 与
`aggregate_publish` 可以在墙钟预算尚未耗尽时跨越相邻的廉价子阶段，但同一次原生调用绝不消费
同一子阶段的第二个数据块；因此 group/cell/audit/workspace 的确定性条目上限保持不变。达到预算、
子阶段游标未完成或发生错误时立即 yield。该融合仅减少 continuation barrier，不重排依赖边，
也不允许绕过 publish/save committed boundary。

周期内 save、gameplay 和其他经济写者只观察上一 committed state；Inspector 的有界选中
地块查询可观察最近完成 native slice 的完整状态，并明确标记为 `live_slice`。`epoch_income/expense` 在发布后
表示整个周期总额，不是单日值。

## 惰性会计清零与结构索引

禁止在周期起点扫描全部 cohort 清零收入/支出。每个 lane 使用 `flags` 的保留 parity bit，
在本周期第一次被 ledger 或 market 触及时 O(1) 清零。所有市场在 commit 前都被访问，
所以 committed snapshot 不会残留上周期会计值。

商人 CSR 在 bootstrap 建立；普通周期不重建。只有出生、迁移、换签名或人口归零真正触碰结构
时，`structural_commit` 才校验商人不变量并重建。`aggregate_publish` 复用该结果，只更新受影响
summary 并保留空人口单元库存校验，不再重复修复和全量 CSR 重建。该规则消除了 10M 档周期
起点约 90ms 和周期末约 30ms 的重复全量尖峰。

## WorldClock 契约

in-flight 本身不是错误，周期内世界日正常推进。report 提供
`cycle_deadline_day/days_until_commit/commit_due/commit_over_budget`。

- `commit_due=false`：不请求日屏障，下一个模拟日继续一个 slice。
- 截止日仍未完成：`EconomyDailySystem` 请求 `economy_day_barrier`。
- 屏障期间 WorldClock 不产生新日，但每个真实 frame 发
  `simulation_backpressure_pulse`，经 `DCSystemScheduler.continue_system` 在同一天 catchup。
- commit 或 reset 后解除屏障。

因此正常错峰不会把 334 日周期压缩成 334 个真实 frame，也不会让未完成周期跨过结算日。

## ACTIVE 与报告

本地市场与国内贸易均默认 ACTIVE。贸易使用独立 `trade_runtime_mode`，按
OFF → PROBE → ACTIVE 门禁上线；PROBE 不改变库存、资金、订单或 authoritative state hash。

除通用 stage/cursor/timing/audit 字段外，报告必须包含：`market_cycle_days`、
`market_target_cohorts_per_slice`、`approximation_version/model`、`period_transactions`、
`max_command_latency_days`、deadline 字段、merchant repairs、price cap hits 与
continuation slices。

`STRUCTURAL_COMMIT` 可能释放当期死亡的唯一 merchant cohort。所有受影响 cell 必须在
building employment reconcile 与 `BUILDING_COMMIT` 的内生施工交易之前修复 merchant
invariant 并重建 merchant CSR；`AGGREGATE_PUBLISH` 保留最终校验，但不能作为建筑交易前
的首次修复点。

worker stage ms 是 task CPU 累计；`elapsed_ms` 才是 slice 墙钟。

## 误差契约

固定测试场景相对逐日 reference：

| N | 总消费误差 | 总支出误差 |
| ---: | ---: | ---: |
| 10 | 4.12% | 1.78% |
| 20 | 7.56% | 4.39% |
| 50 | 17.21% | 12.25% |
| 100 | 31.28% | 26.10% |
| 334 | 57.82% | 96.33% |

误差不保证随 N 单调，因为资金/库存约束和价格边界会改变交易分支。表格只代表标准固定
场景，不是全局数学上界。需要更高精度的玩法可强制较短周期；性能不足时 report 会明确
显示 deadline catchup，而不是丢交易。
# BUILDING_GRAPH 阶段扩展

当前冻结周期的稳定阶段顺序为：

`epoch_begin(apply pending operating state/cooldown) → building_plan(plan → resource capacity → input_reserve) → trade_settle → ledger_apply → building_employment → building_production →
household_market → trade_dispatch → structural_commit → wait_commit → building_commit →
aggregate_publish`。

无已建建筑时 employment/production 两阶段直接跳过。建筑阶段和居民市场可以在截止日前错峰完成，
随后进入 `wait_commit`；未完成时沿用 `commit_due && !done` same-day barrier catch-up，不提前阻塞
日历。新产出在 production 后加入库存，居民清算因此可在同一周期购买。

`building_production` 对每个 active cell 内部执行 utility prepass：所有产出 `cycle_flow`
good 的建筑先购买普通库存燃料、生产并结算电力，随后其他建筑可以同周期购买该电力。最后仅遍历
catalog 预编译的 `cycle_flow_good_ids` 清零余量，不扫描全部 goods。该内部两相不新增 scheduler
stage，外部 cursor、deadline 和 committed visibility 保持不变。

企业投入需求、实际 offer 供给与成本锚只在两相生产都结束后更新稀疏 EMA。当前周期价格阶段
始终读取上一 committed 周期信号，避免 utility/普通生产顺序渗入价格结果，也维持冻结周期的
确定性边界。

PKEC v8 在 `building_employment` 的同一 active-cell slice 内先计算生活成本与合同工资，
不增加 epoch-boundary 全量扫描。`building_production` 内部固定为买入原料、生产、业主按消费计划
只按饥饿阈值和寒冷暴露留用最低生存产出、剩余产出出售、销售后基础工资、超额利润奖金与劳动
信号更新；留用品不产生现金流，最终欠薪仍通过原字段报告。利用率忽略不超过 1% 的舍入丢弃，
并在零库存高短缺时主动恢复。`epoch_begin` 按下一周期计划重建稀疏生产投入硬预留；
`household_market` 在预算和最终结算两处保护 owner 营运资金，并只向家庭开放扣除投入预留后的库存。
国内贸易规划/派单同样不能导出预留库存。预留缓存可由已持久化建筑状态确定性重建，因此
ECONOMY_GRAPH stage、截止日语义和 PKEC 权威布局均不变化。

### 建筑计划 continuation（2026-07-20）

`building_plan` 不再在 `start_epoch()` 内同步执行全图扫描。原生 runtime 在 sample-day 冻结后持有
`building_plan_phase` 与 active-cell cursor，分别完成经济计划和投入 reserve 两遍；每个 native call
使用独立 `building_plan_cells_per_slice`；0/auto 确定性采用普通 building cell/group range 的
两倍（当前普通 cell 上限为 256）。household post-building 使用同样的 stage-local auto grain。
该 cursor、业主生存利用率缓存和 reserve 构建临时量不保存、不哈希，也不向 committed
snapshot 暴露；周期中保存继续以 `save_requires_committed_boundary` 拒绝。

营运资金不足时的产能裁剪使用 8 次固定整数二分，始终返回已验证不超预算的下界；相对请求区间
最多低估 `1/256`（约 0.39%）。`working_capital_scale_error_bound_q16` 发布本周期实际未决上界，
用于在平台调优时区分可控数值误差与真实现金短缺。

v11 继续从统一 `survival_household` 目录建立无财富/价格弹性的冻结 `survival_required`；生存品订单、
生产者自留和死亡分母共享该基准。短缺恢复读取扣除生产投入预留后的家庭可用库存，并容忍 1 个
goods 子单位残量。生存食物组的利用率下限按同一业主人口跨过饥饿阈值所需的自留量动态计算。
投入预留按互补配方共同可执行容量缩放，非生存加工让家庭生存食物优先；生产者托底只填正常目标库存缺口，超目标余量丢弃。上述缓存均可重建，不新增 stage、DataCore 槽或 PKEC 字段。

v11 在 `building_production` 的正常商人现金结算后，仅把目标库存剩余缺口托底入库，并按冻结零售价
20% 增加 owner 资金与 `explicit_money_mint`；超过目标的余量进入 discard。该发行在同一 building slice 内完成，不新增 stage。事件现金流 schema v4 沿用
`producer_support_issuance`，CSV v16 summary 保留托底数量、发行额、金银货币流、贸易活性游标和拒绝诊断，building 行新增 owner 容量、
实际业主席位、利用率折算生产等效人数和真实空缺口径。
外部 stage ABI 和冻结/截止日屏障不变；生产默认 cadence 已由后述 workload-auto 规则取代固定五日。

v12 在 `building_commit` 增加原生内生投资。评估使用本周期已完成的企业计划和市场信号，
但只在跨过 30 日边界时允许新增建筑；普通周期不会重复扩建。已有业主空缺仍由
`building_employment` 优先处理。所有已解锁建筑类型进入同一经济评估；缺少可销售产出的 service
会自然失败于市场信号门槛，collector 仍须通过市场需求、资源、建材、营运资金、业主生活费、
盈利和回收期门槛，并复用 BUILD 的建材库存、
出资者资金、商人收入、事件和守恒账本。该节流由 committed day 推导，不新增 PKEC 字段。
## 2026-07-20 cadence changes

The production default is workload-auto cadence (`market_cycle_days=0`) with a
five-day floor. Explicit positive values remain forced for tests and manual
high-fidelity runs. Auto mode fixes market ranges at at most 128 markets and
building ranges at 256 active building cells, then estimates the deadline as:

`max(market cell ranges, cohort ranges) + 4 * building ranges + 4 fixed stages`,
plus 50 percent deterministic scheduler slack above the five-day floor.

The estimate is clamped by `market_max_cycle_days`. Reports expose configured
and effective cadence, market/building/total slice estimates,
`workload_deadline_feasible`, and `workload_cycle_clamped`. These values depend
only on authoritative workload, never frame rate or speed scale.

At a due boundary, one pending trade-planner slice is returned separately from
`epoch_begin`. `boundary_continuation_required` requests one same-day WorldClock
continuation so trade scanning no longer stacks with the first building-plan
range and does not shift the sample day. This is distinct from deadline
catch-up; normal auto workloads must report zero deadline barrier slices.

Investment review is an independent 10-day boundary checked in
`building_commit`; vacancy repair still runs whenever a committed cycle exposes
an owner opening. Each cell may start at most one building per review.

Trade signal collection is fused into existing building and market per-good
work. The sparse planner continues between settlement boundaries under its scan
and route budgets. At each settlement boundary, a completed candidate set or safe
completed prefix may dispatch after stock, cash, capacity, topology, and country
revalidation. No daily all-building-type scan was added: the full constructible
catalog is evaluated only on the 10-day investment review for populated cells.

`building_commit_phase` separates ready-construction commit, bounded investment
review-cell ranges, and final employment reconciliation. `review_prepare` builds
one ascending transient list for the current rolling/review phase and positive
committed population; non-review cells are not visited by investment. After
`construction_commit`, `investment_prepare` builds finance,
pending/existing/resource scratch in a separate cooperative phase. The following
`investment` phase evaluates and commits bounded review-cell ranges; both phases
have stable `building_commit.*` breakdown keys. Investment and finalize use
independent deterministic defaults of 96 and 128 cells instead of inheriting
the normal building range. Their profile overrides change only continuation
boundaries. Transient
pending/existing/resource indexes are built once per epoch commit for that list and released
after finalization. Candidate evaluation may later move to read-only worker
ranges, but sponsor funds, materials, population movement, and construction
creation must be revalidated and committed in stable cell order.

## Rolling five-phase graph (PKEC v20, current)

The former global epoch and workload-selected cadence are superseded. Every day
the native graph builds the sorted workset for `cell_id % 5 == day % 5` and
finishes that bucket through bounded same-day continuation. One native call may
consume up to eight deterministic ranges in stable graph order. The normal wall
budget is 0.8 ms; at `speed_scale>=20` native uses at least 1.8 ms to amortize
the GDScript/GDExtension/SUS bridge. Wall time only decides whether to yield
before the next range and never changes a decision or range boundary.
`done=false` raises the existing day barrier and real-frame pulse until the final publish. Each cell
uses a fixed five-day transaction, so adjacent committed dates differ by at most
four days and one cell's consecutive settlement dates differ by exactly five.

Daily order is country snapshot, resource update, trade arrival/refund, eligible
commands, due local transactions, sparse trade planning/dispatch, then stable
reduction and publish. Trade arrival never changes a cell's settlement date.
Normal operation has no `WAIT_COMMIT`, deadline catchup, or deferred cell. The
legacy stage enum value remains only for old trace decoding and immediately
falls through when encountered.

## Building production worker partition

`building_production` keeps the same rolling stage and due-cell cursor. Within
one bounded production range, native may dispatch disjoint cells to
`WorkerThreadPool`; no new economy graph stage, SUS job, dependency edge, or
publish boundary is introduced. This is currently legal only while each cell
owns the same-numbered market. Workers write only that cell's cohorts, building
groups, market, resource-delta column, and sparse signal rows. Per-cell
`ProductionResult` diagnostics and trace drafts are merged in cursor order before
the stage advances, preserving deterministic event order and global reductions.
The result lanes are runtime-owned scratch and retain nested vector capacity
between ranges; warmed `production_result_allocation_growth_count/bytes` should
therefore be zero.

The same body runs as one task below `worker_market_threshold`, when workers are
disabled or unavailable, when the range/group workload is too small, or when a
non-identity cell-to-market mapping is detected. These fallbacks are native and
do not change five-day cadence, the range boundary, or same-day continuation.
The frame timebox can schedule another continuation after this range completes;
it cannot preempt a production range already executing.
