shader_type canvas_item;
render_mode unshaded, blend_mix;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// resource_ground_cover.gdshader: wild plant communities and grazing traces.
//
// One full-world quad, zero geometry per cell (same addressing as FogOfWarLayer):
// map index -> cell -> cover_lut. The cover LUT is written by ResourceGroundCover only
// from resource observations (fog memory), so unexplored cells are always empty.
//
// cover_lut (RGBA8, nearest):
//   R = primary layer * 16 + secondary layer   (cover_albedo layers 0..15)
//   G = primary abundance  (0 = no plant community)
//   B = secondary abundance
//   A = trace kind * 64 + trace strength (kind 1..3 -> layer trace_layer_base + kind - 1)
// memory_lut: last-seen climate (temp, moisture, snow, vitality), shared with the props.
//
// Textures are sampled in WORLD space, so neighbouring cells of one species merge into a
// single continuous meadow; cell borders are warped by noise and broken by clumping.
// All periodic quantities snap to the east-west wrap period so the seam is invisible.
//
// Cost per pixel (desktop q2): 3 cell taps (2 fetches each) + memory + height +
// terrain normal + horizon + 4 albedo + 1 normal. q1: 1 tap, 3 albedo. Mobile: no normal
// map, no extra taps, no anti-tiling sample (compile-time).
// ════════════════════════════════════════════════════════════════════════

uniform sampler2D cover_lut : filter_nearest, repeat_disable;
uniform sampler2D memory_lut : filter_nearest, repeat_disable;
// Live climate for currently visible cells (same blend rule as resource_impostor).
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform bool has_dynamic_lut = false;
uniform bool fog_enabled = true;
uniform sampler2DArray cover_albedo : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray cover_normal : filter_linear_mipmap, repeat_enable;
uniform bool art_bound = false;
uniform vec2 lut_dims = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float hex_size = 22.0;
uniform float camera_zoom = 1.0;
uniform float world_time = 0.0;
uniform int visual_quality = 1;
uniform float cover_opacity = 0.85;
uniform float tile_hex = 1.6;
uniform float edge_warp_hex = 0.35;
uniform float clump_scale_hex = 2.5;
uniform float clump_strength = 0.45;
uniform int cover_taps = 1;
uniform float normal_strength = 0.8;
uniform float shadow_strength = 0.45;
uniform float lens_amount = 0.0;
uniform float lens_dim = 0.35;
uniform float trace_opacity = 0.45;
uniform float far_opacity = 0.65;
// The art is tone-matched for neutral light; the map palette is warmer and more saturated.
uniform float cover_saturation = 1.45;
uniform float cover_gain = 1.22;
// Map palette grade: the terrain greens are yellow and carry almost no blue.
uniform vec3 cover_grade = vec3(1.05, 1.0, 0.72);
// Calibrates this SH + Lambert + fake-GI model to the terrain BRDF at noon (QA: mean HSV
// value of covered pixels within 0.02 of the bare terrain).
uniform float light_gain = 1.62;
// 0 = full sky colour in the ambient (bluish), 1 = neutral grey ambient.
uniform float light_neutralize = 0.55;
uniform float trace_layer_base = 13.0;
uniform float climate_response = 0.7;
uniform float snow_response = 0.85;
uniform float vitality_dead_threshold = 0.04;
uniform float vitality_power = 0.65;
uniform float wind_strength = 0.35;
uniform float weather_wind_boost = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.18);
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
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4101523;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;
#define VT_USE_MAP_INDEX
#define VT_USE_HEIGHT
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HORIZON
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#include "res://shaders/include/earth_daylight.gdshaderinc"
vec2 wrap_map_uv(vec2 uv) { return visual_static_wrap_uv(uv); }
#include "res://shaders/include/terrain_horizon.gdshaderinc"

varying vec2 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// World units per period cell, snapped so the wrap period holds an integer count.
float gc_snap(float s) {
	if (wrap_period_x <= 0.0001) {
		return s;
	}
	return wrap_period_x / max(1.0, floor(wrap_period_x / s + 0.5));
}

