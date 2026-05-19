// uniforms.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：world_map.gdshader 的全部 uniform / 常量 / varying 声明集中地。
//        所有"shader 的输入"都在本文件，shader 的"输出"分散在各个 helper include。
// 调用方：world_map.gdshader（主 shader）必须最早 include 本文件。
//         所有 helper include（biome_color / vegetation / weather_front / ...）
//         都假设本文件的 uniform/常量已经在 caller-scope 中可见。
// 依赖：无（叶子模块）。
// 兼容铁律：
//   - 本文件所有 uniform 的【名称 / 类型 / hint 修饰（hint_range / source_color /
//     filter_* / repeat_* / hint_default_black）/ 默认值】对 GDScript 端
//     set_shader_parameter("...") 与 world_map_material.tres 必须 100% 保持不变。
//   - 所有 B_* / V_* / CV_* / WT_* 常量名与数值不可改动（CPU 端 enum 与之对齐）。
//   - MAX_WEATHER_FRONTS=16 不可改（CPU 端会照此大小裁剪 weather_front_* 数组）。
// 性能（PERF）：无。本文件只声明，运行时无开销。
// ─────────────────────────────────────────────────────────────────────────


// =========================================================================
// 【纹理输入组】
// =========================================================================
// world_map.gdshader v9.atlas：高分辨率地理仿真渲染
//   height_tex       (RG8 16-bit, hm_size, LINEAR)
//                     归一化海拔 [0, 1]，解码 (R*256 + G) / 257
//   enum_atlas       (RGB8, derived_size, NEAREST)
//                     R = biome (TerrainType.TERRAIN id)
//                     G = vegetation (VegetationType.VEG id)
//                     B = cover (CoverType.CV id)
//   scalar_atlas     (RGBA8, derived_size, LINEAR)
//                     R = moisture
//                     G = flow_accum (log-scaled)
//                     B = latitude_norm ∈ [0, 1]
//                     A = 0（保留）
//   vector_atlas     (RGBA8, derived_size, LINEAR)
//                     RG = ocean_current (-1..1 mapped from 0..1)
//                     BA = wind_field    (-1..1 mapped from 0..1)
//   dynamic_cell_atlas (RGBA8, derived_size, LINEAR)
//                     R=temp, G=wetness/moisture, B=snow_cover, A=vegetation_vitality
//   sea_ice_tex      (R8, derived_size, LINEAR)

