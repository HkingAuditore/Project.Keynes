# Scheduling and Job Graph

## 2026-08 continuation budget contract

固定预算仍为 `sim_frame_budget_ms=8ms`、`sim_slice_budget_ms=3ms`；Country/Economy
只在 deadline-critical 时获得启动机会，普通诊断不得扩大单片 native 调用。每个
continuation 报告新增 `continuation_budget_exhausted`、
`continuation_started_slices`、`continuation_completed_slices` 和
`continuation_blocked_by_stage`，用于区分预算截断、stage barrier 和正常完成。
跨多个渲染帧聚合时 exhausted 取 OR，并累计
`continuation_budget_overrun_frames` / `continuation_max_budget_overrun_ms`；最后一帧正常完成
不得抹掉前一帧的预算超限证据。

Country 的 research pending queue 不新增 SUS node，Economy 保持锁定市场 N∈[1,5]、
计划 P∈[5,15]、投资 I∈[10,30]（I > P）、原 stage 顺序和 frozen epoch authority。Bio occupancy 的第一阶段是每日完整覆盖；
切片开关关闭时 one-shot 是正式路径；打开后 `bio_occupancy_daily` 每次 scheduler
访问只推进一个固定 `BIO_OCCUPANCY_SLICE_CELLS=2048` 范围。四个阶段
（persistence/diffusion/merge/publish）通过 `bio_occupancy_day_barrier` 冻结同一
语义日，只有最终 slice 才允许发布 occupancy/discovery；完成前不得让 WorldClock
启动下一日。该 job 保持 `must_run=false`、`max_slices_per_tick=1`，不会用 job-local
8ms 绕过全局预算。slice cursor/staging 是 transient，不跨存档、不进入 state/event
hash；能力不足或校验失败必须显式回退并记录失败阶段。
若首片在普通 SUS tick 中被 `frame_budget_exhausted`/`strict_budget_one_job` 跳过，
MapGenerator 将其转为 pending-day barrier，由下一 pulse 启动首片，不会静默丢失该日。

Native daily ACTIVE 若在 `run_native_daily_slice` 返回 `done=false`，同样设置
`native_daily_day_barrier`。下一渲染帧的 continuation pulse 优先续接 native daily，
并在同一 `sim_frame_budget_ms` 内连续推进同步切片（包含 deferred JIT patch 的下一调用），
直到 round 完成、到达“预算减 3ms 不可抢占片余量”的启动截止线或 64 片防御上限；然后再续接 Bio，最后才处理
Country/Economy ACK。C++ 仍独占 graph/node/range cursor，每次 native call 仍是不可抢占的
原子切片；这里改变的只是切片之间是否强制空等一个渲染帧。round 完整提交后才释放 barrier。这样
不会把不同 day context 混入同一个 native round，也不会让不可抢占的诊断/经济 drain
延迟 climate 或 occupancy 的提交。

运河不新增 scheduler/runtime：Economy 每日边界推进项目并提交 Effect，Effect gameplay
adapter 原子发布边；现有 `runtime_hydrology` 尾部运行稀疏运河传播；视觉上传仍是 Godot
retained boundary，且每帧最多一个 array layer。详见 [运河运行时](./canal-runtime.md)。

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

## Effect Runtime ordering

`effect_runtime` is a production `DCSystem` wrapper. It is configured and
registered directly by `MapGenerator._setup_sus()` before country/economy
bootstrap, so an economy or country initialization early return cannot starve
the independent effect graph. Its fixed ordering is
`trigger_runtime` priority 80 -> `ideology_runtime` priority 82 -> `effect_runtime` priority 85 ->
`modifier_daily` priority 90 -> `gameplay_effect` priority 95 ->
`country_daily` priority 255 -> `economy_daily` priority 260. The effect job is deadline-critical only when
`effect_should_run(day)` reports due instances, pending transactions, or an
unfinished same-day cursor. It runs one cooperative slice per scheduler visit and returns
`done=false` while the native instance cursor is incomplete; it never advances
country, economy, Modifier, or conserved state itself.

Within a slice, a contiguous declarative candidate batch of 64 or more uses
worker planning when the platform provides real threads. Planning reads frozen
Effect slabs only; deterministic serial replay retains all transaction and
cadence writes. Behavior callbacks remain serial until their owner declares
them thread-safe. No-worker platforms use the same plan/replay contract on the
calling thread.

After its native evaluation slice, `EffectRuntimeSystem` first calls the C++
Economy adapter, then Modifier, Country, and Gameplay adapters. Economy goes
first because its generation-safe transaction preflight can terminally reject
a malformed family command before a mixed transaction stages a new Modifier
row. `ModifierDailySystem` calls
`ack_effect_native_modifier()` immediately after `run_modifier_daily()`. Thus
the ordering is not merely a priority convention: Modifier is the safe commit
boundary for native Effect commands. `EffectFacade.dispatch_transactions()` is
still called for unsupported/custom commands only.

`FAMILY_COMMIT` does not evaluate effect programs. It only reconciles sparse source bindings,
publishes frozen metric revisions, and freezes family behavior-factor CSR from the same metric
snapshot; priority 85 performs evaluation on its next eligible scheduler
visit. A domain rejection leaves the instance due for the next day, while ACKed EVENT_ONCE/retire
transitions are reclaimed. This keeps structural ownership in Economy and lifecycle/transaction
ownership in EffectRuntime without a same-stage callback.

`ideology_runtime` priority 82 uses independent command, pending-ACK, and active
progress budgets. A slice returning `done=false` keeps a same-day continuation;
it may not carry unfinished work silently into the next calendar day. Pending
ACK traversal is O(pending), active progress is O(active), and a quiescent day
does not inspect sparse discovered ideas. Economy priority 260 publishes the
next committed class-opinion revision, so ideology commands earlier in the same
day intentionally consume the previous committed revision.

Country research completion registers the technology Effect instance during
`country_daily` (255), after that day's Effect slot (85) has already run.
The country slice then raises `country_day_barrier` when Effect or Modifier still
has due work, because `country_should_run` is already false after `_last_research_day`
advances. `_continue_economy_inflight()` drains Trigger/Ideology opportunistically,
then loops the hard Effect→Modifier→gameplay ACK chain. Trigger/Ideology
`should_run` must not starve an in-flight economy epoch or pin the calendar:
the country barrier stays up only while that hard ACK chain is still due **and**
economy catchup is in flight. After Country finishes, continuation still runs
economy slices even if the hard ACK chain is not yet idle. `_drain_native_effect_ack_chain()`
is shared with `advance_save_boundary()`. If a pending technology's Effect instance still has
not ACKed by the next country day, Country applies the permanent `UNIQUE_SOURCE`
Modifier directly so the completed tag cannot stay pending forever.

Trigger handoff often stamps Country `DISCOVER` commands with
`effective_day = event.day + 1`. Those future-dated transactions stay queued,
but `effect_should_run` / `country_should_run` only return true once the command
is due. Pinning the current day on tomorrow's ACK livelocked the starter soak
when occupancy/breakthrough evidence first crossed a Trigger threshold.

Backend fallback：

```text
DCSystemScheduler
  -> SusSchedulerExt when GDExtension is loaded
  -> SusScheduler.gd backend fallback when the extension is unavailable
```

`_setup_sus()` 不再选择 legacy scheduler 生产分支；`SusScheduler.gd` 只作为
`DCSystemScheduler` 的内部 backend / stale-DLL fallback。两条 backend 的目标是
报告语义尽量同形：`ran`、`slices`、`progress_ratio`、`stage_name`、`substage`、
`skipped[...]`、budget window。

## 注册链路

入口是 `Project/project-keynes/scripts/geography/map_generator.gd::_setup_sus()`。

`WorldRuntimeHost.generate_world()` 是 scheduler 生命周期的外层可见性边界：生成开始时先将
runtime 标记为不可 tick 并暂停 `WorldClock`，只有地图生成、全部 system 注册、topology build
以及可选存档恢复全部成功后，才开放 `run_daily_tick()` 并发布 `world_ready`。新游戏恢复生成前的
暂停状态；读档保留 `world_clock` provider 恢复出的权威状态。生成失败保持暂停且不开放 tick。
`DCSystemScheduler.tick()` 遇到未 build topology 仍须报错；不得在 scheduler 内自动 build 或吞错来
掩盖 host 生命周期违规。

当前 `_setup_sus()` 大致做以下事情：

1. 创建 `DCSystemScheduler`，并由 scheduler 读取 `ClimateProfile` 配置 frame/strict budget。
2. 注册 `season_refresh`。
3. 注册 `ocean_currents`。
4. 注册 `natural_resource_daily`（**保留边界 job**：在 native/legacy 分叉之前注册，与 `season_refresh`/`ocean_currents` 同级，两条路径都生效）。reads `cell.temp`/`cell.moisture`，`build_topology` 自动排序（不加硬 `depends_on`）；`must_run=true`，避免被 `native_daily_sim`（单 Job 即可超 frame budget）之后的 `frame_budget_exhausted` 守卫每日跳过 → reserve 永不演化。
5. 当 native daily ACTIVE 可注册时，注册 `native_daily_sim` 并保留 visual upload jobs，然后 **early-return**（不再注册下面的 legacy 气候/天气 job）。
6. 否则（legacy 路径）注册 `refresh_climate_daily`、可选 `sea_ice_daily`、`enum_atlas_upload`、`weather_refresh`、`dynamic_visual_atlas_upload`。
7. 可能注册 native environment runtime 相关 job。
8. 调用 topology/build step，使 depends graph 生效。

> ⚠ 历史 bug（2026-06 修复）：`natural_resource_daily` 曾只在 legacy 分支注册（步骤 6 内），native daily ACTIVE 时被步骤 5 的 early-return 跳过，导致资源 reserve 永不更新。修复为提到分叉前作为保留边界 job + `must_run=true`。回归测试见 `tests/natural_resource_daily_schedule_test.gd`。

`DCSystemScheduler.register_system(system, cp)` 负责 feature flag gating 和 descriptor 构造。底层如果存在 `SusSchedulerExt`，会把 job descriptor 注册到 C++ scheduler；否则保留 GDScript scheduler 行为。`MapGenerator` 只创建 job 并传入 map/world/baker/native ext 等上下文；profile 到 budget/policy 的解释在 `DCSystemScheduler.configure_from_profile()` 和 `DCSystemScheduler.configure_job_from_profile()` 内完成。

