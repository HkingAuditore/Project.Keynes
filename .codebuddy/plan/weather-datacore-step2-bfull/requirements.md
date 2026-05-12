# Weather DataCore Step-2 · B-full：Hot Loop 全 view_f32 化

> **Plan ID**：`weather-datacore-step2-bfull`
> **状态**：DRAFT（待执行）
> **创建时间**：2026-05-11
> **依赖**：`dots-foundation-and-weather-migration`（Step-1 已完成：front 镜像 + cell weather 4 个 component 已挂入 World）
> **后续**：`dots-roadmap-to-gdextension`（GDExtension 阶段会复用本步骤铺好的 SoA 通道）
> **预计工程量**：2 - 2.5 天（一刀切方案，不分批）

---

## 0. 背景与决策依据

Step-1 完成后，weather hot loop（`weather_system.run_weather_field_solve_slice` /
`begin_weather_field_solve` / `commit_weather_field_solve`）仍然走 **AoS 路径**：
通过 `cell.temperature` / `cell.moisture` / `cell.air_mass_temp_anomaly` 等
HexCell 强类型成员访问数据。这意味着：

1. **DataCore 通道不闭合**：cell-level component 已挂入 World，但 weather hot
   loop 不读 view_f32，导致 DataCore 路径上 weather 这一段是"挂着没用"。
2. **GDExtension 移植路上的脏路径**：未来要把 weather hot loop 搬到 C++，
   必须先让 GDScript 端走 view_f32（无论拷贝还是镜像），C++ 才能直接拿到
   `PackedFloat32Array.ptrw()` 而不必反射 HexCell 字段。
3. **B-1 / B-2 的预拷贝循环冗余**：`begin_weather_field_solve` 里
   `_field_slice_prev_vapor[i] = prev_cell.weather_vapor` 这种循环本质上
   是把 AoS → 临时 PackedArray，B-full 后 `weather_vapor` 已经是 SoA，
   直接 view_f32 即可，预拷贝循环消失。

**Review 中的对应问题**：P0-② 的"weather hot loop 仍走 AoS"。

**用户决策**：
- 方案选择：**B-full（一刀切）** —— 6 个新 component + 6 个 SoA 字段一次到位
- 工程量预算：2 - 2.5 天（已接受）
- CLI 开关：复用 `--data-core` / `--no-data-core` 主开关；不再单独加
  `--data-core-weather-field`（用户已有性能基线数据，无需 A/B 对比）

---

## 1. 范围（What）

### 1.1 In Scope

#### 新增 6 个 cell-level component（DCComponentIds）
| 常量名 | StringName | dtype | 写入侧 | 读取侧 |
|---|---|---|---|---|
| `CELL_WEATHER_VAPOR` | `cell.weather_vapor` | F32 | weather commit | weather hot loop（prev/curr） |
| `CELL_WEATHER_CONVERGENCE` | `cell.weather_convergence` | F32 | weather commit | weather hot loop（curr） |
| `CELL_WEATHER_INSTABILITY` | `cell.weather_instability` | F32 | weather commit | weather hot loop（curr） |
| `CELL_WEATHER_FIELD_INIT` | `cell.weather_field_init` | U8（0/1） | weather commit | weather hot loop + map_baker + data_overlay_baker + main.gd |
| `CELL_AIR_MASS_TEMP_ANOMALY` | `cell.air_mass_temp_anomaly` | F32 | climate pass（map_generator）| weather hot loop |
| `CELL_HAS_RIVER` | `cell.has_river` | U8（0/1） | map_generator（地图生成期一次）| weather hot loop + map_baker + main.gd（feats） |

#### 新增 6 个 MapData SoA 字段
- `weather_vapor_arr: PackedFloat32Array`
- `weather_convergence_arr: PackedFloat32Array`
- `weather_instability_arr: PackedFloat32Array`
- `weather_field_init_arr: PackedByteArray`（0/1）
- `air_mass_temp_anomaly_arr: PackedFloat32Array`
- `has_river_arr: PackedByteArray`（0/1）

