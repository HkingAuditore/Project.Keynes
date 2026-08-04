shader_type canvas_item;
// [pk-web-texture-budget] 同 world_map.gdshader：不依赖引擎 Light2D，补 unshaded
// 省掉隐式受光路径的纹理单元。
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// weather_overlay.gdshader — 天气云 overlay（2026-06-19 精简重写）
//
// 单数据通路：weather_lut（per-cell 天气场 LUT，由 encode_cell_luts 产出；经
//             map_index_atlas.GB 的 cell.index 间接寻址逐格采样，见 sample_field_weather）。
// 单噪声系统：解析梯度噪声（Perlin-like，quintic 插值），无任何纹理噪声依赖。
// 三层云：cumulus（中层主云）/ cirrus（高层卷云）/ fog（低层山雾）。
// 降水：按天气类型 profile flag 叠加（闪电已移除）。
// 唯一的 filter_nearest 采样是 map_index_atlas（biome），仅用于 is_water 与低雾山地权重。
// ════════════════════════════════════════════════════════════════════════

// cell-index 间接寻址（cloud-from-field 2026-06-20）：per-cell 天气场 LUT。
//   R=weather_type, G=intensity, B=cloud, A=vapor（与 encode_cell_luts 同布局）。
//   decode_cell_index(uv) 用 map_index_atlas.GB 取 cell.index，再 cell_lut_uv 采样本格天气。
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut_prev : filter_nearest, repeat_disable;  // 上一仿真帧 LUT(帧间插值减两次更新间横跳)
uniform float weather_lerp : hint_range(0.0, 1.0) = 1.0;              // 0=prev 1=curr,两次仿真更新之间随时间推进
uniform vec2 lut_dims = vec2(0.0);
// 视野门控：enum_lut.a = 迷雾知识度 k。已探索但当前看不见的地方不该显示实时天气
// ——「你记得这里的地形，但不知道今天下不下雨」这个信号比灰化本身更能说明问题。
// fog_mask_enabled 关闭时整个分支被 uniform 条件跳过，不产生额外采样。
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform bool fog_mask_enabled = false;
uniform bool has_terrain_edge_data = false;
uniform float terrain_ecotone_width : hint_range(0.0, 0.96) = 0.84;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform float world_time = 0.0;
// 一个 hex 的“直径”（wp 单位）。邻域采样偏移按它物理换算，避免与 map_index_atlas
// 的 hex 像素尺度发生频率共振导致六边形晶格。
uniform float hex_world_diameter = 38.0;
// 云下假阴影沿背光方向的投影偏移（hex 直径倍数）。太阳越低偏移越长 → 悬浮感越强。
uniform float cloud_shadow_offset : hint_range(0.0, 3.0) = 1.15;

// 昼夜（TOD）：方向光色 / 环境光色 / 晨昏全部走 earth_daylight 唯一真源（见下方 include），
// 不再由 GDScript 推单一 tod_sun_color/tod_ambient_color/tod_night_factor（那会让全图云统一明暗、
// 与逐像素晨昏线的地面/水面/植被对不上）。此处仅保留：总开关、迎光屏幕方向（earth_daylight 不给
// 2D 方向，云体积梯度需要它）、全局曝光、云染色开关。
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale : hint_range(0.2, 1.5) = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure : hint_range(0.2, 2.5) = 1.0;
uniform bool cloud_tod_tint_enabled = true;

// [cylindrical-earth-daylight] 逐像素经纬度晨昏线唯一真源（与地形 brdf / 水面 / 植被同 include）。
// earth_daylight 要求 caller 在 include 前声明下列同名 uniform（默认值同 uniforms.gdshaderinc，
// 保证 GDScript 尚未推入时退化为“正午永昼”而非黑屏）。
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
#include "res://shaders/include/earth_daylight.gdshaderinc"

// 全局
uniform int weather_overlay_quality : hint_range(0, 2) = 2;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;

// 天气数据源：weather_lut（per-cell LUT，见 sample_field_weather）。旧 weather_front_* uniform 已删。

// 天气类型表。
const int MAX_WEATHER_TYPES = 8;
uniform vec4 weather_profile_colors[MAX_WEATHER_TYPES];

const int WT_CLEAR = 0;
const int WT_RAIN = 1;
const int WT_STORM = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT = 4;
const int WT_FOG = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON = 7;

const int B_OCEAN = 0;
const int B_COAST = 1;
const int B_HILL = 5;
const int B_MOUNTAIN = 6;
const int B_LAKE = 18;
const int B_REEF = 19;
const int B_SEA_ICE = 20;
const int B_KELP = 21;

varying vec2 v_world;

float wx_wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 wx_wrap_world_pos(vec2 wp) {
	return vec2(wx_wrap_world_x(wp.x), wp.y);
}

vec2 wx_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wx_wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

float wx_cloud_seam_weight(vec2 wp) {
	if (wrap_period_x <= 0.0001) {
		return 0.0;
	}
	vec2 wwp = wx_wrap_world_pos(wp);
	float seam_width = min(max(hex_world_diameter * 3.0, 1.0), wrap_period_x * 0.25);
	float seam_x = wrap_origin_x + wrap_period_x;
	float dist_to_right = clamp(seam_x - wwp.x, 0.0, seam_width);
	return 1.0 - smoothstep(0.0, seam_width, dist_to_right);
}

