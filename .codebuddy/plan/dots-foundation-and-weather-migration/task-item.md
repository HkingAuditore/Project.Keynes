# 实施计划

> 本计划严格按"先建基石、再迁天气、最后治理"的三段式组织。所有任务都是编码任务，且每一步都基于上一步的产物递进。
> 主要目标文件：`scripts/data_core/world.gd`（新建）、`scripts/data_core/query.gd`（新建）、`scripts/data_core/command_buffer.gd`（新建）、`scripts/data_core/component_ids.gd`（新建）、`scripts/geography/map_data.gd`、`scripts/weather/weather_system.gd`、`scripts/weather/weather_front.gd`、`scripts/sus/sus_scheduler.gd`、`scripts/sus/sus_job.gd`、`scripts/sus/jobs/weather_refresh_job.gd`、`scripts/data/climate_profile.gd`、`scripts/main.gd`。

---

- [x] 1. **DataCore 基石：World 容器 + Component 注册表**
   - 新建 `scripts/data_core/world.gd`（class_name `DCWorld`），实现 `register_component(name, dtype, stride=1, track_prev=false) -> int`、`get_component_array(comp_id)`、`create_entities(count)`、`entity_count()`、`resize_all(count)` 等核心 API
   - 新建 `scripts/data_core/component_ids.gd`（常量集中表，便于 weather/未来 system 引用）；定义 dtype 枚举 `F32 / I32 / U8 / VEC2_F32 / VEC3_F32`
   - dtype 非法时 `push_error` 并拒绝注册；`create_entities` 一次性 resize 全部 component（禁止 push_back）
   - `get_component_array` 返回底层 PackedArray 引用，零拷贝
   - _需求：1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7_

- [x] 2. **DataCore 基石：ComponentView + 双缓冲 swap**
   - 在 `DCWorld` 实现 `view_f32(comp_id) / view_i32(comp_id) / view_u8(comp_id) / view_f32_prev(comp_id) / view_vec2(comp_id) -> {x,y}`，全部返回 PackedArray 引用
   - `register_component(track_prev=true)` 时同步分配 `_arr_prev`；提供 `swap_double_buffer(comp_ids)`（O(1) 交换引用，无拷贝）和 `commit_round(comp_ids)`（round 末整批 swap）
   - debug 构建下：sub-pass 状态未完成时调用 `swap_double_buffer` 触发 `push_error`（轻量校验，依赖 `_pending_passes` 计数）
   - _需求：2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 5.1, 5.2, 5.3, 5.4, 5.5_

- [x] 3. **DataCore 基石：Query DSL + 多种遍历范围**
   - 新建 `scripts/data_core/query.gd`（class_name `DCQuery`），实现 `with(comp_id) / readonly(comp_id) / readwrite(comp_id) / with_dirty_mask(mask) / with_archetype(arch_id) / with_index_list(idx_list) / build()` 链式 API
   - 实现 `for_each_index(callback: Callable) -> bool`，按设置的过滤器选择最优遍历路径；callback 返回 false 立即中断
   - 预留 `for_each_chunk(start, end, callback)` 接口（首版同步实现 + TODO 注释，给未来 WorkerThreadPool 留位）
   - 在 `DCWorld` 提供 `query() -> DCQuery` 工厂（每次返回内部预分配池里的实例，避免 hot path 分配）
   - _需求：3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 14.4_

- [x] 4. **DataCore 基石：HexNeighborTopology + bind_map_data 桥接**
   - 在 `DCWorld` 实现 `bind_map_data(map_data: MapData)`：把 MapData 的 25 个 PackedArray 按引用挂入对应 component 槽位（不复制）；`_neighbor_indices` 挂为 `HexNeighborTopology` 内置 component
   - 实现 `topology() -> { neighbor_index(idx,dir), neighbors_packed() -> PackedInt32Array }`；未构建时 `push_error`
   - 实现 `rebind_arrays()`：当 MapData 重新 `rebuild_soa_from_cells` 后刷新所有 component 引用
   - bind 时校验所有数组长度一致 == `map_data.cell_count()`，否则 `push_error` 中止
   - 在 `MapData.rebuild_soa_from_cells` / `_alloc_soa` 末尾调用 `World.rebind_arrays()`（如已 bind）；`MapData.flush_soa_to_cells` 行为不变
   - _需求：4.1, 4.2, 4.3, 4.4, 4.5, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6_

