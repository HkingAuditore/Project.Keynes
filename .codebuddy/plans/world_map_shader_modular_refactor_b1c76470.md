---
name: world_map_shader_modular_refactor
overview: 把 `world_map.gdshader`（2299 行）按"uniform 块 / 常量 / 函数域"彻底拆分到 `shaders/include/` 下的多个 `.gdshaderinc` 文件，主文件仅保留 `#include` 列表 + `vertex/fragment` 主体，并补全模块化注释。所有 uniform 名称、默认值、行为保持 100% 不变，CPU 端（hex_renderer.gd / weather_layer.gd / world_map_material.tres）零改动。
todos:
  - id: extract-uniforms
    content: 在 shaders/include/ 新建 uniforms.gdshaderinc，把全部 uniform、常量（B_/V_/CV_/WT_）、植被 LUT、varying v_world 按功能分组迁入并加段注释。
    status: completed
  - id: extract-leaf-helpers
    content: 新建 height / climate_season / biome_color / vegetation / snow_cover / weather_front / biome_detail / hillshade_tod 八个 .gdshaderinc，原文搬迁对应函数，文件头补"职责/依赖/调用方/PERF"注释。
    status: completed
    dependencies:
      - extract-uniforms
  - id: rewire-main-shader
    content: "改写 world_map.gdshader：仅保留 shader_type、render_mode、按拓扑顺序的 11 个 #include、vertex()，删除已迁出的 uniform 与函数体。"
    status: completed
    dependencies:
      - extract-leaf-helpers
  - id: annotate-fragment-stages
    content: 为留在主文件的 fragment() 主体加 STAGE 注释（atlas 采样 / 陆地 / 水面 / 河流 / 海岸 / 雪 / 覆盖物 / 天气 / 火山 / 羊皮纸 / TOD / 季节过渡），不修改任何表达式。
    status: completed
    dependencies:
      - rewire-main-shader
  - id: verify-zero-regression
    content: 用 [subagent:code-explorer] 反向扫描所有 set_shader_parameter("...") 与 .tres 中引用的 uniform 名，与 uniforms.gdshaderinc 对照清单，确认无遗漏/改名/默认值漂移。
    status: completed
    dependencies:
      - annotate-fragment-stages
---

## 用户原始诉求

将 `Project/project-keynes/shaders/world_map.gdshader`（单文件 2299 行）做一次彻底的结构性重构：拆成多个文件、写好注释、把"输入（uniform）"和"输出（函数）"按功能模块分类码放，方便后续手动定位与修改某个子系统。

## 重构目标

- **可维护性**：单文件不超过约 400 行；每个模块顶部有"职责 / 依赖 / 调用方 / 数据流向"四段注释。
- **结构清晰**：uniform 与函数按"功能模块"集中放置——找水体改水体文件、找天气改天气文件，不再在 2300 行里翻。
- **行为零回归**：本次重构是**纯文本搬迁 + `#include` 组合**，shader 行为、uniform 名/类型/默认值/hint 修饰、`MAX_WEATHER_FRONTS=16` 等外部接口 100% 保持不变（材质 `.tres` 与所有 GDScript 的 `set_shader_parameter` 无需改动）。
- **性能锚点**：用户提到"性能也不好"，但本轮不做行为修改；在拆出的每个模块顶部用 `// PERF:` 注释标注疑似热点（fbm 调用次数、邻域采样次数、weather front 循环），供后续独立优化任务定位。

## 拆分模块（按"找问题→进对应文件"的直觉划分）

1. **uniforms / 常量**：纹理输入、世界尺寸、视觉总开关、颜色色阶、生物群系/植被/覆盖物/天气 id 常量、植被 LUT、`varying`。
2. **noise**：已有 `common_noise.gdshaderinc`，保持不动。
3. **height**：`decode_height_rg8` 与小工具。
4. **climate_season**：半球相位、insolation、季节温度偏移、当前温度。
5. **biome_color**：hypsometric、深海三层 tint、`biome_hue_modulate`。
6. **vegetation**：植被四季 LUT、`vegetation_seasonal_tint*`、`vegetation_tint`、`biome_accepts_vegetation_tint`。
7. **snow_cover**：`compute_snow_factor` 与 `cover_overlay`。
8. **weather_front**：4 个 weather 几何/掩码函数与 `sample_terrain_weather_tint`。
9. **biome_detail**：`procedural_biome_detail` 巨型分支。
10. **hillshade_tod**：双光源 hillshading + `get_sun_dir/sky_tint/day_brightness/apply_day_night` + `compute_terrain_normal/biome_roughness/apply_tod_pbr`。
11. **water**：保留现有 `water.gdshaderinc`，不动。
12. **主文件**：仅保留 `shader_type`、`render_mode`、若干 `#include`、`vertex()`、`fragment()`（fragment 主体也按 section 用注释清楚划分阶段：采样→陆地→水面→后处理）。

