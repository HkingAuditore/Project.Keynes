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
uniform vec2 lut_dims = vec2(0.0);

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
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

// 带时间演化的 FBM：每 octave 旋转后加时间漂移 → 云内部翻腾而非死板平移。
float cloud_fbm_evolve(vec2 p, int octaves, float t) {
	mat2 m = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));
	float sum = 0.0;
	float amp = 0.5;
	vec2 sh = vec2(t * 0.16, -t * 0.12);
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += cloud_grad_noise(p + sh) * amp;
		p = m * p;
		sh *= 0.5;
		amp *= 0.5;
	}
	return sum;
}

// ── 云密度主函数：两层扰动噪声 billboard 云（cumulus / 雾 / front 共用）──
// p：世界坐标（调用方已做风向 advection）。coverage：该点语义云量 [0,1]。seed：错开不同 front。
// 低频层定大团蓬松主体，高频层做细节与破碎边缘，两层都随时间持续扰动。
// 密度驱动清晰/柔和：云核（低频值高）处高频细节权重大 → 清晰蓬松团块；
// 云缘（低频值低）处高频权重小 → 柔和过渡。coverage 越大 → 阈值越低 → 云越多越实。
float cloud_density_soft(vec2 p, float coverage, float seed) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	int q = effective_weather_quality();
	int lo_oct = (q >= 1) ? 4 : 3;
	// 高频降一档（q2:3→2）：减碎块更柔和，且每像素少 3 次噪声采样（本函数每像素被调 3 次）。
	int hi_oct = (q >= 1) ? 2 : 1;
	float t = world_time;
	vec2 base_p = p * 0.0100 + vec2(seed); // 0.0150→0.0100：放大云团尺度，全图视角下连成片、不再密集碎斑
	float low = cloud_fbm_evolve(base_p, lo_oct, t * 0.35);
	float high = cloud_fbm_evolve(base_p * 3.6 + vec2(11.7, 4.2), hi_oct, t * 0.7);
	// 高频权重大幅下调（原 0.26~0.52 → 0.14~0.28）：低频大团主导，去掉细碎"雪花屏"麻点。
	float detail_w = mix(0.14, 0.28, smoothstep(0.30, 0.72, low));
	float shape = low * 0.86 + (high - 0.5) * detail_w;
	// 阈值随云量下移成团；过渡再加宽到 0.46（原 0.34）→ 云缘长程渐隐、彻底去掉硬块边。
	float thr = mix(0.45, 0.25, coverage);
	float density = smoothstep(thr, thr + 0.46, shape);
	return clamp(density, 0.0, 1.0);
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
	// 软羽化：低端贴 0 起步（长尾软边、不再硬切），上端不到满（通透不挡视线）。
	// 0.10→0.03 拉长云缘渐隐尾、0.90→0.86 让核心更易聚出 alpha → 边缘软、核心仍成形。
	return clamp(smoothstep(0.03, 0.86, density), 0.0, 1.0);
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
	if (wt == WT_STORM || wt == WT_MONSOON) {
		col *= 0.82;
	}
	if (wt == WT_BLIZZARD) {
		col = mix(col, vec3(0.86, 0.92, 1.0), 0.18 + (1.0 - local_day) * 0.14);
	}
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
	float band = cloud_fbm(sp, 3);
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	float fiber = cloud_fbm(sp * 2.3 + vec2(11.0, -5.0), 2);
	streak *= 0.7 + 0.3 * smoothstep(0.40, 0.80, fiber);
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
	vec2 cp = wp - dir * world_time * 1.6;
	float density = cloud_density_soft(cp, coverage, 13.0);
	float edge = smoothstep(0.04, 0.40, density) * (1.0 - smoothstep(0.62, 0.97, density));
	return make_cloud_layer(density, edge, coverage, 0.55);
}

// ── 逐格天气场采样结果（结构沿用旧名 FrontField，现由 weather_lut 填充）──
struct FrontField {
	vec3 color;
	float alpha;
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
	f.cloud = 0.0;
	f.precip = 0.0;
	f.shadow = 0.0;
	f.edge = 0.0;
	f.type = WT_CLEAR;
	f.axis = vec2(1.0, 0.0);
	return f;
}

float type_cloud_bias(int wt) {
	if (wt == WT_STORM) return 1.18;
	if (wt == WT_MONSOON) return 1.12;
	if (wt == WT_FOG) return 1.20;
	if (wt == WT_BLIZZARD) return 1.06;
	return 1.0;
}

