# C++/DOTS Runtime 架构总览

## Native Modifier authority

`DCWorldExt` 内的 `ModifierRuntime` 共享实现但隔离 Climate、Country、Economy、Gameplay
四个 store。`modifier_daily` priority 90 在所有消费者前完成命令、到期和 snapshot version
发布。Modifier 永不拥有业务 base state；各领域仍拥有 temperature、country、economy 和
gameplay base SoA。完整契约见
[`native-modifier-runtime.md`](./native-modifier-runtime.md)。

## Formal product entry and save coordination

The product main scene is `main_menu.tscn`. `GameFlowService` owns one pending
new/load request and `GameSaveCoordinator` owns the cross-provider save boundary;
the former `world_setup` metadata path is development-only. The complete
generation, bootstrap, PKSV, and restore contract is documented in
[`game-flow-start-save.md`](./game-flow-start-save.md).

Saving does not introduce a second simulation authority. It freezes new clock
advancement, drains existing country/economy continuations across render frames,
then snapshots `DCWorld`, native environment state, PKCM, WorldClock, PKCN, PKEC, PKGP,
PKFG, journal, PKTR v2, and player view. Restore regenerates static geography and applies
PKCM after environment, PKCN before PKEC, PKGP after PKEC, and PKTR after Economy/domain state.
PKFG carries only the monotonic `cell_explored` progress;
current visibility and fog knowledge are derived and are recomputed on restore.

本文说明当前运行期架构如何分层，以及每层负责什么。核心原则是：复杂 cell/pixel hot-loop 尽量在 C++ `DCWorldExt` 内以 SoA slot 跑完；GDScript 保留 orchestration、feature gate、调度状态机、UI/debug、fallback 和少量低频业务逻辑。

## 总体分层

```text
Godot scene / main.gd
  |
  | fast tick / debug log / UI overlay
  v
MapGenerator / MapBaker / WeatherSystem wrappers
  |
  | create systems, build knobs, choose native/fallback path
  v
DCSystemScheduler / SusScheduler / SusSchedulerExt
  |
  | profile budget, policy, depends_on, slicing, reports
  v
DCWorld (GDScript) <---- schema ----> DCWorldExt (C++ GDExtension)
  |                                   |
  | MapData PackedArray mirrors       | Slot / SoA / C++ kernels
  v                                   v
MapData, render atlases, weather fronts, debug views
```

File ownership follows the runtime boundary: `MapGenerator` and `MapBaker`
remain stable orchestration facades, while domain implementations live under
`geography/map_generation`, `simulation/*`, and `rendering/bakers`. Runtime
diagnostic snapshots are owned by `DCDiagnosticsBus`; they are reports only and
never become simulation or DataCore authority. See
`docs/architecture/module-boundaries.md` for extraction and dependency rules.

The first completed extraction keeps the native generation result contract in
`geography/map_generation/terrain_gen.gd` and the native latitude bake contract
in `rendering/bakers/climate_baker.gd`. Both modules receive explicit inputs and
return data packages; neither registers systems, writes slots, or owns Godot
rendering objects.

`MapData` 另持三个视野数组（`visible_arr` / `explored_arr` / `fog_k_arr`），
`WorldData` 另持两个生成期烘死的静态视野场（`cell_view_height` /
`cell_view_block`）；它们由 `VisionSolver` 而非任何 C++ pass 维护。

### GDScript orchestration 层

主要入口：

- `Project/project-keynes/scripts/main.gd`
- `Project/project-keynes/scripts/geography/map_generator.gd`
- `Project/project-keynes/scripts/rendering/map_baker.gd`
- `Project/project-keynes/scripts/weather/weather_system.gd`
- `Project/project-keynes/scripts/simulation/systems/*.gd`
- `Project/project-keynes/scripts/simulation/sus/jobs/*.gd`

职责：

- 初始化 `MapData`、`WorldData`、`DCWorld`、`DCWorldExt`。
- 读取 `ClimateProfile` / feature flags，决定走 C++、DataCore 还是 legacy fallback。
- 组装 C++ pass 的 `Dictionary knobs`、PackedArray 输入和 scalar 参数。
- 调度 stage 状态机，例如 climate daily round、weather begin/solve/commit、ocean physical stages。
- 将 C++ 返回值转成 scheduler report 和 debug log。
- 在 C++ 不可用、方法签名不匹配、数据未 bind 或 pass 返回 fallback 时保持 GDScript 路径可运行。

