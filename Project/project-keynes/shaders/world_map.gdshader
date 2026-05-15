shader_type canvas_item;
render_mode blend_mix;

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
//                     A = 0（保留；Daily Sim SoA Refactor 阶段 1 起原 sea_ice 已拆到独立 sea_ice_tex）
//   vector_atlas     (RGBA8, derived_size, LINEAR)
//                     RG = ocean_current (-1..1 mapped from 0..1)
//                     BA = wind_field    (-1..1 mapped from 0..1)
//   volcano_field_tex (R8, derived_size, LINEAR)
//                     R = 火山强度场（原 scalar_atlas.a）
//   sea_ice_tex      (R8, derived_size, LINEAR)
//                     R = sea_ice_fraction ∈ [0, 1]  （连续海冰覆盖率，
//                                                   由 SeaIceAtlasUploadJob 每 stride 日上传一次）
//
// 不再有 hex 逻辑、不再做 domain warp。整张地图就是这 4 张连续纹理的合成。
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D enum_atlas   : filter_nearest, repeat_disable;
uniform sampler2D scalar_atlas : filter_linear,  repeat_disable;
uniform sampler2D vector_atlas : filter_linear,  repeat_disable;
// 火山强度场独立 R8（原 scalar_atlas.a，已让位给 sea_ice_fraction）
uniform sampler2D volcano_field_tex : filter_linear, repeat_disable;
// Daily Sim SoA Refactor 阶段 1：海冰覆盖率独立 R8（原 scalar_atlas.a）。
// 每 stride 日由 SeaIceAtlasUploadJob 上传一次；bake_world 后初始为全 0。
uniform sampler2D sea_ice_tex : filter_linear, repeat_disable;
// v9.fbm-opt：共享 noise 贴图（256×256 R8 tileable，由 MapBaker 烘焙）。
// value_noise(p) 改用 texture(noise_tex, p / NOISE_TEX_SCALE).r 实现，
// 单 octave 从"4× hash21 + smoothstep mix"降为 1 次 bilinear fetch（GPU 硬件加速）。
uniform sampler2D noise_tex    : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform vec2 derived_resolution = vec2(1024.0, 768.0);

uniform float sea_level : hint_range(0.0, 1.0) = 0.42;

// ─── Phase 1：季节相位 + 气候异常（每帧由 WorldClock 驱动） ───────────────
// season_phase ∈ [0, 4)：0=春 1=夏 2=秋 3=冬
// climate_anomaly ∈ [-0.2, +0.2]：长期气温偏移
// world_time：累积秒数，给海洋洋流流纹动画用（Phase 3）
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float climate_anomaly : hint_range(-0.5, 0.5) = 0.0;
uniform float world_time = 0.0;

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

// ─── 任务 1：视觉总开关（shader 侧占位；具体分支在后续任务接入） ─────────
// 声明为 uniform 是为了让 CPU 侧 set_shader_parameter 永远有效，避免写入一个
uniform int visual_quality : hint_range(0, 2) = 2;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform bool extreme_weather_ground_effect_enabled = true;

// 季节温度振幅。0.20 = 夏冬之间 ±20% 温度差，比较显著但不夸张
uniform float season_temp_amp : hint_range(0.0, 0.4) = 0.20;
// ─── True Insolation-Driven Climate（Phase F）: CPU/GPU 同源参数 ──────
// 主开关 — 关闭时回退到 legacy hemi_phase + 余弦路径。
uniform bool true_insolation_enabled = true;
// 黄赤交角（弧度），23.5° ≈ 0.4101523
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
// 连续日长项幅度
uniform float insolation_daylen_amp : hint_range(0.0, 1.0) = 0.35;
// 把 (insol_now - insol_mean) 映射回温度偏移的增益
uniform float insolation_season_gain : hint_range(0.0, 2.0) = 1.0;
// 植被换色总开关与强度
uniform float vegetation_season_strength : hint_range(0.0, 1.0) = 0.85;
// 动态雪量（季节性雪盖叠加在 biome SNOW 之外）总开关与强度
uniform float dynamic_snow_strength : hint_range(0.0, 1.0) = 0.85;
// 洋流动画总开关与强度
uniform float ocean_current_strength : hint_range(0.0, 1.0) = 0.88;

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
// Phase 6：陆地风迹噪声（沿盛行风方向的轻微条纹，让风带可视化）
uniform float wind_streak_strength : hint_range(0.0, 0.20) = 0.05;

// ─── 任务 9：洋流/风带可视化 toggle ──────────────────────────────────────
// ocean_current_debug：0 = 正常渲染（低对比流纹）；1 = 调试模式（高对比带箭头感流向）。
uniform bool  ocean_current_debug = false;
// Systemic Ocean Currents：独立 L8 纹理，编码 per-pixel 上升流强度（0=下沉 / 128=中性 / 255=上升）。
// 主路径不采样；仅 ocean_current_debug 开启时作为彩色覆盖叠加。
uniform sampler2D ocean_upwelling_tex : source_color, filter_linear, repeat_disable;
// 季风陆地风纹增强倍率：在 MONSOON type 锋面覆盖区域，陆地的 wind_streak
// 振幅 ×monsoon_wind_streak_boost（默认 3.0），将非主观风感提升为主体特征。
uniform float monsoon_wind_streak_boost : hint_range(1.0, 6.0) = 3.0;
uniform float vegetation_axis_strength : hint_range(0.0, 1.0) = 0.35;
uniform float cover_axis_strength : hint_range(0.0, 1.0) = 0.65;
// Seasonal terrain transition overlay. Main terrain stays opaque; the temporary
// old-terrain layer dissolves out over early-season progress to avoid hard cuts.
uniform bool season_transition_overlay = false;
uniform float season_transition_progress : hint_range(0.0, 1.0) = 1.0;
uniform float season_transition_softness : hint_range(0.02, 0.45) = 0.18;

