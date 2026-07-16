# Performance Diagnostics Playbook

本文用于解释运行日志，并给出排查 C++/DOTS 路径是否符合预期的流程。目标不是只看“耗时高不高”，而是定位高耗时来自 C++ compute、GDScript fallback、slot sync、flush、dirty mask、GPU upload，还是统计窗口里的旧 spike。

## 玩家场景 GM 性能入口

`player_game.tscn` 运行时默认显示右上角 `PerfMiniHUD`；F4 切换显隐。顶栏 GM 按钮、
反引号或 F1 打开精简性能面板，可查看 last-tick、30-tick Top-N、climate/weather/economy
breakdown，并执行性能快照、性能 CSV、地块 CSV 和经济 epoch CSV 录制。玩家场景的诊断数据源是
`WorldRuntimeHost`，它在同一 daily tick 上分段记录：

- `t_sus_ms`：`MapGenerator.sus_tick_daily()`，包含 climate、economy 和其他 SUS jobs。
- `t_render_ms`：fronts、weather field texture 等 renderer 同步，不等于 GPU fragment 时间。
- `t_ui_ms`：选中地块 live patch 与顶栏时间状态更新。
- `bd_ui_live_patch_build_ms`：右侧面板 ViewModel 读取选中地块/原生快照并构造
  live patch 的墙钟。
- `bd_ui_live_patch_apply_ms`：`InspectorPanel` 把 live patch 应用到当前可见控件的墙钟。
  `bd_ui_ran=false` 表示该 tick 未达到 750ms 面板刷新节流；`bd_ui_tab` 记录当前标签页。
- `fast_ms`：以上路径与少量调度胶水的总墙钟；录制器开销另见
  `fast_ms_after_recorders` / recorder summary。

性能 CSV 在桌面写入仓库 `tmp/perf_record_*.csv`，地块 CSV 写入
`tmp/tile_data_record_*.csv`，经济录制按提交 epoch 写入 `tmp/economy_record_*.csv`；
移动端分别写入 `user://perf`、`user://tile_data` 和 `user://economy_data`。
全量地块录制会同步编码、写盘，可能主动制造卡顿，因此先录性能基线，再短时开启地块录制，
并检查 `tile_ms/format_ms/flush_ms/encoder_path`。

经济录制已使用原生 CSV v5 双缓冲：GM 面板显示 `captured/written epoch`、
`queued_batches`、`capture_ms_last/p95/max` 和 worker 耗时。正常录制为 `recording`，点击停止后为
`draining`，排空后为 `completed`。`queue_full` 表示长期产生速度超过编码/磁盘吞吐，recorder
已保留并写完所有已接受 epoch，同时用 `first_unrecorded_epoch` 标明停止边界；`row_limit`
表示下一完整 epoch 会超过上限，因此整批未接收；`write_failed` 表示文件错误，五表回退到
上一个完整 epoch。不要把后台 worker 时间算进 SUS job 耗时，主线程成本看 `capture_ms_*`。
若只需排查一个地块，先在地图选中它，再勾选 GM 面板的“仅录制当前地块”后开始；选区会在
start 时锁定，文件名包含 `cell/q/r`。这种模式显著减少四张明细表的抓取、编码与写盘量，但
summary 仍是全局一行，不能把它误当成该地块的小计。

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

## Skip reason 快速判断

| reason | 典型含义 | 下一步 |
| --- | --- | --- |
| `policy_gated` | job 当前 tick 未落在 `ClimateProfile.sim_stagger_*` 配置的 bucket phase 上。默认这是全平台错峰的正常结果。 | 看 stride/phase 是否符合预期，以及一个完整 bucket 周期内是否至少运行一次。 |
| `strict_budget_one_job` | `sim_strict_budget_enabled=true` 时，scheduler tick 内轮转只放行一个 optional job。 | 这是 strict round-robin 预算模式，不是 profile bucket；确认是否真的需要打开 strict。 |
| `frame_budget_exhausted` | tick 内 frame budget 被前面的 slice 吃完，后续 optional job 没启动。 | 看 `largest`、`must_run`、slice budget 和是否长期饿死 simulation authority job。 |
| `dep_pending` | depends_on 上游 round 仍未完成。 | 检查依赖是否是硬数据依赖；跨多 tick 的上游会拖慢下游。 |

当前默认错峰由 `DCSystemScheduler.configure_job_from_profile()` / `apply_job_schedule()` 解释 `ClimateProfile.sim_stagger_enabled`、`sim_stagger_bucket_stride` 和各 job phase。正常日志会看到不同 job 在不同 tick `ran`，其他 tick 记为 `policy_gated`；这不等同于性能故障。真正需要处理的是某个 job 经过完整 bucket 周期仍长期只有 `frame_budget_exhausted` 或 `dep_pending`。

## `path=` 字段解释

| path | 含义 | 是否异常 |
| --- | --- | --- |
| `gdext` | C++ GDExtension pass 成功。 | 正常。 |
| `gdext_native_daily_slice` | `native_daily_sim` ACTIVE 的 C++ continuation slice。 | 正常；看 `done=false`、`stage_name`、cursor 和 `round_native_ms`。 |
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

## Native daily slice 排查

`native_daily_sim` ACTIVE 的正常形态是一轮 native daily graph 被拆成多个 SUS slice：

```text
native_daily_sim ran=... progress=0.46
    path=gdext_native_daily_slice stage=wind_surface substage=wind_surface_knobs done=false cursor=5..6 round=...
```

判断：

- `total_ms` / `native_ms` 是当前 slice 的墙钟，应接近单个 native node 的耗时；不要把它当整轮耗时。
- `round_native_ms` 是本轮累计 native 墙钟，用来观察整轮总成本。
- **⚠ per-group 字段（`climate_ms`/`ocean_ms`/…）≠ slice wall**：这些字段是各 `run_*_pass` **返回值**累加，而有的
  pass（如 `run_climate_pass_a`）末尾直接 `return 0.0`（无内部计时），其真实成本只体现在该 slice 的 `native_ms`
  里、却在 `climate_ms` 中显示≈0。**所以"per-node breakdown 某组≈0"不代表该节点便宜**——定位重节点要按 `stage_name`
  聚合 slice 级 `native_ms`（见 `tmp_native_spread_validate.gd` 的 per-stage 归因），必要时在该 pass 内部加临时
  in/loop/flush 三段计时。2026-06 的 `climate_pass_a` ~1.7ms 隐藏热点（逐日重算 `dc_insolation_annual_mean`
  年均日照积分）就是这样被找出来的。
- `done=false` 表示 C++ continuation 仍在推进，下个 SUS tick 会绕过 stride 继续执行；这不是失败。
- 有界降频契约字段用于判断“低频计算是否可控”，而不是只看 `done=false`：
  `native_daily_sample_day` 是本轮权威采样日，`native_daily_commit_day=-1` 表示尚未提交，
  `native_daily_age_days` 是当前日相对采样日的年龄，`native_daily_commit_lag_budget_days`
  是本 profile 允许的最大提交延迟，`native_daily_commit_over_budget=true` 表示已经违反契约。
  同一组字段会出现在 `native_daily/slow-dump`、fast tick breakdown、`NativeDailySimJob`
  report 和 perf CSV 的 `bd_climate_native_daily_*` 列中。移动端 N 日降频验收时，先筛
  `bd_climate_native_daily_commit_over_budget=true`；理想结果应为 0 行。
  启动日志中的 `native_stride` / `native_budget` 是最终运行值；移动端默认应为 20/20，
  除非 WorldSetup 显式覆盖。