GDScript 不应该再承担复杂全图 hot-loop 的长期权威实现。保留 fallback 是为了灰度、A/B、stale DLL 保护和回归定位，不是性能路径。

### DataCore GDScript world

主要入口：

- `Project/project-keynes/scripts/data_core/world.gd`
- `Project/project-keynes/scripts/data_core/component_schema.gd`
- `Project/project-keynes/scripts/data_core/component_ids.gd`
- `Project/project-keynes/scripts/data_core/view_adapter.gd`

职责：

- `DCWorld` 管理 GDScript 侧 component slots。
- `bind_map_data()` 把 `MapData` 的 PackedArray 绑定到 component slot。
- `write_f32/write_i32/write_u8` 系列 API 是 GDScript 写入 DataCore 的标准入口。
- `write_*_indexed` / `write_*_dense` 批量写入，并用 value-diff 标记 dirty mask。
- dirty mask 被 atlas upload、baker 和 debug 逻辑消费，用于避免全图重传。

注意：`DCWorld` 是 GDScript 侧数据核心，不等于 C++ 的 `DCWorldExt`。两者通过 schema 和显式同步契约保持一致。

### C++ GDExtension world

主要入口：

- `gdext/src/world_ext.h`
- `gdext/src/world_ext.cpp`
- `gdext/src/component_bind_table.gen.h`
- `gdext/src/knobs_struct.*`
- `gdext/src/environment_runtime.*`

职责：

- `DCWorldExt` 管理 C++ slot/SoA。
- `bind_map_data()` 根据 `component_bind_table.gen.h` 把 `MapData` 字段注册到 C++ slot。
- `refresh_slots_from_map()` 把 GDScript/MapData 当前值拉入 C++ slot。
- `flush_slots_to_map()` / 内部 `_flush_slot_to_map()` 把 C++ slot 写回 `MapData`。
- `snapshot_f32/snapshot_i32/snapshot_u8` 提供 C++ slot 快照。
- `run_*_pass` 系列执行 hot-loop，例如 climate、ocean、wind、weather、sea ice、transpiration、SLP、PSI、raster。

C++ pass 的目标形态是：循环外解析 slot id 和 knobs，循环内只做裸指针/数组计算，不做 Variant、Object get/set、字符串查找或跨语言调用。

### 调度层

主要入口：

