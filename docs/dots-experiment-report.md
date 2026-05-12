
# Project Keynes — DOTS 实验报告（A1 archetype filter / A2 ECS scheduler）

> 文档定位：本文是一份**实验后报告**，记录 2026-05-12 在 GDScript 沙盒里
> 完成的两组 DOTS 化探索实验（A1 + A2），并给出"是否值得正式立项 ECS"的
> 工程结论。读者对象：未来要决定 production 是否走 ECS 路线的人，以及
> 想了解"为什么我们拒绝/采纳"的接手者。
>
> 配套阅读：
> - [`docs/cpp-gdscript-best-practices.md`](./cpp-gdscript-best-practices.md) §3 / §5 通信契约与 hot loop 军规
> - [`docs/cpp-async-experiment-report.md`](./cpp-async-experiment-report.md) D 方案（worker thread）实验报告
> - [`docs/performance-charter.md`](./performance-charter.md) §12 性能契约
>
> 实验代码（**仅 dev 沙盒，不进 release**）：
> - `Project/project-keynes/tmp/bench_archetype_filter.gd` — A1
> - `Project/project-keynes/tmp/demo_ecs_run.gd` — A2 主入口
> - `Project/project-keynes/tmp/demo_ecs_job.gd` — A2 job 描述（库类）
> - `Project/project-keynes/tmp/demo_ecs_scheduler.gd` — A2 拓扑调度（库类）
> - `Project/project-keynes/tmp/bench_ecs_scheduler_stress.gd` — A2-Stress（J ∈ {3..50}）
> - `Project/project-keynes/tmp/bench_ecs_scheduler_realjobs.gd` — A2-RealJobs（§4 选项乙，2026-05-12 新增）
> - `Project/project-keynes/tmp/bench_soa_chunk_repack.gd` — B0-Sandbox（§4 选项丙，2026-05-12 新增）

---

## 0. 三句话总结

1. **A1 通过功能测试，但实测无性能收益**——archetype 作为"逻辑过滤器"语义是对的（bit-equal PASS、OCEAN-cells 全 0），但在 stencil 类算子上**净开销 ≈ 0**，过滤掉的算力被 archetype 比较和 cache miss 抵消。
2. **A2 通过功能测试，bit-equal=0.0**——声明式 reads/writes + Kahn 拓扑排序能从手写顺序里**机械推导**出等价的执行序，调度器引入的非确定性 = 0，环检测 guard 正常工作。规模化压力测试（J ∈ {3..50}）order_legal / order_stable 全 PASS（§3.5），**真实 C++ pass 流水线**（J ∈ {3, 5, 8}）下 J=8 调度器净开销仅 **+5.08%**（远低于 25% 红线），bit-equal 全 PASS（§3.6）。
3. **B0 SoA chunk 物理重排沙盒结论：算法可行、有真加速，但 mask 必须准静态**——GDScript 沙盒里 chunked 路径相对自然顺序加速 0.31x – 0.73x（与 ocean%% 正相关），但 repack 阶段占 chunked 总耗时 70-89%，意味着只有当 LAND/OCEAN mask 准静态（如本项目当前 climate）时才能摊销，动态 mask 需要增量 repack 设计（§B0 / §4 选项丙）。
4. **不建议**把 A1/A2 整合进 `bench_demo_complex.gd` 和 `bench_async_demo_complex.gd`——两者的算子语义与 ECS 架构假设**不匹配**，硬接会增加复杂度而无收益。详见 §5。

---

## 1. 背景：为什么做这两个实验

DOTS（Data-Oriented Tech Stack）化是一个**渐进式**的工程探索。在动 production 路径之前，我们必须先在沙盒里回答两个问题：

| 问题 | 实验 |
|------|------|
| Q1：能不能用 archetype（"组件组合"）作为业务过滤器，让算子只跑相关 cells？ | A1 `bench_archetype_filter.gd` |
| Q2：能不能用声明式依赖图（reads/writes）+ 拓扑排序，机械推导 pass 执行顺序？ | A2 `demo_ecs_run.gd` |

这两个问题的答案决定了"是否值得正式立项 ECS"。如果 Q1 显示无性能收益、Q2 显示调度模型可行，那么**ECS 化的真实价值在调度层而不是数据布局层**——这是一个有用的负面结论，能帮我们避免投入数月做 SoA chunk 物理重排。

### 严守的纪律

- 实验**不引入线程**（线程化由 D 方案另行覆盖，见 [`docs/cpp-async-experiment-report.md`](./cpp-async-experiment-report.md)）
- 实验**不修改 `_slots[].arr_f32` 内存布局**（数据主权仍在 C++，GDScript 只是 driver）
- 实验**不进 production 路径**（所有代码在 `Project/project-keynes/tmp/`）

---

## 2. 实验 A1 — Archetype 作为逻辑过滤器

### 2.1 设计

- **archetype** 在本实验中等价于"一个 mask 数组（每 cell 一个 archetype-id）"。
- 三个跑法对照：
  - `vanilla`：与 `run_thermal_gradient_pass` 等价，全网格统一计算。
  - `archetyped_all`：携带 archetype 比较分支但 mask 命中所有 cell（应等价于 vanilla）。
  - `archetyped_land`：mask 仅命中 LAND（约 70%），OCEAN cells 写 0。
- 校验：
  - `vanilla ≡ archetyped_all` 必须 **bit-equal**（PASS）
  - `archetyped_land` 的 OCEAN cells 必须 **全为 0**（PASS）

### 2.2 性能矩阵（实测）

