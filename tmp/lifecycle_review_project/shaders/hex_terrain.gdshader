shader_type canvas_item;
render_mode unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// 纸质地图册风格地形 shader (Atlas v1)
// 设计原则：
//   - 不画方向性光照，不画庄稼行/沙丘等周期性图案
//   - 每个生物群系是一片接近平面色的柔和印刷色，跨格连续
//   - hex 边界由低频侵蚀场扭曲后再做 cube_round 归属判定，看上去是自然地理弯线
//   - 邻居混合只发生在最外圈薄薄一层，避免"果冻边"
//
// 顶点属性契约：
//   COLOR.r  = terrain_id / 15.0
//   COLOR.g  = elevation [0, 1]
//   COLOR.b  = coastal [0, 1]
//   COLOR.a  = packed_seed
//   UV.xy    = 格内局部坐标（hex_size 归一化，中心=0）
//   CUSTOM0  = (tid_self/15, tid_nb_l/15, tid_nb_r/15, w_self)
//   CUSTOM1  = (cell_q, cell_r, w_nb_l, w_nb_r)

const int T_OCEAN     = 0;
const int T_COAST     = 1;
const int T_PLAIN     = 2;
const int T_GRASSLAND = 3;
const int T_FOREST    = 4;
const int T_HILL      = 5;
const int T_MOUNTAIN  = 6;
const int T_DESERT    = 7;
const int T_TUNDRA    = 8;
const int T_SNOW      = 9;

uniform float hex_size = 26.0;
uniform float texture_strength : hint_range(0.0, 1.0) = 1.0;     // 占位：影响大区亮度变化幅度
uniform float organic_warp : hint_range(0.0, 2.0) = 1.0;          // 占位：未使用方向 warp，仅占位
uniform float edge_roughness : hint_range(0.0, 1.5) = 1.0;        // 占位：未使用

// 邻居混合（极薄外环）
uniform float blend_edge_start : hint_range(0.0, 1.0) = 0.92;
uniform float blend_edge_end   : hint_range(0.5, 1.3) = 1.06;
uniform float blend_noise_amp  : hint_range(0.0, 1.0) = 0.35;
uniform float blend_max_weight : hint_range(0.0, 1.0) = 0.25;

// Domain Warp（侵蚀边界）
uniform float domain_warp_amp : hint_range(0.0, 0.45) = 0.14;
uniform float domain_warp_freq : hint_range(0.006, 0.05) = 0.026;

// 占位 uniform，保留 .tscn / 旧 setter 兼容
uniform float water_wave_speed : hint_range(0.0, 2.0) = 0.0;
uniform vec2 light_dir = vec2(0.0, 0.0);
uniform float elevation_contrast : hint_range(0.0, 1.0) = 0.0;
uniform vec3 deep_ocean_color : source_color = vec3(0.142, 0.245, 0.395);
uniform vec3 mid_ocean_color : source_color = vec3(0.205, 0.355, 0.495);
uniform vec3 shallow_color : source_color = vec3(0.345, 0.515, 0.620);
uniform vec3 coast_water_color : source_color = vec3(0.420, 0.625, 0.690);
uniform vec3 beach_color : source_color = vec3(0.860, 0.830, 0.700);

varying vec2 v_pos;
varying vec2 v_local;
varying float v_tid_norm;
varying float v_elevation;
varying float v_coastal;
varying float v_seed;

varying vec4 v_cust0;
varying vec4 v_cust1;

float sat(float v) {
	return clamp(v, 0.0, 1.0);
}

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) break;
		sum += value_noise(p * freq) * amp;
		freq *= 2.03;
		amp *= 0.48;
	}
	return sum;
}

float hex_metric(vec2 local) {
	vec2 p = abs(local);
	return max(p.x * 1.1547005, p.y + p.x * 0.5773503);
}

vec3 world_to_cube_f(vec2 pos, float size) {
	float q_f = (sqrt(3.0) / 3.0 * pos.x - 1.0 / 3.0 * pos.y) / size;
	float r_f = (2.0 / 3.0 * pos.y) / size;
	float s_f = -q_f - r_f;
	return vec3(q_f, r_f, s_f);
}

