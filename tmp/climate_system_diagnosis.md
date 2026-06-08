# 气候模拟系统综合诊断报告

## 一、核心发现摘要

| 问题 | 根因数量 | 严重度 |
|------|---------|--------|
| 温度跳变 | 3 个根因 | **致命** |
| 高山雪盖不自然 | 3 个根因 | 高 |
| 降水持续滞留 | 2 个根因 | 高 |
| 植被普遍死亡 | 4 个根因 | 高 |

---

## 二、问题 #1：温度跳变（不平滑）

### 2.1 数据证据

CSV 数据分析显示：
- **最大单 cell 温度跳变：0.536**（tick 19→20，cell 1212：0.0756 → 0.6120）
- **总跳变次数（>0.1）：17,911 次**
- 跳变集中在特定 tick 边界（tick 19→20, 28→29 等），说明是系统性而非随机噪声

### 2.2 根因 #1：`thermal_daily_delta_cap` 被多个下游 pass 绕过（致命）

**Pass A**（`_climate_pass_a_soa`，map_generator.gd:8480）正确应用了日变化上限：

```gdscript
var temp_now = clampf(
    prev_temp + clampf(heat_next - prev_temp, -thermal_delta_cap, +thermal_delta_cap),
    0.0, 1.0
)
```

但 Pass A 之后还有 **6 个 pass** 直接修改温度，没有任何 delta cap 限制：

1. **Pass B**（`_climate_pass_b_soa`，line 8703）：叠加 coastal/albedo/landform 修正
2. **Ocean water pass**（`_ocean_water_pass`）：洋流热输运
3. **Ocean land pass**（`_ocean_land_pass`）：陆地热输运
4. **Wind air mass pass**（`_wind_air_mass_pass`，line 11645）：`temp = lerpf(temp, upstream_temp, heat_mix)` — **直接覆盖温度**
5. **Wind surface pass**（`_wind_surface_pass`，line 11734）：表面温度异常叠加
6. **Sea ice pass**（`_apply_sea_ice_daily_pass`）：海冰温度修正

**关键代码**（`_wind_air_mass_pass`，line 11708）：

```gdscript
var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)
temp_out_arr[idx_cell] = clampf(temp_mixed, 0.0, 1.0)
```

上游 cell 温度可能与当前 cell 差异极大（尤其在陆地-海洋边界或地形边界），`lerpf` 以 `heat_mix`（默认值未在报告中找到，但通常 0.1-0.3）混合后可产生远超 `thermal_delta_cap`（0.085）的变化。

### 2.3 根因 #2：SoA 快照时机导致 temp_arr 与 temp_arr_prev 不同步

CSV 数据中 `temp_arr`（当前 tick 写入）和 `temp_arr_prev`（上一 tick 的值）之间存在巨大差异，说明 `temp_arr_prev` 可能是 Pass A 写入前的快照，而 `temp_arr` 是所有 7 个 pass 完成后的最终值。这导致观测到的"跳变"实际上是多个 pass 叠加的结果。

### 2.4 根因 #3：初始化阶段 thermal_energy_arr 未预热

从 CSV 数据看，tick 6 时大部分 cell 的 `thermal_energy_arr=0.0` 而 `temp_arr>0`，说明初始化时 thermal_energy 没有正确预热到与温度一致的值。这导致第一个计算周期中热惯性 lerp 从 0 开始追赶，产生初始化跳变。

---

## 三、问题 #2：高山雪盖不自然

### 3.1 根因 #1：温度跳变导致雪盖在有/无之间硬切

`_derived_snow_cover`（map_generator.gd:4709）使用 smoothstep：

```gdscript
var cold_snow: float = (1.0 - smoothstep(0.20, 0.60, temp_now)) * 0.70
var altitude_w: float = smoothstep(0.22, 0.90, land_h)
var alpine_temp_w: float = 1.0 - smoothstep(0.20, 0.85, temp_now)
var alpine_snow: float = altitude_w * alpine_temp_w * 0.92
```

但温度本身有 ±0.5 的跳变，当温度在 smoothstep 边界（0.20 或 0.60）附近跳变时，雪盖会从 0.7 突然跳到 0 或反之。这在中高纬度地区尤其明显。

### 3.2 根因 #2：雪线海拔修正太弱

`weather_system.gd` 中的雪线参数：

