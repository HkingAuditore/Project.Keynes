# GDScript / C++ Data Bridge

## Modifier PackedArray bridge

`ModifierFacade` 通过 protocol v1 平行 PackedArray 提交 apply/remove/refresh/set-stacks；
`DCWorldExt` 在 C++ 中稳定排序后写四域 store。GDScript 不持有 bucket 或实例镜像，也不能直接
修改 native store。command result、list、explain、journal 和 report 是冷查询；气候 fallback
只能调用 `evaluate_modifier_stat`，生产 hot loop 使用 native helper/冻结 POD。PKCM/PKGP 直接
传 `PackedByteArray`，PKCN/PKEC 内嵌对应 domain。详见
[`native-modifier-runtime.md`](./native-modifier-runtime.md)。

## Complete-save bridge

PKSV persistence is a snapshot boundary, not a new owner. GDScript coordinates
section capture while each native authority emits its own versioned state:
PKCN v2, PKEC v22, PKCM v1, PKGP v1, and `PKEnvironmentRuntime v1`. Environment export includes the
resident core vectors, weather ping-pong buffers, topology, dirty/active sets,
round flags, stage cursors, and snapshot generations. Restore validates schema
and dimensions before swapping any arrays. See
[`game-flow-start-save.md`](./game-flow-start-save.md) for section and ordering
rules.

ACTIVE bundle 的紧凑 capsule ABI、旧 DLL fallback 和植被 indexed publish
契约见
[运行时性能优化契约](runtime-performance-optimization-2026-07.md)。

本文记录 GDScript、DataCore、C++ GDExtension 之间的数据传递契约。性能问题里大量“明明设计上应该走 C++，日志却显示 `path=gdscript`”或“C++ 已经算完但画面/后续 pass 没变”的原因，都来自这里的同步边界。

> 贸易拓扑的地形输入固定为地图生成权威的 `MapData.base_terrain_arr` / `cell_base_terrain`。
> `cell_terrain` 归气候动态层所有，海冰等季节性切换不得进入贸易拓扑哈希。

## 参与者

| 角色 | 文件 | 职责 |
| --- | --- | --- |
| `MapData` | `Project/project-keynes/scripts/geography/map_data.gd` | 地图级 SoA 镜像，保存 terrain/temp/moisture/ocean/weather 等 PackedArray。 |
| `DCWorld` | `Project/project-keynes/scripts/data_core/world.gd` | GDScript DataCore world，绑定 `MapData`，提供 `write_*`、dirty mask、view API。 |
| `DCWorldExt` | `gdext/src/world_ext.cpp` | C++ DataCore world，保存 C++ slot/SoA，执行 native pass。 |
| schema | `component_schema.gd` | component 单一源，声明 GDScript name、C++ name、dtype、map_field、owner。 |
| C++ bind table | `component_bind_table.gen.h` | schema 的 C++ mirror，供 `DCWorldExt.bind_map_data()` 使用。 |
| `HexCell` facade | `Project/project-keynes/scripts/geography/hex_cell.gd` | 兼容 `cell.temperature = v` 等旧写法，底层转成 `world.write_f32()`。 |

## Schema 绑定契约

`component_schema.gd` 是 DataCore component 的单一源。每条 schema 记录至少包含：

- `name`：GDScript 侧 dot name，例如 `cell.temp`。
- `cpp_name`：C++ 侧 underscore name，例如 `cell_temp`。
- `dtype`：`F32` / `I32` / `U8`。
- `map_field`：`MapData` 上的 PackedArray 字段名。
- `owner`：该字段主要由哪个机制写入。

`DCWorld.bind_map_data()` 直接读 schema 并把 `MapData` 字段挂到 GDScript slot。`DCWorldExt.bind_map_data()` 读 `component_bind_table.gen.h`，注册 C++ slot 并绑定对应 `MapData` 字段。

约束：

- 改 schema 后必须同步更新 C++ generated bind table。
- C++ pass 内 `component_id("cell_temp")` 使用的是 `cpp_name`，不是 GDScript dot name。
- `map_field` 拼错会导致 bind 静默偏离或 slot size 为 0，后续 C++ pass 可能 fallback。
- dtype 不一致会让 `arr_f32` / `arr_i32` / `arr_u8` 访问错槽，必须在 bind 阶段报错处理。

Runtime hydrology 新增的契约：

- `cell.hydro_parent` / `cell_hydro_parent`：`I32`，`map_field=hydro_parent_arr`，owner 为 `map_generation`。这是生成期 Priority-Flood parent graph 的静态拓扑，非河流陆地也可有下游 parent。
- `cell.river_flow` / `cell_river_flow`：`F32`，`map_field=river_flow_arr`，owner 为 `map_generation`。这是生成期归一化河宽/径流权重，season river ecology 可直接读 slot 区分普通河道与强径流主河。
- `cell.river_discharge`、`cell.river_discharge_30d`、`cell.river_storage`、`cell.groundwater_storage`、`cell.surface_runoff`：`F32`，owner 为 `runtime.hydrology`。这些字段由 `run_runtime_hydrology_pass` 写入并 `_flush_slot_to_map()` 回 `MapData`。
- Legacy `run_hydrology_discharge_pass_native()` 在调用 C++ 前先 `refresh_slots_from_map()`，确保 weather commit 写到 `MapData` 的 `weather_precip/snowpack/soil_moisture` 对 C++ 可见，并从 weather cadence 游标传入真实 `dt_days`。Native daily graph 中的 `runtime_hydrology` 节点复用 round 起点 refresh，依赖前序 weather node 已在 C++ slots 中发布当日 precip，并使用 `native_daily_sim_stride` 作为本轮 dt。
- Native daily ACTIVE 在构建 round bootstrap bundle **之前**调用 `MapData.soa_begin_climate_transaction()`；该边界同时冻结 `temp/moisture/snow/sea_ice *_prev` 和 `weather_classification_temp/moisture`。若在 bundle 之后才冻结，weather knobs 会捕获错误引用；若完全不冻结，classification 与 `*_prev` 会永久停在地图生成态。
- `cell.res_timber_reserve`、`cell.res_stone_reserve`、`cell.res_arable_land_reserve` 等 31 个自然资源/农业容量储量字段：`F32`，owner 为 `economy.resources`，`map_field=res_*_reserve_arr`。另有一一对应的 `cell.res_*_extra_change` 字段；生产发布一次性采收/开采 delta，资源 pass 只应用一次后清零。`cell.resource_habitat_mask`（U8）编码 land/marine-water/freshwater/coastal-land habitat；`marine_fish` 使用与海洋水格相邻的 coastal-land bit，`freshwater_fish` 使用湖泊水格及湖岸陆格的 freshwater bit，使渔场只读取本格储量。鱼类资源占用 DataCore 经济资源 slot。小麦、玉米等栽培作物不再拥有 DataCore slot，而是 MarketStore goods。新增资源需加 reserve/extra 常量 + MapData 数组 + schema 行 + codegen + 重 build，并登记 `ResourceProfileRegistry._PROFILE_PATHS`。knobs 使用 `habitat_modes`/`habitat_mask_slot` 和 `dt_days`；五日 catchup 仅放大自然演化，不重复放大 external delta。
- `cell.plant_available_water` / `cell_plant_available_water`：`F32`，
  `map_field=plant_available_water_arr`。climate owner 在陆地按基础湿度、30 日水量平衡和正土壤
  蓄水合成并夹到 `[0,1]`，水域固定写 0。C++ combined/thread/scalar 与 GDScript fallback
  使用同一公式并在完成边界发布。
