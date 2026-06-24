shader_type canvas_item;
render_mode blend_mix;

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

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable; // R = biome id / 255 ; G/B = cell.index 低/高字节
// cell-index 间接寻址（cloud-from-field 2026-06-20）：per-cell 天气场 LUT。
//   R=weather_type, G=intensity, B=cloud, A=precip（与 encode_cell_luts 同布局）。
//   decode_cell_index(uv) 用 map_index_atlas.GB 取 cell.index，再 cell_lut_uv 采样本格天气。
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut_prev : filter_nearest, repeat_disable;  // 上一仿真帧 LUT(帧间插值减两次更新间横跳)
uniform float weather_lerp : hint_range(0.0, 1.0) = 1.0;              // 0=prev 1=curr,两次仿真更新之间随时间推进
uniform vec2 lut_dims = vec2(0.0);

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float world_time = 0.0;
// 一个 hex 的“直径”（wp 单位）。邻域采样偏移按它物理换算，避免与 map_index_atlas
// 的 hex 像素尺度发生频率共振导致六边形晶格。
uniform float hex_world_diameter = 38.0;

// 昼夜（TOD）：方向光色 / 环境光色 / 晨昏全部走 earth_daylight 唯一真源（见下方 include），
// 不再由 GDScript 推单一 tod_sun_color/tod_ambient_color/tod_night_factor（那会让全图云统一明暗、
// 与逐像素晨昏线的地面/水面/植被对不上）。此处仅保留：总开关、迎光屏幕方向（earth_daylight 不给
// 2D 方向，云体积梯度需要它）、全局曝光、云染色开关。
uniform bool day_night_enabled = true;
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

// 天气类型表（颜色 + 功能 flag）
const int MAX_WEATHER_TYPES = 8;
uniform vec4 weather_profile_colors[MAX_WEATHER_TYPES];
uniform int weather_profile_flags[MAX_WEATHER_TYPES];

const int FLAG_SNOW_GRAIN = 4;
const int FLAG_RAIN_STREAK = 8;
const int FLAG_FOG_BREATHE = 16;

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

int effective_weather_quality() {
#if defined(MOBILE_QUALITY_LOW)
	return 0;
#elif defined(MOBILE_QUALITY_MID)
	return min(weather_overlay_quality, 1);
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
vec2 cloud_hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123);
}

float cloud_grad_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 ga = -1.0 + 2.0 * cloud_hash22(i + vec2(0.0, 0.0));
	vec2 gb = -1.0 + 2.0 * cloud_hash22(i + vec2(1.0, 0.0));
	vec2 gc = -1.0 + 2.0 * cloud_hash22(i + vec2(0.0, 1.0));
	vec2 gd = -1.0 + 2.0 * cloud_hash22(i + vec2(1.0, 1.0));
	float va = dot(ga, f - vec2(0.0, 0.0));
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float n = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	return 0.5 + 0.5 * n;
}

// 旋转去相关 FBM（标准云体）。各 octave 间旋转 → 消除网格对齐的块状感。
float cloud_fbm(vec2 p, int octaves) {
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += cloud_grad_noise(p) * amp;
		p = m * p;
		amp *= 0.5;
	}
	return sum;
}

// 带时间演化的 FBM：每 octave 旋转后加不同方向的时间漂移 → 云内部翻腾而非死板平移。
float cloud_fbm_evolve(vec2 p, int octaves, float t) {
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	mat2 tm = mat2(vec2(0.76, 0.64), vec2(-0.64, 0.76));
	float sum = 0.0;
	float norm = 0.0;
	float amp = 0.5;
	vec2 sh = vec2(t * 0.17, -t * 0.13);
	vec2 wobble = vec2(sin(t * 0.23), cos(t * 0.19)) * 0.32;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		float fi = float(i);
		sum += cloud_grad_noise(p + sh + wobble * (0.55 + fi * 0.18)) * amp;
		norm += amp;
		p = m * p;
		sh = tm * sh * 0.62 + vec2(t * 0.015, -t * 0.011);
		wobble = tm * wobble;
		amp *= 0.5;
	}
	return clamp(sum / max(norm, 0.001), 0.0, 1.0);
}

