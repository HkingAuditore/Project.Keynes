# 当前地形生成算法文档

本文总结 Project.Keynes 当前实际运行的初始地形生成算法：每一步做什么、使用什么算法、在哪个函数里实现、最终数据如何进入渲染和运行期 SoA/DataCore。

当前状态：**初始地形生成已 100% C++/GDExtension 化**。`MapGenerator.generate()` 负责流程编排，权威地形、水文、生态和特殊地貌生成在 `gdext/src/world_ext.cpp`。旧 GDScript `_generate_cells` 和后处理 fallback 已删除，native 失败会直接中止生成。

## 关键源码入口

| 职责 | 文件 | 函数 |
| --- | --- | --- |
| 世界生成入口 | `Project/project-keynes/scripts/geography/map_generator.gd` | `generate()` |
| native 生成桥 | `Project/project-keynes/scripts/geography/map_generator.gd` | `_generate_cells_native_base()` |
| native 结果装配 | `Project/project-keynes/scripts/geography/map_generator.gd` | `_assemble_native_generation_map()` |
| C++ base 生成 | `gdext/src/world_ext.cpp` | `DCWorldExt::run_native_world_generate_base_pass()` |
| C++ post-base 后处理 | `gdext/src/world_ext.cpp` | `DCWorldExt::run_native_world_generate_post_base_pass()` |
| C++ 同源 helper | `gdext/src/world_ext.cpp` | `pk_compute_temperature()` / `pk_decide_terrain_ex()` / `pk_derive_*()` |
| GDScript 运行期 helper | `Project/project-keynes/scripts/geography/map_generator.gd` | `_compute_temperature()` / `_decide_terrain()` / `_derive_*()` |
| 渲染烘焙入口 | `Project/project-keynes/scripts/rendering/map_baker.gd` | `bake_world()` |
| 视觉高度/biome 上采样 | `Project/project-keynes/scripts/rendering/map_baker.gd` | `_bake_height_biome_moisture()` |
| 河流视觉 SDF | `Project/project-keynes/scripts/rendering/map_baker.gd` | `_bake_river_sdf()` / `_trace_river_chain()` |
| SoA 镜像 | `Project/project-keynes/scripts/geography/map_data.gd` | `_build_indices()` / `init_soa_from_bake()` |
| 枚举定义 | `Project/project-keynes/scripts/geography/terrain_type.gd` | `TerrainType.TERRAIN` |
| 三轴定义 | `Project/project-keynes/scripts/geography/landform_type.gd` / `vegetation_type.gd` / `cover_type.gd` | `LandformType.LF` / `VegetationType.VEG` / `CoverType.CV` |
| 生成参数 | `Project/project-keynes/scripts/data/climate_profile.gd` | `continent_*` / `river_*` / `lake_*` / `veg_*` 等 |

## 总体数据边界

当前初始地图生成分三层：

1. **C++ base pass**：`run_native_world_generate_base_pass()` 生成基础 per-cell 数组，包括 cube 坐标、海拔、湿度、温度、初始 terrain、初始三轴、湖泊种子标记。
2. **C++ post-base pass**：`run_native_world_generate_post_base_pass()` 基于 base 输出继续做湖泊连通、雨影、河流、河岸生态、植被反馈、特殊地貌、reef/kelp，返回最终 per-cell 数组。
3. **GDScript 装配和运行期接入**：`_assemble_native_generation_map()` 只校验数组并创建 `MapData` / `HexCell`；`MapBaker` 负责视觉烘焙；`MapData.init_soa_from_bake()` 把 HexCell AoS 同步到 SoA；`_setup_sus()` 绑定 DataCore / C++ runtime。

## 顶层生成流程

入口函数：`await MapGenerator.generate(cfg, hex_size)`。生成在 Godot 主线程协作式执行，并在重阶段边界让帧；不要不带 `await` 调用，也不要把包含 Godot 对象/纹理上传的整条链直接迁入 worker。

1. `cfg.validate()` 校验地图配置。
2. 解析 seed：`cfg.seed != 0` 时使用配置 seed，否则 `randi()`。
3. 初始化 `_rng` 和 `_init_noise(seed)`。GDScript 侧现在只保留 `_height_warp`，用于运行期雨影 jitter 桥接；初始生成噪声在 C++ 内创建。
4. 调 `_generate_cells_native_base(cfg, seed)`。
5. `_generate_cells_native_base()` 调 `DCWorldExt.run_native_world_generate_base_pass(seed, cfg_dict, profile_dict)`。
6. base 成功后调 `DCWorldExt.run_native_world_generate_post_base_pass(seed, cfg_dict, profile_dict, base_res)`。
7. post-base 成功后调 `_assemble_native_generation_map()` 创建 `MapData` 和 `HexCell`。
8. `_snapshot_base_state(map)` 保存 `base_terrain / base_landform / base_vegetation`。
9. `_bootstrap_sea_ice_fraction(map, cfg)` 初始化海冰连续覆盖率，稳定极地多年冰可把 `terrain` 翻成 `SEA_ICE`。
10. `_sync_axes_for_map(map, cfg)` 因海冰可能改写 terrain，重新派生三轴。
11. `map._build_indices()` 在 bake 前建立 cell index 和邻居索引。
12. 对每个 cell bootstrap 温度和 `current_state`。
13. `MapBaker.bake_world(map, cfg, hex_size, seed)` 烘焙视觉高度图、enum atlas、scalar atlas、河流 SDF 和物理环流。
14. `_compute_ocean_currents()` 在非 physical-hex 路径下从像素洋流回采到 cell。
15. `_compute_terrain_perturbed_wind()` 在非 physical-hex 路径下生成 per-cell 地形扰动风。
16. 初始化 `WeatherSystem`。
17. 再次 `map._build_indices()`，然后 `map.init_soa_from_bake()`。
18. `map.bake_lat_temp_year_lut(self)`，最后 `_setup_sus(map, world, cfg, hex_size)` 进入运行期。

