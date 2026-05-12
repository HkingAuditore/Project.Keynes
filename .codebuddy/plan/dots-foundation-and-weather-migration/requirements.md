# 需求文档 — DOTS 风格数据架构基石 + 天气系统迁移

## 引言

本项目目前的 hex-grid 模拟（climate / weather / ocean / sea_ice / vegetation 等）已经在 `MapData` 内手工搭建了一层 SoA（Structure of Arrays）：25 个 `Packed*Array` 字段、邻居索引、双缓冲、dirty mask、LUT。这套形态在功能上接近 Unity DOTS 的 "ComponentData + Chunk + ECB"，但**散落在 `MapData` 内**、命名以业务字段为主（`temp_arr`、`weather_intensity_arr` …）、各 system 直接读写裸 PackedArray，导致：

1. 新增字段必须改 `MapData` 主类，违反开闭原则；
2. 没有统一的 component 注册 / 查询 / 生命周期管理，跨 system 数据所有权不清；
3. 切片调度 / 双缓冲 / dirty mask 是逐字段手工写的，难以横向复用到未来的经济、生物群、单位、AI 等海量数据系统；
4. weather_system.gd（约 105KB / 单文件）内部仍是 AoS（`weather_front` 实例数组）+ 临时 SoA 混用，迁移示范价值最高。

**本计划目标**：先打造一套通用的、轻量的、面向 GDScript 的"类 DOTS 数据架构基石"（以下简称 **DataCore**），再以 weather_system 作为首个迁移样本，验证基石的可用性、性能与可扩展性。基石必须满足：

- **零 GDExtension 依赖**：纯 GDScript + Packed*Array，移动平台同时可用；后续如果要换 GDExtension/C++ 后端，只需要替换 `World`/`Chunk` 的实现，不动 system 代码；
- **海量数据驱动**：未来 cell 规模可扩到 10K+，archetype/chunk 仍可分组连续存储；
- **与现有 SoA 平滑兼容**：`MapData` 现有的 25 个 Packed 数组**不被丢弃**，而是被 DataCore 包装成"标准 component"，迁移期间 legacy 路径 + DataCore 路径并存，开关切换；
- **可被 SusScheduler 直接驱动**：SusJob 通过 `Query` 拿到 component view，hot loop 仍走 `PackedFloat32Array` 内联访问，**无新增反射/字典查找开销**；
- **天气作为首个迁移用例**：完成 weather_system 在 DataCore 上的运行，weather_refresh 单 round ≤ 当前实现（无回归），并展示出 component 复用、archetype 分组、稀疏遍历的能力。

---

## 名词约定

| 术语 | 含义 | 类比 Unity DOTS |
|---|---|---|
| **Entity** | 一个唯一 int32 ID（首版直接 = `cell_index`） | Entity |
| **Component** | 一组同类型 PackedArray 字段（如 `Temperature{value: f32}`） | IComponentData |
| **Archetype** | 一组 entity 共享同一组 component 集合的逻辑分组（首版可选，仅在 weather 迁移时启用） | Archetype |
| **Chunk** | archetype 内连续存储的一段 entity 数据（首版 chunk_size = 全图，未来可切 256） | Chunk |
| **World** | 全局根容器，注册 component / archetype，管理生命周期 | World |
| **Query** | 描述"我要哪些 component 的只读/读写视图" + 遍历范围（全部 / dirty / archetype / 自定义 mask） | EntityQuery |
| **System** | 一个执行单元，从 World 拿 Query，按 tick/round 推进数据；首版直接套到 SusJob 上 | SystemBase / ISystem |
| **CommandBuffer** | 延迟到 round 末执行的结构性变更（add/remove component、destroy entity）队列 | EntityCommandBuffer |

---

## 需求

### 需求 1 — DataCore：World 与 Component 注册中枢

**用户故事**：作为引擎层开发者，我希望有一个统一的 `World` 单例容器，可以在启动时注册任意数量的 component 类型，运行期通过类型 ID 拿到对应的 PackedArray 视图，以便所有未来子系统（weather/economy/units/AI）共享同一套数据架构。

