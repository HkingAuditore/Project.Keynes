# Project.Keynes 地形 Shader 开发文档

> 版本：v10.semi-pbr（2026-05-19 重构后）
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
    COLOR = apply_global_adjustments(col, wp, pixel_noise); // 羊皮纸 + tonemap + sRGB
}
```

---

## 3. Include 拓扑与依赖

**严格按以下顺序**写入 `world_map.gdshader`，不可乱序（GLSL 没有前向声明，被引用符号必须先定义）：

| # | 模块 | 依赖项 | 角色 |
|---|---|---|---|
| 1 | `uniforms.gdshaderinc` | – | 叶子，所有 sampler / 常量 / 枚举 ID 入口 |
| 2 | `material_constants.gdshaderinc` | uniforms | 叶子，magic number / F0 / 特性开关 |
| 3 | `common_noise.gdshaderinc` | uniforms | 叶子，`fbm` / `voronoi_cell` / `derive_independent_noise4` |
| 4 | `height.gdshaderinc` | uniforms | 叶子，`decode_height_rg8` |
| 5 | `climate_season.gdshaderinc` | uniforms | 叶子，`hemi_phase` / `season_offset_unified` / `compute_current_temp` |
| 6 | `biome_color.gdshaderinc` | uniforms, B_* | 叶子，按 biome 取基础色 |
| 7 | `vegetation.gdshaderinc` | common_noise + uniforms.V_* | 叶子，植被季节色 |
| 8 | `weather_front.gdshaderinc` | common_noise + uniforms.WT_* | 叶子，极端天气掩码 |
| 9 | `snow_cover.gdshaderinc` | common_noise + height + weather_front | 雪盖判定与色化 |
| 10 | `biome_detail.gdshaderinc` | common_noise + B_* | biome 内部纹理变化 |
| 11 | `hillshade_tod.gdshaderinc` | uniforms + height | 山影 + 时间昼夜 |
| 12 | `water.gdshaderinc` | common_noise + uniforms.B_* | 水共享细节（波纹/平静面） |
| 13 | `surface_params.gdshaderinc` | material_constants | 半 PBR 容器 |
| 14 | `tonemap.gdshaderinc` | material_constants | sRGB↔Linear / ACES |
| 15 | `shore_common.gdshaderinc` | uniforms + material_constants | 海岸 3×3 邻域 + halo |
| 16 | `brdf.gdshaderinc` | surface_params + tonemap + material_constants + uniforms.tod_* | 光照核心 |
| 17 | `land_pipeline.gdshaderinc` | 全部上游 | 陆地总调度 |
| 18 | `water_pipeline.gdshaderinc` | 全部上游 | 水面总调度 |
| 19 | `global_adjustments.gdshaderinc` | tonemap + uniforms | 末端调整（羊皮纸/季节过渡/tonemap/sRGB） |

> **新增 inc 时**：只能放在自己依赖的最后一个 inc 之后；如果新模块给多个下游用，应同时更新本表。

---

## 4. 数据流（Atlas 通道）

CPU 端（Godot GDScript）把 hex 内恒定的动态状态打包成 cell-index + per-cell LUT。shader 在 fragment 开头解析 cell id，并从 LUT 采样动态/生态状态：

| Atlas | 格式 | 通道含义 |
|---|---|---|
| `height_tex` | RG8 LINEAR | `(R*256 + G)/257` ⇒ 海拔 [0,1] |
| `map_index_atlas` | RGBA8 NEAREST | R=biome, G/B=`cell.index` low/high, A=保留 |
| `enum_lut` | RGB8 NEAREST | per-cell biome / vegetation / cover |
| `dyn_lut` | RGBA8 NEAREST | R=temp, G=wetness, B=snow_cover, A=sea_ice 或 vitality |
| `eco_lut` | RGBA8 NEAREST | R=foliage_density, G=stress, B=transition_age, A=growth |

**关键约定**：

- `dyn_valid = (_cell_id < 0) ? 0.0 : 1.0`：地图外哨兵像素走 fallback；
- `eco_valid = step(0.01, eco_foliage + eco_stress + eco_transition)`：生态层是否已 bake；
- `scalar_atlas` / `vector_atlas` / `dynamic_cell_atlas` / `dyn_atlas_smooth_atlas` /
  `ecology_visual_atlas` / `ice_state_atlas` / `sea_ice_tex` 已退役，不再绑定或采样。

---

## 5. 核心渲染管线

每个 fragment 的执行路径如下：

```
SETUP（world_map.gdshader::fragment）
  ├── 采样 6 张 atlas + noise_tex（1 次 pixel_noise）
  ├── 解码 elev / biome / veg / cover / moist / lat_norm
  ├── 解码 dyn_temp / dyn_wet / dyn_snow / dyn_vitality
  ├── 解码 eco_foliage / eco_stress / eco_transition / eco_growth
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
                     ├── season_transition_overlay（pixel_noise.a 派生 dissolve）
                     ├── apply_tonemap（ACES 或 Reinhard）
                     └── linear_to_srgb（仅 USE_LINEAR_LIGHTING=true）