- `stage_name` 应稳定对应 native daily slice node，例如 `climate_pass_a`、`ocean_water`、`wind_surface`、`stage_b`、`weather`、`runtime_hydrology`、`stage_b_after_hydrology`。当 `native_daily_split_weather_node_enabled=true` 时，`weather` 是跳板节点，实际耗时会拆到 `weather_field`、`weather_commit`、`weather_distribute`、`weather_summary`、`weather_cyclone`、`weather_stage_b`。
- `sus_window ... largest=... cursor=A-B` 中的 cursor 来自 scheduler summary 的 largest slice cursor。native daily graph 下它对应本 slice 处理的 node 区间，可与 `native_daily/slow-dump node=... cursor=...` 对齐。
- Split weather report 会同时保留旧聚合字段 `weather_ms` / `weather_tick_ms`，并新增 `weather_field_ms`、`weather_commit_ms`、`weather_distribute_ms`、`weather_summary_ms`、`weather_cyclone_ms`、`weather_stage_b_ms`；`weather_split_skipped_monolithic=true` 表示本轮没有调用旧的一体化 `run_weather_refresh_daily_pass`。失败时 `fail_stage` 会落在对应 split stage，`fallback_reason` 给出 `field_solve`、`field_commit`、`distribute`、`summary` 或 `stage_b` 等具体原因。
- `native_daily/slow-dump ... prebuilt=true` 表示 weather cadence 到期时 `weather_knobs` 已在 round-start bundle 中预构建，node 12 的 JIT patch 会短路；若仍看到 `stage=weather/weather_knobs bundle=4-6ms prebuilt=false`，优先查 Android 包是否未更新或 weather prebuild 前置条件失败。
- `bundle=... jit=... keys=[...]` 用于区分 round-start bundle 和 deferred JIT patch。`jit` 高且 `keys=["ocean_water_knobs", "ocean_land_knobs"]` 时，热点在最新温度/TTA 的 GDScript knobs 构建；`jit` 高且包含 `wind_air_knobs` 时，先确认 Android/Windows DLL 是否已有 `supports_wind_air_slot_temp()`：新 DLL 应让 wind-air 直接读 `cell_temp` slot，只保留静态 `baseline_arr`，不再构建 `temp_before_arr`。`jit≈0` 但 `bundle` 高时，优先查 round-start bundle 或 report 聚合。`ocean_water/land` 的 baseline 热路径会复用 `temp_baseline_arr`，若仍高，下一步看 TTA copy 或把对应动态输入继续迁入 C++ slot。
- `native_daily_coarse_spread_yield_enabled=true` 时，spread yield 会从全节点 checkpoint 收缩到 `[2,6,12,19,20]`。它用于验证降低 C++/GDScript round-trip 的均值收益；开启后必须同时检查 `largest_slice_ms`、`stage_name` 和 weather split 字段，确认没有把多个重节点重新堆到同一 tick。
- 移动端主场景应先出现 `[WorldSetup] ClimateProfile path=res://data/world/earth_like_mobile_complex.tres mobile=true split_weather=true wind_period=6`，随后首个 native slice 日志应包含 `split=true split_skipped_monolithic=true`，并在 breakdown / largest 中出现 `weather_field` 等 split 节点。`weather_knobs embedded` 只表示 bundle 仍携带天气输入，不单独代表 monolithic；如果小米/Android log 仍显示 `wind_period=3`、`split=false` 或完全没有 split 节点，先查 profile 是否未加载；如果 profile 日志已经是 split=true 但 native slice 仍没有 split 字段，再查 Android GDExtension `.so` 是否旧、是否已重建并重启应用。
- 移动端复杂 profile 还把 `weather_field_advect_steps` 覆盖为 `4`（桌面默认仍为 `8`），用更短上风采样降低 `weather_field/weather_knobs` 的单节点峰值。若天气场尖峰仍高，先看 slow dump 里的 `adv=...` 是否继续主导，再决定是否继续拆 field solve。
- `[fast tick WARN]` 中 `native_daily/finalizer ...` 只在 native daily round 完成并执行 finalizer 时打印。它用于解释 `largest=native_daily_sim/native_daily_complete/round_complete`：`cell/temp/tta/thermal/sort/sea_ice/precip` 定位计算段，`write_mode/dense/sparse/dirty_collect/dirty_ratio/dirty=temp/tta/thermal/comps_dense/comps_sparse` 定位 DataCore 可见写入，`temp_clamped/tta_clamped/thermal_init/max_dt/pre_max_dt` 定位稳定性 clamp。`NativeDailySimJob` 的 scheduler report 为降低热路径成本不再嵌完整 `native_daily_report`；`main.gd` 会回退读 `MapGenerator.native_daily_last_result()` 获取完整 native result。若 `finalizer_total_ms` 高但 `cell_ms` 低，优先查 sparse/dense 写入和 dirty ratio；`mixed_sparse_dense` 表示每个 component 独立选择 sparse/dense，常见于 temp/thermal dirty 高但 TTA dirty 低的移动端 round；`dirty_skip=true` / `skip_comps=[...]` 表示 `sparse_perf` 命中上一轮高 dirty hint，本轮跳过对应 component 的 GDScript dirty collect 并直接 dense 写；若 `cell_ms` 高，继续区分 native finalizer path 与 temp/TTA/thermal 子段。
- `native_daily_complete` 的 `apply_ms` 是完成 slice 的 GDScript 可见收尾墙钟，已经拆出 `complete_apply_*` 子字段：`publish_tta` 是 raw/clamped TTA 发布到 `MapData`/DataCore 的 wrapper 成本；`weather_result` 是 `WeatherSystem.apply_unified_fast_tick_result()`；`visual_intents` 是 fronts/LUT/atlas dirty intent 应用；`finalizer` 是 `_native_daily_apply_finalizer()` 外层调用墙钟；`finalizer_merge` 是 finalizer diag 合并；`result_patch` 是把最终输出重新挂回 result；`observed` 是这些子段求和；`other = apply_ms - observed`，用于定位清理状态、字典写入或尚未细分的 GDScript glue。
- 如果又看到 `native_daily_sim/native_daily path=gdext_native_daily` 单片 9-11ms，说明当前不是 production `NativeDailySimJob` slice hot path；优先查是否手动调用 debug/full-run helper、DLL 是否旧，或 ACTIVE 注册是否被拒绝后走了别的测试入口。
- `published_slots`、scheduler-level `published_to_slot` 和 `visual_dirty_intents` 只应在 round 完成 slice 上出现；中间 slice 为空是正常的。graph-level `published_to_slot=true` 不替代具体 pass 的 visible flush 证据。
- `authority_blockers` 只看 simulation authority 和 production fallback；`retained_boundaries` 才看 `visual_uploads`、front objects、ImageTexture/LUT upload、sea-ice atlas、ocean texture commit、season detail scatter、CSV/debug。`graph_coverage_state=complete` 不要求这些 Godot presentation boundaries 消失。
- `fronts_changed` 现在来自真实 `weather_lut_changed || fronts_count > 0`，不是 `weather_knobs` 存在即 true。weather owner 已 active 但 `visible_publish_verified=false` 时，继续查 field commit readiness。

Slow native daily slices now print independently of `[fast tick WARN]`:

```text
[native_daily/slow-dump] tick=... stage=.../... node=.../... cursor=... done=... wall=... bundle=... jit=... keys=... native_call=... cpp=... compute=... refresh=... flush=... apply=... round=... weather=... prebuilt=...
[native_daily/slow-dump/weather] field=... commit=... commit_loop=... dist=... summary=... cyclone=... stage_b=... adv=... fronts=... active=... lut_dirty=... conv_dirty=...
[native_daily/slow-dump/complete-apply] total=... observed=... other=... publish_tta=... weather_result=... visual=... finalizer=... merge=... result_patch=...
[native_daily/slow-dump/finalizer] total=... cell=... temp=... tta=... thermal=... sea_ice=... precip=... write_mode=... dense=... sparse=... dirty_collect=... dirty_skip=... skip_comps=... dirty_ratio=...
```

These lines are throttled and intended to explain `[SUS-cpp] largest=...` even
when the current log sample does not include a full fast-tick breakdown.

## Runtime hydrology breakdown

启用 `ClimateProfile.runtime_hydrology_enabled` 后，legacy `weather_refresh` 可能出现：

```text
stage_name=hydrology_discharge substage=route_full path=gdext
native_ms=... compute_ms=... flush_ms=... refresh_ms=...
water_budget_error=... river_discharge_p95=... river_discharge_max=...
published_to_slot=true
```

判断：

- `published_to_slot=true` 表示 `river_discharge* / river_storage / groundwater_storage / surface_runoff / soil_moisture / water_balance_30d` 已 flush 回 `MapData`。
- `compute_ms` 高说明产流或 parent routing 本体重；`flush_ms` 高说明 PackedArray CoW/MapData 回灌成本高；`refresh_ms` 高说明 hydrology 前同步 weather slots 成本高。
- `water_budget_error` 是轻量诊断值，不是严格闭合的物理守恒误差；它包含土壤库、地下水库和河道 storage 的日级滞后。若长期接近或超过 `1.0`，优先查 `hydro_parent_arr` 是否存在循环/断链或 release rate 是否过低。
- `river_discharge_p95/max` 用来观察雨季增强、湖泊削峰、主河不断流等趋势；不要把单日 max spike 直接等同于地图河宽，因为视觉使用的是 `river_discharge_30d`。

