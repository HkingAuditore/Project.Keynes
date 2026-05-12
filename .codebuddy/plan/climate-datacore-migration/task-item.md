# 实施计划

> 本计划严格按"先迁通管线、再做性能验收、最后开关收口"的四段式组织。
> 所有任务都是编码任务，每一步基于上一步的产物递进。
>
> **主要目标文件**：
> - `scripts/data/climate_profile.gd`（新增 `use_data_core_climate` 字段）
> - `scripts/simulation/sus/jobs/refresh_climate_daily_job.gd`（新增 `_on_world_bound` + comp_id 缓存 + 把 view 引用透传给 generator）
> - `scripts/geography/map_generator.gd`（4 个 SoA sub-pass 取数入口分支化）
> - `scripts/main.gd`（F11 热键 + CLI 参数 + SUS 日志 path 标识）
> - `data/world/earth_like.tres`（验收过线后默认开启）
> - `.codebuddy/plan/dots-foundation-and-weather-migration/SOP.md`（增补 §3a / §6a）

---

## A 阶段：最小迁移（取数入口替换）

> 目标：把 4 个 SoA sub-pass 的 25 个 `map.xxx_arr` 取数行改成 `_world.view_*(comp_id)`，
> 通过 `use_data_core_climate` 开关灰度，默认 off。

- [ ] **A-1. ClimateProfile 增加 `use_data_core_climate` 字段**
   - 在 `scripts/data/climate_profile.gd` `use_data_core_weather` 之后追加：
     ```gdscript
     # 3) use_data_core_climate
     #    在 use_data_core = true 的前提下启用 climate sub-pass 通过 DCWorld 取
     #    cell-level component 数组（替代 map.xxx_arr 直接字段访问），统一数据
     #    访问入口，为未来 C++ 接管 hot loop 扫清前置条件。
     #    本开关不改变任何算法/数值，仅切换数组来源；行为应零回归。
     @export var use_data_core_climate: bool = false
     ```
   - 默认 `false`，不修改 `earth_like.tres`（D 阶段验收过线后再改）
   - _需求：Story 1.1, 1.2_

- [ ] **A-2. RefreshClimateDailyJob 注入 World + 缓存 25 个 comp_id**
   - 在 `refresh_climate_daily_job.gd` 增加成员：
     ```gdscript
     var _world: DCWorld = null  # 由 SusScheduler.bind_world 注入
     var _data_core_components_ready: bool = false
     # 25 个 component_id 缓存（参考 weather_refresh_job.gd:118~131 写法）
     var _comp_cell_temp: int = -1
     var _comp_cell_moisture: int = -1
     # ... 共 25 个
     ```
   - 实现 `_on_world_bound() -> void`：调用 `_world.component_id(DCComponentIds.CELL_*)` 一次性缓存全部 25 个 ID
   - 实现 `data_core_ready() -> bool`：返回 `_data_core_components_ready and _world != null and _world.is_bound()`
   - **关键 assert**：在 `_on_world_bound` 末尾，对 `_comp_cell_temp` 做引用一致性校验：
     ```gdscript
     # bind_map_data 应保证 view_f32 返回的就是 map.temp_arr 同一个底层引用
     # 若失败，强制关闭 use_data_core_climate 并 push_error
     if _world.view_f32(_comp_cell_temp) != map.temp_arr:
         push_error("[DataCore/climate] view_f32(CELL_TEMP) ref mismatch with map.temp_arr; disabling use_data_core_climate")
         _data_core_components_ready = false
         return
     ```
   - **不要**在 `_run_pass` / `run_slice` 内做任何取数动作（保持 Job 与 SoA 函数解耦，Job 只负责调度）
   - _需求：Story 1.4, 2.1_

- [ ] **A-3. MapGenerator 暴露 World 取数入口给 4 个 sub-pass**
   - 在 `map_generator.gd` 新增辅助方法（避免每个 sub-pass 都写 25 行 view 调用）：
     ```gdscript
     ## DataCore 路径取数：返回与 map.xxx_arr 等价的 PackedArray 引用字典。
     ## 仅当 cp.use_data_core_climate=true 且 _data_core_world 已 bind 时返回非空。
     ## 失败时返回空 Dict，调用方走 legacy 路径。
     func _climate_views_from_world(cp: ClimateProfile) -> Dictionary:
         if cp == null or not cp.use_data_core_climate:
             return {}
         var w = get_data_core_world()
         if w == null or not w.is_bound():
             return {}
         var job = _refresh_climate_job  # SUS 注入时存的引用
         if job == null or not job.data_core_ready():
             return {}
         return {
             "temp": w.view_f32(job._comp_cell_temp),
             "moisture": w.view_f32(job._comp_cell_moisture),
             # ... 共 25 个 key
             "climate_dirty_mask": w.view_u8(job._comp_cell_climate_dirty),
         }
     ```
   - 在 `_setup_sus` 中保存 RefreshClimateDailyJob 引用为 `_refresh_climate_job` 成员（如果还没保存）
   - _需求：Story 1.4, 1.5_