// ─── Milestone 3：天气子系统（最多 MAX_WEATHER_FRONTS 个活跃锋面） ──────
//   weather_front_centers[i] = (center.x, center.y, radius, intensity ∈ [0,1])
//   weather_front_types[i]   = WeatherType.WT id（< 0 表示该 slot 空，shader 跳过）
//   weather_front_count      = 实际活跃数（≤ MAX_WEATHER_FRONTS）
// fragment 端循环遍历，对每个 front 算高斯覆盖 → max-merge 取最强 → 按类型叠加 overlay。
const int MAX_WEATHER_FRONTS = 16;
uniform vec4 weather_front_centers[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_shapes[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_visuals[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int weather_front_count = 0;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;

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

// ─── 任务 6：极端天气地表反馈（积雪 / 裂地）──────────────────────────────
// compute_extreme_weather_mask() 依赖 fbm()，而 fbm 定义在本文件后段。
// ─── 双光源 hillshading ──────────────────────────────────────────────────
uniform float hillshade_strength : hint_range(0.0, 1.0) = 0.45;
uniform float hillshade_slope_gain : hint_range(0.5, 24.0) = 8.0;
uniform vec2  hillshade_dir      = vec2(-0.55, -0.55);
uniform vec2  hillshade_fill_dir = vec2( 0.60,  0.40);

// ─── 河流（从 flow accumulation） ───────────────────────────────────────
uniform float river_strength       : hint_range(0.0, 1.0) = 0.85;
uniform float river_threshold_low  : hint_range(0.0, 1.0) = 0.55;
uniform float river_threshold_high : hint_range(0.0, 1.0) = 0.85;
uniform vec3  river_color          : source_color = vec3(0.30, 0.50, 0.68);
uniform vec3  river_outline_color  : source_color = vec3(0.16, 0.30, 0.45);

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
// 与 scripts/weather_type.gd 严格按 enum 顺序对齐。
const int WT_RAIN     = 1;
const int WT_STORM    = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT  = 4;
const int WT_FOG      = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON  = 7;

varying vec2 v_world;

// ───  ─────────────────────────────────────────────────────────────────
// hash21 / value_noise / fbm / voronoi_cell 已抽至 common_noise.gdshaderinc。
#include "res://shaders/include/common_noise.gdshaderinc"

vec2 weather_front_axis(vec4 shape) {
	vec2 ax = shape.xy;
	if (dot(ax, ax) <= 0.0001) {
		return vec2(1.0, 0.0);
	}
	return normalize(ax);
}

float weather_front_ellipse_distance(vec2 wp, vec2 center, float radius, vec4 shape) {
	vec2 ax = weather_front_axis(shape);
	vec2 ay = vec2(-ax.y, ax.x);
	vec2 local = wp - center;
	float major = max(radius * max(shape.z, 0.05), 0.001);
	float minor = max(radius * max(shape.w, 0.05), 0.001);
	return length(vec2(dot(local, ax) / major, dot(local, ay) / minor));
}

float weather_front_gaussian_coverage(vec2 wp, vec4 center_data, vec4 shape) {
	float radius = center_data.z;
	if (radius < 0.001) {
		return 0.0;
	}
	float ed = weather_front_ellipse_distance(wp, center_data.xy, radius, shape);
	if (ed > 1.6) {
		return 0.0;
	}
	float k = ed / 0.5;
	return clamp(center_data.w * exp(-0.5 * k * k), 0.0, center_data.w);
}

float compute_extreme_weather_mask(vec2 wp, int type_id) {
	float best = 0.0;
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;
		int wt_i = int(wt_f + 0.5);
		if (wt_i != type_id) continue;
		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float radius = c.z;
		if (radius < 0.001) continue;
		float ed = weather_front_ellipse_distance(wp, c.xy, radius, shape);
		float spread = mix(1.0, 1.20, visual.z);
		float d = ed / spread;
		if (d > 1.65) continue;
		float radial = 1.0 - smoothstep(0.60, 1.34 + visual.z * 0.18, d);
		float freq = (type_id == WT_BLIZZARD) ? 0.020 : 0.034;
		vec2 offset = (type_id == WT_BLIZZARD) ? vec2(13.0, -7.0) : vec2(-29.0, 41.0);
		float n = fbm((wp + offset) * freq, 2);
		float visual_amount = (type_id == WT_BLIZZARD) ? max(visual.y, visual.x * 0.72) : max(visual.x, c.w);
		float threshold = mix(0.48, 0.22, clamp(visual_amount, 0.0, 1.0)) + visual.z * 0.10;
		float density = smoothstep(threshold, threshold + 0.24, n);
		float mask = radial * mix(0.62, 1.0, density) * clamp(visual_amount, 0.0, 1.0);
		best = max(best, mask);
	}
	return best;
}

// ─── 高度解码（RG8 16-bit） ──────────────────────────────────────────────

float decode_height_rg8(vec2 uv) {
	vec4 s = texture(height_tex, uv);
	return (s.r * 256.0 + s.g) / 257.0;
}

// ─── 等高线设色（hypsometric tint） ───────────────────────────────────────
// 注意：用 is_water (biome 决定) 而不是 elev 来分支海陆，否则会因为 height_tex
// 的 barycentric 平滑插值在 hex 边界处把"水 hex 但 elev 偶尔越过 sea_level"
// 的像素画成陆地——结果就是海岸完全脱离 hex 形状，永远平滑曲线。
vec3 water_depth_gradient(float offshore_t, float elev) {
	float offshore_s = smoothstep(0.00, 1.00, clamp(offshore_t, 0.0, 1.0));
	float near_surface = smoothstep(0.08, 1.00, clamp(elev / max(sea_level, 0.001), 0.0, 1.0));
	float contrast_t = clamp((deep_ocean_contrast - 0.5) / 2.5, 0.0, 1.0);

	// Cartoon water palette: overlapping wide ramps, not isolated depth bands.
	// Coast -> turquoise shelf -> teal sea -> cobalt basin -> soft indigo abyss.
	float shelf_t = smoothstep(0.05, 0.46, offshore_s);
	float mid_t = smoothstep(0.28, 0.78, offshore_s);
	float basin_t = smoothstep(0.56, 1.00, offshore_s);
	float abyss_t = smoothstep(0.76, 1.00, offshore_s);

	// Open Ocean Color Rebalance：把以下五个色阶的乘法系数往 vec3(1.0) 收敛，
	// 去掉"加蓝压红"的塑料感。新基础调色板已自带合理冷暖差，无需再用大幅倍率。
	// 旧值 / 新值 / 视觉影响：
	//   coast_col  *(0.96,1.06,1.08) → *(1.00,1.04,1.04)  浅海保留蓝，但不再额外加蓝
	//   shelf_col  *(0.82,1.16,1.18) → *(0.96,1.06,1.06)  陆架不再被推成纯青蓝
	//   mid_col    *(0.88,1.05,1.18) → *(0.96,1.02,1.06)  中海域去过饱和
	//   basin_tint mix(0.76,0.96,1.22)..(0.70,0.92,1.30) → mix(0.92,1.00,1.10)..(0.88,0.98,1.14)
	//   abyss_warm *(0.86,0.98,1.24) → *(0.94,0.98,1.10)
	//   abyss_cool mix(0.58,0.72,1.08)..(0.46,0.60,1.18) → mix(0.78,0.86,1.06)..(0.72,0.82,1.10)
	vec3 coast_col = mix(color_shallow, color_coast_water, 0.88) * vec3(1.00, 1.04, 1.04);
	vec3 shelf_col = mix(color_coast_water, color_mid_ocean, 0.24) * vec3(0.96, 1.06, 1.06);
	vec3 mid_col = mix(color_mid_ocean, color_deep_ocean, 0.18) * vec3(0.96, 1.02, 1.06);
	// Deep Ocean Layered Color: widen hue/sat span between basin and abyss so
	// the deepest tiers read as "warm cobalt blue → cool indigo/violet" rather
	// than a flat monochrome navy. basin pushes slightly warmer/bluer, abyss
	// leans cooler with a violet bias.
	float richness_t = clamp(deep_ocean_color_richness, 0.0, 1.0);
	vec3 basin_tint = mix(vec3(0.92, 1.00, 1.10), vec3(0.88, 0.98, 1.14), richness_t);
	vec3 basin_col = mix(color_mid_ocean, color_deep_ocean, 0.50) * basin_tint;
	vec3 abyss_warm = color_deep_ocean * vec3(0.94, 0.98, 1.10);
	vec3 abyss_cool = color_deep_ocean * mix(vec3(0.78, 0.86, 1.06), vec3(0.72, 0.82, 1.10), richness_t);
	vec3 abyss_col = mix(abyss_warm, abyss_cool, contrast_t);

	vec3 ocean_col = coast_col;
	ocean_col = mix(ocean_col, shelf_col, shelf_t * 0.92);
	ocean_col = mix(ocean_col, mid_col, mid_t * 0.78);
	ocean_col = mix(ocean_col, basin_col, basin_t * 0.68);
	ocean_col = mix(ocean_col, abyss_col, abyss_t * 0.58);

	// Broad deep-water chroma drift keeps large oceans layered while staying calm.
	// Open Ocean Color Rebalance：blue_shift/violet_shift 整体压幅，避免 basin/abyss
	// 被乘法叠加再次推成纯蓝。旧 0.20 / 0.12 → 新 0.12 / 0.07。
	vec3 blue_shift = mix(vec3(0.98, 1.01, 1.06), vec3(0.90, 0.96, 1.12), basin_t);
	vec3 violet_shift = mix(vec3(1.0), vec3(0.94, 0.92, 1.10), abyss_t);
	ocean_col *= mix(vec3(1.0), blue_shift, 0.12 * smoothstep(0.26, 1.0, offshore_s));
	ocean_col *= mix(vec3(1.0), violet_shift, 0.07 * abyss_t);

	vec3 shallow_lift = mix(shelf_col, coast_col, near_surface);
	vec3 result = mix(ocean_col, shallow_lift, (1.0 - smoothstep(0.12, 0.42, offshore_s)) * near_surface * 0.36);

	// Safety band: gently pull extreme results back toward the deep-ocean base
	// so newly-widened palette never drifts into a cartoony alien hue. Scales
	// with richness_t so richness==0 is a no-op (旧视觉完全保留).
	float pullback = 0.15 * richness_t * smoothstep(0.40, 1.0, offshore_s);
	result = mix(result, color_deep_ocean, pullback);
	return result;
}

// ─── Deep Ocean Layered Color 辅助函数 ──────────────────────────────────
// Current tint: warm/cool bias along ocean currents. UV.y points "down" while
// lat_signed is already oriented (north positive). A current flowing from low
// to high |latitude| (warm current) biases toward warm aqua; the reverse
// (cold current) biases toward cool cyan. Zero flow → identity.
vec3 deep_ocean_current_tint(vec2 oc, float lat_signed, float flow_mag) {
	if (!ocean_current_enabled) {
		return vec3(1.0);
	}
	if (flow_mag < 0.05) {
		return vec3(1.0);
	}
	// In Godot UV space y grows downward. North (lat_signed > 0) corresponds
	// to decreasing UV.y, hence a current whose UV.y component moves *against*
	// the hemisphere sign is heading poleward (warm current). The product
	// (-oc.y * lat_signed) captures this: positive → warm, negative → cold.
	float dir = clamp(-oc.y * lat_signed * 4.0, -1.0, 1.0);
	// Open Ocean Color Rebalance：暖/寒流 ±6% 的方向系数与新去饱和 base palette
	// 协同——在 strength 0.60 + cap 0.85 之下总幅度约 ±5%，flow_mag>0.2 区域仍
	// 落在需求饱和度区间 [0.40, 0.62] 内，无需调整 warm/cold 数值。
	vec3 warm = vec3(1.04, 1.02, 0.94);
	vec3 cold = vec3(0.94, 1.00, 1.08);
	vec3 tint = mix(vec3(1.0), (dir >= 0.0) ? warm : cold, abs(dir));
	float amp = clamp(deep_ocean_current_tint_strength * deep_ocean_color_richness, 0.0, 1.0);
	// Also scale by actual flow magnitude so weak eddies don't get loud tints.
	amp *= smoothstep(0.05, 0.45, flow_mag);
	// Cap overall excursion at ~±15%.
	return mix(vec3(1.0), tint, amp * 0.85);
}

// Latitude tint: tropical teal-green, temperate neutral, polar cool-cyan.
// current_temp (in [~0, ~1]) nudges the result slightly warmer when high so
// seasonal swings bleed into ocean color naturally.
vec3 deep_ocean_latitude_tint(float lat_signed, float current_temp) {
	float abs_lat = clamp(abs(lat_signed), 0.0, 1.0);
	float tropical_w = 1.0 - smoothstep(0.00, 0.35, abs_lat);
	float polar_w    = smoothstep(0.55, 0.95, abs_lat);
	// Open Ocean Color Rebalance：扩大热带 / 极地色相分离，让低纬偏青绿、
	// 高纬偏冷青在新去饱和 base 上仍达成 Δhue ≥ 8°。
	// 旧值 / 新值 / 视觉影响：
	//   tropical (0.92, 1.08, 1.04) → (0.88, 1.10, 1.00)  低纬更明显偏青绿
	//   polar    (0.96, 1.02, 1.12) → (0.96, 1.00, 1.16)  高纬更明显偏冷青
	vec3 tropical = vec3(0.88, 1.10, 1.00);
	vec3 polar    = vec3(0.96, 1.00, 1.16);
	vec3 tint = mix(vec3(1.0), tropical, tropical_w);
	tint = mix(tint, polar, polar_w);
	// Temperature second-order nudge: warmer → slightly warmer tint (up to ±3%).
	float temp_bias = clamp(current_temp - 0.5, -0.5, 0.5);
	vec3 temp_tint = vec3(1.0 + temp_bias * 0.06, 1.0, 1.0 - temp_bias * 0.06);
	tint *= temp_tint;
	float amp = clamp(deep_ocean_latitude_tint_strength * deep_ocean_color_richness, 0.0, 1.0);
	return mix(vec3(1.0), tint, amp);
}

// Abyss tint: darken + subtle blue/violet bias on the deepest water.
vec3 deep_ocean_abyss_tint(float offshore_depth) {
	float abyss_w = smoothstep(0.72, 1.00, clamp(offshore_depth, 0.0, 1.0));
	// Open Ocean Color Rebalance：把外层 *0.90 抬到 *0.96，避免 abyss 段
	// 在与 water_depth_gradient 内的 abyss_col + blue_shift 叠乘后变成"灰蓝压抑"。
	// 旧值 / 新值 / 视觉影响：vec3(0.82,0.90,1.08)*0.90 → vec3(0.82,0.90,1.08)*0.96
	// abyss 段相对 basin 仍下降但 ΔV 由 ~22% 收敛到 ~12%，保留冷偏方向不变。
	vec3 base_abyss_tint = vec3(0.82, 0.90, 1.08) * 0.96;
	vec3 tint = mix(vec3(1.0), base_abyss_tint, abyss_w);
	float contrast_scale = clamp(deep_ocean_contrast / 0.96, 0.6, 1.4);
	float amp = clamp(deep_ocean_abyss_tint_strength * deep_ocean_color_richness * contrast_scale, 0.0, 1.2);
	return mix(vec3(1.0), tint, clamp(amp, 0.0, 1.0));
}

vec3 hypsometric_tint(float elev, bool is_water) {
	if (is_water) {
		float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		float offshore_t = smoothstep(0.0, 1.0, depth_t);
		return water_depth_gradient(offshore_t, elev);
	}
	float t = clamp((elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	if (t < 0.10) return mix(color_beach, color_lowland, t / 0.10);
	// v10.2：低地→丘陵→山地段全部扩宽，让更多 cell 落在"中等海拔"色阶
	// 而不是被推到 mountain/peak/snow 顶端
	if (t < 0.55) return mix(color_lowland, color_hill, (t - 0.10) / 0.45);
	if (t < 0.85) return mix(color_hill, color_mountain, (t - 0.55) / 0.30);
	// peak→snow 拐点 0.96 → 0.985：snow 只占 top 1.5%
	// gradient `mix(peak, snow, (t-0.985)/0.015)` 让边界 cell（t=0.99）才有 30% 雪白
	if (t < 0.985) return mix(color_mountain, color_peak, (t - 0.85) / 0.135);
	return mix(color_peak, color_snow, (t - 0.985) / 0.015);
}

// ─── biome 色相调制（高度负责亮度，biome 负责色相） ──────────────────────

vec3 biome_hue_modulate(vec3 base, int biome) {
	if (biome == B_FOREST)    return base * vec3(0.70, 1.05, 0.65);
	if (biome == B_GRASSLAND) return base * vec3(0.85, 1.05, 0.78);
	if (biome == B_DESERT)    return base * vec3(1.18, 1.02, 0.72);
	if (biome == B_TUNDRA)    return base * vec3(0.92, 1.00, 1.00);
	if (biome == B_SNOW)      return base * vec3(0.92, 0.95, 1.00);
	if (biome == B_MOUNTAIN)  return base * vec3(1.00, 0.95, 0.95);
	if (biome == B_HILL)      return base * vec3(1.05, 1.00, 0.90);
	if (biome == B_SWAMP)     return base * vec3(0.55, 0.85, 0.62);
	// Phase 10：Whittaker 4
	// JUNGLE：极深饱和绿（雨林郁闭）
	if (biome == B_JUNGLE)    return base * vec3(0.50, 1.00, 0.55);
	if (biome == B_SAVANNA)   return base * vec3(1.10, 1.00, 0.62);
	if (biome == B_TAIGA)     return base * vec3(0.62, 0.92, 0.78);
	// STEPPE：浅黄绿，比 GRASSLAND 减半饱和
	if (biome == B_STEPPE)    return base * vec3(1.00, 1.04, 0.82);
	// Phase 11
	// SHRUBLAND：灰绿带土黄（地中海干性灌丛）
	if (biome == B_SHRUBLAND) return base * vec3(1.05, 0.98, 0.78);
	if (biome == B_MANGROVE)  return base * vec3(0.50, 0.88, 0.65);
	if (biome == B_GLACIER)   return base * vec3(0.92, 0.98, 1.05);
	// DELTA：棕绿斑驳（湿润沉积带）
	if (biome == B_DELTA)     return base * vec3(0.78, 1.00, 0.65);
	// OASIS：鲜亮饱和绿（沙漠中的生命）
	if (biome == B_OASIS)     return base * vec3(0.55, 1.10, 0.55);
	// SALT_FLAT：极淡黄白（高反射）
	if (biome == B_SALT_FLAT) return base * vec3(1.18, 1.15, 0.92);
	// BADLANDS：橙红条纹（沉积层）
	if (biome == B_BADLANDS)  return base * vec3(1.20, 0.85, 0.60);
	return base;
}

// ─── Phase 1：季节相位辅助 ───────────────────────────────────────────────

// Plan B：hemi_phase() 把日历 season_phase（phase=0 = 1 月）映射成
// "本地季节语义"（0=本地春, 1=本地夏, 2=本地秋, 3=本地冬），供
// vegetation_seasonal_tint 等纯视觉函数使用。
//   北半球（lat_signed < 0）: 本地春 = 4 月(sp=1) → eff = sp - 1
//   南半球（lat_signed > 0）: 本地春 = 10 月(sp=3) → eff = sp + 1
// 温度偏移走 season_temp_offset_legacy(lat_signed, phase)，不再经过本函数。
float hemi_phase(float phase, float lat_signed) {
	return (lat_signed < 0.0) ? mod(phase + 3.0, 4.0) : mod(phase + 1.0, 4.0);
}

// 季节温度偏移（Plan B 日历对齐）：cos((phase - 2) × π/2) × amp × hemi_sign
// phase=0(1月) 北半球: -amp（冬）；phase=2(7月) 北半球: +amp（夏）
// 【Legacy / 回退路径】：仅在 true_insolation_enabled == false 时使用。
float season_temp_offset(float phase) {
	return cos((phase - 2.0) * 1.5707963) * season_temp_amp;
}

float season_temp_offset_legacy(float lat_signed, float phase) {
	float hemi_sign = (lat_signed < 0.0) ? 1.0 : ((lat_signed > 0.0) ? -1.0 : 0.0);
	return cos((phase - 2.0) * 1.5707963) * season_temp_amp * hemi_sign;
}

// ─── True Insolation-Driven（Phase F）: CPU/GPU 同源公式 ────────────────
// CPU 端 _compute_insolation / _insolation_season_offset 的 GLSL 镜像。
// 为了单像素可接受的性能，年均 insolation 采用解析近似：
//   insol_annual_mean(lat) ≈ cos(lat) · (1 − ε²/4)
// 非极区误差 < 5%，极区稍大但视觉上不会被玩家察觉；真正的物理权威仍在 CPU。
float compute_insolation_shader(float lat_rad, float phase) {
	float year_progress = mod(phase, 4.0) / 4.0;
	// Plan B：phase=0(1月) → +tilt（南向 subsolar，北半球冬至）；phase=2(7月) → -tilt。
	float subsolar = axial_tilt_rad * cos(6.2831853 * year_progress);
	float cos_zenith = max(cos(lat_rad - subsolar), 0.0);
	float lat_sign = (lat_rad > 0.0) ? 1.0 : ((lat_rad < 0.0) ? -1.0 : 0.0);
	// 与 subsolar 同相位：phase=2 时 cos=-1，北极 sign=-1 → 1 + amp（昼最长）。
	float daylen = 1.0 - insolation_daylen_amp * cos(6.2831853 * year_progress) * lat_sign;
	return clamp(cos_zenith * daylen, 0.0, 1.0);
}

float insolation_annual_mean_shader(float lat_rad) {
	// cos(lat) × (1 − ε²/4) 的解析近似
	float c = max(cos(lat_rad), 0.0);
	return c * (1.0 - axial_tilt_rad * axial_tilt_rad * 0.25);
}

float insolation_season_offset_shader(float lat_signed, float phase) {
	// lat_signed ∈ [-1, 1] → lat_rad ∈ [-π/2, π/2]
	float lat_rad = lat_signed * 1.5707963;
	float now_val = compute_insolation_shader(lat_rad, phase);
	float mean_val = max(insolation_annual_mean_shader(lat_rad), 1e-4);
	float dev = clamp((now_val - mean_val) / mean_val, -1.0, 1.5);
	return insolation_season_gain * dev * season_temp_amp;
}

// 统一入口：true_insolation_enabled 打开时走 insolation 派生；
// 关闭时走 legacy 日历对齐后的 cos 公式，保持旧画面完全一致。
float season_offset_unified(float lat_signed, float phase) {
	if (true_insolation_enabled) {
		return insolation_season_offset_shader(lat_signed, phase);
	}
	return season_temp_offset_legacy(lat_signed, phase);
}

// 当前实时温度：[0, 1]。和 map_generator._compute_temperature 同公式：
// lat_temp = pow(cos(lat_signed * π/2), 1.2) - elev*0.5
// 然后叠 + season_offset + climate_anomaly
float compute_current_temp(float elev, float lat_signed, float season_offset) {
	float lat_temp = pow(max(cos(lat_signed * 1.5707963), 0.0), 1.2);
	float alt_penalty = elev * 0.5;
	return clamp(lat_temp + season_offset + climate_anomaly - alt_penalty, 0.0, 1.0);
}

// 返回乘性 tint（应用为 base * vegetation_seasonal_tint(...)）
vec3 vegetation_seasonal_tint(float phase) {
	vec3 spring = vec3(0.95, 1.06, 0.92);  // 鲜
	vec3 summer = vec3(0.80, 1.00, 0.72);  // 深绿
	vec3 autumn = vec3(1.12, 0.92, 0.62);  // 暖黄橙
	vec3 winter = vec3(0.78, 0.78, 0.86);  // 灰冷
	if (phase < 1.0) return mix(spring, summer, phase);
	if (phase < 2.0) return mix(summer, autumn, phase - 1.0);
	if (phase < 3.0) return mix(autumn, winter, phase - 2.0);
	return mix(winter, spring, phase - 3.0);
}

// 季节性雪盖：综合"永久 SNOW biome"+"季节降温/高山雪线"两部分。返回 [0, 1]。
// - 当前温度 < 0.18 + 陆地 → 季节雪（冬季中纬度也覆雪）
float compute_snow_factor(int biome, float current_temp, float elev, bool is_water) {
	if (is_water) return 0.0;
	float factor = 0.0;
	// 1) 永久 SNOW biome 基础
	if (biome == B_SNOW) factor = 0.65;
	if (biome == B_GLACIER) factor = 0.80;
	float cold_factor = smoothstep(0.18, 0.04, current_temp);
	factor = max(factor, cold_factor * 0.85);
	float land_h = (elev - sea_level) / max(1.0 - sea_level, 0.001);
	if (land_h > 0.40) {
		float alt_snow = smoothstep(0.40, 0.85, land_h) * smoothstep(0.40, 0.10, current_temp);
		factor = max(factor, alt_snow * 0.85);
	}
	return clamp(factor, 0.0, 1.0);
}

// ─── Milestone 2：植被轴色相调制 ────────────────────────────────────────
// 返回乘性 tint（围绕 1.0 浮动），代表"在 biome 主色基础上的植被偏色"。
//   - 针叶林 / 北方林         → 偏墨青绿
//   - 草本植被               → 偏黄绿
//   - 干旱植被               → 偏黄褐
//   - 苔原 / 裸地            → 偏冷灰
// 仅在"主色不能完整表达植被"的地形上生效（PLAIN/HILL/MOUNTAIN/PEAK/LOWLAND/
// GRASSLAND），FOREST/JUNGLE/DESERT/SAVANNA/TAIGA 等 biome 主色已经精确，跳过。
vec3 vegetation_tint(int veg) {
	if (veg == V_TROPICAL_RAINFOREST) return vec3(0.78, 1.10, 0.78);
	if (veg == V_SUBTROPICAL_FOREST)  return vec3(0.82, 1.08, 0.78);
	if (veg == V_TROPICAL_DRY_FOREST) return vec3(0.92, 1.06, 0.74);
	if (veg == V_TEMPERATE_DECIDUOUS) return vec3(0.86, 1.08, 0.76);
	if (veg == V_TEMPERATE_CONIFER)   return vec3(0.78, 1.00, 0.74);
	if (veg == V_TAIGA)               return vec3(0.74, 0.96, 0.74);
	if (veg == V_BOREAL_SHRUB)        return vec3(0.85, 0.98, 0.78);
	if (veg == V_TEMPERATE_GRASSLAND) return vec3(0.92, 1.06, 0.76);
	if (veg == V_TEMPERATE_STEPPE)    return vec3(1.05, 1.02, 0.74);
	if (veg == V_MEDITERRANEAN_SHRUB) return vec3(1.00, 0.96, 0.78);
	if (veg == V_SAVANNA)             return vec3(1.08, 1.00, 0.72);
	if (veg == V_DESERT_SCRUB)        return vec3(1.10, 1.00, 0.78);
	if (veg == V_XERIC_DESERT)        return vec3(1.14, 1.02, 0.74);
	if (veg == V_OASIS_VEG)           return vec3(0.86, 1.10, 0.78);
	if (veg == V_TUNDRA)              return vec3(0.92, 0.96, 0.92);
	if (veg == V_ALPINE_TUNDRA)       return vec3(0.92, 0.94, 0.94);
	if (veg == V_ALPINE_MEADOW)       return vec3(0.88, 1.05, 0.82);
	if (veg == V_POLAR_DESERT)        return vec3(0.96, 0.96, 0.98);
	if (veg == V_MANGROVE)            return vec3(0.78, 1.02, 0.80);
	if (veg == V_SWAMP)               return vec3(0.84, 1.02, 0.80);
	if (veg == V_MARSH)               return vec3(0.88, 1.04, 0.82);
	return vec3(1.0);
}

// FOREST/JUNGLE/DESERT/SAVANNA/TAIGA/... 主色已经精确表达植被，跳过避免双倍饱和。
bool biome_accepts_vegetation_tint(int biome) {
	return (biome == B_PLAIN
		|| biome == B_HILL
		|| biome == B_MOUNTAIN
		|| biome == B_GRASSLAND);
}

// ─── Milestone 2：覆盖物轴叠加 ──────────────────────────────────────────
// SNOW/SEA_ICE/GLACIER 已经被 dynamic_snow / biome 主路径处理，这里只补
// "原系统没专门处理"的两个：FLOODING（水蓝叠加）+ PERMAFROST（灰青微暗）。
vec4 cover_overlay(int cover) {
	if (cover == CV_FLOODING)   return vec4(0.30, 0.45, 0.62, 0.45);
	if (cover == CV_PERMAFROST) return vec4(0.74, 0.78, 0.82, 0.10);
	if (cover == CV_GLACIER)    return vec4(0.86, 0.92, 0.96, 0.20);
	// Systemic Ocean Currents：远洋华深海富营养标记——淡绿 tint，表示浮游生物繁殖。
	// 不覆盖流纹动画，仅在最后混色中加一层成环境光影响。
	if (cover == CV_PELAGIC_BLOOM) return vec4(0.28, 0.58, 0.42, 0.22);
	return vec4(0.0);
}

// ─── Milestone 3 (split)：地形 shader 只保留 DROUGHT/HEATWAVE 的 multiplicative 调色 ─────
// 其他 weather 类型（RAIN/STORM/FOG/BLIZZARD/MONSOON）全部移到 WeatherLayer 独立渲染，
// 返回值：
//   a   = 实际生效强度（已乘 coverage * weather_strength）；0 = 当前 fragment 无 multiplicative 天气
vec4 sample_terrain_weather_tint(vec2 wp) {
	int best_type = WT_CLEAR;
	float best_coverage = 0.0;
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;  // sentinel：空 slot
		int wt_i = int(wt_f + 0.5);
		// 只挑 multiplicative 类型，其余交给 WeatherLayer
		if (wt_i != WT_DROUGHT && wt_i != WT_HEATWAVE) continue;
		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float ed = weather_front_ellipse_distance(wp, c.xy, c.z, shape);
		float spread = mix(1.0, 1.18, visual.z);
		float radial = 1.0 - smoothstep(0.62, 1.34 + visual.z * 0.18, ed / spread);
		float broken_edge = fbm((wp + c.xy * 0.13) * 0.030, 2);
		float coverage = radial * mix(0.70, 1.0, broken_edge) * clamp(max(c.w, visual.x), 0.0, 1.0);
		if (coverage > best_coverage) {
			best_coverage = coverage;
			best_type = wt_i;
		}
	}
	if (best_coverage <= 0.001) return vec4(0.0);
	// DROUGHT 强度 0.30 / HEATWAVE 强度 0.25（与原 weather_overlay_color 数值一致）
	vec3 tint;
	float base_alpha;
	if (best_type == WT_DROUGHT) {
		tint = vec3(1.18, 0.92, 0.65);
		base_alpha = 0.30;
	} else {  // WT_HEATWAVE
		tint = vec3(1.20, 1.00, 0.70);
		base_alpha = 0.25;
	}
	return vec4(tint, base_alpha * best_coverage * weather_strength);
}

// ─── 锐利程序化贴图（不依赖 hex，世界坐标连续） ─────────────────────────

vec3 procedural_biome_detail(int biome, vec2 wp) {
	if (biome == B_FOREST) {
		float vor = voronoi_cell(wp * 0.30);
		float n = fbm(wp * 0.40, 3);
		float modulator = mix(0.78, 1.15, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.92, 1.05, n);
		return vec3(modulator);
	}
	if (biome == B_GRASSLAND) {
		float n = fbm(wp * 0.18, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt：micro ±0.05，单 octave 足够
		return vec3(mix(0.85, 1.10, n) * mix(0.95, 1.05, micro));
	}
	if (biome == B_DESERT) {
		vec2 dune_dir = vec2(0.85, 0.30);
		float t = dot(wp, dune_dir) * 0.040;
		// v9.fbm-opt：sin 内部的 phase 扰动，单 octave 已经够"沙丘走向有变化"
		float waves = sin(t + fbm(wp * 0.06, 1) * 5.0) * 0.5 + 0.5;
		float micro = fbm(wp * 0.30, 1);
		return vec3(mix(0.88, 1.10, waves) * mix(0.95, 1.05, micro));
	}
	if (biome == B_HILL) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt
		// v10.3：上限 1.06×1.04=1.10，配合 hillshade 最多 ×1.6
		return vec3(mix(0.85, 1.06, n) * mix(0.95, 1.04, micro));
	}
	if (biome == B_MOUNTAIN) {
		float n = fbm(wp * 0.30, 4);
		float vor = voronoi_cell(wp * 0.16);
		// v10.3：上限从 1.20×1.10=1.32 降到 1.05×1.03=1.08
		// 配合 hillshade max 1.45 后总放大 ≤ 1.57，peak 色 (0.55) × 1.57 = 0.86 → 灰褐
		return vec3(mix(0.72, 1.05, n) * mix(0.92, 1.03, smoothstep(0.05, 0.5, vor)));
	}
	if (biome == B_PLAIN) {
		float n = fbm(wp * 0.12, 3);
		float micro = fbm(wp * 0.40, 1);  // v9.fbm-opt
		return vec3(mix(0.92, 1.08, n) * mix(0.97, 1.03, micro));
	}
	if (biome == B_TUNDRA) {
		float n = fbm(wp * 0.16, 3);
		return vec3(mix(0.85, 1.08, n));
	}
	if (biome == B_SNOW) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.93, 1.04, n) * mix(0.98, 1.02, micro));
	}
	if (biome == B_SWAMP) {
		float pools = fbm(wp * 0.55, 3);
		float mud = fbm(wp * 0.18 + vec2(13.0, -7.0), 2);
		float pool_factor = smoothstep(0.55, 0.45, pools);
		float base_mod = mix(0.88, 1.08, mud);
		float pool_mod = mix(1.0, 0.78, pool_factor);
		return vec3(base_mod * pool_mod);
	}
	if (biome == B_JUNGLE) {
		float canopy = voronoi_cell(wp * 0.45);
		float n = fbm(wp * 0.55, 3);
		float micro = fbm(wp * 1.20, 1);  // v9.fbm-opt：micro ±0.05，单 octave 足够
		float canopy_mod = mix(0.72, 1.08, smoothstep(0.05, 0.55, canopy));
		float n_mod = mix(0.92, 1.05, n);
		float micro_mod = mix(0.94, 1.04, micro);
		return vec3(canopy_mod * n_mod * micro_mod);
	}
	if (biome == B_SAVANNA) {
		// 稀树草原：金黄草低频 fbm + 散点深绿（树丛）voronoi
		float grass = fbm(wp * 0.16, 3);
		float trees = voronoi_cell(wp * 0.22);
		float tree_factor = smoothstep(0.05, 0.45, trees);
		float grass_mod = mix(0.85, 1.12, grass);
		float tree_mod = mix(0.62, 1.0, tree_factor);
		return vec3(grass_mod * tree_mod);
	}
	if (biome == B_TAIGA) {
		// 泰加：FOREST 同款但更暗、加冷调白点（积雪未融）
		float vor = voronoi_cell(wp * 0.34);
		float n = fbm(wp * 0.40, 3);
		float patches = fbm(wp * 0.65 + vec2(11.0, 17.0), 2);
		float modulator = mix(0.70, 1.05, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.90, 1.04, n);
		float frost = smoothstep(0.78, 0.92, patches);
		modulator *= mix(1.0, 1.18, frost);
		return vec3(modulator);
	}
	if (biome == B_STEPPE) {
		float n = fbm(wp * 0.14, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.90, 1.06, n) * mix(0.96, 1.04, micro));
	}
	if (biome == B_SHRUBLAND) {
		// 灌丛：中频斑点（灌木簇）+ 微干燥粒
		float vor = voronoi_cell(wp * 0.36);
		float n = fbm(wp * 0.30, 3);
		float bush = mix(0.82, 1.05, smoothstep(0.05, 0.55, vor));
		float n_mod = mix(0.93, 1.06, n);
		return vec3(bush * n_mod);
	}
	if (biome == B_MANGROVE) {
		// 红树林：SWAMP 同款水洼但更深、加密集树根 voronoi
		float pools = fbm(wp * 0.50, 3);
		float roots = voronoi_cell(wp * 0.55);
		float pool_factor = smoothstep(0.55, 0.40, pools);
		float root_mod = mix(0.78, 1.0, smoothstep(0.05, 0.45, roots));
		float pool_mod = mix(1.0, 0.70, pool_factor);
		return vec3(root_mod * pool_mod);
	}
	if (biome == B_GLACIER) {
		// 冰川：低频起伏 + 高频裂纹（voronoi 边缘 = 冰裂缝）
		float n = fbm(wp * 0.18, 3);
		float crack = voronoi_cell(wp * 0.70);
		float crack_factor = smoothstep(0.0, 0.18, crack);
		return vec3(mix(0.92, 1.06, n) * mix(0.78, 1.02, crack_factor));
	}
	if (biome == B_DELTA) {
		float n = fbm(wp * 0.35, 3);
		float fans = fbm(wp * 0.55 + vec2(13.0, -7.0), 2);
		float pools = smoothstep(0.55, 0.40, fans);
		float n_mod = mix(0.85, 1.10, n);
		float pool_mod = mix(1.0, 0.78, pools);
		return vec3(n_mod * pool_mod);
	}
	if (biome == B_OASIS) {
		// 绿洲：中心鲜绿 + 周围淡黄沙渐变（径向 fade 用 voronoi 距离场）
		float vor = voronoi_cell(wp * 0.40);
		float n = fbm(wp * 0.50, 3);
		// vor 越小 = 越靠近某个特征点（绿洲核心） → 鲜绿
		float core = smoothstep(0.40, 0.05, vor);
		float n_mod = mix(0.92, 1.10, n);
		float core_mod = mix(0.85, 1.20, core);
		return vec3(n_mod * core_mod);
	}
	if (biome == B_SALT_FLAT) {
		float crystals = voronoi_cell(wp * 1.10);
		float crystal_factor = smoothstep(0.0, 0.15, crystals);
		float crack = voronoi_cell(wp * 0.30);
		float crack_factor = smoothstep(0.0, 0.10, crack);
		return vec3(mix(0.85, 1.10, crystal_factor) * mix(0.95, 1.02, crack_factor));
	}
	if (biome == B_BADLANDS) {
		// 荒原：横向沉积层条纹（用世界 y mod）+ 高频粗砂
		float bands = sin(wp.y * 0.45 + fbm(wp * 0.12, 2) * 4.0) * 0.5 + 0.5;
		float sand = fbm(wp * 0.40, 3);
		return vec3(mix(0.85, 1.18, bands) * mix(0.92, 1.06, sand));
	}
	return vec3(1.0);
}

