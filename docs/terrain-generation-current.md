# 当前地形生成算法文档

本文整理 Project.Keynes 当前使用的初始世界地形生成算法。范围包括：

- `MapGenerator.generate()` 与 `_generate_cells()` 的完整阶段顺序。
- 海拔、大陆、山脉、湖泊、河流、湿度、生态、特殊地貌、三轴派生算法。
- `MapBaker` 如何把逻辑地形烘焙成高度图、enum atlas、scalar atlas 和河流 SDF。
- `MapData` / DataCore / C++ DOTS 运行期数据边界。
- 当前算法的已知限制，尤其是水文与 C++/DOTS 化边界。

本文描述的是当前代码事实，不是目标方案。

## 主要源码入口

| 职责 | 文件 | 关键入口 |
| --- | --- | --- |
| 世界生成总入口 | `Project/project-keynes/scripts/geography/map_generator.gd` | `generate()` |
| per-cell 初始生成 | `Project/project-keynes/scripts/geography/map_generator.gd` | `_generate_cells()` |
| 地图数据与 SoA 镜像 | `Project/project-keynes/scripts/geography/map_data.gd` | `init_soa_from_bake()` / `rebuild_soa_from_cells()` |
| HexCell facade / AoS 字段 | `Project/project-keynes/scripts/geography/hex_cell.gd` | `terrain` / `landform` / `vegetation` / `cover` 等字段 |
| 地形枚举 | `Project/project-keynes/scripts/geography/terrain_type.gd` | `TerrainType.TERRAIN` |
| 几何地貌轴 | `Project/project-keynes/scripts/geography/landform_type.gd` | `LandformType.LF` |
| 植被轴 | `Project/project-keynes/scripts/geography/vegetation_type.gd` | `VegetationType.VEG` |
| 覆盖物轴 | `Project/project-keynes/scripts/geography/cover_type.gd` | `CoverType.CV` |
| 生成参数 | `Project/project-keynes/scripts/data/climate_profile.gd` | 大陆、山脉、水文、气候、生态参数 |
| 基础地图配置 | `Project/project-keynes/scripts/geography/map_config.gd` | `width` / `height` / `num_continents` / `sea_level` / `seed` |
| 渲染烘焙 | `Project/project-keynes/scripts/rendering/map_baker.gd` | `bake_world()` |
| DataCore schema | `Project/project-keynes/scripts/data_core/component_schema.gd` | `cell.terrain` / `cell.has_river` / `cell.is_water` 等 |

## 权威数据边界

当前初始地形生成不是 C++/DOTS 权威。生成期主要权威仍是 GDScript `MapGenerator` 对 `HexCell` AoS 字段的直接写入：

- `cell.elevation`
- `cell.moisture`
- `cell.terrain`
- `cell.landform`
- `cell.vegetation`
- `cell.cover`
- `cell.has_river`
- `cell.is_lake_seed`
- `cell.has_volcano`
- `cell.base_*`

`MapGenerator.generate()` 在 `_generate_cells()`、三轴派生、海冰 bootstrap、`MapBaker.bake_world()`、洋流/风回填之后，才调用 `map.init_soa_from_bake()`。该调用把 `HexCell` AoS 快照复制到 `MapData` SoA 数组，例如 `terrain_arr`、`landform_arr`、`vegetation_arr`、`cover_arr`、`elevation_arr`、`has_river_arr`、`is_water_arr`。

随后 `_setup_sus()` 创建 `DCWorld` 并 `bind_map_data(map)`，如果 `DCWorldExt` 可用，也绑定同一份 `MapData` PackedArray。运行期气候、天气、海冰、季节刷新等系统才从 SoA / DataCore / C++ pass 继续读写。

因此：

- 初始地形、水文、湖泊、河流生成的当前权威路径是 GDScript + `HexCell`。
- `cell.has_river` 已进入 schema，owner 是 `map_generation`，但 C++ 当前主要消费该字段，不生成河网本身。
- `MapBaker` 读 `HexCell` / `MapData` 的初始结果烘焙视觉贴图。
- 后续运行期可继续改写 `terrain` / `cover`，尤其是季节刷新与海冰 daily pass。

## 总体调用顺序

`MapGenerator.generate(cfg, hex_size)` 的高层顺序如下：

1. `cfg.validate()`。
2. 解析 seed，初始化 `_rng` 和噪声场。
3. 调用 `_generate_cells(cfg)` 生成 `MapData` 和所有 `HexCell`。
4. `_sync_axes_for_map(map, cfg)`：从 `terrain + elevation + context` 派生 `landform / vegetation / cover`。
5. `_snapshot_base_state(map)`：保存 `base_terrain / base_landform / base_vegetation`。
6. `_bootstrap_sea_ice_fraction(map, cfg)`：初始化 `sea_ice_fraction`，稳定极地多年冰可把 terrain 翻为 `SEA_ICE`。
7. 再次 `_sync_axes_for_map(map, cfg)`，因为海冰可能改 terrain。
8. `map._build_indices()`，给 `cell.index` 和邻居索引做 bake 前准备。
9. 温度 bootstrap：写 `cell.current_state` 与温度 backing fields。
10. `MapBaker.bake_world(map, cfg, hex_size, seed)` 生成视觉 `WorldData`。
11. `_compute_ocean_currents(map, world, hex_size)`，在非 physical-hex 路径下从像素洋流回采到 cell。
12. `_compute_terrain_perturbed_wind(map)`，在非 physical-hex 路径下生成 per-cell 地形扰动风。
13. 初始化 `WeatherSystem` 并下发气候配置。
14. 再次 `map._build_indices()`。
15. `map.init_soa_from_bake()`，把 AoS 生成结果同步到 SoA。
16. `map.bake_lat_temp_year_lut(self)`。
17. `_setup_sus(map, world, cfg, hex_size)`，进入 DataCore / SUS / C++ 运行期。