#### 验收标准
1. WHEN 启动时 THEN 系统 SHALL 提供 `DataCore.World` 单例，承载 entity 数组、component 注册表、archetype 列表
2. WHEN 调用 `world.register_component(name: StringName, dtype: int, stride: int = 1)` THEN 系统 SHALL 创建一个 component 槽位，分配 PackedArray 容器（按 dtype 选 `PackedFloat32Array`/`PackedInt32Array`/`PackedByteArray`），并返回一个 `ComponentId`（int）
3. WHEN 调用 `world.get_component_array(comp_id) -> Packed*Array` THEN 系统 SHALL 直接返回底层数组引用（hot loop 用），调用时间 SHALL 小于 1μs
4. IF dtype 不在 {`F32`, `I32`, `U8`, `VEC2_F32`(stride=2), `VEC3_F32`(stride=3)} 范围 THEN 系统 SHALL push_error 并拒绝注册
5. WHEN 调用 `world.create_entities(count: int)` THEN 系统 SHALL 一次性 resize 所有已注册 component 的 PackedArray 到 `count`，禁止单个 push_back（避免 GC 抖动）
6. WHEN 调用 `world.entity_count() -> int` THEN 系统 SHALL 返回当前 entity 总数
7. WHEN 移动平台启动 THEN 系统 SHALL 仅使用 PackedArray，不引入 GDExtension/Native module 依赖

---

### 需求 2 — DataCore：Component 视图与读写访问器

**用户故事**：作为 system 编写者，我希望通过类型安全的 `ComponentView` 在 hot loop 中读写 component 字段，单次访问开销与裸 `PackedFloat32Array` 索引一致，以便不损失性能。

#### 验收标准
1. WHEN system 调用 `world.view_f32(comp_id) -> PackedFloat32Array` THEN 系统 SHALL 直接返回底层数组引用（无拷贝）
2. WHEN system 在内层循环中通过该引用进行 `arr[i]` 读写 THEN 单次访问 SHALL 与现有 `temp_arr[i]` 模式等价（基线测试要求 0 % 性能回归）
3. IF 调用方对返回的 PackedArray 调用 `resize` / `push_back` 等结构性变更 THEN 系统 SHALL 在 debug 构建下 push_warning（约定：结构性变更只能通过 `world.create_entities` / CommandBuffer）
4. WHEN system 需要双缓冲读 THEN 系统 SHALL 提供 `world.view_f32_prev(comp_id) -> PackedFloat32Array`，返回上一轮快照
5. WHEN system 需要 stride>1（如 vec2 ocean_current）的访问 THEN 系统 SHALL 提供 `world.view_vec2(comp_id) -> { x: PackedFloat32Array, y: PackedFloat32Array }` 拆分形式，避免内层循环 stride 跳格
6. WHEN component 注册时设置了 `track_prev=false` THEN 系统 SHALL 不分配 `_prev` 镜像，节省内存（默认 false，按需开启）

---

### 需求 3 — DataCore：Query 与遍历范围

**用户故事**：作为 system 编写者，我希望用声明式 `Query` 描述"我要遍历哪些 entity"，包括全图 / dirty / archetype / 自定义 mask，以便 hot loop 自动选择最优遍历路径。

#### 验收标准
1. WHEN 调用 `world.query().with(comp_a).with(comp_b).readonly(comp_c).build() -> Query` THEN 系统 SHALL 创建一个 query 描述对象，记录读集合 / 写集合
2. WHEN 调用 `query.for_each_index(callback)` 但 query 上未设过滤器 THEN 系统 SHALL 顺序遍历全部 entity index（行为与现有 `for i in range(n)` 等价）
3. WHEN query 上调用 `.with_dirty_mask(mask: PackedByteArray)` THEN 遍历 SHALL 仅访问 mask[i]==1 的 index
4. WHEN query 上调用 `.with_archetype(arch_id)` THEN 遍历 SHALL 仅访问该 archetype 内的 index 段（连续）
5. WHEN query 上调用 `.with_index_list(idx_list: PackedInt32Array)` THEN 遍历 SHALL 按列表顺序访问，用于 weather front 周边稀疏域
6. WHEN system 嵌套使用 query（外层全图 + 内层邻居）THEN 系统 SHALL 不引入对象分配（query 本身是轻量结构体或预分配池）
7. IF query 传给的 callback 返回 `false` THEN 遍历 SHALL 立即中断（用于 SusJob 的预算耗尽提前退出）

---

### 需求 4 — DataCore：邻居拓扑组件

**用户故事**：作为 hex-grid 的 system 编写者，我希望邻居索引（`_neighbor_indices`）被统一封装成一个 component-like 的 topology，以便未来非 hex 拓扑（grid / quad / graph）可替换实现。

