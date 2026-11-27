# 当前地形生成算法文档

本文总结 Project.Keynes 当前实际运行的初始地形生成算法：每一步做什么、使用什么算法、在哪个函数里实现、最终数据如何进入渲染和运行期 SoA/DataCore。

当前状态：**初始地形生成已 100% C++/GDExtension 化**。`MapGenerator.generate()` 负责流程编排，权威地形、水文、生态和特殊地貌生成在 GDExtension（base pass 在 `gdext/src/world_ext_generate_base.cpp`，post-base 在 `gdext/src/world_ext_generate.cpp`）。旧 GDScript `_generate_cells` 和后处理 fallback 已删除，native 失败会直接中止生成。

> **2026-11-18 更新（cell 级地形重构：脊噪声 → 构造抬升场）**：base pass 的地形段改为
> 「**§R 脊信号前置 → §2.4' SPL（抬升场 + 坡面扩散 + 最陡受体 + 线性高度预算）→ §5' 脊线残差**」，
> 液滴侵蚀与热力坍塌分支已整段删除、p99 膝点压缩取消（§3.6 / §3.7 / §6）。
> 方案与实测见 [terrain-ridge-uplift-plan.md](plans/terrain-ridge-uplift-plan.md)（结果为「部分达标」：M2/M4/性能达标，M1/M5 未达标）。
>
> ⚠ **本版本起 cell 高程 `E[]` 变化 ⇒ 旧存档作废，需新开局**：读档按种子重建世界，重建结果与旧档不再一致
> （起始格不一致时 `start_cell_drift` 拒绝读档，碰巧一致时动态 SoA 与新算法的视觉/水文会静默错位）。

## 关键源码入口

| 职责 | 文件 | 函数 |
| --- | --- | --- |
| 世界生成入口 | `Project/project-keynes/scripts/geography/map_generator.gd` | `generate()` |
| native 生成桥 | `Project/project-keynes/scripts/geography/map_generator.gd` | `_generate_cells_native_base()` |
| native 结果装配 | `Project/project-keynes/scripts/geography/map_generation/terrain_gen.gd` | `TerrainGeneratorScript.assemble_native_result()` |
| C++ base 生成 | `gdext/src/world_ext_generate_base.cpp` | `DCWorldExt::run_native_world_generate_base_pass()` |
| C++ post-base 后处理 | `gdext/src/world_ext_generate.cpp` | `DCWorldExt::run_native_world_generate_post_base_pass()` |
| C++ 同源 helper | `gdext/src/world_ext_internal.h` | `pk_compute_temperature()` / `pk_decide_terrain_ex()` / `pk_derive_*()` |
| GDScript 运行期 helper | `Project/project-keynes/scripts/geography/map_generator.gd` | `_compute_temperature()` / `_decide_terrain()` / `_derive_*()` |
| 渲染烘焙入口 | `Project/project-keynes/scripts/rendering/map_baker.gd` | `bake_world()` |
| terrain-index native bridge | `Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd` | `DCTerrainIndexBaker.bake()` / `apply_result()` |
| 视觉高度/biome 上采样 | `Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd` | `DCTerrainBaker.bake_height_biome_moisture()` |
| 河流视觉 SDF | `Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd` | `DCTerrainBaker.bake_river_sdf()` |
| SoA 镜像 | `Project/project-keynes/scripts/geography/map_data.gd` | `_build_indices()` / `init_soa_from_bake()` |
| 枚举定义 | `Project/project-keynes/scripts/geography/terrain_type.gd` | `TerrainType.TERRAIN` |
| 三轴定义 | `Project/project-keynes/scripts/geography/landform_type.gd` / `vegetation_type.gd` / `cover_type.gd` | `LandformType.LF` / `VegetationType.VEG` / `CoverType.CV` |
| 生成参数 | `Project/project-keynes/scripts/data/climate_profile.gd` | `continent_*` / `river_*` / `lake_*` / `veg_*` 等 |

## 总体数据边界

当前初始地图生成分三层：

1. **C++ base pass**：`run_native_world_generate_base_pass()` 生成基础 per-cell 数组，包括 cube 坐标、海拔、湿度、温度、初始 terrain、初始三轴、湖泊种子标记。
2. **C++ post-base pass**：`run_native_world_generate_post_base_pass()` 基于 base 输出继续做湖泊连通、雨影、河流、河岸生态、植被反馈、特殊地貌、reef/kelp，返回最终 per-cell 数组。
3. **GDScript 装配和运行期接入**：`TerrainGeneratorScript.assemble_native_result()` 只校验数组并创建 `MapData` / `HexCell`；`MapBaker` 负责视觉烘焙；`MapData.init_soa_from_bake()` 把 HexCell AoS 同步到 SoA；`_setup_sus()` 绑定 DataCore / C++ runtime。

