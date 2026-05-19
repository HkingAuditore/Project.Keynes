---
name: map-visual-overhaul-v1
overview: 彻底重构地图视觉表达：让海冰随季节明显伸缩、雪线像呼吸、植被换季、云做成独立三层卫星云图、消除 hex 块状色阶；同时严格控制 fragment 采样数 ≤8。
todos:
  - id: data-model
    content: 扩展 [skill:civ-grounded-development] HexCell/VegetationProfile 字段：ice_thickness、ice_age、wet_recency、drought_recency、season_color_lut、anomaly_color_shift
    status: completed
  - id: baker-smooth-atlas
    content: 在 map_baker.gd 实现 rebake_dyn_atlas_smooth：沿 hex 邻接做 box blur，输出 dyn_atlas_smooth_tex（RGBA8）
    status: completed
    dependencies:
      - data-model
  - id: baker-ice-wet-atlas
    content: 实现 rebake_ice_state_atlas + rebake_wet_mark_atlas，并将海冰滞后积分与湿迹衰减接入 climate_system 每日 tick
    status: completed
    dependencies:
      - data-model
  - id: cloud-strip-from-worldmap
    content: 使用 [subagent:code-explorer] 定位并删除 world_map.gdshader 内 ambient_cloud_shadow / 海面 storm 调制 / low_fog 三处云雾代码及对应 hex_renderer setter
    status: completed
  - id: weather-overlay-three-layer
    content: 在 weather_overlay.gdshader 重构出 cirrus / cumulus / fog 三层独立云，方向速度 alpha 各异，并接入 weather_layer.gd 参数
    status: completed
    dependencies:
      - cloud-strip-from-worldmap
  - id: worldmap-shader-rewire
    content: 重写 world_map.gdshader：海冰改 ice_state 驱动、雪线接入 dyn_atlas_smooth 单点采样、删除 N12/N13 的 6 邻域采样，确保 fragment ≤ 8 sample
    status: completed
    dependencies:
      - baker-smooth-atlas
      - baker-ice-wet-atlas
  - id: vegetation-season-lut
    content: 使用 [subagent:code-explorer] 把 24 个 vegetation .tres 补齐 season_color_lut；shader 加 season LUT uniform 与南北半球反相插值
    status: completed
    dependencies:
      - data-model
      - worldmap-shader-rewire
  - id: wet-marks-and-cracks
    content: 在 world_map.gdshader 接入 wet_mark_atlas，做湿迹偏深 + 龟裂 fbm 调制，仅在 recency > 阈值时混入
    status: completed
    dependencies:
      - worldmap-shader-rewire
  - id: climate-anomaly-coupling
    content: 在 climate_baker 与 vegetation LUT 路径中接入 climate_anomaly：抬高海冰临界温度、苔原带色相北移
    status: completed
    dependencies:
      - baker-ice-wet-atlas
      - vegetation-season-lut
  - id: qa-perf-cleanup
    content: 逐档 visual_quality 跑性能/视觉验证：核对 fragment 采样数 ≤ 8、烘焙增量
    status: completed
    dependencies:
      - weather-overlay-three-layer
      - wet-marks-and-cracks
      - climate-anomaly-coupling
---

## 产品概述

对当前 hex 地图的视觉表达进行**彻底重构**：让玩家在地图上一眼看到"地球真的在呼吸"——海冰随季节伸缩、雪线随气温推退、植被四季色相轮换、云从地图本体彻底剥离独立成卫星云图风的三层云带、降水/干旱在地面留短暂痕迹、长期气候异常宏观可见。代码层面消除"颜色按 hex 块切"的硬阶梯，并把单像素 fragment 采样数严格控制在 ≤8。

## 核心功能

### 1. 海冰生命化（Sea-Ice Life）

- **复用项目已有的 `cell.sea_ice_frac`** 字段（已在 ClimateProfile 配套 `sea_ice_freeze_rate / sea_ice_melt_rate / sea_ice_terrain_threshold / sea_ice_terrain_hysteresis`，在 `_apply_sea_ice_daily_pass` 中按温度做滞后积分）——逻辑层已是"生命化"模型；问题在于视觉层完全没消费它，转而走 lat-driven 静态 mask（病灶 A）。
- 极地核心终年不化、中纬冬扩夏退、climate_anomaly 升高时极区可见地缩水。
- 视觉：厚冰瓷白带蓝裂纹、薄冰半透蓝白、消融期破碎浮冰带——边缘由 fbm 撕碎，不再 lat-mask 一刀切。

