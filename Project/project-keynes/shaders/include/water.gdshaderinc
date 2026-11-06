// water.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────────
// Water surface helpers extracted from world_map.gdshader (2026-05-08 refactor).
// Contents:
//   - 旧版正弦波浪（Gerstner-Lite）：water_surface_height / sample_water_normal。
//                                   【仅陆地河流水面使用】；海洋已不走这条路径。
//   - sample_flow_water_normal    : 【海洋波浪入口】= 底层涟漪（哈希值噪声 + 两相位 flowmap）
//                                   + 顺流洋流丝 + 海况强度场。
//                                   （离散浪头笔触 2026-11-06 停用，代码以注释形式留档）
//                                   输出法线 / 波高 / 洋流丝；冰面剔除。
//   - water_shade_lines           : 湖面横向波痕（水面管线仍在用）
//   - water_biome_weights         : 3×3 邻域 biome 软权重
//   （water_domain_warp / water_calm_brightness / water_calm_tint 已确认零调用，2026-11 清理删除）
//
// Dependencies (caller-side MUST declare BEFORE #include):
//   - sampler2D map_index_atlas       (for water_biome_weights biome id lookup)
//   - int       B_LAKE / B_REEF / B_KELP / B_SEA_ICE  (biome id constants)
//   - fbm / value_noise / voronoi_cell / hash21       (from common_noise.gdshaderinc)
//
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

#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
// 解析梯度版 water_surface_height：返回 (∂h/∂x, ∂h/∂y)，替代 4 次中心差分。
// 正弦项直接求导；细节 fBM-2 用一次 textureGather 取 2×2 texel，对硬件双线性面片求导——
// 原差分步长 0.5 世界单位在噪声空间只有约 0.03 texel，读到的本来就是同一块面片的斜率。
// GLES3 没有 textureGather，Compatibility 继续走差分。
#define PK_WATER_ANALYTIC_NORMAL

vec2 water_periodic_wave_phase_grad(vec2 dir, float k) {
	if (wrap_period_x <= 0.0001) {
		return dir * k;
	}
	float desired_cycles = dir.x * k * wrap_period_x / WATER_WRAP_TAU;
	float cycles = floor(abs(desired_cycles) + 0.5);
	float gx = (cycles > 0.0) ? sign(desired_cycles) * cycles * WATER_WRAP_TAU / wrap_period_x : 0.0;
	return vec2(gx, dir.y * k);
}

// fbm(water_cyl_noise_p(wp, freq, ofs), 2) 对 wp 的梯度。
vec2 water_fbm2_cyl_grad(vec2 wp, float freq, vec2 ofs) {
	vec2 nuv = water_cyl_noise_p(wp, freq, ofs) / NOISE_TEX_SCALE;
	vec2 ts = vec2(textureSize(noise_tex, 0));
	vec2 f = fract(nuv * ts - 0.5);
	vec4 g = textureGather(noise_tex, nuv, 1);
	// gather 分量顺序：x=(i0,j1) y=(i1,j1) z=(i1,j0) w=(i0,j0)
	vec2 dfdp = vec2(mix(g.z - g.w, g.y - g.x, f.y), mix(g.x - g.w, g.y - g.z, f.x))
			* ts / NOISE_TEX_SCALE;
	if (wrap_period_x <= 0.0001) {
		return dfdp * freq;
	}
	// 圆柱映射 p = (cosθ·r, sinθ·r + y·freq)，r·dθ/dx = freq。
	float theta = water_wrap_lon_angle(wp);
	return vec2(dot(dfdp, vec2(-sin(theta), cos(theta))), dfdp.y) * freq;
}