## 参数与噪声

基础配置来自 `MapConfig`：`width`、`height`、`num_continents`、`sea_level`、`continent_size`、`seed`。

主要生成调参来自 `ClimateProfile`：

| 类别 | 字段 |
| --- | --- |
| 大陆形状 | `continent_warp_amp`、`dist_field_weight`、`noise_weight`、`meso_weight`、`offshore_amp` |
| 边界海洋化 | `edge_falloff_start`、`edge_falloff_end`、`edge_falloff_depth` |
| 大陆中心 | `main_radius_min/max`、`satellite_radius_min/max`、`satellites_per_main`、`main_placement_min/max`、`satellite_placement_min/max`、`*_separation_factor` |
| 水文 | `river_channel_init_cells`、`river_headwater_init_cells`、`river_headwater_min_land_h`、`river_flow_percentile`、`hydro_river_min_length`、`hydro_lake_min_cells`、`hydro_lake_min_depth`、`hydro_lake_min_volume`、`pit_fill_max_iters`、`lake_seed_freq`、`lake_seed_threshold`、`lake_seed_depth`、`lake_seed_min_interior` |
| 湿度耦合 | `coastal_moisture_boost`、`orographic_boost`、`rain_shadow_threshold`、`rain_shadow_factor`、`rain_shadow_lookback` |
| 植被反馈 | `veg_forest_donor`、`veg_swamp_donor`、`veg_grassland_donor`、`veg_desert_donor`、`veg_jungle_donor`、`veg_taiga_donor`、`veg_savanna_donor`、`veg_oasis_donor`、`veg_delta_donor`、`veg_salt_flat_donor`、`veg_feedback_elev_decay` |
| 特殊地貌 | `max_volcanoes`、`volcano_min_dist`、`volcano_min_land_h`、`plateau_min_land_h`、`plateau_max_relief`、`plateau_min_cells`、`mountain_min_land_h`、`mountain_min_relief`、`peak_min_land_h`、`peak_min_prominence`、`peak_land_cells_per_peak` |
| 海冰 | `sea_ice_form_threshold`、`sea_ice_melt_threshold`、`sea_ice_terrain_threshold`、`sea_ice_terrain_hysteresis`、`sea_ice_freeze_insol_*` |

C++ base pass 使用的 `FastNoiseLite`：

| 噪声 | 类型 | 参数 | seed | 用途 |
| --- | --- | --- | --- | --- |
| `height_noise` | `TYPE_SIMPLEX_SMOOTH` | `frequency=0.014`，FBM 4 octaves | `seed` | 大陆主形、海岸细节 |
| `height_warp` | `TYPE_SIMPLEX_SMOOTH` | `frequency=0.025`，FBM 3 octaves | `seed + 13` | 大陆距离扰动、坐标 warp、边界扰动、雨影 jitter |
| `detail_noise` | `TYPE_SIMPLEX` | `frequency=0.040`，FBM 3 octaves | `seed + 257` | 中尺度地形、山脉 ridge、离岸岛屿 |
| `moisture_noise` | `TYPE_SIMPLEX_SMOOTH` | `frequency=0.022`，FBM 4 octaves | `seed + 9973` | 基础湿度 |
| `lake_noise` | `TYPE_SIMPLEX` | `frequency=lake_seed_freq`，FBM 3 octaves | `seed + 9173` | 湖泊种子 |

## C++ Base Pass 详细流程

实现函数：`DCWorldExt::run_native_world_generate_base_pass()`。

### 0. 输入校验

函数读取 `cfg.width / height / sea_level / continent_size / num_continents`，校验 cell 数量不超过 `1,000,000`。再从 `profile` 读取大陆、山脉、水文和湿度参数。失败时返回 `rc=-1` 和 `fail_stage`；成功时返回 `rc=0`、`path=gdext`、`native_algorithm=hydrology_basin_seed_v2`。

### 1. 大陆中心生成

实现位置：`run_native_world_generate_base_pass()` 内部的 `Center`、`try_place` 和主大陆/卫星岛循环。

算法：

1. 使用 Godot `RandomNumberGenerator`，seed 为 `seed`，保证与原 GDScript 同源。
2. `base_radius_unit = continent_size * 0.6`。
3. 主大陆数量 `n_main = max(1, num_continents)`。
4. 卫星岛数量 `n_main * satellites_per_main`。
5. 主大陆半径从 `main_radius_min/max` 随机，放置范围 `main_placement_min/max`，最多尝试 50 次。
6. 卫星岛半径从 `satellite_radius_min/max` 随机，放置范围 `satellite_placement_min/max`，最多尝试 30 次。
7. `try_place()` 用拒绝采样避免中心过近：候选点到已有中心距离必须大于 `(radius + existing.radius) * sep_factor`。

这是 Poisson-like 的简化拒绝采样，不做全局最优化；多次失败的中心会跳过。

### 2. 坐标与原始海拔

实现位置：`run_native_world_generate_base_pass()` 的 `coords + elevation` 双层循环。

每个 cell 按 row-major 遍历：

1. offset 坐标 `(col,row)` 转 cube 坐标：`q = col - ((row - (row & 1)) / 2)`，`r = row`，`s = -q-r`。
2. `cell_lat_norm = row / max(height - 1, 1)`。
3. `nx = col / max(width - 1, 1)`，`ny = row / max(height - 1, 1)`。