### 2. 颜色不再按 hex 块切（Smooth Dynamic Atlas）

- 在 baker 侧把 per-cell 状态做一次"沿 hex 邻接的 box blur"再上传，生成 `dyn_atlas_smooth`；shader 单点采样即可得到连续场。
- 温度 / 雪量 / 植被胁迫的所有派生视觉（雪线、植被胁迫、湿迹）都基于平滑场，hex 边阶梯彻底消除。

### 3. 雪线呼吸 + 边缘破碎

- 雪量门槛随季节相位 + climate_anomaly 漂移，冬天向低海拔/低纬下推，夏天向上退。
- 雪边缘用单层 fbm + 平滑场撕成不规则斑驳，永不出现"整 hex 全雪/全无雪"。

### 4. 植被四季换色

- 每个 vegetation 类型有"基础色 + 四季色偏 LUT"（春萌/夏盛/秋黄/冬褐），按季节相位 + 纬度对称（南北半球反相）插值。
- 热带常青、温带四季分明、草原跟随湿度做干湿色相轮换、苔原跟随 climate_anomaly 北移。

### 5. 云完全独立成卫星云图（三层）

- 删除 `world_map.gdshader` 内所有云/雾代码（ambient_cloud_shadow、海面 storm 调暗、low_fog 山雾）。
- `weather_overlay.gdshader` 重构成三层独立云：
- **卷云层（Cirrus，高空）**：纬向带状、快速漂移、低 alpha 半透薄纱。
- **积云层（Cumulus，中空）**：局地堆积成团、中速漂移、跟随 weather_field 强对流。
- **雾层（Fog，低空）**：贴附山地与海岸、慢速、风向各向同性。
- 三层独立的 alpha/速度/方向，叠出真正"云图风"。

### 6. 湿迹与裂痕短期痕迹

- 每个陆地 cell 记录"最近降水后时长"和"最近干旱时长"两标量。
- 降水后地表短暂偏深湿润色 + 微弱 specular；干旱过久出现龟裂噪声纹理。
- 痕迹随时间自然消退，不依赖天气是否仍在头顶。

### 7. 长期气候异常宏观可见

- `climate_anomaly` 升高 → 海冰临界温度抬高（极区缩水）+ 苔原带温度门槛抬升（向极地退）。
- 玩家在 +0.1 climate_anomaly 时即可看到极地白冰圈缩了一圈、苔原带颜色发生位移。

### 8. 性能硬约束

- 主地图 fragment 单像素采样 ≤ 8 次（含所有 atlas 与噪声纹理）。
- 所有"看起来需要邻域"的视觉（雪边破碎、植被胁迫、湿迹）由 baker 端预烘平滑产物提供，shader 端单点采样即可。

## 技术栈

- **引擎**：Godot 4（GDScript + GDShader），现有项目栈。
- **渲染管线**：保持现有 `MapData → MapBaker（CPU 烘焙 atlas）→ ImageTexture → ShaderMaterial（GDShader）` 的数据流。
- **数据结构**：复用 `WorldData.cell_pixel_lists`（cell→像素 1D index 反向索引）做平滑邻接遍历。

## 实现策略

### 架构总览（数据流）

```mermaid
flowchart TD
    A[ClimateSystem 每日 tick] --> B[ice_state / wet_marks / vegetation_phase 更新]
    B --> C[ClimateBaker.bake_dynamic_atlases]
    C --> D1[dyn_atlas_smooth RGBA8<br/>R=temp_blur G=moist_blur B=snow_blur A=vitality_blur]
    C --> D2[ice_state_atlas R8<br/>R=sea_ice_frac (复用 cell.sea_ice_frac)]
    C --> D3[wet_mark_atlas RG8<br/>R=wet_recency G=drought_recency]
    C --> D4[veg_phase_atlas RG8<br/>R=season_phase_local G=anomaly_shift]
    D1 & D2 & D3 & D4 --> E[world_map.gdshader<br/>fragment ≤8 sample]
    F[WeatherSystem] --> G[weather_overlay.gdshader<br/>三层云独立]
    E --> H[最终画面]
    G --> H
```

### 关键技术决策

#### 1. dynamic_cell_atlas 平滑（病灶 B 解药）