## Tech Stack

- **目标平台**：Godot 4 Shading Language（GLSL 风格的 `canvas_item` shader）。
- **拆分机制**：Godot 4 原生支持 `#include "res://path/to.gdshaderinc"`（项目内已有 `common_noise.gdshaderinc`、`water.gdshaderinc` 两处验证可用，分别在主 shader 第 363 行与第 1244 行 include 成功）。沿用同一机制，无新增外部依赖。

## Implementation Approach

**策略：纯文本搬迁 + `#include` 顺序组合**，确保 zero behavior change。

### 关键技术决策

1. **不引入新模式**：项目已经在用 `.gdshaderinc` 分文件，沿用即可，不引入条件编译、宏开关等额外机制。
2. **保留外部接口铁律**：所有 uniform 的名称/类型/默认值/`hint_range`/`source_color`/`filter_*`/`repeat_*`/`hint_default_black` 标注、`MAX_WEATHER_FRONTS=16` 数组长度、所有 `B_*` / `V_*` / `CV_*` / `WT_*` 常量名与数值——全部按原样原文复制粘贴到对应 include。`world_map_material.tres` 与 GDScript `set_shader_parameter("...")` 调用无需改动。
3. **`#include` 顺序按依赖拓扑排序**：Godot 4 的 `#include` 等价于文本展开（无前向声明），所以在主 shader 中必须按以下顺序 include（顺序错误会导致 "未声明 / 重定义"）：

```
4. uniforms.gdshaderinc           // 所有 uniform、所有常量、varying
5. common_noise.gdshaderinc       // 已存在；依赖 noise_tex / NOISE_TEX_SCALE
6. height.gdshaderinc             // decode_height_rg8（依赖 height_tex / hm_resolution）
7. climate_season.gdshaderinc     // hemi_phase / insolation_* / compute_current_temp
8. biome_color.gdshaderinc        // hypsometric_tint / deep_ocean_*_tint
9. vegetation.gdshaderinc         // vegetation_seasonal_tint_lut 等（依赖 fbm + V_* + LUT）
10. snow_cover.gdshaderinc         // compute_snow_factor / cover_overlay（依赖 fbm）
11. weather_front.gdshaderinc      // weather_front_* / sample_terrain_weather_tint
12. biome_detail.gdshaderinc       // procedural_biome_detail（依赖 fbm/voronoi_cell）
13. hillshade_tod.gdshaderinc     // hillshading_two_lights / apply_tod_pbr
14. water.gdshaderinc             // 已存在；依赖 enum_atlas + B_LAKE/B_REEF/B_KELP/B_SEA_ICE
```

15. **fragment 函数留在主文件**：fragment 主体（约 1050 行）是个"装配线"，把上面所有 helper 串起来。拆出去等于需要传 30+ 个局部状态参数，反而更难维护。保留在主文件里，但用 `// ─── STAGE N: xxx ───` section comment 把它划分成清晰的阶段（atlas 采样 / 陆地着色 / 水面着色 / 后处理 / TOD / 季节过渡），让定位仍然简单。
16. **不做性能优化**：本轮**只**做结构搬迁。fbm 调用次数、weather front 循环、邻域采样数等保持不变。仅在每个 include 头部用 `// PERF: ...` 标记疑似热点，作为后续优化任务的锚点。

### 注释规范

每个新 `.gdshaderinc` 顶部用统一格式：

```
// <模块名>.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：本文件提供什么（一句话）。
// 调用方：fragment() 哪个阶段会调用 / 哪些函数依赖本文件。
// 依赖（caller-side 必须先声明 / 先 include）：
//   - uniform xxx                 （在 uniforms.gdshaderinc）
//   - sampler2D yyy               （在 uniforms.gdshaderinc）
//   - 常量 B_OCEAN / V_NONE / ... （在 uniforms.gdshaderinc）
//   - fbm / voronoi_cell          （在 common_noise.gdshaderinc）
// 性能（PERF）：本文件已知热点（fbm 次数 / 循环深度），供后续优化定位。
// ─────────────────────────────────────────────────────────────────────────
```

原代码内部的所有解释性中文注释（"2026-05-18 N1"、"P0-B"、"map-visual-overhaul-v1"、"v9.fbm-opt" 等历史决策注释）必须**完整保留**，因为它们记录了具体调参决策与修复记录。

## Implementation Notes