海拔由以下信号合成：

1. **大陆距离扰动**：`dist_perturb = height_warp(nx*250+11.3, ny*250-7.1) * continent_warp_amp`。扰动距离值，让海岸线不规则，同时避免直接扭曲坐标把远洋拉进大陆。
2. **大陆距离场**：对每个大陆中心计算 `df = pow(clamp(1 - (distance + dist_perturb) / radius, 0, 1), 1.5)`，多个中心取最大值。取最大而非相加，可以保留主大陆和卫星岛的独立尺度。
3. **多频 FBM 起伏**：坐标放大到 `nx*200 / ny*200` 后，用 `height_warp` 扭曲采样点；`height_noise` 与 `detail_noise` 按 `0.70 / 0.30` 混合，映射到 `[0,1]`。
4. **中尺度 meso 起伏**：`detail_noise(nx*400+137, ny*400-91)` 映射到 `[0,1]`，产生高原/谷地大块结构。
5. **海岸细节**：`height_noise(nx*80+500, ny*80+500) * 0.06`。
6. **离岸群岛**：`pow(max(detail_noise(nx*900-333, ny*900+217) - 0.55, 0), 1.5) * offshore_amp`，只有强 spike 才抬出水面。
7. **边界衰减**：按 `edge_falloff_start/end/depth` 对靠近地图边缘的位置做 smoothstep 扣减，让地图边缘倾向于海洋。

合成公式核心是：

```text
raw = dist_field * (dist_field_weight + noise_01*noise_weight + meso*meso_weight)
    + coast
    + offshore
    - edge_falloff
```

### 3. 海拔归一化

实现位置：base pass 的 `normalize` block。

扫描全图 `min_e / max_e`，若范围大于 `0.001`，把所有海拔线性映射到 `[0,1]`：

```text
E[i] = (E[i] - min_e) / (max_e - min_e)
```

山脉 ridge 在归一化后才加，避免 ridge 扩大分母、压低普通陆地。

### 4. 湖泊种子下沉

实现位置：base pass 的 `carve lake seeds` block。

算法：

1. 创建 `is_lake_seed_arr`，初始全 0。
2. 第一阶段只标记候选，不立刻下沉海拔。这样同一个低频湖盆里的相邻候选不会被“刚凿出的水邻居”互相排斥成碎小湖。
3. 候选条件：
   - `E[idx] >= sea_level + 0.04`
   - `nx/ny` 不在地图边缘带外，边缘带由 `lake_seed_min_interior` 控制
   - `lake_noise(q, r) >= lake_seed_threshold`
   - 6 邻没有低于海平面的水邻居
4. 第二阶段统一把所有候选格下沉到 `sea_level - lake_seed_depth`。

这一步不直接设置 `terrain=LAKE`；真正湖泊由 post-base 连通分量检测决定。

### 5. 洼地平滑

实现位置：base pass 的 `smooth pit depressions` block。

算法是迭代式 pit fill：

1. 最多迭代 `pit_fill_max_iters` 次。
2. 对每个陆地格，如果 `E[idx] <= lowest_neighbor_elevation`，抬到 `lowest_neighbor + 0.001`。
3. 某轮没有改动则提前结束。

目的不是做真实水文侵蚀，而是消除局部无出口洼地，帮助后续河流 flow accumulation 找到下坡路径。

### 6. 山脉脊线

实现位置：base pass 的 `mountain ridges` block。

只作用于 `E >= sea_level` 的陆地格，且 `ridge_boost_amp > 0` 时启用。

算法：

1. 两套 ridge noise：`ridge_a = 1 - abs(detail_noise(nx*180+71.3, ny*180-33.7))`，`ridge_b = 1 - abs(detail_noise(nx*220-50.7, ny*220+91.1))`。
2. `ridge_signal = pow(max(ridge_a, ridge_b), 1.4)`，形成两组不同走向山脉链。
3. 计算局部坡度 `slope = E[idx] - lowest_neighbor_elevation`。
4. `slope_gate = clamp(slope * 8.0, 0.30, 1.0)`。
5. `land_factor = pow((E - sea_level)/(1-sea_level), 1.5)`。
6. `addition = ridge_signal * land_factor * slope_gate * ridge_boost_amp`。
7. 加回海拔后做软上限：超过 `soft_max=0.78` 的部分用指数压缩，最终 clamp 到 `land_elev_cap=0.93`。

### 7. 基础湿度与初步 terrain

实现位置：base pass 的 `moisture base + 初判地形` 循环。

湿度：

```text
large = (moisture_noise(nx*100, ny*100) + 1) * 0.5
small = (moisture_noise(nx*400+79, ny*400-31) + 1) * 0.5
moisture = clamp(large*0.65 + small*0.35, 0, 1)
```

温度由 `pk_compute_temperature(ny, elevation, sea_level)` 计算：

1. `pk_lat_temp_bell((ny - 0.5) * 2)` 得到纬度钟形温度，当前指数 `PK_LAT_TEMP_CURVE_EXP = 1.3`。
2. `land_h = clamp((elevation - sea_level) / (1 - sea_level), 0, 1)`，先得到海平面以上的相对高度。
3. `temp_height = lerp(land_h, clamp(elevation, 0, 1), 0.25)`，保留少量绝对海拔冷却锚点，避免纯 `land_h` 过热。
4. `pk_alt_penalty(temp_height)` 扣海拔降温：线性项 `temp_height*0.40`，高山项 `smoothstep(0.45, 1.00, temp_height)*0.22`。
5. `temperature = clamp(lat_temp - alt_penalty, 0, 1)`。