vec2 wx_cloud_seam_partner(vec2 wp) {
	return wx_wrap_world_pos(wp) - vec2(wrap_period_x, 0.0);
}

int effective_weather_quality() {
#if defined(MOBILE_QUALITY_LOW)
	return 0;
#elif defined(MOBILE_QUALITY_MID)
	return 0;
#elif defined(MOBILE_QUALITY_HIGH)
	return 0;
#else
	return weather_overlay_quality;
#endif
}

// 廉价算术 hash（非纹理）——仅用于低雾 mountain_w 的邻域抖动，破除六边形对称。
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float hash_signed(vec2 p) {
	return hash21(p) - 0.5;
}

// ── 解析梯度噪声（Perlin，quintic）：云形唯一来源，平滑、无纹理网格 ──
// cloud_hash22 / cloud_grad_noise / cloud_fbm / cloud_fbm_evolve 已抽到共享
// include，与 fog_of_war.gdshader 共用同一份实现。
#include "res://shaders/include/cloud_noise.gdshaderinc"

// ── 云密度主函数：软轮廓 + 清晰核心 + 时间扰动细节（cumulus / 雾 / front 共用）──
// p：世界坐标（调用方已做风向 advection）。coverage：该点语义云量 [0,1]。seed：错开不同 front。
// 低频层负责大团柔和边缘；中高频只在云核逐步增强，让内部纹理清楚但边缘仍羽化。
float cloud_density_soft(vec2 p, float coverage, float seed) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	int q = effective_weather_quality();
	float t = world_time;

	float cloud_mask = smoothstep(0.025, 0.18, coverage);
	float amount = smoothstep(0.04, 0.3, coverage);

#if defined(PK_MOBILE_ANY)
	float low_pulse = 0.92 + 0.08 * sin(t * 0.09 + seed * 1.7);
	return clamp(cloud_mask * mix(0.22, 0.58, amount) * low_pulse, 0.0, 1.0);
#else

	// Classic fBM cloud stack:
	// 1) low-frequency fBM gives continuous cloud texture;
	// 2) domain warp breaks circular/noisy repetition;
	// 3) billow/detail fBM adds puffy internal contrast;
	// 4) coverage remap controls how much texture survives.
	vec2 warp = vec2(0.0);
#if !defined(PK_MOBILE_HIGH_SLIM)
	if (q >= 2) {
		vec2 warp_p = p * 0.0012 + vec2(seed * 0.23, -seed * 0.17);
		float wa = cloud_fbm_evolve(warp_p + vec2(13.7, 2.9), 2, t * 0.10);
		float wb = cloud_fbm_evolve(warp_p + vec2(-5.4, 19.1), 2, -t * 0.09);
		warp = (vec2(wa, wb) - vec2(0.5)) * mix(0.32, 0.78, amount);
	}
#endif

	// 噪声相位必须只由世界坐标/时间/seed 决定，不能由 coverage 决定；否则每次 weather_lut 刷新云量变化时，噪声坐标也会跳。
	vec2 base_p = p * 0.0038 + warp + vec2(seed * 0.37, seed * 0.61);
	int body_oct = (q >= 1) ? 4 : 3;
	float body_noise = cloud_fbm_evolve(base_p, body_oct, t * 0.16);
	float detail_noise = cloud_fbm_evolve(base_p * 2.35 + vec2(11.7, 4.2), (q >= 1) ? 3 : 2, t * 0.34);
	float billow = 1.0 - abs(detail_noise * 2.0 - 1.0);
	float fine_noise = (q >= 2)
		? cloud_fbm_evolve(base_p * 5.10 + vec2(-21.3, 15.8), 2, t * 0.58)
		: detail_noise;
	float shape = clamp(body_noise * 0.68 + billow * 0.20 + fine_noise * 0.12, 0.0, 1.0);

	// coverage=1 时保留连续 fBM 纹理，不再用高阈值把云挖成孤岛；
	// coverage 较低时才提高 cutoff，形成云边界退缩。
	float coverage_cut = mix(0.66, 0.26, amount);
	float density = clamp((shape - coverage_cut) / max(1.0 - coverage_cut, 0.001), 0.0, 1.0);
	float soft_texture = smoothstep(0.05, 0.88, density);
	float cloud_core = smoothstep(0.66, 1.00, density);
	float texture_cloud = clamp(soft_texture * 0.82 + cloud_core * 0.08, 0.0, 1.0);
	float opacity = mix(0.38, 0.82, amount);
	return clamp(texture_cloud * cloud_mask * opacity, 0.0, 1.0);
#endif
}

struct CloudLayerSample {
	float density;
	float edge;
	float coverage;
	float height_bias;
};

CloudLayerSample make_cloud_layer(float density, float edge, float coverage, float height_bias) {
	CloudLayerSample s;
	s.density = clamp(density, 0.0, 1.0);
	s.edge = clamp(edge, 0.0, 1.0);
	s.coverage = clamp(coverage, 0.0, 1.0);
	s.height_bias = clamp(height_bias, 0.0, 1.0);
	return s;
}