- 资源 pass 的 `cell_temp` 与 `ResourceProfile.temp_lo/temp_hi` 均使用 `[0,1]` 地图气候单位；目录审计禁止摄氏式范围。植被 dynamics 的 C++ 返回包中 `succession_indices/succession_to_veg` 不直接改变 enum 权威；`MapGenerator._apply_vegetation_succession_candidates()` 在 Godot 边界批量写 `cell_vegetation/cell_base_vegetation` 到 DCWorld 与 DCWorldExt，并同步 HexCell/MapData 后才对视觉消费者可见。
- 自然资源目录逐 Profile 选择温度/水分列。`fertile_soil`、`timber`、`wild_game` 读取
  `cell_temp_30d + cell_plant_available_water`；淡水/海洋鱼读取
  `cell_temp_30d + cell_moisture`；地质资源继续读取即时温度与环境湿度。native pass 与
  GDScript reference 必须逐 cell 对拍。

建筑 sample boundary 仍从 `MapData.neighbor_indices_packed()` 捕获静态六邻拓扑，供建筑条件和
国内贸易使用；它不再参与资源采集。目录保留
`building_production_resource_access_modes` 对齐列，但所有值必须为 local/0，GDScript catalog 和
NativeEconomyRuntime 都拒绝非零值。生产和 Inspector 可达储量查询只读取建筑本格。
- Goods 已退出 cell schema。库存/价格/需求 EMA/短缺由 `NativeEconomyRuntime::MarketStore` 的 market-major 定点矩阵持有，库存属于本地 merchant cohorts，成交资金直接进入商人而非匿名 market cash。UI 通过 `get_market_cell_snapshot(cell_idx)` 冷路径查询。旧 Dictionary 存档多出的 `cell_goods_*` key 被自然忽略；新经济状态只走 PKEC v14 byte chunks。新增 good 只新增资源，不再改 `MapData` 或 bind table。

国内贸易拓扑也不进入 DataCore schema。`MapData.neighbor_indices_packed()` 与
`economy_trade_passable_lut()` / `economy_trade_move_cost_lut()` 在经济边界通过
`capture_economy_trade_topology()` 一次性传入平行 PackedArrays；C++ 再结合冻结
`cell_country` 构建连通分量。`MapGenerator._setup_economy_runtime()` 在 native economy
configure 成功后、population/market/building bootstrap 前执行该捕获；`OFF` 跳过，
`PROBE/ACTIVE` 若 API 缺失或捕获失败则中止本次经济初始化，禁止出现“模式已开启但拓扑
未就绪”的静默状态。地图只提供输入，不持有路线、信号、订单或托管。

Economy bridge 是粗粒度 packet ABI：bootstrap/commands 使用平行 PackedArrays；hot loop 不出现 Dictionary、Callable 或 Object。每个 ACTIVE market cycle 的 sample day 由 `world_ext_economy.cpp` 从 temp/moisture/snow/weather raw slots 捕获一次 Q16 snapshot；周期内不重复跨界。gameplay 与 save 只观察 committed boundary；选中地块 Inspector 是有界冷查询例外。首屏摘要只调用不生成需求预览的 `get_population_cell_summary`；人口、市场、建筑标签按当前可见标签惰性调用 `get_population_cell_snapshot` / `get_market_cell_snapshot` / `get_building_cell_snapshot`。贸易单使用 `get_trade_orders_for_cell(cell, offset, limit)` 分页查询并返回物资行 CSR，禁止全局订单矩阵。完整查询在 native slice 之间同步返回最新数组，in-flight 标记 `snapshot_source=live_slice, committed=false`，边界标记 `snapshot_source=committed`。查询不复制全图、不修改经济状态，也不进入 state hash/存档。人口预计需求另取选中 cell 当前环境 slot，复用同一原生需求内核生成 cohort-major CSR。详见 [Native Economy Runtime](./native-economy-runtime.md) 与 [Domestic Trade Runtime](./domestic-trade-runtime.md)。

同日经济 continuation 使用绑定方法 `run_economy_slice_compact(ctx)`；它和
`run_economy_slice(ctx)` 进入同一个 `DCWorldExt::run_economy_slice_internal`，因此环境/建筑上下文
冻结、资源 delta flush、committed CSV capture 与 gameplay event publish 的顺序完全一致。差异只在
native 返回字典：compact 不构造内存、债务、transit/escrow 等全量冷诊断，GDScript 也不以 compact
结果覆盖最后一个 full report。旧 `run_economy_slice` API 和 component bind table 均不变。
`EconomyDailySystem` 在既有 `ctx` Dictionary 中附带自身的 `slice_budget_ms`，仅供原生图在
`building_commit`/`aggregate_publish` 内决定是否继续跨越下一个廉价子阶段；字段不进入
DataCore、PKEC 或权威哈希，旧调用缺省为 0.8ms。

经济 CSV v14 是同一 committed visibility boundary 的 debug consumer。`DCWorldExt::run_economy_slice()` 先完成 `publish_epoch()`，再把建筑自然资源 delta 写入/flush 到 DataCore reserve slot，最后才允许 `EconomyCsvRecorder` 把 native cohort/market/building SoA 与资源 slot 复制进一个空闲 POD buffer。后台 worker 只接触 `std::vector`、字符串表和绝对路径，不访问 Godot API 或运行中的 runtime。控制面仅绑定 `start_economy_csv_recording(config)`、`request_stop_economy_csv_recording()`、`get_economy_csv_recording_status()`；GDScript 不再逐 cell 调 snapshot API。`config.cell_indices` 为空时按 `cell_stride` 取全图样本，非空时排序去重并覆盖 stride；GM 的“当前地块”只传一个在 start 时锁定的 index。summary 仍是全局提交摘要，cohorts/buildings/resources/market 仅遍历显式样本；building 行明确区分 `owner_capacity`（物理容量）、`owner_required`（活跃组等于容量、停产/不可用组为零）、`planned_owner_equivalent`（仅用于观察利用率折算量）、`filled_owner` 与 `owner_openings`，并发布 `projected_owner_income_per_day`。v14 summary 保留既有字段并新增 ACTIVE 业主岗位重配、跨职业和概率跳过计数；market 继续包含逐商品投入预留、家庭可用库存和完整配置周期的商人目标库存。双缓冲满时自动停止接收并排空已接受批次，不阻塞经济提交；CSV 调试状态不进入 PKEC、replay hash 或 simulation authority。

## Production climate bridge override (current)

Each due cell is sampled once from six raw F32 slots: current temperature,
30-day temperature, ambient moisture, plant-available water, snow, and weather.
`world_ext_economy.cpp` quantizes all six to Q16 without per-cell Godot calls.
They share the environment hash, shape validation, reset, memory accounting, and
PKEC v22 cell record. The frozen values remain private until that cell's rolling
settlement commits.

Economy CSV v22 supersedes the historical v14 recorder paragraph above. Its
building rows append temperature fit, water fit, climate capacity, and
climate-lost output; summary rows append profiled/limited group counts and the
average climate capacity. These are committed read-only diagnostics, not a
second authority.

## PackedArray CoW 公理

Godot `PackedFloat32Array` / `PackedInt32Array` / `PackedByteArray` 是 Copy-on-Write。当前架构不依赖双向可变零拷贝。

必须按以下事实开发：