## 全平台 profile bucket 错峰

错峰启动策略由 `ClimateProfile` 统一配置，并在 `DCSystemScheduler.configure_job_from_profile()` / `apply_job_schedule()` 中解释。job 构造函数只保留本地默认 cadence；注册到 SUS 前会被 profile bucket 覆盖，避免各 job 内部继续按 `OS.has_feature("mobile")` 硬编码 phase。

默认配置：

| Job / bucket | 默认 stride | 默认 phase | 说明 |
| --- | --- | --- | --- |
| `ocean_currents` | `AlwaysPolicy` | n/a | 每 tick 进入 job-local `should_run()`；daily SLP/wind 不 bucket-gate，但由 `ClimateProfile.ocean_daily_wind_period_ticks`（默认 3）降频；慢层 PSI/ocean 由内部 `ContinuousSlicedPolicy` 控制。 |
| `native_environment_runtime` | `sim_stagger_bucket_stride=8` | `0` | native environment 桶。 |
| `refresh_climate_daily` / `native_daily_sim` | `sim_stagger_climate_stride=2` | `1` | climate 桶；native daily ACTIVE 用同一 climate cadence。 |
| `dynamic_visual_atlas_upload` | `8` | `2` | dynamic visual 桶（**仅退役的逐像素 fallback 路径用此 stride**）。cell-indirection LUT 主路径的刷新 cadence 已与此错峰桶解耦：见下文 §Cell LUT Catch-Up（按 base stride，默认每 tick due）。 |
| `weather_refresh` / `enum_atlas_upload` | `8` | `4` | weather 下游与 enum atlas 桶。 |
| `sea_ice_daily` | `8` | `6` | sea ice 桶。 |

`sim_stagger_enabled=false` 会回到各 job 的基础 stride/phase；`ocean_currents` 在关闭错峰时保持 `AlwaysPolicy`，其慢层物理 cadence 继续由内部 `ContinuousSlicedPolicy` 和 ocean period knobs 控制。

这和 `strict_budget_enabled` 不是同一个机制：profile bucket 是 **tick 入口前的 policy gate**，目标是让重型 job 分布在不同 tick；strict budget 是 **tick 内预算模式**，会在同一 tick 中尽量只放行一个 optional job，并以 `strict_budget_one_job` 形式出现在 skip 统计里。默认不要用 strict round-robin 替代 bucket phase。

### Gate 归属

当前调度 gate 分层如下：

| Gate | 配置/解释层 | 执行层 | skip reason |
| --- | --- | --- | --- |
| 普通 frame budget | `DCSystemScheduler.configure_from_profile()` -> `SusScheduler.set_frame_budget_ms()` | `SusSchedulerExt.tick()` / GDScript SUS fallback | `frame_budget_exhausted` |
| strict budget | `DCSystemScheduler.configure_from_profile()` | `SusSchedulerExt.tick()` / GDScript SUS fallback | `strict_budget_one_job` |
| policy gate / bucket phase | `DCSystemScheduler.configure_job_from_profile()` / `apply_job_schedule()` | `SusSchedulerExt._policy_should_run()` / GDScript policy | `policy_gated` |
| depends gate | `DCSystemScheduler.build_topology()` + job `depends_on` descriptor | `SusSchedulerExt.tick()` / GDScript SUS fallback | `dep_pending` |

也就是说，策略和预算解释集中在 scheduler facade；真正逐 tick 执行、统计和 skip 归因仍集中在 SUS/C++ scheduler。`run_slice(done=false)` 是 job 执行续跑机制，不再承载“这个 job 应该在哪个 tick 启动”的策略判断。

## 主要 runtime jobs

| id | 典型文件 | 职责 | 当前形态 |
| --- | --- | --- | --- |
| `season_refresh` | `simulation/systems/season_refresh_system.gd` | 日历/轨道相位、B+ path、慢变量缓存、atlas queue。 | Production 入口是 `SeasonRefreshSystem`；旧 `SeasonRefreshJob` 已删除。GDScript stage orchestration，部分 gdext 加速。 |
| `refresh_climate_daily` | `simulation/systems/climate_daily_system.gd` | climate daily round：Pass-A/B、ocean water/land、wind、sea ice hook、transpiration。 | GDScript 6-stage state machine + 多个 C++ pass。 |
| `natural_resource_daily` | `simulation/systems/natural_resource_daily_system.gd` | 自然资源每日生成/衰减（per-cell reserve）。reads cell.temp/cell.moisture/cell.is_water；writes 各 `cell.res_*_reserve`。 | 单 pass 调 `MapGenerator.run_natural_resource_pass_scheduled` → C++ `run_natural_resource_pass`（slot 权威）+ GDScript fallback。Job 日历 stride 每天可跑，**不等于**积分 `dt_days`。活格每天 `dt_days=1`（漏跑才按真实间隔补，clamp 1–5）；空野 `cell % 60 == day % 60`，`dt_days=clamp(today-last,1,60)` 一次入账整段自然演化。`extra_change` 只应用一次。`must_run=true`（否则会被 native_daily_sim 超预算后 budget-skip）。 |
| `country_daily` | `simulation/systems/country_daily_system.gd` | ACTIVE 国家命令图；原子预检/应用/发布领土、名称与科技变化。 | priority 255；`must_run=false`、`max_slices=1`、`use_job_should_run=true`；无到期命令零 slice，跨帧批次使用 `country_day_barrier`。 |
| `economy_daily` | `simulation/systems/economy_daily_system.gd` | ACTIVE 冻结周期 `ECONOMY_GRAPH`；sample day 读取环境并冻结国家状态；建筑计划/投入 reserve 使用两遍 active-cell continuation，随后按建筑 cell/cohort 预算错峰生产与 N 日居民市场。国内贸易规划复用同一 job 的软 slice。切片前 `dispatch_effect_native_economy()`，以便 Country 255 ACK 后的 `SETTLE_FAMILY_EXPEDITION` 能立即落地或进入 pending；本国迁徙的 SETTLE-only 事务没有 Country 前置，可在同一切片消费。 | priority 260；国家命令先提交；`must_run=false`、`max_slices=1`、`use_job_should_run=true`、starvation=2。`building_cells_per_slice=0` 自动取市场 cell budget 的 1/4 并封顶 512；贸易规划从不申请屏障；只有 `commit_due && !done` 才开 WorldClock same-day catchup 屏障。 |
| `modifier_daily` | `simulation/systems/modifier_daily_system.gd` | ACTIVE `MODIFIER_GRAPH`：先过期，再按 producer/sequence 稳定执行命令并发布四域 snapshot version。 | priority 90；`must_run=false`、`max_slices=1`、`use_job_should_run=true`、`use_job_deadline_critical=true`；有当日边界工作时预算旁路一次，保证早于 climate 100、country 255、economy 260。consumer 中产生的命令延至后续安全边界。 |
| `effect_runtime` | `simulation/systems/effect_runtime_system.gd` | ACTIVE `EFFECT_GRAPH`：对 frozen metric snapshot 评估 dense effect IR/Behavior，声明式 batch 在 worker plan 后稳定串行 merge，生成跨域 transaction，不直接写 domain。 | priority 85；`must_run=false`、`max_slices=1`、`use_job_should_run=true`、`use_job_deadline_critical=true`；`max_work_per_slice` 与每个定义的 `max_work` 共同限制工作量。 |
| `ideology_runtime` | `simulation/systems/ideology_runtime_system.gd` | Country-scoped ideology collection, slots, offers, understanding and transition intent; it creates no domain write directly. | priority 82；only active ideology rows receive daily visits; `dormant_scan_count=0`. |
| `gameplay_effect` | `simulation/systems/gameplay_effect_system.gd` | Commits native `PUBLISH_EVENT` POD ingress to the authoritative gameplay journal, then returns the Effect ACK. | priority 95；no second gameplay state, no script consumer in the commit path. |

Modifier 的冻结点、scope 与领域消费顺序见
[`native-modifier-runtime.md`](./native-modifier-runtime.md)。Modifier store 不得在 climate/economy
worker 内变更；async climate 只接收主线程冻结的 add/factor 数组。
| `sea_ice_daily` | `simulation/systems/sea_ice_daily_system.gd` | 海冰日更新和 terrain flip。 | wrapper 调用 native/MapGenerator helper。 |
| `enum_atlas_upload` | `simulation/systems/enum_atlas_upload_system.gd` / legacy job | cover/vegetation/enum atlas dirty patch 和 GPU upload。 | C++ cached patch + GDScript upload。`must_run=false`。`speed_scale>=20` 时按 100ms 墙钟 defer（`skipped_reason=fast_forward_deferred`），不 consume pending；降回 1×/5× 后 catch-up。 |
| `weather_refresh` | `simulation/systems/weather_system.gd` / `sus/jobs/weather_refresh_job.gd` | weather field begin/solve/commit、front summary、可选 `hydrology_discharge`、stage-b。 | wrapper 委托 legacy job；staged begin/solve/commit 是当前可见天气权威，merged native 只可在 `weather_native_daily_available()` 放行后使用。运行期水文是链内 stage。 |
| `ocean_currents` | `simulation/sus/jobs/ocean_currents_job.gd` | physical ocean stages：SLP、wind、PSI、upwelling、raster、pixel commit。 | GDScript stage machine + C++ kernels/raster。同 tick daily wind 若已成功跑 `wind` 段且 physical stage 正在 `phys_wind`，job 会复用该 wind 并让出到下一 tick，避免 daily/physical wind 双跑；`elapsed_ms` 现在按 physical stage-local 计时，`job_elapsed_ms` 保留整 job 墙钟。各 physical stage 内部支持**按 cell 区间切片**（`start_idx`/`end_idx` knob，由 `MapBaker` 的 stage 内 cell cursor 驱动），由 `ClimateProfile.physical_cell_slice_enabled` / `physical_cell_slice_divisor` profile-gate 控制，默认关闭。 |
| `dynamic_visual_atlas_upload` | `simulation/systems/dynamic_visual_atlas_upload_system.gd` | enum/dyn/eco cell LUT、dirty/stride、ImageTexture update。 | GDScript upload orchestration，C++ patch/raster 辅助；不再发布 `weather_lut`。cell-indirection 主路径会在 dirty mask 明确为 0、LUT 纹理已存在且无生态 transition 待推进时返回 `path=cell_indirection_lut_skip`，避免无效全量 LUT refresh；`weather_lut` 在 `weather_refresh` commit/merged/direct 完成点内联发布。快进 `speed_scale>=20` 时与 overlay 同量级按 100ms 墙钟 skip（`fast_forward_deferred`），脏标志留下；降速后 `_lut_refresh_pending` catch-up。 |
| `native_daily_sim` | `simulation/sus/jobs/native_daily_sim_job.gd` | native daily active/probe path。 | ACTIVE hot path 调 `DCWorldExt::run_native_daily_slice()`，C++ 持有 graph continuation / node cursor；GDScript做 SUS shell、bundle round-start、fallback/debug 和 Godot visual/演替发布边界。stage-b 的 vegetation stride 按调用次数计，vitality/streak 的实际 `day_scale = weather_vegetation_dynamics_stride × native_daily_sim_stride`；C++ 返回的 succession candidates 必须在 GDScript 边界写回 vegetation/base_vegetation 槽位。原生 breakdown 同步发布 `stage_b_call_index/veg_dyn_ran/stage_b_total_runs`，供 tile CSV 区分“尚未跑到 vegetation node”和“已运行但无演替”。Scheduler report 只提升关键字段，不再嵌完整 `native_daily_report` 大字典；slow dump/debug 可回读 `MapGenerator.native_daily_last_result()`。 |

