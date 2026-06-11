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
| `weather_refresh` | `simulation/systems/weather_system.gd` / `sus/jobs/weather_refresh_job.gd` | weather field begin/solve/commit、front summary、stage-b。 | wrapper 委托 legacy job，内部可走 merged native。 |
| `ocean_currents` | `simulation/sus/jobs/ocean_currents_job.gd` | physical ocean stages：SLP、wind、PSI、upwelling、raster、pixel commit。 | GDScript stage machine + C++ kernels/raster。 |
| `dynamic_visual_atlas_upload` | `simulation/systems/dynamic_visual_atlas_upload_system.gd` | dynamic smooth atlas、dirty/stride、ImageTexture update。 | GDScript upload orchestration，C++ patch/raster 辅助。 |
| `native_daily_sim` | `simulation/sus/jobs/native_daily_sim_job.gd` | native daily active/probe path。 | 仍受 gate 控制，未替代 legacy runtime authority。 |

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

### `slice_budget_ms`

job-local soft budget。它由 job 的 `run_slice(ctx)` 使用，例如：

- climate daily 每次推进一个 sub-pass 或 sub-stage。
- weather field solver 按 cell budget 切片。
- ocean raster 按 pixel range 切片。
- atlas upload 按 dirty patch/phase 推进。

`slice_budget_ms` 是协作式预算，不是硬中断。

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

- 如果同一段日志后面出现 `transp gdext wall=0.35 native=0.029 ...`，说明当前 transp native compute 很小，`largest` 可能保留了窗口内旧 spike。
- 如果连续多个窗口 `largest` 都指向同一 `path=gdscript` 且 stage breakdown 也没有 native 字段，才说明当前仍在 fallback。

## Job 开发规则

- `run_slice()` 必须返回结构化 report，至少包含 `done`、`elapsed_ms`、`progress_ratio`、`stage_name`。
- C++/fallback path 必须写进 report，不能只写日志。
- 长 pass 要拆 stage 或 cell/pixel range，不要依赖 scheduler 抢占。
- `must_run` 只用于物理/气候等不能冻结的系统，不用于普通上传。
- 上传类 job 可以被 budget skip，但要有 starvation 保护或 dirty queue 机制。
- job 内部调用 C++ pass 后，必须把 native breakdown 合并进 report，供 `main.gd` 输出。

## Daily Wind Cadence

`WorldClock.day_changed(day_idx)` is the authoritative daily tick source. If a
frame crosses multiple integer days, `WorldClock` emits one `day_changed` per
crossed day so the SUS tick stream remains `one tick == one game day`.
`main.gd` forwards that signal day and `WorldClock.season_phase_for_day(day_idx)`
to `MapGenerator.sus_tick_daily()`, so catch-up ticks do not reuse the final
frame's day or phase.

`season_phase` here is an orbital/calendar coordinate only. Climate forcing is
derived downstream from subsolar latitude, daily insolation, day length, thermal
inertia, pressure, wind, and moisture fields.

`ocean_currents` is registered with `AlwaysPolicy` even though the heavy ocean
chain is not meant to run every day. This is intentional: `SusSchedulerExt`
only evaluates the registered policy descriptor, not the job's GDScript
`should_run()` override. The job must therefore be eligible every day so it can
run the C++ daily wind prepass, while its internal `_slow_slice_policy`
continues to gate PSI/ocean/upwelling/raster work by
`ocean_currents_period_ticks / ocean_currents_slice_count`.

Expected daily reports:

- `stage_name=daily_wind_prepass`, `path=gdext_daily_wind` on wind-only days.
- `wind_period_ticks=1` for the daily wind prepass.
- `ocean_period_ticks`, `slice_count`, and `ticks_per_slice` describe the slow
  ocean/raster chain, not the daily wind chain.
- `daily_wind_sim_day` / `sim_day` should advance by one for each SUS daily
  tick, including catch-up ticks emitted from one rendered frame.