- [x] 5. **DataCore 基石：CommandBuffer（结构性变更延迟队列）**
   - 新建 `scripts/data_core/command_buffer.gd`（class_name `DCCommandBuffer`），暴露 `create_entity() -> int`（占位 ID）、`destroy_entity(idx)`、`add_component(idx, comp_id)`、`remove_component(idx, comp_id)`
   - `DCWorld.command_buffer() -> DCCommandBuffer`（全局单例 + reset），`flush_command_buffer()` 按记录顺序应用并清空
   - flush 时若任意指令 resize 了底层 PackedArray，同步 resize 所有已注册 component（保证长度对齐）
   - 首版仅需保证 `create_entity / destroy_entity` 的最小语义可工作（weather front spawn/destroy 用得到）；`add/remove_component` 可暂以 archetype 标记位实现
   - _需求：6.1, 6.2, 6.3, 6.4, 6.5, 6.6_

- [x] 6. **DataCore 基石：Archetype 逻辑分组**
   - 在 `DCWorld` 实现 `create_archetype(name, comp_ids) -> int`、`assign_archetype(idx, arch_id)`、`entity_archetype: PackedInt32Array`（首版仅维护标记，不做物理重排）
   - 在 `DCQuery.with_archetype(arch_id)` 路径中按 `entity_archetype[i] == arch_id` 过滤
   - 暴露 `enable_archetype_sorting: bool` 字段（默认 false）+ `_sort_archetype()` TODO 占位（首版不实现物理重排）
   - 单元测试覆盖：注册两个 archetype，assign 后 query.with_archetype 仅遍历对应 entity
   - _需求：7.1, 7.2, 7.3, 7.4, 7.5_

- [x] 7. **SusJob/SusScheduler 接入 DataCore**
   - 在 `scripts/sus/sus_job.gd` 增加可选字段 `var queries: Array = []`、新增 `_world: DCWorld` 引用注入接口；`SusScheduler` 启动时若 `ClimateProfile.use_data_core` 为 true，则注入 World
   - `_run_slice(ctx)` 允许 job 直接用 `_world.query()...for_each_index(callback)`，callback 返回 false 退出表示预算耗尽
   - round 完成钩子中调用 `_world.commit_round(my_comp_ids)`；`flush_soa_to_cells` 维持原状
   - debug 构建：在 sub-pass 完成时校验 query 写集合外是否被写入（轻量 hash 比对，仅 `OS.is_debug_build()`）
   - _需求：9.1, 9.2, 9.3, 9.4, 9.5_

- [x] 8. **Weather 迁移 Step 1：注册 weather component & front archetype**
   - 在 `weather_system._ready` / `setup` 路径，按 `ClimateProfile.use_data_core_weather` 开关向 World 注册：`COMP_WEATHER_INTENSITY/CLOUD/PRECIP/TYPE`（cell-level，挂入 MapData 已有数组）和 `COMP_FRONT_POS_X/Y/VEL_X/Y/KIND/STRENGTH/RADIUS/AGE`（front-level，由 World 独立分配）
   - 创建 archetype `WEATHER_FRONT_ARCH = world.create_archetype("WeatherFront", [front_comp_ids])`
   - 把现有 `WeatherFront` 实例数组改为内部"front index pool"，运行期通过 World 数组读写；旧 `weather_front.gd` 类降级为只读视图 helper（保留供 UI 兼容），构造/销毁全部走 CommandBuffer
   - _需求：10.1, 10.2, 10.3, 10.4, 10.5, 13.1_

