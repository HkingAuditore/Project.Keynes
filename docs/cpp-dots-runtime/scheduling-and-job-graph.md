# Scheduling and Job Graph

本文整理当前 runtime scheduler 的链路、job 注册、切片预算和日志统计。目标是让开发者能从 `[SUS-cpp]` / `[fast tick WARN]` 反推出哪个 job 在跑、为什么被 skip、为什么 `largest` 指向某个 stage、以及哪些工作仍在 GDScript orchestration。

## 调度器层次

```text
MapGenerator._setup_sus()
  |
  | create scheduler by profile
  v
DCSystemScheduler (preferred DataCore facade)
  |
  | wraps systems, forwards to C++ SUS when available
  v
SusSchedulerExt (C++ scheduler)
  |
  | priority, depends_on, frame budget, skip accounting, reports
  v
DCSystem / SusJob run_slice(ctx)
  |
  | GDScript state machine + native pass calls
  v
DCWorldExt run_*_pass()
```

Fallback：

```text
DCSystemScheduler unavailable / disabled
  -> legacy SusScheduler.gd
  -> legacy SusJob.gd
```

两条路径的目标是报告语义尽量同形：`ran`、`slices`、`progress_ratio`、`stage_name`、`substage`、`skipped[...]`、budget window。

## 注册链路

入口是 `Project/project-keynes/scripts/geography/map_generator.gd::_setup_sus()`。

当前 `_setup_sus()` 大致做以下事情：

1. 根据 `ClimateProfile.use_dc_system_scheduler` 等 flag 选择 `DCSystemScheduler` 或 legacy scheduler。
2. 创建并配置 scheduler frame budget。
3. 注册 `season_refresh`。
4. 注册 `ocean_currents`。
5. 注册 `refresh_climate_daily`。
6. 注册 `sea_ice_daily`。
7. 注册 `enum_atlas_upload`。
8. 注册 `weather_refresh`。
9. 注册 `dynamic_visual_atlas_upload`。
10. 可能注册 native daily / environment runtime 相关 job。
11. 调用 topology/build step，使 depends graph 生效。

`DCSystemScheduler.register_system(system, cp)` 负责 feature flag gating 和 descriptor 构造。底层如果存在 `SusSchedulerExt`，会把 job descriptor 注册到 C++ scheduler；否则保留 GDScript scheduler 行为。

## 主要 runtime jobs

| id | 典型文件 | 职责 | 当前形态 |
| --- | --- | --- | --- |
| `season_refresh` | `simulation/systems/season_refresh_system.gd` / `sus/jobs/season_refresh_job.gd` | 日历/轨道相位、B+ path、慢变量缓存、atlas queue。 | GDScript stage orchestration，部分 gdext 加速。 |
| `refresh_climate_daily` | `simulation/systems/climate_daily_system.gd` | climate daily round：Pass-A/B、ocean water/land、wind、sea ice hook、transpiration。 | GDScript 6-stage state machine + 多个 C++ pass。 |
| `sea_ice_daily` | `simulation/systems/sea_ice_daily_system.gd` | 海冰日更新和 terrain flip。 | wrapper 调用 native/MapGenerator helper。 |
| `enum_atlas_upload` | `simulation/systems/enum_atlas_upload_system.gd` / legacy job | cover/vegetation/enum atlas dirty patch 和 GPU upload。 | C++ cached patch + GDScript upload。 |
| `weather_refresh` | `simulation/systems/weather_system.gd` / `sus/jobs/weather_refresh_job.gd` | weather field begin/solve/commit、front summary、可选 `hydrology_discharge`、stage-b。 | wrapper 委托 legacy job；staged begin/solve/commit 是当前可见天气权威，merged native 只可在 `weather_native_daily_available()` 放行后使用。运行期水文是链内 stage。 |
| `ocean_currents` | `simulation/sus/jobs/ocean_currents_job.gd` | physical ocean stages：SLP、wind、PSI、upwelling、raster、pixel commit。 | GDScript stage machine + C++ kernels/raster。 |
| `dynamic_visual_atlas_upload` | `simulation/systems/dynamic_visual_atlas_upload_system.gd` | dynamic smooth atlas、dirty/stride、ImageTexture update。 | GDScript upload orchestration，C++ patch/raster 辅助。 |
| `native_daily_sim` | `simulation/sus/jobs/native_daily_sim_job.gd` | native daily active/probe path。 | 仍受 gate 控制，未替代 legacy runtime authority；天气场启用而 native weather publish 未验证时必须回落到 legacy SUS jobs。 |

