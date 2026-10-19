# 经济公式性能优化进展（2026-10-19）

对应已批准计划：Track A（bit-equal）Phase 0–3。固定参照世界：`tmp/perf_fixtures/late_manual1_18563.pksv`
（2400 格、载入 day=18563、sha256 `53800A8B…50F1AFC`），回放 10 天预热 + 40 天测量、speed=50。
测量口径：无 cost-probe 的回放 worker `execute`（`[save-replay/result].measurement_worker_time_us`），
辅以低频聚合 `PK_ECONOMY_COST_CSV` 与 `PK_RUNTIME_WATERFALL_CSV`。墙钟噪声 ±6–15%，判定以计数器为主。

## 工具（新增，可复用）

- `tools/perf/run_replay_probe.ps1`：冻结 fixture → `Invoke-SaveReplay` → 收集 waterfall / economy cost /
  forensics(state_hash) → 自动跑分析脚本。支持 `-NoProbes`、`-EnvOverride @{...}`、`-Days`、`-WarmupDays`、`-DayTrace`。
- `tools/perf/analyze_waterfall.py`：waterfall 每 attempt/committed 分段 ms/day、failed attempt、最慢日。
  （补齐了 `runtime-perf-findings-2026-10-09.md:11` 引用但已丢失的 `tmp/analyze_waterfall.py`。）
- `tools/perf/analyze_economy_cost.py`：economy cost CSV 的 phase 聚合、work/次、memo 命中率、单日尖峰。

## Phase 0：观测修正（已完成）

### 探针降噪（`gdext/src/economy_cost_probe.h`）

原实现对每次 probe 构造/析构都 `fprintf`（高频阶段每天数千行），probe 自身开销被算进父阶段。
现在默认按 `(day, phase)` 聚合：`work` 为累计 units、`ms` 为累计耗时，跨日或进程退出时落一行；
`PK_ECONOMY_COST_CSV_FULL=1` 恢复逐调用行（仅调查用，禁止用于吞吐结论）。

修正后的归因（同一 fixture，probe 运行 87.98 ms/天）：

| phase | 之前（逐调用探针） | 现在（聚合） |
|---|---:|---:|
| `startup_producer_select` | 28.7 ms/天（8331 次） | **15.9 ms/天**（1.9 µs/次） |
| `owner_opportunity_quote` | 21.9 ms/天 | 32.0 ms/天（CPU 合计；16 µs/次） |
| `cohort_demand_preview` | 37.3 ms/天（CPU） | 32.0 ms/天（CPU）/ 4.7 ms/天墙钟（并行） |
| 探针总税 | ~20–30 ms/天 | ~4.4 ms/天（87.98 vs 83.60 无探针） |

新增：`derived.pass` / `derived.replay` / `derived.parallel` / `derived.merge` /
`derived.seed_cells|enqueued_goods|startup_calls` 计数器；`owner_quote.double_eval`；
`_derived_snapshot_hash` 暴露到 economy report（A/B 逐日确定性证据）。

### 基线（当前 DLL、无探针、3 次中位）

- worker `execute` **88.62 ms/天**（88.21 / 89.94 / 88.62），days/s 11.01–11.23。
- 3 次回放 state_hash 全部 = `7916088685429272618`（day 18614，确定性基线）。
- 对照：换 DLL 前同 fixture 单次 83.60 ms/天；同批次运行间噪声 ±6–15%，不做单次对比结论。

### 关键修正（相对上一轮诊断报告）

1. `epoch.finish` ⊃ `epoch_vectors`（嵌套），每日 epoch 尾部 ≈17.5 ms，不是 35 ms；其主体是
   `refresh_derived_business_demand`（`economy_runtime_epoch.cpp:1102`，全量 live-cell 扫描，不按 N/P/I 分片）。
2. 同日重试是幂等的：economy 每天只开一次 epoch（`epoch.finish` 0.96 行/天），失败 attempt 上的
   `econ.formulas` 是当天唯一一次经济脉冲；「先 park economy」只会挪成本、不省成本。真正浪费的是失败 attempt
   仍继续执行的 COUNTRY 之后域（示例 ~12 ms/次，待计数器确认）。
3. `startup_producer.memo_*` 命中率 0%（4473 miss/天）：`entries` 死代码已删除；memo 仍单 cell 作用域。
4. `owner_quote` 命中率 3.2%（1158 miss/天），其中 **1154/天 会执行第二次 `finalize_at_scale`**
   （`owner_quote.double_eval`）——下一轮首要目标。

## Phase 3 已落地（bit-equal，已验证）

- `owner_opportunity_quote` memo：`std::map` → `std::unordered_map`（FNV-1a over key words，
  `LivingCostVectorKeyHash`），key 改用 thread_local 复用 vector（去掉每调用一次堆分配）。
