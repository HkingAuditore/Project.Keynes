# Project Keynes — `res://data/` 数据目录指南

本目录存放三类 Godot Resource（`.tres`）配置文件，对应世界模拟的三大轴：

| 子目录 | Resource 类 | 数量 | 用途 |
|---|---|---|---|
| `terrain/` | `TerrainProfile` | 26 | 每种地形的通行性、移动消耗、调试色、中文名 |
| `vegetation/` | `VegetationProfile` | 24 | 每种植被的气候适应性、生态反馈、演替链 |
| `world/` | `ClimateProfile` | 1+ | 世界生成参数（大陆形态、湿度、轨道日照、水文、生态反馈） |

---

## 1. 新增一种地形

### 步骤

1. **新建 `.tres`**：在 `res://data/terrain/` 下复制一个现有文件（如 `plain.tres`），重命名为新地形的英文小写名（如 `hot_spring.tres`）。在 Inspector 中填写所有字段：

   | 字段 | 说明 | 示例 |
   |---|---|---|
   | `terrain_type` | 对应 `TerrainType.TERRAIN` 枚举整数值（见步骤 2） | `26` |
   | `display_name` | 英文 debug 名 | `"HOT_SPRING"` |
   | `display_name_cn` | UI 中文名 | `"温泉"` |
   | `passable_land` | 陆地单位可通行 | `true` |
   | `passable_sea` | 海洋单位可通行 | `false` |
   | `move_cost` | 进入该地形的移动消耗（整数） | `2` |
   | `base_color` | Baker / debug 调色 | `Color(0.4, 0.8, 0.9)` |

2. **在 `TerrainType.TERRAIN` 枚举加值**：打开 `res://scripts/geography/terrain_type.gd`，在 `enum TERRAIN` 末尾追加：
   ```gdscript
   HOT_SPRING = 26,
   ```
   > ⚠ 不要改动已有枚举值的顺序或数值——shader / baker 依赖下标。

3. **在 `TerrainProfileRegistry._PROFILE_PATHS` 注册路径**：打开 `res://scripts/data/terrain_profile_registry.gd`，在 `_PROFILE_PATHS` 字典末尾追加：
   ```gdscript
   26: "res://data/terrain/hot_spring.tres",
   ```

4. **（可选）处理 baker / shader 新下标**：如果 `MapBaker` 或 `world_map.gdshader` 有按枚举下标索引的颜色数组，需要在对应位置补充第 26 项。

5. **验证**：启动游戏，在 Output 面板确认自测脚本打印 `[Terrain] 27 / 27 loaded`（或手动调用 `_RegistrySelfCheck.run_once()`）。

---

## 2. 新增一种植被

### 步骤

1. **新建 `.tres`**：在 `res://data/vegetation/` 下复制一个现有文件（如 `temperate_grassland.tres`），重命名（如 `alpine_bog.tres`）。在 Inspector 中填写字段：

   | 字段 | 说明 | 典型范围 |
   |---|---|---|
   | `veg_type` | 对应 `VegetationType.VEG` 枚举整数值 | 新值 |
   | `display_name_cn` | UI 中文名 | `"高山沼泽"` |
   | `transpiration` | 蒸腾率（影响周边湿度） | `0.0 – 1.0` |
   | `albedo` | 反照率（影响局地温度） | `0.0 – 1.0` |
   | `eco_score` | 生态评分（正 = 健康，负 = 退化） | `-0.8 – 1.2` |
   | `ideal_temp` | 最适温度（归一化 0–1） | `0.0 – 1.0` |
   | `ideal_moist` | 最适湿度（归一化 0–1） | `0.0 – 1.0` |
   | `temp_tolerance` | 温度容差（高斯半宽） | 默认 `0.28` |
   | `moist_tolerance` | 湿度容差（高斯半宽） | 默认 `0.28` |
   | `next_richer` | 升级演替下家的 VEG 整数值；链尾填 `-1` | |
   | `next_harsher` | 退化演替下家的 VEG 整数值；链尾填 `-1` | |

2. **在 `VegetationType.VEG` 枚举加值**：打开 `res://scripts/geography/vegetation_type.gd`，在 `enum VEG` 末尾追加：
   ```gdscript
   ALPINE_BOG = 24,
   ```