//                     兼容旧调试/数据通道；主视觉海冰由 shader 按水温实时派生。
//
// 不再有 hex 逻辑、不再做 domain warp。整张地图就是这 4 张连续纹理的合成。
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D enum_atlas   : filter_nearest, repeat_disable;
uniform sampler2D scalar_atlas : filter_linear,  repeat_disable;
uniform sampler2D vector_atlas : filter_linear,  repeat_disable;
// vector_atlas 是否已注入真实数据。bake_world / commit_ocean_buffers 完成时由 hex_renderer 置 true。
// 未绑定时 Godot 默认 fallback 是白纹理（vec4(1)），错误地解码为 (1,1) 强洋流向；
// 用此 flag 让 shader 在 false 时直接把 vects 当 0.5 中性值，等价于"没有洋流/风"。
uniform bool vector_atlas_valid = false;
// dynamic_cell_atlas RGBA8：R=temp, G=wetness/moisture, B=snow_cover, A=vegetation_vitality。
// map-visual-overhaul-v1：主 shader 已切换到 `dyn_atlas_smooth_tex` 消费（消除 hex 阶梯）；
// 本 uniform 保留给调试/info 面板（hex_renderer 仍按旧接口绑定），shader 自身不再读它。
uniform sampler2D dynamic_cell_atlas : hint_default_black, filter_linear, repeat_disable;
// map-visual-overhaul-v1：dyn_atlas_smooth_tex RGBA8 LINEAR（derived_size）。
// dynamic_cell_atlas 的"沿 hex 邻接 box blur"产物，跨 cell 平滑——shader 单点采样
// 即可得到连续场，彻底消除"颜色按 hex 块切"的硬阶梯（病灶 B 解药）。
// hint_default_black 让纹理未绑定时采样为 (0,0,0,0)，触发 dyn_valid fallback。
uniform sampler2D dyn_atlas_smooth_atlas : hint_default_black, filter_linear, repeat_disable;
// map-visual-overhaul-v1：ice_state_atlas R8 LINEAR（derived_size）。
// 每像素 = 该 cell.sea_ice_frac × 255 量化；仅水域 cell 写非零，陆地恒 0。
// shader 据此替换原 lat-driven 静态 ice mask（病灶 A 解药）—— 海冰随温度真冻融、
// 边缘由 fbm 撕碎，不再"极地海冰终年不化"。
uniform sampler2D ice_state_atlas : hint_default_black, filter_linear, repeat_disable;
// ecology_visual_atlas RGBA8: R=foliage_density, G=stress/dryness,
// B=vegetation transition age, A=recent growth/damage.
uniform sampler2D ecology_visual_atlas : hint_default_black, filter_linear, repeat_disable;
// map-visual-overhaul-v1：weather_field_tex 已从主地图 shader 完全移除。
// 海面天气视觉（storm/rain/cloud_field）现在全部由 weather_overlay.gdshader 的
// 三层独立云（cirrus/cumulus/fog）承担——主地图保持"清爽地表"，不画云。
// 历史 uniform：weather_field_tex / weather_field_ocean_enabled /
//               weather_field_ocean_strength （已删除）。
// 兼容旧调试/数据通道；主地图海冰视觉不采样它。
uniform sampler2D sea_ice_tex : filter_linear, repeat_disable;
// v10.noise-pack：共享 noise 贴图（256×256 RGBA8 tileable，由 MapBaker 烘焙）。
// R=raw value_noise，G/B/A=2/3/4 octave fBM 预积分；fbm(p,N) 全局降为 1 次采样。
uniform sampler2D noise_tex    : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;



// =========================================================================
// 【世界 / 分辨率组】
// =========================================================================
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform vec2 derived_resolution = vec2(1024.0, 768.0);

uniform float sea_level : hint_range(0.0, 1.0) = 0.42;


// =========================================================================
// 【季节 / 时钟 / climate 组】
// =========================================================================
// ─── Phase 1：季节相位 + 气候异常（每帧由 WorldClock 驱动） ───────────────
// season_phase ∈ [0, 4)：0=春 1=夏 2=秋 3=冬
// climate_anomaly ∈ [-0.2, +0.2]：长期气温偏移
// world_time：累积秒数，给海洋洋流流纹动画用（Phase 3）
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float climate_anomaly : hint_range(-0.5, 0.5) = 0.0;
uniform float world_time = 0.0;


// =========================================================================
// 【昼夜 / TOD（Time-Of-Day）组】
// =========================================================================
// ─── 任务 2/3：昼夜循环（1 个游戏季 = 1 次完整昼夜） ─────────────────────
// 由 WorldClock.day_phase_changed → HexRenderer.set_day_phase 推入；默认逐帧更新，
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform bool day_night_enabled = true;
// 夜晚整体亮度压到白天的 [min, max]；默认 0.35~0.55（需求 3.4）
uniform float night_brightness_min : hint_range(0.0, 1.0) = 0.35;
uniform float night_brightness_max : hint_range(0.0, 1.0) = 0.55;

