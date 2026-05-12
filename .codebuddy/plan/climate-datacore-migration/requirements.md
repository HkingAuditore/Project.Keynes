# Climate → DataCore 迁移：需求规格

> 本计划为 [`dots-foundation-and-weather-migration`](../dots-foundation-and-weather-migration/) 之后的 **E 阶段**独立计划。
> 上一计划于 2026-05-11 close-out，weather_refresh 性能 +8%（≤110% 红线）✅、行为对照 PASS ✅、SOP 落盘 ✅。
> 本计划的目标是把 `refresh_climate_daily`（当前 ~10ms 大头）也迁到 DataCore，**统一所有 hot path 的数据访问入口**，
> 为最终目标（C++/GDExtension 接管 hot loop）扫清"case-by-case 桥接 MapData 字段"的杂活。

---

## 0. 上下文与基础事实（侦察结论）

### 0.1 已经就位的能力（无需重做）

| 项目 | 状态 | 来源 |
|---|---|---|
| `DCWorld.bind_map_data()` | ✅ | `dots-foundation-and-weather-migration` 任务 4 |
| 25 个 cell-level component（CELL_TEMP / CELL_MOISTURE / ...） | ✅ 已注册 | `scripts/data_core/component_ids.gd` |
| `topology.hex_neighbors` | ✅ | 同上 |
| `use_soa_pipeline = true` | ✅ 默认开 | `data/world/earth_like.tres` |
| `use_sparse_climate = true` | ✅ 默认开 | 同上 |
| 4 个 SoA sub-pass（`_climate_pass_a_soa` / `_b_soa` / `_ocean_water_pass_soa` / `_ocean_land_pass_soa`）| ✅ | `scripts/geography/map_generator.gd` |
| `RefreshClimateDailyJob` 6-段切片调度 | ✅ | `scripts/simulation/sus/jobs/refresh_climate_daily_job.gd` |
| F9 / F10 灰度切换基础设施 | ✅ | `dots-foundation-and-weather-migration` D-02 |
| `--validate-weather` 框架 | ✅ | 同上 D-01 |

### 0.2 climate 与 weather 迁移的本质区别

| 维度 | weather（已完成）| climate（本计划）|
|---|---|---|
| 新增 component 数量 | 8 个 front-level | **0**（cell-level 已全部注册）|
| 新增 archetype | `ARCH_WEATHER_FRONT` | **0**（climate 都是 cell-level）|
| 是否需要 CommandBuffer | ✅（front spawn/destroy）| ❌（无结构性变更）|
| 桥接逻辑（类似 `sync_fronts_to_world`）| ✅ 复杂 | ❌ 不需要 |
| 内层循环改造 | hot loop 仍走 AoS HexCell | **已经是 PackedArray 直读**（C-02 备注确认）|
| **本质工作量** | 结构性变更 + 桥接 | **数组取数入口替换**（`map.temp_arr` → `_world.view_f32(...)`）|
| 历史回归（迁移后）| +39% → 优化到 +8% | **预期 ≤5%**（仅多一次方法调用 vs 直接字段访问）|

### 0.3 用户决策范围

- ✅ 迁移过来即可，**不做行为对照**（`--validate-climate`）—— climate SoA 内层已稳定，迁移只换数组来源，数值不变
- ✅ 性能对比保留 —— 验证迁移没引入回归
- ✅ 灰度开关 + 热键保留 —— 万一炸了能切回 legacy
- ✅ 默认值策略：完成迁移 + 性能验收过线后，`earth_like.tres` 默认开启

---

## 1. 功能需求（用户故事）

### Story 1：作为 climate 系统维护者，我要让 4 个 SoA sub-pass 的数组取数入口走 DCWorld

**理由**：统一数据访问入口，让未来 C++ 接管时只需要桥一个 World，不用逐个桥接 MapData 的 25 个 PackedArray 字段。

