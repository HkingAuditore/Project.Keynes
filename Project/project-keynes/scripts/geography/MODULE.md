# geography — 地理与世界基础模块

> 状态：**v1 已冻结**（地图/地形/植被/世界时钟）。新模块依赖此处的对外只读 API，内部实现可继续重构。

## 范围

负责：
- 六边形地图的几何与坐标（`HexUtils`、`HexCell.q/r/s`）
- 程序化世界生成（`MapGenerator` → 大陆形态 / 河网 / 湿度 / 植被 / 洋流）
- 世界状态容器（`MapData`、`WorldData`，含所有用于 GPU 上传的 PackedArray 缓冲）
- 地理可观测的类型枚举（`TerrainType`、`VegetationType`、`CoverType`、`LandformType`、`WeatherType`）
- 世界时钟与昼夜节律（`WorldClock`、`TODProfile`）

## 公共类（class_name 全局符号，可直接引用）

| 类 | 入口 | 说明 |
|---|---|---|
| `HexUtils` | 静态方法 | 立方坐标 ↔ 像素、邻居、距离、Brensham 等纯几何 |
| `HexCell` | `new()` 后由 MapGenerator 填充 | 单个地块的所有状态。**不要 new 出来自己用** |
| `MapData` | `new(width, height)` | hex 二维网格容器；`set_cell(c)` / `get_cell(q,r)` |
| `MapConfig` | `new()` | 地图生成参数集（width/height/sea_level/seed 等） |
| `MapGenerator` | `new()` + `generate(cfg)` | 入口；返回 `MapData`，并在内部组装 `WorldData` |
| `WorldData` | 由 MapGenerator 产出 | 渲染/查询用的世界级缓冲 + ImageTexture，含 `sample_*(world_pos)` 系列 |
| `WorldClock` | `Node` 节点 | 信号驱动时间：`day_changed` / `season_changed` / `year_changed` / `day_phase_changed` |
| `TODProfile` | 纯脚本对象 | 太阳色 / 夜色 / 曝光的中枢，由 `WorldClock.day_phase_changed` 驱动 |
| `TerrainType` `VegetationType` `CoverType` `LandformType` `WeatherType` | `enum` + 静态查询 | 内部转发到 `data/*_profile_registry.gd` |

## HexCell 字段访问契约

外部模块（economy / unit / civ ...）**只读**以下字段：

- 坐标：`q`, `r`, `s`
- 地形语义：`terrain`, `landform`, `vegetation`, `cover`, `has_river`
- 标量：`elevation` ∈ [0,1], `moisture` ∈ [0,1], `temperature`, `latitude`
- 通行性（由 TerrainProfile 计算后写入）：`passable_land`, `passable_sea`
- 流体场：`wind_vector`, `ocean_current`（如需路径/风险计算）

外部模块**不能写**任何 HexCell 字段——所有写入由 `MapGenerator` / `WeatherSystem` / SUS Jobs 完成。

外部模块**不要触碰**的内部状态（命名前缀或语义提示）：
- `_ema_*`, `_history_*`, `_vitality_*_streak` — 模拟内部 EMA/历史窗口
- `accumulated_snow_days`, `pre_snow_cover` — 天气模块内部状态
- `temperature_breakdown`, `current_state` — 调试字典
- `temp_baseline`, `temp_season_offset`, `temp_30d_mean`, `temp_365d_mean` — 气候推导中间量

## 主要入口

```gdscript
# 生成世界
var gen := MapGenerator.new()
var generated: Dictionary = await gen.generate(cfg, hex_size)
var map: MapData = generated["map"]
var world: WorldData = gen.world_data

# 按世界坐标查询
var biome := world.sample_biome(pos)
var moist := world.sample_moisture(pos)
var wind := world.sample_wind(pos)

# 按 hex 坐标查询
var cell := map.get_cell(q, r)
```

## 模块依赖图（出向）

```
geography/
  ├── 依赖 data/         (TerrainProfile / VegetationProfile / ClimateProfile)
  ├── 依赖 weather/      (MapGenerator 生成时调用 WeatherSystem 初始化)
  └── 依赖 simulation/   (MapGenerator 注册 SUS Jobs)
```

> 注：geography → weather 的依赖是**单向 wire-up**（构造期），运行期 weather/ 反过来读 geography/ 字段。

## 修改 / 扩展规范

- 新增地形/植被：见 `res://data/README.md` 的步骤
- 新增 HexCell 字段：先在此 MODULE.md 的"字段访问契约"标注归属（geography 还是其他模块代写）
- 新增 `class_name`：注意 Godot 全局类注册偶发未拾取，必要时用 `preload("res://scripts/geography/xxx.gd")` 替代依赖 class_name