- `Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
- `Project/project-keynes/scripts/data_core/dc_system.gd`
- `Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd`
- `Project/project-keynes/scripts/simulation/sus/sus_job.gd`
- `gdext/src/sus_scheduler_ext.cpp`
- `gdext/src/system_schedule.cpp`

职责：

- `DCSystemScheduler` 是 DataCore 版系统调度 facade。
- `DCSystemScheduler` 解释 `ClimateProfile` 中的 runtime schedule profile：frame/strict budget、job-local slice budget、must_run/starvation、以及全平台 bucket phase。
- `SusSchedulerExt` 是 C++ 实现的运行期 SUS scheduler，负责 priority、depends、frame budget、policy gate、skip、统计窗口。
- legacy `SusScheduler` 保留同形语义，作为 C++ scheduler 不可用时的 fallback。
- `system_schedule.cpp` 是 C++ 侧更进一步的 schedule graph 尝试，用于把多段 native daily chain 收进 C++ dispatch。

当前运行期仍以 GDScript 注册和组合系统为主。C++ scheduler 负责调度执行与统计，C++ pass 负责复杂计算。

## 数据权威边界

| 数据/行为 | 当前权威 | 说明 |
| --- | --- | --- |
| component schema | `component_schema.gd` | 单一源，C++ mirror 由 `component_bind_table.gen.h` 生成。 |
| GDScript runtime state | `MapData` / `DCWorld` | UI、debug、部分 baker 和 fallback 仍读取这些镜像。 |
| C++ hot-loop 中间数据 | `DCWorldExt` slot | pass 执行期间的权威计算 buffer。 |
| 阶层/市场/经济账本 | `DCWorldExt::NativeEconomyRuntime` | 独立 chunk/market store，不进入 per-cell slots；只发布 committed summary/snapshot。 |
| C++ pass 输出 | slot + publish/flush/snapshot | 输出必须显式发布到 GDScript 可见层。 |
| 调度报告 | scheduler report Dictionary | `main.gd` 和 debug console 消费。 |
| feature gates | `ClimateProfile` / `FeatureFlags` | 由 GDScript 决定 native/fallback 路径。 |
| 视野与迷雾 | `VisionSolver`（GDScript） | 事件驱动而非每日 tick。`cell.visible`/`cell.explored` 是 schema 组件，`fog_k_arr` 是只供 `enum_lut.a` 消费的派生量；只有 `explored` 进存档。详见 [视野迷雾与国界线](./vision-fog-and-borders.md)。 |

关键结论：C++ 写入 slot 不会自动让所有 GDScript 读者立刻看到。是否可见取决于该 pass 是否执行了 `_flush_slot_to_map()`、是否返回 `published_to_slot=true`、调用侧是否跳过了重复拷贝，以及 GDScript 读者是否读取的是已更新的 `MapData`/`DCWorld`。

## 运行期初始化链路

1. 玩家/Debug 入口 `await MapGenerator.generate()`；`MapGenerator` / `MapBaker` 在生成阶段边界协作式让出主循环帧，然后构建 `MapData`，生成地形、邻接、初始 climate/weather/ocean SoA。
2. `DCWorld.bind_map_data(map)` 绑定 GDScript DataCore slots。
3. `DCWorldExt.bind_map_data(map)` 绑定 C++ slots。
4. `_setup_sus()` 创建 systems/jobs；`DCSystemScheduler` 根据 profile 统一配置 budget、policy 和 job descriptor。
5. 注册完成后调用 topology/build step，使 depends graph 可运行。
6. 每个 fast tick 调用 scheduler `tick(ctx)`。
7. scheduler 按 frame budget 和 depends 运行一个或多个 `run_slice()`。
8. job wrapper 进入 `MapGenerator` / `MapBaker` / `WeatherSystem`，尝试 C++ pass，失败则 fallback。
9. pass 返回 report，scheduler 聚合为 last tick summary、job stats、budget window。
10. `main.gd` 输出 `[fast tick WARN]`、`[SUS-cpp]` 和各 job breakdown。

生成协程只改变主线程调度方式，不移动模拟或数据权威。Native base/post-base 仍由 C++ 权威计算，GDScript/Godot 仍拥有 `MapData`/`HexCell` 装配、纹理编码与上传、DataCore 初始化和场景绑定。当前不把整段生成放入 `WorkerThreadPool`：这些 Godot 对象边界不满足 worker-only POD/独占资源条件。每个单独 native/编码 pass 仍不可抢占；若某一 pass 自身形成长帧，应继续在该 pass 内切片或提供纯数据 worker kernel，而不是从 UI 层强制绘制。

## C++ 化的当前边界

已经明显下移到 C++ 的计算包括：

- climate Pass-A 和部分 daily climate 子 pass。
- ocean water / ocean land。
- wind air mass / wind surface / wind field 相关 pass。
- sea ice daily。
- transpiration。
- weather field solve / distribute / summary / stage-b 相关 native 子 pass。
- physical ocean 的 SLP、wind、PSI、upwelling、raster 等路径。
- enum/dynamic atlas 的部分 patch/cache/raster 加速。
- 生成期 native world generation base/post-base：`run_native_world_generate_base_pass` 在 `native_generation_mode=ACTIVE` 时直接生成基础地图 SoA 结果包；`run_native_world_generate_post_base_pass` 接收该结果包并在 C++ 内完成湖泊 BFS、河流 flow accumulation、河岸/植被反馈、过渡生态、地标和水体变种。GDScript 只发请求、收 PackedArray 并装配 `MapData`/`HexCell`。
- 生成期 native world generation publish：`run_native_world_generate_pass` 把生成后的 `MapData` SoA 初始仿真字段发布为 C++ slot 权威并 flush 回 `MapData`。
- 生成期高分视觉 Tile：`run_bake_visual_tile_layer_pass` 只生成临时静态视觉 byte bundle，
  GPU hierarchical horizon 只生成渲染数据；全局 geometry/CSR、HexCell、DataCore 和仿真权威
  均不移动。Godot 仍拥有 `Texture2DArray`、上传、generation-id 原子发布和 legacy fallback。
  详见 [Visual Tile Rendering](./visual-tile-rendering.md)。

仍然保留在 GDScript 的职责包括：

- job 注册、feature gate、signature probe、stale DLL fallback。
- stage 状态机和跨 tick progress 管理。
- 地图生成的 HexCell/拓扑装配；湖泊/河流/生态/地标后处理在 native generation ACTIVE 路径下已由 C++ 结果包 pass 接管，GDScript 仅保留 fallback ground-truth。
- low-N 或高业务复杂度对象逻辑，例如部分 weather front 对象层和 UI/debug。
- C++ fallback ground-truth。
- atlas GPU upload、Image/ImageTexture/RID 等 Godot 对象侧操作。
- visual tile budget/layout、Texture2DArray 生命周期、异步 compute 编排和 renderer shader variant 绑定。

## 新增 C++/DOTS 功能的架构规则

- 先确认该机制是 hot-loop 或调度长尾，不要为了低频业务逻辑提前 C++ 化。
- 输入优先来自 C++ slot；缺 slot 时临时通过 knobs PackedArray 传入，并在后续迁移中补 schema。
- 输出优先写 C++ slot，并返回 `published_to_slot` / `fallback_reason` 等明确 report。
- GDScript caller 只做 path selection、knobs 构造、返回值解释和 fallback。
- 每个新增 pass 都必须有当前 GDScript ground-truth 或 A/B 验证路径。
- 修改同步方式时同时检查 atlas dirty mask 和 debug log，否则容易出现“计算已快但渲染/上传仍慢”的误判。
# Native country authority

`NativeCountryRuntime` 与 `NativeEconomyRuntime` 同级，不是 DataCore cell component 的扩展。
它单一持有国家身份与 generation handle、领土 CSR、全国科技和现金/商品国库。GDScript 的
`CountryFacade` 只负责资源/命令打包、stable-ID 解析和冷路径查询；`CountryDailySystem` 是 priority
255 的薄调度壳。只有 `cell.country_slot` 发布到 DataCore/MapData，名称、科技、国库和 CSR 不进入
`HexCell` 或逐格 Object。

经济运行时通过窄 C++ 指针桥在 sample day 冻结归属、国家科技、generation/hash，并在整个结算
周期使用该快照。国内贸易拓扑也以该冻结归属生成国家连通分量；新订单只走同一非中立国家，
已发运订单不因后续边界变化取消。当前 PKCN v7 保存国家状态、研究/研究信号、全国与地块五类税务政策、
Country Modifier domain 与 Country Effect ingress 幂等证据；PKEC v31 引用匹配的 PKCN identity，并持久化经济状态、显赫家族及其
成员/建筑所有权、家族重要人物与需求归因、补贴权重、财政累计、科研采购累计、BuildingIdentityStore、Economy Modifier
domain、生产气候冻结/诊断字段与 Economy Effect ingress 幂等证据；
完整恢复顺序固定为 PKCM、PKCN、PKEC、PKGP。详见
[Native Modifier Runtime](./native-modifier-runtime.md)、[Native Country Runtime](./native-country-runtime.md)、
[Country / Economy Bridge](./country-economy-bridge.md) 和
[Country Scheduling / Save](./country-scheduling-save.md)，贸易机制见
[Domestic Trade Runtime](./domestic-trade-runtime.md) 与
[税收与财政结算运行时](./tax-fiscal-runtime.md)。

## Trigger graph

`TriggerRuntime` is the native event-to-effect graph between committed event
publication and domain consumers. It owns packed trigger state only; domain
commands are applied by Modifier/Country/Economy adapters at safe boundaries.
See [Native Trigger Runtime](./native-trigger-runtime.md).

## Native prosperity and settlement identity

`NativeEconomyRuntime::SettlementStore` is the sole mutable owner of per-cell
prosperity tier and settlement-name identity. Its only input is committed
population. At `aggregate_publish/COMMIT`, it consumes the already deduplicated
`population_changed_cells`, applies deterministic 10% downgrade hysteresis, and
updates only changed cells. It is not mirrored into `MapData`, `HexCell`, or a
DataCore component.

GDScript compiles `SettlementProfile` and `SettlementNamePackProfile`, resolves
stable IDs/display strings, and consumes cold snapshots or revision deltas.
`SettlementLabelLayer` owns pooled Godot visual objects only. Inspector and map
labels are read-only consumers and never become a parallel simulation.