## 顶层生成流程

入口函数：`await MapGenerator.generate(cfg, hex_size)`。生成在 Godot 主线程协作式执行，并在重阶段边界让帧；不要不带 `await` 调用，也不要把包含 Godot 对象/纹理上传的整条链直接迁入 worker。

1. `cfg.validate()` 校验地图配置。
2. 解析 seed：`cfg.seed != 0` 时使用配置 seed，否则 `randi()`。
3. 初始化 `_rng` 和 `_init_noise(seed)`。GDScript 侧现在只保留 `_height_warp`，用于运行期雨影 jitter 桥接；初始生成噪声在 C++ 内创建。
4. 调 `_generate_cells_native_base(cfg, seed)`。
5. `_generate_cells_native_base()` 调 `DCWorldExt.run_native_world_generate_base_pass(seed, cfg_dict, profile_dict)`。
6. base 成功后调 `DCWorldExt.run_native_world_generate_post_base_pass(seed, cfg_dict, profile_dict, base_res)`。
7. post-base 成功后调 `TerrainGeneratorScript.assemble_native_result()` 创建 `MapData` 和 `HexCell`。
8. `DCTerrainGenerator.snapshot_base_state(map)` 保存 `base_terrain / base_landform / base_vegetation`。
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

### 程序生成面板

正式新游戏面板和调试地图设置都提供三个 0–100 滑杆。50 沿用当前配置；
重建存档地图时，正式开局从 `NewGameConfig.world_controls` 读取原设置，缺省值视为 50。

- **地形崎岖度**调整基础地形的宏观起伏、山脊强度和抬升回补。
- **地貌与生态多样性**调整湿度噪声和平滑强度，以及台地、裂谷和干旱荒地的形成门槛。植被由现有气候和地形适生度计算。
- **矿产与物种密度**将地质资源主矿点、小矿点及最低覆盖率乘以 0.5–2.0，保留地质评分、储量预算公式和大陆配额。物种播种在原有适生地、载体和行会限制内，用同一倍率调整填充目标，并用倍率的平方根调整播种扩散半径。物种保底和日常扩散继续使用各自的规则。

地形参数由 `native_generation_bridge.gd` 在组装请求时应用到生成 profile 的副本。
矿藏参数由 `map_resource_deposits.gd` 组装，物种密度只应用到初始播种请求。融合原生引导与逐阶段引导使用同一倍率。三个滑杆仅用于程序生成。

基础配置来自 `MapConfig`：`width`、`height`、`num_continents`、`sea_level`、`continent_size`、`seed`。

主要生成调参来自 `ClimateProfile`：

| 类别 | 字段 |
| --- | --- |
| 大陆形状 | `continent_warp_amp`、`dist_field_weight`、`noise_weight`、`meso_weight`、`offshore_amp` |
| 边界海洋化 | `edge_falloff_start`、`edge_falloff_end`、`edge_falloff_depth` |
| 大陆中心 | `main_radius_min/max`、`satellite_radius_min/max`、`satellites_per_main`、`main_placement_min/max`、`satellite_placement_min/max`、`*_separation_factor` |
| 水文 | `river_channel_init_cells`、`river_headwater_init_cells`、`river_headwater_min_land_h`、`river_flow_percentile`、`hydro_river_min_length`、`hydro_lake_min_cells`、`hydro_lake_min_depth`、`hydro_lake_min_volume`、`pit_fill_max_iters`、`lake_seed_freq`、`lake_seed_threshold`、`lake_seed_depth`、`lake_seed_min_interior` |
| cell 级侵蚀 / 脊抬升（2026-11-18 重构） | `spl_iters`（14）、`spl_erodibility`（1.2）、`spl_area_exp`（0.45）、`spl_uplift_rate`（**0.08**）、`spl_ref_cells`（2400）、`spl_headroom_frac`（0.97）、`spl_ridge_uplift`（**0.03**）、`spl_hillslope_diffusion`（**0.08**）、`ridge_residual_frac`（**0.15**）、`ridge_boost_amp`（0.60）；液滴与热力坍塌的 `erosion_*` 键**已删除** |
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
4. **经度是周期轴**：噪声按 `lon = col / width` 取 `θ = 2π·lon`，走 `cyl_noise()` 圆环采样（col=0 与 col=width-1 相邻不重合），所以海拔/气候在接缝处东西无缝。

**当前默认是双峰地台模型（`PK_BIMODAL_ENABLED = true`，2026-06-26 起）**：

1. **大陆性 mask**：`cont = dist_field·PK_CONT_RADIAL_W + (cont_noise−0.5)·PK_CONT_NOISE_W + offshore`，再乘极地偏海因子。
   `dist_field` 已**不再 `pow(1.5)`、不再是穹顶**，只作 mask 种子。