## Job descriptor 字段

| 字段 | 含义 |
| --- | --- |
| `id` | scheduler 统计和 depends 使用的唯一 job id。 |
| `priority` | 同 tick 内排序依据；高优先级通常先跑。 |
| `stride` / policy | 控制 job 频率，不一定每 tick 都应该 run。 |
| `depends_on` | 前置 job 未完成时当前 job 可被 `dep_pending` skip。 |
| `slice_budget_ms` | job 内部 soft budget，通常由 `run_slice()` 自己控制。 |
| `must_run` | 绕过 scheduler-wide frame budget gate，但不绕过 policy/depends。 |
| `progress_ratio` | 0..1，表示当前 round/stage 进度，不等于“该 job 今天是否完成全部业务”。 |
| `stage_name` | 当前或刚完成的主要 stage，用于 `largest` 和 debug log。 |
| `substage` | 更细粒度来源，例如 pixel range、transp apply、fronts count。 |
| `path` | 当前 slice 的执行路径，例如 `gdext`、`gdext_raster`、`data_core`、`gdscript_sliced`。 |

## Budget 语义

### `frame_budget_ms`

scheduler-wide 总预算。`SusSchedulerExt` 默认会把它 clamp 在安全范围内。每 tick 中，非 `must_run` job 会在预算耗尽后被 skip，并记录 `frame_budget_exhausted`。

注意：

- `frame_budget_ms` 约束的是 scheduler 选择是否继续启动下一个 slice。
- 它不能抢占已经进入的 C++ pass。
- 某个 C++ pass 单次执行超长时，仍会表现为当前 tick 的 `largest` 或 `total max` spike。
- 这是 **intra-tick（tick 内）** 预算：管的是单个 SUS tick 里启动多少 slice。它**管不到**一帧里串行调了多少个 `sus_tick_daily`（=多少个 SUS tick）——那是下面的 inter-tick 闸负责。

### `sim_frame_budget_ms` / `max_sim_days_per_frame`（WorldClock per-frame 闸）

plan/best-effort-sim-stepping（2026-06-17）新增的 **inter-tick（tick 间）** 预算，位于 `WorldClock._process`（`scripts/geography/world_clock.gd`）。它约束**一个渲染帧里最多推进几天**（=最多调几次 `sus_tick_daily`）：

- `sim_frame_budget_ms`（默认 8ms）：一帧用于"堆叠日级 tick"的墙钟时间盒；跑满 ≥1 天后超时即停。
- `max_sim_days_per_frame`（默认 8）：单帧推进天数硬上限（安全阀）。
- 超出部分的整数天**直接丢弃、不积债**，只保留 <1 天的小数（低速平滑）。

与 `frame_budget_ms` 的分工：`frame_budget_ms` 管 tick **内**的 slice 启动；`sim_frame_budget_ms` 管一帧里 tick 的**个数**。高倍速过载时若只有前者，帧时仍会被 N 个 tick 叠加拖垮（死亡螺旋）；后者是杜绝该螺旋的关键。详见 "Daily Wind Cadence" 节的 per-frame governor 说明。

### `slice_budget_ms`

job-local soft budget。它由 job 的 `run_slice(ctx)` 使用，例如：

- climate daily 每次推进一个 sub-pass 或 sub-stage。
- weather field solver 按 cell budget 切片。
- ocean raster 按 pixel range 切片。
- atlas upload 按 dirty patch/phase 推进。

`slice_budget_ms` 是协作式预算，不是硬中断。

Weather field 的 cell budget 来自 `weather_field_slice_cells()`，当前按
`ClimateProfile.weather_field_slice_cells` clamp 到 `100..6400`，默认 `2400`。
当 GDExtension weather field 可用且 `n_cells <= 6400` 时，`map_generator`
优先返回 `n_cells`，让 native field solve 一次覆盖全图。目标是每 1-2 个模拟日
完成一次 `gdext_commit`；CSV 中的 `weather_commit_tick_delta` /
`weather_last_commit_tick` 是判断天气生命周期 cadence 的权威字段。若该值被压得太低
或 native 不可用，field solve/commit 会跨过多 tick，CSV 中会表现为天气生成、变化、
消失频率偏慢；这属于切片 cadence 问题，不一定是分类规则问题。