- `bind_map_data()` 初始可以让两侧看到同一份 backing。
- C++ 一旦对 PackedArray 调 `ptrw()` 写入，可能 detach，C++ 侧持有自己的 buffer。
- GDScript 修改 `map.temp_arr[i]` 不保证 C++ slot 看到。
- GDScript 修改 `world.view_f32(cid)[i]` 不会写回 world。
- C++ 写 slot 不保证 GDScript 读者看到。
- 两侧同步必须走显式 API。

因此，“C++ 算过”与“GDScript/渲染读到新值”是两个事件，中间必须有 publish/flush/snapshot。

## Gameplay event bus 契约

`DCWorldExt` 现在提供通用 gameplay event bus，定位是“可持久化/可回放的技术基建”，不是某个视觉系统的临时队列。它与 DataCore slot 并列：

- slot 保存当前状态；event bus 保存发生过的事实。不要把 event journal 镜像进 `component_schema.gd`。
- C++ 和 GDScript 都可发布事件，入口分别是 native `_emit_gameplay_event()` / `_emit_succession_events()` 和 GDScript `GameplayEventBus.publish_event()` / `publish_events_batch()`。
- 所有事件进入统一单调 `event_id`、统一 ring/log 和统一 packed-array schema。基础字段包括 `event_id`、`tick`、`phase`、`type`、`source`、`flags`、`entity_id`、`cell_idx`、`payload_schema`、`payload_i0..i3`。
- 第一批类型包括 `VEGETATION_SUCCESSION`、`TERRAIN_FLIP`、`WEATHER_FRONT_CHANGED`、`VISUAL_DIRTY_INTENT`。`VEGETATION_SUCCESSION` 的 payload 约定为 `cell_idx` + `old_veg/new_veg`。
- 消费端必须使用 consumer cursor：`poll_gameplay_events({"consumer_id": ...})` 读取，`ack_gameplay_events(consumer_id, up_to_event_id)` 确认。renderer、UI、debug 不应共用一个 consumer id。
- 持久化使用 `snapshot_gameplay_event_journal()`，恢复使用 `restore_gameplay_event_journal()`，回放使用 `replay_gameplay_events()`。快照只含 POD/packed payload，不含 Godot Object 引用。
- ring buffer 溢出不静默：report 必须显示 `dropped_event_count` / `first_dropped_event_id`，consumer 落后看 `consumer_lag`。

GDScript 侧统一通过 `scripts/data_core/gameplay_event_bus.gd` 包装 native API。渲染或 UI 不直接解析 C++ raw arrays，除非是在 debug 工具里显式 inspect schema。

### Economy event journal

千万 cohort 经济域不把逐笔变化直接写入通用 gameplay ring。`NativeEconomyRuntime` 使用专用
header + delta-leg journal，并由 `DCWorldExt` 暴露 `get_economy_event_schema`、
`set_economy_trace_filter`、`poll_economy_events`、`ack_economy_events`、
`get_economy_trace_report` 与 PKEJ archive chunk API。跨界输出始终是 PackedArrays；
`EconomyFacade.economy_event_batch` 仅在 committed boundary 批量 emit；冷路径
`write_event_archive()` 使用 `FileAccess.COMPRESSION_ZSTD` 写独立压缩 PKEJ 文件。

handler 是只读观察者。需要改变经济时必须提交 economy command，由下一冻结周期处理；禁止
在 market/building hot loop 中调用 Callable、发逐事件 signal 或构造 Dictionary。

玩家人口 Inspector 另用 `set_economy_inspector_trace_cell(cell)` 注册一个单地块目标，不覆盖
调试 `set_economy_trace_filter`。`get_population_cell_snapshot` 会返回上次提交周期的稀疏
cashflow CSR、周期日期和 `settlement_detail_available/pending`。滚动五相模式只在该地块实际
到期结算时提交新的完整 cashflow 批次；其余相位继续保留上一次完整分类，首次选中则保持
pending 直到该地块首次到期结算。
该缓存不进入 DataCore slot、PKEC 存档或核心 state hash。

## GDScript 写入 C++ 可见数据

### 单点写

`DCWorld.write_f32(comp_id, idx, v)` / `write_i32` / `write_u8`

用途：

- 兼容 `HexCell` facade setter。
- 少量实体或 debug 写入。

副作用：

- 写入 GDScript slot。
- 标记 dirty mask 单点。

风险：

- 在 N=2400 或更大全图 hot-loop 内逐 cell 调用会产生 `_dirty_mark_one` 风暴。
- 全图或大批量更新应改用 indexed/dense API。

### 连续区间写

`write_f32_range(comp_id, start, src)` / `write_i32_range` / `write_u8_range`

用途：

- 把一整段 PackedArray 推入 `DCWorld`。
- 常见于 weather field solver 或初始化同步。

副作用：

- 标记 `[start, start + n)` dirty range。

适用条件：

- 输入天然连续。
- 变化范围本身就是整段，不需要 value-diff 降低 dirty。

### 稀疏索引写

`write_f32_indexed(comp_id, indices, values)` / `write_i32_indexed` / `write_u8_indexed`

用途：

- hot pass 在 GDScript fallback 中收集 dirty indices 后一次性提交。
- weather distribute、feedback、Pass-B、sea ice 等稀疏更新。

特性：

- 对每个 index 做 value-diff：只有值变化才写入并标 dirty。
- 越界 index 静默跳过，避免批量场景刷屏。

建议：

- hot loop 中先收集 `PackedInt32Array indices` 和 values。
- 循环结束一次 `write_*_indexed`。

### Dense 写

`write_f32_dense(comp_id, values)` / `write_i32_dense` / `write_u8_dense`

用途：

- 整个 component 全量替换。
- C++ snapshot 或 GDScript pass 已经有完整输出 buffer。

特性：

- value-diff 后标 dirty，避免“全图值几乎没变但 atlas 全脏”。

风险：

- 如果每 tick 都 dense 写大量字段，即使 value-diff 已优化，仍会有遍历成本。

## Cell-index 间接寻址 LUT 是渲染产物，不进 schema

玩家信息遮罩同样遵守这条边界：`DataOverlayBaker.bake_cell_lut()` 从 flush 后的
`DCViewAdapter` / `MapData` 只读快照生成临时 RGBA8 `overlay_lut`，由
`DataOverlayLayer` 绑定到 GPU。请求、dirty、10 Hz 节流、选中资源和 UI 展开状态都不是
DataCore component，也不写存档。自然资源 mode 通过 profile 的 `reserve_map_field` 读取
已有 reserve array，并与 Inspector 共用 `ResourceProfileRegistry.reference_reserve()`；
overlay 不参与生成、补充、衰减、开采或市场结算。

plan: *cell-index atlas indirection*（详见 computation-pipelines.md「Cell-index 间接寻址」节）。

- `map_index_atlas`（`WorldData.enum_atlas_tex`）/ `enum_lut_tex` / `dyn_lut_tex` / `eco_lut_tex` / `weather_lut_tex` 是
  **渲染层产物（`WorldData` 上的 `ImageTexture`）**，不是 DataCore slot：
  **schema / `component_bind_table.gen.h` 无需改动**。