- **方案**：在 `MapBaker` 中对 `dyn_atlas` 做一次"沿 hex 邻接图的距离加权 blur"后再上传——一次 6 邻接平均 + 中心权重 0.5，单 cell O(7) 操作。
- **为何不直接 LINEAR**：cell 在矩形 atlas 上的像素分布是不规则六边形 footprint，LINEAR 过滤只能在 1 个像素纹素内插值，跨 cell 边界仍是阶跃。预烘 blur 是真正在 cell 邻接图上做的平均，跨 cell 平滑。
- **新增 atlas**：`dyn_atlas_smooth_tex`（RGBA8，与 dyn_atlas 同尺寸），shader 仅采样它。原 `dynamic_cell_atlas_tex` 保留给调试/info 面板，不再供主 shader 消费。
- **复杂度**：每帧重烘开销 = O(N_cells × 7) 标量加和；4096 cells ≈ 30k 加法，CPU 时间 < 1 ms。

#### 2. 海冰生命化（病灶 A 解药）

- **CPU 数据源（复用）**：`cell.sea_ice_frac`（已 facade 化 SoA，已由 `_apply_sea_ice_daily_pass` 按 ClimateProfile 滞后积分推进），不新增 `ice_thickness / ice_age` 字段，避免 schema/C++ 重 build。
- **新增 atlas**：`ice_state_atlas`（R8，每像素 = 该 cell 当前 sea_ice_frac × 255 量化）。仅水域 cell 写非零，陆地恒 0。复用 `water_cell_pixel_lists`（已存在的水格反向索引）做高速写入。
- **climate_anomaly 联动**：在 `_apply_sea_ice_daily_pass` 内对 `temperature` 做有效偏移（`temp_eff = temperature + climate_anomaly_strength * climate_anomaly`），让冻融阈值随长期升温抬高 → 极地白圈可见缩水。零 GPU 改动。
- **GPU 视觉**：`ice_state_atlas` 单点采样得到 `ice_frac`；ridge fbm 复用现有 `noise_tex` 一次额外采样按 frac 分三档（frac<0.35 浮冰碎块、0.35~0.7 薄冰半透蓝白、>0.7 厚冰瓷白带蓝裂纹）。
- **删除**：world_map.gdshader L1485-1500 的 `temp_ice / polar_ice / depth_ice` 派生路径，全部由单点采样 `ice_state_atlas` + fbm 撕碎边缘替代。

#### 3. 雪线呼吸 + 破碎边缘

- **CPU**：dyn_atlas_smooth 已含 blur 后的 snow_cover；shader 用 `snow_smoothed + fbm_breakup * 0.18 - smooth_threshold(season_phase, climate_anomaly)`。
- **采样削减**：原 N13 的 6 邻域采样**全部删除**（病灶 D 解药），改用 dyn_atlas_smooth 的单点采样替代。

#### 4. 植被四季换色

- **数据**：`VegetationProfile` 资源新增 `season_color_lut: Array[Color]`（春/夏/秋/冬 4 项），`anomaly_color_shift: Color`（climate_anomaly 偏移色）。
- **GPU**：在 shader 内对 vegetation id 索引到四季色 LUT（uniform vec4 array[24][4]），按 `season_phase + hemisphere_sign`（南北反相）做 4 段 cubic mix。零额外采样。
- **草原干湿**：用 dyn_atlas_smooth.G（moist_blur）线性 mix 到 LUT 之上。

#### 5. 云三层独立（病灶 C 解药）

- **删除（world_map.gdshader）**：
- L1734-1850 海面 storm/rain/cloud_field 调制（`weather_field_ocean_*`）
- L1850-1900 ambient_cloud_shadow 相关代码
- low_fog / mountain_fog 山雾分支
- **重构（weather_overlay.gdshader）**：
- **Cirrus**：单层 fbm，方向 `(1, 0.15)` 纬向，速度 `world_time * 0.6`，alpha 0.18 ~ 0.42。
- **Cumulus**：双层 fbm（low + edge），方向跟随 vector_atlas.ba 风场，速度 `world_time * 0.25`，alpha 0.35 ~ 0.85，受 weather_field strong-conv 调制。
- **Fog**：单层 fbm，方向各向同性慢漂，alpha 在 mountain_height_mask × wet_mark.G 双权重下生效。
- 三层独立 octave 数（Cirrus 2、Cumulus 3、Fog 2）= 7 次 fbm 采样（仍只用 1 张 noise_tex），但发生在 weather_overlay 不计入主地图预算。

#### 6. 湿迹与裂痕

