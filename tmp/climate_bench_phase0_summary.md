# 气候 Stencil 加速 — Phase 0 基线（数据地基）

机器：32 逻辑核（MT 任务数 clamp 到 16）。AVX2 build。墙钟最优（warmup4 + meas16）。
方法：真实 MapGenerator 生成（native ACTIVE），推进 3 日稳态后直接计时 pass 变体。
关键事实：**native daily 图当前调用的是单线程标量 `run_climate_pass_a` / `run_climate_pass_b`**，
已实现并 A/B 验证过的 `_thread` 多核变体只是绑定了但**未接入图**。

| n_cells | pass | config | compute_ms | speedup | M_cell/s | ~GB/s |
|---|---|---|---|---|---|---|
| 6,912 | a | scalar-1T | 0.428 | 1.00x | 16.1 | 2.1 |
| 6,912 | a | scalar-MT | 0.159 | 2.69x | 43.5 | 5.6 |
| 6,912 | b | scalar-1T | 0.250 | 1.00x | 27.6 | 3.3 |
| 6,912 | b | autovec-1T | 0.256 | 0.98x | 27.0 | 3.2 |
| 6,912 | b | autovec-MT | 0.094 | 2.66x | 73.5 | 8.8 |
| 19,200 | a | scalar-1T | 1.189 | 1.00x | 16.1 | 2.1 |
| 19,200 | a | scalar-MT | 0.300 | 3.96x | 64.0 | 8.2 |
| 19,200 | b | scalar-1T | 0.672 | 1.00x | 28.6 | 3.4 |
| 19,200 | b | autovec-1T | 0.693 | 0.97x | 27.7 | 3.3 |
| 19,200 | b | autovec-MT | 0.181 | 3.71x | 106.1 | 12.7 |
| 49,152 | a | scalar-1T | 2.877 | 1.00x | 17.1 | 2.2 |
| 49,152 | a | scalar-MT | 0.612 | 4.70x | 80.3 | 10.3 |
| 49,152 | b | scalar-1T | 1.720 | 1.00x | 28.6 | 3.4 |
| 49,152 | b | autovec-1T | 1.762 | 0.98x | 27.9 | 3.3 |
| 49,152 | b | autovec-MT | 0.337 | 5.10x | 145.9 | 17.5 |
| 110,592 | a | scalar-1T | 6.618 | 1.00x | 16.7 | 2.1 |
| 110,592 | a | scalar-MT | 1.310 | 5.05x | 84.4 | 10.8 |
| 110,592 | b | scalar-1T | 3.862 | 1.00x | 28.6 | 3.4 |
| 110,592 | b | autovec-1T | 4.101 | 0.94x | 27.0 | 3.2 |
| 110,592 | b | autovec-MT | 0.693 | 5.57x | 159.6 | 19.2 |

## 结论（gate 后续阶段）

1. **两 pass 在 1T 都是 compute-bound**（~2–3.4 GB/s，远低于 DRAM 带宽）→ MT 近线性扩展
   （随 N 增大：pass_a 2.69→5.05x，pass_b 2.66→5.57x），到 110k 仍未触 memory-bound 拐点。
2. **最大且最低风险的杠杆 = 把 ACTIVE 图的 climate 节点接到 `_thread` 多核变体**
   （已 A/B 验证）→ 实测 ~4–5.5x（49k–110k 真实图尺寸）。这是当前完全未吃到的收益。
3. **autovec-1T ≈ scalar-1T（pass_b 0.94–0.98x）** → 编译器自动向量化对 pass_b 的
   gather 无效；手写 SIMD 对 pass_b 不值（与代码内 `<30%` 注释一致）。
4. **pass_a 手写 AVX2（Phase 1）**：compute-bound 本可受益，但 pass_a 计算被
   transcendental 主导（insolation sin/cos、day_length acos、pow）。手写 AVX2 要到
   ulp≤4 必须有 SVML 级矢量化超越函数，可向量化的纯算术子段占比小 → ROI 低、风险高。
   → Phase 1 决策：**不实现 pass_a 显式 SIMD**；in-core 轴用 MT 兜住。
5. **融合 pass_a+pass_b（Phase 2）→ no-go**：理论上省一整遍网格扫描 + 一次 flush，但既然两 pass
   都是 compute-bound（非 memory-bound，见 1.），省内存流量的收益≈微（~10% 量级）；而融合要重写
   pass_a 不写 `cell_temp`、pass_b snapshot 逐 cell 化、合并图节点 + 改 yield_bits 索引 + 重绑方法表，
   高风险低回报。**决策：不实现融合**，多核已吃到主要收益。
6. **SFC（Phase 3）→ no-go**：当前 ~2–3.4 GB/s 远未 memory/cache-bound（见 1.），重排提升 cache
   局部性的收益预期≈0；且迁移代价极高（破存档 + 重烘焙 atlas/CSR/neighbor_indices）。**决策：不迁移**，
   数据驱动停在此处。

## 最终落地（2026-07）

- 已接图：slice `exec_slice_node` + `system_schedule.cpp::SCHEDULE_GRAPH` + legacy if-chain 三路
  climate pass_a/pass_b → `_thread` 多核变体（`n_tasks=0` 自适应）。
- 门槛全绿：`sim_2ms_ulp_tolerant_test`（scalar↔thread/simd 逐 cell worst=0）、`native_daily_active_bootstrap_test`(20/0)、
  `native_daily_graph_order_test`(11)、`natural_resource_daily_schedule_test`(24 日端到端)。
- 顺带修复：`run_climate_pass_b_thread` 漏写海冰反照率水域尾循环的潜在 bug（接图前由 ulp 测试捕获）。
- no-go 记录：pass_a 手写 AVX2（4.）、融合（5.）、SFC（6.）——均因 compute-bound + 高风险低回报。