// ── 云密度主函数：软轮廓 + 清晰核心 + 时间扰动细节（cumulus / 雾 / front 共用）──
// p：世界坐标（调用方已做风向 advection）。coverage：该点语义云量 [0,1]。seed：错开不同 front。
// 低频层负责大团柔和边缘；中高频只在云核逐步增强，让内部纹理清楚但边缘仍羽化。
float cloud_density_soft(vec2 p, float coverage, float seed) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	int q = effective_weather_quality();
	// 性能分档：q0=轮廓云(2 octave)；q1=主云+粗细节(3+1)；q2=轻量 warp + 细节(3+2+1)。
	int lo_oct = (q >= 1) ? 3 : 2;
	int hi_oct = (q >= 2) ? 2 : ((q >= 1) ? 1 : 0);
	float t = world_time;

	vec2 warp = vec2(0.0);
	if (q >= 2) {
		vec2 warp_p = p * 0.0038 + vec2(seed * 0.23, -seed * 0.17);
		warp = vec2(
			cloud_fbm_evolve(warp_p + vec2(13.7, 2.9), 1, t * 0.18),
			cloud_fbm_evolve(warp_p + vec2(-5.4, 19.1), 1, -t * 0.15)
		) - vec2(0.5);
	}

	// 噪声相位必须只由世界坐标/时间/seed 决定，不能由 coverage 决定；否则每次 weather_lut 刷新云量变化时，噪声坐标也会跳。
	vec2 base_p = p * 0.0105 + warp * ((q >= 2) ? 0.42 : 0.0) + vec2(seed * 0.37, seed * 0.61);
	float low = cloud_fbm_evolve(base_p, lo_oct, t * 0.34);
	float mid = low;
	if (hi_oct > 0) {
		mid = cloud_fbm_evolve(base_p * 3.15 + vec2(11.7, 4.2), hi_oct, t * 0.72);
	}
	float fine = mid;
	if (q >= 2) {
		fine = cloud_grad_noise(base_p * 7.4 + vec2(-21.3, 15.8) + vec2(t * 0.47, -t * 0.31));
	}

	float cover_gate = smoothstep(0.03, 0.22, coverage);

	float coverage_solid = smoothstep(0.16, 0.86, coverage);
	float core_gate = smoothstep(0.42, 0.78, low) * cover_gate;
	float edge_gate = smoothstep(0.24, 0.58, low) * (1.0 - smoothstep(0.82, 0.98, low));
	float detail_w = mix(0.14, 0.52, core_gate) + edge_gate * mix(0.07, 0.035, coverage_solid);
	float fine_w = ((q >= 2) ? 0.24 : 0.09) * core_gate;
	float detail_signal = (mid - 0.5) * detail_w + (fine - 0.5) * fine_w;
	// 高云量处减少负向噪声挖空、保留正向噪声堆实；低云量处仍让噪声打散边缘。
	float negative_carve = min(detail_signal, 0.0) * mix(1.0, 0.36, coverage_solid);
	float positive_build = max(detail_signal, 0.0) * mix(0.72, 1.18, coverage_solid);
	float shape = low + negative_carve + positive_build;

	// coverage 同时控制阈值和实度：云量越高，阈值越低、核心越容易连成实体，但 feather 仍保留软边。
	float thr = mix(0.58, 0.36, coverage_solid);
	float feather = mix(0.48, 0.28, coverage_solid);
	float body = smoothstep(thr - feather, thr + feather, shape);
	float core = smoothstep(thr + feather * mix(0.18, 0.02, coverage_solid), thr + feather * mix(0.92, 0.58, coverage_solid), shape);
	float internal_detail = ((mid - 0.5) * 0.20 + (fine - 0.5) * 0.12) * core_gate * mix(0.55, 1.15, coverage_solid);
	float density = body * mix(0.56, 0.76, coverage_solid) + core * mix(0.18, 0.36, coverage_solid) + internal_detail;
	return clamp(density * cover_gate, 0.0, 1.0);
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