- **LUT 编码权威路径是 C++（DCWorldExt）**，GDScript 仅做薄壳 + fallback（2026-06-16，用户
  决策"严格按 skill，哪怕只有 2400 个 cell 也在 CPP 做"）。map-index atlas 由 GDScript
  baker 在 `_encode_enum_atlas` 内编码：
  - `encode_cell_luts(opts) → Dictionary{enum_lut/dyn_lut/eco_lut/weather_lut: PackedByteArray,
    path, elapsed_ms, fallback, published_to_slot=false}`：C++ 读 8 个 SoA slot
    （`cell_temp/cell_moisture/cell_snow_cover/cell_vegetation_vitality/cell_sea_ice_frac/
    cell_terrain/cell_vegetation/cell_cover`，全部已在 schema），输出 enum/dyn/eco 三张 LUT 的
    `PackedByteArray`；GDScript 只负责 `Image.create_from_data` + `ImageTexture.update`。
  - `enum_lut` 是 **RGBA8**（缓冲 `slots_total * 4`）：R=biome / G=veg / B=cover /
    **A=迷雾知识度 `fog_k`**。A 通道来自 `opts.fog_k_arr` 这个**可选 `PackedByteArray` 入参**，
    而不是 slot——`VisionSolver` 的权威实现目前在 GDScript，走显式数组可以避开
    `refresh_slots_from_map()` 用陈旧镜像覆盖 native-only 气候值的风险（与 `snow_cover_arr`
    同一个理由）。未提供时 A 恒为 255（全知）。注意 `cell.visible` / `cell.explored`
    **本身是 schema 组件**（见下文 vision 小节），只有派生量 `fog_k` 走入参。
  - `weather_lut`（RGBA8，R=type/G=intensity/B=cloud/A=vapor）：另读 4 个 weather slot
    （`cell_weather_type/cell_weather_intensity/cell_weather_cloud/cell_weather_vapor`）逐格量化；
    shader 中原先以 precip 驱动的雨雪/降水门控改读 G=intensity。
    供 `weather_overlay.gdshader` 经 cell-index 间接寻址驱动云分布。weather slot 是**软依赖**——
    天气未初始化（slot size < n_cells）时该段保持全 0（云不显示），enum/dyn/eco 不受影响、不整张回退。
    运行期发布由 `weather_refresh` 在 commit/merged/direct 完成点内联执行；
    `dynamic_visual_atlas_upload` 刷新 enum/dyn/eco 时不再更新时间戳，避免 visual LUT stride/phase 与
    weather commit cadence 不一致时重置 `weather_lerp`。


  - LUT/map-index 不写 slot（`published_to_slot=false`）——它们是 GPU 纹理，不是 DataCore 数据，
    无 `flush`/`snapshot` 需求；C++ 直接把字节缓冲塞进返回 Dict，GDScript 端零额外 marshalling 拷贝
    （CoW 引用传递）。
  - eco `transition_age` 的 per-cell prev 状态由 C++ 端 `AtlasPipelineState::lut_prev_veg/
    lut_prev_vit/lut_transition_age` 持久维护（`invalidate_atlas_csr_cache` 同步失效），
    **不经 GDScript 来回传**——`map_baker` 不再持有该状态。
- 量化公式与 fan-out 编码器同源（C++ `pk_atlas_sig_dynamic` / `pk_atlas_sig_ecology`，
  GDScript fallback `_dynamic_cell_signature` / `_ecology_visual_signature`），保证 LUT 与旧
  per-pixel atlas **bit-equivalent**。
- fan-out 方向反转：旧 `n_cells → n_pix` 直写 atlas_buffer（每日数 MB）改为
  `n_cells → n_cells` LUT（~7KB）；cell index 静态合入 `map_index_atlas.g/b`，不进 DataCore、不参与每日 sync。
- flag 关时本路径零触达，CoW 公理 / `published_to_slot` / `flush` / `snapshot`
  语义均不受影响。

## 视野迷雾的数据落点（三层，各有不同持久化语义）

`VisionSolver`（GDScript 权威，见 `vision-fog-and-borders.md`）的输入输出跨了
三种存储，不要混为一谈：

- **静态预烘焙（`WorldData`，非 slot）**：`cell_view_height` / `cell_view_block`
  两个 `PackedByteArray`，在 `MapBaker.bake_world` 的 post_base 阶段由地形派生，
  地形不变就永不变。它们是解算器的只读输入，不进 schema、不进存档——重新生成
  同一个 seed 必然得到同一份。
- **运行时状态（`MapData` + schema）**：`cell.visible` / `cell.explored` 是
  `U8` component（`owner="vision"`），按 SOP 走 `component_schema.gd` →
  `component_bind_table.gen.h`。`explored` 单调累积并进 PKFG 存档，`visible`
  每次解算全量重写、不存档。
- **派生视觉量（`MapData.fog_k_arr`，非 slot）**：blur 后的知识度，唯一消费者是
  `enum_lut.a`。它刻意**不是** DataCore component——没有任何 C++ pass 读它，
  进 schema 只会让每日 refresh/flush 白白多搬 2400 字节。

## C++ 读取 GDScript 最新值

`DCWorldExt.refresh_slots_from_map()`

含义：

- 从当前 `MapData` / GDScript 侧镜像拉取数据到 C++ slot。
- 让 C++ pass 看到 GDScript 自上次同步后的写入。

`DCWorldExt.refresh_slots_from_map_keys(slot_names: PackedStringArray)` 是同一方向的白名单版本：

- 只拉取传入的 `cpp_name` slots（如 `cell_temp` / `cell_moisture`），用于边界 pass 只依赖少量 `MapData` 字段的场景。
- slot 名必须能通过 `component_id()` 解析，并且存在 `component_bind_table.gen.h` 的 `map_field` 绑定；未知 slot 会被跳过。
- 新 DLL 可优先走该 API，旧 DLL fallback 到 `refresh_slots_from_map()`。

使用规则：

- 一轮 native chain 开始前调用一次通常足够。
- 多个 stage 共享同一轮输入时，不要每个 stage 都重复调用。
- 如果前一个 GDScript fallback 写了 `MapData` / `DCWorld`，下一个 C++ pass 依赖这些字段，则必须 refresh。
- 如果前一个 C++ pass 已直接写 slot，并且下一个 C++ pass 读同一 slot，通常不需要 refresh。

常见优化：

- `MapGenerator` 内有“round 启动时 refresh 一次”的缓存语义，用来避免每个 stage helper 都做一次 `refresh_slots_from_map()`。
- 对 `natural_resource_daily`、`daily_wind` 这类只读少数输入 slot 的边界 job，优先用 `refresh_slots_from_map_keys()`，避免全量回拉所有绑定字段。
- 日志里 `sync=...` 或 `refresh=...` 变大时，先检查是否重复 refresh。
- Native daily bundle 现在包含 `native_daily_boundary_contract`，把
  `bootstrap_config_keys`、`tick_delta_keys`、`refresh_policy` 和 `flush_policy`
  拆开报告。它是减少 Dictionary marshal 与 refresh/flush 边界的验收入口：
  bootstrap/state snapshot 应逐步迁入 native runtime config；每 tick 只保留真正的
  tick-delta knobs；`refresh_slots_from_map` / `flush_slots_to_map` 应只出现在 tick
  边界或可见/debug 边界。
- `configure_native_world()` 现在把 profile/static knobs 作为 `runtime_config_report`
  常驻在 `DCWorldExt`，daily report 提升 `resident_config_keys`、`bundle_key_count`
  和 `tick_delta_key_count`。评估 marshal 收敛时先看这些 counters，而不是只看
  单个 pass 的 native compute time。
