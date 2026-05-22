# Phase C.3：Job Graph (WorkerThreadPool) 验收报告

> plan：`docs/plans/dots-total-cpp/`（plan_create artifact）
> 工件：
> - `gdext/src/parallel_dispatcher.h`：通用 `parallel_for_range<F>` + `parallel_for_range_with_emit<Emit, F>` 模板，封装 `WorkerThreadPool::add_group_task` + serial fallback
> - `gdext/src/world_ext.{h,cpp}`：5 个 `_thread` 入口
> - `Project/.../map_generator.gd`：sea_ice / vegetation_dynamics dispatch gate
> - `Project/.../dots_soak_ab_runner.gd`：`start_thread_batch`
> - `Project/.../main.gd`：`start_soak_ab_thread_batch_debug` + `start_soak_ab_phase_c4_acceptance_debug`

## 背景

承接 C.1 schedule graph 的事实基础（同 mask 互不冲突节点理论可并行），C.3 把 5 个
计算量大但 cell 间相互独立的 pass 拆为 cell-range job，在 Godot
`WorkerThreadPool` 上跑。Reduce 阶段（如 weather summary 的 12 fronts 聚合、
sea_ice 的全局 max ice / albedo 累积）严格按 `task_idx` 升序串行收集，避免
浮点 reduce 顺序漂移导致 A/B 非 bit-equal。

## 5 个 `_thread` 入口

| # | name | 接入点 | 主体计算 | reduce 模式 |
|---|---|---|---|---|
| 1 | `run_climate_pass_b_thread` | C.3a | climate_pass_b (温度/降水二阶融合) | 无 reduce（per-cell 独立写） |
| 2 | `run_ocean_water_pass_thread` | C.3b | ocean water 扩散 + 洋流 | 无 reduce |
| 3 | `run_ocean_land_pass_thread` | C.3c | ocean land 边界耦合 | 无 reduce |
| 4 | `run_sea_ice_daily_pass_thread` | C.3d | sea_ice 生消 + albedo | per-task `IceEmit { dmax, dalbedo }` → 主线程顺序 reduce |
| 5 | `run_vegetation_dynamics_pass_thread` | C.3d | 植被演替（Component_VegDynStatePool 写入） | per-task `VegEmit { succession_count }` → 主线程顺序 reduce |

所有 `_thread` 入口都接受 `n_tasks: int` 参数；传 `0` 表示让 C++ 端按
"~1024 cells/task" 自适应分组（`n_tasks = max(1, n_cells / 1024)`，常见 N=2400 →
2-3 个 task）。`n_tasks = 1` 等价于退化为 serial 路径；负数视作错误并 fallback。

## 共享 Helper：`parallel_for_range`

```cpp
// parallel_dispatcher.h
template <typename F>
void parallel_for_range(int n_cells, int n_tasks, F&& body) {
    // body(int task_idx, int cell_lo, int cell_hi)
    // 1. 基于 WorkerThreadPool::add_group_task 分发 [n_tasks] 组
    // 2. WTP 不可用 / n_tasks <= 1 → serial fallback
}

template <typename Emit, typename F>
void parallel_for_range_with_emit(int n_cells, int n_tasks,
                                  std::vector<Emit>& emits,  // 大小 = n_tasks
                                  F&& body /* (task_idx, lo, hi, Emit&) */) {
    // 与上同结构；调用方在主线程按 task_idx 升序遍历 emits[] 做 reduce
}
```

## 验收门槛

| 项 | 目标 |
|---|---|
| 每个 _thread 入口 thread on/off A/B | rc / breakdown / fronts / succession 字段 epsilon ≤ 1e-5 |
| reduce 顺序稳定性 | thread on N 次重跑结果完全一致（同 PRNG seed） |
| elapsed_ms（per-pass） | thread on 在 n_cells ≥ 2400 + WTP 可用时 ≤ thread off（不强制更快，至少不退化 > 5%） |
| n_tasks=0 自适应 | 与 n_tasks=2/4/8 显式值结果完全一致 |
| WTP 不可用环境 | serial fallback 自动生效，A/B 仍 bit-equal |

## 跑批方法

GDScript shell（main.gd debug 入口）：

