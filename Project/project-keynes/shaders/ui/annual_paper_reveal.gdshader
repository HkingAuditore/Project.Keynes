shader_type canvas_item;
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
varying vec4 ink_modulate;
void vertex() {
	ink_modulate = COLOR;
}
void fragment() {
	vec4 paper = texture(TEXTURE, UV);
	float grain = fract(sin(dot(floor(UV * vec2(700.0, 400.0)), vec2(12.9898, 78.233))) * 43758.5453);
	float edge = UV.x + (grain - 0.5) * 0.007;
	paper.a *= 1.0 - smoothstep(reveal - 0.015, reveal + 0.015, edge);
	COLOR = paper * ink_modulate;
}
