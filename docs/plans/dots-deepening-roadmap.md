# DOTS 深化路线图

本文目标不是继续把 GDScript 函数逐个翻译成 C++，而是把日级仿真从 **GDScript conductor 调 native pass** 推进到 **native DOTS graph 掌握数据权威与系统推进**。

## 总目标

最终形态：

- GDScript 只负责启动、profile/flag、UI/debug、Godot 对象和 texture upload。
- `DCWorldExt` 负责 runtime state、system graph、slot/SoA 权威、日级 tick、report。
- `MapData` / `HexCell` / `WeatherFront` 退化为可见镜像或 debug facade，不再决定仿真流程。

## Phase 0: 定义 DOTS 权威边界

先把“哪些东西必须由 DOTS 权威接管”写死，否则会继续变成零散 C++ pass。

要做：

- 明确 `run_native_daily_tick` 的目标覆盖范围：climate、ocean、weather、hydrology、stage_b、season refresh 的哪些部分。
- 定义 native tick 输入：`tick_index`、`sim_day`、`season_phase`、profile knobs、world seed。
- 定义 native tick 输出：slot 写入、dirty mask、front snapshot、atlas dirty intent、结构化 breakdown。
- 明确 GDScript 只允许做的事：调用 tick、读 report、上传纹理、展示 UI、fallback/A-B。

验收标准：

- 有一份 runtime authority map：每个系统当前权威是 `C++ slot`、`GDScript state machine` 还是 `Godot object`。
- 所有后续迁移都以这份 map 为准，不再按“哪个函数慢就搬哪个”推进。

## Phase 1: 让 Native Daily Tick 成为可运行主干

当前最大缺口是 `native_daily_sim_mode` 默认不是生产权威，`weather_native_daily_available()` 还阻断统一 daily 路径。

要做：

- 打通 `native_daily_sim_mode=ACTIVE` 的注册路径。
- 让 `run_native_daily_tick` 能在不破坏现有 SUS jobs 的情况下跑一整日核心链。
- 把现有 `system_schedule.cpp` 从“镜像/尝试”升级为真实 native system graph 入口。
- 每个 native node 声明 reads/writes mask，失败时返回明确 `fail_stage`，而不是让 GDScript 猜。

优先覆盖：

- `climate_pass_a`
- `climate_pass_b`
- `ocean_water`
- `ocean_land`
- `wind_air`
- `wind_surface`
- `sea_ice`
- `transpiration`
- `weather_refresh_daily`
- `runtime_hydrology`
- `stage_b`

验收标准：

- 单次 `run_native_daily_tick` 可以完整推进一天，并返回统一 report。
- 与现有 SUS sliced path 做 SAME_SOURCE A/B：关键 SoA 字段误差在既定阈值内。
- 失败时自动回到旧 SUS path，但日志明确说明失败节点。

## Phase 2: Weather 成为 Native Daily 的可见权威

这是当前阻塞统一 native daily 的关键点。天气不是只要 C++ 算完，还必须正确 publish 到 `MapData`、front snapshot、weather LUT 和可视层。

要做：

- 解决 `weather_native_daily_available()` 恒 false 的根因。
- 验证 `run_weather_refresh_daily_pass` 成功后，以下字段都能被 `MapData`、CSV、render/debug 读到：
  - `weather_type_arr`
  - `weather_intensity_arr`
  - `weather_cloud_arr`
  - `weather_precip_arr`
  - `weather_field_init_arr`
  - `weather_transition_alpha_arr`
- 把 `WeatherFront` 对象层降级为 snapshot consumer，front pool/packed fronts 由 native 状态维护。
- 让 weather LUT 发布从 GDScript job hook 变成 native report intent + GDScript upload。

验收标准：

- `weather_native_daily_available()` 可以按真实条件返回 true。
- native daily 路径下天气不是“tick 走了但画面/CSV 全 clear”。
- front 数量、类型、位置、强度与 legacy path A/B 可解释。

## Phase 3: 迁移 GDScript Stage 状态机

现在 DOTS 深度不足的核心不是 pass，而是状态机还在 GDScript。需要把 `_round_active`、`_pass_cursor`、`_phys_stage`、`_round_stage` 这类流程状态迁到 native runtime state。

优先顺序：

1. `ClimateDailySystem`
   - 迁移 `_pass_cursor`、round token、phase lock、finalizer 状态。
   - native graph 内按节点推进，不再由 GDScript 每 tick 决定下一段。
2. `WeatherRefreshJob`
   - 迁移 begin/solve/summary/hydrology/commit/stage_b 状态。
   - staged path 和 merged path 合并成一个 native transaction 模型。