vec2 cloud_sun_axis() {
	vec2 axis = tod_sun_dir.xy;
	if (dot(axis, axis) <= 0.0001) {
		return normalize(vec2(0.62, -0.38));
	}
	return normalize(axis);
}

float cloud_density_alpha(float density) {
	// 拉宽 alpha 曲线，避免中高密度过早饱和；内部密度差会保留到最终透明度。
	float soft = smoothstep(0.012, 0.96, density);
	float core = smoothstep(0.52, 1.00, density);
	return clamp(pow(soft, 1.16) * 0.84 + core * 0.12, 0.0, 1.0);
}

// billboard 白云着色：以亮白为主，迎太阳侧更亮、背光侧 / 厚核略压暗形成体积感，薄边银边。
// 光照走 earth_daylight：sun_col（晨昏暖橙↔正午暖白）、amb_col（夜冷蓝↔昼天空）、local_day（夜=0）。
// 方向光乘 local_day → 夜侧无阳照（与 brdf.make_lighting_context 同源），云的明暗随晨昏线扫过。
vec3 compute_cloud_lighting(CloudLayerSample layer, vec3 base_tint, int wt, float light_grad, float silver_gain, vec3 sun_col, vec3 amb_col, float local_day) {
	if (!cloud_tod_tint_enabled) {
		return base_tint;
	}
	float d = layer.density;
	float sun_facing = smoothstep(-0.5, 0.5, light_grad);
	float shade = mix(0.76, 1.0, sun_facing);   // 背光侧偏灰、迎光侧全亮
	shade *= mix(1.0, 0.88, d * 0.6);            // 厚核轻压暗，出体积感
	float rim = layer.edge * silver_gain * (0.4 + 0.6 * sun_facing);
	vec3 sun_c = sun_col * local_day;            // 夜侧 local_day=0 → 无方向光
	vec3 col = base_tint * (amb_col * 0.42 + sun_c * (shade * 0.74 + rim * 0.34));
	// 云层光照不按天气类型染色/压暗，保证同云量同显示。
	// 夜侧地板由环境光（夜冷蓝）决定，不再用裸常数 → 与地面夜色同冷调。
	return max(col * tod_exposure, amb_col * 0.42);
}

vec4 apply_cloud_layer(vec3 base_col, float base_alpha, CloudLayerSample layer, vec3 layer_col, float alpha_scale, float occlusion) {
	float density = layer.density;
	float shaded_density = density * (1.0 - clamp(occlusion, 0.0, 1.0) * 0.28);
	float layer_alpha = clamp(cloud_density_alpha(shaded_density) * alpha_scale * weather_strength, 0.0, 0.96);
	vec3 density_col = layer_col * mix(1.06, 0.80, density);
	float blend_w = clamp(layer_alpha * (0.60 + layer.edge * 0.20 + density * 0.30), 0.0, 1.0);
	vec3 col = mix(base_col, density_col, blend_w);
	float alpha = clamp(base_alpha + layer_alpha * (1.0 - base_alpha * 0.22), 0.0, 0.97);
	return vec4(col, alpha);
}

// ── 三层云采样 ──

// 高云（卷云）：各向异性拉丝薄纱，沿风向延展。
float sample_high_cloud(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	float u = dot(wp, dir);
	float v = dot(wp, side);
	vec2 sp = vec2(u * 0.010 + t * 0.9, v * 0.030);
	int q = effective_weather_quality();
	float band = cloud_fbm(sp, (q >= 2) ? 3 : 2);
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	if (q >= 2) {
		float fiber = cloud_fbm(sp * 2.3 + vec2(11.0, -5.0), 1);
		streak *= 0.76 + 0.24 * smoothstep(0.40, 0.80, fiber);
	}
	return clamp(streak * coverage, 0.0, 1.0);
}