## `_generate_cells()` 阶段顺序

`_generate_cells(cfg)` 是初始地形生成的核心。当前顺序如下：

| 阶段 | 调用 | 说明 |
| --- | --- | --- |
| 0 | `_make_continent_centers()` | 放置主大陆与卫星岛中心。 |
| 1 | `_compute_elevation()` per cell | 生成原始海拔。 |
| 1b | `_normalize_elevation()` | 全图海拔归一化到 `[0, 1]`。 |
| 1.5 | `_carve_lake_seeds()` | 用噪声选内陆格，强制下沉为湖泊种子。 |
| 2 | `_smooth_pit_depressions()` | 迭代抬平局部洼地，帮助河流下坡。 |
| 3 | `_apply_mountain_ridges()` | normalize 后给陆地增加山脉脊线。 |
| 4 | `_compute_moisture_base()` per cell | 多尺度噪声生成基础湿度。 |
| 5 | `_decide_terrain(..., permanent_only=true)` | 初步 terrain 分类。 |
| 5.5 | `_detect_lakes()` | 从边界海水 BFS，未连海水体改为 `LAKE`。 |
| 6 | `_apply_coastal_moisture_boost()` | 水邻接提升沿岸湿度。 |
| 6.5 | `_apply_orographic_moisture_boost()` | 高地正雨提升湿度。 |
| 6.6 | 保存 `base_moisture` | 季节刷新从此基线出发。 |
| 7 | `_apply_rain_shadow()` | 按纬度风带/地形做雨影干化。 |
| 8 | 再次 `_decide_terrain()` | 用湿度修正后的气候重判低地 terrain。 |
| 9 | `_generate_rivers_flow_accumulation()` | 生成 `has_river` 布尔。 |
| 10 | `_apply_river_ecology()` | 河流格加湿，部分平原翻森林/草地。 |
| 11 | `_apply_vegetation_feedback()` | terrain donor 向邻居扩散湿度，再重判部分 terrain。 |
| 12 | `_apply_shrubland_pass()` / `_apply_mangrove_pass()` / `_apply_glacier_pass()` | 过渡生态和冰川。 |
| 13 | `_apply_swamp_pass()` | 低湿热靠水区域改 `SWAMP`。 |
| 14 | `_apply_volcano_pass()` / `_apply_delta_pass()` / `_apply_oasis_pass()` / `_apply_salt_flat_pass()` / `_apply_badlands_pass()` | 永久/特殊地貌。 |
| 15 | `_apply_reef_kelp_pass()` | 海洋变体 `REEF` / `KELP` 和深海 bloom cover。 |

此顺序很重要。例如湖泊种子在 pit smoothing 之前被下沉，河流在雨影与二次 terrain 之后生成，三角洲和绿洲依赖 `has_river`，REEF/KELP 在特殊地貌之后才处理。

## 参数来源

基础地图尺寸与海平面来自 `MapConfig`：

- `width`
- `height`
- `num_continents`
- `sea_level`
- `continent_size`
- `seed`
- ocean / wind heat transport 若干运行期配置

多数生成调参来自 `ClimateProfile`：

- 大陆形状：`continent_warp_amp`、`dist_field_weight`、`noise_weight`、`meso_weight`、`offshore_amp`
- 边界衰减：`edge_falloff_start`、`edge_falloff_end`、`edge_falloff_depth`
- 大陆中心：`main_radius_min/max`、`satellite_radius_min/max`、`satellites_per_main`、placement 和 separation 系数
- 山脉：`ridge_boost_amp`
- 水文：`river_flow_percentile`、`pit_fill_max_iters`、`lake_seed_freq`、`lake_seed_threshold`、`lake_seed_depth`、`lake_seed_min_interior`
- 湿度气候：`coastal_moisture_boost`、`orographic_boost`、`rain_shadow_threshold`、`rain_shadow_factor`、`rain_shadow_lookback`
- 植被反馈：`veg_*_donor`、`veg_feedback_elev_decay`
- 海冰：`sea_ice_form_threshold`、`sea_ice_melt_threshold`、`sea_ice_terrain_threshold` 等
- 特殊地貌：`max_volcanoes`、`volcano_min_dist`、`volcano_min_land_h`

注意：`MapConfig.river_count` 仍存在，但当前 `_generate_rivers_flow_accumulation()` 不使用它。实际河流数量由流量分位 `ClimateProfile.river_flow_percentile` 间接控制。

## 噪声初始化

`_init_noise(seed_val)` 初始化四类噪声：

- `_height_noise`
  - `TYPE_SIMPLEX_SMOOTH`
  - `frequency = 0.014`
  - FBM，4 octaves
  - 用于大陆主形和海岸细节。
- `_height_warp`
  - `TYPE_SIMPLEX_SMOOTH`
  - `frequency = 0.025`
  - FBM，3 octaves
  - 用于大陆距离扰动、坐标扭曲、边缘扰动、雨影纬度 jitter。
- `_detail_noise`
  - `TYPE_SIMPLEX`
  - `frequency = 0.040`
  - FBM，3 octaves
  - 用于中频地形、山脉 ridge、离岸岛屿。
- `_moisture_noise`
  - `TYPE_SIMPLEX_SMOOTH`
  - `frequency = 0.022`
  - FBM，4 octaves
  - 用于基础湿度。

## 大陆中心

`_make_continent_centers(cfg)` 生成主大陆和卫星岛：

1. `base_radius_unit = cfg.continent_size * 0.6`。
2. 主大陆数量 `n_main = max(1, cfg.num_continents)`。
3. 卫星岛数量 `n_main * satellites_per_main`。
4. 主大陆半径在 `main_radius_min/max` 中随机，放置在 `main_placement_min/max` 范围内。
5. 卫星岛半径在 `satellite_radius_min/max` 中随机，放置范围更宽。
6. `_try_place()` 用 Poisson-like 拒绝采样避免中心过度重叠：
   - 距离必须大于 `(my_radius + other_radius) * sep_factor`。
   - 主大陆最多尝试 50 次，卫星岛最多尝试 30 次。