#### 修改 `world.bind_map_data`：新增 7 个 attach 行
6 个新 component + 1 个补漏（`CELL_TERRAIN`，原本声明了但 `bind_map_data` 漏挂）。

#### 修改 `MapData.rebuild_soa_from_cells` / `flush_soa_to_cells` / `_alloc_soa`
- `_alloc_soa`：新增 6 行 resize
- `rebuild_soa_from_cells`：新增 6 行 AoS → SoA 镜像
- `flush_soa_to_cells`：weather 4 个浮点 + bool init 写回 HexCell；
  `air_mass_temp_anomaly / has_river` **不写回**（运行期 SoA 是权威；HexCell
  字段保留作为旧 AoS 路径 fallback，但 DataCore 路径下读 SoA）

#### 修改 `weather_refresh_job._on_world_bound`
- 新增 6 个 comp_id 缓存
- `data_core_ready()` 检查范围扩展到 6 个新 comp_id

#### 修改 `weather_system` 三段式 hot loop
- `begin_weather_field_solve`：删除 prev_vapor / prev_precip 预拷贝循环（直接拿 view_f32 prev 切片）
- `run_weather_field_solve_slice`：cell-loop 内 11 处 `cell.xxx` → `view_xxx[i]`
- `commit_weather_field_solve`：write 端补齐 6 个新 SoA 镜像（替代或并行 HexCell 写）

#### 修改 `map_generator` 的 air_mass_temp_anomaly 写入（climate pass）
当 DataCore enabled 时，`cell.air_mass_temp_anomaly = ...` 旁加一行
`view_f32(CELL_AIR_MASS_TEMP_ANOMALY)[i] = ...`（单字段写出，开销极低）。
保留 AoS 写入以兼容 fallback。

#### 修改 `map_generator` 的 has_river 写入（地图生成期）
仅在 `bind_map_data` 之后做一次性 SoA 镜像（`rebuild_soa_from_cells` 已覆盖）。
运行期 has_river 不变，无热路径成本。

### 1.2 Out of Scope

- ❌ **不做** GDExtension 移植（那是下一阶段 plan：`dots-roadmap-to-gdextension`）
- ❌ **不做** weather 三段式 → SUS sub-pass 化重构（与本步骤无关，保留现状）
- ❌ **不做** front-level component 扩展（Step-1 已完成 8 个 front 字段镜像）
- ❌ **不做** `weather_system.gd` 主体逻辑改写——只换数据访问入口，算法零改动
- ❌ **不加 CLI 开关**：复用 `--data-core`，不需要单独的 `--data-core-weather-field`
- ❌ **不**把 `temperature_transport_anomaly` 纳入 SoA / component。这个字段由
  climate ocean heat transport pass 写入，归 `climate-datacore-migration` 的
  ocean pass 改造范畴。本 plan 仅在 `_avg_ocean_anomaly_at_idx` helper 中保留
  对它的 AoS 访问；helper 接收 `cells: Array` 不变。weather hot loop 主体
  （cell-loop body + `_apply_frontal_convergence_boost`）的其它 16 处字段
  访问全部走 SoA。这是本 plan 的精确边界。

---

## 2. 验收标准（Acceptance Criteria）

### 2.1 行为不回归
- `--data-core=false`（legacy 路径）：所有数值与 Step-1 完全一致（哈希不变）
- `--data-core=true`：weather hot loop 数值与 legacy 路径**逐位等价**（误差 ≤ 1e-6）
- `ab_test.gd` 跑 30 天，climate / weather 各 pass 末尾的 SoA 哈希在
  legacy / DataCore 两条路径下一致

### 2.2 性能不劣化
- weather field solve 总耗时（30 天平均）DataCore 路径 ≤ legacy 路径 × 1.05
  （允许 5% 噪声）
- prev_vapor / prev_precip 预拷贝循环消失（profiler 中
  `_field_slice_prev_vapor` 调用栈占比 → 0）

