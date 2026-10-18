shader_type canvas_item;
render_mode unshaded;

uniform float reveal : hint_range(0.0, 1.0) = 1.0;
uniform float page_height = 600.0;
uniform float page_top = 0.0;
uniform vec4 brass : source_color = vec4(0.88, 0.68, 0.34, 1.0);
varying float page_y;
varying vec4 vertex_tint;

void vertex() {
	page_y = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).y;
	vertex_tint = COLOR;
}

void fragment() {
	vec4 source = texture(TEXTURE, UV) * vertex_tint;
	float head = mix(-100.0, page_height + 100.0, reveal);
	float distance_to_head = head - (page_y - page_top);
	float exposure = smoothstep(-65.0, 25.0, distance_to_head);
	float sheen = exp(-pow(distance_to_head / 32.0, 2.0)) * sin(reveal * 3.14159265);
	source.rgb = mix(source.rgb, brass.rgb, sheen * 0.24);
	COLOR = vec4(source.rgb, source.a * exposure);
}
