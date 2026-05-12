# Weather DataCore Step-2 · B-full · Task Items

> Plan：`weather-datacore-step2-bfull`
> 配套文档：[`requirements.md`](./requirements.md)
> 执行风格：**精确到文件 + 行号**；每个 Step 完成后必须 `cargo check` 等价
> 验证（GDScript 端为 `--check-only` + ab_test diff）

---

## Step 1：DataCore 基础设施（component 声明 + SoA 字段 + bind_map_data 挂入）

> 时间预算：4 小时

### 1.1 `scripts/data_core/component_ids.gd`
在 Cell-level 内置 component 区段（约第 39-69 行附近）末尾新增 6 个常量：

```gdscript
const CELL_WEATHER_VAPOR: StringName = &"cell.weather_vapor"
const CELL_WEATHER_CONVERGENCE: StringName = &"cell.weather_convergence"
const CELL_WEATHER_INSTABILITY: StringName = &"cell.weather_instability"
const CELL_WEATHER_FIELD_INIT: StringName = &"cell.weather_field_init"
const CELL_AIR_MASS_TEMP_ANOMALY: StringName = &"cell.air_mass_temp_anomaly"
const CELL_HAS_RIVER: StringName = &"cell.has_river"
```

### 1.2 `scripts/geography/map_data.gd`

#### 1.2.1 字段声明（约第 60-95 行附近，按现有分组插入）
- 在 weather_intensity_arr / weather_cloud_arr / weather_precip_arr 附近新增：
  ```gdscript
  var weather_vapor_arr:        PackedFloat32Array = PackedFloat32Array()
  var weather_convergence_arr:  PackedFloat32Array = PackedFloat32Array()
  var weather_instability_arr:  PackedFloat32Array = PackedFloat32Array()
  var weather_field_init_arr:   PackedByteArray   = PackedByteArray()
  ```
- 在 temp_anomaly_arr 附近新增：
  ```gdscript
  var air_mass_temp_anomaly_arr: PackedFloat32Array = PackedFloat32Array()
  ```
- 在 is_water_arr 附近新增：
  ```gdscript
  var has_river_arr:            PackedByteArray   = PackedByteArray()
  ```

#### 1.2.2 `_alloc_soa()`（约第 239-269 行）
新增 6 行 resize：
```gdscript
weather_vapor_arr.resize(n)
weather_convergence_arr.resize(n)
weather_instability_arr.resize(n)
weather_field_init_arr.resize(n)
air_mass_temp_anomaly_arr.resize(n)
has_river_arr.resize(n)
```

#### 1.2.3 `rebuild_soa_from_cells()`（约第 274-316 行）
在 cell-loop 末尾（写完所有标量字段后）补：
```gdscript
weather_vapor_arr[i] = c.weather_vapor
weather_convergence_arr[i] = c.weather_convergence
weather_instability_arr[i] = c.weather_instability
weather_field_init_arr[i] = (1 if c.weather_field_initialized else 0)
air_mass_temp_anomaly_arr[i] = c.air_mass_temp_anomaly
has_river_arr[i] = (1 if c.has_river else 0)
```

#### 1.2.4 `flush_soa_to_cells()`（约第 320-345 行）
在 weather_precip 写回行之后补：
```gdscript
c.weather_vapor = weather_vapor_arr[i]
c.weather_convergence = weather_convergence_arr[i]
c.weather_instability = weather_instability_arr[i]
c.weather_field_initialized = (weather_field_init_arr[i] > 0)
```
**`air_mass_temp_anomaly` / `has_river` 不写回**（运行期不会从 SoA 反向写回 AoS；
HexCell 字段在地图生成 / climate pass 时已被独立写入）。

### 1.3 `scripts/data_core/world.gd` · `bind_map_data`（约第 466-486 行）
在现有 21 行 attach 之后新增 7 行：