2. **陆海分界**：`C = smoothstep(THRESH−MARGIN, THRESH+MARGIN, cont)`，海岸线定在 `C=0.5`（窄 margin → 陡大陆坡折）。
3. **造山带**：`ridge = ridged noise (1−|n|)` 成脉 × 低频 `belt` 成带，`orogeny = pow(ridge, PK_OROG_SHARP)·belt·PK_OROGENY_AMP`，只随 `C` 出现在陆地侧。
4. **陆地侧**：`platform = PK_PLATFORM_H + macro·PK_PLATFORM_UNDULATE + orogeny`；`lt = (C−0.5)·2`，`E = sea_level + lt·platform`——即平坦大陆地台 + 低频起伏 + 造山带，**内陆平坦、海岸上坡**。
5. **海洋侧**：只产「水侧占位深度」保证 `E < sea_level`；真实洋底由后面的「距岸 BFS」（大陆架 3 hex → 大陆坡 → 10 hex 达深渊）统一重写。
6. 双峰路径**跳过 min/max 归一化**（见 §3）。

下面的旧径向穹顶合成式只在 `PK_BIMODAL_ENABLED = false` 的回退路径生效，保留作回退基础设施：

```text
raw = dist_field^(1.5) * (dist_field_weight + noise_01*noise_weight + meso*meso_weight)
    + coast + offshore + macro * dist_field^(1.5) * macro_relief_weight
    - edge_falloff
```

回退路径的分项含义：大陆距离扰动 `dist_perturb = height_warp(...)·continent_warp_amp`；
多频 FBM 起伏 `height_noise`/`detail_noise` 按 0.70/0.30 混合；中尺度 `meso` 出高原/谷地大块结构；
海岸细节 `height_noise·0.06`；离岸群岛 `pow(max(detail_noise−0.55,0), 1.5)·offshore_amp`；
边界衰减按 `edge_falloff_start/end/depth` 用 smoothstep 扣减，让地图边缘倾向海洋。

### 3. 海拔归一化（双峰路径已跳过）

实现位置：base pass 的 `normalize` block。

**双峰地台模型（当前默认，`PK_BIMODAL_ENABLED = true`）不执行本步**：双峰模型已锚定 `sea_level` 直接产出
`[0,1]` 海拔，min/max 拉伸会把海平面位置搬走，因此 `normalize` 只在旧径向路径（`PK_BIMODAL_ENABLED = false`）
下运行。

旧径向路径行为（仅在回退路径生效）：扫描全图 `min_e / max_e`，若范围大于 `0.001`，把所有海拔线性映射到 `[0,1]`：

```text
E[i] = (E[i] - min_e) / (max_e - min_e)
```

该路径下山脉 ridge 在归一化后才加，避免 ridge 扩大分母、压低普通陆地；双峰路径的脊信号现在改为在**任何侵蚀之前**
算成抬升场（§3.6），SPL 结束后只保留一份 `ridge_residual_frac` 的残差（§6）。

### 3.5 海底距岸剖面（代码块 2.55）

**2.55 海底深度自然化**：以所有陆地格（`E ≥ sea`）为源做多源 BFS 得到每个海洋格的距岸 hex 距离，
近岸 3 hex 为大陆架（浅）、10 hex 达深渊（`PK_OCEAN_ABYSS_FRAC` 占 `sea_level` 比例），叠低频盆地噪声造海沟/海岭。
锚定 `sea_level`：陆地格完全不动，海陆边界与陆地高度不被改写。

### 3.6 脊信号前置：构造抬升场（代码块 R，2026-11-18）

位置：§2.55 洋底之后、SPL 之前。实现位置：base pass 的 `R. 脊信号前置` block。

算法（公式与常量逐字沿用旧 §5，只把输入换成 `E0`）：

1. 先把当前 `E` 拷一份 `e0_frozen`，**之后所有的脊计算只读它**——否则 `ridge_add` 会依赖迭代次数/顺序，
   破坏「同种子逐位一致」。
2. 两套 ridge noise：`ridge_a = 1 − |detail_noise(...·180·feature_scale...)|`、
   `ridge_b = 1 − |detail_noise(...·220·feature_scale...)|`（经度走圆柱采样，跨接缝无缝）。
3. `ridge_signal = pow(max(ridge_a, ridge_b), 1.4)`。
4. `slope = E0[idx] − 最低邻居（读 E0）`；`slope_gate = clamp(slope*8.0, 0.30, 1.0)`。
5. `land_factor = pow((E0 − sea)/(1−sea), 1.5)`。
6. `ridge_add = ridge_signal · land_factor · slope_gate · ridge_boost_amp`；**海洋格 `ridge_add = 0`**。
7. 诊断：`ridge_debug_dump=1` 时额外返回 `ridge_add_arr`（未乘 §5' 预算缩放 `g`），**纯诊断、不改变任何输出数组**。