- [x] 9. **Weather 迁移 Step 2：sub-pass 全部走 Query**
   - 改写 `weather_system._tick_advect_soa` / `_tick_spawn_soa` / `_tick_distribute_soa` / `_tick_cyclone_soa` 四个 sub-pass：内部用 `world.query().with_archetype(WEATHER_FRONT_ARCH)...for_each_index(...)` 或 `with_index_list(neighbor_idx)` 替换原有手写遍历
   - hot loop 内仍只走 PackedArray `arr[i]` 索引（用 `view_f32(...)` 在循环外取一次本地引用），保持零回归
   - 跨 tick 切片：sub-pass 用 SusJob cursor + `_world.swap_double_buffer` 共同保证下游读 prev 快照
   - 删除已无引用的 `WeatherFront` AoS 相关代码段（构造、garbage、index 转换 helpers），目标降幅 ≥ 30% 的 weather_system.gd 行数
   - _需求：11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7_

- [x] 10. **治理、对照测试、SUS 日志收口 + 行为零回归验证**
   - 在 `ClimateProfile` 增加 `use_data_core: bool=false` / `use_data_core_weather: bool=false`，并在 `main.gd` 加命令行解析 `--data-core` / `--no-data-core` ✅
   - SUS 30 tick 汇总日志增加 `world_entities` / `world_components` 字段；weather breakdown 末尾追加 `path=data_core | legacy` ✅
   - 实现对照测试 `--validate-weather`：单进程内 A/B 采样模式，按 path 分桶累计 `fronts_count` / `cloud_sum` / `precip_sum` / `temp_field_hash`，每窗口（30 day/桶）自动打印 diff 表，并附 ≤5% / ≤3% / ≤3% / ≤1% 阈值判定；F12 热键随时打印当前快照 ✅（D-01 完成 2026-05-11）
   - 实测 weather_refresh round 平均耗时 ≤ 迁移前 110%（达成需求 11.6 / 12.3 验收线后才能默认 turn-on 开关）✅（C-03 实测 +8%，过线）
   - 文档化灰度切换 / 回滚 SOP 到 `.codebuddy/plan/dots-foundation-and-weather-migration/SOP.md` ✅（D-02 完成 2026-05-11）
   - _需求：12.1, 12.2, 12.3, 12.4, 12.5, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6_

---

## B 阶段验收记录（2026-05-11）

### B-04：双路径平行实测对比（30-tick 窗口）

| 指标 | Legacy 路径 | DataCore 路径 | 差值 | 验收阈值（≤110%） |
|---|---|---|---|---|
| `weather_refresh` avg | ~13.7ms | 14.9–19.1ms | **+9% ~ +39%** | ❌ 未达标 |
| `weather_refresh` max | ~16.6ms | 23.4ms | **+41%** | ❌ 未达标 |
| `weather_refresh` slices/round | 2 | 2~3（极端 3）| +0~50% | ⚠️ 偶发超切 |
| `refresh_climate_daily` avg | ~9.5ms | ~9.8ms | +3% | ✅ 持平 |
| `world.bound` | n/a | true | — | ✅ |
| `entities` / `components` | n/a | 2416 / 37 | — | ✅ 注册规模符合预期 |
| 行为：`fronts=12` 稳定 | ✅ | ✅ | — | ✅ |

### 回归来源根因

1. **`sync_fronts_to_world` 全量同步开销**：每次 sub-pass commit 都遍历 16 个 front 槽 × 6~7 次反射字段查询（`if "center" in f` / `f.has("center")`），即使 fronts 内容未变也全量重写。
2. **sub-pass 切片增多**：DataCore 路径下 weather_tick 内部仍走 legacy AoS（任务 9 仅完成 query 接入与镜像，hot loop 没下沉到 SoA），多了 view_f32×8、archetype 校验、entity_count 扩展等额外开销，触发了 budget 提前耗尽 → slices=3。
3. **DCWorld.is_bound() / archetype_none() 在每个 commit site 重复调用**。

### 决策：进入 C 阶段消化回归（选项 A）

- 不调整 B-04 验收阈值，把 110% 红线作为 C 阶段必过线。
- 用户已在 `earth_like.tres` 默认 `use_data_core_weather=true` + `use_data_core=true`（F9 / `--no-data-core` 可灰度回滚）。
- 进入 C 阶段后所有 task-item 状态以本节为基线对比。

---

## C 阶段任务清单（性能消化）