native daily ACTIVE 中同一工作表现为 `SCHEDULE_GRAPH` 的 `runtime_hydrology` 节点。此时重点看 `hydrology_ms`、`hydrology_compute_ms`、`hydrology_flush_ms`、`hydrology_published_to_slot`、`hydrology_water_budget_error`、`hydrology_river_discharge_p95/max`。publish 成功后 `authority_report.runtime_hydrology.phase` 会升为 `native_active_verified`。如果 `fail_stage=runtime_hydrology`，优先查 `runtime_hydrology_knobs` 是否进入 bundle、hydrology slots 是否在 schema/bind table 中存在、以及 weather node 是否已经通过 readiness gate 发布 precip。

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
transp/native breakdown source=current diagnostic_wall_ms=0.35 refresh_ms=0.000 native_call_ms=0.040 native_ms=0.029 native_compute_ms=0.016 native_apply_ms=0.011 native_flush_ms=0.002 sync_total_ms=0.159 sync_write_ms=0.000 sync_mark_ms=0.000 dirty_count=...
```

字段解释：

| 字段 | 含义 |
| --- | --- |
| `source` | `current` 表示来自当前 `pass_diag`；`cached` 表示同一 climate breakdown 中 finalize 后保留的最后一次 transp/native 诊断。 |
| `diagnostic_wall_ms` | GDScript caller 看到的总墙钟。 |
| `native_ms` | C++ pass 内部总耗时。 |
| `native_call_ms` | 跨 GDExtension 调用和返回封装成本。 |
| `native_compute_ms` | C++ tight-loop 计算成本。 |
| `native_apply_ms` | 应用结果到 slot/输出 buffer。 |
| `native_flush_ms` | C++ slot flush 到 MapData。 |
| `refresh_ms` | 调用前 GDScript→C++ slot refresh；可能是全量 `refresh_slots_from_map()`，也可能是白名单 `refresh_slots_from_map_keys()`。 |
| `sync_total_ms` | caller 侧同步、等待、snapshot 或其他 glue 成本。 |
| `sync_write_ms` | GDScript DataCore write API 成本。 |
| `sync_mark_ms` | dirty mark 成本。 |
| `dirty_count` | native pass 返回并同步的 dirty cell 数。 |

判断：

- `native_compute_ms` 很低但 `diagnostic_wall_ms` 高：边界/同步问题。
- `native_ms` 很低但 `largest=transp/apply path=gdscript_sliced`：多半是窗口旧 spike 或 fallback apply 仍偶发。
- `sync_write_ms` / `sync_mark_ms` 高：检查是否又走了单点 setter 或全图 dirty。
- `refresh_ms` / `sync_total_ms` 高：检查是否重复 refresh、是否仍在全量 `refresh_slots_from_map()`、或是否有不必要 snapshot。

`natural_resource_daily` 的 native report 额外给出 `loop_ms` / `flush_ms` /
`skipped_static_resources`。若 `flush_ms` 接近总耗时，优先查资源 slot 发布数量；若
`loop_ms` 高，才继续看资源数、SIMD/多核和 per-cell 公式。

`[fast tick WARN]` / periodic breakdown 会在 `natural_resource_daily` 下打印：

```text
natural_resource path=gdext wall=... cpp=... compute=... loop=... flush=... wrapper=... layout=cell_range_fused_seq dispatches=0 resources=published/input skipped_static=... published_to_slot=true total_delta=...
```

其中 `wall` 是 job 外层耗时，`cpp` 是 C++ pass 返回的 native 总耗时，
`wrapper ~= wall - cpp`。若 `loop` 低但 `flush` 或 `wrapper` 高，优先查
slot flush / MapData publication / refresh 边界；若 `loop` 高，优先查资源数量和
每资源 per-cell 公式。`layout=cell_range_fused_seq dispatches=0` 表示小图走
single-thread SIMD fused body；`layout=cell_range_fused_mt dispatches=1` 表示大图
才进入 WorkerThreadPool。若仍慢，用 `tests/natural_resource_pass_bench.gd` 对比
`SIMD+1T` / `SIMD+MT` 判断 WTP dispatch 是否超过收益。`main.gd` 会优先读 scheduler report；若 SUS 摘要裁掉
自定义字段，则回读 `MapGenerator.natural_resource_last_result()` 的原始 pass report。
`[natural_resource/slow-dump]` 会在资源 pass 自身超过阈值时独立打印同一组字段，
用于没有 fast-tick breakdown 的短 log。

## Climate wrapper breakdown

`[fast tick WARN]` 会在 `refresh_climate_daily` 下额外打印：

```text
climate wrapper breakdown round_start_total_ms=... round_start_terrain_sync_ms=... capture_start_state_ms=... pass_overhead_ms=... finalize_total_ms=... finalize_finalizer_ms=... finalizer_total_ms=... finalizer_cell_ms=... finalizer_temp_ms=... finalizer_tta_ms=... finalizer_thermal_ms=... finalizer_sort_ms=... finalizer_write_mode=sparse_perf finalizer_write_dense_ms=... finalizer_sparse_write_ms=... finalizer_dirty_ratio=... tta_mirror=false/0 tta_clamped=0 thermal_init=0 temp_mirror=false
```

这行解释 `largest=refresh_climate_daily/...` 的外层墙钟。`pass_overhead_ms`
是当前 slice 墙钟减去 pass report 的差值；`round_start_*` 是 round 入口锁相位、
terrain sync、start-state capture、mark stale、SoA transaction 和 dirty mask；
`finalize_*` 是 `_finalize_round()` wrapper；`finalizer_*` 是
`_apply_daily_climate_finalizer()` 内部 cell loop、sort、sea ice、precip 和 DataCore 可见写入。

判断：

- `transp/native diagnostic_wall_ms` 低但 `finalize_total_ms` 高：热点在 round 收尾，不在 transp C++。
- `finalize_finalizer_ms` 高：继续看 `finalizer_cell_ms`、`finalizer_temp_ms`、`finalizer_tta_ms`、`finalizer_thermal_ms`、`finalizer_sort_ms`、`finalizer_write_mode`、`finalizer_write_dense_ms`、`finalizer_sparse_write_ms`。
- `finalizer_write_mode=sparse_perf|sparse_safe` 表示 native finalizer 成功后只通过 `write_f32_indexed` 提交 temp/TTA/thermal 的 dirty index；`mixed_sparse_dense` 表示部分 component 超过 `native_daily_finalizer_sparse_max_dirty_ratio` 后单独 dense，其他 component 仍 sparse；`dense_fallback_dirty_ratio` 表示所有需写 component 都因 dirty ratio 过高退回 dense。`sparse_perf` 会在上一轮 dirty ratio 明显高于阈值时对该 component 直接 dense 写，并通过 `dirty_skip/skip_comps` 暴露；每 8 轮会强制采样以刷新 hint。
- Android 默认跳过 round-start terrain facade 全图同步，`round_start_terrain_sync_ms` 应接近 0；sea-ice slice 后仍会同步，因为 terrain/water facade 可能真实变化。
- facade 开启时 finalizer 不再把 `temperature` 或 TTA 逐 cell 镜像回 `HexCell`；TTA 兼容读者通过 `HexCell.temperature_transport_anomaly` facade 从 GDScript `DCWorld` 读取。`tta_mirror=true/N` 只应出现在 facade 关闭或 TTA clamp 需要修正 legacy backing 的场景。
- `round_start_terrain_sync_ms` 或 `round_start_mark_stale_ms` 高：查 round boundary sync/stale 标记；如需临时恢复 round-start terrain sync，可显式设置 `climate_round_start_terrain_sync_enabled=true`。
- `pass_overhead_ms` 高：查 `_run_pass()` wrapper、pre-pass mark stale、integrity diagnostic 或 report 字段遗漏。

## `refresh_climate_daily` 高 p95 排查

流程：

1. 看 `largest` 指向哪个 substage：`pass_a`、`pass_b`、`ocean_water`、`wind_air`、`transp`。
2. 看当前 tick 的 detailed breakdown，而不是只看 window max。
3. 如果 `path=data_core`，确认是否有 native 子项，例如 `ocean_water gdext runs=... fallbacks=0`。
4. 如果出现 `native_or_gd`，查 caller 是否用同一字段同时承载 native/fallback timing。
5. 查 `fallback_reason` 或 stale DLL warning。
6. 查 `refresh_slots_from_map()` 是否在同一 round 多次重复；边界 job 若只读少数 slot，确认是否可改用 `refresh_slots_from_map_keys()`。
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
- `path=dc_not_ready`（旧标签 `legacy`，2026-06-17 改名）表示该 tick DataCore 尚未
  就绪、走的是非 DataCore cell path；它反映 DataCore readiness，**不是** C++ 代码被
  GDScript 绕过。偶发的 `fronts_*` 峰多与该 path + 大量 front churn 同时出现。
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

- `phys_wind_period_ticks` equals
  `ClimateProfile.ocean_daily_wind_period_ticks` (default 3; mobile profiles may
  raise it).
- `phys_daily_wind_due=true` only on ticks matching that cadence.
- `phys_daily_wind_ran=true` on due ticks.
- `phys_daily_wind_path=gdext_daily_wind`, `gdext_daily_wind_slp`, or
  `gdext_daily_wind_wind`
- `phys_sim_day` advances by one per recorded SUS daily tick
- `phys_daily_wind_delta_p95` is normally non-zero but should remain smooth
- `phys_daily_wind_dir_delta_p95` isolates direction-only movement. Use it for
  "wind vector flipped" investigations because `phys_daily_wind_delta_p95`
  also includes speed/flux movement.
- `phys_daily_wind_dir_flip_count` counts cells whose daily direction turn
  exceeded the hard flip threshold. After the 2026-06-27 direction limiter this
  should be rare and tied to real fronts/terrain, not broad near-zero flux noise.
- `phys_ticks_per_slice` may be greater than 1; that describes the slow
  ocean/raster chain and should not prevent daily wind updates
- `phys_slp_cell_cursor` / `phys_wind_cell_cursor` / `phys_psi_cell_cursor`：stage 内
  cell 切片游标；末切片时 `== n_cells`，用于确认切片按预期推进、无中途 stall。仅在
  cell-range 切片开启（默认关闭）时出现。
- `phys_cell_slice_enabled`：是否启用 stage 内 cell 切片（默认 `false`，inert-by-default）。
- `j_native_daily_sim_*` 与 `bd_climate_*` 的 native daily 诊断现在会透出
  `node_index`、`next_node_index`、`last_completed_node`、`processed_nodes`、
  `jit_patch_build_ms`、`jit_patch_keys`、`deferred_wait_node/key`、finalizer dirty-collect
  skip 字段，以及 node-range 字段 `node_range_active`、`node_range_node`、
  `node_cell_cursor_start/end/count/processed`。若 slow dump 显示
  `cells=start-end/count`，说明尖峰来自同一 graph node 内的 cell chunk，而非 bundle/JIT
  或 finalizer。
- 若 `j_native_daily_sim_ms` 明显大于 `bd_climate_wrapper_wall_ms`，先看
  `j_native_daily_sim_slice_actual_ms`、`j_native_daily_sim_slice_reported_ms`、
  `j_native_daily_sim_slice_reported_gap_ms`、`j_native_daily_sim_slice_wrapper_wall_ms`、
  `j_native_daily_sim_slice_job_shell_wall_ms` 和 `j_native_daily_sim_job_wrapper_gap_ms`：
  `slice_actual` 是 SUS 外层调用 `run_slice()` 的墙钟，`slice_reported` 是 job 返回的
  `elapsed_ms`，`slice_reported_gap` 表示 GDExtension/GDScript 调用壳、report 构造或字段对齐
  没有被 wrapper breakdown 覆盖。`bd_climate_job_shell_*` 是 `NativeDailySimJob` 内部同口径
  自测，可用于区分 C++ SUS 外层开销和 job 内 report 构造开销。
- `native_daily_finalizer_slice_enabled=true` 时，CSV 会先出现
  `stage=native_daily_finalizer substage=pending done=false`，下一片才是
  `native_daily_complete`。判断是否还要继续细切 finalizer，应看完成片的
  `finalizer_cell_ms`、`finalizer_write_dense_ms`、`finalizer_sparse_write_ms` 和
  `finalizer_dirty_collect_ms`，不要把 pending 片误读成一次完整 round。

If a due tick reports `phys_daily_wind_ran=false`, read
`phys_daily_wind_fallback_reason` first.
Common causes are `physical_disabled`, `missing_world_ext`, `missing_cpp_method`,
or missing indexed map data. If `phys_daily_wind_path` is one of the gdext daily
wind paths but the visual wind overlay looks stale, check the raster/atlas
upload path separately: the simulation authority is `cell_wind_x/y` and
`cell_wind_speed`, while the BA channels in the vector atlas are a visual copy.

### SLP vs wind attribution

`daily_wind` is two native authority passes (SLP, then wind). The per-stage
timings are split so the budget owner is unambiguous:

- `phys_daily_wind_slp_ms` / `phys_daily_wind_wind_ms` (tile CSV) and
  `daily_wind_slp_ms` / `daily_wind_wind_ms` (ocean breakdown): SLP is normally
  the heavier of the two (~3-4ms vs ~1.5ms).
- On a wind-only day the ocean slice report sets `substage` to the dominant
  sub-stage, so `sus_window largest=ocean_currents/daily_wind_prepass/
  daily_wind_slp` (or `daily_wind_wind`) tells you which pass dominated without
  reading per-field timings.
- `main.gd` prints a dedicated breakdown line whenever the prepass runs:

```text
ocean_currents ran=3.10ms slices=1 progress=1.00
    daily_wind stage=slp path=gdext_daily_wind_slp slp=3.05 wind=-1.00 total=3.09 refresh=0.04 dominant=daily_wind_slp/3.05 slp_dp95=0.01200 wind_dp95=0.00000 commit=true reason=
    daily_wind/slp_internal passA=2.41 passB=0.32 norm=0.21 marshall=0.11 (passA=逐cell三角/insolation, passB=邻域平滑, norm=recenter+p95排序+缩放, marshall=prev混合+发布)