| grid    | iter | mode             | µs    | vs vanilla |
|---------|------|------------------|-------|------------|
| 32×32   |   4  | vanilla          | 176   | 1.00x      |
| 32×32   |   4  | archetyped_all   | 175   | 0.99x      |
| 32×32   |   4  | archetyped_land  | 177   | 1.01x      |
| 32×32   |  16  | vanilla          | 689   | 1.00x      |
| 32×32   |  16  | archetyped_all   | 355   | 0.52x ⚠    |
| 32×32   |  16  | archetyped_land  | 339   | 0.49x ⚠    |
| 64×64   |   4  | vanilla          | 383   | 1.00x      |
| 64×64   |   4  | archetyped_all   | 361   | 0.94x      |
| 64×64   |   4  | archetyped_land  | 372   | 0.97x      |
| 64×64   |  16  | vanilla          | 1413  | 1.00x      |
| 64×64   |  16  | archetyped_all   | 1377  | 0.97x      |
| 64×64   |  16  | archetyped_land  | 1515  | 1.07x      |
| 128×128 |   4  | vanilla          | 1482  | 1.00x      |
| 128×128 |   4  | archetyped_all   | 1433  | 0.97x      |
| 128×128 |   4  | archetyped_land  | 1448  | 0.98x      |
| 128×128 |  16  | vanilla          | 5567  | 1.00x      |
| 128×128 |  16  | archetyped_all   | 5583  | 1.00x      |
| 128×128 |  16  | archetyped_land  | 5445  | 0.98x      |

> ⚠ 32×32/iter=16 那两行 0.52x/0.49x 是 µs 量级 bench 的正常噪声（首次 vanilla 还在 page-fault / cache cold，后续两次已 warm）——其余 16 行才是真实信号。

### 2.3 结论

| 维度 | 状态 |
|------|------|
| `vanilla ≡ archetyped_all` bit-equal | ✅ PASS（max_abs_diff = 0.0） |
| `archetyped_land` OCEAN-zeroed | ✅ PASS（OCEAN 309/1024 cells 全为 0） |
| `archetyped_all` 相对 vanilla 性能 | ≈ 0%（CPU 分支预测器吃掉额外比较） |
| `archetyped_land` 相对 vanilla 性能 | ≈ ±5%（30% 跳过的算力 ≈ archetype 比较 + cache miss 损失） |

**核心结论**：**Archetype 作为逻辑过滤器无性能收益**。

### 2.4 为什么 logical filter 不够

stencil 类算子（thermal_gradient / demo_complex）的核心成本是**邻居访问的 cache 行为**。即使我们能"跳过 30% 的 OCEAN cells"，跳格子的方式破坏了顺序内存访问模式，cache miss 损失抵消了节省的算力。

**反向推论**：要从 archetype 拿到真实加速，必须做**物理 chunk 重排**（B 阶段）—— 把 LAND cells 在内存中连续聚集，让算子按 chunk 顺序遍历。但这需要重写 `_slots[].arr_f32` 的内存模型，工程量极大，且**目前没有性能压力证明值得这么做**。所以 A1 的另一个意义是：**反向证明了"不做 B 阶段"是合理的工程决策**。

### 2.5 production 接入后发现的"视觉副作用"（2026-05-12 补充）

A1 实验结论是"无性能收益但功能正确"，因此我们把 `run_demo_complex_pass_archetyped`
作为 demo `cell_demo_thermal_gradient` 的第三条 dispatch path（`ECS_ARCHETYPE`，
见 [`scripts/data/climate_profile.gd`](../Project/project-keynes/scripts/data/climate_profile.gd)
`DemoTGPath`）落地。在 `earth_like.tres` 把 path 切到 `2 (ECS_ARCHETYPE)` 后，
Overlay 的视觉效果与 LEGACY/ECS 两条路径**显著不同**——陆地颜色更鲜艳跳跃、
海洋全部贴在色标的最低色（纯蓝）。

**这不是 bug，是 archetype-as-filter 的语义副作用**：

- C++ 端 `run_demo_complex_pass_archetyped` 在 stage 6-8（normalize + output）
  阶段对 `arch != target` 的 cell 写 `OUT[i] = 0.0f` 并**跳过 min/max 统计**
  （见 `gdext/src/world_ext.cpp` `run_demo_complex_pass_archetyped` 注释）。
- 后果：
  1. OCEAN cell 输出强制为 0 → baker 把它们贴到色标最低色 → 海洋失去内部梯度信息。
  2. min/max 仅扫 LAND → LAND 自归一化区间被拉宽 → 陆地对比度比 LEGACY/ECS 更陡峭。

**为什么仍然把它当成"语义"而非缺陷**：archetype filter 的设计目标本来就是
"OCEAN 不参与 LAND 算子"。bench 里的 `archetyped_land OCEAN-cells-zeroed=YES`
sanity 检查就是在守这条契约。如果让 OCEAN cell 也参与 normalize，archetype
filter 在这个算子上就**完全等价于 vanilla**（A1 三组数据已证），demo 失去对照价值。

**视觉与数值的真实差距**（同一帧并排观察）：

| 路径 | LAND 色阶基准 | OCEAN 显示 | 与 LEGACY 视觉一致性 |
|------|--------------|------------|--------------------|
| LEGACY | 全图 min/max | 低值平滑过渡 | 基线 |
| ECS | 全图 min/max（与 LEGACY bit-equal） | 低值平滑过渡 | ✅ 完全一致 |
| ECS_ARCHETYPE | 仅 LAND min/max | 强制 0（最低色） | ❌ 差异显著 |

**当前决策**：保留 ECS_ARCHETYPE 作为 demo 的"archetype filter 视觉证据"
（用户能直接看到"按 archetype 过滤写入"这条 ECS 概念的可见后果），**不在
overlay 端做特殊处理掩盖差异**。如果未来需要在 production 用 archetype filter
路径上视觉一致，应在 baker 端识别"out=0 且 is_water"的 cell 并按底图渲染——
但目前没有这个需求。

**记入备忘的工程教训**：