中心记录为 Dictionary：

```gdscript
{ "pos": Vector2, "radius": float, "kind": "main" | "satellite" }
```

## 海拔生成

`_compute_elevation(nx, ny, cfg)` 使用归一化坐标 `[0, 1]` 生成 raw elevation。

### 1. 大陆距离扰动

对每个大陆中心计算距离时加入同一低频扰动：

```text
dist_perturb = height_warp(nx * 250 + 11.3, ny * 250 - 7.1) * continent_warp_amp
```

目的：

- 让大陆边界不是圆形。
- 扰动距离值而非坐标，避免远洋区域被错误拉进大陆。

### 2. 距离场

对每个大陆中心：

```text
d = distance((nx, ny), center.pos) + dist_perturb
df = clamp(1 - d / center.radius, 0, 1)
df = pow(df, 1.5)
dist_field = max(dist_field, df)
```

多个中心取最大值，而不是相加。这样主大陆与卫星岛各自保留尺度，不容易把大陆间海峡直接焊死。

### 3. 多频 FBM 起伏

先把坐标放大到 `nx * 200` / `ny * 200`，再用 `_height_warp` 做坐标扭曲：

- `_height_noise` 提供大陆主形。
- `_detail_noise` 提供中频变化。
- 二者按 `0.70 / 0.30` 混合，映射到 `[0, 1]`。

### 4. Meso 中尺度起伏

`meso = detail_noise(nx * 400 + 137, ny * 400 - 91)` 映射到 `[0, 1]`。

它比 macro 高频，比 detail 低频，用来在大陆内部产生 plateau / valley 大块结构，避免山地只堆在大陆中心。

### 5. 海岸细节

`coast = height_noise(nx * 80 + 500, ny * 80 + 500) * 0.06`。

这是小幅海岸扰动。

### 6. 离岸群岛

```text
offshore_raw = detail_noise(nx * 900 - 333, ny * 900 + 217)
offshore = pow(max(offshore_raw - 0.55, 0), 1.5) * offshore_amp
```

只有强 spike 才能把远洋区域抬出海面，因此离岸岛屿稀疏出现。

### 7. 合成

```text
raw = dist_field * (
    dist_field_weight
  + noise_01 * noise_weight
  + meso * meso_weight
) + coast + offshore
```

关键点：噪声项乘以 `dist_field`，避免整个远洋因噪声均值被整体抬高。

### 8. 边缘衰减

用切比雪夫式边缘距离加扰动：

```text
edge_d_base = max(abs(nx - 0.5) * 2, abs(ny - 0.5) * 2)
edge_d = edge_d_base + height_warp(nx * 150 + 199, ny * 150 - 73) * 0.38
edge_t = smoothstep(edge_falloff_start, edge_falloff_end, edge_d)
raw -= edge_t * edge_falloff_depth
```

目的：

- 保证地图四周倾向海洋。
- 避免边缘海洋呈规则矩形框。

## 海拔归一化

`_normalize_elevation(map)` 扫描所有 cell 的 min/max，然后线性归一化到 `[0, 1]`。

山脉 ridge 不在 `_compute_elevation()` 内加，而是在归一化后独立执行。代码注释说明原因：如果 ridge 参与归一化，会扩大分母并压低非山地 cell，损失陆地面积。

## 湖泊种子

`_carve_lake_seeds(map, cfg)` 在归一化后、pit smoothing 前执行。

算法：

1. 创建独立 `FastNoiseLite.TYPE_SIMPLEX` 噪声，seed 为 `_last_seed + 9173`。
2. 频率 `lake_seed_freq`，FBM 3 octaves。
3. 遍历所有 cell，过滤：
   - `elevation >= sea_level + 0.04`
   - `nx/ny` 在 `lake_seed_min_interior` 到 `1 - lake_seed_min_interior` 内
   - 噪声值 `>= lake_seed_threshold`
   - 6 邻居没有低于海平面的水邻居
4. 命中的 cell：
   - `cell.elevation = sea_level - lake_seed_depth`
   - `cell.is_lake_seed = true`

这一步只是“凿低”候选格，不直接设置 `terrain = LAKE`。真正的 `LAKE` 在初步 terrain 判定后由 `_detect_lakes()` 决定。

重要后果：

- 种子下沉到海平面以下，因此随后 `_smooth_pit_depressions()` 会跳过这些格。
- 湖泊大小高度依赖噪声命中的相邻格数，没有湖盆水位、溢出口或 basin 合并逻辑。

## 洼地平滑

`_smooth_pit_depressions(map, cfg)` 迭代最多 `pit_fill_max_iters` 次。

对每个 elevation 高于海平面的陆地 cell：

1. 找最低邻居海拔。
2. 如果当前 cell 海拔 `<= lowest_nb`，认为是 pit。
3. 抬高到 `lowest_nb + 0.001`。
4. 如果一轮没有变化则提前结束。

目的：

- 消除 1-cell 或多 cell 碗形局部洼地。
- 让后续 flow accumulation 更容易沿下坡链通到水域。

限制：

- 这是局部 fill，不是 Priority-Flood。
- 它倾向消除真实内陆盆地。
- 它不计算 basin spill、湖面水位或内流流域。

## 山脉脊线

`_apply_mountain_ridges(map, cfg)` 在归一化和 pit smoothing 后执行，只作用于 `elevation >= sea_level` 的陆地。

算法：

1. 对每个陆地 cell 计算归一化坐标。
2. 用两套 ridge noise：