```gdscript
# 补漏：原 21 行漏挂的 CELL_TERRAIN
_bind_register_and_attach(DCComponentIds.CELL_TERRAIN, DCComponentIds.U8, false, map_data.terrain_arr)
# B-full 新增 6 个
_bind_register_and_attach(DCComponentIds.CELL_WEATHER_VAPOR, DCComponentIds.F32, false, map_data.weather_vapor_arr)
_bind_register_and_attach(DCComponentIds.CELL_WEATHER_CONVERGENCE, DCComponentIds.F32, false, map_data.weather_convergence_arr)
_bind_register_and_attach(DCComponentIds.CELL_WEATHER_INSTABILITY, DCComponentIds.F32, false, map_data.weather_instability_arr)
_bind_register_and_attach(DCComponentIds.CELL_WEATHER_FIELD_INIT, DCComponentIds.U8, false, map_data.weather_field_init_arr)
_bind_register_and_attach(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY, DCComponentIds.F32, false, map_data.air_mass_temp_anomaly_arr)
_bind_register_and_attach(DCComponentIds.CELL_HAS_RIVER, DCComponentIds.U8, false, map_data.has_river_arr)
```

### 1.4 验证（Step-1 完工标准）
- 启动游戏（`--data-core=true`）→ 无 push_error
- 第 1 帧 SUS 注入完成后，`world.component_id(CELL_WEATHER_VAPOR) >= 0`
- `is_same(world.view_f32(comp_id), map_data.weather_vapor_arr) == true`

---

## Step 2：Weather Refresh Job 注册 6 个新 comp_id

> 时间预算：1 小时

### 2.1 `scripts/simulation/sus/jobs/weather_refresh_job.gd`

#### 2.1.1 字段声明区（cell-level 缓存区，约第 81-92 行）
新增 6 行：
```gdscript
var _comp_cell_weather_vapor: int = -1
var _comp_cell_weather_convergence: int = -1
var _comp_cell_weather_instability: int = -1
var _comp_cell_weather_field_init: int = -1
var _comp_cell_air_mass_temp_anomaly: int = -1
var _comp_cell_has_river: int = -1
```

#### 2.1.2 `_on_world_bound()`（约第 110-145 行）
在原 4 行 cell-level component_id() 缓存之后新增 6 行：
```gdscript
_comp_cell_weather_vapor = _world.component_id(DCComponentIds.CELL_WEATHER_VAPOR)
_comp_cell_weather_convergence = _world.component_id(DCComponentIds.CELL_WEATHER_CONVERGENCE)
_comp_cell_weather_instability = _world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
_comp_cell_weather_field_init = _world.component_id(DCComponentIds.CELL_WEATHER_FIELD_INIT)
_comp_cell_air_mass_temp_anomaly = _world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
_comp_cell_has_river = _world.component_id(DCComponentIds.CELL_HAS_RIVER)
```

#### 2.1.3 `data_core_ready()`（约第 148-152 行）
扩展返回值条件：
```gdscript
return _data_core_components_ready and _world != null and _world.is_bound() \
    and _comp_cell_intensity >= 0 and _comp_front_pos_x >= 0 \
    and _comp_cell_weather_vapor >= 0 and _comp_cell_weather_convergence >= 0 \
    and _comp_cell_weather_instability >= 0 and _comp_cell_weather_field_init >= 0 \
    and _comp_cell_air_mass_temp_anomaly >= 0 and _comp_cell_has_river >= 0
```

### 2.2 提供 view-getter 给 weather_system 调用

在 `weather_refresh_job.gd` 末尾新增便捷接口（避免 weather_system 直接持有
`_world` 字段，保持调用链清晰）：