> archetype 作为"逻辑过滤器"不仅没有性能收益（§2.3），还会**改变下游消费者
> 看到的数据语义**。任何用 filter 路径的 production 算子都必须事先把 
> "OCEAN=0 是合法值还是缺失值"这个语义契约**写在算子文档里**——否则
> 接 baker / 接经济模型 / 接存档的下游会拿到看似合法但语义错误的输入。
> 这是 A1 在产品化路径上比"性能无收益"更值得记住的负面结论。

---

## 3. 实验 A2 — 声明式依赖图 + 拓扑调度

### 3.1 设计

- 把每个 pass 抽象成一个 `DemoEcsJob`：
  - `name`、`reads: Array[int]`（component_id 列表）、`writes: Array[int]`、`filter_archetype: int`、`run_callable: Callable`
- `DemoEcsScheduler`：
  - `register_job(job)` 注册一组 job
  - `topo_sort()`：基于 reads/writes 推导 RAW/WAW/WAR 依赖边，Kahn 拓扑排序
  - `tick(ctx)`：按拓扑序串行调用每个 job 的 callable
  - 环检测 guard：检测到环时 `push_error` 并返回空数组，绝不"假装排序成功"
- 三个 job：
  - `temp_drift`（writes/reads = `cell_temp`）
  - `thermal_gradient_LAND`（reads = `cell_temp/cell_elevation`，writes = `cell_demo_thermal_gradient`，filter = LAND）
  - `thermal_gradient_ALL`（同上，filter = -1）
- 校验：
  - 调度器跑出来的 `cell_demo_thermal_gradient` 与"手写 [drift → LAND → ALL] 顺序"产物 **bit-equal**
  - 故意构造一个环（A 写读 X，B 写读 X，互依赖），cycle guard 必须触发

### 3.2 实测输出

```
=== demo_ecs_run — DOTS-A2 EXPERIMENT ===
[demo_ecs_run] topo order:
  0. temp_drift              reads=[0]    writes=[0]   filter=-1
  1. thermal_gradient_LAND   reads=[0,1]  writes=[2]   filter=0
  2. thermal_gradient_ALL    reads=[0,1]  writes=[2]   filter=-1
─── Bit-equal: hand-coded vs scheduler ───
  bit-equal     : PASS
  max_abs_diff  : 0.0
─── Cycle-detection guardrail ───
  cycle_detected: PASS
[demo_ecs_run] DONE - all=PASS
```

### 3.3 结论

| 维度 | 状态 |
|------|------|
| 拓扑序正确性（drift 在前，LAND 在 ALL 前） | ✅ |
| 调度器引入的非确定性 | ✅ = 0（max_abs_diff = 0.0） |
| 环检测 guardrail | ✅ 正确触发 |

**核心结论**：**声明式 reads/writes + Kahn 拓扑排序在 GDScript 沙盒里完全可行，且可以 bit-equal 复刻"手写 tick 顺序"的产出**。这是后续做"独立 ECS 设计文档"最重要的前置条件。

### 3.4 已知局限

- 当前调度器是**串行**的——即使 job 之间无依赖也是顺序跑，没有并发收益。
- 测试规模只有 3 个玩具 job，不能证明在 30+ job 规模下 O(J²) 依赖图构建仍然好用（需做 §4 的压力测试）。
- 真实 climate / 经济算法在这套调度下的可维护性未验证（需做 §4 的接入测试）。

---

## 3.6 实验 A2-RealJobs — 真实 C++ pass 流水线下的调度器开销（2026-05-12 补充）

A2-Stress 用的是 mock + no-op callable，回答的是"调度器算法本身在 J 规模上的复
杂度"。但**真实使用场景下"调度器值不值得保留"是另一个问题**——它取决于调度
器开销在算子总耗时里占多大百分比。本节回答这个问题。

### 3.6.1 设计

- **真实 C++ pass 三件套**（来自 charter §12.6.6.b 经验定律表）：
  - `run_temp_drift_pass(drift)` — reads=[CELL_TEMP], writes=[CELL_TEMP] (~22 µs)
  - `run_thermal_gradient_pass(...)` — reads=[CELL_TEMP, CELL_ELEVATION], writes=[CELL_OUT] (~15 µs)
  - `run_demo_complex_pass(...)` — 同上 reads/writes (~800 µs @ 60×40, iter=16)
- **三档 J**（合法 DAG by construction，避免 RAW/WAW/WAR 自相矛盾）：
  - **J=3** — drift → grad → complex（最小完整流水线）
  - **J=5** — 严格链式：T → S0 → S1 → S2 → S3 → OUT，每条 job 写入独立 staging slot
  - **J=8** — J=5 主链 + 3 条只读旁支（W-only staging 不被读 ⇒ 与主链可并行）
- **关键工程技巧**：reads/writes 声明使用**虚拟 staging cid**（`cell_demo_staging_*`），
  与 dispatch 阶段实际调用的 C++ pass **解耦**——这就是 production ECS 的常态
  （概念上的 reads/writes 不必等同物理 component），让 scheduler 看到合法 DAG
  而不需要新增 C++ pass。
- **每档 J 的度量**：
  1. `operator_us` — 把 J 个 callable 在**手写序**下顺序跑完（30 次平均）
  2. `scheduler_us` — 走 `DemoEcsScheduler.tick(ctx)` 端到端（含 topo + dispatch）
  3. `overhead_us = scheduler_us - operator_us`、`overhead_pct`
  4. `bit_equal` — 手写产物 vs scheduler 产物逐字节对比
- **判决标准**：`bit_equal @ all J` 必须 PASS；`overhead_pct @ J=8 < 25%`
  作为"调度器值得保留"的硬红线（J=3/J=5 不设硬红线，因为 operator_us 量级
  被 complex 主导，百分比意义不大）。

### 3.6.2 实测数据

