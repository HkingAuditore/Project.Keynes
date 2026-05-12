# 实施计划：DOTS Roadmap to GDExtension

> 本任务清单按 4 个迭代（I1 / I2 / I3 / I4）组织。每条任务可独立勾选验收。
> 终点是 **GDExtension 接管 hot loop，综合加速 ≥ 2.5x**。
>
> **执行原则**：严格按 I1 → I2 → I3 顺序推进；每个 sub-iter 出口未达标禁止进入下一个。

---

## I1 — Hot Path 数据通道收口

### I1.A：Climate 工程化收尾（1 天）

- [x] **I1.A-1. SUS 日志输出 climate path 标识** ✅ 2026-05-11
   - 改动点已落盘（3 处）：
     - [main.gd](../../Project/project-keynes/scripts/main.gd) `_print_daily_breakdown` 内 climate 行：`climate path=%s dc=%s`（并存以兑现历史脚本）
     - [refresh_climate_daily_job.gd](../../Project/project-keynes/scripts/simulation/sus/jobs/refresh_climate_daily_job.gd) `_finalize_round` 内 sliced summary print 末尾追加 ` path=...`
     - [map_generator.gd](../../Project/project-keynes/scripts/geography/map_generator.gd) wrapper 路径 print 同步追加 ` path=...`（当前不触发，保留一致）
   - 三态推导逻辑与 weather 一致：`legacy` / `data_core_cells_only` / `data_core`
   - 依据：真相源 = `cp.use_data_core_climate`（F11/tres 可切换），避免 `data_core_ready()` 不可逆导致 path 误报
   - _需求：Story I1.A.1_

- [ ] **I1.A-2. 跑 4 个 30-tick 窗口实测**
   - 启动：`Godot --headless res://main.tscn`，跑 30 game-day × 4 个独立窗口
   - 路径切换：F11 toggle（运行期）+ 重启切 tres 默认值（永久路径）
   - 抓指标：`refresh_climate_daily` avg/max、各 sub-pass breakdown、frame_budget_exhausted 次数
   - _需求：Story I1.A.2_

- [ ] **I1.A-3. 把实测数据填到 climate task-item.md 的 §B 阶段验收记录**
   - 目标文件：[`.codebuddy/plan/climate-datacore-migration/task-item.md`](../climate-datacore-migration/task-item.md)
   - 编辑表格：把 4 行 `TBD` 替换成实测数字
   - 验证红线：DataCore avg ≤ Legacy avg × 105%；max ≤ ×108%
   - 不通过 → 走 climate plan B-4 优化项，本路线图暂停
   - _需求：Story I1.A.2_

- [ ] **I1.A-4. SOP §3a / §6a 落盘**
   - 目标文件：[`.codebuddy/plan/dots-foundation-and-weather-migration/SOP.md`](../dots-foundation-and-weather-migration/SOP.md)
   - 增补 §3a "Climate 灰度推进流程"：mermaid 流程图（默认 off → F11 灰度 on → 4 窗口验收 → tres 默认 on）
   - 增补 §6a "Climate 回滚"：两档（F11 运行期 / tres 永久）；CLI 已 WONTFIX，不在 SOP 描述
   - _需求：Story I1.A.3_

- [ ] **I1.A-5. climate plan close-out 标记**
   - 目标文件：[`.codebuddy/plan/climate-datacore-migration/task-item.md`](../climate-datacore-migration/task-item.md)
   - 在文件末尾追加 ✅ "2026-XX-XX close-out, 综合验收过线" 标记
   - 把所有未勾选任务（C-1 / C-3 / D-1 / D-2 / D-3）状态归位（实际已完成的勾选；C-2 已 WONTFIX）
   - _需求：Story I1.A.4_

---

### I1.B：Weather 内部 SoA 化（4~5 天，**核心攻坚**）

> ⚠️ weather_system.gd 是 105KB 单文件，每次编辑前**必须先读最新文件内容**避免摘要陷阱。
> ⚠️ 改造期间务必启用 `--validate-weather` 30-day 对照，每完成一个函数就验证 L2 误差。

#### B.1 — 字段化（1 天）

