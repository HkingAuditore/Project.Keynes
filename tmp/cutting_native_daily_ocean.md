# 削减 `native_daily_sim` 与 `ocean_currents` 的策略（结合 Project.Keynes Skill）

> 数据来源：`tmp/perf_record_20260707_202818.csv`（491 tick 窗口）。
> 架构依据：`project-keynes-runtime-architecture`、`project-keynes-dots-deepening`、`cpp-dots-runtime-development` 三个 Skill。
> 代码依据：`native_daily_sim_job.gd`、`ocean_currents_job.gd`、`system_schedule.cpp`、`world_ext_daily_sim.cpp`、`world_ext_climate.cpp`、`world_ext_weather.cpp`。

---

## 0. 一句话结论

两份作业**根因相同**：切片粒度是「节点 / 物理阶段」级别的整遍扫描（一次 pass 遍历全部 cell），**不可被 `slice_budget_ms` 抢占**，于是每片实际 1.1–3.1ms（native）/ 0.6–1.9ms（ocean），都远超协作预算（1.0 / 0.55ms）；`weather` 节点单片更尖到 **7.79ms**——这是整段仿真里最大的单帧尖峰。

最大结构性杠杆（两作业通用）：**给节点 / 物理阶段加「按 cell 预算」的细切片**（pass 已支持 `start_idx/end_idx`，只是 `run_native_daily_slice` / `_physical_solve_step_one` 没用），把单帧尖峰打散。其余是调参类杠杆（advect_steps / field_advect_steps / PSI 迭代）与弱机降频。

> ⚠ 对 **native_daily** 此结论成立（其 `SCHEDULE_GRAPH` pass 已读 `start_idx/end_idx`，瓶颈确在 C++ cell kernel）；对 **ocean 物理阶段** 此前提已被 §7.1 修正——瓶颈在 GDScript wrapper，且 phys pass 当前根本不接受 cell 区间。详见 §7。

---

## 1. `native_daily_sim` 实测分布（41 轮，每轮 11 片）

| 切片（stage） | 均值 ms | p95 ms | 最大 ms | 说明 |
|---|---|---|---|---|
| native_daily_complete | 3.12 | 3.64 | 3.89 | 收尾片：finalizer + flush + publish |
| climate_pass_a | 3.02 | 3.66 | 3.91 | 首片：bundle 构建 + refresh 开销 |
| **weather** | 2.91 | 3.06 | **7.79** | **最重节点 + 全局最大尖峰** |
| ocean_water | 1.82 | 2.03 | 2.09 | 水域平流 |
| runtime_hydrology | 1.52 | 1.68 | 2.02 | 水文（当前非 SCHEDULE_GRAPH 节点，属覆盖盲区）|
| wind_air | 1.34 | 1.46 | 1.67 | 空气质点平流（n×advect×6 邻域）|
| wind_surface | 1.32 | 1.50 | 1.71 | 地表风 |
| sea_ice / transpiration / climate_pass_b / ocean_land | 1.1–1.3 | — | — | 次级 |

**关键观察**：
- `bd_climate_*` 节点纯 C++ 计时其实很小（wind_air 0.23ms、wind_surface 0.22ms），但切片级 `j_native_daily_sim_*` 却 1.2–3.1ms —— **每片有大量 bundle/JIT/refresh/flush/apply 固定开销**叠加在节点计算上。
- 所有切片都 >1.0ms 预算 → 协作预算形同虚设，单帧尖峰由「节点粒度」决定。

### 削减杠杆（按性价比）

1. **【结构·最大】按 cell 预算细切片**：`SCHEDULE_GRAPH` 各 `run_*_pass` 已读 `start_idx/end_idx`，但 `run_native_daily_slice` 按整节点推进（游标 `_native_daily_slice_node_index`）。改为「每片设 cell 上限」，把单个 node 的 cell 摊到多 tick。直接把 7.79ms 的 weather 尖峰和 3ms 首/尾片压到 ~1.5ms 内。**需改执行器 + PROBE/A-B。**
2. **【调参·大】`field_advect_steps`（weather）**：`weather_system.gd:114` 默认 **6**，C++ 缺 key 回退 3。降到 2–3（须 GDScript 显式下发，否则回退 3）。直接削最重节点 `weather`（含 field_solve + 6 邻域 × advect_steps）。
3. **【调参·大】`advect_steps`（wind_air / wind_surface / ocean knobs）**：砍掉内层 `n_cells × advect_steps × 6` 邻居循环次数，对 wind/ocean 三节点同效。
4. **【调参·中】`weather_synoptic_*`**：关 `weather_synoptic_enabled` 或降 `syn_adv_cells`（默认 3）可省整段 ψ 平流演化。
5. **【调参·小】`stage_b` 空 knob 跳过**：确保 albedo/veg_dyn/feedback 全 false 时 `stage_b_knobs` 为空 → 整段 `return true` 跳过（已支持）。
6. **【架构·弱机】降 native daily 触发频率**：当前约每 12 tick 起一轮（491 tick / 41 轮）。弱机把 `native_daily` 的 `StridePolicy` 步长调大（每 2–3 个仿真日一轮），尖峰更少，代价是仿真新鲜度略降。

