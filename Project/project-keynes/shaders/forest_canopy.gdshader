shader_type canvas_item;
render_mode unshaded;

// Large-area forest canopy shader aligned 1:1 with vegetation_impostor.gdshaderinc:
// - Reads per-chunk coverage_tex, city_mask_tex, and cell_meta_tex (RG=cell_id, BA=terrain_normal).
// - Samples dyn_lut, eco_lut, enum_lut using the exact cell LUT indirection.
// - Evaluates veg_cell_state() + veg_palette() for authentic climate, phenology,
//   drought, autumn red, vitality, and snow response across biomes.
// - Shares earth_daylight, cloud_shadow, world_lighting_field, contact AO,
//   terrain slope normal, night floor, and pk_fog_memory_wash with the original trees.

#include "res://shaders/include/fog_memory.gdshaderinc"

uniform sampler2D coverage_tex : filter_linear, repeat_disable;
uniform sampler2D city_mask_tex : filter_linear, repeat_disable;
uniform sampler2D cell_meta_tex : filter_nearest, repeat_disable;
uniform sampler2DArray canopy_albedo_tiles : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray canopy_aux_tiles : filter_linear_mipmap, repeat_enable;

// Shared simulation display LUTs (bound from HexRenderer._shader_mat).
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform bool cell_luts_bound = false;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

uniform float hex_size = 32.0;
uniform float tile_hex_span = 2.6;

// Earth daylight / TOD uniforms (shared with earth_daylight.gdshaderinc).
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;

// Climate & phenology uniforms required by vegetation_climate.gdshaderinc
// (matched to tree_default.tres defaults).
uniform float dry_yellow_strength = 0.92;
uniform float wet_green_strength = 0.42;
uniform float lush_green_strength = 0.62;
uniform float heat_red_strength = 0.44;
uniform float autumn_red_strength = 0.68;
uniform float temperature_color_strength = 0.76;
uniform float moisture_color_strength = 0.78;
uniform float snow_white_strength = 0.92;
uniform float stress_hide_strength = 0.65;
uniform float snow_hide_strength = 0.08;
uniform float vitality_dead_threshold = 0.14;
uniform float vitality_healthy_threshold = 0.74;
uniform float vitality_alpha_power = 1.15;
uniform float vitality_low_color_strength = 0.66;
uniform float vitality_high_color_strength = 0.36;
uniform float vitality_color_contrast = 0.88;

// Wind & lighting parameters matched to vegetation_impostor.gdshaderinc.
uniform vec2 wind_dir = vec2(1.0, 0.22);
uniform float wind_strength = 0.85;
uniform float wind_time = 0.0;
uniform float snow_amount = 0.0;
uniform bool normal_enabled = true;
uniform bool ao_enabled = true;
uniform float contact_ao_strength = 0.42;
uniform float sun_shade_strength = 0.55;
uniform float ambient_floor = 0.22;
uniform float terrain_horizon_cast_floor = 0.82;
uniform float self_shadow_strength = 0.45;
uniform float fog_gray_strength = 0.75;

#define PK_CLOUD_SHADOW_DIRECT
#define PK_WORLD_LIGHTING_FIELD
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/cloud_shadow.gdshaderinc"
#include "res://shaders/include/world_lighting_field.gdshaderinc"
#include "res://shaders/include/vegetation_climate.gdshaderinc"

varying vec2 v_world_pos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float smooth_noise2d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	v_world_pos = VERTEX;
}

vec2 canonical_world(vec2 wp) {
	if (wrap_period_x > 0.001) {
		wp.x = wrap_origin_x + mod(wp.x - wrap_origin_x, wrap_period_x);
	}
	return wp;
}

vec2 cell_lut_uv(float cid) {
	float lw = max(lut_dims.x, 1.0);
	float lh = max(lut_dims.y, 1.0);
	float cx = mod(cid, lw);
	float cy = floor(cid / lw);
	return vec2((cx + 0.5) / lw, (cy + 0.5) / lh);
}

