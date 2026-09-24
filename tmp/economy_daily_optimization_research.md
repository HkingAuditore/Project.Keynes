# Economy 日事务优化研究（2026-09-20）

## 结论与证据口径
当前权威路径为 C++ NativeSimulationHost → StageOps → NativeEconomyRuntime，公式绑定 OwnedState；GDScript 负责输入、时钟、展示和文件 I/O。优先研究提交派生数据的全量遍历与 epoch 临时列初始化，暂不改变公式、结算频率、哈希协议或并行顺序。

之前的 16.9 ms Economy 平均值是重复计时，应撤回。formulas_ms 包含 stages_ms；AGGREGATE_PUBLISH 包含 publish 和 native hash；mirror 包含 ledger 导出、校验、hash 以及 POD state hash。不能把这些全部相加。
旧同配置 worker_timing60_final.log 的 31 个每百日样本：formulas 平均 7.895 ms，stages 5.840 ms，mirror 3.141 ms。仅 formulas + mirror = 11.036 ms；这还不是完整 Economy 分支，后续 snapshot/command 路径不在此计时内。每百日采样可能与结算周期重合，不能推断普通日均值或可靠 P95。
最新 session 的 13-stage ms 是起止快照而非逐日分布；work 全部 2400 来自 finish_ok 固定赋值，不是各阶段实际工作量。worker 97.9% EXECUTE 是墙钟状态（包含线程被抢占或内部等待），不是 CPU 利用率。record_start/end timing delta 为 60.894 s，而 recording_elapsed 为 60.001 s，窗口也尚未严格对齐。

## 源码定位与候选方案

### 1. 哈希和提交导出（优先级最高：先测量，再融合遍历）
- economy_graph_stage_dispatch.cpp: finish_ok 最终阶段调用 NativeEconomyRuntime::state_hash。
- runtime_economy_pod.cpp: export_committed_ledger 复制 population/market/domain，valid 后 recompute_hash。
- native_simulation_host.cpp: Economy 分支发布完成后另调用 RuntimeEconomyPodAuthority::state_hash。
- POD hash 遍历 stock/price/demand_ema/shortage 四列；2400 × 134 = 321600 个 market-good lane，不是 321600 个市场。
- Native、ledger、POD hash 的字段和顺序不同，不能直接相互替代；也不能把 FNV 分块 hash 直接拼接冒充原 hash。
方案：先记录三种 hash 的调用次数、遍历 lane 数和耗时；验证是否有同一未变状态的重复调用。有严格失效证明才缓存。随后评估将导出复制、值验证及对应 hash 融合，保持每种 hash 的输入顺序/字段完全一致。ledger.valid 当前在 ledger.clear 后看到 hash=0，不应误报成这里又验证一次完整 hash。
风险：命令可在同一 committed generation 内改变状态，单纯按 generation 缓存不安全。导出失败必须保留上一份 committed ledger；现有 scratch/swap 已做到，不重做这项优化。
观测包络：旧百日样本 native hash 1.405 ms、ledger hash 1.190 ms、copy 0.500 ms、validate 0.147 ms；这些是成本，不是承诺可消除的收益。POD hash 尚无独立计时。

### 2. Epoch 临时列按 touched lane 清理（第二优先级）
economy_runtime_epoch.cpp 的 vector_init 为 reserve、business demand、ceiling observation、producer supply 等数组逐日 assign/copy，并调用 refresh_derived_business_demand。
方案：统计 allocated lanes、due lanes、touched lanes 和实际写入字节。优先将纯临时且默认零的数组变为 touched-list 清理或 generation stamp；保持冻结 EMA/price 输入的快照语义。每个读取点都要证明未触达 lane 读到默认值，避免遗留上一日数据。
风险：市场 signal lane 可能在结构修改时重排；dirty/touched 信息必须跟随稳定身份或在重排时失效。assign 不必然分配，需用容量变化计数区分清零成本与分配成本。

### 3. 提交 mirror 的二次投影（第三优先级）
economy_runtime.cpp: flush_formula_owned_domain_mirrors 做 sync_owned_* → fill_ledger_*；随后 export_committed_ledger 再复制这些 domain block。
方案：先按 building/trade/family/resource/cursor 记录复制字节和耗时，区分 alias/no-op 与实际复制。评估从 live store 直接填充下一份 ledger，或按 domain revision 复用不可变块。
风险：现有 POD command/存档/兼容查询会读 mirror；不能只优化无命令日却使命令日读取过期投影。变更必须保持 live/committed 隔离与失败发布原子性。

### 4. Aggregate audit 复用现有增量路径（先检查是否生效）
economy_runtime_publish.cpp 已有 closing_audit_mode、full_required、periodic_full、mismatch fallback；epoch open 已能复用 closing totals。不要再另起增量审计实现。
方案：输出 full/fast/mismatch/force_full 的逐日计数和原因，调查是否每次都被强制 full。覆盖 expedition、treasury、trade/fiscal escrow、结构变更等写入后，再考虑修正不必要的失效。
风险：禁止关闭守恒校验来制造性能收益；population/money/goods error 必须为零，增量结果需与 full reference 对拍。

### 5. Household / person / family 随人口增长的成本
最新结束快照 HOUSEHOLD 1.203 ms、PERSON 0.505 ms、FAMILY 0.174 ms，只是单个样本。代码已存在分块 driver、并行市场计算和部分 dirty-gated CSR，不建议直接加线程。
方案：记录 prepare/worker/merge、实际 due markets/cohorts、person need edges、CSR rebuild 原因与 scan steps；以固定日龄和人口规模对比，确认瓶颈属于查找、结构维护还是计算后再选索引/增量/并行。

## 推荐落地顺序与验收
1. 先补齐互不重叠的 prelude / 13 stages / mirror-copy / validation / 各 hash / snapshot-command / final-publish 计时，并导出逐日计数。拆分日执行线程内部等待，统一 recording 时间窗口。
2. 一次固定 seed、固定日数的基线覆盖普通日、周期交界、有命令日、存档与恢复。既保留全样本分布，也按 day mod 周期分组，避免每百日采样偏差。
3. 根据第一步选哈希重复调用或临时列清零作为首个小补丁；不同时改 hash ABI 和状态布局。
4. 验证旧/新精确 hash、逐日状态/账本 parity、守恒、StageOps 顺序、命令及 save/load；再做相同配置 5×60 s 性能验收，记录 avg/P95/max、提交间隔、fallback/fault/skip。以调用次数、遍历 lane、复制字节和 scan delta 证明减少了工作，耗时作为补充。

本轮仅只读源码和已有录制分析，新增此研究文档；未改 C++/GDScript、schema 或 bind table，未新跑构建或 soak。