### 2.3 接口一致性
- `view_f32(CELL_WEATHER_VAPOR)` 与 `MapData.weather_vapor_arr` **同引用**
  （`is_same(a, b)` true，与现有 25 个 component 一致）
- `weather_refresh_job.data_core_ready()` 在 6 个新 comp_id 全 ≥ 0 时才返回 true

### 2.4 fallback 健壮
- `--data-core=false`：weather 三段式自动走 AoS 路径，零 push_error
- `--data-core=true` 但某个 comp_id < 0（异常分支）：fallback 到 AoS，
  push_warning 一次（不刷屏）

### 2.5 渲染端兼容
- `map_baker` / `data_overlay_baker` / `main.gd` / `data_overlay_baker` 等
  读 `cell.weather_field_initialized` 的位置，行为不变（`flush_soa_to_cells`
  保证 HexCell 字段在 round 末与 SoA 一致）

---

## 3. 风险与缓解

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| `flush_soa_to_cells` 漏写 6 个新字段中某一个 → renderer 读到旧值 | 中 | 高 | task-item Step-3 强制 grep 全工程 `weather_vapor / convergence / instability / field_initialized / air_mass_temp_anomaly / has_river` 的所有 reader，逐一确认 flush 覆盖 |
| `weather_field_init` bool → u8 → bool 转换错位 | 低 | 高 | 统一约定：SoA 用 0/1 byte；reader 写 `> 0` 判断；flush 时 `c.weather_field_initialized = (arr[i] > 0)` |
| `air_mass_temp_anomaly` 在 climate pass 写但未在 DataCore 路径下镜像 → weather 读到旧 anomaly | 中 | 高 | task-item Step-4 在 `map_generator._climate_pass_b` 末尾加 SoA 写出（条件 DataCore enabled）|
| `has_river` 在地图生成期之后被 `_river_filter_pass` 二次修改 → SoA 与 AoS 漂移 | 低 | 中 | 在所有 `cell.has_river = ...` 写入点加 `if data_core_enabled: has_river_arr[i] = ...` 或在所有写入完成后调一次 `rebuild_soa_from_cells()` |
| weather_refresh_job 的 prev/curr 双缓冲与 weather_vapor / weather_precip 不一致（precip 已是 SoA 但 vapor/convergence/instability 是新加的） | 中 | 中 | 6 个新字段统一在 `_alloc_soa` 中 resize 但**不开 _prev 双缓冲**；hot loop 用切片局部数组当 prev（保持现有切片语义） |
| 渲染端在 round 末读 `cell.xxx`，但 SoA 还没 flush 回 HexCell | 低 | 中 | weather commit 末尾必须先 SoA 写完再 flush_soa_to_cells（已有调度顺序无需改）|

---

## 4. 关联文档

- 上游：`.codebuddy/plan/dots-foundation-and-weather-migration/requirements.md`
  （Step-1 完成情况）
- 上游：`.codebuddy/plan/climate-datacore-migration/requirements.md`（climate
  hot loop 已完成 view_f32 化的范本，本步骤复用相同模式）
- 下游：`.codebuddy/plan/dots-roadmap-to-gdextension/architecture.md`（本步骤
  铺好的 SoA 通道是 GDExtension 阶段的入口）

---

## 5. 完工后状态（Definition of Done）

执行完毕后，DataCore enabled 路径下：

1. ✅ Climate 4 个 SoA sub-pass 全走 view_f32（climate-datacore-migration 已完成）
2. ✅ Weather front 镜像走 query API（Step-1 已完成）
3. ✅ **Weather hot loop 全走 view_f32（本 plan 完成）** ← New
4. ⏸️ GDExtension 移植（下个 plan）
5. ⏸️ Sub-pass 化 weather 三段式（更下个 plan）

到 5 完成时，整个 climate + weather hot path 都已是 SoA + DataCore，
GDExtension 可以无缝接管。