```

If `dominant=daily_wind_slp` and `slp` keeps climbing, the SLP kernel/inputs are
the next target; if `dominant=daily_wind_wind`, look at the wind kernel. A high
`refresh` with low `slp`/`wind` means the cost is the GDScript→C++ slot refresh,
not the math kernels. Current daily-wind uses a slot whitelist; if this regresses,
check whether the loaded DLL exposes `refresh_slots_from_map_keys()`.

When `daily_wind_wind_ran=true` and the physical chain is already at `phys_wind`,
`ocean_currents` reuses the same-tick wind via `prime_physical_solve_from_current_wind()`
and yields before PSI. The slice report then contains `phys_wind_dedupe_applied=true`,
`phys_wind_skipped_reason=daily_wind_reused`, `stage_local_ms` for the attribution
owner, and `job_elapsed_ms` for the full run_slice wall clock. If a `phys_wind`
largest spike still includes daily prepass cost, check whether these fields are missing
or whether the daily tick was SLP-only (`daily_wind_wind_ran=false`).

### 2-tick split + SLP-internal instrumentation

`plan/daily-wind-stage-split` staggers SLP and wind across adjacent game days
(profile flag `daily_wind_split_passes`, default `true`):

- `stage=slp` ticks show `slp=…`, `wind=-1.00`, `path=gdext_daily_wind_slp`;
  `stage=wind` ticks show `slp=-1.00`, `wind=…`, `path=gdext_daily_wind_wind`.
  `stage=both` is the cold-start / first-prepass / regression path. Expect the
  single-tick peak to be ~3ms (SLP day) rather than ~5ms (SLP+wind).
- The `daily_wind/slp_internal` line breaks the SLP `elapsed_ms` into
  `passA` (per-cell trig / `dc_insolation_*` / synoptic — usually the dominant
  cost), `passB` (6-neighbor smoothing), `norm` (recenter + p95 sort + scale),
  and `marshall` (prev-blend + recenter + delta + slot publish). It only prints
  on ticks where SLP actually ran (`slp_passA_ms >= 0`). Fields come from C++
  `run_slp_field_pass`; an older DLL that predates the instrumentation returns
  `-1` for all four (rebuild + restart Godot to populate them).
- If `passA` dominates, the cost is the per-cell math, and the next lever is
  reducing transcendental calls — not the smoothing or marshalling. If `norm` is
  unexpectedly high, the `std::sort` over `n_cells` is the suspect.
- `plan/slp-lat-lut` already moved the latitude-only baseline
  (`dc_insolation_now`, the 16-sample `dc_insolation_annual_mean`,
  `base_lat`/`s_lat`) into a per-pass latitude LUT (`slp_lat_lut_bins`, default
  1024), so passA should now be a few tenths of a ms rather than ~2.9ms. If passA
  regresses, check that `slp_lat_lut_bins` was not lowered and that the DLL is the
  rebuilt one. A/B parity can be checked by bumping `slp_lat_lut_bins=8192`
  (near-exact) and comparing `slp_abs_p95` / `slp_delta_p95`.

### PSI solver warm-start (plan/psi-warm-start)

The recurring `phys_psi_init` peak stacks the SLP prepass and the PSI SOR solve
on the same tick. `run_psi_solver_pass` now **warm-starts** SOR from the previous
tick's ψ (`cell_ocean_psi` slot) instead of zero:

- Knob `psi_warm_start` (default `true`); `psi_total_iters` lowered `40 → 16`
  (`MapBaker._PHYS_PSI_TOTAL_ITERS`). Expected PSI stage cost drops ~1ms → ~0.3ms.
- Knob `psi_early_exit_mode=off|balanced|perf` adds residual early exit on top
  of warm-start. Reports: `phys_psi_iters_run`, `phys_psi_residual_final`,
  `phys_psi_early_exit`, `phys_psi_mode`. Default `perf` uses min 6 iterations
  and checks max `abs(new_psi-old_psi)` every 2 iterations.
- Validate with `phys_slice`'s `ocean_delta_p95`: it should stay smooth. A sudden
  jump after the iteration cut means under-convergence → raise `psi_total_iters`
  or confirm warm-start is engaging (slot present, sized `n_cells`).
- For a cold-start A/B baseline, set `psi_warm_start=false` and restore higher
  iterations; the delta in `ocean_delta_p95` quantifies the warm-start benefit.
- If ψ ever looks frozen/stale, confirm `cell_ocean_psi` is still being published
  each solve (warm-start reads what the previous solve wrote); a null/size-
  mismatched slot falls back to the zero initial guess automatically.

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

## Gameplay event bus / chunked detail 验证

经济 journal 额外检查 `get_economy_trace_report()`：

- `event_summary_ms/event_detail_ms/event_publish_ms` 分别归因语义 append、选中范围 legs 和 O(1)
  committed batch 切换；publish 不应随总 cohort 数出现新的全量扫描尖峰。
- `detail_truncated_count=0`、`evicted_event_count`、`oldest/newest_event_id` 与 consumer `gap/lag`
  是追踪完整性证据；consumer 落后不得触发 economy backpressure。
- trace OFF/SELECTIVE 与 worker/scalar 的核心 economy state hash 必须一致；worker/scalar
  `event_stream_hash` 也必须一致。
- 10M auto cadence 与固定五日建筑 benchmark 必须分别标注，不能用自动 N 性能替代默认档证据。

新增 API 探针：

- `DCWorldExt.has_method("get_gameplay_event_schema")`
- `DCWorldExt.has_method("publish_gameplay_events")`
- `DCWorldExt.has_method("poll_gameplay_events")`
- `DCWorldExt.has_method("snapshot_gameplay_event_journal")`
- `DCWorldExt.has_method("get_gameplay_event_bus_report")`

事件总线 smoke：

1. C++ vegetation pass 产生 `VEGETATION_SUCCESSION` 后，`GameplayEventBus.poll_succession_cells(&"detail_renderer")` 应返回与旧 `succession_indices` 对齐的 cell set。
2. GDScript `publish_event()` 发布 debug 事件后，用另一个 consumer id poll，确认事件 id 单调递增且不会抢走 renderer cursor。
3. `snapshot_gameplay_event_journal()` 后 `clear_gameplay_events()`，再 `restore_gameplay_event_journal(snapshot)`，`replay_gameplay_events()` 应能按 tick/type 读回同一批事件。
4. `get_gameplay_event_bus_report()` 中 `dropped_event_count=0` 是正常目标；若非 0，检查 `event_count`、`oldest_event_id/newest_event_id` 和 `consumer_lag`。

detail scatter 日志：

- 全量路径应显示 `path=gdext_chunked`（chunked 开启）或 `path=gdext`（chunked 关闭）。
- event-driven 局部刷新应显示 `path=gdext_event_chunk`，并在 `[detail_scatter/SLOW_CHUNK]` 中同时报告 `cells`、`chunks`、`sampled`、`active`、`water`、`ctx`、`knobs`、`native`、`apply`、`remaining`。
- `chunks` 应远小于 dirty `cells` 覆盖全图时的等效层数；单次小规模演替通常只重建少量 chunk。
- `sampled > 0` 表示 delta 路径把 chunk 内 MapData/Profile 采样交给 C++；`active` 是 native suitability 过滤后真正喂给 scatter 的 cell 数。若 `active=0` 但 wall time 仍高，优先看 MultiMesh apply / Godot object 成本，而不是 GDScript per-cell sampling。
- `water` 是 offset water mask 获取/构建成本；正常只有首个 layer 可能非零，其它 layer 应命中共享缓存。`ctx` 是 layer-level native common knobs 构建成本；`knobs` 是单 chunk 补 `sample_cell_indices` 的成本；`native` 是 GDExtension call；`apply` 是 `MultiMesh.buffer` 提交。
- `remaining` 长时间大于 0 表示 chunk task 被预算拆帧，这是正常降峰；若视觉滞后可提高 `detail_scatter_refresh_chunks_per_frame` 或 `detail_scatter_refresh_apply_budget_ms`。
- 若回到 `path=gdscript`，先看 `reason`：常见是旧 DLL、缺 `encode_detail_scatter_delta`、bad native payload 或 `_world_ext` 未注入。

本次实现的本机验证记录（2026-06-26）：

- 静态 `rg` 已确认 native declarations、ClassDB bindings、GDScript wrapper 和 renderer 调用点一致。
- `scons platform=windows target=template_debug` 在 `gdext` 下构建通过，并产出 `dots_ext.windows.template_debug.x86_64.dll`。
- 当前机器 PATH 和项目脚本记录路径均未找到 Godot executable，因此 headless `--check-only` / 30 tick runtime 验证需在 Godot 可执行路径恢复后执行。运行前必须重启 Godot，避免加载旧 DLL。

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

## 高倍速 FPS 跳水 / 死亡螺旋（fast-forward spiral）

**症状**：低倍速（如 x20）流畅，高倍速（如 x50）FPS 暴跌（实测到 ~5 FPS）。但单个 `[fast tick WARN]` 里 `sus` 仍只有 ~4ms、`sus_window` p95 也健康——看不出哪个 job 慢。

**关键线索**：周期采样的 `fast tick #N` 行出现 **sus 远大于单 tick 成本** 的帧，例如：