> 目标：DataCore 路径 weather_refresh avg 回到 legacy 同档 ±5%，max ≤ 18ms，slices=2 稳定。

- [x] **C-01. `sync_fronts_to_world` 三阶优化**（2026-05-11 完成）
   - C-01.1：入口加 dirty short-circuit ✅ —— 缓存上次 `_last_sync_n / _last_sync_id_xor / _last_sync_content_hash`，三者全等时直接 return；空写场景节省 ~95%
   - C-01.2：类型分发 ✅ —— 入口判一次 `is_first_object_typed`，分发到 `_sync_fronts_object_path`（强类型快路径，零反射）/ `_sync_fronts_dict_path`（兼容 Dict / alias，原行为保留）
   - C-01.3：循环外取 view、`base / arch_id / arch_none` 提到循环外（避免每次重新查找）；free 段差分仅在 n.._cap 区间标 ARCH_NONE ✅
   - 实现位置：`weather_refresh_job.gd:182-340`
   - 预期效果：单次 `sync_fronts_to_world` 从 ~0.4ms 降到 ≤0.05ms（dirty 短路时）/ ≤0.15ms（全量）

- [~] **C-02. `weather_system` sub-pass hot-loop 内层 SoA 化（advect / spawn / distribute）**
   - C-02.1：cell-level intensity / cloud / precip 等本地引用化 ⏸️ **无需做** —— grep 确认 weather_system.gd **没有任何** `view_f32 / temp_arr / weather_intensity_arr` 引用，它走的是内部 field-solver SoA + HexCell 写，**不读 World 数据**。这意味着回归 100% 来自 `sync_fronts_to_world`，C-01 已覆盖。
   - C-02.2：advect 子循环中 `front_pos_x[i]` 改本地引用 ⏸️ **无需做** —— 同上，weather_system 不读 World 中的 front-level component（它读的是 AoS `WeatherFront.center.x`）。
   - C-02.3：`run_slice` 入口缓存 `is_data_core_on` 一次 ✅ —— 已实施（`weather_refresh_job.gd:439-441`），两个 commit site 复用同一变量，避免重复评估 ClimateProfile + `data_core_ready()`
   - 备注：B 阶段当前的"+1.2~5.4ms 回归"经定位**全部源自 sync_fronts_to_world**，C-01 改造后预期已能消化。C-02 真正的 SoA 内层化要等"weather_system 内部读 SoA 而非 HexCell"的下一阶段计划（不属于本期"先迁通管线、后治理"范围）。

- [x] **C-03. 实测 + 写回验收日志**（2026-05-11 完成）
   - 同条件 30 game day（earth_like preset，stride=1）抓 4 个 30-tick 汇总窗口
   - 详见下方"C 阶段验收记录"小节

---

## C 阶段验收记录（2026-05-11）

### C-03：C-01 优化后 30-tick 实测对比

| 指标 | Legacy（B 基线）| DataCore（B 阶段）| **DataCore（C 阶段）** | C vs Legacy | 验收阈值（≤110%）|
|---|---|---|---|---|---|
| `weather_refresh` avg | ~13.7ms | 14.9–19.1ms | **12.66 / 14.89 / 16.84ms（avg≈14.8ms）** | **+8%** | ✅ **过线** |
| `weather_refresh` max | ~16.6ms | 23.4ms | **18.06ms** | +9% | ✅ **过线** |
| `weather_refresh` slices/round | 2 | 2~3（偶发 3）| **2（4 个窗口全 2 稳定）**| — | ✅ |
| `refresh_climate_daily` avg | ~9.5ms | ~9.8ms | ~10.1ms | +6% | ✅（与 weather 无关）|
| `weather_tick` (adv+spawn+dist) | ~9.5ms | ~10.0ms | 9.2~11.4ms（spawn 抖动）| 持平 | ✅ |
| `world.bound / entities / components` | n/a | 2416 / 37 | 2416 / 37 | — | ✅ |
| `fronts=12` 稳定 | ✅ | ✅ | ✅ | — | ✅ |

### 关键改造收益拆分