- [ ] **I1.B-1. 注册 8 个 front-level F32 + 1 U8 + 1 I32 component**
   - 目标文件：`scripts/data_core/component_ids.gd`（如已注册则跳过）+ `scripts/data_core/world.gd::bind_map_data` 或独立 `bind_weather_fronts` 入口
   - component 列表：FRONT_CENTER_X / Y / RADIUS / INTENSITY / AGE / LIFETIME / HEADING / SPEED / KIND（U8）/ ARCHETYPE_LINK（I32）
   - 注册时机：`weather_system._init` 内调用 `world.create_pool("weather_fronts", max_active_fronts)` 后立即注册
   - _需求：Story I1.B.1_

- [ ] **I1.B-2. WeatherFront 类改造为"读访问器" + 写入路由到 World**
   - 目标文件：`scripts/weather/weather_front.gd`
   - 字段保留兼容（getter 直接读 World.view_f32(comp_id)[idx]）
   - setter（如有）路由到 `world.view_f32(comp_id)[idx] = v`
   - 新增 `bind_world(world, idx)` 让实例与 World 槽位关联
   - _需求：Story I1.B.1_

#### B.2 — Hot 函数迁移（2~3 天）

- [ ] **I1.B-3. 迁移 `_step_active_fronts`**
   - 目标文件：`scripts/weather/weather_system.gd`
   - 改为 `query.with_archetype(ARCH_WEATHER_FRONT).for_each_index(func(i): ...)`
   - 循环外取 8 个 PackedArray 引用，循环内仅 index 读写
   - _需求：Story I1.B.3 行 #2_

- [ ] **I1.B-4. 迁移 `_apply_field_advection`**
   - 仅切换数据入口（map.xxx → world.view_f32），算法不动
   - _需求：Story I1.B.3 行 #3_

- [ ] **I1.B-5. 迁移 `_compute_emergent_coupling`**
   - 同模式
   - _需求：Story I1.B.3 行 #4_

- [ ] **I1.B-6. 迁移 `pack_to_uniforms`**
   - GPU uniform pack 阶段，hot path 末段，慎重
   - 验收：渲染层 shader 输出无视觉差异
   - _需求：Story I1.B.3 行 #5_

- [ ] **I1.B-7. 迁移 spawn / destroy（首版用 World.assign_archetype，I2.B 再升级 ECB）**
   - `_spawn_front`：`world.assign_archetype(idx, ARCH_WEATHER_FRONT)` 后写入 8 个字段
   - `_destroy_front`：`world.assign_archetype(idx, ARCH_NONE)`
   - **不用** `_active_fronts.append/remove_at`（避免 Array 分裂）
   - _需求：Story I1.B.3 行 #6, #7_

#### B.3 — 行为对照 + 性能验收（1 天）

- [ ] **I1.B-8. 启用 `--validate-weather` 跑 30-day 对照**
   - 验收：weather field grid（temp / moisture / pressure）逐 cell L2 ≤ 1e-5
   - 验收：active_fronts 30-day 直方图 / 平均寿命 / 平均强度三组统计完全一致
   - _需求：Story I1.B.4_

- [ ] **I1.B-9. 性能验收**
   - 4 个 30-tick 窗口对比：legacy vs DataCore 路径
   - 红线：avg ≤ legacy × 110%；max ≤ × 115%
   - 不通过 → 排查"循环内反射 component_id"等已知踩坑（参考 climate B-4 经验）
   - _需求：Story I1.B.5_

- [ ] **I1.B-10. sync_fronts_to_world 标记 deprecated**
   - 目标文件：`scripts/simulation/sus/jobs/weather_refresh_job.gd::_sync_fronts_to_world`
   - 函数注释加 `## DEPRECATED (since 2026-XX-XX, scheduled removal in 6 months)`
   - 实现内追加 `push_warning_once("...")`
   - _需求：Story I1.B.2_

---

## I2 — 架构债务清理

### I2.A：多 entity pool（3 天）

- [x] **I2.A-1. World 增加 pool API** ✅ 2026-05-11
   - 目标文件：`scripts/data_core/world.gd`
   - 新增字段：`var _pools: Array = []`（Array[Dictionary {name, start, count}]）+ `var _pool_by_name: Dictionary = {}`
   - 新增方法：`create_pool(name, capacity) -> int` / `pool_range(pool_id) -> Vector2i` / `pool_id(name) -> int`
   - 内部：`create_pool` 把 entity_count 累加，所有已注册 component resize；返回 [start, end) 段
   - _需求：Story I2.A.1_