```gdscript
const SNOW_ELEV_NEUTRAL: float = 0.30
const SNOW_ELEV_FREEZE_GAIN: float = 0.20   # elev 每升 1.0 → freeze_t 上抬 0.20
const SNOW_ELEV_FREEZE_MAX_OFF: float = 0.06 # 最大偏移仅 ±0.06
const SNOW_ELEV_MELT_GAIN: float = 0.30
const SNOW_ELEV_MELT_MAX_OFF: float = 0.10   # 最大偏移仅 ±0.10
```

对于 `elevation=0.9` 的山峰：
- `elev_delta = 0.9 - 0.30 = 0.60`
- `freeze_off = clamp(0.60 * 0.20, -0.06, 0.06) = 0.06`（被 clamp 上限卡住）
- `melt_off = clamp(0.60 * 0.30, -0.10, 0.10) = 0.10`（被 clamp 上限卡住）
- `freeze_t_local = 0.24 + 0.06 = 0.30`
- `melt_t_local = 0.31 + 0.10 = 0.41`

这意味着山峰的降雪温度阈值仅从 0.24 提升到 0.30，融化阈值从 0.31 提升到 0.41。但温度范围是 0-1，这个偏移量太小，无法让高山在暖季也保持雪盖。现实中山顶应终年有雪（雪线以上），但这里 0.41 的融化阈值意味着温度超过 0.41 就开始融雪，而中纬度夏季温度很容易超过 0.41。

### 3.3 根因 #3：视觉雪盖 vs 物理积雪系统不一致

存在两套独立的雪系统：

1. **Pass A 中的 `_derived_snow_cover`**：纯粹基于温度和海拔的视觉计算
2. **Weather system 中的 snowpack 积累/融化**：物理积雪系统，参数不同

`climate_profile.gd` 中：
```gdscript
snowpack_accum_gain: float = 0.10  # profile 定义
```

`weather_system.gd` 中：
```gdscript
var _snowpack_accum_gain: float = 0.16  # 运行时默认值
```

**积雪增益不一致**：profile 定义 0.10 但运行时用 0.16。如果 profile 值没有正确传递到 weather system，积雪行为会偏离设计意图。

---

## 四、问题 #3：降水持续滞留

### 4.1 根因 #1：precipitation carryover 机制过强

`field_solver.gd`（line 362-367）中的降水持续机制：

```gdscript
var dyn_decay: float = _weather_system._field_precip_decay + wind_mag * 0.25
var carry_limit: float = _weather_system._field_precip_carryover_max
var precip_floor: float = 0.0
if vapor >= 0.50 and old_precip >= 0.08:
    precip_floor = old_precip * minf(1.0 - dyn_decay, carry_limit) * vapor_floor_factor * maxf(rain_focus, 0.35)
var precip: float = clampf(maxf(precip_raw, precip_floor), 0.0, 1.0)
```

参数配置（`climate_profile.gd`）：
```gdscript
weather_precip_decay: float = 0.48         # 衰减率
weather_precip_carryover_max: float = 0.25  # 最大 carryover 比例
```

**问题分析**：
- 当 `vapor >= 0.50` 且 `old_precip >= 0.08` 时，降水有一个**最低保底值** `precip_floor`
- `precip_floor = old_precip * min(1-0.48, 0.25) * vapor_factor * max(rain_focus, 0.35)`
- 即 `precip_floor ≈ old_precip * 0.25 * vapor_factor * 0.35`（最低情况）
- 如果 vapor 一直高（沿海/山地迎风坡），这个保底值会让降水永远不会降到 0
- **正反馈循环**：降水 → 土壤湿度高 → 蒸发高 → vapor 高 → 维持降水

### 4.2 根因 #2：天气场平流将降水从一个 cell 吹到相邻 cell 而非消除

天气场求解器使用风向平流（advection）将 vapor 从上游 cell 带到下游：

```gdscript
var advected_vapor: float = _upstream_vapor_idx_from_first(...)
var vapor: float = lerpf(base_m, advected_vapor, advect_w)  # advect_w ≈ 0.65-0.95
```

下游 cell 收到上游的 vapor 后产生降水，但上游 cell 的 vapor 没有被充分消耗（`weather_vapor_precip_sink = 0.62` 意味着每单位降水只消耗 0.62 的 vapor）。这导致 vapor 在风场方向上不断传递、不断产生降水，形成"降水链"。

---

## 五、问题 #4：植被普遍死亡

### 5.1 根因 #1：compat（适应度）计算对水分胁迫反应迟钝

