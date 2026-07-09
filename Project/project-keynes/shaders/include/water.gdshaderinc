// water.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────────
// Water surface helpers extracted from world_map.gdshader (2026-05-08 refactor).
// Contents:
//   - Gerstner-Lite wave constants
//   - water_surface_height        : height field for differential normals
//   - sample_water_normal         : central-diff normal from height field + smooth strength envelope
//   - water_domain_warp           : ShaderToy 3tyBRh-style coord warp
//   - water_shade_lines           : legacy sin-band stripes (kept for API compat)
//   - water_calm_brightness       : low-contrast fbm brightness noise (±8%)
//   - water_calm_tint             : low-contrast fbm cold/warm tint (±3%)
//   - water_biome_weights         : 3×3 neighborhood soft weights for biome blend
//
// Dependencies (caller-side MUST declare BEFORE #include):
//   - sampler2D map_index_atlas       (for water_biome_weights biome id lookup)
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
const float WATER_WAVE_FREQ_A = 0.118;
const float WATER_WAVE_FREQ_B = 0.202;
const float WATER_WAVE_FREQ_C = 0.336;
const float WATER_WAVE_AMP_A  = 0.052;
const float WATER_WAVE_AMP_B  = 0.024;
const float WATER_WAVE_AMP_C  = 0.010;
const float WATER_WAVE_SPEED_A = 0.18;
const float WATER_WAVE_SPEED_B = 0.27;
const float WATER_WAVE_SPEED_C = 0.39;
const float WATER_WRAP_TAU = 6.2831853;

float water_wrap_lon_angle(vec2 wp) {
	if (wrap_period_x <= 0.0001) {
		return 0.0;
	}
	float wx = wrap_world_x(wp.x);
	return fract((wx - wrap_origin_x) / wrap_period_x) * WATER_WRAP_TAU;
}

vec2 water_cyl_noise_p(vec2 wp, float freq, vec2 ofs) {
	if (wrap_period_x <= 0.0001) {
		return wp * freq + ofs;
	}
	float theta = water_wrap_lon_angle(wp);
	float radius = max(abs(freq) * wrap_period_x / WATER_WRAP_TAU, 1e-4);
	return vec2(cos(theta) * radius, sin(theta) * radius + wp.y * freq) + ofs;
}

float water_fbm_cyl(vec2 wp, float freq, vec2 ofs, int octaves) {
	return fbm(water_cyl_noise_p(wp, freq, ofs), octaves);
}

float water_value_noise_cyl(vec2 wp, float freq, vec2 ofs) {
	return value_noise(water_cyl_noise_p(wp, freq, ofs));
}

float water_periodic_wave_phase(vec2 wp, vec2 dir, float k) {
	if (wrap_period_x <= 0.0001) {
		return dot(wp, dir) * k;
	}
	float theta = water_wrap_lon_angle(wp);
	float desired_cycles = dir.x * k * wrap_period_x / WATER_WRAP_TAU;
	float cycles = floor(abs(desired_cycles) + 0.5);
	float phase_x = (cycles > 0.0) ? sign(desired_cycles) * cycles * theta : 0.0;
	return phase_x + dir.y * wp.y * k;
}