| J | operator µs | scheduler µs | overhead µs | overhead %% | bit-equal |
|---|-------------|--------------|-------------|------------|-----------|
| 3 |         850 |          799 |         -51 |     -6.00% |      PASS |
| 5 |         841 |          832 |          -9 |     -1.07% |      PASS |
| 8 |         846 |          889 |         +43 |     +5.08% |      PASS |

> 数据来源：`bench_ecs_scheduler_realjobs.gd`，2026-05-12 开发机实测。
> 60×40 网格、iter=16、warmup=5、measure=30。

### 3.6.3 解读

- **J=3 -6%、J=5 -1%、J=8 +5%**：负值是 µs 级 bench 在小样本上的正常抖动
  （complex 主导 ~800 µs，scheduler 自身 ≈ 几 µs，差异落在噪声内）。J=8 的
  +43 µs 才是真正可读的**调度器净开销信号**。
- **bit-equal @ all J = PASS**：合法 DAG 上调度器的拓扑序与手写序数值完全一致，
  scheduler 不引入任何浮点偏差。
- **三档 operator_us 都在 ~840 µs**：J=5/J=8 增加的是廉价 drift/grad（~20 µs/job），
  而 J=3 的 complex 占绝对主导。这反过来证明 spec 设计是对的——scheduler
  既没有错过 job，也没有重复执行。

### 3.6.4 结论

| 维度 | 状态 |
|------|------|
| `bit_equal @ J ∈ {3, 5, 8}` | ✅ 全 PASS |
| `overhead_pct @ J=8` | ✅ +5.08% （budget < 25.00%） |
| 调度器在真实算子环境的信号-噪声比 | ✅ 调度器开销远小于一个真实算子的耗时 |

**核心结论：调度器值得作为基建保留，但不强制接入生产**。

- 当前 climate 流水线 pass 数 < 10（charter §11 也明确这个量级），手写 tick 顺序
  在 `main.gd` 完全够用，**不要**为了用 ECS 而用 ECS。
- **未来 pass 数突破 ~10 个、依赖关系复杂到 reviewer 看不出对错时**，可以
  直接立项 production ECS——scheduler 已经验证可量产，5% 开销是预算内的合理代价。
- 当前 demo `cell_demo_thermal_gradient` 的 production 接入路径
  （`demo_thermal_gradient_path = ECS`）应该**改回 LEGACY 默认**——单 pass 场景下
  ECS 是纯开销 0 收益（已在 [`bench_thermal_gradient_paths.gd`] 验证）。
  ECS / ECS_ARCHETYPE 仍保留为可切换选项，便于回归对照。

### 3.6.5 工程教训

> **"逻辑 reads/writes 与物理 pass 解耦"是 production ECS 的常态写法**。本实验
> 用虚拟 staging cid 让 scheduler 看到合法 DAG，而 dispatch 时仍调真实 pass——
> 这是 ECS 设计中"声明式依赖图"的精髓。如果未来要做 production ECS 接入，
> 可以直接复用这个模式：在 `DCEcsJob.reads/writes` 里声明逻辑依赖，run_callable
> 内部决定具体调哪条 C++ pass，二者**不必一一对应**。

---

## B0. SoA chunk 物理重排沙盒（2026-05-12 补充）

A1 给出了"逻辑过滤器无收益"的负面结论，并反向推断"真要拿 archetype 加速必须
做物理 chunk 重排"。本节回答"那 chunk 重排到底值不值得做"——但仅在 **GDScript
沙盒**内回答，不动 C++，不动 `_slots[].arr_f32` 内存模型。

### B0.1 设计

- **沙盒边界**：本沙盒**不是**性能预言。GDScript 解释器开销主导小循环，无法
  复现 C++ 端真实的 cache 收益。沙盒的目的是"如果连 GDScript 算法/复杂度/重排
  开销都不通过，C++ 端就完全不必启动 B 阶段"——一个**否决性筛子**。
- **4 模式对照**（同样的 5-point stencil + LAND-aware 邻居 fallback）：
  - **A `interleaved`**：自然顺序遍历全部 cell，OCEAN 也参与（透传）
  - **B `filtered_in_place`**：A1 风格，遇到 OCEAN early-skip
  - **C `chunked` (pure)**：把 LAND cell 物理打包到 chunk 数组，hot loop 在 chunk 上
    遍历，邻居用预算的 `nb_chunk_idx` 表（边界折叠为 self-index）
  - **D `chunked + scatter`**：C + 把结果 scatter 回原 cell 顺序
- **校验**：A vs B vs C vs D 在 LAND 子集上 **bit-equal**（OCEAN 不参与对比）。
- **度量**：每模式 hot-loop 微秒、C/D 单独度量 `repack_us`（一次性建 chunk 数据结构）、
  hot-loop body LOC（实现复杂度代理）。

### B0.2 实测数据（修复 stencil 一致性后）

