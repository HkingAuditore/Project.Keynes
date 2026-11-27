shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Pass 1 of WorldLightingField:
// Evaluate per-texel linear direct exitant radiance D on the coarse PTT-GI grid.
// Output RGB = clamp(D / radiance_scale, 0.0, 1.0), A = 1.0.

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

#include "res://shaders/include/earth_daylight.gdshaderinc"

// RGB = sRGB coarse albedo, A = land mask [0, 1]
uniform sampler2D ptt_albedo_tex : filter_nearest, repeat_disable;
// R = coupling C_i, GB = coarse_normal.xy * 0.5 + 0.5, A = coarse_normal.z
uniform sampler2D ptt_coupling_tex : filter_nearest, repeat_disable;
uniform float radiance_scale = 2.0;
uniform bool ptt_gi_ready = false;

const float INV_PI = 0.31830988618;

void fragment() {
	vec3 out_radiance = vec3(0.0);
	if (ptt_gi_ready) {
		vec4 albedo_px = texture(ptt_albedo_tex, UV);
		float land_mask = albedo_px.a;
		if (land_mask > 0.001) {
			vec4 coupling_px = texture(ptt_coupling_tex, UV);
			vec3 N = vec3(
				coupling_px.g * 2.0 - 1.0,
				coupling_px.b * 2.0 - 1.0,
				coupling_px.a
			);
			float n_len = length(N);
			N = (n_len > 1e-4) ? (N / n_len) : vec3(0.0, 0.0, 1.0);

			float lat_signed = clamp(UV.y, 0.0, 1.0) * 2.0 - 1.0;
			EarthDaylight ed = eval_earth_daylight(UV, lat_signed, day_night_enabled);
			float ndl = max(dot(N, ed.sun_dir), 0.0);

			vec3 albedo_lin = sky_srgb_to_linear(albedo_px.rgb);
			vec3 sun_lin = sky_srgb_to_linear(ed.sun_col);
			vec3 direct_radiance = albedo_lin * sun_lin * (ed.local_day * ndl * land_mask * INV_PI);
			float inv_scale = 1.0 / max(radiance_scale, 0.0001);
			out_radiance = clamp(direct_radiance * inv_scale, vec3(0.0), vec3(1.0));
		}
	}
	COLOR = vec4(out_radiance, 1.0);
}