// 低云 / 山雾：贴地、慢漂，biome_weight（山地权重）调制可见度。
float sample_low_fog(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	if (biome_weight <= 0.001 || intensity <= 0.001) {
		return 0.0;
	}
	float t = world_time;
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 cp = wp - dir * t * 0.8;
	float fog = cloud_density_soft(cp, clamp(intensity + 0.12, 0.0, 1.0), 53.0);
	return clamp(fog * intensity * biome_weight, 0.0, 1.0);
}

// 中云（积云）：视觉主角，跟风漂移、内部持续翻卷。coverage 已是语义云量，单次取密度。
CloudLayerSample sample_cumulus_layer(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return empty_cloud_layer();
	}
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	vec2 cp = wp - dir * t * 1.45 + side * sin(t * 0.19 + dot(wp, dir) * 0.0022) * hex_world_diameter * 0.22;
	float density = cloud_density_soft(cp, coverage, 13.0);
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
	return mix(1.0, 1.22, p);
}

float precip_cloud_opacity_bias(float precip) {
	float p = smoothstep(0.04, 0.72, precip);
	return mix(1.0, 1.16, p);
}


// front_axis / front_ellipse_distance / visual_weather_intensity 已随 sample_fronts 一并删除。

// ── cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免引入 dyn/eco LUT 依赖）──
int wx_decode_cell_index(vec2 uv) {
	vec2 gb = texture(map_index_atlas, wx_wrap_uv(uv)).gb;
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

// 逐格 LUT 采样(只采当前帧)。帧间插值不在这里做(否则每 tap 翻倍采样)，改在 sample_field_weather
// 算出最终标量后、只对中心 cell 采一次 prev 做 mix → 全程只多 1 次采样。
vec4 wx_sample_lut(int cid) {
	return texture(weather_lut, wx_cell_lut_uv(cid));
}

// 逐格天气场采样（cloud-from-field 2026-06-20）：经 cell-index 间接寻址读 weather_lut。
// type 取中心 cell（枚举不可插值）；intensity/cloud/precip 4-tap 双线性平滑跨格柔化。
// 替代旧 sample_fronts 椭圆摘要 → 云精确对应 HexCell.weather_*。
FrontField sample_field_weather(vec2 wp) {
	FrontField best = empty_field();
	if (lut_dims.x < 1.0) return best; // weather_lut 未就绪 → 无云
	vec2 uv = wx_wrap_uv((wp - world_origin) / world_size);
	int cid_c = wx_decode_cell_index(uv);
	if (cid_c < 0) return best;
	vec4 center = wx_sample_lut((cid_c));
	int wt = int(center.r * 255.0 + 0.5);

	// 性能分区/连续性正解：空间柔化(4-tap+blur)已删——用户要的是时间连续,不是空间边界,且删后采样
	// 大降(weather_lut 仅 center+prev 2 次)。云形的程序化噪声仍在。逐格值在 baker 端如需柔化另议。
	float intensity_amount = center.g;
	float cloud_amount = center.b;
	float precip_amount = center.a;
	// 帧间插值(时间平滑)：两次仿真更新(commit)之间渲染每帧都画,直接显示会在更新瞬间横跳。把上一帧标量
	// 按 weather_lerp(weather_layer 按 LUT 实际更新节奏推进 0→1)平滑过渡到当前帧 → 消时间横跳。type 离散不插。
	if (weather_lerp < 0.999) {
		vec4 prev_c = texture(weather_lut_prev, wx_cell_lut_uv(cid_c));
		intensity_amount = mix(prev_c.g, intensity_amount, weather_lerp);
		cloud_amount = mix(prev_c.b, cloud_amount, weather_lerp);
		precip_amount = mix(prev_c.a, precip_amount, weather_lerp);
	}
	// 云层以连续 weather_cloud 为基础，再按本格降水量连续增强密度，避免 weather_type 离散跳变影响云显示。
	float cloud_linear = clamp(cloud_amount / 0.72, 0.0, 1.0);
	float cloud_shaped = smoothstep(0.14, 0.72, cloud_amount);
	float cloud_cover = clamp(mix(cloud_linear, cloud_shaped, 0.52) * precip_cloud_bias(precip_amount), 0.0, 1.0);
	float precip_gate = clamp(precip_amount * 1.4, 0.0, 1.0);


	best.color = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].rgb : vec3(0.0);
	best.alpha = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].a : 0.0;
	best.intensity = intensity_amount;
	best.cloud = cloud_cover;
	best.precip = precip_gate;
	best.shadow = clamp(cloud_cover * 0.6, 0.0, 1.0);
	best.edge = 0.0;
	best.type = wt;
	best.axis = vec2(1.0, 0.15); // 逐格无风向，用近似纬向漂移让 billboard 流动
	return best;
}