```text
ridge_a = 1 - abs(detail_noise(nx * 180 + 71.3, ny * 180 - 33.7))
ridge_b = 1 - abs(detail_noise(nx * 220 - 50.7, ny * 220 + 91.1))
ridge_signal = pow(max(ridge_a, ridge_b), 1.4)
```

3. 计算坡度门控：

```text
slope = cell.elevation - lowest_neighbor_elevation
slope_gate = clamp(slope * 8.0, 0.30, 1.0)
```

4. 计算陆地高度权重：

```text
land_factor = (elevation - sea_level) / (1 - sea_level)
land_factor = pow(land_factor, 1.5)
```

5. 加成：

```text
addition = ridge_signal * land_factor * slope_gate * ridge_boost_amp
```

6. 对高值做软饱和：

```text
soft_max = 0.78
land_elev_cap = 0.93
if raw_post > soft_max:
    raw_post = soft_max + (land_elev_cap - soft_max) * (1 - exp(-(raw_post - soft_max) * 3))
```

设计目标：

- 山脉在高地和坡缘上更明显。
- 高原内部不整片变山。
- 限制最高陆地海拔到约 0.93，避免 shader peak / snow 段过白。

## 温度模型

`_compute_temperature(ny, elevation)`：

1. 纬度基础温度来自 `DCClimateMath.lat_temp_bell_from_ny(ny)`。
2. 海拔惩罚：

```text
lin = elevation * 0.40
hi = smoothstep(0.45, 1.00, elevation) * 0.22
alt_penalty = lin + hi
```

3. 返回 `clamp(lat_temp - alt_penalty, 0, 1)`。

这个温度用于：

- 初始 terrain 判定。
- 雨影/生态 pass 的温度门槛。
- 三轴派生。
- 初始 temperature bootstrap。
- 海冰 bootstrap。

## 湿度模型

`_compute_moisture_base(nx, ny)` 混合两层噪声：

```text
large = moisture_noise(nx * 100, ny * 100)
small = moisture_noise(nx * 400 + 79, ny * 400 - 31)
moisture = clamp(large * 0.65 + small * 0.35, 0, 1)
```

后续湿度还会被这些 pass 改动：

- 沿岸湿度补偿
- 山地正雨
- 雨影
- 河岸生态
- 植被反馈
- 绿洲等特殊地貌

`base_moisture` 的保存点在沿岸补偿和山地正雨之后、雨影之前。代码注释称它是“无季节、无雨影、无河岸生态”的基线，但实际它已经包含 coastal boost 与 orographic boost。

## 初步 terrain 决策

`_decide_terrain(elevation, temperature, moisture, cfg, permanent_only)` 是核心分类树。

水体：

- `elevation < sea_level - 0.06` -> `OCEAN`
- `elevation < sea_level` -> `COAST`

陆地高度：

```text
land_height = (elevation - sea_level) / (1 - sea_level)
```

雪线与永久雪：

- `permanent_only=true` 用更严苛阈值，降低 bake 期永久雪数量。
- `permanent_only=false` 用更宽松阈值，供运行期季节性翻雪。

当 `permanent_only=true`：

- `snow_line = 0.85`
- `snow_line_temp = 0.26`
- `cold_snow_line = 0.70`
- `cold_snow_temp = 0.05`
- `polar_temp = -1.0`，即 bake 期关闭极地低地永久雪。

高地与寒带：

- `land_height > 0.62` -> `MOUNTAIN`
- `temperature < 0.20` -> `TUNDRA`
- `land_height > 0.22` -> `HILL`

Whittaker 风格低地：

- 热带 `temperature > 0.55`
  - `moisture > 0.65` -> `JUNGLE`
  - `moisture > 0.30` -> `SAVANNA`
  - else `DESERT`
- 暖温带 `temperature > 0.40`
  - `moisture > 0.55` -> `FOREST`
  - `moisture > 0.30` -> `GRASSLAND`
  - else `STEPPE`
- 凉温带 `temperature > 0.20`
  - `moisture > 0.40` -> `TAIGA`
  - `moisture > 0.20` -> `STEPPE`
  - else `DESERT`
- fallback -> `PLAIN`

## 湖泊检测

`_detect_lakes(map, cfg)` 在初步 terrain 判定后执行。

算法：

1. 从地图边界上的 `OCEAN` / `COAST` cell 入队。
2. BFS 只沿 `OCEAN` / `COAST` 扩散。
3. 所有没有被标记为 ocean-connected 的 `OCEAN` / `COAST` cell 改为 `LAKE`。

注意：

- 它只区分“连到边界海洋”与“不连到边界海洋”。
- 不计算湖泊连通分量大小。
- 不计算水深、湖面、溢出口、出流河。
- `LAKE` 不是通过 basin fill 得到，而是由海拔低于海平面且不连海得到。

## 沿岸湿度补偿

`_apply_coastal_moisture_boost(map)`：

1. 遍历非水 cell。
2. 统计 6 邻居中水体数量。
3. `coastal_ratio = water_nbs / total_nbs`。
4. `cell.moisture += coastal_ratio * coastal_moisture_boost`。

水体语义通过 `_is_water(cell.terrain)` 判断。

## 山地正雨

`_apply_orographic_moisture_boost(map)`：

1. 若 `orographic_boost == 0` 则 no-op。
2. 遍历非水 cell。
3. 若 `cell.elevation <= 0.30` 跳过。
4. `boost = 1 + (cell.elevation - 0.30) * orographic_boost`。
5. `cell.moisture *= boost` 并 clamp。

这与河流初始流量使用的 orographic 公式同源，但这里写回 `cell.moisture`。

## 雨影

`_apply_rain_shadow(map, cfg)` 调 `_apply_rain_shadow_per_cell(map, cfg, 1.0)`。

对每个非水 cell：