### Native daily report contract

`native_daily_sim` ACTIVE 的 C++ 入口仍是 graph-node slice，但调度语义是一个
`day_changed` 内完成一个 logical daily round。当前 hot path 是
`MapGenerator.run_native_daily_slice_from_job()` -> `DCWorldExt::run_native_daily_slice()`：

- `NativeDailySimJob` 会放开 `max_slices_per_tick`，并使用至少 8ms（或更高的
  `native_daily_perf_target_ms`，当前 clamp 上限同为 8ms）的本地 transaction budget；默认 ACTIVE
  路径应在同一 SUS tick 内连续推进 native slice 直到 round `done=true`。只有异常超时、失败或
  显式低预算 profile 才应把 round 留到后续 tick。
- **有界降频契约（2026-07）**：移动端允许把 native daily 从“每天权威提交”改为
  “每 `native_daily_sim_stride=N` 天采样一次权威 round，并在
  `native_daily_commit_lag_budget_days` 天内提交”。这不是无约束的 budget skip：
  round start 记录 `native_daily_sample_day/sample_tick`，每个 slice/report/CSV 都带
  `native_daily_current_day`、`native_daily_commit_day`、`native_daily_age_days`、
  `native_daily_commit_lag_budget_days`、`native_daily_commit_over_budget` 和
  `native_daily_contract_state`。`commit_over_budget=true` 会触发
  `[native_daily/contract]` warn；该状态表示调度契约违约，必须降低 N/加 slices/放宽
  budget 或继续拆热点，而不是接受静默漂移。中间 N 天可以读取上一轮权威状态或轻量插值；
  更新日必须用真实 `dt_days`（例如 sea-ice cap 随 N 放宽，runtime hydrology 的降水/融雪累计与 soil/WB30/Q30/地下水/河道状态也按 N 日等效推进）推进，避免误差跨周期累积。ACTIVE round 在 bundle 构建前冻结 climate `*_prev` 与 weather classification 快照，确保降频不会让分类长期读取地图生成态。
  `earth_like.tres` 资源保留 10/10 作为基准；`main.gd` 在移动端未被 WorldSetup 显式覆盖时
  会运行时提升为 20/20，并同步 `native_daily_sea_ice_spread_dt_cap_days=20`。
- **错峰执行（`native_daily_spread_across_ticks`，2026-06，默认 false）**：打开后
  `_configure_native_daily_transaction_budget` 改走 spread 分支——`max_slices_per_tick` 压到
  `native_daily_max_slices_per_tick`（默认 1，即"每 tick 跑一个 slice batch、A→B→C→A 轮转"），
  并把 `must_run` 设为 **false**（2026-06 错峰修复，见下「保留作业错峰」）让 native 遵守 frame budget。
  C++ 跨 tick 持久化 slice 游标 + slot，
  所以一轮的**完成态**与一-tick 原子模式逐 slice bit-equal（`tmp_native_batch_bitequal_test.gd` 锁定）。
  代价：①一个仿真日要跨多个 tick 才落地（仿真推进按 batch 数变慢）；②native round 不再相对 retained
  物理/视觉 job（`ocean_currents`/风场/上传）原子完成，导致与一-tick 模式**有界、确定性的轨迹漂移**
  （24 天真调度复测：多数格 <0.5%，混沌热点 `temp`≤0.15 / `wind`≤1.88，无 NaN、范围健康；soak 复测 temp
  漂移随天数收敛——120 天降到 ≤0.003，cap 差异会被洗掉）。
  - **yield 粒度随模式自适应（2026-06）**：spread 模式与原子模式的最优 yield 集相反，由
    `_native_daily_effective_yield_nodes(cp)` 选择。原子要**粗批**（少 round-trip、低整轮成本）→ `{2,6}`；
    spread 要**细切**（每 tick 跑最小批、低 per-tick 峰值）→ `_NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD`
    = 全部 21 个节点 `[0..20]`。多设 yield 点是**纯 bit-equal**的（只加 C++↔GDScript 断点；非 patch 节点
    的 round-start knob 已满足，`{2,6}` 的 patch 仍在那两个索引照常触发）。C++ 当天缺 knob 的索引会跳过，
    所以典型一轮落在 ~5 个 tick（而非 21）。`native_daily_split_weather_node_enabled=true` 时，weather transaction
    会进一步拆成 `weather_field -> weather_commit -> weather_distribute -> weather_summary -> weather_cyclone -> weather_stage_b`
    六个可调度子节点；原子模式也会额外在这些子节点前 yield，避免单个 monolithic weather C++ call 撑爆一帧。split
    关闭时 C++ 会把这些子节点视为不存在，默认/桌面 profile 不支付空 slice 成本。`native_daily_coarse_spread_yield_enabled`
    是可选 PROBE gate：spread 仍跨 tick，但 yield 集收缩到 `[2,6,12,19,20]`，用于验证减少
    C++/GDScript round-trip 是否能降低均值；默认关闭，开启后必须同时看 `largest_slice_ms` p95/max，
    防止把多个 weather/native 子节点重新堆到同一 tick。实测 spread `maxslices=1` per-tick：均值 **3.14→1.9ms（−40%）**、
    p95 **5.0→4.3ms**；代价是一仿真日跨 ~5 tick（推进 ~2.5× 慢，spread 设计本就接受）。
  - **保留作业错峰（`must_run=false` + budget-yield，2026-06）**：spread 早期 per-tick max ≈ 5.8ms 的真凶
    经逐 job 归因（修正 `tmp_native_spread_validate.gd` 的 worst-tick 字段 bug 后）证明是
    **`season_refresh` 与 `native_daily_sim` 撞车**：scheduler 按 priority 升序跑（`season_refresh`=50 先于
    `native_daily_sim`=210），`season_refresh` 的 11-stage 慢变量 round（每 ~30 tick 起一轮）单 stage ~3ms
    就吃满 2ms frame budget；而 native 当时 `must_run=true` → **无视已耗尽的预算硬叠加** ~2.5ms batch →
    `2.98 + 2.48 ≈ 5.8ms`。修复：spread 下 native 改 `must_run=false`，从而在同 tick 更早跑的
    `season_refresh` 已耗尽预算时**让出本 tick**（season round 是有界的 ~11 tick，让完即恢复）。防饿死保险
    `native_daily_spread_starve_ticks`（`ClimateProfile`，默认 16 > season round 长度）：连续被预算挤掉这么多
    tick 后强制跑一个 batch，确保极端持续抢占下 native 仍能推进。非 season 窗口预算未在 native 前耗尽，所以
    它照常每 tick 推进一个 batch。实测 24 天真调度：**max 5.82→4.97ms（−15%）**、p95 4.57→4.51、均值 1.93
    不变、ticks/round 5.13→4.79（略好）；spread-vs-onetick 漂移仍在既有有界区间（wind ~1.88 不变）。
    bit-equal A/B（per-round 全 38 数组一致）+ bootstrap（原子分支未动）+ graph-order 全绿。
  - **C++ 单节点地板已细查并消除（2026-06）**：错峰后 worst-tick = native 最重单节点（~3.3ms）。逐节点切片
    归因（`tmp_native_spread_validate.gd` 按 stage 聚合 `native_ms`，再在 `run_climate_pass_a` 内 in/loop/flush
    三段计时）证明那 ~1.7ms **不是"重数学核"**，而是 `climate_pass_a` 的逐 cell **每日重算 `dc_insolation_annual_mean`**：
    该年均日照积分每 cell 跑 16 个三角样本（~144 trig/cell），但只取决于 cell 纬度 + 行星 `axial_tilt`/`daylen`
    （全部跨日不变），却被每日每 cell 重算（2464×16 trig/日 ≈ 1.38ms）。又因 `run_climate_pass_a` 末尾 `return 0.0`
    （无内部计时），这笔账被藏在 `climate_ms≈0` 之外，历史 breakdown 一直看不到。修复：按 cell 记忆该年均值
    （`DCWorldExt::ensure_insol_annual_mean_cache`，用 (n, 纬度位, tilt, daylen) 的 FNV-1a 指纹失效——几乎只在
    建图/改行星参数时重建一次），主循环改查缓存（与内联同函数同入参，**bit-equal**）。实测：spread 稳态
    `climate_pass_a` **1.7→0.38ms（−78%）**、per-tick p95 **4.33→3.19ms（−26%）**、均值 1.86→1.78；原子
    `round_native_call_ms` **3.69→2.37ms（−36%）**、原子 tick max 10.1→8.85ms。首轮付一次性 ~1.6ms 建缓存，
    之后常驻命中。bitequal + bootstrap(20/0) + graph-order(11) 全绿。
  - **climate pass_a / pass_b 接入多核 _thread（2026-07，bit-equal）**：此前 native daily 图（slice
    `exec_slice_node` + `system_schedule.cpp::SCHEDULE_GRAPH` + legacy if-chain）的 climate 节点调的是
    **单线程标量** `run_climate_pass_a` / `run_climate_pass_b`——已实现并验证过的 `_thread` 多核变体
    （`pk::parallel_for_range`，自适应 ceil(n/1024) clamp[1,16]）一直**绑定却未接图**。三路 exec 全部改调
    `run_climate_pass_a_thread(...,0)` / `run_climate_pass_b_thread(...,0)`（`n_tasks<=0`=自适应；为此放宽
    `pass_b_thread` 原 `n_tasks<1→1` 的钳制）。安全性：pass_a 纯 cell-local、无邻居；pass_b own-cell 写
    `local_thermal_anomaly`/`moisture`，邻居只读 round-start 快照（`temp_transport_anomaly`/`is_water`）+ 预拍
    `temp_snapshot` → 两者天然无跨 cell 写依赖，多核逐位等价。`tests/climate_pass_bench.gd` 基线（32 核 / MT≤16）：
    49k cell `pass_a` 2.83→0.61ms（**4.7x**）、`pass_b` 1.72→0.34ms（**5.1x**）；110k 档 5.05x / 5.57x，
    随 N 仍上升 → 两 pass compute-bound（~2–3 GB/s 远未触 DRAM 带宽），多核近线性。
    **门槛**：`tests/sim_2ms_ulp_tolerant_test.gd`（A/B：scalar↔thread、scalar↔simd 逐 cell ulp）现 worst=0
    全绿——该测试**捕获并修复了 `pass_b_thread` 漏写「海冰反照率水域尾循环」的潜在 bug**（`sea_ice_albedo_cooling>0`
    时 water `local_thermal_anomaly` 与 scalar 分叉；因从未接图而长期休眠）。bootstrap(20/0) + graph-order(11) 全绿。
    > 已评估但**未做**的两条（数据驱动 no-go，见 `tmp/climate_bench_phase0_summary.md`）：
    > ① pass_a 手写 AVX2——pass_a compute 被 transcendental（insolation sin/cos、day_length acos、pow）主导，
    >   矢量化到 ulp≤4 需 SVML 级超越函数，可向量化纯算术子段占比小、ROI 低；in-core 轴已由多核兜住。
    > ② pass_a+pass_b 融合 / SFC 重排——两 pass 既是 compute-bound（非 memory/cache-bound），融合省内存流量、
    >   SFC 改 cache 局部性的收益都≈0，且高风险，故不实施。
  - **附带：去掉 spread round-start 的 bundle 深拷（2026-06）**：`run_native_daily_slice` 轮首原 `bundle.duplicate(true)`
    + `tick_knobs.duplicate(true)`（后者把内嵌 bundle 又深拷一遍）改为：tick_knobs 浅拷并 `erase("native_daily_bundle")`，
    bundle 走 `native_daily_cow_structural_copy`（深拷字典/数组结构、CoW 共享 Packed 叶子缓冲）。C++ 只改字典层
    （patch 换键、ocean anomaly 交接），从不就地写 Packed 缓冲，故与 `duplicate(true)` **bit-equal**，但省掉每轮
    ~10 个 knob 字典的逐数组字节拷贝（实测此处非瓶颈，~0.15ms，属顺带清理）。
  `earth_like.tres` 现默认开启（`maxslices=1`，spread → yield 全切）；`native_daily_active_bootstrap_test.gd`
  显式置回 false 以继续验证原子路径。复测工具：`tests/tmp_native_spread_validate.gd`（含 `yield=` 覆盖参数
  与 worst-tick 归因）。
