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
- 看 `phys_ocean_current_preclamp_p95/max` 与
  `phys_ocean_current_clamp_count/ratio`。如果 pre-clamp p95 长期高于
  `phys_ocean_current_max_magnitude` 且 clamp ratio 很高，说明强度被最终
  vector clamp 压平；优先调低 `ocean_psi_source_scale`，其次才是
  `ocean_current_scale`、热盐/密度权重或上限。不要先排查 CSV encoder。

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
| 日志 `total=13ms` 但 FPS 仅 18 | 模拟没拖累帧 | `_run_fast_tick` 末尾的 `_refresh_overlay_data` **不计入** `sus/render/ui`；overlay bake 可能独自吃掉 10ms+。详见下节。 |

## Overlay Bake Cost（debug 模式温度/天气图层卡顿）

**症状**：玩家切到温度 / 降水 / 湿度等 Debug Overlay 通道后，FPS 显著下降（实测从 60 降到 18）。但 `[fast tick WARN]` 报告中 `sus/render/ui` 三段加起来仍然只有 5-15ms，看似正常。

**原因**：`main.gd::_refresh_overlay_data` → `DataOverlayBaker.bake` 在 `_run_fast_tick` 末尾、`fast_ms` 计时**之后**才执行，整段开销**不被纳入** `sus/render/ui` 任何统计字段。它在主线程同步阻塞，直接影响 `_process` 帧率，但 SUS 日志对此一无所知。

历史问题点（debug-overlay-perf v1 之前）：

1. **每帧 `ImageTexture.create_from_image()`**：1080×574 RGBA8 = 2.4MB，触发 GPU 资源销毁 + VRAM 重分配，单次 ~5-15ms 同步阻塞。
2. **每帧 `PackedByteArray.resize(2,482,176)`**：GDScript GC 压力。
3. **`for i in range(620544): buf[i*4+3] = 0`**：62 万次解释字节赋值清 alpha。
4. **跳日帧也重 bake**：x20 倍速下每秒触发 20+ 次。

修复后（debug-overlay-perf v1，2026-06-12）：

- 在 `main.gd` 持久化 `_overlay_tex: ImageTexture` 与 `_overlay_buf: PackedByteArray`，传给 baker 复用。bake 内部用 `tex.update(img)` 代替 `create_from_image`；用 `buf.fill(0)` 代替 GDScript 循环清零。
- 引入 `_overlay_dirty` 标记：`_on_day_changed` 顶部置 true；fast tick 末尾仅在「`overlay_mode != NONE` AND 非跳日 AND dirty」三条件全满足时才 bake，bake 后立即清 dirty。
- `_apply_overlay_mode` / `_generate_and_render` 等显式入口绕过 dirty gate，并在 regenerate 时把 `_overlay_tex/_buf` 置 null 让 baker 安全新建（derived_size 可能已变）。
- baker 热路径优化：`stats` 改用强类型局部变量、`values_for_median` 用 `PackedFloat32Array` 预分配、`mode_is_discrete` 谓词外提、`int(x*255.0+0.5)` 替代 `int(round(x*255.0))`。

**实测收益**：1080×574 derived size、x20 倍速下，每个游戏日 bake 时间从 ~12-20ms 降到 ~1.5-3ms；FPS 从 18 回到 60。

**诊断技巧**：

- 如果用户报告"开 Debug 通道就卡"但 SUS 日志正常，先看是否 `_overlay_mode != 0`。
- `main.get_overlay_last_bake_ms()` 暴露最近一次 bake 耗时；超过 5ms 都应警觉。
- `main.get_overlay_bake_path()` 暴露 pixel fan-out 路径，正常应为 `gdext_fanout`；若为 `gdscript_fanout`（旧 DLL / SoA 未建）或 `gdscript_fanout_soa`（C++ 返回参数错）说明未走到 C++，可结合 push_warning 的 `reason` 排查。
- 关闭 overlay（切到 NONE）能定位是否瓶颈在 bake：FPS 恢复即坐实。
- pixel fan-out（典型 ~62 万次写）已于 debug-overlay-perf v2（2026-06-12）下沉 `world_ext.cpp::encode_overlay_atlas`；per-cell 采样仍在 GDScript（~n_cells 次，分支重）。若 `gdext_fanout` 下 bake 仍偏高，先看 GPU `tex.update` 与 per-cell 采样，而非 fan-out。

## Tile Data Recorder Cost（全量地块 CSV 录制卡顿）

**症状**：点击 DebugConsole 的“开始地块全量录制”后，游戏写入 `tmp/tile_data_record_*.csv` 时明显卡顿；普通 `[fast tick WARN]` 中的 `sus/render/ui` 不一定能解释全部耗时。

**原因**：这条路径不是 `DCWorldExt.snapshot_f32()` 慢。`snapshot_f32/snapshot_i32/snapshot_u8` 只是返回 C++ slot 的 PackedArray 快照；当前卡顿主因是 `TileDataRecorder.on_fast_tick()` 在主线程同步完成：

