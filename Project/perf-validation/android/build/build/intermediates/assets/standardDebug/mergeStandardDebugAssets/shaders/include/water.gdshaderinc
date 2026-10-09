// water.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────────
// Water surface helpers extracted from world_map.gdshader (2026-05-08 refactor).
// Contents:
//   - Gerstner-Lite wave constants
//   - water_surface_height        : height field for differential normals
//   - sample_water_normal         : central-diff normal from height field
//   - water_domain_warp           : ShaderToy 3tyBRh-style coord warp
//   - water_shade_lines           : legacy sin-band stripes (kept for API compat)
//   - water_calm_brightness       : low-contrast fbm brightness noise (±8%)
//   - water_calm_tint             : low-contrast fbm cold/warm tint (±3%)
//   - water_biome_weights         : 3×3 neighborhood soft weights for biome blend
//
// Dependencies (caller-side MUST declare BEFORE #include):
//   - sampler2D enum_atlas            (for water_biome_weights biome id lookup)
//   - int       B_LAKE / B_REEF / B_KELP / B_SEA_ICE  (biome id constants)
//   - fbm / value_noise / voronoi_cell / hash21       (from common_noise.gdshaderinc)
//
// No behavior change vs. the pre-refactor inline version — pure text move.
// ─────────────────────────────────────────────────────────────────────────────

// ─── Water Visual Overhaul：统一水面波浪高度场（Gerstner-Lite） ──────────
// 3 个固定方向的正弦相位叠加，生成"视觉高度场"用于法线/光照，不做顶点位移。
// 方向、频率、振幅、相速度全部硬编码，避免每水体 uniform 多传一组；各水体在
// caller 端用一个 (amp_scale, freq_scale, current_bias_weight) 控制差异。
//
// wp：世界坐标（v_world），已包含 ocean_current_v 方向偏转后的"扭曲世界坐标"。
// t ：world_time。
//
// 返回：抽象"水面高度"（量纲是归一化 [-amp_total, +amp_total]，仅供差分求法线）。
const vec2 WATER_WAVE_DIR_A = vec2( 0.8,  0.3);
const vec2 WATER_WAVE_DIR_B = vec2(-0.4,  0.7);
const vec2 WATER_WAVE_DIR_C = vec2( 0.1, -0.9);
const float WATER_WAVE_FREQ_A = 0.42;
const float WATER_WAVE_FREQ_B = 0.78;
const float WATER_WAVE_FREQ_C = 1.18;
const float WATER_WAVE_AMP_A  = 0.028;
const float WATER_WAVE_AMP_B  = 0.016;
const float WATER_WAVE_AMP_C  = 0.009;
const float WATER_WAVE_SPEED_A = 0.26;
const float WATER_WAVE_SPEED_B = 0.38;
const float WATER_WAVE_SPEED_C = 0.52;

// quality=0：只叠 1 个主方向（低端机）；quality>=1：叠 3 个方向。
// amp_scale/freq_scale：caller 按水体类型传入（需求 1.5/1.6）。
float water_surface_height(vec2 wp, float t, float amp_scale, float freq_scale, int quality) {
	vec2 dA = normalize(WATER_WAVE_DIR_A);
	float kA = WATER_WAVE_FREQ_A * freq_scale;
	float pA = dot(wp, dA) * kA - t * WATER_WAVE_SPEED_A;
	float h = sin(pA) * WATER_WAVE_AMP_A;
	if (quality >= 1) {
		vec2 dB = normalize(WATER_WAVE_DIR_B);
		vec2 dC = normalize(WATER_WAVE_DIR_C);
		float kB = WATER_WAVE_FREQ_B * freq_scale;
		float kC = WATER_WAVE_FREQ_C * freq_scale;
		float pB = dot(wp, dB) * kB - t * WATER_WAVE_SPEED_B;
		float pC = dot(wp, dC) * kC - t * WATER_WAVE_SPEED_C;
		h += sin(pB) * WATER_WAVE_AMP_B + sin(pC) * WATER_WAVE_AMP_C;
	}
	return h * amp_scale;
}