```text
fast tick #1095: 36ms (sus=34.97 render=0.73 ui=0.00 skipped_day=true)
```

`sus=35ms` 而单 tick 才 ~4ms → 这一帧把 `sus_tick_daily` **串行跑了 ~8 次**。注意 `_fast_tick_count` 是按 `day_changed`（每模拟日）自增的，不是每渲染帧，所以 `fast tick #N` 的采样间隔是"日"不是"帧"。

**根因**：`WorldClock._process` 按 `delta × speed` 反推要推进的天数。某帧变慢 → 下帧 `delta` 变大 → 跨更多天 → 一帧串行更多 SUS tick → 帧更慢，正反馈形成死亡螺旋。SUS 的 `frame_budget_ms` 是 tick **内** 预算，管不住一帧里 tick 的**个数**。

**修复（plan/best-effort-sim-stepping, 2026-06-17）**：`WorldClock` 改为 best-effort 吞吐模型——每帧最多推进 `max_sim_days_per_frame` 天、累计超 `sim_frame_budget_ms`（默认 8ms）即停，累加器里没追完的整数天丢弃不积债（`_last_day` 仍连续 +1、不跳日，故 season/year 边界都精确命中）。倍速变成"目标天/秒"，过载时是"本帧少推进几天"→有效倍速平滑降级（日历推进变慢，Paradox 式）、FPS 保持稳定。详见 `scheduling-and-job-graph.md` 的 per-frame governor 节。

**⚠️ 螺旋只是一半——真正的高倍速 FPS 杀手是 overlay 每日重 bake（2026-06-17）**：best-effort 消灭了"一帧堆叠 N 个 tick"的崩溃，但 x50 实测仍只有 ~22 FPS。`[clock/step]` 埋点（`WorldClock.debug_step_log`）打出真相：`ran=1 loop=37ms proc=37ms`——**单个**模拟日的 `_advance_one_sim_day` 就 ~37ms，而 `fast tick total` 只报 ~5ms。差额 ~32ms 来自 `_on_day_changed` 末尾、`fast_ms` 测量之后才跑的 `_refresh_overlay_data()`（约 592K 像素 fan-out；C++ `DCWorldExt` 未绑定时退 `gdscript_fanout` ~30ms）。x50 下几乎每渲染帧都推进一天 → 每帧 ~30ms overlay bake → 22 FPS。

诊断要点：
- `render-profile`（F3）的 `sus_frame_avg ≈ 45ms` vs `non_sus_frame_avg ≈ 0.1ms` + `sus_ticks=119/120` → 成本严格挂在"推进了日的帧"上。
- F9/F10/F11（地形 shader / weather overlay / DVA atlas）**全无效**——它们碰不到 data overlay 层，也碰不到 enum/sea_ice/ocean 贴图上传。别被"按了没反应"误导成 GPU 无关。
- `vram tex` 在两次 dump 间来回跳几 MB = 贴图在 `create_from_image` 重建（而非原地 `update()`），是上传/重 bake 的旁证。

**修复（overlay 墙钟节流, 2026-06-17）**：`main.gd` 给 `_refresh_overlay_data` 加第 4 道 gate `overlay_min_bake_interval_ms`（默认 100ms / 10Hz）。距上次 bake 不足该间隔就跳过且**不消费 `_overlay_dirty`**，下一个到点的帧再 bake 最新状态。仿真照常逐日推进；overlay 与模拟日解耦。低速（日间隔 ≥ interval）下永不触发、行为不变。深层优化（让 `gdext_fanout` 生效把单次 bake 压到 ~2ms）另行处理；节流是与 bake 成本无关的稳妥兜底。

**排查/调参**：
- 若高倍速仍掉帧，先确认 `fast tick #N` 是否还有 `sus` 远超单 tick 的帧；没有则瓶颈在别处（如 overlay bake，见下文）。
- `sim_frame_budget_ms` 调大 → 倍速天花板更高但每帧渲染余量更少；调小 → FPS 更稳但有效倍速更早降级。
- 这是 inter-tick 闸，与 `frame_budget_ms`（intra-tick）正交。

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
| 单 tick `sus=4ms` 但 x50 仅 5 FPS | 某个 job 慢 | 死亡螺旋：一帧串行跑了 N 个 SUS tick。看 `fast tick #N` 是否有 `sus` 远超单 tick 的帧。详见"高倍速 FPS 跳水"节。 |

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

For climate-realism CSV rechecks, run `tools/analyze_tile_climate_csv.py` on a
30+ tick recording and compare these fixed metrics before changing formulas
again:

- `wind_dir_delta_p95` / `wind_flip_gt_120deg_ratio`: direction continuity of
  `cell_wind_x/y`. These should improve without changing the unit-vector
  contract.
- `ocean_clamp_ratio`: whether `ocean_current_max_magnitude` is acting as a rare
  safety guard or as the main current shaper. Sustained p95 above a few percent
  means source/scale weights are still too hot.
- `moisture_base_corr`: how hard runtime `moisture_arr` remains anchored to
  `base_moisture_arr`. It should fall from the old near-0.98 value while
  retaining coast/inland/rain-shadow structure.
- `sea_ice_binary_ratio` and sea-ice neighbor p99: ice-edge continuity. These
  should drop without introducing low-latitude or land sea ice; use the corrected
  absolute latitude formula `abs(2 * cell_lat_norm_arr - 1)`.

Weather CSV fields should be read from `sample["weather"]`, not from
`sample["climate"]`. If `weather_dirty_mask` changes but `weather_dirty_count`
is permanently zero, first check the recorder input path before changing
weather math.

Important weather fields:

- `weather_diag_present`: the sample carried a weather breakdown.
- `weather_field_commit_path`: native or fallback commit path.
- `weather_field_commit_publish_verified`: `true` means the commit result was
  verified against visible `MapData.weather_*_arr` arrays after native/fallback
  publish.
- `weather_field_commit_publish_repaired`: `true` means native commit returned
  success but the visible `MapData` arrays did not match the solved `next_*`
  buffers, so `field_solver.gd` republished through the existing GDScript
  commit loop.
- `weather_field_commit_init_count`: number of cells whose
  `weather_field_init_arr` was visible after commit. If this is `0` while
  `weather_field_commit_path` or commit cadence advanced, the failure is a
  publish/bridge boundary, not naturally clear weather.
- `weather_field_commit_publish_reason`: reason string from the publish guard,
  for example `field_init_incomplete_0_of_6400` or `field_sample_mismatch_*`.
- `weather_refresh_convergence`: whether this tick should publish convergence.
- `weather_field_solve_tick` and `weather_convergence_refresh_stride`: cadence
  source for convergence refresh.
- `weather_commit_tick_delta` and `weather_last_commit_tick`: commit cadence
  diagnostics. Use these as the day axis for weather lifecycle analysis; partial
  field-solve ticks can otherwise make rain/fog duration look longer than the
  committed weather state actually lived.
- `weather_cold_front_count` and `weather_warm_front_count`: transient summary
  diagnostics derived from front temperature advection. These are CSV/front
  diagnostics only; they are not DataCore schema fields and do not introduce
  new weather enum values.
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

All-clear diagnosis: if every sampled row has `weather_type_arr=CLEAR`, all
continuous weather fields are zero, and `weather_field_init_arr=0`, do not tune
classification thresholds first. That pattern means the weather field was never
published to the `MapData` arrays consumed by render/CSV. Check the publish
guard fields above and the native commit path before changing weather math.
If `weather_last_commit_tick` or `weather_commit_tick_delta` advances while
`weather_field_solve_tick=-1`, `weather_field_commit_path` is empty, and
`weather_field_commit_init_count=0`, the staged weather job was bypassed rather
than merely producing clear weather. Check `weather_native_daily_available()`,
the merged weather gate in `weather_refresh_job.gd`, and whether
`native_daily_sim_mode=ACTIVE` prevented independent `weather_refresh`
registration.

`weather_native_daily_available()` 的当前判断应从
`MapGenerator.weather_native_daily_readiness_report()` 读原因，而不是只看
`has_method("run_weather_refresh_daily_pass")`。常见 block reason：

- `no_verified_staged_commit_yet`：还没有 staged weather commit 证明 visible publish。
- `field_commit_not_publish_verified`：commit 跑了，但 `MapData.weather_*` 可见数组未通过验证。
- `field_commit_required_gdscript_repair`：native commit 后靠 GDScript repair 才发布；不能作为 native daily weather authority。
- `field_init_incomplete_X_of_N`：`weather_field_init_arr` 未覆盖全图。

