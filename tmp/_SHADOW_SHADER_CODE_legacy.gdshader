shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform float lod_alpha = 1.0;

uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);

uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float snow_hide_strength = 0.62;
uniform float aquatic_response = 0.0;

uniform vec4 shadow_color = vec4(0.05, 0.06, 0.08, 1.0);
uniform float shadow_strength = 0.28;
uniform float shadow_length_scale = 1.0;
uniform float shadow_max_len = 1.4;
uniform float shadow_min_sun_elevation = 0.16;
uniform float shadow_foot_radius = 0.55;   // 足部半径(局部单位; ×实例 size = 世界足印)
uniform float shadow_edge_softness = 0.25;  // 0..1 软边起点(越小越柔; r<此值为实心核心)

#include \"res://shaders/include/earth_daylight.gdshaderinc\"

varying float shadow_alpha_v;
varying float shadow_r;   // 单位径向 0(心)..1(缘)，用于柔边

int sh_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 sh_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

float sh_vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

void vertex() {
	vec2 uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
#ifdef PK_QUALITY_LOW
	VERTEX = vec2(0.0);
	shadow_r = 1.0;
	shadow_alpha_v = 0.0;
#else
	float lat_signed = uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	// presence-lite：枯死 / 积雪覆盖时阴影一并消失（与植株 compute_presence 同向，省去 eco fetch）。
	int cid = sh_decode_cell_index(uv);
	vec4 dyn = (cid >= 0) ? texture(dyn_lut, sh_cell_lut_uv(cid)) : vec4(0.0);
	float dyn_valid = 1.0;
	float vitality = mix(0.70, dyn.a, dyn_valid);
	vitality = mix(vitality, 0.86, aquatic_response);
	float snow = dyn.b * dyn_valid;
	float presence = pow(sh_vitality_norm(vitality), vitality_alpha_power);
	presence *= 1.0 - clamp(snow, 0.0, 1.0) * snow_hide_strength;

	// 太阳水平分量 → 背光方向 sdir（世界帧）；低太阳(竖直分量小)→ proj 拉长。
	vec2 sun_h = ed.sun_dir.xy;
	float sun_len = length(sun_h);
	float sun_up = max(ed.sun_dir.z, 0.0);
	vec2 sdir = (sun_len > 1e-4) ? -sun_h / sun_len : vec2(0.0, 1.0);
	float proj = clamp(sun_len / max(sun_up, shadow_min_sun_elevation), 0.0, shadow_max_len)
		* shadow_length_scale;

	// 本实例正交基（去缩放归一化）：把世界 sdir 转到局部帧，乘回 MODEL_MATRIX(含随机旋转) 后方向统一。
	vec2 inst_ax = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[0].y);
	vec2 inst_ay = vec2(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y);
	float inst_axl = length(inst_ax);
	float inst_ayl = length(inst_ay);
	vec2 nax = (inst_axl > 1e-5) ? inst_ax / inst_axl : vec2(1.0, 0.0);
	vec2 nay = (inst_ayl > 1e-5) ? inst_ay / inst_ayl : vec2(0.0, 1.0);
	vec2 sdl = vec2(dot(sdir, nax), dot(sdir, nay));     // 局部帧背光方向
	vec2 perp = vec2(-sdl.y, sdl.x);                      // 垂直方向(椭圆次轴)

	// 单位圆 VERTEX → 椭圆：主轴沿 sdl(足印半径 + 投影一半)，中心前移 proj/2；次轴沿 perp(足印半径)。
	// proj=0(太阳当顶) → 退化为足部圆盘(接触阴影)；proj 大(低太阳) → 长椭圆。
	vec2 p = VERTEX;
	float half_major = shadow_foot_radius + proj * 0.5;
	float center_along = proj * 0.5;
	VERTEX = sdl * (center_along + p.x * half_major) + perp * (p.y * shadow_foot_radius);

	shadow_r = length(p);   // 网格本身 |p|<=1，传给片元做径向柔边
	// 永昼低角度光会令密集实例阴影大面积重叠；减弱 alpha，但保留方向与移动感。
	shadow_alpha_v = shadow_strength * lod_alpha * ed.local_day * clamp(presence, 0.0, 1.0);
#endif
}

void fragment() {
	// 径向平滑：核心(r<softness)实心，向边缘平滑淡出至 0 → 柔边、无多边形轮廓。
	float edge = 1.0 - smoothstep(shadow_edge_softness, 1.0, shadow_r);
	float a = shadow_alpha_v * edge;
	a = (a < 0.003) ? 0.0 : a;
	COLOR = vec4(shadow_color.rgb, a);
}
