# 气候运行时架构与权威

## 目录

- Worker 权威（先读这节）
- 分层
- 权威判定
- 生产调度
- Native daily 图
- 数据桥与发布
- 系统边界表
- 源码阅读地图
- 架构变更检查表

## Worker 权威（2026-09-08 起，先读这节）

**本文余下各节描述的主线程路径，在 Climate 上已经默认不是执行路径。**
`runtime_climate_authority_enabled` 生产默认 true，generate 时以 per-domain ACTIVE
（`implemented_domain_mask = CLIMATE|COMMIT = 0x802`）启动 POD worker，下面 native daily
图里的 14 个 Climate 节点被抑制门跳过，由 worker 在后台线程跑同一份共享纯内核。其余七个
gameplay domain 仍走主线程，所以余下各节对它们依然成立。

ACTIVE 下每个逻辑日的真实顺序（钉死，不可换序）：

```text
WorldClock._process() -> day_changed
  -> apply_runtime_climate_writeback(day N 的 worker 结果 -> MapData，38~39 个场)
  -> season refresh
  -> capture_runtime_inputs(day N+1：environment 快照 + round scalars + stage knobs)
  -> 主线程 14 个 Climate 节点被抑制门跳过
  -> worker 后台算 day N+1，明天回灌
```

三条必须先知道的语义：

- **滞后一日。**玩家在 day N+1 看到的是 worker 算的 day N。这是转 ACTIVE 时明确接受的代价。
- **换序会静默作废。**回灌必须在 season refresh 之前：反过来的话 season refresh 对回灌表内
  字段的写入会被次日回灌整体覆盖，没有任何报错。
- **worker 跑的 stage 比主线程少。**round 内八个（`pass_a`..`transpiration`，即下表 1–8）
  走 `run_climate_round_passes`；`albedo` / `vegetation_dynamics` / `climate_feedback` /
  `weather_distribute` / `weather_field` 五个走 `climate_stage_knobs` 通道单独接线；
  `runtime_hydrology` 两侧都不跑（生产侧 `runtime_hydrology_enabled=false` 时
  `_build_native_daily_runtime_hydrology_knobs` 返回空字典）。

已知偏差与限制：

- **stage 次序与生产不同**：worker 侧 `climate_feedback` 排在 `weather` / `distribute`
  之前，生产是之后。尚未重排。
- **ψ / cyclone / monsoon 未接**：worker 的 `WeatherFieldInput` 里这几条留空，kernel 走
  no-psi 分支，代价是涡旋驱动降水的移动性变弱。留空是刻意的——它们的推进输入是风场，而
  worker 的 wind pass 在 round 里排在 weather 之后，接上只会把风场分叉传给 ψ。
- **大地图跟不上节拍**：180x120 下 `writeback_days=30/50`，40ms 窗口内有 20 天回灌未落地。
- **小地图是负收益**：60x40 下 `sus_sim_avg` +5.5%。真实收益在帧延迟，而 headless 的
  `frame_wall_ms` 恒 0，量不出来。

回退是一个开关：generate 前把 `runtime_climate_authority_enabled` 设 false，即回到下面
描述的主线程路径。SHADOW 对拍也要走这条。

## 分层

```text
WorldClock.day_changed
  -> MapGenerator.sus_tick_daily / bundle & boundary orchestration
  -> DCSystemScheduler
  -> SusSchedulerExt budget / policy / skip / stats
  -> DCSystem or retained SusJob shell
  -> DCWorldExt SoA slots + native pass / native daily continuation
  -> pass report / graph report / finalizer / visual intents
  -> DCWorld / MapData / CSV / WeatherFront / LUT / atlas / renderer
```

- `ClimateProfile` 和具体 `.tres` 决定 feature gate、cadence、budget、物理 knob 与 owner gate。
- `DCWorld` 是 GDScript DataCore mirror；`DCWorldExt` 是 C++ slot/SoA compute world。
- `MapData` 是大量 GDScript、debug、CSV、baker 和 renderer 的可见 SoA mirror。
- `SusSchedulerExt` 负责调度，不拥有气候业务状态。
- `MapGenerator` 负责生命周期、bundle、fallback、finalizer 和 Godot 边界，不应重新承接全图数学 hot loop。

## 权威判定

逐项判断，不用单一“native=true”概括：