// ─── 双光源 hillshading（key + fill，软阴影） ───────────────────────────

float hillshading_two_lights(vec2 uv) {
	vec2 texel = 1.0 / hm_resolution;
	float l = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y));
	float dx = (r - l) * hillshade_slope_gain;
	float dy = (d - u) * hillshade_slope_gain;
	vec3 normal = normalize(vec3(-dx, -dy, 1.0));

	vec3 key_dir  = normalize(vec3(hillshade_dir.x,      hillshade_dir.y,      0.65));
	vec3 fill_dir = normalize(vec3(hillshade_fill_dir.x, hillshade_fill_dir.y, 0.50));

	float key  = max(dot(normal, key_dir),  0.0);
	float fill = max(dot(normal, fill_dir), 0.0) * 0.40;
	return key + fill;
}

// ─── 任务 3：风格化 PBR 昼夜着色辅助 ───────────────────────────────────
// 关键决策 1：保留 PBR 物理光照流程（方向光 NdotL + 菲涅尔柔边），但色温/饱和度
//   phase=0.0 日出：太阳从东方地平线升起，天色暖橙
//   phase=0.25 正午：太阳在天顶（接近正上方），天色偏白
//   phase=0.5 日落：太阳回到地平线（西方），天色暖橙偏红
//
// 返回"太阳方向向量"（世界坐标空间，XY 是水平，Z 是向上近似法向）。
// 正午 z 接近 1（正上方），日出/日落 z 接近 0，午夜 z 为负（光从下面来，
// 在渲染上被解释为"无直接光"，地表由环境冷色补光）。
vec3 get_sun_dir(float phase) {
	// 一天 360° 旋转：phase→angle；0.0 起点设在"日出地平线"
	float angle = phase * 6.2831853;  // 2π
	float sun_x = cos(angle - 1.5707963);   // shift：phase=0 时 cos(-π/2)=0, sin(...)
	float sun_z = sin(angle - 1.5707963) + 1.0; // phase=0 时 z≈0 (地平线) ... phase=0.25 时 z≈2 → 归一化后 ~1
	sun_z = sun_z - 1.0;  // 重新平移为 [-1, 1]：日出 0, 正午 1, 日落 0, 午夜 -1
	// y 方向做 0.15 的微偏（稍偏南），贴近"太阳轨迹不是完美竖直面"的直觉
	float sun_y = 0.15;
	return normalize(vec3(sun_x, sun_y, sun_z));
}