初步地形由 `pk_decide_terrain_ex(elevation, temperature, moisture, sea_level, permanent_only=true)` 决定：

1. `elevation < sea_level - 0.06` -> `OCEAN`
2. `elevation < sea_level` -> `COAST`
3. `land_h = (elevation - sea_level)/(1-sea_level)`
4. 永久雪线：`land_h > 0.85 && temp < 0.26` 或 `land_h > 0.70 && temp < 0.05` -> `SNOW`
5. `land_h > 0.70`（生成期永久地形为 `>0.72`）-> `MOUNTAIN`
6. `temperature < 0.20` -> `TUNDRA`
7. 中低海拔不再直接落成 `HILL` terrain；丘陵由 `LandformType.LF.HILL` 表达。
8. 低地按 Whittaker 风格分类：
   - `temp > 0.55`：湿度 `>0.65 JUNGLE`，`>0.36 SAVANNA`，`>0.20 STEPPE`，否则 `DESERT`
   - `temp > 0.38`：湿度 `>0.55 FOREST`，`>0.32 GRASSLAND`，`>0.20 STEPPE`，否则 `DESERT`
   - 凉温带：湿度 `>0.45 TAIGA`，`>0.22 STEPPE`，否则 `COLD_DESERT`

### 8. 沿岸湿度、副热带干带与迎风坡增湿

实现位置：base pass 的 `coastal + orographic moisture` block。

沿岸湿度：当前权威路径使用 `dist_ocean` 全向距离地板，`moisture_coastal_floor` 按 `moisture_coastal_scale` 随距海指数衰减，近海陆格保底湿润，深内陆保留干燥梯度。

副热带干带：`moisture_subtropical_dry_strength / center / width` 在南北副热带纬度扣湿，并乘以距海大陆度，恢复稳定的热带/暖温带荒漠带；近海格受沿海地板保护，不会被整片抽干。

迎风/高地正雨已合入纬向水汽扫描的 rain-out 与 orographic gain，不再额外跑旧的 6 邻加湿棘轮。

### 9. 初始数组和三轴派生

实现位置：base pass 的 `初始仿真字段 + base 快照 + 轴派生` 循环。

写入：

- `base_terrain = terrain`
- `is_water = pk_is_water_terrain(terrain)`
- `base_moisture = moisture`
- `temp / temp_baseline / temp_30d / temp_365d / thermal_energy = pk_compute_temperature(...)`
- `temp_anomaly = 0`
- `temp_baseline_year = pk_lat_temp_bell(...)`
- `snow_cover = 0`
- `ema_initialized = 1`
- `landform = pk_derive_landform(...)`
- `vegetation = pk_derive_vegetation(...)`
- `cover = pk_derive_cover(...)`

post-base 末尾还会重新派生三轴，因为后处理会继续改写 terrain。

## C++ Post-Base Pass 详细流程

实现函数：`DCWorldExt::run_native_world_generate_post_base_pass()`。

它接收 base pass 的 PackedArray，补齐缺失数组，构建邻接表 `NB[n*6]`，然后完成湖泊、水文、生态和特殊地貌。

### 1. 输入补齐与邻接表

实现位置：post-base 函数开头到 `sync_axes` lambda。

步骤：

1. 校验 `q_arr / r_arr / elevation_arr / moisture_arr / terrain_arr` 等关键数组长度。
2. 缺 `s_arr` 时用 `s=-q-r` 补齐。
3. 缺温度、年均温、snow、cover 等数组时按当前海拔/纬度补齐。
4. 创建输出数组：`base_terrain_arr`、`landform_arr`、`base_landform_arr`、`vegetation_arr`、`base_vegetation_arr`、`is_water_arr`、`has_river_arr`、`has_volcano_arr`。
5. 构建 `NB[i*6 + dir]` 邻接索引，地图边缘为 `-1`。
6. 定义 `sync_axes(i)`，用最终 terrain + volcano flag 派生 `landform / vegetation / cover / is_water / base_*`。

### 2. Priority-Flood 水文修正与湖盆识别

实现位置：post-base 的 `Hydrologic correction` block。

算法是轻量版 Priority-Flood / depression filling：

1. 先从边界 `OCEAN / COAST` 做 BFS，得到 `connected`：与海洋连通的海水保持海洋语义。
2. 把所有地图边界格按原始海拔压入最小堆。
3. 反复弹出最低 spill cell，访问未处理邻居：
   - `hydro_fill[neighbor] = max(elevation[neighbor], hydro_fill[current])`
   - `hydro_parent[neighbor] = current`
4. 结果是一个水文修正高程面：每个格都知道经最低溢流口排水到边界的 parent path。
5. 对非海洋连通格，如果 `hydro_fill - elevation >= hydro_lake_min_depth`，标为湖盆候选。
6. 对候选湖盆做连通分量：
   - 面积 `>= hydro_lake_min_cells` 的湖盆保留为 `LAKE`
   - 面积较小但体积 `>= hydro_lake_min_volume` 且有足够最大深度的湖盆也保留
   - 其余噪声小坑会被重新判定为陆地，避免一格碎湖

这一步仍复用 base pass 的湖泊种子作为“可能的洼地”，但最终湖泊由全局溢流水文面决定，而不是由局部水体 BFS 决定。

### 3. base_moisture 快照

实现位置：湖泊检测后、雨影前。

`BM[i] = M[i]`。该基线包含基础湿度、沿岸增湿、迎风坡增湿和湖泊分类后的水体语义，但不包含雨影、河流生态和植被反馈。

### 4. 雨影干化