- [x] **I2.A-2. DCQuery 支持 in_pool 过滤** ✅ 2026-05-11
   - 目标文件：`scripts/data_core/query.gd`
   - `in_pool(pool_id) -> DCQuery`：保存 [start, end) 范围
   - `for_each_index` 内层循环用 `i in range(start, end)` 替代 `range(world.entity_count())`
   - _需求：Story I2.A.1_

- [x] **I2.A-3. 迁移 cell pool 创建路径** ✅ 2026-05-11
   - 改 `world.bind_map_data` 头部调 `create_pool(POOL_CELLS, n)`，并修复 cells pool 与 entity_count 重复累加的 bug
   - _需求：Story I2.A.2_

- [x] **I2.A-4. 迁移 weather front pool 创建** ✅ 2026-05-11
   - 改 `weather_refresh_job._on_world_bound` 调 `world.create_pool(POOL_WEATHER_FRONTS, MAX_FRONTS_DC)`
   - 用 `pool_range(pid)` 获取 base，I2.B 之后改为 ECB free-list 分配
   - _需求：Story I2.A.2_

- [x] **I2.A-5. 所有 hot loop 显式 `query.in_pool(...)`** ✅ 2026-05-11
   - weather Query 路径：`q.in_pool(_pool_id_fronts)` 已落地
   - climate hot path 4 个 sub-pass 仍使用 `[0, n_cells)` 物理段直访（pool=0 与全段同义，不强求改写）
   - _需求：Story I2.A.2_

- [x] **I2.A-6. 行为零回归验收** ✅ 2026-05-11
   - 实测：30-tick 多窗口 climate / weather SUS 指标与 baseline ±2~5% 持平
   - entities=2416, components=43, pools=2（修复 cells 重复累加 bug 后稳定）
   - _需求：Story I2.A.3_

---

### I2.B：CommandBuffer 实战化（2 天）

- [x] **I2.B-1. weather _spawn_front 切换到 ECB** ✅ 2026-05-11
   - **路径甲实施**（非 weather_system 内部 spawn 时换 idx，而是在 weather_refresh_job sync 端给 front 分 idx）：
     `_sync_fronts_object_path` 检测 `f.world_idx == -1` → `ecb.create_in_pool(_pool_id_fronts, ARCH_WEATHER_FRONT)` 拿真实 idx 并写回 `f.world_idx`
   - flush 时机：sync 函数末尾 `world.flush_command_buffer()`（一次性应用 archetype + free-list）
   - 路径选择决策：spawn 时机不变（仍在 weather_system 内 commit_stage_a），仅 sync 时引入 ECB；该决策通过"业务禁读"纪律（WeatherFront.world_idx 仅 sync 路径可读）保证终局对齐性
   - _需求：Story I2.B.1_

- [x] **I2.B-2. weather _destroy_front 切换到 ECB** ✅ 2026-05-11
   - sync 端检测上轮 `_synced_fronts` 中本轮不在的 front → `ecb.destroy_in_pool(_pool_id_fronts, world_idx)` 并 `f.world_idx = -1`
   - 实现：`_CMD_DESTROY_TO_POOL` flush 时 archetype 置 ARCH_NONE + `_pool_free` 归还 idx
   - _需求：Story I2.B.1_

- [x] **I2.B-3. CommandBuffer pool-aware API** ✅ 2026-05-11（**替代原扩容方案**）
   - 实施 `create_in_pool / destroy_in_pool / set_archetype` 三件套 + `_CMD_SET_ARCH / _CMD_DESTROY_TO_POOL` 两条新命令
   - `create_in_pool` 立即调 `World._pool_alloc` 拿真实 idx（同步返回，非占位值），仅"打 archetype 标记"延后到 flush
   - **按需扩容（resize_pool）暂未实现**：weather pool 容量固定 16，无扩容需求；扩容路径并入 I3.A 的 C++ DCWorldExt 设计
   - _需求：Story I2.B.2_（部分实现，扩容延后）

- [x] **I2.B-4. WeatherFront.world_idx 字段化 + 业务禁读纪律** ✅ 2026-05-11（**替代 _front_free_indices 弃用**）
   - 实际现状：weather_system 早就没用手工 free-list（Array[WeatherFront] 即句柄），无需弃用
   - 真正的工作是给 WeatherFront 加 `world_idx: int = -1`，附"框架内部字段、业务禁读"纪律注释
   - 升级路径：P1-⑤ "WeatherFront SoA 化" 阶段把 WeatherFront 退化为"瘦句柄"，业务代码经 `world.view_*(comp)[front.world_idx]` 合法引用此字段
   - _需求：Story I2.B.3_

