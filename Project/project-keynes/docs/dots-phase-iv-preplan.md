# DOTS Phase IV 预案 — SIMD / chunk_remap / D-async（不主动启动）

> Master 手册 §8（Phase IV preplan）。
> **Status**：preplan only；charter §3.1 / §3.2 触发条件未达成，**严禁动代码**。
> 2026-05-14 — 初版。

---

## 0. 严格触发条件（Performance Charter §0 第 2 条铁律）

> "SIMD / 多线程是带触发条件的优化，不是默认手段（charter §3.1 / §3.2）"

Phase IV 三大优化（SIMD / chunk_remap / D-async）**必须满足以下全部前置条件**才允许启动：

### 0.1 通用前置（charter §3.1）

1. **Phase 2/3/4 全部完成**：
   - Phase 2：所有写路径下移到 world.write_*_indexed（master 手册 §3.10）
   - Phase 3：4 巨石全部 ≤ 目标行数（map_baker ≤ 150 / weather_system ≤ 200 / map_generator ≤ 800 / main ≤ 400）
   - Phase 4：serialize / migration / soak fixture / hot-reload 全部就位

2. **SUS 调度稳定**：
   - 1000 tick 滚动窗口下，所有 system tick 时间 ±5% 抖动以内
   - 无 fast tick WARN 集中爆发（10 连续 tick 内 ≤ 1 个 sus > 8ms）

3. **SAME_SOURCE 验收持续通过**：
   - 1 周连续运行 F3 SAME_SOURCE A/B 不出现意外漂移
   - 所有 stochastic 字段稳定在 whitelist 阈值内

4. **micro-bench 量化**：
   - 必须有 charter §12.5 模板 bench，对应 hot pass 输出 stable kernel μs
   - 没有 bench 数据的优化不准做（pre-optimization is forbidden）

### 0.2 SIMD 触发条件（charter §3.1）

满足以下**任一**条件才考虑：

- A) hot pass kernel mean ≥ 5ms 持续 3 周以上无法通过 algorithm 优化降下
- B) gdext layer 实测 cross-language 调用占比 ≥ 30% 总开销
- C) 用户硬件 telemetry 显示 P50 平台 < 当前算法预算的 80%

### 0.3 chunk_remap 触发条件

- D) 当前 cell-major SoA 因 cache miss 占主导（perf record / VTune 实测 cache_miss_rate ≥ 15%）
- E) cell 数量从 2400 涨到 ≥ 100k 且 hot pass scaling 非线性

### 0.4 D-async（多线程）触发条件（charter §3.2）

满足以下**全部**条件：

- F) hot pass 占总 frame budget ≥ 30%
- G) 算法已通过 SIMD 但仍超 budget 50% 以上
- H) data race 边界清晰（无 cell × cell 写共享状态）
- I) 单元测试覆盖 multi-thread safety（每个并行 system 都有 race condition test）

---

## 1. 三类优化的 deferred roadmap

### 1.1 SIMD 化（charter §12.7）

**候选 pass**：

| pass | 当前 kernel | SIMD 潜在 speedup | 触发优先级 |
|------|-------------|-------------------|------------|
| weather_field solve | 0.20ms | ~2x（已超 charter target） | 低（已达标）|
| climate Pass-A | 0.07ms | ~3x | 极低（远超 target） |
| climate Pass-B | 0.07ms | ~3x | 极低 |
| ocean water/land | 0.09/0.02ms | ~2x | 极低 |
| sea_ice daily | 0.04ms | ~3x | 极低 |
| transpiration | 0.02ms | ~3x | 极低 |
| **wind_field solver** | **(待 Block B)** | **预估 5-10x** | **优先（实测 35.55ms p95）** |

**实施技术栈**：
- C++ side：`<immintrin.h>` AVX2 intrinsics
- 多平台：`#ifdef __AVX2__` / `#ifdef __ARM_NEON__` 分支
- fallback：scalar loop（GDExtension 必须移动平台兼容）
- 实验代码模板：见 `gdext/experiments/simd_climate_pass_a.cpp`（待加）

**SIMD 不做的场景**（即使 perf 触发）：

- 算法本身分支多（>20% mispredict rate）
- 内层循环含跨 cell 邻居访问（需 gather load，移动平台代价高）
- 输入输出 stride > 1（拆轴后变 stride=1 才考虑）