#### 验收标准
1. WHEN World 启动且接入 MapData 后 THEN 系统 SHALL 注册一个内置 topology component（`HexNeighborTopology`），承载 `PackedInt32Array` (size=N*6)
2. WHEN system 调用 `world.topology().neighbor_index(idx, dir) -> int` THEN 行为 SHALL 与现有 `MapData.neighbor_index(idx, dir)` 等价
3. WHEN system 需要原始 packed 数据用于内层循环 THEN 系统 SHALL 提供 `world.topology().neighbors_packed() -> PackedInt32Array`
4. IF 拓扑未构建 THEN 系统 SHALL push_error 并要求 system 先调用 `world.bind_map_data(map_data)`
5. WHEN MapData 已存在的 `_neighbor_indices` 已构建 THEN World 在 `bind_map_data` 时 SHALL 直接复用同一份 PackedInt32Array 引用（不复制）

---

### 需求 5 — DataCore：双缓冲与 swap

**用户故事**：作为 system 编写者，我希望 component 的双缓冲 swap 由 World 统一管理，sub-pass 跨 tick 切片时下游读 `_prev`、当前 sub-pass 写 `_next`，避免每个 system 自己手写 `duplicate()`。

#### 验收标准
1. WHEN component 注册时 `track_prev=true` THEN 系统 SHALL 同时分配 `_arr` 与 `_arr_prev`
2. WHEN 调用 `world.swap_double_buffer(comp_ids: Array)` THEN 系统 SHALL 在常数时间内交换 `_arr` 与 `_arr_prev` 的内部引用（不做内存拷贝）
3. WHEN sub-pass 跨 tick 切片中途 THEN 系统 SHALL 保证下游读 `_arr_prev` 拿到的是**整段 sub-pass 启动前**的快照，不被 in-flight 写污染
4. IF 调度器在 sub-pass 未完成时调用了 `swap_double_buffer` THEN 系统 SHALL push_error 并中止（防止下游读到半成品）
5. WHEN sub-pass round 末按"完成快照"语义 THEN 系统 SHALL 提供 `world.commit_round(comp_ids)` 一次性 swap 所有指定 component

---

### 需求 6 — DataCore：CommandBuffer（结构性变更延迟）

**用户故事**：作为 system 编写者，我希望在 hot loop 中提交"创建/销毁 entity、增/减 component"等结构性变更但不立即生效，由 World 在 round 末统一 flush，以便 hot loop 不被 resize 打断。

#### 验收标准
1. WHEN system 调用 `world.command_buffer() -> CommandBuffer` THEN 系统 SHALL 返回一个轻量 buffer 对象（首版可全局单例 + reset）
2. WHEN system 调用 `cb.create_entity()` / `cb.destroy_entity(idx)` / `cb.add_component(idx, comp_id)` / `cb.remove_component(idx, comp_id)` THEN buffer SHALL 仅记录指令，不立即生效
3. WHEN World 调用 `world.flush_command_buffer()` THEN 系统 SHALL 按记录顺序应用所有指令，执行完后清空 buffer
4. IF 同一 round 内出现冲突指令（destroy 后 add component）THEN 系统 SHALL 按记录顺序处理（destroy 前的 add 仍生效，destroy 之后该 entity 失效）
5. WHEN flush 期间任意指令 resize 了 PackedArray THEN 系统 SHALL 同步 resize 所有已注册 component（保持长度对齐）
6. WHEN weather 迁移阶段尚未需要动态创建/销毁 entity THEN CommandBuffer 的实现可以是占位（只暴露 API、内部最小实现），不阻塞首期落地

---

### 需求 7 — DataCore：Archetype/Chunk 分组（首版可选）

**用户故事**：作为性能优化工程师，我希望未来能把 entity 按 archetype（如"陆地 cell"/"海洋 cell"/"沿岸 cell"）分组连续存储，hot loop 内消除分支，并能与外部 archetype 系统（如阵营、单位类别）共享相同机制。