---

## 2. `ocean_currents` 实测分布（491 tick）

| 阶段 | 均值 ms | p95 ms | 最大 ms | n | 说明 |
|---|---|---|---|---|---|
| phys_wind | 1.88 | 2.56 | 2.61 | 81 | 最重物理阶段 |
| phys_psi_init | 1.76 | 1.95 | 2.11 | 41 | 压力场初始化 |
| phys_slp | 1.71 | 1.94 | 2.06 | 82 | 海平面气压 |
| daily_wind_prepass | 1.57 | 1.74 | 2.42 | 82 | 独立节奏的 SLP+wind 预解 |
| phys_upwelling | 0.62 | 0.76 | 0.85 | 41 | 上升流 |
| （idle / policy_wait）| 0 | — | — | 164 | 已被策略正确门控 |

所有「干活」切片 0.6–1.9ms，都 >0.55ms 预算。

**已具备的好架构**（不要破坏）：`ContinuousSlicedPolicy` 把一轮物理解摊到 `slice_count` 片；像素光栅已是**事件驱动**（仅 season_phase 跨整数时 rebake）；移动端已 `OS.has_feature("mobile")` 跳过 rebake（`ocean_current_visual_active()` 开关）；commit 已 defer 拆片。

### 削减杠杆

1. **【结构·最大】物理阶段内按 cell 细切片**：`phys_wind`(1.88) / `phys_psi_init`(1.76) / `phys_slp`(1.71) 目前每个是**一整遍** pass。让 `_physical_solve_step_one` 接受 cell 区间，把单个阶段摊到多 tick（与 native daily 同法）。**⚠ 修正：原「直接压到 <1ms」前提不成立——见 §7.1；phys pass 当前不接受 cell 区间（§7.2），真正瓶颈在 wrapper（§7.5）。**
2. **【调参·大】降 PSI 迭代**：`phys_psi_init` + `psi_iters` 是压力求解，降迭代次数 / 放宽 early-exit 残差阈值可削 1.76ms 这一段。
3. **【调参·中】`daily_wind_prepass` 也 cell 预算化**：它 1.57ms 且走独立节奏，同样可细切。
4. **【架构·弱机】`ocean_period_ticks` / `wind_period_ticks` 调大**：弱机把物理解周期拉长（每 2–3 日而非每日）。注意 ocean_currents_job 注释明确：wind/ocean_current/upwelling 必须按节奏更新，否则天气与 ocean heat transport 会读到冻结场——用 `daily_wind_split_passes` 错峰 SLP/wind，而非整体停更。
5. **【保留】移动端 rebake 跳过 + `ocean_current_visual_active()` 开关**：已验证把 non_sus 22ms→8ms，移动端务必保持。

---

## 3. 跨作业通用：设备档位策略

两份作业都已支持 `OS.has_feature("mobile")` 分支与 `ClimateProfile` / `MapConfig` 调参。建议定义一个**三档质量开关**（桌面 / 弱机 / 移动），把下列旋钮映射进去，而非硬编码：

| 旋钮 | 桌面 | 弱机 | 移动 |
|---|---|---|---|
| `sim_frame_budget_ms` (8) | 8 | 10 | 12（更宽松守门）|
| `sim_slice_budget_ms` (3) | 3 | 4 | 5 |
| native daily `StridePolicy` 步长 | 1 | 2 | 3 |
| `field_advect_steps` | 6 | 3 | 2 |
| `advect_steps` | 默认 | ×0.6 | ×0.5 |
| `ocean_period_ticks` | 30 | 45 | 60 |
| `ocean_current_visual_active` | true | true | false |
| 每片 cell 预算（结构改动后）| 关 | 开 | 开 |

---

## 4. Skill 强制约束（改动前必读，否则会踩坑）

来自 `cpp-dots-runtime-development` / `project-keynes-runtime-architecture` / `project-keynes-dots-deepening`：

