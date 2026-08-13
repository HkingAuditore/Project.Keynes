---
name: project-keynes-climate-runtime
description: Develop, review, tune, migrate, optimize, or diagnose the Project.Keynes climate runtime across daily climate, temperature and moisture, ocean heat transport, wind and air mass, sea ice, transpiration, albedo, vegetation feedback, weather fields/fronts, runtime hydrology, physical ocean circulation, native daily scheduling, DataCore slots, C++/GDScript parity, and climate-facing visual publish. Use for climate/weather/ocean/hydrology formulas, ClimateProfile knobs, DCWorldExt climate passes, native daily graph changes, performance spikes, CSV realism analysis, fallback retirement, slot/publish bugs, and related tests or documentation.
---

# Project.Keynes Climate Runtime

以当前源码为准完成气候运行时开发。先建立权威、数据流、算法和调度事实，再修改公式、pass、slot、profile 或发布边界。

本 skill 与 `civ-grounded-development`、`project-keynes-runtime-architecture`、`cpp-dots-runtime-development` 配合使用。前者约束 read-first；后两者约束通用 runtime、DataCore 和 C++/DOTS 契约；本 skill 只补充气候域专用事实和工作流。

## 首要规则

1. 把当前源码、生产 profile 和可运行测试视为事实源；把历史计划、旧验证日志和注释视为辅助证据。
2. 不把“调用了 C++”等同于 DOTS 权威。分别确认 formula、slot、stage/cursor、tick、visible publish、Godot object 和 fallback owner。
3. 不在 native/fallback/async/split-weather 路径之间只改一份公式。列出全部镜像并做 SAME_SOURCE/A-B。
4. 不假设 `PackedArray` 跨 GDScript/C++ 双向共享。显式设计 refresh、slot write、flush/snapshot、`published_to_slot` 和 dirty intent。
5. 不通过调高 `must_run`、放宽 frame budget 或降低采样频率掩盖单个长 native call。
6. 不先调物理系数来修复未发布、旧 DLL、错误 cadence、错误 `dt_days`、slot stale 或 recorder 取错 report 的问题。
7. 不新增平行气候状态。优先扩展 `ClimateProfile`、现有 schema slot、现有 pass、native daily bundle/report 和现有验证工具。
8. 变更机制、图顺序、slot、owner、report、fallback、默认 profile 或视觉边界时，同步更新当前 runtime 文档与本 skill。

## 必做 Grounding

先用一句话限定任务，再读 `references/system-map.md` 的气候/运行时段落。随后按任务选择源码：

- 日气候、温湿、海冰、蒸腾、植被反馈：
  - `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`
  - `Project/project-keynes/scripts/simulation/climate/*.gd`
  - `Project/project-keynes/scripts/simulation/ocean/*.gd`
  - `Project/project-keynes/scripts/simulation/sea_ice/*.gd`
  - `Project/project-keynes/scripts/simulation/biology/transpiration_pass.gd`
  - `gdext/src/world_ext_climate.cpp`
- 天气、front、天气提交：
  - `Project/project-keynes/scripts/weather/weather_system.gd`
  - `Project/project-keynes/scripts/weather/field_solver.gd`
  - `Project/project-keynes/scripts/weather/front_advect.gd`
  - `Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd`
  - `gdext/src/world_ext_weather.cpp`