// 天空染色：四关键色 smoothstep 插值。手调曲线，不走物理光谱。
vec3 get_sky_tint(float phase) {
	vec3 sunrise = vec3(1.20, 0.88, 0.72);  // 暖
	vec3 noon    = vec3(1.00, 1.00, 0.98);  // 近白
	vec3 sunset  = vec3(1.18, 0.80, 0.62);  // 暖橙偏红
	vec3 night   = vec3(0.55, 0.65, 0.92);  // 冷蓝（月光）
	if (phase < 0.25)
		return mix(sunrise, noon,   smoothstep(0.0,  0.25, phase));
	if (phase < 0.5)
		return mix(noon,    sunset, smoothstep(0.25, 0.5,  phase));
	if (phase < 0.75)
		return mix(sunset,  night,  smoothstep(0.5,  0.75, phase));
	return mix(night,   sunrise, smoothstep(0.75, 1.0,  phase));
}

// 整体亮度系数：夜间压到 night_brightness_min ~ max 之间，白天为 1.0。
float get_day_brightness(float phase) {
	// 白天区间 [0.0, 0.5]（日出→日落）= 1.0；夜晚区间 [0.5, 1.0] 压暗
	// 过渡段 ±0.06 phase 做软过渡
	float day_mask = smoothstep(0.06, 0.0, abs(phase - 0.25) - 0.19);
	// 夜间值：min~max 之间再按 phase 相对午夜 0.75 的距离微调（午夜最暗）
	float night_t = smoothstep(0.0, 0.25, abs(phase - 0.75));
	float night_brightness = mix(night_brightness_min, night_brightness_max, night_t);
	return mix(night_brightness, 1.0, day_mask);
}

// 风格化 PBR 着色：对输入 albedo 应用 NdotL + 菲涅尔柔边 + 天色 tint + 夜间压暗。
// terrain_normal 由 hillshading 的 dx/dy 近似重构（已经算过，此处复用 result）；
vec3 apply_day_night(vec3 albedo, float phase, vec2 slope_xy) {
	vec3 n = normalize(vec3(-slope_xy, 1.0));
	vec3 sun = get_sun_dir(phase);
	// NdotL：太阳在地平线下时会是负数，clamp 到 0 = 无直接光
	float ndotl = max(dot(n, sun), 0.0);
	// 风格化 PBR：ambient 0.55（手绘风不追求 100% 物理），direct 0.45 × NdotL
	float lighting = 0.55 + 0.45 * ndotl;
	// 菲涅尔柔边：用 z 分量模拟"视角几乎垂直"，对山坡背光侧做轻微提亮
	// fresnel = pow(1.0 - NdotV, 3)；2D canvas NdotV 近似 n.z
	float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
	lighting += fresnel * 0.08;
	// 天色 tint
	vec3 sky = get_sky_tint(phase);
	vec3 result = albedo * lighting * sky;
	// 整体亮度（夜间压暗）
	result *= get_day_brightness(phase);
	return result;
}

// ─── Pass 2（任务 3）：TOD 驱动的风格化 PBR ────────────────────────────
// 为 Sobel 3x3（visual_quality>=1）或保留 4-tap（visual_quality==0，需求 3.6）。
// 关键改动（对应需求 3.1~3.6）：
//   1. 法线 N 来自 height_tex 的 Sobel/Center-Diff，比 hillshading_two_lights 更强
//   2. 光照方向 = tod_sun_dir，色温 = tod_sun_color，环境 = tod_ambient_color
//   3. 高光 = Blinn-Phong NdotH，roughness 按 biome 分类（雪光滑、森林粗糙）
//   4. 平地退化：|∇h| < epsilon 时跳过方向光（避免噪声伪影）
//   5. 最终乘 tod_exposure 并做艺术化 tonemap
//   6. day_night_enabled=false 时 caller 跳过本函数，回退到 apply_day_night 路径
//
// 返回：PBR 染色后的 RGB（caller 负责 clamp）。
// 从 height_tex 采样得到 tangent-space 法线（Sobel 3x3 或 4-tap 中心差分）
vec3 compute_terrain_normal(vec2 uv, int quality) {
	vec2 texel = 1.0 / hm_resolution;
	if (quality <= 0) {
		// 低质：4-tap 中心差分（与原 hillshading 一致）
		float l0 = decode_height_rg8(uv - vec2(texel.x, 0.0));
		float r0 = decode_height_rg8(uv + vec2(texel.x, 0.0));
		float u0 = decode_height_rg8(uv - vec2(0.0, texel.y));
		float d0 = decode_height_rg8(uv + vec2(0.0, texel.y));
		float dx0 = (r0 - l0) * hillshade_slope_gain;
		float dy0 = (d0 - u0) * hillshade_slope_gain;
		return normalize(vec3(-dx0, -dy0, 1.0));
	}
	// 高质：Sobel 3x3（8 采样，方向性更稳）
	float hLU = decode_height_rg8(uv + vec2(-texel.x, -texel.y));
	float hU2 = decode_height_rg8(uv + vec2( 0.0,     -texel.y));
	float hRU = decode_height_rg8(uv + vec2( texel.x, -texel.y));
	float hL2 = decode_height_rg8(uv + vec2(-texel.x,  0.0));
	float hR2 = decode_height_rg8(uv + vec2( texel.x,  0.0));
	float hLD = decode_height_rg8(uv + vec2(-texel.x,  texel.y));
	float hD2 = decode_height_rg8(uv + vec2( 0.0,      texel.y));
	float hRD = decode_height_rg8(uv + vec2( texel.x,  texel.y));
	// Sobel X：[[-1,0,1],[-2,0,2],[-1,0,1]] / 8；Y 
	float gx = ((hRU + 2.0 * hR2 + hRD) - (hLU + 2.0 * hL2 + hLD)) * 0.125;
	float gy = ((hLD + 2.0 * hD2 + hRD) - (hLU + 2.0 * hU2 + hRU)) * 0.125;
	gx *= hillshade_slope_gain;
	gy *= hillshade_slope_gain;
	return normalize(vec3(-gx, -gy, 1.0));
}

// 按 biome 查表粗糙度（需求 3.3）：雪/冰光滑、沙中等、森林/草原粗糙
float biome_roughness(int biome) {
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_SEA_ICE) return 0.22;
	if (biome == B_DESERT || biome == B_SALT_FLAT) return 0.58;
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.88;
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE) return 0.78;
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS) return 0.65;
	return 0.55;
}

// 主入口：TOD 驱动的 PBR。is_water 时让上层直接跳过。
vec3 apply_tod_pbr(vec3 albedo, vec2 uv, int biome, int quality) {
	// 1. 法线
	vec3 N = compute_terrain_normal(uv, quality);
	float slope_mag = length(vec2(N.x, N.y));

	vec3 L = normalize(tod_sun_dir);
	float ndotl = max(dot(N, L), 0.0);
	float direct_amp = hillshade_strength + 0.55;
	vec3 diffuse = tod_sun_color * ndotl * direct_amp;

	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);
	float roughness = biome_roughness(biome);
	float shininess = mix(128.0, 4.0, roughness);
	float spec_amp = mix(0.25, 0.02, roughness);
	float ndoth = max(dot(N, H), 0.0);
	float spec = pow(ndoth, shininess) * spec_amp;
	vec3 specular = tod_sun_color * spec;

	vec3 ambient = tod_ambient_color;

	if (slope_mag < 0.015) {
		return albedo * (ambient + tod_sun_color * 0.3) * tod_exposure;
	}

	vec3 lit = albedo * (ambient + diffuse) + specular;

	// 7. 夜晚压暗
	float night_scale = mix(1.0, 0.55, tod_night_factor);
	lit *= night_scale;

	// 8. 曝光 + 艺术化 tonemap（简易 Reinhard）
	lit *= tod_exposure;
	lit = lit / (1.0 + lit * 0.35);
	return lit;
}