// 中心差分法线：eps 世界坐标单位下估 ∂h/∂x, ∂h/∂y，返回 z-up 归一化法线。
// 关闭（enabled=false）时返回 vec3(0,0,1)，caller 的 NdotL/NdotH/菲涅尔全部退化为"水平水面"。
vec3 sample_water_normal(vec2 wp, float t, float amp_scale, float freq_scale, int quality, bool enabled) {
	if (!enabled) {
		return vec3(0.0, 0.0, 1.0);
	}
	float eps = 0.5;
	float hx0 = water_surface_height(wp - vec2(eps, 0.0), t, amp_scale, freq_scale, quality);
	float hx1 = water_surface_height(wp + vec2(eps, 0.0), t, amp_scale, freq_scale, quality);
	float hy0 = water_surface_height(wp - vec2(0.0, eps), t, amp_scale, freq_scale, quality);
	float hy1 = water_surface_height(wp + vec2(0.0, eps), t, amp_scale, freq_scale, quality);
	// 差分斜率：dhx = ∂h/∂x，dhy = ∂h/∂y；法线 = normalize((-dhx, -dhy, 1))
	// 乘一个 "normal_gain" 让浅水/法线更夸张（需求 1.2 决定 z 固定 1.0）
	float normal_gain = 7.0;
	float dhx = (hx1 - hx0) / (2.0 * eps) * normal_gain;
	float dhy = (hy1 - hy0) / (2.0 * eps) * normal_gain;
	return normalize(vec3(-dhx, -dhy, 1.0));
}

// ─── ShaderToy 启发：水面域扭曲 ──────────────────────────────────────
// 参考 https://www.shadertoy.com/view/3tyBRh 中的 "p += fbm(p)*warp" 手法。
// 在水色采样/条纹采样前，把 wp 沿两个 fbm 方向偏移，让同一片水体的 noise
// 纹理不再是规整 fbm 线条，也让 biome 边界（下一步 biome soft weight）
// 不再是直线的 NEAREST 网格切，而是像水流搅散。
//
// warp_strength：0 = 不扭曲；1.6（默认）≈ 半个 cell；4.0 极强。
vec2 water_domain_warp(vec2 wp, float t, float warp_strength) {
	if (warp_strength <= 0.001) {
		return wp;
	}
	// 两层速度不同的低频 fbm，方向互相正交，形成"旋转感"
	float n1 = fbm(wp * 0.032 + vec2(t * 0.025,  t * 0.014), 2) - 0.5;
	float n2 = fbm(wp * 0.032 + vec2(-t * 0.018, t * 0.022) + vec2(37.0, 13.0), 2) - 0.5;
	return wp + vec2(n1, n2) * warp_strength;
}

// ─── ShaderToy 启发：横向波痕条纹 ─────────────────────────────────────
// 参考 https://www.shadertoy.com/view/dtKcWz 的做法：在水面叠加 3 层低振幅
// 正弦条带（不同方向、不同频率、不同速度），用 smoothstep 提取"亮暗条纹"作为
// 浪痕，叠在水色上；这是 2D 风格化水的"灵魂"——不靠光照，靠线条传达动感。
//
// 返回值 ∈ [-0.5, 0.5]，caller 以 lerp 形式叠色：col *= 1.0 + lines * strength。
float water_shade_lines(vec2 wp, float t, float freq_scale, int quality) {
	vec2 d1 = vec2( 0.92,  0.38);
	vec2 d2 = vec2(-0.55,  0.83);
	vec2 d3 = vec2( 0.10, -0.99);
	// 用 smoothstep 提带宽≈0.2 的亮条：sin 大于 0.6 的顶部形成浪峰亮线
	float p1 = sin(dot(wp, d1) * 0.38 * freq_scale - t * 0.36);
	float b1 = smoothstep(0.70, 0.98, p1) - smoothstep(0.98, 1.00, p1) * 0.2;
	if (quality <= 0) {
		return (b1 - 0.5) * 0.6;
	}
	float p2 = sin(dot(wp, d2) * 0.62 * freq_scale - t * 0.48);
	float b2 = smoothstep(0.74, 0.96, p2) - smoothstep(0.96, 1.00, p2) * 0.2;
	float p3 = sin(dot(wp, d3) * 0.92 * freq_scale - t * 0.62);
	float b3 = smoothstep(0.78, 0.94, p3) - smoothstep(0.94, 1.00, p3) * 0.2;
	// 加权叠加：主条纹权重最大，细碎小条纹用于打碎规整感
	float bands = b1 * 0.55 + b2 * 0.30 + b3 * 0.15;
	// [-0.5, 0.5] 居中化
	return (bands - 0.5) * 0.55;
}