Merged/native daily weather scheduling rule (2026-06-22): method presence is
not a handoff contract. `weather_refresh_job` only enables the one-shot
weather transaction when `MapGenerator.weather_native_daily_available()` returns
true. `native_daily_sim` uses the same gate; if weather field is enabled and the
gate is false, ACTIVE registration is refused so normal `weather_refresh` still
registers and publishes the staged field. This prevents the failure pattern
where cadence diagnostics advance but `weather_field_init_arr` and all weather
field arrays remain zero.

### `hydrology_discharge`

`runtime_hydrology_enabled=true` 时，`weather_refresh` 的 sliced round 顺序为：

```text
weather_begin -> weather_solve -> weather_summary
  -> hydrology_discharge -> weather_commit(stage_b)
```

这个 stage 不单独注册 `HydrologyDischargeSystem`，因为它依赖当天已经提交的 `weather_precip`，并且要在 stage-b 植被动态读取 `soil_moisture/water_balance_30d` 前完成。report 字段包括 `stage_name=hydrology_discharge`、`substage=route_full`、`path`、`published_to_slot`、`native_ms`、`compute_ms`、`flush_ms`、`refresh_ms`、`water_budget_error`、`river_discharge_p95/max`、`flood_count`。

### `must_run`

`must_run=true` 只绕过 frame budget gate。它用于避免关键物理/气候推进被长时间饿死。

典型语义：

- `ocean_currents` 需要持续推进物理 stage，否则 ocean/wind/PSI 会冻结。
- climate daily 曾因被 budget 掐断导致后续 weather/ocean 失去新输入，因此相关 job 需要谨慎配置。

风险：

- 过多 `must_run` 会削弱 frame budget 的保护。
- `must_run` job 内部仍应切片，不能把所有重计算一次塞进主线程。

### Starvation 防护

legacy `SusJob` 和 C++ `SusSchedulerExt` 都维护 skip 统计。长期 `frame_budget_exhausted` 会让某些 job 的 progress 停滞，表现为：

- `ran` 远小于窗口 tick 数。
- `skipped[frame_budget_exhausted=N]` 持续增长。
- weather/fronts 或 atlas 可视化明显滞后。

排查时先看 job 是否应该 `must_run`，再看上游 `largest` 是否长期吃掉预算。

## Depends 语义

`depends_on` 用于保证输入链路顺序。例如 weather 依赖 climate 的设计曾导致云层几十天才动一次；后续 weather refresh 取消了某些严格 depends，让天气可以独立按频率推进。

使用规则：

- 只有存在硬数据依赖时才设置。
- 如果上游 job 可能跨多 tick 才完成，下游会被 `dep_pending` 拖慢。
- 对视觉/上传类 job，宁可允许滞后，也不要阻塞物理计算。

## Report 聚合

每个 `run_slice()` 返回 Dictionary，scheduler 聚合为：

- last tick report：当前 tick 每个 job 是否 ran、elapsed、stage、path。
- job stats：过去 `log_interval_ticks` 窗口内每个 job 的 avg/p95/max/slices/skipped。
- budget window：过去 N ticks 的 total p95/max、over_1ms 计数、largest slice。

`main.gd` 再把这些报告输出为：

```text
[SUS-cpp] last 30 ticks: refresh_climate_daily ran=30 avg=2.27ms p95=18.08ms max=18.71ms slices=30
[SUS-cpp] budget last 270 ticks: total_p95=17.82ms max=28.54ms over_1ms=203 largest=refresh_climate_daily/transp/apply path=gdscript_sliced 28.49ms
```

## 统计字段解释