1. **先修埋点 aliasing（阻塞）**：`bd_climate_*` 与 `bd_weather_*` 两列族逐字段相等，说明天气束计时器被气候束覆盖。在修好 recorder 前，`bd_climate_*` 节点拆分不可信——**本文的切片级 `j_native_daily_sim_*` 数据是可靠的**（独立列），但节点级 `bd_climate_*` 仅作相对参考。
2. **C++ 加速 ≠ DOTS 权威变更**：按 cell 细切片属于「公式/热循环」层级，不是权威迁移，不要因此改 `published_to_slot` / 阶段状态机所有权。
3. **PROBE / A-B / soak 优先**：任何 native 路径改动先在 PROBE 模式跑，对比 GDScript/fallback 输出，验证 parity 后再局部 ACTIVE；**fallback 路径保留到 soak 证据齐全**。
4. **改了行为就同步文档**：`docs/cpp-dots-runtime/computation-pipelines.md`、`scheduling-and-job-graph.md`、`performance-diagnostics-playbook.md` 必须同 PR 更新（节点顺序、切片行为、budget、report 字段）。
5. **保持 stage 名稳定**：`SusSchedulerExt` 的 `largest=job/stage/substage` 日志与 CSV 诊断依赖稳定名；重命名会破坏历史对比。
6. **默认不加 SIMD / WorkerThreadPool**：2400 cell 规模下，标量紧循环通常最优；只有当标量 C++ pass 实测仍过慢且数据布局合适才考虑。
7. **runtime_hydrology 是覆盖盲区**：它不在 `SCHEDULE_GRAPH` 内，native daily 完成语义未覆盖它。动 native graph 顺序前先做 A-B。

---

## 5. 建议落地顺序

1. 修 `bd_climate_*` / `bd_weather_*` 埋点 aliasing（让拆分可信）。
2. 弱机/移动先上**设备档位开关**（纯配置，零风险，立刻见效）：降 `field_advect_steps`、关 `ocean_current_visual`、拉长 `ocean_period_ticks`、native daily 步长 +1。
3. **结构改动（最大杠杆）**：给 native daily 与 ocean 物理阶段加「每片 cell 预算」细切片，PROBE 跑 30+ tick 看 p95/max 与 fallback 计数。
4. 调参收尾：`advect_steps`、PSI 迭代、synoptic 开关。
5. 全程同步文档与 CSV 诊断。

---

## 6. 已落地改动（2026-07-07 本会话，已写入代码）

| 项 | 状态 | 改动文件 | 说明 |
|---|---|---|---|
| 【架构·弱机】 | ✅ 已落地 | `ocean_currents_job.gd` + `climate_profile.gd` | 见下 |
| 【保留】 | ✅ 已确认存在 | `map_baker.gd` / `main.gd` | `ocean_current_visual_active()` 开关 + `daily_wind_split_passes` 错峰，无需改动 |
| 【结构·最大】 | ⏳ PROBE 阶段设计（本环境无法构建/A-B，见 §7） | — | 根因已修正（见 §7.1） |
| 【调参·中】 | ⏳ 同 §7 | — | 瓶颈在 wrapper，非 C++ kernel |
| 【调参·大】 | ⛔ 评估为低价值，建议不做（见 §7.4） | — | PSI kernel 仅 ~0.4ms |

**【架构·弱机】具体改动**：
- `ocean_currents_job.gd`：新增 `_apply_device_period_scale()`（line 613），在两个初始化点调用（line 167 init、line 1265 `reconfigure`）。逻辑：移动端默认 ×2；或 `ClimateProfile.ocean_period_scale_weak > 1` 时按该倍率缩放 `wind_period_ticks` / `ocean_period_ticks` / `period_ticks`，并重建 `_slow_slice_policy`。仅改「多久跑一轮」，不动单阶段工作量；wind/ocean/upwelling 仍由 `ContinuousSlicedPolicy` 节奏更新，不会整体冻结（注释见函数体）。
- `climate_profile.gd`：在 `洋流频率` 组新增 `@export_range(1.0, 4.0, 0.5) var ocean_period_scale_weak: float = 1.0`（line ~503），弱 PC 可在 profile 设 2.0~3.0；桌面默认 1.0 不动。字段存在后 `_apply_device_period_scale` 的 `.get()` 不再触发缺失属性报错。

> 纯 GDScript / Resource 改动，无 native 行为变更，**无需**同步 `docs/cpp-dots-runtime/*`（native 文档只在 §7.3 真正落地时才需改）。

---

## 7. 待做 — ocean 物理阶段「按 cell 细切片」的**修正**设计（PROBE 阶段）