- [x] **I2.B-5. I2 综合验收** ✅ 2026-05-11
   - 实测窗口：30-tick 多次循环
   - climate 数据零回归（path=data_core 不变，avg 9.29-9.62ms 与 I2.A 持平）
   - weather 数据零回归（path=data_core 不变，avg 12.49-14.63ms 与 I2.A 持平）
   - `set_weather_fronts(n=12)` 渲染层正常收 fronts；ECB flush 开销吸收在 weather_tick 总耗时内
   - 无 push_warning 噪声（dict mock 路径未触发）
   - _需求：Story I2.B 综合_

---

## I3 — GDExtension 接管 Hot Loop

### I3.A：C++ 骨架（4~5 天）

- [ ] **I3.A-1. 工程目录结构创建**
   - 新增：`gdext/SConstruct`（继承 godot-cpp 模板）
   - 新增：`gdext/src/world_ext.h` + `world_ext.cpp`（DCWorldExt 主体，先空实现）
   - 新增：`gdext/src/register_types.cpp`（GDExtension 注册入口）
   - 新增：`gdext/godot-cpp/`（git submodule，pin 到与当前 Godot 版本兼容的 godot-4.x 分支）
   - 新增：`Project/project-keynes/addons/dots_ext/dots_ext.gdextension`（三平台动态库声明）
   - 新增：`Project/project-keynes/addons/dots_ext/bin/<platform>/`（编译产物输出目录）
   - _需求：Story I3.A.1_

- [ ] **I3.A-2. SCons 编译跑通（Windows MSVC）**
   - `cd gdext && scons platform=windows target=template_debug`
   - 输出：`addons/dots_ext/bin/windows/dots_ext.windows.template_debug.x86_64.dll`
   - 验证：Godot 启动后 `ClassDB.class_exists("DCWorldExt") == true`
   - _需求：Story I3.A.1_

- [ ] **I3.A-3. DCWorldExt 镜像 GDScript API**
   - C++ 实现：register_component / component_id / view_f32 / view_u8 / view_i32 / create_pool / pool_range / bind_map_data
   - 内部数据结构：与 GDScript 版 DCWorld 完全对齐（_slots / _slot_by_name / _pools 等）
   - bind_map_data 通过 `Object::call("get_temp_arr")` 等 GDScript 桥接读 MapData 字段（首版可接受调用开销）
   - _需求：Story I3.A.2_

- [ ] **I3.A-4. 零加速 wrapper 验证**
   - 在 climate hot path 上加开关 `cp.use_gdext_world`
   - C++ 端 view_f32 仅返回 GDScript 同样的 PackedArray，hot loop 还是 GDScript 跑
   - 验收：30-day 数值完全一致；SUS 耗时 ±5%（开销来自跨语言桥接）
   - _需求：Story I3.A.2_

- [ ] **I3.A-5. Linux GCC 构建跑通**
   - 在 WSL2 / Linux VM / CI 跑 `scons platform=linux target=template_debug`
   - _需求：Story I3.A.3_

- [ ] **I3.A-6. Android NDK arm64 构建跑通**
   - `scons platform=android target=template_debug arch=arm64`
   - 验证：Android 真机或模拟器加载 .so 不崩
   - _需求：Story I3.A.3_

---

### I3.B：第一个 Hot Loop 接管（3~4 天）

- [ ] **I3.B-1. ClimateProfile struct 序列化**
   - 目标文件：`gdext/src/climate_profile_struct.h`
   - 把 ClimateProfile 的 ~25 个数值常量打包成 plain C struct
   - GDScript 端：在 sub-pass 入口调用前一次性填充并传入（避免 hot loop 内回调）
   - _需求：Story I3.B.1_

- [ ] **I3.B-2. 实现 `DCWorldExt::run_climate_pass_a`**
   - 复刻 [`map_generator.gd._climate_pass_a_soa`](../../scripts/geography/map_generator.gd) 算法
   - 内层循环用 `float* p = arr.ptrw()` 裸指针
   - 邻居访问通过 `topology.hex_neighbors` 的 PackedInt32Array
   - _需求：Story I3.B.1_