// front_axis / front_ellipse_distance / visual_weather_intensity 已随 sample_fronts 一并删除。

// ── cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免引入 dyn/eco LUT 依赖）──
int wx_decode_cell_index(vec2 uv) {
	vec2 gb = texture(map_index_atlas, uv).gb;
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

// 逐格天气场采样（cloud-from-field 2026-06-20）：经 cell-index 间接寻址读 weather_lut。
// type 取中心 cell（枚举不可插值）；intensity/cloud/precip 4-tap 双线性平滑跨格柔化。
// 替代旧 sample_fronts 椭圆摘要 → 云精确对应 HexCell.weather_*。
FrontField sample_field_weather(vec2 wp) {
	FrontField best = empty_field();
	if (lut_dims.x < 1.0) return best; // weather_lut 未就绪 → 无云
	vec2 uv = (wp - world_origin) / world_size;
	int cid_c = wx_decode_cell_index(uv);
	if (cid_c < 0) return best;
	vec4 center = texture(weather_lut, wx_cell_lut_uv(cid_c));
	int wt = int(center.r * 255.0 + 0.5);
	if (wt == WT_CLEAR || wt == WT_DROUGHT || wt == WT_HEATWAVE) return best;

	// 4-tap 双线性：在 map_index_atlas 的 bilinear footprint 上取 4 个 cell，按子像素权重
	// 混合 intensity/cloud/precip，补回跨 cell 边界平滑（type 保持中心 cell，枚举不可插值）。
	vec2 res = vec2(textureSize(map_index_atlas, 0));
	vec2 tc = uv * res - 0.5;
	vec2 base = floor(tc);
	vec2 f = tc - base;
	vec2 inv = 1.0 / res;
	int i00 = wx_decode_cell_index((base + vec2(0.5, 0.5)) * inv);
	int i10 = wx_decode_cell_index((base + vec2(1.5, 0.5)) * inv);
	int i01 = wx_decode_cell_index((base + vec2(0.5, 1.5)) * inv);
	int i11 = wx_decode_cell_index((base + vec2(1.5, 1.5)) * inv);
	vec4 c00 = (i00 >= 0) ? texture(weather_lut, wx_cell_lut_uv(i00)) : center;
	vec4 c10 = (i10 >= 0) ? texture(weather_lut, wx_cell_lut_uv(i10)) : center;
	vec4 c01 = (i01 >= 0) ? texture(weather_lut, wx_cell_lut_uv(i01)) : center;
	vec4 c11 = (i11 >= 0) ? texture(weather_lut, wx_cell_lut_uv(i11)) : center;
	vec4 sm = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);

	float cloud_amount = sm.b;
	float precip_amount = sm.a;
	// weather_cloud 物理场整体偏高（实测 last-tick p50≈0.61、p90≈0.81，连 CLEAR 都≈0.6）；旧 smoothstep(0.15,0.58)
	// 把几乎所有有云格子(占图≈49%)全抬成 cloud_cover≈1 → 满屏均匀浓白。阈值上移到 [0.48,0.84]：仅显著高于常态
	// 的云量才成浓云，常态云量变淡通透、拉开浓淡层次。(覆盖率仍由 cloud 物理场/分类决定，根治见"降 cloud 场"一步。)
	float cloud_cover = clamp(smoothstep(0.48, 0.84, cloud_amount) * type_cloud_bias(wt), 0.0, 1.0);
	float precip_gate = clamp(precip_amount * 1.4, 0.0, 1.0);
	if (wt == WT_FOG) {
		precip_gate = 0.0;
		cloud_cover = clamp(smoothstep(0.42, 0.80, cloud_amount) * 1.05, 0.0, 1.0); // 同步上移并去掉 +0.10 基底（基底让每个 FOG 格永远有云，本身就加重满屏）
	}

	best.color = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].rgb : vec3(0.0);
	best.alpha = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].a : 0.0;
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
	float sheet = cloud_fbm(vec2(across * 0.052, along * 0.018 + world_time * 2.8), 2);
	float near_lines = cloud_fbm(vec2(across * 0.19, along * 0.060 + world_time * 12.0), 2);
	float curtain = smoothstep(0.30, 0.62, sheet);
	float lines = smoothstep(0.46, 0.70, near_lines);
	float rain = (curtain * 0.85 + lines * 0.72) * precip;
	if (precip > 0.10) {
		float shaft_band = cloud_fbm(vec2(across * 0.014, along * 0.006 - world_time * 0.55), 2);
		float shaft = smoothstep(0.46, 0.72, shaft_band) * smoothstep(0.10, 0.42, precip);
		rain += shaft * 0.65;
	}
	return clamp(rain, 0.0, 1.0);
}