CloudLayerSample empty_cloud_layer() {
	return make_cloud_layer(0.0, 0.0, 0.0, 0.0);
}

float remap_cloud_density(float shape, float coverage, float core_boost) {
	float cover_gate = smoothstep(0.02, 0.18, coverage);
	float d = clamp(shape * cover_gate, 0.0, 1.0);
	float core = d * d;
	float contrast = smoothstep(0.08, 0.88, d);
	return clamp(mix(d * 0.74, contrast, 0.42) + core * core_boost * 0.58, 0.0, 1.0);
}

// 中云 advection 世界坐标（风向漂移 + 侧向翻卷）。抽出以便云影/光照梯度复用同一坐标系，
// 避免与 sample_cumulus_layer 内联公式漂移。
vec2 cumulus_advect(vec2 wp, vec2 axis) {
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	return wp - dir * t * 1.45 + side * sin(t * 0.19 + dot(wp, dir) * 0.0022) * hex_world_diameter * 0.22;
}

float cloud_density_alpha(float density) {
	// 可见度与遮挡度解耦：薄云更早显形，厚云不再把 alpha 顶满挡住地块。
	float soft = smoothstep(0.020, 0.56, density);
	float core = smoothstep(0.54, 1.00, density);
	return clamp(pow(soft, 0.90) * 0.54 + core * 0.16, 0.0, 0.70);
}

// billboard 白云着色：以亮白为主，迎太阳侧更亮、背光侧 / 厚核略压暗形成体积感，薄边银边。
// 光照走 earth_daylight：sun_col（晨昏暖橙↔正午暖白）、amb_col（夜冷蓝↔昼天空）、local_day（夜=0）。
// 方向光乘 local_day → 夜侧无阳照（与 brdf.make_lighting_context 同源），云的明暗随晨昏线扫过。
vec3 compute_cloud_lighting(CloudLayerSample layer, vec3 base_tint, int wt, float light_grad, float thickness, float silver_gain, vec3 sun_col, vec3 amb_col, float local_day) {
	if (!cloud_tod_tint_enabled) {
		return base_tint;
	}
	float d = layer.density;
	float thick = clamp(thickness, 0.0, 1.0);
	float sun_facing = smoothstep(-0.52, 0.55, light_grad);
	float shade = mix(0.72, 1.02, sun_facing);  // 背光侧柔和压暗、迎光侧略抬亮
	shade *= mix(1.0, 0.86, d * 0.46);           // 厚核轻压暗，出体积感
	shade *= mix(1.0, 0.74, thick * (1.0 - sun_facing) * 0.72); // 假厚度背光自阴影
	float rim = layer.edge * silver_gain * (0.38 + 0.68 * sun_facing) * mix(1.0, 0.72, thick);
	vec3 sun_c = sun_col * local_day;            // 夜侧 local_day=0 → 无方向光
	float amb_w = mix(0.18, 0.31, local_day);
	vec3 col = base_tint * (amb_col * amb_w + sun_c * (shade * 0.84 + rim * 0.42));
	col = mix(col, col * vec3(0.72, 0.75, 0.84), thick * (1.0 - sun_facing) * 0.20);
	// 云层光照不按天气类型染色/压暗，保证同云量同显示。
	// 夜侧地板由环境光（夜冷蓝）决定，不再用裸常数 → 与地面夜色同冷调。
	return max(col * tod_exposure, amb_col * mix(0.17, 0.27, local_day));
}

vec4 apply_cloud_layer(vec3 base_col, float base_alpha, CloudLayerSample layer, vec3 layer_col, float alpha_scale, float occlusion) {
	float density = layer.density;
	float shaded_density = density * (1.0 - clamp(occlusion, 0.0, 1.0) * 0.28);
	float layer_alpha = clamp(cloud_density_alpha(shaded_density) * alpha_scale * weather_strength, 0.0, 0.96);
	vec3 density_col = layer_col * mix(1.08, 0.90, density);
	float blend_w = clamp(layer_alpha * (0.60 + layer.edge * 0.20 + density * 0.30), 0.0, 1.0);
	vec3 col = mix(base_col, density_col, blend_w);
	float alpha = clamp(base_alpha + layer_alpha * (1.0 - base_alpha * 0.22), 0.0, 0.97);
	return vec4(col, alpha);
}

// ── 三层云采样 ──

// 高云（卷云）：各向异性拉丝薄纱，沿风向延展。
float sample_high_cloud_raw(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	float u = dot(wp, dir);
	float v = dot(wp, side);
	vec2 sp = vec2(u * 0.004 + t * 0.9, v * 0.012);
	int q = effective_weather_quality();
	float band = cloud_fbm(sp, (q >= 2) ? 3 : 2);
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	if (q >= 2) {
		float fiber = cloud_fbm(sp * 2.3 + vec2(11.0, -5.0), 1);
		streak *= 0.76 + 0.24 * smoothstep(0.40, 0.80, fiber);
	}
	return clamp(streak * coverage, 0.0, 1.0);
}