| 字段 | 含义 | 注意 |
| --- | --- | --- |
| `ran` | 窗口内实际执行 `run_slice()` 的次数。 | 小于窗口长度不一定是 bug，可能被 policy/stride 控制。 |
| `avg` | 执行过的 slice 平均耗时。 | 不包括 skipped。 |
| `p95` | 执行过的 slice 95 分位。 | 小样本时 p95 可能等于 max。 |
| `max` | 窗口内最大 slice。 | 最适合定位 spike。 |
| `slices` | job 返回的 work slices 数。 | 一个 `run_slice()` 内可能报告多段业务。 |
| `skipped[...]` | 按原因聚合的跳过次数。 | `frame_budget_exhausted` 是最常见预算问题。 |
| `total_p95` | tick 级 SUS 总耗时 p95。 | 与单 job p95 不同。 |
| `over_1ms` | 窗口内 SUS 总耗时超过 1ms 的 tick 数。 | 用于感知整体压力。 |
| `largest` | 窗口内最大 slice 的 job/stage/substage/path。 | 可能来自旧 spike，不一定是当前最后一 tick。 |

## `largest` 的正确读法

`largest=refresh_climate_daily/transp/apply path=gdscript_sliced 28.49ms` 表示：

- 在 budget window 内，最大单 slice 属于 `refresh_climate_daily`。
- job report 的 `stage_name` 是 `transp`。
- `substage` 是 `apply`。
- report 的 `path` 是 `gdscript_sliced`。
- 耗时 28.49ms。

它不等于“当前 tick 仍然在 GDScript 路径”。要结合最新 job breakdown：

- 如果同一段 `[fast tick WARN]` 日志后面出现 `transp/native breakdown source=current diagnostic_wall_ms=0.35 native_compute_ms=0.016 ...`，说明当前 transp native compute 很小，`largest` 可能保留了窗口内旧 spike。
- `source=cached` 表示当前 WARN 打印发生在 climate round finalize 后，日志使用的是同一 breakdown 中缓存的最后一次 transp/native 诊断。
- 如果连续多个窗口 `largest` 都指向同一 `path=gdscript` 且 stage breakdown 也没有 native 字段，才说明当前仍在 fallback。

## Job 开发规则

- `run_slice()` 必须返回结构化 report，至少包含 `done`、`elapsed_ms`、`progress_ratio`、`stage_name`。
- C++/fallback path 必须写进 report，不能只写日志。
- 长 pass 要拆 stage 或 cell/pixel range，不要依赖 scheduler 抢占。
- `must_run` 只用于物理/气候等不能冻结的系统，不用于普通上传。
- 上传类 job 可以被 budget skip，但要有 starvation 保护或 dirty queue 机制。
- job 内部调用 C++ pass 后，必须把 native breakdown 合并进 report，供 `main.gd` 输出。

### 陷阱：weather 有两条调度路径，合并 native 路径绕过 stage 钩子

`weather_refresh_job` 有两条互斥路径（`_should_use_merged_native_weather` 选择）：

1. **切片状态机**（fallback）：`begin_weather_refresh_stage_a` → 多次 `run_weather_refresh_stage_a_slice` →
   `commit_weather_refresh_stage_a`(stage 2) → `hydrology_discharge`(stage 3) → stage_b。每个 stage 是 GDScript 钩子。
2. **合并 native facade**（默认快路径）：单 slice 调 `map_generator.refresh_weather_daily` → `try_run_refresh_daily_combined_gdext`
   → 一体化 C++ `run_weather_refresh_daily_pass`。**它完全绕过切片状态机的所有 stage GDScript 钩子**
   （见 map_generator.gd 注释"合并 path 完全绕过了 stage_b GDScript 入口"）。合并 facade 必须自己显式补做
   stage_b 才需要的副作用（如 enum atlas dirty mark）。

**规范**：任何"每轮一次"的 weather 子步骤，**不能只挂在切片状态机的 stage 钩子上**——默认的合并路径会绕过它，导致该步骤静默不执行（典型症状：pass 从不运行、其输出 SoA 恒为初值）。正确做法二选一：
- **挂在两条路径共同必经的 C++ 入口**：合并路径内部也调 `run_weather_field_solve_pass`，所以把每轮子步骤
  内联进它、用 `start_idx==0` 触发（一轮第一个切片）即可两条路径都执行。**ψ(synoptic eddy)推进就是这样挂的**
  （world_ext.cpp `run_weather_field_solve_pass` 内，`start_idx==0` 时对全场推进一次 ψ，主循环只读）。