实现位置：post-base 的 `_apply_rain_shadow_per_cell(season_phase=1.0)` 复刻 block。

算法：

1. 重建 `height_warp`：`TYPE_SIMPLEX_SMOOTH`、`seed+13`、`frequency=0.025`、FBM 3 octaves。
2. 对非水格计算 jitter：`height_warp(q*8, r*8) * 0.04`。
3. `pk_wind_belt_wind_at(row_norm, 1.0, jitter)` 得到盛行风。
4. `pk_upwind_dir_index_from_wind()` 映射到 6 个 hex 方向。
5. 直接探测 `lookback` 格外的上风 cell：`Q + DQ[dir]*lookback`、`R + DR[dir]*lookback`。
6. 如果上风格海拔 `> 当前海拔 + rain_shadow_threshold`，当前湿度乘 `rain_shadow_factor`。

这里直接 cube 跳转，而不是逐步走邻接表，目的是与原 GDScript `get_cell_by_cube` 行为一致。

### 5. 二次 terrain 判定

实现位置：雨影后的 `redecide_touched` 循环。

对非水、非 `MOUNTAIN`、非 `SNOW`、非 `TUNDRA` 的格子，用雨影后的湿度再跑 `pk_decide_terrain_ex(..., permanent_only=true)`。如果结果不同就改写 terrain。

### 6. 河流：Priority-Flood Parent Flow Accumulation

实现位置：post-base 的 `Flow accumulation on the hydrologically corrected parent graph` block。

当前初始河流只用这个算法，`MapConfig.river_count` 不参与。主河由 `ClimateProfile.river_channel_init_cells` 控制，高地窄源流由 `river_headwater_init_cells` 和 `river_headwater_min_land_h` 控制；`river_flow_percentile` 只保留为兼容字段。

步骤：

1. 收集所有非水格到 `land`。
2. 复用上一步 `hydro_parent`，也就是每个格经最低溢流口排水到边界的 parent path。
3. 初始化流量：
   - `base_rain = lerp(0.4, 1.6, moisture)`
   - `land_h = (hydro_fill - sea_level)/(1-sea_level)`
   - `oro = 1 + max(land_h - 0.30, 0) * orographic_boost`
   - 海洋连通水体不产流，湖泊可承接并向 outlet 传递上游流量
4. 按 `hydro_order` 反向遍历，把每格流量累加给 `hydro_parent`。
5. 对所有陆地统计 `up_count` 汇水格数，`up_count >= river_channel_init_cells` 的格成为主河道。
6. 对 `land_h >= river_headwater_min_land_h` 的高地，如果 `up_count >= river_headwater_init_cells`，沿 `hydro_parent` 追踪到既有河道或水体，形成窄小源流。
7. 之后按连通分量清理：不接触水体或长度 `< hydro_river_min_length` 的河段会被取消。
8. 孤立格修剪：没有河流邻居、也没有水邻居的单独 river 格会被取消。
9. 河流格如果邻接 `LAKE` 但当前下游没有进入任何水体，会把最低的相邻湖格写入 `river_downstream_arr`，避免视觉上到湖边、数据上不入湖。
10. 对每个河流格输出：
   - `river_downstream_arr[i]`：下游河格或终端水体的 cell index。
   - `river_flow_arr[i]`：按 `log1p(flow)` 归一化的径流/宽度权重，合流后的主流更宽，源流和支流更细。
   - `hydro_parent_arr[i]`：全图静态下游 parent，非河流陆地也有排水方向，供运行期水文路由使用。

`terrain` 不会改成 river；河流由 `has_river_arr + river_downstream_arr + river_flow_arr` 表达。

运行期水文闭环不会重新生成河网拓扑。`hydro_parent_arr` 是生成期的静态排水图，`river_discharge_arr / river_discharge_30d_arr / river_storage_arr / groundwater_storage_arr` 是 daily runtime 状态：降水、积雪融水、土壤水和基流沿 parent graph 汇流，更新动态 discharge；`MapBaker` 在需要重烘河流 SDF 时优先使用 `river_discharge_30d_arr` 作为宽度权重，缺失时回退到生成期 `river_flow_arr`。

### 7. 河岸生态

实现位置：post-base 的 `river_ecology_touched` 循环。

规则：

1. 有河流的陆地格保证 `moisture >= 0.65`。
2. 永久地貌只加湿，不改 terrain。
3. `DESERT` 不直接改写，留给绿洲/盐滩规则。
4. `PLAIN` 河岸按温度变成 `FOREST` 或 `GRASSLAND`。

### 8. 植被反馈

实现位置：post-base 的 donor table 与 `vegetation_feedback_touched` 循环。

算法：

1. 按 terrain 枚举建立 donor 表。
2. 正反馈来自 `FOREST / SWAMP / GRASSLAND / JUNGLE / TAIGA / SAVANNA / OASIS / DELTA`。
3. 负反馈来自 `DESERT / SALT_FLAT`。
4. 每个 donor 按海拔衰减：`donor_eff = donor * clamp(1 - elevation * veg_feedback_elev_decay, 0.1, 1.0)`。
5. donor 贡献累加到所有非水邻居。
6. 应用湿度 delta 后，对非水、非 `MOUNTAIN`、非 `SNOW`、非永久地貌格再跑 `pk_decide_terrain()`。

### 9. 过渡生态与特殊地貌

以下都在 `run_native_world_generate_post_base_pass()` 后半段实现：

