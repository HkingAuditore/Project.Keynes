# Phase B — fronts archetype 化 / Z-lock 验收报告

> 配套 plan：`dots-total-cpp` Phase B（fronts archetype 池化 + cyclone 突刺定位 + SIMD ON + enum_atlas 退役）

## 决策上下文

Phase A.1 fronts SoA zero-copy 已落地（earth_like.tres `use_gdext_fronts_soa = true`）。
当时方案设计阶段提出过两个分支：

- **X1（archetype 化）**：把 `_unpack_summary_soa_to_fronts` 内的 N 次 `WeatherFront.new()` 也一并干掉，GDScript 侧改为 PackedFrontView 按 idx 取列
- **Z（保留 GDScript 对象层）**：N 次 `new()` 留着，因为 SoA marshalling 已经从 ~17×N Variant entry 砍到 ~24 PackedArray ref，对象构造成本相对 marshalling 已是次要

Z 锁死的判据：**`_unpack_summary_soa_to_fronts` 每 tick wall-clock p95 < 100μs**。
若 p95 跨过 100μs → 推翻 Z 回 X1（archetype 化优先级提升）。

## 实测遥测（B.1）

### 插桩点

`scripts/weather/weather_system.gd:_build_fronts_from_rc`（line ~1167-1190），编辑器模式下包夹 `_unpack_summary_soa_to_fronts(soa)` 调用：

- ring buffer 容量 = 100 样本
- 每满 100 tick print 一次 `mean / p50 / p95`，然后归零再采下一窗口
- gate：`OS.has_feature("editor")` + `use_gdext_fronts_soa` 已生效
- 仅遥测，不改变热路径语义

### 验收门槛

| 指标 | 阈值 | 触发动作 |
| --- | --- | --- |
| p95 unpack μs/tick | < 100 | **Z 锁死**，Phase B.1 完成 |
| p95 unpack μs/tick | ≥ 100 | 推翻 Z 回 X1，启动 fronts archetype 化 |

### 实测结果（待填）

| 日期 | 场景（map_size / front_n） | 窗口数 | mean μs | p50 μs | p95 μs | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| TBD | TBD | TBD | TBD | TBD | TBD | TBD |

数据采集方式：dots_soak_ab_runner `fronts_soa_on` 矩阵跑 ≥ 100 tick，console 抓 `[weather/summary] fronts_soa unpack telemetry` 行。

## B.2 cyclone 突刺细粒度遥测（已就绪 — 等数据）

`gdext/src/world_ext.cpp:cyclone_wake_step` 已 by-ref 写回 6 字段 + pool_size：
`phase1_decay_ms / phase2_inject_ms / n_decayed / n_evicted / n_replaced / n_injected / pool_size`

`scripts/geography/map_generator.gd:6375-6419` SLOW dump 触发器：
- 阈值 `weather_tick_ms ≥ 5ms` 或 `cyclone_ms ≥ 3ms`（比原 plan 的 sus_sim>100ms 激进 20-30×）
- cyclone ≥ 0.5ms 时附加第二行 7 字段子段
- 节流 30 fast tick

待真实突刺出现自动 dump，定位 193ms 尖峰是衰减循环 vs 注入循环、evict vs replace。

## B.3 SIMD 三 flag（撤销）

经 grounding 揭示 `data/world/earth_like.tres` line 16-18 已 overlay 为 true，dispatch 实际已是 thread > simd > scalar 路径。
`climate_profile.gd` 中 default=false 仅 schema 兜底，运行时 runtime 早已是 SIMD ON。
故 B.3 验收撤销，ROI 投入 B.2 突刺数据采集。

## B.4 enum_atlas 退役（待办）

依赖：72h soak 0 触发 → 删 GDScript fallback → `dots_completion_gate.gd` enum_atlas_pack `required = true`。
依赖关系已从 B.3 改为直接依赖 B.2（B.3 撤销）。