1. 计算 `ny`。
2. 用 `_height_warp` 给纬度加 jitter。
3. `_pick_upwind_dir()` 选择上风 hex 方向。
   - 若 `cell.wind_vector` 已有值，优先用它。
   - 否则回退到 `WindBelt.wind_at(ny, season_phase, jitter)`。
4. 沿上风方向走 `rain_shadow_lookback` 格。
5. 若 upwind cell 存在，且 `upwind.elevation > cell.elevation + rain_shadow_threshold`：
   - `cell.moisture *= rain_shadow_factor`

生成期调用时 `cell.wind_vector` 通常还未由 `_compute_terrain_perturbed_wind()` 生成，因此一般回退到纬度风带。

## 二次 terrain 决策

雨影后，代码再次遍历 cell：

- 跳过水体。
- 跳过 `MOUNTAIN` / `SNOW` / `TUNDRA`。
- 用更新后的 moisture 再跑 `_decide_terrain(..., permanent_only=true)`。

这一步让低地生态响应 coastal / orographic / rain shadow。

## 河流生成

`_generate_rivers_flow_accumulation(map, cfg)` 是当前唯一的初始河流生成算法。

算法：

1. 收集所有非水 cell。
2. 按 elevation 从高到低排序。
3. 对每个陆地 cell 找最低且严格更低的邻居，记录为 `downhill[cell]`。
4. 初始 flow：

```text
base_rain = lerp(0.4, 1.6, cell.moisture)
land_h = (elevation - sea_level) / (1 - sea_level)
orographic = 1 + max(land_h - 0.30, 0) * orographic_boost
flow[cell] = base_rain * orographic
```

5. 按高到低遍历，把当前 flow 加给 downhill 邻居。
6. 若 downhill 邻居是水体，则认为流量入水，不继续累积。
7. 对所有 flow 值排序，取 `river_flow_percentile` 分位值作为阈值。
8. `flow[cell] >= threshold` 的陆地 cell 标记 `cell.has_river = true`。
9. `_filter_dead_end_rivers()` 移除不能沿 downhill 链到达水体的 river cell。
10. `_filter_isolated_rivers()` 移除没有河流/水体邻居的孤立 river cell。

当前输出只有 `has_river` 布尔，未保存：

- flow accumulation 数值
- receiver/downhill index
- river id
- main stem / tributary graph
- river order
- river width
- outlet / basin 信息

## 河岸生态

`_apply_river_ecology(map, cfg)`：

- 只处理 `cell.has_river && !is_water`。
- 永久地标只加湿，不改 terrain。
- `cell.moisture = max(cell.moisture, 0.65)`。
- `DESERT` 不在此处直接翻绿，后续 `_apply_oasis_pass()` 处理。
- `PLAIN`：
  - `temp > 0.55` -> `FOREST`
  - `temp > 0.30` -> `GRASSLAND`

## 植被反馈

`_apply_vegetation_feedback(map, cfg)` 使用 terrain donor 改变邻居 moisture。

donor 来自 `ClimateProfile`：

- `FOREST`: `veg_forest_donor`
- `SWAMP`: `veg_swamp_donor`
- `GRASSLAND`: `veg_grassland_donor`
- `DESERT`: `veg_desert_donor`
- `JUNGLE`: `veg_jungle_donor`
- `TAIGA`: `veg_taiga_donor`
- `SAVANNA`: `veg_savanna_donor`
- `OASIS`: `veg_oasis_donor`
- `DELTA`: `veg_delta_donor`
- `SALT_FLAT`: `veg_salt_flat_donor`

每个 donor 乘以海拔衰减：

```text
elev_factor = clamp(1 - elevation * veg_feedback_elev_decay, 0.1, 1)
donor_eff = donor * elev_factor
```

贡献累积到非水邻居。应用 moisture delta 后，对非水、非 `MOUNTAIN`、非 `SNOW`、非永久地貌重新跑 `_decide_terrain()`。

## 沼泽

`_apply_swamp_pass(map, cfg)` 条件：

- 非水。
- 非 `MOUNTAIN` / `SNOW` / `TUNDRA`。
- 非永久地貌。
- `land_h <= 0.10`。
- `moisture >= 0.75`。
- 年均温 `temp >= 0.30`。
- 有水源：
  - `cell.has_river`，或
  - 任意邻居 `_is_water()`。

满足则 terrain -> `SWAMP`。

## 过渡生态

### Shrubland

`_apply_shrubland_pass()` 条件：

- 当前 terrain 是 `GRASSLAND` / `STEPPE` / `SAVANNA` / `PLAIN`。
- 非水，非永久地貌。
- `land_h <= 0.30`。
- `temp >= 0.50`。
- `0.25 <= moisture <= 0.40`。
- 至少一个 `OCEAN` / `COAST` 邻居。

满足则 terrain -> `SHRUBLAND`。

### Mangrove

`_apply_mangrove_pass()` 条件：

- 非水。
- 非 `MOUNTAIN` / `SNOW` / `TUNDRA` / `SWAMP`。
- 非永久地貌。
- `land_h <= 0.05`。
- `temp >= 0.65`。
- 紧邻 `COAST`。
- `cell.has_river` 或邻接 `SWAMP`。

满足则 terrain -> `MANGROVE`。

### Glacier

`_apply_glacier_pass()` 只替换 `SNOW` / `TUNDRA`。

条件：

- 非水。
- `temp < 0.05`。
- 且满足以下之一：
  - 沿海冰舌：`land_h < 0.20` 且邻接 `OCEAN` / `COAST` / `SEA_ICE`
  - 高山冰川：`land_h > 0.65`

满足则 terrain -> `GLACIER`。

## 特殊地貌

### Volcano

`_apply_volcano_pass()`：

- 候选必须是 `MOUNTAIN`。
- `land_h >= volcano_min_land_h`。
- 用 `_last_seed + 7717` 洗牌。
- greedy 放置，任意两个火山 cube 距离至少 `volcano_min_dist`。
- 最多 `max_volcanoes` 个。
- 输出是 `cell.has_volcano = true`，不替换 terrain。