float sample_high_cloud(vec2 wp, vec2 axis, float coverage) {
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = sample_high_cloud_raw(primary_wp, axis, coverage);
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, sample_high_cloud_raw(wx_cloud_seam_partner(primary_wp), axis, coverage), seam_w);
}


// 低云 / 山雾：贴地、慢漂，biome_weight（山地权重）调制可见度。
float sample_low_fog_raw(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	if (biome_weight <= 0.001 || intensity <= 0.001) {
		return 0.0;
	}
	float t = world_time;
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 cp = wp - dir * t * 0.8;
	float fog = cloud_density_soft(cp, clamp(intensity + 0.12, 0.0, 1.0), 53.0);
	return clamp(fog * intensity * biome_weight, 0.0, 1.0);
}

float sample_low_fog(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = sample_low_fog_raw(primary_wp, axis, intensity, biome_weight);
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, sample_low_fog_raw(wx_cloud_seam_partner(primary_wp), axis, intensity, biome_weight), seam_w);
}

float sample_cumulus_density(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = cloud_density_soft(cumulus_advect(primary_wp, axis), coverage, 13.0);
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, cloud_density_soft(cumulus_advect(wx_cloud_seam_partner(primary_wp), axis), coverage, 13.0), seam_w);
}

// 中云（积云）：视觉主角，跟风漂移、内部持续翻卷。coverage 已是语义云量，单次取密度。
CloudLayerSample sample_cumulus_layer(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return empty_cloud_layer();
	}
	float density = sample_cumulus_density(wp, axis, coverage);
	float feather = smoothstep(0.025, 0.30, density) * (1.0 - smoothstep(0.50, 0.86, density));
	float rim = smoothstep(0.10, 0.46, density) * (1.0 - smoothstep(0.58, 0.98, density));
	float edge = clamp(feather * 0.72 + rim * 0.42, 0.0, 1.0);
	return make_cloud_layer(density, edge, coverage, 0.55);
}

// ── 逐格天气场采样结果（结构沿用旧名 FrontField，现由 weather_lut 填充）──
struct FrontField {
	vec3 color;
	float alpha;
	float intensity;
	float cloud;
	float precip;
	float shadow;
	float edge;
	int type;
	vec2 axis;
};

FrontField empty_field() {
	FrontField f;
	f.color = vec3(0.0);
	f.alpha = 0.0;
	f.intensity = 0.0;
	f.cloud = 0.0;
	f.precip = 0.0;
	f.shadow = 0.0;
	f.edge = 0.0;
	f.type = WT_CLEAR;
	f.axis = vec2(1.0, 0.0);
	return f;
}

float precip_cloud_bias(float precip) {
	// 用连续降水量替代离散 weather_type 增强云量，避免类型跳变造成云层频闪。
	float p = smoothstep(0.04, 0.72, precip);
	return mix(1.0, 1.06, p);
}

float precip_cloud_opacity_bias(float precip) {
	float p = smoothstep(0.04, 0.72, precip);
	return mix(1.0, 1.04, p);
}


// front_axis / front_ellipse_distance / visual_weather_intensity 已随 sample_fronts 一并删除。

// ── cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免引入 dyn/eco LUT 依赖）──
int wx_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(wx_wrap_uv(uv)).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}
vec2 wx_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

int wx_decode_edge_secondary(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(wx_wrap_uv(uv)).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

float wx_bayer2_digit(vec2 bit_xy) {
	if (bit_xy.y < 0.5) {
		return (bit_xy.x < 0.5) ? 0.0 : 2.0;
	}
	return (bit_xy.x < 0.5) ? 3.0 : 1.0;
}

const float WX_DITHER_THRESHOLD_MARGIN = 0.18;

float wx_mobile_dither_uv_threshold(vec2 uv, vec2 wp) {
	vec2 atlas_dims = visual_static_texture_size();
	vec2 pixel_xy = floor(wx_wrap_uv(uv) * atlas_dims);
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float period_px = max(
				8.0,
				round((atlas_dims.x * wrap_period_x / world_size.x) / 8.0) * 8.0);
		float phase = (wx_wrap_world_x(wp.x) - wrap_origin_x) / wrap_period_x;
		pixel_xy.x = floor(fract(phase) * period_px);
	}
	vec2 p = mod(pixel_xy, 8.0);
	float value = 16.0 * wx_bayer2_digit(mod(p, 2.0))
			+ 4.0 * wx_bayer2_digit(mod(floor(p * 0.5), 2.0))
			+ wx_bayer2_digit(floor(p * 0.25));
	float raw_threshold = (value + 0.5) / 64.0;
	return mix(
			WX_DITHER_THRESHOLD_MARGIN,
			1.0 - WX_DITHER_THRESHOLD_MARGIN,
			raw_threshold);
}