1. 每个 fast tick 读取当前 `MapData`。
2. 每个 cell 写一行 CSV。
3. 每行包含所有可用 SoA 字段以及固定诊断字段。
4. 把这些值格式化成文本，再同步写到 `tmp/tile_data_record_*.csv`。

在 2400 cells、几十个 SoA 字段的配置下，这等价于每个 tick 生成数千行、MB 级文本。历史录制文件常见 600MB-3GB，说明磁盘与字符串格式化都会进入帧预算。用户要求“每个 tick、每个 cell、所有 SoA 字段”时，不应通过采样、跳 cell 或删字段来隐藏成本；应先用诊断确认成本，再做不丢数据的优化。

当前 recorder 诊断字段：

```text
[fast tick recorder] frame=... recorder=...ms tile=...ms rows=... total_after=...ms
        recorder total=... perf=... tile=... collect=... stats=... format=... flush=... encoder=... tile_rows=... tile_recorded=... tile_reason=... total_after=...ms
```

含义：

- `fast_ms_before_recorders` 是旧的 fast tick 计时，通常只覆盖 `sus/render/ui` 与 overlay gate 前后的逻辑。
- `fast_ms_after_recorders` / `total_after` 把 recorder 同步成本也算进去。
- `tile_ms` 是 `TileDataRecorder.on_fast_tick()` 本 tick 的墙钟。
- `collect/stats/format/flush` 分别是 SoA 数组收集、派生统计、CSV 编码、文件写入耗时。
- `encoder=gdext` 表示本 tick 走 `DCWorldExt.encode_tile_csv_rows()` 批量编码；`encoder=gdscript` 表示旧 DLL、方法探测失败或 C++ 返回空 buffer 后走 GDScript 兜底。
- `tile_rows` 在全量默认配置下应约等于 `cell_count`。
- `tile_reason` 只有未录制、达到行数上限、MapData 改变、SoA 尺寸改变等情况才非空。

当前实现做了不丢数据的降阻塞优化：

- 默认仍是 `tick_stride=1`、`cell_stride=1`、`compact_fields=false`，即每个 tick、每个 cell、所有可用 SoA 字段。
- CSV 行用批量 `store_string()` 写入，避免每个 cell 一次 `store_line()`。
- q/r/s 在 `start()` 时按 cell index 缓存，录制中不再每行读取 `HexCell` 对象。
- 每 tick 固定诊断列只格式化一次，行内只追加 `row_idx/cell_index/q/r/s` 与 SoA 值。
- 如果当前 DLL 暴露 `DCWorldExt.encode_tile_csv_rows()`，每 tick 的全部行文本由 C++ 从 GDScript 传入的 `MapData` PackedArray 快照批量编码成 `PackedByteArray`，GDScript 侧用 `FileAccess.store_buffer()` 一次写入。字段顺序、行数、float 格式、NaN/Inf 空值语义保持与 GDScript formatter 等价。

如果 `encoder=gdext` 后全量录制仍明显卡顿，下一步优化应保持完整性：优先考虑后台线程/双缓冲写盘或二进制无损格式；不要默认改成 stride 采样或 compact 字段。

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

## Climate stability diagnostics

Weather CSV fields should be read from `sample["weather"]`, not from
`sample["climate"]`. If `weather_dirty_mask` changes but `weather_dirty_count`
is permanently zero, first check the recorder input path before changing
weather math.

Important weather fields:

- `weather_diag_present`: the sample carried a weather breakdown.
- `weather_field_commit_path`: native or fallback commit path.
- `weather_refresh_convergence`: whether this tick should publish convergence.
- `weather_field_solve_tick` and `weather_convergence_refresh_stride`: cadence
  source for convergence refresh.
- `weather_convergence_dirty_count`, `weather_convergence_delta_p95`, and
  `weather_convergence_published`: convergence publication diagnostics.
- `weather_target_mismatch_count`, `weather_transitioning_count`,
  `weather_transition_alpha_mean`, and `weather_transition_alpha_p95`: per-tick
  lifecycle diagnostics from `weather_type_arr`, `weather_target_type_arr`, and
  `weather_transition_alpha_arr`. A permanently high mismatch count with flat
  alpha values points to transition commit/cadence, not field generation.
  Stable cells should have `weather_prev_type_arr == weather_target_type_arr`
  and `weather_transition_alpha_arr == 0`; nonzero alpha on stable cells is a
  transition bookkeeping bug, not real weather generation.
- `weather_classification_temp_arr` and
  `weather_classification_moisture_arr`: per-cell snapshots read by the weather
  field solver for classification. Compare these with `temp_arr` and
  `moisture_arr` before treating cold rain or warm blizzard rows as a classifier
  bug; a large delta means the CSV is showing post-climate current state against
  a previous-snapshot weather decision.

`refresh_convergence=false` means convergence is intentionally held for this
tick. Treat `weather_convergence_published=false` or zero
`weather_convergence_delta_p95` as cadence information unless the same fields
stay flat on refresh ticks.