- round 起点由 GDScript 构建一次 `native_daily_bundle` 并传给 C++；round 未完成时后续
  slice 发轻量 continue knobs，并可携带 `native_daily_bundle_patch`。patch 只刷新当前即将执行
  节点所需的动态 knobs（如 pass-b / ocean / wind / sea-ice / transpiration），避免 graph round
  继续读取 round-start 的旧温度、TTA 或气团状态。
- **Node-range slicing（2026-07，默认关闭）**：`ClimateProfile.native_daily_node_range_enabled`
  打开后，GDScript 会把 `native_daily_node_range_cells` 和
  `native_daily_node_range_nodes` 传给 `DCWorldExt::run_native_daily_slice()`。C++ 在同一个
  graph node 内持有 cell cursor；白名单节点每次只执行 `[start_idx,end_idx)`，未完成时保持
  `_native_daily_slice_node_index` 不变并返回 `done=false`，下一 SUS slice 继续同一节点且不重复
  JIT patch。节点完整处理后才沿用既有 yield / deferred / graph cursor 规则。首批支持节点是
  `climate_pass_a`、`ocean_water`、`ocean_land`、`wind_air`、`wind_surface` 和 split weather 下的
  `weather_field`；`stage_b`、`runtime_hydrology`、`weather_summary`、`weather_cyclone`
  仍保持整节点。中间 chunk 通过 `defer_flush=true` 留在 C++ slots，末 chunk 才 flush 到
  `MapData`，避免把边界成本乘以 chunk 数。report 字段包括
  `node_range_active`、`node_range_node`、`node_cell_cursor_start/end/count/processed`。
  `climate_pass_a` 的 range 片使用同一份 annual-insolation cache，所有片都保持
  `defer_visible_publish=true`；只有 native daily graph 完整提交时才 flush，避免逐片
  把同一批 slots 复制回 `MapData`。
- native daily 首片若被 SUS 以 `frame_budget_exhausted` 或
  `strict_budget_one_job` 跳过，`MapGenerator` 会设置 transient
  `native_daily_day_pending` 并保持 `native_daily_day_barrier`。下一次 continuation
  pulse 直接调用 `continue_system("native_daily_sim")` 启动首片，完成或失败后清除
  pending；因此预算竞争不会静默丢失一个 semantic day。该标记不进入存档、state hash
  或 event hash，`sus_reset_all()` 会清理它。
- continuation pulse 可在同一帧预算内多次调用 `continue_system("native_daily_sim")`。
  deferred node 只要求 GDScript 在下一调用前同步构造 JIT patch，不代表异步等待；因此可以在
  同一 pulse 继续。循环只决定何时启动下一原子切片，不改变 C++ graph/node/range cursor、
  frozen day context 或最终 publish 边界；达到下一片启动截止线、8ms 预算或 64 片防御上限仍保留
  `native_daily_day_barrier`，留给下一渲染帧。
- **Finalizer pseudo-node（2026-07，默认关闭）**：
  `native_daily_finalizer_slice_enabled=true` 时，C++ graph 完成的 slice 先返回
  `stage=native_daily_finalizer substage=pending done=false`，下一次 `NativeDailySimJob`
  slice 专门执行 `_native_daily_apply_finalizer()`，再发布 round completion。它先把
  `native_daily_complete` 与 graph done 片拆开，后续若 finalizer 自身仍超预算，再继续做
  DataCore 写回/range finalizer 细切。
- **Lazy knobs / deferred nodes（2026-07）**：production hot path 的 round-start
  bundle 只携带首节点 `climate_pass_a_struct` 和调度/readiness 元数据；后续
  `climate_pass_b`、`ocean_water/land`、`wind_air/surface`、`sea_ice`、
  `transpiration`、以及 weather/hydrology/stage_b cadence-due 节点通过
  `native_daily_deferred_nodes` 声明。C++ `run_native_daily_slice()` 会把这些
  deferred 节点视为“未来存在”，不会因当前缺少 knobs 提前 `done=true`，并自动在
  对应 node 前 yield 给 GDScript 构建 `native_daily_bundle_patch`。诊断字段包括
  `deferred_node_count`、`jit_patch_build_ms`、`jit_patch_keys`、
  `bundle_cache_hit`、`bundle_cache_rebuild_reason`、`bundle_static_ms`、
  `bundle_dynamic_ms`。
- **Ocean knobs hot-path cache（2026-07）**：`ocean_water/land` 仍必须在
  Pass-A/B 之后 JIT 构建，因为它读取最新 `temp` / TTA；但构建器不再无条件
  `map.iter_cells()` 或逐格重建 baseline。生成期 EMA 已全初始化后，baseline 直接复用
  `temp_baseline_arr` / DataCore view，只有冷启动/修复路径才回到 HexCell facade。
  这保持动态输入时序不变，同时减少 `ocean_water/ocean_water_knobs` slice 的
  GDScript 打包与 PackedArray 往返成本。
- **Finalizer sparse write（2026-07）**：native finalizer 仍是 temp/TTA/thermal
  的生产计算边界；完成后 GDScript DataCore 可见写入按
  `ClimateProfile.native_daily_finalizer_write_mode=dense|sparse_safe|sparse_perf`
  选择 dense 或 `write_f32_indexed` 稀疏提交。默认 `sparse_perf`，epsilon 默认
  `0.0005`，dirty ratio 超过 `native_daily_finalizer_sparse_max_dirty_ratio`
  （默认 `0.45`）的 component 自动退回 dense，其他低 dirty component 仍走 sparse。
  `sparse_perf` 还会记录上一轮各 component 的 dirty ratio；若上一轮已明显超过
  阈值（阈值 + 0.10），下一轮会直接 dense 写该 component，并每 8 轮强制采样一次，
  避免在移动端高 dirty 天气轮重复做三数组 GDScript dirty collect。因此 report
  可能出现 `finalizer_write_mode=mixed_sparse_dense`。report 字段：
  `finalizer_write_mode`、`finalizer_dirty_count_temp/tta/thermal`、
  `finalizer_dirty_ratio`、`finalizer_sparse_write_ms`、`finalizer_write_dense_ms`、
  `finalizer_dirty_collect_ms`、`finalizer_dirty_collect_skipped`、
  `finalizer_dirty_collect_skip_components`、`finalizer_sparse_components`、
  `finalizer_dense_components`。这些字段会从
  `MapGenerator.run_native_daily_slice_from_job()` 的 `res/breakdown` 继续提升到
  `NativeDailySimJob` scheduler report；`main.gd` 在 `[fast tick WARN]` 下打印
  `native_daily/finalizer ...`，用于定位 `native_daily_complete/round_complete`
  尖峰到底来自 cell loop、clamp、sort 还是 dense/sparse DataCore 写回。
