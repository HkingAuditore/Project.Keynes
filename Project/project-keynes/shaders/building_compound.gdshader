shader_type canvas_item;
render_mode unshaded;
#ifdef PK_WEB_BUILDING_MIN
// Web restricted tier: these building shaders never include
// shader_quality.gdshaderinc, so they never received MOBILE_QUALITY_LOW.
// Without it the LOW branch of terrain_horizon.gdshaderinc does not apply and
// the gi_horizon_lut dynamic-array loop (8 iterations x 4 taps) is not DCE'd,
// which made the first compile 15-22 s in the browser. On web terrain_horizon_tex
// is always null, and the LOW branch builds the same neutral struct as the
// unbound-early-out branch, so the image is bit-identical.
#define MOBILE_QUALITY_LOW
#endif

// One instance is one building volume (footprint + eave/ridge heights + roof
// form + material, see building_form.gdshaderinc). The quad is expanded in the
// vertex stage to cover the footprint and its leaned roof; the fragment stage
// corrects one parallax step onto the roof height field, intersects the walls
// analytically, lights the result with the shared earth daylight, and paints
// procedural roof materials.

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform float geometry_alpha = 1.0;
uniform int visual_quality = 1;
// Instances whose in-cell importance rank (COLOR.a) exceeds this collapse.
uniform float lod_fraction = 1.0;
// Screen-space lean per world unit of height. The map camera looks straight
// down; a slight lean toward screen-up keeps one facade sliver readable.
uniform float oblique = 0.30;

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

// Windows are emissive only after the local sun has crossed into night. Keep
// the transition soft so the whole map does not pop when the terminator moves.
const float BUILDING_WINDOW_NIGHT_START = 0.18;
const float BUILDING_WINDOW_NIGHT_FULL = 0.62;
const float BUILDING_WINDOW_LIGHT_GAIN = 1.45;
const float BUILDING_WINDOW_HALO_GAIN = 0.34;
const float BUILDING_AMBIENT_GAIN = 0.62;
const float BUILDING_SUN_GAIN = 0.78;
const float BUILDING_MOON_GAIN = 0.40;

// [building-terrain-light 2026-10-18] 高画质（visual_quality >= 2）下建筑不再自成一套光照：
//   地形法线：vertex 按实例中心 map uv 采一次，flat varying 带进 fragment（每栋建筑一次 fetch）；
//   horizon GI：fragment 用逐像素重建的 map uv 采样，一次拿直射遮蔽 / 天空可见度 / bent normal。
// 与 world_map、植被共用 visual_tile_sampling + terrain_horizon 的解码与强度参数，所以
// 同一格里的屋顶、田地和地形不会各算一套光。低/中画质取中性值，与接入前逐位一致。
#define VT_USE_HORIZON
#define VT_USE_TERRAIN_NORMAL
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform bool terrain_normal_tex_bound = false;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_normal_influence = 0.65;
// 建筑体量跟随地形坡向的比例。坡度是**加**到自身法线上的（不是插值），否则屋面彼此的
// 夹角会被压平；这样整栋建筑随坡面偏明暗，屋顶的坡面层次仍然保留。
uniform float building_terrain_tilt = 0.55;
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
varying flat vec2 v_height;
varying flat vec2 v_ux;
varying flat vec2 v_lift;
varying flat vec4 v_ids;      // form, material, era, archetype
varying flat vec2 v_seed_cell;
varying flat vec2 v_map_uv;
varying flat vec3 v_ground_n;  // 实例中心的地形法线（shader 空间，+z=天顶）
varying flat vec3 v_sun_dir;
varying flat vec3 v_sun_col;
varying flat vec3 v_amb_col;
varying flat vec3 v_day;      // local_day, pixel_night, moon_strength

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