- **零行为变更原则**：禁止"顺手"重构 if-else 写法、合并相同分支、改变 `mix` 的参数顺序或 `clamp` 范围、改默认值。一切只是搬迁。
- **`vegetation_season_lut[V_COUNT * 4]`** 这种数组大小依赖 `V_COUNT` 常量；常量必须在数组声明之前 include。所以 `uniforms.gdshaderinc` 内部必须保持：先 `const int V_COUNT = 24;`，再 `uniform vec4 vegetation_season_lut[V_COUNT * 4];`（与现状一致）。
- **`water.gdshaderinc` 依赖 `enum_atlas` 与 `B_LAKE` 等常量**：这就是为什么旧文件把它的 `#include` 放在文件最末。新结构下 uniforms include 排第一，所以 water include 可以提前到合理位置（最后一个 include），保持现状即可。
- **避免循环 include**：所有 include 都是叶子模块（不互相 include），由主 shader 集中拼装。
- **`render_mode blend_mix` 与 `shader_type canvas_item`** 必须留在主文件最顶端，不能拆到 include 里（Godot 不允许 include 文件含 `shader_type`）。
- **回归验证**：用 `git diff --stat`（应只新增 .gdshaderinc，主文件大幅缩减），并打开 Godot 编辑器加载主场景肉眼对比一帧，确认未引入编译错误与视觉变化。

## Directory Structure

```
Project/project-keynes/shaders/
├── world_map.gdshader                                  # [MODIFY] 主文件，从 2299 行缩到 ~150 行。保留 shader_type、render_mode、所有 #include、vertex()、fragment()（含 STAGE 注释划分）。
├── world_map.gdshader.uid                              # [KEEP]
└── include/
    ├── common_noise.gdshaderinc                        # [KEEP] 已存在，不动。
    ├── water.gdshaderinc                               # [KEEP] 已存在，不动。
    ├── uniforms.gdshaderinc                            # [NEW] 集中所有 uniform、所有常量（B_/V_/CV_/WT_）、植被四季 LUT、varying v_world。按 section 注释分块：采样器组、世界/分辨率组、季节/气候组、TOD 组、水体子开关组、视觉总开关组、深海色组、植被/雪/风/洋流组、季节过渡组、天气锋面组、地形色阶组、hillshade 组、河流 / 等高线 / 海岸光晕 / 羊皮纸组、id 常量组、LUT 组。
    ├── height.gdshaderinc                              # [NEW] decode_height_rg8。依赖 height_tex / hm_resolution。
    ├── climate_season.gdshaderinc                      # [NEW] hemi_phase / season_temp_offset / season_temp_offset_legacy / compute_insolation_shader / insolation_annual_mean_shader / insolation_season_offset_shader / season_offset_unified / compute_current_temp。依赖 axial_tilt_rad / season_temp_amp / true_insolation_enabled / insolation_* / climate_anomaly / sea_level。
    ├── biome_color.gdshaderinc                         # [NEW] water_depth_gradient / deep_ocean_current_tint / deep_ocean_latitude_tint / deep_ocean_abyss_tint / hypsometric_tint / biome_hue_modulate。依赖 color_* uniform、deep_ocean_* uniform、B_* 常量、ocean_current_enabled。
    ├── vegetation.gdshaderinc                          # [NEW] vegetation_seasonal_tint / vegetation_seasonal_tint_dissolve / vegetation_seasonal_tint_lut / vegetation_tint / biome_accepts_vegetation_tint。依赖 fbm（common_noise）、V_* 常量、vegetation_season_lut、vegetation_anomaly_shift、climate_anomaly、B_* 常量。
    ├── snow_cover.gdshaderinc                          # [NEW] compute_snow_factor / cover_overlay。依赖 fbm、sea_level、B_* 常量、CV_* 常量。
    ├── weather_front.gdshaderinc                       # [NEW] weather_front_axis / weather_front_ellipse_distance / weather_front_gaussian_coverage / compute_extreme_weather_mask / sample_terrain_weather_tint。依赖 MAX_WEATHER_FRONTS、weather_front_centers/shapes/visuals/types/count、weather_strength、WT_* 常量、fbm。
    ├── biome_detail.gdshaderinc                        # [NEW] procedural_biome_detail（巨型 if-else 按 biome 分支，每个 biome 一段独立 fbm/voronoi 调色）。依赖 fbm、voronoi_cell、B_* 常量。文件头注释列出"每个 biome 用了什么噪声特征"以便后续单独调一个 biome。
    └── hillshade_tod.gdshaderinc                       # [NEW] hillshading_two_lights / get_sun_dir / get_sky_tint / get_day_brightness / apply_day_night（旧版） / compute_terrain_normal / biome_roughness / apply_tod_pbr。依赖 height_tex / hm_resolution / hillshade_* / tod_* / night_brightness_*、B_* 常量、decode_height_rg8。
```

外部不需要任何修改：

- `Project/project-keynes/materials/world_map_material.tres`：仍引用 `world_map.gdshader` 资源 UID 不变。
- `scripts/rendering/hex_renderer.gd` / `map_baker.gd` / `data_overlay_baker.gd` / `data_overlay_layer.gd` / `weather_layer.gd`：所有 `set_shader_parameter("...")` 因 uniform 名/类型/默认值未变而继续生效。