`ridge_add` 在本节算完后不再随水系变化，它作为 §3.7 抬升场 U 的脊项参与「抬升 vs 下切」的准平衡：
脊信号强、汇水小的格 `U/C` 大 → 高出下游 → 成脊；穿过山带的大河 `A` 大、`C` 大 → 抬升被下切抵消 → 峡谷（先成河）。

### 3.7 SPL 侵蚀：抬升场 + 坡面扩散 + 最陡受体（代码块 2.4'，2026-11-18）

位置：`normalize` + 洋底之后、地形决策之前（注意与视觉层的像素侵蚀不同层级）。
原 §2.4 SPL 与 §2.5 液滴 / 热力坍塌合并为本节：**液滴与热力坍塌分支已整段删除**（坡面扩散承担软化陡坡、圆脊的职责），
`p99` 膝点硬压缩也已取消。实现位置：base pass 的 `2.4' Stream-Power 河流侵蚀` block。

每轮（`spl_iters` 默认 14）：

1. Priority-Flood 求填洼面 `filled` 与出栈序 `proc`（下游先）。
2. **最陡受体**：`rcv[i] = argmax_d (filled[i] − filled[nb_d])`，仅取严格更低的邻居；平局取 `d` 小者；
   无严格更低邻点时沿用 Priority-Flood 的「关闭者」（平地 ε 路径），否则平地上的汇水无法下传。
3. 汇水面积 `A` 沿 `rcv` 累积（初值 1，单位=格）。
4. **隐式下切**：`E[i] = (E[i] + U[i] + C·E[rcv]) / (1 + C)`，`C = K·(A/Ā)^m`，
   **`U[i] = spl_uplift_rate·relief0[i] + spl_ridge_uplift·ridge_add[i]`**（每轮施加）。
   `proc` 升序 ⇒ 更新 `E[i]` 时 `E[rcv]` 已就绪，且加权平均保证 `E[i] ≥ E[rcv]`（不倒灌、不发散）。
5. **坡面扩散**一步（显式线性，hex 6 邻 Laplacian）：
   `E'_i = E_i + κ·Σ_k (E_nb_k − E_i)/6`，`κ = spl_hillslope_diffusion`（0.08）；**仅陆地**、海洋邻居按固定边界；
   **双缓冲**（读 `E` 写 `e_diff`，整步结束后一次拷回），与遍历方向/线程数无关。

循环结束后做一次**线性高度预算**（取代膝点压缩）：对陆地相对海平面高度 `h = E − sea` 乘**同一个**系数，使
`p99(h)` 落到 `target = sea + (soft_max − sea)·spl_headroom_frac`（默认 **0.97**）；
其中 `land_elev_cap = max(0.93, sea + (1−sea)·0.94)`、`soft_max = land_elev_cap − (land_elev_cap − sea)·0.06`。
系数被夹到 ≤ 1（**只压不抬**），统一缩放保序、地貌分类阈值含义不变。

其他要点：

- 大图按 `spl_ref_cells`（默认 2400）做分辨率缩放：`s = max(1, sqrt(n/spl_ref_cells))`，
  `C = K·s·(A/Ā/s)^m`，使每格高差 ∝ `1/s` 一致（`N ≤ spl_ref_cells` 时 `s=1`，与旧行为逐位相同）。
- `spl_iters = 0` 关闭 SPL（回到「无侵蚀」基线）；**没有**「关 SPL 就回液滴」的分支（不保留旧算法，计划 §2.3）。
- 产出：沿高汇水下切出树状河谷（长干流 + 支流），低汇水脊线被抬升保留，杂散闭流洼地被抬填。
- 实测（默认参数，32 种子均值）：陆地闭合洼地 34.6 → **22.0（−36%）** / 674 → **403.4（−40%）**；
  base pass 耗时 7.63 → **7.60 ms**（60×40）、110.6 → **101.3 ms**（200×150）；
  但 M1（脊–水系）与 M5（平顶率）**未达标**、M2b（高脊洼地）变差——
  见 [terrain-ridge-uplift-plan.md](plans/terrain-ridge-uplift-plan.md) §6.2 / 附 A。

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

### 6. 脊线残差（代码块 5'，2026-11-18）

实现位置：base pass 的 `5'. 脊线残差` block（在「湖泊种子下沉」「洼地平滑」两步之后，即代码块 §3 / §4 之后）。

旧 §5 是「侵蚀之后再整段叠脊噪声」：脊信号与汇水无关 → 脊线横跨河谷、在谷中筑坝，坝后盆地被 post-base 的
Priority-Flood 判成湖盆。**这条顺序问题已在 2026-11-18 消除**：脊信号已前移到 §R（§3.6）作为抬升场参与
「抬升 vs 下切」平衡，本节只保留**同一份 `ridge_add` 的残差**，用于给脊顶一点锐度：