- 或在合并 facade(`refresh_weather_daily`)里也显式调用一次，与切片路径对称。

诊断"pass 没运行 vs 数据没写入"：先确认调度路径（合并 vs 切片），再看 pass 是否在该路径上被调用。`weather_refresh_job`
没运行的子步骤，其 C++ 端不会有任何 log/计时字段——这是"没运行"（调度没挂上），区别于"运行了但 publish/flush 没把结果写回消费层"（数据没写入）。

## Daily Wind Cadence

`WorldClock.day_changed(day_idx)` is the authoritative daily tick source. Each
`day_changed` drives exactly one SUS tick (`one day_changed == one SUS tick`).
`main.gd` forwards that signal day and `WorldClock.season_phase_for_day(day_idx)`
to `MapGenerator.sus_tick_daily()`, so each tick uses its own day/phase.

Per-frame governor (plan/best-effort-sim-stepping, 2026-06-17): `WorldClock._process`
now uses a best-effort throughput model instead of replaying every crossed day.
The speed multiplier is a *target* days/sec; each rendered frame advances at most
`max_sim_days_per_frame` days and stops once the per-frame wall-clock box
`sim_frame_budget_ms` (default 8ms) is exceeded. The accumulator's leftover whole
days are **dropped, not carried** (only the sub-day fraction is kept), so debt
cannot accumulate. This removes the fast-forward spiral-of-death (at high speed a
single hitch used to stack many `sus_tick_daily` calls into one frame, dragging
frame time to ~200ms / ~5 FPS). `_last_day` still increments by exactly 1 per
advance and is never skipped, so season/year boundaries are always hit; "dropping"
means the engine advances *fewer days this frame*, i.e. when the target exceeds
sustainable throughput the effective speed degrades smoothly (the in-game date
advances slower than nominal, Paradox-style) while FPS stays stable. On capable
hardware the box is never hit and the full target speed runs (e.g. 50x ≈ 0.83
days/frame is well under the ~120 days/sec ceiling at 8ms/4ms-per-tick).

`season_phase` here is an orbital/calendar coordinate only. Climate forcing is
derived downstream from subsolar latitude, daily insolation, day length, thermal
inertia, pressure, wind, and moisture fields.

`SusSchedulerExt` evaluates the registered policy descriptor directly for the
normal hot path. A job can opt into its GDScript `should_run(ctx)` by setting
`use_job_should_run=true`; reserve that for stateful eligibility that cannot be
encoded as a policy descriptor. `ocean_currents` deliberately stays on the
descriptor path and is registered with `AlwaysPolicy` even though the heavy
ocean chain is not meant to run every day. The job remains eligible for the C++
daily wind prepass, while its internal `_slow_slice_policy` gates
PSI/ocean/upwelling/raster work by
`ocean_currents_period_ticks / ocean_currents_slice_count`.

Expected daily reports:

- `stage_name=daily_wind_prepass`, `path=gdext_daily_wind` (both kernels),
  `gdext_daily_wind_slp` (SLP-only day), or `gdext_daily_wind_wind` (wind-only
  day) depending on the 2-tick split (below).
- `wind_period_ticks=1` for the daily wind prepass.
- `ocean_period_ticks`, `slice_count`, and `ticks_per_slice` describe the slow
  ocean/raster chain, not the daily wind chain.
- `daily_wind_sim_day` / `sim_day` should advance by one for each SUS daily
  tick, including catch-up ticks emitted from one rendered frame.

### Daily wind SLP / wind attribution

`run_daily_wind_field_update()` runs two C++ authority kernels in one round —
the SLP field pass (`run_slp_field_pass`, ~3-4ms) and the wind field pass
(`run_wind_field_pass`, ~1.5ms). To make the scheduler log distinguish the two
without changing the kernels, the report now carries:

- `slp_ms` / `wind_ms`: per-stage native timing for the SLP and wind passes.
- `slp_stage_name=daily_wind_slp`, `wind_stage_name=daily_wind_wind`: stable
  stage labels.
- `dominant_stage` (`daily_wind_slp` or `daily_wind_wind`) and
  `dominant_stage_ms`: whichever sub-stage consumed the most time this round.