Native daily 自身的 slice report 还会暴露 `published_slots`、scheduler-level
`published_to_slot`、`visual_dirty_intents`、`retained_gdscript_authority`、
`retained_boundaries`、`authority_report`、`authority_blockers` 和
`graph_coverage_state`。如果 `graph_coverage_state=partial` 或
`graph_coverage_complete=false`，先看 simulation blockers；例如缺少
`runtime_hydrology_knobs` 时的 `runtime_hydrology`、owner gate 未 active 的
`season_refresh` / `ocean_currents_physical_state`、或
`legacy_sus_fallback_enabled` 仍在列表中时，只能称为 partial native daily。
`visual_uploads`、WeatherFront、LUT/ImageTexture、atlas/detail scatter 等只应出现在
`retained_boundaries`，不应阻塞 simulation graph complete。`wind_air` / `wind_surface` 已接入 graph 时，重点改看
`wind_air_ms` / `wind_surface_ms`、`published_slots` 中的 `cell_temp` /
`cell_air_mass_temp_anomaly`，以及 SHADOW hash/A-B 是否对齐。

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

## Mobile 60 FPS 调查（2026-06-14 完成定位）

实测瓶颈分布（Adreno 830，vsync_mode=1，atlas mobile=512）：

```
120 帧 sample (Shader ON, climate async on):
  frame wall ms: min=0.31  avg=25.08  p50=24.75  p95=34.57  max=58.44
  sus_ticks=3/120 sus_frame_avg=58.18ms  non_sus_frame_avg=24.23ms
  histogram: [12-16)=23 [16-20)=36 [20-24)=10 [24-28)=111 (主峰) [32-36)=40

120 帧 sample (Shader OFF, _world_quad.material=null):
  frame wall ms: min=0.10  avg=10.82  p50=8.26  p95=46.17
  sus_ticks=7/120 non_sus_frame_avg=8.42ms
  histogram: [4-8)=17 [8-12)=92 (主峰) [40+)=6
```

**结论**：
- SUS 帧（C++ + GDScript SUS）只占 **3/120 = 2.5%**，单帧 60ms 但平均贡献微乎其微
- 非 SUS 帧 117 帧每帧 ~24ms，**99% 是 GPU shader 时间**
- `_world_quad.material = null` 实测让非 SUS 帧从 24ms → 8.4ms（**主地形 shader 占 70% 帧时间**）
- weather_overlay shader 实测无影响（已用 F10 toggle 排除）
- atlas size 256 vs 512 实测无影响（已用 F12 toggle 排除）
- DVA upload 关掉只减 ~1.5ms（已用 F11 toggle 排除）

**已落地修复**（main.gd::_push_visual_toggles）：mobile 入口强制 `visual_quality=0`，
跳过：河岸 fbm 扰动 / river flow / shore 4 对角 sample / fbm octave。预期非 SUS 帧
~8-12ms → 60 FPS 可达。

调查工具（保留作未来 baseline）：

| 热键 / mobile 按钮 | 函数 | 用途 |
|---|---|---|
| F3 / Profile | `dump_render_profile()` | 120 帧 sample + 直方图 + SUS 帧关联统计 |
| F9 / Shader | `toggle_world_shader_disabled()` | _world_quad.material = null 实测 GPU 端 |
| F10 / Weather | `toggle_weather_layer_visible()` | weather overlay 排除测试 |
| F11 / DVA | `toggle_dynamic_visual_atlas_upload()` | atlas commit 排除测试 |
| F12 / Atlas | `toggle_atlas_resolution()` | atlas 256/512 GPU fillrate 测试 |



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


## Shader 像素 sample 预算（2026-06-15 审计后）

之前路线 A（water fbm 砍 4 个）+ B（ecology_visual_quality=0）实测合计仅省 0.3ms。
重新拆解后定位**真正大头**：**水面像素 36+ 个 texture sample，主因是 5×5 / 3×3 邻域采样**：

| 操作 | 修复前 sample 数 | 修复后（q=0）|
|---|---|---|
| SETUP（noise+height+enum+scalar+vector+dyn+eco）| 7 | 7 |
| `compute_offshore_depth`（height）| 25 (q≥1) / 9 (q=0) | **5**（plus pattern: center + 4 邻居）|
| `compute_water_biome_weights`（enum_atlas 3×3）| 9 | **0**（hard-cut，q=0 跳过）|
| 水面其他 fbm / features / plume / overlay shore | ~10 | ~10 |
| **水面总** | **~36** | **~23** |

陆地像素：
- SETUP 7
- `compute_terrain_normal` 4-tap = 4 height sample
- biome_detail 2-3 fbm
- shore_neighborhood q=0 = 4 enum sample
- 总约 18 sample

**关键 takeaway**：3×3 / 5×5 neighborhood sample 是 GPU 隐藏开销大头，远超 fbm（已经 packed
成 noise_tex 一次 sample 即可）。`hex_terrain shader` 本体行数（296）不代表 GPU 成本——
真正贵的是每像素 30+ texture sample，移动端 GPU bandwidth bound。

修复点：
1. `water_pipeline.gdshaderinc::compute_offshore_depth` q=0 用 5-sample plus pattern（中心+上下左右）
2. `water_pipeline.gdshaderinc::compute_water_biome_weights` q=0 hard-cut（不调 3×3 邻域）
3. q=0 仍跳过 deep_ripple / ridge_n / gyre / caustics / sparkle / lane 等（已经 gated）

预期收益：水面像素 sample 减少 ~36%，移动端水面占屏幕 50% → 总 sample 减 ~18%。
GPU fragment 时间从 13ms 预期降到 ~8-10ms → 60 FPS 接近达成。


## Mobile 60 FPS 二阶段（2026-06-15 log_next.txt 修复 6 项）

shader 路线收敛后，log_next.txt 暴露**第二轮瓶颈**：

```
frame 407–999  (visual_active=false, atlas 不可见):  FPS=117, p50=8.2ms, non_sus=8.2ms
frame 2412+    (visual_active=true,  atlas 可见):    FPS=33,  p50=25ms,  non_sus=22ms
frame 2587     ice atlas commit 期:                  max=549.95ms 巨型 spike
```

Visual active 开启后 `draw_calls 32→45`，`primitives 1654→7096` —— ocean atlas
shader 多采样 4 张 RGBA8 atlas，fragment bandwidth 翻 3 倍。

同时 SUS-cpp 持续报 `largest=refresh_climate_daily/transp/native path=gdext 19ms`，
但 transp/native breakdown 显示 `native_compute_ms=0.06`，剩余 18ms 全在
`finalize_finalizer_ms`（cell loop 5.26ms + sort 0.96ms + write_dense 0.65ms 等）。
**SUS 归因错把 transp 当瓶颈**。

落地 6 项修复（commit hash 待补，2026-06-15）：

| Fix | 位置 | 行为 |
|---|---|---|
| **#1** | `ocean_currents_job.gd::_begin_physical_round` | mobile 上 `_phys_need_visual` 在首次 bake 后强制 false。物理 solve 照跑（authority 在 cell_ocean_x/y），仅跳过 pixel atlas rebake → primitives 7096→1644，non_sus 22ms→8ms 预期。|
| **#2** | `climate_daily_system.gd::run_slice` | mobile 默认 `async_enabled=true` —— 即使 `cp.use_climate_round_async=false` 也强开。worker thread 跑整个 round（plan §async-stage-3 框架），transp/finalizer 19ms 移出主线程。|
| **#3** | `dynamic_visual_atlas_upload_system.gd::_apply_cpp_commit_task` | 包 profile 到 `Image.create_from_data` + `ImageTexture.update`/`create_from_image`。`total > 25ms` 触发 `push_warning("[atlas/commit-spike]")` 暴露 frame 2587 stall 的真实 root cause（是 VRAM alloc 同步 wait 还是别的）。|
| **#4** | 多处 print gate | (a) `world_ext.cpp` PHASE-D-DIAG 计数器改 `static int`（之前 lambda 局部变量，每 round 重置 8 次 → 累 144 行）；(b) `hex_renderer.gd` plan-c/uni 加 mobile gate；(c) `dc_system_scheduler.gd` ocean_skip diag budget mobile 8/desktop 64；(d) `map_baker.gd::set_world_ext` 同 ext re-inject 短路（之前 enum_atlas slice 每片重置 upwelling/DIAG#1 计数器，225 行）。|
| **#5** | `climate_daily_system.gd::run_slice` 返回 dict | 加 `kernel_ms` / `slice_wall_ms` / `finalizer_ms` 三个独立口径。当 `finalize_ms >= max(2ms, native_kernel * 4)` 时改 `substage→finalizer / path→data_core_finalizer / stage_name→round_finalize`，让 SUS-cpp `largest=` 不再把 transp 当瓶颈追错方向。|
| **#6** | `climate_daily_system.gd::run_slice` | mobile 上把 `_finalize_round()` 推到下一片专门跑（`_finalize_pending` 标志）。本片 done=false 返回 progress=1.0；下一 tick 入口检测 → 跑 finalize → done=true。把 5-8ms finalizer 从最后一个 pass slice 剥离出来。仅 mobile 启用，桌面端 sync slice 走原路径不动。|

排查/重读时注意：

- Fix #2 和 #6 协同：**优先级**是 #2 async（整 round 异步）；只有 ext 失败回退到 sync 时 #6 defer 才生效。两者不冲突，不重复。
- Fix #5 仅当 `finalize_ms >= max(2ms, kernel_ms * 4)` 才改 substage，所以 round 中间片不会误报 finalizer。
- Fix #4 `set_world_ext` 短路是关键：之前 enum_atlas 每个 slice 都 `set_world_ext(world_ext)` 重新注入相同对象，触发所有诊断 counter 清零；现在改成 `if _world_ext == ext: return` 让 ext 真正变化时才重置。
- Fix #1 保留首次 bake（`_phase_int_seen == -9999` 或 `_visual_round_id == 0`），避免 shader 拿到空 atlas 渲染异常。