- **tick-delta knob `weather_transition_dt_days`（2026-06-28）**：与 climate `thermal_dt_days`、
  sea_ice `dt_days` 同类的"上次到本次 pass 真实游戏天数差"补偿 knob，缺省 1.0。来源
  `MapGenerator._consume_weather_dt_days()`（独立游标 `_last_weather_pass_day`、同-tick 缓存、
  clamp[0,30]、缺源回退 1.0），在 unified native daily 路径经 `WeatherSystem.set_weather_transition_dt_days()`
  注入 `_build_weather_field_knobs`（fast/fallback 两处）与 commit knobs；C++
  `run_weather_field_solve_pass` / `run_weather_field_commit_pass` 与 GDScript `field_solver.gd`
  用它把过渡 alpha 累加从"每次求解"改为"每游戏天数"。probe（commit_side_effects=false）传 1.0 不推进游标。
- **沿海海洋性调温 knob `maritime_factor` / `maritime_season_damp`（climate-zone-fix P2）**：
  `climate_pass_a_struct`（`_build_native_daily_climate_pass_a_struct`）与 async kick input
  （`climate_daily_system.gd::_build_async_kick_input`）现都携带一个**静态 per-cell** 数组
  `maritime_factor`（PackedFloat32Array，∈(0,1]，海岸≈1/内陆→0）和标量 `maritime_season_damp`
  （来自 `ClimateProfile.maritime_season_damp`，0=关闭）。数组由 `MapGenerator._ensure_maritime_factor()`
  按 `is_water_arr` 多源 BFS 距海 + 指数衰减（e 折距 `maritime_decay_cells`）算一次并缓存（按 `(n,decay)`
  失效）。C++ `run_climate_pass_a` / `run_climate_pass_a_thread` / `_async_pass_a_kernel_pure` 三路在
  `pk_season_offset_continental` 之后统一 `season_offset *= (1 - maritime_season_damp * maritime_factor[i])`
  （仅陆地），缩小沿海年较差→温带海洋性(Cfb)。sync 与 async 读同一缓存数组 + 同一 decay → A/B 逐位一致；
  damp=0 或数组缺省时三路均跳过缩放（与历史逐位一致）。该机制独立于 legacy 标量 `temp_land_continentality`
  （后者仍被 pass_a 忽略，`native_pass_a_legacy_season_offset_test` 不变）。
- **降水季节性 knob `field_thermal_conv_precip` / `field_stratiform_gain` / `field_omega_ascent_gain` /
  `field_cool_season_vapor_floor`（climate-zone-fix P3）**：原 C++-only/constexpr 项导出为 `ClimateProfile`
  `weather_field_*`，经 `weather_system.gd::_sync_profile_weather_knobs` 装进 `_field_*` 成员，再由
  `_build_field_knobs`（resident dynamic_fields + fallback 两处）注入 weather field knobs。C++
  `world_ext_weather.cpp` 与 GDScript `field_solver.gd` 同读这些 knob/成员（SAME_SOURCE）：
  thermal_conv_precip↓减暖季对流主导、stratiform_gain↑补冷季层状、omega_ascent_gain↓弱化静止 ITCZ、
  cool_season_vapor_floor 给冷季蒸发地板（`temp_evap=max(floor,smoothstep(0.10,0.78,T))`，0=原行为）。
  附带修正 `field_solver.gd` 的 `PRECIP_BASE_FRAC` 常量漂移（0.12→读 `_field_precip_base_frac`=0.08，与
  C++ knob 主路径同源）。缺 key 时 C++ 回退历史默认（0.30/1.0/0.40/0.0）→裸 cp_struct 测试逐位不变。

## C++ 写入 GDScript 可见数据

### Slot 写入

C++ pass 的理想输出方式：

1. 循环外解析 `sid = component_id("cell_xxx")`。
2. 获取 `Slot &s = _slots.write[sid]`。
3. 用 `ptrw()` 取得裸指针。
4. hot loop 写入 slot。
5. 结束后按需要 flush/publish。

slot 写入本身只保证 C++ 后续 pass 可见。

### Flush 到 MapData

`flush_slots_to_map()` 或内部 `_flush_slot_to_map(sid)`

含义：

- 把 C++ slot 写回绑定的 `MapData` 字段。
- GDScript 读 `map.xxx_arr` 才能看到 C++ 输出。

适用：

- pass 输出要被渲染、debug、GDScript fallback 或后续 GDScript stage 读取。
- SLP/PSI 等 C++ pass 返回 `published_to_slot=true` 并在 C++ 内 flush 对应 slot 时，GDScript caller 可以跳过重复拷贝。
- 生成期 `run_native_world_generate_base_pass` 是无 bind 的结果包 API：GDScript 传入 cfg/profile，C++ 直接返回 q/r/s、elevation、moisture/base_moisture、terrain/is_water、temp/temp_baseline/temp_30d/temp_365d、lat/temp_year、landform/vegetation/cover 等 PackedArrays。它不写 slot，返回 `published_to_slot=false`；调用方只做数组尺寸校验。
- 生成期 `run_native_world_generate_post_base_pass` 同样是无 bind 的结果包 API：GDScript 把 base 结果包原样传入，C++ 在 SoA 内完成 lake BFS、rain shadow、river flow、river ecology、vegetation feedback、shrubland/mangrove/glacier/swamp、volcano、delta/oasis/salt flat/badlands、reef/kelp/pelagic bloom，并返回最终 terrain/base terrain、landform/base landform、vegetation/base vegetation、cover、is_water、has_river、river_flow、river_downstream、hydro_parent、has_volcano 等 PackedArrays。它也不写 slot，返回 `published_to_slot=false`；调用方只装配 `MapData`/`HexCell`，失败时才在 C++ base 结果上跑 GDScript post-base fallback。
- 生成期 `run_native_world_generate_pass` / `run_native_generation_slice` 仍采用 bind 后 publish 路径：C++ 读取 bind 后的 `cell_lat_norm` / `cell_elevation` / `cell_terrain` 等 slot，发布 `cell_temp*`、`cell_temp_baseline_year`、`cell_thermal_energy`、`cell_ema_initialized`、`cell_is_water` 等初始仿真 slot，并 `_flush_slot_to_map` 回 `MapData`。GDScript wrapper 成功后必须重绑 `DCWorld.rebind_map_data(map, demo_flag)`，因为 C++ flush 可能 reseat `MapData.xxx_arr`，旧的 GDScript `DCWorld` slot 引用不会自动跟随。
- 生成期 `run_temp_baseline_year_bake`（cell_temp_baseline_year 权威烘焙）即采用此路径：以 `lat_norm` knob 入参，C++ 写 `cell_temp_baseline_year` slot 后 `_flush_slot_to_map` 回 `MapData.temp_baseline_year_arr`，返回 `published_to_slot=true`；ext 不可用时 GDScript `bake_lat_temp_year_lut` 兜底（详见 computation-pipelines.md "Temp baseline year bake"）。

### Snapshot

`snapshot_f32(comp_id)` / `snapshot_i32` / `snapshot_u8`

含义：

- 返回 C++ slot 当前值的 PackedArray 快照。

适用：

- GDScript 端需要手动拉取 C++ 输出。
- benchmark / debug / save / A-B 对比。

注意：

- snapshot 是数据传递，不是共享可变引用。
- snapshot 后如果 GDScript 修改这个 PackedArray，不会自动写回 C++ slot。

### `published_to_slot`

部分 C++ pass 返回 Dictionary，其中 `published_to_slot` 表示：

- C++ 已经把结果写入 slot。
- 对应输出已经 flush 或可被 DataCore slot 消费。
- GDScript caller 不应再做昂贵的 array unpack/copy，除非 fallback reason 说明未发布。

当前 SLP 和 PSI 链路已经使用该字段避免重复 copy。排查 ocean currents 时，应把 `published=true` 视为 C++ slot publish 生效的强信号。

### Native daily graph-level publish

