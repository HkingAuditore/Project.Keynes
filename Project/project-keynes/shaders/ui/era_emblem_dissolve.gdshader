shader_type canvas_item;

// 时代徽记：碎裂燃尽（dissolve 0→1）与从光中凝形（dissolve 1→0）共用一套。
// 噪声全部在着色器内计算，不依赖外部贴图。
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform float edge_width = 0.09;
uniform vec4 edge_color : source_color = vec4(1.0, 0.55, 0.14, 1.0);
uniform vec4 edge_hot : source_color = vec4(1.0, 0.95, 0.74, 1.0);
uniform float crack = 0.0;
uniform float glow = 0.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.79, 0.30, 1.0);
uniform float flash = 0.0;
uniform float seed = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
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

float fbm(vec2 p) {
	float total = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		total += value_noise(p) * amp;
		p = p * 2.03 + vec2(1.7, 9.2);
		amp *= 0.5;
	}
	return total;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float n = fbm(UV * 5.0 + vec2(seed, seed * 1.37));
	// fbm 实际只落在 ~0.25..0.75：先拉伸到 0..1，燃烧前沿才是一条细线而不是整片染色。
	n = clamp((n - 0.25) * 2.0, 0.0, 1.0);
	// 先从边缘和噪声低处烧起，中心最后消失，像纸被火舌舔尽。
	float shape = n * 0.75 + clamp(1.0 - length(UV - vec2(0.5)) * 1.6, 0.0, 1.0) * 0.25;
	float t = dissolve * (1.0 + edge_width) - edge_width;
	float alive = step(t, shape);
	float band = 1.0 - clamp((shape - t) / edge_width, 0.0, 1.0);
	band *= alive * step(0.0001, dissolve);

	// 裂纹：噪声等值线，随 crack 变亮。
	float lines = 1.0 - smoothstep(0.0, 0.022, abs(fbm(UV * 3.4 + vec2(seed * 2.1, 3.0)) - 0.5));
	lines *= base.a * crack;

	vec3 rgb = base.rgb;
	// 前沿后方先焦黑，再在最前缘烧成橙金。
	rgb = mix(rgb, rgb * 0.35, smoothstep(0.0, 0.6, band));
	rgb = mix(rgb, edge_color.rgb, smoothstep(0.55, 1.0, band));
	rgb += edge_hot.rgb * pow(band, 4.0) * 1.2;
	rgb += edge_hot.rgb * lines * 1.1;
	rgb = mix(rgb, vec3(1.0, 0.96, 0.86), clamp(flash, 0.0, 1.0));

	// 外缘光晕（同纸徽 rim 做法）：只画在原图透明处。
	float rim = 0.0;
	for (int i = 0; i < 8; i++) {
		float ang = float(i) * 0.785398;
		vec2 offset = vec2(cos(ang), sin(ang));
		rim = max(rim, texture(TEXTURE, UV + offset * 0.018).a);
		rim = max(rim, texture(TEXTURE, UV + offset * 0.036).a * 0.6);
	}
	float body = base.a * alive;
	// 光晕只画在原图本来就透明的外缘，烧穿的内部保持镂空。
	float outside = (1.0 - base.a) * rim * glow * (1.0 - dissolve);
	float alpha = clamp(body + outside, 0.0, 1.0);
	vec3 color = (rgb * body + glow_color.rgb * outside) / max(body + outside, 0.0001);
	// 注意：fragment 里的 COLOR 已乘过贴图 alpha，这里不再乘它（否则外缘光晕会被清零），
	// 整体透明度改走 opacity。
	COLOR = vec4(color, alpha * opacity);
}
