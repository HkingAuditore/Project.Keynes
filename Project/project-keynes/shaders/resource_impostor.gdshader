shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D style_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D memory_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float hex_size = 22.0;
uniform float camera_zoom = 1.0;
uniform float world_time = 0.0;
uniform bool fog_enabled = true;
uniform bool has_dynamic_lut = false;
uniform bool has_ecology_lut = false;
uniform int visual_quality = 1;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4101523;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;
uniform float vitality_dead_threshold = 0.04;
uniform float vitality_power = 0.65;
uniform float climate_response = 0.7;
uniform float snow_response = 0.85;
uniform float wind_strength = 0.35;
uniform float animal_motion = 0.55;
uniform float detailed_pixels = 12.0;
uniform float simple_pixels = 6.0;
uniform float fade_pixels = 2.0;
// 压低饱和度，使资源与地图色调融合（1 = 原色）。
uniform float palette_saturation = 0.80;
// 资源透镜：0 = 世界内实景，1 = 屏幕恒定尺寸的识别徽章；filter_style >= 0 时只显示该资源。
uniform float lens_amount = 0.0;
uniform float badge_px = 34.0;
uniform int filter_style = -1;
// The world view is decoration, not a signpost: no outlines or cast shadows by default,
// ground decals and submerged cues blend at low opacity, and extreme lumas are compressed.
uniform float decal_opacity = 0.42;
uniform float submerged_opacity = 0.55;
uniform float outline_strength = 0.0;
uniform float contact_shadow = 0.45;
uniform float cast_shadow = 0.0;
uniform float luma_compress = 0.75;
uniform vec2 luma_range = vec2(0.24, 0.64);
// 群落外沿的羽化与扰动；植株/晶体之间不再绘制封闭底板。
uniform float area_feather = 0.55;
uniform float area_edge_noise = 0.35;
uniform float plant_cluster_density = 1.30;
#define VT_USE_HORIZON
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HEIGHT
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform bool has_height_tex = false;
uniform bool has_flow_tex = false;
uniform float sea_level = 0.42;
uniform float river_clear_threshold = 0.54;
uniform bool terrain_normal_tex_bound = false;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_horizon_cast_floor = 0.82;
uniform int terrain_horizon_debug_view = 0;
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength = 0.90;
uniform float gi_ao_floor = 0.38;
uniform float gi_ao_smoothing = 0.75;
uniform float gi_bent_strength = 0.35;
uniform float gi_normal_floor = 0.85;
uniform vec2 wind_dir = vec2(1.0, 0.18);
uniform float weather_wind_boost = 0.0;
#include "res://shaders/include/earth_daylight.gdshaderinc"
vec2 wrap_map_uv(vec2 uv) { return visual_static_wrap_uv(uv); }
#include "res://shaders/include/terrain_horizon.gdshaderinc"

varying flat vec4 v_style;
varying flat vec4 v_climate;
varying flat vec4 v_data;
varying flat vec2 v_sub;
varying flat vec2 v_ecology;
varying flat vec3 v_light;
varying flat vec3 v_direct;
varying flat vec3 v_sun;
varying flat vec2 v_axis;
varying flat vec2 v_rank;
varying flat vec4 v_sky;
varying flat vec3 v_terrain;
varying flat vec3 v_day;
varying flat float v_horizon;
varying vec2 v_world_position;
// x = instance kind (1 prop, 2 ground decal, 3 submerged, 4 lens-only),
// y = 1 when this instance carries the resource's lens badge.
varying flat vec2 v_kind;
// Light transmission through water for submerged cues (1 on land).
varying flat float v_transmission;

float rv_hash(float n) {
	return fract(sin(n * 12.9898 + 78.233) * 43758.5453);
}

// Pull pure black / pure white towards the terrain's luma band, keeping chroma.
vec3 rv_compress_luma(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	float target = mix(luma_range.x, luma_range.y, clamp(l, 0.0, 1.0));
	return clamp(c + vec3((target - l) * luma_compress), vec3(0.0), vec3(1.0));
}