float snow_field(vec2 wp, vec2 axis, float precip) {
	vec2 wind = normalize(axis + vec2(0.12, 0.36));
	vec2 side = vec2(-wind.y, wind.x);
	float along = dot(wp, wind);
	float across = dot(wp, side);
	float band = cloud_fbm(vec2(along * 0.036 + world_time * 1.4, across * 0.078), 2);
	float veil = cloud_fbm(vec2(along * 0.012 + world_time * 0.45, across * 0.026), 2);
	float flurry = smoothstep(0.40, 0.70, band) * 0.62 + smoothstep(0.26, 0.58, veil) * 0.42;
	return clamp(flurry * precip, 0.0, 1.0);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = (wp - world_origin) / world_size;

	// [cylindrical-earth-daylight] 逐像素晨昏线唯一真源：纬度近似 uv.y*2-1（与地形 lat_signed 同定义/同向）。
	// 同一时刻东西经度晨昏不同 → 云的明暗随晨昏线扫过，与地面/水面/植被完全一致（不再全图统一明暗）。
	float lat_signed = clamp(uv.y * 2.0 - 1.0, -1.0, 1.0);
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	FrontField w = sample_field_weather(wp);

	int biome = int(texture(map_index_atlas, uv).r * 255.0 + 0.5);
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

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
		vec2 s_uv = clamp(uv + m_offs[li] * ring_step + jj * 1.4 * ring_step, vec2(0.0), vec2(1.0));
		int bs = int(texture(map_index_atlas, s_uv).r * 255.0 + 0.5);
		bool s_water = (bs == B_OCEAN) || (bs == B_COAST) || (bs == B_LAKE)
				|| (bs == B_REEF) || (bs == B_KELP) || (bs == B_SEA_ICE);
		float bw = (bs == B_MOUNTAIN) ? 1.0 : ((bs == B_HILL) ? 0.65 : (s_water ? 0.0 : 0.35));
		float kw = (li == 0) ? 1.4 : 1.0;
		mw_sum += bw * kw;
		mw_tot += kw;
	}
	float mountain_w = clamp(mw_sum / max(mw_tot, 0.001)
			+ hash_signed(floor(wp * 0.085 + vec2(67.0, -31.0))) * 0.18, 0.0, 1.0);

	int q_weather = effective_weather_quality();
	vec2 cumulus_axis = w.axis;
	vec2 cirrus_axis = vec2(1.0, 0.15); // 卷云固定纬向（地球大气环流近似）

	// 高云强度：仅 STORM/MONSOON/RAIN 触发。
	float cirrus_intensity = 0.0;
	if (w.type == WT_STORM || w.type == WT_MONSOON) {
		cirrus_intensity = w.cloud * 0.70;
	} else if (w.type == WT_RAIN) {
		cirrus_intensity = w.cloud * 0.55;
	}
	float cirrus = (q_weather >= 1) ? sample_high_cloud(wp, cirrus_axis, cirrus_intensity) : 0.0;
	CloudLayerSample cirrus_layer = make_cloud_layer(
		remap_cloud_density(cirrus, cirrus_intensity, 0.16),
		smoothstep(0.05, 0.42, cirrus) * (1.0 - smoothstep(0.58, 0.96, cirrus)),
		cirrus_intensity,
		0.92
	);

	// 中云（主云）强度（w.cloud 已是语义云量，直接驱动 billboard 密度，不再二次打折）。
	float cumulus_intensity = (w.cloud > 0.02) ? w.cloud : 0.0;
	if (w.type == WT_STORM || w.type == WT_MONSOON) cumulus_intensity = clamp(cumulus_intensity * 1.15, 0.0, 1.0);
	CloudLayerSample cumulus_layer = sample_cumulus_layer(wp, cumulus_axis, cumulus_intensity);
	float cumulus = cumulus_layer.density;

	// 低雾强度（front 云量 + 山地权重）。
	float fog_intensity = 0.0;
	if (w.cloud > 0.05) {
		float wf = w.cloud * 0.65;
		if (w.type == WT_FOG) wf = max(wf, w.cloud * 1.30);
		if (w.type == WT_STORM || w.type == WT_MONSOON) wf *= 1.10;
		fog_intensity = wf;
	}
	float local_fog_w = mountain_w;
	if (w.type == WT_FOG) local_fog_w = min(max(local_fog_w, mountain_w * 1.6), 0.85);
	float low_fog = (q_weather >= 1) ? sample_low_fog(wp, w.axis, fog_intensity, local_fog_w) : 0.0;
	CloudLayerSample fog_layer = make_cloud_layer(
		remap_cloud_density(low_fog, max(fog_intensity, local_fog_w), 0.24),
		smoothstep(0.04, 0.42, low_fog) * (1.0 - smoothstep(0.54, 0.96, low_fog)),
		max(fog_intensity, local_fog_w),
		0.18
	);

	// 太阳方向密度梯度（迎光/背光），q0 关闭省一次云密度采样。
	float cumulus_light_grad = 0.0;
	if (q_weather >= 1 && cumulus_layer.density > 0.001) {
		vec2 sun_axis = cloud_sun_axis();
		float light_step = hex_world_diameter * ((q_weather >= 2) ? 0.62 : 0.42);
		CloudLayerSample light_probe = sample_cumulus_layer(wp + sun_axis * light_step, cumulus_axis, cumulus_intensity);
		cumulus_light_grad = clamp(cumulus_layer.density - light_probe.density, -1.0, 1.0);
	}
	float layer_occlusion = (q_weather >= 2)
		? clamp(fog_layer.density * 0.34 + cumulus_layer.density * 0.28, 0.0, 1.0)
		: 0.0;

	bool has_layer = (cumulus > 0.001) || (cirrus > 0.001) || (low_fog > 0.001) || (w.precip > 0.001);
	if (!has_layer) {
		COLOR = vec4(0.0);
	} else {
		int flags = (w.type >= 0 && w.type < MAX_WEATHER_TYPES) ? weather_profile_flags[w.type] : 0;

		// 主云（积云）：billboard 亮白为主，仅轻微类型色偏 + 夜间冷灰。
		vec3 main_base = mix(vec3(0.97, 0.98, 1.00), max(w.color, vec3(0.82, 0.85, 0.90)), 0.22);
		main_base = mix(main_base, vec3(0.55, 0.62, 0.72), ed.pixel_night);
		vec3 col = compute_cloud_lighting(cumulus_layer, main_base, w.type, cumulus_light_grad, (q_weather >= 2) ? 0.95 : 0.6, ed.sun_col, ed.amb_col, ed.local_day);
		float profile_alpha_factor = (w.type >= 0 && w.type < MAX_WEATHER_TYPES) ? (0.78 + w.alpha * 0.22) : 1.0;
		float alpha = clamp(cloud_density_alpha(cumulus_layer.density) * profile_alpha_factor * weather_strength * 0.50, 0.0, 0.58);

		// 地面投影阴影。
		float shadow_alpha = clamp(w.shadow * weather_strength * 0.20 * (1.0 - ed.pixel_night * 0.35), 0.0, 0.30);
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

		// 降雨。
		if ((flags & FLAG_RAIN_STREAK) != 0 && w.precip > 0.001) {
			float rain = rain_field(wp, w.axis, w.precip);
			vec3 rain_col = (w.type == WT_MONSOON) ? vec3(0.42, 0.56, 0.68) : vec3(0.52, 0.62, 0.74);
			col = mix(col, rain_col, rain * 0.68);
			alpha = clamp(alpha + rain * 0.50 * weather_strength, 0.0, 0.95);
			col *= mix(1.0, 0.55, rain * 0.85);
		}

		// 降雪。
		if ((flags & FLAG_SNOW_GRAIN) != 0 && w.precip > 0.001) {
			float snow = snow_field(wp, w.axis, w.precip);
			col = mix(col, vec3(0.88, 0.94, 1.0), snow * 0.66);
			alpha = clamp(alpha + snow * 0.38 * weather_strength, 0.0, 0.94);
		}

		// 雾呼吸（缓慢明暗起伏）。
		if ((flags & FLAG_FOG_BREATHE) != 0) {
			float breathe = sin(world_time * 0.55) * 0.035;
			col = mix(col, vec3(0.76, 0.79, 0.78), 0.28);
			alpha = clamp(alpha + (0.10 + breathe) * w.cloud * weather_strength, 0.0, 0.82);
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