vec2 water_surface_height_grad(vec2 wp, float t, float amp_scale, float freq_scale, int quality) {
	vec2 dA = normalize(WATER_WAVE_DIR_A);
	float kA = WATER_WAVE_FREQ_A * freq_scale;
	float pA = water_periodic_wave_phase(wp, dA, kA) - t * WATER_WAVE_SPEED_A;
	vec2 grad = cos(pA) * WATER_WAVE_AMP_A * water_periodic_wave_phase_grad(dA, kA);
	if (quality >= 1) {
#if !defined(PK_MOBILE_ANY)
		vec2 dB = normalize(WATER_WAVE_DIR_B);
		vec2 dC = normalize(WATER_WAVE_DIR_C);
		float kB = WATER_WAVE_FREQ_B * freq_scale;
		float kC = WATER_WAVE_FREQ_C * freq_scale;
		float pB = water_periodic_wave_phase(wp, dB, kB) - t * WATER_WAVE_SPEED_B;
		float pC = water_periodic_wave_phase(wp, dC, kC) - t * WATER_WAVE_SPEED_C;
		grad += cos(pB) * WATER_WAVE_AMP_B * water_periodic_wave_phase_grad(dB, kB);
		grad += cos(pC) * WATER_WAVE_AMP_C * water_periodic_wave_phase_grad(dC, kC);
		grad += water_fbm2_cyl_grad(wp, 0.060, vec2(-t * 0.055, t * 0.036))
				* (WATER_WAVE_AMP_A * 0.58);
#endif
	}
	return grad * amp_scale;
}
#endif

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
#ifdef PK_WATER_ANALYTIC_NORMAL
	vec2 h_grad = water_surface_height_grad(wpw, t, amp_scale, base_fs, quality);
#else
	float hx0 = water_surface_height(wpw - vec2(eps, 0.0), t, amp_scale, base_fs, quality);
	float hx1 = water_surface_height(wpw + vec2(eps, 0.0), t, amp_scale, base_fs, quality);
	float hy0 = water_surface_height(wpw - vec2(0.0, eps), t, amp_scale, base_fs, quality);
	float hy1 = water_surface_height(wpw + vec2(0.0, eps), t, amp_scale, base_fs, quality);
	vec2 h_grad = vec2(hx1 - hx0, hy1 - hy0) / (2.0 * eps);
#endif
	// 差分斜率：dhx = ∂h/∂x，dhy = ∂h/∂y；法线 = normalize((-dhx, -dhy, 1))
	// 中尺度波频率已回升，斜率增益略收，避免高光重新变成密集白线。
	// normal_gain = 固定增益 8.5 × 低频强度包络（含 water_wave_patch_strength 浪带调制）。
	// base 与 detail 共享这一项，所以 patch 对两者都生效；base 额外乘 water_base_normal_strength
	// 单独控制"宏观涌浪法线"强度，detail 走 water_detail_normal_strength，互不干扰。
	float normal_gain = 8.5 * water_normal_strength_envelope(wpw, t, quality);
	float dhx = h_grad.x * normal_gain * water_base_normal_strength;
	float dhy = h_grad.y * normal_gain * water_base_normal_strength;

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

// ═══════════════════════════════════════════════════════════════════════════
// [water-wave-marks 2026-11-06] 第五版：离散「浪头笔触」，取代正弦平面波叠加。
//
// 前四版的共同问题：任何「正弦叠加」都是处处连续、周期规整的纹理（用户评价：太规律、
// 太连续、丑），而且每像素要几十次 sin/cos + atan + 多次噪声采样（太贵）。
//
// 这一版换成剪纸 / 版画式的离散笔触：
//   · 空间切成斜切格（x 方向按周期取整 ⇒ 环绕缝连续），每格用哈希决定「有没有浪头」
//     「出生相位」「位置」「朝向抖动」「长度」「弯曲方向」；约 15%~60% 的格子有笔触，
//     其余是平静海面 ⇒ 稀疏、不均、不连续；
//   · 每个笔触是一小段弧形浪脊（前亮后暗），沿浪向漂移，生命周期 sin² 式淡入淡出；
//   · 浪向 = 背景浪向（单倍频低频噪声）向洋流方向靠拢；每格再随机偏转 ±0.55 rad，
//     所以同一片海里笔触朝向不一，但整体顺流；
//   · 洋流丝：同一函数的「顺流拉长」变体，快速顺流漂移，静帧也能读出流向；
//   · 成本：每层 2 次 ALU 哈希 + 少量乘加，无 sin/cos / atan / 额外纹理采样；
//     整个函数只剩 2 次 noise_tex 采样（背景浪向 + 海况分区）。
// ═══════════════════════════════════════════════════════════════════════════
const float WATER_FLOW_PRESENCE_LO = 0.015;
const float WATER_FLOW_PRESENCE_HI = 0.16;