// ─── Water Calm Noise（本轮）：大尺度柔和亮度噪声 ──────────────────────
// 用低频 fbm（空间缩放 0.010，单个斑块约 30~80 hex 跨度）代替旧 3 层 sin
// 条纹；返回 [-1, 1]，caller 以 col *= 1.0 + calm * 0.08 形式叠加，即 ±8%
// 亮度扰动，从而营造"淡淡的、像云影一样缓慢起伏"的观感。
float water_calm_brightness(vec2 wp, float t) {
	float n = fbm(wp * 0.006 + vec2(t * 0.014, t * 0.008), 2);
	// fbm 基本落在 [0, ~0.9]，线性重新映射到 [-1, 1]
	return clamp(n * 1.9 - 0.95, -1.0, 1.0);
}

// ─── Water Calm Noise：低对比度色相扰动层 ──────────────────────────────
// 更低频（0.006）、更慢的时间推进（1/2 亮度噪声速度）、相位反向，让色相变化
// 与亮暗不同步，奉上"呼吸感"。octaves 由 quality 控制（≥ 2 提升到 3）。
float water_calm_tint(vec2 wp, float t, int octaves) {
	float n = fbm(wp * 0.0038 + vec2(-t * 0.008, t * 0.010), octaves);
	return clamp(n * 1.15, 0.0, 1.0);
}

// ─── biome soft weights (radius-aware 3×3 neighborhood) ───────────────────
// Returns vec4: (w_lake, w_reef, w_kelp, w_ice); ocean/coast remains implicit.
// blend_radius controls the sample footprint in atlas texels. 0 is handled by
// the caller as a hard-cut fallback; values above 1 widen the transition band.
vec4 water_biome_weights(vec2 uv, vec2 tx, float blend_radius) {
	float radius = clamp(blend_radius, 0.25, 4.0);
	vec2 step_uv = tx * radius;
	float cnt_lake = 0.0;
	float cnt_reef = 0.0;
	float cnt_kelp = 0.0;
	float cnt_ice  = 0.0;
	float total_w = 0.0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			vec2 o = vec2(float(ox), float(oy));
			// Center sample anchors the current tile; diagonals still contribute but
			// cannot fully overwrite a narrow water feature.
			float sw = 1.0 - 0.18 * clamp(length(o), 0.0, 1.41421356);
			vec2 suv = clamp(uv + o * step_uv, vec2(0.0), vec2(1.0));
			int b = int(texture(enum_atlas, suv).r * 255.0 + 0.5);
			if (b == B_LAKE)    cnt_lake += sw;
			if (b == B_REEF)    cnt_reef += sw;
			if (b == B_KELP)    cnt_kelp += sw;
			if (b == B_SEA_ICE) cnt_ice  += sw;
			total_w += sw;
		}
	}
	return vec4(cnt_lake, cnt_reef, cnt_kelp, cnt_ice) / max(total_w, 0.001);
}