- **CPU**：`HexCell.wet_recency`（0~1，1=刚下完雨，自然衰减），`drought_recency`（0~1，1=久旱）。
- **GPU**：单张 R8/RG8 atlas（wet_mark_atlas），同样过 box blur。地表色 mix：
- 湿润：`base_col * mix(1.0, 0.85, wet_recency)`（短暂偏深）
- 干裂：`base_col * mix(1.0, fbm_crack, drought_recency * 0.4)`
- 仅在生效时才 mix，零分支额外采样（用 step）。

#### 7. climate_anomaly 联动

- 单 uniform `climate_anomaly`，shader 内：
- 海冰临界温度抬升（在 ice baker 端调整）。
- 苔原带 (V_TUNDRA / V_TAIGA) 在 LUT 内额外乘 `(1 + anomaly_color_shift * climate_anomaly)`。
- 数值改变后玩家可见：极区白圈缩、北方森林边界北推。

### 性能与采样核算

#### 主地图 fragment 采样表（目标 ≤ 8）

| 采样 | 用途 | 备注 |
| --- | --- | --- |
| 1 | `height_tex` | hypsometric / hillshade |
| 2 | `enum_atlas` | biome / vegetation / cover |
| 3 | `scalar_atlas` | moisture / flow / lat_norm |
| 4 | `dyn_atlas_smooth_tex` | **新**，单点替代原 6 邻域 |
| 5 | `ice_state_atlas` | **新**，海冰状态 |
| 6 | `wet_mark_atlas` | **新**，湿迹/裂痕 |
| 7 | `noise_tex` (low fbm) | fbm 共享 |
| 8 | `noise_tex` (high fbm) | fbm 共享 |


**删除**：原 N12/N13 的 6 点 hex 邻域采样、`vector_atlas`（洋流改为 atlas 内单点采样融到 dyn_atlas 富余通道，或保留单次按需要）、`ecology_visual_atlas`（合并入 dyn_atlas_smooth 的 A 通道作为 vitality_blur）、`weather_field_tex`（彻底从主地图剔除，挪到 overlay）。

> 实施时：若调试期发现需要保留 vector_atlas（洋流方向流纹），可与 wet_mark_atlas 二选一打开 `visual_quality<2` 时的优先级，确保严格 ≤ 8。

#### CPU 烘焙开销

- dyn_atlas_smooth 平滑：每天 1 次，O(N_cells × 7) ≈ 30k 加法 < 1 ms。
- ice_state 更新：每天 1 次，O(N_water_cells) ≈ 10k cells × 4 字段 < 0.5 ms。
- wet_mark 衰减：每帧/每 tick，O(N_land_cells) 单 mul，开销可忽略。
- 总增量 < 2 ms / day-tick，符合现有 SUS 切片预算。

### Implementation Notes（执行细节）

#### 接地约束

- 复用 `MapBaker._dynamic_cell_atlas_buf` / `cell_pixel_lists` 现有数据结构与 dirty 机制；新 atlas 全部走相同的 RGBA8 + ImageTexture.update 路径。
- 复用 `ClimateBaker` 的 cell 状态接口（不引入新系统类），所有新字段加在 HexCell 上。
- shader uniform 新增遵循现有 `hint_default_black` + `dyn_valid = step(0.02, ...)` 的 fallback 模式，避免未绑定时全图变黑/白。

#### 性能与日志

- 平滑 blur 仅遍历 dirty cells（复用 _last_dynamic_cell_sigs 比较），未变 cell 不重算。
- 季节色 LUT 上传一次（在 setup 时 push 一组 vec4 array uniform），不 per-frame 推送。
- 日志走现有 push_warning / sus_report 通道，新加的 baker 函数返回 `report` Dictionary（与 rebake_dynamic_cell_atlas_only 同结构），供 SUS 监控。

#### 兼容性 / 风险控制

- 老的 `dynamic_cell_atlas_tex` 保留供 info_panel 等调试 UI 消费，仅主 shader 切换到 smooth 版本。
- 删除 world_map 内云相关 uniform 时，hex_renderer.gd 同步删除对应 setter；以 `set_meta` 接口在过渡期内做空函数兜底，避免外部脚本调用崩溃。
- 提交粒度：按 todolist 每项一个 commit，海冰、平滑 atlas、云剥离、植被换色、湿迹、climate_anomaly 联动可独立回滚。

## 目录结构（新增 / 修改）

