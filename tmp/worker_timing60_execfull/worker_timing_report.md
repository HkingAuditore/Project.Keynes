# Worker timing soak（60×40）

配置：ACTIVE，seed=1735228708，foreign_count=5，speed=50，warmup=5s，record=60s，16 native workers。

## 结果

- 录制窗口：60000.8 ms；有效推进 2950 日；吞吐 **49.166 日/秒**（门槛 49，已通过）。
- worker fault：0；native executor fault：0；authority graph：complete。
- frame wall：avg 6.915 ms，p95 8.168 ms，max 92.956 ms。

## worker 墙钟时间（record_start → end）

| bucket | ms | worker 占比 | 录制窗口占比 |
|---|---:|---:|---:|
| execute | 59615.468 | 97.900% | 99.358% |
| input_wait | 1182.852 | 1.942% | 1.971% |
| clock_wait | 0.000 | 0.000% | 0.000% |
| save_build | 0.000 | 0.000% | 0.000% |
| save_pause | 0.000 | 0.000% | 0.000% |
| paused | 0.000 | 0.000% | 0.000% |
| overhead | 96.006 | 0.158% | 0.160% |
| boundary_wait | 0.001 | 0.000% | 0.000% |
| total | 60894.327 | 100.000% | 101.489% |

## 解释和卡点

`EXECUTE` 已覆盖 `build_day_plan → execute_day_plan → 命令收尾 → authority grant → climate writeback → publish_day` 的完整语义日事务；它占 worker 时间约 97.9%。 当前最大卡点因此在日事务执行本身，而不是 worker 等待。`INPUT_WAIT` 约 1.94%，`CLOCK_WAIT` 为 0；ACTIVE Climate 驱动模式会持续有日输入，因而没有常规时钟睡眠。`SAVE_BUILD`/`SAVE_PAUSE` 都为 0，说明本次 60 秒 runner 没触发存档窗口，存档路径仍需单独 save soak 才能量化。`OVERHEAD` 已降到约 0.16%，剩余主要是循环控制/状态切换。

从 perf 采样看，单 tick `largest_slice_ms` 固定约 1.219 ms；runtime graph 单次 `last_elapsed_us` avg/p95/max = 78.1/257.0/257.0 µs，说明 GDScript→native graph 调用不是主瓶颈。现阶段应优先继续拆分 `EXECUTE` 内的 economy boundary、ledger/hash、climate worker 和 publish/writeback；等待类优化收益很小。

## 潜在卡点排名

1. **Economy 日事务**：此前同配置日志中每 100 日采样的 boundary 平均约 16.88 ms，其中 formulas 7.90 ms、stage ops 5.84 ms、mirror 3.14 ms；ledger hash 平均约 1.19 ms，aggregate publish/native hash 合计约 3.12 ms。这里是最值得继续拆分和优化的 native 热点。
2. **Climate POD plan**：本次 perf 平均 2.212 ms，P95 3.231 ms，最大 6.584 ms；每次覆盖 2400 cells，属于稳定的第二级日事务成本。
3. **主线程渲染残差**：frame perf 平均 4.951 ms，P95 6.775 ms，最大 94.615 ms；与 frame wall 的相关系数约 0.58。最大尖峰时 native graph 仅 15 µs、主线程等待为 0，说明该尖峰不来自 worker 阻塞。
4. **clock catch-up**：clock loop 平均 1.755 ms，P95 4.464 ms，最大 14.106 ms；相关性较低但会在一帧追赶多个日时放大单帧耗时。

应优先 profiling economy formulas/stage ops/mirror 的内部循环和分配，再看 Climate plan 的输入构建；等待输入、边界锁、GDScript→native graph 调用目前都不是主卡点。

## 2026-09-20 研究更正
此前潜在卡点排名中的 16.88 ms 将嵌套阶段相加，作废。31 个百日样本中 formulas 7.895 ms 已包含 stages 5.840 ms；formulas + mirror 3.141 ms = 11.036 ms，且不代表普通日均值。render_residual 是未归因余量，不能仅凭该值判定渲染器耗时。详见 ../economy_daily_optimization_research.md。