- **GDScript 端热路径开销削减（2026-06，bit-equal）**：① 诊断快照
  `_native_daily_last_result` / `_last_weather_breakdown` / `_last_climate_breakdown` 以及
  `native_daily_last_result()` 取值改用**浅拷贝**（`Dictionary.duplicate()`）——只新建顶层
  dict（顶层加 key 仍隔离），嵌套 PackedArray 走 CoW 共享而非每 slice 逐字节深拷上千浮点。
  ② `_build_native_daily_ocean_knobs` / `_build_native_daily_wind_knobs` 内 per-cell 循环
  内联 NaN/inf 守卫（消除每 cell 一次函数调用）、ocean anomaly 直接就地填 work buf（去掉
  `_prepare_*` 的额外分配 + 第二遍 copy）。后续 wind-air 又加入 slot-temp 输入路径：
  新 DLL 通过 `supports_wind_air_slot_temp()` 让 `_build_native_daily_wind_knobs` 省略
  `temp_before_arr`，C++ `run_wind_air_mass_pass` 直接读 `cell_temp` slot 并用 `baseline_arr`
  做非有限值兜底；旧 DLL 仍回退到历史数组快照。实测：`round_apply_ms` −32%、`round_bundle_ms`
  −47%（ocean_knobs −60% / wind_knobs −68%，slot-temp 进一步降低 wind_air JIT 打包）；spread
  `maxslices=1` per-tick 均值 3.89→3.13ms、max 7.15→5.99ms。三项 bit-equal A/B（40-round）
  + bootstrap 全绿。
  ③ **finalizer 重诊断门禁（2026-06，bit-equal）**：`_native_daily_apply_finalizer` 里的百分位机器
  （per-cell `temp_deltas`/`preclamp_temp_deltas` 数组填充 + 两次 `sort` 求 p95/p99、`sea_ice_delta_max`
  全格扫描、`precip_p95` 排序）由 `_native_daily_finalizer_heavy_diag`（默认 **false**）门禁——**clamp
  本身（`thermal_daily_delta_cap` / `tta_cap`）永不门禁**，所以仿真逐 bit 不变；只有 CSV/report-only 的
  p95/p99/sea_ice_delta_max/precip_p95 在关时变陈旧（廉价的 running max / gt-count 仍准）。需要这些百分位的
  CSV/tile recorder 或 perf probe 可置 `generator._native_daily_finalizer_heavy_diag = true`。实测
  `finalizer_total_ms` **1.54→1.02ms（−34%）**、`round_apply_ms` 1.98→1.42ms；spread per-tick 均值
  3.13→1.86ms、p95 4.43→4.25ms（此阶段 max 仍 ~5.8ms，后由「保留作业错峰」降到 ~5.0ms）。bit-equal A/B
  （全 38 数组一致）+ bootstrap 全绿。
- Native daily climate 前缀必须与 retained `ClimateDailySystem` 一致：
  `climate_pass_a -> climate_pass_b -> ocean_water -> ocean_land -> wind_air -> wind_surface`。
  `climate_pass_b` 会写 `cell_moisture` 并读取上一日/round-start 的
  `temperature_transport_anomaly`，不能放到 `ocean_*` 之后。
- C++ 在 `DCWorldExt` 内保存 `round_active`、`current_node`、`round_id`、累计 breakdown、bundle pass keys 和 state snapshot。
- `run_native_daily_slice()` 采用**节点批处理**（2026-06，bit-equal perf）：C++ 在一次调用里连跑**连续的非 yield 节点**，直到下一个节点属于 yield 集才返回 `done=false`，把控制权交回 GDScript。yield 集**随 cadence 模式自适应**（`_native_daily_effective_yield_nodes(cp)`）：原子模式经**实测最小化** = `_NATIVE_DAILY_SLICE_YIELD_NODES` = `{2,6}`；spread 模式改用 `_NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD` = 全部 `[0..20]`。当 `native_daily_split_weather_node_enabled=true`，原子模式也会追加 weather 子节点 `{13..18}` 的 yield，split 关闭时 C++ 直接跳过这些子节点。patch 的 `match next_node_index` 分支只需覆盖真正要 JIT 构建 knobs 的节点：`1/2/4/6/7/11/12/19/20`，其中 hydrology 与 hydrology 后 stage-b 已因 weather split 插入而移动到 `19/20`。返回值仍含 `progress_ratio`、`stage_name`、`substage`、`cursor_start/cursor_end`（批处理下 `cursor_start` 为该批首节点）和 `node_report`。ACTIVE slice 使用 `world_ext_daily_sim.cpp` 内的 lightweight slice graph；`run_native_daily_tick()` debug/full-run helper 仍使用 `SCHEDULE_GRAPH` dispatcher。
- **Weather knobs prebuild（2026-07）**：ACTIVE slice 的 deferred round-start 现在会在 weather cadence 到期时预构建 `weather_knobs`，并保留 node 12 作为执行/yield 边界。这样 `weather/weather_knobs` slice 不再在执行帧支付 `build_unified_fast_tick_weather_knobs()` 的 GDScript 打包成本；report/breakdown 字段 `weather_knobs_prebuilt=true` 表示 node 12 的 JIT patch 已短路复用 round-start bundle。
- Sea ice 在 native sliced ACTIVE 中仍按每日松弛语义推进：`sea_ice_knobs.dt_days` 会消费并推进 `_last_sea_ice_pass_day`，但上限压到 1 天。这个上限现在用于防止异常跨 tick continuation 折叠成批量融化/冻结；正常 ACTIVE 不应让一个 climate/sea-ice round 跨过多日。
- 最后一个 native node 完成后，`MapGenerator` 会先发布 native 返回的 TTA，再执行 climate finalizer（复用旧 `thermal_daily_delta_cap` / `temperature_transport_anomaly_daily_cap` 语义，写回 `MapData` 和 GDScript `DCWorld`），然后才把 `published_slots` / `visual_dirty_intents` / finalizer diagnostics 暴露给 scheduler、CSV 和 debug。
- `total_ms` / `native_ms` 是**最后一个 slice** 墙钟，供 SUS largest 归因；`round_native_ms` 是当前 native round 累计墙钟，也是判断 daily transaction 实际成本的主指标。
- 如果 `runtime_hydrology_enabled=true`，`MapGenerator` 必须构造 `runtime_hydrology_knobs`，并且 probe 的 `required_pass_keys` 必须同时看到 `weather_knobs` 与 `runtime_hydrology_knobs`。旧的 “hydrology 直接拒绝 ACTIVE” gate 已移除；现在由 bundle/probe/graph report 决定是否能注册 ACTIVE。
- Hydrology 开启时 native daily bundle 不把 stage-b 平铺进 `weather_knobs`；C++ graph 顺序变为 `weather -> [weather_* split nodes when enabled] -> runtime_hydrology -> stage_b_after_hydrology`（stage-b 仍按 cadence 可选）。Hydrology 关闭且 split 开启时，embedded stage-b 只在 `weather_stage_b` 节点运行；split 关闭时仍保留既有 monolithic weather/stage-b 行为。

`run_native_daily_tick()` 保留为 debug/full-run helper，`run_native_sim_tick()` 保留给 SHADOW/A-B/hash diff，不是普通 ACTIVE hot path。

`native_daily_sim` 把 native slice report 直接透传到 slice report 的 `native_daily_report` 字段，并把关键字段提升到 scheduler 可见层：