- native daily、调度与 owner gate：
  - `Project/project-keynes/scripts/geography/map_generator.gd`
  - `Project/project-keynes/scripts/simulation/sus/jobs/native_daily_sim_job.gd`
  - `Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
  - `gdext/src/world_ext_daily_sim.cpp`
  - `gdext/src/system_schedule.{h,cpp}`
- 海洋物理与视觉：
  - `Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd`
  - `Project/project-keynes/scripts/rendering/map_baker.gd`
  - `gdext/src/world_ext_physical.cpp`
- schema、profile 与发布：
  - `Project/project-keynes/scripts/data/climate_profile.gd`
  - `Project/project-keynes/data/world/earth_like.tres`
  - `Project/project-keynes/data/world/earth_like_mobile_complex.tres`
  - `Project/project-keynes/scripts/data_core/component_schema.gd`
  - `gdext/src/component_bind_table.gen.h`
  - `Project/project-keynes/scripts/geography/map_data.gd`

再读当前文档中的相关章节：

- `docs/cpp-dots-runtime/runtime-authority-matrix.md`
- `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `docs/cpp-dots-runtime/computation-pipelines.md`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`

输出一份简短 grounding note，至少写明：

- 当前入口、调用链和 owner。
- 输入、输出、持久状态、临时 scratch 与可见消费者。
- native、fallback、async、split/monolithic 路径。
- cadence、`dt_days`、budget 和 dirty/publish 边界。
- 现有公式、阈值、cap、EMA/迟滞/守恒约束。
- 复用方案以及需同步的代码、测试和文档。

## Reference 路由

按任务加载，不要一次性把所有 reference 塞进上下文：

- 改 owner、调度、native daily、slot 或发布：读 [architecture-and-authority.md](references/architecture-and-authority.md)。
- 改公式、knob、字段或数值：读 [algorithms-and-data.md](references/algorithms-and-data.md)。
- 做性能优化、日志诊断、A/B、测试或 CSV 分析：读 [performance-and-validation.md](references/performance-and-validation.md)。
- 判断现状、默认生产路径、retained boundary、fallback 或已知风险：读 [current-status.md](references/current-status.md)。

## 当前图顺序底线

每次都从 `gdext/src/system_schedule.cpp::SCHEDULE_GRAPH` 复核。当前顺序为：

```text
climate_pass_a
-> climate_pass_b
-> ocean_water
-> ocean_land
-> wind_air
-> wind_surface
-> sea_ice
-> transpiration
-> albedo
-> vegetation_dynamics
-> climate_feedback
-> stage_b
-> weather
-> runtime_hydrology
-> stage_b_after_hydrology
```

节点按 bundle key 条件执行。启用 hydrology 时，GDScript 必须省略普通 `stage_b_knobs`，提供 `runtime_hydrology_knobs` 和 `stage_b_after_hydrology_knobs`，以保持 weather publish → hydrology → stage-b。不要按旧文档把 Pass-B 放到 ocean 之后，也不要把 hydrology 当成图外机制。

## 修改工作流

### 1. 建立契约表

在编码前列出：

| 项目 | 必答问题 |
| --- | --- |
| Authority | 谁拥有 stage/cursor、slot、tick、visible publish、object、fallback？ |
| I/O | 每个输入来自 slot、knob、snapshot 还是 Godot object？每个输出写到哪里？ |
| Time | stride、真实 `dt_days`、EMA、rate、cap、迟滞如何换算？ |
| Order | 前后节点读写依赖是什么？是否允许半发布？ |
| Mirrors | scalar/thread/async/GDScript/split/monolithic 哪些路径必须同步？ |
| Visibility | 谁需要 flush、snapshot、dirty intent、LUT/atlas/front apply？ |
| Validation | 哪个现有 test、A/B、CSV 指标和 perf report 能证伪？ |

### 2. 选择最小落点

- 只调平衡：优先改 `ClimateProfile` 或具体 `.tres` override，区分脚本默认与生产资源值。
- 改公式：在权威 C++ kernel 修改，并同步所有仍受支持的 SAME_SOURCE 镜像。
- 改持久 per-cell 状态：扩展 `component_schema.gd`，运行 codegen，重建 GDExtension；不要用长期 PackedArray knob 代替 slot。
- 改临时 per-round 输入：优先 resident config 或已有 bundle/knob；证明无需持久化。
- 改 stage/cursor：扩展既有 native daily graph/facade；不要另建旁路 scheduler。
- 改可视化：保留 Godot `ImageTexture`、WeatherFront、LUT/atlas 和 renderer object 边界，除非已有明确 native object API。

### 3. 实现 C++ hot loop

- 在循环外解析 component ID、knob、LUT、常量和数组尺寸。
- 在循环内只使用 raw pointer、POD、scalar 和无分配 helper。
- 为邻居读取拍稳定快照；证明 own-cell write 与 reduction 顺序后再并行。
- 保持确定性遍历、归约、merge 和 float 运算顺序。
- 把全局归约放在完整 range 或末切片；中间切片不得发布半成品给下游。
- 只在测量证明需要时启用 WorkerThreadPool/SIMD/range slicing。
- 返回 `path`、timing breakdown、`published_to_slot`、`fallback_reason`、dirty/work/cadence 证据。

### 4. 处理桥接与可见性

- GDScript→C++：round/tick 边界 refresh 一次；仅少量输入时优先 `refresh_slots_from_map_keys()`。
- C++→C++：沿用已更新 slot，不做无意义 refresh。
- C++→GDScript/MapData：按消费者需要 flush 或 snapshot。
- C++→视觉：发 `visual_dirty_intents`；不要把 intent 误报成 GPU upload 完成。
- native daily ACTIVE：允许 pass defer visible publish，但必须在 round finalizer 原子发布需要可见的温湿/热状态。
- caller 识别 `published_to_slot=true` 后跳过重复 unpack/dense copy。

### 5. 维护 fallback

- 保留明确的 PROBE/A-B/stale-DLL/failure fallback，直到有 parity 和 soak 证据。
- 报告 `fallback_reason`，不要只打印日志。
- 证明 fallback 仍在生产可达前，保持公式镜像；若只作隔离测试，明确标记并从 hot path 移出。
- 删除前更新 `runtime-deletion-inventory.md`，用 `rg` 证明无生产调用。

## 数值与物理底线

- 把核心温度、湿度、海冰等 normalized 字段按 `[0,1]` 语义处理；`soil_moisture` 是有符号异常，不是绝对湿度。
- 把 `cell_wind_x/y` 视为单位方向，把 `cell_wind_speed` 视为强度。
- 把 `cell_temp` 的 daily 唯一合成写者保持为 `wind_surface`；Pass-A 写 baseline，Pass-B 写 local anomaly，ocean 写 ocean anomaly，wind-air 写 air anomaly。
- 把 exact `0.0` 温度视为有效冻结值；只对 NaN/Inf 使用 baseline fallback。
- 按真实游戏天数换算 EMA、衰减、transition、海冰 cap、水文累计与库释放。
- 保持天气有效降水双重 gate：非降水天气残余 precip 不得进入 snowpack/hydrology。
- 保持海冰 terrain flip 与 `sea_ice_frac`、water predicate、atlas dirty 的同步。
- 保持 vegetation succession 的 native candidate + GDScript facade/visual publish 边界。

## 验证顺序

1. 用 `rg` 校验符号、调用点、绑定、graph order、mirror 和 docs。
2. 若 schema 变化，运行 `python tools/codegen/gen_cpp_bind_table.py` 并检查生成 diff。
3. 若 C++ 变化，重建 debug/release GDExtension并完全重启 Godot，排除 stale DLL。
4. 运行最小公式/graph/publish 测试，再运行对应集成测试。
5. 做 scalar/thread、native/fallback、split/monolithic 或 ACTIVE/SHADOW SAME_SOURCE/A-B。
6. 做 30+ committed tick soak；涉及季节、海冰、气候型或长期反馈时覆盖足够长日历窗口。
7. 检查 `[SUS-cpp]`、`[fast tick WARN]`、native slow dump、fallback count、publish、dirty 和 cadence。
8. 用 `tools/analyze_tile_climate_csv.py` 分析完整 tile CSV；不要从少量截图或单 tick 调参。
9. 运行 `git diff --check` 并同步 runtime 文档。

## 完成报告

说明：

- 哪个 authority、公式、slot、graph node、profile 或边界发生变化。
- 哪些路径保持镜像，哪些 fallback/retained boundary 仍存在。
- 哪些 C++/GDScript/schema/profile/docs 文件被修改。
- 使用了哪些测试、A/B、soak、CSV 和 `avg/p95/max` 证据。
- 是否存在未运行的 build/runtime 验证、旧 DLL 风险或尚未清空的 blocker。
