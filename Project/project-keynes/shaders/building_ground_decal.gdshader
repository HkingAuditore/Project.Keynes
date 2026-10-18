shader_type canvas_item;
render_mode unshaded;

// Settlement ground: plazas, streets, fields, pits, yards, solar arrays, stone
// circles, paddies, orchards, pastures, gardens, log yards, salt pans and
// quays. One instance = one oriented rectangle (basis lengths are the half
// extents); color.r = param, color.g = flag, custom.a = ground kind.

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform int visual_quality = 1;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4101523;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;

const float GROUND_AMBIENT_GAIN = 0.66;
const float GROUND_SUN_GAIN = 0.72;

// [building-terrain-light 2026-10-18] 聚落地面就是地形本身：高画质下坡度直接进法线
// （vertex 每实例一次），直射遮蔽 / 天空可见度在 fragment 按像素采样，与 world_map 同源。
// 低/中画质取中性值，v_amb + v_sun_l 与接入前的单块 v_light 数值等价。
#define VT_USE_HORIZON
#define VT_USE_TERRAIN_NORMAL
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform bool terrain_normal_tex_bound = false;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_normal_influence = 0.65;
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength = 0.90;
uniform float gi_ao_floor = 0.38;
uniform float gi_ao_smoothing = 0.75;
uniform float gi_bent_strength = 0.35;
uniform float gi_normal_floor = 0.85;
#include "res://shaders/include/earth_daylight.gdshaderinc"
vec2 wrap_map_uv(vec2 uv) { return visual_static_wrap_uv(uv); }
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#include "res://shaders/include/building_form.gdshaderinc"

varying vec2 v_p;
varying flat vec2 v_half;
varying flat vec4 v_ids;      // kind, era, archetype, seed
varying flat vec2 v_param;    // param, flag
varying flat float v_cell;
varying flat vec2 v_map_uv;   // 实例中心的 map uv，供逐像素重建地面位置
varying flat vec2 v_ux;       // 实例 x 轴单位向量（y 轴为其法向）
varying flat vec3 v_ground_n; // 地形法线（shader 空间，+z=天顶）
varying flat vec3 v_sun_dir;
varying flat vec3 v_amb;      // 天光 + 月光（已含 tod_exposure）
varying flat vec3 v_sun_l;    // 直射（已含 tod_exposure）
varying flat float v_season;  // hemisphere-corrected season, 0 spring .. 3 winter
varying flat float v_night;

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

void vertex() {
	vec2 ax = MODEL_MATRIX[0].xy;
	float hl = max(length(ax), 1e-4);
	float hw = max(length(MODEL_MATRIX[1].xy), 1e-4);
	v_half = vec2(hl, hw);
	v_ux = ax / hl;
	float style = floor(INSTANCE_CUSTOM.r * 65.0 + 0.5);
	v_ids = vec4(floor(INSTANCE_CUSTOM.a * 16.0), floor(style / 6.0), mod(style, 6.0),
		INSTANCE_CUSTOM.g);
	v_param = COLOR.rg;
	v_cell = INSTANCE_CUSTOM.b;
	vec2 p = VERTEX * (v_half + vec2(0.12));
	v_p = p;
	VERTEX = p / v_half;

	vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	vec2 map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	v_map_uv = map_uv;
	float lat_signed = clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
	v_season = mod(season_phase + (lat_signed < 0.0 ? 2.0 : 0.0), 4.0);
	EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);
	v_sun_dir = ed.sun_dir;
	// 铺装跟地形同坡：坡度直接进法线；低/中画质保持 +z，与接入前逐位一致。
	vec2 ground_slope = vec2(0.0);
	if (visual_quality >= 2 && terrain_normal_tex_bound) {
		ground_slope = (visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0)
			* terrain_normal_influence;
	}
	v_ground_n = normalize(vec3(ground_slope, 1.0));
	vec3 sun_term = ed.sun_col * max(dot(v_ground_n, ed.sun_dir), 0.0)
		* ed.local_day * GROUND_SUN_GAIN;
	vec3 amb_term = earth_sky_sh(ed.amb_col, ed.sun_col, ed.sun_dir, ed.local_day, v_ground_n)
		* GROUND_AMBIENT_GAIN + EARTH_MOONLIGHT * ed.moon_strength * 0.20;
	v_amb = amb_term * tod_exposure;
	v_sun_l = sun_term * tod_exposure;
	v_night = smoothstep(0.18, 0.62, ed.pixel_night);
}