void vertex() {
	vec2 ax = MODEL_MATRIX[0].xy;
	vec2 ay = MODEL_MATRIX[1].xy;
	float hl = max(length(ax), 1e-4);
	float hw = max(length(ay), 1e-4);
	vec2 ux = ax / hl;
	vec2 uy = ay / hw;
	v_half = vec2(hl, hw);
	v_ux = ux;
	v_height = vec2(COLOR.r, COLOR.g) * BF_HEIGHT_RANGE;
	int form = int(INSTANCE_CUSTOM.a * BF_FORM_SCALE);
	int mat = int(COLOR.b * 16.0);
	float style = floor(INSTANCE_CUSTOM.r * 65.0 + 0.5);
	v_ids = vec4(float(form), float(mat), floor(style / 6.0), mod(style, 6.0));
	v_seed_cell = INSTANCE_CUSTOM.gb;
	vec2 lean = vec2(0.0, -oblique);
	v_lift = vec2(dot(lean, ux), dot(lean, uy));

	vec2 extent = v_half;
	if (form == BF_WINDMILL) {
		extent = vec2(bf_sail_radius(mat, v_half.y) + 0.1);
	}
	vec2 shift = v_lift * v_height.y;
	vec2 margin = vec2(visual_quality > 0 ? 0.9 : 0.25);
	vec2 lo = -extent - margin + min(vec2(0.0), shift);
	vec2 hi = extent + margin + max(vec2(0.0), shift);
	vec2 p = mix(lo, hi, VERTEX * 0.5 + 0.5);
	v_p = p;
	// A culled instance collapses to its origin and rasterises nothing.
	VERTEX = p / v_half * step(COLOR.a, lod_fraction);

	vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	v_map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	float lat_signed = clamp(v_map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(v_map_uv, lat_signed, day_night_enabled);
	v_sun_dir = ed.sun_dir;
	v_sun_col = ed.sun_col;
	v_amb_col = ed.amb_col;
	v_day = vec3(ed.local_day, ed.pixel_night, ed.moon_strength);

	// 地形法线每实例只采一次：坡度在 fragment 里作为整栋建筑的基面倾角，
	// 不随像素变化（建筑是刚体，屋面起伏由自身高度场给出）。
	vec2 ground_slope = vec2(0.0);
	if (visual_quality >= 2 && terrain_normal_tex_bound) {
		ground_slope = (visual_sample_terrain_normal(v_map_uv).rg * 2.0 - 1.0)
			* terrain_normal_influence;
	}
	v_ground_n = normalize(vec3(ground_slope, 1.0));
}

float footprint(vec2 p) {
	return bf_footprint(int(v_ids.x), p, v_half);
}

float roof_z(vec2 p) {
	return bf_roof_height(int(v_ids.x), p, v_half, v_height.x, v_height.y);
}

vec3 to_world(vec3 n) {
	vec2 uy = vec2(-v_ux.y, v_ux.x);
	return normalize(vec3(v_ux * n.x + uy * n.y, n.z));
}

// 建筑体量的基面倾角：把地形坡度加到自身法线的水平分量上，再归一化。
// v_ground_n 在低/中画质或未绑定法线纹理时恒为 +z，这里精确退化为原法线。
vec3 tilt_to_ground(vec3 n) {
	if (v_ground_n.z >= 0.9999) {
		return n;
	}
	return normalize(vec3(n.xy + v_ground_n.xy * building_terrain_tilt, n.z));
}

// 逐像素 map uv：quad 在实例局部平面 v_p 上展开，实例中心 uv 加上局部偏移除以世界尺寸。
// 地图是 top-down 投影，倾斜量（v_lift）只移动屏幕位置，不改变地面落点，所以不参与换算。
vec2 pixel_map_uv(vec2 s) {
	vec2 uy = vec2(-v_ux.y, v_ux.x);
	return v_map_uv + (v_ux * s.x + uy * s.y) / max(world_size, vec2(0.0001));
}

// 只有高画质付 horizon 的 4 次采样；其余情况返回精确中性值，不碰纹理。
// covered=false 是 quad 的留白区（比足印大一圈，含倾斜量），那里不会写任何颜色。
TerrainHorizonSample building_horizon(vec2 map_uv, bool covered) {
	TerrainHorizonSample neutral;
	neutral.direct_visibility = 1.0;
	neutral.sky_visibility = 1.0;
	neutral.bent_normal = vec3(0.0, 0.0, 1.0);
	neutral.nearest_packed = vec4(0.0);
	neutral.has_data = false;
	if (!covered || visual_quality < 2 || terrain_horizon_strength <= 0.0) {
		return neutral;
	}
	return terrain_horizon_evaluate(map_uv, v_sun_dir);
}

// 一个 fragment 里最多会叠 3 层（屋面 + 墙面 + 窗/内院），但地面位置相同，所以 horizon
// 采样在 fragment 顶部做一次、按值传进来——每多一次调用就多 4 次 tap。
vec3 light_at(vec3 n, TerrainHorizonSample hs) {
	float ndl = max(dot(n, v_sun_dir), 0.0) * v_day.x * hs.direct_visibility;
	float mdl = max(dot(n, -v_sun_dir), 0.0) * v_day.z;
	vec3 amb_n = n;
	float sky = 1.0;
	if (hs.has_data) {
		// 与 brdf.gi_ambient_normal / gi_ambient_occlusion 同源：bent normal 只改天光方向，
		// sky visibility 乘在天光强度上，两者来自同一次 horizon 采样。
		amb_n = normalize(mix(n, hs.bent_normal, gi_bent_strength));
		sky = terrain_horizon_apply_normal(hs.sky_visibility, n, hs.bent_normal);
	}
	vec3 amb = earth_sky_sh(v_amb_col, v_sun_col, v_sun_dir, v_day.x, amb_n);
	// The reduced ambient gain balances roofs against direct sun; at night the
	// sky is the only light the terrain gets, so roofs must match it.
	float amb_gain = mix(1.0, BUILDING_AMBIENT_GAIN, v_day.x);
	return (amb * amb_gain * sky + v_sun_col * ndl * BUILDING_SUN_GAIN
		+ EARTH_MOONLIGHT * mdl * BUILDING_MOON_GAIN) * tod_exposure;
}

// Courses run along `along`, rows step down the slope along `across`.
vec3 roof_albedo(int mat, vec2 P, float along, float across, float px,
		float seed, float era, out float spec, out float snow_hold) {
	vec2 q = P + seed * 37.0;
	float n = bf_fbm(q * 1.7);
	spec = 0.0;
	snow_hold = 0.9;
	vec3 c = vec3(0.5);
	if (mat == BM_THATCH) {
		c = mix(vec3(0.55, 0.45, 0.28), vec3(0.66, 0.55, 0.34), seed);
		float streak = bf_vnoise(vec2(along * 9.0, across * 1.4) + seed * 13.0);
		c *= 0.80 + 0.32 * mix(0.5, streak, bf_detail(9.0, px));
		c = mix(c, vec3(0.36, 0.38, 0.24), smoothstep(0.58, 0.82, n) * 0.40);
	} else if (mat == BM_SHINGLE || mat == BM_TILE || mat == BM_SLATE || mat == BM_BRICK) {
		float rows = mat == BM_TILE ? 6.0 : (mat == BM_SLATE ? 6.5 : 5.0);
		vec3 a = mat == BM_TILE ? vec3(0.60, 0.31, 0.20)
			: (mat == BM_SLATE ? vec3(0.30, 0.32, 0.36)
			: (mat == BM_BRICK ? vec3(0.52, 0.29, 0.21) : vec3(0.42, 0.35, 0.29)));
		vec3 b = mat == BM_TILE ? vec3(0.70, 0.43, 0.28)
			: (mat == BM_SLATE ? vec3(0.37, 0.37, 0.42)
			: (mat == BM_BRICK ? vec3(0.60, 0.36, 0.26) : vec3(0.50, 0.42, 0.33)));
		c = mix(a, b, seed);
		float row = across * rows;
		float fd = bf_detail(rows, px);
		float jitter = bf_hash12(vec2(floor(along * rows * 0.8 + floor(row) * 0.5), floor(row)) + seed);
		c *= mix(1.0, 0.86 + 0.26 * jitter, fd);
		c *= mix(1.0, 0.74 + 0.26 * smoothstep(0.0, 0.22, fract(row)), fd);
		if (mat == BM_TILE) {
			c *= mix(1.0, 0.90 + 0.12 * cos(along * 6.2831853 * 6.0), bf_detail(6.0, px));
		}
		c = mix(c, c * vec3(0.78, 0.84, 0.70), smoothstep(0.6, 0.85, n) * 0.5);
		spec = mat == BM_SLATE ? 0.10 : 0.04;
	} else if (mat == BM_METAL) {
		c = mix(vec3(0.54, 0.55, 0.55), vec3(0.47, 0.40, 0.34), smoothstep(0.55, 0.85, n) * seed * 0.45);
		c *= mix(1.0, 0.90 + 0.10 * sin(along * 6.2831853 * 9.0), bf_detail(9.0, px));
		spec = 0.30;
		snow_hold = 0.75;
	} else if (mat == BM_BITUMEN) {
		c = vec3(0.27, 0.27, 0.28) * (0.88 + 0.22 * bf_vnoise(q * 9.0));
		spec = 0.05;
	} else if (mat == BM_CONCRETE) {
		c = vec3(0.64, 0.63, 0.60) * (0.92 + 0.10 * n);
		vec2 g = q * 1.1;
		vec2 gi = floor(g);
		float has = step(0.55, bf_hash12(gi + 3.1));
		vec2 off = vec2(bf_hash12(gi + 7.3), bf_hash12(gi + 1.9)) * 0.5 + 0.25;
		float unit = 1.0 - smoothstep(0.10, 0.10 + px, bf_box(fract(g) - off, vec2(0.14, 0.10)));
		c = mix(c, vec3(0.50, 0.51, 0.50), unit * has * bf_detail(1.1, px));
	} else if (mat == BM_GLASS) {
		// Curtain-wall towers still carry a membrane roof with plant on top;
		// the glass reads on the facade, not from above.
		c = vec3(0.36, 0.38, 0.40) * (0.92 + 0.10 * n);
		vec2 g = q * 0.9;
		vec2 gi = floor(g);
		vec2 off = vec2(bf_hash12(gi + 5.7), bf_hash12(gi + 2.3)) * 0.4 + 0.3;
		float plant = 1.0 - smoothstep(0.12, 0.12 + px, bf_box(fract(g) - off, vec2(0.18, 0.13)));
		c = mix(c, vec3(0.56, 0.57, 0.56), plant * step(0.4, bf_hash12(gi + 8.1)) * bf_detail(0.9, px));
		spec = 0.12;
		snow_hold = 0.6;
	} else if (mat == BM_GREEN) {
		c = mix(vec3(0.30, 0.42, 0.22), vec3(0.42, 0.52, 0.28), n);
		snow_hold = 1.0;
	} else if (mat == BM_COPPER) {
		c = mix(vec3(0.36, 0.56, 0.48), vec3(0.46, 0.64, 0.56), n);
		c = mix(c, vec3(0.30, 0.40, 0.33), smoothstep(0.55, 0.8, bf_vnoise(vec2(along * 2.0, across * 12.0))) * 0.3);
		spec = 0.15;
	} else if (mat == BM_EARTH) {
		c = mix(vec3(0.42, 0.35, 0.27), vec3(0.52, 0.43, 0.32), n);
		c *= 0.86 + 0.2 * bf_vnoise(q * 7.0);
		c = mix(c, vec3(0.38, 0.42, 0.26), smoothstep(0.62, 0.8, bf_fbm(q * 0.8)) * 0.45);
		snow_hold = 1.0;
	} else if (mat == BM_HAY) {
		c = mix(vec3(0.72, 0.60, 0.33), vec3(0.80, 0.68, 0.40), n);
		c *= 0.86 + 0.18 * bf_vnoise(vec2(along * 11.0, across * 2.0) + seed * 5.0);
		snow_hold = 1.0;
	} else if (mat == BM_CHARCOAL) {
		c = mix(vec3(0.32, 0.27, 0.21), vec3(0.15, 0.14, 0.13), smoothstep(0.4, 0.7, n));
		snow_hold = 0.4;
	} else if (mat == BM_SOLAR) {
		c = vec3(0.60, 0.60, 0.58);
		vec2 cellp = vec2(along * 1.4, across * 2.2);
		vec2 f = fract(cellp);
		float panel = step(0.08, f.x) * step(f.x, 0.92) * step(0.10, f.y) * step(f.y, 0.86);
		panel = mix(0.8, panel, bf_detail(2.2, px));
		c = mix(c, vec3(0.10, 0.15, 0.26), panel);
		spec = 0.65 * panel;
		snow_hold = 0.3;
	} else if (mat == BM_STONE) {
		c = mix(vec3(0.56, 0.54, 0.49), vec3(0.64, 0.61, 0.55), n);
		vec2 b = vec2(along * 3.0 + floor(across * 4.0) * 0.5, across * 4.0);
		vec2 f = abs(fract(b) - 0.5);
		c *= mix(1.0, 0.82 + 0.18 * smoothstep(0.42, 0.36, max(f.x * 0.9, f.y)), bf_detail(4.0, px));
		spec = 0.03;
	}
	// Age the roofs of older eras a little more than modern ones.
	c *= mix(0.92, 1.0, smoothstep(0.0, 8.0, era)) * (0.94 + 0.12 * n);
	return c;
}

vec3 wall_albedo(int mat, float era, float archetype, float seed) {
	if (mat == BM_GLASS) return vec3(0.30, 0.38, 0.44);
	if (mat == BM_METAL) return vec3(0.50, 0.50, 0.48);
	if (mat == BM_CONCRETE || mat == BM_BITUMEN || mat == BM_SOLAR || mat == BM_GREEN)
		return mix(vec3(0.62, 0.60, 0.56), vec3(0.72, 0.70, 0.64), seed);
	if (mat == BM_BRICK || mat == BM_CHARCOAL) return vec3(0.50, 0.30, 0.22);
	if (mat == BM_STONE || mat == BM_COPPER) return vec3(0.62, 0.59, 0.52);
	if (era < 1.5) return mix(vec3(0.46, 0.36, 0.25), vec3(0.54, 0.43, 0.30), seed);
	if (era < 6.0) return mix(vec3(0.78, 0.72, 0.60), vec3(0.70, 0.60, 0.47), seed);
	return mix(vec3(0.58, 0.40, 0.30), vec3(0.70, 0.66, 0.58), seed);
}

void fragment() {
	int form = int(v_ids.x + 0.5);
	int mat = int(v_ids.y + 0.5);
	float era = v_ids.z;
	float archetype = v_ids.w;
	float seed = v_seed_cell.x;
	float he = v_height.x;
	float hr = v_height.y;
	vec2 s = v_p;
	float px = max(length(fwidth(v_p)) * 0.7, 1e-4);
	// 逐像素地面位置：horizon 图按真实世界坐标采样，跨山脊的建筑才会在脊线处分开。
	vec2 map_uv = pixel_map_uv(s);

	vec2 cell_uv = lut_uv(v_seed_cell.y);
	vec4 dyn = texture(dyn_lut, cell_uv);
	vec4 knowledge = texture(enum_lut, cell_uv);
	vec4 weather = texture(weather_lut, cell_uv);
	bool live = knowledge.a > 0.88;
	float snow = live ? clamp(dyn.b * 1.25, 0.0, 1.0) : 0.0;
	float wet = (live && visual_quality > 0) ? clamp(dyn.g * weather.g, 0.0, 1.0) : 0.0;
	float night = smoothstep(BUILDING_WINDOW_NIGHT_START, BUILDING_WINDOW_NIGHT_FULL, v_day.y);

	// Roof: the lean is small next to the roof slopes, so one correction of a
	// mid-pitch guess lands on the surface.
	vec2 P = s - v_lift * mix(he, hr, 0.6);
	P = s - v_lift * roof_z(P);
	float f_roof = footprint(P);
	float roof_cov = 1.0 - smoothstep(-0.6 * px, 0.6 * px, f_roof);

	// Walls: analytic ray/footprint intersection. Gable ends rise to the roof
	// line; elsewhere the wall stops at the eave.
	float wall_t = bf_wall_t(form, s, v_lift, v_half, hr);
	if (wall_t >= 0.0 && wall_t > roof_z(s - v_lift * wall_t) + 0.02) {
		wall_t = bf_wall_t(form, s, v_lift, v_half, he);
	}
	// Coverage from the nearest ground point of the swept footprint keeps the
	// silhouette antialiased without a march.
	float lift2 = dot(v_lift, v_lift);
	float t_near = lift2 > 1e-8 ? clamp(dot(s, v_lift) / lift2, 0.0, he) : 0.0;
	float g_edge = wall_t >= 0.0 ? -px : footprint(s - v_lift * t_near);
	float wall_cov = (1.0 - smoothstep(-0.6 * px, 0.6 * px, g_edge)) * (1.0 - roof_cov);
	if (wall_t < 0.0) wall_t = t_near;
	vec2 wall_B = s - v_lift * wall_t;

	vec3 col = vec3(0.0);
	float alpha = 0.0;
	// 留白区的 fragment 不付 horizon 的 4 次 tap；内院与风车自己会画地面/叶片，
	// 没有足印覆盖率也必须算。
	bool covered = roof_cov > 0.0 || wall_cov > 0.0
		|| form == BF_COURTYARD || form == BF_WINDMILL;
	TerrainHorizonSample hs = building_horizon(map_uv, covered);

	if (roof_cov > 0.0) {
		float e = max(0.025, px * 0.5);
		float zx = roof_z(P + vec2(e, 0.0)) - roof_z(P - vec2(e, 0.0));
		float zy = roof_z(P + vec2(0.0, e)) - roof_z(P - vec2(0.0, e));
		vec3 n_loc = normalize(vec3(-zx / (2.0 * e), -zy / (2.0 * e), 1.0));
		vec2 slope = n_loc.xy;
		float along = P.x;
		float across = P.y;
		if (length(slope) > 0.05) {
			vec2 down = normalize(slope);
			along = dot(P, vec2(-down.y, down.x));
			across = dot(P, down);
		}
		float spec_amt;
		float snow_hold;
		vec3 albedo = roof_albedo(mat, P, along, across, px, seed, era, spec_amt, snow_hold);
		vec3 n = tilt_to_ground(to_world(n_loc));

		if (form == BF_CHIMNEY || form == BF_COOLING) {
			float r = length(P) / max(v_half.y, 0.001);
			float inner = form == BF_COOLING ? 0.80 : 0.55;
			float hole = 1.0 - smoothstep(inner - 0.05, inner + 0.02, r);
			albedo = mix(albedo, vec3(0.07, 0.07, 0.075), hole);
			snow_hold *= 1.0 - hole;
			if (form == BF_COOLING) {
				float steam = bf_fbm(P * 1.6 + vec2(TIME * 0.12, TIME * 0.05) + seed * 9.0);
				albedo = mix(albedo, vec3(0.86, 0.88, 0.90), hole * smoothstep(0.35, 0.75, steam) * 0.85);
			}
		}
		if (form == BF_GREENHOUSE) {
			albedo = mix(albedo, vec3(0.36, 0.50, 0.32), 0.35);
		}
		// Flat roofs read through a lit parapet line around the edge.
		if (form == BF_FLAT || form == BF_COURTYARD || form == BF_SAWTOOTH || form == BF_TANK) {
			float rim = 1.0 - smoothstep(0.06, 0.06 + px * 1.5, -f_roof);
			albedo = mix(albedo, albedo * 1.22 + 0.04, rim * 0.6 * bf_detail(4.0, px));
		}
		// Tank lids: a welded seam ring and a central hatch.
		if (form == BF_TANK) {
			float r = length(P) / max(v_half.y, 0.001);
			float seam = 1.0 - smoothstep(0.0, 0.04 + px, abs(r - 0.62));
			float hatch = 1.0 - smoothstep(0.10, 0.10 + px * 2.0, r);
			albedo *= 1.0 - (seam * 0.18 + hatch * 0.25) * bf_detail(3.0, px);
		}
		float snow_amt = snow * snow_hold * smoothstep(0.30, 0.80, n.z);
		albedo = mix(albedo, vec3(0.88, 0.91, 0.95), snow_amt);
		albedo *= 1.0 - wet * 0.18;
		spec_amt = spec_amt * (1.0 - snow_amt) + wet * 0.30;

		vec3 c = albedo * light_at(n, hs);
		vec3 h = normalize(v_sun_dir + vec3(0.0, 0.0, 1.0));
		c += v_sun_col * pow(max(dot(n, h), 0.0), 28.0) * spec_amt * v_day.x * 0.6 * tod_exposure;

		// Eave shade darkens the outline so roofs stay legible against fields.
		float eave = smoothstep(0.0, 0.10 + px * 1.5, -f_roof);
		c *= mix(0.68, 1.0, eave);
		if (live && era >= 7.5 && (form == BF_FLAT || form == BF_TOWER) && visual_quality > 0) {
			vec2 g = fract(P * 2.2 + seed * 3.0);
			float skylight = step(0.82, bf_hash12(floor(P * 2.2 + seed * 3.0)))
				* (1.0 - smoothstep(0.12, 0.2, length(g - 0.5)));
			c += vec3(1.0, 0.78, 0.48) * skylight * night * 0.8 * tod_exposure;
		}
		if (live && mat == BM_CHARCOAL) {
			float ember = smoothstep(0.78, 0.92, bf_vnoise(P * 5.0 + TIME * 0.3));
			c += vec3(1.0, 0.42, 0.12) * ember * mix(0.15, 0.9, night) * tod_exposure;
		}
		col = c * roof_cov;
		alpha = roof_cov;
	}

	if (wall_cov > 0.0) {
		vec2 n2 = bf_wall_normal(form, wall_B, v_half);
		vec3 n = tilt_to_ground(to_world(normalize(vec3(n2, 0.12))));
		float face = dot(wall_B, vec2(-n2.y, n2.x));
		float hf = clamp(wall_t / max(he, 0.05), 0.0, 1.0);
		vec3 albedo;
		float snow_hold;
		float spec_amt;
		if (form == BF_MOUND || form == BF_CONE && he < 0.05) {
			albedo = roof_albedo(mat, wall_B, face, wall_t, px, seed, era, spec_amt, snow_hold);
		} else {
			albedo = wall_albedo(mat, era, archetype, seed);
			albedo *= 0.92 + 0.14 * bf_vnoise(vec2(face * 3.0, wall_t * 2.0) + seed * 11.0);
		}
		// Contact darkening near the ground and a darker gable band above the eave.
		albedo *= mix(0.62, 1.0, smoothstep(0.0, 0.45, wall_t));
		albedo *= wall_t > he + 0.02 ? 0.88 : 1.0;
		vec3 c = albedo * light_at(n, hs);

		bool windows = era >= 1.5 && form != BF_MOUND && form != BF_CHIMNEY
			&& form != BF_COOLING && form != BF_DOME && form != BF_TANK
			&& mat != BM_HAY && mat != BM_CHARCOAL;
		if (windows && wall_t < he) {
			float floor_h = era >= 7.5 ? 0.62 : 0.85;
			float spacing = era >= 7.5 ? 0.34 : 0.48;
			float fy = fract(wall_t / floor_h);
			float fx = fract(face / spacing + seed * 7.0);
			float win_detail = bf_detail(1.0 / spacing, px);
			float in_win = step(0.36, fy) * step(fy, 0.78) * step(0.28, fx) * step(fx, 0.72)
				* step(0.25, wall_t) * win_detail;
			if (mat == BM_GLASS) in_win = 0.6;
			float lit = step(0.35, bf_hash12(vec2(floor(face / spacing), floor(wall_t / floor_h)) + seed * 17.0));
			c = mix(c, vec3(0.10, 0.11, 0.13) * light_at(n, hs) * 1.6, in_win * 0.8);
			if (live) {
				// Once individual windows are below pixel size their average
				// glow keeps lit facades readable at night.
				float glow = in_win * lit + (1.0 - win_detail) * 0.16 * step(0.25, wall_t);
				c += vec3(1.0, 0.64, 0.28) * glow * night * BUILDING_WINDOW_LIGHT_GAIN * tod_exposure;
			}
		}
		col += c * wall_cov;
		alpha += wall_cov;
	}

	// Courtyard interiors are paved or planted ground, never bare terrain.
	if (form == BF_COURTYARD && alpha < 1.0) {
		float wing = bf_courtyard_wing(v_half);
		float d_inner = bf_box(s, v_half - vec2(wing));
		float yard = 1.0 - smoothstep(-px, px, d_inner);
		if (yard > 0.0) {
			vec3 ground = era < 3.5 ? vec3(0.60, 0.56, 0.47) : vec3(0.40, 0.48, 0.30);
			vec2 cob = abs(fract(s * 3.0 + seed * 5.0) - 0.5);
			ground *= mix(1.0, 0.88 + 0.12 * smoothstep(0.46, 0.36, max(cob.x, cob.y)),
				bf_detail(3.0, px) * (era < 3.5 ? 1.0 : 0.3));
			ground = mix(ground, vec3(0.88, 0.91, 0.95), snow * 0.9);
			float court_ao = mix(0.55, 1.0, smoothstep(0.0, 0.7, -d_inner));
			vec3 c = ground * light_at(tilt_to_ground(vec3(0.0, 0.0, 1.0)), hs) * court_ao;
			float a = yard * (1.0 - alpha);
			col += c * a;
			alpha += a;
		}
	}

	if (form == BF_WINDMILL) {
		vec2 hub = s - v_lift * (hr + 0.08);
		bool turbine = bf_is_turbine(mat);
		float angle = seed * 6.2831853 + TIME * (turbine ? 1.1 : 0.35);
		float sail = bf_sails(hub, mat, v_half.y, angle, px);
		vec3 sail_col = turbine ? vec3(0.86, 0.87, 0.88) : vec3(0.74, 0.69, 0.58);
		vec3 lit_sail = sail_col * light_at(vec3(0.0, 0.0, 1.0), hs);
		col = col * (1.0 - sail) + lit_sail * sail;
		alpha = alpha + sail * (1.0 - alpha);
	}

	if (!live && alpha > 0.0) {
		vec3 base = col / max(alpha, 1e-4);
		float gray = dot(base, vec3(0.299, 0.587, 0.114));
		col = (mix(vec3(gray), base, 0.38) * 0.78) * alpha;
	}

	// Night: warm spill on the ground around inhabited buildings.
	if (live && visual_quality > 0 && night > 0.0 && form != BF_MOUND && mat != BM_HAY) {
		float fg = max(footprint(s), 0.0);
		float level = era < 1.5 ? 0.22 : (era < 5.5 ? 0.40 : (era < 7.5 ? 0.62 : 0.9));
		float halo = exp(-fg * 2.6) * level * night * BUILDING_WINDOW_HALO_GAIN * (1.0 - alpha);
		col += vec3(1.0, 0.56, 0.22) * halo * tod_exposure;
		alpha += halo;
	}

	if (alpha < 0.004) discard;
	float fade = geometry_alpha * smoothstep(0.36, 0.54, camera_zoom);
	COLOR = vec4(col / alpha, clamp(alpha, 0.0, 1.0) * fade);
}
