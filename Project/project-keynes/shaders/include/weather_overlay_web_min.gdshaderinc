// weather_overlay_web_min.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [web-weather-min] weather_overlay.gdshader 的 web / ANGLE 裁剪变体。
// 由 PK_WEATHER_CHEAP_NOISE 接入：桌面低/中档及全部移动/Web 档共用。
//
// 为什么需要它（Why）：
//   桌面版云形来自共享解析 Perlin fbm 栈（cloud_noise.gdshaderinc）。cloud_density_soft
//   里同时压着 body(4 octave) + detail(3) + fine(2) + 域扭曲(2×2) 五次 cloud_fbm_evolve，
//   而 cloud_density_soft 在 fragment 里被内联了十几处：中云本体、4-tap 体积法线 ×4、
//   q1 单向光照梯度、偏移投影阴影、低雾，以及每个 sample_* 的接缝伙伴采样再 ×2。
//   每次 cloud_fbm_evolve 展开 6 轮循环、每轮 4 次 cloud_hash22、每次 hash 2 个 sin()，
//   这些循环体在 ANGLE→HLSL(FXC) 里全部要展开/优化/分配寄存器 —— 首次绘制约 45 秒。
//
// 这里做什么（What）：
//   1) 用「无 sin、无循环」的双 octave 梯度噪声替换整座 fbm 栈（wx_min_simplex_noise）。
//   2) 逐字照抄桌面版的 coverage → density → opacity 重映射曲线，所以
//      「云量 ↔ 视觉浓度」的响应关系不变，变的只是云形细节来源。
//   3) 噪声值域（均值/上下限）与漂移速度对齐桌面版，避免整体亮度或移动速度跳变。
// 不做什么：不声明 uniform、不做纹理采样 —— 全部沿用 weather_overlay 已有 uniform。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_WEATHER_OVERLAY_WEB_MIN_INC
#define PK_WEATHER_OVERLAY_WEB_MIN_INC

// 无 sin 的梯度 hash，一次得到二维方向。
vec2 wx_min_gradient(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	vec2 gradient = fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
	return gradient * inversesqrt(max(dot(gradient, gradient), 0.001));
}

// 三角格点梯度噪声：3个梯度、零循环、零纹理，避免梯度噪声的方格平台。
float wx_min_simplex_noise(vec2 p) {
	const float F2 = 0.3660254038;
	const float G2 = 0.2113248654;
	vec2 lattice = floor(p + dot(p, vec2(F2)));
	vec2 x0 = p - lattice + dot(lattice, vec2(G2));
	vec2 corner = x0.x > x0.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec2 x1 = x0 - corner + vec2(G2);
	vec2 x2 = x0 - vec2(1.0) + vec2(2.0 * G2);
	vec3 falloff = max(vec3(0.5) - vec3(dot(x0,x0), dot(x1,x1), dot(x2,x2)), vec3(0.0));
	falloff *= falloff;
	falloff *= falloff;
	vec3 gradients = vec3(dot(wx_min_gradient(lattice), x0),
		dot(wx_min_gradient(lattice + corner), x1),
		dot(wx_min_gradient(lattice + vec2(1.0)), x2));
	// 与高档 Perlin 的较窄值域接近，避免重映射后变成满白/满空的硬花纹。
	return clamp(0.5 + 14.0 * dot(falloff, gradients), 0.0, 1.0);
}

// 云形：低频团块(n0) + 旋转后的细节(n1)，低档一层、中档及以上两层。
// 两层漂移速度对齐桌面 cloud_fbm_evolve(..., world_time*0.16) / (..., *0.34) 的等价位移
// （fbm_evolve 内部 sh = vec2(t*0.17, -t*0.13)，乘进去正好是下面这两个量级）。
float wx_min_cloud_shape(vec2 p, float seed) {
	vec2 base_p = p * 0.0038 + vec2(seed * 0.37, seed * 0.61);
	vec2 drift_low = vec2(world_time * 0.027, -world_time * 0.021);
	vec2 drift_high = vec2(-world_time * 0.058, world_time * 0.045);
	float n0 = wx_min_simplex_noise(base_p + drift_low);
#ifdef PK_WEATHER_LOW
	float n1 = n0;
#else
	float n1 = wx_min_simplex_noise(mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * base_p * 2.35 + vec2(11.7, 4.2) + drift_high);
#endif
	// 不折叠梯度噪声的零线，否则三角格点会形成一圈圈叶片/星状细纹。
	return clamp(n0 * 0.75 + n1 * 0.25, 0.0, 1.0);
}

// cloud_density_soft 的 web 版本。以下 remap 与桌面版逐字一致
// （coverage_cut / density / soft_texture / cloud_core / texture_cloud / opacity 全照抄），
// 只把 shape 的来源换成 wx_min_cloud_shape。
float cloud_density_soft_min(vec2 p, float coverage, float seed) {
	float cloud_mask = smoothstep(0.025, 0.18, coverage);
	float amount = smoothstep(0.04, 0.3, coverage);
	float shape = wx_min_cloud_shape(p, seed);
	// coverage=1 时保留连续纹理；coverage 低时提高 cutoff 让云边界退缩（同桌面语义）。
	float coverage_cut = mix(0.66, 0.26, amount);
	float density = clamp((shape - coverage_cut) / max(1.0 - coverage_cut, 0.001), 0.0, 1.0);
	float soft_texture = smoothstep(0.05, 0.88, density);
	float cloud_core = smoothstep(0.66, 1.00, density);
	float texture_cloud = clamp(soft_texture * 0.82 + cloud_core * 0.08, 0.0, 1.0);
	float opacity = mix(0.38, 0.82, amount);
	return clamp(texture_cloud * cloud_mask * opacity, 0.0, 1.0);
}

// 卷云拉丝：单 octave 梯度噪声。桌面用 cloud_fbm(sp, 2) = 0.5·n0 + 0.25·n1，
// 值域 [0, 0.75]、均值 0.375；这里乘 0.75 把值域/均值对齐 → 下面 smoothstep
// 阈值语义不变（否则单 octave 的均值 0.5 会让卷云铺满整片天空）。
float sample_cirrus_band_min(vec2 wp, vec2 axis, float coverage) {
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float u = dot(wp, dir);
	float v = dot(wp, side);
	vec2 sp = vec2(u * 0.004, v * 0.012);
	float band = wx_min_simplex_noise(sp) * 0.75;
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	return clamp(streak * coverage, 0.0, 1.0);
}

#endif // PK_WEATHER_OVERLAY_WEB_MIN_INC