| 维度 | 证明 |
| --- | --- |
| Formula authority | 哪个实现决定数值公式；其他实现是否只是 SAME_SOURCE fallback。 |
| Slot authority | 哪个 pass 写 C++ slot；slot 是否是 schema 单一字段。 |
| Stage authority | 谁持有 round active、cursor、phase lock、reset/abort。 |
| Tick authority | 谁决定本 logical day/round 执行哪些节点和何时提交。 |
| Visible authority | MapData、CSV、renderer 是否看到同一提交态。 |
| Object authority | WeatherFront、ImageTexture、RID、MultiMesh 等 Godot 对象由谁管理。 |
| Fallback authority | native 失败后谁推进状态，是否仍属 production path。 |
| Worker authority | 该场是否由 POD worker 在后台线程算、经回灌进 MapData；主线程写者是否已被抑制门挡住。 |

只有 native 同时拥有 state、slot、tick/cursor、graph report 和发布契约时，才称 DOTS-authoritative。`published_to_slot=true` 只证明具体 pass 的 slot publish，不证明 front/LUT/GPU 可见。

Climate ACTIVE 下还要多问一层：**这个场有回灌写者吗？**worker 算出来但没有 store 成员或
没进 `apply_runtime_climate_writeback` 的场，MapData 会停在世界生成值而不报错——`soil_moisture`、
pass_a 的五条输出（`insolation_now/dev`、`day_length`、`heat_input`、`temp_season_offset`）
和 `weather_field_init` 都栽在这上面，表现是"字段冻结"而不是数值分叉。反向也要问：**主线程还有第二个写者吗？**
抑制门漏掉的写者会和回灌打架，表现为单 tick 跳变。

## 生产调度

> Climate ACTIVE 下这一节描述的注册结果仍然发生（节点照常注册），**但 Climate 那些节点在
> 执行时被抑制门跳过**。看调度报告时不要把"已注册"读成"跑过了"。

`MapGenerator._setup_sus()` 使用 `DCSystemScheduler`。当前重要形态：

1. 注册 `season_refresh`、`ocean_currents` 和保留边界 `natural_resource_daily`。
2. 生产 profile 满足 native daily ACTIVE readiness 时，注册 `native_daily_sim` 并 early-return，不再注册 legacy daily climate/weather/sea-ice production jobs。
3. ACTIVE 不可用时，注册 `refresh_climate_daily`、可选 `sea_ice_daily`、`weather_refresh` 及视觉 jobs。
4. `natural_resource_daily` 处于 native/legacy 分叉之外；它消费已发布 climate slots。

`frame_budget_ms` 只决定是否启动下一个 slice，不能抢占已进入的 C++ pass。`slice_budget_ms` 只提供协作式让出。`must_run` 不应用来隐藏长节点。

生产 `earth_like.tres` 当前采用：

- `native_daily_sim_mode=ACTIVE`
- stride 10、commit lag budget 10
- spread across ticks + coarse yield
- split weather
- node range for ocean water/land
- ocean thread variant
- sliced/native finalizer publish
- climate/weather/ocean/season active owner gates
- legacy daily production retired
- runtime hydrology enabled
- physical cell slicing enabled

移动复杂 profile 使用 stride/lag 20、单 slice/tick、split weather、owner gates、legacy retirement 和 hydrology，但未显式启用桌面 profile 的全部 node-range/thread/native-finalizer overrides。每次以资源文件为准。

## Native daily 图

`gdext/src/system_schedule.cpp` 的当前表是唯一顺序事实：

1. `climate_pass_a`
2. `climate_pass_b`
3. `ocean_water`
4. `ocean_land`
5. `wind_air`
6. `wind_surface`
7. `sea_ice`
8. `transpiration`
9. `albedo`
10. `vegetation_dynamics`
11. `climate_feedback`
12. `stage_b`
13. `weather`
14. `runtime_hydrology`
15. `stage_b_after_hydrology`

表按 bundle key 跳过不存在的节点，不是每轮无条件跑完 15 项。

> **Climate ACTIVE 下这 15 项由 worker 承担（`runtime_hydrology` 除外，两侧都不跑），且
> 次序不同**：worker 的 `climate_feedback` 排在 `weather`/`distribute` 之前。下面那些"关键
> 顺序理由"是主线程图的性质，worker 侧只保证 round 内八个 pass 的 in←out 接力顺序，五个
> `stage_knobs` stage 的相对位置尚未对齐生产语义。这是已知待办，不是已验证等价。

关键顺序理由：

- Pass-B 读取 round-start TTA，必须在当天 ocean 更新之前运行，防止当天新 TTA 即刻反馈进当天湿度。
- `wind_surface` 汇总 baseline、ocean、air 和 local anomaly 后发布 `cell_temp`。
- sea ice 必须读取 wind-surface 后的有效温度。
- weather 读取当轮 climate/wind 可见状态。
- hydrology 读取当天有效 precip，并在 stage-b 读取 soil/WB30 前完成。
- hydrology 开启时用 `stage_b_after_hydrology`，不能同时跑普通 `stage_b`。