// ─── Pass 2（任务 2）：TOD 全局光照 uniform（单一数据源） ───────────────
// 由 TODProfile 经 HexRenderer.apply_tod 推入。禁止在 shader 内自行从 day_phase
// tod_sun_dir：切线空间下的入射光方向（已归一化，z 为固定高度分量）
uniform vec3  tod_sun_dir       = vec3(0.4, -0.7, 0.6);
uniform vec3  tod_sun_color     : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3  tod_ambient_color : source_color = vec3(0.65, 0.68, 0.75);
// night_factor ∈ [0, 1]，0=白天 1=夜晚；供地表/水体/粒子做一致的夜晚染色
uniform float tod_night_factor  : hint_range(0.0, 1.0) = 0.0;
// tod_exposure：最终 tonemap 前的曝光倍率（艺术化调节用）
uniform float tod_exposure      : hint_range(0.2, 2.5) = 1.0;

// ─── Pass 2 新增开关（任务 4/6） ─────────────────────────────────────────
// cloud_tod_tint_enabled：只给云阴影用；云本体渲染在 weather_overlay.gdshader。
uniform bool water_sparkle_enabled = true;
uniform bool cloud_tod_tint_enabled = true;


// =========================================================================
// 【水体子系统组】
// =========================================================================
// ─── Water Visual Overhaul（本轮）：水体子特性独立开关与参数 ────────────
// 这组开关对应 requirements.md 的需求 1/2/4/5 的细分子系统，保证"大一键关"
// （water_effect_enabled=false）之外，还能逐个切换每个效果。
// 统一波浪高度场（需求 1）
// 菲涅尔天空反射（需求 2）
// 河流流动条纹（需求 4）
// 珊瑚礁焦散（需求 5.1）
// 浅海/浅湖透底（需求 5.3/5.4）
uniform bool  water_waves_enabled            = true;
uniform bool  water_fresnel_enabled          = true;
uniform bool  river_flow_enabled             = true;
uniform bool  caustics_enabled               = true;
uniform bool  shallow_transparency_enabled   = true;
uniform float water_gloss                    : hint_range(4.0, 128.0) = 34.0;
uniform float water_reflection_strength      : hint_range(0.0, 1.0) = 0.32;
uniform float river_flow_speed               : hint_range(0.0, 4.0) = 0.75;
uniform float river_flow_freq                : hint_range(0.02, 1.0) = 0.16;
uniform float caustics_strength              : hint_range(0.0, 1.0) = 0.32;
uniform float deep_ocean_contrast            : hint_range(0.5, 3.0) = 0.96;
uniform vec3  lake_water_color : source_color = vec3(0.20, 0.48, 0.56);
uniform float shallow_transparency_factor    : hint_range(0.0, 1.0) = 0.56;
uniform float water_cartoon_color_strength   : hint_range(0.0, 1.0) = 0.75;
uniform float water_transition_softness      : hint_range(0.0, 1.0) = 1.0;
uniform float estuary_plume_strength         : hint_range(0.0, 1.0) = 0.65;

// ShaderToy 启发的两层视觉增强（参考 3tyBRh "2D Stylized Water" 与 dtKcWz
// "2D Ocean Waves"）：
//  - water_domain_warp_strength：在水色采样前把世界坐标做一次 fbm 扭曲，
//    让 "湖/海/礁/藻" 的交界不再是规整直线，而是像水被搅散一样的 wavy edge。
//  - water_wave_line_strength：原为"横向波痕条纹"总强度；本轮（Water Calm
//    防止水面重新出现高对比密集纹理）。字段名保留是为了不破坏既有 .tscn 序列化。
uniform float water_domain_warp_strength : hint_range(0.0, 4.0) = 1.45;
uniform float water_wave_line_strength   : hint_range(0.0, 1.0) = 0.70;
// ─── Water Calm Noise（本轮）：低对比度柔和噪声的两个细分强度 ───────────
// water_calm_noise_brightness  : 亮度扰动层（大尺度 fbm，默认约 ±5%）的强度系数
// water_calm_noise_tint_strength: 色相扰动层（更低频 fbm 在冷/暖 tint 之间
//                                 mix，默认约 ±2%）的强度系数
uniform float water_calm_noise_brightness    : hint_range(0.0, 1.0) = 0.95;
uniform float water_calm_noise_tint_strength : hint_range(0.0, 1.0) = 0.95;
// biome 软混合半径（世界坐标单位，越大过渡带越宽；0 = 关闭软混合，回退到硬切）
uniform float water_biome_blend_radius   : hint_range(0.0, 4.0) = 3.15;


