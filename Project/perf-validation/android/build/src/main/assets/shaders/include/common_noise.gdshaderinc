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
// v10.noise-pack: `noise_tex` is RGBA8. R stores raw value noise; G/B/A store
// pre-integrated 2/3/4-octave fBM, so fbm() is globally one texture fetch.
// ─────────────────────────────────────────────────────────────────────────────

// hash21 仅 voronoi_cell 还在用（Worley 暂不烘）；value_noise / fbm 已经走 noise_tex 路径。
float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

// ─── derive_independent_noise4 ─────────────────────────────────────────
// 用同一颗种子 seed 派生 4 个相互独立、谱平坦的随机数。
//
// 用途：治理"pixel_noise 多分量被复用为独立 RV"的陷阱——v10.noise-pack 中
// pixel_noise 的 .r/.g/.b/.a 是同坐标 fbm-2/3/4-octave 预积分，频谱和相位
// 高度相关，把它们当作 4 个互不相关的随机数会让 paper grain / equator band /
// dissolve overlay 等多个调制项以"同一节奏"抖动，视觉上出现"块感"。
//
// 实现：4 颗不同的 hash 起点，分别 fract(sin(dot(...))) 派生；纯 ALU，无纹理
// 采样开销（约 4 次 sin + 4 次 dot ≈ 8 ALU），比再做一次 fbm 便宜得多。
//
// 返回：vec4，每个分量 ∈ [0,1)，互相独立。
//        约定语义（caller 自决）：.r=phase/jitter, .g=amp/grain,
//        .b=eq_band, .a=eq_mix / dissolve
vec4 derive_independent_noise4(vec2 seed) {
	// 4 个互质的常向量，避免分量共线
	const vec2 K0 = vec2(127.1, 311.7);
	const vec2 K1 = vec2(269.5,  183.3);
	const vec2 K2 = vec2(419.2,  371.9);
	const vec2 K3 = vec2(113.5,  271.9);
	const float S0 = 43758.5453;
	const float S1 = 14738.2913;
	const float S2 = 22571.4297;
	const float S3 = 30671.0931;
	float r = fract(sin(dot(seed, K0)) * S0);
	float g = fract(sin(dot(seed + vec2(1.7, 9.2), K1)) * S1);
	float b = fract(sin(dot(seed + vec2(7.1, 3.4), K2)) * S2);
	float a = fract(sin(dot(seed + vec2(4.3, 6.8), K3)) * S3);
	return vec4(r, g, b, a);
}

// v10.noise-pack：noise_tex 由 CPU 预烘为 RGBA：
//   R = raw tileable value noise（兼容 value_noise）
//   G = 2-octave fBM 预积分
//   B = 3-octave fBM 预积分
//   A = 4-octave fBM 预积分
// 因此绝大多数 fbm(p, N) 从 N 次纹理采样降为 1 次纹理采样。
float value_noise(vec2 p) {
	return texture(noise_tex, p / NOISE_TEX_SCALE).r;
}

float fbm(vec2 p, int octaves) {
	vec4 n = texture(noise_tex, p / NOISE_TEX_SCALE);
	if (octaves <= 1) return n.r * 0.5;
	// 热重载/旧存档兜底：若当前 world 还持有旧 R8 noise_tex，G/B 为 0 或 A 为 1。
	// 此时临时退回旧多采样路径；下一次 bake_world 会生成 RGBA 噪声包并自动走快路径。
	bool packed_valid = (n.g + n.b > 0.0001) && (n.a < 0.98);
	if (packed_valid) {
		if (octaves == 2) return n.g;
		if (octaves == 3) return n.b;
		return n.a;
	}
	float sum = n.r * 0.5;
	float amp = 0.24;
	float freq = 2.03;
	for (int i = 1; i < 6; i++) {
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