> ⚠ 本节是设计 + 草稿，标记 PROBE，**未在本环境构建/A-B**，禁止直接 ACTIVE。
> 阻塞前提（Skill 约束 #1/#3）：① 修 `bd_climate_*`/`bd_weather_*` 埋点 aliasing；② 本地重建 GDExtension；③ 跑 30+ tick PROBE 对比 fallback 计数与 p95/max，soak 证据齐全再 ACTIVE；④ fallback 路径保留。

### 7.1 关键修正：phys 阶段的耗时**不在 C++ cell kernel，而在 GDScript wrapper**

原 §2 的「让 `_physical_solve_step_one` 接受 cell 区间，把 1.5–1.9ms 压到 <1ms」基于一个**错误前提**——以为耗时全在 C++ 全图扫描。实测与代码核对后：

- `map_baker.gd:6752` 注释：PSI 快路径 STAGE **0.67ms** = C++ kernel 0.45 + boundary 0.16 + dict 0.06。但 profiled `phys_psi_init` 是 **1.76ms**。差额是 `_physical_solve_step_one` 的 **GDScript wrapper 开销**：`iter_cells` / `neighbor_indices_packed` 构建 / 25+ knob 字段打包成 Dictionary / wind 数组 pack / writeback。
- `run_psi_solver_pass` 的 C++ 内核（world_ext_physical.cpp:2387-2422，SOR Gauss-Seidel）16 次迭代仅 ~0.4ms；`run_wind_field_pass`（213）/`run_slp_field_pass`（1506）内核同量级。
- **结论**：仅把 C++ pass 按 cell 切片 → **不会**把 1.76ms 压到 <1ms，因为 wrapper 每 tick 仍扫全 cell、仍重建 knob dict。真正的杠杆是**削减 wrapper 开销**（见 §7.5），而不是切 kernel。

### 7.2 另一个被遗漏的事实：phys pass 当前**根本不接受 cell 区间**

`start_idx/end_idx` knob 只存在于像素光栅 `run_ocean_field_rasterize_full`（world_ext_physical.cpp:861-872），**不存在于** `run_physical_solve_pass`（1223，SLP→wind→PSI→upwelling 单体链）、`run_slp_field_pass`（1506）、`run_wind_field_pass`（213）、`run_psi_solver_pass`（2062）。所以「按 cell 细切片」需要先**给这四个 pass 加 cell-range 入参 + 持久化中间状态**，不是简单接线。

每个阶段要持久化、跨 tick 续算的中间状态：

| 阶段 | 当前形态 | 切片障碍 | 需持久化状态 |
|---|---|---|---|
| SLP | 逐点算 `slp_out`（point-wise） | 输出数组须跨切片累积 | `slp_out[]`（传入/续填）|
| wind | Pass 0 **coast BFS 遍历全 cell** 算 `coast_dist`（339-390），再逐点算风 | coast BFS 必须整遍先跑完 | `coast_dist[]`（一次性预计算，置位后只读）+ 风场 slice 游标 |
| PSI | **原地** SOR 迭代（2387-2422），全 16 次迭代一次性 | 原地更新跨 cell 有序依赖；按 cell 切会破坏收敛 | `psi[]` 场 + 迭代游标 `psi_iter_cursor` + `psi_residual`（按迭代切片，每 tick 跑 K 次迭代）|
| upwelling | 依赖以上输出 | 须等 PSI 完成 | 无（末端）|

> ⚠ PSI 若按「cell 切片」会在单次迭代内破坏 Gauss-Seidel 的 in-place 依赖；**正确切法是按迭代切片**（每 tick 跑 K 次完整 cell 扫描），但这是 K× wrapper 调用，反而更贵（见 §7.1）。因此 PSI 段**不应切 cell**，.optimization 应放在 wrapper。

### 7.3 草稿改动（PROBE 用，未经构建/A-B）

1. **C++ 侧**（world_ext_physical.cpp）：
   - `run_slp_field_pass` / `run_wind_field_pass` / `run_psi_solver_pass` 增加 `start_idx/end_idx` knob 读取（照搬 raster 的 866-872 写法），主循环改为 `[start_idx, end_idx)`。
   - `run_wind_field_pass`：把 coast BFS（339-390）抽成独立可调用入口 `run_wind_coast_bfs()`，由 `_physical_solve_step_one` 在该轮 WIND 切片前一次性调用并缓存 `coast_dist` 到 slot；WIND 切片只读。
   - `run_psi_solver_pass`：增加 `psi_warm`（传入上轮 `psi[]`）、`psi_iter_cursor`、`psi_residual` 出参，外层循环改为从 `psi_iter_cursor` 续算、达 `PSI_TOTAL_ITERS` 或 early-exit 残差才 FINALIZE。
   - `run_physical_solve_pass`（1223）：拆成可分步调用的子阶段（或新增 `run_physical_solve_slice` 接受阶段游标 + cell 区间），跨 tick 续算，SLP→wind 交接靠持久化 `slp_out`。