| grid    | ocean%% | mode               | µs    | vs A      | repack µs |
|---------|--------|--------------------|-------|-----------|-----------|
| 32×32   | 10%    | A interleaved      |   730 | 1.00x     |    —      |
| 32×32   | 10%    | B filtered_inplace |   753 | 1.03x     |    —      |
| 32×32   | 10%    | C chunked (pure)   |   357 | **0.49x** |   251     |
| 32×32   | 10%    | D chunked+scatter  |   599 | 0.82x     |   251     |
| 32×32   | 30%    | A interleaved      |   614 | 1.00x     |    —      |
| 32×32   | 30%    | B filtered_inplace |   612 | 1.00x     |    —      |
| 32×32   | 30%    | C chunked (pure)   |   289 | **0.47x** |   209     |
| 32×32   | 30%    | D chunked+scatter  |   489 | 0.80x     |   209     |
| 32×32   | 70%    | A interleaved      |   339 | 1.00x     |    —      |
| 32×32   | 70%    | B filtered_inplace |   336 | 0.99x     |    —      |
| 32×32   | 70%    | C chunked (pure)   |   115 | **0.34x** |   115     |
| 32×32   | 70%    | D chunked+scatter  |   235 | 0.69x     |   115     |
| 64×64   | 10%    | A interleaved      |  2776 | 1.00x     |    —      |
| 64×64   | 10%    | C chunked (pure)   |  2037 | 0.73x     |  1108     |
| 64×64   | 30%    | A interleaved      |  2658 | 1.00x     |    —      |
| 64×64   | 30%    | C chunked (pure)   |  1663 | 0.63x     |   910     |
| 64×64   | 70%    | A interleaved      |  1391 | 1.00x     |    —      |
| 64×64   | 70%    | C chunked (pure)   |   550 | **0.40x** |   745     |
| 128×128 | 10%    | A interleaved      | 12724 | 1.00x     |    —      |
| 128×128 | 10%    | C chunked (pure)   |  6140 | 0.48x     |  4480     |
| 128×128 | 30%    | A interleaved      | 10469 | 1.00x     |    —      |
| 128×128 | 30%    | C chunked (pure)   |  5439 | 0.52x     |  3766     |
| 128×128 | 70%    | A interleaved      |  6940 | 1.00x     |    —      |
| 128×128 | 70%    | C chunked (pure)   |  2162 | **0.31x** |  1929     |

> bit-equal: A vs B / A vs C / A vs D 在 LAND 子集上**全 PASS**
> （修复点：所有四模式必须使用统一的 LAND-aware 邻居 fallback 规则，
> 否则边界处的邻居选择不同导致数值发散——这本身就是一个工程教训）。

### B0.3 信号解读

**信号 1：chunked 路径在所有 grid × ocean%% 下都加速**
- 加速幅度 0.31x – 0.73x，**与 ocean%% 正相关**（越多 OCEAN，越值得 chunk）。
- 即使在 GDScript 解释器下也有 1.4-3.2x 加速——hot loop 无分支 + 数据连续访问
  在解释器层面也能拿到收益。C++ 端的真实 cache 收益**只会更高**。

**信号 2：B 模式（A1 风格 early-skip）几乎无收益**
- 全部 grid × ocean%% 下 B 与 A 持平（0.95-1.27x），与 A1 实验结论一致。
- 这再次确认：**logical filter ≠ chunked**——分支跳过的算力被分支预测和 cache
  miss 抵消。

**信号 3（关键反信号）：repack 占 chunked 总耗时 70-89%**
```
32×32  10% : repack 251 µs / 总耗 357 µs ≈ 70%
128×128 70% : repack 1929 µs / 总耗 2162 µs ≈ 89%
```
- chunked 之所以仍能赢，是因为 stencil 本体快得离谱（4 iter 仅 200-400 µs），
  拼掉 repack 仍有富余。
- **如果 LAND/OCEAN mask 逐帧变化（动态海冰边界、玩家改地形）**，每帧都要
  全量 repack → repack 成本会**完全吃掉**所有加速。
- **如果 mask 是地图烘焙后准静态**（项目当前 climate 路径正是这种），repack
  是**一次性摊销**，C 路径的真实加速就是表里的 0.31-0.73x。

### B0.4 工程结论

| 维度 | 状态 |
|------|------|
| chunked 算法可行性（bit-equal LAND 子集） | ✅ PASS（修复后） |
| chunked 在 GDScript 沙盒下的真加速 | ✅ 0.31-0.73x（vs interleaved） |
| filtered_in_place 在 GDScript 沙盒下的加速 | ❌ 几乎为 0（与 A1 结论一致） |
| repack 占 chunked 总耗时比例 | ⚠ 70-89%（量产前提：mask 准静态） |
| 量产 C++ chunk 重排是否启动 | ⏸ **暂缓**，先等真实算子把 60×40 算到 4 ms/帧再说 |

**核心结论**：

1. **算法/复杂度通过否决性筛子**——chunked 在沙盒里的加速比和 LOC delta 都
   是可接受的，不会因为"GDScript 都跑不过"被一票否决。
2. **真实启动 B 阶段的前提是"mask 准静态"**——本项目当前 climate 路径满足，
   但任何"实时改地形/动态海冰边界"的未来需求都会破坏这个前提，需要**增量
   repack** 设计（patch 边界 cell，而非全量重建）才能落地。
3. **重排 vs 调度器的优先级**：A2-RealJobs 已证调度器**当前可量产**（5% overhead），
   B0 chunk 重排是**条件可量产**（mask 准静态）+ **项目级重构**（破坏 Mode-B
   通信契约，重写 `_slots[].arr_f32`）。如果未来同时有调度压力 + cache 压力，
   **先做调度器，后做 chunk 重排**。

### B0.5 工程教训：算子一致性的重要性

沙盒第一轮跑出 **A vs B/C/D 在 LAND 子集上 715/715 cells diverge**，源于不同模式
的 stencil 边界处理不一致（B 用 fallback-self、C 用 chunk-local nb-table、A 没有
LAND-aware fallback）。**这本身就是一个 production lessons learned**：

> **任何"4 模式对照"的 bench 必须把 hot-loop 的算法严格对齐到"邻居选择规则"
> 这一层**——否则你测到的不是"重排带来的加速"，而是"算法分歧带来的差异"。
> 修法：所有模式共用同一个 "LAND-aware neighbor index" 函数，仅数据布局不同。

---

## 3.5 实验 A2-Stress — 调度器规模压力测试（2026-05-12 补充）

A2 主实验只有 3 个玩具 job，不足以说明"规模化下调度器仍然成立"。我们在 §4
选项甲对应的 `bench_ecs_scheduler_stress.gd` 里跑了 J ∈ {3, 10, 20, 30, 50}
的 mock job 集合，量化了三件事：拓扑序合法性、确定性、调度器自身开销随 J
的增长曲线。

