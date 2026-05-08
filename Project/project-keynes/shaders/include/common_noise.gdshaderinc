// common_noise.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────────
// Shared procedural-noise utilities used across world_map.gdshader (and future
// minimap / river / particle shaders). Stateless, uniform-free except for a
// dependency on the caller-side declared sampler `noise_tex` and constant
// `NOISE_TEX_SCALE`. Caller MUST declare both before #including this file:
//
//   uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
//   const float NOISE_TEX_SCALE = 256.0;
//
// Why extracted: these four functions are repeatedly reused by the main shader
// (fbm alone is called 20+ times) and are prime reuse candidates for future
// 2D shaders in the project. No behavior change — pure text move.
// ─────────────────────────────────────────────────────────────────────────────

// hash21 仅 voronoi_cell 还在用（worley 暂不烘）；value_noise 已经走 noise_tex 路径。
float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

// v9.fbm-opt：用预烘的 tileable noise_tex 替换原本的 4× hash21 + smoothstep mix。
// repeat_enable + filter_linear 让多 octave fbm 仍然连续，肉眼与原 value_noise 几乎无差。
float value_noise(vec2 p) {
	return texture(noise_tex, p / NOISE_TEX_SCALE).r;
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += value_noise(p * freq) * amp;
		freq *= 2.03;
		amp *= 0.48;
	}
	return sum;
}

float voronoi_cell(vec2 p) {
	vec2 ip = floor(p);
	vec2 fp = fract(p);
	float min_d = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 ofs = vec2(
				hash21(ip + g + vec2(1.7, 9.2)),
				hash21(ip + g + vec2(7.1, 3.4))
			);
			vec2 r = g + ofs - fp;
			float d = dot(r, r);
			min_d = min(min_d, d);
		}
	}
	return sqrt(min_d);
}