float gc_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise on a lattice of `scale` world units, periodic across the map wrap.
float gc_noise(vec2 wp, float scale, float salt) {
	float s = gc_snap(scale);
	vec2 p = wp / s;
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (wrap_period_x > 0.0001) {
		float cells = floor(wrap_period_x / s + 0.5);
		x0 = mod(x0, cells);
		x1 = mod(x1, cells);
	}
	vec2 o = vec2(salt * 17.13, salt * 5.71);
	return mix(mix(gc_hash(vec2(x0, i.y) + o), gc_hash(vec2(x1, i.y) + o), f.x),
		mix(gc_hash(vec2(x0, i.y + 1.0) + o), gc_hash(vec2(x1, i.y + 1.0) + o), f.x), f.y);
}

vec2 gc_wrap(vec2 wp) {
	if (wrap_period_x > 0.0001) {
		wp.x = wrap_origin_x + mod(wp.x - wrap_origin_x, wrap_period_x);
	}
	return wp;
}

vec2 gc_map_uv(vec2 wp) {
	return (wp - world_origin) / max(world_size, vec2(0.0001));
}

// Cell under a world point; -1 when outside the map.
float gc_cell(vec2 wp) {
	vec4 encoded = visual_sample_map_index(gc_map_uv(wp));
	float lo = floor(encoded.g * 255.0 + 0.5);
	float hi = floor(encoded.b * 255.0 + 0.5);
	float cell = lo + hi * 256.0;
	return (cell >= 65535.0 || cell >= lut_dims.x * lut_dims.y) ? -1.0 : cell;
}

vec2 gc_lut_uv(float cell) {
	return (vec2(mod(cell, lut_dims.x), floor(cell / lut_dims.x)) + 0.5) / lut_dims;
}

vec4 gc_cover(float cell) {
	return cell < 0.0 ? vec4(0.0) : floor(texture(cover_lut, gc_lut_uv(cell)) * 255.0 + 0.5);
}