2. **GDScript 侧**（map_baker.gd `_physical_solve_step_one`）：
   - 增加 `cell_start/cell_end` 参数与**阶段内游标**（`_phys_slice_cursor` 持久化在 baker/job），把 7-stage 状态机改成「每 tick 只推进一个 stage 的一个 cell 区间」。
   - **关键**：wrapper 的 knob Dictionary / `neighbor_indices_packed` / wind 数组 pack / writeback 必须**随 cell 区间缩减**，否则切片无效（见 §7.1）。

### 7.4 【调参·大】降 PSI 迭代 —— 评估为**低价值，建议不做**

- PSI 已由 profile 下发 `psi_total_iters: _PHYS_PSI_TOTAL_ITERS`（16）+ `psi_early_exit_mode:"perf"`（climate_profile.gd:368 默认）。C++ kernel 仅 ~0.4ms（§7.1）。
- 再降迭代对 1.76ms 整段几乎无影响——瓶颈在 wrapper，不在 kernel。降迭代还会牺牲收敛精度（洋流/热传输场漂移），**得不偿失**。
- 若坚持作为 fallback 微旋钮：仅 `_PHYS_PSI_TOTAL_ITERS` 16→12，**须 PROBE 残差漂移 ≤ 1e-5**。但优先级远低于 §7.5 的 wrapper 削减。

### 7.5 真正的最大杠杆（替代原【结构·最大】/【调参·中】的 cell 切片）：**削减 GDScript wrapper 开销**

既然耗时在 `_physical_solve_step_one` 的 wrapper，正向优化应针对它：
1. ✅ **knob Dictionary 跨 stage 复用**：**已实现（2026-07-07，`map_baker.gd`）**。新增 `_phys_ensure_knob_cache(map,hex_size,bounds,profile,cfg)`，把 SLP/WIND/PSI/UPWELLING 四个 stage 的**常量字段**预建成 base dict（按 `map+profile+hex_size` 失效），每调用只 `base.duplicate()` 一次 + 覆盖少量变化字段（`season_phase`/`sim_day`/`world_seed`/`prev_slp_arr`/`wind_*` 数组）。省去原先每 stage 重建 27/22/25/7 字段 Dictionary（含 7 次 profile 属性读取 + 多次 `int()` 枚举转换）。
2. ❌ **`neighbor_indices_packed` 缓存**：**经代码核实无需做**。`map_data.gd:341` 即 `return _neighbor_indices`，本就是 O(1) 返回缓存成员；`iter_cells()`(336)、`soa_size()`(438) 同理。每 stage 调用零成本，原「每 tick 重建」判断是误判。
3. ✅ **writeback 走直接 slot 写入**：已存在。`published_to_slot=true` 时 C++ 直写 slot + flush，GDScript 跳过 2400-loop writeback（`map_baker.gd:6750` 注释：fast path 15ms→0.67ms）；fallback 路径保留兼容旧 DLL。未改（已最优）。
4. ⏳ **`daily_wind_prepass`（1.57ms）同理**：其瓶颈待 PROBE 确认是否在 wrapper；若同因，按 1 的 base-dict 模式削。属独立 job，留作下一步。

> 改动性质：纯 GDScript 成员缓存 + 调用点重构，**零接口变更、无需重建 DLL**，fallback 路径完全保留。需在你本地构建后跑 30+ tick PROBE，对比 `phys_psi_init`/`phys_wind`/`phys_slp`/`daily_wind_prepass` 的 p95/max 与 fallback 计数，soak 证据齐全再视作 ACTIVE。建议作为独立 PR，先于 §7.3 的 C++ cell-range 重构。

#### 7.5.1 A/B 实测验证（2026-07-07，222750.csv vs 215611.csv）

本环境虽无构建链，但用户提供了改动后的性能数据，可作 A/B（215611 = 改之前基线，222750 = 改之后对照；均为桌面捕获，period-scale 默认 no-op）：

