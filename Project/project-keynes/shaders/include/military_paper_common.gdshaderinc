// military_paper_common.gdshaderinc
// Shared paper / pencil primitives for the military map-layer shaders
// (occupation hatch, area dash, front ribbon, battle ring, convoy).
//
// Consumers must declare these uniforms BEFORE including this file (they are
// part of every military layer's public surface):
//   uniform float wrap_period_x   // 0 = flat map, >0 = cylindrical east-west wrap
//   uniform float wall_seconds    // visual clock driving the slow paper breathing
//
// Everything here is allocation-free GLSL with no texture samplers, so a layer
// that only needs paper noise costs nothing extra.

float pk_hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float pk_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(pk_hash21(i), pk_hash21(i + vec2(1.0, 0.0)), u.x),
		mix(pk_hash21(i + vec2(0.0, 1.0)), pk_hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// 三倍频 FBM。高频倍频按屏幕足迹（lod）淡出，缩小时收敛到噪声均值，
// 不会退化成沙砾噪点（与 vision-fog-and-borders.md 的 LOD 约束同一条）。
float pk_fbm(vec2 p, float lod) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	float freq = 1.0;
	for (int i = 0; i < 3; i++) {
		float fade = clamp(1.0 - (freq * lod - 0.5) * 0.9, 0.0, 1.0);
		sum += pk_value_noise(p * freq) * amp * fade;
		norm += amp * fade;
		amp *= 0.5;
		freq *= 2.0;
	}
	return norm > 0.0001 ? sum / norm : 0.5;
}

// 纸面斑块：低频大斑 + 中频脏边，减去均值后可直接乘到颜色上。
float pk_paper_blotch(vec2 world, float lod) {
	return pk_fbm(world * 0.045 + vec2(13.7, 7.1), lod) - 0.5;
}

// 铅笔线：一条带手绘抖动的线，中心 1 像素宽，两侧柔化；d 为到线的距离。
float pk_pencil_line(float d, float aa, float strength) {
	float core = 1.0 - smoothstep(aa * 0.55, aa * 1.6, abs(d));
	return core * strength;
}

// 纸边撕裂：0..1，1 表示仍在纸上，边缘宽度 ~0.02 世界单位。
float pk_torn_edge(float d, float aa, float depth) {
	return 1.0 - smoothstep(-aa, aa, d - depth);
}