预期总收益（mobile，2400 cells，Adreno 830）：

- non_sus_frame_avg 22ms → 8ms（Fix #1 主导）
- SUS-cpp largest 不再误指向 transp，真正瓶颈可见
- finalizer 不再制造 8ms spike（Fix #6 拆 slice + #2 async 双保险）
- 500ms commit spike 通过 `[atlas/commit-spike]` warn 自报，root cause 可定位
- 热路径打印总量降 70%（PHASE-D 系列、upwelling/DIAG#1、plan-c/uni 等被 mobile gate）


## Mobile 60 FPS 第三轮：Fix #6 实测反效果，已回退（2026-06-15）

Fix #6（finalizer 拆 slice 跨帧）真机日志显示**让 FPS 变差**：

| 指标 | Fix #1-5 中间状态 | + Fix #6 |
|---|---|---|
| FPS (fronts=12 期) | 47-66 | **27-29** |
| sus_ticks/120 | 61 | **76-79** ⬆ |
| sus_frame_avg | 28ms | **36ms** ⬆ |
| 直方图 [40+) | 2 帧 | **34 帧** ⬆ |

**Root cause**：把 round 末尾的 finalize 拆成独立 SUS slice 后：
- 每个 SUS slice 都带 scheduler 边界开销
- 1 个 round 现在占 2 个 SUS slice → 带 SUS 工作的帧数 +30%
- **finalize 5-8ms 是确定性 cost，不是随机 spike**，拆 slice 无法降低总开销，只是搬运

**Lesson**：拆 slice 不是无脑好。对于 SUS budget 已经足够（< 16.6ms / 60FPS budget）的情况下，把工作分散到更多帧反而让更多帧承担 scheduler overhead。仅当单 slice 真的撑爆 budget 时（>16ms 等）才值得拆。

Fix #6 sync + async 两条路径已在 `climate_daily_system.gd::run_slice` 和 `_run_slice_async` 中回退到原行为（done 帧立即 `_finalize_round()`）。`_finalize_pending` 状态字段保留作 sentinel，便于未来重新启用时只需切回 if 分支。


## Mobile 60 FPS 第四轮：weather fronts 三件套（Fix #7A/B/C）

log_next.txt 显示 fronts=12 时：
- `draw_calls 32→41` (+9)
- `primitives 1644→5418` (+3774)
- `non_sus_frame_avg 8→22ms`

WeatherLayer 三套并行系统：

1. **WeatherOverlayQuad** + `weather_overlay.gdshader` (1046 行) — 共享全屏 fragment shader，每像素 30+ texture sample（6-邻域 fbm + per-cell wind advection + 16-front loop）
2. **CloudShadows 池** — 16 个 Sprite2D + `BLEND_MUL`。**实际已 dead code**（云阴影迁移到 overlay shader 内），但 `_init_shadow_pool` 仍构造 16 sprite + 256×256 alpha 圆盘
3. **WeatherParticles 池** — 16 个 GPUParticles2D，每个 amount=80-900 粒子按 area 缩放。**primitives 5400 的真正来源**

落地 3 项 mobile gate（2026-06-15）：

| Fix | 位置 | 行为 |
|---|---|---|
| **#7A** | `hex_renderer.gd::set_weather_fronts` | mobile 入口 `fronts = fronts.slice(0, 4)`。桌面 16 不变。预计 primitives -2400，draw_calls -8。|
| **#7B** | `weather_layer.gd::_init_particles_pool` | mobile early return 跳过 16 个 GPUParticles2D 构造。雨/雪降级为 shader 内 streak/grain effect（line 405-460 那段）。`_sync_particles_pool` 的 `if _particles_pool.is_empty(): return` 守卫保证 NPE-safe。|
| **#7C** | `weather_layer.gd::_init_shadow_pool` | mobile early return 跳过 16 个 Sprite2D + 256×256 alpha 圆盘 ImageTexture（~262KB VRAM）。`_sync_shadow_pool` 本就已是 dead code（line 605-612 提前 return），mobile 顺便省 setup 成本。|

排查注意：

- `_sync_particles_pool` 和 `_sync_shadow_pool` 入口的 `is_empty()` 守卫是关键，让 mobile 上空池不会 NPE。
- Fix #7A 截断是在 hex_renderer 入口（最外层），下游 `_make_front_snapshots / _push_fronts_to_overlay / _sync_particles_pool` 都只看 trimmed array，`_active_count <= 4`。
- shader 内 `weather_front_count` uniform 写 4 让 `for (int i = 0; i < MAX_WEATHER_FRONTS; i++)` 早 break 跳过 12 个空 slot 的距离计算。

预期收益（mobile，fronts=12 → 实际处理 4）：

- draw_calls 41 → ~33（-8 sprite + -4 particles 收益）
- primitives 5418 → ~2000（少 ~3500 粒子）
- non_sus_frame_avg 22ms → 12-15ms 预期
- FPS 27-29 → 45-55 预期


## Mobile 60 FPS 第五轮：SUS frame budget + atlas must_run（Fix #8A/B）

log_next.txt（2026-06-15 20:01）暴露**真正的视觉延迟瓶颈**：玩家反馈"雪线和海冰更新特别慢，严重跟不上时间变化"。日志精确数据：

```
[SUS-cpp] last 30 ticks: dynamic_visual_atlas_upload ran=3 ... skipped[frame_budget_exhausted=24, policy_gated=3]
[SUS-cpp] last 30 ticks: refresh_climate_daily ran=29 ... avg=5.78ms p95=12.97ms max=14.59ms
[SUS] sim budget strict=false frame=2.00ms ...
```

- **SUS frame budget 仅 2ms**，但 `refresh_climate_daily` p95=12.97ms (climate async path 主线程 finalize + sea_ice handoff)，**一个 job 就吃光后续所有 budget**
- `dynamic_visual_atlas_upload` 优先级 250（最低），**ran=3/30 (10%)**，frame_budget_exhausted=24/30 (**80% 被饿死**)
- 雪线 / 海冰视觉源是 `dyn_atlas_smooth.B` (snow) / `ice_state_atlas.R` (ice)，profile 配置 `dynamic_visual_atlas_upload_stride=2`，但实际饿死后 **~20 仿真日才完整 commit 一次**
- 真实玩家感受：x1 速度（~10 仿真日/秒）下 atlas 每 2 秒上传一次，**远超 1 秒人眼可察觉阈值**

落地 2 项 mobile 修复（2026-06-15）：

| Fix | 位置 | 行为 |
|---|---|---|
| **#8A** | `dc_system_scheduler.gd::configure_from_profile` + `sus_scheduler.gd::set_frame_budget_ms` + `gdext/sus_scheduler_ext.h::set_frame_budget_ms` | Scheduler 层统一解释 profile budget；SUS clamp 上限从 2.0ms 改 4.0ms（C++ 端无条件放开上界）。Mobile 启动时强制 `frame_ms = max(profile, 4.0)`，desktop 仍 clamp 到 2.0ms。SUS 总预算 +2ms 给所有 job 上车机会。|
| **#8B** | `dynamic_visual_atlas_upload_system.gd::_init` | `must_run = false` → `must_run = true`。绕过 frame_budget gate，每 SUS tick 都跑 1 个 phase。slice_budget_ms=1.5 单 phase 完成单层 atlas，4 phase（dyn/eco/smo/ice）共 ~6ms 跨 4 tick 完成完整 commit。|

> 2026-07 更新：运行时 profile 已统一走 `earth_like.tres`，`SusScheduler.gd` 不再按 mobile
> 把 `sim_frame_budget_ms` 压到 4ms；当前 GDScript/C++ scheduler mirror 使用同一 16ms
> 安全上限，实际预算由 profile 决定。

预期收益：

- `dynamic_visual_atlas_upload ran` 从 3/30 (10%) → ~25-30/30 (90%+)
- atlas commit 频率从 ~20 仿真日/次 → ~2 仿真日/次（stride=2 配置生效）
- 雪线/海冰视觉延迟 x1 速度 2-3s → 0.2-0.3s（玩家不可察觉）
- mobile SUS p95 维持 9-15ms 之间，仍 < 16.6ms 60FPS 单帧 budget

注意事项：

- 三层 clamp（GDScript map_generator / GDScript sus_scheduler / C++ sus_scheduler_ext.h）都要同步放开，否则任何一层会把 4.0 压回 2.0

后续修正（2026-06-23）：`must_run=true` 后来已回退，避免 visual upload 绕过
预算造成帧尖峰。当前做法是让 `dynamic_visual_atlas_upload` 保持 optional，并通过
`use_job_should_run=true` 使用 job-local LUT catch-up 状态。诊断时看
`lut_last_due_tick`、`lut_last_refresh_tick`、`lut_refresh_pending_before` 和
`lut_catchup`：如果 stride 到期 tick 被 `frame_budget_exhausted` 跳过，下一次运行
会以 catch-up 方式补刷。cell-indirection 主路径新增 no-dirty skip：当 dirty mask
可读且 `mask_dirty_count=0`、LUT 纹理已存在、没有 ecology transition 待推进且不是
catch-up 时，报告 `path=cell_indirection_lut_skip`、`lut_skip_no_dirty=true`、
`dirty_reason=no_dirty`，用于把“该 tick DVA 被调度”与“真的重烘 LUT”区分开。
应出现 `lut_catchup=true` 并刷新 `dyn_lut`，雪盖/海冰视觉不应一直停在旧状态。
- C++ 改动需要 rebuild arm64 .so（已完成）
- 副作用：Android NDK 严格编译时 `world_ext.cpp` 暴露了 `smoothstep_fn` 跨函数引用 bug（Windows 编译时 dead-code 优化吃掉了），顺手在原地用 `smoothstep_local` lambda 修复（不影响功能）。


## Mobile 60 FPS 第六轮：phase 错峰调度（Fix #9，#8B 已回退）