#### 验收标准
1. WHEN 调用 `world.create_archetype(name, comp_ids) -> ArchetypeId` THEN 系统 SHALL 注册一个 archetype 描述
2. WHEN 调用 `world.assign_archetype(idx, arch_id)` THEN 系统 SHALL 把 entity 标记为该 archetype（首版仅维护 `entity_archetype: PackedInt32Array`，不做物理重排）
3. WHEN query 上调用 `.with_archetype(arch_id)` THEN 遍历 SHALL 跳过非该 archetype 的 entity
4. WHEN 物理重排开关 `world.enable_archetype_sorting=true` 启用（**非首版必交付**，仅暴露 API） THEN 系统 SHALL 把同 archetype 的 entity 在 Packed 数组中重排为连续段，并维护 `entity_remap: PackedInt32Array` 供 topology 反查
5. WHEN 首版（weather 迁移阶段）archetype_sorting 未启用 THEN 验收测试 SHALL 至少证明"逻辑分组 + with_archetype 遍历"能正常运行（功能正确，不要求性能加成）

---

### 需求 8 — Bridge：MapData ↔ DataCore 对接层

**用户故事**：作为迁移过渡期工程师，我希望 DataCore 不要求项目立即放弃 MapData 现有 SoA，而是把现有的 25 个 PackedArray "认领"为 component，让 legacy 路径与 DataCore 路径共享同一份数据，以便分阶段切换。

#### 验收标准
1. WHEN 调用 `world.bind_map_data(map_data: MapData)` THEN 系统 SHALL 把 MapData 中已存在的 25 个 PackedArray **按引用挂入** World 对应 component 槽位（不复制）
2. WHEN bind 完成 THEN `world.view_f32(COMP_TEMP)` 与 `map_data.temp_arr` SHALL 是同一份底层数据（任一方写入对另一方立即可见）
3. WHEN MapData 调用 `rebuild_soa_from_cells()` 重新分配数组 THEN 系统 SHALL 提供 `world.rebind_arrays()` 重新刷新引用（避免 dangling）
4. WHEN MapData 调用 `flush_soa_to_cells()` THEN 行为 SHALL 不受 DataCore 影响（DataCore 不接管 HexCell 同步）
5. WHEN bind 期间发现 MapData 上的数组长度不一致 THEN 系统 SHALL push_error 并中止 bind
6. WHEN bind 完成 THEN World 的 `entity_count` SHALL 等于 `map_data.cell_count()`

---

### 需求 9 — DataCore：调度器接入与 SusJob 适配

**用户故事**：作为 SUS 调度器维护者，我希望 SusJob 可以直接通过 World/Query 拿到数据，并保留现有的 frame_budget / slice / progress / breakdown 能力，以便不重写整套调度逻辑。

#### 验收标准
1. WHEN 一个 SusJob 子类声明 `var queries: Array[Query]` 字段 THEN 调度器 SHALL 把 World 注入 job 并允许其在 `_run_slice(ctx)` 中直接使用 query
2. WHEN job slice 遍历某个 query 但单 slice 时间预算耗尽 THEN job SHALL 通过 callback 返回 false 终止本 slice，保存 cursor，下一 tick 继续
3. WHEN job 跨 tick 切片期间 THEN World 双缓冲 SHALL 保证下游 job 读到的是 round 起点快照
4. WHEN 一个 round 完成 THEN job SHALL 调用 `world.commit_round(comp_ids)` 完成 swap，并允许 `flush_soa_to_cells` 把数据回流到 HexCell 供 UI 读
5. IF 任意 job 在 `_run_slice` 中执行了未记录到 query 写集合的写操作 THEN debug 构建 SHALL push_warning（轻量校验，不阻塞运行）

---

### 需求 10 — Weather 迁移：weather component 注册与状态拆解

**用户故事**：作为 weather_system 维护者，我希望把当前散落在 `WeatherFront` 实例数组 + MapData `weather_*_arr` 的状态拆成清晰的 component 集合，以便后续 spawn/advect/distribute 各 sub-pass 在 DataCore 上独立工作。

#### 验收标准
1. WHEN 启动时 THEN World SHALL 注册以下 weather 相关 component：`WeatherIntensity{value:f32}`、`WeatherCloud{value:f32}`、`WeatherPrecip{value:f32}`、`WeatherType{value:u8}`，全部 track_prev=true
2. WHEN 启动时 THEN World SHALL 注册一个 `WeatherFront` archetype，其 entity 是 front（不是 cell），承载 component：`FrontPos{x,y:f32}`、`FrontVel{x,y:f32}`、`FrontKind{value:u8}`、`FrontStrength{value:f32}`、`FrontRadius{value:f32}`、`FrontAge{value:i32}`
3. WHEN 现有 `weather_front.gd` 实例数组被废弃替换 THEN weather_system 内部 SHALL 改为通过 `world.query().with_archetype(WEATHER_FRONT_ARCH)` 遍历 front entity
4. WHEN 现有 `weather_intensity_arr` / `weather_cloud_arr` / `weather_precip_arr` / `weather_type_arr` 已存在于 MapData THEN bind 阶段 SHALL 直接挂入对应 component（不重新分配）
5. WHEN front 数量动态变化 THEN 系统 SHALL 通过 CommandBuffer 在 round 末统一 spawn/destroy front entity（不在 hot loop 中改 PackedArray 长度）

