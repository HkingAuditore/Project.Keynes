shader_type canvas_item;
render_mode unshaded;

// Ground tree-shadow receiver pass (z=1 below canopy z=3).
// Shares earth_daylight, cloud_shadow, world_lighting_field, and fog knowledge
// with the terrain and canopy so shadow direction, length, and fog/night fade match.

uniform sampler2D coverage_tex : filter_linear, repeat_disable;
uniform sampler2D city_mask_tex : filter_linear, repeat_disable;
uniform sampler2D cell_meta_tex : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform bool cell_luts_bound = false;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);

uniform float shadow_strength = 0.44;
uniform float canopy_height_world = 18.0;
uniform float min_sun_elevation = 0.26;
uniform float max_shadow_length_world = 42.0;
uniform float page_world_span = 640.0;
uniform float halo_uv_margin = 0.10;
uniform bool shadow_enabled = true;

#define PK_CLOUD_SHADOW_DIRECT
#define PK_WORLD_LIGHTING_FIELD
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/cloud_shadow.gdshaderinc"
#include "res://shaders/include/world_lighting_field.gdshaderinc"

varying vec2 v_world_pos;

void vertex() {
	v_world_pos = VERTEX;
}

vec2 cell_lut_uv(float cid) {
	float lw = max(lut_dims.x, 1.0);
	float lh = max(lut_dims.y, 1.0);
	return vec2((mod(cid, lw) + 0.5) / lw, (floor(cid / lw) + 0.5) / lh);
}

float sample_occluder(vec2 uv) {
	vec2 clamped = clamp(uv, vec2(0.002), vec2(0.998));
	vec4 cov = texture(coverage_tex, clamped);
	float city = texture(city_mask_tex, clamped).r;
	return cov.r * (0.45 + 0.55 * cov.a) * (1.0 - city);
}

void fragment() {
	if (!shadow_enabled) {
		discard;
	}
	float fog_k = 1.0;
	if (cell_luts_bound) {
		vec4 meta = texture(cell_meta_tex, UV);
		float cid = floor(meta.r * 255.0 + 0.5) + floor(meta.g * 255.0 + 0.5) * 256.0;
		fog_k = texture(enum_lut, cell_lut_uv(cid)).a;
		if (fog_k < 0.25) {
			discard;
		}
	}

	vec2 wp = v_world_pos;
	if (wrap_period_x > 0.001) {
		wp.x = wrap_origin_x + mod(wp.x - wrap_origin_x, wrap_period_x);
	}
	vec2 map_uv = (wp - world_origin) / max(world_size, vec2(1.0));
	float lat_signed = clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0;

	EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);
	float local_day = ed.local_day;
	if (local_day <= 0.03) {
		discard;
	}
	vec3 L = normalize(ed.sun_dir);
	float elev_fade = smoothstep(0.05, 0.22, L.z);
	if (elev_fade <= 0.001) {
		discard;
	}

	float horizon_vis = world_lighting_active() ? sample_world_lighting(map_uv).a : 1.0;
	float cloud_vis = cloud_shadow_direct_visibility(map_uv, local_day);

	// Direction from receiver point toward the sun (opposite of cast shadow shift).
	vec2 ray_world = canopy_height_world * L.xy / max(L.z, min_sun_elevation);
	float ray_len = length(ray_world);
	float max_halo_world = page_world_span * halo_uv_margin * 0.92;
	float clamped_len = min(ray_len, min(max_shadow_length_world, max_halo_world));
	vec2 ray_uv = (ray_len > 0.0001)
		? (ray_world * (clamped_len / ray_len)) / max(page_world_span, 1.0)
		: vec2(0.0);

	// Soft directional shadow + subtle contact grounding under forest edge.
	float contact = sample_occluder(UV) * 0.25;
	float cast_occ = 0.0;
	cast_occ += sample_occluder(UV + ray_uv * 0.28) * 0.28;
	cast_occ += sample_occluder(UV + ray_uv * 0.56) * 0.32;
	cast_occ += sample_occluder(UV + ray_uv * 0.85) * 0.24;
	cast_occ += sample_occluder(UV + ray_uv * 1.05) * 0.16;
	float occ = max(cast_occ, contact);

	float fog_vis = smoothstep(0.35, 0.95, fog_k);
	float shadow_a = clamp(occ * shadow_strength * local_day * elev_fade * horizon_vis * cloud_vis * fog_vis, 0.0, 0.52);
	if (shadow_a < 0.01) {
		discard;
	}
	// Match vegetation_impostor's cool shadow floor tint.
	COLOR = vec4(0.035, 0.05, 0.055, shadow_a);
}