后续 `_derive_landform()` 看到 `has_volcano` 会输出 `LandformType.LF.VOLCANO`。

### Delta

`_apply_delta_pass()`：

- 非水。
- `cell.has_river`。
- 非永久地貌。
- `land_h <= 0.08`。
- 至少一个 `OCEAN` / `COAST` 邻居。

满足则 terrain -> `DELTA`。

### Oasis

`_apply_oasis_pass()`：

- 非水。
- 非永久地貌。
- 非 `MOUNTAIN` / `SNOW` / `TUNDRA` / `GLACIER`。
- `base_moisture <= 0.30`。
- `temp >= 0.40`。
- `cell.has_river` 或邻接 `LAKE`。

满足则：

- `cell.moisture = max(cell.moisture, 0.55)`
- terrain -> `OASIS`

### Salt Flat

`_apply_salt_flat_pass()`：

- 当前 terrain 必须是 `DESERT`。
- `land_h <= 0.12`。
- 当前 cell 没有 river。
- 1-ring 内没有 river 或水体。

满足则 terrain -> `SALT_FLAT`。

注释提到 r=2，但当前实现只检查 1-ring 邻居。

### Badlands

`_apply_badlands_pass()`：

- 当前 terrain 必须是 `DESERT`。
- 计算 cell + 邻居 elevation 的 `max - min`。
- relief >= `0.025`。

满足则 terrain -> `BADLANDS`。

## 海洋变体

`_apply_reef_kelp_pass()` 只处理 `OCEAN` / `COAST`。

### Reef

条件：

- 有陆地邻居。
- `temp > 0.60 - widen`。
- 不是河口邻接，即没有陆地邻居 `has_river`。
- 当前 terrain 是 `COAST`。

满足则 terrain -> `REEF`。

### Kelp

条件：

- 有陆地邻居。
- `0.30 - widen <= temp <= 0.55 + widen`。
- 当前 terrain 是 `COAST`。

满足则 terrain -> `KELP`。

### Upwelling widen

如果 `cfg.enable_ocean_heat_transport` 且 `cell.upwelling_strength > 0.4` 且有陆地邻居：

```text
widen = 0.08
```

但注意初始 `_apply_reef_kelp_pass()` 在 `_generate_cells()` 内执行，此时 physical circulation 通常还没有由 `MapBaker` 完成，`upwelling_strength` 多数情况下仍是默认值。

### Pelagic bloom

若 ocean enabled，当前是深海 `OCEAN`，没有陆地邻居，`upwelling_strength > 0.6`，则：

- `cell.cover = CoverType.CV.PELAGIC_BLOOM`

同样受初始 upwelling 是否已有值影响。

## 海冰 bootstrap

`_bootstrap_sea_ice_fraction(map, cfg)` 在 `_generate_cells()` 完成、`base_*` 快照之后执行。

处理对象：

- 仅水体。
- `LAKE` 强制 `sea_ice_fraction = 0`，淡水湖不在此处结冰。

计算：

- 若 `temp_ref < sea_ice_form_threshold`，按距离阈值给 fraction，并 smoothstep。
- 若 `temp_ref > sea_ice_melt_threshold`，fraction = 0。
- 中间迟滞带线性过渡，并乘以 0.35。
- 若 solar gate 开启，用年均 insolation 进一步压制。
- 仅 `polar_w >= 0.78 && temp_ref < form_threshold * 0.85` 的稳定极地多年冰可以在生成期直接 terrain -> `SEA_ICE`。
- 非稳定 pack 即使 fraction 达阈值，也被压到阈值以下，让 daily pass 后续推进。

生成后会再次 `_sync_axes_for_map()`，更新 `landform/vegetation/cover`。

## 三轴派生

当前生成期间 terrain 仍是工作源，最终通过 `_sync_axes_for_map()` 派生：

- `landform`
- `vegetation`
- `cover`

### Landform

`_derive_landform(cell, cfg)`：

1. `has_volcano` 优先 -> `VOLCANO`。
2. `terrain == LAKE` -> `LAKE`。
3. `OCEAN` / `COAST` / `REEF` / `KELP` / `SEA_ICE` 视为 marine，按海拔相对 sea level 分：
   - `< sea * 0.55` -> `DEEP_OCEAN`
   - `< sea * 0.92` -> `OCEAN`
   - else -> `COAST`
4. 特殊地貌：
   - `DELTA` -> `DELTA`
   - `BADLANDS` -> `BADLANDS`
   - `SALT_FLAT` -> `SALT_FLAT`
5. 陆地按 `land_h`：
   - `> 0.82` -> `PEAK`
   - `> 0.62` -> `MOUNTAIN`
   - `> 0.22` -> `HILL`
   - `> 0.05` -> `LOWLAND`
   - else -> `PLAIN`

### Vegetation

`_derive_vegetation(cell, landform, temperature)`：

- `OCEAN` / `COAST` / `LAKE` / `SEA_ICE` -> `NONE`
- `REEF` -> `CORAL_REEF`
- `KELP` -> `KELP_FOREST`
- `GLACIER` -> `NONE`
- `SNOW` 按下层地貌给 alpine tundra / polar desert / none
- `PEAK` -> `NONE`
- 特殊 terrain 映射：
  - `DELTA` -> `MARSH` 或 `MANGROVE`
  - `OASIS` -> `OASIS_VEG`
  - `SALT_FLAT` -> `NONE`
  - `BADLANDS` -> `DESERT_SCRUB`
  - `SWAMP` -> `SWAMP`
  - `MANGROVE` -> `MANGROVE`
  - `SHRUBLAND` -> `MEDITERRANEAN_SHRUB`