**验收标准（EARS）**：
1. WHEN `ClimateProfile.use_data_core_climate = true` 且 `_world.is_bound() = true`，THEN `_climate_pass_a_soa` / `_b_soa` / `_ocean_water_pass_soa` / `_ocean_land_pass_soa` 内 25 个 `var xxx_a = map.xxx_arr` 取数行 SHALL 改为 `var xxx_a = _world.view_f32/u8/i32(comp_id_xxx)`
2. WHEN `use_data_core_climate = false`，THEN 4 个 sub-pass SHALL 完全走 legacy 路径（即当前 `map.xxx_arr` 行为，零回退风险）
3. WHEN `_world.is_bound() = false` 但 `use_data_core_climate = true`，THEN sub-pass SHALL 自动 fallback 到 legacy 路径并 push_warning（不致命）
4. THE component_id 缓存 SHALL 在 `_on_world_bound` 回调中一次性完成，hot path 内不重复 `_world.component_id(StringName)` 查找
5. THE `view_f32 / view_u8 / view_i32` 调用 SHALL 在循环外取一次本地引用，hot loop 内仍是 `arr[i]` 索引（杜绝 weather B-04 那种"循环内反射"踩坑）

### Story 2：作为性能负责人，我要在 SUS 日志看到 climate path 标识 + 双路径性能对比

**理由**：和 weather 一样，需要可观测才能验收。

**验收标准（EARS）**：
1. WHEN SUS 30-tick 汇总日志输出 `refresh_climate_daily` 行时，THEN 日志末尾 SHALL 追加 `path=data_core` 或 `path=legacy`
2. WHEN 用户按 F11 时，THEN `ClimateProfile.use_data_core_climate` SHALL 切换并打印 `[DataCore] F11 toggle: use_data_core_climate=<true|false> (path=<...>)`
3. THE F11 toggle SHALL 不与 F9（weather path）互相干扰，两个开关独立
4. THE F11 toggle 处理 SHALL `<= 1ms`（不阻塞主线程）

### Story 3：作为运维，我要明确的灰度推进路径和回滚 SOP

**理由**：weather 上线时 SOP 救过命，climate 同样需要。

**验收标准（EARS）**：
1. THE 现有 `dots-foundation-and-weather-migration/SOP.md` SHALL 增补 §3a "Climate 灰度推进流程" + §6a "Climate 回滚"
2. THE SOP SHALL 描述 4 个推进 step（默认 off → 灰度 on → 性能验收 → tres 默认 on）
3. THE SOP SHALL 列出 F11（运行期）/ tres `use_data_core_climate`（永久）两种开关入口的优先级；CLI 入口已 WONTFIX 不在 SOP 中描述

### Story 4：~~作为开发者，我要命令行能强制开关 climate path~~ **WONTFIX (2026-05-11)**

**用户决策**：已有老性能数据，CLI A/B 启动开关无价值；F11 热键已覆盖运行期切换需求；tres 默认值已覆盖永久开关需求。原 Story 4 全部 EARS 标准作废。

回滚路径仍然完整：
- 运行期：F11 toggle
- 永久：修改 `data/world/earth_like.tres` 中 `use_data_core_climate`
- 紧急回退：`use_data_core = false` 也会自动连带禁用（依赖守卫已就位）

---

## 2. 非功能需求

### 2.1 性能（验收红线）

| 指标 | Legacy 基线 | DataCore 路径目标 | 红线 |
|---|---|---|---|
| `refresh_climate_daily` avg | ~10ms | ≤10.5ms | **≤105%**（比 weather 的 110% 收紧）|
| `refresh_climate_daily` max | ~14ms | ≤15ms | ≤108% |
| `refresh_climate_daily` slices/round | 6（4 个执行 + 2 个 skip）| 6 | 持平 |
| 单 sub-pass slice_ms | ≤8ms（slice_budget）| ≤8ms | 持平 |