void fragment() {
	vec2 wp = gc_wrap(v_world);
	float hex_px = hex_size * camera_zoom;
	// Warped lookup position: community borders follow noise, not hexagon edges.
	float warp_scale = hex_size * 0.85;
	vec2 warp = (vec2(gc_noise(wp, warp_scale, 1.0), gc_noise(wp, warp_scale, 2.0)) - 0.5)
		* 2.0 * edge_warp_hex * hex_size;
	warp += (vec2(gc_noise(wp, warp_scale * 0.31, 3.0), gc_noise(wp, warp_scale * 0.31, 4.0)) - 0.5)
		* 0.7 * edge_warp_hex * hex_size;
	vec2 lookup = wp + warp;
	float cell = gc_cell(lookup);
	vec4 cover = gc_cover(cell);
	float layer_p = floor(cover.r / 16.0);
	float layer_s = cover.r - layer_p * 16.0;
	float ab_p = cover.g / 255.0;
	float ab_s = cover.b / 255.0;
	float trace_kind = floor(cover.a / 64.0);
	float trace_k = (cover.a - trace_kind * 64.0) / 63.0;

	// Gradients come from the unwrapped, continuous position (no seam spikes) and are
	// taken before any branch so mip selection stays valid in divergent quads.
	float tile = gc_snap(max(tile_hex, 0.1) * hex_size);
	vec2 uv = wp / tile;
	vec2 dx = dFdx(v_world) / tile;
	vec2 dy = dFdy(v_world) / tile;

	vec3 out_pm = vec3(0.0);
	float out_a = 0.0;
	if (art_bound && cell >= 0.0 && (ab_p > 0.0 || trace_kind > 0.5)) {
		vec2 cell_uv = gc_lut_uv(cell);
		vec4 climate = texture(memory_lut, cell_uv);
		if (has_dynamic_lut) {
			float live = fog_enabled ? step(0.88, texture(enum_lut, cell_uv).a) : 1.0;
			climate = mix(climate, texture(dyn_lut, cell_uv), live);
		}
		float health = pow(clamp(climate.a, 0.0, 1.0), vitality_power);
		float snow = clamp(climate.b * snow_response, 0.0, 1.0);
		// Temperature phenology with the vegetation palette's thresholds
		// (vegetation_climate.gdshaderinc) so the meadow turns with the woods: cool
		// transition -> autumn gold, cold -> winter-withered, mild + moist -> fresh green,
		// heat counts as drought. A world-space jitter staggers the change across cells.
		float temp_j = climate.r + (gc_noise(wp, hex_size * 1.3, 11.0) - 0.5) * 0.08;
		float heat = smoothstep(0.74, 0.96, climate.r);
		float golden = smoothstep(0.16, 0.34, temp_j) * (1.0 - smoothstep(0.38, 0.58, temp_j))
			* mix(0.55, 1.0, smoothstep(0.30, 0.68, climate.g));
		float withered = 1.0 - smoothstep(0.16, 0.38, temp_j);
		float fresh = smoothstep(0.30, 0.56, temp_j) * (1.0 - smoothstep(0.62, 0.82, climate.r))
			* smoothstep(0.30, 0.68, climate.g) * health;
		float cool = 1.0 - smoothstep(0.20, 0.44, climate.r);
		float dry = clamp(max((0.35 - climate.g) * 1.4 + (1.0 - health) * 0.45, heat * 0.78), 0.0, 1.0);

		// Soft community edge: fraction of nearby taps that share this community.
		float edge = 1.0;
#ifndef PK_MOBILE_ANY
		if (cover_taps > 1 && ab_p > 0.0) {
			float r = hex_size * 0.22;
			vec4 c1 = gc_cover(gc_cell(lookup + vec2(r, r * 0.35)));
			vec4 c2 = gc_cover(gc_cell(lookup - vec2(r * 0.45, r)));
			float m1 = (floor(c1.r / 16.0) == layer_p ? 1.0 : 0.0) * c1.g / 255.0;
			float m2 = (floor(c2.r / 16.0) == layer_p ? 1.0 : 0.0) * c2.g / 255.0;
			edge = (1.0 + m1 + m2) / 3.0 / max(ab_p, 0.001);
			edge = smoothstep(0.15, 0.85, clamp(edge, 0.0, 1.0));
		}
#endif

		// Gentle wind sway, phase-shifted across the meadow.
		vec2 w = normalize(wind_dir + vec2(0.0001));
		float gust = sin(world_time * 1.15 + dot(wp, w) / (hex_size * 0.7))
			+ 0.4 * sin(world_time * 2.3 + dot(wp, vec2(-w.y, w.x)) / (hex_size * 0.45));
		vec2 sway = w * gust * 0.0045 * (0.5 + wind_strength + weather_wind_boost * 0.6);

		vec4 a = textureGrad(cover_albedo, vec3(uv + sway, layer_p), dx, dy);
#ifndef PK_MOBILE_ANY
		if (visual_quality >= 2) {
			// Anti-tiling: a rotated, rescaled copy blended by macro noise.
			mat2 rot = mat2(vec2(0.766, 0.643), vec2(-0.643, 0.766)) * 0.61;
			vec4 a2 = textureGrad(cover_albedo, vec3(rot * uv + vec2(0.31, 0.17) + sway, layer_p),
				rot * dx, rot * dy);
			float m = smoothstep(0.35, 0.65, gc_noise(wp, hex_size * 3.7, 9.0));
			a = mix(a, a2, m);
		}
#endif
		vec4 b = textureGrad(cover_albedo, vec3(uv * 0.93 + vec2(0.37, 0.21) + sway, layer_s), dx * 0.93, dy * 0.93);
		float clump = gc_noise(wp, clump_scale_hex * hex_size, 5.0) * 0.7
			+ gc_noise(wp, clump_scale_hex * hex_size * 0.37, 6.0) * 0.3;
		float mix_s = ab_s * smoothstep(0.42, 0.62, gc_noise(wp, clump_scale_hex * hex_size * 0.8, 7.0));
		vec3 plant_pm = mix(a.rgb * a.a, b.rgb * b.a, mix_s);
		float plant_a = mix(a.a, b.a, mix_s);
		float abundance = mix(ab_p, ab_s, mix_s);
		// Coverage is sharpened so plant clumps read as solid foliage, gaps as open ground.
		plant_a = smoothstep(0.08, 0.62, plant_a);
		plant_a *= abundance * edge * mix(1.0 - clump_strength, 1.0, smoothstep(0.28, 0.68, clump));
		plant_a *= mix(0.25, 1.0, health)
			* smoothstep(vitality_dead_threshold * 0.3, vitality_dead_threshold, climate.a);
		// Snow buries low communities; only tall tips poke through.
		plant_a *= 1.0 - smoothstep(0.1, 0.8, snow) * 0.85;
		// Winter-withered meadows die back to sparse stubble.
		plant_a *= 1.0 - withered * climate_response * 0.35;
		plant_a = ab_p > 0.0 ? plant_a : 0.0;
		vec3 plant = plant_pm / max(mix(a.a, b.a, mix_s), 0.0001);
		float plant_l = dot(plant, vec3(0.299, 0.587, 0.114));
		plant = max(mix(vec3(plant_l), plant, cover_saturation), vec3(0.0)) * cover_gain * cover_grade;
		// Phenology hues keep the bitmap's luma so leaf detail survives the colour change.
		float graded_l = dot(plant, vec3(0.299, 0.587, 0.114));
		plant = mix(plant, plant * vec3(0.92, 1.07, 0.90), fresh * climate_response * 0.5);
		plant = mix(plant, vec3(0.86, 0.64, 0.18) * graded_l / 0.62, golden * climate_response * 0.60);
		plant = mix(plant, vec3(0.60, 0.47, 0.30) * graded_l / 0.49, withered * climate_response * 0.65);
		float cool_l = dot(plant, vec3(0.299, 0.587, 0.114));
		plant = mix(plant, vec3(cool_l) * vec3(0.96, 1.0, 1.06), cool * climate_response * 0.30);
		plant = mix(plant, vec3(0.56, 0.47, 0.29) * (0.7 + 0.6 * dot(plant, vec3(0.333))), dry * climate_response * 0.45);
		plant = mix(plant, vec3(0.84, 0.88, 0.92), snow * 0.45);

		// Grazing trace underneath (trampled paths, rooting mud, caravan prints).
		vec4 t = vec4(0.0);
		if (trace_kind > 0.5) {
			t = textureGrad(cover_albedo, vec3(uv * 1.27 + vec2(0.53, 0.11), trace_layer_base + trace_kind - 1.0),
				dx * 1.27, dy * 1.27);
		}
		float trace_a = t.a * trace_k * trace_opacity * (1.0 - snow * 0.7) * smoothstep(0.25, 0.6, clump + 0.2);

		// Lighting: same astronomical daylight as terrain; per-pixel sun direction.
		vec2 map_uv = visual_static_wrap_uv(gc_map_uv(wp));
		vec3 sun;
		vec3 amb_c;
		vec3 sun_c;
		float day;
		float moon;
		if (tod_debug_sun_position_enabled) {
			sun = normalize(tod_sun_dir);
			day = smoothstep(-0.08, 0.22, sun.z);
			float dusk = smoothstep(-0.06, 0.14, sun.z) * (1.0 - smoothstep(0.14, 0.42, sun.z));
			sun_c = mix(EARTH_DAYLIGHT_NOON, EARTH_DAYLIGHT_DUSK, dusk);
			amb_c = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, day);
			moon = (1.0 - day) * 0.72;
		} else {
			EarthDaylight ed = eval_earth_daylight(map_uv, clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0, day_night_enabled);
			sun = ed.sun_dir;
			sun_c = ed.sun_col;
			amb_c = ed.amb_col;
			day = ed.local_day;
			moon = ed.moon_strength;
		}
		vec2 terrain_xy = terrain_normal_tex_bound ? (visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0) * 0.65 : vec2(0.0);
		vec3 n = normalize(vec3(terrain_xy, 1.0));
		float ao = 1.0;
		float self_shadow = 0.0;
		// Canopy height 0..1 (normal strip B); coverage is a cheap proxy without the normal map.
		float hgt = a.a * 0.6;
#ifndef PK_MOBILE_ANY
		if (visual_quality >= 1) {
			vec4 nm = textureGrad(cover_normal, vec3(uv + sway, layer_p), dx, dy);
			vec2 nxy = (nm.rg * 2.0 - 1.0) * normal_strength;
			n = normalize(vec3(terrain_xy + vec2(nxy.x, -nxy.y), 1.0));
			ao = mix(1.0, nm.a, 0.8);
			hgt = nm.b;
			// Rough cast shadow, zero extra fetches (the tree blob-shadow idea): the relief
			// normal is the slope of the blurred tuft height, so in a gap a normal facing
			// away from the sun means a tuft stands sunward of it. Longer at low sun.
			float away = -dot(vec2(nxy.x, -nxy.y), normalize(sun.xy + vec2(0.0001)));
			float cast = smoothstep(0.04, 0.30, away * mix(1.0, 1.8, 1.0 - clamp(sun.z, 0.0, 1.0)));
			self_shadow = cast * (1.0 - a.a) * shadow_strength * day * abundance * edge;
		}
#endif
		TerrainHorizonSample horizon = terrain_horizon_evaluate(map_uv, sun);
		// Fake GI: deep foliage sees less sky (height AO), terrain sky visibility and bent
		// normal from the shared horizon bake, exactly like the vegetation impostors.
		// Mean-preserving: tops brighten as much as the deep foliage darkens.
		float depth_ao = mix(0.80, 1.12, pow(clamp(hgt, 0.0, 1.0), 0.6));
		vec3 amb_n = n;
		float sky_vis = 1.0;
		if (horizon.has_data) {
			vec3 mixed_n = mix(n, horizon.bent_normal, gi_bent_strength);
			amb_n = dot(mixed_n, mixed_n) > 1e-6 ? normalize(mixed_n) : n;
			sky_vis = terrain_horizon_apply_normal(horizon.sky_visibility, n, horizon.bent_normal);
			sky_vis = mix(1.0, sky_vis, (gi_lut_bound ? gi_ao_strength : 0.6) * 0.6);
		}
		vec3 sky = earth_sky_sh(amb_c, sun_c, sun, day, amb_n);
		sky = mix(sky, vec3(dot(sky, vec3(0.333))), light_neutralize * day) * ao * depth_ao * sky_vis;
		float direct = day * horizon.direct_visibility;
		// Leaf tips glow a little when backlit/side-lit (thin-leaf transmission).
		float transmit = day * pow(clamp(hgt, 0.0, 1.0), 2.0) * (1.0 - sun.z * 0.6) * 0.22;
		vec3 light = (sky + sun_c * direct * max(dot(n, sun), 0.0) * 0.78
			+ sun_c * transmit * horizon.direct_visibility
			+ EARTH_MOONLIGHT * moon * max(n.z, 0.0) * 0.30) * tod_exposure * light_gain;
		// Shadowed valleys of the terrain dim the meadow like the rest of the ground.
		float horizon_cast = clamp((1.0 - horizon.direct_visibility) * day, 0.0, 1.0);
		light *= mix(1.0, mix(1.0, terrain_horizon_cast_floor, 0.7), horizon_cast);

		// Composite inside the layer: plant over canopy shadow over trace.
		vec3 trace_rgb = t.rgb / max(t.a, 0.0001) * light;
		out_pm = trace_rgb * trace_a;
		out_a = trace_a;
		vec3 shadow_rgb = vec3(0.10, 0.11, 0.08) * light;
		out_pm = shadow_rgb * self_shadow + out_pm * (1.0 - self_shadow);
		out_a = self_shadow + out_a * (1.0 - self_shadow);
		out_pm = plant * light * plant_a + out_pm * (1.0 - plant_a);
		out_a = plant_a + out_a * (1.0 - plant_a);

		// Never on water or the river body.
		if (has_height_tex) {
			vec4 ground = visual_sample_height(gc_map_uv(wp));
			float height = (ground.r * 256.0 + ground.g) / 257.0;
			float land = smoothstep(sea_level - 0.002, sea_level + 0.004, height);
			float river = has_flow_tex ? 1.0 - smoothstep(river_clear_threshold - 0.10, river_clear_threshold, ground.b) : 1.0;
			out_a *= land * river;
			out_pm *= land * river;
		}
		float far = mix(far_opacity, 1.0, smoothstep(8.0, 24.0, hex_px));
		float k = cover_opacity * far * mix(1.0, lens_dim, clamp(lens_amount, 0.0, 1.0));
		out_a *= k;
		out_pm *= k;
	}
	COLOR = vec4(out_pm / max(out_a, 0.0001), out_a);
}