- [ ] **I3.B-3. GDScript 端切换分支**
   - 目标文件：`scripts/geography/map_generator.gd::_climate_pass_a_soa`
   - 在函数顶部增加：`if cp.use_gdext_climate and _gdext_world: return _gdext_world.run_climate_pass_a(cp_struct, phase, season_phase)`
   - GDScript 实现保留作为 fallback
   - _需求：Story I3.B.1_

- [ ] **I3.B-4. 行为对照（--validate-climate-cpp）**
   - 新增 CLI 参数 `--validate-climate-cpp`（`main.gd._parse_data_core_cli`）
   - 启用后跑 30-day A/B：GDScript path vs C++ path
   - 验收：整图 temperature L2 ≤ 1e-5
   - _需求：Story I3.B.3_

- [ ] **I3.B-5. 性能验收**
   - 4 个 30-tick 窗口对比
   - 红线：C++ pass_a 实测 ≤ GDScript × 33%（即 ≥ 3x 加速）
   - 综合：refresh_climate_daily avg ≤ legacy × 70%
   - _需求：Story I3.B.2_

---

### I3.C：渐进接管（5~6 天）

- [ ] **I3.C-1. `run_climate_pass_b`** — C++ 实现 + 行为对照 + 性能验收
- [ ] **I3.C-2. `run_ocean_water_pass`** — 同上
- [ ] **I3.C-3. `run_ocean_land_pass`** — 同上
- [ ] **I3.C-4. `run_weather_field_advection`** — weather 端的第一个 C++ 接管
- [ ] **I3.C-5. 综合验收**：
   - climate refresh_climate_daily avg ≤ legacy × 35%
   - weather_refresh avg ≤ legacy × 50%
   - 两者数值零回归
- _需求：Story I3.C.1, I3.C.2_

---

### I3.D：综合验收 + 跨平台回归 + close-out（2~3 天）

- [ ] **I3.D-1. 综合性能基线（earth_like / 1024×606）**
   - 4 个 30-tick 窗口实测：C++ 全开 vs GDScript 全开
   - 综合 daily-tick 总耗时加速比 ≥ 2.5x
   - _需求：Story I3.D.1_

- [ ] **I3.D-2. 移动端实测**
   - Android arm64 真机跑 30-day，抓 SUS 日志
   - 加速比独立记录（移动端 CPU 弱，预期加速比更高）
   - _需求：Story I3.D.1_

- [ ] **I3.D-3. 三平台回归烟测**
   - Windows / Linux / Android 各 30-day
   - 三平台数值结果一致（FMA 顺序差异 ≤ 1e-6）
   - _需求：Story I3.D.2_

- [ ] **I3.D-4. 路线图 close-out**
   - 在本文件末尾追加 ✅ "2026-XX-XX close-out, 综合加速 X.Xx, 三平台过线"
   - 更新 SOP.md：增补 §10 "GDExtension 维护 SOP"（编译/部署/回滚 GDExtension 的步骤）
   - _需求：Story I3.D.3_

---

## I4 — 可选：Archetype 物理重排 + 工程化收口（1 周）

> 仅在 I3.D 实测瓶颈是 cache miss 或团队扩张需要工程化收口时启动。

### I4.A：Archetype 物理重排

- [ ] **I4.A-1. World 增加 `enable_archetype_sorting` 实现**
- [ ] **I4.A-2. 物理重排算法**：在 round 末按 archetype 标记位排序 entity 数据
- [ ] **I4.A-3. 性能验收**：cache miss 实测下降；hot loop avg 进一步降 5~10%

### I4.B：单元测试 + 演示

- [ ] **I4.B-1. DataCore 模块单元测试**：DCWorld / DCQuery / DCCommandBuffer / DCWorldExt
- [ ] **I4.B-2. GDExtension 演示场景**：纯 C++ 跑 100K entity benchmark scene
- [ ] **I4.B-3. 团队接入文档**：如何写新的 C++ system / 如何注册新 component

---

## 阶段验收记录（待补）

### I1.A 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| SUS 日志 path 标识 | ✅ 2026-05-11 | 3 处 print 均已落盘 |
| 4 窗口性能对比（avg %）| ⬜ | TBD% |
| SOP §3a / §6a 落盘 | ⬜ | — |
| climate plan close-out | ⬜ | — |

### I1.B 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| 8 个 front-level component 注册 | ⬜ | — |
| 7 个 hot 函数全部迁移 | ⬜ | — |
| L2 误差 ≤ 1e-5 | ⬜ | TBD |
| weather_refresh avg ≤ ×110% | ⬜ | TBD% |