| 阶段 | 触发函数/循环 | 条件摘要 | 输出 |
| --- | --- | --- | --- |
| Shrubland | `shrubland_touched` | `GRASSLAND/STEPPE/SAVANNA/PLAIN`，暖、低中海拔、中干、近海或邻海 | `terrain=SHRUBLAND` |
| Mangrove | `mangrove_touched` | 热带、极低海拔、邻 `COAST`，且有河流、邻 `SWAMP` 或局部高湿 | `terrain=MANGROVE` |
| Glacier | `glacier_touched` | `SNOW/TUNDRA`，极冷；低海拔沿海或高海拔 | `terrain=GLACIER` |
| Swamp | `swamp_touched` | 暖、低地、高湿，且有河流或水邻居 | `terrain=SWAMP` |
| Volcano | `volcano_candidates` / `volcano_placed` | `MOUNTAIN` 且 `land_h >= volcano_min_land_h`，用 `seed+7717` 洗牌，满足最小间距 | `has_volcano=1`，`landform=VOLCANO` |
| Delta | `delta_touched` | 有河流、低海拔、邻 `OCEAN/COAST` | `terrain=DELTA` |
| Oasis | `oasis_touched` | `DESERT`、暖、基线或当前湿度仍偏干，且有河流或邻湖 | `terrain=OASIS`，`moisture>=0.55` |
| Salt Flat | `salt_flat_touched` | `DESERT/COLD_DESERT`、低地、距海足够远、无河流/水邻且接近盆底 | `terrain=SALT_FLAT` |
| Badlands/Mesa | `badlands_touched` / `mesa_touched` | `DESERT/COLD_DESERT`，局部高差明显；局部高点且海拔足够高转 `MESA` | `terrain=BADLANDS/MESA` |
| Plateau | `plateau_touched` | 高海拔、低到中等局部起伏、连通面积达到 `plateau_min_cells`；默认 `plateau_max_relief=0.12` | `landform=PLATEAU` |
| Mountain Slim | `mountain_demoted` / `mountain_to_plateau` | `MOUNTAIN` 必须满足 `mountain_min_land_h` 和 `mountain_min_relief`；平缓高地转 `PLATEAU`，较低缓坡转 `HILL` | `landform=PLATEAU/HILL` |
| Peak Summit | `peak_summit` | 先把单格海拔派生出的大片 `PEAK` 退回 `MOUNTAIN`，再按局部高点、邻域落差、最小间距和数量上限筛出少量峰顶 | `landform=PEAK` |
| Rift Valley | `rift_valley` | 两侧抬升夹住的线状洼地候选，按地形分数排序并限量，避免普通山谷大面积误判 | `landform=RIFT_VALLEY` |
| Reef | `reef_touched` | `COAST`、暖、邻陆、无河流入海邻居 | `terrain=REEF` |
| Kelp | `kelp_touched` | `COAST`、凉温、邻陆 | `terrain=KELP` |
| Pelagic Bloom | `pelagic_touched` | 深海、无陆邻、upwelling 强 | `cover=PELAGIC_BLOOM` |

火山不是 terrain，而是 `has_volcano` flag；post-base 放置火山时会立即写 `LandformType.LF.VOLCANO`，运行期同步也会按 `has_volcano_arr` 兜底恢复。高原不是 terrain，而是 post-base 末尾的 landform override。

### 10. 最终三轴同步和返回

实现位置：post-base 末尾 `sync_axes(i)`。

最终派生：

- `landform = pk_derive_landform_with_volcano(terrain, elevation, sea_level, has_volcano)`
- `vegetation = pk_derive_vegetation(terrain, landform, temp, moisture)`
- `cover = pk_derive_cover(terrain, snow_cover=0)`，深海 bloom 可预先写成 `PELAGIC_BLOOM`
- `is_water = pk_is_water_terrain(terrain)`
- `base_terrain / base_landform / base_vegetation` 同步为最终初始状态

返回数组包括：

- 坐标：`q_arr / r_arr / s_arr`
- 地理：`elevation_arr`、`moisture_arr`、`base_moisture_arr`
- 温度：`temp_arr`、`temp_baseline_arr`、`temp_30d_arr`、`temp_365d_arr`、`temp_anomaly_arr`、`thermal_energy_arr`
- 纬度：`cell_lat_norm_arr`、`temp_baseline_year_arr`
- 枚举：`terrain_arr / base_terrain_arr`、`landform_arr / base_landform_arr`、`vegetation_arr / base_vegetation_arr`、`cover_arr`
- 标志/水文：`is_water_arr`、`has_river_arr`、`river_flow_arr`、`river_downstream_arr`、`hydro_parent_arr`、`river_discharge_arr`、`river_discharge_30d_arr`、`river_storage_arr`、`groundwater_storage_arr`、`surface_runoff_arr`、`has_volcano_arr`、`is_lake_seed_arr`、`ema_initialized_arr`
- 诊断：`stage_counts`、`river_flow_threshold`、`river_lake_snap_count`、`lake_count`、`river_count`、`volcano_count`、`desert_class_count`、`plateau_count`、`peak_count`、`rift_valley_count`、`highland_river_count`、`mountain_peak_river_count`

## 三轴派生规则

C++ 权威 helper 在 `world_ext.cpp`，GDScript 同源 helper 在 `map_generator.gd`。

### Landform

函数：`pk_derive_landform()` / `pk_derive_landform_with_volcano()`，GDScript 对应 `_derive_landform()`。

规则：