vec3 water_hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// 圆柱噪声坐标：与 water_cyl_noise_p 数值一致，但 cos/sin 由调用方算一次后传入。
vec2 water_cyl_p_cs(vec2 cs, vec2 wp, float freq, vec2 ofs) {
	if (wrap_period_x <= 0.0001) {
		return wp * freq + ofs;
	}
	float radius = max(abs(freq) * wrap_period_x / WATER_WRAP_TAU, 1e-4);
	return vec2(cs.x * radius, cs.y * radius + wp.y * freq) + ofs;
}

// 一层笔触。返回 xy = 高度场对世界坐标的梯度，z = 高度（浪脊为正、后方浪谷为负），w = 笔触强度 [0,1]。
//   cell / shear：格尺寸（世界单位）与斜切系数（打破格线）；dirv：浪向（单位向量）；
//   streak：true 时笔触沿 dirv 拉长（洋流丝），false 时垂直 dirv 拉长（浪脊）；
//   cover：有笔触的格子比例；rate / travel：生命周期频率与生命内的漂移距离（格宽倍数）；
//   width_frac / len_frac：笔触厚度 / 半长（格宽倍数，逐格再抽一次倍率）；fp：屏幕像素对应的
//   世界长度（调用方在分支外求值）：笔触比 1 像素细时整体淡出，避免远景闪烁；
//   jit：0..1 的低频抖动（复用入口静态噪声，零采样）：逐笔轻重不同，轮廓不再是同一条解析曲线。
vec4 water_mark_layer(vec2 wp, float cell, float shear, vec2 dirv, bool streak,
		float cover, float t, float rate, float travel,
		float width_frac, float len_frac, float fp, float seed, float jit) {
	bool wrapped = wrap_period_x > 0.0001;
	float n_cells = wrapped ? max(floor(wrap_period_x / cell + 0.5), 1.0) : 1.0;
	float cw = wrapped ? wrap_period_x / n_cells : cell;
	vec2 q = vec2((wp.x + shear * wp.y) / cw, wp.y / cell);
	vec2 ci = floor(q);
	vec2 f = q - ci;
	vec2 id = vec2(wrapped ? mod(ci.x, n_cells) : ci.x, ci.y) + vec2(seed, seed * 1.37);
	// 生命周期序号参与哈希：同一格每个周期长出**不同**的笔触（有无 / 位置 / 长度 / 弯曲都重抽）。
	// 相位偏移 h0.x 只由格子决定（否则周期边界会错位）；周期边界处 env=0，重抽不可见。
	float ph = t * rate + water_hash32(id * 0.731 + 5.3).x;
	float life = fract(ph);
	vec2 cyc = vec2(mod(floor(ph), 997.0));
	vec3 ha = water_hash32(id + cyc * vec2(7.13, 3.77));
	float present = smoothstep(cover, cover - 0.10, ha.z);
	if (present <= 0.0) {
		return vec4(0.0);
	}
	vec3 hb = water_hash32((id + cyc * vec2(7.13, 3.77)) * 1.713 + 31.7);
	// 平台式包络：生命中段近满强度，前后各 22% 淡入淡出（旧的 (4x(1-x))² 大部分时间很暗）。
	float env = clamp(min(life, 1.0 - life) * 4.5, 0.0, 1.0);
	env = env * env * (3.0 - 2.0 * env);
	// 长度用 hb.z、粗细用 hb.x、弯曲用二者混合：旧版"越长弯得越厉害"的耦合被解开，
	// 形状不再是一族缩放后的同一条曲线。
	float L = len_frac * cell * (0.55 + 0.90 * hb.z);
	// 格内位置：长笔触必须靠中间站（否则两头被格线切掉），短笔触可以到处跑。
	// 于是小碎浪散得开、大浪脊铺得稳，行与行之间不再对齐。
	float inset = clamp(L / max(cell, 1e-4) * 0.5 + 0.06, 0.06, 0.40);
	vec2 dq = f - vec2(mix(inset, 1.0 - inset, ha.x), mix(inset, 1.0 - inset, ha.y));
	vec2 d = vec2(dq.x * cw - shear * dq.y * cell, dq.y * cell);
	float e = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	// 每格浪向抖动（小角度近似，不用 sin/cos）。±0.55 rad：同片海里朝向不再像排线。
	float a = (hb.y - 0.5) * (streak ? 0.30 : 1.10);
	float ca = 1.0 - 0.5 * a * a;
	float sa = a - a * a * a * 0.1666667;
	vec2 dd = vec2(dirv.x * ca - dirv.y * sa, dirv.x * sa + dirv.y * ca);
	d -= dd * ((life - 0.5) * travel * cell);
	float uu = dot(d, dd);
	float ss = dot(d, vec2(-dd.y, dd.x));
	if (streak) {
		float tmp = uu;
		uu = ss;
		ss = tmp;
	}
	// 粗细倍率：逐格 0.62~1.38，同一层不再所有笔触一样粗。
	float wr = 0.62 + 0.76 * hb.x;
	float w_nom = width_frac * cell * wr;
	float w = max(w_nom, fp * 1.1);
	float aa = smoothstep(0.30, 1.10, w_nom / max(fp, 1e-4));
	float cr = fract(hb.x * 3.71 + hb.z * 1.93);
	float curve = (cr - 0.5) * 2.0 * ss * ss / (L * 2.4);
	float xu = (uu - curve) / w;
	float b = max(1.0 - xu * xu, 0.0);
	float b2 = b * b;
	float lm = clamp(1.0 - abs(ss) / L, 0.0, 1.0);
	lm = lm * lm * (3.0 - 2.0 * lm);
	// 逐笔轻重：低频噪声调制强度（0.70~1.30），相邻笔触浓淡不同。
	float k = present * env * smoothstep(0.0, 0.14, e) * aa * lm * (0.70 + 0.60 * jit);
	if (streak) {
		return vec4(0.0, 0.0, b2 * k, b2 * k);
	}
	// 前亮后暗：浪脊 + 后方 1.7w 处的浅谷。
	float xt = (uu - curve + 1.7 * w) / (1.4 * w);
	float c = max(1.0 - xt * xt, 0.0);
	float c2 = c * c;
	// [water-mark-shape] 截面指数逐格微调：b²（圆肩）↔ b³（更软的肩）之间插值。
	// 旧版整层共用一条抛物线，所以每条笔触的坡肩一模一样 —— 这是"形状太规律"的一半。
	// 用 hb.x 的再次打散（而不是 hb.y）——hb.y 已经决定朝向，复用会让"朝某个方向的笔触总是更软"，
	// 那又是一种能被眼睛读出来的规律。
	float prof = 0.6 * fract(hb.x * 7.31);
	float hs = mix(b2, b2 * b, prof);
	float dhs = mix(-4.0 * xu * b, -6.0 * xu * b2, prof) * (b > 0.0 ? 1.0 : 0.0);
	float h = (hs - 0.40 * c2) * k;
	float dh = (dhs / w
			+ 0.40 * 4.0 * xt * c / (1.4 * w) * (c > 0.0 ? 1.0 : 0.0)) * k;
	// [water-mark-shape 2026-11-06] 补上 ss 方向梯度：h 沿 ss 的依赖主要来自弯曲项 curve，
	// ∂h/∂ss ≈ -dh·∂curve/∂ss（长度收口 lm 的导数仍忽略）。旧版只取 ∂h/∂uu，
	// 所以弯曲的两侧完全不受光，弯笔触看起来像一条被压平的纸片。
	float dcurve = (cr - 0.5) * 4.0 * ss / (L * 2.4);
	vec2 perp = vec2(-dd.y, dd.x);
	return vec4(dh * (dd - perp * dcurve), h, b2 * k);
}