- **目标作业 ocean_currents 各阶段均值**：phys_psi_init 2.211→2.193(-0.8%)、phys_wind 2.029→1.992(-1.8%)、phys_slp 1.828→1.771(-3.1%)、daily_wind_prepass 1.666→1.627(-2.3%)、phys_upwelling 0.649→0.619(-4.6%)；作业均摊 1.158→1.132ms（-2.2%）。
- **对照组 native_daily_sim（未改动）各阶段**：波动 **-10.4%~+7.5%**（ocean_land -10.4%、ocean_water -8.2%、weather +7.5%）；作业均摊 1.833→1.777ms（-3.1%）。
- **判定**：优化作业的 -0~4.6% 完全落在**未改对照的 run-to-run 噪声带**内 → **wrapper 削减无可归因实测收益**。改动安全、无回归，但几乎不省钱。
- **根因印证**：瓶颈确为 C++ kernel + GDExtension 边界 marshaling 的固定成本（见 §7.1），knob 字典缓存只削掉 μs 级一层，被噪声淹没。继续在 GDScript wrapper 上做文章收益边际；真要压 ocean 阶段必须走 §7.3 的 C++ cell-range 重构（或削减 C++ 内核）。
- 报告：`tmp/perf_report3_ab.html`，数据：`tmp/perf_analysis2b.json`（基线）/ `tmp/perf_analysis3.json`（对照）。

### 7.6 验证缺口（本环境已知条件）

- ⛔ 无法重建 GDExtension（本环境无 scons/编译器构建链路验证）；无法跑 Godot headless PROBE/A-B。
- ⛔ 未修 `bd_climate_*`/`bd_weather_*` aliasing（Skill 阻塞项 #1）；但本文切片级 `j_native_daily_sim_*` / `j_ocean_currents_*` 数据独立可靠。
- ✅ 因此 §7.3 / §7.5 只作为**后续 PR 的审计起点**，需在你本地构建后跑 30+ tick PROBE，对比 fallback 计数与 p95/max，soak 证据齐全再 ACTIVE；fallback 路径保留。
- 📌 若 §7.3 真落地，必须同 PR 更新 `docs/cpp-dots-runtime/{computation-pipelines,scheduling-and-job-graph,performance-diagnostics-playbook}.md`（stage 名、切片行为、budget、report 字段），并保持 stage 名稳定（Skill 约束 #4/#5）。

## 8. 新目标：`dynamic_visual_atlas_upload` 暴涨（2026-07-07 222750.csv 发现）

A/B 中浮现的、与本次 wrapper 优化无关但值得下一刀的常驻负载：

- **变化**：占比 4.9%→**11.2%**、均摊 0.173→**0.421ms/帧**、运行次数 343→**737**（约 2.4×）。已跃居第 3 大作业（仅次于 native_daily_sim / ocean_currents）。
- **性质**：渲染图集上传作业（非 sim 作业），与 `_physical_solve_step_one` / period-scale 无关。可能与移动端 rebake 跳过（`main.gd` 的 `non_sus` 22ms→8ms 路径）在不同设备档位下的频率/分片策略有关，或本轮捕获的地图/视觉配置使其更频繁触发。
- **下一步（待用户确认方向）**：
  1. 定位其触发节奏（`_configure` / period 策略），确认 2.4× 增长是配置差异还是回归；
  2. 若频率可降：错峰或拉长上传周期（同 ocean period-scale 思路）；
  3. 若单帧偏重：看是否能分片上传（subslice）而非整图集一次上传。
- ⚠️ 本环境只能从 CSV 看到它涨了，无法定位触发逻辑——需读对应 job/renderer 源码或用户提供更细的阶段埋点。

## 7.7 具体实施方案（用户「做 1/2/3」——逐函数级施工图，2026-07-08）

> 基于当读 `world_ext_physical.cpp` / `world_ext.h` / `map_baker.gd` 与三份 cpp-dots-runtime 文档。
> 本环境**无法 rebuild DLL / 跑 headless PROBE**，故只给设计；落地须用户在本地构建后验收（§7.6）。
> **关键修正（当读代码后）**：SLP 的 Pass A/B 已是 `pk::parallel_for_range` range-lambda（1506 内 line 1782/1885），PSI 在 GDScript 已拆 INIT/ITERS/FINALIZE 且 ITERS 用 `_PER_STEP` 推进（map_baker.gd:541/6894）。所以**切片主要是"给已有 range 结构加 `[start,end)` 边界 + 落地游标"，不是重写 kernel**。

### 7.7.1 Item 1 — 砍每调用固定开销（C++，最高确定性、最低风险，应最先做）
**为什么是主线索**：phys 阶段尖峰 ~1.3ms 是**每调用固定成本**（slot id 解析 + is_water_lut 重建 + neighbor_indices 数组 marshaling），cell-range 削不动它。PSI kernel 仅 0.4ms、UPWELLING 0.65ms——固定开销砍掉后这俩单 call 即 <1ms，无需 cell-range。

