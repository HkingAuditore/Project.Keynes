shader_type canvas_item;

// 书法大字的“运笔”揭示：按本地 x 坐标从左到右扫开，边缘带飞白抖动与一道金色笔锋。
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float x_min = -400.0;
uniform float x_max = 400.0;
uniform float softness = 48.0;
uniform vec4 lead_color : source_color = vec4(1.0, 0.86, 0.52, 1.0);

varying vec2 local_pos;

float hash11(float n) {
	return fract(sin(n * 78.233) * 43758.5453);
}

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float y = local_pos.y;
	float jitter = (hash11(floor(y / 3.0)) - 0.5) * softness * 0.7 + sin(y * 0.11) * softness * 0.3;
	float edge = mix(x_min - softness, x_max + softness, progress) + jitter;
	float mask = 1.0 - smoothstep(edge - softness, edge, local_pos.x);
	float lead = smoothstep(edge - softness * 1.6, edge - softness * 0.5, local_pos.x) * mask;
	vec4 c = COLOR;
	c.rgb += lead_color.rgb * lead * 0.65 * step(progress, 0.999);
	c.a *= mask;
	COLOR = c;
}