ivec3 cube_round(vec3 c) {
	float rq = floor(c.x + 0.5);
	float rr = floor(c.y + 0.5);
	float rs = floor(c.z + 0.5);
	float dq = abs(rq - c.x);
	float dr = abs(rr - c.y);
	float ds = abs(rs - c.z);
	if (dq > dr && dq > ds) {
		rq = -rr - rs;
	} else if (dr > ds) {
		rr = -rq - rs;
	} else {
		rs = -rq - rr;
	}
	return ivec3(int(rq), int(rr), int(rs));
}

// 低频侵蚀式扰动：让 hex 间分界看起来像被流水/风化推出来的缓弯，而不是 60° 直线
vec2 erosion_boundary_warp(vec2 wp) {
#ifdef PK_QUALITY_LOW
	return vec2(0.0);
#else
	vec2 p = wp * domain_warp_freq;

	vec2 pre = vec2(
		fbm(p * 0.55 + vec2(19.31, -7.23), 2),
		fbm(p * 0.55 + vec2(-11.73, 31.91), 2)
	);
	vec2 q = p + (pre - 0.5) * 1.35;

	vec2 broad = vec2(
		fbm(q + vec2(37.19, 13.71), 3),
		fbm(q + vec2(-21.47, 89.53), 3)
	) - 0.5;

	float e = 0.85;
	float hx = fbm(q + vec2(e, 0.0), 3) - fbm(q - vec2(e, 0.0), 3);
	float hy = fbm(q + vec2(0.0, e), 3) - fbm(q - vec2(0.0, e), 3);
	vec2 flow = vec2(hy, -hx);

	vec2 mid = vec2(
		fbm(q * 1.55 + vec2(5.7, -42.2), 2),
		fbm(q * 1.55 + vec2(-33.1, 8.4), 2)
	) - 0.5;

	vec2 warp_dir = broad * 0.70 + flow * 0.82 + mid * 0.34;
	return warp_dir * hex_size * domain_warp_amp * 1.35;
#endif
}

// 地图册调色板：参考国家地理 / Times Atlas 的柔和印刷色
vec3 terrain_base_color(int tid) {
	if (tid == T_OCEAN)     return vec3(0.215, 0.360, 0.510);
	if (tid == T_COAST)     return vec3(0.405, 0.610, 0.690);
	if (tid == T_PLAIN)     return vec3(0.910, 0.875, 0.700);
	if (tid == T_GRASSLAND) return vec3(0.745, 0.815, 0.560);
	if (tid == T_FOREST)    return vec3(0.475, 0.645, 0.435);
	if (tid == T_HILL)      return vec3(0.795, 0.720, 0.490);
	if (tid == T_MOUNTAIN)  return vec3(0.685, 0.625, 0.525);
	if (tid == T_DESERT)    return vec3(0.945, 0.870, 0.640);
	if (tid == T_TUNDRA)    return vec3(0.775, 0.785, 0.715);
	return vec3(0.965, 0.965, 0.965); // SNOW
}

bool is_water_tid(int tid) {
	return tid == T_OCEAN || tid == T_COAST;
}

// 单一陆地着色：基色 + 极轻的低频亮度抖动；不再画方向性 / 周期性图案
vec3 land_colored(int tid, vec2 wp) {
	vec3 base = terrain_base_color(tid);

	// 大区低频亮度（跨多个 hex 连续），±~5%
#ifdef PK_QUALITY_LOW
	return base;
#else
	float regional = fbm(wp * 0.012 + vec2(17.0, -23.0), 3);
	float micro = fbm(wp * 0.045 + vec2(-9.0, 11.0), 2);
	float light = 1.0 + (regional - 0.5) * 0.08 * texture_strength
					+ (micro - 0.5) * 0.035 * texture_strength;
	return base * light;
#endif
}

// 水体：深 → 浅两阶 + 低频亮度变化，不再画水波
vec3 water_colored(int tid, vec2 wp, float elevation) {
	vec3 deep = terrain_base_color(T_OCEAN);
	vec3 shallow_col = terrain_base_color(T_COAST);

	float depth_factor = (tid == T_COAST) ? 0.80 : sat(elevation * 1.6);
	vec3 base = mix(deep, shallow_col, depth_factor);

#ifdef PK_QUALITY_LOW
	return base;
#else
	float regional = fbm(wp * 0.010 + vec2(31.0, 7.0), 3);
	float light = 1.0 + (regional - 0.5) * 0.06;
	return base * light;
#endif
}