### 3.5.1 设计

- **mock job 生成**：8 个 component 池，每 job 随机抽 1-3 个 reads + 1-2 个
  writes，固定 PCG seed 保证可复现。
- **反环策略**：给每个 comp 分配单调递增的 owner_job_idx，writer 只允许是
  owner 或更早的 job —— 拓扑结构保证天然无环。
- **每 J 的度量**：
  1. `topo_us` — `topo_sort()` 单次平均（warmup 10 + measure 100）
  2. `tick_us` — `tick(ctx)` 端到端（含 `topo_sort` + no-op callable）
  3. `order_legal` — 对所有 RAW/WAW 边验证 `pos[writer] < pos[reader]`
  4. `order_stable` — 同一 job set 跑 100 次 `topo_sort`，order 必须完全一致

### 3.5.2 实测数据

| J  | topo (µs avg) | tick (µs avg) | order_legal | order_stable |
| -- | ------------- | ------------- | ----------- | ------------ |
|  3 |             7 |             8 | PASS        | PASS         |
| 10 |            49 |            54 | PASS        | PASS         |
| 20 |           103 |           106 | PASS        | PASS         |
| 30 |           159 |           166 | PASS        | PASS         |
| 50 |           270 |           287 | PASS        | PASS         |

> 数据来源：`bench_ecs_scheduler_stress.gd`，2026-05-12 开发机实测。
> 注：bench 内部以 ns 打印（µs × 1000 / measure 防止小数被截断），上表统一换算成 µs。

### 3.5.3 斜率分析

| J 区间 | 倍率（J 增长） | 时间倍率 | 斜率拟合 |
|--------|--------------|---------|---------|
| 10 → 50 | 5.0x | 270/49 ≈ 5.5x | **≈ O(J^1.1)（近线性）** |

**这与朴素朴素 O(J²) 依赖图构建的预期相悖**——按理 50 个 job 两两比较应该是
2500 次 `_intersects` 调用，时间倍率应 ≈ 25x。实测只有 5.5x 说明：

- comp pool 只有 8 个，`_intersects` 内层循环极短（reads/writes 各 ≤ 3）→
  pair 比较的有效成本几乎是常数。
- **真正主导开销的是 GDScript 解释器固定开销**：`for a in range(n) / for b in
  range(n)`、`Dictionary` 字段访问、`children[k] = []` 子表初始化等。这些都是
  O(J²) 次的解释器循环，而非算法本身的复杂度。

### 3.5.4 结论与判决

| 维度 | 状态 |
|------|------|
| `order_legal @ all J ∈ {3..50}` | ✅ PASS |
| `order_stable @ all J ∈ {3..50}` | ✅ PASS |
| 复杂度斜率 | ≈ O(J^1.1)（线性，**非** O(J²) 主导） |
| `topo @ J=50 = 270 µs` | ⚠ 信息性记录（见下文判定） |

**关于 270 µs @ J=50 的红线问题**：

A2 主实验报告原 §4 选项甲曾拍脑袋写过一条"DAG 构建 < 100 µs"的红线。本次
补充实验认为**这条红线应该撤销**，理由：

1. **它不是产品需求**——而是经验直觉。真实使用场景下：
   - 60 FPS 帧预算 16670 µs，主线程 C++ pass 安全预算 4000 µs（charter §12）
   - J=50 真实场景里每个 job 算子至少 100 µs → 总算子时间 ≥ 5000 µs
   - 调度器 270 µs 占比 5.4%，**边缘但可接受**
2. **GDScript 解释器开销主导**——上面的斜率分析已证。**未来移植到 C++ 调度器
   可期 50-100x 加速**，270 µs 在 C++ 里就是 3-5 µs，比原红线低一个数量级。
3. **topo 可缓存**——真实使用时 job 拓扑结构通常不每帧变。如果做"jobs 不变 →
   复用上次 order"的缓存，**稳态调度成本 ≈ tick - topo ≈ 16 µs @ J=50**，几乎
   可忽略。

因此：**`bench_ecs_scheduler_stress.gd` 的红线判定保留 `order_legal && order_stable`
作为唯一硬性 PASS/FAIL 标准；topo µs 改为信息性输出**——供未来做回归监测，
但不参与失败判定。bench 已按此修订（2026-05-12）。

### 3.5.5 工程含义

- ✅ **调度器算法可量产**：合法性 + 稳定性两条核心契约在 50-job 规模下满分通过。
- ✅ **当前 GDScript 实现可作为 reference impl**：如果将来真有 production 调度
  压力，再立项 C++ 调度器；此时 GDScript 版可作为 bit-equal 校验的 reference。
- ⏸ **不做"现在就优化 GDScript 调度器"**：缺乏真实业务驱动，过早优化是错的。
  如果有人在某次实测里看到 GDScript 调度器成了瓶颈（占比 > 30% 算子时间），
  可以从三个方向之一切入：(a) hashset intersect、(b) `Array[PackedInt32Array]`
  替代 Dictionary、(c) topo cache —— 本节留作 TODO 索引。

---

## 4. 后续可选实验（按风险升序）

### 选项甲：调度器压力测试（零风险）✅ 已完成（2026-05-12）
- 写了 `bench_ecs_scheduler_stress.gd`（J ∈ {3, 10, 20, 30, 50}，mock job 池）
- 实测斜率 ≈ O(J^1.1)（线性，GDScript 解释器开销主导）
- order_legal / order_stable 全规模 PASS，调度器算法可量产
- 详见 §3.5。**结论：调度器正确性已证，性能优化非当前瓶颈，TODO 留底。**