On a wind-only day the ocean job's slice report sets
`substage = dominant_stage`, so `sus_window largest=ocean_currents/
daily_wind_prepass/<daily_wind_slp|daily_wind_wind>` points straight at the
sub-stage that ate the budget. The slice report also surfaces
`daily_wind_slp_ms`, `daily_wind_wind_ms`, `daily_wind_dominant_stage`, and
`daily_wind_dominant_stage_ms` directly (independent of the
`_record_phys_diag` `daily_wind_*` prefix merge).

`main.gd._print_daily_breakdown()` prints a dedicated `daily_wind stage=… path=…
slp=… wind=… total=… refresh=… dominant=…/… slp_dp95=… wind_dp95=… commit=…
reason=…` line for the `ocean_currents` job whenever `daily_wind_due=true` (the
tick the prepass actually ran), mirroring the existing climate/weather/sea_ice
breakdown lines. When SLP actually ran this tick it also prints a
`daily_wind/slp_internal passA=… passB=… norm=… marshall=…` line.

### 2-tick SLP/wind split

`plan/daily-wind-stage-split` (profile flag `ClimateProfile.daily_wind_split_passes`,
default `true`) staggers the two daily authority kernels across adjacent game
days instead of running both every day:

- `OceanCurrentsJob._daily_wind_stage_for(ctx)` picks the `stage` argument passed
  to `run_daily_wind_field_update()`: `"slp"` on even `day_index`, `"wind"` on
  odd `day_index`, and `"both"` for the first prepass after a reset (cold-start
  safety net). A wind-only day whose `map.slp_arr` size is stale falls back to
  running SLP too (`stage_note=wind_only_slp_primed`).
- The single-tick SUS peak drops from ~5ms (SLP+wind) to ~3ms (SLP day) / ~1ms
  (wind day). SLP and wind each refresh every other day; at 20–50x this is
  imperceptible. The prepass `path` becomes `gdext_daily_wind_slp` /
  `gdext_daily_wind_wind` on split days, and `gdext_daily_wind` when both run.
- The report adds `stage_requested`, `slp_ran`, and `wind_ran` so logs can tell
  which kernel actually ran. On an SLP-only day `wind_ms=-1`; on a wind-only day
  `slp_ms=-1`. `dominant_stage` is the single stage that ran (or the larger when
  both ran), keeping `sus_window largest` attribution stable.
- Set the flag `false` to restore the merged every-day path for regression or
  low-speed precision.

## Ocean physical / visual scheduling

`ocean_currents` now separates simulation authority from visual atlas work
inside the existing job.

- Physical state is reported with fields such as `phys_round_active`,
  `physical_round_id`, `phys_phase_locked`, and the usual physical stage/path
  breakdown. This state owns SLP, wind, PSI, ocean current, and upwelling
  authority.
- Visual state is reported with `visual_round_active`, `visual_round_id`,
  `visual_pending_commit`, `visual_pixel_progress`, `visual_lag_ticks`,
  `visual_next_pixel_idx`, and `visual_total_pixels`. This state only describes
  raster/atlas catch-up.
- `should_run()` should remain a pure eligibility check where possible.
  Climate-defer bookkeeping and physical/visual state mutation belong in
  `run_slice()` so scheduler probes do not change job state.
- A visual raster or pending visual commit may make the job eligible, but it
  must not block the next physical round. If visual work falls behind and
  `ocean_visual_rebake_drop_stale=true`, stale visual work can be discarded and
  restarted from the newest physical fields.
- Legacy report aliases such as `round_active`, `pending_commit`, and
  `next_pixel_idx` are compatibility fields. Prefer the `phys_*` and
  `visual_*` fields for new diagnostics.

## Cell LUT Catch-Up

With cell-indirection enabled, the world-map snow/ice visual path is the
per-cell dynamic LUT (`dyn_lut.B/A`). `dynamic_visual_atlas_upload` remains a
budgeted optional job, but it sets `use_job_should_run=true` and tracks
`lut_last_due_tick` / `lut_last_refresh_tick`. If the stride due tick is skipped
by `frame_budget_exhausted`, the next eligible tick reports `lut_catchup=true`
and refreshes the LUT instead of waiting for the next stride. This fixes
intermittent stale snow cover without returning the whole upload job to
`must_run=true`.