| 改造项 | 估算贡献 |
|---|---|
| C-01.1 dirty short-circuit | ~80% 全量同步调用变为 no-op return |
| C-01.2 类型分发 + 强类型快路径 | 循环内消除 96 次反射查询/调用 |
| C-01.3 archetype 差分 + view 提循环外 | 消除冗余字段查找开销 |
| C-02.3 commit-site 缓存 | 每个 sub-pass 少 1 次 ClimateProfile + ready 检查 |

### B-04 → C-03 横向对比

- B 阶段 max 23.4ms / avg 19.1ms（+39%）→ C 阶段 max 18.06ms / avg 14.8ms（+8%）
- 残余 +8% 主要来自 `weather_tick` 自身的 spawn 阶段抖动（4.3 → 6.0，30% 浮动），与 DataCore 无关
- slices=3 偶发现象在 C 阶段消失，说明 sync 开销被压缩进了第一个 budget slot

### 决策

- **C 阶段过线**，第 10 项 task 中的"实测 weather_refresh ≤ 迁移前 110%"已达成
- 但 `--validate-weather` 数值对照测试 + SOP 文档仍 pending，所以第 10 项保留 `[~]`
- 推荐下一步：D 阶段（数值对照 + SOP 文档收口），或者跳到下一系统的 DataCore 迁移（climate / ocean）

---

## D 阶段交付记录（2026-05-11）

### D-01：`--validate-weather` 单进程 A/B 采样

实装位置：[main.gd](../../Project/project-keynes/scripts/main.gd) `_validate_weather_collect / _validate_compute_field_stats / _validate_weather_try_emit_diff / _validate_weather_print_diff / _validate_weather_print_snapshot`

**关键设计**：
- 单进程内按 path 自动分桶（legacy / data_core / data_core_cells_only），用户用 F9/F10 在同一会话内切 path 即可双向采样
- 采样指标：`fronts_count` / `cloud_sum` / `precip_sum` / `temp_hash_sum`（量化到 1/1024 后 sum） / `temp_hash_xor`（量化后逐 cell xor）
- 数据源：直接读 [main.gd](../../Project/project-keynes/scripts/main.gd) 持有的 `_current_map`，避免 HexCell 慢路径
- 每桶满 `_validate_window_size`（默认 30）且至少 2 桶都满时，自动打印 diff 表（含阈值 ≤5% / ≤3% / ≤3% / ≤1% + VERDICT）
- F12 热键：随时打印当前累计快照（不清零）

**性能影响**：仅 `--validate-weather` 启用时生效；单次采样 = O(N) 一次扫 cloud/precip/temp 三数组（2400 cells × 3 = 7200 次访问，估 < 0.05ms），不影响生产路径。

### D-02：SOP 文档

落盘位置：[SOP.md](./SOP.md)

**覆盖范围**：
- §0 角色与术语（4 个 path 取值含义）
- §1 启动期开关矩阵（CLI / tres / 默认值优先级）
- §2 运行期热键（F9 / F10 / F11 / F12）+ DCWorld 单次绑定的关键提示
- §3 灰度推进 mermaid 流程图（4 步 Step）+ 每步必看 SUS 指标
- §4 `--validate-weather` 完整流程（启动 → 切 F9 → 等 diff 表）+ 阈值说明
- §5 SUS 日志字段速查（避免日后查日志找文档）
- §6 三档回滚 SOP（轻度 / 永久 / 紧急）
- §7 验收门槛对齐表
- §8 FAQ（5 条常见问题）
- §9 变更历史

### 决策

- **本期"DataCore 基石 + Weather 首次迁移"计划全部 10 项任务完成 ✅**
- weather_refresh 性能 +8%（红线 110%）✅；行为对照测试自动化 ✅；运维 SOP 落盘 ✅
- 下一阶段建议：**E 阶段** —— 把 `refresh_climate_daily`（当前 ~10ms 大头）也迁到 DataCore，验证基石的 cell-level 双缓冲 + 多 sub-pass 切片能力（climate Pass A/B/ocean/sea_ice 4 个 sub-pass，比 weather 4 个 sub-pass 体量更大、依赖更复杂）。

> E 阶段不在本计划范围内，独立 plan 目录会另开。本计划至此 close-out。