### 1.2 chunk_remap

**目标**：把 cell SoA 从 cell-major 重排为 chunk-major（如每 64 cells 一组），让 hot pass 内层循环顺序访问邻居索引时 cache 友好。

**实施步骤**（仅 trigger 后启动）：

1. 实测 perf record cache_miss_rate ≥ 15% 后立项
2. world.gd 加 `chunk_size: int` 参数（default 1 = legacy cell-major）
3. _build_indices() 重排 cell.index 为 chunk-id × chunk_size + slot_id
4. 邻居索引 LUT 也跟着重建（每个 chunk 内邻居 LUT 局部化）
5. SAME_SOURCE A/B 验收（chunk_size=1 与 chunk_size=64 行为应 bit-equal）
6. micro-bench 对比，speedup ≥ 1.5x 才合入

**风险**：

- 邻居跨 chunk 仍是 random access（chunk_remap 仅减弱不消除 cache miss）
- 改 cell.index 语义会影响所有 view_f32 调用方（需 facade 透明）

### 1.3 D-async（多线程）

**强烈警告**（charter §3.2）：

> "GDScript 不支持真线程；GDExtension 内可用 std::thread / std::async / WorkerThreadPool。
> 但 cross-language Variant 调用必须串行。所以多线程**只能在 C++ 内做**，
> 不能让 GDScript 端持有多线程结果（无法竞争安全转换为 Variant）。"

**唯一合理场景**：单个 hot pass 内部按 cell range 分片，C++ 内 OpenMP / std::thread 并行，
最后单线程聚合写回 SoA。

**实施步骤**（仅 trigger 后启动）：

1. 实测 hot pass kernel ≥ frame_budget × 30%（如 weather_field 13ms / 16ms = 81% 算触发）
2. 用 profiler 定位 inner loop 是否 embarrassingly parallel（无 cell-cross dependency）
3. C++ 加 `#pragma omp parallel for` 包内层 cell 循环
4. SAME_SOURCE A/B 验收（fp64 严格 bit-equal；fp32 接受 mean_diff ≤ 0.0001）
5. 跨平台测试（Windows MSVC OpenMP / Linux GCC / macOS clang / Android NDK）
6. 移动平台 fallback：单线程（OpenMP 在 NDK 21+ 才稳）

**绝不做**的事：

- 让 SusJob 在多 thread 跑（GDScript 不安全）
- 让 weather front collection 跨线程修改（front 是 RefCounted）
- 把 SoA write 拆到多线程（数据竞争 + cache line ping-pong）

---

## 2. 实验报告引用

完成 trigger 评估后，必须有正式实验报告：

```
docs/dots-experiment-report-phase-iv-XXX.md  # 每个优化独立报告
```

报告必须含：

- 触发条件实证数据（perf record / SUS log）
- micro-bench 前后对比
- 跨平台兼容性测试结果
- SAME_SOURCE A/B 验收记录
- 失败/回滚 case（哪些方向尝试了但没用）

参考已有报告：

- `docs/dots-experiment-report.md`（GDExtension F.1-F.5 实测）
- charter §12.5（template_bench.gd 模板）

---

## 3. 当前回答："为什么不做 Phase IV"

| 问 | 答 |
|----|----|
| 现在 weather_field 7.79ms / 16ms budget 不就 49%？要 SIMD 吗？ | **不**。已超 charter target（< 2ms）的 35×；不在 trigger 列表 |
| ocean_currents p95=35ms 痛得要死，要并行吗？ | **不**。先做 Block B C++ 化（GDScript → C++ ~10x），再看是否还需 SIMD |
| 玩家说 lag 啊？ | 先抓现场 perf record + SUS log，**通过 charter §3 trigger 评估**才动手 |
| 别的 ECS 引擎都默认多线程啊？ | **Project.Keynes 不是引擎**。我们是单进程 GDExtension hot loop；多线程只在 C++ 内的算法分片有意义 |

---

## 4. 引用

- `docs/performance-charter.md` §3.1 / §3.2（Phase IV trigger 权威定义）
- `docs/dots-master-execution-handbook.md` §8（28 周方案 Phase IV preplan）
- `docs/dots-experiment-report.md`（GDExtension 实测先例）
- `docs/dots-block-e-acceptance.md`（Definition of Done）