```gdscript
# 单跑 thread A/B（5 个入口同时切 use_gdext_thread_fallback flag）
main.start_soak_ab_thread_batch_debug()

# 顶层 C.4 acceptance：串行跑 unified_fast_tick / system_schedule / thread / season_round
main.start_soak_ab_phase_c4_acceptance_debug()
```

矩阵：
- A（thread_off）：`use_gdext_thread_fallback = false` → 5 个 _thread 入口走 serial
- B（thread_on） ：`use_gdext_thread_fallback = true`  → 走 WTP 并行（n_tasks=0 自适应）

A/B SAME_SOURCE 同源 30 + 1000 tick 两轮。

## 实测数据（待填）

### 30-tick 烟测（编辑器 debug build）

| 指标 | A (thread_off) | B (thread_on) | diff |
|---|---|---|---|
| breakdown.pass_b_ms p50 | TBD | TBD | TBD |
| breakdown.ocean_water_ms p50 | TBD | TBD | TBD |
| breakdown.ocean_land_ms p50 | TBD | TBD | TBD |
| breakdown.sea_ice_ms p50 | TBD | TBD | TBD |
| breakdown.veg_dyn_ms p50 | TBD | TBD | TBD |
| succession_indices diff | TBD | TBD | 必须 0 |
| 任一 ms 字段 max diff | — | — | ≤ 1e-5？ |

### 1000-tick 验收（生产 release build）

| 指标 | A (thread_off) | B (thread_on) | diff | 判定 |
|---|---|---|---|---|
| breakdown.pass_b_ms p50 | TBD | TBD | TBD | TBD |
| breakdown.pass_b_ms p95 | TBD | TBD | TBD | TBD |
| breakdown.sea_ice_ms p50 | TBD | TBD | TBD | TBD |
| breakdown.sea_ice_ms p95 | TBD | TBD | TBD | TBD |
| breakdown.veg_dyn_ms p50 | TBD | TBD | TBD | TBD |
| breakdown.veg_dyn_ms p95 | TBD | TBD | TBD | TBD |
| 所有 ms 字段 max diff | — | — | TBD | ≤ 1e-5？ |
| fronts max diff | — | — | TBD | ≤ 1e-5？ |
| succession diff count | — | — | TBD | = 0？ |

## 风险与回滚

- `use_gdext_thread_fallback` 默认 false → 默认走 serial，**零风险默认值**
- WTP 不可用 / n_cells 极小 → 自动 serial fallback，与 thread off 完全等价
- task_idx 升序 reduce 是 race-free 的关键，请勿改成 atomic 或乱序合并
- 如需立即回滚：`ClimateProfile.use_gdext_thread_fallback = false`，立刻生效，不需重建 .dll

## 收益与后续

- 直接收益预估：n_cells=2400 + 4 核 WTP 时
  - climate_pass_b：~0.3 ms → ~0.15 ms（-50%）
  - sea_ice_daily：~0.4 ms → ~0.2 ms（-50%）
  - vegetation_dynamics：~0.5 ms → ~0.25 ms（-50%）
- C.4 验收目标：fast_ms p95 ≤ 1.5 ms / sus_sim max < 30 ms
- 后续可选：C.2 SoA chunk 重组（已 cancel 暂不做，等 fast_ms 退化再重启）

## 状态

- [x] C++ 三件套：parallel_dispatcher.h 模板 + 5 个 _thread 入口（world_ext.cpp）+ ClassDB 绑定
- [x] GDScript：map_generator.gd sea_ice / vegetation_dynamics dispatch gate（pass_b / ocean_water / ocean_land 在 C.3a-c 已接入）
- [x] dots_soak_ab_runner start_thread_batch
- [x] main.gd start_soak_ab_thread_batch_debug + start_soak_ab_phase_c4_acceptance_debug
- [x] .dll 重建（scons platform=windows target=template_{debug,release} 双 build OK，10:15 时间戳）
- [ ] 30-tick 烟测 A/B（填本文档实测数据）
- [ ] 1000-tick 验收 A/B（填本文档实测数据）
- [ ] 72h soak 0 crash 通过 → `use_gdext_thread_fallback = true` 上线