```gdscript
## DataCore step-2：把 6 个新 cell view 一次性打包返回，weather_system
## 在 begin / run_slice / commit 入口取一次即可，避免反复查 comp_id。
func data_core_views() -> Dictionary:
    if not data_core_ready():
        return {}
    return {
        "vapor": _world.view_f32(_comp_cell_weather_vapor),
        "convergence": _world.view_f32(_comp_cell_weather_convergence),
        "instability": _world.view_f32(_comp_cell_weather_instability),
        "field_init": _world.view_u8(_comp_cell_weather_field_init),
        "air_anomaly": _world.view_f32(_comp_cell_air_mass_temp_anomaly),
        "has_river": _world.view_u8(_comp_cell_has_river),
        # 顺便把 step-1 已挂入的 4 个也带出去，weather_system 一次取齐
        "intensity": _world.view_f32(_comp_cell_intensity),
        "cloud": _world.view_f32(_comp_cell_cloud),
        "precip": _world.view_f32(_comp_cell_precip),
        "wtype": _world.view_u8(_comp_cell_type),
        # climate pass 写、weather hot loop 读的 7 个
        "temp": _world.view_f32(_world.component_id(DCComponentIds.CELL_TEMP)),
        "moisture": _world.view_f32(_world.component_id(DCComponentIds.CELL_MOISTURE)),
        "wind_x": _world.view_f32(_world.component_id(DCComponentIds.CELL_WIND_X)),
        "wind_y": _world.view_f32(_world.component_id(DCComponentIds.CELL_WIND_Y)),
        "elevation": _world.view_f32(_world.component_id(DCComponentIds.CELL_ELEVATION)),
        "terrain": _world.view_u8(_world.component_id(DCComponentIds.CELL_TERRAIN)),
        "snow_cover": _world.view_f32(_world.component_id(DCComponentIds.CELL_SNOW_COVER)),
    }
```

> 注：`view_u8` / `view_f32` 是 DCWorld 的现成 API；如果 climate pass 已经
> 缓存了 temp/moisture comp_id，weather_system 也可以从 climate_job 取，
> 避免重复查找。**优先用 weather_refresh_job 自己缓存全套**，调用链清晰。

### 2.3 验证
- ab_test 启动 → `data_core_ready()` 返回 true
- `data_core_views()` 返回 17 项，每项 size == cell_count

---

## Step 3：Weather System Hot Loop view_f32 化（核心改动）

> 时间预算：6 - 8 小时（**最大、最容易踩坑的一步**）

### 3.1 `scripts/weather/weather_system.gd · begin_weather_field_solve`

#### 3.1.1 删除 prev 预拷贝循环（约第 595-605 行）
**原代码**：
```gdscript
for i in range(n):
    var prev_cell: HexCell = ...
    _field_slice_prev_vapor[i] = prev_cell.weather_vapor if prev_cell.weather_field_initialized else prev_cell.moisture
    _field_slice_prev_precip[i] = prev_cell.weather_precip if prev_cell.weather_field_initialized else 0.0
```

**改为**：
- DataCore enabled：直接拿 view 的快照（`vapor.duplicate()` 或在
  field_init==0 的位置 fallback 到 moisture）
- DataCore disabled：保留原 AoS 循环

伪代码：
```gdscript
var dc_enabled: bool = _is_dc_field_enabled()  # 见 3.4
if dc_enabled:
    var v: Dictionary = _refresh_job.data_core_views()
    # vapor[i] 在 init==0 时无效；用 moisture 兜底
    var n: int = v.vapor.size()
    _field_slice_prev_vapor.resize(n)
    _field_slice_prev_precip.resize(n)
    for i in range(n):  # 这个循环虽然还在，但比原 AoS 循环少一半字段访问
        if v.field_init[i] > 0:
            _field_slice_prev_vapor[i] = v.vapor[i]
            _field_slice_prev_precip[i] = v.precip[i]
        else:
            _field_slice_prev_vapor[i] = v.moisture[i]
            _field_slice_prev_precip[i] = 0.0
else:
    # 原 AoS 路径保留
    ...
```

> **注意**：B-1 的"消除 prev 预拷贝循环"在严格意义上无法做到——`run_slice`
> 会在多 tick 中分批读 prev，一旦 commit 把 vapor 写新值，prev 就丢了。
> 因此 prev 必须是 begin 时的快照拷贝。但 DataCore 路径下这个拷贝是
> view_f32.duplicate() 一次性拷贝，比 AoS 字段访问每个 cell 都要快。

#### 3.1.2 同样处理第 850-862 行的另一处 prev 预拷贝（`prev_vapor[i]` / `prev_precip[i]` 局部数组版本）

### 3.2 `scripts/weather/weather_system.gd · run_weather_field_solve_slice`

#### 3.2.1 cell-loop 入口取一次 view（约第 620-660 行循环外）
```gdscript
var dc_enabled: bool = _is_dc_field_enabled()
var v: Dictionary = _refresh_job.data_core_views() if dc_enabled else {}
```

