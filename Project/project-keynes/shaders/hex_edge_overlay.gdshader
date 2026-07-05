shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// 地形交界覆盖层 shader v4.8
// 核心：低透明宽晕染 + 连续噪声溶解，弱化六边形硬分界。
// COLOR.rgb = 覆盖色，COLOR.a = 中心线透明度（两侧顶点为 0 自动渐隐）
// UV.x      = kind，0 = 陆地地形交界，1 = 海岸线 ribbon，2 = 宽海岸晕染
// UV.y      = edge seed

uniform float hex_size = 26.0;
uniform float noise_scale : hint_range(0.01, 1.0) = 0.18;
// v4.8 默认值：海岸柔和可见，陆地交界偏晕染而非描线
uniform float coast_foam_strength : hint_range(0.0, 1.0) = 0.24;
uniform float land_edge_strength : hint_range(0.0, 1.0) = 0.14;
uniform float dissolve_amount : hint_range(0.0, 1.0) = 0.16;
uniform float bleed_strength : hint_range(0.0, 1.0) = 0.24;
uniform float overall_alpha : hint_range(0.0, 1.0) = 0.50;

varying vec2 v_pos;
varying vec2 v_data;

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 5; i++) {
		if (i >= octaves) break;
		sum += value_noise(p * freq) * amp;
		freq *= 2.08;
		amp *= 0.48;
	}
	return sum;
}

void vertex() {
	v_pos = VERTEX;
	v_data = UV;
}

void fragment() {
	float kind = v_data.x;
	float seed = v_data.y;
	vec2 p = v_pos / max(hex_size, 1.0) * 26.0 + vec2(seed * 197.0, seed * -131.0);

	// 低频噪声生成柔和断续边，不再叠加强高频锯齿。
	float n1 = 0.58;
	float n2 = 0.52;
	float n3 = 0.50;
	float fine_grain = 0.5;
#ifndef PK_QUALITY_LOW
	n1 = fbm(p * noise_scale, 3);
	n2 = fbm((p + vec2(seed * 43.0, seed * -29.0)) * noise_scale * 1.35, 2);
	n3 = fbm((p * 0.7 + vec2(seed * -71.0, seed * 53.0)) * noise_scale * 1.9, 2);
	fine_grain = value_noise(p * noise_scale * 2.2 + vec2(seed * 83.0, seed * -47.0));
#endif

	float cut1 = smoothstep(0.16, 0.58, n1);
	float cut2 = smoothstep(0.14, 0.62, n2);
	float dissolve = smoothstep(0.18, 0.68, n3) * dissolve_amount;
	float broken = cut1 * mix(0.72, 1.0, cut2) * (1.0 - dissolve * 0.35);
	broken *= mix(0.92, 1.04, fine_grain);
	broken *= smoothstep(0.02, 0.24, n1 + n2 * 0.45 - 0.18);

	vec3 col = COLOR.rgb;
	float alpha = COLOR.a * broken;

	// kind=2：宽海岸晕染，保留连续性但不绕过太多透明度，避免形成粗硬外轮廓。
	if (kind > 1.5) {
		float grain = mix(0.78, 1.0, n1);
		float lace = smoothstep(0.08, 0.58, n1 + n2 * 0.35 - dissolve_amount * 0.18);
		alpha = COLOR.a * grain * mix(0.76, 1.0, lace) / max(overall_alpha, 0.001);
	}
	else if (kind > 0.5) {
		// 海岸边：泡沫 + 沙色 + 浅滩
		float foam = smoothstep(0.45, 0.78, n1) * coast_foam_strength;
		float sand = smoothstep(0.22, 0.62, n2);
		float wet = smoothstep(0.55, 0.85, n3);
		vec3 foam_col = vec3(0.78, 0.90, 0.82);
		vec3 sand_col = vec3(0.68, 0.60, 0.38);
		vec3 shoal_col = vec3(0.28, 0.58, 0.56);
		col = mix(shoal_col, sand_col, sand * 0.60);
		col = mix(col, foam_col, foam * 0.40);
		col = mix(col, shoal_col * 0.75, wet * 0.25);
		alpha *= 0.62 + foam * 0.20 + sand * 0.15;
	} else {
		// 陆地交界：柔和风化色带，不再用暗线切开两个 hex。
		float shade = smoothstep(0.08, 0.70, n1);
		float warmth = smoothstep(0.20, 0.78, n2);
		float bleed = smoothstep(0.22, 0.82, n3) * bleed_strength;
		vec3 muted = col * vec3(0.72, 0.76, 0.68);
		vec3 warm_mix = col * vec3(1.10, 1.06, 0.94);
		col = mix(muted, col, shade * 0.72 + bleed * 0.24);
		col = mix(col, warm_mix, warmth * 0.14);
		alpha *= land_edge_strength * (0.56 + bleed * 0.55);
		alpha *= smoothstep(0.12, 0.62, n1 + n2 * 0.25);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha * overall_alpha, 0.0, 1.0));
}
