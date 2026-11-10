// Shared top-down map lighting for instanced sprites (trade vehicles and army
// formations). Keep the formula here so both layers sample the exact same
// daylight, terrain normal, horizon shadow, sky GI and moon response.
#ifndef TERRAIN_INSTANCE_LIGHTING_INC
#define TERRAIN_INSTANCE_LIGHTING_INC

#define VT_USE_HORIZON
#define VT_USE_TERRAIN_NORMAL

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
uniform int visual_quality = 2;
uniform bool terrain_instance_lighting_enabled = true;

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

vec2 wrap_map_uv(vec2 uv) {
	return visual_static_wrap_uv(uv);
}

#include "res://shaders/include/terrain_horizon.gdshaderinc"

struct TerrainInstanceLight {
	vec3 color;
	vec3 sun_dir;
	float local_day;
	float direct_visibility;
	float sky_visibility;
	bool horizon_has_data;
};

// Evaluate once per vertex. At formation scale this is one map sample per
// sprite instance, never one terrain fetch per screen pixel.
TerrainInstanceLight eval_terrain_instance_lighting(vec2 world_center) {
	TerrainInstanceLight result;
	result.color = vec3(1.0);
	result.sun_dir = vec3(0.0, 0.0, 1.0);
	result.local_day = 1.0;
	result.direct_visibility = 1.0;
	result.sky_visibility = 1.0;
	result.horizon_has_data = false;
	if (!terrain_instance_lighting_enabled) {
		return result;
	}

	vec2 map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	EarthDaylight ed = eval_earth_daylight(
		map_uv,
		clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0,
		day_night_enabled
	);
	vec3 n = vec3(0.0, 0.0, 1.0);
	TerrainHorizonSample hs;
	hs.direct_visibility = 1.0;
	hs.sky_visibility = 1.0;
	hs.bent_normal = n;
	hs.nearest_packed = vec4(0.0);
	hs.has_data = false;
	if (visual_quality >= 2) {
		if (terrain_normal_tex_bound) {
			n = normalize(vec3(
				(visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0)
					* terrain_normal_influence,
				1.0
			));
		}
		if (terrain_horizon_tex_bound && terrain_horizon_strength > 0.0) {
			hs = terrain_horizon_evaluate(map_uv, ed.sun_dir);
		}
	}
	vec3 amb_n = hs.has_data
		? normalize(mix(n, hs.bent_normal, gi_bent_strength))
		: n;
	float sky = hs.has_data
		? terrain_horizon_apply_normal(hs.sky_visibility, n, hs.bent_normal)
		: 1.0;
	vec3 amb = sky_ambient_srgb(
		ed.local_day, amb_n, ed.amb_col, ed.sun_col, ed.sun_dir);
	float ndl = max(dot(n, ed.sun_dir), 0.0)
		* ed.local_day * hs.direct_visibility;
	float mdl = max(dot(n, -ed.sun_dir), 0.0) * ed.moon_strength;
	result.color = (
		amb * mix(1.0, 0.62, ed.local_day) * sky
		+ ed.sun_col * ndl * 0.78
		+ EARTH_MOONLIGHT * mdl * 0.40
	) * tod_exposure;
	result.sun_dir = ed.sun_dir;
	result.local_day = ed.local_day;
	result.direct_visibility = hs.direct_visibility;
	result.sky_visibility = sky;
	result.horizon_has_data = hs.has_data;
	return result;
}

#endif