- `StartupProducerMemoState::entries` 死 map 删除（含 `invalidate()` 引用）。
- `economy_runtime_epoch.cpp`：每个 epoch 结束把既有阶段计时器以 `epoch_perf.*` 记录进 cost CSV（纯诊断）。

验证：40 天回放 3 次，最终 state_hash 与改造前完全一致（`7916088685429272618`），
`PK_ECONOMY_MEMO_VERIFY` 路径保留。性能：88.62 vs 83.60 在测量噪声内，不能证明收益也不能证明回退；
下一轮以 `owner_quote.double_eval` 与 per-caller 计数决定是否保留 flat map。

## 新的阶段归因（`epoch_perf.*`，单次运行，注意该次机器噪声偏大，比例有效）

| 阶段 | ms/天 | 备注 |
|---|---:|---|
| `epoch_begin_vector_init`（= derived pass） | 22.7（该次偏高） | 其中 replay 14.6 / 并行 preview 8.1 |
| `building_employment` | 13.5 | 串行，19 个建筑格约 700 µs/格 |
| `building_production` | 13.0 | 其中 `market_signal` 10.5（并行任务内串行段） |
| `building_plan` | 7.3 | evaluate 7.2；worker CPU 合计 48.9（9 任务） |
| `investment`（含 evaluate/allocate/prepare） | 7.7 | cold-day 尖峰明显 |
| `startup_demand_prepare` | 4.9 | |
| `finalize_construction` / `finalize_reconcile` | 2.0 / 2.0 | |
| `family_commit_normalize` | 2.7 | |
| `building_factor_cache` | hits 5490 / misses 171 每天 | 命中率 97% |
| `owner_opportunity_quote` | 34.3（CPU 合计） | 1158 miss/天，double_eval 1154/天 |

## Phase 2（派生需求并行化）暂缓：崩溃已定位到高概率原因

尝试：把 `refresh_derived_business_demand` 的串行 replay 改为“每 cell 纯读计算 + 按 cell 顺序归并”，
用 `parallel_for_range` 并行。串行新路径已验证 bit-equal；**并行路径在首日触发 access violation
（0xC0000005）**，`PK_ECONOMY_MEMO_DISABLE` / `PK_ECONOMY_PREVIEW_BASIS_DISABLE` 均不能规避。

高概率根因：实现中把任务结果容器声明为
`thread_local std::vector<DerivedCellWork> cell_work;` 并以 `[&]` 捕获进并行任务——执行线程对
thread_local 变量的访问可能解析到**执行线程自己的实例**（而非调用线程的引用），导致 worker 线程访问
未 resize 的向量而越界。修复方案：改为普通局部变量（`std::vector<DerivedCellWork> cell_work;`），
调用期间地址稳定、任务只写不相交元素，随后按 cell 顺序串行归并即可。改动已存档在
`tmp/derived_parallel_block.cpp` + `tmp/patch_derived_parallel.py`，下一轮重放并验证。

## 下一轮工作（按优先级）

1. **re-attempt Phase 2**：应用存档 block，修复 thread_local 捕获 → 期望 `derived.replay`
   14.6→~2 ms/天（并行 12 任务，24 核机器）；串行 `PK_ECONOMY_DERIVED_PARALLEL=0` 作 reference；
   验证 state_hash 与 `_derived_snapshot_hash` 逐日一致。
2. **owner quote double_eval**：先加 predicate 计数（`has_soft_partial_input` / bare<1 / tooled<1 各占比），
   再决定合并两次 `finalize_at_scale` 或跳过证明等价的分支；目标 CPU 34→~20 ms/天。
3. **building_employment（13.5 ms/天串行）**：加格内子探针（labor signal、owner quote、slot 分配），
   按结果做 plan-then-replay 并行或减少每格重复报价。
4. **production.market_signal（10.5 ms/天）**：评估按市场 N 周期滞后计算是否可 bit-equal 降频。
5. 清掉 `_derived_household_preview_scratch` 等被新路径取代的遗留 scratch（配合 Phase 2 落地）。
6. 文档：`performance-diagnostics-playbook.md` 增加“聚合探针模式/两种吞吐口径”；
   `native-economy-runtime.md`、`economy-graph-scheduling.md` 记录 derived pass 并行归并契约。

## 复现命令

```powershell
# 无探针吞吐（主指标）
.\tools\perf\run_replay_probe.ps1 -OutDir tmp\perf_runs\noprobe -NoProbes
# 低频归因
.\tools\perf\run_replay_probe.ps1 -OutDir tmp\perf_runs\probe
# 指定 reference 环境（例如串行对照）
.\tools\perf\run_replay_probe.ps1 -OutDir tmp\perf_runs\serial -EnvOverride @{ PK_ECONOMY_DERIVED_PARALLEL = '0' }
```