> **红线收紧理由**：climate 迁移仅换数组取数入口，无新增桥接逻辑（vs weather B-04 的 `sync_fronts_to_world`），理论开销几乎为零；多出来的成本仅来自 `view_f32` 方法调用（vs 直接字段访问），单次约 100~200ns，per round 25 次取数 = ≤5μs，相对 ~10ms 总耗时 < 0.05%。

### 2.2 行为零回归

- 既然不做 `--validate-climate`，则要求"代码层面 100% 等价"：
  1. `view_f32(_comp_cell_temp)` 返回的 `PackedFloat32Array` 必须和 `map.temp_arr` **是同一个底层数组的引用**（`bind_map_data` 已保证）
  2. 4 个 SoA sub-pass 内层循环代码不动，仅替换取数入口（diff 应只有声明行变化）
  3. dirty mask / sparse path / EMA 等逻辑分支保持原样

### 2.3 可观测性

- SUS 日志 / F12 快照保持现有格式 + `climate_path` 字段
- 日志噪声不增加（仅在 path 切换时打印一行）

### 2.4 风险与回滚

| 风险 | 缓解 |
|---|---|
| `view_f32` 返回的引用与 `map.xxx_arr` 不一致 | 在 `_on_world_bound` 中 assert：`_world.view_f32(_comp_cell_temp) is map.temp_arr` 失败则 push_error 并强制 use_data_core_climate=false |
| `_world.is_bound()` 在某些 reload 场景下 false | sub-pass 入口 fallback 到 legacy；只 push_warning 不 push_error |
| 性能反向回归（极端情况）| F11 实时切回 legacy；CLI `--no-data-core-climate` 永久切回；任务 D 完成 tres 默认 on 之前不修改默认值 |

---

## 3. 不在本计划范围内（明确排除）

| 项目 | 理由 |
|---|---|
| 行为对照测试 `--validate-climate` | **用户明确要求跳过** —— climate SoA 内层已稳定，迁移仅换数组来源，数值不变 |
| ClimateProfile 内部参数（true_insolation_enabled / season_temp_amp 等）逻辑变更 | 本计划只迁数据通道，不动算法 |
| `_climate_pass_a` / `_b` legacy（非 SoA）路径迁移 | legacy 路径仅在 `use_soa_pipeline = false` 时启用，已是冷路径，不值得迁移 |
| ocean_currents（`OceanCurrentsJob`）迁移 | 独立 Job，不属于 `refresh_climate_daily` 6 段切片范围；下一计划再说 |
| sea_ice_atlas_upload 迁移 | GPU 上传 Job，与本计划数据通道无关 |
| C++/GDExtension 接管 hot loop | 终极目标，本计划是为它扫清前置条件，但本计划不做 |
| weather_system 内部 SoA 化（C-02.1 / .2 那两条遗留） | 不属于"climate 迁移"范畴 |

---

## 4. 验收门槛（出口标准）

完成本计划需同时满足：

1. ✅ Story 1~4 全部 EARS 验收标准达成
2. ✅ §2.1 性能红线 ≤105% 过线（4 个 30-tick 窗口实测）
3. ✅ `_climate_pass_a/b/ocean_water/ocean_land_soa` 4 个函数 git diff 仅取数行变化（行为零回归基础保证）
4. ✅ SOP.md 增补 §3a / §6a 落盘
5. ✅ tres 默认 `use_data_core_climate = true`（验收过线后开启）
6. ✅ 现有所有 SUS 日志 / F9 / F12 行为不受影响

---

## 5. 时间预估

| 阶段 | 预估 |
|---|---|
| Phase A：最小迁移（取数入口替换）| 2~3 天 |
| Phase B：双路径性能对比 | 1 天 |
| Phase C：F11 + CLI + SOP | 0.5 天 |
| Phase D：默认 turn-on + 收口 | 0.5 天 |
| **合计** | **4~5 天** |

> 比 weather 计划（~2 周）短得多，因为没有结构性变更和桥接逻辑。