---

### 需求 11 — Weather 迁移：sub-pass 全部走 Query

**用户故事**：作为 weather_system 内部 sub-pass（advect / spawn / distribute / cyclone）维护者，我希望每个 sub-pass 都通过 Query 拿数据，不再直接读写 MapData PackedArray，以便沉淀通用模式给后续系统抄作业。

#### 验收标准
1. WHEN advect sub-pass 运行 THEN 系统 SHALL 通过 `query.with_archetype(WEATHER_FRONT_ARCH).readwrite(FrontPos, FrontVel, FrontAge).readonly(WindX, WindY)` 描述其数据访问，并仅遍历 front entity
2. WHEN spawn sub-pass 运行 THEN 系统 SHALL 通过 `query.with(IsWater, Temp).readonly(...)` 拿到候选 cell 集合，CommandBuffer 提交 front 创建
3. WHEN distribute sub-pass 运行 THEN 系统 SHALL 对每个 active front 通过 `query.with_index_list(front_neighbor_idx_list)` 仅遍历 front 周边 cell（继承现有"基于 fronts 的稀疏 advect"思想）
4. WHEN cyclone sub-pass 运行 THEN 系统 SHALL 用同一套 query 接口表达"单 tick 至多处理 1 个 front"约束，多 front 跨 tick 轮转
5. WHEN 任一 sub-pass 跨 tick 切片 THEN 系统 SHALL 通过 SusJob 的 cursor 机制 + World 双缓冲共同保证语义不变
6. WHEN weather_system 完成迁移 THEN 该模块的 weather_refresh round 平均耗时 SHALL 不超过迁移前同条件下的 110%（允许 10% 浮动；后续阶段 C 优化才进一步压缩）
7. WHEN weather_system 完成迁移 THEN 移除已不再被引用的 `WeatherFront` AoS 实例数组，weather_system.gd 文件大小 SHALL 显著降低（目标降幅 ≥ 30%）

---

### 需求 12 — Weather 迁移：行为零回归与对照测试

**用户故事**：作为 QA，我希望迁移前后 weather 输出在 30 game-day 内的统计指标（fronts 数、平均 cloud / precip 总量、降水分布峰值位置）保持一致，以便迁移不引入肉眼可见的天气行为漂移。

#### 验收标准
1. WHEN 关闭 DataCore 开关 (`use_data_core_weather=false`) 启动种子相同的存档 THEN 30 天后采集 fronts_count、cloud_sum、precip_sum、temp_field_hash 作为 baseline
2. WHEN 打开 DataCore 开关启动相同存档 THEN 同样采集 30 天指标
3. THEN baseline 与 DataCore 路径在 fronts_count 上 SHALL 差 ≤ 5%；cloud_sum / precip_sum SHALL 在 ±3% 以内；temp_field_hash 允许变化但 hash 距离 SHALL ≤ 给定阈值（具体阈值在实现阶段标定）
4. WHEN 任何指标超出阈值 THEN 验收 SHALL 失败，必须先修复语义再上线
5. WHEN 测试通过且开关默认翻 true THEN 文档 SHALL 记录灰度切换流程与回滚 SOP

---

### 需求 13 — 治理、可观测、回滚

**用户故事**：作为运维维护者，我希望 DataCore 与 weather 迁移每一步都有 ClimateProfile / 命令行开关、SUS 日志、metrics 暴露，以便随时灰度、随时回滚、随时定位回归。