float rv_ellipse(vec2 p, vec2 extent) {
	return (length(p / extent) - 1.0) * min(extent.x, extent.y);
}

// 与树木同源的定向天光；地表法线与 GI 只在 vertex 采样。
vec3 rv_ambient(vec3 normal) {
	vec3 mixed_n = mix(normal, v_sky.xyz, gi_bent_strength);
	vec3 amb_n = dot(mixed_n, mixed_n) > 0.000001 ? normalize(mixed_n) : normal;
	float ao = terrain_horizon_apply_normal(v_sky.w, normal, v_sky.xyz);
	vec3 sky = earth_sky_sh(v_light, v_direct, v_sun, v_day.x, amb_n);
	return sky * ao * mix(1.0, 0.70, v_day.x)
		+ EARTH_MOONLIGHT * v_day.z * max(dot(normal, -v_sun), 0.0) * 0.35 * tod_exposure;
}

void vertex() {
	float cell = INSTANCE_CUSTOM.r;
	vec2 cell_uv = (vec2(mod(cell, lut_dims.x), floor(cell / lut_dims.x)) + 0.5) / lut_dims;
	vec4 memory = texture(memory_lut, cell_uv);
	float knowledge = fog_enabled ? texture(enum_lut, cell_uv).a : 1.0;
	float live = step(0.88, knowledge);
	vec4 current = texture(dyn_lut, cell_uv);
	v_climate = mix(memory, current, has_dynamic_lut ? live : 0.0);
	vec4 ecology = texture(eco_lut, cell_uv);
	v_ecology = mix(vec2(memory.a, 1.0 - memory.a), ecology.rg, has_ecology_lut ? live : 0.0);
	float style = INSTANCE_CUSTOM.g;
	v_style = texture(style_lut, vec2(0.25, (style + 0.5) / 64.0));
	vec4 meta = texture(style_lut, vec2(0.75, (style + 0.5) / 64.0));
	float radius_px_world = length(MODEL_MATRIX[0].xy) * camera_zoom;
	float radius_px = mix(radius_px_world, badge_px * 0.5, clamp(lens_amount, 0.0, 1.0));
	v_data = vec4(meta.r, meta.g, INSTANCE_CUSTOM.b, live);
	v_transmission = COLOR.g;
	v_sub = vec2(meta.b, style);
	v_rank = vec2(INSTANCE_CUSTOM.a, radius_px);
	vec2 center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	vec2 map_uv = visual_static_wrap_uv((center - world_origin) / max(world_size, vec2(0.0001)));
	EarthDaylight daylight = eval_earth_daylight(map_uv, clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0, day_night_enabled);
	if (tod_debug_sun_position_enabled) {
		v_sun = normalize(tod_sun_dir);
		float d_day = smoothstep(-0.08, 0.22, v_sun.z);
		float d_dusk = smoothstep(-0.06, 0.14, v_sun.z) * (1.0 - smoothstep(0.14, 0.42, v_sun.z));
		vec3 sun_c = mix(EARTH_DAYLIGHT_NOON, EARTH_DAYLIGHT_DUSK, d_dusk);
		vec3 amb_c = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, d_day);
		float moon = (1.0 - d_day) * 0.72;
		v_light = amb_c * tod_exposure;
		v_direct = sun_c * tod_exposure;
		v_day = vec3(d_day, smoothstep(0.0, 0.65, v_sun.z), moon);
	} else {
		v_sun = daylight.sun_dir;
		v_light = daylight.amb_col * tod_exposure;
		v_direct = daylight.sun_col * tod_exposure;
		v_day = vec3(daylight.local_day, daylight.sun_high, daylight.moon_strength);
	}
	TerrainHorizonSample horizon = terrain_horizon_evaluate(map_uv, v_sun);
	v_horizon = horizon.direct_visibility;
	v_sky = vec4(horizon.bent_normal, horizon.sky_visibility);
	vec2 terrain_xy = terrain_normal_tex_bound ? (visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0) * 0.65 : vec2(0.0);
	v_terrain = normalize(vec3(terrain_xy, 1.0));
	v_axis = normalize(MODEL_MATRIX[0].xy);
	float kind_raw = COLOR.a + 0.01;
	float kind = floor(kind_raw);
	float carrier = step(fract(kind_raw), 0.25);
	v_kind = vec2(kind, carrier);
	float present = step(0.10, knowledge);
	float lens = clamp(lens_amount, 0.0, 1.0);
	float lod = smoothstep(fade_pixels, simple_pixels, radius_px_world);
	float rank_alpha = mix(step(COLOR.r, 0.1), 1.0, smoothstep(simple_pixels, detailed_pixels, radius_px_world));
	float world_vis = lod * rank_alpha * step(kind, 3.5);
	// Lens badges: only each cell's primary resource (or the filtered one), thinned
	// by on-screen cell density so zoomed-out badges never pile into a blob. A
	// resource drawn as decal + prop owns exactly one badge (the carrier).
	float matches = filter_style >= 0 ? step(abs(style - float(filter_style)), 0.5) : 1.0;
	float keep = clamp(pow(hex_size * camera_zoom * 1.7 / max(badge_px, 1.0), 2.0), 0.0, 1.0);
	float thin = step(rv_hash(cell * 0.731 + 3.17), keep);
	float lens_vis = step(COLOR.r, 0.1) * matches * thin * carrier;
	v_style.a = mix(world_vis, lens_vis, lens) * present;
	VERTEX *= mix(1.0, badge_px * 0.5 / max(radius_px_world, 0.001), lens);
	VERTEX *= step(0.001, v_style.a);
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