`DCWorldExt::run_native_daily_slice()` 是 graph-level report，不替代每个 pass 的
`published_to_slot`。它额外返回：

- `published_slots`：native daily bundle/graph 层声明本 round 涉及并可追踪的 slot 家族。
- scheduler-level `published_to_slot`：`NativeDailySimJob` 根据 `published_slots` 提升的布尔诊断字段，表示 graph report 至少声明了一组 slot 发布证据。
- `visual_dirty_intents`：C++ graph 对 GDScript/Godot visual boundary 的上传意图，不代表 GPU upload 已完成。
- `authority_report` / `authority_blockers` / `retained_boundaries` / `graph_coverage_state`：`authority_blockers` 只说明哪些 simulation authority 或 production fallback 仍阻止 graph complete；`retained_boundaries` 说明仍计划留在 GDScript/Godot 的 visual/object/debug 上传边界。

诊断顺序：

1. 看 pass-level `published_to_slot`，确认具体 C++ pass 是否写 slot / flush。
2. 看 graph-level `published_slots`，确认 native daily round 是否把该 slot 家族纳入 report。
3. 看 MapData/renderer/CSV 是否需要 visible flush 或 Godot upload。

不要因为 graph-level `published_to_slot=true` 就删除某个 pass 的 visible publish、CSV/debug flush 或 GDScript repair path；删除前必须有对应 pass-level 证据和可见层验证。

### Atlas buffer 直写发布（CSR fan-out 家族）

视觉 / 调试 atlas 的 byte-fill pass（`encode_dynamic_cell_atlas` /
`encode_ecology_visual_atlas` / `encode_dyn_smooth_atlas` /
`encode_ice_state_atlas` / `encode_overlay_atlas`）走另一种发布形态：

- 不写 DataCore slot，而是 GDScript 把一块 `atlas_buffer: PackedByteArray`（长度
  `n_pix * stride`）连同 CSR pixel 列表（`cell_first_px` / `cell_px_count` /
  `flat_px_indices`，复用 `WorldData` 持久 SoA，按 `cell.index` 索引）传入。
- C++ 端 `ptrw()` 直写该 buffer（必要时先 `memset` 清零），再把它原样放回返回
  Dictionary 的 `atlas_buffer` 字段。CoW 公理下，GDScript caller **必须**用返回的
  buffer（`buf = res["atlas_buffer"]`）而不是假设入参被原地改写。
- 失败时返回 `fallback=true` + `reason`，caller 走 GDScript 等价 fan-out。
- `encode_overlay_atlas`（debug-overlay-perf v2）是其中唯一**不读 `_slots`、不要求
  `_bound`** 的成员：overlay 的 per-cell R/G/valid 全部由 GDScript 预采样按
  `cell.index` 喂入，因此地图刚生成 / climate slot 未绑定也能工作。GDScript 侧
  `_fanout_cell_bytes_soa` 是其 bit-equal 兜底。

### Recorder CSV byte buffer

`DCWorldExt.encode_tile_csv_rows(knobs)` 是 tile data recorder 专用的
buffer encoder，不是 slot pass：

- GDScript 仍是权威 orchestration 层：选择 `MapData` 当前 SoA PackedArrays、
  生成固定诊断列、检查 row limit、决定 fallback。
- C++ 不读 `_slots`，也不需要 `refresh_slots_from_map()`；它只接收
  `q_arr/r_arr/s_arr` 和 `arrays: Array[PackedFloat32Array|PackedInt32Array|PackedByteArray]`，
  按既有 CSV 列顺序把一个 tick 的所有 cell 行编码成 UTF-8 `PackedByteArray`。
- GDScript caller 用 `FileAccess.store_buffer()` 写返回 bytes。返回空
  `PackedByteArray` 表示参数非法或旧方法不可用，caller 必须回退到 GDScript
  `_format_record_line()`，不能丢 tick、丢 cell 或丢字段。
- 该路径不发布 DataCore slot，不使用 `published_to_slot`。诊断看
  `tile_encoder_path` / 日志 `encoder=gdext|gdscript`。

### Wind vector contract

风场有两个不同语义的表示，不能混用：

- `cell_wind_x` / `cell_wind_y`：DataCore slot 与 `MapData.wind_x_arr/y_arr` 中的单位方向向量。
- `cell_wind_speed`：真实风速强度。天气平流、降水 carryover、气团热输运、surface injection、PSI/upwelling 风应力都应读这个 slot 做强度权重。
- `WorldData.wind_field_buffer` 与 vector atlas BA：渲染用速度向量，写入 `dir * clamp(wind_speed / 1.7, 0, 1)`。shader 对 BA 求长度时得到归一化风速。

如果某个 C++ 或 GDScript 消费端用 `sqrt(wind_x^2 + wind_y^2)` 当风速，结果会因为单位方向模长接近 1 而退化成全图恒定强风。

### Wind air-mass publish contract

`run_wind_air_mass_pass` 与 GDScript fallback `_wind_air_mass_pass` 只写
`cell_air_mass_temp_anomaly` / `MapData.air_mass_temp_anomaly_arr`，并 flush 该
slot 供后续 surface pass 读取。它们不发布 `cell_temp`，也不应调用
`_flush_slot_to_map(cell_temp)`。

新 DLL 暴露 `supports_wind_air_slot_temp()` 后，GDScript wind-air knobs 会设置
`read_temp_from_slot=true` 并省略 `temp_before_arr`；C++ 直接读当前 `cell_temp`
slot 作为 air-mass 上风采样输入，非有限值仍用同一 `baseline_arr` 兜底。旧 DLL
没有能力探针时保持历史兼容路径：GDScript 构建完整 `temp_before_arr` 后传入
`run_wind_air_mass_pass`。这样 native daily 的 wind 节点不再为当前温度做一次
`MapData -> PackedArray knob -> C++` 的全图往返。

`run_wind_surface_pass` / `_wind_surface_pass` 是气团异常写入 `cell_temp` 的
唯一阶段。这个边界用于避免同一 climate round 内先由 air-mass 覆盖当前温度、
再由 surface pass 二次注入造成局部温度 ping-pong。

## C++ Pass 返回契约

简单 pass 可能返回 `elapsed_ms` 浮点数，复杂 pass 应返回 Dictionary。

推荐 Dictionary 字段：

| 字段 | 含义 |
| --- | --- |
| `elapsed_ms` / `native_ms` | C++ 内部耗时。 |
| `path` | 实际路径，例如 `gdext`、`gdext_raster`、`data_core`、`gdscript_sliced`。 |
| `published_to_slot` | 输出是否已经发布到 slot/MapData。 |
| `fallback_reason` | fallback 原因；成功时为空或不写。 |
| `compute_ms` | C++ tight-loop 纯计算成本。 |
| `apply_ms` | 写 output slot / apply diff 成本。 |
| `flush_ms` | slot flush 到 MapData 成本。 |
| `refresh_ms` | `refresh_slots_from_map()` 成本。 |
| `sync_ms` | caller 侧同步/等待/拉取成本。 |
| `dirty_count` | 输出实际变更数量。 |

返回字段要服务调试，不要只返回一个大 `elapsed_ms`。最近的性能误判通常来自总耗时无法区分 compute、flush、sync 和旧窗口 spike。

## 标准 Native Pass 模板

GDScript caller：