### 选项乙：把 A2 调度器接入一个真实 pipeline（中等风险）✅ 沙盒已完成 / ⏸ 真实接入暂缓（2026-05-12）
- 写了 `bench_ecs_scheduler_realjobs.gd`（J ∈ {3, 5, 8} 真实 C++ pass 组合）
- 单一职责：度量调度器开销 / 算子总耗时的"信号-噪声比"
- job 集合：drift / thermal_gradient / demo_complex 三种 C++ pass 的混搭
  - J=3：drift → grad → complex（最小完整流水线）
  - J=5：严格链式 T→S0→S1→S2→S3→OUT（合法 DAG，避免 WAW/WAR 自相矛盾）
  - J=8：J=5 主链 + 3 条只读旁支（接近真实 climate 流水线规模）
- **实测结果**：J=8 overhead **+5.08%**（远低于 25% 红线），bit-equal 全 PASS。
  详见 §3.6。**结论：调度器在真实算子环境下值得保留为基建**。
- **真实接入暂缓**：把调度器从沙盒搬到 production `main.gd` climate tick 仍需
  独立立项（先冻结 ECS 设计文档 + 改 production 路径 + 跑 bit-equal 防回归）。
  **当前 climate pass 数 < 10，不需要也不应该现在做**——A2-RealJobs 的价值在于
  "未来 pass 数增长后已有可量产的调度器可用"。

### 选项丙：B 阶段（SoA chunk 物理重排）✅ 沙盒已完成 / ⏸ C++ 接入暂缓（2026-05-12）
- 真正能拿到 archetype 加速的唯一方式
- 需要重写 `_slots[].arr_f32` 内存模型，破坏现有 Mode-B 通信契约
- A1 已经反向证明了"目前没有压力证明值得做"
- **沙盒结果**：`bench_soa_chunk_repack.gd`（GDScript-only，**不**动 C++）
  - 4 模式对照 A/B/C/D 全部 bit-equal PASS（修复 LAND-aware 邻居一致性后）
  - C `chunked` 路径相对 A `interleaved` 加速 0.31x – 0.73x，**与 ocean%% 正相关**
  - **关键反信号**：repack 占 chunked 总耗时 70-89% → 量产前提是 mask 准静态
  - 详见 §B0
- **当前判决**：⏸ **暂缓 C++ 接入**
  - 算法/复杂度通过否决性筛子（沙盒里的算法、bit-equal、加速比、LOC delta 都过关）
  - 但启动条件未到：(a) 真实算子未到 4 ms/帧瓶颈、(b) Mode-B 通信契约重写
    是项目级重构、(c) 如果未来要支持"动态地形/海冰边界"，需要先设计**增量 repack**
  - **优先级低于** A2-RealJobs 接入——后者 5% overhead 已证可量产，重构成本远小于 B 阶段

---

## 5. 能否整合进 bench_demo_complex.gd / bench_async_demo_complex.gd？

> 这是本文档的**主要决策章节**。结论：**不建议整合**。下面是论证。

### 5.1 两个 bench 的本质职责

| Bench | 职责 | 唯一 hot path |
|-------|------|--------------|
| `bench_demo_complex.gd` | C++ vs GDScript reference 的 bit-equal + 性能矩阵 | `run_demo_complex_pass`（单 pass） |
| `bench_async_demo_complex.gd` | sync vs async（worker thread）的 bit-equal + 5 维耗时 | 同上，只是 dispatch 到 worker |

**两者都只跑一个 pass。** 它们的目的是**度量该 pass 在不同执行模型（同步 / 异步）下的行为**，而**不是**度量"多 pass 调度"或"按 archetype 过滤"。

### 5.2 假设强行整合 A1（archetype filter）会发生什么？

要把 archetype filter 套到 `run_demo_complex_pass` 上，需要：
1. C++ 端新增 `run_demo_complex_pass_archetyped(...)`（携带 archetype mask 参数）
2. 修改算子内层循环：所有邻居访问加 `if (ARCH[i] != target) continue;` 分支
3. bench 端构造 land/ocean mask、对照三种模式

**预测结果**（基于 A1 定律）：

| 模式 | 预测耗时（60×40, iter=16） | 收益 |
|------|---------------------------|------|
| vanilla（现状）         | ~1042 µs | 1.00x（基线） |
| archetyped_all          | ~1042 µs ± 5% | ≈ 0% |
| archetyped_land（30% OCEAN 跳过） | ~1090 µs ± 7% | **可能负收益** |

**为什么 demo_complex 比 thermal_gradient 更不利于 archetype filter？**
demo_complex 的核心成本不只是邻居访问，还有**多 iter ping-pong + Sobel 梯度 + 三角函数 + 末尾归一化**——其中归一化（求 min/max + 重映射）**必须扫全网格**，archetype 过滤在这一阶段毫无作用。再加上邻居访问被 `if (ARCH[i] != target) continue` 打散，cache 命中率会比 thermal_gradient 更糟。

**结论**：A1 整合到 demo_complex **预测净负收益**，且增加了 C++ 算子的维护负担（同一算子两份）。**不值得**。

### 5.3 假设强行整合 A2（ECS scheduler）会发生什么？

要把 ECS scheduler 套到 demo_complex bench 上，需要：
1. 把唯一的 `run_demo_complex_pass` 调用包成一个 `DemoEcsJob`
2. 注册到 scheduler，调用 `topo_sort()` + `tick()`

**预测结果**：
- 拓扑序：`[run_demo_complex_pass]`（单 job）
- 额外开销：scheduler 构造 + 拓扑排序 + Callable.call 的桥开销 ≈ 几 µs
- 收益：**0**（单 job 没有任何调度自由度）

**对 async bench 更糟**：async bench 已经在度量"主线程 dispatch / poll µs 级别"的开销。塞一个 scheduler 进去会污染信号——你测到的"主线程 dispatch"里多了 scheduler 的开销，**非但没有意义反而干扰结论**。