float wx_edge_secondary_weight(vec2 uv) {
	if (!has_terrain_edge_data || terrain_ecotone_width <= 0.0001) {
		return 0.0;
	}
	float edge_distance = visual_sample_edge_distance(wx_wrap_uv(uv)).r;
	float one_screen_pixel = max(fwidth(edge_distance), 1.0 / 255.0);
	float quality_scale;
#if defined(MOBILE_QUALITY_LOW)
	quality_scale = 0.58;
#elif defined(MOBILE_QUALITY_MID)
	quality_scale = 0.82;
#elif defined(MOBILE_QUALITY_HIGH)
	quality_scale = 0.94;
#else
	quality_scale = (weather_overlay_quality <= 0) ? 0.68
			: ((weather_overlay_quality == 1) ? 0.92 : 1.0);
#endif
	float width = clamp(terrain_ecotone_width * quality_scale, one_screen_pixel, 0.98);
	float analytic = 0.5 * (1.0 - smoothstep(0.0, width, edge_distance));
	float aa = 0.5 * (1.0 - smoothstep(0.0, one_screen_pixel, edge_distance));
	return max(analytic, aa);
}

// 逐格 LUT 采样(只采当前帧)。帧间插值不在这里做(否则每 tap 翻倍采样)，改在 sample_field_weather
// 算出最终标量后、只对中心 cell 采一次 prev 做 mix → 全程只多 1 次采样。
vec4 wx_sample_lut(int cid) {
	return texture(weather_lut, wx_cell_lut_uv(cid));
}

// 逐格天气场采样（cloud-from-field 2026-06-20）：经 cell-index 间接寻址读 weather_lut。
// type/intensity/cloud/vapor 取中心 cell（枚举不可插值）；只做帧间(prev)时间平滑。
// Spatial transitions use the shared neighbor/distance field; the hard atlas
// index remains authoritative and is never dither-remapped.
// 替代旧 sample_fronts 椭圆摘要 → 云精确对应 HexCell.weather_*。
FrontField sample_field_weather(vec2 wp) {
	FrontField best = empty_field();
	if (lut_dims.x < 1.0) return best; // weather_lut 未就绪 → 无云
	vec2 uv = wx_wrap_uv((wp - world_origin) / world_size);
	int cid_c = wx_decode_cell_index(uv);
	if (cid_c < 0) return best;
	float edge_w = wx_edge_secondary_weight(uv);
	int secondary_id = (edge_w > 0.0001) ? wx_decode_edge_secondary(uv) : -1;
#if defined(PK_MOBILE_ANY)
	if (secondary_id >= 0 && wx_mobile_dither_uv_threshold(uv, wp) < edge_w) {
		cid_c = secondary_id;
	}
	// 移动端只采样 DitherUV 选中的一个视觉 cell，避免连续混合的副 LUT 成本。
	secondary_id = -1;
#endif
	// 视野屏蔽提前于所有云计算：不可见格直接退成无云，顺带把三层云 / TOD 光照 /
	// 投影阴影整条管线一起省掉。
	float fog_vis = 1.0;
	if (fog_mask_enabled) {
		float fog_k = texture(enum_lut, wx_cell_lut_uv(cid_c)).a;
		if (secondary_id >= 0) {
			float secondary_k = texture(enum_lut, wx_cell_lut_uv(secondary_id)).a;
			fog_k = mix(fog_k, secondary_k, edge_w);
		}
		fog_vis = smoothstep(0.5, 1.0, fog_k);
		if (fog_vis < 0.01) return best;
	}
	vec4 center = wx_sample_lut((cid_c));
	if (secondary_id >= 0) {
		vec4 secondary = wx_sample_lut(secondary_id);
		center.gba = mix(center.gba, secondary.gba, edge_w);
	}
	int wt = int(center.r * 255.0 + 0.5);

	// 性能分区/连续性正解：空间柔化(4-tap+blur)已删——用户要的是时间连续,不是空间边界,且删后采样
	// 大降(weather_lut 仅 center+prev 2 次)。云形的程序化噪声仍在。逐格值在 baker 端如需柔化另议。
	float intensity_amount = center.g;
	float cloud_amount = center.b;
	float vapor_amount = center.a;
	// 帧间插值(时间平滑)：两次仿真更新(commit)之间渲染每帧都画,直接显示会在更新瞬间横跳。把上一帧标量
	// 按 weather_lerp(weather_layer 按 LUT 实际更新节奏推进 0→1)平滑过渡到当前帧 → 消时间横跳。type 离散不插。
	if (weather_lerp < 0.999) {
		vec4 prev_c = texture(weather_lut_prev, wx_cell_lut_uv(cid_c));
		if (secondary_id >= 0) {
			vec4 prev_secondary = texture(weather_lut_prev, wx_cell_lut_uv(secondary_id));
			prev_c.gba = mix(prev_c.gba, prev_secondary.gba, edge_w);
		}
		intensity_amount = mix(prev_c.g, intensity_amount, weather_lerp);
		cloud_amount = mix(prev_c.b, cloud_amount, weather_lerp);
		vapor_amount = mix(prev_c.a, vapor_amount, weather_lerp);
	}
	float precip_amount = intensity_amount;
	float visual_cloud_amount = clamp((cloud_amount + 0.6 * vapor_amount), 0.0, 1.0);
	// 云层以 weather_cloud + weather_vapor 为基础。2026-06-29：水汽先进入可视云量，
	// 显示端要让湿润区的层云/薄积云可见，避免只在降水核心处看见云。
	float cloud_linear = clamp(visual_cloud_amount / 0.8, 0.0, 1.0);
	float cloud_shaped = smoothstep(0.05, 0.8, visual_cloud_amount);
	float cloud_cover = clamp(mix(cloud_linear, cloud_shaped, 0.44) * precip_cloud_bias(precip_amount), 0.0, 1.0);
	float precip_gate = clamp(precip_amount * 1.05, 0.0, 1.0);


	best.color = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].rgb : vec3(0.0);
	best.alpha = ((wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].a : 0.0) * fog_vis;
	best.intensity = intensity_amount * fog_vis;
	best.cloud = cloud_cover * fog_vis;
	best.precip = precip_gate * fog_vis;
	best.shadow = clamp(cloud_cover * 0.6, 0.0, 1.0) * fog_vis;
	best.edge = vapor_amount * fog_vis;
	best.type = wt;
	best.axis = vec2(1.0, 0.15); // 逐格无风向，用近似纬向漂移让 billboard 流动
	return best;
}