split weather 可把 monolithic `weather` 交易拆为 field、commit、distribute、summary、cyclone、weather-stage-b 子节点；报告必须保留聚合字段并指出 `weather_split_skipped_monolithic=true`。

native daily continuation：

- `run_native_daily_slice()` 持有 graph continuation、node cursor 和 round accumulator。
- 中间 slice 的 `published_slots` / `visual_dirty_intents` 为空是正常的。
- 完成 slice 才发布 graph-level report，并进入 GDScript/native finalizer 与 Godot boundary apply。
- `native_daily_sample_day`、commit day、age、lag budget 和 over-budget 共同定义有界降频契约。

## 数据桥与发布

GDScript→C++：

- round start 或明确 GDScript 写入后调用 refresh。
- 少量输入使用 `refresh_slots_from_map_keys()`。
- 连续 native 节点直接消费前一节点更新的 slot。
- static/profile 配置优先常驻 native runtime config；bundle 只带 tick delta 和必要对象边界输入。

C++→GDScript：

- `_flush_slot_to_map()` 使 `MapData` 可见。
- `snapshot_*` 用于 debug/A-B/save 型 pull。
- `published_to_slot=true` 让 caller 跳过重复 copy。
- `defer_visible_publish=true` 只延迟可见镜像，不移动 slot authority；round finalizer 必须完成原子可见提交。

图级发布：

- `published_slots`：本轮声明的 slot family。
- `visual_dirty_intents`：请求 GDScript/Godot 刷新，不等于已经上传。
- `authority_blockers`：阻止 simulation graph complete 的 authority/fallback 项。
- `retained_boundaries`：明确保留的 object/visual/debug 边界，不应被误算为 blocker。
- `graph_coverage_state=complete` 不要求消灭 WeatherFront 或 ImageTexture。

CoW 规则：

- 不假设传入 PackedArray 被 C++ 原地修改后 GDScript 自动看到。
- 返回 PackedArray buffer 时必须接收返回值。
- `bind_map_data()` 后某侧重新赋值/写时，不保证另一侧引用仍同步。

### Worker 通路（Climate ACTIVE）

上面那套 slot/flush 是主线程通路。worker 走的是另一条，二者不共用：

主线程→worker（`capture_runtime_inputs`，每日一次）：

- `RuntimeEnvironmentSnapshot`：全部 per-cell lane 的整份拷贝。
- `climate_round_scalars`：复用生产的 `_build_native_daily_climate_pass_a_struct` 构建，
  **必须整套传**。只补单个字段治不了病——`season_phase` 缺失是永远的春分，`insol_amp` 取
  结构默认 0.20 而 profile 是 0.32，季节振幅只剩 62.5%。
- `climate_stage_knobs`：五个 stage 各自的 knobs + lane，键名口径必须逐字对生产的解析处。
- `ClimateRoundStaticKnobs`：catalog 表、`water_terrain_ids`、`neighbor_indices`。

worker→主线程（`apply_runtime_climate_writeback`，次日一次）：

- store 内字段走 `RuntimeClimateStore`。
- store 外字段走 `RuntimeClimateSnapshot` extras，**刻意不进 store**，因为进 store 会动
  PKEC 存档格式：`soil_moisture` 与 pass_a 五条输出用 `apply_extra`（F32）；
  `weather_field_init` 用 `apply_extra_u8`（U8）。C2 曾测到 ACTIVE 整场 `field_init=0`、
  OFF 整场 `1`，客户端因此把已回灌的 `weather_type` 当成从未初始化。

三条跨边界的坑（都真出过事）：

- **缺 lane 是静默的。**`copy_f32` 语义宽松，缺席的 lane 被填成等长全零而不是报错。
  `sea_ice_frac` 就是这样每天从零冰起算，max 恒等于 `si_daily_delta_cap`。
- **缺 knob 落到结构默认值。**默认值往往是个合理数字，于是表现为"物理偏弱"而不是崩溃。
- **枚举跨边界必须给字符串。**Godot 4 的 `String()` 构造函数不接受 int，给序号会在
  GDScript 侧抛构造错误、打断整个字段收集，表现成 parity 0/30 而非某字段分叉。

## 系统边界表