// quality=0：只叠 1 个主方向（低端机）；quality>=1：叠 3 个方向。
// amp_scale/freq_scale：caller 按水体类型传入（需求 1.5/1.6）。
// [水面去条纹 2026-06-25] 三组固定方向正弦相干叠加会在整片洋面形成规则平行"条纹"，
// 在低粗糙度高光下尤其刺眼。主频控制在中尺度涌浪；quality>=1 叠中低频碎波，
// 避免回到短促梳齿，同时保留可读的波浪细节。
float water_surface_height(vec2 wp, float t, float amp_scale, float freq_scale, int quality) {
	vec2 dA = normalize(WATER_WAVE_DIR_A);
	float kA = WATER_WAVE_FREQ_A * freq_scale;
	float pA = water_periodic_wave_phase(wp, dA, kA) - t * WATER_WAVE_SPEED_A;
	float h = sin(pA) * WATER_WAVE_AMP_A;
	if (quality >= 1) {
#if !defined(PK_MOBILE_ANY)
		vec2 dB = normalize(WATER_WAVE_DIR_B);
		vec2 dC = normalize(WATER_WAVE_DIR_C);
		float kB = WATER_WAVE_FREQ_B * freq_scale;
		float kC = WATER_WAVE_FREQ_C * freq_scale;
		float pB = water_periodic_wave_phase(wp, dB, kB) - t * WATER_WAVE_SPEED_B;
		float pC = water_periodic_wave_phase(wp, dC, kC) - t * WATER_WAVE_SPEED_C;
		h += sin(pB) * WATER_WAVE_AMP_B + sin(pC) * WATER_WAVE_AMP_C;
		// 中低频碎波：补回波面细节，但频率仍明显低于旧版密集梳齿纹。
		float detail = water_fbm_cyl(wp, 0.060, vec2(-t * 0.055, t * 0.036), 2) - 0.5;
		h += detail * WATER_WAVE_AMP_A * 0.58;
#endif
	}
	return h * amp_scale;
}

// 低频、慢速的法线强度包络：只改斜率强弱，不改水面高度相位，用来打散整片水面一致的高光条纹。
// [wave-patchiness 2026-06-29] 这层低频 fbm 同时充当"波浪强度乘子"：复用它（不新增采样），把波浪
// 整体斜率（含细节法线，因为 detail 的 ds=normal_gain*strength 也吃这里）按空间做强弱分布，模拟
// 风浪带——有的海域浪大、有的平。强弱对比由 water_wave_patch_strength 控制（0=均匀，原 0.72~1.32 行为）。
float water_normal_strength_envelope(vec2 wp, float t, int quality) {
	if (quality <= 0) {
		return 1.0;
	}
	// [wave-patchiness tilling] 浪带频率乘 water_wave_patch_scale：大→浪带碎，小→浪带宽。
	float pscl = water_wave_patch_scale;
	float slow = water_fbm_cyl(wp, 0.0055 * pscl, vec2(t * 0.009, -t * 0.006), 2);
	float mid = water_fbm_cyl(wp, 0.0140 * pscl, vec2(-t * 0.016, t * 0.011) + vec2(19.0, -37.0), 1);
	// 对比窗口略放宽 + 0.5 居中，让 patch 强度更线性可控。
	float env = smoothstep(0.10, 0.92, slow * 0.70 + mid * 0.30);
	// patch>1 时 lo 会插值成负数（波浪斜率反向）→ clamp 到 0 防翻转；hi 可无限放大风浪海域。
	float lo = max(mix(1.0, 0.28, water_wave_patch_strength), 0.0);  // 平静海域
	float hi = mix(1.0, 1.90, water_wave_patch_strength);            // 风浪海域
	return mix(lo, hi, env);
}