float edge_fade(float d, float width, float px) {
	return smoothstep(0.0, width + px, -d);
}

// Crops ripen over the year; the variant picks grain, row crops or pasture.
vec3 field_color(vec2 p, float variant, float season, float px, out float rows) {
	float grow = season < 1.0 ? season : (season < 2.0 ? 1.0 + (season - 1.0) * 0.6 : 0.0);
	vec3 soil = vec3(0.43, 0.36, 0.27);
	vec3 young = vec3(0.40, 0.50, 0.24);
	vec3 crop;
	float row_freq = 3.2;
	if (variant < 0.45) {
		vec3 ripe = vec3(0.74, 0.62, 0.32);
		crop = mix(young, ripe, smoothstep(0.9, 1.5, grow));
		if (season >= 2.0 && season < 3.0) crop = mix(vec3(0.62, 0.53, 0.32), soil, (season - 2.0));
	} else if (variant < 0.8) {
		crop = mix(vec3(0.30, 0.42, 0.20), vec3(0.34, 0.46, 0.22), grow);
		row_freq = 2.4;
		if (season >= 2.0 && season < 3.0) crop = mix(crop, soil, (season - 2.0) * 0.8);
	} else {
		crop = mix(vec3(0.42, 0.50, 0.28), vec3(0.47, 0.52, 0.30), grow);
		row_freq = 0.0;
		if (season >= 2.0) crop = mix(crop, vec3(0.48, 0.45, 0.30), 0.5);
	}
	float cover = season < 1.0 ? smoothstep(0.1, 0.9, season) : (season < 3.0 ? 1.0 : 0.0);
	if (row_freq > 0.0) {
		rows = 0.5 + 0.5 * sin(p.y * 6.2831853 * row_freq);
		float fd = bf_detail(row_freq, px);
		cover *= mix(0.85, smoothstep(0.15, 0.65, rows), fd);
	} else {
		rows = 0.5;
	}
	vec3 c = mix(soil, crop, cover);
	c *= 0.90 + 0.16 * bf_fbm(p * 1.3 + variant * 41.0);
	return c;
}

