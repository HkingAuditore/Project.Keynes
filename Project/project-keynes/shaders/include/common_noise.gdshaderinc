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

// Phase B：风场驱动的 domain warp。
// 思路与 water.gdshaderinc 的 water_domain_warp 一致，但接受外部 flow 向量
// （来自 front.axis 或 wind_field），用两层错位 FBM 做坐标抖动 → 让云/雾的
// 形态边缘"破碎、卷曲"，而不是整体平移看起来很僵。
//
// 参数：
//   wp        : 世界坐标采样点（相对于 front.center 的 local 坐标更稳定）
//   flow      : 单位向量（norm 不要求严格 1，可有强度差异）
//   t         : 推进时间，沿 flow 方向滑动
//   strength  : 噪声扭曲幅度（云通常 6~12，雾减半 3~6）
//   freq      : 噪声频率（云用 ~0.024，雾稍低 ~0.018）
//
// 返回：扭曲后的采样坐标。
vec2 wind_domain_warp(vec2 wp, vec2 flow, float t, float strength, float freq) {
	// 1) 先沿 flow 方向做整体 advection（让云团真正"飘"过去）
	vec2 advected = wp - flow * t;
	// 2) 再用两层频率相同、相位错开的 FBM 组成扭曲向量
	float n1 = fbm(advected * freq + vec2( t * 0.020,  t * 0.012), 2) - 0.5;
	float n2 = fbm(advected * freq + vec2(-t * 0.014,  t * 0.018) + vec2(37.0, 13.0), 2) - 0.5;
	return advected + vec2(n1, n2) * strength;
}