- [ ] **A-4. 改造 4 个 SoA sub-pass 的取数入口（核心工作）**
   - **改造原则**：循环外取一次本地引用，内层循环代码**一行不动**（关键风险防护）
   - 每个函数开头：
     ```gdscript
     var _dc_views: Dictionary = _climate_views_from_world(cp)
     var _use_dc: bool = not _dc_views.is_empty()
     var temp_a: PackedFloat32Array = _dc_views.get("temp", map.temp_arr) if _use_dc else map.temp_arr
     # ... 25 行同样模式
     ```
   - 涉及文件：`scripts/geography/map_generator.gd`
   - 涉及函数（精确行号见 requirements.md §0.1）：
     - `_climate_pass_a_soa` (line 3744) — 13 个数组（temp / moist / snow / dirty_mask / base_moist / elev / is_water / temp_baseline / temp_30d / temp_365d / temp_anom / cell_lat_norm / temp_baseline_year）
     - `_climate_pass_b_soa` (line 3970) — 7 个数组（temp / moist / snow / is_water / elev / temp_baseline / climate_dirty_mask）
     - `_ocean_water_pass_soa` (line 4179) — 6 个数组（temp / temp_baseline / elev / is_water / ocean_current_x / ocean_current_y）
     - `_ocean_land_pass_soa` (line 4257) — 6 个数组（同上）
   - 共 32 处取数行（含重复字段），改造后 git diff 应**仅**含这 32 行变化 + 各函数开头 2 行（`_dc_views` / `_use_dc` 声明）
   - _需求：Story 1.1, 1.2, 1.3, 1.5；非功能 2.2_

- [ ] **A-5. 烟测：手动开启灰度跑 30 day**
   - 启动时 console 打印：`[DataCore/climate] sub-pass path=data_core (n=25 components cached)`
   - 跑 30 game-day 后人眼看 `refresh_climate_daily ran=...` 日志没炸（无 push_error / push_warning 风暴）
   - 切回 legacy（F11 toggle off）继续跑 30 day，行为应完全一致
   - _需求：非功能 2.2, 2.4_

---

## B 阶段：双路径性能对比

> 目标：在 SUS 日志看到 climate path 标识，并跑 4 个 30-tick 窗口实测，验证 ≤105% 红线。

- [ ] **B-1. SUS 30-tick 汇总日志增加 `climate_path` 字段**
   - `main.gd` 输出 `refresh_climate_daily ran=... avg=...` 那行末尾追加：` path=<legacy|data_core>`
   - 实现位置：参考 weather 日志格式（`weather_refresh ... path=data_core`）
   - 单次 sub-pass 的 partial round breakdown（`A=4.1 B=5.8 ocean=6.9 ...`）行末同样追加 `path=...`
   - _需求：Story 2.1_

- [ ] **B-2. 30-tick × 4 窗口实测对比**
   - 同条件（earth_like preset，stride=1）跑 30 game-day，分别在 legacy 和 data_core 路径下抓 4 个 30-tick 汇总窗口
   - 记录指标到本文件 §C 阶段验收记录小节：
     - `refresh_climate_daily` avg / max / slices/round
     - `pass_a` / `pass_b` / `ocean` / `sea_ice` / `transp` 各段耗时
     - 是否触发 `frame_budget_exhausted`
   - _需求：非功能 2.1_

- [ ] **B-3. 性能验收**
   - DataCore 路径 avg ≤ Legacy avg × 105%
   - DataCore 路径 max ≤ Legacy max × 108%
   - 任意 sub-pass slice_ms ≤ 8ms（slice_budget）
   - 不通过 → 进入 B-4 优化；通过 → 跳到 C 阶段
   - _需求：非功能 2.1_

- [ ] **B-4. （仅在 B-3 不通过时执行）优化**
   - 嫌疑点 1：`_climate_views_from_world` 每次调用都查 `get_data_core_world()` / `data_core_ready()`，可考虑在 round 入口缓存到成员变量
   - 嫌疑点 2：Dictionary `.get(key, fallback)` 比直接字段访问慢，可改为 PackedArray 数组缓存（按 25 个槽位 index 取）
   - 嫌疑点 3：参考 weather C-01 优化经验（dirty short-circuit）
   - _需求：非功能 2.1_

---

## C 阶段：热键 + CLI + SOP

> 目标：让运维有完整的灰度推进 / 回滚手段，文档落盘。