// ─── 底层细节海面 v2：哈希值噪声 + 解析梯度（零纹理采样）──────────────────────
// 实机定位（固定种子 A/B 逐层关闭）：旧的「noise_tex 差分涟漪」单独就会在太阳高光区产生
// 大片同向的斜向长亮条——预烘噪声贴图的梯度不是各向同性的。改用逐格哈希 + quintic 插值的
// 值噪声，梯度解析求出，天然各向同性、梯度连续（无菱形小面）；x 向格数取整 ⇒ 环绕缝连续。
// 返回 xy = 对世界坐标的梯度，z = 起伏（零均值）。drift 以「格」为单位。
vec3 water_hash_ripple(vec2 wp, float cell, vec2 drift, float seed, float shear) {
	bool wrapped = wrap_period_x > 0.0001;
	float n_cells = wrapped ? max(floor(wrap_period_x / cell + 0.5), 1.0) : 1.0;
	float cw = wrapped ? wrap_period_x / n_cells : cell;
	// 斜切：q.x 加 y 的线性项，格线不再轴对齐（x 向仍严格周期）。
	vec2 q = vec2(wp.x / cw + shear * wp.y / cell, wp.y / cell) + drift;
	vec2 ci = floor(q);
	vec2 f = q - ci;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f - 1.0) * (f - 1.0);
	float x0 = wrapped ? mod(ci.x, n_cells) : ci.x;
	float x1 = wrapped ? mod(ci.x + 1.0, n_cells) : ci.x + 1.0;
	float a = water_hash32(vec2(x0, ci.y) + seed).x;
	float b = water_hash32(vec2(x1, ci.y) + seed).x;
	float c = water_hash32(vec2(x0, ci.y + 1.0) + seed).x;
	float d = water_hash32(vec2(x1, ci.y + 1.0) + seed).x;
	float h = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
	vec2 dq = vec2((b - a + (a - b - c + d) * u.y) * du.x,
			(c - a + (a - b - c + d) * u.x) * du.y);
	return vec3(dq.x / cw, (dq.y + shear * dq.x) / cell, h - 0.5);
}