- `HILL` / `MOUNTAIN` / `PLAIN` 会重新按 Whittaker vegetation 判定，而不是直接等于 terrain。
- 普通 `FOREST/JUNGLE/SAVANNA/GRASSLAND/STEPPE/DESERT/TAIGA/TUNDRA` 各自映射到更细 vegetation。

### Cover

`_derive_cover(cell, snow_cover)`：

- `terrain == GLACIER` -> `CoverType.CV.GLACIER`
- `terrain == SEA_ICE` -> `CoverType.CV.SEA_ICE`
- `terrain == SNOW` -> `CoverType.CV.SNOW`
- 若 `snow_cover > 0.5 && !is_water` -> `SNOW`
- `terrain == TUNDRA` -> `PERMAFROST`
- else `NONE`

## Base 快照

`_snapshot_base_state(map)` 在第一次三轴派生后、海冰 bootstrap 前执行：

- `cell.base_terrain = cell.terrain`
- `cell.base_landform = cell.landform`
- `cell.base_vegetation = cell.vegetation`

注意：

- 海冰 bootstrap 可能之后把 terrain 改成 `SEA_ICE`，但 `base_terrain` 保持海冰形成前的值，用于融化回退。
- 运行期 sea-ice daily pass 也只动 `terrain`，不动 `base_terrain`。

## `MapBaker` 视觉烘焙

`MapBaker.bake_world()` 在逻辑生成结束后运行。

主要地形相关产物：

- `world.height_buffer`
- `world.biome_buffer`
- `world.moisture_buffer`
- `world.vegetation_buffer`
- `world.cover_buffer`
- `world.flow_buffer`
- `world.latitude_buffer`
- `world.height_tex`
- `world.enum_atlas_tex`
- `world.scalar_atlas_tex`

顺序：

1. 计算 `world.world_bounds`、`hm_size`、`derived_size`。
2. `_bake_height_biome_moisture()` 一次性生成 height / biome / moisture / vegetation / cover pixel buffers。
3. `_hydraulic_erosion(world.height_buffer, hm_flow_dummy, hm_size)` 对像素高度图做轻度侵蚀。
4. `_bake_river_sdf()` 从 `cell.has_river` 链生成河流 SDF。
5. `_bake_latitude_buffer()`。
6. `_bake_initial_physical_circulation()` 和 `_bake_initial_vector_buffers()`。
7. volcano field、dynamic atlases、ice state atlas。
8. `_encode_height_tex()`。
9. `_encode_enum_atlas()`：打包 biome / vegetation / cover。
10. `_encode_scalar_atlas()`：打包 moisture / flow / latitude。

## 河流视觉 SDF

`_bake_river_sdf(map, hex_size, bounds, res)`：

1. 初始化距离 mask 为 INF。
2. `_trace_all_rivers()` 遍历所有 `cell.has_river` 且非终端水体的 cell。
3. 若 cell 未 visited，调用 `_trace_river_chain()`。
4. chain 通过 `_find_downhill_river_neighbor()` 逐步找严格更低的 `has_river` 邻居。
5. 若遇到已 visited 的主河道，把合流点追加后停止。
6. 末尾若邻接终端水体，把河尾延伸到水体中心 78% 处。
7. 对 chain 做 Catmull-Rom densify。
8. `_warp_river_chain()` 加低频/高频扰动，让河道更自然弯曲。
9. `_stamp_polyline_binary()` 栅格化。
10. `_chamfer_sdt()` 生成距离场。
11. 输出 `[0, 1]`，其中 1 是河心，0 是距离超过 `SDF_MAX_DIST_PX`。

关键限制：

- 视觉追踪仍只读 `has_river` 布尔和严格下坡邻居。
- 没有 river width / discharge。
- 没有 river id / graph。
- 支流和主流合并靠 `visited` 字典近似处理。

## Atlas 打包

`scalar_atlas_tex`：

- R = moisture
- G = flow / river SDF
- B = latitude
- A = 0 reserved

`enum_atlas_tex`：

- 当前调用传入 biome / vegetation / cover 三个 buffer。具体通道编码在 `_encode_enum_atlas()` 内。

海冰不再放在 scalar atlas A 通道，默认也不再生成独立全零 `sea_ice_tex`，主地图海冰视觉由 shader / dynamic state 相关路径处理。

## SoA 与 DataCore 同步

`map.init_soa_from_bake()` 调 `rebuild_soa_from_cells()`：

- 若索引未构建，先 `_build_indices()`。
- `_alloc_soa(n)`。
- 遍历 `_cell_array`，复制 AoS 到 PackedArray：
  - 连续字段：温度、湿度、雪盖、海冰、天气、海拔、base moisture、洋流、风、SLP、upwelling、位置等。
  - enum 字段：`terrain_arr`、`landform_arr`、`vegetation_arr`、`base_terrain_arr`、`base_landform_arr`、`base_vegetation_arr`、`cover_arr`、weather types。
  - 水体：`is_water_arr[i] = MapData.terrain_is_water_u8(terrain_arr[i])`。
  - 河流：`has_river_arr[i] = 1 if c.has_river else 0`。
  - runtime anomaly 字段初始化为 0。
  - prev buffers 初始化为当前快照。

随后 `_setup_sus()`：

- 创建 `DCWorld`。
- `DCWorld.bind_map_data(map)`。
- 若 `DCWorldExt` 存在，`DCWorldExt.bind_map_data(map)`。
- 将 `DCWorldExt` 注入 `MapBaker`，供后续 physical / atlas / C++ pass 使用。

## Schema 中的生成字段

`component_schema.gd` 中 owner 为 `map_generation` 的核心字段包括：

