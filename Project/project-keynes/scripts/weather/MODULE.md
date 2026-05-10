# weather — 天气模拟模块

> 状态：**Phase 0~3 v9d 已完工**（云场 / 锋面 / 雨幕 / 积雪累积 / 物理调参）。Phase 4（日出金边、伪体积感）待启动。

## 范围

负责：
- 全图天气场求解（vapor / cloud / precip / instability，per-cell 网格场）
- 锋面对象（`WeatherFront`：暴风/雷暴/季风/暴雪/雾的连续团块，跨日演化）
- 风带模型（`WindBelt`：纬度带的稳定主轴，叠加季节性 monsoon 偏置）
- 锋面散度检测（冷暖气流交汇处升级为可见走廊）
- 积雪累积/融化的多日逻辑（写回 `HexCell.cover`）

**不负责**：
- 风场本身（来自 `WorldData.wind_field_buffer`，由 geography 在生成期产出）
- 渲染（shader 在 `weather_overlay.gdshader`，纹理打包在 `map_baker.bake_weather_field_only`）

## 公共类

| 类 | 入口 | 说明 |
|---|---|---|
| `WeatherSystem` | `new()` + `init(seed, bounds, hex_size)` + `tick_one_day(map, world, season_idx, anomaly, season_phase)` | 主循环，由 SUS `WeatherRefreshJob` 每日调度 |
| `WeatherFront` | `new()`（内部实例化） | 单个气团；`advance_one_day()` 跨日演化 |
| `WindBelt` | 纯静态 | 纬度风带主轴查询 |

## 对外查询接口（其他模块只用这些）

```gdscript
# WeatherSystem 实例（由 MapGenerator 持有，可通过 main.gd 暴露）
var ws: WeatherSystem = ...

# 按世界坐标查询某点天气
var info := ws.query_at(world_pos)
# 返回 { type: WeatherType, intensity: float, cloud, precip, vapor, ... }

# HexCell 上的天气字段（每日 tick 后由 WeatherSystem 写入）
cell.weather_now           # 当前天气类型
cell.cloud / .precip / .vapor / .instability
cell.snow_cover            # [0,1]，给 shader 用
```

## 不要直接调用的内部方法

- `_solve_weather_field()` — 主求解循环
- `_apply_frontal_convergence_boost()` — 锋面后处理
- `_upstream_vapor()` — advection 函数
- `_apply_snow_accumulation()` — 积雪累积逻辑（共享方法，由两条分支调用）

## HexCell 写入字段（由本模块负责维护）

- `weather_now`, `cloud`, `precip`, `vapor`, `instability`
- `snow_cover`, `accumulated_snow_days`, `pre_snow_cover`
- 当 `accumulated_snow_days >= 3` 时会写 `cover = SNOW`，融化时恢复 `pre_snow_cover`
- 当 `intensity > 0.55 && precip > 0.55`（heavy_flood）或低洼湿润时写 `cover = FLOODING`

> 经济模块如读 `cell.cover`，要预期它可能是 SNOW/FLOODING（来自天气）而不是地理本底。`cell.base_landform` 才是地理本底地貌。

## 调参备忘

`weather_system.gd` 内的 `v3 / v4 / v5 / v9b / v9c / v9d` 注释记录了关键常量的 rationale：

- `_field_advect_steps = 1` (fast-tick cap)
- `_field_condensation_gain = 0.32` → v9b 回调到 0.42（凝结倍数 *2.2）
- `_field_precip_decay = 0.82` (v5)
- `_apply_frontal_convergence_boost` 起跳门槛 `frontal_score > 0.45` (v5)

调任何一个数值前**先读注释里的根因分析**，避免重蹈已踩过的坑（见 `~/.workbuddy/memory/2026-05-10.md` 完整推演）。

## 模块依赖图

```
weather/
  ├── 依赖 geography/    (HexCell / MapData / WorldData / WeatherType / WindBelt)
  ├── 依赖 data/         (WeatherProfile)
  └── 依赖 simulation/   (sus_job 基类，在 jobs/weather_refresh_job.gd)
```
