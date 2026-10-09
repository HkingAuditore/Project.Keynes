# 50× 性能诊断（2026-10-08）

目标是每秒提交 50 个权威模拟日，即平均每个日边界不超过 20 ms。
当前记录证明后台执行预算本身已经超标；增大时钟倍率或 SUS 预算不能直接达到目标。

## 玩家录制证据

来源：`tmp/perf_record_20261008_181820.csv`，2,390 行，倍率均为 50。
使用相邻记录或首尾的累计差分，不把累计量当作单帧时间。

| 指标 | 结果 |
| --- | ---: |
| 权威提交日 | 22,081 → 26,601，共 4,520 天 |
| 录制区间墙钟 | 233.221 秒 |
| 端到端吞吐 | 19.38 天/秒 |
| worker execute 差分 | 164.050 秒 |
| execute / 提交天数 | 36.294 ms/天 |
| 仅执行时间推算的上限 | 27.55 天/秒 |
| input_wait 差分 | 5.673 秒，约 1.255 ms/天 |
| boundary_wait 差分 | 47 微秒 |
| 未记录的 worker phase 差分 | 63.300 秒 |
| 排除 >1 秒采样间隔的吞吐 | 26.79 天/秒 |

仅执行时间也需减少约 44.9% 才能满足 20 ms/天；这是平均预算计算，不能代替尾延迟验收。
execute 是 worker 执行区间墙钟，包含被 OS 抢占的时间，不等同于线程 CPU 时间。

13 个 >1 秒的采样间隔包括 12 个约 1.58–1.72 秒的间隔，以及一个 45.072 秒的间隔。
仅凭旧 CSV 无法将它们分别认定为自动存档或暂停。旧 CSV 没有 save_build、save_pause、paused
三列，但 total 包含它们，故差额有 63.3 秒。修复后新 CSV 能直接分辨。

主线程日输入捕获 avg/p95/max 为 3.658/3.928/4.422 ms；日回调整体为
4.603/5.004/5.780 ms。该边界也需要优化，但不能消除后台每日报表与提交成本。
不能将日回调和 worker execute 简单相加：它们可能并行。

首行 sched_proc 累计量包括开始录制前的历史，例如 snapshots=140,084.898 ms。
它不能被解释成录制期间单帧花了 140 秒。runtime_graph_event_dispatch_ms 及 largest_slice
整段不变，也不能作为逐日热点排名。

## 新开局热点探针

用现有 `PK_ECONOMY_COST_CSV` 探针，地图 100×64、seed=19991123、saved_setup=true、
正式开局、4 国、80 人；过滤首 5 天，按 phase 汇总同日多次调用。
原始证据：`tmp/perf_20261008_cost_baseline.csv`。

| phase | ms/采样日（均值） | 含义 |
| --- | ---: | --- |
| native_hash | 3.230 | NativeEconomyRuntime 完整状态哈希 |
| pod_hash | 4.032 | POD authority 的完整人口/市场哈希 |
| ledger_hash | 3.418 | 每日两次账本哈希，各约 1.71 ms |
| ledger_validate | 2.219 | 账本校验，包含其中一次 ledger_hash |
| epoch_vectors | 1.334 | epoch 初始化向量工作 |
| household | 0.417 | 消费阶段 |
| employment | 0.404 | 雇佣阶段 |
| production | 0.295 | 生产阶段 |

这些阶段有嵌套关系，不能全部相加。aggregate 包含 native_hash；ledger_validate 包含一次
ledger_hash。该新开局规模不同于玩家第两万多天，不能把表里的比例直接套到玩家世界。

探针确认市场数组有 857,600 个 lane（6,400 格 × 134 种物资）。
即使只有 4 格有聚落，完整哈希也扫描全表。运行成本因此有显著地图规模固定项。
当前生产权威仍在 C++；本轮没有改变公式、提交顺序、schema、bind table 或 hash/save ABI。

源码入口：

- `gdext/src/economy_runtime.cpp::NativeEconomyRuntime::state_hash`
- `gdext/src/runtime_economy_pod.cpp::RuntimeEconomyPodAuthority::state_hash`
- `gdext/src/runtime_economy_state.cpp::RuntimeEconomyLedgerState::computed_hash/valid`
- `gdext/src/native_simulation_host.cpp::execute_day_plan` 的经济提交/镜像边界
- `Project/project-keynes/scripts/game/world_runtime_host.gd` 日输入 capture

## 建议的优化顺序与验收条件

1. 优先减少完整哈希、账本验证与兼容镜像的重复遍历。先建立提交 generation 对应的
   原子发布与校验所有权，明确哪次校验验证外部输入、哪次重复验证同一个不可变对象。
   不能直接关掉守恒检查、最终哈希或降低验证频率来满足吞吐数字。
2. 针对初始化和输入 capture 检查全量重建/拷贝是否能复用静态拓扑与只更新真实变化。
   复用必须有明确 generation/dirty 契约，不能把不同日期的环境输入当作等价。
3. 用可恢复的后期存档重测实际公式成本，再选择雇佣、贸易、人物/家族等热点；
   目前证据不足以指定后期某个业务公式为第一瓶颈。
4. 在同一配置、同一初始状态重复 A/B；验证零守恒错误、state hash 对拍、存档回放，
   以及 warmup 后 ≥50 authoritative days/s。图形场景另验帧尾延迟与发布新鲜度。

## 已完成的改动与验证限制

已在 PerfRecorder 固定列和 runtime snapshot 映射中补齐
`runtime_graph_worker_time_save_build_us`、`runtime_graph_worker_time_save_pause_us`、
`runtime_graph_worker_time_paused_us`，同步性能诊断文档。
`perf_recorder_test.gd`：76 checks、0 failures；`git diff --check` 通过。
没有 C++ 改动，没有构建 GDExtension，没有性能达标结论。

两项已有验证阻断：

- 18:17 自动存档的临时副本通过正式加载路径回放，在进入模拟前被
  `ecp2_restore_failed / save_fiscal_peer_record_invalid:amounts` 拒绝。
  日志：`tmp/perf_20261008_baseline_replay.log`。原存档未被覆盖。
- 新开局 headless runner 完成且 fatal=false、ledger_failures=0、三项守恒误差均为 0，
  但 CSV 行数为 209、expected_rows=99，吞吐检查也失败；该 run 不属于验收通过。
  日志：`tmp/perf_20261008_headless_baseline.log`。

可重算的统计：`python tmp/analyze_perf_20261008.py`，生成
`tmp/perf_20261008_analysis.json`。
