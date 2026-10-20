shader_type canvas_item;
render_mode unshaded;

// 墨渗揭示：用 fbm 阈值把元素沿某个方向"洇"出来，前缘带一条湿边。
// 取代旧的 annual_paper_reveal —— 旧版只能横向擦除且过渡带仅 1.5%，
// 观感像被裁掉；这里前缘有噪声、有湿边颜色，像墨落在纸上。

uniform float bleed : hint_range(0.0, 1.2) = 1.0;
uniform float edge : hint_range(0.004, 0.2) = 0.045;
uniform vec2 direction = vec2(1.0, 0.15);
uniform vec4 rim_color : source_color = vec4(0.46, 0.16, 0.13, 1.0);
uniform float rim : hint_range(0.0, 0.6) = 0.18;
uniform float noise_scale = 6.0;
uniform float noise_amount : hint_range(0.0, 0.4) = 0.11;
uniform float seed = 0.0;
// 贴图（TextureRect）走 UV；自绘文字（Label 的字形四边形）UV 是图集坐标，
// 必须改用局部像素位置归一化，否则每个字各自从自己的左上角开始洇。
uniform vec2 bounds = vec2(0.0);
// 下沿化进纸里：在元素局部像素坐标里把 alpha 慢慢收掉。
// 用"化掉 alpha"而不是"盖一层纸色"——纸本身有纹理，盖上去会留一块平斑。
uniform float fade_from = 0.0;
uniform float fade_to = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(269.5, 183.3) + seed);
	p += dot(p, p + 37.71);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec4 src = texture(TEXTURE, UV) * COLOR;
	vec2 unit = (bounds.x > 0.0 && bounds.y > 0.0) ? clamp(VERTEX / bounds, vec2(0.0), vec2(1.0)) : UV;
	vec2 dir = normalize(direction + vec2(1e-5));
	// 把点积归一化到 0..1，让 bleed 的语义在任意方向上都一致。
	float span = max(1e-4, dot(vec2(1.0), abs(dir)));
	float axis = dot(unit, dir) / span;
	float grain = value_noise(unit * noise_scale) - 0.5;
	float t = axis + grain * noise_amount;
	float alpha = 1.0 - smoothstep(bleed - edge, bleed + edge, t);
	// 湿边：前缘窄带混入朱红，宽度随 edge 变化。
	float band = exp(-pow((t - bleed) / max(edge, 1e-3), 2.0)) * rim;
	vec3 rgb = mix(src.rgb, rim_color.rgb, clamp(band, 0.0, 1.0));
	// 下沿羽化：沿 x 给一点起伏，收口不会是一条水平直线。
	float dissolve = 0.0;
	if (fade_to > fade_from + 1.0) {
		float wob = (value_noise(vec2(VERTEX.x * 0.018, seed + 3.0)) - 0.5) * 26.0;
		dissolve = smoothstep(fade_from + wob, fade_to + wob, VERTEX.y);
	}
	COLOR = vec4(rgb, src.a * alpha * (1.0 - dissolve));
}