1. 直接复用 §3.6 算出的 `ridge_add`（已含 `ridge_boost_amp`），**不再重算噪声、不再乘 amp**。
2. `ridge_residual_frac`（默认 **0.15**，上限 0.30）是残差比例；加法 = `g · ridge_residual_frac · ridge_add[i]`。
3. 冻结基底 `ridge_pre`，避免抬升按遍历顺序累积。
4. **统一高度预算**：`land_elev_cap = max(0.93, sea + (1−sea)·0.94)`、`soft_max = land_elev_cap − (land_elev_cap − sea)·0.06`
   （顶部只留 6% 做 C1 收尾）；极端配置先把基底按海平面锚定比例缩放，再用 24 次二分求全局增益 `g`
   使陆地 p99 ≤ `soft_max`；超过 `soft_max` 的部分用指数软收尾
   `h = soft_max + span·(1 − exp(−(h−soft_max)/span))`，`span = land_elev_cap − soft_max`。
5. 诊断输出 `ridge_budget_scale`（即 `g`）、`ridge_base_scale`、`ridge_tail_cells`、`ridge_land_cells`、`ridge_elevation_cap`。

该 block 的增量按同一全局比例 `g` 分配（不是逐点压缩），只有顶部极少数尖峰走 C1 软收尾，且不动海洋与海陆分布。
`ridge_residual_frac = 0` 时完全内生（山脊只由 §3.7 的抬升场 + 水系长出来）；**超过 0.30 会重新引入脊坝**（上界即 0.30）。
脊抬升的落地结果是**部分达标**（M1 / M5 未达成），见 [terrain-ridge-uplift-plan.md](plans/terrain-ridge-uplift-plan.md) §6.2 / 附 B。

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

沿岸湿度：当前权威路径使用 `dist_ocean` 全向距离地板，`moisture_coastal_floor` 按 `moisture_coastal_scale` 随距海指数衰减。完整地板先作为海洋输入参与副热带干带，扣湿后再保留 35% 的残余海岸保障，避免无冷洋流/离岸风依据的贴岸极旱，同时不让小大陆失去内陆沙漠；post-base 的明确背风雨影仍可在局部覆盖该保护。

副热带干带：`moisture_subtropical_dry_strength / center / width` 在南北副热带纬度扣湿，并乘以距海大陆度，恢复稳定的热带/暖温带荒漠带；默认 strength 为 `0.22`，与 C++ fallback 对齐，近海格受沿海地板保护。

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
6. 如果上风格海拔 `> 当前海拔 + rain_shadow_threshold`，当前湿度乘 `rain_shadow_factor`（默认 `0.65`，保留背风干化但不再一次砍半）。

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
   - `river_flow_arr[i]`：按 `log1p(flow)` 归一化的视觉宽度权重，合流后的主流更宽，源流和支流更细。
   - post-base 内部另保留 `river_ecology_flow`，沿用旧归一标尺供大河源、三角洲和泛滥平原阈值使用；视觉宽度调参不改变生态强度。
   - `hydro_parent_arr[i]`：全图静态下游 parent，非河流陆地也有排水方向，供运行期水文路由使用。

`terrain` 不会改成 river；河流由 `has_river_arr + river_downstream_arr + river_flow_arr` 表达。

运行期水文闭环不会重新生成河网拓扑。`hydro_parent_arr` 是生成期的静态排水图，`river_discharge_arr / river_discharge_30d_arr / river_storage_arr / groundwater_storage_arr` 是 daily runtime 状态：降水、积雪融水、土壤水和基流沿 parent graph 汇流，更新动态 discharge；同一 pass 还把河道/一环河岸 `moisture` 维持在约 `0.66/0.38` 的下限，使季节 terrain 重判不会把密集河网重新判成荒漠。`MapBaker` 在需要重烘河流 SDF 时优先使用 `river_discharge_30d_arr` 作为宽度权重，缺失时回退到生成期 `river_flow_arr`。

### 7. 河岸生态

实现位置：post-base 的 `river_ecology_touched` 循环。

规则：

1. 有河流的陆地格按生态流量保证 `moisture >= 0.66/0.74`；所有成形支流也作为距水场 source。
2. 永久地貌只加湿，不改 terrain。
3. 荒漠河道按低地、生态流量和温度转为 `FLOODPLAIN/OASIS/STEPPE`。
4. 湖河距水场完成湿度回灌后，普通陆地用同一 `gen_temp + pk_decide_terrain_ex` 做一次受保护的最终全图重判；河岸一环下限随流量约为 `0.36..0.42`，向外指数衰减；水体、河道、永久特征和 `MOUNTAIN/SNOW/TUNDRA` 不参与。
5. `PLAIN` 河岸按温度变成 `FOREST/GRASSLAND/FLOODPLAIN`。