```

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

### 6.3 旁路：hillshade-only

`day_night_enabled=false` 时调试模式，走 `evaluate_hillshade_only(s)`，保留 v9 key+fill 双光源体验。

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
    vec3  normal;       // 已归一化
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
    float eco_foliage, float eco_stress, float eco_transition,
    float eco_growth, float eco_valid, vec4 pixel_noise);
```

### 8.2 LAND 1.x — `compute_land_base_surface`

输出 `SurfaceParams`：

| Stage | 改动字段 | 说明 |
|---|---|---|
| 1.1 hypsometric / biome / detail | base_color | 海拔色带 + biome 基色 + biome_detail |
| 1.2 河流 | base_color, ao | 沿 flow_accum 描线，ao 微降 |
| 1.3 顺坡明暗 | base_color | 旧 hillshade 微调（保持 v9 风味） |
| 1.4 等高线 | base_color | 等高线条 |
| 1.5 N/R/AO/metallic | normal/roughness/ao/metallic | 切坡度→法线，地表粗糙度按 biome 派生 |

### 8.3 LAND 2.x — `apply_land_material_modifiers`

四个 stage helper 串联，**只改 base_color**：

```glsl
struct LandModInputs { /* 13 字段 */ };

surface = apply_seasonal_vegetation_tint(surface, i);   // 2.1
surface = apply_moisture_tint(surface, i);              // 2.2
surface = apply_vegetation_axis_tint(surface, i);       // 2.3
surface = apply_ecology_tint(surface, i);               // 2.4
```

新增季节/植被 modifier：在 `LandModInputs` 加字段，写一个新 `apply_xxx_tint`，加到 `apply_land_material_modifiers` 调度即可。

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

---

## 9. 水面管线（Water Pipeline）

**位置**：`water_pipeline.gdshaderinc`

### 9.1 总调度

```glsl
vec3 render_water_pipeline(
    int biome, float elev, vec2 wp, vec2 uv,
    vec4 scals, float lat_signed, float current_temp,
    vec2 ocean_current_v, vec2 wind_v);
```

### 9.2 SEA 1.x — `compute_water_base_surface`

由于水面变化更复杂，base 函数被拆成 14 个 helper（每个 ≤60 行），通过 `WaterStageCtx` 串联：