```gdscript
func run_my_pass_native(map: MapData) -> Dictionary:
    if _data_core_world_ext == null:
        return {"path": "gdscript", "fallback_reason": "no_ext"}
    if not _data_core_world_ext.has_method("run_my_pass"):
        return {"path": "gdscript", "fallback_reason": "missing_method"}

    _data_core_world_ext.refresh_slots_from_map()

    var knobs := {
        "season_phase": _phase,
        "some_scale": scale,
    }
    var ret = _data_core_world_ext.run_my_pass(knobs)
    if ret is Dictionary and bool(ret.get("published_to_slot", false)):
        return ret

    return _run_my_pass_gdscript_fallback(map)
```

C++ pass：

```cpp
Dictionary DCWorldExt::run_my_pass(Dictionary knobs) {
    Dictionary out;
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_out = component_id(StringName("cell_my_output"));
    if (sid_temp < 0 || sid_out < 0) {
        out["path"] = "gdscript";
        out["fallback_reason"] = "missing_slot";
        out["published_to_slot"] = false;
        return out;
    }

    const Slot &temp_s = _slots[sid_temp];
    Slot &out_s = _slots.write[sid_out];
    const float *temp = temp_s.arr_f32.ptr();
    float *dst = out_s.arr_f32.ptrw();

    // Tight loop only: no Variant, no Object get/set, no StringName lookup.
    for (int i = 0; i < _entity_count; ++i) {
        dst[i] = temp[i];
    }

    _flush_slot_to_map(sid_out);
    out["path"] = "gdext";
    out["published_to_slot"] = true;
    return out;
}
```

## 反模式

| 反模式 | 后果 | 替代 |
| --- | --- | --- |
| GDScript hot loop 内逐 cell 调 `write_f32` | 跨界/dirty storm，atlas 全脏 | 收集后 `write_f32_indexed` 或 dense。 |
| C++ hot loop 内读 Dictionary / Object property | Variant 和 Object call 吃掉 C++ 收益 | 循环外解析 knobs 和 slot。 |
| 假设 `bind_map_data()` 后永远共享 buffer | CoW 后读旧值 | 显式 `refresh` / `flush` / `snapshot`。 |
| C++ pass 写 slot 后 caller 继续全量 unpack | 重复拷贝，日志显示 sync/apply 偏高 | 使用 `published_to_slot` 跳过。 |
| 每个 stage 都 `refresh_slots_from_map()` | sync 成本累积 | round 开始一次 refresh，stage 间沿用 C++ slot。 |
| fallback 没有 `fallback_reason` | 日志只看到 `path=gdscript`，无法定位 | 返回具体原因：missing_method、missing_slot、bad_size、stale_dll。 |

现代经济资源扩展后，DataCore 明确持有 30 组 `cell.res_<id>_reserve` 与
`cell.res_<id>_extra_change` F32 slots；`component_schema.gd` 是唯一 bind-table 输入，生成结果为
142 个 component entries（另含 `cell.resource_habitat_mask`，以及 `owner="vision"`
的 `cell.visible` / `cell.explored`）。goods、building、profession 和 technology tags 仍只存在于 economy
catalog/native runtime，不进入 MapData。`DCWorldExt` 在 sample boundary 批量解析资源 slot，生产
结束后按资源列批量写回 extra-change，边界内没有逐 cell Object 调用。

## 排查 checklist

1. `world bound=true` 吗？
2. `component_count` / slot size 与 `MapData.cell_count()` 一致吗？
3. C++ method 是否已 `ClassDB::bind_method` 注册？
4. GDScript caller 是否通过 `has_method()` 进入了 native 分支？
5. native pass 返回的是 Dictionary 还是旧 float stub？
6. `fallback_reason` 是什么？
7. C++ pass 输出是否写 slot？
8. 输出是否 `_flush_slot_to_map()` 或 `snapshot_*`？
9. caller 是否识别 `published_to_slot=true` 并跳过重复 copy？
10. 后续 GDScript/C++ stage 是否需要 `refresh_slots_from_map()`？

## Climate stability bridge notes

The current climate/weather/ocean stability fixes intentionally reuse existing
bridge surfaces and component slots.

- `cell_temperature_transport_anomaly` remains the bridge slot for ocean heat
  transport anomaly state. `MapData.temperature_transport_anomaly_arr` is the
  GDScript mirror consumed by fallback code and diagnostics. Do not add a
  parallel TTA array unless the schema/codegen workflow explicitly requires it.
- `HexCell.temperature_transport_anomaly` is a facade-backed compatibility
  property, but its getter intentionally reads GDScript `DCWorld` instead of
  `DCWorldExt`. The climate finalizer writes this value through
  `DCWorld.write_f32_dense()` / `MapData` and only marks the C++ mirror stale for
  the next round, so an ext read can observe a previous native snapshot.
- `native_daily_sim` ACTIVE uses the same finalizer boundary after the last
  native graph node: `MapGenerator` clamps final `cell_temp` and
  `cell_temperature_transport_anomaly` against round-start snapshots, writes the
  results to `MapData` and GDScript `DCWorld`, and lets the next native round's
  `refresh_slots_from_map()` pull that finalized state back into `DCWorldExt`.
  Do not bypass this with direct C++ slot reads in GDScript-visible diagnostics.
- Ocean water and land native passes receive the previous TTA state through the
  existing anomaly array knobs and publish the stabilized value back through the
  same slot/mirror boundary. Callers must keep honoring `published_to_slot` and
  dense writes so later climate stages do not read stale state.
- `cell_ocean_current_x/y` are still independent float slots, but the physical
  expectation is a final vector-magnitude limit. Diagnostics should compute
  `sqrt(x*x + y*y)` when validating saturation, not inspect per-component max
  values alone.
- PSI clamp diagnostics are pass reports, not schema slots. `DCWorldExt`
  returns `ocean_current_preclamp_p95`, `ocean_current_preclamp_max`,
  `ocean_current_clamp_count`, `ocean_current_clamp_ratio`, and
  `ocean_current_max_magnitude`; `MapBaker` caches them for
  `OceanCurrentsJob`, and the tile recorder exports the same values with a
  `phys_` prefix.
- Weather CSV diagnostics are not slot schema. They are sampled reports from
  `sample["weather"]`. `weather_dirty_count`, `weather_convergence_dirty_count`,
  and `weather_convergence_delta_p95` must be interpreted as weather commit
  report fields, not as climate pass fields.
## Building graph bridge

建筑目录、owner-lot、岗位和生产账本不进入 component schema。`world_ext_economy.cpp` 在周期
sample day 从已有 static/climate slots 捕获地理条件，并只为建筑目录实际引用的自然资源复制
reserve 与 pending extra 快照。建筑限产使用 `reserve + min(pending, 0)`：负 pending 防止资源
pass 步长较大时重复超采，正 pending 必须等资源 pass 才可采。周期发布后，native
resource-major 定点培育/采收净 delta 被一次性写入对应
`cell_res_*_extra_change` C++ slot 并 `_flush_slot_to_map()`。

PKEC v8 的稀疏 `LaborMarketStore`、role 合同工资、生活成本、基础工资与奖金同样完全留在
`NativeEconomyRuntime`，不新增 component slot，也不逐 cohort 跨语言调用。GDScript 仅通过
选中地块 `get_building_cell_snapshot` 读取有界 role/labor-market 并行数组。
建筑组查询额外发布 `owner_capacity/owner_required/owner_openings`：capacity 是完整物理 owner 槽位；
ACTIVE 组的 required 等于 capacity；RECOVERY 组按 recovery probe capacity 与 planned utilization
缩放；亏损停产或不可用组为 0，openings 等于 `max(required - filled_owner, 0)`。
`planned_owner_equivalent` 仅是 utilization-scaled 生产诊断，不参与 ACTIVE 招聘目标；planned
utilization 继续缩放 production 与 employee required。Inspector 不得用 planned equivalent 或建筑
数量冒充业主岗位。`projected_owner_income_per_day` 用 `max(required, filled_owner)` 作为人数分母，
并包含已消费自留物资的冻结零售价生活价值；该字段是迁移排序诊断，不代表现金收入。

