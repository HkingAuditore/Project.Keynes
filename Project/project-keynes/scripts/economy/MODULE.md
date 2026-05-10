# economy — 经济模块（占位 / 待开工）

> 状态：**未实现**。本目录用于规划经济模块的边界与依赖。

## 设计目标

将"地理事实"转译为"经济产能"，建模：
- 资源：可耕地、水源、林木、矿藏、洋流渔场
- 生产：每地块的食物/物资产出
- 人口与城市：定居点的承载力、增长、衰退
- 贸易：城市间的物资流动与价格

## 边界声明（开工前先写在这里以约束实现）

### 允许依赖

- `geography/`：通过 `HexCell` 只读字段 + `WorldData.sample_*()` 接口读取地理事实
- `weather/`：通过 `HexCell.weather_now`、`cell.cover` 读天气**结果**（不读内部状态）
- `data/`：自行定义 `ResourceProfile.tres` / `BuildingProfile.tres` 等资源
- `simulation/`：注册自己的 SUS Job 做周期更新
- `ui/`：自定义经济面板

### 不允许依赖

- 直接 import `weather/weather_system.gd` 内部方法
- 写 `HexCell` 中归 geography/weather 维护的字段（见各自 MODULE.md 的契约）

## 计划模块组件（草案）

```
economy/
  MODULE.md
  resource_type.gd          # enum FOOD / WOOD / IRON / ...
  resource_yield.gd         # 给 HexCell 算每种资源的基线产能
  city.gd                   # class_name City
  city_registry.gd          # 全局城市集合
  trade_network.gd          # 城市之间的可达性 + 流动
  economy_system.gd         # class_name EconomySystem，主入口
  jobs/
    economy_tick_job.gd     # 注册到 SUS，每 N 天更新
```

## 第一版 MVP 建议范围

1. 给每个 `HexCell` 算 `food_yield` / `prod_yield` / `gold_yield`（纯函数，从 terrain/landform/vegetation/has_river/cover 推导）
2. 加一个 `City` 类，含位置 + 人口 + 仓储
3. 选定 1~3 个起始城市，让人口按周边地块产能增长
4. UI 加一个城市面板，显示当前产能与人口

可暂时跳过：贸易、价格、科技、政治。

## 与 geography/ 的对接清单（实现时填）

| 需要的输入 | 来源 | 备注 |
|---|---|---|
| 地块地形/landform/植被 | `cell.terrain` / `.landform` / `.vegetation` | 直接读 |
| 是否河流 / 是否海岸 | `cell.has_river` / `cell.terrain == COAST` | |
| 海拔 / 湿度 / 温度 | `cell.elevation` / `.moisture` / `.temperature` | 标量 [0,1] |
| 气候带 / 季节 | `WorldClock` + `cell.latitude` | 派生 |
| 当前天气 / 雪盖 / 洪涝 | `cell.weather_now` / `.cover` | 短期扰动 |

> 实现时若发现 geography 缺少需要的查询，**优先在 geography 里加纯函数**而不是把推导塞进 economy。
