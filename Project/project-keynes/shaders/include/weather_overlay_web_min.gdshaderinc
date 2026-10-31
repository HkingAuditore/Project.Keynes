// weather_overlay_web_min.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [web-weather-min] weather_overlay.gdshader 的 web / ANGLE 裁剪变体。
// 唯一外部开关：weather_overlay.gdshader 里的 `#ifdef PK_WEB_WEATHER_MIN`
// （由 weather_layer.gd::_load_overlay_shader() 在 web 上 prepend `#define`）。
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
//   1) 用「无 sin、无循环」的双 octave 值噪声替换整座 fbm 栈（wx_min_value_noise）。
//   2) 逐字照抄桌面版的 coverage → density → opacity 重映射曲线，所以
//      「云量 ↔ 视觉浓度」的响应关系不变，变的只是云形细节来源。
//   3) 噪声值域（均值/上下限）与漂移速度对齐桌面版，避免整体亮度或移动速度跳变。
// 不做什么：不声明 uniform、不做纹理采样 —— 全部沿用 weather_overlay 已有 uniform。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_WEATHER_OVERLAY_WEB_MIN_INC
#define PK_WEATHER_OVERLAY_WEB_MIN_INC

// 无 sin 的位混合 hash（Dave Hoskins hash12）。桌面 cloud_hash22 用 sin() 造 hash，
// ANGLE 后端会把每次 sin 展开成多项式近似：既贵在编译期，也贵在每像素。
float wx_min_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// 平滑值噪声（单 octave，4 次 hash，无循环、无 mat2 旋转）。
float wx_min_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = wx_min_hash(i);
	float b = wx_min_hash(i + vec2(1.0, 0.0));
	float c = wx_min_hash(i + vec2(0.0, 1.0));
	float d = wx_min_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 云形：低频团块(n0) + 绝对值折叠出的蓬松核(billow)，共两层值噪声。
// 两层漂移速度对齐桌面 cloud_fbm_evolve(..., world_time*0.16) / (..., *0.34) 的等价位移
// （fbm_evolve 内部 sh = vec2(t*0.17, -t*0.13)，乘进去正好是下面这两个量级）。
float wx_min_cloud_shape(vec2 p, float seed) {
	vec2 base_p = p * 0.0038 + vec2(seed * 0.37, seed * 0.61);
	vec2 drift_low = vec2(world_time * 0.027, -world_time * 0.021);
	vec2 drift_high = vec2(-world_time * 0.058, world_time * 0.045);
	float n0 = wx_min_value_noise(base_p + drift_low);
	float n1 = wx_min_value_noise(base_p * 2.35 + vec2(11.7, 4.2) + drift_high);
	float billow = 1.0 - abs(n1 * 2.0 - 1.0);
	return clamp(n0 * 0.68 + billow * 0.32, 0.0, 1.0);
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

// 卷云拉丝：单 octave 值噪声。桌面用 cloud_fbm(sp, 2) = 0.5·n0 + 0.25·n1，
// 值域 [0, 0.75]、均值 0.375；这里乘 0.75 把值域/均值对齐 → 下面 smoothstep
// 阈值语义不变（否则单 octave 的均值 0.5 会让卷云铺满整片天空）。
float sample_cirrus_band_min(vec2 wp, vec2 axis, float coverage) {
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float u = dot(wp, dir);
	float v = dot(wp, side);
	vec2 sp = vec2(u * 0.004 + world_time * 0.9, v * 0.012);
	float band = wx_min_value_noise(sp) * 0.75;
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	return clamp(streak * coverage, 0.0, 1.0);
}

#endif // PK_WEATHER_OVERLAY_WEB_MIN_INC