| 系统 | 当前主要 owner | 保留边界 |
| --- | --- | --- |
| Climate daily | native graph/pass + finalizer；legacy `ClimateDailySystem` 保留 fallback/debug | reset/abort、MapData/dirty/diagnostics |
| Weather | native field/commit transaction 已可 ACTIVE；GDScript保留 facade | WeatherFront object、LUT/ImageTexture、repair/probe |
| Runtime hydrology | native graph/pass | legacy staged A/B entry、视觉河宽消费 |
| Physical ocean | C++ SLP/wind/PSI/current slots；native facade 镜像 stage state | raster、texture commit、Godot buffer |
| Sea ice | native pass/graph fraction | terrain facade sync、visual dirty/upload |
| Vegetation dynamics | C++ vitality/stress/succession candidate | GDScript 写 candidate 到 vegetation/base facade 并刷新 scatter |
| Season refresh | active owner gate 可声明 native state | atlas queue、detail scatter、Godot upload |
| Climate visuals | simulation slots 只读输入 | LUT/atlas encoding与GPU upload仍为 Godot 边界 |

> **Climate ACTIVE 下前六行的"当前主要 owner"要再往上挪一层**：native graph/pass 仍是算法
> 实现，但**执行者是 worker 线程**，主线程那一份被抑制。"保留边界"列不变——reset/abort、
> MapData dirty、diagnostics、WeatherFront、LUT/texture、scatter 上传全都仍在主线程，这也是
> 为什么 worker 权威没有消灭这些边界。Season refresh 是特例：它仍完整跑在主线程，且必须排在
> 回灌之后。

## 源码阅读地图

- `gdext/src/world_ext_climate.cpp`：Pass-A/B、ocean heat、sea ice、transpiration、hydrology、albedo、vegetation、feedback、stage-b、async/native climate round。
- `gdext/src/world_ext_weather.cpp`：weather field solve、commit、wind-air/surface、distribute、front summary、combined transaction。
- `gdext/src/world_ext_daily_sim.cpp`：slice graph、bundle patch、owner snapshot、report、published slots、visual intents。
- `gdext/src/system_schedule.cpp`：节点顺序与 dispatch。
- `gdext/src/world_ext_physical.cpp`：SLP、wind field、PSI、upwelling、physical solve。
- `map_generator.gd`：生产注册、bundle、profile gate、finalizer、readiness、fallback、visible apply。
- `climate_daily_system.gd`：legacy/async round shell、diagnostics、boundary intents。
- `weather_refresh_job.gd`：staged/merged weather、front/LUT/hydrology边界。
- `ocean_currents_job.gd`：physical/visual 双状态机。

Worker 权威路径（Climate ACTIVE）：

- `gdext/src/world_ext_simulation_host.cpp`：capture（含 scalars / stage knobs / static knobs
  的全部解析）、writeback、parity 字段表与哈希、权威门。**读接线问题从这里起步。**
- `gdext/src/runtime_climate_kernel.cpp`：worker 侧 round 编排与五个 stage_knobs stage 的
  守卫。lane 长度不足时整段跳过，守卫条件在这里。
- `gdext/src/runtime_climate_passes.{h,cpp}`：九个 pass 的共享纯内核，生产与 worker 同一份。
  两侧数值不同时先排除输入差异，不要先怀疑这里。
- `gdext/src/runtime_pod_protocol.h`：`RuntimeEnvironmentSnapshot` 与各 stage Input 结构的契约。
- `Project/project-keynes/tests/climate_parity_probe.gd`：SHADOW 对拍 harness。
- `docs/cpp-dots-runtime/full-authoritative-runtime-status.md` §39–§42：落地过程、四类缺陷
  与方法论积累。

## 架构变更检查表

- 更新 `component_schema.gd` 后运行 codegen 并提交生成 header。
- 更新 bind method；新 DLL 能被 `has_method()`/能力探针识别。
- 更新 GDScript wrapper、native bundle builder、async input、fallback 和 report。
- 更新 `SCHEDULE_GRAPH` 与 graph-order tests。
- 更新 authority matrix、bridge、scheduling、computation、diagnostics 文档。
- 保留 fallback 直到 A/B/soak；删除时更新 deletion inventory。
- 证明可见消费者看到完成态，而不是半轮 slot 或旧 MapData。

Climate 改动额外要过的（ACTIVE 下主线程那条路已经不是生产路径，只测它等于没测）：

- 新增/改名任何 per-cell 场：capture 侧有没有填？worker 有没有 store 成员或独立字段？
  writeback 有没有写者？三处缺一处都是静默冻结。
- 新增 knob：capture 的字典键名有没有逐字对上 C++ 解析处？默认值有没有照抄生产的 clamp？
- 改 stage 顺序或节拍：`climate_stage_knobs` 那五个 stage 的节拍计数器是 worker 侧独立的，
  生产计数器在抑制后永不推进，不要拿它做判断。
- 验收不能只跑 headless：ACTIVE soak 的字段统计过了，仍可能在客户端翻车（已发生四次）。
  对着 `PK_SOAK_AUTHORITY=0` 的同 seed 基准读 nz/mean/max，再让玩家录一份 tile CSV 对照。