- `cell.elevation`
- `cell.base_moisture`
- `cell.wind_x`
- `cell.wind_y`
- `cell.pos_x`
- `cell.pos_y`
- `cell.lat_norm`
- `cell.temp_baseline_year`
- `cell.terrain`
- `cell.landform`
- `cell.vegetation`
- `cell.base_terrain`
- `cell.base_landform`
- `cell.base_vegetation`
- `cell.cover`
- `cell.is_water`
- `cell.has_river`

这表示它们已经是 DataCore 可见 slot，但不表示初始生成已由 C++ 计算。

## 水体语义

当前工程存在几层水体语义：

- `TerrainType` / terrain profile：通行性和显示语义。
- `LandformType.LF.is_water`：几何地貌轴的水体语义。
- `MapData.terrain_is_water()` / `is_water_arr`：物理水体 mask，供气候、海洋、天气使用。
- 渲染和部分 C++ pass 的 LUT：注释中经常强调 `OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE` 都应按水域处理。

需要注意当前 `MapData.terrain_is_water()` 函数体只显式列出 `OCEAN/COAST/LAKE`，而同文件注释写明 `REEF/SEA_ICE/KELP` 也应为 water。部分运行期 C++ / shader / LUT 可能另有包含扩展水体的逻辑。维护时应谨慎核对具体消费路径。

## 运行期地形改写

初始生成结束后，terrain / cover 仍可能被改写：

### Season refresh

`SeasonRefreshSystem` / `SeasonRefreshJob` 调用 `MapGenerator.run_season_refresh_stage*`。

相关阶段会重用或 native 化以下逻辑：

- moisture / rain shadow / terrain redecide
- river ecology
- vegetation feedback
- shrubland
- mangrove
- glacier
- swamp
- oasis / salt flat / badlands 等部分阶段

多数 stage 现在优先尝试 `DCWorldExt.run_season_refresh_stage()` 或 `run_season_refresh_micro_pass()`，失败回退 GDScript。

### Sea ice daily

海冰 daily pass 读 `sea_ice_fraction`、`base_terrain` 等，必要时：

- `terrain -> SEA_ICE`
- `terrain -> base_terrain`

该过程通过 `_set_cell_runtime_terrain()` 或 indexed batch 更新：

- `cell.terrain`
- `map.terrain_arr`
- `map.landform_arr`
- `map.cover_arr`
- `map.is_water_arr`
- dirty mask / atlas 更新信号

`base_terrain` 运行时不随海冰翻转改变。

### Weather / snow / cover

天气、雪盖和 albedo 相关路径会读写 snow cover / snowpack / cover dirty，部分天气分发可能影响 `cover`，但慢层 `base_*` 仍由 season refresh 管控。

## `_set_cell_runtime_terrain()`

这是运行期/生成期统一 terrain 写入 helper。它负责：

- 设置 `cell.terrain`。
- 如果要求 `sync_axes`，同步 `landform`、`vegetation`、`cover`。
- 若 SoA 已构建，写 `map.terrain_arr` / `landform_arr` / `cover_arr` / `is_water_arr`。
- 设置 dirty 标记，让 enum atlas / dynamic atlas 后续刷新。

生成期早期 SoA 未构建时，它主要写 `HexCell`；运行期则必须保持 AoS、SoA、DataCore dirty 一致。

## 当前算法特征

优点：

- 大陆形状不是纯噪声，已有主大陆 + 卫星岛 + 边缘海洋约束。
- 山脉在 normalize 后独立叠加，减少对陆地面积的副作用。
- terrain 分类结合 elevation、temperature、moisture，基础生态带较完整。
- 引入 coastal moisture、orographic boost、rain shadow、vegetation feedback，让生态不是一次性噪声散点。
- terrain / landform / vegetation / cover 三轴已经解耦，后续表现和玩法可读更细语义。
- 运行期已经大量 DataCore / C++ 化，初始结果会同步到 schema slot。

主要限制：

- 初始地形/水文生成仍由 GDScript AoS 权威，不符合“生成 hot-loop C++/DOTS 权威”的目标。
- 河流只有 `has_river` 布尔，没有河网图、流量输出、river order、宽度或主支流关系。
- 河流阈值是全图分位，不是基于真实 drainage area / discharge 的局部门槛。
- 河流视觉从 `has_river` 严格下坡追踪，容易短段化、断裂或缺少主干连续性。
- 湖泊由 seed 下沉 + ocean-connected BFS 得到，没有 basin、spill elevation、water level、outlet。
- pit smoothing 会消除大量真实内陆盆地，但 lake seed 又会绕过 smoothing，导致湖泊偏离真实水文。
- `MapConfig.river_count` 是历史字段，当前主河流算法不使用。
- 部分水体语义在注释和函数体之间存在不一致，需要按消费路径核对。
- reef/kelp 的 upwelling 条件在初始生成期可能读到默认值，因为 physical circulation 在 bake 中更晚完成。

## 为后续重构保留的事实清单

若要迁移到更真实的 C++/DOTS 水文和地形生成，应至少保留或替代以下当前契约：

1. `MapGenerator.generate()` 需要在 `MapBaker.bake_world()` 前得到稳定的 `terrain/landform/vegetation/cover/elevation/has_river`。
2. `MapData.init_soa_from_bake()` 需要能从最终生成结果初始化所有 SoA。
3. `component_schema.gd` 已有 `cell.has_river`，但缺少 flow / receiver / river_id / lake_id / lake_depth 等更真实水文字段。
4. `MapBaker._bake_river_sdf()` 当前只消费 `cell.has_river`，若引入 river graph，需要改 baker。
5. 海冰、季节刷新、天气系统依赖 `base_terrain` 与 runtime `terrain` 的区别。
6. `LAKE` 当前是 terrain enum，而不是单独 lake component。
7. 水体 mask 必须同步到 `is_water_arr`，否则气候、海洋、天气和 atlas dirty 路径会不一致。
8. 运行期 C++ pass 写 slot 后必须 flush / dirty mark，不能只修改 C++ 内部数组。