3. **在 `VegetationProfileRegistry._PROFILE_PATHS` 注册路径**：打开 `res://scripts/data/vegetation_profile_registry.gd`，追加：
   ```gdscript
   24: "res://data/vegetation/alpine_bog.tres",
   ```

4. **检查演替链闭合**：确认 `next_richer` / `next_harsher` 指向的 VEG 值存在，且不会形成无限循环（链尾用 `-1`）。

5. **验证**：Output 面板确认 `[Vegetation] 25 / 25 loaded`。

---

## 3. 新增一种世界预设

世界预设是一份 `ClimateProfile` 资源，描述一整套世界生成参数。切换预设**无需改任何代码**。

### 步骤

1. **复制 `earth_like.tres`**：在 `res://data/world/` 下复制并重命名（如 `ice_age.tres`）。

2. **在 Inspector 调整参数**：以下是"冰河世纪"预设的典型偏移方向：

   | 字段 | earth_like | ice_age 建议 | 说明 |
   |---|---|---|---|
   | `sea_ice_form_threshold` | `0.10` | `0.15` | 更容易结冰 |
   | `sea_ice_melt_threshold` | `0.22` | `0.30` | 更难融化 |
   | `weather_ocean_evap_gain` | `0.40` | `0.25` | 海面蒸发偏弱，降水源减少 |
   | `ocean_moisture_coupling_gain` | `1.5` | `0.9` | 洋流对水汽输送影响更弱 |
   | `insolation_season_gain` | `2.5` | `2.0` | 日照季节响应更温和 |
   | `orographic_boost` | `1.5` | `2.0` | 山地降雪更多 |
   | `veg_forest_donor` | `0.06` | `0.02` | 冻土森林蒸腾弱 |
   | `veg_desert_donor` | `-0.04` | `-0.08` | 冰原更干燥 |
   | `vitality_change_rate` | `0.015` | `0.010` | 植被适应更慢 |
   | `succession_degrade_days` | `30` | `20` | 退化更快 |

3. **在 `MapGenerator.climate_profile` 指向新 `.tres`**：在 Godot 场景树中选中持有 `MapGenerator` 的节点，在 Inspector 的 `climate_profile` 字段拖入 `ice_age.tres`。或在代码里：
   ```gdscript
   _generator.climate_profile = load("res://data/world/ice_age.tres")
   ```

4. **运行游戏**：无需重启引擎，直接生成即可看到冰河世界。

---

## 字段速查（不直观字段说明）

| 字段 | 含义 | 典型取值 |
|---|---|---|
| `rain_shadow_lookback` | 向上风方向回溯多少个 hex 来判断山脉遮挡 | `1–3`；越大雨影越宽 |
| `satellite_separation_factor` | 卫星岛之间允许的最小间距系数（1.0 = 不重叠） | `0.4–0.7`；越小群岛越密 |
| `transpiration_outflow_rate` | 每"日"植被最多向 6 个邻居各输出多少 moisture | `0.01–0.05` |
| `transpiration_self_rate` | 每"日"植被蒸腾留给自身的 moisture 比例 | `0.005–0.02` |
| `eco_drift_amp` | 年度 `base_moisture` 漂移幅度上限（生态评分驱动） | `0.005–0.02` |
| `eco_score_clamp` | 平稳期漂移速度阻尼（越小越慢） | `0.3–0.8` |
| `meso_weight` | 中频地貌噪声权重（打破大陆同心圆梯度） | `0.2–0.5` |
| `offshore_amp` | 大陆远海偶发群岛的振幅 | `0.0–0.6`；0 = 无离岛 |
| `pit_fill_max_iters` | 洼地填充最大迭代次数（防止无限循环） | `50–200` |

---

## 自测脚本

运行 `res://scripts/data/_registry_self_check.gd` 可一次性验证所有 tres 是否正确加载：

```gdscript
# 在任意 Node 的 _ready() 里调用（开发期）：
load("res://scripts/data/_registry_self_check.gd").new().run()
```

输出示例：
```
─── Registry self-check ─────────────────────────────
  [Terrain]    26 / 26 loaded
  [Vegetation] 24 / 24 loaded
  [Climate]    res://data/world/earth_like.tres OK (legacy_moisture_scale=[1, 1, 1, 1], volcanoes=8)
─── Registry self-check done ────────────────────────
```