void fragment() {
	int kind = int(v_ids.x + 0.5);
	float era = v_ids.y;
	float seed = v_ids.w;
	vec2 p = v_p;
	float px = max(length(fwidth(v_p)) * 0.7, 1e-4);

	vec2 cell_uv = lut_uv(v_cell);
	vec4 knowledge = texture(enum_lut, cell_uv);
	if (knowledge.a < 0.04) discard;
	vec4 dyn = texture(dyn_lut, cell_uv);
	vec4 weather = texture(weather_lut, cell_uv);
	bool live = knowledge.a > 0.88;

	vec3 c = vec3(0.4);
	float a = 0.0;
	float snow_hold = 1.0;
	vec3 emit = vec3(0.0);
	vec2 q = p + seed * 53.0;

	if (kind == BG_PLAZA) {
		float r = v_half.x / 1.25;
		float d = length(p) - r + (bf_vnoise(q * 1.4) - 0.5) * 0.25 * r;
		a = 1.0 - smoothstep(-0.25 * r, 0.12 * r, d);
		float wealth = v_param.x;
		if (era < 1.5 || wealth < 0.2) {
			c = vec3(0.45, 0.37, 0.27) * (0.85 + 0.25 * bf_fbm(q * 2.0));
		} else if (era < 6.0) {
			c = vec3(0.53, 0.49, 0.42);
			vec2 cq = q * vec2(3.0, 4.2);
			cq.x += floor(cq.y) * 0.5;
			vec2 cell_id = floor(cq);
			vec2 cob = abs(fract(cq) - 0.5);
			float stone = 0.88 + 0.18 * bf_hash12(cell_id + seed * 13.0);
			float joint = smoothstep(0.47, 0.38, max(cob.x, cob.y * 1.1));
			c *= mix(1.0, stone * (0.90 + 0.10 * joint), bf_detail(4.2, px));
			c *= 0.88 + 0.18 * bf_fbm(q * 1.2);
		} else {
			c = era < 8.0 ? vec3(0.60, 0.58, 0.54) : vec3(0.64, 0.64, 0.62);
			vec2 slab = abs(fract(q * 1.1) - 0.5);
			c *= mix(1.0, 0.90 + 0.10 * smoothstep(0.48, 0.44, max(slab.x, slab.y)), bf_detail(1.1, px));
		}
		// Poor squares wear back to trampled earth at the edges.
		if (era >= 1.5 && wealth < 0.4) {
			float worn = smoothstep(0.35, 0.75, bf_fbm(q * 0.9)) * (0.4 - wealth) / 0.2;
			c = mix(c, vec3(0.45, 0.38, 0.29), clamp(worn, 0.0, 1.0));
		}
		// Rich squares centre on a fountain (or, before piped water, a monument).
		if (era >= 1.5 && wealth > 0.7 && v_param.y < 0.5) {
			float rc = length(p);
			float rim = r * 0.20;
			float basin = 1.0 - smoothstep(rim - px, rim + px, rc);
			float lip = basin * smoothstep(rim * 0.72 - px, rim * 0.72 + px, rc);
			if (era >= 2.5) {
				vec3 water = vec3(0.22, 0.33, 0.38) * (0.9 + 0.2 * bf_vnoise(q * 6.0 + TIME * 0.4));
				c = mix(c, water, basin);
				c = mix(c, vec3(0.70, 0.67, 0.60), lip);
			} else {
				c = mix(c, vec3(0.62, 0.58, 0.50), basin);
			}
			float plinth = 1.0 - smoothstep(rim * 0.22 - px, rim * 0.22 + px, rc);
			c = mix(c, vec3(0.74, 0.71, 0.64), plinth);
			snow_hold = 0.6;
		}
		if (v_param.y > 0.5) {
			float hearth = 1.0 - smoothstep(0.12, 0.22, length(p));
			c = mix(c, vec3(0.16, 0.13, 0.11), hearth);
			emit = vec3(1.0, 0.48, 0.16) * (1.0 - smoothstep(0.0, 0.18, length(p)))
				* (0.25 + 0.75 * v_night) * (0.8 + 0.2 * sin(TIME * 7.0 + seed * 30.0));
		}
		snow_hold = 0.8;
	} else if (kind == BG_ROAD) {
		// A gentle meander keeps streets from reading as ruled lines.
		float along_t = (p.x + v_half.x) / (2.0 * v_half.x);
		float wander = (bf_vnoise(vec2(p.x * 0.16, seed * 17.0)) - 0.5) * v_half.y * 1.4
			* smoothstep(0.15, 0.5, along_t);
		vec2 rp = vec2(p.x, p.y - wander);
		float across = abs(rp.y) / v_half.y;
		float end_x = v_half.x - v_half.y;
		float d_side = abs(rp.y) - v_half.y * (1.0 + (bf_vnoise(q * vec2(0.8, 0.0)) - 0.5) * 0.25);
		float d_end = p.x - end_x;
		float tail = v_param.y > 0.5
			? (1.0 - smoothstep(-0.8, 0.0, d_end)) * mix(1.0, 0.45, smoothstep(0.45, 1.0, along_t))
			: 1.0;
		float cap = v_param.y > 0.5 ? 1.0 : 1.0 - smoothstep(-px, v_half.y * 0.6,
			length(vec2(max(d_end, 0.0), rp.y)) - v_half.y);
		a = (1.0 - smoothstep(-0.6 * v_half.y, 0.25 * v_half.y, d_side)) * tail * cap * 0.85;
		// Poor towns keep dirt streets one band longer than rich ones.
		float road_era = v_param.x < 0.2 ? min(era, 1.0) : (v_param.x < 0.4 ? era - 1.0 : era);
		if (road_era < 1.5) {
			c = vec3(0.47, 0.39, 0.29);
			float rut = smoothstep(0.08, 0.0, abs(across - 0.45));
			c *= 1.0 - rut * 0.18 * bf_detail(2.0, px);
			a *= 0.80;
		} else if (road_era < 6.0) {
			c = vec3(0.48, 0.43, 0.35) * (0.88 + 0.2 * bf_vnoise(q * 3.0));
			if (road_era >= 3.5) {
				vec2 cob = abs(fract(vec2(rp.x * 3.0, rp.y * 3.0) + seed) - 0.5);
				c = mix(c, vec3(0.56, 0.54, 0.50), 0.5);
				c *= mix(1.0, 0.86 + 0.14 * smoothstep(0.44, 0.34, max(cob.x, cob.y)), bf_detail(3.0, px));
			}
		} else if (road_era < 7.5) {
			c = vec3(0.42, 0.40, 0.37) * (0.9 + 0.15 * bf_vnoise(q * 4.0));
		} else {
			c = vec3(0.24, 0.245, 0.25) * (0.92 + 0.12 * bf_vnoise(q * 6.0));
			float lane = (1.0 - smoothstep(0.02, 0.05, abs(rp.y))) * step(0.5, fract(p.x * 1.2));
			c = mix(c, vec3(0.80, 0.78, 0.70), lane * 0.7 * bf_detail(1.2, px) * step(0.12, v_half.y));
			float curb = smoothstep(0.82, 0.92, across);
			c = mix(c, vec3(0.55, 0.55, 0.53), curb * 0.6);
			if (live && road_era >= 8.5) {
				float lamp = 1.0 - smoothstep(0.0, 0.25, length(vec2(fract(p.x * 0.7) - 0.5, (across - 0.95) * 0.4)));
				emit += vec3(1.0, 0.80, 0.52) * lamp * v_night * 0.5;
			}
		}
		snow_hold = road_era < 7.5 ? 1.0 : 0.6;
	} else if (kind == BG_FIELD) {
		float d = bf_box(p, v_half - vec2(0.05)) + (bf_vnoise(q * 1.1) - 0.5) * 0.18;
		a = edge_fade(d, 0.32, px) * 0.92;
		float rows;
		c = field_color(p, v_param.x, v_season, px, rows);
		if (v_param.y > 0.5) {
			float hedge = 1.0 - smoothstep(0.0, 0.10 + px, -d);
			float bush = 0.6 + 0.4 * bf_vnoise(q * 6.0);
			c = mix(c, vec3(0.20, 0.27, 0.14) * bush, hedge * 0.85);
		}
	} else if (kind == BG_PIT) {
		float r = length(p / v_half);
		float d = (r - 1.0) * min(v_half.x, v_half.y) + (bf_vnoise(q * 1.5) - 0.5) * 0.25;
		a = edge_fade(d, 0.25, px);
		float terrace = fract(r * 4.0);
		float depth = 1.0 - r;
		c = mix(vec3(0.52, 0.47, 0.40), vec3(0.30, 0.27, 0.24), depth);
		c *= mix(1.0, 0.82 + 0.18 * smoothstep(0.0, 0.25, terrace), bf_detail(4.0 / min(v_half.x, v_half.y), px));
		if (v_param.x < 0.3) c = mix(c, vec3(0.40, 0.36, 0.30), 0.4);
		if (v_param.x > 0.6) {
			float water = 1.0 - smoothstep(0.18, 0.24, r);
			c = mix(c, vec3(0.20, 0.27, 0.30), water);
		}
		snow_hold = 0.7;
	} else if (kind == BG_YARD) {
		float d = bf_box(p, v_half - vec2(0.08));
		a = edge_fade(d, 0.25, px) * 0.85;
		c = era < 6.0 ? vec3(0.44, 0.38, 0.30) : vec3(0.40, 0.39, 0.37);
		c *= 0.86 + 0.22 * bf_fbm(q * 2.4);
		float stack = step(0.72, bf_hash12(floor(q * 2.0)));
		c = mix(c, c * 0.62, stack * bf_detail(2.0, px) * 0.6);
		if (v_param.y > 0.5) {
			// Shanty mud: dark trodden earth with standing puddles.
			c = vec3(0.33, 0.27, 0.20) * (0.85 + 0.25 * bf_fbm(q * 3.1));
			float puddle = smoothstep(0.66, 0.72, bf_vnoise(q * 1.7));
			c = mix(c, vec3(0.22, 0.24, 0.24), puddle * 0.8);
			snow_hold = 0.8;
		}
	} else if (kind == BG_PADDY) {
		// Bunded rice terraces: flooded in spring, green in summer, gold at harvest.
		float d = bf_box(p, v_half - vec2(0.05)) + (bf_vnoise(q * 1.1) - 0.5) * 0.12;
		a = edge_fade(d, 0.20, px) * 0.94;
		float s = v_season;
		vec3 flood = vec3(0.30, 0.40, 0.42);
		vec3 green = vec3(0.36, 0.52, 0.22);
		vec3 gold = vec3(0.70, 0.62, 0.30);
		c = s < 1.0 ? mix(flood, green, smoothstep(0.4, 1.0, s))
			: (s < 2.0 ? mix(green, gold, smoothstep(1.2, 1.9, s))
			: (s < 3.0 ? mix(gold, vec3(0.45, 0.40, 0.30), s - 2.0) : flood * 0.9));
		float bund_x = abs(fract(p.x * 0.55 + v_param.x) - 0.5);
		float bund = smoothstep(0.46, 0.49, bund_x) * bf_detail(0.55, px);
		bund = max(bund, 1.0 - smoothstep(0.0, 0.07 + px, -d));
		c = mix(c, vec3(0.40, 0.36, 0.26), bund * 0.75);
		c *= 0.92 + 0.14 * bf_fbm(q * 2.2);
		snow_hold = 0.6;
	} else if (kind == BG_ORCHARD) {
		float d = bf_box(p, v_half - vec2(0.05)) + (bf_vnoise(q * 1.1) - 0.5) * 0.15;
		a = edge_fade(d, 0.25, px) * 0.92;
		vec3 grass = vec3(0.42, 0.49, 0.27) * (0.9 + 0.2 * bf_fbm(q * 1.5));
		if (v_param.y > 0.5) {
			// Fodder meadow: mown swaths and hay windrows.
			float swath = 0.5 + 0.5 * sin(p.y * 6.2831853 * 1.6 + bf_vnoise(q) * 2.0);
			c = mix(grass, vec3(0.62, 0.58, 0.34), smoothstep(0.55, 0.9, swath) * bf_detail(1.6, px)
				* step(1.0, v_season));
		} else {
			// Tree rows: dark canopy dots on a grass floor.
			vec2 g = p * vec2(1.6, 1.8) + v_param.x * 7.0;
			vec2 f = fract(g) - 0.5;
			float tree = 1.0 - smoothstep(0.26, 0.34 + px, length(f));
			vec3 canopy = v_season >= 2.0 && v_season < 3.0 ? vec3(0.50, 0.42, 0.20)
				: vec3(0.20, 0.32, 0.15);
			canopy *= 0.85 + 0.3 * bf_hash12(floor(g) + seed * 9.0);
			c = mix(grass, canopy, tree * mix(0.6, 1.0, bf_detail(1.8, px)));
		}
	} else if (kind == BG_PASTURE) {
		float d = bf_box(p, v_half - vec2(0.05)) + (bf_vnoise(q * 0.9) - 0.5) * 0.25;
		a = edge_fade(d, 0.35, px) * 0.85;
		vec3 lush = vec3(0.40, 0.50, 0.26);
		vec3 dry = vec3(0.55, 0.52, 0.34);
		c = mix(lush, dry, v_season >= 1.6 && v_season < 3.0 ? 0.5 : 0.1);
		c *= 0.86 + 0.24 * bf_fbm(q * 1.1);
		float track = smoothstep(0.62, 0.70, bf_vnoise(q * vec2(0.6, 2.4)));
		c = mix(c, vec3(0.47, 0.41, 0.31), track * 0.5);
		if (v_param.y > 0.5) {
			float fence = 1.0 - smoothstep(0.0, 0.05 + px, -d);
			c = mix(c, vec3(0.36, 0.30, 0.22), fence * 0.8);
		}
	} else if (kind == BG_GARDEN) {
		// Private garden: lawn, clipped beds and, for the rich, a pool.
		float d = bf_box(p, v_half - vec2(0.05));
		a = edge_fade(d, 0.18, px) * 0.95;
		float wealth = v_param.x;
		c = mix(vec3(0.40, 0.46, 0.27), vec3(0.34, 0.50, 0.24), wealth);
		c *= 0.90 + 0.16 * bf_fbm(q * 2.0);
		vec2 bed = abs(fract(p * vec2(1.2, 1.5) + seed) - 0.5);
		float shrub = smoothstep(0.30, 0.22, max(bed.x, bed.y)) * step(0.55, bf_hash12(floor(p * vec2(1.2, 1.5) + seed * 5.0)));
		c = mix(c, vec3(0.18, 0.30, 0.14), shrub * 0.7 * bf_detail(1.5, px));
		float hedge = 1.0 - smoothstep(0.0, 0.06 + px, -d);
		c = mix(c, vec3(0.20, 0.31, 0.15), hedge * clamp(wealth * 1.4, 0.0, 1.0));
		if (v_param.y > 0.5) {
			float pool = 1.0 - smoothstep(-px, px, bf_box(p - vec2(v_half.x * 0.25, 0.0),
				vec2(v_half.x * 0.32, v_half.y * 0.45)));
			vec3 water = era >= 7.5 ? vec3(0.30, 0.62, 0.72) : vec3(0.24, 0.38, 0.42);
			c = mix(c, water * (0.92 + 0.12 * bf_vnoise(q * 5.0 + TIME * 0.3)), pool);
		}
	} else if (kind == BG_LOG_YARD) {
		float d = bf_box(p, v_half - vec2(0.06));
		a = edge_fade(d, 0.20, px) * 0.9;
		c = vec3(0.42, 0.35, 0.26) * (0.85 + 0.2 * bf_fbm(q * 2.5));
		vec2 g = vec2(p.x * 0.8, p.y * 6.0);
		float pile = step(0.45, bf_hash12(vec2(floor(g.x), 0.0) + seed * 3.0));
		float log_line = smoothstep(0.30, 0.12, abs(fract(g.y) - 0.5)) * bf_detail(6.0, px);
		c = mix(c, mix(vec3(0.52, 0.38, 0.22), vec3(0.62, 0.48, 0.30), log_line), pile * 0.85);
		snow_hold = 0.9;
	} else if (kind == BG_SALT_PAN) {
		float d = bf_box(p, v_half - vec2(0.05));
		a = edge_fade(d, 0.15, px) * 0.95;
		vec2 g = p * vec2(0.9, 1.4) + v_param.x * 5.0;
		vec2 f = abs(fract(g) - 0.5);
		float dyke = smoothstep(0.42, 0.47, max(f.x, f.y)) * bf_detail(1.4, px);
		float stage = bf_hash12(floor(g) + seed * 7.0);
		vec3 brine = mix(vec3(0.42, 0.56, 0.58), vec3(0.62, 0.58, 0.60), stage);
		vec3 crust = vec3(0.90, 0.89, 0.85);
		c = mix(brine, crust, smoothstep(0.55, 0.85, stage));
		c = mix(c, vec3(0.46, 0.41, 0.33), dyke * 0.8);
		snow_hold = 0.4;
	} else if (kind == BG_QUAY) {
		// Waterfront: timber jetty planks, or a concrete quay with bollards.
		float d = bf_box(p, v_half - vec2(0.04));
		a = edge_fade(d, 0.10, px);
		if (v_param.y > 0.5) {
			c = vec3(0.56, 0.55, 0.52) * (0.92 + 0.12 * bf_vnoise(q * 4.0));
			float bollard = 1.0 - smoothstep(0.05, 0.05 + px, length(vec2(fract(p.x * 0.8) - 0.5, p.y - v_half.y * 0.75)));
			c = mix(c, vec3(0.20, 0.20, 0.21), bollard);
		} else {
			float plank = abs(fract(p.x * 3.4 + seed) - 0.5);
			c = vec3(0.46, 0.36, 0.24) * (0.85 + 0.2 * bf_hash12(vec2(floor(p.x * 3.4 + seed), 1.0)));
			c *= mix(1.0, 0.78 + 0.22 * smoothstep(0.48, 0.42, plank), bf_detail(3.4, px));
		}
		snow_hold = 0.7;
	} else if (kind == BG_SOLAR) {
		float d = bf_box(p, v_half - vec2(0.05));
		a = edge_fade(d, 0.1, px);
		c = vec3(0.40, 0.44, 0.30);
		vec2 g = vec2(p.x * 0.9, p.y * 2.6);
		vec2 f = fract(g);
		float panel = step(0.06, f.x) * step(f.x, 0.94) * step(0.14, f.y) * step(f.y, 0.78);
		panel = mix(0.7, panel, bf_detail(2.6, px));
		c = mix(c, vec3(0.10, 0.15, 0.27), panel);
		float h = smoothstep(0.7, 0.78, f.y) * panel;
		c += vec3(0.25, 0.30, 0.36) * h * 0.3;
		snow_hold = 0.35;
	} else if (kind == BG_STONE_RING) {
		float r = length(p);
		float ring_r = v_half.x * 0.78;
		float ground = 1.0 - smoothstep(ring_r * 0.95, v_half.x, r);
		c = vec3(0.44, 0.43, 0.32) * (0.9 + 0.2 * bf_fbm(q * 2.0));
		a = ground * 0.4;
		float stones = 0.0;
		float count = 9.0 + floor(v_param.x * 5.0);
		float ang = atan(p.y, p.x) / 6.2831853 * count;
		float local = fract(ang) - 0.5;
		float radial = r - ring_r;
		vec2 sp = vec2(local * 6.2831853 * ring_r / count, radial);
		stones = 1.0 - smoothstep(0.08, 0.08 + px, length(sp / vec2(1.0, 1.4)));
		c = mix(c, vec3(0.52, 0.50, 0.46), stones);
		a = max(a, stones);
	}

	if (a < 0.004) discard;
	if (live) {
		float wet = clamp(dyn.g * weather.g, 0.0, 1.0);
		c *= 1.0 - wet * 0.22;
		c = mix(c, vec3(0.86, 0.89, 0.93), clamp(dyn.b * 1.2, 0.0, 1.0) * snow_hold * 0.9);
	}
	// 逐像素地面位置：只有跨过一条山脊的铺装才会在内部出现明暗过渡。
	vec2 uy = vec2(-v_ux.y, v_ux.x);
	vec2 map_uv = v_map_uv + (v_ux * p.x + uy * p.y) / max(world_size, vec2(0.0001));
	float direct = 1.0;
	float sky = 1.0;
	if (visual_quality >= 2 && terrain_horizon_strength > 0.0) {
		TerrainHorizonSample hs = terrain_horizon_evaluate(map_uv, v_sun_dir);
		if (hs.has_data) {
			direct = hs.direct_visibility;
			sky = terrain_horizon_apply_normal(hs.sky_visibility, v_ground_n, hs.bent_normal);
		}
	}
	c *= v_amb * sky + v_sun_l * direct;
	if (live) c += emit * tod_exposure;
	if (!live) {
		float gray = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(gray), c, 0.30) * 0.72;
	}
	COLOR = vec4(c, a * smoothstep(0.36, 0.54, camera_zoom));
}