#### 3.2.2 cell-loop 内字段访问替换（11 处）
| 原写法 | DataCore 写法 |
|---|---|
| `cell.temperature` | `v.temp[i]` |
| `cell.air_mass_temp_anomaly` | `v.air_anomaly[i]` |
| `cell.moisture` | `v.moisture[i]` |
| `cell.wind_vector.x / y` | `v.wind_x[i]` / `v.wind_y[i]` |
| `cell.elevation` | `v.elevation[i]` |
| `cell.terrain` | `int(v.terrain[i])` |
| `cell.has_river` | `v.has_river[i] > 0` |
| `cell.weather_convergence` | `v.convergence[i]` |
| `cell.weather_instability` | `v.instability[i]` |
| `cell.weather_field_initialized` | `v.field_init[i] > 0` |
| `cell.snow_cover`（如有读取）| `v.snow_cover[i]` |

**重要**：cell-loop 的循环变量 i 必须是 **MapData index**（与 view 同 stride），
不是 `_round_active_cells` 的 sub-index。如果现有循环用的是 sub-index，
要么映射成 map_index，要么把 view 切成同样的 sub-array（不推荐，多一次拷贝）。
→ **优先方案**：循环遍历 `_round_active_cells_idx[k]` 拿到 map_index `i`，
  view 用 `i` 直接索引。

#### 3.2.3 邻居访问（neighbor loop）
原代码：
```gdscript
for nb in cell.neighbors:
    var t_nb = nb.temperature + ...
```
改为：
```gdscript
var nb_idx_packed: PackedInt32Array = map_data.neighbor_indices_packed()
for k in range(6):
    var nb_idx: int = nb_idx_packed[i * 6 + k]
    if nb_idx < 0: continue
    var t_nb = v.temp[nb_idx] + ...
```
（`MapData.neighbor_indices_packed()` 已存在，第 218 行函数签名已确认）

### 3.3 `scripts/weather/weather_system.gd · commit_weather_field_solve`

#### 3.3.1 write 端补齐 6 个新 SoA 镜像（约第 735-750 行）
原代码：
```gdscript
out_cell.weather_field_initialized = true
out_cell.weather_vapor = _field_slice_next_vapor[i]
...
out_cell.weather_instability = _field_slice_next_instability[i]
...
out_cell.weather_convergence = _field_slice_next_convergence[i]
```

DataCore enabled 时**并行写 SoA**：
```gdscript
if dc_enabled:
    v.field_init[i] = 1
    v.vapor[i] = _field_slice_next_vapor[i]
    v.instability[i] = _field_slice_next_instability[i]
    v.convergence[i] = _field_slice_next_convergence[i]
    # weather_intensity / cloud / precip / type 已由 step-1 路径覆盖；
    # 但要确认 step-1 是否真在 commit 写 SoA——若没写，本步骤一并补
# AoS 写入保留（flush_soa_to_cells 路径不依赖，但 fallback 路径依赖）
out_cell.weather_field_initialized = true
out_cell.weather_vapor = _field_slice_next_vapor[i]
...
```

> **关键决策**：DataCore 路径下，权威是 SoA；AoS 写入仅为
> renderer 在 SoA flush 之前的兼容（renderer 多数路径已迁移到 SoA 读，
> 但 main.gd / data_overlay_baker 仍读 HexCell）。保留 AoS 写入零成本。

### 3.4 `_is_dc_field_enabled()` 内部开关
新增私有方法（仿照 climate_job 的 `_is_data_core_enabled()`）：
```gdscript
func _is_dc_field_enabled() -> bool:
    if _refresh_job == null:
        return false
    if not _refresh_job.data_core_ready():
        return false
    # 复用 use_data_core 主开关；不加新 CLI 开关（用户决策）
    return _refresh_job._is_data_core_enabled() if _refresh_job.has_method("_is_data_core_enabled") \
        else true  # 兜底：只要 ready 就走 DataCore
```