#include "res://shaders/include/resource_forms.gdshaderinc"
#include "res://shaders/include/resource_solid_forms.gdshaderinc"
#include "res://shaders/include/resource_topdown_forms.gdshaderinc"
#include "res://shaders/include/resource_decal_forms.gdshaderinc"

void fragment() {
	int form = int(v_data.x + 0.5);
	int family = int(v_data.y + 0.5);
	int sub_style = int(v_sub.x + 0.5);
	int kind = int(v_kind.x + 0.5);
	float seed = v_data.z;
	float live = v_data.w;
	float lens = clamp(lens_amount, 0.0, 1.0);
	// QuadMesh V is inverted relative to Canvas Y. The map is viewed straight down, so
	// every subject is drawn top-down (p.y up in form space, canvas y down on screen).
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float px_px = max(1.0 / max(v_rank.y, 1.0), 0.004);
	float health = pow(clamp(v_climate.a, 0.0, 1.0), vitality_power);
	float motion = world_time * live;
	vec3 tint = v_style.rgb;
	float snow = clamp(v_climate.b * snow_response, 0.0, 1.0);
	vec3 light_dir = normalize(v_sun);
	vec3 direct_light = v_direct * v_day.x * v_horizon;
	// Flat-ground lighting shared by decals and submerged cues.
	float flat_diffuse = max(dot(v_terrain, light_dir), 0.0);
	vec3 flat_light = rv_ambient(v_terrain) + direct_light * flat_diffuse * 0.78;

	// Subject = the full procedural drawing. In the world it is only drawn for small
	// props; while the lens is on it is also the picture inside every badge.
	vec3 subj_rgb = vec3(0.0);
	float subj_alpha = 0.0;
	float subj_combined = 0.0;
	if (kind == 1 || lens > 0.001) {
		float form_zoom = mix(1.0, 1.02, lens);
		vec2 pf = p * form_zoom;
		float px = px_px * form_zoom;
		// 风只移动枝叶轮廓，地面贴花与矿石不随风漂移。
		if (family == 0 && form != 26) {
			float wind_time = motion;
			vec2 w = normalize(wind_dir + vec2(0.0001));
			vec2 local_w = vec2(dot(w, v_axis), -dot(w, vec2(-v_axis.y, v_axis.x)));
			float gust = sin(wind_time * 1.25 + seed * 21.0 + pf.y * 2.8)
				+ 0.38 * sin(wind_time * 2.1 + seed * 9.0 + pf.x * 3.0);
			float amp = (wind_strength + weather_wind_boost * 0.6) * (form == 0 || form == 7 ? 0.085 : 0.045);
			pf -= local_w * gust * amp * (1.0 - lens * 0.65);
		}
		RSurf s = rs_empty();
		if (family == 3) {
			// Badge picture of marine & freshwater fish: 4 curved silver-aqua fish in a shoal.
			vec3 fish_col = sub_style == 0 ? vec3(0.46, 0.80, 0.88) : vec3(0.56, 0.86, 0.74);
			for (int i = 0; i < 4; i++) {
				float fi = float(i);
				vec2 fc = i == 0 ? vec2(-0.18, -0.14) : (i == 1 ? vec2(0.20, -0.02) : (i == 2 ? vec2(-0.12, 0.22) : vec2(0.18, 0.28)));
				float fscale = i == 0 ? 1.05 : (i == 1 ? 0.92 : 0.78);
				vec2 fp = rs_rot(-0.42 + fi * 0.12) * ((pf - fc) / fscale);
				fp.x += sin(fp.y * 6.5 + motion * 1.2 + fi) * 0.04;
				rs_part(s, fp, vec2(0.0, -0.04), vec2(0.13, 0.32), fish_col * (0.92 + 0.08 * fi), 0.14, px);
				rs_blade(s, fp, vec2(0.0, 0.20), vec2(-0.14, 0.44), 0.075, fish_col * 0.78, 0.10, px);
				rs_blade(s, fp, vec2(0.0, 0.20), vec2(0.14, 0.44), 0.075, fish_col * 0.78, 0.10, px);
			}
			s.spec = 0.82;
			s.rim = 0.35;
		} else {
			s = rt_resource(pf, form, family, sub_style, tint, seed, px, family == 1 ? motion * animal_motion : motion, lens < 0.5);
		}

		bool free_standing = family == 1 || form == 6 || form == 7 || form == 26 || form == 16 || form == 17 || form == 18;
		// Outlines are off in the world by default (they read as stickers); badges keep a firm one.
		float outline_k = mix((free_standing ? 0.55 : 0.28) * outline_strength, free_standing ? 0.55 : 0.28, lens);

		vec3 base = s.albedo;
		bool detailed_view = visual_quality > 0 && v_rank.y >= detailed_pixels;

		if (family == 0 && form != 26) {
			float dry = clamp((0.35 - v_climate.g) * 1.4 + (1.0 - health) * 0.45 + v_ecology.y * 0.12, 0.0, 1.0);
			base = mix(base, vec3(0.54, 0.45, 0.26), dry * climate_response * 0.38);
		}
		float snow_mask = snow * (family == 1 ? 0.18 : (s.h < 0.08 ? 0.55 : 0.85)) * smoothstep(-0.1, 0.5, s.n.z);
		base = mix(base, vec3(0.84, 0.88, 0.92), snow_mask);

		// Mute towards the terrain's palette: saturated catalogue colours stay on badges only.
		float grey_albedo = dot(base, vec3(0.299, 0.587, 0.114));
		base = mix(vec3(grey_albedo), base, palette_saturation);
		base = mix(rv_compress_luma(base), base, lens);

		vec2 screen_n = vec2(s.n.x, -s.n.y);
		vec2 world_slope = v_axis * screen_n.x + vec2(-v_axis.y, v_axis.x) * screen_n.y;
		vec3 normal = normalize(vec3(world_slope + v_terrain.xy * s.n.z, max(s.n.z, 0.22)));
		float diffuse = max(dot(normal, light_dir), 0.0);

		vec3 view_dir = vec3(0.0, 0.0, 1.0);
		vec3 half_dir = normalize(light_dir + view_dir);
		float ndoth = max(dot(normal, half_dir), 0.0);
		float shininess = mix(14.0, 44.0, s.metallic * 0.6 + s.spec * 0.4);
		float spec_factor = pow(ndoth, shininess) * s.spec * (1.0 - snow_mask * 0.7) * 0.7;
		vec3 spec_color = mix(vec3(1.0), base * 1.35, s.metallic) * s.spec_tint;

		float rim_factor = pow(1.0 - max(dot(normal, view_dir), 0.0), 2.0) * s.rim;
		vec3 unlit = base;
		vec3 diff_light = rv_ambient(normal) + direct_light * (diffuse * 0.78 + rim_factor * 0.10);
		base = (base * diff_light + direct_light * spec_color * spec_factor * 0.35) * s.ao;
		base *= 0.92 + 0.22 * clamp(s.h * 2.0, 0.0, 1.0);

		float edge_line = (1.0 - smoothstep(0.0, px * 2.2, -s.d)) * step(s.d, 0.0);
		base *= 1.0 - edge_line * outline_k;
		// Lens badges stay readable at night.
		base = mix(base, unlit * (0.92 + 0.16 * diffuse), lens * 0.80);

		float aa = clamp(fwidth(s.d), px * 0.60, px * 2.5);
		float alpha = 1.0 - smoothstep(-aa, aa, s.d);
		if (family == 0 && form != 26) {
			alpha *= mix(0.28, 1.0, health) * smoothstep(vitality_dead_threshold * 0.3, vitality_dead_threshold, v_climate.a);
			alpha *= 1.0 - snow * 0.60;
		}
		if (form == 22) {
			alpha *= 0.88;
		}
		if (form == 19 || form == 20) {
			alpha *= 0.90;
		}
		if (form == 25) {
			alpha *= 0.84;
		}
		// Areas, not objects: feather the silhouette into the terrain and let the ground
		// show between plants / crust grains. Badges keep the crisp silhouette.
		bool area_form = (family == 0 && form != 6 && form != 7 && form != 26)
			|| form == 18 || form == 19 || form == 20 || form == 22;
		if (area_form) {
			float warp = (vf_vnoise(pf * 5.0 + seed * 7.0) - 0.5) * area_edge_noise;
			// 羽化群落外沿，不能对每片叶/晶体的距离场再羽化，否则小实体全部消失。
			float inner = 1.0 - smoothstep(max(0.30, 0.92 - area_feather), 0.96, length(pf) + warp);
			alpha *= mix(inner, 1.0, lens);
		}

		// Soft ground contact; the silhouette-derived cast shadow is opt-in (cast_shadow).
		// Flat areas have no height, so no contact ring either.
		float shadow = s.floor_a * contact_shadow * (area_form ? lens : 1.0);
		if (detailed_view && free_standing && lens < 0.5 && cast_shadow > 0.001) {
			vec2 grad = vec2(dFdx(s.d), dFdy(s.d));
			vec2 away = -normalize(v_sun.xy + vec2(0.0001));
			float facing = clamp(dot(normalize(grad + vec2(0.00001)), away), 0.0, 1.0);
			float reach = clamp(0.10 / max(v_sun.z, 0.35), 0.04, 0.26);
			float cast = (1.0 - smoothstep(0.0, reach * facing + 0.01, s.d)) * step(0.0, s.d) * facing;
			shadow = max(shadow, cast * 0.32 * cast_shadow * smoothstep(-0.06, 0.15, v_sun.z));
		}

		float grey = dot(base, vec3(0.299, 0.587, 0.114));
		base = mix(vec3(grey) * 0.85, base, mix(0.25, 1.0, live));
		float combined = alpha + shadow * (1.0 - alpha);
		vec3 shadow_tint = mix(vec3(0.11, 0.13, 0.095), s.floor_col, 0.45);
		subj_rgb = mix(shadow_tint, base, alpha / max(combined, 0.0001));
		subj_alpha = alpha;
		subj_combined = combined;
	}

	// World appearance by instance kind.
	vec3 world_rgb = subj_rgb;
	float world_a = subj_combined;
	if (kind == 2) {
		vec4 g = rd_ground_decal(p, form, sub_style, tint, seed);
		vec3 col = g.rgb;
		float grey_albedo = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(grey_albedo), col, palette_saturation);
		col = rv_compress_luma(col);
		col = mix(col, vec3(0.84, 0.88, 0.92), snow * 0.55);
		col *= flat_light;
		float grey = dot(col, vec3(0.299, 0.587, 0.114));
		world_rgb = mix(vec3(grey) * 0.85, col, mix(0.25, 1.0, live));
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_a = g.a * decal_opacity * strength * (1.0 - snow * 0.45);
		if (form == 22) {
			// 地力以健康草被表达，干旱/低活力转黄、退隐，积雪下不铺绿色地毯。
			world_a *= smoothstep(vitality_dead_threshold, 0.65, v_climate.a) * (1.0 - snow * 0.80);
		}
	} else if (kind == 3) {
		vec4 w = rd_submerged(p, form, family, sub_style, seed, motion);
		world_rgb = w.rgb * flat_light;
		float strength = clamp(0.55 + v_rank.x * 0.15, 0.55, 1.0);
		world_a = w.a * submerged_opacity * strength * mix(0.6, 1.0, live) * clamp(v_transmission, 0.0, 1.0);
	} else if (kind >= 4) {
		world_a = 0.0;
	}
	float horizon_cast = clamp((1.0 - v_horizon) * v_day.x, 0.0, 1.0);
	float cast_floor = mix(1.0, terrain_horizon_cast_floor, 0.70);
	cast_floor = mix(1.0, cast_floor, mix(1.0, v_sky.w, gi_ao_strength));
	world_rgb *= mix(1.0, cast_floor, horizon_cast);

	vec3 color = world_rgb;
	float out_alpha = world_a;
	if (lens > 0.001) {
		// Shape-coded recognition badge: circle = animal, rounded square = plant,
		// hexagon = mineral. The ring colour repeats the category; the picture inside is
		// the same subject drawn on the map, so the badge teaches the map and vice versa.
		float bd = rt_badge_sdf(p, family);
		float inside = 1.0 - smoothstep(-px_px, px_px, bd);
		float ring = 1.0 - smoothstep(0.0, px_px * 1.5, abs(bd + 0.075) - 0.075);
		float rim = 1.0 - smoothstep(0.0, px_px * 1.2, abs(bd - 0.03) - 0.03);
		float halo = (1.0 - smoothstep(0.0, 0.12, bd)) * step(0.0, bd);
		vec3 backing = mix(vec3(0.43, 0.47, 0.48), vec3(0.28, 0.32, 0.34), smoothstep(0.1, 0.8, length(p)));
		vec3 badge_rgb = mix(backing, subj_rgb, clamp(subj_alpha, 0.0, 1.0));
		badge_rgb = mix(badge_rgb, rt_badge_ring(family), ring);
		vec3 out_rgb = vec3(0.02, 0.03, 0.03);
		float out_a = halo * 0.38;
		out_rgb = mix(out_rgb, vec3(0.96), rim);
		out_a = max(out_a, rim);
		out_rgb = mix(out_rgb, badge_rgb, inside);
		out_a = max(out_a, inside);
		color = mix(world_rgb, out_rgb, lens);
		out_alpha = mix(world_a, out_a, lens);
	}
	if (lens < 0.001 && terrain_horizon_debug_view > 0) {
		color = vec3(terrain_horizon_debug_view == 1 ? (1.0 - v_horizon) * v_day.x : v_horizon);
	}
	if ((family == 0 || kind == 2) && has_height_tex && lens < 1.0) {
		// 扩大的植被/地力斑必须沿实际河岸裁切，不能只检查群落中心。
		vec2 ground_uv = (v_world_position - world_origin) / max(world_size, vec2(0.0001));
		vec4 ground = visual_sample_height(ground_uv);
		float height = (ground.r * 256.0 + ground.g) / 257.0;
		float land = smoothstep(sea_level - 0.002, sea_level + 0.002, height);
		float river = has_flow_tex ? 1.0 - smoothstep(river_clear_threshold - 0.08, river_clear_threshold, ground.b) : 1.0;
		out_alpha *= mix(land * river, 1.0, lens);
	}
	COLOR = vec4(color, out_alpha * v_style.a);
}