- `path`：ACTIVE hot path 为 `gdext_native_daily_slice`；debug/full-run helper 仍可能为 `gdext_native_daily` 或 probe path。
- `done` / `progress_ratio` / `stage_name` / `substage` / `cursor_start` / `cursor_end`：native graph continuation 进度。默认 ACTIVE cadence 下，外层 `native_daily_last_result()` 通常应看到当前 day 的 completed round；只有 transaction budget 不足或异常 continuation 时才会把 `partial=true` 暴露到 CSV/debug。
- `fail_stage` / `fallback_reason`：任何 native node 失败时必须可直接定位。
- `native_ms` / `round_native_ms` / `compute_ms` / `refresh_ms` / `flush_ms`：分别对应当前 slice 墙钟、当前 round 累计、pass 累计、round 边界 refresh、round 结束 flush。
- `published_slots` / `published_to_slot`：本 tick 按 bundle 粗粒度声明的可见 slot 家族和 scheduler 可见发布布尔值，用于诊断 publish contract，不替代 per-pass `published_to_slot`。
- `dirty_cells` / `visual_dirty_intents`：native graph 对 GDScript render/upload 层的意图，upload 本身仍由 Godot/GDScript 执行。
- `retained_gdscript_authority` / `retained_boundaries` / `graph_coverage_complete`：`retained_gdscript_authority` 只保留缺失的 simulation graph 节点线索；`retained_boundaries` 单独列出 `visual_uploads`、WeatherFront object rebuild、weather LUT upload、sea-ice terrain/atlas、ocean texture commit、season atlas/detail scatter、CSV/debug 等计划保留的 Godot/visual 边界。`graph_coverage_complete` 只由 `authority_blockers` 是否为空决定，不再被 Godot presentation boundary 永久阻塞。
- `authority_report` / `authority_blockers` / `graph_coverage_state`：机器可读的权威验收仪表，并由 `NativeDailySimJob` 提升到 scheduler report。`authority_report` 按 `climate_round`、`sea_ice`、`weather_transaction`、`runtime_hydrology`、`ocean_physical`、`season_refresh`、`visual_upload` 和 `fallback` 分组给出 owner、phase、simulation blockers、retained boundaries 与 publish 预期；顶层 `authority_blockers` 只列阻止 daily simulation graph complete 的项。`graph_coverage_state=partial` 表示仍有 simulation authority 或 production fallback 未退休；Godot/visual boundary 只应出现在 `retained_boundaries`。
- `weather_transaction` 的 owner 由 `weather_native_daily_readiness_report()` 驱动：visible publish、front result apply 和 weather LUT publish 入口都满足时升为 `native_ready`，否则保持 `gdscript_retained` 并把 readiness `reason` 写入 blockers。打开 `native_weather_transaction_active_owner_enabled` 后，ready tick 可报告 `native_active`；native execution 通过 `field_commit_publish_verified` 将 report phase 升为 `native_active_verified`。ACTIVE `fronts_changed` 现在取真实 `weather_lut_changed || fronts_count > 0`，不再因存在 `weather_knobs` 恒 true。front object rebuild 与 `ImageTexture`/weather LUT upload 仍是 `retained_boundaries`。
- `climate_round` 的 report 细分 `remaining_gdscript_simulation_authority` 和 `remaining_godot_boundary_authority`。默认 `native_ready` 仍保留 `sync_sliced_fallback`；打开 `native_climate_round_active_owner_enabled` 后，snapshot 会把 simulation remaining 清空、声明 `fallback_mode=explicit_failure_only`，只留下 Godot/MapData 与 reset/abort 边界。
- `sea_ice` 的 graph node 有 `sea_ice_knobs` 时报告 native owner；native round 完成且发布 sea-ice slots 后 phase 升为 `native_active_verified`。terrain flip visibility 与 sea-ice atlas/upload 只列入 `retained_boundaries`，不再作为 simulation authority blocker。
- `ocean_physical` 现在从 `OceanCurrentsJob.ocean_physical_state_snapshot()` 进入 native daily bundle。新 DLL 还提供 `native_ocean_physical_begin/step/finish/reset/get` facade，让 native report 持有 physical round id、phase lock、stage cursor 和 finish/reset intents；GDScript job 只 mirror 并执行 visual raster/texture commit。打开 `native_ocean_physical_active_owner_enabled` 且 snapshot owner 为 `native_active` 后，`ocean_currents_physical_state` 不再进入顶层 `authority_blockers`；pixel raster、texture commit、Godot buffer upload 仍是 `retained_boundaries`。
- `season_refresh` 现在从 `season_refresh_state_snapshot()` 与 `season_cadence_policy` 进入 native daily bundle。report 会镜像 period counter、round stage/cursor、B+ native round 状态、simulation slot dirty intents、atlas/detail visual intents，以及 stage-b call_index/stride/should-run policy；打开 `native_season_refresh_active_owner_enabled` 且 B+ native round 可证明时，owner 可升为 `native_active`。atlas queue 与 detail scatter 仍是 `retained_boundaries`。
- `boundary_contract` 来自 `native_daily_bundle.native_daily_boundary_contract`，拆分 `bootstrap_config_keys` 与 `tick_delta_keys`，并报告 refresh/flush policy。`NativeDailyReport` 同时提升 `bundle_key_count`、`tick_delta_key_count`、`runtime_config_report`、`native_daily_active_default_ready` 和 `active_default_blockers`。它不是行为开关，而是减少 Dictionary marshal、把 runtime config 常驻 native、以及限制 refresh/flush 到 tick/visible boundary 的验收面；只有 readiness 为 true 且 blockers 清空时才允许切默认 ACTIVE。
- `native_state_snapshot`：声明当前 tick 的状态机 owner。现阶段 `weather_transaction_state_owner`、`ocean_physical_state_owner` 等可能仍是 `gdscript_retained`；只有对应状态 owner 迁到 native 后，才允许把该系统称为 DOTS-authoritative。Climate round 现在会把 `ClimateDailySystem` 的 `_round_active`、`_pass_cursor`、`_phase_locked`、async kick/poll 和 pass token 作为 `climate_round_state` mirror 透出，且当 `native_probe_state.climate_round_authority_ready=true` 时，`climate_round_state_owner` 与 mirror `owner` 报为 `native_ready`。`native_ready` 表示 native lifecycle/facade/intents contract 已具备 handoff 条件；`simulation_authority` 仍为 `false`，`remaining_gdscript_authority` 仍列出 Godot/MapData 边界、reset/abort 边界和 sync sliced fallback。`ClimateProfile.native_climate_round_active_owner_enabled=true` 是受控 ACTIVE owner gate：native-ready 时 report 会提升为 `native_active`，并把 `native_probe_state.authority=native_active_owner`、`simulation_authority=true` 写入 snapshot；这仍不退休 `remaining_gdscript_authority`。GDScript async path 优先通过 `native_climate_round_begin/kick/poll` facade 触达 worker，旧 `async_climate_round_*` 方法只作为兼容 fallback。`native_climate_round_begin_round/finish_round` 会记录 native `lifecycle_round_active`、`phase_locked`、poll attempts、stage、`start_state_intents` 和 `boundary_intents`；GDScript async start 已改为调用 native begin-round 后 mirror 这些 state intents，旧 DLL 才本地预写。`native_climate_round_poll()` 还会把 worker 实际 flush 成功的 `published_slots`、sea-ice flip `visual_dirty_intents`、ms 单位 `breakdown`、`finish_boundary_intents`、以及 `finalize_tail_boundary_intents` 透到 facade 顶层，供 scheduler/debug 使用。`finalize_tail_boundary_intents` 现在覆盖 `use_worker_finalizer_diag` / `apply_gdscript_finalizer_fallback`、`advance_full_sweep_counter`、`publish_climate_breakdown`、`annual_log`、`soa_noop`、`soak_dump`、`integrity_check` 以及尾部 reset/flush/stale/dump 动作；`reset_native_climate_round_state()` 同样返回 `reset_boundary_intents`，GDScript 只负责执行这些 Godot/MapData/debug 侧 intents。

### Gameplay event bus 与视觉消费

`DCWorldExt` 的 gameplay event bus 是跨 C++/GDScript 的事件日志，不是 scheduler job：

- native jobs/stages（例如 vegetation dynamics / Stage-B）在执行中发布事件；发布本身计入对应 native pass 的耗时。
- renderer/UI/debug 用独立 consumer cursor poll，不参与 simulation authority，也不影响 C++ scheduler 的依赖图。
- chunked detail apply 由 `HexRenderer._drain_detail_refresh_queue()` 在渲染帧中按 `detail_scatter_refresh_layers_per_frame` 推进；这是 Godot object/MultiMesh 提交，不应放进 C++ SUS job。
- 诊断时把 `event_bus_ms` / native pass ms / `gd_chunk_apply_ms` 分开看：事件产生慢看 native stage，consumer lag 看 event bus report，chunk apply 慢看 `[detail_scatter/SLOW_LAYER] chunks=...`。
- gameplay journal 达到容量上限后的淘汰必须是 O(1) `pop_front`；当前底层为 `std::deque`。
  若 `aggregate_publish.world_gameplay_publish` 随运行时长抬升，首先检查是否重新引入了连续数组的
  头删搬移，再检查事实产生数量，不能把这种容器成本误判成 GDExtension bridge 成本。

经济事件遵守同一消费隔离，但详细记录留在 economy-owned journal：市场 worker 只生成本 market
fragment，主线程按 market index 合并；`aggregate_publish` 守恒成功后才令 batch 可见。
`EconomyDailySystem` 看到 `economy_event_batch_published=true` 后通知 facade handler，不增加
depends、must_run 或 economy backpressure。常规 UI 只订阅轻量 availability signal；没有详细 batch
订阅者时 facade 直接推进自身 ACK cursor，不执行 packed journal poll。consumer 落后只形成 lag/gap
诊断，不阻塞 WorldClock。

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

scheduler-wide 总预算。`ClimateProfile.sim_frame_budget_ms` 是当前权威配置；GDScript SUS fallback 与 `SusSchedulerExt` 使用同一套全平台安全上限（当前 16ms），不再按 `OS.has_feature("mobile")` 把移动端压到 4ms。每 tick 中，非 `must_run` job 会在预算耗尽后被 skip，并记录 `frame_budget_exhausted`。

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

native daily ACTIVE 使用同一依赖顺序，但不单独注册 `HydrologyDischargeSystem`：

```text
weather -> [weather_field -> weather_commit -> weather_distribute
  -> weather_summary -> weather_cyclone -> weather_stage_b, when split enabled]
  -> runtime_hydrology -> stage_b_after_hydrology
```

`runtime_hydrology` 是 `system_schedule.cpp::SCHEDULE_GRAPH` 节点，只有 bundle 含 `runtime_hydrology_knobs` 时运行。它依赖当天 weather node 发布的 `weather_precip`，并且要在 stage-b 植被动态读取 `cell_moisture/soil_moisture/water_balance_30d` 前完成。report 字段包括 `hydrology_ms`、`runtime_hydrology_ms`、`hydrology_native_ms`、`hydrology_compute_ms`、`hydrology_flush_ms`、`hydrology_water_budget_error`、`hydrology_river_discharge_p95/max`、`hydrology_river_moisture_floor_touches`、`hydrology_riparian_moisture_floor_touches`、`hydrology_flood_count`、`hydrology_published_to_slot`；published slots 包含后置写入的 `cell_moisture`。legacy staged path 仍使用 `stage_name=hydrology_discharge` / `substage=route_full`。

### `must_run`

`must_run=true` 只绕过 frame budget gate。它用于避免关键物理/气候推进被长时间饿死。

典型语义：

- `ocean_currents` 需要持续推进物理 stage，否则 ocean/wind/PSI 会冻结。
- climate daily 曾因被 budget 掐断导致后续 weather/ocean 失去新输入，因此相关 job 需要谨慎配置。

风险：

