shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Pass 3 of WorldLightingField:
// Composite shared world_lighting_tex:
//   RGB = PTT-GI indirect bounce irradiance (scaled by 1 / radiance_scale, LINEAR)
//   A   = dynamic terrain direct-sun visibility [0, 1]
// Render target MUST use transparent_bg = true with blend_disabled so Alpha is
// written verbatim without blending against a clear color.

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float season_phase = 0.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4091;
uniform bool day_night_enabled = false;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.5, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.0, 0.0, 1.0);
uniform bool tod_latitude_sun_enabled = true;
uniform float tod_sun_relief_max_up = 0.88;
uniform float daylight_height_px = 2.0;

#include "res://shaders/include/earth_daylight.gdshaderinc"

#define VT_USE_HORIZON
#ifndef MAP_VISUAL_TILED
#define VT_USE_TERRAIN_SURFACE_ARRAY
#endif
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

uniform bool direct_shadow_enabled = true;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_strength = 1.20;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_max_angle = 1.309;

#include "res://shaders/include/terrain_horizon_shadow.gdshaderinc"

uniform sampler2D indirect_light_tex : filter_linear, repeat_disable;
uniform bool ptt_gi_ready = false;

float composite_unpack_byte(vec4 packed, int channel_index) {
	if (channel_index == 0) return floor(packed.r * 255.0 + 0.5);
	if (channel_index == 1) return floor(packed.g * 255.0 + 0.5);
	if (channel_index == 2) return floor(packed.b * 255.0 + 0.5);
	return floor(packed.a * 255.0 + 0.5);
}

float composite_unpack_nibble(vec4 packed, int dir_index) {
	int ch = dir_index / 2;
	float byte_v = composite_unpack_byte(packed, ch);
	float hi = floor(byte_v / 16.0);
	float lo = byte_v - hi * 16.0;
	return ((dir_index % 2) == 0) ? hi : lo;
}

float composite_horizon_angle_by_index(vec4 packed, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	return (composite_unpack_nibble(packed, idx) / 15.0) * terrain_horizon_max_angle;
}

float composite_horizon_angle_from_packed(vec4 packed, float sector) {
	int i0 = int(floor(sector));
	float t = fract(sector);
	float h0 = composite_horizon_angle_by_index(packed, i0);
	float h1 = composite_horizon_angle_by_index(packed, i0 + 1);
	return mix(h0, h1, t);
}

float composite_direct_visibility_from_packed(vec2 uv, vec3 light_dir) {
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len <= 1e-4) {
		return 1.0;
	}
	sun_xy /= sun_h_len;
	float angle = atan(sun_xy.y, sun_xy.x);
	if (angle < 0.0) {
		angle += TERRAIN_HORIZON_TAU;
	}
	float sector = angle / TERRAIN_HORIZON_OCTANT;

	vec4 p00;
	vec4 p10;
	vec4 p01;
	vec4 p11;
	vec2 f;
#ifdef PK_HORIZON_GATHER
	visual_gather_horizon(uv, p00, p10, p01, p11, f);
#else
#ifdef MAP_VISUAL_TILED
	vec2 dims = visual_logical_resolution;
	vec2 world_p = world_origin + uv * world_size;
	if (wrap_period_x > 0.0001) {
		world_p.x = wrap_origin_x + mod(world_p.x - wrap_origin_x, wrap_period_x);
	}
	vec2 domain_uv = clamp(
		(world_p - visual_domain_origin) / max(visual_domain_size, vec2(0.0001)),
		vec2(0.0),
		vec2(1.0)
	);
	vec2 p = domain_uv * dims - vec2(0.5);
#else
	vec2 dims = vec2(textureSize(terrain_horizon_tex, 0));
	vec2 p = visual_static_wrap_uv(uv) * dims - vec2(0.5);
#endif
	vec2 b = floor(p);
	f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));
#ifdef MAP_VISUAL_TILED
	vec2 uv00 = (visual_domain_origin + (b + vec2(0.5, 0.5)) * inv_dims * visual_domain_size - world_origin) / world_size;
	vec2 uv10 = (visual_domain_origin + (b + vec2(1.5, 0.5)) * inv_dims * visual_domain_size - world_origin) / world_size;
	vec2 uv01 = (visual_domain_origin + (b + vec2(0.5, 1.5)) * inv_dims * visual_domain_size - world_origin) / world_size;
	vec2 uv11 = (visual_domain_origin + (b + vec2(1.5, 1.5)) * inv_dims * visual_domain_size - world_origin) / world_size;
#else
	vec2 uv00 = visual_static_wrap_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = visual_static_wrap_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = visual_static_wrap_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = visual_static_wrap_uv((b + vec2(1.5, 1.5)) * inv_dims);
#endif
	p00 = visual_sample_horizon(uv00);
	p10 = visual_sample_horizon(uv10);
	p01 = visual_sample_horizon(uv01);
	p11 = visual_sample_horizon(uv11);
#endif

	float h00 = composite_horizon_angle_from_packed(p00, sector);
	float h10 = composite_horizon_angle_from_packed(p10, sector);
	float h01 = composite_horizon_angle_from_packed(p01, sector);
	float h11 = composite_horizon_angle_from_packed(p11, sector);
	float horizon_angle = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);

	return terrain_horizon_visibility_at_angle(light_dir, sun_h_len, horizon_angle);
}

void fragment() {
	vec3 indirect_rgb = vec3(0.0);
	if (ptt_gi_ready) {
		indirect_rgb = texture(indirect_light_tex, visual_static_wrap_uv(UV)).rgb;
	}

	float direct_vis = 1.0;
	if (direct_shadow_enabled && terrain_horizon_strength > 0.0) {
		bool use_dir_tex = horizon_dir_tex_bound;
#ifndef MAP_VISUAL_TILED
		use_dir_tex = use_dir_tex && (terrain_surface_layer_count >= 10);
#endif
		if (use_dir_tex || terrain_horizon_tex_bound) {
			float lat_signed = earth_daylight_latitude_norm(UV.y, daylight_height_px) * 2.0 - 1.0;
			EarthDaylight ed = eval_earth_daylight(UV, lat_signed, day_night_enabled);
			vec3 light_dir = earth_daylight_key_dir(ed, tod_sun_dir,
				tod_latitude_sun_enabled || !day_night_enabled, tod_sun_relief_max_up);
			if (use_dir_tex) {
				direct_vis = terrain_horizon_direct_from_dir_tex(UV, light_dir);
			} else {
				direct_vis = composite_direct_visibility_from_packed(UV, light_dir);
			}
		}
	}

	COLOR = vec4(indirect_rgb, direct_vis);
}
