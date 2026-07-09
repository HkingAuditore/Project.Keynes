# economy — 经济模块（物资数据层已接入 / 系统待开工）

> 状态：**经济系统未实现**；物资（goods）数据层已接入 DataCore。
> 当前已有 `GoodProfile` / `GoodProfileRegistry`、`data/goods/*.tres`，以及 `economy.goods` owner 的 per-cell 库存/价格 F32 slots。

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
- `data/`：读取 `GoodProfile.tres` / 未来 `BuildingProfile.tres` 等资源；自然资源仍通过 `ResourceProfile` 管理
- `data_core/`：通过 `DCWorld.write_f32_indexed/write_f32_dense` 或未来 C++ pass 批量读写 `cell_goods_*` slots
- `simulation/`：注册自己的 SUS Job 做周期更新
- `ui/`：自定义经济面板

### 不允许依赖

- 直接 import `weather/weather_system.gd` 内部方法
- 写 `HexCell` 中归 geography/weather 维护的字段（见各自 MODULE.md 的契约）
- 给 `HexCell` 增加动态 goods Dictionary/Object/list；每地块物资库存必须走 SoA slots

## 计划模块组件（草案）

```
economy/
  MODULE.md
  goods_catalog.gd          # 可选薄壳；底层复用 GoodProfileRegistry
  resource_yield.gd         # 给 HexCell 算每种资源的基线产能
  city.gd                   # class_name City
  city_registry.gd          # 全局城市集合
  trade_network.gd          # 城市之间的可达性 + 流动
  economy_system.gd         # class_name EconomySystem，主入口
  jobs/
	economy_tick_job.gd     # 注册到 SUS，每 N 天更新
```

## 第一版 MVP 建议范围

1. 给每个地块计算若干物资的产出/消费 delta，并批量写入 `cell_goods_*_qty`
2. 加一个 `City` 类，含位置 + 人口 + 仓储
3. 选定 1~3 个起始城市，让人口按周边地块物资供给增长
4. UI 加一个城市/地块物资面板，冷路径读取 `GoodProfileRegistry.cell_goods_snapshot()`

可暂时跳过：贸易网络、动态定价、科技、政治。价格 slot 已存在并按 `GoodProfile.default_price` 初始化，但尚无价格计算系统。

## 与 geography/ 的对接清单（实现时填）

| 需要的输入 | 来源 | 备注 |
|---|---|---|
| 地块地形/landform/植被 | `cell.terrain` / `.landform` / `.vegetation` | 直接读 |
| 是否河流 / 是否海岸 | `cell.has_river` / `cell.terrain == COAST` | |
| 海拔 / 湿度 / 温度 | `cell.elevation` / `.moisture` / `.temperature` | 标量 [0,1] |
| 气候带 / 季节 | `WorldClock` + `cell.latitude` | 派生 |
| 当前天气 / 雪盖 / 洪涝 | `cell.weather_now` / `.cover` | 短期扰动 |

> 实现时若发现 geography 缺少需要的查询，**优先在 geography 里加纯函数**而不是把推导塞进 economy。