// sample_fronts（旧 fronts 椭圆通路）已删除——云分布改由 sample_field_weather 逐格 LUT 驱动。

// ── 降水（解析噪声）──
// 注：cloud_fbm(p,N) 取值约 [0, 1-2^-N]，故下方 smoothstep 上阈值按此范围设定
// （比旧纹理 fbm 的 [0,1] 略低），保证条纹能正常起跳。
float rain_field(vec2 wp, vec2 axis, float precip) {
	if (precip < 0.008) return 0.0;
	vec2 wind_dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 dir = normalize(wind_dir * 0.55 + vec2(0.0, 1.0) * 0.45);
	vec2 side = vec2(-dir.y, dir.x);
	float along = dot(wp, dir);
	float across = dot(wp, side);
	int q = effective_weather_quality();
	float sheet = cloud_fbm(vec2(across * 0.052, along * 0.018 + world_time * 2.8), (q >= 2) ? 2 : 1);
	float curtain = smoothstep(0.30, 0.62, sheet);
	float rain = curtain * 0.85 * precip;
	if (q >= 1) {
		float near_lines = cloud_fbm(vec2(across * 0.19, along * 0.060 + world_time * 12.0), 1);
		float lines = smoothstep(0.46, 0.70, near_lines);
		rain += lines * 0.62 * precip;
	}
	if (q >= 2 && precip > 0.10) {
		float shaft_band = cloud_fbm(vec2(across * 0.014, along * 0.006 - world_time * 0.55), 1);
		float shaft = smoothstep(0.46, 0.72, shaft_band) * smoothstep(0.10, 0.42, precip);
		rain += shaft * 0.55;
	}

	return clamp(rain, 0.0, 1.0);
}