**改 `world_ext.h`（约 1914 `_psi_*` 成员旁）新增成员**：
- `int _phys_sid_pos_x/pos_y/terrain/landform/wind_x/wind_y/wind_spd/slp/temp/temp_an/ice/ocx/ocy/upwelling/psi_prev;`（对应四个 pass 当前各自 `component_id(StringName("cell_*"))` 的解析结果）
- `bool _phys_sid_valid=false; uint64_t _phys_sid_fp=0;`
- `uint8_t _phys_is_water_lut[256]; bool _phys_is_water_valid=false; uint64_t _phys_is_water_fp=0;`
- `std::vector<int32_t> _phys_neighbor_indices; bool _phys_nb_valid=false; uint64_t _phys_nb_fp=0;`

**新增 helper `_phys_resolve_static(int n_cells, const PackedInt32Array& nb, const PackedByteArray& water_ids)`**（仿 PSI 指纹法，line 2228-2277，不挂 `_bound` 钩子、靠指纹失效）：
- 计算 `fp = FNV(n_cells, water_ids, nb)`；若 `!_phys_sid_valid || fp != _phys_sid_fp` 则一次性 `component_id(StringName(...))` 解析全部 slot id、填 `_phys_is_water_lut`、拷 `_phys_neighbor_indices`，置 valid。
- 四个 leaf pass 顶部调用它，随后用 `_phys_sid_*` / `_phys_is_water_lut` / `_phys_neighbor_indices` 替换原 `component_id(StringName(...))`、`is_water_lut[256]` 栈重建、`knobs["neighbor_indices"]`。
- 具体替换点：
  - `run_slp_field_pass`(1506)：slot-id 1605-1621、is_water_lut 1624-1625、nb_arr 1592。
  - `run_wind_field_pass`(213)：slot-id 228-239、is_water_lut 299-304、nb_arr 291。
  - `run_psi_solver_pass`(2062)：slot-id 2163-2178、is_water_lut 2180-2185、nb_arr 2152。
  - `run_physical_circulation_pass`(1333)：slot-id 1375-1384、is_water_lut 1401-1406、nb_arr 1370。
- **零接口变更**：不加 knob、不改 stage 名、fallback 路径（缺 key 仍 `fail()`）不变。风险：低。

### 7.7.2 Item 2 — cell-range 切片（C++ + GDScript，WIND/SLP 必需，PSI/UPWELLING 可选）
**C++ four leaf pass 通用模式**（参照光栅 line 866-872 的 clamp 模板）：
```
int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
if (start_idx<0) start_idx=0; if (end_idx>n_cells) end_idx=n_cells; if (start_idx>end_idx) start_idx=end_idx;
```
主循环 `for i in [0,n_cells)` → `for i in [start_idx,end_idx)`（PSI 用 water 域 `start_k/end_k` over `n_water`，其迭代循环在 2392）。

**WIND（213）拦路点 — coast BFS 抽出**：Pass 0 + Pass 0b（338-394、396+）每调用重建 `coast_dist`/`sea_dist` 全图 vector，是全局状态。新增 `_phys_ensure_wind_coast(knobs)`（指纹 TR+water_ids+NB，同 PSI 套路）缓存进成员；`run_wind_field_pass` 改读缓存数组，per-cell 风场体（依赖完整 slp_arr + 完整 coast_dist，无扩散）直接可切片、无需 halo。

**SLP（1506）— 已有 range-lambda，加边界 + 末期归约**：
- Pass A（1782 `slp_passA_range`）、Pass B（1885 lambda）已是 `[rb,re)`；把 `n_cells` 换成 `end_idx`、起始 `0` 换成 `start_idx` 即可。
- **recenter/p95（1907-1929）、response-rate 融合（1935-1941）、slp_out 打包 + slot 发布（1962-1975）是全局归约/整图写**——必须"只跑一次"。用文档既定 idiom（`scheduling-and-job-graph.md:475` `start_idx==0` 触发一轮一次工作）：recenter/p95/融合/发布只在 `end_idx==n_cells`（末切片）执行；中间切片只写 `slp_buf` 对应区间。

**PSI（2062）— 迭代域已是 water 子集，最干净**：
- 迭代循环 `for k in [start_k,end_k)`（2392）。
- **finalize（grad psi→ocean_current+thermohaline+clamp，2424+）当前每次调用都跑**——加守卫 `end_k == n_water` 才跑；中间切片只更新 `cell_ocean_psi` 工作缓冲（warm-start 已读它，line 2213，跨 tick 天然持久）。
- curl/τ 预计算（迭代前 Pass）是 per-water-cell、依赖完整 wind；首切片（`start_k==0`）算一次缓存进成员，后续切片复用。