3. `OceanCurrentsJob`
   - 迁移 physical round state。
   - visual raster state 可以保留在 GDScript 或 native report 层，因为它主要服务 GPU upload。

验收标准：

- GDScript job 的 `run_slice()` 变成薄调用：构造 tick ctx -> 调 native -> 转发 report。
- 不再在 GDScript 中维护仿真权威状态机。
- save/load 或 regenerate 后 native state 可重置、可诊断。

## Phase 4: 把对象权威降级为 Facade

这一步是真 DOTS 和“C++ 加速旧对象模型”的分水岭。

要做：

- `HexCell` 只保留兼容 getter/setter，权威读写走 `DCWorld` / `DCWorldExt` slot。
- `WeatherFront` 从 `Array[WeatherFront]` 权威改为 native front pool 权威。
- `MapData` 保留 SoA mirror，但不再作为 native graph 内部的中间传输层。
- 对 UI/debug/renderer 提供 snapshot API，而不是让它们读写仿真权威对象。

验收标准：

- 核心仿真不需要遍历 `HexCell` 对象。
- front 生成、推进、衰减、summary 不依赖 `WeatherFront` 实例数组。
- 对象层变化不会影响 native simulation 结果，只影响显示/调试。

## Phase 5: 减少跨语言边界

现在很多路径仍靠 `Dictionary knobs`、`has_method`、`refresh_slots_from_map()`、`flush_slots_to_map()`、`published_to_slot`。这对迁移期合理，但不是最终 DOTS 形态。

要做：

- 把高频 knobs 固化到 native profile/runtime config，避免每 tick 大 Dictionary marshal。
- native graph 内部节点直接读写 slot，中间结果不 flush。
- 每个 daily tick 只在边界做一次必要 publish/flush。
- 把 fallback reason、native breakdown、dirty intent 统一进 `NativeDailyReport`。

验收标准：

- 一天仿真不再出现多次 GDScript -> C++ -> GDScript -> C++ 往返。
- `refresh_slots_from_map()` 只在 tick 边界或外部 GDScript 写入后出现。
- `published_to_slot` 从每个 pass 的分散判断，升级为 graph-level publish contract。

## Phase 6: Native Report 和 Debug 体系统一

如果没有统一诊断，后面很难判断“DOTS 接管失败”还是“可视层没跟上”。

要做：

- 定义统一 report 字段：
  - `path`
  - `native_ms`
  - `compute_ms`
  - `flush_ms`
  - `refresh_ms`
  - `fail_stage`
  - `fallback_reason`
  - `published_slots`
  - `dirty_cells`
  - `fronts_changed`
  - `visual_dirty_intents`
- `main.gd` 不再拼各 job 私有 breakdown，而是读 native daily report。
- CSV recorder 增加 native graph 节点字段，能看到每个系统是否由 C++ DOTS 权威推进。

验收标准：

- 一段日志能回答：今天跑了哪些 system、谁写了哪些 slot、是否 fallback、是否 publish。
- 不需要到各个 GDScript job 里拼诊断字段。

## Phase 7: 收敛 Fallback，切换默认路径

最后才删或降级旧路径。不要一开始删 fallback，否则 A/B 和回归定位会很痛。

要做：

- `native_daily_sim_mode` 从 OFF -> PROBE -> ACTIVE。
- PROBE 模式：native daily 跑但不发布，用于 A/B。
- ACTIVE 模式：native daily 发布，legacy SUS 只作 fallback。
- 当连续 soak 通过后，把 legacy GDScript hot loop 降级到 debug/test-only。
- 删除已经无意义的 `has_method` 分支和旧 DLL 兼容路径。

验收标准：

- 默认桌面路径为 native daily authority。
- mobile 路径可以选择 native daily 或低频 native graph，但不是回到 GDScript 权威。
- fallback 触发率长期为 0，触发时有明确原因。

## 推荐优先级

1. 先打通 weather native publish，否则 native daily 永远无法成为主路径。
2. 把 `run_native_daily_tick` 做成完整 graph shell，哪怕第一版内部仍调用现有 pass。
3. 迁移 climate/weather/ocean 的状态机到 native state。
4. 把 object layer 降权为 snapshot/facade。
5. 减少 Dictionary/flush/refresh 边界成本。
6. PROBE/A-B soak 后切 ACTIVE 默认。

关键判断标准：以后问“今天这个模拟日由谁推进”，答案必须是 **`DCWorldExt native graph`**，而不是“GDScript job 选了几个 C++ pass 来跑”。这就是下一阶段 DOTS 深化的核心。