// 两相位 flowmap：每个相位内位移有界；周期序号换哈希种子 ⇒ 不循环；保方差混合。
vec3 water_hash_ripple_flow(vec2 wp, float cell, vec2 adv_world, float t, float rate, float seed, float shear) {
	float ph0 = fract(t * rate);
	float ph1 = fract(ph0 + 0.5);
	float w0 = 1.0 - abs(1.0 - 2.0 * ph0);
	float w1 = 1.0 - w0;
	float s0 = seed + mod(floor(t * rate), 997.0) * 13.7;
	float s1 = seed + 5.0 + mod(floor(t * rate + 0.5), 997.0) * 13.7;
	vec3 a = water_hash_ripple(wp, cell, -adv_world * (ph0 / cell), s0, shear);
	vec3 b = water_hash_ripple(wp, cell, -adv_world * (ph1 / cell) + vec2(0.37, 0.11), s1, shear);
	return (a * w0 + b * w1) * inversesqrt(w0 * w0 + w1 * w1);
}

// ─── 洋流驱动的波浪法线 + 波高 + 洋流丝 ─────────────────────────────────
// 返回：z-up 法线；wave_height：波高（浪脊为正、后方为负，供明暗与浪尖）；
//       flow_streak：已乘 cur 与强度的洋流丝 [0,1]。wave_mask = 冰面剔除权重。
vec3 water_flow_surface(vec2 wp, float t, vec2 flow, float amp_scale,
		float freq_scale, float noise_lf, float wave_mask,
		inout float wave_height, inout float flow_streak) {
	wave_height = 0.0;
	flow_streak = 0.0;
	if (wave_mask <= 0.001) {
		return vec3(0.0, 0.0, 1.0);
	}
	// 屏幕像素的世界尺寸：必须在任何分支之外求导数。
	float fp = max(length(dFdx(wp)), length(dFdy(wp)));
	float flow_mag = length(flow);
	// sqrt：弱流（0.03~0.08，占海面大头）也要有可见的方向偏置，停滞点仍平滑归零。
	float cur = sqrt(smoothstep(WATER_FLOW_PRESENCE_LO, WATER_FLOW_PRESENCE_HI, flow_mag))
			* clamp(ocean_current_strength * 1.15, 0.0, 1.0);
	vec2 flow_dir = flow / max(flow_mag, 1e-3);

	bool wrapped = wrap_period_x > 0.0001;
	float theta = wrapped ? water_wrap_lon_angle(wp) : 0.0;
	vec2 cs = vec2(cos(theta), sin(theta));

	// 背景浪向：单倍频 value noise（频率 0.003 ⇒ 成片同向，片间换向）；总跨度 < π。
	float bg_r = value_noise(water_cyl_p_cs(cs, wp, 0.0030, vec2(t * 0.0030, t * 0.0021)));
	float bg_ang = (bg_r - 0.5) * 2.6 + 0.35;
	vec2 bg_dir = vec2(cos(bg_ang), sin(bg_ang));
	vec2 dirv = normalize(bg_dir * (1.0 - clamp(cur * 1.25, 0.0, 1.0)) + flow_dir * clamp(cur * 1.25, 0.0, 1.0));

	// 海况分区：一次 fbm 采样，同时决定涌浪笔触与碎浪笔触的覆盖率（互补）。
	float zone_n = 0.37;
#if !defined(PK_MOBILE_ANY)
	zone_n = fbm(water_cyl_p_cs(cs, wp, 0.0065, vec2(t * 0.008, -t * 0.006)), 2);
#else
	zone_n = noise_lf * 0.74;
#endif
	float zs = smoothstep(0.20, 0.55, zone_n);
	// 海况强度场：两个尺度的低频哈希噪声合成「粗糙度」rough ∈ [0,1]：平静海域法线接近
	// water_rough_min、风浪海域拉满到 water_rough_max；同时调制笔触覆盖率与波高。
	//   water_rough_scale    ：海况分区的空间尺度（越大，平静 / 风浪区块越大）
	//   water_rough_coverage ：风浪区所占比例（0 = 几乎全平静，1 = 几乎全风浪）
	float rs = max(water_rough_scale, 0.05);
	float rough_n = water_hash_ripple(wp, 420.0 * rs, vec2(t * 0.0040, -t * 0.0027) / rs, 211.0, 0.31).z * 0.62
			+ water_hash_ripple(wp, 150.0 * rs, vec2(-t * 0.0060, t * 0.0040) / rs, 307.0, -0.27).z * 0.38 + 0.5;
	float rough_c = mix(0.75, 0.25, clamp(water_rough_coverage, 0.0, 1.0));
	float rough = smoothstep(rough_c - 0.20, rough_c + 0.20, rough_n);
	// [water-mark-off 2026-11-06] 笔触覆盖率随笔触一起停用（原先只服务涌浪 / 碎浪两层）。
	// float cov_k = max(water_mark_coverage, 0.0);
	// float cover_a = clamp(mix(0.20, 0.66, zs) * mix(0.25, 1.25, rough) * cov_k, 0.0, 0.95);
	// float cover_b = clamp(mix(0.58, 0.18, zs) * mix(0.30, 1.20, rough) * cov_k, 0.0, 0.95);

	// 格尺寸随 water_flow_wave_density 缩放（默认密度时 ≈ 66 / 34 世界单位）；
	// water_ripple_scale 只缩放底层涟漪的格子大小。
	float dens = max(water_flow_wave_density * freq_scale * water_base_normal_scale, 0.05);
	float sc = 1.27 / dens;
	// 流动速度 ∝ water_flow_advection（位移固定、周期缩放；旧版位移与周期都乘它，速度成了平方关系）。
	float rate_s = water_flow_advection / 1.15;
	float rsc = sc * max(water_ripple_scale, 0.05);
	// 底层细节海面：先于笔触求值，笔触叠在其上。
	// 平流位移 = 背景浪向 × water_flow_drift_base + 洋流向量 × water_flow_drift_current（世界单位 / 周期）；
	// 位移必须大于一个格宽，才是净流动而不是原地淡入淡出。
	vec2 adv_big = bg_dir * water_flow_drift_base + flow * water_flow_drift_current;
	vec3 rp1 = water_hash_ripple_flow(wp, 52.0 * rsc, adv_big, t, 0.04 * rate_s, 71.0, 0.47);
	float rip_k = 6.5 * water_ripple_strength;
	vec2 grad = rp1.xy * rip_k;
	float height = rp1.z * 0.60 * water_ripple_strength;
	if (visual_quality >= 1) {
		vec2 adv_small = vec2(bg_dir.x * 0.5 - bg_dir.y * 0.87, bg_dir.x * 0.87 + bg_dir.y * 0.5)
				* (water_flow_drift_base * 0.47) + flow * (water_flow_drift_current * 0.60);
		vec3 rp2 = water_hash_ripple_flow(wp, 23.0 * rsc, adv_small, t, 0.06 * rate_s, 133.0, -0.39);
		grad += rp2.xy * rip_k * water_ripple_detail_mix;
		height += rp2.z * 0.45 * water_ripple_strength;
	}
	float mlen = max(water_mark_length, 0.05);
	// ── [water-mark-off 2026-11-06] 浪头笔触停用 ───────────────────────────
	// 主浪改由底层涟漪 + 顺流洋流丝表达。下面是**注释掉**而不是运行期开关：
	// 编译期就不存在这段，不占指令也不占寄存器。回退时把注释放开即可。
	// 注意：`wave_height` 因此只剩涟漪高度，浪尖碎白（smoothstep(0.30,0.72,wave_h)）
	// 会明显变少 —— 这是停用笔触的直接后果，不是 bug。
	// vec4 la = water_mark_layer(wp, 66.0 * sc, 0.21, dirv, false, cover_a,
	// 		t, 0.06 * rate_s, 0.40, 0.14, 0.26 * mlen, fp, 3.0, noise_lf);
	// grad += la.xy * (0.55 * water_mark_strength);
	// height += la.z;
	// if (visual_quality >= 1) {
	// 	// 碎浪层：浪向相对主向偏转约 50°（常量旋转），格线反向斜切。
	// 	// [water-mark-shape] 34 → 37：两层格宽从近 2:1 挪开，避免叠出超周期摩尔纹。
	// 	vec2 dirb = vec2(dirv.x * 0.64 - dirv.y * 0.77, dirv.x * 0.77 + dirv.y * 0.64);
	// 	vec4 lb = water_mark_layer(wp, 37.0 * sc, -0.27, dirb, false, cover_b,
	// 			t, 0.10 * rate_s, 0.50, 0.14, 0.22 * mlen, fp, 11.0, noise_lf);
	// 	grad += lb.xy * (0.40 * water_mark_strength);
	// 	height += lb.z * 0.80;
	// }
	float amp_mod = mix(0.90, 1.20, cur);
	wave_height = clamp(height * amp_mod * mix(0.35, 1.0, rough), -1.0, 1.0);

#if !defined(PK_MOBILE_ANY)
	if (visual_quality >= 2 && water_flow_streak_strength > 0.001 && cur > 0.004) {
		// 洋流丝：顺流拉长、漂得更快；覆盖率随流强升高 ⇒ 强流区丝更密。
		vec2 adv = flow_dir;
		vec4 ls = water_mark_layer(wp, 52.0 * sc, 0.17, adv, true,
				mix(0.22, 0.65, cur), t, 0.07 * rate_s, 0.7, 0.11, 0.30 * mlen, fp, 23.0, noise_lf);
		flow_streak = ls.w * cur * water_flow_streak_strength * wave_mask;
	}
#endif

	// 法线强度：平静区 = water_rough_min、风浪区 = water_rough_max。
	float env = mix(water_rough_min, water_rough_max, rough) * mix(0.85, 1.15, zs);
	grad *= 0.6 * water_base_normal_strength * amp_scale * env * wave_mask
			* water_flow_wave_amplitude * amp_mod;
	return normalize(vec3(-grad, 1.0));
}