1. `has_volcano` 优先 -> `VOLCANO`
2. `LAKE` -> `LAKE`
3. `OCEAN / COAST / REEF / KELP / SEA_ICE` 按海拔分 `DEEP_OCEAN / OCEAN / COAST`
4. `DELTA / BADLANDS / SALT_FLAT` 映射为对应 landform
5. 陆地基础分段按 `land_h`：`>0.92 PEAK`，`>0.70 MOUNTAIN`，`>0.22 HILL`，`>0.05 LOWLAND`，否则 `PLAIN`；生成期 post-base 会先把平缓高地覆写为 `PLATEAU`，再用局部起伏筛掉过宽的 `MOUNTAIN`，最后稀疏化 `PEAK`。

运行期 `sync_current_state` 和 GDScript `_sync_axes_for_cell()` 会保留生成期写入的结构性 landform：`PEAK / VOLCANO / PLATEAU / RIFT_VALLEY`，避免季节刷新或海冰 bootstrap 后的全图同步把这些地貌重判抹掉。

### Vegetation

函数：`pk_derive_vegetation()`，GDScript 对应 `_derive_vegetation()`。

规则：

1. 普通水体、湖泊、海冰 -> `NONE`
2. `REEF` -> `CORAL_REEF`
3. `KELP` -> `KELP_FOREST`
4. `GLACIER` -> `NONE`
5. `SNOW` 根据 landform 派生极地荒漠/高山苔原/无植被
6. `DELTA / OASIS / SALT_FLAT / BADLANDS / SWAMP / MANGROVE / SHRUBLAND` 映射为专用植被
7. `HILL / MOUNTAIN / PLAIN` 走 Whittaker vegetation，而不是直接等于 terrain
8. 森林、草地、沙漠等按 temperature/moisture 和 alpine 状态映射；`STEPPE/SAVANNA` 如果落在 `MOUNTAIN/PEAK` 上，会转为 `ALPINE_TUNDRA / ALPINE_MEADOW / BOREAL_SHRUB`，避免高山格显示成普通温带草原。

### Cover

函数：`pk_derive_cover()`，GDScript 对应 `_derive_cover()`。

规则：

1. `GLACIER` -> `GLACIER`
2. `SEA_ICE` -> `SEA_ICE`
3. `SNOW` -> `SNOW`
4. 非水且 `snow_cover > 0.5` -> `SNOW`
5. `TUNDRA` -> `PERMAFROST`
6. 否则 -> `NONE`

## GDScript 装配

函数：`MapGenerator._assemble_native_generation_map(res, cfg)`。

它不重新生成地形，只做数组校验和对象装配：

1. 校验 `n_cells == cfg.width * cfg.height`。
2. 校验核心数组类型和长度。
3. 创建 `MapData.new(cfg.width, cfg.height)`。
4. 对每个 index 创建 `HexCell(q, r)`。
5. 写入 `elevation / moisture / base_moisture / terrain / base_terrain / landform / base_landform / vegetation / base_vegetation / cover / has_river / has_volcano / is_lake_seed`。
6. 写入温度 backing fields 和初始 `current_state`。
7. `map.set_cell(cell)` 入库。

## 海冰 Bootstrap

函数：`MapGenerator._bootstrap_sea_ice_fraction(map, cfg)`。

这是 native 生成后的 GDScript 生成期步骤：

1. 只处理水体，湖泊直接 `sea_ice_fraction=0`。
2. 用 `_compute_temperature(ny, elevation)` 得到年基线温度。
3. `temp < sea_ice_form_threshold` 时按离阈值距离算冰覆盖率，并用 `smoothstep(0.10, 0.85, frac)` 平滑。
4. `temp > sea_ice_melt_threshold` 时覆盖率为 0。
5. 两阈值之间按迟滞带线性过渡，并乘 0.35。
6. 如果 solar gate 开启，再乘 `_sea_ice_freeze_gate(annual_insol, low, high)`。
7. 只有稳定极地多年冰会在生成期直接 `terrain -> SEA_ICE`：`polar_w >= 0.78`、`temp_ref < form_threshold * 0.85`、`frac >= sea_ice_terrain_threshold`。

海冰可能改写 terrain，所以 `generate()` 随后调用 `_sync_axes_for_map()`。

## MapBaker 视觉烘焙

逻辑层地形生成到 `HexCell` 后，`MapBaker.bake_world()` 把 hex 玩法层上采样成高分辨率 `WorldData`。

### bake_world 顺序

函数：`MapBaker.bake_world(map, cfg, hex_size, seed)`。

1. 初始化 baker RNG 和视觉噪声。
2. 清空海冰、enum atlas、weather atlas、dynamic atlas、cell-index LUT 等缓存。
3. 创建 `WorldData`，计算 `world_bounds`、`hm_size`、`derived_size`、`sea_level`、`bake_seed`。
4. `_bake_height_biome_moisture()` 一次循环生成 `height_buffer / biome_buffer / moisture_buffer / vegetation_buffer / cover_buffer`，并建立 `pixel_to_cell_lookup / cell_pixel_lists / CSR`。
5. `_hydraulic_erosion()` 对视觉 `height_buffer` 做轻度水力侵蚀。
6. `_bake_river_sdf()` 把 `cell.has_river` 链烘成河流 SDF。
7. `_bake_latitude_buffer()` 生成每像素纬度。
8. `_bake_initial_physical_circulation()` 和 `_bake_initial_vector_buffers()` 生成风、洋流、上升流相关 buffer。
9. 跳过已退役的 dynamic/ecology/smooth/ice per-pixel atlas。
10. 编码 `height_tex / terrain_horizon_tex / map_index_atlas(enum_atlas_tex) / flow_tex / water_depth_tex / terrain_normal_tex`。
11. 调用 `bake_cell_luts()` 生成 per-cell enum/dynamic/ecology LUT。

### 高度、biome、湿度上采样

函数：`MapBaker._bake_height_biome_moisture()`。

每个像素：