- [ ] **C-1. F11 热键：切换 `use_data_core_climate`**
   - `main.gd` `_unhandled_input` 增加 F11 分支（参考 F9 / F10 的实现）
   - 切换时打印：`[DataCore] F11 toggle: use_data_core_climate=<true|false> (path=<...>)`
   - 注意：F11 切换后 climate 系统**不需要重建** —— 只是下一个 round 进入时取数路径不同；无 weather 那种 sync 桥接需求
   - _需求：Story 2.2, 2.3, 2.4_

- [x] ~~**C-2. CLI 参数 `--data-core-climate` / `--no-data-core-climate`**~~ **WONTFIX (2026-05-11)**
   - 用户决策：已有老性能数据，无需 CLI 启动开关做 A/B；F11 热键已足够覆盖运行期切换需求。
   - 影响：requirements.md Story 4 整条作废；`main.gd._parse_data_core_cli()` 不需要新增 climate 分支。
   - 回退路径仍然完整：F11（运行期）+ tres 默认值（永久）+ `_apply_data_core_cli_to_profile()` 中的依赖守卫（自动 enable use_data_core）。

- [ ] **C-3. SOP.md 增补 §3a "Climate 灰度推进流程" + §6a "Climate 回滚"**
   - §3a 内容：4 步 mermaid 流程图（默认 off → 灰度 on → 性能验收 → tres 默认 on）+ 每步必看 SUS 指标
   - §6a 内容：3 档回滚（轻度 F11 / 永久 CLI / 紧急回退默认值）
   - 增补到现有 [`SOP.md`](../dots-foundation-and-weather-migration/SOP.md) 末尾，不新建文件
   - _需求：Story 3.1, 3.2, 3.3_

---

## D 阶段：默认 turn-on + 收口

> 目标：所有验收过线后，默认开启，本计划 close-out。

- [ ] **D-1. `earth_like.tres` 默认开启**
   - 在 `data/world/earth_like.tres` `use_data_core_weather = true` 后追加：
     ```
     use_data_core_climate = true
     ```
   - _需求：验收门槛 5_

- [ ] **D-2. 收口验证**
   - 重新启动游戏（不带任何 CLI 参数），观察 SUS 日志 `path=data_core` 持续显示
   - 跑 30 game-day，性能指标稳定在 ≤105%
   - F11 切到 legacy 再切回，行为正常
   - 在本文件追加 D 阶段验收记录小节
   - _需求：验收门槛 1~6 全过_

- [ ] **D-3. 计划 close-out**
   - 在本文件末尾打 ✅ 完成标记
   - 不再开新阶段；下一阶段（如 ocean_currents 迁移、weather_system 内层 SoA 化、C++/GDExtension）开新计划目录

---

## A 阶段验收记录（待补）

> 完成 A-5 后填入。

| 项目 | 状态 |
|---|---|
| `use_data_core_climate` 字段就位 | ⬜ |
| 25 个 comp_id 缓存就位 | ⬜ |
| 4 个 sub-pass 取数入口分支化 | ⬜ |
| 引用一致性 assert 通过 | ⬜ |
| 30-day 灰度烟测无 push_error | ⬜ |

---

## B 阶段验收记录（待补）

> 完成 B-3 后填入。

### B-2：30-tick × 4 窗口对比表

| 指标 | Legacy 路径 | DataCore 路径 | 差值 | 验收阈值 |
|---|---|---|---|---|
| `refresh_climate_daily` avg | TBD ms | TBD ms | TBD% | ≤105% |
| `refresh_climate_daily` max | TBD ms | TBD ms | TBD% | ≤108% |
| `pass_a` avg | TBD | TBD | TBD% | — |
| `pass_b` avg | TBD | TBD | TBD% | — |
| `ocean_water+ocean_land` avg | TBD | TBD | TBD% | — |
| `sea_ice` avg | TBD | TBD | TBD% | — |
| `transp` avg | TBD | TBD | TBD% | — |
| frame_budget_exhausted 次数 | TBD | TBD | — | 持平 |

---

## C / D 阶段交付记录（待补）

> 完成 C-3 / D-2 后填入。

---

## 风险登记表

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| `view_f32` 返回引用与 `map.xxx_arr` 不一致 | 低 | 高（数值会跑飞）| A-2 引用一致性 assert，失败强制关闭开关 |
| 性能不达标 | 中 | 中 | B-4 备选优化点；最坏退回到 C 阶段决策（保留开关默认 off）|
| `_world.is_bound() = false` 的 race condition | 低 | 低 | sub-pass fallback 到 legacy + push_warning |
| 用户期望 climate 加速但实际没加速 | 高 | 低 | requirements §0.2 已明确 climate 迁移**不带性能收益**，仅为 C++ 化扫前置 |
