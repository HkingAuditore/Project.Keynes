# Project.Keynes 地形 Shader 开发文档

> 2026-10-31 Web 更新：高档 `PK_WEB_PC_HIGH` 复用 PC 地形/水面/植被代码，
> 不定义移动端质量宏；水陆通过 `PK_WEB_SPLIT_WATER` / `PK_WEB_WATER_ONLY` 分 pass。
> 低/中档保持 LOW 编译前缀，运行期启用基本 PBR 和四类近景植被。
> 所有实际程序由 owner 提供一致的预热源码。高档陆地程序保持 8 sampler、高档水面程序 7 sampler，
> 高档地图生成时烘焙 horizon；地形与普通近景植被读取真实 horizon，家族批次释放该槽位；
> GI 弹射改用 packed occluder（不再需要 bounce_lut）。详见 `docs/web-export.md` 首节与 §9.25。
> Web 运行中切换高档会在共享程序内恢复地形侵蚀细节和迷雾 q1/q2，不在当前帧编译完整 PC 变体。
>
> **2026-11-01 烘焙地表（v3 方案 B）**：在 v2 把 normal+relief 打包进 **4 层
> `terrain_surface_tex`**（layer0 normal、layer1 relief、layer2 detail、layer3 occluder）之后，
> Web 陆地程序**仍恰 8 槽**：detail/micro/occluder 全部塞进已绑 array（surface layer2/3、
> material layer4），不再声明 2D `terrain_detail_tex`/`terrain_micro_tex`/`gi_occluder_tex`/
> `bounce_lut`。`water_depth_tex` 只进水面程序：HIGH water 8 槽、compact water 6 槽、
> 桌面 Compatibility 主 pass 8 槽。LOW(`visual_quality=0`) 的 detail/micro/bounce 全部运行时
> 门控为恒等，像素与 B 之前一致。详见 `docs/web-export.md` §9.24/§9.25 与 §4 纹理通道表。
>
> **2026-11-02 6 层打包（edge 层）**：同一个 array 扩到 **6 层**，layer4 = `edge_distance`
> （R 距离 / G crease / BA 海岸占比）、layer5 = `edge_neighbor` RG（次生 cell id）+ `water_depth` R。
> 数据本来就在 native tile bundle 里 ⇒ **零新增烘焙**；陆地与两个水面程序读同一个 sampler ⇒
> Web 恢复次生生态过渡 / DitherUV 远景过渡 / 沟谷 crease / 海岸 halo / 次生水格时
> **一个材质槽都不新增**（陆地仍 8；HIGH water 7→8、compact water 5→6 只加这 1 张）。
> 详见 `docs/web-export.md` §9.27。
>
> **2026-11-01 C 收尾**：packed GI bounce 从 HIGH 扩到 **MID（vq>=1；MID 强度 0.6、HIGH 1.0、
> LOW 恒 0）**；`water_depth_tex` 升级 **RGBA8**（R=归一深度、G/B/A=湖/礁/海带 3×3 软权重；
> compact 水面 `w = max(binary, GBA)`，GBA=0 自动退化为旧二元行为）；micro 共享程序
> （LOW/MID 运行档）经 Edge/ANGLE A/B 实测 **SAFE → 默认启用**（`WORLD_MAP_WEB_PREFIX_MICRO`；
> `?micro=off|0|false` 可退回裁 micro 的旧前缀，`?micro=shared|on` 可显式开，非 web 恒关）：
> world_map 编译 5417→4582 ms（−15.4%）、总 warmup −5.5%，无 10× 悬崖。
>
> **2026-11-02 全平台陆地/水面双 program 拆分**：桌面 / 移动（Vulkan / GLES3 / Mobile）的
> 主地形也拆成两个 fragment program —— **陆地 program**（`PK_LAND_ONLY`：不 include
> `water_pipeline.gdshaderinc`，但**必须保留** `water.gdshaderinc` 供河面法线
> `sample_water_normal`）与 **水面 program**（`PK_WATER_ONLY`：不 include
> `land_pipeline.gdshaderinc`）。Web 既有的 `PK_WEB_LAND_ONLY` / `PK_WEB_WATER_ONLY`
> 前缀**字节契约不变**，shader 顶部只做「Web 宏 → 通用宏」的别名归一。运行时开关
> `hex_renderer.split_land_water_passes` 默认全平台开启；`terrain_surface_debug_view != 0`
> 或（Compatibility + tiled）自动回退单 program；水面材质任一变体 shader 语言层编不过
> （`get_shader_uniform_list().is_empty()`）→ **整条**拆分回退单 program（不许只回退一半）。
> 覆盖几何由 `scripts/rendering/terrain_coverage_mesh.gd`（`TerrainCoverageMesh.build`）
> 产出的两张保守 mesh 负责：纯陆/纯水 block 只光栅化自己那条管线，混合 block 两侧都画、
> shader 内逐像素互补 discard；模块缺失/构建失败/开关关闭 → 两片共享整张 quad。
> 未探索像素改由各 program 自己画同值 `fog_unexplored_color`（含 Web compact 水面程序），
> 不再依赖 pass 1 兜底 —— 分 mesh 后纯水 block 没有陆地 pass。

> 版本：v10.semi-pbr（2026-07-05 性能变体分档）
> 主入口：`shaders/world_map.gdshader`
> 适用范围：本文档覆盖 `world_map.gdshader` + `shaders/include/*.gdshaderinc` 共 1 主 + 19 支模块。
> 兼容标记：本套 shader 同时存在 `world_map.legacy.gdshader.bak`（v9 baseline，用于 A/B 对照）。

---

## 目录