### 8. 植被反馈（已退休）

旧 donor table 单向加湿与其二次重判已退休。该路径会形成“植被越多越湿、越湿越容易继续判成植被”的生成期正反馈；当前最终重判只消费风输送、雨影和湖河回灌形成的静态湿度，不读取植被反馈。

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
| Rift Valley | `rift_valley` | 两侧断崖夹住的洼地候选仅沿谷轴连成构造带；按最小连续长度过滤孤立洼点，不设全图数量、面积或间距配额 | `landform=RIFT_VALLEY` |
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

函数：`TerrainGeneratorScript.assemble_native_result(res, cfg)`。

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
4. 优先 `DCWorldExt.run_bake_geometry_fields_pass()`（融合 native pass）：C++ 进程内串起 terrain-index → 侵蚀 → 河流 SDF → 海岸 SDF → 纬度；返回 fallback 时才回退到下列 per-pass 编排（`DCTerrainBaker.bake_height_biome_moisture()` 一次循环生成 `height_buffer / biome_buffer / moisture_buffer / vegetation_buffer / cover_buffer`，并建立 `pixel_to_cell_lookup / cell_pixel_lists / CSR`）。
5. 侵蚀在融合 pass 内由 `dem_erosion_mode` 分支决定（默认 `spl`；`carve`/`spl+carve`/`droplet` 见下文「轻度水力侵蚀」小节）；legacy 回退路径调 `DCTerrainBaker.bake_hydraulic_erosion()` 做液滴侵蚀。
6. `DCTerrainBaker.bake_river_sdf()` 把 `cell.has_river` 链烘成河流 SDF。
7. `_bake_latitude_buffer()` 生成每像素纬度。
8. `_bake_initial_physical_circulation()` 和 `_bake_initial_vector_buffers()` 生成风、洋流、上升流相关 buffer。
9. 跳过已退役的 dynamic/ecology/smooth/ice per-pixel atlas。
10. 编码 `height_tex / terrain_horizon_tex / map_index_atlas(enum_atlas_tex) / flow_tex / water_depth_tex / terrain_normal_tex`。
11. 调用 `bake_cell_luts()` 生成 per-cell enum/dynamic/ecology LUT。

### 高度、biome、湿度上采样

函数：`DCTerrainBaker.bake_height_biome_moisture()`。

该函数是 native terrain-index 缺失时的 GDScript ground-truth fallback；它通过显式噪声对象和 bake knobs 调用 `DCTerrainGeometryUtils` 的无状态几何工具，不复制 MapBaker 的状态。融合 native geometry pass 成功时不会执行该 fallback。

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

### 轻度水力侵蚀（汇流 SPL + 限坡 + 沉积，2026-11-18）

生产路径是融合几何 pass `DCWorldExt.run_bake_geometry_fields_pass` 内的**侵蚀阶段**
（`gdext/src/world_ext_bake.cpp`）；`DCTerrainBaker.bake_hydraulic_erosion()`（液滴）现在只在
fused 返回 fallback 时的 legacy per-pass 编排里执行。

模式由 `dem_erosion_mode` 选择，默认值在 `terrain_index_baker.gd::DEM_DEFAULTS`，经
`dem_landform_knobs()` 并入 fused knobs（可用 `project_keynes/rendering/dem/<去 dem_ 前缀>` 覆盖）：

| 模式 | 执行内容 |
| --- | --- |
| `spl`（**出货默认**） | SPL 管线（建树 → 系数 → 隐式下切 → [沉积/展宽] → 限坡）→ 河流 SDF → 海岸 SDF；不跑刻谷、不跑液滴 |
| `carve`（**C++ 缺省**，逐位回退基线） | 几何刻谷（Priority-Flood 填洼 → MFD 汇水 → `log(A)` 映射谷深 → 倒角谷壁）+ 液滴装饰 → 河流 → 海岸 |
| `spl+carve`（诊断） | SPL 管线 + 浅刻谷（谷深 × `dem_spl_carve_scale`）→ 河流 → 海岸 |
| `droplet`（历史对照） | 仅液滴侵蚀，不做几何刻谷 |

C++ 缺省**恒为 `carve`**，且不认识的模式串一律回退 `carve`，所以不传该 knob 的宿主（perf-validation 镜像）
行为逐位不变；`spl` 只能由 GDScript `DEM_DEFAULTS` 显式开启。

`pk_erosion`（`gdext/src/bake_erosion_spl.h`，header-only、无 Godot 依赖）的实现顺序：

