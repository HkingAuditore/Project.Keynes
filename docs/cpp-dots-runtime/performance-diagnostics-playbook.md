# Performance Diagnostics Playbook

本文用于解释运行日志，并给出排查 C++/DOTS 路径是否符合预期的流程。目标不是只看“耗时高不高”，而是定位高耗时来自 C++ compute、GDScript fallback、slot sync、flush、dirty mask、GPU upload，还是统计窗口里的旧 spike。

## 先看三层日志

### 1. Fast tick warn

示例：

```text
[fast tick WARN] #247 sus=2.83 render=0.96 ui=0.00 total=4ms skip_day=false
    sus_window p95=17.82ms max=28.54ms over1ms=189 largest=ocean_currents/ocean_pixel_slice/pixels_49536_50048 path=gdext_raster 1.07ms
```

含义：

- `sus` 是当前 tick simulation scheduler 耗时。
- `render` / `ui` 是渲染和 UI。
- `sus_window` 是滑动窗口统计，不只代表当前 tick。
- `largest` 是窗口内最大 slice 的来源。

判断：

- 当前 tick `sus=2.83ms` 不高，但窗口 p95/max 高，说明过去窗口内有 spike。
- `largest path=gdext_raster 1.07ms` 表示最大 slice 来自 C++ raster，并不代表 fallback。

### 2. Per-job breakdown

示例：

```text
refresh_climate_daily ran=0.59ms slices=1 progress=0.25
    A=1.6 B=0.2 ocean=0.1 sea_ice=0.0 ice_bake=0.0 transp=0.0 cells=2400 pass=ocean_water partial=true dirty=1.00 visited=1.00 path=full
    climate path=data_core dc=data_core
    ocean_water gdext flag=true runs=1 fallbacks=0 avg_native=0.09ms
```

含义：

- 当前 job 这次 slice 只用了 0.59ms。
- `A=1.6` 等字段可能是 round 聚合或历史 stage timing，不一定等于当前 slice wall time。
- `ocean_water gdext flag=true runs=1 fallbacks=0` 是 C++ 路径成功信号。

### 3. `[SUS-cpp]` window summary

示例：

```text
[SUS-cpp] last 30 ticks: refresh_climate_daily ran=30 avg=2.27ms p95=18.08ms max=18.71ms slices=30
[SUS-cpp] budget last 270 ticks: total_p95=17.82ms max=28.54ms over_1ms=203 largest=refresh_climate_daily/transp/apply path=gdscript_sliced 28.49ms
```

含义：

- `last 30 ticks` 是按 job 聚合。
- `budget last 270 ticks` 是按整个 SUS tick 聚合。
- `largest` 可能保留旧 spike，不能单独证明当前仍走 GDScript。

## `path=` 字段解释

| path | 含义 | 是否异常 |
| --- | --- | --- |
| `gdext` | C++ GDExtension pass 成功。 | 正常。 |
| `gdext_raster` | C++ raster/pixel slice。 | 正常，常见于 ocean/atlas。 |
| `data_core` | DataCore 路径，可能包含 C++ pass 和 GDScript orchestration。 | 不等于 fallback。 |
| `full` | 当前 wrapper 走 full map path。 | 需结合 native breakdown。 |
| `cpp_cached_patch` | atlas/patch 使用 C++ cached patch。 | 正常。 |
| `gdscript_sliced` | GDScript sliced fallback/apply。 | 如果长期出现为 largest，需要继续迁移或排查 native gate。 |
| `gdscript` | 纯 GDScript fallback 或 report 默认值。 | 需看 fallback reason 和 stage 时机。 |
| `none` / 空 | job 无实际 work 或 report 未填。 | 对 no-op 正常，对 hot pass 不应长期出现。 |

原则：`path` 是该 report 对应 slice/stage 的标签，不是整个系统永久状态。

## `published_to_slot` / `published=true`

看到 SLP/PSI 等日志中：

```text
published=true
published_to_slot=true
```

说明：

- C++ pass 已写入对应 slot。
- 通常也已 flush 到 `MapData` 或提供了 C++ slot 权威输出。
- GDScript caller 可以跳过重复 array copy。

如果 `published=false`：

1. 看 `fallback_reason`。
2. 查 slot 是否存在、size 是否匹配。
3. 查 C++ pass 是否早退。
4. 查 caller 是否传入缺失 knobs。

`published=true` 是“C++ slot publish 生效”的强信号；此时不要只因为 `largest` 窗口里还有旧 `path=gdscript` 就判断当前失败。

## `psi_path=gdscript` 的早期阶段 caveat

`ocean_currents` 的 physical chain 是 stage machine。`psi_path` 在 PSI stage 真正执行前可能显示默认值或上一轮值：

