shader_type canvas_item;
render_mode unshaded;

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
uniform sampler2D cell_index_high_atlas : filter_nearest, repeat_disable;
uniform sampler2D building_macro_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform vec2 atlas_pixel_size = vec2(0.0009765625);
uniform vec2 world_size = vec2(1.0);
uniform float hex_size = 22.0;
uniform float camera_zoom = 1.0;
uniform vec2 world_origin = vec2(0.0);
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
const float BUILDING_MACRO_WINDOW_NIGHT_START = 0.18;
const float BUILDING_MACRO_WINDOW_NIGHT_FULL = 0.62;
const float BUILDING_MACRO_WINDOW_LIGHT_GAIN = 1.18;
#include "res://shaders/include/earth_daylight.gdshaderinc"

vec2 lut_uv(float cell) {
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

void fragment() {
	vec4 index_sample = texture(map_index_atlas, UV);
	float cell = floor(index_sample.g * 255.0 + 0.5)
		+ 256.0 * floor(index_sample.b * 255.0 + 0.5)
		+ 65536.0 * floor(texture(cell_index_high_atlas, UV).r * 255.0 + 0.5);
	if (cell > 16777214.0) discard;
	vec2 cell_uv = lut_uv(cell);
	vec4 data = texture(building_macro_lut, cell_uv);
	if (data.a < 0.5) discard;
	// The macro LUT is populated only from known intelligence rows.  Fog is a
	// presentation mode (live vs remembered), never an occupancy gate.
	float knowledge = texture(enum_lut, cell_uv).a;
	float density = data.r;
	float archetype = floor(data.g * 255.0 + 0.5);
	float era = floor(data.b * 255.0 + 0.5);
	// The macro mark is a tiny house glyph rather than a flat occupancy blob:
	// dark foundation, warm wall band, pitched roof and a short southeast shadow.
	vec2 p = fract(UV * world_size / max(hex_size * 0.92, 1.0));
	vec2 q = p - vec2(0.5, 0.53);
	float body = (1.0 - smoothstep(0.31 + density * 0.08,
		0.34 + density * 0.08, abs(q.x)))
		* (1.0 - smoothstep(0.20 + density * 0.04,
		0.23 + density * 0.04, abs(q.y + 0.045)));
	float roof_top = -0.22 - density * 0.025;
	float roof_bottom = 0.03;
	float roof_t = clamp((q.y - roof_top) / max(roof_bottom - roof_top, 0.001), 0.0, 1.0);
	float roof_width = (0.055 + roof_t * (0.34 + density * 0.06));
	float roof = (1.0 - smoothstep(-0.025, 0.025,
		roof_width - abs(q.x)))
		* smoothstep(roof_top - 0.025, roof_top + 0.025, q.y)
		* (1.0 - smoothstep(roof_bottom - 0.025, roof_bottom + 0.025, q.y));
	float foundation = (1.0 - smoothstep(0.29, 0.32, abs(q.x)))
		* (1.0 - smoothstep(0.045, 0.065, abs(q.y - 0.19)));
	float door = (1.0 - smoothstep(0.035, 0.050, abs(q.x)))
		* (1.0 - smoothstep(0.095, 0.12, abs(q.y - 0.08)));
	float window_l = (1.0 - smoothstep(0.040, 0.060, abs(q.x + 0.13)))
		* (1.0 - smoothstep(0.045, 0.065, abs(q.y - 0.075)));
	float window_r = (1.0 - smoothstep(0.040, 0.060, abs(q.x - 0.13)))
		* (1.0 - smoothstep(0.045, 0.065, abs(q.y - 0.075)));
	float windows = max(window_l, window_r) * body;
	float shadow = (1.0 - smoothstep(0.20, 0.24, abs(q.x - 0.16)))
		* (1.0 - smoothstep(0.055, 0.075, abs(q.y - 0.24)));
	float glyph = max(max(body, roof), max(foundation, door));
	if (archetype < 1.5) glyph *= step(length(q * vec2(1.0, 1.15)), 0.46);
	if (archetype > 1.5 && archetype < 3.5) glyph *= step(abs(q.x), 0.43 + density * 0.08);
	vec3 early = vec3(0.35, 0.25, 0.17);
	vec3 late = vec3(0.25, 0.34, 0.39);
	vec3 wall_color = mix(early, late, era / 10.0);
	vec3 roof_color = mix(vec3(0.62, 0.43, 0.24), vec3(0.48, 0.60, 0.64), era / 10.0);
	vec3 color = mix(wall_color, roof_color, roof);
	color = mix(color, vec3(0.12, 0.11, 0.10), foundation * 0.72);
	color = mix(color, vec3(0.10, 0.075, 0.05), door * 0.80);
	color = mix(color, vec3(0.16, 0.19, 0.20), shadow * 0.38);
	color *= mix(0.86, 1.12, step(0.0, q.y));
	float lat_signed = clamp(UV.y, 0.0, 1.0) * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(UV, lat_signed, day_night_enabled);
	vec3 building_light = ed.amb_col
		+ ed.sun_col * ed.local_day * 0.24 * max(ed.sun_dir.z, 0.0)
		+ ed.moon_col * ed.moon_strength * 0.08;
	color *= max(building_light, vec3(0.08)) * tod_exposure;
	// The macro layer used to lose all emissive information, making most
	// settlements become black blocks as soon as this LOD took over.
	if (knowledge > 0.88) {
		float window_night = smoothstep(BUILDING_MACRO_WINDOW_NIGHT_START,
			BUILDING_MACRO_WINDOW_NIGHT_FULL, ed.pixel_night);
		color += vec3(1.0, 0.60, 0.22) * windows * window_night
			* BUILDING_MACRO_WINDOW_LIGHT_GAIN * tod_exposure;
	}
	if (knowledge < 0.88) {
		float gray = dot(color, vec3(0.299, 0.587, 0.114));
		color = mix(vec3(gray), color, 0.35) * 0.72;
	}
	float memory_alpha = mix(0.66, 1.0, step(0.04, knowledge));
	float alpha = glyph * smoothstep(0.78, 0.40, camera_zoom) * memory_alpha;
	COLOR = vec4(color, alpha * 0.94);
}