1. **计算栅格**：基线长边超过 `dem_erosion_max_dim`（1024）时按整数因子盒式下采样（wrap 感知，别名列按经线周期处理），`hex_px` 同步换算；`factor=1` 时不下采样。
2. `build_flow`：Priority-Flood + ε 填洼（float key + FIFO 洼地）→ 拓扑序 `order` → 单受体最陡下降 `rcv` → 汇水面积 `A_hex`（1 px = 1/`hex_px²` hex）。
3. `precompute_coeff`：`C = (dem_spl_k / dem_spl_iters) · A_hex^dem_spl_m / dx_hex`，循环外一次算完。
4. `spl_incise`：沿 `order` 下游→上游隐式求解 `h = (h + C·h_rcv) / (1 + C)`，再 `clamp(·, sea+eps, h_old)`——只降、不下海。
5. 可选 `deposit` / `floor_widen`：沿同一棵树反向累积削蚀体积，超搬运能力处填回（上限 `h_pre`、`min_child_h` 保证不造洼）。**两者默认 `false`**（`dem_dep_enabled` / `dem_floor_widen`），是否默认开等 A/B 裁决。
6. `slope_limit`：按局地起伏缩放坡限的前向/后向倒角扫描，只削高侧、单像素削减有 `dem_slope_limit_cap_per_relief` 上限。
7. **写回**：`delta = h_pre − h`（≥ 0）在计算栅格上双线性放大后 `h = h_pre − delta↑`，陆地截断到 `sea+eps`；`factor=1` 时直接就地写回。

不变量（测试断言，A1–A11）：任一阶段后 `h ≤ h_pre`；水体与河心像素**逐位不变**；陆地 ≥ `sea_level + 5e-4`；
`pits_out ≤ pits_in`；同 knobs + 同分辨率逐位可复现（迭代次数只按分辨率分档，禁止按耗时自适应）；
`dem_dep_enabled=false` 时与 P2 结果逐位相等。

实测（`template_debug`，同图同次运行成对对照）：**desktop 1024×606** `carve` 231.6 ms → `spl` 264.9 ms
（`spl` desktop 多次实测约 233–265 ms，同机波动约 ±15%）；**Web high 2048×1212** `carve` 1072.8 ms →
`spl` **514.5 ms**（spl 在 1024 计算栅格上跑，反比 carve 快 558 ms）；2048 上 `upsample_ms` = 16.2 ms。
`spl` 分项 desktop 中位 flow≈80 / spl≈13 / limit≈13 ms。生产路径 `[fused] erosion` = 86.0 ms、
`spl_p99_drop` = 0.0719，`MapBaker v6: total` 1439 → 1393 ms。完整预算与验收见
[terrain-erosion-spl-plan.md](plans/terrain-erosion-spl-plan.md) §5。

`run_bake_erosion_spl_pass(knobs)` 是同一条管线的 buffer-encoder 入口，只给测试 / A/B probe 喂合成高度场，
生产走融合 pass；`run_bake_erosion_pass`（液滴）ABI 不变，保留给 `carve` / `droplet` / legacy 回退。

legacy 液滴侵蚀（`DCTerrainBaker.bake_hydraulic_erosion()`，仅在 fused fallback 与 `carve`/`droplet` 模式跑）：
预计算圆形 brush kernel → 生成 `EROSION_DROPS` 个雨滴 → 每个雨滴随机起点、最多走 `EROSION_MAX_STEPS` 步 →
双线性采样高度与梯度、按惯性和梯度更新方向 → 按高度差 / 速度 / 水量 / 携沙容量决定沉积或侵蚀 →
侵蚀按 brush kernel 扣邻近像素高度 → 按 `EROSION_EVAPORATION` 衰减水量。它只做边界平滑（单步扣除约 10⁻³，
5 步走不出一个 hex），不形成水系——这正是本轮换掉它的原因。

### River SDF

函数：`DCTerrainBaker.bake_river_sdf()`（`scripts/rendering/bakers/terrain_baker.gd`）。

1. GDScript 显式构造几何 knobs：尺寸、世界 bounds、hex size、seed、基础半径、SDF 距离上限、Catmull-Rom 步长和 X wrap 周期。
2. `DCWorldExt.run_bake_river_sdf_pass()` 在 C++ 内完成河流拓扑 trace、跨经度连续展开、Catmull-Rom 致密化、warp、可变宽度 stamp、3-4 chamfer SDT 和归一化。
3. GDScript 只校验 `out_buf` 类型和 `W*H` 尺寸；非法或 native fallback 返回全尺寸空 buffer并记录错误。
4. 河流拓扑不跨语言传输；post-base 先把拓扑暂存到 `DCWorldExt`，bake pass 直接读取。
5. 输出写入 `world.flow_buffer`，随后由现有纹理上传路径发布。