```text
stage=slp->wind ... psi_path=gdscript
```

这不一定表示 PSI fallback。正确判断方法：

- 看后续 stage 是否进入 PSI。
- 看 `stage_psi_path` 是否变成 `gdext`。
- 看 `run_psi_solver_pass` 是否返回 `published_to_slot=true`。
- 看 ocean current x/y slots 是否被发布。

只有 PSI stage 执行后仍持续 `psi_path=gdscript`，并伴随 fallback reason，才说明 C++ PSI 未接管。

## Transpiration breakdown

示例：

```text
transp gdext wall=0.35 native=0.029 call=0.040 compute=0.016 apply=0.011 flush=0.002 refresh=0.000 sync=0.159 write=0.000 mark=0.000 integrity=0.000 dirty=...
```

字段解释：

| 字段 | 含义 |
| --- | --- |
| `wall` | GDScript caller 看到的总墙钟。 |
| `native` | C++ pass 内部总耗时。 |
| `call` | 跨 GDExtension 调用和返回封装成本。 |
| `compute` | C++ tight-loop 计算成本。 |
| `apply` | 应用结果到 slot/输出 buffer。 |
| `flush` | C++ slot flush 到 MapData。 |
| `refresh` | 调用前 `refresh_slots_from_map()`。 |
| `sync` | caller 侧同步、等待、snapshot 或其他 glue 成本。 |
| `write` | GDScript DataCore write API 成本。 |
| `mark` | dirty mark 成本。 |
| `integrity` | integrity diagnostics 成本。 |

判断：

- `compute` 很低但 `wall` 高：边界/同步问题。
- `native` 很低但 `largest=transp/apply path=gdscript_sliced`：多半是窗口旧 spike 或 fallback apply 仍偶发。
- `write/mark` 高：检查是否又走了单点 setter 或全图 dirty。
- `refresh/sync` 高：检查是否重复 `refresh_slots_from_map()` 或不必要 snapshot。

## `refresh_climate_daily` 高 p95 排查

流程：

1. 看 `largest` 指向哪个 substage：`pass_a`、`pass_b`、`ocean_water`、`wind_air`、`transp`。
2. 看当前 tick 的 detailed breakdown，而不是只看 window max。
3. 如果 `path=data_core`，确认是否有 native 子项，例如 `ocean_water gdext runs=... fallbacks=0`。
4. 如果出现 `native_or_gd`，查 caller 是否用同一字段同时承载 native/fallback timing。
5. 查 `fallback_reason` 或 stale DLL warning。
6. 查 `refresh_slots_from_map()` 是否在同一 round 多次重复。
7. 查 dirty mask 是否被全图标脏，导致 atlas upload 反过来吃预算。

判断标准：

- C++ compute 已经低于 1ms，但 p95 高，多半不是算法本体，而是 orchestration/sync/window spike。
- `ran=30` 且 `skipped` 少，说明调度没有饿死。
- `skipped[frame_budget_exhausted]` 多，说明其他 job 或单 slice 超预算抢走了窗口。

## Weather refresh 排查

重点字段：

```text
weather_tick=0.4 (adv=0.0 spawn=0.3 dist=0.1 cyc=0.0) field_bake=...
weather_job total=0.1 prelude=0.0 begin=0.0 run_slice=0.0 direct_a=0.0 commit=0.0 stage_b=0.0 sync=0.0 soak=0.0 unattributed=0.1
weather_commit inner=3.5 setup=0.0 loop=3.5 dc=0.0 conv=0.0 dist=0.1 summary=0.3 path=...
weather path=data_core_cells_only
```

判断：

- `weather_job total` 是 job wrapper 外层。
- `weather_commit inner` 是 commit 或 field/object unpack 内部。
- `path=data_core_cells_only` 表示 DataCore cell path，不代表 C++ field solve 失败。
- 如果 `loop` 高，查 commit loop 是否仍在对象层或 GDScript apply。
- 如果 `summary` 高，查 fronts summary/unpack。

## Atlas upload 排查

Enum atlas：

```text
enum_atlas_upload axis= path=cpp_cached_patch elapsed=0.01 patch=0.42 img=0.00 upload=1.39 dirty=1411px/6cells cache=true
```

判断：

- `patch` 高：CPU patch/cache 构建。
- `img` 高：Image 写入。
- `upload` 高：GPU texture update，不是 C++ compute。
- `dirty px/cells` 比值高：少量 cell 覆盖大像素区域，属于地图投影/atlas granularity。

Dynamic visual atlas：

- `skipped[frame_budget_exhausted]` 多表示上传滞后。
- 如果 simulation 正常，只是 visual atlas upload 被 skip，优先不要把它设 `must_run`，应优化 dirty/stride/upload。