// =========================================================================
// 【视觉总开关组】
// =========================================================================
// ─── 任务 1：视觉总开关（shader 侧占位；具体分支在后续任务接入） ─────────
// 声明为 uniform 是为了让 CPU 侧 set_shader_parameter 永远有效，避免写入一个
uniform int visual_quality : hint_range(0, 2) = 2;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform bool extreme_weather_ground_effect_enabled = true;


// =========================================================================
// 【insolation / 季节温度组】
// =========================================================================
// 季节温度振幅。2026-05-19 Plan-C：默认 0.20 → 0.32（与 climate_profile.gd
// season_temp_amp / hex_renderer.gd 同步）。让中高纬地块在年度循环中真正
// 穿过雪线带 [0.30, 0.48]。运行时由 hex_renderer.set_shader_parameter 推送，
// 此默认值仅在 shader 单独编译/调试时生效。
uniform float season_temp_amp : hint_range(0.0, 0.4) = 0.32;
// ─── True Insolation-Driven Climate（Phase F）: CPU/GPU 同源参数 ──────
// 主开关 — 关闭时回退到 legacy hemi_phase + 余弦路径。
uniform bool true_insolation_enabled = true;
// 黄赤交角（弧度），23.5° ≈ 0.4101523
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
// 连续日长项幅度
uniform float insolation_daylen_amp : hint_range(0.0, 1.0) = 0.35;
// 把 (insol_now - insol_mean) 映射回温度偏移的增益
uniform float insolation_season_gain : hint_range(0.0, 2.0) = 1.0;


// =========================================================================
// 【植被 / 雪 / 洋流 / 风组】
// =========================================================================
// 植被换色总开关与强度
uniform float vegetation_season_strength : hint_range(0.0, 1.0) = 0.85;
// 动态雪量（季节性雪盖叠加在 biome SNOW 之外）总开关与强度
uniform float dynamic_snow_strength : hint_range(0.0, 1.0) = 0.85;
// 调试用：true 时雪盖跳过 fbm cosmetic 抖动，直接拿 dyn_snow 上屏，
// 用于验证 CPU→atlas→shader 链路是否健康（屏幕值应 ≈ info_panel.snow_cover）。
uniform bool debug_force_dyn_snow_only = false;
// 洋流动画总开关与强度
uniform float ocean_current_strength : hint_range(0.0, 1.0) = 0.88;


// =========================================================================
// 【深海色彩层次组】
// =========================================================================
// ─── Deep Ocean Layered Color（深海色彩层次感） ─────────────────────────
// 总开关振幅。0 = 完全还原旧视觉；1 = 子层按各自默认振幅全量生效。
uniform float deep_ocean_color_richness         : hint_range(0.0, 1.0) = 0.85;
// 洋流冷/暖色偏：暖流（低纬→高纬）偏微暖，寒流（高纬→低纬）偏冷青。
uniform float deep_ocean_current_tint_strength  : hint_range(0.0, 1.0) = 0.60;
// 纬度/温度驱动色温带：热带翠绿—温带中性—极地冷青。
uniform float deep_ocean_latitude_tint_strength : hint_range(0.0, 1.0) = 0.85;
// 深渊幽冷：深海最深段加压暗与微蓝紫偏移，强化质感。
uniform float deep_ocean_abyss_tint_strength    : hint_range(0.0, 1.0) = 0.60;
// 海盆 gyre 色斑增强：放大半封闭海 vs 开阔腹地的色相差。
uniform float deep_ocean_patch_boost            : hint_range(0.0, 1.0) = 0.50;