玩家评估 Fix #8A/B 时指出：**"纯用预算时间来卡执行内容很不合理，这样可能导致游戏的逻辑计算发生严重的漂移。难道就不能规定每几个逻辑帧执行一次吗，然后每个逻辑帧的执行内容错开。"**

这是 SUS 设计本意。`SusPolicy.StridePolicy(stride, phase)` 第二参数就是 phase 错峰，但**全代码库 ~15 处 StridePolicy 构造全部 phase=0**：

```
搜索结果（grep StridePolicy.new(stride）：
  climate_daily_system.gd: phase=0
  sea_ice_daily_system.gd: phase=0
  dynamic_visual_atlas_upload_system.gd: phase=0
  enum_atlas_upload_system.gd: phase=0
  weather_refresh_job.gd: phase=0
  ... 全部 phase=0
```

后果：所有 stride=2 的 job 都落在偶 tick（tick 0, 2, 4...），跟 stride=1 的 climate 撞车。SUS budget 2ms 在偶 tick 被 climate + sea_ice + weather + ocean 累积超 6ms 全部抢光 → atlas 80% 饿死。奇 tick 没有 job 跑（空 tick）。

落地 Fix #9（2026-06-15）：

| 改动 | 文件 | 行为 |
|---|---|---|
| **atlas phase=1** | `dynamic_visual_atlas_upload_system.gd::_init` + `reconfigure` | mobile `phase_offset = 1`，stride=2 时落奇 tick |
| **enum_atlas phase=1** | `enum_atlas_upload_system.gd::_init` + `reconfigure` | 同上，跟 dynamic_visual 同片错峰 |
| **climate/sea_ice/weather 注释更正** | 三个 system.gd | stride=1 时 phase 无效，注释明确仿真层不动 |
| **Fix #8B 回退** | `dynamic_visual_atlas_upload_system.gd` | `must_run = true → false`，遵循 SUS 调度语义而非绕过 budget |
| **Fix #8A 保留** | `map_generator.gd` + `sus_scheduler*` | mobile budget 4ms 给偶 tick 累积工作留余地，奇 tick 让 atlas 单独跑 |

调度效果：

```
偶 tick (phase=0)：
  season_refresh (0.07ms) + climate (~1ms typical/12ms finalize) +
  sea_ice (1.33ms) + weather (0.85ms) + ocean_currents (3.66ms when due) =
  累 ~3-7ms，超 budget 时 ocean/weather 部分饿死（自适应）

奇 tick (phase=1)：
  season_refresh (0.07ms) + climate (0ms, 不跑) +
  sea_ice (0ms, 不跑) + weather (0ms, 不跑) + ocean_currents (0ms, 不跑) +
  enum_atlas (0.27ms) + dynamic_visual_atlas (1-3ms) =
  累 ~3ms，atlas 不再被饿死 ✅
```

仿真权威性保持：

- climate/sea_ice/weather 都 stride=1（每仿真日跑），phase 无影响
- atlas 配 stride=2 ≈ 每 2 仿真日上传一次（玩家不可察觉 0.2 秒延迟）
- ocean_currents 内部用 ContinuousSlicedPolicy，本身就跨 30 tick 分摊

预期收益（对比 Fix #1-7 状态）：

- `dynamic_visual_atlas_upload ran/30` 从 3 (10%) → ~15 (50%) — atlas 落奇 tick 不再被饿死
- atlas commit 实际频率 ~20 仿真日 → ~2 仿真日（profile stride=2 真正生效）
- 雪线/海冰视觉延迟 2-3s → 0.2-0.3s
- 偶 tick budget 仍可能撞，但 atlas 不在受影响 list 里

设计原则确认：

- 不再用 `must_run = true` 绕过 budget（这种"硬性兜底"等于设计错误的事后补救）
- phase 错峰是 SUS 调度的合理用法，每个 job 在自己的 tick 上跑完整 slice 而不被截断
- starvation_threshold 仍是兜底，但希望永远不触发

## ECONOMY_GRAPH 诊断

先看 `fatal` 与三条 `*_error`。任一守恒误差非 0 都是正确性故障，不应通过放宽
epsilon 解决。`saturation_count>0` 表示输入规模/参数接近数值上限；即使审计仍为
0，也要检查公式参数、异常账户和库存。

stage 判断：

- `ledger_apply` 长：命令 range 太大，查 `processed_commands/pending_commands`。
- `household_market` 长：比较 `processed_cohorts/needs/variants/components`、
  `formula_ms/clear_ms/fallback_ms/merchant_settle_ms/price_ms` 与
  `worker_tasks`；`worker_tasks=1` 可能是小 range 或 WTP 不可用。
- `structural_commit` 长：迁移/转职/归零事件过多，查 ECB 来源，不能在此全局 compact。
- `wait_commit`：计算已提前完成，正在等周期截止日；这是冻结结算隔离，不是卡死。
- `aggregate_publish` 长：cell summary 或审计扫描异常；不得改成全世界 Dictionary。
- `building_plan_ms` 长：检查是否按 owner-lot 重复解析 catalog/字符串；计划只能访问预编译 CSR
  与冻结价格。`zero_utilization_building_groups` 高时对照 expected revenue、operating cost、margin gap。
- `market_signal_ms` 长：比较 `market_signal_edges/updates` 与实际建筑 input/output 边；不得退化为
  `cell_count × good_count` 扫描。

上述 stage ms 在 worker 路径是 task CPU 时间之和，slice `elapsed_ms` 才是墙钟。
正常冻结周期中 `epoch_active=true/commit_due=false` 时不得出现屏障；世界日应继续推进。
只有 `commit_due=true && done=false` 才应看到 `economy_day_barrier`，此时模拟日不前进，
real-frame pulse 令 `continuation_slices` 增加并最终解除。周期边界出现全量尖峰时，检查
是否误恢复“全 cohort 会计清零”或“无结构变化也重建 merchant CSR”。

误差排障同时记录 `market_cycle_days/approximation_model`。消费/价格异常首先用较短强制
周期复现；如果 N=1 正常而长周期偏差大，这是近似调参问题，不是守恒错误。

UI 看到 `committed=false/busy=true` 时应同时收到 `snapshot_source=live_slice` 的完整选中
地块数组；若只有聚合摘要，说明 DLL/API 版本不匹配或查询契约回退，而不是正常等待。
Facade 缓存仅作异常兜底，不能用旧缓存覆盖更新的 live snapshot。save 返回
`save_requires_committed_boundary` 仍属于
正常隔离，不应绕过。
## BUILDING_GRAPH 诊断

- `building_employment` 长：比较 active building cells、group count、owner/employee filled；不应出现
  `cell_count × group_count` 扫描。
- `building_production` 长：检查 processed groups、input/resource/output edge 数、高价 offer
  排序，以及 `labor_signal_ms` 与 owner payroll/bonus 分摊。
- Price V3 异常：从市场快照逐项检查 household/business demand、offered supply、cost anchor、
  excess/inventory/shortage/cost/idle pressure 和 projected change，不能只看最终价格猜原因。
- `production_output_discarded>0`：商人正资金不足，不是库存 publish 失败。
- `building_resource_delta_cells=0` 且产量非零：检查 behavior/resource columns 和 extra slot；reserve
  存在而 extra slot 缺失应直接 fatal，不能静默生成资源产出。
- 农场零储量时应出现 `building_resource_generated>0`、`building_resource_consumed=0`；在下一次
  natural-resource pass 前 effective reserve 仍为 0。若提前产出，检查正 pending 是否被错误合入。
- 矿场跨多个经济周期但资源 pass 尚未运行时，负 pending 必须降低 effective reserve；关注
  `building_resource_limited_groups` 与 generated/consumed/net_delta，枯竭后产出应为 0。
- committed 后 population/money/goods error 仍必须精确为 0；`building_wages_unpaid>0` 与
  `wage_suspended_building_groups>0` 表示销售后仍无法足额支付生活工资，不表示该轮生产为零；
  `loss_suspended_building_groups>0` 才表示企业亏损状态机已停产。结合建筑 CSV 的
  `operating_state/severe_loss_cycles/recovery_cycles/purchase_intent_capacity_q16/realized_profit_margin_q16`
  判断停产原因。
- 先比较 `building_base_wages_due/paid`、投入采购现金、产出收入、销售后分配与商人购买力，不能
  用铸币掩盖。
- 市场 CSV v5 还提供 `realized_withdrawal_ema/production_input_reserve/household_available_stock/merchant_inventory_target/merchant_procurement_shortfall`；summary 同步提供 `owner_working_capital_reserved/production_input_reserved/production_input_reserve_shortfall/production_output_supported/producer_support_money_issued`；
  summary 提供 `merchant_procurement_budget/reserved/spent`。若商人现金归零，先验证 spent 未超过
  budget 且 reserved 约为冻结期初现金的 25%，再排查居民消费或外部命令，而不是把采购阶段误判为耗尽现金。
- `wage_plan_ms` 长：比较 active labor keys、当地 cohort/signature 数与消费篮子边数；不得退化
  为 cell×profession 或 cohort×building 稠密矩阵。
- 金银场景检查 `gold/silver_accepted`、对应 issued money 和 `bullion_money_issued`；总发行额必须
  等于两个分项之和并增加 `_explicit_money_mint`。普通 producer revenue 增长但 bullion=0 时总货币必须不变。
- 电力场景检查 `cycle_flow_produced/consumed/discarded`，committed market electricity stock 必须为
  0。active-cell 性能不得每 cell 扫全部 goods；清零只遍历预编译 `cycle_flow_good_ids`。
- 现代 124-good 目录会放大 MarketStore、price loop、snapshot 和 event 成本；与旧 5-good building
  基线比较时必须标注 catalog size、trace mode 和 cadence，不能把目录规模差异归咎于单个公式。