// 兼容层：旧调用点（8 参 / 7 参）继续可编，丢弃洋流丝 / 波高。
// （Godot 的 shader include 分别缓存，编辑器可能短暂持有旧版 water_pipeline。）
vec3 sample_flow_water_normal(vec2 wp, float t, vec2 flow, float amp_scale,
		float freq_scale, float noise_lf, float wave_mask,
		inout float wave_height, inout float flow_streak) {
	return water_flow_surface(wp, t, flow, amp_scale, freq_scale, noise_lf,
			wave_mask, wave_height, flow_streak);
}

vec3 sample_flow_water_normal(vec2 wp, float t, vec2 flow, float amp_scale,
		float freq_scale, float noise_lf, float wave_mask, inout float wave_height) {
	float discarded_streak = 0.0;
	return water_flow_surface(wp, t, flow, amp_scale, freq_scale, noise_lf,
			wave_mask, wave_height, discarded_streak);
}

vec3 sample_flow_water_normal(vec2 wp, float t, vec2 flow, float amp_scale,
		float freq_scale, float noise_lf, float wave_mask) {
	float discarded_height = 0.0;
	float discarded_streak = 0.0;
	return water_flow_surface(wp, t, flow, amp_scale, freq_scale, noise_lf,
			wave_mask, discarded_height, discarded_streak);
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
			int b = int(visual_sample_map_index(suv).r * 255.0 + 0.5);
			if (b == B_LAKE)    cnt_lake += sw;
			if (b == B_REEF)    cnt_reef += sw;
			if (b == B_KELP)    cnt_kelp += sw;
			if (b == B_SEA_ICE) cnt_ice  += sw;
			total_w += sw;
		}
	}
	return vec4(cnt_lake, cnt_reef, cnt_kelp, cnt_ice) / max(total_w, 0.001);
}
