shader_type canvas_item;
uniform float sweep : hint_range(-0.5, 1.5) = -0.5;
void fragment() {
	float band = 1.0 - smoothstep(0.0, 0.10, abs(UV.x + UV.y * 0.28 - sweep));
	COLOR.rgb = mix(COLOR.rgb, vec3(0.87, 0.66, 0.31), band * 0.72);
}
