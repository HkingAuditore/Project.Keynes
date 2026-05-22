# Phase C.1：System Schedule Graph 验收报告

> plan：`docs/plans/dots-total-cpp/`（plan_create artifact）
> 工件：`gdext/src/system_schedule.h` / `system_schedule.cpp` / `world_ext.{h,cpp}` 改动 / map_generator/climate_profile/feature_flags/dots_completion_gate/dots_soak_ab_runner

## 背景

把 `DCWorldExt::run_native_daily_tick` 内部 line 960-1063 的 11 段手写
`if (bundle.has("<X>_knobs")) { ms = run_<X>_pass(...); breakdown[...]=...; any_pass_ran=true; }`
模板代码抽象为：

1. **静态调度图**：`pk::SystemNode SCHEDULE_GRAPH[]`（11 项，编译期固定，顺序与原 if-chain 严格一致）
2. **统一 dispatch loop**：`pk::dispatch_system_schedule(self, bundle, tick_knobs, breakdown, ...)`，遍历表 + dispatch 到节点成员函数指针 `exec_fn`
3. **双轨入口**：bundle 注入 `use_system_schedule: bool` 决定走新 dispatch 还是原 if-chain

算法、读写字段、breakdown 字段语义、副作用（`_native_fronts_snapshot` 写入、`stage_b` 4 个 breakdown 回填、`succession_*` 透传）零改动 → 理论 bit-equal。

## 11 个节点表

| # | name | bundle_key | fail_stage | exec_fn | 主要 breakdown 写入 |
|---|---|---|---|---|---|
| 1 | climate_pass_a | climate_pass_a_struct | climate_pass_a | `_exec_node_climate_pass_a` | pass_a_ms += climate_ms |
| 2 | ocean_water | ocean_water_knobs | ocean_water | `_exec_node_ocean_water` | ocean_water_ms += ocean_ms |
| 3 | ocean_land | ocean_land_knobs | ocean_land | `_exec_node_ocean_land` | ocean_land_ms += ocean_ms |
| 4 | climate_pass_b | climate_pass_b_knobs | climate_pass_b | `_exec_node_climate_pass_b` | pass_b_ms += climate_ms |
| 5 | sea_ice | sea_ice_knobs | sea_ice | `_exec_node_sea_ice` | sea_ice_ms += climate_ms |
| 6 | transpiration | transpiration_knobs | transpiration | `_exec_node_transpiration` | transp_ms += climate_ms |
| 7 | albedo | albedo_knobs | albedo | `_exec_node_albedo` | albedo_ms += stage_b_ms |
| 8 | vegetation_dynamics | vegetation_dynamics_knobs | vegetation_dynamics | `_exec_node_vegetation_dynamics` | veg_dyn_ms += stage_b_ms |
| 9 | climate_feedback | climate_feedback_knobs | climate_feedback | `_exec_node_climate_feedback` | feedback_ms += stage_b_ms |
| 10 | stage_b | stage_b_knobs | stage_b | `_exec_node_stage_b` | stage_b_ms +=；回填 albedo/veg_dyn/feedback_ms + succession_* |
| 11 | weather | weather_knobs | weather (动态 reason) | `_exec_node_weather` | weather_ms = total_ms + copy_dict_into + _native_fronts_snapshot |

## 验收门槛

| 项 | 目标 |
|---|---|
| breakdown.pass_a_ms / pass_b_ms / ocean_water_ms / ocean_land_ms / sea_ice_ms / transp_ms / albedo_ms / veg_dyn_ms / feedback_ms / weather_ms / stage_b_ms / climate_ms / ocean_ms / total_ms | epsilon ≤ 1e-5 |
| breakdown.succession_indices / succession_to_veg / stat_succession_count | 完全相等 |
| out["fronts"] | 数量相等 + 字段 epsilon ≤ 1e-5 |
| out["fronts_changed"] / out["rc"] / out["fail_stage"] | 完全相等 |
| elapsed_ms（total_ms p50 / p95） | B ≤ A * 1.02（理论无差异） |
| 72h soak | 0 crash / 0 NaN / atlas 0 错位 |

## 跑批方法

GDScript shell（编辑器或 dots_soak_ab_runner 入口）：

```gdscript
DotsSoakAbRunner.start_system_schedule_batch(main_node, PackedInt32Array([30, 1000]))
```

矩阵：
- A（sched_off）：`use_gdext_system_schedule = false` → C++ 走原 11 段 if-chain
- B（sched_on） ：`use_gdext_system_schedule = true`  → C++ 走 dispatch_system_schedule

A/B SAME_SOURCE 同源 30 + 1000 tick 两轮。

## 实测数据（待填）

### 30-tick 烟测（编辑器）

| 指标 | A (sched_off) | B (sched_on) | diff |
|---|---|---|---|
| breakdown.total_ms p50 | TBD | TBD | TBD |
| breakdown.weather_ms p50 | TBD | TBD | TBD |
| breakdown.climate_ms p50 | TBD | TBD | TBD |
| breakdown.stage_b_ms p50 | TBD | TBD | TBD |
| fronts diff | TBD | TBD | epsilon |
| succession 字段 | TBD | TBD | 必须 0 |

### 1000-tick 验收（生产 release build）

| 指标 | A (sched_off) | B (sched_on) | diff | 判定 |
|---|---|---|---|---|
| breakdown.total_ms p50 | TBD | TBD | TBD | TBD |
| breakdown.total_ms p95 | TBD | TBD | TBD | TBD |
| 所有 ms 字段 max diff | — | — | TBD | ≤ 1e-5？ |
| fronts max diff | — | — | TBD | ≤ 1e-5？ |
| succession diff count | — | — | TBD | = 0？ |

## 风险与回滚

- `use_gdext_system_schedule` 默认 false → 默认走原 if-chain，**零风险默认值**
- 任一节点 ms<0 / weather rc!=0 → dispatch loop 立即短路 + `finish_with_failure`，与原 if-chain 同语义
- 如需立即回滚：`ClimateProfile.use_gdext_system_schedule = false`，立刻生效，不需重建 .dll

## 收益与后续

- 直接收益：**0**（只是数据驱动重构，不动算法）
- 关键收益：**C.3 job_graph 拓扑分组的事实基础**
  - C.3 在 SystemNode 加 `uint64_t in_mask / out_mask`（component 粒度）
  - 同 mask 互不冲突节点 → 并行；冲突 → 串行
  - "加新 pass = 在 SCHEDULE_GRAPH 加一行"，自动并入调度

## 状态

- [x] C++ 三件套：system_schedule.h / .cpp / world_ext.h 11 个 _exec_node_ 声明 / world_ext.cpp 双轨 if 切换
- [x] GDScript：climate_profile use_gdext_system_schedule + feature_flags + dots_completion_gate + map_generator bundle 注入
- [x] dots_soak_ab_runner start_system_schedule_batch
- [ ] .dll 重建（scons platform=windows target=template_release dev_build=no -j8）
- [ ] 30-tick 烟测 A/B（填本文档实测数据）
- [ ] 1000-tick 验收 A/B（填本文档实测数据）
- [ ] 72h soak 0 crash 通过 → `use_gdext_system_schedule = true` 上线