1. 像素中心转世界坐标。
2. 用 `_warp_noise_lo` 和 `_warp_noise_hi` 双频 warp 扭曲采样点，弱化 hex 直边。
3. `_world_to_cube_f()` 转浮点 cube 坐标，`_cube_round()` 找归属 hex。
4. 按局部角度选两个 sextant 邻居。
5. `_barycentric()` 算 self + 两邻居权重。
6. `elevation` 和 `moisture` 做三点插值。
7. `terrain / vegetation / cover` 使用归属 self cell 的枚举，保持 enum atlas NEAREST 语义。
8. 陆地高度叠加 biome detail noise：山地加 ridge，丘陵加较弱 ridge，平原加 plain detail。
9. 写入 height/biome/moisture/vegetation/cover buffer。
10. 同步建立像素到 cell 的 lookup 和 cell 到 pixels 的反向索引。

### 轻度水力侵蚀

函数：`MapBaker._hydraulic_erosion()`。

这是视觉层侵蚀，不回写 `HexCell.elevation`：

1. 预计算圆形 brush kernel。
2. 生成 `EROSION_DROPS` 个雨滴。
3. 每个雨滴随机起点，最多走 `EROSION_MAX_STEPS`。
4. 双线性采样高度和梯度，用惯性和梯度更新方向。
5. 根据高度差、速度、水量和携沙容量决定沉积或侵蚀。
6. 侵蚀按 brush kernel 从邻近像素扣高度。
7. 水量按 `EROSION_EVAPORATION` 衰减，过低则停止。

### 河流 SDF

函数：`MapBaker._bake_river_sdf()`、`_trace_all_rivers()`、`_trace_river_chain()`。

流程：

1. `_trace_all_rivers()` 遍历 `has_river` 且非终端水体的格子。
2. 先按 `river_downstream` 统计入流数，入流数为 0 的河格作为支流/主流源头。
3. `_trace_river_chain()` 沿 C++ 输出的 `river_downstream` 指针追踪，而不是按原始海拔重新猜下坡邻居。
4. 如果支流接入已访问主河道，仍追加合流点，避免视觉断裂。
5. `river_flow` 随折线一起插值，作为每段 stroke 半径的权重。
6. `_catmull_rom_dense_with_widths()` 用 Catmull-Rom 曲线加密折线和宽度。
7. `_warp_river_chain()` 用地形同源 warp 噪声让河道弯曲。
8. `_stamp_polyline_variable()` 按 `river_flow` 栅格化可变宽度折线。
9. `_chamfer_sdt()` 用 3-4 chamfer 距离变换生成距离场。
9. 输出 `[0,1]`：`1` 表示河上，`0` 表示距离超过 `SDF_MAX_DIST_PX`。

### 纹理编码

| 函数 | 输出 | 编码 |
| --- | --- | --- |
| `_encode_height_tex()` | `height_tex` | RG8 16-bit，高字节 R，低字节 G |
| `_encode_enum_atlas()` | `enum_atlas_tex` | RGBA8 map-index，`R=terrain/biome`，`G/B=cell.index`，`A=0` |
| `bake_cell_luts()` | per-cell LUTs | enum/dynamic/ecology LUT |

## MapData / SoA / DataCore

`MapData` 生成期先以 HexCell AoS 存储：

- `_cells`：cube 坐标 -> `HexCell`
- `all_cells()`：遍历所有 cell
- `_build_indices()`：构建 `_cell_array`、`_cell_index`、`_neighbor_indices`

`map.init_soa_from_bake()` 把 HexCell 字段同步到 PackedArray：

- float：`temp_arr`、`moisture_arr`、`elevation_arr`、`base_moisture_arr`、`sea_ice_frac_arr`、`cell_lat_norm_arr` 等
- byte：`terrain_arr`、`landform_arr`、`vegetation_arr`、`cover_arr`、`base_*`、`is_water_arr`、`has_river_arr`

之后 `_setup_sus()` 创建 `DCWorld` / `DCWorldExt` 并绑定同一份 `MapData` 数组。运行期气候、天气、洋流、海冰、植被演替等系统主要读写 SoA / slot，不再重新跑初始地形生成。

## 维护注意

1. 初始生成没有 GDScript fallback。修改 `world_ext.cpp` 后必须 rebuild GDExtension。
2. C++ helper 与 GDScript helper、shader helper 有 SAME_SOURCE 关系，尤其是纬度温度曲线、海拔降温、雪盖和海冰公式。
3. `MapConfig.river_count` 当前不控制河流数量；主河由 `river_channel_init_cells` 控制，高地源流由 `river_headwater_init_cells / river_headwater_min_land_h` 控制，之后会沿 `hydro_parent` 下坡连通到水体。
4. `has_river` 是逻辑 flag，terrain 不会变成 river；视觉河流由 `MapBaker._bake_river_sdf()` 生成。
5. `MapBaker._hydraulic_erosion()` 只改视觉高度图，不回写逻辑海拔，因此不影响玩法水文。
6. post-base 的 `base_moisture` 快照在雨影之前；运行期季节刷新从该基线出发。
7. 海冰 bootstrap 可能改写 terrain，所以 native post-base 后仍需要一次 `_sync_axes_for_map()`。
8. 三轴语义已取代单轴 terrain 作为新代码推荐读取方式；terrain 仍是渲染和兼容层重要 enum。
9. reef/kelp 生成可读取 upwelling，但生成期是否已有完整 upwelling 取决于调用时序。
10. 新增水体 terrain 时必须同步 `pk_is_water_terrain()`、GDScript `_is_water()`、shader、SoA/DataCore 消费路径。