void sample_species(int layer_idx, vec2 tile_uv, out vec4 alb, out vec4 aux) {
	alb = texture(canopy_albedo_tiles, vec3(tile_uv, float(layer_idx)));
	aux = texture(canopy_aux_tiles, vec3(tile_uv, float(layer_idx)));
}

vec2 rot90_uv(vec2 uv) {
	return vec2(-uv.y, uv.x);
}

vec2 rot90_nxy(vec2 nxy) {
	return vec2(-nxy.y, nxy.x);
}

vec3 species_source_rgb(int s_idx) {
	if (s_idx == 1) {
		return vec3(0.18, 0.30, 0.21); // conifer
	}
	if (s_idx == 2) {
		return vec3(0.28, 0.42, 0.20); // palm
	}
	return vec3(0.24, 0.37, 0.18); // broadleaf
}

float species_phenology_resp(int s_idx) {
	if (s_idx == 1) return 0.16; // evergreen conifer
	if (s_idx == 2) return 0.24; // tropical palm
	return 1.0;                  // deciduous broadleaf
}

float species_snow_hold(int s_idx) {
	if (s_idx == 1) return 0.92; // conifers hold deep snow caps
	if (s_idx == 2) return 0.25;
	return 0.58;
}

void fragment() {
	vec4 cov_sample = texture(coverage_tex, UV);
	float city_mask = texture(city_mask_tex, UV).r;
	float forest_cov = cov_sample.r * (1.0 - city_mask);
	if (forest_cov < 0.06) {
		discard;
	}

	// Decode per-pixel cell index & terrain macro slope normal from cell_meta_tex.
	vec4 meta = texture(cell_meta_tex, UV);
	float cid = floor(meta.r * 255.0 + 0.5) + floor(meta.g * 255.0 + 0.5) * 256.0;
	vec2 terrain_n = (meta.ba * 2.0 - 1.0) * 1.15;

	// Sample live cell climate / phenology / fog knowledge LUTs (same as original trees).
	vec4 dyn = vec4(0.55, 0.62, snow_amount, 0.85);
	vec4 eco = vec4(0.0, 0.0, 0.0, 0.0);
	float fog_k = 1.0;
	if (cell_luts_bound) {
		vec2 luv = cell_lut_uv(cid);
		dyn = texture(dyn_lut, luv);
		eco = texture(eco_lut, luv);
		fog_k = texture(enum_lut, luv).a;
	}
	if (fog_k < 0.01) {
		discard;
	}

	vec2 wp = canonical_world(v_world_pos);
	vec2 map_uv = (wp - world_origin) / max(world_size, vec2(1.0));
	float lat_signed = clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0;

	EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);
	vec3 L = normalize(ed.sun_dir);
	float local_day = ed.local_day;

	// Travelling gust wave across the canopy.
	vec2 wdir = normalize(wind_dir + vec2(0.0001, 0.0));
	float gust_phase = dot(wp, wdir) * 0.022 - wind_time * 1.65;
	float gust_wave = sin(gust_phase) + 0.45 * sin(gust_phase * 2.13 + dot(wp, vec2(-wdir.y, wdir.x)) * 0.031);
	float micro_sway = sin(wind_time * 2.4 + wp.x * 0.09 + wp.y * 0.07);
	float sway_scale = (0.010 * gust_wave + 0.0035 * micro_sway) * wind_strength * clamp(cov_sample.a + 0.25, 0.0, 1.0);

	float tile_world = max(hex_size * tile_hex_span, 16.0);
	vec2 tile_uv = wp / tile_world + wdir * sway_scale;

	// Select top-2 species from (broadleaf, conifer, palm).
	float w_con = cov_sample.g;
	float w_palm = cov_sample.b;
	float w_broad = max(0.0, 1.0 - w_con - w_palm);

	int s0 = 0;
	int s1 = 1;
	float wt0 = w_broad;
	float wt1 = w_con;
	if (w_con >= w_broad && w_con >= w_palm) {
		s0 = 1; wt0 = w_con;
		if (w_broad >= w_palm) { s1 = 0; wt1 = w_broad; } else { s1 = 2; wt1 = w_palm; }
	} else if (w_palm >= w_broad && w_palm >= w_con) {
		s0 = 2; wt0 = w_palm;
		if (w_broad >= w_con) { s1 = 0; wt1 = w_broad; } else { s1 = 1; wt1 = w_con; }
	} else {
		s0 = 0; wt0 = w_broad;
		if (w_con >= w_palm) { s1 = 1; wt1 = w_con; } else { s1 = 2; wt1 = w_palm; }
	}
	float wt_sum = max(wt0 + wt1, 0.001);
	wt0 /= wt_sum;
	wt1 /= wt_sum;

	// Evaluate live climate cell state & vitality thinning (mirrors vegetation_impostor).
	VegCellState cs = veg_cell_state(dyn, eco, 0.0);
	float phen_resp0 = species_phenology_resp(s0);
	float presence = veg_presence(cs, dyn, phen_resp0);
	float eff_cov = forest_cov * mix(0.45, 1.0, presence);
	if (eff_cov < 0.06) {
		discard;
	}

	// Smooth continuous noise (zero grid-cell seams).
	float n_edge = smooth_noise2d(wp / max(hex_size * 0.90, 8.0));
	float n_clump = smooth_noise2d(wp / max(hex_size * 1.90, 16.0) + vec2(17.3, 9.1));

	// Tier 1: crisp individual crowns.
	vec4 alb_t1;
	vec4 aux_t1;
	sample_species(s0, tile_uv, alb_t1, aux_t1);
	vec2 nxy_t1 = aux_t1.rg * 2.0 - 1.0;

	float t1_cov = eff_cov + (n_edge - 0.5) * 0.24 + (n_clump - 0.5) * 0.16;
	float t1_cut = mix(0.74, 0.36, smoothstep(0.08, 0.50, t1_cov));
	float a1 = smoothstep(t1_cut - 0.06, t1_cut + 0.08, alb_t1.a) * smoothstep(0.06, 0.16, t1_cov);

	vec3 acc_rgb = alb_t1.rgb;
	vec2 acc_nxy = nxy_t1;
	float acc_h = aux_t1.b;
	float acc_ao = aux_t1.a;
	float acc_a = a1;
	int dom_species = s0;

	// Tier 2: rotated offset layer in mid/dense stands (mixes secondary species cleanly).
	float t2_cov = eff_cov + (n_clump - 0.5) * 0.18;
	if (t2_cov > 0.42) {
		int s_t2 = (wt1 > 0.16) ? s1 : s0;
		vec2 uv_t2 = rot90_uv(tile_uv * 1.07) + vec2(0.37, 0.61);
		vec4 alb_t2;
		vec4 aux_t2;
		sample_species(s_t2, uv_t2, alb_t2, aux_t2);
		float t2_cut = mix(0.78, 0.38, smoothstep(0.42, 0.78, t2_cov));
		float a2 = smoothstep(t2_cut - 0.06, t2_cut + 0.08, alb_t2.a) * smoothstep(0.42, 0.54, t2_cov);
		if (a2 > 0.02) {
			vec2 nxy_t2 = rot90_nxy(aux_t2.rg * 2.0 - 1.0);
			float h1_cmp = acc_h * acc_a + 0.06;
			float h2_cmp = aux_t2.b * a2;
			float t2_wins = smoothstep(-0.05, 0.05, h2_cmp - h1_cmp);
			float new_a = clamp(acc_a + a2 * (1.0 - acc_a), 0.0, 1.0);
			float mix_w = (acc_a < 0.02) ? 1.0 : t2_wins;
			acc_rgb = mix(acc_rgb, alb_t2.rgb * mix(0.84, 1.0, t2_wins), mix_w);
			acc_nxy = mix(acc_nxy, nxy_t2, mix_w);
			acc_h = mix(acc_h, aux_t2.b * 0.92, mix_w);
			acc_ao = mix(acc_ao, aux_t2.a * mix(0.78, 0.96, t2_wins), mix_w);
			acc_a = new_a;
			if (mix_w > 0.5) {
				dom_species = s_t2;
			}
		}
	}

	// Tier 3: shaded understory only in the densest rainforest/old-growth cores.
	float t3_cov = eff_cov + (n_edge - 0.5) * 0.14;
	if (t3_cov > 0.74 && acc_a < 0.94) {
		vec2 uv_t3 = tile_uv * 1.21 + vec2(0.58, 0.23);
		vec4 alb_t3;
		vec4 aux_t3;
		sample_species(s0, uv_t3, alb_t3, aux_t3);
		float t3_cut = mix(0.76, 0.40, smoothstep(0.74, 0.94, t3_cov));
		float a3 = smoothstep(t3_cut - 0.06, t3_cut + 0.08, alb_t3.a) * smoothstep(0.74, 0.86, t3_cov);
		if (a3 > 0.02) {
			float under_w = a3 * (1.0 - acc_a);
			float new_a = clamp(acc_a + under_w, 0.0, 1.0);
			float blend_u = under_w / max(new_a, 0.001);
			acc_rgb = mix(acc_rgb, alb_t3.rgb * 0.62, blend_u);
			acc_nxy = mix(acc_nxy, aux_t3.rg * 2.0 - 1.0, blend_u);
			acc_h = mix(acc_h, aux_t3.b * 0.45, blend_u);
			acc_ao = mix(acc_ao, aux_t3.a * 0.58, blend_u);
			acc_a = new_a;
		}
	}

	if (acc_a < 0.05) {
		discard;
	}

	// Authentic climate & phenology palette via veg_palette() (identical to original trees).
	float crown_seed = clamp(n_edge * 0.62 + n_clump * 0.38, 0.0, 1.0);
	float dom_phen_resp = species_phenology_resp(dom_species);
	VegPalette pal = veg_palette(
		species_source_rgb(dom_species), cs, crown_seed,
		dom_phen_resp, 0.64, 1.0, 0.94, 0.96
	);

	// Blend climate palette with crown sprite hue at palette brightness (vegetation_impostor L635-647).
	vec3 leaf = pal.leaf;
	leaf *= 0.90 + 0.20 * n_edge;
	float red_pick = smoothstep(0.38, 0.72, n_clump);
	leaf = mix(leaf, pal.red_col, red_pick * pal.red_amt);
	float leaf_l = dot(leaf, vec3(0.299, 0.587, 0.114));
	float greenness = smoothstep(0.08, 0.35, (leaf.g - max(leaf.r, leaf.b)) / max(leaf.g, 0.01));
	vec3 albedo = mix(leaf, acc_rgb * 1.45 * leaf_l, mix(0.15, 1.0, greenness));

	// Snow cap driven by live dyn_lut snow & cold (not a hardcoded scalar).
	float snow_cap = smoothstep(0.32, 0.82, acc_h + (n_edge - 0.5) * 0.16);
	float local_snow = max(pal.snow_amt, snow_amount) * species_snow_hold(dom_species) * mix(0.45, 1.0, snow_cap);
	albedo = mix(albedo, vec3(0.93, 0.95, 0.99), clamp(local_snow, 0.0, 0.95));

	// Crown dome normal blended onto terrain macro slope normal (vegetation_impostor L630).
	vec3 n_loc = vec3(0.0, 0.0, 1.0);
	if (normal_enabled) {
		vec2 nxy = acc_nxy + wdir * (gust_wave * 0.07 * wind_strength * acc_h);
		float nz = sqrt(max(0.08, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.92)));
		n_loc = normalize(vec3(nxy, nz));
	}
	vec3 N = normalize(vec3(n_loc.xy + terrain_n * n_loc.z, n_loc.z));

	// Directional canopy self-shadowing (2-tap height march toward +L.xy).
	float self_vis = 1.0;
	if (normal_enabled && local_day > 0.03 && L.z > 0.04) {
		vec2 sun_step = (L.xy / max(L.z, 0.32)) * 0.022;
		float h1 = texture(canopy_aux_tiles, vec3(tile_uv + sun_step * 0.65, float(dom_species))).b;
		float h2 = texture(canopy_aux_tiles, vec3(tile_uv + sun_step * 1.45, float(dom_species))).b;
		float occ = clamp((max(h1, h2) - acc_h - 0.05) * 2.2, 0.0, 1.0);
		self_vis = 1.0 - occ * self_shadow_strength;
	}

	// Shared world lighting (terrain horizon + PTT-GI bounce) & cloud shadows.
	float horizon_vis = 1.0;
	vec3 wl_bounce = vec3(0.0);
	if (world_lighting_active()) {
		vec4 wl = sample_world_lighting(map_uv);
		horizon_vis = wl.a;
		wl_bounce = wl.rgb * world_lighting_radiance_scale * 0.18;
	}
	vec2 cloud_vis = cloud_shadow_land_visibility(map_uv, local_day);

	// Lighting formula matched directly to vegetation_impostor.gdshaderinc L649-707.
	vec3 sun_col = mix(EARTH_DAYLIGHT_DUSK, EARTH_DAYLIGHT_NOON, ed.sun_high);
	vec3 amb_col = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, local_day);
	if (!day_night_enabled) {
		sun_col *= EARTH_ETERNAL_SUN_GAIN;
		amb_col *= EARTH_ETERNAL_AMBIENT_GAIN;
	}

	float wrap = 0.30;
	float diff = clamp((dot(N, L) + wrap) / (1.0 + wrap), 0.0, 1.0);
	float direct = diff * local_day * horizon_vis * self_vis * cloud_vis.x;
	vec3 amb = sky_ambient_srgb(local_day, N, amb_col, sun_col, L) * cloud_vis.y;
	float moon = max(dot(N, -L), 0.0) * ed.moon_strength;

	vec3 light = max(amb * mix(1.0, 0.70, local_day), vec3(ambient_floor * 0.5))
		+ wl_bounce
		+ sun_col * direct * sun_shade_strength * 1.40
		+ EARTH_MOONLIGHT * moon * 0.35;

	float ao_factor = ao_enabled ? mix(1.0, acc_ao, clamp(contact_ao_strength * 2.0, 0.0, 1.0)) : 1.0;
	vec3 rgb = albedo * light * ao_factor;

	// Night floor consistent with vegetation_impostor.gdshaderinc.
	rgb = max(rgb, albedo * 0.38 * 0.45 * mix(0.75, 1.0, local_day));
	rgb = max(rgb, vec3(0.013, 0.016, 0.023) * (1.0 - local_day));

	float horizon_cast = clamp((1.0 - horizon_vis) * local_day, 0.0, 1.0);
	if (horizon_cast > 0.001) {
		rgb *= mix(1.0, mix(1.0, terrain_horizon_cast_floor, 0.70), horizon_cast);
	}
	rgb *= mix(1.0, 0.86, 1.0 - local_day);
	rgb *= tod_exposure;

	// Fog-of-war memory wash (explored-but-unseen cells sink into fog like terrain/old trees).
	rgb = pk_fog_memory_wash(rgb, fog_k, fog_gray_strength);
	float final_a = acc_a * smoothstep(0.02, 0.25, fog_k);

	COLOR = vec4(rgb, final_a);
}
