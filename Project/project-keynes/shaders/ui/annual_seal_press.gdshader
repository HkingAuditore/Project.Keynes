shader_type canvas_item;
render_mode unshaded;

// 印章压印：不是"淡入一枚图"，而是"一记章压在湿纸上"。
// press 把印面密度从 0 推到 1，干墨用高频噪声做缺墨，落下瞬间有一圈扩散环，
// 高评级再叠一道斜向掠光。取代旧的 annual_stamp_glint（掠光是它唯一做的事）。

uniform float press : hint_range(0.0, 1.0) = 1.0;
uniform vec4 ink : source_color = vec4(0.46, 0.16, 0.13, 1.0);
uniform float grit : hint_range(0.0, 1.0) = 0.55;
uniform float glint = -1.0;
uniform float density : hint_range(0.2, 1.0) = 0.92;
uniform float ring : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(143.13, 271.79) + seed);
	p += dot(p, p + 61.37);
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
	vec4 src = texture(TEXTURE, UV);
	// 干墨：两层不同频率的噪声相乘，形成断续的墨粒而不是均匀斑点。
	float dry = value_noise(UV * 68.0) * 0.6 + value_noise(UV * 210.0) * 0.4;
	float coverage = mix(1.0, 0.55 + 0.85 * dry, grit);
	// 压印前缘：press 从 0 到 1 时，先从边缘往里吃墨。
	float bias = mix(0.0, 1.0, smoothstep(0.0, 0.35, press));
	float mask = smoothstep(0.26, 0.60, src.a) * coverage * press * mix(0.82, 1.0, bias);
	// The generated rosette already carries its final paper, pigment and foil
	// colours. Grit should break up the stamped edge, not recolour the sprite.
	vec3 rgb = src.rgb;
	// 斜向掠光
	float sweep = 1.0 - smoothstep(0.0, 0.13, abs(UV.x + UV.y * 0.28 - glint));
	rgb = mix(rgb, vec3(0.97, 0.84, 0.52), sweep * 0.34 * step(0.0, glint));
	// 落印冲击环：一圈很淡的墨晕向外散开
	float r = length(UV - 0.5);
	float halo = smoothstep(0.03, 0.0, abs(r - mix(0.28, 0.62, ring))) * (1.0 - ring);
	rgb = mix(rgb, ink.rgb * 1.5, halo * 0.28);
	COLOR = vec4(rgb, src.a * mask * density * COLOR.a);
}