该 delta 是“下一次自然资源 pass 的外部变化”，因此 `economy_daily` 声明读取 reserve，但不把
extra_change 声明为同 tick write：natural-resource job 同时读取 extra/write reserve，若建立当日
双向 DAG 会形成环。报告中的 `building_resource_generated/consumed/net_delta`、
`building_resource_limited_groups`、`building_resource_delta_cells` 与 `published_to_slot` 用于确认发布。
选中地块建筑快照可附带当前 reserve、pending 与 effective 定点列；该冷查询不复制全图。

Price V3 的企业需求 EMA、实际供给 EMA 与成本锚同样只存在 native 稀疏
`MarketSignalStore`，不注册 DataCore component。市场/建筑 selected-cell snapshot 可冷路径返回
这些列及压力分解、计划利润与利用率；GDScript 仅格式化显示，不重算价格或利润。
# Country bridge contract

国家系统只新增一个 DataCore 可见镜像：`cell.country_slot`（I32，`-1` 为无主）。
`CountryDailySystem` 在 ACTIVE commit 后把 native `cell_country_slot` 发布到该 slot/MapData；
国家 stable ID、显示名、领土 CSR、科技 bitset、现金和商品矩阵都不进入 component schema。

`CountryFacade` 使用粗粒度 `configure_country` / `bootstrap_country` /
`submit_country_commands` / `run_country_slice` 与 snapshot/save API。经济热路径不通过该 Facade，
而由 `NativeEconomyRuntime` 直接持有窄类型 `NativeCountryRuntime*`，在 sample day 复制纯数值冻结
快照。这样避免 Dictionary/Object/string lookup 和 GDScript 往返，也避免为全国一致科技制造逐格副本。
## Economy recorder CSV v11

CSV v11 keeps C++ as the only economy authority and adds derived diagnostics at
the committed boundary. Building rows include owner living cost, livelihood requirement, viability
operating cost, and income gap. Resource rows now publish opening reserve,
natural net change, previously pending artificial change applied, current
artificial change pending, and closing reserve. The recorder history is debug
state only: it is excluded from simulation state hash and PKEC save data. Summary rows append
construction goods consumed plus endogenous investment candidates, owner mobility, starts, and
fund/material blocking counters. Investment V5 additionally publishes
`building_investment_probability_skips`; this is committed-boundary diagnostic
history, not mutable GDScript state or PKEC state. This appended summary column
bumps the recorder schema to CSV v13; PKEC remains v15.
CSV v14 subsequently appends the three ACTIVE owner-job counters and projected
owner daily income; PKEC remains v15.

Resource rows retain signed `natural_net_change` and signed artificial deltas,
and add positive-valued natural increase/decrease plus artificial
generation/extraction columns for direct stock-flow checks. Natural positive and
negative columns decompose the observed net change; they are not a claim that
simultaneous gross ecological birth and death were separately observed.
Summary rows distinguish current unresolved trade deadline misses from
cumulative unique shortage episodes. Market rows add last trade attempt day,
last rejection reason, and current deadline-exceeded state. All v11 additions
are recorder/snapshot diagnostics only; no DataCore slot, PKEC field, or mutable
GDScript economy state is added.
## Economy v15 bridge additions

GDScript compiles resource profile coefficients and v15 behavior knobs into
packed catalog/profile columns at configure time. The native hot loop reads only
those fixed columns and frozen environment/resource arrays; it never reads a
Godot `Resource`, `Dictionary`, or stable-id string during settlement.

Selected-cell building snapshots expose desired/funded capacity, allocated
working capital, investment score, payback, and rejection reason. Market
snapshots expose desired/funded/unfunded business demand, export safety stock,
import fill target, relief pressure, signal age, and first-dispatch delay. These
are read-only diagnostic views over native state and do not create a GDScript
economy authority.

Rolling query snapshots also expose `state_day`, `age_days`, and
`snapshot_source=rolling_committed`. Global reports expose the settlement
watermark, newest committed state day, maximum state age, due/processed/deferred
cell counts, and the stable settlement phase. C++ remains the only mutable
authority; GDScript does not merge rolling cell state into a synthetic same-day
world snapshot.

## Moisture round-commit bridge (2026-07-24)

Inside `run_native_daily_slice()`, Pass-A, Pass-B, transpiration, and weather
distribute receive `defer_visible_publish=true`; their intermediate
`cell_moisture` buffers stay in `DCWorldExt`. Native weather field solve also
omits the optional GDScript `moisture_read_arr` snapshot so it reads the current
C++ slot instead of stale `MapData.moisture_arr`.

When the wrapper finalizer completes, it snapshots only the authoritative
`cell_moisture` slot and assigns that buffer to the exact `MapData` instance
passed into the scheduler round. This avoids relying on the bridge's retained
bound-map object identity while keeping the full-schema bulk flush disabled. The
old narrow bound-map flush remains only as a stale-extension fallback.
`MapData`, CSV, debug, and render consumers therefore observe a completed
round, not pass-level intermediates. Other slot publish contracts and
standalone/legacy pass flushes are unchanged.

The sliced round also owns a moisture commit transaction. Its initial bulk
refresh imports the last committed `MapData` value. After that point,
`refresh_slots_from_map()` and `refresh_slots_from_map_keys()` skip
`cell_moisture` until the wrapper finalizer has assigned the completed snapshot and calls
`complete_native_daily_moisture_commit()`. This prevents unrelated systems'
between-slice bulk refreshes from restoring the frozen visible value over the
in-flight native slot. Native failure paths release the protection without
publishing a partial value.

## Settlement query bridge

Prosperity and names have no DataCore slot or MapData mirror.
`get_population_cell_summary/snapshot` exposes selected-cell fields. Map
rendering binds through `get_named_settlement_snapshot()` and then consumes
`get_settlement_delta(revision)` packed arrays. Native retention is bounded to
eight revisions and `2 * cell_count` entries; an expired cursor returns
`full_snapshot=true`.

Trigger catalogs cross the bridge once as packed columns. GDScript owns resource
configuration and domain adapters; C++ owns dense trigger state and PKTR bytes.

## Visual tile byte bridge

Visual Tile bake is a generation-time buffer bridge, not a DataCore slot bridge.
`MapBaker` builds the cell SoA/base knobs once and reuses the same PackedArrays for each
`run_bake_visual_tile_layer_pass` call; C++ performs every O(n_pixels) loop and returns one
layer's byte bundle/hash/timing. GDScript may create `Image` and call
`Texture2DArray.update_layer()`, but must not decode or recompute pixels.
The result also reports `normal_radius_x_px`, `normal_radius_y_px` and the baseline
reference steps used to keep derived terrain normals invariant across visual resolutions.

`generation_id` and `layer_id` are part of every layer result. A stale result is discarded,
and `WorldData.visual_tiles` becomes renderer-visible only after every static layer succeeds.
Horizon compute bypasses the language bridge except for final readback/upload; its native
fallback `run_resample_visual_horizon_layer_pass` follows the same one-layer byte contract.
No Tile array is attached to component schema or save data. Full contract:
[Visual Tile Rendering](./visual-tile-rendering.md).
