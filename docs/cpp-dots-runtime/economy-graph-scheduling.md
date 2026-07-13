# Market V2 冻结周期、错峰与调度契约

## 为什么不再每日全量

10M cohort × 16 needs 等于每轮约 1.6 亿条需求。旧实现虽然是 C++/SoA/WTP，仍要求
每天在 20 个 slice 内完成整图，单 slice 约处理 50 万 cohort，因此 p95 约 89ms。
瓶颈是固定点除法、need/bundle 展开和内存带宽，不是跨语言 Dictionary。

Market V2 / Price V3 现采用 `frozen_sample_adaptive_price_v2`：周期起点冻结人口、资金、价格、库存和四类
环境输入；在 N 个模拟日内按地块连续 range 错峰计算，需求量一次性乘 N；所有地块与
结构命令完成后，最早在周期截止日统一发布 N 日交易总量。

## 周期选择

`EconomyProfile` 提供：

- `market_cycle_days`：生产默认 5；0 为按 cohort 预算自动，其他正数强制 N。
- `market_max_cycle_days`：自动周期上限，默认 365。
- `market_target_cohorts_per_slice`：0 为规模自动；小/中/大世界分别使用
  4k/12k/30k cohort。

自动公式为 `ceil(active_cohorts / target_cohorts_per_slice)`，再 clamp 到周期上限。
cell range 同时受计划 `markets_per_slice` 和实际 cohort 数约束，因此人口分布不均时不会
静默生成超长 slice；若周期上限导致工作未完成，截止日进入 same-day catchup。

生产默认固定 5 日周期。性能验收脚本显式设置自动模式：200k cohort 得到 50 日，
10M cohort 得到 334 日。周期越长，平均与 p95 越低，但价格、财富和环境反馈延迟/误差
越大。固定 5 日在极端 10M 档无法于五个普通 slice 内完成，会在截止日进入有界
same-day catchup；若目标是极限规模流畅快进，应把 profile 改为 0 自动。

## 图阶段

1. `trade_planning`：上次发布后以确定工作单元扫描稀疏信号并有界寻路；是无屏障软任务。
2. `epoch_begin`：校验 matrix/merchant 索引，捕获 sample day 环境，冻结输入，并生成建筑利润/利用率计划。
3. `trade_settle`：结算到期货物/卖方托管，货物可参与当期本地市场。
4. `ledger_apply`：只消费 `effective_day <= sample_day` 的命令；周期中提交的命令等下轮。
5. `trade_dispatch`：ACTIVE 稳定裁剪并托管发运；PROBE 只报告候选。
6. `household_market`：每天最多一个 cohort-budgeted market range，计算 N 日总需求/交易。
7. `structural_commit`：稳定提交本轮结构 ECB。
8. `wait_commit`：若提前算完，保持内部结果不可见，等待 `sample_day + N - 1`。
9. `aggregate_publish`：统一发布 summaries、价格、库存、收入/支出、贸易 EMA 和守恒审计。

周期内 save、gameplay 和其他经济写者只观察上一 committed state；Inspector 的有界选中
地块查询可观察最近完成 native slice 的完整状态，并明确标记为 `live_slice`。`epoch_income/expense` 在发布后
表示整个周期总额，不是单日值。

## 惰性会计清零与结构索引

禁止在周期起点扫描全部 cohort 清零收入/支出。每个 lane 使用 `flags` 的保留 parity bit，
在本周期第一次被 ledger 或 market 触及时 O(1) 清零。所有市场在 commit 前都被访问，
所以 committed snapshot 不会残留上周期会计值。

商人 CSR 在 bootstrap 建立；普通周期不重建。只有迁移、换签名或人口归零真正触碰结构
时，publish 才校验商人不变量并重建。该规则消除了 10M 档周期起点约 90ms 和周期末约
30ms 的全量尖峰。

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

本地市场默认 ACTIVE。贸易使用独立 `trade_runtime_mode`，默认 PROBE，按
OFF → PROBE → ACTIVE 门禁上线；PROBE 不改变库存、资金、订单或 authoritative state hash。

除通用 stage/cursor/timing/audit 字段外，报告必须包含：`market_cycle_days`、
`market_target_cohorts_per_slice`、`approximation_version/model`、`period_transactions`、
`max_command_latency_days`、deadline 字段、merchant repairs、price cap hits 与
continuation slices。

worker stage ms 是 task CPU 累计；`elapsed_ms` 才是 slice 墙钟。

## 误差契约

固定测试场景相对逐日 reference：

| N | 总消费误差 | 总支出误差 |
| ---: | ---: | ---: |
| 10 | 14.43% | 19.72% |
| 20 | 29.05% | 41.26% |
| 50 | 56.86% | 94.53% |
| 100 | 15.17% | 25.16% |
| 334 | 63.42% | 3.99% |

误差不保证随 N 单调，因为资金/库存约束和价格边界会改变交易分支。表格只代表标准固定
场景，不是全局数学上界。需要更高精度的玩法可强制较短周期；性能不足时 report 会明确
显示 deadline catchup，而不是丢交易。
# BUILDING_GRAPH 阶段扩展

当前冻结周期的稳定阶段顺序为：

`epoch_begin → trade_settle → ledger_apply → trade_dispatch → household_market → structural_commit →
building_employment → wait_commit → building_production → building_commit → aggregate_publish`。

无已建建筑时 employment/production 两阶段直接跳过。在截止日前完成的居民市场仍进入
`wait_commit`；截止日只处理有建筑地块的 CSR range。未完成时沿用
`commit_due && !done` same-day barrier catch-up，不提前阻塞日历。新产出在 production 后加入
库存，保证不会被同一周期居民市场消费。

`building_production` 对每个 active cell 内部执行 utility prepass：所有产出 `cycle_flow`
good 的建筑先购买普通库存燃料、生产并结算电力，随后其他建筑可以同周期购买该电力。最后仅遍历
catalog 预编译的 `cycle_flow_good_ids` 清零余量，不扫描全部 goods。该内部两相不新增 scheduler
stage，外部 cursor、deadline 和 committed visibility 保持不变。

企业投入需求、实际 offer 供给与成本锚只在两相生产都结束后更新稀疏 EMA。当前周期价格阶段
始终读取上一 committed 周期信号，避免 utility/普通生产顺序渗入价格结果，也维持冻结周期的
确定性边界。

PKEC v8 在 `building_employment` 的同一 active-cell slice 内先计算生活成本与合同工资，
不增加 epoch-boundary 全量扫描。`building_production` 内部固定为基础工资按 owner 比例
结算、欠薪停产、生产销售、超额利润奖金与劳动信号更新四相；外部 stage ABI 和默认五日
冻结/截止日屏障不变。