### 3.5 验证（Step-3 完工标准）
- 启动 `--data-core=true`，跑 30 天 ab_test，与 `--data-core=false` 比对哈希
- 哈希必须**完全一致**（误差 ≤ 1e-6 浮点抖动可接受，但 SoA 模式下应该
  逐位等价，因为算法零改动）
- profiler 中 `_field_slice_prev_vapor` 预拷贝循环占比 → 接近 0

---

## Step 4：air_mass_temp_anomaly / has_river 写入侧 SoA 镜像

> 时间预算：2 小时

### 4.1 `scripts/geography/map_generator.gd · _climate_pass` 中的 anomaly 写入

#### 4.1.1 大约第 5255 行 `cell.air_mass_temp_anomaly = 0.0`
加一行（条件 DataCore enabled）：
```gdscript
cell.air_mass_temp_anomaly = 0.0
if _dc_enabled and i >= 0:  # i 为 map_index
    map_data.air_mass_temp_anomaly_arr[i] = 0.0
```

#### 4.1.2 大约第 5289 行 `cell.air_mass_temp_anomaly = temp_mixed - baseline[cell]`
同样补 SoA 写出。

#### 4.1.3 大约第 5334 行 `cell.air_mass_temp_anomaly = anomaly_in`
同样补 SoA 写出。

> **简化方案**（推荐）：在 `_climate_pass_b` 全部完成后，加一次
> ```gdscript
> if _dc_enabled:
>     for i in range(n):
>         map_data.air_mass_temp_anomaly_arr[i] = map_data.cell_at(i).air_mass_temp_anomaly
> ```
> 这样三处写入点不用改，只在 pass 末尾做一次单字段镜像。
> 性能成本：1 次 PackedFloat32Array 顺序写，n=2000 时 < 0.1ms。

### 4.2 `scripts/geography/map_generator.gd · has_river` 写入

`has_river` 在地图生成期写入（约第 2480 / 2522 / 2538 行）：
```gdscript
cell.has_river = true / false
```

**简化方案**：在 `bind_map_data` 之后调用 `rebuild_soa_from_cells()`，
`has_river_arr` 自动同步（Step-1 的 `rebuild_soa_from_cells` 已包含此字段）。
**无需在每个写入点加 SoA 写出**。

确认：`bind_map_data` 调用栈中的 SoA rebuild 时机 → 必须在 `has_river`
所有写入完成之后。grep 确认 `rebuild_soa_from_cells` 在 `_river_filter_pass`
之后调用。

### 4.3 验证
- ab_test 第 1 天：`map_data.air_mass_temp_anomaly_arr` 与所有
  `cell.air_mass_temp_anomaly` 字段值一致（用 debug 命令打印 hash 比对）
- `map_data.has_river_arr` 与 `cell.has_river` 一致

---

## Step 5：Renderer / Baker 路径回归测试

> 时间预算：2 小时

### 5.1 强制 grep 巡检（**不能漏**）
对 6 个新字段在工程里的所有 reader 做巡检：

```bash
grep -r "weather_vapor\|weather_convergence\|weather_instability\|weather_field_initialized\|air_mass_temp_anomaly\|cell\.has_river" scripts/
```

**必检文件**（已知 reader）：
- `scripts/main.gd` — 第 1010 / 1048-1049 行
- `scripts/rendering/map_baker.gd` — 第 1689 / 2198-2201 / 2229-2232 行
- `scripts/rendering/data_overlay_baker.gd` — 第 270-271 行
- `scripts/geography/map_generator.gd` — 第 992-993 / 4677-4678 / 4828-4829 行

**预期**：renderer 都在 round 末读 HexCell；`flush_soa_to_cells` 已保证
HexCell 与 SoA 一致；**renderer 端零改动**。

### 5.2 回归测试矩阵

| 配置 | 命令 | 预期 |
|---|---|---|
| Legacy 路径 | `--data-core=false` 跑 30 天 | 哈希基线 H_legacy |
| DataCore 路径 | `--data-core=true` 跑 30 天 | 哈希 H_dc == H_legacy（逐位等价）|
| 渲染回归 | 两个配置截图比对 | 像素级一致 |