- 过多 `must_run` 会削弱 frame budget 的保护。
- `must_run` job 内部仍应切片，不能把所有重计算一次塞进主线程。
- `native_daily_sim` 不应靠 `must_run=true` 掩盖长 slice。正确形态是 `must_run=false`、`max_slices_per_tick=1`，并由 C++ continuation 保证单片足够短。

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
  - ocean physical stage 已落地该规则：`run_slp_field_pass` / `run_wind_field_pass` / `run_physical_circulation_pass` 现接受 cell-range knob，由 `OceanCurrentsJob._physical_solve_step_one` 的 stage 内 cursor 把 SLP/wind/upwelling 各自摊到多 tick；全局归约（SLP recenter/p95/融合/发布、WIND coast BFS）只在末切片执行，沿用文档既定 `start_idx==0`（一轮首切片）/`end_idx==n_cells`（末切片）idiom。PSI 因 Gauss-Seidel 全扫掠按设计不做 cell-range 切片。默认关闭，开启前须 bit-equal + 零 fallback + 每切片 <1ms 验收。
  - NS 化新增段（2026-08-04）遵循同一游标语义：动量旧通量快照驻留成员 `_phys_wind_snap_fx/fy`，只在 `start_idx==0`（或 size 失配换图）重建、后续切片复用——否则前序切片写回的新风会污染"旧值"语义，切片 ≠ 全量。散度阻尼 L1 与轨迹表构建（均为全图操作）只在 `end_idx==n_cells` 的末切片执行，与 coast BFS / SLP recenter 同级。验收：`tests/native_wind_traj_momentum_test.gd` 的"两切片 ≡ 全量 逐位一致"用例。
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
- `wind_period_ticks=ClimateProfile.ocean_daily_wind_period_ticks` for the
  daily wind prepass — default 3 means the prepass fires only on
  `tick_index % 3 == 0`, not every tick. `MapGenerator` injects the same profile
  value on both the initial `configure` and runtime `reconfigure` paths. Raising
  the cadence removes recurring `daily_wind` spike frames; wind/SLP change
  slowly, and mobile profiles may trade freshness for lower single-frame cost.
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

### Physical stage 内 cell 切片游标（inert-by-default，2026-07）

`ocean_currents` 的 slow chain（SLP → wind → upwelling；PSI 沿用既有迭代切片）除既有
`ocean_currents_period_ticks` / `ocean_currents_slice_count` 的**跨 tick 切片**外，现新增
**stage 内 cell-range 切片**：`MapBaker` 持 `_phys_cell_slice_enabled`（默认 `false`，关闭时
游标不写入 knob、C++ 退化为整图 `start_idx=0/end_idx=n_cells` 调用，行为完全等价）、
`_phys_cell_slice_divisor` 与三枚游标 `_phys_slp_cursor` / `_phys_wind_cursor` /
`_phys_upwelling_cursor`。开启后每个 physical stage 被切成多 tick：调用 C++ pass 时注入
`start_idx=cursor, end_idx=min(cursor+cells_per_tick, n_cells)`，推进 cursor，末切片
（`end_idx == n_cells`）才写回 `map.slp_arr` / commit WIND / 复位游标并进入下一 stage。游标
仅在每轮 solve 的 `_PHYS_STAGE_NONE → SLP` 边界归零，stage 名（`phys_slp`/`phys_wind`/
`phys_psi_*`/`phys_upwelling`）稳定，全部 `fail()` fallback 路径保留。该能力须本地 rebuild DLL
并跑 30+ tick PROBE（bit-equal、零 fallback、每切片 p95/max < 1ms、轨迹无漂移）后才可设
`_phys_cell_slice_enabled = true`，否则保持关闭即历史行为。

`main.gd._print_daily_breakdown()` prints a dedicated `daily_wind stage=… path=…
slp=… wind=… total=… refresh=… dominant=…/… slp_dp95=… wind_dp95=… commit=…
reason=…` line for the `ocean_currents` job whenever `daily_wind_due=true` (the
tick the prepass actually ran), mirroring the existing climate/weather/sea_ice
breakdown lines. When SLP actually ran this tick it also prints a
`daily_wind/slp_internal passA=… passB=… norm=… marshall=…` line.

The outer `ocean_currents` scheduler policy must remain `AlwaysPolicy`, even
when full-platform stagger buckets are enabled. Its daily SLP/wind prepass is
the fast authority for `cell_wind_*` and weather/climate inputs; the slow
PSI/ocean-current work is already gated inside `OceanCurrentsJob` by its own
`ContinuousSlicedPolicy`. Bucket-gating the outer job makes wind direction and
ocean-current fields appear frozen under native daily ACTIVE.

### 2-tick SLP/wind split

`plan/daily-wind-stage-split` (profile flag `ClimateProfile.daily_wind_split_passes`,
default `true`) staggers the two daily authority kernels across adjacent due
occurrences instead of running both on every due tick:

- `OceanCurrentsJob._daily_wind_stage_for(ctx)` picks the `stage` argument passed
  to `run_daily_wind_field_update()`: it alternates by the actual due-occurrence
  counter `_daily_wind_due_seq` (`"slp"` when even, `"wind"` when odd), with
  `"both"` for the first prepass after a reset (cold-start safety net). The
  counter increments once per real prepass run. **Do not** key the split on
  `day_index` parity: with `wind_period_ticks>1` the due ticks land on a fixed
  parity, which would pin the stage to a single kernel and freeze the other
  field. A wind-only day whose `map.slp_arr` size is stale falls back to
  running SLP too (`stage_note=wind_only_slp_primed`).
- The single-tick SUS peak drops from ~5ms (SLP+wind) to ~3ms (SLP run) / ~1ms
  (wind run). Combined with the default `wind_period_ticks=3`, the prepass fires
  every 3rd tick and alternates kernels, so SLP and wind each refresh every 6th
  tick; a mobile profile can raise `ocean_daily_wind_period_ticks` to widen that
  interval. The prepass `path` becomes `gdext_daily_wind_slp`
  / `gdext_daily_wind_wind` on split runs, and `gdext_daily_wind` when both run.
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

Fast-forward (`SusTickContext.speed_scale >= 20`) is a separate wall-clock gate:
`enum_atlas_upload` and `dynamic_visual_atlas_upload` skip with
`skipped_reason=fast_forward_deferred` unless at least 100ms have elapsed since
the last successful upload or the existing starvation threshold is hit. Skip
does not consume pending/LUT dirty flags. Dropping below 20× forces a catch-up.

Production `sus_tick_daily` terrain-mirror sync is dirty-flagged. Clean days
return immediately; only MapData-only terrain/water writes call
`mark_runtime_terrain_mirror_dirty()`. Indexed dual-write paths (sea-ice flips,
canals) do not mark dirty.

### Large-map sea-ice visual freeze fix (2026-06-29)