// ─── Water Visual Overhaul：水体函数与常量已抽至 water.gdshaderinc ──────
// 内容：Gerstner-Lite 常量 + water_surface_height / sample_water_normal /
//       water_domain_warp / water_shade_lines / water_calm_brightness /
//       water_calm_tint / water_biome_weights
// 依赖：common_noise.gdshaderinc（fbm/value_noise/voronoi_cell/hash21）、
//       enum_atlas sampler 与 B_LAKE/B_REEF/B_KELP/B_SEA_ICE 常量（均在本文件上方声明）。
#include "res://shaders/include/water.gdshaderinc"

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));

	float elev = decode_height_rg8(uv);

	// v9.atlas：把 3 张 atlas 一次采样解码到局部变量，后续逻辑读这些变量
	vec4 enums = texture(enum_atlas,   uv);
	vec4 scals = texture(scalar_atlas, uv);
	// C3 plan (vector_atlas removal)：vector_atlas 已不再被任何 GDScript 路径
	// 注入（hex_renderer 不再 set_shader_parameter）。直接把 vects 置零，下游
	// `ocean_current_v / wind_v` 全部退化为 vec2(0)，所有 length>0.05 等阈值
	// 分支自然短路，海面回到无洋流暗道 / 静态 wave 状态。仍保留 uniform 声明
	// 与下方解码代码以避免任何 shader compile 漂移；把 sampler 调用替换为常量。
	vec4 vects = vec4(0.5);

	int biome = int(enums.r * 255.0 + 0.5);
	int veg   = int(enums.g * 255.0 + 0.5);
	int cover = int(enums.b * 255.0 + 0.5);
	float moist     = scals.r;
	float lat_norm  = scals.b;
	// Daily Sim SoA Refactor 阶段 1：sea_ice_fraction 从 scalar_atlas.a 拆到独立 sea_ice_tex。
	// scalar_atlas.a 已为保留位（0）。vol_intensity 仍从独立 volcano_field_tex 采样。
	float sea_ice_frac_px = texture(sea_ice_tex, uv).r;
	float vol_intensity_atlas = texture(volcano_field_tex, uv).r;
	vec2 ocean_current_v = vects.rg * 2.0 - 1.0;
	vec2 wind_v          = vects.ba * 2.0 - 1.0;

	// flow + river_edge_warp 仅在陆地的 river 分支才用，这里推迟到 _if (!is_water)_ 计算，
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

	// ─── Phase 1：季节相位 + 当前温度（每帧由 WorldClock 驱动） ───────────
	float lat_signed = lat_norm * 2.0 - 1.0;            // [-1, 1]
	// eff_phase 仅用于植被季节色相（vegetation_seasonal_tint）；温度偏移走 insolation 统一入口。
	float eff_phase = hemi_phase(season_phase, lat_signed);
	// True Insolation-Driven：CPU / GPU 同源季节偏移（true_insolation_enabled == true 时走 insolation 派生）
	float season_offset = season_offset_unified(lat_signed, season_phase);
	float current_temp = compute_current_temp(elev, lat_signed, season_offset);

	vec3 col = hypsometric_tint(elev, is_water);

	if (!is_water) {
		// 2. biome 色相调制
		col = biome_hue_modulate(col, biome);
		// JUNGLE 一年常绿不参与；DESERT/SAVANNA/STEPPE 草本变化已经在 detail 里）
		if (biome == B_FOREST || biome == B_GRASSLAND || biome == B_HILL || biome == B_PLAIN
				|| biome == B_TAIGA) {
			vec3 veg_tint = vegetation_seasonal_tint(eff_phase);
			col = mix(col, col * veg_tint, vegetation_season_strength);
		} else if (biome == B_SAVANNA || biome == B_STEPPE) {
			// 草原 / 稀树草原：振幅减半（干湿季对比远不如温带森林明显）
			vec3 veg_tint = vegetation_seasonal_tint(eff_phase);
			col = mix(col, col * veg_tint, vegetation_season_strength * 0.5);
		}
		col *= procedural_biome_detail(biome, wp);
		// 3.5. Milestone 2：植被轴调制
		// 仅在主色单一的地形 (PLAIN/HILL/MOUNTAIN/GRASSLAND) 上启用，
		if (vegetation_axis_strength > 0.001
				&& veg != V_NONE
				&& biome_accepts_vegetation_tint(biome)) {
			vec3 v_tint = vegetation_tint(veg);
			col = mix(col, col * v_tint, vegetation_axis_strength);
		}
	}

	// 4. Hillshading（陆地强阴影；海面用低频纹理代替 + Phase 3 洋流流纹动画）
	if (!is_water) {
		// v10.4：light 来自 key+fill，理论上限 ≈ 1.2，必须 saturate 到 [0,1]
		float light = clamp(hillshading_two_lights(uv), 0.0, 1.0);
		col *= mix(1.0 - hillshade_strength, 1.0 + hillshade_strength, light);

		// Data-driven land wind streaks.
		vec2 wind = wind_v;
		if (length(wind) > 0.05 && wind_streak_strength > 0.001) {
			vec2 wind_norm_dir = normalize(wind);
			vec2 perp = vec2(-wind_norm_dir.y, wind_norm_dir.x);
			float along = dot(wp, wind_norm_dir) * 0.016;
			float across = dot(wp, perp) * 0.115;
			float lane = fbm(vec2(along + world_time * 0.018, across), 2);
			float fine = fbm(vec2(along * 2.7 + 19.0, across * 0.72 - world_time * 0.012), 1);
			float streak = smoothstep(0.40, 0.78, lane * 0.70 + fine * 0.30);
			float monsoon_cov = 0.0;
			for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
				if (i >= weather_front_count) break;
				int wt_i = int(weather_front_types[i] + 0.5);
				if (wt_i != WT_MONSOON) continue;
				vec4 c = weather_front_centers[i];
				vec4 shape = weather_front_shapes[i];
				vec4 visual = weather_front_visuals[i];
				float ed = weather_front_ellipse_distance(wp, c.xy, c.z, shape);
				float cov = 1.0 - smoothstep(0.62, 1.36 + visual.z * 0.18, ed);
				monsoon_cov = max(monsoon_cov, cov * max(visual.x, visual.y));
			}
			float boost = mix(1.0, monsoon_wind_streak_boost, monsoon_cov);
			vec3 wind_tint = mix(vec3(0.96, 1.00, 1.03), vec3(0.84, 0.94, 1.04), monsoon_cov);
			col *= mix(vec3(1.0), wind_tint, wind_streak_strength * boost * 0.65);
			col *= 1.0 + (streak - 0.5) * wind_streak_strength * boost * 1.8;
		}
	} else if (is_water) {
		// ═══════════════════════════════════════════════════════════════
		// 旧实现的根本问题：LAKE/REEF/KELP/SEA_ICE/OCEAN 每个 biome 是互斥
		// 新做法：
		// 1) 用 water_biome_weights 的 3×3 邻域计数得到软权重。
		// 2) 先算统一"深浅梯度底色"（需求 3.1/3.2 的三段离岸色）。
		// 3) 各 biome 特征色 / 特征纹理 用 weight 累加 mix 到底色上。
		// 4) 域扭曲（water_domain_warp）让所有 biome 特征纹理沿同一水流被搅散，
		// ───────────────────────────────────────────────────────────────

		float water_boundary_softness = clamp(water_biome_blend_radius / 2.2, 0.0, 1.0);
		float warp_for_water = water_domain_warp_strength * mix(0.45, 1.0, water_boundary_softness);
		vec2 wpw = water_domain_warp(wp, world_time, warp_for_water);

		// (B) 统一深浅梯度底色（离岸度 offshore，代替旧的三段 if）
		float offshore = 0.0;
		{
			vec2 tx = 1.0 / hm_resolution;
			float deep_cnt = 0.0;
			if (visual_quality >= 1) {
				for (int oy = -2; oy <= 2; oy++) {
					for (int ox = -2; ox <= 2; ox++) {
						float eh = decode_height_rg8(uv + vec2(float(ox), float(oy)) * tx);
						deep_cnt += step(eh, sea_level - 0.02);
					}
				}
				offshore = clamp(deep_cnt / 25.0, 0.0, 1.0);
			} else {
				for (int oy = -1; oy <= 1; oy++) {
					for (int ox = -1; ox <= 1; ox++) {
						float eh = decode_height_rg8(uv + vec2(float(ox), float(oy)) * tx);
						deep_cnt += step(eh, sea_level - 0.02);
					}
				}
				offshore = clamp(deep_cnt / 9.0, 0.0, 1.0);
			}
		}
		float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		float offshore_depth = clamp(offshore * 0.68 + smoothstep(0.00, 0.68, depth_t) * 0.32, 0.0, 1.0);
		vec3 tier_color = water_depth_gradient(offshore_depth, elev);
		float water_fill_w = smoothstep(0.02, 0.82, 0.58 + offshore_depth * 0.34);
		// Let the stylized water palette dominate, while still preserving subtle terrain shading below it.
		col = mix(col, tier_color, water_fill_w);
		float lagoon_lift = 1.0 - smoothstep(0.10, 0.56, offshore_depth);
		col = mix(col, col * vec3(0.90, 1.07, 1.10), lagoon_lift * 0.14);

		// (C) 全局低频水色起伏（所有水体共享同一层 ripple，边界无感）
		float base_ripple = fbm(wpw * 0.008 + vec2(31.0, 7.0), 2);
		float deep_ripple = fbm(wpw * 0.0038 + vec2(-47.0, 23.0), 2);
		float deep_layer_w = smoothstep(0.36, 1.0, offshore_depth);
		col *= 1.0 + (base_ripple - 0.5) * mix(0.050, 0.082, deep_layer_w);
		vec3 deep_variation = mix(vec3(0.92, 1.03, 1.14), vec3(1.08, 0.94, 1.05), deep_ripple);
		col *= mix(vec3(1.0), deep_variation, deep_layer_w * 0.115);
		vec3 cartoon_chroma = mix(vec3(0.78, 1.20, 1.18), vec3(0.70, 0.96, 1.38), smoothstep(0.12, 1.0, offshore_depth));
		col *= mix(vec3(1.0), cartoon_chroma, water_cartoon_color_strength * 0.26);
		if (visual_quality >= 1 && water_cartoon_color_strength > 0.001) {
			float color_block = fbm(wpw * 0.0048 + vec2(world_time * 0.010, -world_time * 0.006), 2);
			vec3 block_tint = mix(vec3(0.80, 1.16, 1.15), vec3(0.92, 0.93, 1.24), color_block);
			col *= mix(vec3(1.0), block_tint, water_cartoon_color_strength * mix(0.10, 0.18, deep_layer_w));
		}

		// (D) biome 软权重
		vec4 bw;
		if (water_biome_blend_radius > 0.001) {
			float blend_radius_eff = water_biome_blend_radius * mix(1.0, 1.45, water_transition_softness);
			bw = water_biome_weights(uv, 1.0 / hm_resolution, blend_radius_eff);
		} else {
			// 软混合关闭 → 退化为"当前像素 biome 占 1"
			bw = vec4(
				biome == B_LAKE    ? 1.0 : 0.0,
				biome == B_REEF    ? 1.0 : 0.0,
				biome == B_KELP    ? 1.0 : 0.0,
				biome == B_SEA_ICE ? 1.0 : 0.0
			);
		}
		// Radius-aware smooth weights: wider radii use a lower entry threshold so
		// neighboring water biomes feather in gently instead of popping at one texel.
		float transition_soft = clamp(max(water_boundary_softness, water_transition_softness), 0.0, 1.0);
		float blend_entry = mix(0.28, 0.05, transition_soft);
		float blend_full = mix(0.92, 0.56, transition_soft);
		float w_lake = smoothstep(blend_entry, blend_full, bw.x);
		float w_reef = smoothstep(blend_entry, blend_full, bw.y);
		float w_kelp = smoothstep(blend_entry, blend_full, bw.z);
		// Emergent Climate Coupling：海冰权重直接读 sea_ice_tex 的连续 sea_ice_fraction，
		// 不再依赖 biome == SEA_ICE 的邻域计数（否则就会出现"80% 覆盖率却显示海洋 /
		// 20% 却显示冰"的硬切错位）。同时对 3×3 邻域做平均，起到和旧实现一致的软边作用。
		float ice_frac_avg = sea_ice_frac_px;
		{
			vec2 tx_ice = 1.0 / derived_resolution;
			float acc_ice = sea_ice_frac_px;
			for (int oy = -1; oy <= 1; oy++) {
				for (int ox = -1; ox <= 1; ox++) {
					if (ox == 0 && oy == 0) continue;
					acc_ice += texture(sea_ice_tex, clamp(uv + vec2(float(ox), float(oy)) * tx_ice, vec2(0.0), vec2(1.0))).r;
				}
			}
			ice_frac_avg = acc_ice / 9.0;
		}
		float w_ice = smoothstep(0.08, 0.85, ice_frac_avg);
		// Keep stacked special-water weights bounded so overlapping borders stay soft
		// without over-tinting or producing decal-like saturated seams.
		float special_sum = max(w_lake + w_reef + w_kelp + w_ice, 1.0);
		w_lake /= special_sum;
		w_reef /= special_sum;
		w_kelp /= special_sum;
		w_ice  /= special_sum;

		float open_ocean_w = clamp(
			(1.0 - w_lake - w_reef * 0.62 - w_kelp * 0.78 - w_ice)
					* smoothstep(0.26, 0.92, offshore_depth),
			0.0,
			1.0
		);
		if (open_ocean_w > 0.001 && water_cartoon_color_strength > 0.001) {
			int ocean_patch_oct = (visual_quality >= 2) ? 3 : 2;
			float gyre_a = fbm(wpw * 0.0056 + vec2(13.0, -31.0), ocean_patch_oct);
			float gyre_b = fbm(wpw * 0.012 + vec2(-29.0, 47.0), 1);
			if (visual_quality >= 1) {
				gyre_b = fbm(wpw * 0.012 + vec2(world_time * 0.012, -world_time * 0.007), 2);
			}
			float gyre_mix = smoothstep(0.20, 0.86, gyre_a * 0.72 + gyre_b * 0.28);
			// Deep Ocean Layered Color: widen the hue/sat span of the gyre patch
			// so half-enclosed seas read differently from the open-ocean interior.
			// Open Ocean Color Rebalance：统一把 patch 与 boost 的饱和度往 base palette
			// 看齐，避免 patch 比 base 更鲜艳；同时把混合权重区间从 (0.34,0.58) 扩到
			// (0.42,0.66)，使大色块更可辨但仍属于"云影感"而不是"色块拼贴"。
			float patch_boost = clamp(deep_ocean_patch_boost * deep_ocean_color_richness, 0.0, 1.0);
			// 旧值 / 新值：cobalt(0.018,0.16,0.48)→(0.10,0.20,0.40) S 0.96→0.75
			//             teal  (0.020,0.32,0.54)→(0.12,0.32,0.44) S 0.96→0.73
			//             violet(0.045,0.13,0.52)→(0.14,0.16,0.42) S 0.91→0.67
			vec3 cobalt_patch = vec3(0.10, 0.20, 0.40);
			vec3 teal_patch = vec3(0.12, 0.32, 0.44);
			vec3 violet_patch = vec3(0.14, 0.16, 0.42);
			// Boosted variants push cobalt slightly deeper-blue, teal greener,
			// violet toward indigo — same family, wider separation.
			// 旧值 / 新值：cobalt_boost(0.010,0.12,0.56)→(0.08,0.16,0.46)
			//             teal_boost  (0.012,0.40,0.50)→(0.10,0.42,0.42)
			//             violet_boost(0.060,0.10,0.60)→(0.16,0.14,0.46)
			vec3 cobalt_boost = vec3(0.08, 0.16, 0.46);
			vec3 teal_boost   = vec3(0.10, 0.42, 0.42);
			vec3 violet_boost = vec3(0.16, 0.14, 0.46);
			cobalt_patch = mix(cobalt_patch, cobalt_boost, patch_boost);
			teal_patch   = mix(teal_patch,   teal_boost,   patch_boost);
			violet_patch = mix(violet_patch, violet_boost, patch_boost);
			vec3 ocean_patch = mix(cobalt_patch, teal_patch, gyre_mix);
			ocean_patch = mix(ocean_patch, violet_patch, smoothstep(0.70, 1.0, offshore_depth) * (1.0 - gyre_mix) * 0.55);
			// 旧值 / 新值：mix(0.34, 0.58, gyre_mix) → mix(0.42, 0.66, gyre_mix)
			float patch_w = open_ocean_w * water_cartoon_color_strength * mix(0.42, 0.66, gyre_mix);
			col = mix(col, ocean_patch, patch_w);
			col *= 1.0 + (gyre_mix - 0.5) * open_ocean_w * water_cartoon_color_strength * 0.18;
		}

		// ─── Deep Ocean Layered Color 整合层 ────────────────────────────
		// 在 gyre patch 之后、LAKE/REEF/KELP/ICE 特征之前叠加三层色偏。
		// 以 open_ocean_w 作 mask，浅海 / 湖 / 礁 / 藻 / 冰自然衰减至 0。
		// 叠加顺序：latitude (色温带) → current (冷暖流) → abyss (幽冷)。
		if (open_ocean_w > 0.001 && deep_ocean_color_richness > 0.001) {
			// Latitude tint：visual_quality==0 仍启用静态版本。
			vec3 lat_tint = deep_ocean_latitude_tint(lat_signed, current_temp);
			col *= mix(vec3(1.0), lat_tint, open_ocean_w);

			// Current tint：仅在 visual_quality>=1 且洋流向量足够明显时启用。
			if (visual_quality >= 1) {
				float flow_mag = length(ocean_current_v);
				if (flow_mag > 0.05) {
					vec3 cur_tint = deep_ocean_current_tint(ocean_current_v, lat_signed, flow_mag);
					col *= mix(vec3(1.0), cur_tint, open_ocean_w * ocean_current_strength);
				}
			}

			// Abyss tint：静态，所有画质等级都启用，只随 open_ocean_w 衰减。
			vec3 ab_tint = deep_ocean_abyss_tint(offshore_depth);
			col *= mix(vec3(1.0), ab_tint, open_ocean_w);

			// Clamp to avoid over-exposure after stacked multiplicative tints.
			col = clamp(col, vec3(0.0), vec3(1.6));
		}

		// (E) LAKE 特征叠加：平静、低对比、偏青绿的湖水层
		// visual_quality=0 保留色彩分层，跳过二层细节；=2 使用完整双层柔噪声。
		int water_detail_oct = (visual_quality >= 2) ? 2 : 1;
		if (w_lake > 0.001) {
			vec3 lake_cartoon = mix(lake_water_color, vec3(0.13, 0.66, 0.72), water_cartoon_color_strength * 0.55);
			vec3 lake_surface = mix(water_depth_gradient(offshore_depth * 0.72, elev), lake_cartoon, 0.66);
			float lake_depth_t = smoothstep(0.04, 0.46, depth_t);
			vec3 lake_deep = lake_cartoon * vec3(0.72, 0.90, 0.96);
			vec3 lake_col = mix(lake_surface, lake_deep, lake_depth_t * 0.42);
			float lake_ripple = fbm(wpw * 0.018 + vec2(7.0, -19.0), water_detail_oct);
			float lake_glass = 0.5;
			if (visual_quality >= 1) {
				lake_glass = fbm(wpw * 0.006 + vec2(-23.0, 11.0), water_detail_oct);
			}
			lake_col *= 1.0 + (lake_ripple - 0.5) * 0.026 + (lake_glass - 0.5) * 0.016;
			lake_col = mix(lake_col, lake_surface, 0.18);
			col = mix(col, lake_col, w_lake * 0.92);
		}

		// (F) REEF 特征叠加：浅青绿 + 大尺度珊瑚斑，保持透明清澈而非高频贴花
		if (w_reef > 0.001) {
			float reef_depth = clamp(offshore_depth * 0.36 + depth_t * 0.16, 0.0, 1.0);
			vec3 reef_lagoon = mix(vec3(0.38, 0.82, 0.78), vec3(0.32, 0.94, 0.84), water_cartoon_color_strength * 0.55);
			vec3 reef_outer = mix(water_depth_gradient(clamp(offshore_depth * 0.82, 0.0, 1.0), elev), vec3(0.14, 0.58, 0.68), 0.34);
			vec3 reef_base = mix(reef_lagoon, reef_outer, smoothstep(0.12, 0.88, reef_depth));
			float coral_soft = 0.5;
			float reef_sheen = 0.5;
			if (visual_quality >= 1) {
				float coral_spots = voronoi_cell(wpw * 0.24);
				coral_soft = smoothstep(0.04, 0.74, coral_spots);
			}
			if (visual_quality >= 2) {
				reef_sheen = fbm(wpw * 0.018 + vec2(17.0, 29.0), 2);
			}
			vec3 coral_tint = mix(vec3(0.32, 0.74, 0.67), vec3(0.22, 0.58, 0.60), smoothstep(0.30, 0.88, offshore_depth));
			vec3 reef_col = mix(reef_base * 1.035, coral_tint, coral_soft * 0.16);
			reef_col *= 1.0 + (reef_sheen - 0.5) * 0.022;
			float reef_edge_feather = mix(0.66, 0.88, 1.0 - smoothstep(0.22, 0.92, offshore_depth));
			float reef_mix_w = w_reef * reef_edge_feather;
			col = mix(col, reef_col, reef_mix_w);
		}

		// (G) KELP 特征叠加：深绿被统一水色包裹，顺洋流形成宽软带状明暗
		if (w_kelp > 0.001) {
			vec3 kelp_base = mix(water_depth_gradient(offshore_depth, elev), vec3(0.06, 0.36, 0.30), 0.62);
			vec2 oc_k = ocean_current_v;
			vec2 oc_norm = (length(oc_k) > 0.05) ? normalize(oc_k) : vec2(1.0, 0.0);
			vec2 perp_k = vec2(-oc_norm.y, oc_norm.x);
			float along_k = dot(wpw, oc_norm) * 0.030;
			float across_k = dot(wpw, perp_k) * 0.095;
			float kelp_streak = 0.5;
			if (visual_quality >= 1) {
				kelp_streak = fbm(vec2(along_k + world_time * 0.035, across_k), water_detail_oct);
			}
			float kelp_patch = fbm(wpw * 0.018 + vec2(5.0, -41.0), water_detail_oct);
			vec3 kelp_col = mix(kelp_base, vec3(0.05, 0.28, 0.23), kelp_patch * 0.26);
			kelp_col *= mix(0.94, 1.045, kelp_streak);
			col = mix(col, kelp_col, w_kelp * 0.86);
		}

		// (H) SEA_ICE 特征叠加：冷蓝白冰盖 + 低对比裂纹，跳过动态水纹语言
		if (w_ice > 0.001) {
			vec3 ice_base = mix(water_depth_gradient(offshore_depth * 0.65, elev), vec3(0.84, 0.91, 0.95), 0.82);
			float crack_factor = 0.55;
			if (visual_quality >= 1) {
				float crack = voronoi_cell(wpw * 0.34);
				crack_factor = smoothstep(0.03, 0.18, crack);
			}
			float ice_noise = fbm(wpw * 0.12 + vec2(-9.0, 31.0), water_detail_oct);
			vec3 ice_col = mix(ice_base * 0.82, ice_base * 1.04, crack_factor);
			ice_col *= mix(0.96, 1.035, ice_noise);
			col = mix(col, ice_col, w_ice * 0.94);
		}

		if (shallow_transparency_enabled && visual_quality >= 1) {
			float depth_clarity = 1.0 - smoothstep(0.28, 0.86, offshore_depth);
			float coastal_clarity = (biome == B_COAST) ? 1.0 : 0.0;
			float lake_clarity = w_lake * (1.0 - smoothstep(0.16, 0.62, depth_t));
			float reef_clarity = w_reef * 0.42;
			float kelp_guard = 1.0 - w_kelp * 0.70;
			float ice_guard = 1.0 - w_ice;
			float clarity_w = clamp(
				(coastal_clarity * 0.62 + lake_clarity * 0.46 + reef_clarity) * depth_clarity,
				0.0,
				0.72
			) * kelp_guard * ice_guard * shallow_transparency_factor;
			if (clarity_w > 0.001) {
				vec3 substrate_col = mix(color_lowland, color_beach, coastal_clarity * 0.70 + reef_clarity * 0.35);
				substrate_col = mix(substrate_col, lake_water_color * 0.78, w_lake * 0.55);
				vec3 clear_water_col = mix(col, substrate_col, 0.20 + depth_clarity * 0.18);
				clear_water_col = mix(clear_water_col, col * vec3(0.94, 1.02, 1.04), 0.35);
				col = mix(col, clear_water_col, clarity_w);
			}
		}

		// Data-driven ocean current streaks. Keep direction fixed to vector_atlas.rg;
		// avoid phase-crossfaded flow-map advection that reads as rotating swirls.
		if (ocean_current_enabled && visual_quality >= 1) {
			vec2 oc = ocean_current_v;
			float flow_mag = clamp(length(oc), 0.0, 1.0);
			vec2 oc_dir = (flow_mag > 0.035) ? normalize(oc) : normalize(wind_v + vec2(0.0001, 0.0));
			vec2 oc_side = vec2(-oc_dir.y, oc_dir.x);
			float along = dot(wp, oc_dir) * mix(0.010, 0.024, water_cartoon_color_strength) + world_time * 0.035;
			float across = dot(wp, oc_side) * mix(0.060, 0.105, water_cartoon_color_strength);
			int current_oct = (visual_quality >= 2) ? 2 : 1;
			float lane_low = fbm(vec2(along, across), current_oct);
			float lane_high = fbm(vec2(along * 2.8 + 17.0, across * 0.55 - 31.0), 1);
			float current_lane = smoothstep(0.38, 0.80, lane_low * 0.72 + lane_high * 0.28);
			float non_static = clamp(1.0 - w_ice - w_lake * 0.85, 0.0, 1.0);
			float current_w = ocean_current_strength * non_static * mix(0.48, 1.0, smoothstep(0.08, 0.74, offshore_depth));
			current_w = clamp(current_w * mix(0.45, 1.0, flow_mag), 0.0, 1.0);
			float streak_amp = ocean_current_debug ? 0.82 : mix(0.24, 0.42, water_cartoon_color_strength);
			vec3 current_tint = mix(vec3(0.78, 1.08, 1.16), vec3(0.50, 0.76, 1.25), smoothstep(0.34, 1.0, offshore_depth));
			vec3 current_shadow = mix(vec3(1.03, 0.99, 0.92), vec3(0.84, 0.94, 1.10), smoothstep(0.20, 1.0, offshore_depth));
			col *= mix(1.0, 1.0 + (current_lane - 0.50) * streak_amp, current_w);
			col *= mix(vec3(1.0), mix(current_shadow, current_tint, current_lane), current_w * 0.20);
			if (ocean_current_debug) {
				vec3 dir_tint = vec3(0.5 + oc_dir.x * 0.5, 0.5 + oc_dir.y * 0.3, 0.5 - oc_dir.x * 0.5);
				col = mix(col, dir_tint, 0.28 * ocean_current_strength * non_static);
				// Systemic Ocean Currents：上升/下沉流彩色高亮。
				// up_raw ∈ [0,1]，0.5 为中性；偏离 0.5 幅度越大越显色。
				float up_raw = texture(ocean_upwelling_tex, uv).r;
				float up_signed = up_raw * 2.0 - 1.0;            // [-1, 1]
				float up_mag = abs(up_signed);
				if (up_mag > 0.1) {
					vec3 up_color = (up_signed > 0.0)
						? vec3(1.00, 0.90, 0.15)                 // 上升：黄
						: vec3(0.62, 0.25, 0.85);                // 下沉：紫
					col = mix(col, up_color, 0.55 * up_mag * non_static);
				}
			}
		}
		float river_sdf_water = texture(scalar_atlas, uv).g;
		if (estuary_plume_strength > 0.001 && river_sdf_water > river_threshold_low * 0.58) {
			vec2 plume_vec = ocean_current_v + wind_v * 0.24;
			vec2 plume_dir = (length(plume_vec) > 0.05) ? normalize(plume_vec) : vec2(1.0, 0.0);
			vec2 plume_step = plume_dir * (1.0 / hm_resolution) * mix(3.0, 7.0, water_transition_softness);
			float tail_a = texture(scalar_atlas, clamp(uv - plume_step, vec2(0.0), vec2(1.0))).g;
			float tail_b = texture(scalar_atlas, clamp(uv - plume_step * 1.8, vec2(0.0), vec2(1.0))).g;
			float plume_src = max(river_sdf_water, max(tail_a * 0.82, tail_b * 0.62));
			float plume_noise = 0.5;
			if (visual_quality >= 1) {
				plume_noise = fbm(wpw * 0.055 + plume_dir * world_time * 0.065, water_detail_oct);
			}
			float plume = smoothstep(river_threshold_low * 0.72, river_threshold_high, plume_src);
			plume *= mix(0.88, 1.14, plume_noise);
			plume *= clamp(1.0 - w_ice - w_lake * 0.22, 0.0, 1.0);
			vec3 plume_col = mix(
				river_color * vec3(1.12, 1.10, 1.02),
				color_coast_water * vec3(0.84, 1.14, 1.20),
				smoothstep(0.12, 0.70, offshore_depth)
			);
			col = mix(col, plume_col, clamp(plume * estuary_plume_strength * 0.55, 0.0, 0.55));
		}
	}
	// Water Visual Overhaul：水体统一波浪 + 光照 + 浪花 + 焦散。
	// 全部受 water_effect_enabled 总开关控制；关掉即回退到上面的基础水体着色。
	if (is_water && water_effect_enabled) {
		// ── 0. 按水体类型确定波浪分档（需求 1.4/1.5/1.6/1.7） ────────────
		// SEA_ICE 不参与波浪；LAKE 细密小波；REEF 被礁削弱；其他海域标准幅度。
		float wave_amp_scale  = 1.0;
		float wave_freq_scale = 1.0;
		float current_align_w = 0.0;  // 波方向与洋流向量的对齐权重
		if (biome == B_LAKE) {
			wave_amp_scale = 0.22;
			wave_freq_scale = 0.82;
			current_align_w = 0.0;
		} else if (biome == B_REEF) {
			wave_amp_scale = 0.42;
			wave_freq_scale = 0.78;
			current_align_w = 0.36;
		} else if (biome == B_KELP) {
			wave_amp_scale = 0.36;
			wave_freq_scale = 0.70;
			current_align_w = 0.40;
		} else if (biome == B_OCEAN || biome == B_COAST) {
			wave_amp_scale = 0.72;
			wave_freq_scale = 0.76;
			current_align_w = 0.46;
		} else {
			// SEA_ICE 等：禁用波浪
			wave_amp_scale = 0.0;
		}
		// visual_quality==0 退化：1 分量主方向（需求 1.8）
		int wave_q = (visual_quality >= 1) ? 1 : 0;
		// 把 wp 沿洋流方向做更明显的宽尺度偏转，让波浪视觉上跟随洋流而非独立漂浮。
		vec2 wave_wp = wp;
		if (ocean_current_enabled && current_align_w > 0.001) {
			vec2 current_dir = (length(ocean_current_v) > 0.05) ? normalize(ocean_current_v) : vec2(1.0, 0.0);
			float current_push = current_align_w * mix(0.85, 1.45, ocean_current_strength);
			wave_wp = wp + current_dir * current_push + ocean_current_v * current_align_w * 0.80;
		}
		// 水面法线（供浪花近岸放大使用前先算一次）
		bool waves_on = water_waves_enabled && wave_amp_scale > 0.001;
		vec3 N_water = sample_water_normal(
			wave_wp, world_time, wave_amp_scale, wave_freq_scale, wave_q, waves_on
		);

		// ── 0.5. 海岸 SDF（在 shader 内多处用到：近岸 N 放大 / 浪花 / 透底 / 河口） ──
		float coast_sdf = abs(elev - sea_level);
		if (waves_on && coast_sdf < 0.05 && (biome == B_OCEAN || biome == B_COAST)) {
			float near_shore_boost = 1.0 + 0.12 * (1.0 - smoothstep(0.0, 0.05, coast_sdf));
			N_water.xy *= near_shore_boost;
			N_water = normalize(N_water);
		}

		// ── 1. 方向光漫反射 + Blinn-Phong 高光（需求 2.1/2.2） ───────────
		// tod_sun_dir 已在切线空间下归一化；水面法线亦 z-up。
		vec3 L = normalize(tod_sun_dir);
		vec3 V = vec3(0.0, 0.0, 1.0);
		vec3 H = normalize(L + V);
		float NdotL = max(dot(N_water, L), 0.0);
		float NdotH = max(dot(N_water, H), 0.0);
		float gloss_eff = water_gloss;
		float spec_mul = 0.72;
		if (biome == B_LAKE) {
			gloss_eff = 72.0;
			spec_mul = 0.42;
		}
		float spec_term = pow(NdotH, gloss_eff);
		float specular_strength = mix(0.50, 0.18, tod_night_factor) * spec_mul;
		vec3 specular = tod_sun_color * spec_term * specular_strength;
		col *= 1.0 + NdotL * 0.10;
		col += specular;

		// ── 2. 菲涅尔天空反射（需求 2.3/2.4） ────────────────────────
		if (water_fresnel_enabled) {
			float F;
			if (visual_quality <= 1) {
				// 低质：常量菲涅尔
				F = 0.30;
			} else {
				F = pow(1.0 - clamp(N_water.z, 0.0, 1.0), 5.0);
			}
			// sky tint：由 tod_ambient_color 派生，白天偏浅蓝，夜晚用 ambient 本身
			vec3 sky_tint = tod_ambient_color * mix(1.15, 0.70, tod_night_factor);
			col = mix(col, sky_tint, F * water_reflection_strength);
		}

		// ── 3. 海岸滚动浪花（需求 6.1/6.2/6.3/6.4） ──────────────────
		if (biome == B_COAST || biome == B_OCEAN) {
			float foam_mask_raw = 1.0 - smoothstep(0.0, 0.045, coast_sdf);
			if (foam_mask_raw > 0.001) {
				// 主浪：沿 coast_sdf 推进的滚动相位，低频慢速，避免形成密集白线。
				float local_noise = 0.5;
				float sub_wave = 0.5;
				if (visual_quality >= 1) {
					int foam_oct = (visual_quality >= 2) ? 2 : 1;
					local_noise = fbm(wp * 0.10 + vec2(world_time * 0.08, -world_time * 0.06), foam_oct);
				}
				float main_phase = coast_sdf * 130.0 - world_time * 1.10 + local_noise * 1.20;
				float main_wave = sin(main_phase) * 0.5 + 0.5;
				// 子浪只作为柔和破碎；低画质跳过子浪，保留一条柔和主浪。
				if (visual_quality >= 1) {
					float sub_phase = coast_sdf * 240.0 - world_time * 1.65 + local_noise * 0.75;
					sub_wave = sin(sub_phase) * 0.5 + 0.5;
				}
				float wave_stack = main_wave * 0.82 + sub_wave * 0.18;
				// 风速扩宽浪花带（需求 6.4）：长度 [0, 1.4]，扩宽 0~25%
				float wind_mag = clamp(length(wind_v), 0.0, 1.4);
				float wind_widen = 1.0 + wind_mag * 0.18;
				float foam_mask = 1.0 - smoothstep(0.0, 0.045 * wind_widen, coast_sdf);
				float foam = smoothstep(0.70, 0.97, wave_stack) * foam_mask * 0.28;
				float crest = smoothstep(0.93, 1.0, main_wave) * foam_mask * 0.16;
				col = mix(col, vec3(0.90, 0.95, 0.98), clamp(foam + crest, 0.0, 0.42));
			}
		}

		// ── 4. 粼光高光（保留但大幅降幅，避免与 Blinn-Phong 重复） ──────
		if (day_night_enabled && visual_quality >= 1 && water_sparkle_enabled) {
			float sparkle_freq = 0.085;
			float sparkle_speed_day = 0.32;
			int sparkle_oct = (visual_quality >= 2) ? 2 : 1;
			float sparkle = fbm(wp * sparkle_freq + vec2(world_time * sparkle_speed_day, -world_time * 0.20), sparkle_oct);
			float spark_mask = smoothstep(0.88, 0.985, sparkle);
			vec3 day_sparkle_col = vec3(1.03, 1.02, 0.96);
			vec3 night_sparkle_col = vec3(0.76, 0.86, 1.03);
			vec3 sparkle_col = mix(day_sparkle_col, night_sparkle_col, tod_night_factor);
			float base_intensity = 0.028;
			float intensity = mix(base_intensity, base_intensity * 0.45, tod_night_factor);
			float night_freq_scale = mix(1.0, 0.55, tod_night_factor);
			spark_mask *= night_freq_scale;
			col = mix(col, col * sparkle_col, spark_mask * intensity);
		}

		// ── 4.5. Water Calm Noise：大尺度低对比度柔和噪声 ─────────
		if (water_wave_line_strength > 0.001 && waves_on && visual_quality >= 1) {
			// biome 幅度调制：湖泊略弱、海藻很弱、海冰不叠加动态柔噪声。
			float calm_amp_mul = 1.0;
			if (biome == B_LAKE) {
				calm_amp_mul = 0.65;
			} else if (biome == B_KELP) {
				calm_amp_mul = 0.28;
			} else if (biome == B_SEA_ICE) {
				calm_amp_mul = 0.0;
			}
			float calm = water_calm_brightness(wave_wp, world_time);
			float bright_amp = water_wave_line_strength
					* water_calm_noise_brightness * calm_amp_mul;
			col *= mix(1.0, 1.0 + calm * 0.045, clamp(bright_amp, 0.0, 1.0));

			// 色相扰动层（默认约 ±1%，visual_quality >= 1 才启用；>=2 提升 octaves）
			int tint_oct = (visual_quality >= 2) ? 3 : 2;
			float tint_mix = water_calm_tint(wave_wp, world_time, tint_oct);
			vec3 TINT_COLD = vec3(0.97, 0.99, 1.03);
			vec3 TINT_WARM = vec3(1.03, 1.015, 0.97);
			vec3 tint = mix(TINT_COLD, TINT_WARM, tint_mix);
			float tint_amp = water_wave_line_strength
					* water_calm_noise_tint_strength * calm_amp_mul;
			col *= mix(vec3(1.0), tint, 0.035 * clamp(tint_amp, 0.0, 1.0));
		}
		// ── 5. 珊瑚礁焦散（需求 5.1/5.2） ────────────────────────────
		if (biome == B_REEF && caustics_enabled && visual_quality >= 1
				&& day_night_enabled && tod_night_factor < 0.5) {
			int caustics_oct = (visual_quality >= 2) ? 2 : 1;
			float caustics = fbm(wp * 0.35 + vec2(world_time * 0.08, -world_time * 0.12), caustics_oct);
			float caustics_mask = smoothstep(0.55, 0.75, caustics);
			float day_factor = 1.0 - tod_night_factor;
			vec3 caustic_col = tod_sun_color * 1.15;
			col = mix(col, col + caustic_col * 0.35, caustics_mask * caustics_strength * day_factor);
		}

		if (shallow_transparency_enabled && visual_quality >= 1) {
			float coast_clear = 0.0;
			if (biome == B_COAST || biome == B_LAKE || biome == B_REEF) {
				coast_clear = 1.0 - smoothstep(0.0, 0.035, coast_sdf);
			}
			if (coast_clear > 0.001) {
				vec3 clarity_tint = col * vec3(0.96, 1.02, 1.05);
				col = mix(col, clarity_tint, coast_clear * shallow_transparency_factor * 0.18);
			}
		}

		// ── 7. BLIZZARD 薄冰（保留原 Pass2 行为） ─────────────────────
		if (extreme_weather_ground_effect_enabled && weather_front_count > 0) {
			float ice_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
			if (ice_mask > 0.001) {
				vec3 thin_ice = vec3(0.82, 0.88, 0.92);
				col = mix(col, thin_ice, clamp(ice_mask * 0.70, 0.0, 0.70));
			}
		}
	}

	// 5. 河流（仅陆地；流量驱动宽度）
	if (!is_water) {
		// 河岸边缘使用更宽、更低频的扰动，避免细河变成锯齿噪声线。
		// visual_quality=0 直接读 atlas，跳过 2 次 fbm 河岸扰动以保留性能。
		vec2 river_edge_warp = vec2(0.0);
		if (visual_quality >= 1) {
			river_edge_warp = vec2(
				fbm(wp * 0.075 + vec2(7.0, -3.0), 1),
				fbm(wp * 0.075 + vec2(-11.0, 5.0), 1)
			) - 0.5;
		}
		float flow = texture(scalar_atlas, uv + river_edge_warp * 0.0024).g;
		float river_t_raw = smoothstep(river_threshold_low, river_threshold_high, flow);
		float river_t = river_t_raw;
		float outline_t = smoothstep(river_threshold_low * 0.78, river_threshold_low, flow)
				* (1.0 - smoothstep(river_threshold_high, min(river_threshold_high + 0.22, 1.0), flow));
		if (river_t > 0.001 && river_flow_enabled && river_flow_speed > 0.001 && visual_quality >= 1) {
			float pulse = 1.0 + 0.055 * sin(dot(wp, vec2(0.35, 0.42)) - world_time * 0.55);
			river_t = clamp(river_t * pulse, 0.0, 1.0);
		}
		float river_depth_w = smoothstep(0.18, 1.0, river_t_raw);
		vec3 river_surface = mix(river_color * vec3(1.10, 1.08, 1.02), color_mid_ocean, 0.18);
		vec3 river_deep = mix(river_color * vec3(0.72, 0.84, 0.98), color_deep_ocean, 0.20);
		vec3 river_body = mix(river_surface, river_deep, river_depth_w * 0.42);
		vec3 river_edge_col = mix(river_outline_color, river_color * vec3(0.82, 0.95, 1.05), 0.32);
		col = mix(col, river_edge_col, outline_t * 0.50 * river_strength);
		col = mix(col, river_body, river_t * river_strength);

		// Water Visual Overhaul：河流顺坡流动明暗。宽软条纹沿下游方向移动，避免小河被高频噪声吞掉。
		if (river_t > 0.001
				&& river_flow_enabled
				&& river_flow_speed > 0.001
				&& visual_quality >= 1) {
			vec2 texel = 1.0 / hm_resolution;
			float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
			float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
			float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
			float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
			vec2 grad = vec2(hr - hl, hd - hu);
			float slope_mag = length(grad);
			if (slope_mag > 0.002) {
				vec2 fbm_smooth = vec2(
					fbm(wp * 0.045, 1) - 0.5,
					fbm(wp * 0.045 + vec2(21.0, -13.0), 1) - 0.5
				) * 0.11;
				vec2 flow_dir = normalize(-grad + fbm_smooth);
				vec2 flow_perp = vec2(-flow_dir.y, flow_dir.x);
				float along = dot(wp, flow_dir) * river_flow_freq;
				float across = dot(wp, flow_perp) * river_flow_freq * 0.42;
				vec2 flow_uv = vec2(along + world_time * river_flow_speed * 0.42, across);
				int river_flow_oct = (visual_quality >= 2) ? 2 : 1;
				float flow_streak = fbm(flow_uv, river_flow_oct);
				vec3 flow_tint = river_body * mix(0.92, 1.09, flow_streak);
				col = mix(col, flow_tint, river_t * river_strength * 0.28);
			}
		}
	}

	// 6. 海岸 / 湖岸 / 河口柔和过渡
	// 旧逻辑只按 abs(elev - sea_level) 画细线，容易在山地、雪地或森林旁形成硬亮边。
	// 这里结合邻域水陆接触、海拔带宽和河流流量，让岸线成为一条柔和浅色过渡带。
	vec2 shore_texel = 1.0 / hm_resolution;
	float nearby_water_cnt = 0.0;
	float nearby_land_cnt = 0.0;
	float nearby_lake_cnt = 0.0;
	float nearby_ocean_cnt = 0.0;
	float shore_sample_cnt = 0.0;
	for (int sy = -1; sy <= 1; sy++) {
		for (int sx = -1; sx <= 1; sx++) {
			if (sx == 0 && sy == 0) {
				continue;
			}
			bool is_diag_shore_sample = (sx != 0) && (sy != 0);
			if (visual_quality <= 0 && is_diag_shore_sample) {
				continue;
			}
			vec2 suv = clamp(uv + vec2(float(sx), float(sy)) * shore_texel, vec2(0.0), vec2(1.0));
			int sb = int(texture(enum_atlas, suv).r * 255.0 + 0.5);
			bool sw = (sb == B_OCEAN) || (sb == B_COAST) || (sb == B_LAKE)
					|| (sb == B_REEF) || (sb == B_KELP) || (sb == B_SEA_ICE);
			nearby_water_cnt += sw ? 1.0 : 0.0;
			nearby_land_cnt += sw ? 0.0 : 1.0;
			nearby_lake_cnt += (sb == B_LAKE) ? 1.0 : 0.0;
			nearby_ocean_cnt += ((sb == B_OCEAN) || (sb == B_COAST) || (sb == B_REEF) || (sb == B_KELP)) ? 1.0 : 0.0;
			shore_sample_cnt += 1.0;
		}
	}
	float shore_inv = 1.0 / max(shore_sample_cnt, 1.0);
	float shore_contact = is_water ? (nearby_land_cnt * shore_inv) : (nearby_water_cnt * shore_inv);
	float shore_w = smoothstep(0.06, 0.42, shore_contact);
	float sea_band = 1.0 - smoothstep(0.0, is_water ? 0.065 : 0.040, abs(elev - sea_level));
	float lake_side_w = smoothstep(0.08, 0.42, nearby_lake_cnt * shore_inv);
	float ocean_side_w = smoothstep(0.08, 0.42, nearby_ocean_cnt * shore_inv);
	float estuary_flow = 0.0;
	if (!is_water) {
		estuary_flow = smoothstep(river_threshold_low * 0.90, river_threshold_high, scals.g) * ocean_side_w;
	}
	float coast_t = clamp(max(sea_band * 0.55, shore_w * 0.72) + estuary_flow * 0.30, 0.0, 1.0);
	vec3 ocean_halo = mix(coast_halo_color, color_beach * vec3(0.82, 0.92, 1.02), 0.36);
	vec3 lake_halo = mix(coast_halo_color * vec3(0.84, 1.05, 1.12), lake_water_color * vec3(1.06, 1.08, 1.03), 0.40);
	vec3 estuary_halo = mix(river_color, color_coast_water, 0.58) * vec3(0.96, 1.03, 1.06);
	vec3 shore_halo = mix(ocean_halo, lake_halo, lake_side_w * (1.0 - ocean_side_w * 0.45));
	shore_halo = mix(shore_halo, estuary_halo, estuary_flow * 0.55);
	float halo_strength = coast_halo_strength * mix(0.34, 0.62, shore_w) * (is_water ? 0.86 : 1.0);
	col = mix(col, shore_halo, coast_t * halo_strength);

	// 7. 可选等高线（陆地）
	if (contour_enabled && !is_water) {
		float contour_phase = fract(elev / max(contour_step, 0.001));
		float dist = abs(contour_phase - 0.5);
		float contour_t = smoothstep(0.50, 0.42, dist);
		col = mix(col, contour_color, contour_t * contour_strength);
	}

	// 7.5. Phase 1：动态雪盖（季节性）— 放在 hillshade 之后让雪本身带阴影
	if (!is_water) {
		float snow_factor = compute_snow_factor(biome, current_temp, elev, is_water) * dynamic_snow_strength;
		// 雪本身轻微随地形噪声打散（避免铺满死板）
		float snow_noise = fbm(wp * 0.18 + vec2(63.0, -29.0), 1);
		snow_factor *= mix(0.85, 1.10, snow_noise);
		snow_factor = clamp(snow_factor, 0.0, 1.0);
		vec3 snow_color = vec3(0.94, 0.95, 0.97);
		col = mix(col, snow_color, snow_factor);
	}

	// 7.55. 任务 6：BLIZZARD 积雪增强（在季节雪盖之后叠加，暴风雪区域更白）
	if (extreme_weather_ground_effect_enabled
			&& !is_water
			&& weather_front_count > 0) {
		float blizz_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
		if (blizz_mask > 0.001) {
			// 坡度权重：陡坡雪积不住（坡度大 → 权重低）
			vec2 texel = 1.0 / hm_resolution;
			float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
			float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
			float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
			float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
			float slope_mag = length(vec2(hr - hl, hd - hu)) * hillshade_slope_gain;
			float slope_w = 1.0 - smoothstep(0.35, 0.85, slope_mag);  // 陡坡 → 0.15，平地 → 1.0
			// 植被权重：密林（TAIGA/DECIDUOUS/CONIFER/RAINFOREST）内部树冠遮雪 → 权重压到 0.35
			float veg_w = 1.0;
			if (veg == V_TAIGA
					|| veg == V_TEMPERATE_DECIDUOUS
					|| veg == V_TEMPERATE_CONIFER
					|| veg == V_TROPICAL_RAINFOREST
					|| veg == V_SUBTROPICAL_FOREST) {
				veg_w = 0.35;
			} else if (veg == V_BOREAL_SHRUB
					|| veg == V_MEDITERRANEAN_SHRUB
					|| veg == V_TROPICAL_DRY_FOREST) {
				veg_w = 0.65;
			}
			float w = blizz_mask * slope_w * veg_w;
			vec3 fresh_snow = vec3(0.97, 0.98, 1.00);
			col = mix(col, fresh_snow, clamp(w, 0.0, 0.92));
		}
	}

	// 7.6. Milestone 2：覆盖物轴叠加（FLOODING / PERMAFROST / GLACIER）
	// SNOW / SEA_ICE 已被 dynamic_snow / biome 主路径处理，函数内返回 0 跳过。
	if (cover_axis_strength > 0.001) {
		vec4 ov = cover_overlay(cover);
		if (ov.a > 0.001) {
			// FLOODING 仅在陆地上有意义；PERMAFROST / GLACIER 同理
			if (!is_water) {
				col = mix(col, ov.rgb, ov.a * cover_axis_strength);
			}
		}
	}

	// 7.65. Milestone 3 (split)：地形 shader 只处理 DROUGHT/HEATWAVE 的 multiplicative 调色
	// 其他 weather 类型（RAIN/STORM/FOG/BLIZZARD/MONSOON）由 WeatherLayer 独立渲染。
	if (weather_front_count > 0 && weather_strength > 0.001) {
		vec4 wov = sample_terrain_weather_tint(wp);
		float wa = wov.a;
		if (wa > 0.001) {
			col = mix(col, col * wov.rgb, clamp(wa, 0.0, 0.85));
			// HEATWAVE 加热气扭曲（用 wov.rgb.g > 0.95 区分 HEATWAVE 与 DROUGHT）
			if (wov.rgb.g > 0.95) {
				float heat = fbm(wp * 0.30 + vec2(0.0, world_time * 1.2), 1);
				col *= 1.0 + (heat - 0.5) * 0.10 * wa;
			}
		}
	}

	// 7.66. 任务 6：DROUGHT 裂地叠加（在 multiplicative 调色之后做纹理叠加）
	// 与季节性 DROUGHT 调色互补：调色让整块地变枯黄，这里再叠
	if (extreme_weather_ground_effect_enabled
			&& !is_water
			&& weather_front_count > 0) {
		float drought_mask = compute_extreme_weather_mask(wp, WT_DROUGHT);
		if (drought_mask > 0.001) {
			// voronoi 边缘：cell 中心距离 → 网格线（越接近 cell 边界值越小）
			float crack = voronoi_cell(wp * 0.42);
			float crack_factor = smoothstep(0.0, 0.12, crack);  // 边界处 = 0（深色裂缝）
			vec3 crack_color = vec3(0.38, 0.28, 0.20);
			col = mix(col, crack_color, drought_mask * (1.0 - crack_factor) * 0.55);
			// 叠加一层低频土黄 tint，增强"裂地底色"
			vec3 dry_earth = vec3(0.80, 0.70, 0.48);
			col = mix(col, col * dry_earth, drought_mask * 0.30);
		}
	}

	// vol_intensity 已在 fragment 顶部从 scalar_atlas.a 解出
	float vol_intensity = vol_intensity_atlas;
	if (vol_intensity > 0.01) {
		vec3 lava_color = vec3(1.10, 0.45, 0.20);
		col = mix(col, col * lava_color, vol_intensity * 0.55);
		float core = smoothstep(0.55, 0.95, vol_intensity);
		col = mix(col, vec3(1.0, 0.78, 0.30), core * 0.55);
		// 烟柱 anchor 在火山中心；用 vol_intensity 当 mask
		float plume_mask = smoothstep(0.10, 0.55, vol_intensity);
		float plume_y = wp.y + world_time * 6.0;
		float plume = fbm(vec2(wp.x * 0.40, plume_y * 0.18), 3);
		float plume_factor = smoothstep(0.55, 0.85, plume) * plume_mask;
		col = mix(col, vec3(0.55, 0.50, 0.48), plume_factor * 0.65);
	}

	// 8. 羊皮纸 + paper grain
	col = mix(col, col * parchment_tint, parchment_strength);
	// v9.fbm-opt：paper_grain_strength 通常 < 0.10，单 octave 已足够，肉眼不可分辨
	float grain = fbm(wp * 0.45 + vec2(91.0, -7.0), 1);
	col *= mix(1.0 - paper_grain_strength, 1.0 + paper_grain_strength, grain);

	// 9. 任务 3：风格化 PBR 昼夜着色（在羊皮纸之后，保证 tint 不被羊皮纸抹掉）
	// day_night_enabled=false 时完全短路，回退到原有着色路径（需求 6.2）。
	if (day_night_enabled) {
		// Pass 2（任务 3）：陆地走 TOD 驱动的 PBR（Sobel 法线 + NdotL + NdotH + tonemap）。
		if (is_water) {
			// 水面只需要一个柔和的环境/日光 tint，避免与粼光叠加过亮
			col = col * (tod_ambient_color * 0.6 + tod_sun_color * 0.4);
			col *= mix(1.0, 0.55, tod_night_factor);
			col *= tod_exposure;
		} else {
			col = apply_tod_pbr(col, uv, biome, visual_quality);
		}
	}

	float alpha = 1.0;
	if (season_transition_overlay) {
		float dissolve_noise = fbm(wp * 0.035 + vec2(17.0, -43.0), 2);
		float edge = clamp(season_transition_progress, 0.0, 1.0);
		float soft = max(season_transition_softness, 0.001);
		float threshold = 1.0 - edge;
		alpha = 1.0 - smoothstep(threshold - soft, threshold + soft, dissolve_noise);
		alpha *= 1.0 - smoothstep(0.88, 1.0, edge);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
}