### 5.3 性能数据
- 与 climate-datacore-migration 完成时的 baseline 比对
- 重点关注 weather field solve 总耗时
- 写一份 `perf-report.md` 到本 plan 目录

---

## Step 6：完工记录

> 时间预算：1 小时

### 6.1 更新 `dots-roadmap-to-gdextension/architecture.md`
- 标记 P0-② 为 ✅ 完成
- 在 weather hot loop 章节标注："已完成 view_f32 化（plan：weather-datacore-step2-bfull）"

### 6.2 创建 `weather-datacore-step2-bfull/perf-report.md`
- 完工前后的 weather field solve 耗时对比
- prev 预拷贝循环消失证据（profiler 截图或日志）
- DataCore enabled / disabled 哈希一致性证据

### 6.3 提交 commit
- commit message：`feat(datacore): weather hot loop full view_f32 (P0-② done)`

---

## 时间估算汇总

| Step | 内容 | 预算 |
|---|---|---|
| 1 | 基础设施（component + SoA + bind_map_data）| 4h |
| 2 | weather_refresh_job 注册 + view-getter | 1h |
| 3 | weather_system hot loop view_f32 化 | 6-8h |
| 4 | air_mass_temp_anomaly / has_river 写入侧 | 2h |
| 5 | renderer 回归 + 性能验证 | 2h |
| 6 | 完工记录 | 1h |
| **合计** | | **16-18h（≈ 2-2.5 天）** |

---

## 风险检查表（每步完工前 self-check）

- [ ] Step-1：`view_f32(comp_id)` 与 `map_data.xxx_arr` `is_same` 返回 true
- [ ] Step-2：`data_core_ready()` 在 DataCore enabled 时返回 true
- [ ] Step-3：哈希一致性（DataCore vs Legacy）逐位等价
- [ ] Step-3：profiler 显示 prev 预拷贝循环占比降低
- [ ] Step-4：`air_mass_temp_anomaly_arr` 与 HexCell 字段哈希一致
- [ ] Step-5：renderer 截图无变化
- [ ] Step-5：性能不劣化（≤ baseline × 1.05）

---

## 实测验收（2026-05-11）

### 实施完成状态
- ✅ Step 1-6 全部代码改动落地
- ✅ 6 个文件 lint 全绿
- ✅ A/B test 数值等价性确认（DataCore enabled vs disabled 渲染输出一致）

### 性能验收 ❌（未达预期）
| 指标 | Legacy 基线 | DataCore B-full | Δ |
|---|---|---|---|
| `weather_tick` 内部 | 8.6 ~ 9.0 ms | 9.5 ~ 11.5 ms | **+0.9 ~ +2.5 ms** |
| `weather_refresh` avg | 13.69 ~ 15.59 ms | 14.10 ~ 24.06 ms | **+0.4 ~ +8.5 ms** |
| `refresh_climate_daily` | 9.53 ~ 10.11 ms | 8.89 ~ 9.15 ms | -0.4 ~ -1 ms（沿用上 plan 收益）|

### 根因
**GDScript 解释器下 `PackedFloat32Array[i]` 索引访问比 `cell.weather_vapor` 对象成员访问更慢**（Variant 拆装箱 + bound check 的开销超过 hash property lookup）。详细分析见
[`perf-report.md` §7.3](./perf-report.md)。

### 用户决策（2026-05-11）：**选项 B — 保留全部改动**

接受当前 1-3 ms 劣化作为 **GDExtension I3.C-4** 的前置投资。理由：
1. 数据布局已就绪，I3.C-4 接管时 hot loop body 几乎零改动
2. 现在回退会导致 I3.C-4 重做迁移
3. 数值等价性已验证

### 验收结论
- [x] 代码完工（Step 1-6 全部 ✅）
- [x] lint 通过
- [x] 数值等价
- [ ] 性能达标 ❌ → **延后到 GDExtension I3.C-4 兑现**
- [x] 决策日志已落入 [`architecture.md`](../dots-roadmap-to-gdextension/architecture.md) §8
- [x] 性能数据已归档 [`perf-report.md`](./perf-report.md) §7

**Plan 状态：✅ 完工归档**（带"性能延期兑现"标记 → 等待 I3.C-4）