// =========================================================================
// 【洋流可视化组】
// =========================================================================
// ─── 任务 9：洋流可视化 toggle ──────────────────────────────────────────
// ocean_current_debug：0 = 正常渲染（低对比流纹）；1 = 调试模式（高对比带箭头感流向）。
uniform bool  ocean_current_debug = false;
// Systemic Ocean Currents：独立 L8 纹理，编码 per-pixel 上升流强度（0=下沉 / 128=中性 / 255=上升）。
// 主路径不采样；仅 ocean_current_debug 开启时作为彩色覆盖叠加。
uniform sampler2D ocean_upwelling_tex : source_color, filter_linear, repeat_disable;


// =========================================================================
// 【植被轴 / 覆盖物轴 / 生态可视化组】
// =========================================================================
uniform float vegetation_axis_strength : hint_range(0.0, 1.0) = 0.35;
uniform float cover_axis_strength : hint_range(0.0, 1.0) = 0.65;
uniform float ecology_visual_strength : hint_range(0.0, 1.0) = 0.70;
uniform float snowline_visual_strength : hint_range(0.0, 1.0) = 0.85;
uniform float foliage_density_strength : hint_range(0.0, 1.0) = 0.75;
uniform int ecology_visual_quality : hint_range(0, 2) = 2;


// =========================================================================
// 【季节过渡 dissolve 组】
// =========================================================================
// Seasonal terrain transition overlay. Main terrain stays opaque; the temporary
// old-terrain layer dissolves out over early-season progress to avoid hard cuts.
uniform bool season_transition_overlay = false;
uniform float season_transition_progress : hint_range(0.0, 1.0) = 1.0;
uniform float season_transition_softness : hint_range(0.02, 0.45) = 0.18;