植被活力漂移逻辑（`_apply_vegetation_dynamics`，line 11262-11282）：

```gdscript
var dv: float = 0.0
if cell.vegetation != VegetationType.VEG.NONE:
    var rate: float = _c().vitality_change_rate  # 0.010
    if compat >= 0.52:
        dv = (compat - 0.5) * 2.0 * rate          # 正向：全速
    elif compat <= 0.48:
        dv = -(0.5 - compat) * 2.0 * rate * _c().compat_harshness  # 负向：35% 速率
```

**问题**：
- `compat_harshness = 0.35` 使负向漂移只有正向的 35%
- 这意味着如果 compat=0.3（较差），每天活力只下降 `(0.5-0.3)*2*0.01*0.35 = 0.0014`
- 从活力 0.7 降到 0.25（演替阈值）需要 `(0.7-0.25)/0.0014 ≈ 321 天`
- 但降水持续滞留导致某些区域长期处于中等胁迫状态（compat 在 0.35-0.48 之间），植被缓慢但持续地退化

### 5.2 根因 #2：water buffer 缓解机制不足

```gdscript
if dv < 0.0:
    var water_buffer: float = clampf(soil_buffer * 0.8, 0.0, 0.60)
    if idx_vd >= 0 and idx_vd < map.water_balance_30d_arr.size():
        water_buffer = clampf(maxf(map.water_balance_30d_arr[idx_vd], 0.0) * 1.5 + soil_buffer * 0.8, 0.0, 0.60)
    dv *= 1.0 - water_buffer
```

**问题**：
- `water_balance_30d` 是 30 天滚动平均的水平衡，值域 [-1, 1]
- 即使 `water_balance_30d = 0.4`（正平衡），`water_buffer = 0.4*1.5 + soil*0.8 ≈ 0.6`
- `dv *= 1.0 - 0.6 = 0.4`，即负向漂移被削弱 60%
- 但如果持续降水滞留导致 `water_balance_30d` 为负，water buffer 反而很小，无法保护植被

### 5.3 根因 #3：演替退化后活力软重置导致循环退化

```gdscript
func _trigger_succession(cell: HexCell) -> bool:
    if cell._vitality_low_streak >= _c().succession_degrade_days:  # 45 天
        var next_h: int = VegetationType.next_in_succession(cell.vegetation, -1)
        if next_h != cell.vegetation:
            cell.vegetation = next_h
            cell.vegetation_vitality = (cell.vegetation_vitality + 0.65) * 0.5  # 软重置
```

**问题**：
- 当活力降到 0.25 以下并持续 45 天后，植被退化到下一阶
- 退化后活力被重置为 `(0.25 + 0.65) * 0.5 = 0.45`
- 但 0.45 仍然低于 0.52（正向恢复阈值），所以植被继续负向漂移
- 只需约 `(0.45-0.25)/0.0014 ≈ 143 天` 再次触发退化
- 这形成一个 **退化循环**：GRASS → SCRUB → DESERT

### 5.4 根因 #4：天气惩罚叠加

```gdscript
var base_penalty: float = float(WEATHER_VITALITY_PENALTY.get(wt, 0.0))
var resistance: float = VegetationType.weather_resistance(int(cell.vegetation), wt)
var penalty: float = base_penalty * wi * (1.0 - resistance) * _c().vegetation_weather_penalty_scale
dv -= penalty
```

恶劣天气（BLIZZARD、DROUGHT、HEATWAVE）会额外降低活力，且这个惩罚不受 `compat_harshness` 缩放。如果天气系统持续产生恶劣天气，植被会同时受到 compat 漂移 + 天气惩罚的双重打击。

---

## 六、系统自洽性评估

### 6.1 ✅ 自洽的部分

| 子系统 | 评估 | 说明 |
|--------|------|------|
| 太阳辐照 → 温度基线 | ✅ | `temp_baseline = cos(lat)^1.2 - alt_penalty`，物理合理 |
| 季节偏移 | ✅ | Phase F 真实辐照模型，使用轴倾角、日长、辐照偏差 |
| 物理环流求解器 | ✅ | 6 步管线（SLP→风场→风应力旋度→海洋 ψ→洋流→上升流），Stommel 模型合理 |
| 海冰状态机 | ✅ | 温度驱动冻结/融化 + 邻居传染 + dt_days 补偿 |
| 植被演替链 | ✅ | 正确的升级/退化链，streak 计数机制合理 |
| 地形对降水的影响 | ✅ | 迎风坡 orographic lift + 雨影（rain shadow）+ 海拔修正 |