// 中心差分法线：eps 世界坐标单位下估 ∂h/∂x, ∂h/∂y，返回 z-up 归一化法线。
// 关闭（enabled=false）时返回 vec3(0,0,1)，caller 的 NdotL/NdotH/菲涅尔全部退化为"水平水面"。
vec3 sample_water_normal(vec2 wp, float t, float amp_scale, float freq_scale, int quality, bool enabled) {
	if (!enabled) {
		return vec3(0.0, 0.0, 1.0);
	}
	// [水面去条纹 2026-06-25] 先对基准坐标做一次低频域扭曲（仅算一次，不在每个差分 tap 重复，
	// 控制额外采样），让规则正弦条纹的走向随空间缓慢弯曲，不再是贯穿整屏的平行直线。
	vec2 wpw = wp;
	if (quality >= 1) {
#if !defined(PK_MOBILE_ANY)
		float wnx = water_fbm_cyl(wp, 0.0135, vec2(t * 0.034, 0.0), 1) - 0.5;
		float wny = water_fbm_cyl(wp, 0.0135, vec2(0.0, t * 0.030) + vec2(23.0, -11.0), 1) - 0.5;
		wpw = wp + vec2(wnx, wny) * 12.0;
#endif
	}
	float eps = 0.5;
	// [base-normal tilling] 宏观涌浪频率单独乘 water_base_normal_scale（细节法线那块仍用原 freq_scale，
	// 两者 tilling 互不影响）。等价于缩放 3 个主波频率。
	float base_fs = freq_scale * water_base_normal_scale;
	float hx0 = water_surface_height(wpw - vec2(eps, 0.0), t, amp_scale, base_fs, quality);
	float hx1 = water_surface_height(wpw + vec2(eps, 0.0), t, amp_scale, base_fs, quality);
	float hy0 = water_surface_height(wpw - vec2(0.0, eps), t, amp_scale, base_fs, quality);
	float hy1 = water_surface_height(wpw + vec2(0.0, eps), t, amp_scale, base_fs, quality);
	// 差分斜率：dhx = ∂h/∂x，dhy = ∂h/∂y；法线 = normalize((-dhx, -dhy, 1))
	// 中尺度波频率已回升，斜率增益略收，避免高光重新变成密集白线。
	// normal_gain = 固定增益 8.5 × 低频强度包络（含 water_wave_patch_strength 浪带调制）。
	// base 与 detail 共享这一项，所以 patch 对两者都生效；base 额外乘 water_base_normal_strength
	// 单独控制"宏观涌浪法线"强度，detail 走 water_detail_normal_strength，互不干扰。
	float normal_gain = 8.5 * water_normal_strength_envelope(wpw, t, quality);
	float dhx = (hx1 - hx0) / (2.0 * eps) * normal_gain * water_base_normal_strength;
	float dhy = (hy1 - hy0) / (2.0 * eps) * normal_gain * water_base_normal_strength;

	// [water-detail-normal] 高频细节涟漪：直接用 analytic 梯度叠到坡度上（不增加 height 差分 tap）。
	// [门控修复 2026-06-29] 原写 quality>=2，但本函数收到的 quality 参数被 caller 钳到最大 1
	//   （wave_q = ctx.quality>=1?1:0，因 water_surface_height 无 q>=2 分支），导致 quality>=2 永不成立、
	//   这块从未执行——这才是"细节法线参数调了没反应"的真因，与玩家选的画质档无关。
	//   修复：改用全局 visual_quality 判定（脱离被钳的参数），保持高画质(>=2)专属语义不变。
#if !defined(PK_MOBILE_ANY)
	if (visual_quality >= 2 && water_detail_normal_strength > 0.001) {
		vec2 e1 = vec2(0.6, -0.8);   // 已是单位向量
		vec2 e2 = vec2(-0.92, -0.39); // ≈单位向量
		// [water-detail-normal 2026-06-29] tiling 由 water_detail_normal_scale 控制（拉远时旧的
		// 0.62/0.95 频率几乎是亚像素 → 被平均掉看不见）。降频后用更大的振幅补回坡度（坡度≈k·a），
		// 让"小波纹"在顶视拉远时也是几像素级、可见，而非糊成平面。
		float k1 = 0.62 * freq_scale * water_detail_normal_scale;
		float k2 = 0.95 * freq_scale * water_detail_normal_scale;
		float a1 = 0.048 * amp_scale;
		float a2 = 0.029 * amp_scale;
		// [water-detail-normal break-tiling] 复用 ShaderToy p+=fbm(p)*warp 破 tiling 手法：
		// 对细节坐标再叠一层"中频"域扭曲（频率≈细节的 0.35 倍、位移∝细节波长 TAU/k1），
		// 让两条固定方向解析正弦不再呈规则平行条纹。warp 缓变（频率明显低于 k1），其导数远小于
		// k1，沿用"忽略 warp 导数"近似（与上面宏观 wpw 同处理），细节法线梯度仍近似成立。
		vec2 dwp = wpw;
		if (water_detail_normal_warp > 0.001) {
			float wf = k1 * 0.35;
			float jx = water_fbm_cyl(wpw, wf, vec2(t * 0.05, 0.0), 1) - 0.5;
			float jy = water_fbm_cyl(wpw, wf, vec2(0.0, t * 0.04) + vec2(53.0, -29.0), 1) - 0.5;
			float warp_amp = water_detail_normal_warp * (6.2831853 / max(k1, 1e-4));
			dwp = wpw + vec2(jx, jy) * warp_amp;
		}
		float c1 = cos(dot(dwp, e1) * k1 - t * 0.95);
		float c2 = cos(dot(dwp, e2) * k2 - t * 1.35);
		float ds = normal_gain * water_detail_normal_strength;
		dhx += (c1 * k1 * e1.x * a1 + c2 * k2 * e2.x * a2) * ds;
		dhy += (c1 * k1 * e1.y * a1 + c2 * k2 * e2.y * a2) * ds;
	}
#endif
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
	float n1 = water_fbm_cyl(wp, 0.032, vec2(t * 0.025,  t * 0.014), 2) - 0.5;
	float n2 = water_fbm_cyl(wp, 0.032, vec2(-t * 0.018, t * 0.022) + vec2(37.0, 13.0), 2) - 0.5;
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
	float p1 = sin(water_periodic_wave_phase(wp, d1, 0.38 * freq_scale) - t * 0.36);
	float b1 = smoothstep(0.70, 0.98, p1) - smoothstep(0.98, 1.00, p1) * 0.2;
	if (quality <= 0) {
		return (b1 - 0.5) * 0.6;
	}
	float p2 = sin(water_periodic_wave_phase(wp, d2, 0.62 * freq_scale) - t * 0.48);
	float b2 = smoothstep(0.74, 0.96, p2) - smoothstep(0.96, 1.00, p2) * 0.2;
	float p3 = sin(water_periodic_wave_phase(wp, d3, 0.92 * freq_scale) - t * 0.62);
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
// [water-noise-reuse 2026-06-29] DEPRECATED：调用方已改用 WaterStageCtx.macro_lf（与 base_ripple
// 共享同一层低频 fbm），本函数保留作 API 兼容/独立采样回退，正常路径不再调用。
float water_calm_brightness(vec2 wp, float t) {
	float n = water_fbm_cyl(wp, 0.006, vec2(t * 0.014, t * 0.008), 2);
	// fbm 基本落在 [0, ~0.9]，线性重新映射到 [-1, 1]
	return clamp(n * 1.9 - 0.95, -1.0, 1.0);
}

// ─── Water Calm Noise：低对比度色相扰动层 ──────────────────────────────
// 更低频（0.006）、更慢的时间推进（1/2 亮度噪声速度）、相位反向，让色相变化
// 与亮暗不同步，奉上"呼吸感"。octaves 由 quality 控制（≥ 2 提升到 3）。
// [water-noise-reuse 2026-06-29] DEPRECATED：调用方已改用 WaterStageCtx.macro_vlf（与 deep_ripple
// 共享同一层极低频 fbm），本函数保留作 API 兼容/独立采样回退，正常路径不再调用。
float water_calm_tint(vec2 wp, float t, int octaves) {
	float n = water_fbm_cyl(wp, 0.0038, vec2(-t * 0.008, t * 0.010), octaves);
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
			vec2 suv = wrap_map_uv(uv + o * step_uv);
			int b = int(texture(map_index_atlas, suv).r * 255.0 + 0.5);
			if (b == B_LAKE)    cnt_lake += sw;
			if (b == B_REEF)    cnt_reef += sw;
			if (b == B_KELP)    cnt_kelp += sw;
			if (b == B_SEA_ICE) cnt_ice  += sw;
			total_w += sw;
		}
	}
	return vec4(cnt_lake, cnt_reef, cnt_kelp, cnt_ice) / max(total_w, 0.001);
}