**UPWELLING（1333）**：per-cell 独立，加 `[start_idx,end_idx)` 即可；is_water_lut 已走 Item 1 缓存。

**GDScript `_physical_solve_step_one`（map_baker.gd）— 落地 stage 内 cell 游标**：
- 新增成员 `_phys_cell_cursor: int = 0`。
- SLP/WIND/UPWELLING 三 stage（当前"一次全图 call → 直接 `_phys_stage = 下一阶段`"）改为：
  - 估算 `cells_per_tick = max(1, int(ceil(n_cells * SLICE_BUDGET_MS / stage_full_ms_est)))`，新增常量 `SLICE_BUDGET_MS = 0.8`（弱机可经 profile 调小）。
  - 调用 C++ pass 传 `start_idx=_phys_cell_cursor, end_idx=min(cursor+cells_per_tick, n_cells)`；推进 cursor；`if cursor >= n_cells: 本 stage 完成 → _phys_cell_cursor=0 → _phys_stage=下一阶段`。
  - 每个 solve 的总 tick 数会变多（每 stage K 切片 × 4 stage）。须确保 `ocean_period_ticks` / `slice_count` 容量足够（PROBE 调）；否则按 §7.4 拉大 period。
- PSI 三 stage 已迭代切片：PSI_INIT 加 `start_k/end_k` 即可（UNSOPTIC/τ 首切片算）；PSI_ITERS 已有 `_PER_STEP`，可并行加 cell-range 或保持迭代切片（二选一，建议先做迭代切片已够，cell-range 作保险）。
- **顺序约束不变**：WIND 需完整 slp（SLP 全切片完才进 WIND）、PSI 需完整 wind——现有 stage 转移已保证，cell-range 仅在 stage 内、cursor 每 stage 归零。
- **stage 名稳定**（phys_slp/phys_wind/phys_psi_init/...，map_baker.gd:5962-5968）：不改，只把"一次调用"变"游标驱动多次调用"，对外仍是四个 stage。

### 7.7.3 Item 3 — 同步三份 cpp-dots-runtime 文档（同 PR）
- **scheduling-and-job-graph.md**：
  - `ocean_currents` 行（101）补一句"物理 stage 现在**内部**按 cell 区间切片（不止 daily_wind prepass），stage 名不变"。
  - Daily Wind Cadence 段（512-554）补 `phys_*` cell cursor 说明与 `start_idx==0`/末切片归约 idiom。
  - "长 pass 要拆 stage 或 cell/pixel range，不要依赖 scheduler 抢占"（457）下补 ocean physical stage 已落地的注记。
- **performance-diagnostics-playbook.md**：
  - ocean_currents PSI 段（177-195）说明 `phys_psi_init` 等现指**单切片（子区间）**成本，一轮 solve 跨多 tick。
  - 字段字典（339-367）新增 `phys_slp_cell_cursor` / `phys_wind_cell_cursor` / `phys_psi_cell_cursor`（末切片 `==n_cells`），并注明其用于确认切片推进。
- **computation-pipelines.md**：ocean physical pipeline 的 stage 列表更新为"每 stage 内部 cell-range 切片"，强调 stage 名稳定、fallback 路径不变。

### 7.7.4 验收（用户本地，本环境做不了）
1. rebuild DLL；headless 跑 30+ tick PROBE。
2. **bit-equal**：切片开启 vs 关闭，最终 `cell_ocean_current_*` / `cell_slp` / `cell_wind_*` 场逐位一致（用现有 `tmp_native_batch_bitequal_test.gd` 思路或 ocean 场 diff 脚本）。
3. `fallback` 计数恒为 0（任何 slice 不得 `fail()`）。
4. 每切片 p95/max < 1ms（Item 1 先把 PSI/UPWELLING 压到线；Item 2 把 WIND/SLP 压到线）。
5. soak：连续多轮 solve 无轨迹漂移（参照文档"有界、确定性轨迹漂移"约束，line 122）。
6. 文档三份同 PR 提交，stage 名不变（Skill #4/#5）。

### 7.7.5 优先级与风险小结
- **Item 1 先做**（确定、低风险、零接口变更）；很可能单独把 PSI+UPWELLING 压到 <1ms。
- **Item 2 再做**（中风险、需 rebuild+PROBE）：WIND/SLP 必需，PSI/UPWELLING 可选。
- **Item 3 随 Item 2 同 PR**（Skill 强制文档同步）。
- 全程 fallback 路径保留，未达 bit-equal/零 fallback 前不得 ACTIVE（§7.6）。