### 6.2 ❌ 不自洽的部分

| 子系统 | 问题 | 影响 |
|--------|------|------|
| 温度 delta cap | Pass A 应用 cap，但 Pass B/C/D/E/F/G 绕过 | 温度跳变 |
| 双雪系统 | Pass A 的 `_derived_snow_cover` vs Weather System 的 snowpack，参数不一致 | 雪盖不稳定 |
| 降水 carryover | 永不归零的降水保底值 + vapor 不充分消耗 | 降水滞留 |
| 植被 compat | 非对称漂移 + 退化循环 + 弱 water buffer | 植被死亡 |
| snowpack 参数 | profile 定义 0.10 vs 运行时 0.16 | 积雪偏离设计 |

---

## 七、修复建议（按优先级排序）

### P0：修复温度 delta cap 绕过

**方案 A（推荐）**：在 `refresh_climate_daily` 的末尾（所有 pass 完成后），对每个 cell 施加一次全局 delta cap：

```gdscript
# 在所有 7 个 sub-pass 完成后
for i in range(n):
    var final_temp: float = temp_a[i]
    var prev_final: float = temp_prev_a[i]  # 需要额外保存 pass 前的温度快照
    temp_a[i] = clampf(
        prev_final + clampf(final_temp - prev_final, -thermal_delta_cap, +thermal_delta_cap),
        0.0, 1.0
    )
```

**方案 B**：让每个下游 pass 都应用 delta cap（侵入性大，但更精确）。

### P1：统一雪系统

1. 删除 Pass A 中的 `_derived_snow_cover` 视觉计算
2. 让 snow cover 完全由 snowpack 物理系统驱动
3. 统一 `snowpack_accum_gain` 参数（profile 值应传递到 weather system）

### P2：修复降水 carryover

1. 将 `weather_precip_carryover_max` 从 0.25 降低到 0.10-0.15
2. 增加 `weather_vapor_precip_sink` 从 0.62 到 0.80（让降水更有效地消耗 vapor）
3. 添加 vapor 衰减：如果 cell 没有降水产生，vapor 应缓慢衰减回 `base_moisture`

### P3：增强高山雪线

1. 增大 `SNOW_ELEV_FREEZE_MAX_OFF` 从 0.06 到 0.15
2. 增大 `SNOW_ELEV_MELT_MAX_OFF` 从 0.10 到 0.25
3. 让海拔 0.8+ 的山峰的融化阈值提升到 0.5+，使其在中纬度暖季也能保持雪盖

### P4：修复植被退化循环

1. 降低 `compat_harshness` 的影响：当活力已经很低时（<0.4），进一步降低退化速率
2. 增强 water buffer：将乘数从 0.8 提升到 1.2，让正水平衡更有效地保护植被
3. 演替后活力重置：使用 `(vitality + 0.75) * 0.5` 而不是 `(vitality + 0.65) * 0.5`，给更多恢复空间

---

## 八、数据流全景图

```
太阳辐照 (Phase F: 轴倾角, 日长, 辐照偏差)
    ↓
temp_baseline = cos(lat)^1.2 - alt_penalty
    ↓
season_offset = gain × amp × dev_today
    ↓
radiative_target = clamp(baseline + season_offset)
    ↓
thermal_energy = lerpf(prev, target, alpha_thermal)  ← Pass A (有 delta cap)
    ↓
temperature = prev + clamp(thermal - prev, ±cap)     ← Pass A (有 delta cap)
    ↓
Pass B: + coastal/albedo/landform/evap 修正          ← ❌ 无 delta cap
    ↓
Ocean pass: + 洋流热输运                              ← ❌ 无 delta cap
    ↓
Wind pass: = lerpf(temp, upstream, mix)               ← ❌ 无 delta cap，直接覆盖
    ↓
Sea ice pass: 冻结/融化修正                            ← ❌ 无 delta cap
    ↓
Weather field: vapor → cloud → precip → snowpack     ← 积雪物理系统
    ↓
Snow cover: smoothstep(snowpack)                      ← 视觉派生
    ↓
Vegetation: compat → vitality → succession            ← 植被动态
```

**关键断裂点**：Pass A 的 delta cap 保护在 Pass B 之后完全失效。