| Stage | Helper | 作用 |
|---|---|---|
| 1.1 | `compute_offshore_depth` | 由邻居判定离岸深度 |
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
vec3 apply_water_specials(vec3 col, SurfaceParams surface, int biome, vec2 wp, int quality);
```

负责 `caustics_enabled` / `water_sparkle_enabled` / `water_fresnel_enabled` 的视觉乘子。这些是 **stylized** 而非 PBR，故从 BRDF 中分离。

### 9.4 SEA 3 — `shade_water_surface`

```glsl
LightingContext lc = make_lighting_context(AMBIENT_FLOOR_WATER);
vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_WATER_LEGACY, SPEC_MIN_WATER_LEGACY);
return apply_water_specials(lit, surface, biome, wp, visual_quality);
```

---

## 10. 全局后处理（Global Adjustments）

**位置**：`global_adjustments.gdshaderinc`

```glsl
vec3 apply_global_adjustments(vec3 col, vec2 wp, vec4 pixel_noise) {
    col = apply_paper_grain(col, wp, pixel_noise);          // 羊皮纸纸纹
    col = apply_equator_band(col, ...);                     // 赤道带柔光
    col = apply_season_transition_overlay(col, pixel_noise);// 季节过渡 dissolve
    if (USE_LINEAR_LIGHTING && day_night_enabled) {
        col = apply_tonemap(col);    // ACES 或 Reinhard，内部自带 exposure_bias
        col = linear_to_srgb(col);
    }
    return col;
}
```

**关键修复（v10 重构）**：旧版每个 pipeline 末尾各自调一次 Reinhard，导致 land/water 视觉基准不一致；现在统一在 `apply_global_adjustments` 末端单次 tonemap，所有上游均输出 **linear-HDR**。

---

## 11. 噪声系统

**位置**：`common_noise.gdshaderinc`

| 函数 | 用途 | 性能 |
|---|---|---|
| `value_noise(p)` | 基础值噪声 | 1 fetch |
| `fbm(p, oct)` | 多倍频噪声 | oct fetches |
| `voronoi_cell(p)` | 蜂窝噪声 | ~9 hash21 |
| `derive_independent_noise4(seed)` | 4 个相互独立的随机数 | 4 sin + 4 dot ≈ 8 ALU |
| `noise_tex 采样` | 主路径，预烘焙 4 通道 noise pack | 1 fetch |

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
const float NIGHT_BRIGHTNESS_FLOOR = 0.55;
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
    s = apply_seasonal_vegetation_tint(s, i);
    s = apply_moisture_tint(s, i);
    s = apply_vegetation_axis_tint(s, i);
    s = apply_ecology_tint(s, i);
    s = apply_volcanic_ash_tint(s, i);    // ← 加在最后
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

> 以 1920×1080 全屏 1× 渲染、`visual_quality=2` 估算

| 阶段 | 纹理 fetch | ALU（约） |
|---|---|---|
| SETUP（atlas 解码 + pixel_noise） | 7 | 30 |
| 陆地 base + modifier + overlay | 4-6（noise/biome_detail） | ~120 |
| 水面 base（14 helper 全开） | 3-5 | ~180 |
| BRDF 主路径（Cook-Torrance） | 0 | ~32 |
| BRDF legacy（Blinn-Phong） | 0 | ~14 |
| global_adjustments | 0 | ~25 |

**优化原则**：

1. `visual_quality` 三档（0/1/2）控制 octave / 高代价 helper 是否启用
2. 编译期常量分支（`USE_*`）必死代码消除；运行期 uniform 分支使用 `if` 即可，Godot 4 GLSL 编译器会做 wave-coherent 优化
3. 禁止在 fragment 内写循环变长边界——所有 `for (int i = 0; i < CONST; i++)` 必须用编译期常量

---

## 15. 调试与回归

### 15.1 单独验证 BRDF

把 `day_night_enabled=false`，shader 走 `evaluate_hillshade_only`，可单独定位 surface 是否构造正确（base_color/normal 是否对）。

### 15.2 单独验证 atlas 通道

`shaders/data_overlay.gdshader` 是独立的 debug shader，把任意 atlas 通道按红绿蓝直出。

### 15.3 视觉回归检查表

| 维度 | 验证步骤 |
|---|---|
| 6 类 biome 基色 | 在 `main.tscn` 切换 OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE 的视图，对照 `world_map.legacy.gdshader.bak` |
| 3 档 visual_quality | `0=低/1=中/2=高`，确认低档不爆 caustics、不丢 sparkle |
| 4 个季节 | `season_phase ∈ {0,1,2,3}`，对照植被色与雪线 |
| 一键回退 | 改 `USE_PBR_BRDF=false` 重编译，确认与 v9 视觉等价 |
| 昼夜循环 | `day_phase ∈ [0,1]`，确认夜间 night_factor 不爆黑、日出日落色温过渡顺滑 |

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
| `hillshade_tod.gdshaderinc` | `apply_hillshade_*` | 山影/昼夜 |
| `water.gdshaderinc` | `apply_water_*` | 水共享细节 |
| `land_pipeline.gdshaderinc` | `render_land_pipeline` | 陆地总调度 |
| `water_pipeline.gdshaderinc` | `render_water_pipeline`, `apply_water_specials` | 水面总调度 |
| `global_adjustments.gdshaderinc` | `apply_global_adjustments` | 末端调整 + tonemap |

---

> 文档维护：每次改动主结构（新加 inc / 改 BRDF 接口 / 改 SurfaceParams 字段）需同步更新本文件。
> 最后更新：2026-05-19（半 PBR 重构完工）
