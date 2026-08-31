shader_type canvas_item;
render_mode unshaded;

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform float compound_visual_scale = 0.144;

varying flat float v_cell;
varying flat float v_archetype;

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

void vertex() {
	float style = floor(INSTANCE_CUSTOM.r * 65.0 + 0.5);
	v_archetype = mod(style, 6.0);
	v_cell = INSTANCE_CUSTOM.b;
	VERTEX *= vec2(1.16, 0.82) * compound_visual_scale;
}

void fragment() {
	vec2 cell_uv = lut_uv(v_cell);
	vec4 knowledge = texture(enum_lut, cell_uv);
	if (knowledge.a < 0.04) discard;
	vec4 dyn = texture(dyn_lut, cell_uv);
	vec4 weather = texture(weather_lut, cell_uv);
	vec3 soil = vec3(0.34, 0.29, 0.23);
	if (v_archetype < 0.5) soil = vec3(0.40, 0.35, 0.23);
	else if (v_archetype < 1.5) soil = vec3(0.29, 0.27, 0.25);
	else if (v_archetype < 3.5) soil = vec3(0.32, 0.32, 0.31);
	else if (v_archetype < 4.5) soil = vec3(0.39, 0.39, 0.35);
	else soil = vec3(0.38, 0.33, 0.27);
	bool live = knowledge.a > 0.88;
	float wet = live ? dyn.g * weather.g : 0.0;
	float snow = live ? dyn.b : 0.0;
	soil *= 1.0 - wet * 0.20;
	soil = mix(soil, vec3(0.80, 0.84, 0.86), snow * 0.58);
	if (!live) {
		float gray = dot(soil, vec3(0.299, 0.587, 0.114));
		soil = mix(vec3(gray), soil, 0.30) * 0.72;
	}
	vec2 edge_d = min(UV, vec2(1.0) - UV);
	float edge = smoothstep(0.0, 0.12, min(edge_d.x, edge_d.y));
	COLOR = vec4(soil, edge * 0.46 * smoothstep(0.54, 0.76, camera_zoom));
}