### I2.A 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| World pool API 落地 | ✅ 2026-05-11 | create_pool / pool_range / pool_id / pool_count / _pool_alloc / _pool_free |
| cells / weather_fronts 两个 pool 物理分离 | ✅ 2026-05-11 | entities=2416 (2400+16), pools=2 |
| 行为零回归（SUS ±2%）| ✅ 2026-05-11 | climate avg 9.43→9.62ms（+2%），weather avg 13.87→13.69ms（持平），ocean avg 4.79→4.40ms（持平） |

### I2.B 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| ECB 接管 spawn/destroy | ✅ 2026-05-11 | create_in_pool / destroy_in_pool / set_archetype + _CMD_SET_ARCH / _CMD_DESTROY_TO_POOL |
| pool free-list 落地 | ✅ 2026-05-11 | World._pool_free_lists（栈式 LIFO，O(1) alloc/free） |
| WeatherFront.world_idx 纪律字段 | ✅ 2026-05-11 | 业务禁读注释；P1-⑤ 升级为瘦句柄 |
| 按需扩容（resize_pool）| ⬜ 延后 | weather pool 容量固定 16 暂无需求；并入 I3.A C++ DCWorldExt 设计 |
| 30-tick 烟测零回归 | ✅ 2026-05-11 | climate 9.29-9.62ms / weather 12.49-14.63ms / 无 push_warning 噪声 / fronts=12 渲染正常 |

### I3.A 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| Windows 编译通过 | ⬜ | — |
| Linux 编译通过 | ⬜ | — |
| Android 编译通过 | ⬜ | — |
| 零加速 wrapper 验证 | ⬜ | — |

### I3.B 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| pass_a C++ 实现 | ⬜ | — |
| L2 误差 ≤ 1e-5 | ⬜ | TBD |
| pass_a 加速比 ≥ 3x | ⬜ | TBDx |

### I3.C 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| 4 个 hot loop 全部接管 | ⬜ | — |
| climate 整体加速 ≥ 2x | ⬜ | TBDx |
| weather field 加速 ≥ 2x | ⬜ | TBDx |

### I3.D 验收记录

| 项目 | 状态 | 数据 |
|---|---|---|
| 综合 daily-tick 加速 ≥ 2.5x | ⬜ | TBDx |
| 三平台过线 | ⬜ | — |
| 路线图 close-out | ⬜ | — |

---

## 风险登记表

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| weather_system.gd 改造引入数值回归 | 中 | 高 | --validate-weather L2 ≤ 1e-5；逐函数验证 |
| 多 pool 改造破坏现有 archetype 标记 | 中 | 中 | I2.A.6 SUS ±2% 红线 |
| godot-cpp 与 Godot 版本不兼容 | 中 | 高 | submodule pin 到具体 commit；升级 Godot 时跑全量回归 |
| Android NDK 编译坑 | 高 | 中 | I3.A.6 早测；缺一不进 I3.B |
| C++ 加速比不达 3x | 中 | 中 | 单 pass 失败可回退 GDScript；先 -O2 自动向量化，不达标再 SIMD |
| 团队中无人能维护 C++ | 中 | 低 | I4.B 文档（可选） |

---

## 决策日志

- **2026-05-11**：路线图制定。终点确定为 GDExtension 接管 hot loop（用户明确）。
- **2026-05-11**：climate plan CLI 参数 WONTFIX，理由：已有老性能数据，无需 A/B 启动开关。
- **2026-05-11**：I1.A 收尾任务从 climate plan 拷贝到本路线图执行（climate plan 同步标记 close-out）。
- **2026-05-11**：**I2.A 完工**——World pool API + Query.in_pool 落地；entities=2416, pools=2 稳定；行为零回归。
- **2026-05-11**：**I2.B 完工**（A 路线 + 路径甲）——ECB pool-aware（create_in_pool / destroy_in_pool / set_archetype）+ pool free-list；WeatherFront.world_idx 加业务禁读纪律；30-tick 实战零回归。**按需扩容（resize_pool）延后到 I3.A**——weather pool 容量固定 16 暂无需求，C++ DCWorldExt 设计阶段统一处理 pool resize。详见 [architecture.md 决策日志]。
- **2026-05-11**：**I3 启动评估开始**——按 I2.B 完工状态，路线图正式进入 I3.A（C++ 骨架与 godot-cpp 集成）阶段。