## Daily wind diagnostics

When validating the physical wind cadence from tile-data CSV or fast-tick
samples, the expected daily C++ path is:

- `phys_wind_period_ticks=1`
- `phys_daily_wind_due=true`
- `phys_daily_wind_ran=true`
- `phys_daily_wind_path=gdext_daily_wind`
- `phys_sim_day` advances by one per recorded SUS daily tick
- `phys_daily_wind_delta_p95` is normally non-zero but should remain smooth
- `phys_ticks_per_slice` may be greater than 1; that describes the slow
  ocean/raster chain and should not prevent daily wind updates

If `phys_daily_wind_ran=false`, read `phys_daily_wind_fallback_reason` first.
Common causes are `physical_disabled`, `missing_world_ext`, `missing_cpp_method`,
or missing indexed map data. If `phys_daily_wind_path=gdext_daily_wind` but the
visual wind overlay looks stale, check the raster/atlas upload path separately:
the simulation authority is `cell_wind_x/y` and `cell_wind_speed`, while the BA
channels in the vector atlas are a visual copy.

## Stale DLL / method probe

典型症状：

- GDScript flag 已开，但 `has_method("run_xxx_pass")` false。
- C++ pass 返回旧 float stub 或参数数量不匹配。
- 日志 warning 提示 rebuild GDExtension。
- `path=gdscript` 但没有业务 fallback reason。

排查：

1. 搜 `_bind_methods()` 是否有 `ClassDB::bind_method(D_METHOD("run_xxx_pass"...))`。
2. 搜 `.gd` caller 的 `_validate_gdext_method_signature` 或 `has_method`。
3. 确认 editor/debug/release DLL 都是最新 build。
4. 重启 Godot，避免旧 DLL 仍被加载。

## Budget 问题排查

如果看到：

```text
skipped[frame_budget_exhausted=25]
```

按顺序判断：

1. 被 skip 的 job 是 simulation authority 还是 visual/upload？
2. 如果是 simulation authority，是否应该 `must_run=true` 或拆更细 slice？
3. 如果是 visual/upload，是否可接受滞后？
4. 哪个 `largest` 抢走预算？
5. 该 `largest` 是当前问题还是旧窗口 spike？
6. 是否有 single slice 不能被 scheduler 抢占，例如一次 C++ pass 太大？

## 常见误判

| 现象 | 容易误判 | 正确解释 |
| --- | --- | --- |
| `largest=... path=gdscript 28ms` | 当前仍全走 GDScript | 可能是窗口旧 spike；看当前 stage breakdown。 |
| `climate path=data_core` | 没走 C++ | DataCore 是上层路径，子 pass 可能已是 `gdext`。 |
| `psi_path=gdscript` | PSI C++ 失败 | 可能 PSI stage 尚未执行。 |
| `published=true` 但画面没变 | C++ 没写成功 | 可能 visual atlas/upload 滞后，或读的是另一个镜像。 |
| C++ `compute=0.02ms` 但 wall 高 | C++ 慢 | 多半是 refresh/flush/sync/write/dirty。 |
| `skipped` 多 | 计算错 | 可能只是 visual upload 被预算延后。 |
| `upload=1.5ms` | C++ patch 慢 | GPU/ImageTexture upload，不是 C++ kernel。 |

## 标准诊断流程

1. 复制完整 `[fast tick WARN]` 段，不要只贴 `largest` 一行。
2. 找 `sus_window largest`，定位 job/stage/substage/path。
3. 找同一 tick 的 per-job breakdown，确认当前 path。
4. 找 `[SUS-cpp] last N ticks`，看该 job 是否持续高 p95。
5. 找 `skipped[...]`，判断是否预算饿死。
6. 找 native breakdown，拆 compute/apply/flush/refresh/sync。
7. 找 `published_to_slot`，确认 C++ 输出是否发布。
8. 如果 path 是 GDScript，找 fallback reason、has_method、signature probe、stale DLL warning。
9. 如果 compute 低但 wall 高，查 DataCore write/dirty/atlas upload。
10. 最后才考虑改算法；多数 spike 先来自调度、同步或上传。

## 接受标准

一个 C++/DOTS 化计算链路基本符合预期，应满足：

- hot-loop report 显示 `path=gdext` / `gdext_raster` / 明确 native 子项。
- fallback count 为 0 或有明确可接受原因。
- C++ `compute/native` 低于目标预算。
- `published_to_slot=true` 的 pass 不再被 GDScript 重复全量 copy。
- `refresh_slots_from_map()` 每 round 次数可解释。
- atlas dirty 不因无变化 dense write 被全图标脏。
- `skipped[frame_budget_exhausted]` 不会长期饿死 simulation authority job。