The cell-indirection LUT carries **every** dynamic visual (temp / moisture / snow
/ vegetation-vitality / **sea-ice**, all in `dyn_lut`) and is cheap
(`~0.57ms @ 6400 cells`). Two coupled defaults made it refresh only once per
~8 game-days, which looked **visually frozen on slow large maps** (the sim
numbers moved but the screen didn't) while small/medium maps — where 8 days pass
in a blink — looked live:

1. **Stagger inflated the LUT cadence.** `apply_job_schedule` fed the job the
   stagger *bucket* stride (8) via `reconfigure()`, so `_lut_due_for_tick` only
   marked the LUT "due" every 8 ticks regardless of map size. The stagger only
   ever existed to spread the **retired expensive per-pixel atlas upload**, not
   the cheap LUT. Fix: `_lut_cadence_stride()` / `_lut_cadence_phase()` decouple
   the cell-indirection LUT cadence from the stagger bucket — it is now due every
   `dynamic_visual_atlas_upload_stride` tick (knob default `1` = every tick). The
   staggered `_lut_stride` / `_lut_phase` survive only for the dead per-pixel
   fallback (cell-indirection off).
2. **Starvation rescue was too lax.** On large maps the `must_run` climate round
   eats the whole `sim_frame_budget_ms` every tick, so the (non-`must_run`, by
   the no-drift design rule) visual job is perpetually `frame_budget_exhausted`
   and only the starvation net runs it. The old `starvation_threshold=8` (a
   holdover from the expensive per-pixel era) meant ~8-day visual lag. Lowered to
   `2` in `DcSystemScheduler._apply_budget_profile_to_job` so the cheap LUT
   catches up within ~3 ticks under sustained budget pressure.

Headless A/B (`tests/tmp_seaice_visual_eval.gd`, 380-day sample, full-year warmup,
slot/encode confirmed fresh on all sizes — root cause was **never** a stale
`cell_sea_ice_frac` slot): large-map (100×64) `dynamic_visual_atlas_upload`
refreshes went **42 → 127 / 380 ticks** (≈ every 8 → every 3), and the chronic
"always pending, 0 caught-up" pattern (0 `policy_gated`, 338 `frame_budget_exhausted`)
resolved. Small/medium refresh ≈ every 2 ticks. `must_run` stays `false`
throughout (no budget bypass / logical drift).
## Economy building stages

`economy_daily` 继续保持 `must_run=false`、一 tick 一 slice 和 deadline-only barrier。它新增地理
与自然资源 reserve reads，使 sample snapshot 排在 natural-resource 更新之后。建筑状态本身不是
DC component。无建筑时 BUILDING_GRAPH 零成本跳过；有建筑时只调度 active-cell CSR，阶段名固定
为 `building_employment`、`building_production`、`building_commit`。

`building_production` 的外部 stage ABI 不变。业主先购买原料并完成生产/出售，再按 owner 汇总
并比例支付基础工资；最终欠薪保留诊断标记但取消奖金，不追溯停止本期生产。建筑内部仍先运行产出
`cycle_flow` 的 utility groups 并完成商人收购，再运行其余 collector/industrial groups，最后
清空剩余 cycle-flow 库存。utility producer 禁止同时消费 cycle-flow，因而不引入递归依赖或
新的 scheduler node；锁定周期冻结、deadline barrier 和 continuation cursor 均保持原契约。

该 stage 可在一次既有 production range 内部调用 `parallel_for_range`，按 due cell 分派原生
WorkerThreadPool 任务。任务只写 cell-local cohort/building/market/resource/signal lane；跨 cell 的
诊断、留用品、现金流与 trace 先写入 `ProductionResult`，随后按原 cursor 顺序稳定归并。它不是
新的 SUS job，不新增 graph node、dependency 或 barrier。低于阈值、WTP 不可用或
`cell_to_market[cell] != cell` 时走同一原生 body 的单任务路径。frame budget 只能决定 range 完成后
是否继续下一 continuation，不能中断正在执行的 range。

`ProductionResult` lane 由 runtime 持有并在 range 间复用容量。计划与 household post-building
允许使用普通 building range 两倍的确定性吞吐 batch，投资/finalize 使用独立的默认 96/128-cell
continuation。它们只改变 native call 边界，稳定 cell/group 求值、主线程归并顺序、SUS 节点、
锁定 N/S cadence、barrier 和 publish 契约均不改变。

`epoch_begin` 在进入就业阶段前按冻结样本生成 owner-lot 收入/成本诊断；生活成本与合同工资
在 `building_employment` 的 active-cell slice 内计算。生产结束后才更新稀疏企业
需求/供给/成本信号。Price V3 在本周期只读取上一 committed 信号，因此不新增图节点、跨阶段
反向依赖或 DataCore 写边。

## Economy domestic trade slices

`building_commit` 完成后必须 yield；下一次 native 调用才进入 `aggregate_publish`。发布阶段按
prepare、closing audit、verify、watermark、trade flow/diagnostics、trade init、commit 顺序推进，
使用固定条目预算而非墙钟决定游标。直到最后 commit，`epoch_active` 与 save boundary 保持关闭
可见性；禁止在审计成功前交换 committed summaries。国家拓扑哈希变化时，trade init 的
component clear、seed scan 与 BFS 也保留 queue/cursor 并按每片 4096 单元推进，不允许退回完整
地图的一次性 BFS。

Closing audit 支持 FULL/PROBE/INCREMENTAL。增量路径使用 native 首触 shadow-delta
账本；household/production worker 的 due workset 在 dispatch 前由主线程预登记，
worker 不并发写 audit stamp。PROBE 的全量结果仍是权威，INCREMENTAL 的周期 mismatch
在 committed swap 前失败并关闭本 session fast path。该机制不增加 SUS node、依赖边或
PKEC 字段。

贸易规划在 `aggregate_publish` 内分片初始化只读工作集，完成发布后阶段名为 `trade_planning`。market×good
扫描使用配置的 pair 配额；路线阶段最多完成配置的 source 数，并额外受每个 native slice 固定
256 次有效 Dijkstra 扩展的总配额约束。未完成 source 的 heap、stamp、accepted/pending target
和 expansion cursor 留在 `TradePlanStore`，下片从同一 source 继续。所有配额都是确定整数，不根据
实际耗时改变结果。未完成时 `economy_should_run()` 继续返回软任务，但
`economy_day_barrier=false`，因此 WorldClock 正常前进。

slice report 的归因字段为 `executed_stage/executed_substage`；`stage` 与 `next_stage` 描述返回后的
状态。SUS continuation 统计必须使用 executed 字段，否则 publish 的最后一片会被误记为
`trade_planning`。

同日 `country_economy_continuation` 调用 `run_economy_slice_compact`，只跨桥返回调度、屏障、事件和
当前阶段 breakdown；普通 daily tick 与显式 `get_economy_report` 保持 full report。compact/full
共享同一 C++ 权威推进和 `DCWorldExt` publish wrapper，不改变锁定 N/S cadence、稳定顺序、资源写回、
CSV capture 或 event visibility。MapGenerator 以 `economy_should_run(day)` 与 slice `done/fatal`
驱动循环，不得在每个 continuation 前后重建完整 report。
完成 publish COMMIT 时 C++ 复制一次纯诊断 `last_completed_*` 快照，避免下一 epoch 清零 live
counter 后 CSV 丢失 worker、allocation 和 structure 数据；该快照不参与调度、存档或 state hash。

到经济提交边界时顺序固定为 `trade_settle → external_ledger → building_employment →
building_production → household_market → trade_dispatch → structural_commit`。出口派发单独占一个
continuation slice，并按本地清算后的库存目标再次裁剪。ACTIVE 若规划片恰与新周期到期
重合，先执行一片规划，再在后续 slice 进入
本地市场；只有整个到期经济图未完成才沿用既有 same-day catchup。PROBE 只生成/报告建议，
不延迟旧本地市场 cadence，也不修改经济状态 hash。详见
[Domestic Trade Runtime](./domestic-trade-runtime.md)。

`household_market` 的 rolling range 顺序仍由 `cell % 5` 与稳定 market ID 决定。大世界
ACTIVE 结算使用 thread-local worker landing buffer，主线程按原顺序合并；并行只缩短 range
内部公式计算，不新增依赖边或可见提交点。compact continuation report 以
`household_market_breakdown_ms/work` 暴露 settle 的 prepare、worker、aggregate/trade merge、
trace、other，以及四个收尾子阶段。多个确定性 chunk 可在同一 `slice_budget_ms` 内融合，但
同一 market 只结算一次；锁定 N 分桶和 same-day catchup 语义不变。

## Economy rolling five-phase cadence (2026-07-20, current)

`economy_daily` keeps C++ stage-state authority and production cadence is fixed
at five days. On simulation day `d`, one stable bucket is due:
`cell_id % 5 == d % 5`. World scale changes the number of cells in that bucket,
never the cadence. Bounded native calls process at most one building, market, or
structural range and return `done=false` while the bucket is incomplete. The
same-day barrier then drives consecutive bounded continuations within the
real-frame `sim_frame_budget_ms` time box until daily trade
arrival, stable reduction, and publish finish. The completed report has
`deferred_cells=0` and `max_state_age_days<=4`; an in-flight barrier is expected
continuation behavior, not a missed-deadline anomaly.
Both runtime hosts must inject `WorldClock` into `MapGenerator` before
`generate()`, because country/economy jobs are constructed during SUS setup.
`MapGenerator.set_world_clock_ref()` also rebinds already-created jobs and the
`simulation_backpressure_pulse` connection as a delayed-injection safeguard;
debug and player scenes therefore use the same barrier contract.
When the pulse drains the barrier synchronously, `WorldClock` rechecks the source
set and may continue consuming the current frame's calendar allowance; completion
does not force an otherwise empty render frame.

Incremental trade planning advances one bounded slice each day but cannot delay
the local bucket. Trade arrival is a daily transaction and does not wait for the
destination's next local settlement. Workload-auto cadence and global
`WAIT_COMMIT` are retained only as historical/reference terminology and are not
production scheduling paths.

Before serial building production, due building cells precompute their frozen
demand basis in deterministic contiguous worker ranges. Workers write only their
cell-owned cache slices; the main thread reduces saturation counters by cell ID.
This is a cache-preparation substage, not a new authority or visible simulation
stage, and worker count cannot affect the state/event hash.

Building plan evaluate、building production 与 household market 现在都在原有
`economy_daily` continuation 内使用稳定连续的 weighted ranges；它们没有新增 SUS node，也没有
移动 `NativeEconomyRuntime` 的 stage/tick authority。默认 fan-out 上限是
`economy_worker_task_cap=12`。一个 native range 仍不可被 SUS 抢占，SUS 只在 range 返回后决定
是否启动下一 continuation。plan/production/market 均先 wait，再按 task id 和原 cursor 顺序归并，
所以 scalar 与 worker 的 state/event hash 契约不变。

到期建筑 cell 在既有 building-plan prepare 内冻结并预计算各组生产气候能力，不增加 SUS node
或经济 stage。就业需求使用气候前计划能力，保留已填岗位和合同基薪；production worker 先合并
劳动、投入、资金、资源能力，再以冻结气候能力限幅。非到期 cell 的诊断和状态不提前变化，日内
环境更新只在该 cell 下一次 `cell % 5` 到期时进入冻结快照。报告发布气候 Profile/限产组数与
平均 Q16 能力；计算只访问 due-cell CSR，不执行全地图乘建筑类型扫描。

## Native daily moisture commit boundary (2026-07-24)

The graph order and yield nodes are unchanged. Moisture-producing nodes no
longer publish their intermediate `MapData.moisture_arr` values from a slice.
At wrapper-finalizer completion, the existing finalizer snapshots only
`cell_moisture` and assigns it to the exact round `MapData`; a deferred
finalizer slice therefore does not expose moisture early. The completed
breakdown exposes `moisture_committed`, `moisture_commit_path`,
`moisture_commit_slot_size`, and `moisture_commit_flush_ms`; non-final slices
do not claim a visible moisture commit.

The round-start bulk refresh runs before the native moisture transaction opens.
While the graph and deferred wrapper finalizer are in progress, both bridge-wide
`refresh_slots_from_map()` and keyed `refresh_slots_from_map_keys()` calls skip
`cell_moisture`; otherwise unrelated jobs would overwrite the in-flight slot
with the intentionally frozen visible value. This includes the
`natural_resource_daily` climate-input refresh that runs between native slices.
The finalizer closes the transaction only after publishing the completed slot
snapshot. Native failure closes it without exposing a partial value.

## Deadline-critical dynamic budget bypass（2026-07-18）

`SusJob.use_job_deadline_critical` 默认关闭。仅 opt-in job 可通过只读、常数时间的
`is_deadline_critical(ctx)` 在当日返回 true，并绕过一次 frame budget 或 strict-budget 的“是否启动”
门槛；它不会改成 `must_run`，依赖 gate、`max_slices_per_tick` 和 slice loop 预算仍正常生效。
`SusSchedulerExt` 与 GDScript fallback 保持同一语义，并在 per-job report 发布
`deadline_critical` / `deadline_budget_bypass`。

`country_daily` 在当天确有到期国家命令时启用该门槛；`economy_daily` 只在冻结周期已达到
`cycle_deadline_day` 时启用。WorldClock 每次 `_advance_one_sim_day()` 返回后立即重读
`country_day_barrier` / `economy_day_barrier`，因此 day handler 当天新升起屏障时，同一渲染帧
不能再越过下一天。常规周期工作与贸易规划仍按普通软预算运行。

## Prosperity commit substep

Prosperity adds no SUS job or scheduler edge. It runs inside economy
`aggregate_publish/COMMIT`, after the committed summary swap and before dirty
generations publish. Bootstrap and legacy restore may scan once; normal commits
process only sorted, deduplicated `population_changed_cells`, so scalar and
worker paths share one deterministic naming order.

Trigger graph scheduling: `trigger_runtime` runs after committed event publication
and before Modifier/Country/Economy consumers. Its report uses `path=TRIGGER_GRAPH`,
`stage_name`, `progress_ratio`, and fallback/gap fields.