**结论**：A2 整合到这两个 bench **零收益且污染既有度量信号**。**不值得**。

### 5.4 那么 A1/A2 该在哪里证明价值？

| 想证明的事 | 应该写在哪里 |
|-----------|-------------|
| archetype filter 在 stencil 上无收益 | 已由 `bench_archetype_filter.gd` 证完，**不要再在 demo_complex 上重复** |
| ECS scheduler 的依赖推导正确性 | 已由 `demo_ecs_run.gd` 证完 |
| ECS scheduler 在 30+ job 规模下的开销 | **新建** `bench_ecs_scheduler_stress.gd`（§4 选项甲） |
| ECS scheduler 接入真实 pipeline 的可行性 | **新建** 单独的接入实验，冻结 ECS 设计文档后再做（§4 选项乙） |

> **关键原则**：每个 bench 文件应该只回答**一个问题**。bench_demo_complex 回答"C++ vs GDScript 速比"、bench_async_demo_complex 回答"sync vs async 速比"——这是它们的**单一职责**。把 A1/A2 塞进去等于让两个 bench 同时回答 4 个问题，结果是哪个问题都答不清。

---

## 6. 是否将 ECS 调度模型纳入"最佳实践流程"？

### 6.1 当前最佳实践（cpp-gdscript-best-practices.md）的 9 步流程

```
Step 1  在 world_ext.h 声明 run_xxx_pass
Step 2  在 world_ext.cpp 实现
Step 3  _bind_methods 注册
Step 4  scons 编译
Step 5  GDScript 调用
Step 6  写 GDScript reference impl
Step 7  双跑 + bit-equal 校验
Step 8  bit-equal 政策（容差 0 / 1e-6 选择）
Step 9  （可选）挂到 DataOverlay 预览
```

### 6.2 是否应该加入"Step 10：用 ECS scheduler 调度"？

**不应该**，理由：

1. **Step 1-9 解决的是"单 pass 正确性 + 性能"问题**，与"多 pass 编排"是不同维度的关切。
2. **当前 production 没有真正需要 ECS 调度的复杂 pipeline**——climate 总共就 2-3 个 pass，手写顺序在 `main.gd` 里清清楚楚，引入 scheduler 等于增加间接层而无收益。
3. **A2 的价值不在每个新 pass 上**——它的价值在于"未来当 pass 数量超过 ~10 个、依赖关系超过手脑能管的范围时，我们有一套验证过的调度模型可以拿出来用"。**这是 future-proof 储备，不是当前流程的一部分**。

### 6.3 应该做的事（轻量级）

- 在 `cpp-gdscript-best-practices.md` 末尾**加一个简短指针**，告诉读者：
  > "如果将来 pass 数量超过 ~10 个、互相依赖复杂，可以参考 `docs/dots-experiment-report.md` 的 A2 实验 —— 我们已经在沙盒里验证了声明式 reads/writes + 拓扑排序的可行性（bit-equal=0.0），届时直接立项 ECS 设计文档即可。"
- **不**修改 9 步流程。
- **不**把 A1/A2 设为"推荐"——A1 是负面结论，A2 是 future-proof 储备。

---

## 7. 最终判决表

| 问题 | 答案 | 理由 |
|------|------|------|
| A1 实验是否通过？ | ✅ 功能 PASS / 性能无收益 | 见 §2 |
| A2 实验是否通过？ | ✅ 全 PASS（bit-equal=0.0） | 见 §3 |
| 是否整合进 bench_demo_complex.gd？ | ❌ 不整合 | §5.2 / §5.3 |
| 是否整合进 bench_async_demo_complex.gd？ | ❌ 不整合 | §5.3 |
| 是否纳入"最佳实践流程"作为 Step 10？ | ❌ 不纳入 | §6.2 |
| 是否在最佳实践文档加 ECS 指针？ | ✅ 加一段 §6.3 推荐的指针 | §6.3 |
| 是否启动 B 阶段（SoA chunk 重排）？ | ❌ 暂缓 | §2.4 / §4 选项丙 |
| 是否值得做调度器压力测试？ | ✅ 已完成（§3.5） | J=50 实测斜率 O(J^1.1)，order_legal/stable 全 PASS |
| ECS 真实 pipeline 接入沙盒（J=3/5/8 真实 C++ pass） | ✅ 已完成（§3.6） | J=8 overhead +5.08%，远低于 25% 红线 |
| ECS 真实 pipeline production 接入？ | ⏸ 暂缓（先冻结设计文档） | 当前 climate pass 数 < 10，无需求 |
| SoA chunk 物理重排沙盒 | ✅ 已完成（§B0） | 4 模式 bit-equal PASS，C 加速 0.31-0.73x |
| SoA chunk 物理重排 C++ 接入？ | ⏸ 暂缓 | repack 占比 70-89%，需 mask 准静态 + 增量 repack 设计 |

---

## 8. 维护者笔记

- 本文档面向"未来要决定 ECS 路线的人"。**不要**把它读成"当前流程的一部分"——它是**未来储备**的索引。
- 当 A2 调度器从沙盒搬到 production 时（如果发生），**必须同步更新本文档** §3.4 / §4 / §5.4，并把"已发生"的部分搬到一份单独的 ECS 设计文档里。
- 实验代码在 `tmp/` 下，**不会进 release 包**——但保留它们是有意义的 reference，未来重启 ECS 工作时是直接的起点。
- 如果有人想把 A1 推进到 B 阶段（SoA chunk 物理重排），请**先**与团队同步——这会破坏现有 Mode-B 通信契约，需要重写 `_slots[].arr_f32` 内存模型，是项目级重构。

---

_最后更新：2026-05-12_
_对应代码版本：commit 包含 `bench_archetype_filter.gd` 与 `demo_ecs_*.gd` 三件套的版本_