When investigating local temperature ping-pong, first check for jumps from
exactly `0.0` to the geometric baseline. Runtime code must not use
`temp > 0.0` as a validity test; zero is a valid frozen temperature, while NaN
or Inf are the only values that should trigger baseline fallback.

Use the climate finalizer CSV fields before changing pass cadence:

- `climate_current_pass`, `climate_partial`, `climate_progress_ratio`,
  `climate_processed_cells`, `climate_cursor_start`, and
  `climate_cursor_end` identify which climate daily sub-pass owned the current
  tick slice.
- `climate_pass_stage`, `climate_pass_substage`, `climate_pass_path`,
  `climate_pass_status`, `climate_budget_interrupted`, and
  `climate_pass_token` mirror `ClimateDailySystem.pass_diag`. Use them to
  separate a real temperature/precipitation rule problem from a partially
  completed climate round or native/fallback path switch.
- `climate_p95_temp_delta` / `climate_p99_temp_delta` show actual post-clamp
  daily movement distribution.
- `climate_preclamp_max_temp_delta` /
  `climate_preclamp_p99_temp_delta` show what the climate chain attempted
  before finalizer limiting.
- `climate_temp_delta_gt_005_count`, `climate_temp_delta_gt_010_count`, and
  `climate_temp_delta_gt_020_count` count how many cells moved by more than the
  local thresholds on that tick.
- `climate_temp_delta_clamped_count` indicates the daily cap is actively
  preventing larger jumps. If this is high for many ticks, inspect upstream heat
  transport/pass inputs instead of only loosening the final cap.
- If large local jumps line up with `climate_pass_stage=wind_air`, the expected
  output is `air_mass_temp_anomaly_arr` only. A simultaneous `cell_temp` rewrite
  from that stage indicates the GDScript/C++ publish contract regressed.

When diagnosing ocean cadence, separate physical authority from visual catch-up.

- Physical fields: `phys_round_active`, `physical_round_id`, physical
  `stage_name`, PSI path, SLP/wind/current/upwelling delta fields.
- Visual fields: `visual_round_active`, `visual_round_id`,
  `visual_pending_commit`, `visual_lag_ticks`, `visual_pixel_progress`,
  `visual_next_pixel_idx`, and `visual_total_pixels`.
- A large `largest=ocean_currents/ocean_pixel_slice/... path=gdext_raster`
  entry can be a visual raster cost. It does not by itself prove that physical
  ocean fields are frozen. Check whether `physical_round_id` advances and
  whether SLP/wind/current delta diagnostics keep changing.
- If `visual_lag_ticks` grows while physical fields continue updating, the
  simulation is healthy but the atlas is stale. Inspect raster quota, commit
  cost, and `ocean_visual_rebake_drop_stale` before changing physical cadence.

## Render frame profile 热键（2026-06-14）

`main.gd::_unhandled_key_input` 加了三个 60 FPS 调查热键，专门定位"主线程仿真已优化但
仍 26 FPS"的非 SUS 帧时间消耗（GPU / Canvas rebuild / atlas commit）：

- **F3 — `dump_render_profile()`**：打印当前 FPS / TIME_PROCESS / TIME_PHYSICS_PROCESS /
  TIME_NAVIGATION_PROCESS / draw_calls / primitives / objects / VRAM (total / texture /
  buffer) / node + resource + orphan count / atlas hm_size / msaa / fxaa / mobile flag。
  RenderingServer 的 view_calls / view_prims 也包含。一行 print 给完整 GPU 端时间。

- **F11 — `toggle_dynamic_visual_atlas_upload()`**：通过 `Engine.set_meta(&"force_disable_dva_upload", true)`
  让 DVA 的 `should_run` 直接 return false。**用来对比关掉 atlas commit 后 FPS 改善多少**——
  如果关掉后 FPS 显著回升（5+ 帧），说明 atlas commit 是 GPU/CPU 瓶颈来源；不变则瓶颈在别处。

- **F12 — `toggle_atlas_resolution()`**：通过 `Engine.set_meta(&"force_atlas_quarter_size", true)`
  让 `MapBaker._hm_max_dim()` 返回 256（默认 mobile 是 512）。会触发 regenerate
  （重 bake atlas ~5 秒）。**用来验证 GPU 负载是否随 atlas 像素总量线性变化**。

调查手册（移动端 60 FPS 未达时按顺序排查）：

1. F3 抓基线（climate async on，DVA on，atlas mobile 512）。
2. F11 关 DVA → 等 5 秒稳定 → F3 抓数据。FPS 回升 5+ 帧 → DVA 是瓶颈。
3. F12 降 atlas 256 → 等 regenerate → F3 抓数据。FPS 回升说明 GPU fillrate 受限；不变说明
   GPU 不是瓶颈，瓶颈在 CPU / Canvas / shader 复杂度。
4. F11 + F12 同时开 → 看上限。
5. 看 draw_calls：若 > 200 说明 Canvas 没 batched，渲染 submit 端是瓶颈。
6. 看 RenderingServer.view_calls：跟 Performance.draw_calls 对比，差距大说明有不可见 viewport
   在白做工。