vec3 terrain_shade(int tid, vec2 wp, float elevation) {
	if (is_water_tid(tid)) {
		return water_colored(tid, wp, elevation);
	}
	return land_colored(tid, wp);
}

void vertex() {
	v_pos = VERTEX;
	v_local = UV;
	v_tid_norm = COLOR.r;
	v_elevation = COLOR.g;
	v_coastal = COLOR.b;
	v_seed = COLOR.a;
	v_cust0 = CUSTOM0;
	v_cust1 = CUSTOM1;
}

void fragment() {
	vec2 wp = v_pos;
	vec2 local = v_local;

	// 粗筛：fragment 离格中心明显超过 1 + warp_amp 的部分直接 discard，避免拖尾
	float hex_m_raw = hex_metric(local);
	if (hex_m_raw > 1.0 + domain_warp_amp * 1.35 + 0.04) {
		discard;
	}

	// 侵蚀式低频扰动 → cube_round 归属判定
	vec2 wp_warped = wp + erosion_boundary_warp(wp);
	vec2 cell_qr = v_cust1.xy;
	vec3 sample_cube = world_to_cube_f(wp_warped, hex_size);
	ivec3 rounded = cube_round(sample_cube);
	if (float(rounded.x) != cell_qr.x || float(rounded.y) != cell_qr.y) {
		discard;
	}

	float hex_m = hex_metric(local);

	float elevation = sat(v_elevation);
	float coastal = v_coastal;

	// 解码 river proximity（仅用于轻微河岸湿色）
	float river_prox = 0.0;
	float raw_seed = v_seed;
	if (raw_seed > 0.9) {
		river_prox = (raw_seed - 0.9) * 10.0;
	}

	int tid_s = int(floor(v_cust0.x * 15.0 + 0.5));
	int tid_l = int(floor(v_cust0.y * 15.0 + 0.5));
	int tid_r = int(floor(v_cust0.z * 15.0 + 0.5));
	bool has_l = tid_l != tid_s;
	bool has_r = tid_r != tid_s;

	// 极薄外圈混合带（默认仅外 8% 区域）
	float edge_t = smoothstep(blend_edge_start, blend_edge_end, hex_m);

	float n_a = 0.5;
#ifndef PK_QUALITY_LOW
	n_a = fbm(wp * 0.045 + vec2(7.0, -13.0), 2);
#endif
	float bias = (n_a - 0.5);

	float dir_signal = clamp(v_cust1.z - v_cust1.w, -1.0, 1.0);
	float steer = dir_signal + bias * blend_noise_amp;

	float vote_l = sat(steer) * edge_t * (has_l ? 1.0 : 0.0);
	float vote_r = sat(-steer) * edge_t * (has_r ? 1.0 : 0.0);

	float vote_sum = vote_l + vote_r;
	float total_nb = min(vote_sum, blend_max_weight);
	if (vote_sum > 0.0001) {
		float k = total_nb / vote_sum;
		vote_l *= k;
		vote_r *= k;
	}
	float w_self = 1.0 - (vote_l + vote_r);

	vec3 col_s = terrain_shade(tid_s, wp, elevation);
	vec3 col = col_s * w_self;
	if (vote_l > 0.001 && tid_l != tid_s) {
		col += terrain_shade(tid_l, wp, elevation) * vote_l;
	} else {
		col += col_s * vote_l;
	}
	if (vote_r > 0.001 && tid_r != tid_s) {
		col += terrain_shade(tid_r, wp, elevation) * vote_r;
	} else {
		col += col_s * vote_r;
	}

	// 河流湿润区：仅做极轻冷色偏移，不画暗带
	if (!is_water_tid(tid_s) && river_prox > 0.0) {
		vec3 wet_tint = vec3(0.55, 0.70, 0.78);
		col = mix(col, wet_tint, river_prox * river_prox * 0.10);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