float snow_field(vec2 wp, vec2 axis, float precip) {
	vec2 wind = normalize(axis + vec2(0.12, 0.36));
	vec2 side = vec2(-wind.y, wind.x);
	float along = dot(wp, wind);
	float across = dot(wp, side);
	int q = effective_weather_quality();
	float band = cloud_fbm(vec2(along * 0.036 + world_time * 1.4, across * 0.078), (q >= 2) ? 2 : 1);
	float veil = band;
	if (q >= 1) {
		veil = cloud_fbm(vec2(along * 0.012 + world_time * 0.45, across * 0.026), 1);
	}
	float flurry = smoothstep(0.40, 0.70, band) * 0.62 + smoothstep(0.26, 0.58, veil) * 0.42;


	return clamp(flurry * precip, 0.0, 1.0);
}

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
	int biome = int(texture(map_index_atlas, wx_wrap_uv(uv)).r * 255.0 + 0.5);
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
			int bs = int(texture(map_index_atlas, s_uv).r * 255.0 + 0.5);
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

	// 太阳方向密度梯度：不再二次采样主云（q2 原本几乎翻倍 ALU），改用边缘/核心的廉价近似。
	float cumulus_light_grad = (q_weather >= 2) ? clamp(cumulus_layer.edge * 0.55 + cumulus_layer.density * 0.22 - 0.32, -1.0, 1.0) : 0.0;

	float layer_occlusion = (q_weather >= 2)
		? clamp(fog_layer.density * 0.34 + cumulus_layer.density * 0.28, 0.0, 1.0)
		: 0.0;

	bool has_layer = (cumulus > 0.001) || (cirrus > 0.001) || (low_fog > 0.001) || (w.precip > 0.001);
	if (!has_layer) {
		COLOR = vec4(0.0);
	} else {
		int flags = (w.type >= 0 && w.type < MAX_WEATHER_TYPES) ? weather_profile_flags[w.type] : 0;

		// 主云（积云）：云显示只由 w.cloud 驱动；颜色不再按天气类型/降水/强度变化。
		vec3 main_base = mix(vec3(0.97, 0.98, 1.00), vec3(0.55, 0.62, 0.72), ed.pixel_night);
		vec3 col = compute_cloud_lighting(cumulus_layer, main_base, w.type, cumulus_light_grad, (q_weather >= 2) ? 1.08 : 0.72, ed.sun_col, ed.amb_col, ed.local_day);
		float cloud_core = smoothstep(0.38, 0.92, cumulus_layer.density);
		float cloud_edge_soft = 1.0 - smoothstep(0.18, 0.58, cumulus_layer.density);
		col *= mix(1.07 + cloud_edge_soft * 0.05, 0.88, cloud_core * ((q_weather >= 2) ? 0.62 : 0.42));
		float precip_alpha_factor = precip_cloud_opacity_bias(w.precip);
		float alpha = clamp(cloud_density_alpha(cumulus_layer.density) * precip_alpha_factor * weather_strength * 0.66, 0.0, min(0.78, 0.70 * precip_alpha_factor));

		// 地面投影阴影随云量/云核变化，并按本格降水量连续轻微增强。
		float shadow_alpha = clamp(w.shadow * weather_strength * (0.17 + cloud_core * 0.07) * precip_alpha_factor * (1.0 - ed.pixel_night * 0.35), 0.0, min(0.36, 0.32 * precip_alpha_factor));

		col = mix(vec3(0.06, 0.08, 0.10), col, alpha / max(alpha + shadow_alpha, 0.001));
		alpha = clamp(alpha + shadow_alpha, 0.0, 0.94);

		// 低雾（底层，介于地面与中云之间）。
		if (fog_layer.density > 0.001) {
			vec3 fog_base = mix(vec3(0.80, 0.84, 0.88), vec3(0.62, 0.68, 0.74), ed.pixel_night);
			vec3 fog_col = compute_cloud_lighting(fog_layer, fog_base, WT_FOG, 0.0, 0.08, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 fog_comp = apply_cloud_layer(col, alpha, fog_layer, fog_col, 0.54, 0.0);
			col = fog_comp.rgb;
			alpha = fog_comp.a;
		}

		// 降雨：保留降水视觉本身，但不再影响云层显示标准。
		if ((flags & FLAG_RAIN_STREAK) != 0 && w.precip > 0.001) {
			float rain = rain_field(wp, w.axis, w.precip);
			vec3 rain_col = vec3(0.52, 0.62, 0.74);
			col = mix(col, rain_col, clamp(rain * 0.50, 0.0, 0.70));
			alpha = clamp(alpha + rain * 0.18 * weather_strength, 0.0, 0.82);
			col *= mix(1.0, 0.72, rain * 0.68);
		}

		// 降雪。
		if ((flags & FLAG_SNOW_GRAIN) != 0 && w.precip > 0.001) {
			float snow = snow_field(wp, w.axis, w.precip);
			col = mix(col, vec3(0.88, 0.94, 1.0), snow * 0.66);
			alpha = clamp(alpha + snow * 0.38 * weather_strength, 0.0, 0.94);
		}

		// 高云（卷云，最上层薄纱）。
		if (cirrus_layer.density > 0.001) {
			vec3 cirrus_base = mix(vec3(0.92, 0.94, 0.98), ed.sun_col, 0.28);
			cirrus_base = mix(cirrus_base, vec3(0.72, 0.78, 0.88), ed.pixel_night);
			vec3 cirrus_col = compute_cloud_lighting(cirrus_layer, cirrus_base, w.type, cirrus_layer.edge * 0.18, 0.36, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 cirrus_comp = apply_cloud_layer(col, alpha, cirrus_layer, cirrus_col, 0.20, layer_occlusion * 0.45);
			col = cirrus_comp.rgb;
			alpha = min(cirrus_comp.a, 0.94);
		}

		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
	}
}