1. [设计哲学](#1-设计哲学)
2. [整体架构](#2-整体架构)
3. [Include 拓扑与依赖](#3-include-拓扑与依赖)
4. [数据流（Atlas 通道）](#4-数据流atlas-通道)
5. [核心渲染管线](#5-核心渲染管线)
6. [半 PBR BRDF](#6-半-pbr-brdf)
7. [SurfaceParams 与材质模型](#7-surfaceparams-与材质模型)
8. [陆地管线（Land Pipeline）](#8-陆地管线land-pipeline)
9. [水面管线（Water Pipeline）](#9-水面管线water-pipeline)
10. [全局后处理（Global Adjustments）](#10-全局后处理global-adjustments)
11. [噪声系统](#11-噪声系统)
12. [常量与开关（Material Constants）](#12-常量与开关material-constants)
13. [扩展指南](#13-扩展指南)
14. [性能预算](#14-性能预算)
15. [调试与回归](#15-调试与回归)
16. [常见陷阱](#16-常见陷阱)

---

## 1. 设计哲学

本 shader 走**「半 PBR Stylized」**路线，不是传统离线 PBR，也不是纯 NPR。三大原则：

| 原则 | 含义 | 落地位置 |
|---|---|---|
| **物理正确的核** | 主路径 BRDF 是 Cook-Torrance（GGX + Smith + Schlick + 能量守恒），线性空间运算 | `brdf.gdshaderinc::evaluate_brdf_pbr` |
| **风格化的皮** | hillshade / caustics / sparkle / paper grain 这类视觉乘子保留并继续作用 | `land_pipeline` / `water_pipeline` 末段、`global_adjustments` |
| **单点回退** | `USE_PBR_BRDF=false` 即回到 v9 Blinn-Phong + Reinhard，不动业务代码 | `material_constants.gdshaderinc::USE_PBR_BRDF` |

为什么不走完全 PBR：

- 顶视角 2D canvas_item，没有真实视角变化，IBL/反射探针没有意义；
- 业务诉求强烈依赖**地理学风格化**（季节色、生态压力色、海岸 halo、deep_ocean 色温），把 PBR 主导权交出去会丢风味；
- 实时性能预算苛刻（约 2048×1536 像素全幅 fragment），只有标量光源 + 简化 Cook-Torrance 划得来。

---

## 2. 整体架构

```
                    ┌────────────────────────────────────┐
                    │       world_map.gdshader           │
                    │  (vertex + fragment 调度入口)      │
                    └───────────────┬────────────────────┘
                                    │ #include
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
   ┌────▼─────┐              ┌──────▼──────┐             ┌──────▼──────┐
   │ 数据层    │              │ 几何 / 气候  │             │ 风格化叶子   │
   │ uniforms │              │ height       │             │ biome_color │
   │          │              │ climate_season│             │ biome_detail│
   │          │              │ hillshade_tod │             │ vegetation │
   │          │              │              │             │ snow_cover  │
   │          │              │              │             │ weather_front│
   └──────────┘              └──────────────┘             └─────────────┘
                                    │
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
   ┌────▼─────────┐         ┌───────▼───────┐          ┌────────▼────────┐
   │ 半 PBR 核心  │         │ shore_common  │          │ Pipelines       │
   │ surface_params│        │ (邻域 halo)    │          │ land_pipeline   │
   │ material_consts│       │               │          │ water_pipeline  │
   │ tonemap      │         │               │          │ global_adj      │
   │ brdf         │         │               │          │                 │
   └──────────────┘         └───────────────┘          └─────────────────┘
```

**fragment() 的三段式调度**：

```glsl
void fragment() {
    // SETUP：atlas 解码 + 季节相位 + 温度
    ...
    if (!is_water) {
        col = render_land_pipeline(...);   // 陆地：base→modifier→overlay→shade
    } else {
        col = render_water_pipeline(...);  // 水面：base→specials→shade
    }
    COLOR = apply_global_adjustments(col, wp, pixel_noise, dyn_snow, ...); // 羊皮纸 + tonemap + sRGB
}
```

---

## 3. Include 拓扑与依赖

**严格按以下顺序**写入 `world_map.gdshader`，不可乱序（GLSL 没有前向声明，被引用符号必须先定义）：

| # | 模块 | 依赖项 | 角色 |
|---|---|---|---|
| 1 | `shader_quality.gdshaderinc` | – | 编译期性能变体宏：`PK_QUALITY_*` / `PK_SKIP_*` |
| 2 | `uniforms.gdshaderinc` | – | 叶子，所有 sampler / 常量 / 枚举 ID 入口 |
| 2b | `pixel_scale.gdshaderinc` | uniforms（`pixel_world_size` / `hex_size`） | 叶子，世界尺度 ↔ 屏幕像素尺度换算（`pk_px_per_world_unit` / `pk_px_per_world_at` / `pk_hex_px` / `pk_near_detail_blend`）。被 `biome_detail` 与 `terrain_surface_detail` 各自 include（有 include guard），因此 include 顺序由这两者决定，不会被 `world_map.gdshader` 直接引用 |
| 3 | `material_constants.gdshaderinc` | uniforms | 叶子，magic number / F0 / 特性开关 |
| 4 | `common_noise.gdshaderinc` | uniforms | 叶子，`fbm` / `voronoi_cell` / `derive_independent_noise4` |
| 5 | `height.gdshaderinc` | uniforms | 叶子，`decode_height_rg8` |
| 6 | `climate_season.gdshaderinc` | uniforms | 叶子，`hemi_phase` / `season_offset_unified` / `compute_current_temp` |
| 7 | `biome_color.gdshaderinc` | uniforms, B_* | 叶子，按 biome 取基础色 |
| 8 | `vegetation.gdshaderinc` | common_noise + uniforms.V_* | 叶子，植被季节色 |
| 9 | `weather_front.gdshaderinc` | common_noise + uniforms.WT_* | 叶子，极端天气掩码 |
| 10 | `snow_cover.gdshaderinc` | common_noise + height + weather_front | 雪盖判定与色化 |
| 11 | `biome_detail.gdshaderinc` | common_noise + B_* + pixel_scale | biome 内部纹理变化 + 近景高频颗粒 |
| 12 | `hillshade_tod.gdshaderinc` | uniforms + height + visual_tile_sampling | 烘焙法线唯一入口 `terrain_baked_normal` + 昼夜 |
| 13 | `water.gdshaderinc` | common_noise + uniforms.B_* | 水共享细节（波纹/平静面）。**拆分后陆地 program 仍 include**（河面法线）；Web land-only 变体不 include |
| 14 | `surface_params.gdshaderinc` | material_constants | 半 PBR 容器 |
| 15 | `tonemap.gdshaderinc` | material_constants | sRGB↔Linear / ACES |
| 16 | `shore_common.gdshaderinc` | uniforms + material_constants | 海岸 3×3 邻域 + halo |
| 17 | `brdf.gdshaderinc` | surface_params + tonemap + material_constants + uniforms.tod_* | 光照核心 |
| 18 | `land_pipeline.gdshaderinc` | 全部上游 | 陆地总调度（`PK_WATER_ONLY` 时整段不 include） |
| 19 | `water_pipeline.gdshaderinc` | 全部上游 | 水面总调度（`PK_LAND_ONLY` / `PK_WEB_WORLD_MIN` 时整段不 include） |
| 20 | `global_adjustments.gdshaderinc` | tonemap + uniforms | 末端调整（羊皮纸/季节过渡/tonemap/sRGB） |

> **新增 inc 时**：只能放在自己依赖的最后一个 inc 之后；如果新模块给多个下游用，应同时更新本表。

---

## 4. 数据流（Atlas 通道）

CPU 端（Godot GDScript）把 hex 内恒定的动态状态打包成 cell-index + per-cell LUT。shader 在 fragment 开头解析 cell id，并从 LUT 采样动态/生态状态：

| Atlas | 格式 | 通道含义 |
|---|---|---|
| `height_tex` | RG8 LINEAR | `(R*256 + G)/257` ⇒ 海拔 [0,1] |
| `terrain_horizon_tex` | RGBA8 NEAREST | 8方向 horizon angle：R=E/NE, G=N/NW, B=W/SW, A=S/SE，high/low nibble；shader 解码后手动双线性 |
| `map_index_atlas` | RGBA8 NEAREST | R=biome, G/B=`cell.index` low/high, A=landform |
| `enum_lut` | RGB8 NEAREST | per-cell biome / vegetation / cover |
| `dyn_lut` | RGBA8 NEAREST | R=temp, G=wetness, B=snow_cover, A=sea_ice 或 vitality |
| `terrain_material_tex` | Texture2DArray（**5 层**） | 四方连续材质族（Compatibility 亦启用）。layer0..3：R=albedo 细节，GB=切线法线 xy，A=roughness；**layer4 = micro 平铺纹理**（v3，MID/HIGH 近景门控） |
| `terrain_surface_tex` | `Texture2DArray`（**6 层 RGBA8**，同尺寸；非 tiled 的地形与两个水面程序共用） | **layer0 = 粗法线 `0.5+n·0.5` + BA 近景高度细节坡度；layer1 = relief 粗段/细段坡度**；**layer2 = baked detail（R）**；**layer3 = 两个 16-bit occluder cell id**；**layer4 = edge_distance（R 格界距离 / G crease / BA 8 邻域水·湖占比）**；**layer5 = edge_neighbor（RG 次生 cell id；B = water_depth R；A 预留，texelFetch）**。`terrain_surface_layer_count` 运行期告知实际层数，`terrain_edge_layers_bound=(layers>=6)` 门控 edge 两层；tiled 用 `visual_terrain_*_tiles` 各数组（relief 是 `relief_scale` 倍分辨率，不能同 array） |
| `terrain_normal_tex` | RGBA8 2D（仅其它只读法线的图层） | RG=粗法线、BA=近景细节坡度。world_map 非 tiled 已改读 `terrain_surface_tex` layer0；本 2D 只给植被/建筑/资源/贸易/ground cover 等只开 `VT_USE_TERRAIN_NORMAL` 的 shader，内容与 layer0 相同（显式内存取舍） |
| `water_depth_tex` | **RGBA8** NEAREST（C 轮升级） | **R=归一水深**（0=岸、1=最深）；**G/B/A=湖/礁/海带 3×3 软权重**。**仅水面程序**：Web HIGH water / compact water / 桌面 Compatibility 完整主 pass（`VT_USE_WATER_DEPTH`）；湖泊深度读烘焙 R、海面仍用连续 elev；GBA=0 时自动退化为旧二元权重 |

**烘焙法线 / relief 的唯一来源（2026-11-01）**：

- **tiled 桌面**：`visual_terrain_normal_tiles` / `visual_terrain_relief_tiles` 由
  `run_bake_visual_tile_layer_pass` 逐 tile 烘焙；运行时由 `terrain_baked_normals`
  （= `visual_tiles.static_ready` 且两张数组都在）确认本张图可用。
- **非 tiled（Web 全部档位 + 桌面 legacy fallback）**：`MapBaker._bake_legacy_static_surface()`
  复用同一个 native pass 以**整图单 tile**烘焙（`origin/size = world_bounds`、
  `relief_supersample = 1`；长边封顶 Web `1024`（实际再被 `world.hm_size` 钳住，Web LOW 即 512）、
  桌面 `1024`），返回的 payload 打包成 **6 层** `terrain_surface_tex`：
  normal 同时作为 2D `terrain_normal_tex` 与 layer0、relief 作为 layer1；layer2 由
  `world.terrain_detail_tex`（R8）resize/转 RGBA8 得到，layer3 由 `world.gi_occluder_tex`
  （RGBA8 两个 16-bit cell id，NEAREST resize）得到，缺失时分别填中性 0x80 / 0xFF 哨兵；
  **layer4 = `bundle.edge_distance`**（R 距离 / G crease / BA 海岸占比）、
  **layer5 = `bundle.edge_neighbor` RG + `bundle.water_depth` R**（次生 cell id；B 水深）。
  layer4/5 直接来自同一个 native bundle ⇒ **零新增烘焙成本**（只多一层 GDScript 交织，
  日志单列 `edge_ms`）；缺失时填中性（layer4 `R=255`/`G=BA=0`，layer5 `RG=0xFFFF`/`B=A=0`），
  运行期 `terrain_edge_layers_bound=(layers>=6)` 门控，**不采越界层**。
  **内存增量**：surface 2→4 层 Web LOW 512×~300 约 +1.2 MB、MID/HIGH 1024×~600
  约 +6 MB；4→6 层再 +约 1.2 MB / +6 MB；material 4→5 层 mobile 512² 约 +1 MB、
  high 1024² 约 +4 MB。pass 失败时才退回旧 RG8 `encode_bake_terrain_normal_tex_data`
  （扩成 RGBA8 后 array 照建、layer1 中性 128、layer4/5 中性），再失败则平地法线。
- **任何变体都禁止再用 `height_tex` 邻域中心差分求法线**。旧的运行期高度差分族函数
  （宽半径粗法线差分、叠加高度细节、唯一法线入口、分地貌细节及其全部 helper：分地形
  沟谷/台坎/沙丘/圆丘等）已整体删除，禁止以任何名义加回；同一套配置表只存在于生成期
  C++（`gdext/src/bake_terrain_relief.h`）。
- **8 槽预算的四种形态**（unit 1..8，`PK_WEB_TEXTURE_BUDGET`）：
  - **Web 陆地 / 桌面 Compatibility LOW**（带 `PK_WEB_HORIZON`）：`height_tex`、`map_index_atlas`、
    `enum_lut`、`dyn_lut`、`terrain_material_tex`、**`terrain_surface_tex`（6 层）**、
    `terrain_horizon_tex`、**`noise_tex`**。陆地程序**不得**声明 2D `terrain_normal_tex` /
    `terrain_detail_tex` / `terrain_micro_tex` / `gi_occluder_tex` / 旧 2D relief sampler /
    `bounce_lut` / `terrain_edge_neighbor_tex` / `terrain_edge_distance_tex`——它们都已被
    打包进 surface/material array 或删除（2026-11-02 起 edge 两层也在这个 array 里，
    所以恢复次生生态过渡 / crease / 海岸占比**不占新槽**）。
  - **桌面 Compatibility MID/HIGH**（只有 texture budget、没有 `PK_WEB_HORIZON`）：**8 槽** =
    height / map_index / surface array / noise / enum / dyn / material + **`water_depth_tex`**
    （v3：完整主 pass 自己画水，water depth 需要槽）；`VT_USE_HORIZON` 不开，horizon 走
    `terrain_horizon.gdshaderinc` 的中性叶子——**没有地平线遮蔽**，但法线/relief 仍是烘焙纹理。
    属于诊断/回退渲染路径，不是 Web 产品路径。
  - **Web HIGH 水面**（`PK_WEB_WATER_ONLY`）：独立程序与独立预算，**8 槽** =
    height / map_index / `noise_tex` / enum / dyn / material + **`water_depth_tex`** +
    **surface array**（2026-11-02：只读 layer4/5 恢复 edge_mix / shore_frac / 次生水格，
    不声明 normal/relief/horizon）；`hex_renderer._apply_water_uniforms()` 会为这个 pass
    显式补绑 surface array / `noise_tex` / `water_depth_tex` 与层数门控（独立程序不经过陆地
    程序的 uniform 推送）。
  - **Web compact 水面**（`world_water_web.gdshader`）：**6 槽** = height / map_index / enum /
    dyn + **`water_depth_tex`**（自行声明 `has_water_depth_tex`）+ **surface array**
    （2026-11-02；只读 layer4/5，次生水格查表放在 fragment 前导段，着色函数仍零分支）。
  - 桌面 tiled 仍 **17 槽**；桌面 Vulkan legacy **13 槽**（surface array 6 层但 normal/relief/
    detail/occluder/edge 全部合并，非 tiled 不再声明任何 2D edge/detail sampler）；
    tiled 的 normal/relief
    是两个数组：relief 为 `relief_scale` 倍分辨率，不能同 array 合并。桌面 Compatibility 的
    tiled 预算变体仍 8 槽（不打开 water_depth/detail，诊断路径）。

**材质族缩放分层（2026-10-09）**：贴图本身是近景尺度（石块 / 裂纹 / 草团），在大陆视角下直接铺会变成密集斑点。

- 近层用 `terrain_material_world_size`（默认 256 世界单位，约 11.6 个 hex），远层用 `world_size × terrain_material_far_scale`（默认 ×4），远层 UV 转置并偏移，与近层错开相位。按 `camera_zoom` 在 `terrain_material_far_zoom_start..end`（0.9..1.8）之间混合，albedo 和 roughness 两层都参与，法线只取近层。远景 1 次采样，过渡带 2 次，不新增 sampler。
- 材质法线在 `terrain_material_normal_zoom_start..end`（1.35..2.2）之间淡入，远景为 0；幅度上限是 `TERRAIN_MATERIAL_NORMAL_MAX_XY = 0.18`。移动端两组缩放阈值都整体后移 0.30。
- albedo 细节经过 `d/(1+|d|)` 软压缩后再乘 `terrain_biome_material_strength(biome)` 和远景系数 `terrain_material_far_albedo_scale`。
- `terrain_apply_macro_variation()` 用 x 方向按环绕周期取整的 value noise（纯 ALU，接缝无断层）叠一层大尺度明度和冷暖斑块（`terrain_macro_variation_strength / _world_size`），材质路径和程序化路径都会经过这一步。
- 参数的唯一默认值来源是 `uniforms.gdshaderinc`，与 `hex_renderer.gd` 的 export 默认值保持一致；`player_game.tscn` 和 `world_map_material.tres` 不再覆盖。`terrain_surface_debug_view = 18` 可视化这三项权重：R=材质法线权重，G=远层权重，B=大尺度斑块。

**关键约定**：

- `dyn_valid = (_cell_id < 0) ? 0.0 : 1.0`：地图外哨兵像素走 fallback；
- 主地形 **不再采样 `eco_lut`**（2026-08-06）：叶量/胁迫/物候与 `dyn_vitality` 高度重叠，
  纹理槽让给 `terrain_material_tex`。植被 MultiMesh（`shrub_layer`）仍可独立绑 `eco_lut`。
- `scalar_atlas` / `vector_atlas` / `dynamic_cell_atlas` / `dyn_atlas_smooth_atlas` /
  `ecology_visual_atlas` / `ice_state_atlas` / `sea_ice_tex` 已退役，不再绑定或采样。
- **单通道纹理必须走 `DCAtlasEncoders.upload_single_channel()`，不要自己
  `Image.create_from_data(..., FORMAT_R8/L8, ...)`。** Web(WebGL2) 上单通道纹理**建不起来**
  （L8、R8 都试过），Godot 会把该 sampler 静默换成内部的 4×4 默认**白**纹理，所以该入口在
  Compatibility 后端下把格式加宽到 RGBA8（同构建下 RG8/RGBA8 均正常）。消费者只读 `.r`，
  `Image.convert()` 保证 `.r` 逐位保值。
- **这类失效在 GDScript 侧完全看不出来**：`Texture2D.get_size()`、`get_format()`、
  `has_*` 标志、CPU 侧字节统计全部正常，唯一能证伪的是 shader 里的 `textureSize()` ——
  兜底发生时它报 `4×4`。诊断档 `terrain_surface_debug_view = 16` 就是把这个尺寸按 12 位
  二进制条画出来的（配 `tests/probes/_tmp_decode_texsize_view.gd` 从截图解码）。
- **可选纹理一律配一个 `has_*` bool，不要靠"没绑就采样得 0"降级。** 兜底纹理是白而非黑，
  所以"缺省=无效果"的写法在 Web 上会整体翻转成"缺省=效果拉满"——2026-08 Web 端整图发蓝
  就是 `flow` 恒为 1.0（判定全图是河心）导致的。
  `flow_tex`（`has_flow_tex`）与 `water_depth_tex`（`has_water_depth_tex`）都按这个约定走。

---

## 5. 核心渲染管线

每个 fragment 的执行路径如下：

```
SETUP（world_map.gdshader::fragment）
  ├── 采样核心 atlas + noise_tex（1 次 pixel_noise，全平台统一走预烘 pack）+ 可选 terrain_material_tex
  ├── 解码 elev / biome / veg / cover / moist / lat_norm
  ├── 解码 dyn_temp / dyn_wet / dyn_snow / dyn_vitality
  ├── 计算 lat_signed / season_offset / current_temp
  └── 判定 is_water = biome ∈ {OCEAN, COAST, LAKE, REEF, KELP, SEA_ICE}

if (!is_water)  →  render_land_pipeline()
                     ├── compute_land_base_surface (LAND 1.x)
                     ├── apply_land_material_modifiers (LAND 2.x)
                     ├── apply_land_color_overlays (LAND 3.1)
                     ├── apply_land_material_overlays (LAND 3.2)
                     └── shade_land_surface → evaluate_brdf

else            →  render_water_pipeline()
                     ├── compute_water_base_surface (SEA 1.x ~ 14 helper)
                     ├── apply_water_specials (caustics/sparkle/fresnel)
                     └── shade_water_surface → evaluate_brdf

GLOBAL          →  apply_global_adjustments
                     ├── 羊皮纸纸纹（pixel_noise.b 派生 grain）
                     ├── apply_tonemap（ACES 或 Reinhard）；陆地按 tonemap_hue_preserve
                     │   混入 apply_tonemap_luminance（按明度压缩，不在 toe 段放大色度）
                     └── linear_to_srgb（仅 USE_LINEAR_LIGHTING=true）
```

陆地色度三个旋钮（`hex_renderer.gd` 的 `Land Chroma` 组，setter 直推材质）：
`biome_tint_strength`（`biome_hue_modulate` 乘数保留比例）、`land_albedo_saturation`
（所有陆地变色/覆盖层之后、BRDF 之前的反照率饱和度）、`tonemap_hue_preserve`。

**统一的"5 段式"管线契约**（land 完整体现，water 因为不需要 modifier 阶段简化为 3 段）：

```
base → modifier → color overlay → material overlay → shade
```

- **base**：根据 biome/elev/uv 合成默认 SurfaceParams（base_color/normal/roughness/metallic/ao）
- **modifier**：仅修改 base_color 不动 N/R/M/AO（季节、湿度、植被、生态）
- **color overlay**：只改 base_color 的二次叠加（海岸 halo / 雪盖色 / cover 色）
- **material overlay**：只改 N/R/M/AO（雪面写 metallic=0.02、冰川 0.05）
- **shade**：构造 LightingContext → evaluate_brdf → 返回 linear-HDR vec3

---

## 6. 半 PBR BRDF

**位置**：`brdf.gdshaderinc`

### 6.1 LightingContext

```glsl
struct LightingContext {
    vec3 L;                    // 主光方向，世界空间，已归一化
    vec3 V;                    // 观察方向，2D top-down 默认 VIEW_DIR_TOP_DOWN
    vec3 sun_color_linear;     // 主光辐射度（已 srgb_to_linear）
    vec3 ambient_color_linear; // 环境光（已 srgb_to_linear）
    float exposure;            // tod_exposure
    float night_factor;        // tod_night_factor [0,1]
    float hillshade;           // 风格化乘子，hillshade_strength
    float ambient_floor;       // land=AMBIENT_FLOOR_LAND, water=AMBIENT_FLOOR_WATER
};
```

调用：

```glsl
LightingContext lc = make_lighting_context(AMBIENT_FLOOR_LAND);
vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_LAND_LEGACY, SPEC_MIN_LAND_LEGACY);
```

### 6.2 主路径：Cook-Torrance

```
D_GGX(N·H, α)
G_SmithGGX(N·L, N·V, α)        其中 k = (r+1)²/8
F_Schlick(F0, V·H)             F0 = mix(F0_DIELECTRIC_DEFAULT, albedo, metallic)
spec    = D·G·F / (4·N·L·N·V)
kD      = (1-F)·(1-metallic)
diffuse = kD·albedo·INV_PI
direct  = (diffuse + spec)·N·L·sun_color · (hillshade + HILLSHADE_BASE_LIFT)
ambient = max(ambient_color, ambient_floor)·albedo·ao
lit     = (direct + ambient) · mix(1, NIGHT_BRIGHTNESS_FLOOR, night_factor) · exposure
lit    += emission
```

正常昼夜继续完整复用原有 `day_phase → earth_daylight → 日/月/晨昏线` 单一路径，视觉相位仍负责防止高倍速频闪。关闭 `day_night_enabled` 时才进入年度永昼分支：正式玩家模式直接读取 shader 已有的 `season_phase` 与 `earth_daylight_declination()`，方位在一个游戏年内恰好旋转一圈，高度只随直射点纬度在 30°–70° 间变化；调试场景启用手动覆盖时优先沿用现有 `tod_sun_dir`，使方位和高度滑块直接控制同一套地形、水面、天气与植被光线。水平向量按地形法线所用的“受光点指向光源”约定校正，自动路径不读取日相位，也不影响正常昼夜与月光判断。永昼模式把已有地形坡向迎光强度放大 1.45 倍（封顶 0.55），背光坡限制在约 70% 以上；环境光保留 88%、方向光增益 118%，地形投影下限 90%。植被投影不再设置永昼专属衰减，长度、强度、最大长度和柔边参数完整沿用昼夜模式的同一套 profile 配置。

### 6.3 旁路：hillshade-only

`evaluate_hillshade_only(s)` 仅保留为 legacy/debug helper。`day_night_enabled=false` 现在表示"关闭晨昏线但保留永昼全局平行光"，仍走主 BRDF 路径。

### 6.4 Legacy：Blinn-Phong

`USE_PBR_BRDF=false` 时调 `evaluate_brdf_blinn_phong_legacy`，行为与 v9 视觉等价（含末端 Reinhard）。

### 6.5 主入口

```glsl
vec3 evaluate_brdf(SurfaceParams s, LightingContext lc,
                   float spec_max_legacy, float spec_min_legacy);
```

`spec_max_legacy / spec_min_legacy` 仅在 `USE_PBR_BRDF=false` 时生效。

---

## 7. SurfaceParams 与材质模型

**位置**：`surface_params.gdshaderinc`

```glsl
struct SurfaceParams {
    vec3  base_color;   // sRGB 域；BRDF 内 srgb_to_linear
    vec3  normal;       // 已归一化；BRDF N·L 消费，含材质细节法线
    vec3  macro_normal; // 只含高度场宏观起伏；坡向 hillshade / 坡度调色 / 地貌着色只读它
    float roughness;    // [ROUGHNESS_MIN, ROUGHNESS_MAX]
    float metallic;     // [0,1]
    float ao;           // [0,1]
    float alpha;        // [0,1]
    vec3  emission;     // 自发光
};
```

**默认值（来自 material_constants）**：

| 角色 | metallic | ao | F0 |
|---|---|---|---|
| 陆地 | `DEFAULT_METALLIC_LAND = 0.00` | `DEFAULT_AO_LAND = 1.00` | `F0_DIELECTRIC_DEFAULT = 0.04` |
| 水面 | `DEFAULT_METALLIC_WATER = 0.00` | `DEFAULT_AO_WATER = 1.00` | `F0_WATER = 0.02` |
| 雪 | `DEFAULT_METALLIC_SNOW = 0.02` | – | `F0_SNOW_ICE = 0.03` |
| 冰川 | `DEFAULT_METALLIC_ICE = 0.05` | – | `F0_SNOW_ICE = 0.03` |

**构造接口**：

```glsl
SurfaceParams make_surface_params(base_color, normal, roughness, metallic, ao);
SurfaceParams make_surface_params_full(..., emission, alpha);   // 带 emission/alpha
SurfaceParams blend_surface_overlay(s, color, normal, r, m, ao, weight);
SurfaceParams add_emission(s, color, weight);                   // 火山/闪电接入
```

**真实贴图扩展位（接口先行，当前 no-op）**：

```glsl
struct SurfaceTextureSet { bool has_albedo, has_normal, has_orm; float blend_weight; };
SurfaceParams apply_albedo_map(s, ts, uv);
SurfaceParams apply_normal_map(s, ts, uv);
SurfaceParams apply_orm_map(s, ts, uv);   // O=AO, R=Roughness, M=Metallic
```

未来挂图：仅修改这些 helper 内部，下游调用点不动。

---

## 8. 陆地管线（Land Pipeline）

**位置**：`land_pipeline.gdshaderinc`

### 8.1 总调度

```glsl
vec3 render_land_pipeline(
    int biome, int veg, int cover,
    float elev, float moist, vec2 wp, vec2 uv,
    vec4 scals, float lat_signed, float current_temp,
    float dyn_snow, float dyn_valid, float dyn_vitality,
    vec4 pixel_noise, vec2 shore_frac);
```

### 8.2 LAND 1.x — `compute_land_base_surface`

输出 `SurfaceParams`：

| Stage | 改动字段 | 说明 |
|---|---|---|
| 1.1 hypsometric / biome / detail | base_color | 海拔色带 + biome 基色 + biome_detail |
| 1.2 河流 | base_color, ao | 沿 flow_accum 描线，ao 微降 |
| 1.3 顺坡明暗 | base_color | 旧 hillshade 微调（保持 v9 风味） |
| 1.4 等高线 | base_color | 等高线条 |
| 1.5 N/R/AO/metallic | normal/macro_normal/roughness/ao/metallic | `terrain_baked_normal()` → `macro_normal`（法线全部来自生成期烘焙纹理，见 §4）；`normal` = macro + 随缩放淡入的材质法线；地表粗糙度按 biome 派生 |

`shade_land_surface` 的 TOD 坡向明暗会把 `N.xy` 归一化成坡向，任何非零细节法线都会被放大成满幅明暗，所以它、`apply_relief_tint` 和 `landform_visual` 必须读 `macro_normal`。河流、冻河和积雪压平要同时作用于两个法线。

### 8.3 LAND 2.x — `apply_land_material_modifiers`

四个 stage helper 串联；环境调色修改 `base_color`，衰退时还会提高少量
`roughness`，积雪仍留在 LAND 3 最后覆盖：

```glsl
struct LandModInputs { /* 13 字段 */ };

surface = apply_climate_vegetation_tint(surface, i);    // 2.1，温度/湿度/活力物候
surface = apply_vegetation_axis_tint(surface, i);       // 2.3
surface = apply_environment_color_grade(surface, i);    // 2.4，温湿度/生态/活力统一合色
surface = apply_relief_tint(surface, i);                 // 2.2，海拔/坡度/风塑形
```

新增温湿度、生态或活力 modifier 时，应并入 `apply_environment_color_grade` 的
权重与目标色，避免再追加独立乘色层；独立地貌或材质效果才新增 helper。

### 8.4 LAND 3.x — Overlay 拆双语义

```glsl
// 3.0 共享：估算雪/冰盖材质权重
float w_snow = estimate_land_snow_material_weight(...);

// 3.1 颜色 overlay：海岸 halo + 雪色 + cover 色
surface = apply_land_color_overlays(surface, ...);

// 3.2 材质 overlay：雪/冰川区写入 metallic=0.02/0.05、roughness 微调
surface = apply_land_material_overlays(surface, w_snow, ...);
```

旧版本把这两件事混在一个 `apply_land_overlay_surface`，导致 metallic 写不到——重构后职责清晰。

### 8.5 LAND 4 — `shade_land_surface`

```glsl
LightingContext lc = make_lighting_context(AMBIENT_FLOOR_LAND);
return evaluate_brdf(surface, lc, SPEC_MAX_LAND_LEGACY, SPEC_MIN_LAND_LEGACY);
```

### 8.6 烘焙法线入口 `terrain_baked_normal`（2026-11-01）

`hillshade_tod.gdshaderinc` 里唯一的法线入口，`land_pipeline` 永远调用它
（不再有 `PK_TERRAIN_STATIC_BAKED` 二选一）：

```glsl
vec4 terrain_baked_normal(vec2 uv, int quality, float crease);
//   .xyz = 归一化法线；.w = 折痕（crease * fade_coarse），供凹处遮蔽
```

- 编译期宏 `PK_TERRAIN_BAKED_NORMALS`：tiled = `MAP_VISUAL_TILED && VT_USE_TERRAIN_NORMAL &&
  VT_USE_TERRAIN_RELIEF`；非 tiled = `VT_USE_TERRAIN_NORMAL && VT_USE_TERRAIN_RELIEF`。
  它作用域内声明 `uniform bool terrain_baked_normals` 与
  `decode_relief_slope()` / `decode_relief_slope4()`（tiled / 非 tiled 共用）。
- 非 tiled 的 `terrain_surface_tex` 固定 **6 层**（0 normal / 1 relief / 2 detail / 3 occluder /
  4 edge_distance / 5 edge_neighbor+water_depth）；法线路径只用 layer0/1，edge 层由
  `VT_USE_EDGE_DISTANCE` / `VT_USE_EDGE_NEIGHBOR` 决定是否读取。`uniform int
  terrain_surface_layer_count` 运行期告知实际层数（2=旧图形态 / 3=+detail / 4=+occluder /
  6=+edge），`terrain_detail_layer_bound` / `terrain_occluder_layer_bound` /
  `terrain_edge_layers_bound` 是三个既成事实 bool 门控（false 时 helper 返回中性值，
  **绝不采样越界层**）。
- 粗法线：非 tiled 读 `terrain_surface_tex` **layer0** 的 RG（只开 `VT_USE_TERRAIN_NORMAL` 的
  其它 shader 读 2D `terrain_normal_tex`）；tiled 读 `visual_terrain_normal_tiles`。
  `(rg*2-1) * hillshade_coarse_strength`，nz 由归一化重建。
- 近景高度细节：`decode_relief_slope(layer0.ba)`（tiled：`visual_terrain_normal_tiles` 的 BA），
  乘 `smoothstep(1.35, 2.10, camera_zoom)` 与 `hillshade_detail_strength`，`quality>=1` 决定 qf。
- 分地形粗/细段：非 tiled 读 `terrain_surface_tex` **layer1** 的 RG / BA
  （tiled：`visual_terrain_relief_tiles`），分别乘
  `smoothstep(3, 7, 48*scale*camera_zoom)` / `smoothstep(3, 7, 14*scale*camera_zoom)`，
  `scale = terrain_erosion_world_size/72`，强度乘 `terrain_erosion_strength`。
- **没有**"移动端/LOW 直接只返回粗法线"的早退；Web LOW 靠 `PK_WEB_HORIZON` 得以编译细节
  路径（用户本轮核心诉求），代价只是已绑定的 1–2 次采样。
- 兜底顺序：`terrain_baked_normals=false` → 只读 layer0 的 RG（粗法线）→ array 不可用 → 平地法线。
  `terrain_static_baked` 只表示 tiled 的 edge/water/shore 静态通道可用（`PK_TERRAIN_STATIC_BAKED`
  收窄为 tiled 专属），**不再用来判断法线是否可用**。

---

## 9. 水面管线（Water Pipeline）

**位置**：`water_pipeline.gdshaderinc`

### 9.1 总调度

```glsl
vec3 render_water_pipeline(
    int biome, int cover,
    int secondary_biome, int secondary_cover, float edge_mix,
    float elev, vec2 wp, vec2 uv,
    vec4 scals, float lat_signed, float current_temp,
    vec2 ocean_current_v, vec2 wind_v, float dyn_ice_frac,
    vec2 shore_frac, vec4 pixel_noise);
```

`shore_frac` 是 fragment setup 读到的 `edge_distance.ba`（烘焙的 8 邻域水 / 湖占比），
`pixel_noise` 是入口的静态像素噪声；两者都是复用已有采样，水面管线内部不再为海岸 halo
或冰缘破碎单独读贴图。

`secondary_*` 与 `edge_mix` 只是距离场驱动的静态视觉输入。水陆分支、交互、温度、
海冰浓度、洋流与风仍由主格权威所有；水面管线不会计算两遍。

**water depth（B 方案 v3 + C 收尾 RGBA8，2026-11-01）**：`VT_USE_WATER_DEPTH` 只在**水面程序**
打开（Web HIGH water `PK_WEB_WATER_ONLY`、Web compact `world_water_web.gdshader`、桌面
Compatibility 完整主 pass）。非 tiled 的 `water_depth_tex` 是 **RGBA8**：R=归一深度、G/B/A=
湖/礁/海带 3×3 软权重（由 static surface bake 的 native bundle 直接上传，日志
`water_depth=RGBA8`）。`has_water_depth_tex=true` 时 `compute_offshore_depth` 用烘焙 R 深度
替代湖泊多 tap 邻域估算（湖心烘焙值、海面仍走连续 elev）；compact 水面的渲染函数追加
`vec4 water_depth_px`，`w_lake/w_reef/w_kelp = max(binary, wd.g/b/a)`（无 if/else 直线写法）。
static bake 失败兜底：R=旧 `water_depth_buffer`、GBA=0 → 自动退化为旧二元权重。
陆地 program（桌面 `PK_LAND_ONLY` / Web `PK_WEB_LAND_ONLY`）不声明 `water_depth_tex`
（它没有水面像素）；桌面 tiled 拆分水面 program 与陆地 program 共享同一套 VT 预算，
所以 `visual_water_depth_tiles` 也照绑。

### 9.2 SEA 1.x — `compute_water_base_surface`

由于水面变化更复杂，base 函数被拆成 14 个 helper（每个 ≤60 行），通过 `WaterStageCtx` 串联：

| Stage | Helper | 作用 |
|---|---|---|
| 1.1 | `compute_offshore_depth` | LOW 读烘焙 R8；MID/HIGH 普通海水由连续高度场派生深度，湖泊保留烘焙盆地深度 |
| 1.2 | `apply_water_depth_gradient` | 深度色带 |
| 1.3 | `apply_global_water_ripple` | 全局波纹 |
| 1.4 | `compute_water_biome_weights` | 计算 LAKE/REEF/KELP/OCEAN 权重，**LAKE 不再 max(gloss,72) 绕过**，直接写正确 roughness |
| 1.5 | `apply_open_ocean_patch` | 开阔洋斑块色 |
| 1.6 | `apply_deep_ocean_layered_tint` | 深海 4 层色温（latitude/current/abyss/upwelling） |
| 1.7 | `apply_lake_features` | 湖泊视觉 |
| 1.8 | `apply_reef_features` | 礁石 |
| 1.9 | `apply_kelp_features` | 海带森林 |
| 1.10 | `apply_sea_ice_features` | 海冰盖（消费 `dyn_lut.a`） |
| 1.11 | `apply_shallow_transparency` | 浅水透明 |
| 1.12 | `apply_ocean_currents` | 表层洋流可视化 |
| 1.13 | `apply_estuary_plume` | 河口羽流 |
| 1.14 | `build_water_normal_and_calm` | 法线 + 平静面采样 |

### 9.3 SEA 2 — `apply_water_specials`

```glsl
vec3 apply_water_specials(
    vec3 col, SurfaceParams surface,
    int biome, int secondary_biome, float edge_mix,
    vec2 wp, int quality, float pixel_night, vec3 sun_dir_px);
```

负责 `caustics_enabled` / `water_sparkle_enabled` / `water_fresnel_enabled` 的视觉乘子。这些是 **stylized** 而非 PBR，故从 BRDF 中分离。

### 9.4 SEA 3 — `shade_water_surface`

```glsl
LightingContext lc = make_lighting_context(AMBIENT_FLOOR_WATER);
vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_WATER_LEGACY, SPEC_MIN_WATER_LEGACY);
return apply_water_specials(
    lit, surface, biome, secondary_biome, edge_mix,
    wp, visual_quality, pixel_night, sun_dir_px);
```

---

## 10. 全局后处理（Global Adjustments）

**位置**：`global_adjustments.gdshaderinc`

```glsl
vec4 apply_global_adjustments(vec3 col, vec2 wp, vec4 pixel_noise, float dyn_snow, ...) {
    col = apply_paper_grain(col, wp, pixel_noise);          // 羊皮纸纸纹
    col = apply_equator_band(col, ...);                     // 赤道带柔光
    if (USE_LINEAR_LIGHTING && day_night_enabled) {
        col = mix(apply_tonemap(col), apply_tonemap_luminance(col),
                  tonemap_hue_preserve * land_mask);    // 内部自带 exposure_bias
        col = linear_to_srgb(col);
    }
    return col;
}
```

**关键修复（v10 重构）**：旧版每个 pipeline 末尾各自调一次 Reinhard，导致 land/water 视觉基准不一致；现在统一在 `apply_global_adjustments` 末端单次 tonemap，所有上游均输出 **linear-HDR**。

环境与生态色只允许在 `apply_environment_color_grade` 的 albedo 阶段合成。
`apply_global_adjustments` 不得根据温度、湿度或活力再次乘色，否则会把 BRDF
已经计算完成的太阳光与环境光一并染色，造成局部橙光或荧光色。
该函数继续保留历史 11 参数签名，以兼容 Godot `ShaderInclude` 热缓存；后 7 个
气候/地表参数仅是 ABI 占位，不得恢复为后处理调色输入。

---

## 11. 噪声系统

**位置**：`common_noise.gdshaderinc`

**全平台统一 `noise_tex` 快路径（v2 方案 A 恢复）**：Web 地形程序把 normal+relief 合并成
2 层 `terrain_surface_tex` 后腾出 1 槽，`noise_tex` 因此重新进入 8 槽预算
（`pixel_noise` / `fbm` / 雪 / 植被 / 全局调整都在消费它）。`uniforms.gdshaderinc` 无条件
声明该采样器，`common_noise.gdshaderinc` 只有一份实现（预烘包无效时按旧路径临时退化为
多采样）；v1 的 Web 程序化 ALU 噪声分支已整体删除。`pixel_noise` =
`texture(noise_tex, (wp*0.071 + vec2(19.0,-23.0)) / NOISE_TEX_SCALE)`，包无效时回落
`derive_independent_noise4(...)`。

| 函数 | 用途 | 性能 |
|---|---|---|
| `value_noise(p)` | 基础值噪声 | 1 fetch |
| `fbm(p, oct)` | 多倍频噪声 | 1 fetch（G/B/A 预积分；包无效时回退为 oct 次采样） |
| `voronoi_cell(p)` | 蜂窝噪声 | ~9 hash21 |
| `derive_independent_noise4(seed)` | 4 个相互独立的随机数 | 4 sin + 4 dot ≈ 8 ALU |
| `noise_tex 采样` | 主路径，预烘焙 4 通道 noise pack（全平台） | 1 fetch |

**`pixel_noise` 4 通道语义约定**（v10 半 PBR 后约定）：

| 通道 | 语义 | 谁消费 |
|---|---|---|
| `.r` | phase / jitter | 结构噪声相位扰动 |
| `.g` | amplitude / paper grain | 强度调制 |
| `.b` | equator-band / paper grain | global_adjustments 共享 |
| `.a` | equator mix / dissolve overlay | global_adjustments / season transition |

**多分量复用陷阱警告**：`pixel_noise` 的 .r/.g/.b/.a 来自同坐标 fbm-2/3/4-octave 预积分，**频谱和相位高度相关**。若下游需要严格独立的随机数（例如 4 个互不相关的 dissolve mask），应另调 `derive_independent_noise4(wp + offset)`。

---

## 12. 常量与开关（Material Constants）

**位置**：`material_constants.gdshaderinc`

### 12.1 特性总开关（编译期常量，零运行时开销）

```glsl
const bool USE_PBR_BRDF        = true;  // false=回到 v9 Blinn-Phong
const bool USE_LINEAR_LIGHTING = true;  // false=直接 sRGB 域运算
const bool USE_FILMIC_TONEMAP  = true;  // false=走 Reinhard legacy
```

> **PI 不在本文件声明**：`PI` 是 Godot 4 Shading Language 内置常量，本文件仅声明 `INV_PI`。

### 12.2 关键常量分组

```glsl
// BRDF
const vec3  F0_DIELECTRIC_DEFAULT = vec3(0.04);
const vec3  F0_WATER              = vec3(0.02);
const vec3  F0_SNOW_ICE           = vec3(0.03);
const float ROUGHNESS_MIN         = 0.04;
const float ROUGHNESS_MAX         = 1.00;
const float NDOTL_BIAS            = 0.0005;

// Stylized 乘子
const float AMBIENT_FLOOR_LAND     = 0.18;
const float AMBIENT_FLOOR_WATER    = 0.22;
const float HILLSHADE_BASE_LIFT    = 0.55;
const float NIGHT_BRIGHTNESS_FLOOR = 0.68;
const float SUN_INTENSITY_GAIN     = 1.00;

// Legacy Blinn-Phong（USE_PBR_BRDF=0 路径）
const float GLOSS_MAX_LEGACY      = 128.0;
const float GLOSS_MIN_LEGACY      = 4.0;
const float SPEC_MAX_LAND_LEGACY  = 0.25;
const float SPEC_MIN_LAND_LEGACY  = 0.02;
const float SPEC_MAX_WATER_LEGACY = 0.85;
const float SPEC_MIN_WATER_LEGACY = 0.25;

// Tonemap
const float TONEMAP_EXPOSURE_BIAS = 1.00;
const float REINHARD_K_LEGACY     = 0.35;
const float ACES_A = 2.51, ACES_B = 0.03, ACES_C = 2.43, ACES_D = 0.59, ACES_E = 0.14;

// 材质角色默认
const float DEFAULT_METALLIC_LAND  = 0.00;
const float DEFAULT_METALLIC_WATER = 0.00;
const float DEFAULT_METALLIC_SNOW  = 0.02;
const float DEFAULT_METALLIC_ICE   = 0.05;
const float DEFAULT_AO_LAND        = 1.00;
const float DEFAULT_AO_WATER       = 1.00;
const float DEFAULT_ALPHA          = 1.00;
const vec3  DEFAULT_EMISSION       = vec3(0.0);

// Overlay 上限
const float SHORE_HALO_WEIGHT_MAX  = 0.72;
const float SNOW_OVERLAY_MAX       = 1.00;
```

> **新增 magic number 时**：必须先来本文件加 `const`，禁止在 pipeline 中写裸数值。

---

## 13. 扩展指南

### 13.1 加一个新 biome（例如 MARSH）

1. **CPU**：`scripts/data_core/component_ids.gd` 加 `BIOME_MARSH = 16`；`map_generator` 写入 `map_index_atlas.r`
2. **uniforms.gdshaderinc**：加 `const int B_MARSH = 16`、`uniform vec3 color_marsh : source_color`
3. **biome_color.gdshaderinc**：在 `compute_biome_color` switch 里加 case
4. **biome_detail.gdshaderinc**：可选，加 marsh 特有 detail 噪声
5. **shore_common**：marsh 是陆地 ⇒ `is_water` 不需扩展
6. （可选）`vegetation` / `snow_cover` 中按需加 marsh 分支

### 13.2 加一个新陆地 modifier（例如"火山灰覆盖"）

```glsl
// 1. land_pipeline.gdshaderinc::LandModInputs 加字段
struct LandModInputs {
    ...
    float volcanic_ash_amount;   // ← 新字段
};

// 2. 写一个新 helper
SurfaceParams apply_volcanic_ash_tint(SurfaceParams s, LandModInputs i) {
    if (i.volcanic_ash_amount <= 0.001) return s;
    s.base_color = mix(s.base_color, vec3(0.18, 0.16, 0.15), i.volcanic_ash_amount * 0.6);
    return s;
}

// 3. 加到调度器
SurfaceParams apply_land_material_modifiers(SurfaceParams s, LandModInputs i) {
    s = apply_climate_vegetation_tint(s, i);
    s = apply_vegetation_axis_tint(s, i);
    s = apply_environment_color_grade(s, i);
    s = apply_relief_tint(s, i);
    s = apply_volcanic_ash_tint(s, i);    // 独立材质覆盖放在环境合色之后
    return s;
}
```

### 13.3 加自发光（火山口 / 闪电 / 城市夜景灯）

无须改 BRDF；只在 overlay 阶段调：

```glsl
surface = add_emission(surface, vec3(2.5, 0.8, 0.2), volcanic_lava_weight);
```

`evaluate_brdf` 末端会自动把 `surface.emission` 相加。

### 13.4 接入真实贴图（splat / albedo atlas）

1. 在 `uniforms.gdshaderinc` 加 `uniform sampler2D albedo_atlas`
2. 修改 `surface_params.gdshaderinc::apply_albedo_map`：

```glsl
SurfaceParams apply_albedo_map(SurfaceParams s, SurfaceTextureSet ts, vec2 uv) {
    if (!ts.has_albedo || ts.blend_weight <= 0.0) return s;
    vec3 sampled = texture(albedo_atlas, uv).rgb;
    s.base_color = mix(s.base_color, sampled, ts.blend_weight);
    return s;
}
```

3. 在 `compute_land_base_surface` 末尾调：

```glsl
SurfaceTextureSet ts = default_surface_texture_set();
ts.has_albedo = true; ts.blend_weight = 0.4;
surface = apply_albedo_map(surface, ts, uv);
```

下游所有调用点不需要任何修改。

### 13.5 加新光源类型（IBL / 第二定向光）

修改 `LightingContext`：

```glsl
struct LightingContext {
    ...
    vec3 ibl_diffuse;       // 新增
    vec3 ibl_specular;      // 新增
    vec3 L2;                // 第二光源方向
    vec3 sun2_color_linear;
};
```

在 `evaluate_brdf_pbr` 中加 IBL 项与第二光源项。**所有 caller 不需要改**——只需在 `make_lighting_context` 内填好新字段。

### 13.6 一键回退验证

把 `material_constants.gdshaderinc` 中：

```glsl
const bool USE_PBR_BRDF = false;   // 改这一行
```

整个 shader 死代码消除主路径，回到 v9 Blinn-Phong + Reinhard。`world_map.legacy.gdshader.bak` 是同时段的 baseline，可做 A/B 对照。

---

## 14. 性能预算

> 以 1920×1080 全屏 1× 渲染、高画质变体估算。移动端低/中画质必须依靠 shader variant 在编译期裁剪。

| 阶段 | 纹理 fetch | ALU（约） |
|---|---|---|
| SETUP（atlas 解码 + pixel_noise） | 7；LOW 跳过 `flow_tex`，并可禁用部分 debug/天气 atlas 读取 | 30 |
| 陆地 base + modifier + overlay | 4-6（noise/biome_detail） | ~120 |
| 水面 base（14 helper 全开） | 3-5 | ~180 |
| BRDF 主路径（Cook-Torrance） | 0 | ~32 |
| BRDF legacy（Blinn-Phong） | 0 | ~14 |
| global_adjustments | 0 | ~25 |

### 14.1 变体分档规则

| 档位 | 编译宏 | 目标 |
|---|---|---|
| Low | `PK_SHADER_TIER_LOW` / `MOBILE_QUALITY_LOW` → `PK_QUALITY_LOW` | 移动端保帧优先；取消大部分贴图采样、噪声、植被阴影和天气细节。地形细节坡度来自烘焙 relief（不是运行期高度差分），Web LOW 定义 `PK_WEB_HORIZON` 时照常解码 |
| Mid | `PK_SHADER_TIER_MID` / `MOBILE_QUALITY_MID` → `PK_QUALITY_MID` | 移动端平衡档；保留主色、主要形态和少量动态，跳过高频细节 |
| High | `PK_SHADER_TIER_HIGH` / `MOBILE_QUALITY_HIGH` → `PK_QUALITY_HIGH` | 移动端高档；尽量接近桌面，但仍使用独立 variant |
| Desktop | 无移动宏 → `PK_QUALITY_DESKTOP` | 桌面默认完整路径，继续允许 `visual_quality` 做用户可调细节 |

所有运行时 shader 入口必须 include `res://shaders/include/shader_quality.gdshaderinc`。GDScript 侧创建移动端材质时必须 prepend `PK_SHADER_TIER_*`，并可兼容保留旧的 `MOBILE_QUALITY_*` 宏。`visual_quality` / `weather_overlay_quality` / `cell_curtain_quality` 只允许做同一编译档内的强度、octave 或密度微调；移动端低档不能只靠 uniform `if`“关掉”高成本路径。

### 14.2 当前裁剪点

| 模块 | Low | Mid |
|---|---|---|
| `world_map.gdshader` | 跳过 `flow_tex`；像素级细节噪声由下游宏裁剪 | 保留主 atlas，跳过部分高频路径 |
| `biome_detail.gdshaderinc` | 不采样，不跑内部纹理 | 读 surface array layer2 单次采样，替代每像素 `fbm/voronoi` |
| `snow_cover.gdshaderinc` | 跳过 cosmetic fbm 与暴雪新雪增强 | 保留 |
| `terrain_surface_detail.gdshaderinc` | 材质族编译裁掉；跳过大尺度明暗斑块（`terrain_apply_macro_variation`） | 材质族编译裁掉；保留大尺度斑块（8 次 hash，无采样） |
| `land_pipeline.gdshaderinc` | 跳过河流 pulse、顺坡流动、cover fbm、水面法线细节 | 同 Low 的水/河流高频裁剪 |
| `water.gdshaderinc` / `water_pipeline.gdshaderinc` | 编译期跳过水体副格查找，并跳过 domain warp、额外水噪声、kelp/ice fbm、coast foam、暴雪薄冰、caustics、波坡明暗、SSS、sparkle | 复用距离场连续混合静态水体，不跑 3×3 biome 邻域；取消高细节法线与额外 domain warp，保留主波形 |
| `weather_overlay.gdshader` | 云层使用廉价密度，不采 biome atlas | overlay quality 钳到 1 |
| `weather_cell_curtain.gdshader` | 雨雪帘跳过 broad/fine noise、fog veil、lightning | curtain quality 钳到 1 |
| `fog_of_war.gdshader` | fog quality 钳到 0：1 octave、无光照，只出纯色 + 起伏 | fog quality 钳到 1（3 频段分层密度 + 平滑法线，无域扭曲/质量探针）；High tier 钳到 2（4 频段 + 1 层扭曲 + 2 个质量探针） |
| `country_border.gdshader` | 跳过沿边 wobble 噪声 | 保留 |
| `shrub_layer.gd` 内联 shader | 跳过生态 LUT、地形法线/高度贴图 shading、horizon shadow，阴影 pass 输出透明 | 跳过 horizon shadow 与细节 shading |
| `hex_terrain.gdshader` / `hex_edge_overlay.gdshader` | 跳过 erosion warp、边缘噪声、地/水内部细节 | 保留旧行为 |

**B/C 方案（v3 收尾）Web 运行时增量**（全部按档位门控，LOW 恒为 0 采样）：

| 特性 | 实现 | 成本 | 生效档位 |
| --- | --- | --- | --- |
| baked detail | `terrain_surface_tex` layer2 单次采样 | 1 fetch | MID/HIGH（vq>=1；LOW 恒等 1.0） |
| micro surface | `terrain_material_tex` layer4 单次采样 | 1 fetch | **MID/HIGH 默认开**（共享程序默认 `WORLD_MAP_WEB_PREFIX_MICRO`，HIGH 独立程序同样有；`?micro=off` 可关；LOW 早退） |
| packed GI bounce | `texelFetch` surface layer3 + `enum_lut` 查 biome | 1 texelFetch + 1 LUT fetch | **MID/HIGH（vq>=1；MID ×0.6、HIGH ×1.0；LOW 恒 0）** |
| water depth + 软权重 | 水面程序 `water_depth_tex`（RGBA8）单次采样 | 1 fetch | Web 全档水面 / 桌面 Compatibility 主 pass（GBA=0 退化为旧二元权重） |

LOW(`visual_quality=0`) 的门控是硬契约：`procedural_biome_detail` vq<=0 早退、micro
`visual_quality<=0` 早退、bounce `visual_quality<1` 早退（C 轮起）、detail 读取位于 vq 门控
之后不可达——所以 LOW 改这些 array 层内容必须像素不变（`web_quality_render_test` 有专项断言）。

实现边界（冻结时实测）：micro 在 **MID/HIGH 默认开**——共享 `WORLD_MAP_WEB_PREFIX_MICRO`
（去 `PK_PROBE_NO_MICRO`，sampler 仍 8）+ HIGH 独立程序；C 轮 Edge/ANGLE A/B 实测 SAFE
（world_map 编译 5417→4582 ms / −15.4%，总 warmup −5.5%，无 10× 悬崖），保留
`?micro=off|0|false` kill-switch 与 `?micro=shared|on` 显式开，非 web 恒关；历史 Intel UHD
机器未复测。baked detail layer2 双路径消费：材质未绑/回退路径走 `procedural_biome_detail`；
预算程序（Web/Compatibility）在材质族激活时也会把 layer2 乘进材质 albedo（vq>=1 且
`terrain_detail_available()`），因此 MID/HIGH 产品路径能看到 baked detail。

### 14.3 陆地/水面双 program 的采样预算（2026-11-02 全平台）

拆分只改**几何覆盖 + program 划分**，不改任何采样/算式：桌面每个变体的材质 sampler
数量与今天完整主 pass **逐一相同**（`terrain_shader_variant_test` 逐名断言）。

| 平台 / 变体 | 陆地 program | 水面 program | 备注 |
|---|---|---|---|
| 桌面 legacy（非 tiled，含 mobile 三档） | 15 | 15 | 与今天完整主 pass 相同；水面程序 `PK_WATER_ONLY` |
| 桌面 tiled（含 mobile 三档） | 17 | 17 | 必须保留 `VT_USE_WATER_DEPTH`（否则 `PK_TERRAIN_STATIC_BAKED` 失效） |
| 桌面 Compatibility（`PK_WEB_TEXTURE_BUDGET`，非 tiled） | 8 | 8 | 与今天纯预算主 pass 同名单；tiled + Compatibility 回退单 program |
| Web LOW/MID 陆地 + compact 水面 | 8 / — | — / 5 | **不变**；紧凑水面程序不参与桌面拆分 |
| Web HIGH 陆地 + HIGH 水面 | 8 | 7 | **不变**；HIGH 水面现在是 `PK_WATER_ONLY`（不再 include 陆地管线） |

覆盖 mesh 约束（`TerrainCoverageMesh.build`）：

- 几何规则必须与 `HexRenderer._build_world_quad_mesh()` **完全一致**（wrap P>0 时
  x∈[0,P) 并在 −P/0/+P 各复制一份进同一个 ArrayMesh；顶点是世界坐标）。
- 分类源必须与 shader 的 `is_water` 同源（CPU 逐像素水掩码 = `pixel_to_cell_lookup`
  → `cell.terrain` → `MapData.is_water_render_lut()`；`null` padding 归 water）。
- 保守超集：block 内只要出现该类像素就进该类 mesh，随后两张 mesh 各自外扩
  `MARGIN_BLOCKS=1`；边界 quad 裁剪到世界矩形内。不允许出现漏画（露背景）或重复上色
  （靠 fragment 内 `is_water` 互补 discard）。
- 一次性构建（60×40 / derived 1024×606 / P≈2286 / block 16 实测 `build_ms≈100–119`），
  运行期不重建；构建失败 → `ok=false` + reason → 渲染器回退整张 quad + 单 program。
- **只有"真的有两个 program"时才用覆盖 mesh**（`_water_pass_active()`）：单 program 状态
  （Web MID、拆分关闭、编译失败回退）必须由陆地 quad 铺满整张地图，否则另一类像素露背景。

### 14.4 优化原则

1. 性能分档优先使用编译期宏：`#ifdef PK_QUALITY_LOW`、`#ifndef PK_SKIP_*`，让低档源码不包含昂贵采样和噪声。
2. 运行期 uniform 分支只用于同档内开关、强度或 debug，不作为移动端低画质的主要性能手段。
3. 禁止在 fragment 内写循环变长边界；所有 `for (int i = 0; i < CONST; i++)` 必须用编译期常量。
4. 新增 fragment 贴图采样、`fbm`、`value_noise`、`voronoi_cell` 时必须同步给 Low/Mid 写裁剪路径，并更新本节表格。**禁止新增任何多 tap 高度/法线差分**：地形法线必须来自生成期烘焙纹理（`terrain_baked_normal`），要加新形态请改生成期 bake pass（见 §4 / §8.6）。
5. 需要法线的程序化云优先用**解析导数**，不要用 4-tap 有限差分。迷雾必须把法线拆成低频、低强度的宽缓宏观坡向与高频、小振幅的锐利细节；不能让所有 octave 等权进入同一法线，也不能把窄层级阈值的导数叠成等高线尖脊。
6. 可缩放地图上的程序化噪声必须按屏幕足迹做 **LOD 截断**（把 `fwidth(world) × 域缩放` 喂给 `cloud_cumulus_fbm*` 的 `lod_px`）。跨不过一个像素的 octave 若照采，缩小时整层会走样成沙砾状闪烁噪点。
7. **地图东西向无限滚动，全屏程序化噪声必须可平铺。** 采样点被折回一个环绕周期后，普通噪声在周期两端对不上，接缝处就是一条肉眼可见的竖线。用 `cloud_grad_noise_tiled*` / `cloud_cumulus_fbm*`，并先用 `fog_tileable_scale` 那套办法把域缩放微调到「周期 = 4 的整数倍个噪声格」。域扭曲的子频率只能取 2 的负幂，否则子频率下周期不再是整数格。
8. **全屏层不要做低步数 raymarch。** 俯视地图只看见云海上层，9～16 步会欠采样，数十步又超预算。迷雾使用共享连续场派生 deck/body/top，再用少量质量探针补自阴影；`cloud_volume.gdshaderinc` 继续提供相函数、双指数透过率和 Powder。
9. **玩法遮挡与云团形状分层。** 未探索区 `alpha=1` 由低层 deck 承担，中层 body/高层 top 负责视觉轮廓。不能让同一个高反差高度场既负责完全遮挡又负责所有明暗，否则云缝会变成黑峡谷。
10. **明暗要直接算进颜色，不要「累积再除回覆盖度」。** 覆盖度在满云区恒为 1，除回去等于把所有明暗一起除掉，结果是一整片灰。
11. **拿 FBM 的梯度当法线之前，必须按尺度分路。** 标准参数下 `amp·freq` 是常数，每个 octave 对梯度贡献相同 → 直接求和就是白噪声。迷雾的 1/2、1 倍频组成受限幅的 `broad_grad`，2、4 倍频组成单独的 `detail_grad`，后者用远小于宏观项的振幅叠加；天气云若继续用 `cloud_cumulus_fbm_d`，则依靠 `grad_falloff`。
12. **云不是不透明漫反射面。** 单次散射反照率≈1，背光面不会掉黑：`light_wrap` 要给足，暗部亮度主要靠**不吃 `N·L`** 的多重散射回填项撑着，天空遮蔽的谷底要留下限。少了这些就是「没有 GI」的石头感。
13. **自阴影积分云体质量，不做硬高度差。** 直接比较前方/本地高度会把低频差值放大成巨大沟槽。`fog_shadow_mass()` 取 2～3 个频段的 body/top 质量，加权平均后转为光学厚度。
14. **多重散射不要用指数衰减。** 指数是 Beer 定律（单次散射的直接透射）。高反照率介质（云）处于扩散输运区，尾巴厚得多，用有理式 `1/(1+k·d)`。拿 `exp()` 做 MS 回填 = 把云画成不透光的石头。
15. **如果要拿胞状噪声（Worley）做离散鼓包，别用 F1。** `F1 = min(距离…)` 在「哪个特征点最近」切换处**梯度不连续**，整屏会显出一张 Voronoi 多边形网（直线硬棱 + 发光胞心，像裂冰），比连续 FBM 更难看；换光滑剖面救不了，折痕来自 `min()` 本身。要做就把光滑核 `(1-q)³`（`q=|v|²/R²`）**相加**（metaball）：处处 C1 连续、圆包柔和融合、且不需要 sqrt。另外胞状噪声的哈希不能用 `fract(sin(·))` —— 它的输出直接是特征点**位置**，相关性会变成成排鼓包（梯度噪声里则被插值掩盖）。云海形状这条路走过两轮后按观感回退到低频宏观梯度 FBM + 小权重高频侵蚀，详见 `docs/cpp-dots-runtime/vision-fog-and-borders.md`。
16. **云的暗部要偏蓝，不是中性灰。** 深处的照明主导权从太阳交给天光（Rayleigh 散射，强烈偏蓝），所以 MS 回填的**颜色**要随深度从主光色漂向天光色。受光面暖白 + 暗面冷蓝的对比是云"看起来真"的一大半。色相 tint 先归一化到亮度 1，让改色相和改明度成为两个独立自由度。
17. **任何吃 TOD 的图层都必须消费 `EarthDaylight` 的月光三件套**（`moon_dir`/`moon_col`/`moon_strength`）。日月方向近乎相反，不能直接向量插值；实体表面可选主光硬切，透明/云层则应分别计算日光与月光后连续相加，并在方向轴切换附近削弱方向性阴影。高空云的昼夜过渡应比地表更宽，可加入暮光金橙散射。月光不能简单复用太阳的法线、直射与质量阴影增益：深夜应由低方向性的冷灰天空光和多重散射主导，局部法线只保留微弱月光层次。
18. **动态云层必须消费表现时钟倍率。** 程序化噪声的各频段要用不同相位随时间演化，不能只做整场刚性平移；天气云与迷雾云都通过 `set_clock_speed_multiplier()` 同步游戏倍速，避免 x20 时模拟飞奔而云形仍按真实时间慢放。
19. 与时间无关、只随地图/biome 变化的视觉细节优先烘进 atlas；当前 `terrain_detail_tex` 由 `MapBaker` 初次 bake 和 biome 轴重烘维护。
20. **近景尺度的贴图细节不能直接进入大陆视角的光照。** 地形材质法线必须随放大倍数淡入（口径见 §14.5：`pk_hex_px()`，**不是** `camera_zoom`），并且不能进入 `macro_normal`；远景纹理密度靠放大平铺的远层和低频斑块提供，不能靠压低单层平铺尺寸。

### 14.5 像素尺度细节（pixel-scale detail，2026-11-03）

地表所有细节层（材质平铺 / micro / 程序化 biome 噪声）都是**固定世界尺度**，相机放大时被等比拉大；放大到近景后没有任何一层提供"屏幕像素级"的高频，观感就是放大的像素颗粒。修法不是改频率（会让纹理随缩放游动），而是**补更细的一级常量世界尺度细节 + 按纹素投影交叉淡入**。

**唯一换算入口**：`pixel_scale.gdshaderinc`。权威输入是 `uniform float pixel_world_size`（= 1 / (camera_zoom × content_scale)，一个**物理**像素覆盖多少世界单位，`hex_renderer` 逐帧推送）。

| helper | 语义 | 典型用途 |
|---|---|---|
| `pk_px_per_world_unit()` | 1 world unit = 几屏幕像素（含 content_scale） | 整帧稳定门控（dither 亚像素淡出） |
| `pk_world_per_px_at(wp)` | 1 屏幕像素 = 几 world units，逐像素取 `dFdx/dFdy` 并夹在 `[uniform, 4×]` | 逐像素细节权重 |
| `pk_px_per_world_at(wp)` | 上式的倒数 | 纹素投影换算 |
| `pk_hex_px()` | `hex_size × px_per_world` = 一个 hex 占几物理像素 | 缩放档位门控（micro 淡入 / land dither 淡出） |
| `pk_near_detail_blend(wp, texel_world)` | 纹素投影 2.5px 起、6px 满的 `smoothstep` | 所有"更细一级"的交叉淡入 |

**换算口径（为什么要 hex_px）**：content_scale 被 `pixel_world_size` 吃掉，所以阈值只写一套：
`hex_px` 相同 ⇔ 纹素放大倍数相同 ⇔ 两端观感一致。桌面 `camera_zoom` 阈值 × 默认 `hex_size` 22 就是下表；移动端同一个 hex_px 对应 `camera_zoom / 1.375`。

| 门控 | 旧口径（camera_zoom） | 新口径（hex_px） | 备注 |
|---|---|---|---|
| `terrain_micro_zoom_alpha` vq>=2 | 桌面 1.30 / 1.95；移动 1.55 / 2.20 | 28.6 / 42.9 | 微表面淡入 |
| `terrain_micro_zoom_alpha` vq>=1 | 桌面 1.50 / 2.15；移动 1.80 / 2.50 | 33.0 / 47.3 | |
| `terrain_micro_zoom_alpha` vq=0 | 桌面 2.05 / 2.75；移动 2.35 / 2.95 | 45.1 / 60.5 | |
| `terrain_land_dither_zoom_strength` | 桌面 1.20 / 2.05；移动 1.65 / 2.45 | 26.4 / 45.1 | 桌面/移动统一；移动仍叠亚像素淡出 |
| `terrain_dither_subpixel_fade` | `camera_zoom × texel_world` | `texel_world × pk_px_per_world_unit()` | 阈值 0.85 / 2.2 **物理像素**不变 |

**新增层级与预算**（每像素最多 +2 次采样，远景 0 次）：

| 层级 | 世界尺度 | 出现条件 | 成本 |
|---|---|---|---|
| micro 一级 | 110 world / 张（纹素 110/256） | `hex_px >= 28.6`（vq2） | 既有 1 sample |
| micro 二级 | 24.2 world / 张（4.5× 频率，**同一张纹理**） | 一级纹素 ≥2.5px（桌面 zoom 5.8 / 移动 4.2）且 vq>=1 | +1 sample，权重 `mix` 交叉淡入（能量守恒） |
| biome 近景高频 | 纹素 ≈0.645 world（`k=1.55`） | 参照纹素（2.0 world）≥2.5px 且 vq>=1 | +1 sample（`noise_tex`），`t=0` 时不采 |

`vq=0` 是硬契约：`procedural_biome_detail` 早退、micro 在 `zoom_alpha<=0` / `visual_quality<=0` 处早退，两级新增细节都不可达 ⇒ LOW 像素不变（`web_quality_render_test` 守着）。

---

## 15. 调试与回归

### 15.1 单独验证 BRDF

把 `day_night_enabled=false` 可去掉晨昏线影响，保留永昼全局平行光来验证 surface / BRDF（base_color/normal 是否对）。

### 15.2 单独验证 atlas 通道

`shaders/data_overlay.gdshader` 是独立的 debug shader，把任意 atlas 通道按红绿蓝直出。

### 15.3 视觉回归检查表

| 维度 | 验证步骤 |
|---|---|
| 6 类 biome 基色 | 在 `main.tscn` 切换 OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE 的视图，对照 `world_map.legacy.gdshader.bak` |
| 3 档 shader variant | 通过 `PK_SHADER_TIER_LOW/MID/HIGH` 各编译一次，确认低档不编译 caustics/sparkle/天气细节，画面仍保主色和主形态 |
| 4 个季节 | `season_phase ∈ {0,1,2,3}`，对照植被色与雪线 |
| 一键回退 | 改 `USE_PBR_BRDF=false` 重编译，确认与 v9 视觉等价 |
| 昼夜循环 | `day_phase ∈ [0,1]`，确认夜间冷蓝月光能读出地形法线、night_factor 不爆黑、日出日落色温过渡顺滑 |
| 动态永昼切换 | 点击玩家顶栏月亮按钮，确认 `day_night_enabled=false` 后晨昏线消失；方位仅随 `season_phase` 在一年内转一圈，高度仅随直射点纬度在 15°–45° 变化；重新开启后正常日/月/晨昏线仍只有一套 |

### 15.4 性能回归

Godot 监视器 → Visual → "FPS in Game" 与 "Frame Time"。1920×1080 60FPS 是底线。

---

## 16. 常见陷阱

| 陷阱 | 错误现象 | 根因 / 修复 |
|---|---|---|
| `const float PI = …` | 编译报"PI 重复定义" | Godot 4 内置 `PI`，不要重声明（已知问题，本套已修） |
| `pixel_noise.r/g/b/a` 当独立 RV 用 | 多个效果同节奏抖动 | 改调 `derive_independent_noise4(wp + offset)` |
| 在 sRGB 域做 mix 后期望 PBR 正确 | 颜色偏暗 / 偏灰 | 走 BRDF 前必须 `srgb_to_linear`，输出后必须 `linear_to_srgb`；非 BRDF 路径继续 sRGB 域 |
| 在 `compute_*_base_surface` 内 mix tonemap | land/water 基准不一致 | 所有 pipeline 必须输出 linear-HDR，tonemap 仅在 `apply_global_adjustments` 末端 |
| LAKE 用 `max(gloss, 72)` 强制高光 | 与 PBR 模型冲突，能量不守恒 | LAKE 走 `compute_water_biome_weights` 写正确 roughness |
| 在 `apply_land_material_modifiers` 改 normal/roughness | 把 modifier 与 overlay 职责混淆 | modifier 阶段**只改 base_color**；N/R/M/AO 走 `apply_land_material_overlays` |
| 在 `make_surface_params` 漏写 metallic/emission | 雪面无微反射 / 火山无自发光 | 用 `make_surface_params_full` 或先 `make_surface_params` 再 `add_emission` |
| 新加 magic number 散在 pipeline 里 | 调参要全文件搜 | 必须先在 `material_constants.gdshaderinc` 声明 const |
| 新 inc 放错位置 | 编译报"未定义符号" | 严格按 §3 拓扑表加入 |
| `SurfaceTextureSet.has_*=false` 时还做 mix | 性能浪费 | helper 顶部已有 early return，禁止挪走 |
| 用 `height_tex` 邻域差分求法线 | 运行期多 4–8 次采样；移动端/LOW 还会被裁成只有粗法线，Web 永远读不出起伏 | 法线只能来自生成期烘焙（`terrain_surface_tex` layer0/layer1 或 tiled 数组），唯一入口 `terrain_baked_normal`；新增形态请改生成期 bake |
| 给 Web 地形再加一个 sampler | 第 9 张起落在 unit 9，被内建高光/灯光图集默认白纹覆盖（2026-08「全河/全白」事故根因） | Web 地形 8 槽是硬预算；新效果先复用现有槽（如加 array layer）或走纯 ALU/生成期烘焙，不得加 sampler |
| 在 world_map 里重新声明 2D `terrain_normal_tex` | 非 tiled 走打包 array 后，多声明 2D normal 会与 array 抢槽、且出现两套法线来源 | 非 tiled 的 world_map 只读 `terrain_surface_tex`；2D normal 仅给只开 `VT_USE_TERRAIN_NORMAL` 的其它 shader |
| 在 world_map 里重新声明 2D `terrain_detail_tex` / `terrain_micro_tex` / `gi_occluder_tex` / `bounce_lut` | v3 已把它们塞进 surface/material array；多声明会破坏 8 槽预算或出现两套来源 | 非 tiled world_map 只读 array layer（detail=layer2、occluder=layer3、micro=material layer4）；旧 2D sampler 不再声明 |
| 把 detail/micro/bounce 的新采样加在 LOW 档 | LOW 是"B 前后像素一致"的性能契约，改层内容会出画面差异 | 全部经 `visual_quality` 门控早退（LOW 不采样），并由 `web_quality_render_test` 的 LOW 断言守住 |
| 把 `PK_LAND_ONLY` 加进 `land_pipeline.gdshaderinc` 的河面法线压平条件 | 桌面陆地河心水波法线被错误压平（视觉退化） | 该 `#if` 只认 `PK_MOBILE_ANY` / `PK_WEB_LAND_ONLY`：Web land-only 不 include `water.gdshaderinc` 才需要压平；桌面 land-only **保留** `water.gdshaderinc`，必须采样 `sample_water_normal` |
| tiled 桌面拆分后陆地 program 丢掉 `VT_USE_WATER_DEPTH` | 水面/海岸看起来"变糊"、`PK_TERRAIN_STATIC_BAKED` 静默失效、海岸软权重退回 8-fetch 邻域 | 桌面非预算变体的 VT 预算块对所有 program 无条件打开；`terrain_shader_variant_test` 有 `terrain_static_baked` + `visual_water_depth_tiles` 断言 |
| 拆分只回退一半（只拆水面程序 / 只回退水面） | 水面像素被 land-only program discard 成背景空洞，或两片重复上色 | 编译失败必须**整条**回退单 program（`_split_program_failed` → 重编无 `PK_LAND_ONLY` 的陆地变体 + 整张 quad）；F9 toggle 也两片一起关 |
| 水面 program 对未探索像素 `discard` 让 pass 1 兜底 | 分 mesh 后纯水 block 没有陆地 pass → 迷雾出空洞（Web 上 Fog 层还可能被裁掉） | 各 program 自己画同值 `fog_unexplored_color`（含 compact web 水面程序），两片同色幂等 |
| 覆盖 mesh 顶点/世界矩形/wrap 与 `HexRenderer._build_world_quad_mesh()` 不一致 | LUT 采错 cell、wrap 接缝漏画/双重影 | 契约见 §14.3：同一套 world_bounds/wrap 规则（±P 三份、世界坐标顶点）；覆盖只是保守超集，逐像素分类仍由 fragment `is_water` 决定 |
| 把覆盖 mesh 的空 ArrayMesh 当失败 | 全水/全陆地图每帧回退整张 quad（白白多画） | 模块成功即 `ok=true`，`land_mesh`/`water_mesh` 可能是 0-surface 的合法空 ArrayMesh（`is Mesh` 即有效）；只有 `ok=false` 才回退 |

---

## 附：模块速查卡

| 文件 | 顶层符号 | 一句话 |
|---|---|---|
| `world_map.gdshader` | `vertex / fragment` | 入口 + atlas SETUP + 陆/水分派 |
| `uniforms.gdshaderinc` | `B_*`, `WT_*`, `V_*`, sampler/uniform 全集 | 数据层叶子 |
| `material_constants.gdshaderinc` | `USE_PBR_BRDF`, F0_*, AMBIENT_*, GLOSS_*_LEGACY | 常量与开关 |
| `tonemap.gdshaderinc` | `srgb_to_linear`, `linear_to_srgb`, `apply_tonemap` | 颜色空间 + tonemap |
| `surface_params.gdshaderinc` | `SurfaceParams`, `make_surface_params*`, `add_emission` | 半 PBR 容器 |
| `brdf.gdshaderinc` | `LightingContext`, `evaluate_brdf` | 光照核心 |
| `shore_common.gdshaderinc` | `sample_shore_neighborhood`, `compute_shore_halo` | 海岸 3×3 邻域 + halo |
| `common_noise.gdshaderinc` | `fbm`, `voronoi_cell`, `derive_independent_noise4` | 噪声 |
| `height.gdshaderinc` | `decode_height_rg8` | RG8 → elev |
| `climate_season.gdshaderinc` | `hemi_phase`, `season_offset_unified`, `compute_current_temp` | 温度/季节 |
| `biome_color.gdshaderinc` | `compute_biome_color` | biome → 基色 |
| `biome_detail.gdshaderinc` | `apply_biome_detail` | biome 内部细节 |
| `vegetation.gdshaderinc` | `apply_vegetation_*` | 植被季节色 |
| `weather_front.gdshaderinc` | `compute_extreme_weather_mask` | 极端天气 |
| `snow_cover.gdshaderinc` | `apply_snow_cover` | 雪盖 |
| `hillshade_tod.gdshaderinc` | `terrain_baked_normal`, `biome_roughness` | 烘焙法线唯一入口 / 昼夜 |
| `water.gdshaderinc` | `apply_water_*` | 水共享细节 |
| `land_pipeline.gdshaderinc` | `render_land_pipeline` | 陆地总调度（`PK_WATER_ONLY` 时不 include） |
| `water_pipeline.gdshaderinc` | `render_water_pipeline`, `apply_water_specials` | 水面总调度（`PK_LAND_ONLY` 时不 include） |
| `world_water_web.gdshader` | `render_water_pipeline_web_min`, `shade_water_web` | Web LOW/MID 紧凑水面第二 pass（5 槽；自己画迷雾色） |
| `global_adjustments.gdshaderinc` | `apply_global_adjustments` | 末端调整 + tonemap |
| `scripts/rendering/terrain_coverage_mesh.gd` | `TerrainCoverageMesh.build` | 陆地/水面保守覆盖 ArrayMesh（拆分几何） |

---

> 文档维护：每次改动主结构（新加 inc / 改 BRDF 接口 / 改 SurfaceParams 字段）需同步更新本文件。
> 最后更新：2026-11-02（全平台陆地/水面双 program 拆分 + TerrainCoverageMesh 覆盖几何 + 水面 program 自画迷雾色）