// =========================================================================
// 【天气锋面组】
// =========================================================================
// ─── Milestone 3：天气子系统（最多 MAX_WEATHER_FRONTS 个活跃锋面） ──────
//   weather_front_centers[i] = (center.x, center.y, radius, intensity ∈ [0,1])
//   weather_front_types[i]   = WeatherType.WT id（< 0 表示该 slot 空，shader 跳过）
//   weather_front_count      = 实际活跃数（≤ MAX_WEATHER_FRONTS）
// fragment 端循环遍历，对每个 front 算高斯覆盖 → max-merge 取最强 → 按类型叠加 overlay。
// CPU 兼容铁律：MAX_WEATHER_FRONTS 不可改（weather_layer.gd / weather_system 按此填充）。
const int MAX_WEATHER_FRONTS = 16;
uniform vec4 weather_front_centers[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_shapes[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_visuals[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int weather_front_count = 0;



// =========================================================================
// 【地形 Hypsometric 色阶组】
// =========================================================================
// ─── Hypsometric 色阶（海陆双向，等高线设色） ────────────────────────────
// Open Ocean Color Rebalance v2：在 v1 基础上进一步收敛深/浅海亮度差。
// 旧版 V 区间 0.30~0.66 (Δ=0.36) 在截图上观感是"浅海发亮、深海近黑"，
// 现把 V 收敛到 0.34~0.56 (Δ=0.22)，对比柔化 ~39%，仍保持单调递增。
// 旧值 (v1) / 新值 (v2) / 视觉影响：
//   deep_ocean   (0.10, 0.18, 0.30) → (0.14, 0.22, 0.34)   深海抬亮，少几分黑洞感
//   mid_ocean    (0.16, 0.28, 0.40) → (0.20, 0.30, 0.42)   中海域过渡更连续
//   color_shallow(0.27, 0.45, 0.56) → (0.28, 0.42, 0.52)   浅海略压暗
//   coast_water  (0.40, 0.62, 0.66) → (0.34, 0.50, 0.56)   海岸不再过亮、贴近浅海
uniform vec3 color_deep_ocean   : source_color = vec3(0.14, 0.22, 0.34);
uniform vec3 color_mid_ocean    : source_color = vec3(0.20, 0.30, 0.42);
uniform vec3 color_shallow      : source_color = vec3(0.28, 0.42, 0.52);
uniform vec3 color_coast_water  : source_color = vec3(0.34, 0.50, 0.56);
uniform vec3 color_beach        : source_color = vec3(0.85, 0.78, 0.55);
uniform vec3 color_lowland      : source_color = vec3(0.62, 0.68, 0.42);
uniform vec3 color_hill         : source_color = vec3(0.66, 0.55, 0.32);
uniform vec3 color_mountain     : source_color = vec3(0.45, 0.38, 0.34);
uniform vec3 color_peak         : source_color = vec3(0.55, 0.50, 0.46);
uniform vec3 color_snow         : source_color = vec3(0.96, 0.96, 0.96);


// =========================================================================
// 【Hillshading 组】
// =========================================================================
// ─── 极端天气地表反馈（仅保留 BLIZZARD 雪/薄冰；裂地与热浪/干旱调色已删除）────
// ─── 双光源 hillshading ──────────────────────────────────────────────────

uniform float hillshade_strength : hint_range(0.0, 1.0) = 0.45;
uniform float hillshade_slope_gain : hint_range(0.5, 24.0) = 8.0;
uniform vec2  hillshade_dir      = vec2(-0.55, -0.55);
uniform vec2  hillshade_fill_dir = vec2( 0.60,  0.40);


// =========================================================================
// 【河流组】
// =========================================================================
// ─── 河流（从 flow accumulation） ───────────────────────────────────────
uniform float river_strength       : hint_range(0.0, 1.0) = 0.85;
uniform float river_threshold_low  : hint_range(0.0, 1.0) = 0.55;
uniform float river_threshold_high : hint_range(0.0, 1.0) = 0.85;
uniform vec3  river_color          : source_color = vec3(0.30, 0.50, 0.68);
uniform vec3  river_outline_color  : source_color = vec3(0.16, 0.30, 0.45);


// =========================================================================
// 【等高线 / 海岸光晕 / 羊皮纸组】
// =========================================================================
// ─── 可选等高线 ──────────────────────────────────────────────────────────
uniform bool  contour_enabled = false;
uniform float contour_step       : hint_range(0.01, 0.20) = 0.05;
uniform float contour_strength   : hint_range(0.0, 0.40) = 0.18;
uniform vec3  contour_color      : source_color = vec3(0.20, 0.16, 0.10);

// ─── 海岸光晕 ─────────────────────────────────────────────────────────────
uniform vec3  coast_halo_color    : source_color = vec3(0.78, 0.86, 0.88);
uniform float coast_halo_strength : hint_range(0.0, 1.0) = 0.22;

// ─── 羊皮纸 ───────────────────────────────────────────────────────────────
uniform vec3  parchment_tint        : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength    : hint_range(0.0, 0.4) = 0.10;
uniform float paper_grain_strength  : hint_range(0.0, 0.2) = 0.05;


// =========================================================================
// 【Biome / Vegetation / Cover / Weather ID 常量组】
// =========================================================================
// CPU 兼容铁律：以下常量名与数值必须与 scripts/terrain_type.gd、
// scripts/vegetation_type.gd、scripts/cover_type.gd、scripts/weather_type.gd
// 的 enum 顺序与值严格一致；改一处必须改另一处。
//
// TerrainType.TERRAIN id
const int B_OCEAN     = 0;
const int B_COAST     = 1;
const int B_PLAIN     = 2;
const int B_GRASSLAND = 3;
const int B_FOREST    = 4;
const int B_HILL      = 5;
const int B_MOUNTAIN  = 6;
const int B_DESERT    = 7;
const int B_TUNDRA    = 8;
const int B_SNOW      = 9;
const int B_SWAMP     = 10;
const int B_JUNGLE    = 11;
const int B_SAVANNA   = 12;
const int B_TAIGA     = 13;
const int B_STEPPE    = 14;
const int B_SHRUBLAND = 15;
const int B_MANGROVE  = 16;
const int B_GLACIER   = 17;
const int B_LAKE      = 18;
const int B_REEF      = 19;
const int B_SEA_ICE   = 20;
const int B_KELP      = 21;
const int B_DELTA     = 22;
const int B_OASIS     = 23;
const int B_SALT_FLAT = 24;
const int B_BADLANDS  = 25;

// ─── Milestone 2：VegetationType.VEG id ──────────────────────────────────
// 与 scripts/vegetation_type.gd 严格按 enum 顺序对齐，shader 端按 id 直接 if-else 派色。
const int V_NONE                = 0;
const int V_POLAR_DESERT        = 1;
const int V_TUNDRA              = 2;
const int V_ALPINE_TUNDRA       = 3;
const int V_ALPINE_MEADOW       = 4;
const int V_TAIGA               = 5;
const int V_BOREAL_SHRUB        = 6;
const int V_TEMPERATE_DECIDUOUS = 7;
const int V_TEMPERATE_CONIFER   = 8;
const int V_TEMPERATE_GRASSLAND = 9;
const int V_TEMPERATE_STEPPE    = 10;
const int V_MEDITERRANEAN_SHRUB = 11;
const int V_SUBTROPICAL_FOREST  = 12;
const int V_SAVANNA             = 13;
const int V_TROPICAL_RAINFOREST = 14;
const int V_TROPICAL_DRY_FOREST = 15;
const int V_DESERT_SCRUB        = 16;
const int V_XERIC_DESERT        = 17;
const int V_OASIS_VEG           = 18;
const int V_MANGROVE            = 19;
const int V_SWAMP               = 20;
const int V_MARSH               = 21;
const int V_KELP_FOREST         = 22;
const int V_CORAL_REEF          = 23;
const int V_COUNT               = 24;

// ─── Milestone 2：CoverType.CV id ────────────────────────
const int CV_NONE       = 0;
const int CV_SNOW       = 1;
const int CV_GLACIER    = 2;
const int CV_SEA_ICE    = 3;
const int CV_PERMAFROST = 4;
const int CV_FLOODING   = 5;
// Systemic Ocean Currents：远洋华（浮游生物繁殖）
const int CV_PELAGIC_BLOOM = 6;
// ─── Milestone 3：WeatherType.WT id ──────────────────────────────────────
const int WT_CLEAR    = 0;
// 与 scripts/weather_type.gd 严格按 enum 数值对齐；4(DROUGHT)/6(HEATWAVE) 的地表调色已删除。
const int WT_RAIN     = 1;
const int WT_STORM    = 2;
const int WT_BLIZZARD = 3;
const int WT_FOG      = 5;


// =========================================================================
// 【植被四季 LUT 组（依赖 V_COUNT 常量必须先声明）】
// =========================================================================
// ─── map-visual-overhaul-v1：植被四季换色 LUT ─────────────────────────
// 24 个植被类型 × 4 季（春/夏/秋/冬）× 4 通道（rgb 叠乘色 + 保留 a）。
// 由 hex_renderer._push_vegetation_season_lut() 在 setup 时 push 一次，运行时不刷新。
// shader 端按当前像素半球的 season_phase ∈ [0,4) 做 4 段 cubic mix，南北半球反相。
// climate_anomaly 叠加：vegetation_anomaly_shift[veg] * climate_anomaly。
// 96 个 vec4 占 1.5 KiB uniform buffer，远低于 Godot 默认 16 KiB UBO 上限。
uniform vec4 vegetation_season_lut[V_COUNT * 4];     // [veg*4 + season]
uniform vec4 vegetation_anomaly_shift[V_COUNT];      // 每种植被一个 climate_anomaly 叠加色


// =========================================================================
// 【varying（vertex → fragment）】
// =========================================================================
varying vec2 v_world;