```
Project/project-keynes/
├── shaders/
│   ├── world_map.gdshader                # [MODIFY] 删除 ambient_cloud / 海面 storm / low_fog / 6邻域采样；
│   │                                       # 接入 dyn_atlas_smooth / ice_state_atlas / wet_mark_atlas；
│   │                                       # 重写海冰视觉为 ice_thickness 驱动；植被换色 LUT。
│   ├── weather_overlay.gdshader          # [MODIFY] 三层独立云（cirrus/cumulus/fog）；删除 hex 邻域采样。
│   └── include/
│       └── season_lut.gdshaderinc        # [NEW] 植被四季色 LUT 与季节插值函数。
├── scripts/
│   ├── geography/
│   │   ├── hex_cell.gd                   # [MODIFY] 新增 ice_thickness/ice_age/wet_recency/drought_recency 字段。
│   │   └── world_data.gd                 # [MODIFY] 新增 ice_state_atlas_tex/wet_mark_atlas_tex/dyn_atlas_smooth_tex。
│   ├── rendering/
│   │   ├── map_baker.gd                  # [MODIFY] 新增 rebake_dyn_atlas_smooth / rebake_ice_state_atlas /
│   │   │                                  # rebake_wet_mark_atlas；hex 邻接 box blur 实现。
│   │   ├── hex_renderer.gd               # [MODIFY] 删除云相关 uniform setter；新增 ice/wet/smooth atlas 注入；
│   │   │                                  # 推送植被四季色 LUT。
│   │   └── weather_layer.gd              # [MODIFY] 三层云开关参数同步到 overlay shader。
│   ├── simulation/
│   │   ├── systems/
│   │   │   ├── ice_state_update_system.gd     # [NEW] 每日推进 ice_thickness 滞后积分。
│   │   │   ├── wet_mark_update_system.gd      # [NEW] 每帧/tick 衰减 wet/drought recency。
│   │   │   └── dynamic_visual_atlas_upload_system.gd # [MODIFY] 调用新 baker 函数上传新 atlas。
│   │   └── climate_system.gd              # [MODIFY] 在每日 climate tick 末尾调用 ice_state / wet_mark 更新。
│   └── data/
│       └── vegetation_profile.gd          # [MODIFY] 新增 season_color_lut[4] + anomaly_color_shift。
└── data/
    └── vegetation/                        # [MODIFY] 24 个 .tres 资源补 season LUT 数据（一致性维护）。
```

### 关键代码结构（仅必要的接口契约）

```
# map_baker.gd 新增
func rebake_dyn_atlas_smooth(map: MapData, world: WorldData) -> Dictionary
# 输入：dyn_atlas_buf（已由 rebake_dynamic_cell_atlas_only 写入）
# 输出：dyn_atlas_smooth_buf（每个像素 = 中心 cell × 0.5 + 6 邻居均值 × 0.5）
# 复杂度：O(N_cells × 7)，仅遍历 dirty cells。

func rebake_ice_state_atlas(map: MapData, world: WorldData) -> Dictionary
# RGBA8: R=ice_thickness, G=ice_age_quantized, B=melt_rate, A=ridge_seed
```

```
// world_map.gdshader 海冰新视觉（替换 L1485-1500）
float ice_thick = texture(ice_state_atlas, uv).r;        // [0,1]
float ridge_n  = fbm(wpw * 0.045 + vec2(-71.0, 23.0), 2); // 共享 noise_tex
float ice_visual = smoothstep(0.05, 0.95, ice_thick + (ridge_n - 0.5) * 0.18);
// 三档颜色：浮冰 (0.1~0.35) / 薄冰 (0.35~0.7) / 厚冰 (0.7~1.0)
```

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 在每个 todo 执行前强制 read-first：先核对当前 shader / baker / system 实现细节，再做修改；尤其在删除 ambient_cloud_shadow / 6 邻域采样这类破坏性改动前。
- Expected outcome: 避免误删 / 误改非云相关分支，确保 climate baker / weather layer 等共享代码路径不被破坏。

### SubAgent

- **code-explorer**
- Purpose: 在执行 Step 5（云剥离）和 Step 7（植被四季 LUT）时，跨 shaders + scripts/rendering + scripts/data 三个目录批量定位所有相关 uniform 引用、setter 调用点、.tres 资源使用，避免漏改。
- Expected outcome: 拿到完整的引用清单，保证一次性删干净 / 改干净，不留悬空 uniform 或 setter。