// sample_fronts（旧 fronts 椭圆通路）已删除——云分布改由 sample_field_weather 逐格 LUT 驱动。

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 wp = wx_wrap_world_pos(v_world);
	vec2 uv = wx_wrap_uv((v_world - world_origin) / world_size);

	// [cylindrical-earth-daylight] 逐像素晨昏线唯一真源：纬度近似 uv.y*2-1（与地形 lat_signed 同定义/同向）。
	// 同一时刻东西经度晨昏不同 → 云的明暗随晨昏线扫过，与地面/水面/植被完全一致（不再全图统一明暗）。
	float lat_signed = clamp(uv.y * 2.0 - 1.0, -1.0, 1.0);
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	FrontField w = sample_field_weather(wp);

	int q_weather = effective_weather_quality();
	int biome = 0;
#if !defined(PK_MOBILE_ANY)
	biome = int(visual_sample_map_index(wx_wrap_uv(uv)).r * 255.0 + 0.5);
#endif
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

	// 低雾是 q1+ 才启用的昂贵层；无雾时跳过 4 点山地邻域采样与 hash。
	float fog_intensity = (q_weather >= 1 && w.cloud > 0.05) ? w.cloud * 0.65 : 0.0;
	float mountain_w = 0.0;
	if (fog_intensity > 0.001) {
		// 山地权重（仅低雾用）：4 点 golden-angle 邻域 + hash 抖动，平滑陆海/海拔过渡，
		// 偏移按 hex_world_diameter 物理换算，避免六边形直边。
		vec2 ring_step = vec2(hex_world_diameter) / max(world_size, vec2(0.001));
		const float GA = 2.39996323;
		vec2 m_offs[4] = vec2[4](
			vec2(0.0, 0.0),
			vec2(cos(GA * 1.0 + 0.7), sin(GA * 1.0 + 0.7)) * 2.6,
			vec2(cos(GA * 2.0 + 0.7), sin(GA * 2.0 + 0.7)) * 3.3,
			vec2(cos(GA * 3.0 + 0.7), sin(GA * 3.0 + 0.7)) * 2.9
		);
		float mw_sum = 0.0;
		float mw_tot = 0.0;
		for (int li = 0; li < 4; li++) {
			vec2 jj = vec2(
				hash_signed(floor(wp * 0.18 + vec2(31.0 + float(li) * 11.0, -47.0))),
				hash_signed(floor(wp * 0.18 + vec2(-19.0, 23.0 + float(li) * 9.0)))
			);
			vec2 s_uv = wx_wrap_uv(uv + m_offs[li] * ring_step + jj * 1.4 * ring_step);
			int bs = int(visual_sample_map_index(s_uv).r * 255.0 + 0.5);
			bool s_water = (bs == B_OCEAN) || (bs == B_COAST) || (bs == B_LAKE)
					|| (bs == B_REEF) || (bs == B_KELP) || (bs == B_SEA_ICE);
			float bw = (bs == B_MOUNTAIN) ? 1.0 : ((bs == B_HILL) ? 0.65 : (s_water ? 0.0 : 0.35));
			float kw = (li == 0) ? 1.4 : 1.0;
			mw_sum += bw * kw;
			mw_tot += kw;
		}
		mountain_w = clamp(mw_sum / max(mw_tot, 0.001)
				+ hash_signed(floor(wp * 0.085 + vec2(67.0, -31.0))) * 0.18, 0.0, 1.0);
	}

	vec2 cumulus_axis = w.axis;
	vec2 cirrus_axis = vec2(1.0, 0.15); // 卷云固定纬向（地球大气环流近似）

	// 高云强度：只随云量出现，不按天气类型开关。
	float cirrus_intensity = w.cloud * 0.48;
	float cirrus = (q_weather >= 1) ? sample_high_cloud(wp, cirrus_axis, cirrus_intensity) : 0.0;
	CloudLayerSample cirrus_layer = make_cloud_layer(
		remap_cloud_density(cirrus, cirrus_intensity, 0.16),
		smoothstep(0.05, 0.42, cirrus) * (1.0 - smoothstep(0.58, 0.96, cirrus)),
		cirrus_intensity,
		0.92
	);

	// 中云（主云）强度：使用已按天气层级增强后的 w.cloud。
	float cumulus_intensity = (w.cloud > 0.02) ? w.cloud : 0.0;
	CloudLayerSample cumulus_layer = sample_cumulus_layer(wp, cumulus_axis, cumulus_intensity);
	float cumulus = cumulus_layer.density;

	// 低雾强度也只随云量和山地权重，不按天气类型改变；q0 完全跳过。
	float local_fog_w = mountain_w;
	float low_fog = (fog_intensity > 0.001) ? sample_low_fog(wp, w.axis, fog_intensity, local_fog_w) : 0.0;

	CloudLayerSample fog_layer = make_cloud_layer(
		remap_cloud_density(low_fog, max(fog_intensity, local_fog_w), 0.24),
		smoothstep(0.04, 0.42, low_fog) * (1.0 - smoothstep(0.54, 0.96, low_fog)),
		max(fog_intensity, local_fog_w),
		0.18
	);

	// [tod-point-light 2026-06-25] 云响应逐像素点光源 TOD 光照：用 earth_daylight 的 ed.sun_dir
	// （含纬度/时角的"类点光源太阳方向"，与地形/水面/植被同源）取代旧全局 tod_sun_dir。
	// 水平分量 sun_axis = 太阳方位；其长度 sun_horiz = cos(太阳高度角) → 太阳越低方向感越强。
	vec2 sun_h = ed.sun_dir.xy;
	float sun_horiz = clamp(length(sun_h), 0.0, 1.0);
	vec2 sun_axis = (sun_horiz > 1e-4) ? sun_h / sun_horiz : normalize(vec2(0.62, -0.38));
	float sun_up = max(ed.sun_dir.z, 0.0); // = sin(太阳高度角)

	// 主云 TOD 体积近似：
	// q2: 4-tap 密度差分算法线 + 假厚度；q1: 单向太阳采样；q0: density/edge 近似。
	float cumulus_light_grad = 0.0;
	float cumulus_thickness = cumulus_layer.density;
	if (q_weather >= 2 && cumulus > 0.001) {
		float step_n = hex_world_diameter * 0.34;
		float d_l = sample_cumulus_density(wp - vec2(step_n, 0.0), cumulus_axis, cumulus_intensity);
		float d_r = sample_cumulus_density(wp + vec2(step_n, 0.0), cumulus_axis, cumulus_intensity);
		float d_d = sample_cumulus_density(wp - vec2(0.0, step_n), cumulus_axis, cumulus_intensity);
		float d_u = sample_cumulus_density(wp + vec2(0.0, step_n), cumulus_axis, cumulus_intensity);
		vec2 grad_xy = vec2(d_r - d_l, d_u - d_d);
		vec3 fake_normal = normalize(vec3(-grad_xy * 2.9, 0.92));
		vec3 fake_sun = normalize(vec3(sun_axis * max(sun_horiz, 0.001), max(sun_up, 0.10)));
		float normal_light = dot(fake_normal, fake_sun);
		float directional_grad = dot(grad_xy, sun_axis);
		cumulus_thickness = clamp(cumulus * (0.72 + 0.26 * cumulus_intensity) + (d_l + d_r + d_d + d_u) * 0.058, 0.0, 1.0);
		cumulus_light_grad = clamp((normal_light - 0.52) * 2.25 + directional_grad * 0.82 - cumulus_thickness * 0.18, -1.0, 1.0) * (0.42 + 0.58 * sun_horiz);
	} else if (q_weather >= 1) {
		float step_l = hex_world_diameter * 0.5;
		float d_toward = sample_cumulus_density(wp + sun_axis * step_l, cumulus_axis, cumulus_intensity);
		cumulus_thickness = clamp(cumulus * (0.78 + 0.22 * cumulus_intensity) + d_toward * 0.10, 0.0, 1.0);
		cumulus_light_grad = clamp((cumulus - d_toward) * 1.65 + cumulus_layer.edge * 0.24 - cumulus_thickness * 0.11, -1.0, 1.0) * (0.45 + 0.55 * sun_horiz);
	} else {
		cumulus_thickness = clamp(cumulus_layer.density * (0.80 + 0.20 * cumulus_intensity), 0.0, 1.0);
		cumulus_light_grad = clamp(cumulus_layer.edge * 0.45 + cumulus_layer.density * 0.18 - 0.30, -1.0, 1.0);
	}

	// [cloud-float] 偏移投影假阴影：把云沿背光方向投影到地面（offset = sun_axis*距离；距离 ∝ 云高·tan(天顶角)
	// = cloud_shadow_offset · sun_horiz/sin(h)）。太阳越低影越长偏移越大 → 云悬浮观感。q0 跳过、夜侧无影。
	float offset_shadow = 0.0;
	if (q_weather >= 1 && ed.local_day > 0.01 && cumulus_intensity > 0.02) {
		float sd = hex_world_diameter * cloud_shadow_offset * clamp(sun_horiz / max(sun_up, 0.20), 0.0, 3.2);
		float dsh = sample_cumulus_density(wp + sun_axis * sd, cumulus_axis, cumulus_intensity);
		offset_shadow = cloud_density_alpha(dsh) * ed.local_day;
	}

	float layer_occlusion = (q_weather >= 2)
		? clamp(fog_layer.density * 0.34 + cumulus_layer.density * 0.28, 0.0, 1.0)
		: 0.0;

	bool has_layer = (cumulus > 0.001) || (cirrus > 0.001) || (low_fog > 0.001) || (w.precip > 0.001) || (offset_shadow > 0.003);
	if (!has_layer) {
		COLOR = vec4(0.0);
	} else {
		// 局部云核/羽边（密度驱动）：先算，供压暗与亮度调制复用（cloud_core 后续阴影也用）。
		float cloud_core = smoothstep(0.38, 0.92, cumulus_layer.density);
		float cloud_edge_soft = 1.0 - smoothstep(0.18, 0.58, cumulus_layer.density);
		// 强云区不再把整格底色压成灰片；只让云纹理本身更厚、更少银边。
		float dense_cell = smoothstep(0.14, 0.32, w.cloud);
		float dense_core = clamp(dense_cell * (0.35 + 0.65 * cloud_core), 0.0, 1.0);
		vec3 main_base = mix(vec3(0.97, 0.98, 1.00), vec3(0.55, 0.62, 0.72), ed.pixel_night);
		main_base = mix(main_base, vec3(0.82, 0.86, 0.92), dense_core * 0.28);
		float silver = mix((q_weather >= 2) ? 1.08 : 0.72, 0.58, dense_core);
		vec3 col = compute_cloud_lighting(cumulus_layer, main_base, w.type, cumulus_light_grad, cumulus_thickness, silver, ed.sun_col, ed.amb_col, ed.local_day);
		// 边缘过亮项(>1)在强云核轻微收敛，避免羽边白点闪烁（但不压成暗块）。
		float bright_mul = mix(1.08 + cloud_edge_soft * 0.06, 0.82, cloud_core * ((q_weather >= 2) ? 0.54 : 0.38));
		col *= mix(bright_mul, min(bright_mul, 1.02), dense_core);
		float precip_alpha_factor = precip_cloud_opacity_bias(w.precip);
		float alpha = clamp(cloud_density_alpha(cumulus_layer.density) * mix(1.0, 1.06, dense_core) * precip_alpha_factor * weather_strength * 1.18, 0.0, min(0.86, 0.80 * precip_alpha_factor));

		// 云下假阴影 = 直接(云正下方,薄) + 偏移投影(沿背光方向偏移的云密度)。整体调弱：薄薄一层暗淡，
		// 不再挡住下方地表。偏移投影即使本像素头顶无云也能落影 → 阴影与云分离、营造悬浮感；夜侧消隐。
		float direct_shadow = w.shadow * (0.04 + cloud_core * 0.02);
		float ground_shadow = clamp((direct_shadow + offset_shadow * 0.14) * weather_strength * precip_alpha_factor * ed.local_day, 0.0, 0.10);

		// 阴影色用偏中性的暗调（非接近纯黑），即便叠满也只是压暗而不遮挡地表。
		col = mix(vec3(0.20, 0.22, 0.26), col, alpha / max(alpha + ground_shadow, 0.001));
		alpha = clamp(alpha + ground_shadow, 0.0, 0.94);

		// 低雾（底层，介于地面与中云之间）。
		if (fog_layer.density > 0.001) {
			vec3 fog_base = mix(vec3(0.80, 0.84, 0.88), vec3(0.62, 0.68, 0.74), ed.pixel_night);
			vec3 fog_col = compute_cloud_lighting(fog_layer, fog_base, WT_FOG, 0.0, fog_layer.density * 0.55, 0.08, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 fog_comp = apply_cloud_layer(col, alpha, fog_layer, fog_col, 0.95, 0.0);
			col = fog_comp.rgb;
			alpha = fog_comp.a;
		}

		// 高云（卷云，最上层薄纱）。
		if (cirrus_layer.density > 0.001) {
			vec3 cirrus_base = mix(vec3(0.92, 0.94, 0.98), ed.sun_col, 0.28);
			cirrus_base = mix(cirrus_base, vec3(0.72, 0.78, 0.88), ed.pixel_night);
			vec3 cirrus_col = compute_cloud_lighting(cirrus_layer, cirrus_base, w.type, cirrus_layer.edge * 0.18, cirrus_layer.density * 0.28, 0.36, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 cirrus_comp = apply_cloud_layer(col, alpha, cirrus_layer, cirrus_col, 0.42, layer_occlusion * 0.45);
			col = cirrus_comp.rgb;
			alpha = min(cirrus_comp.a, 0.94);
		}

		float tod_alpha = mix(0.65, 1.0, ed.local_day);
		// 云层随 TOD 变暗/变薄，避免夜侧像白色贴片盖在地表上。
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), min(alpha * tod_alpha, 0.94));
	}
}