#### 验收标准
1. WHEN ClimateProfile 增加 `use_data_core: bool=false` / `use_data_core_weather: bool=false` THEN 系统 SHALL 在 World 初始化与 weather_system 入口分别按开关分发到 legacy / DataCore 路径
2. WHEN 命令行启动添加 `--data-core` / `--no-data-core` 标志 THEN 系统 SHALL 覆盖 ClimateProfile 默认值
3. WHEN SUS 调度器 30 tick 汇总日志输出 THEN 系统 SHALL 增加 `world_entities`、`world_components` 两个字段，体现 DataCore 注册规模
4. WHEN weather sub-pass 走 DataCore 路径 THEN breakdown 输出 SHALL 在原有 `weather_tick=10.5 (adv=2.9 spawn=5.4 dist=2.3 cyc=0.0)` 之后追加 `path=data_core | legacy`
5. WHEN 任何一个 component 注册 / archetype 创建 / bind_map_data 失败 THEN 系统 SHALL 在初始化阶段（非 hot path）push_error 并阻止启动，避免运行期 crash
6. WHEN 用户回滚 ClimateProfile 开关到 false THEN 系统 SHALL 完整退回 legacy 路径，World 实例可保留为空（无副作用），weather_system 回到 AoS 实现

---

### 需求 14 — 移动平台与 GDExtension 升级路径预留

**用户故事**：作为未来可能引入 C++ GDExtension 的工程师，我希望 DataCore 的 API 形态从一开始就以"指针风格"暴露 PackedArray，以便未来把 World/Component 实现替换为 GDExtension 时上层 system 代码零修改。

#### 验收标准
1. WHEN DataCore 暴露的所有 hot-path 数据访问 API 都返回 `Packed*Array` 引用 THEN 未来 GDExtension 实现 SHALL 可以用同样签名（C++ 内部用 `float*` 直接 mmap）替换
2. WHEN 移动平台执行 THEN DataCore SHALL 不依赖 `OS.has_feature` 之外的平台特性（无 RenderingDevice / 无 ThreadPool 强依赖）
3. WHEN 启动后 THEN DataCore SHALL 在 `OS.has_feature("mobile")` 时不强制启用 archetype_sorting / 大块预分配，按 cell_count 自适应内存
4. WHEN 未来引入 WorkerThreadPool 并行 THEN Query 接口 SHALL 已经具备"分块 callback"形态（`query.for_each_chunk(start, end, callback)`），首版预留 API 即可，无需立即并行实现

---

## 不在本期范围

以下条目明确**不在本计划交付范围**，避免范围膨胀：

- ❌ 直接启用 GDExtension/C++ 后端（仅预留 API 形态，需求 14）
- ❌ Compute Shader / GPGPU 路径
- ❌ 把 climate / ocean / sea_ice / vegetation 也迁移到 DataCore（先只迁 weather，验证基石）
- ❌ archetype 物理重排（仅暴露 API，首版不实现）
- ❌ WorkerThreadPool 多线程 system（仅 Query 形态预留）

> 完成本计划后，下一阶段计划（独立 plan）将根据 weather 迁移的实际收益，决定是否：(a) 继续迁移 climate / ocean，(b) 引入 GDExtension 重写 hot loop，(c) 启用 archetype 物理重排。

---

## 边界场景与失败模式

| 场景 | 处理 |
|---|---|
| World 未 bind_map_data 就被 system 调用 | 启动期 push_error，阻止 main 流程进入 fast tick |
| MapData 在运行期 regenerate（cell_count 改变） | World 监听 `map_data` 重新挂入，调 `rebind_arrays` 全量重绑 |
| 同一 component 被两个 system 同时写入 | debug 构建 push_warning（写集合冲突），release 不阻断（首版不强校验） |
| CommandBuffer 在一帧内累积超过 N 条指令（N=1000） | flush 时分批，避免单帧 stall |
| 加载存档后首日 | World 在 `bind_map_data` 后由调用方负责 `rebuild_soa_from_cells`；World 自身不持久化，纯内存视图 |
| ClimateProfile 切换开关而 World 已初始化 | weather_system 入口通过 `bool use_data_core_weather` 即时分发，不要求重启 |

---

## 成功标准（与验收完全对齐）

| 维度 | 指标 |
|---|---|
| **基石可用性** | World/Query/CommandBuffer/View 5 大 API 全部就绪，单元测试覆盖 |
| **零性能回归** | weather_refresh round 平均耗时 ≤ 迁移前 110% |
| **零行为回归** | 30 day 统计指标在 ±5% 阈值内，详见需求 12 |
| **架构可扩展** | 新增一个 component 不改 MapData / 不改 World 主类，只需一行 `world.register_component` |
| **移动平台** | OS.has_feature("mobile") 路径下 World 全功能可用，无 GDExtension 依赖 |
| **可灰度回滚** | ClimateProfile 开关一次切换即可回到 legacy 路径，无副作用 |
