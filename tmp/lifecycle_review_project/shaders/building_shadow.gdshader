shader_type canvas_item;
render_mode unshaded;

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform vec2 legacy_sun_dir = vec2(0.55, 0.84);
uniform float shadow_strength = 0.28;
uniform float compound_visual_scale = 0.144;
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
#include "res://shaders/include/earth_daylight.gdshaderinc"

varying flat float v_cell;
varying flat float v_local_day;

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

void vertex() {
	v_cell = INSTANCE_CUSTOM.b;
	float style = floor(INSTANCE_CUSTOM.r * 65.0 + 0.5);
	float era = floor(style / 6.0);
	float length_scale = clamp(0.75 + era * 0.035, 0.75, 1.15);
	vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	vec2 map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	float lat_signed = clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);
	v_local_day = ed.local_day;
	VERTEX *= compound_visual_scale;
	vec2 horizontal = ed.sun_dir.xy;
	vec2 shadow_dir = length(horizontal) > 0.0001
		? -normalize(horizontal)
		: normalize(legacy_sun_dir);
	float projection = clamp(length(horizontal) / max(ed.sun_dir.z, 0.20), 0.30, 2.0);
	VERTEX.x += shadow_dir.x * (-VERTEX.y) * 0.34 * length_scale * projection;
	VERTEX.y += shadow_dir.y * (-VERTEX.y) * 0.14 * length_scale * projection;
}

void fragment() {
	vec2 uv = lut_uv(v_cell);
	float fog = texture(enum_lut, uv).a;
	float snow = texture(dyn_lut, uv).b;
	float edge = smoothstep(0.0, 0.18, UV.x) * smoothstep(1.0, 0.82, UV.x)
		* smoothstep(0.0, 0.18, UV.y) * smoothstep(1.0, 0.82, UV.y);
	float live = step(0.88, fog);
	float alpha = shadow_strength * edge * mix(0.62, 1.0, live)
		* (1.0 - snow * live * 0.34) * smoothstep(0.52, 0.72, camera_zoom)
		* v_local_day;
	COLOR = vec4(0.16, 0.20, 0.24, alpha);
}