### 纹理编码

| 函数 | 输出 | 编码 |
| --- | --- | --- |
| `_encode_height_tex()` | `height_tex` | RG8 16-bit，高字节 R，低字节 G |
| `_encode_enum_atlas()` | `enum_atlas_tex` | RGBA8 map-index，`R=terrain/biome`，`G/B=cell.index`，`A=0` |
| `bake_cell_luts()` | per-cell LUTs | enum/dynamic/ecology LUT |

### Terrain detail R8

`DCTerrainBaker.rebake_terrain_detail_texture()` 负责跨 biome 连续的 detail
noise raster、byte quantization 和 `DCAtlasEncoders.encode_r8_tex()` 调用。
`MapBaker` 只传入 detail/ridge noise、`WorldData`、native encoder 和范围常量，
再接收返回的 `ImageTexture`；不再持有该像素循环。

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

1. 初始生成没有 GDScript fallback。修改 `gdext/src/world_ext_*.cpp`（base 在 `world_ext_generate_base.cpp`）后必须 rebuild GDExtension。
2. C++ helper 与 GDScript helper、shader helper 有 SAME_SOURCE 关系，尤其是纬度温度曲线、海拔降温、雪盖和海冰公式。
3. `MapConfig.river_count` 当前不控制河流数量；主河由 `river_channel_init_cells` 控制，高地源流由 `river_headwater_init_cells / river_headwater_min_land_h` 控制，之后会沿 `hydro_parent` 下坡连通到水体。
4. `has_river` 是逻辑 flag，terrain 不会变成 river；视觉河流由 `DCTerrainBaker.bake_river_sdf()` 生成。
5. 视觉地形侵蚀（融合 pass 的 `spl` 管线，或 legacy 的 `bake_hydraulic_erosion()`）只改视觉高度图，不回写逻辑海拔，因此不影响玩法水文；`WorldData.sample_height` 与 `world.height_buffer` 均无玩法消费者，改视觉高度是纯视觉变化（读档重烘也会看到新地形）。
6. post-base 的 `base_moisture` 快照在雨影之前；运行期季节刷新从该基线出发。
7. 海冰 bootstrap 可能改写 terrain，所以 native post-base 后仍需要一次 `_sync_axes_for_map()`。
8. 三轴语义已取代单轴 terrain 作为新代码推荐读取方式；terrain 仍是渲染和兼容层重要 enum。
9. reef/kelp 生成可读取 upwelling，但生成期是否已有完整 upwelling 取决于调用时序。
10. 新增水体 terrain 时必须同步 `pk_is_water_terrain()`、GDScript `_is_water()`、shader、SoA/DataCore 消费路径。
11. **cell 层地形段的顺序是契约**：§R（脊信号，输入冻结在 E0）→ §2.4'（抬升场 → 最陡受体 → SPL 下切 → 坡面扩散 → 线性高度预算）→ §5'（残差）。改这个顺序或改 `ridge_add` 的输入都会改变 `E[]`，从而让**旧存档作废、必须新开局**（2026-11-18 起）；液滴 / 热力坍塌 / 膝点压缩已删除，不要再按旧文档找它们。

## Initial Vegetation Ecology (2026-07-31)

After priority-flood, lake selection, river graph construction, and riparian/floodplain moisture correction, post-base performs one final whole-map vegetation classification. It uses the same coastal-adjusted generation temperature as terrain (`T=clamp(gen_temp_with_coastal_adjustment,0,1)`), VegetationProfile's 2-D Gaussian climate fit, and the bounded `pk_vegetation_terrain_weight` soft prior (`0.35..1.25`). Ordinary terrain and landform are never hard mappings; only physical substrates (water, glacier, salt flat, coral, kelp, seagrass) may reject candidates. `NONE` is selected only when every candidate is below `vegetation_min_suitability`; there are no type, patch, or whole-map quotas.

The same pass initializes the existing continuous ecology arrays from `delta=clamp(moisture-base_moisture,-0.5,0.5)`: `water_balance_30d`, `soil_moisture`, and runtime-consistent `plant_available_water`, plus vitality, regen score, growth pressure, and decomposed heat/drought/cold stress. Suitability remains scratch data and adds no persistent DataCore field. `MapGenerator` validates and assembles the native arrays, then `MapData.pending_generation_ecology` applies them after the generic `init_soa_from_bake()` zero bootstrap. Native success must not be followed by the legacy `_derive_vegetation()` overwrite.

Runtime native vegetation paths and the GDScript fallback use the same climate score multiplied by terrain/landform soft weight. Diagnostics include `vegetation_native_ms`, candidate/`NONE` counts, suitability min/mean/max, non-zero plant-water land count, river-adjacent desert count, coastal-highland desert count, and soft-weight min/max.
