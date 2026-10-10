// hillshade_tod.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：地形光照的全部 helper。两条独立路径并存，由 caller 在 fragment 内按
//        day_night_enabled 选择：
//   【路径 A — 经典双光源 hillshading】
//     - hillshading_two_lights(uv) → key + fill 两方向漫反射近似，结果会被
//       fragment 直接乘到 col 上做"陆地阴影"。
//   【路径 B — 旧版风格化日夜（legacy，仅保留作 debug helper）】
//     - get_sun_dir / get_sky_tint / get_day_brightness / apply_day_night：
//       用 day_phase ∈ [0,1] 直接派生太阳位置 + 天色 tint + 整体亮度。
//   【路径 C — 任务 3 TOD 驱动的 PBR（主路径；day_night_enabled=false 时为永昼）】
//     - compute_terrain_normal(uv, quality, biome)：粗法线(烘焙 terrain_normal_tex / 宽半径回退)
//       + 运行期细节法线(按 biome/性能档)，治"细节过强密密麻麻、山脉走向不清晰"。
//     - biome_roughness(biome)：粗糙度查表。
//     - apply_tod_pbr(albedo, uv, biome, quality)：NdotL + Blinn-Phong + 夜间
//       压暗 + 曝光 + Reinhard tonemap。
// 调用方：
//   - hillshading_two_lights → fragment "4. Hillshading"（陆地）。
//   - apply_tod_pbr → fragment "9. 风格化 PBR 昼夜着色"（陆地 + day_night 开启）。
//   - apply_day_night / get_*：保留但当前 fragment 路径已不走（由 TOD PBR 取代）。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：hm_resolution / hillshade_* / tod_* /
//     night_brightness_* / B_* 常量。
//   - height.gdshaderinc：decode_height_rg8（被 hillshading 与 PBR 法线复用）。
// 性能（PERF）：apply_tod_pbr 中 compute_terrain_normal 的高质量分支需要 8 次
//                decode_height_rg8 调用（每次 1 个纹理 fetch）。hillshading
//                4 次。fragment 陆地像素若 day_night_enabled=true 会走 PBR ≈ 8
//                次 height 采样；外加 fragment 自己另算一次坡度（雪坡度判别）
//                与河流坡度（4 次）。总计单像素陆地 ≈ 16~20 次 height 采样。
//                优化方向：把法线烘成 normal_atlas（一次 GPU pass），fragment
//                主路径只 1 次采样。本轮不动。
// ─────────────────────────────────────────────────────────────────────────

// ─── 双光源 hillshading（key + fill，软阴影） ───────────────────────────

float hillshading_two_lights(vec2 uv) {
	vec2 texel = 1.0 / hm_resolution;
	vec2 world_texel = world_size / max(hm_resolution, vec2(1.0));
	float l = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y));
	float gx = terrain_normal_height_scale_hex * max(hex_size, 1e-4) /
		(2.0 * max(world_texel.x, 1e-4));
	float gy = terrain_normal_height_scale_hex * max(hex_size, 1e-4) /
		(2.0 * max(world_texel.y, 1e-4));
	float dx = (r - l) * gx;
	float dy = (d - u) * gy;
	vec3 normal = normalize(vec3(-dx, -dy, 1.0));

	vec3 key_dir  = normalize(vec3(hillshade_dir.x,      hillshade_dir.y,      0.65));
	vec3 fill_dir = normalize(vec3(hillshade_fill_dir.x, hillshade_fill_dir.y, 0.50));

	float key  = max(dot(normal, key_dir),  0.0);
	float fill = max(dot(normal, fill_dir), 0.0) * 0.40;
	return key + fill;
}

// ─── 任务 3：风格化 PBR 昼夜着色辅助 ───────────────────────────────────
// 关键决策 1：保留 PBR 物理光照流程（方向光 NdotL + 菲涅尔柔边），但色温/饱和度
//   phase=0.0 日出：太阳从东方地平线升起，天色暖橙
//   phase=0.25 正午：太阳在天顶（接近正上方），天色偏白
//   phase=0.5 日落：太阳回到地平线（西方），天色暖橙偏红
//
// 返回"太阳方向向量"（世界坐标空间，XY 是水平，Z 是向上近似法向）。
// 正午 z 接近 1（正上方），日出/日落 z 接近 0，午夜 z 为负（光从下面来，
// 在渲染上被解释为"无直接光"，地表由环境冷色补光）。
vec3 get_sun_dir(float phase) {
	// 一天 360° 旋转：phase→angle；0.0 起点设在"日出地平线"
	float angle = phase * 6.2831853;  // 2π
	float sun_x = cos(angle - 1.5707963);   // shift：phase=0 时 cos(-π/2)=0, sin(...)
	float sun_z = sin(angle - 1.5707963) + 1.0; // phase=0 时 z≈0 (地平线) ... phase=0.25 时 z≈2 → 归一化后 ~1
	sun_z = sun_z - 1.0;  // 重新平移为 [-1, 1]：日出 0, 正午 1, 日落 0, 午夜 -1
	// y 方向做 0.15 的微偏（稍偏南），贴近"太阳轨迹不是完美竖直面"的直觉
	float sun_y = 0.15;
	return normalize(vec3(sun_x, sun_y, sun_z));
}

// 天空染色：四关键色 smoothstep 插值。手调曲线，不走物理光谱。
vec3 get_sky_tint(float phase) {
	vec3 sunrise = vec3(1.20, 0.88, 0.72);  // 暖
	vec3 noon    = vec3(1.00, 1.00, 0.98);  // 近白
	vec3 sunset  = vec3(1.18, 0.80, 0.62);  // 暖橙偏红
	vec3 night   = vec3(0.55, 0.65, 0.92);  // 冷蓝（月光）
	if (phase < 0.25)
		return mix(sunrise, noon,   smoothstep(0.0,  0.25, phase));
	if (phase < 0.5)
		return mix(noon,    sunset, smoothstep(0.25, 0.5,  phase));
	if (phase < 0.75)
		return mix(sunset,  night,  smoothstep(0.5,  0.75, phase));
	return mix(night,   sunrise, smoothstep(0.75, 1.0,  phase));
}

// 整体亮度系数：夜间压到 night_brightness_min ~ max 之间，白天为 1.0。
float get_day_brightness(float phase) {
	// 白天区间 [0.0, 0.5]（日出→日落）= 1.0；夜晚区间 [0.5, 1.0] 压暗
	// 过渡段 ±0.06 phase 做软过渡
	float day_mask = smoothstep(0.06, 0.0, abs(phase - 0.25) - 0.19);
	// 夜间值：min~max 之间再按 phase 相对午夜 0.75 的距离微调（午夜最暗）
	float night_t = smoothstep(0.0, 0.25, abs(phase - 0.75));
	float night_brightness = mix(night_brightness_min, night_brightness_max, night_t);
	return mix(night_brightness, 1.0, day_mask);
}

// 风格化 PBR 着色：对输入 albedo 应用 NdotL + 菲涅尔柔边 + 天色 tint + 夜间压暗。
// terrain_normal 由 hillshading 的 dx/dy 近似重构（已经算过，此处复用 result）；
vec3 apply_day_night(vec3 albedo, float phase, vec2 slope_xy) {
	vec3 n = normalize(vec3(-slope_xy, 1.0));
	vec3 sun = get_sun_dir(phase);
	// NdotL：太阳在地平线下时会是负数，clamp 到 0 = 无直接光
	float ndotl = max(dot(n, sun), 0.0);
	// 风格化 PBR：ambient 0.55（手绘风不追求 100% 物理），direct 0.45 × NdotL
	float lighting = 0.55 + 0.45 * ndotl;
	// 菲涅尔柔边：用 z 分量模拟"视角几乎垂直"，对山坡背光侧做轻微提亮
	// fresnel = pow(1.0 - NdotV, 3)；2D canvas NdotV 近似 n.z
	float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
	lighting += fresnel * 0.08;
	// 天色 tint
	vec3 sky = get_sky_tint(phase);
	vec3 result = albedo * lighting * sky;
	// 整体亮度（夜间压暗）
	result *= get_day_brightness(phase);
	return result;
}

// ─── Pass 2（任务 3）：TOD 驱动的风格化 PBR ────────────────────────────
// 为 Sobel 3x3（visual_quality>=1）或保留 4-tap（visual_quality==0，需求 3.6）。
// 关键改动（对应需求 3.1~3.6）：
//   1. 法线 N 来自 height_tex 的 Sobel/Center-Diff，比 hillshading_two_lights 更强
//   2. 光照方向 = tod_sun_dir，色温 = tod_sun_color，环境 = tod_ambient_color
//   3. 高光 = Blinn-Phong NdotH，roughness 按 biome 分类（雪光滑、森林粗糙）
//   4. 平地退化：|∇h| < epsilon 时跳过方向光（避免噪声伪影）
//   5. 最终乘 tod_exposure 并做艺术化 tonemap
//   6. day_night_enabled=false 的主路径语义已改为永昼；本函数保留给 legacy/debug 调用
//
// 返回：PBR 染色后的 RGB（caller 负责 clamp）。
// 从 height_tex 采样得到 tangent-space 法线（Sobel 3x3 或 4-tap 中心差分）
// [terrain-normal 分层 2026-06-25] per-biome 细节法线因子：山地/方山满量，丘陵/荒地次之，
//   森林/草本/沙漠中低，平原/湿地系趋零（"平原真平、不密密麻麻"）。纯 ALU 查表，零额外采样。
float terrain_detail_factor(int biome) {
	// [micro-soften 2026-07-31] 全表约 ×0.65：保留山地相对层次，压掉干燥/有机地表的
	// 高频凹凸。平原/湿地继续趋零。
	if (biome == B_MOUNTAIN || biome == B_MESA) return 0.70;
	if (biome == B_HILL || biome == B_BADLANDS) return 0.55;
	if (biome == B_TUNDRA) return 0.28;
	if (biome == B_DESERT || biome == B_SALT_FLAT || biome == B_COLD_DESERT) return 0.22;
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_SEA_ICE) return 0.22;
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.28;
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE
			|| biome == B_SHRUBLAND || biome == B_CHAPARRAL) return 0.18;
	if (biome == B_PLAIN || biome == B_SWAMP || biome == B_MOOR
			|| biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_OASIS) return 0.08;
	return 0.18;
}

// 三层法线合成（需求：① 粗法线给走向、② 细节按地形叠、③ 低端机不上细节）：
//   1. 粗法线 N_coarse：优先用生成期烘焙的 terrain_normal_tex（1 fetch）拿宏观山脉走向；
//      未绑定（旧存档/未 rebake）时回退到运行期宽半径(hillshade_coarse_radius) 4-tap。
//   2. 细节法线：运行期 1-texel 中心差分（4 fetch），按 quality + biome 门控，叠到粗法线上。
//   3. 性能分档：MOBILE_QUALITY_LOW/MID、desktop visual_quality==0 → 仅粗法线，跳过细节。
// 粗法线（宏观走向），未归一化。
vec3 terrain_coarse_normal(vec2 uv) {
	vec2 texel = 1.0 / hm_resolution;
	vec3 N_coarse;
#ifdef VT_USE_TERRAIN_NORMAL
	if (terrain_normal_tex_bound) {
		vec2 nxy = visual_sample_terrain_normal(uv).rg * 2.0 - 1.0;
		nxy *= hillshade_coarse_strength;                       // 运行期再缩放走向强度
		float nz = sqrt(max(1e-4, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.998)));
		N_coarse = vec3(nxy, nz);
	} else
#endif
	{
		// [pk-web-texture-budget] terrain_normal tile 已裁掉时，无条件走此运行期宽半径
		// 差分半径按 hex 世界尺度换算，旧存档也不会随地图栅格改变明暗强度。
		vec2 world_texel = world_size / max(hm_resolution, vec2(1.0));
		float rx = max(1.0, floor(terrain_normal_sample_radius_hex * max(hex_size, 1e-4) /
			max(world_texel.x, 1e-4) + 0.5));
		float ry = max(1.0, floor(terrain_normal_sample_radius_hex * max(hex_size, 1e-4) /
			max(world_texel.y, 1e-4) + 0.5));
		float lc = decode_height_rg8(uv - vec2(texel.x * rx, 0.0));
		float rc = decode_height_rg8(uv + vec2(texel.x * rx, 0.0));
		float uc = decode_height_rg8(uv - vec2(0.0, texel.y * ry));
		float dc = decode_height_rg8(uv + vec2(0.0, texel.y * ry));
		float gx = terrain_normal_height_scale_hex * max(hex_size, 1e-4) /
			(2.0 * rx * max(world_texel.x, 1e-4));
		float gy = terrain_normal_height_scale_hex * max(hex_size, 1e-4) /
			(2.0 * ry * max(world_texel.y, 1e-4));
		N_coarse = vec3(-(rc - lc) * gx, -(dc - uc) * gy, 1.0);
	}
	return N_coarse;
}

// 在粗法线上叠运行期高度细节法线，返回归一化结果。
vec3 terrain_add_height_detail(vec3 N_coarse, vec2 uv, int quality, int biome) {
	vec2 texel = 1.0 / hm_resolution;
	// ── 2. 细节量：性能分档 + biome 门控 + zoom 门控 ────────────────────
	float detail_amt = 0.0;
#if defined(PK_MOBILE_ANY)
	detail_amt = 0.0;                                            // 移动端全档位：仅粗法线
#else
	if (hillshade_detail_enabled && quality >= 1) {
		// [normal-soften 2026-07-31] 旧逻辑 q>=2 时 qf=1.0，高画质反而把 residual 噪声
		// 放大到最碎。现在高画质只比中画质略强，真正的"高画质增益"转给 albedo 程序纹理。
		float qf = (quality >= 2) ? 0.55 : 0.35;
		detail_amt = hillshade_detail_strength * terrain_detail_factor(biome) * qf;
		// 中远距关掉高度细节法线：鸟瞰只看烘焙粗法线走向；近距再给一点凹凸。
		detail_amt *= smoothstep(1.35, 2.10, camera_zoom);
		// [shore-normal 2026-06-25] 近岸滩坡：近海陆地(coast_sdf 窄带)单独解门控，让海岸读出滩坡起伏。
		//   biome 是 TerrainType id（B_COAST=1 是水体走 water_pipeline，不入此函数）；近岸陆地多为 B_PLAIN，
		//   其 terrain_detail_factor≈0.12 被压平 → 这里用高程贴海平面的程度补一份 detail，仅薄薄一带、不碰内陆平原。
		if (shore_detail_strength > 0.0) {
			float eh = decode_height_rg8(uv);                   // 1 fetch：本像素高程
			if (eh > sea_level) {
				float band = 1.0 - smoothstep(0.0, shore_band_height, eh - sea_level);  // 贴岸→1，内陆→0
				float shore_amt = band * shore_detail_strength * qf;
				shore_amt *= smoothstep(1.20, 1.90, camera_zoom);
				detail_amt = max(detail_amt, shore_amt);
			}
		}
	}
#endif
	if (detail_amt <= 0.0) {
		return normalize(N_coarse);
	}

	// ── 3. 细节法线：宽半径中心差分（不再用 1-texel）────────────────────
	// 1-texel 会把 height RG8 量化台阶和 residual 高频原样搬进法线。改用 2.5~3.5 texel
	// 的差分：仍能读出河岸/崖壁局部坡，但滤掉像素级砂砾。gain 按半径归一，避免宽差分变弱。
	float detail_r = (quality >= 2) ? 3.5 : 2.5;
	float l1 = decode_height_rg8(uv - vec2(texel.x * detail_r, 0.0));
	float r1 = decode_height_rg8(uv + vec2(texel.x * detail_r, 0.0));
	float u1 = decode_height_rg8(uv - vec2(0.0, texel.y * detail_r));
	float d1 = decode_height_rg8(uv + vec2(0.0, texel.y * detail_r));
	float g = hillshade_slope_gain / max(detail_r, 1.0);
	float dx = (r1 - l1) * g;
	float dy = (d1 - u1) * g;
	vec3 N = N_coarse + vec3(-dx, -dy, 0.0) * detail_amt;
	return normalize(N);
}

vec3 compute_terrain_normal(vec2 uv, int quality, int biome) {
	return terrain_add_height_detail(terrain_coarse_normal(uv), uv, quality, biome);
}

#ifdef PK_TERRAIN_STATIC_BAKED
// 烘焙版地形几何法线：粗法线、近景高度细节、分地形细节（沟谷/台坎/沙丘/起伏/丘状）
// 都已在 visual tile 烘焙时逐 texel 求好，这里 2 次采样 + 按缩放淡出。
// 返回 (法线, 沟谷深度)；crease 由调用方从已采样的 edge_distance.g 传入。
// 细节坡度分粗段（波长 >= 32·scale）与细段两组，各自只在屏幕上够宽时淡入，
// 代替原先逐倍频的屏幕波长淡出；近景高度细节保留原来的拉近门控。
vec4 terrain_baked_normal(vec2 uv, int quality, float crease) {
	vec4 n = visual_sample_terrain_normal(uv);
	vec2 nxy = (n.rg * 2.0 - 1.0) * hillshade_coarse_strength;
	float nz = sqrt(max(1e-4, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.998)));
#if defined(PK_MOBILE_ANY) || defined(PK_QUALITY_LOW)
	return vec4(nxy, nz, 0.0);
#else
	if (quality < 1) {
		return vec4(nxy, nz, 0.0);
	}
	vec2 s = nxy / max(nz, 0.2);
	if (hillshade_detail_enabled) {
		float qf = (quality >= 2) ? 1.0 : 0.64;
		s += decode_relief_slope(n.ba) * (qf * smoothstep(1.35, 2.10, camera_zoom));
	}
	float k_relief = 0.0;
	if (terrain_erosion_strength > 0.0001) {
		float scale = max(terrain_erosion_world_size, 1.0) / 72.0;
		vec4 r = decode_relief_slope4(visual_sample_terrain_relief(uv));
		float fade_coarse = smoothstep(3.0, 7.0, 48.0 * scale * camera_zoom);
		float fade_fine = smoothstep(3.0, 7.0, 14.0 * scale * camera_zoom);
		s += r.xy * fade_coarse + r.zw * fade_fine;
		k_relief = fade_coarse;
	}
	return vec4(normalize(vec3(s, 1.0)), crease * k_relief);
#endif
}
#endif

// ─── 侵蚀沟谷细节（DEM 晕渲观感）──────────────────────────────────────
// 高度场只有宏观起伏和无方向的残差噪声，读不出真实地形里顺坡而下的沟谷与山脊。
// 这里在世界空间叠一组"沿坡度方向拉长"的条纹噪声：每个抖动特征点贡献一段余弦起伏，
// 相位沿垂直于坡度的方向变化，于是条纹顺坡延伸；逐层把上一层细节坡度并入方向，
// 细层顺着粗层的沟脊分叉，形成树枝状水系纹理。
vec2 terrain_erosion_hash22(vec2 p) {
	return vec2(hash21(p), hash21(p + vec2(17.31, 41.77)));
}

// x 方向按整数周期取模的 value noise，沿经线环绕无缝；period_cells <= 0 表示不环绕。
float terrain_erosion_value_noise(vec2 p, float period_cells) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_cells > 0.5) {
		x0 = mod(x0, period_cells);
		x1 = mod(x1, period_cells);
	}
	float a = hash21(vec2(x0, i.y));
	float b = hash21(vec2(x1, i.y));
	float c = hash21(vec2(x0, i.y + 1.0));
	float d = hash21(vec2(x1, i.y + 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// world_size 尺度的格坐标；x 方向对齐 wrap 周期。
vec2 terrain_erosion_cell_coord(vec2 wp, float cell_size, out float period_cells) {
	period_cells = 0.0;
	if (wrap_period_x > 0.0001) {
		period_cells = max(1.0, floor(wrap_period_x / cell_size + 0.5));
		float cell_w = wrap_period_x / period_cells;
		return vec2((wrap_world_x(wp.x) - wrap_origin_x) / cell_w, wp.y / cell_w);
	}
	return wp / cell_size;
}

// p 为格坐标；dir 为相位变化方向（条纹沿其垂直方向延伸）；period_cells > 0 时格的 x 下标
// 按周期取模，沿经线环绕无缝。harm2 > 0 叠二次谐波，剖面由对称余弦变成不对称锯齿
// （0.5 ≈ 锯齿波，沙丘迎风缓坡 + 背风陡坡）。返回 (h, ∂h/∂p)，导数省略了 2π 因子。
// 各核的 (cos, sin) 先求和再归一化（Phacelle 式相量）：直接累加余弦会相互干涉，
// 条纹断成大理石状涡纹，对比度忽强忽弱；归一化后条纹连续、对比恒定，只在相位奇点
// 附近（|和| < 1 - TERRAIN_DETAIL_PHASOR_NORM）按比例淡出。
vec3 terrain_phasor_noise(vec2 p, vec2 dir, float period_cells, float harm2) {
	vec2 ip = floor(p);
	vec2 fp = fract(p);
	vec2 acc = vec2(0.0);
	float wsum = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 cell = ip + o;
			if (period_cells > 0.5) {
				cell.x = mod(cell.x, period_cells);
			}
			// 特征点限制在格中央 [0.25, 0.75]，3×3 窗口外的点距当前像素至少 1.25 格；
			// 权重在 1.25 处截到 0，跨格线时核集合的增减不产生跳变。
			vec2 d = fp - o - 0.5 - (terrain_erosion_hash22(cell) - 0.5) * 0.5;
			float w = max(0.0, exp(-dot(d, d) * 2.0) - 0.0439);
			float ph = dot(d, dir) * 6.2831853;
			acc += vec2(cos(ph), sin(ph)) * w;
			wsum += w;
		}
	}
	vec2 v = acc / max(wsum, 1e-4);
	v /= max(length(v), 1.0 - TERRAIN_DETAIL_PHASOR_NORM);
	float c = v.x;
	float s = v.y;
	float s2 = 2.0 * s * c;
	float c2 = c * c - s * s;
	return vec3(c - harm2 * s2, (-s - 2.0 * harm2 * c2) * dir);
}

// 带解析导数的 value noise：返回 (v ∈ [-1, 1], ∂v/∂p)。x 方向按 period_cells 环绕。
vec3 terrain_value_noise_d(vec2 p, float period_cells) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec2 du = 6.0 * f * (1.0 - f);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_cells > 0.5) {
		x0 = mod(x0, period_cells);
		x1 = mod(x1, period_cells);
	}
	float a = hash21(vec2(x0, i.y));
	float b = hash21(vec2(x1, i.y));
	float c = hash21(vec2(x0, i.y + 1.0));
	float d = hash21(vec2(x1, i.y + 1.0));
	float k = a - b - c + d;
	float v = a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y;
	vec2 g = du * vec2((b - a) + k * u.y, (c - a) + k * u.x);
	return vec3(v * 2.0 - 1.0, g * 2.0);
}

// ─── 分地形细节法线 ───────────────────────────────────────────────────
// 宏观起伏由烘焙高度图（汇流刻谷）负责；这里只补格内细节，每种地形用不同的形态组合：
//   gully   顺坡沟谷，sharp 控制剖面（0 圆缓冲沟 → 1 尖脊 V 谷）
//   strata  沿等高线的层状台坎（岩层出露），只在有坡处出现
//   dune    随风向的不对称沙丘 + 细波纹
//   rolling 宽缓的圆形起伏
//   hummock 小尺度丘状凹凸（树冠、冻融丘、草丘）
// 强度单位都是"坡度"：对法线 xy 的最大偏转量级，与波长无关。
struct TerrainDetailProfile {
	float gully;
	float gully_wl;
	float sharp;
	float strata;
	float dune;
	float rolling;
	float hummock;
};

TerrainDetailProfile terrain_detail_profile(int biome) {
	//                                   gully  wl     sharp  strata dune   rolling hummock
	if (biome == B_MOUNTAIN)   return TerrainDetailProfile(0.42, 64.0, 0.70, 0.00, 0.0, 0.00, 0.05);
	if (biome == B_MESA)       return TerrainDetailProfile(0.20, 56.0, 0.35, 0.60, 0.0, 0.03, 0.03);
	if (biome == B_BADLANDS)   return TerrainDetailProfile(0.52, 30.0, 0.85, 0.28, 0.0, 0.00, 0.02);
	if (biome == B_HILL)       return TerrainDetailProfile(0.22, 84.0, 0.10, 0.00, 0.0, 0.26, 0.06);
	if (biome == B_DESERT)     return TerrainDetailProfile(0.00, 64.0, 0.00, 0.00, 0.30, 0.03, 0.00);
	if (biome == B_COLD_DESERT) return TerrainDetailProfile(0.12, 56.0, 0.50, 0.10, 0.00, 0.07, 0.08);
	if (biome == B_SALT_FLAT)  return TerrainDetailProfile(0.00, 64.0, 0.00, 0.00, 0.00, 0.01, 0.02);
	if (biome == B_TUNDRA)     return TerrainDetailProfile(0.06, 72.0, 0.20, 0.00, 0.00, 0.05, 0.09);
	if (biome == B_SNOW || biome == B_GLACIER)
		return TerrainDetailProfile(0.10, 96.0, 0.00, 0.00, 0.00, 0.08, 0.02);
	if (biome == B_SHRUBLAND || biome == B_CHAPARRAL)
		return TerrainDetailProfile(0.10, 64.0, 0.40, 0.04, 0.00, 0.09, 0.06);
	if (biome == B_GRASSLAND || biome == B_STEPPE || biome == B_SAVANNA)
		return TerrainDetailProfile(0.05, 96.0, 0.00, 0.00, 0.00, 0.09, 0.03);
	if (biome == B_FOREST || biome == B_TAIGA || biome == B_JUNGLE || biome == B_MANGROVE)
		return TerrainDetailProfile(0.06, 80.0, 0.00, 0.00, 0.00, 0.05, 0.11);
	if (biome == B_SWAMP || biome == B_MOOR)
		return TerrainDetailProfile(0.00, 64.0, 0.00, 0.00, 0.00, 0.02, 0.05);
	if (biome == B_PLAIN)      return TerrainDetailProfile(0.02, 110.0, 0.0, 0.00, 0.00, 0.07, 0.02);
	if (biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_OASIS)
		return TerrainDetailProfile(0.00, 64.0, 0.00, 0.00, 0.00, 0.03, 0.01);
	return TerrainDetailProfile(0.04, 80.0, 0.00, 0.00, 0.00, 0.06, 0.03);
}

TerrainDetailProfile terrain_detail_profile_mix(
		TerrainDetailProfile a, TerrainDetailProfile b, float t) {
	return TerrainDetailProfile(
			mix(a.gully, b.gully, t), mix(a.gully_wl, b.gully_wl, t), mix(a.sharp, b.sharp, t),
			mix(a.strata, b.strata, t), mix(a.dune, b.dune, t),
			mix(a.rolling, b.rolling, t), mix(a.hummock, b.hummock, t));
}

// 地貌与 biome 正交：林地也可以长在山上。山地 / 丘陵的沟谷直接由宏观坡度连续驱动
// （坡越陡沟越深、脊越尖），不读地貌 id。
TerrainDetailProfile terrain_detail_slope_boost(TerrainDetailProfile p, float slope) {
	p.gully = max(p.gully, 0.40 * smoothstep(0.05, 0.35, slope));
	p.sharp = max(p.sharp, 0.70 * smoothstep(0.12, 0.45, slope));
	p.rolling = max(p.rolling, 0.12 * smoothstep(0.02, 0.10, slope) * (1.0 - smoothstep(0.15, 0.35, slope)));
	return p;
}

float terrain_detail_landform_is_layered(int lf) {
	return (lf == LF_PLATEAU || lf == LF_CANYON || lf == LF_RIFT_VALLEY) ? 1.0 : 0.0;
}

// 逐像素的 biome / 地貌 id 来自 warp 后 cube_round 的硬归属：格界参差，界外还散落
// texel 大小的飞地，直接按它选配置时起伏强度逐 texel 跳变，过渡带碎成噪点。
// 这里改在不扭曲的 hex 对偶三角网上插值：像素落在三个相邻格心围成的三角形里，
// 只在三个格心取 biome / 地貌（格心必在本格内，不受 warp 影响），按重心坐标混合。
// 权重取三次方再归一化，格内部基本保持本格配置，过渡集中在格界附近。
// 水格与地图外按像素自身的配置补位。返回配置，lf_w = (层状地貌权重, 荒地权重)。
TerrainDetailProfile terrain_detail_profile_field(
		vec2 wp, int own_biome, int own_landform, out vec2 lf_w) {
	float s = max(hex_size, 1e-4);
	vec2 a = vec2(0.57735027 * wp.x - 0.33333333 * wp.y, 0.66666667 * wp.y) / s;
	vec2 b = floor(a);
	vec2 f = a - b;
	float upper = step(1.0, f.x + f.y);
	vec2 v0 = b + vec2(upper);
	vec2 v1 = b + vec2(1.0, 0.0);
	vec2 v2 = b + vec2(0.0, 1.0);
	vec3 w = mix(vec3(1.0 - f.x - f.y, f.x, f.y), vec3(f.x + f.y - 1.0, 1.0 - f.y, 1.0 - f.x), upper);
	w = w * w * w;
	w /= max(w.x + w.y + w.z, 1e-6);

	TerrainDetailProfile own = terrain_detail_profile(own_biome);
	float own_layered = terrain_detail_landform_is_layered(own_landform);
	float own_bad = (own_landform == LF_BADLANDS) ? 1.0 : 0.0;
	TerrainDetailProfile acc = TerrainDetailProfile(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
	lf_w = vec2(0.0);
	for (int i = 0; i < 3; i++) {
		vec2 ax = (i == 0) ? v0 : ((i == 1) ? v1 : v2);
		float wi = (i == 0) ? w.x : ((i == 1) ? w.y : w.z);
		vec2 c = vec2(s * 1.7320508 * (ax.x + ax.y * 0.5), s * 1.5 * ax.y);
		vec4 mi = visual_sample_map_index(wrap_map_uv((c - world_origin) / world_size));
		int cid = int(mi.g * 255.0 + 0.5) + int(mi.b * 255.0 + 0.5) * 256;
		TerrainDetailProfile pi = own;
		vec2 li = vec2(own_layered, own_bad);
		if (cid < 65535) {
			int bi = int(texture(enum_lut, cell_lut_uv(cid)).r * 255.0 + 0.5);
			if (!(bi == B_OCEAN || bi == B_COAST || bi == B_LAKE || bi == B_REEF
					|| bi == B_KELP || bi == B_SEA_ICE)) {
				int lf = int(mi.a * 255.0 + 0.5);
				pi = terrain_detail_profile(bi);
				li = vec2(terrain_detail_landform_is_layered(lf), (lf == LF_BADLANDS) ? 1.0 : 0.0);
			}
		}
		acc.gully += pi.gully * wi;
		acc.gully_wl += pi.gully_wl * wi;
		acc.sharp += pi.sharp * wi;
		acc.strata += pi.strata * wi;
		acc.dune += pi.dune * wi;
		acc.rolling += pi.rolling * wi;
		acc.hummock += pi.hummock * wi;
		lf_w += li * wi;
	}
	return acc;
}

TerrainDetailProfile terrain_detail_landform_boost(
		TerrainDetailProfile p, vec2 lf_w, float slope_gate) {
	float layered = lf_w.x * slope_gate;
	float bad = lf_w.y * slope_gate;
	p.strata = max(p.strata, 0.55 * layered);
	p.gully = max(p.gully, 0.46 * bad);
	p.sharp = max(p.sharp, 0.80 * bad);
	p.strata = max(p.strata, 0.22 * bad);
	return p;
}

// 沟谷走向 / 台坎用的平滑高程场：约 1 格半径的中心差分 + 4 点均值，返回 (梯度, 均值)。
// 粗法线只有 0.35 格半径，会在每条刻谷的谷底和脊线两侧翻转方向，用它定向时条纹相位
// 逐像素乱跳；逐像素高程含格内残差，用它切台坎时层线弯成细碎的等高线。
vec3 terrain_detail_flow_field(vec2 uv) {
	vec2 world_texel = world_size / max(hm_resolution, vec2(1.0));
	vec2 r = max(vec2(1.0), floor(vec2(max(hex_size, 1e-4)) / max(world_texel, vec2(1e-4)) + 0.5));
	vec2 texel = 1.0 / max(hm_resolution, vec2(1.0));
	float l = decode_height_rg8(uv - vec2(texel.x * r.x, 0.0));
	float rr = decode_height_rg8(uv + vec2(texel.x * r.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y * r.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y * r.y));
	return vec3(vec2(rr - l, d - u) / max(2.0 * r * world_texel, vec2(1e-4)),
			(l + rr + u + d) * 0.25);
}

// camera_zoom = 每世界单位的屏幕像素数；波长不足 ~3px 的层会闪烁，提前淡出。
float terrain_detail_lod(float wl) {
	return smoothstep(3.0, 7.0, wl * camera_zoom);
}

// N = 要叠加细节的法线；N_coarse = 只含宏观起伏的粗法线，决定沟谷走向与台坎强度。
// 走向不能取 N：近距的高度细节 / 近岸细节是逐 texel 残差，方向乱跳会把条纹扭成水泡纹。
// biome / landform 是像素自身的归属，只在相邻格为水或地图外时补位用。
// 返回 (叠加细节后的法线, 沟谷深度 0..1)。沟谷深度给调用方做凹处遮蔽。
vec4 terrain_apply_landform_detail(
		vec3 N, vec3 N_coarse, vec2 uv, vec2 wp, float elev, int quality,
		int biome, int landform) {
#if defined(PK_MOBILE_ANY) || defined(PK_QUALITY_LOW)
	return vec4(N, 0.0);
#else
	if (terrain_erosion_strength <= 0.0001 || quality < 1) {
		return vec4(N, 0.0);
	}
	vec3 Nc = normalize(N_coarse);
	vec2 grad = -Nc.xy / max(Nc.z, 0.2);
	float slope = length(grad);
	float land_h = clamp((elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	float slope_gate = smoothstep(0.015, 0.10, slope);

	vec2 lf_w;
	TerrainDetailProfile P = terrain_detail_profile_field(wp, biome, landform, lf_w);
	P = terrain_detail_slope_boost(P, slope);
	P = terrain_detail_landform_boost(P, lf_w, slope_gate);

	float k = terrain_erosion_strength;
	float scale = max(terrain_erosion_world_size, 1.0) / 72.0;
	vec2 detail_grad = vec2(0.0);
	float crease = 0.0;
	// 约 1 格半径的平滑高程梯度（高程 / 世界单位），乘 flow_to_slope 换成与粗法线同单位的坡度。
	vec3 flow = terrain_detail_flow_field(uv);
	vec2 flow_grad = flow.xy;
	float flow_to_slope = terrain_normal_height_scale_hex * max(hex_size, 1e-4);

	// ① 顺坡沟谷：细层沿粗层的沟脊偏转，形成树枝状分叉；sharp 把余弦剖面折成尖脊。
	// 沟谷坡度随宏观坡度增长：缓坡上细节坡度远大于宏观坡度时，走向由细节自己主导，
	// 整片读成揉皱的锡纸而不是顺坡的冲沟。
	float gully_amp = P.gully * k
			* clamp(slope / TERRAIN_GULLY_FULL_SLOPE, 0.25, 1.0)
			* mix(0.6, 1.0, smoothstep(0.0, 0.12, land_h));
	if (gully_amp > 0.002) {
		// 走向兜底场：烘焙法线是 RG8，缓坡处方向几乎全是量化噪声，叠低频随机向量场给出连续走向。
		float flow_period;
		vec2 flow_p = terrain_erosion_cell_coord(wp, 288.0 * scale, flow_period);
		vec2 flow_field = vec2(
				terrain_erosion_value_noise(flow_p, flow_period),
				terrain_erosion_value_noise(flow_p + vec2(0.0, 57.0), flow_period)) * 2.0 - 1.0;
		// 平滑坡度直接以向量参与（不先归一化成方向）：沟底和脊顶处它连续地趋于 0，
		// 走向自然交给兜底场；归一化后在那里会整片翻转 180°，相位逐像素乱跳成碎点。
		vec2 grad_dir = flow_grad * flow_to_slope + flow_field * 0.03;
		// 各地形共用一组固定波长的倍频层，gully_wl 只决定能量落在哪几层：波长若随配置
		// 在空间上插值，相位坐标 wp / wl 在过渡带被拉扯，条纹卷成同心圆环。
		int octaves = (quality >= 2) ? 5 : 4;
		float band_c = log2(TERRAIN_GULLY_BASE_WL / max(P.gully_wl, 1.0));
		float wl = TERRAIN_GULLY_BASE_WL * scale;
		float h_sum = 0.0;
		float h_norm = 0.0;
		vec2 g_acc = vec2(0.0);
		vec2 steer_acc = vec2(0.0);
		for (int o = 0; o < 5; o++) {
			float lod = terrain_detail_lod(wl);
			if (o >= octaves || lod <= 0.0) {
				break;
			}
			float of = float(o);
			// 峰值层 = 配置波长；更细的层按 1/2 衰减（与常规 fBm 一致），更粗的层衰减更快。
			float amp = (of <= band_c) ? exp2(-(band_c - of) * 1.5) : exp2(-(of - band_c));
			if (amp < 0.03) {
				wl *= 0.5;
				continue;
			}
			// 偏转量封顶在走向向量的 35%：细节坡度常是宏观的数倍，不封顶时条纹会扭成水波纹。
			// 偏转只累积未锐化的导数：尖脊剖面的导数在脊线上不连续，用它偏转会让相位跳变。
			float dir_len = length(grad_dir);
			vec2 steer = steer_acc * gully_amp;
			float steer_len = length(steer);
			if (steer_len > dir_len) {
				steer *= dir_len / steer_len;
			}
			vec2 gd = grad_dir + steer * 0.35;
			float gl = length(gd);
			vec2 dir = (gl > 1e-4) ? vec2(gd.y, -gd.x) / gl : vec2(1.0, 0.0);
			float cells_x;
			vec2 p = terrain_erosion_cell_coord(wp, wl, cells_x);
			p += vec2(float(o * 17), float(o * 29));
			vec3 n = terrain_phasor_noise(p, dir, cells_x, 0.0);
			// 平滑绝对值折出尖脊：干涉相消处 h 长时间贴近 0，硬 abs/sign 会在那里逐像素翻转。
			float ha = sqrt(n.x * n.x + TERRAIN_DETAIL_CREST_ROUND * TERRAIN_DETAIL_CREST_ROUND);
			float hs = mix(n.x, 1.0 - 2.0 * ha, P.sharp);
			vec2 gs = mix(n.yz, -2.0 * (n.x / ha) * n.yz, P.sharp);
			g_acc += gs * amp * lod;
			steer_acc += n.yz * amp * lod;
			h_sum += hs * amp * lod;
			h_norm += amp * lod;
			wl *= 0.5;
		}
		detail_grad += g_acc * gully_amp;
		crease = (h_norm > 0.0) ? clamp(-h_sum / h_norm, 0.0, 1.0) * min(1.0, gully_amp * 2.5) : 0.0;
	}

	// ② 层状台坎：把高程按层厚 TERRAIN_STRATA_THICKNESS 量化成"平台 + 陡坎"，
	//    detail = (t'(s) - 1) · 宏观坡度，平台变缓、坎壁变陡，均值不变。层线随低频噪声起伏。
	float strata_amp = P.strata * k;
	float elev_grad = length(flow_grad);
	if (strata_amp > 0.002 && slope > 0.004 && elev_grad > 1e-6) {
		float wob_period;
		vec2 wob_p = terrain_erosion_cell_coord(wp, 160.0 * scale, wob_period);
		float wob = terrain_erosion_value_noise(wob_p, wob_period) * 2.0 - 1.0;
		// 层距 = 层厚 / 平滑梯度。层距须不小于约 3 个高度 texel（否则双线性插值把层线切成
		// texel 网格上的碎点）、约 4 屏幕像素（否则闪烁）和约 1/4 格（否则读成细密等高线
		// 而非岩层台坎）；不够时层厚按 2 倍逐级合并。2T 的层线是 T 层线的子集，相邻两级按
		// 对数插值，陡坡上自然只剩主层。层线切在平滑高程上，不随格内残差弯折。
		float texel_world = world_size.x / max(hm_resolution.x, 1.0);
		float min_spacing = max(max(3.0 * texel_world, 4.0 / max(camera_zoom, 1e-3)),
				TERRAIN_STRATA_MIN_SPACING_HEX * max(hex_size, 1e-4));
		float spacing = TERRAIN_STRATA_THICKNESS / elev_grad;
		float level = max(0.0, log2(min_spacing / spacing));
		float l0 = floor(level);
		float lt = level - l0;
		float base = flow.z / TERRAIN_STRATA_THICKNESS + wob * 0.35;
		float tp_mix = 0.0;
		for (int li = 0; li < 2; li++) {
			float lv = l0 + float(li);
			float s = base / exp2(lv);
			float x = clamp((fract(s) - (1.0 - TERRAIN_STRATA_RISER)) / TERRAIN_STRATA_RISER, 0.0, 1.0);
			float tp = 6.0 * x * (1.0 - x) / TERRAIN_STRATA_RISER;
			tp_mix += (tp - 1.0) * ((li == 0) ? (1.0 - lt) : lt);
		}
		// 超过 4 级合并（层距被迫放大 16 倍以上）时已不像岩层，整体淡出。
		float lod = 1.0 - smoothstep(3.0, 4.0, level);
		detail_grad += tp_mix * flow_grad * flow_to_slope * strata_amp * lod;
	}

	// ③ 沙丘：风向随超大尺度噪声缓慢转动；主沙丘锯齿剖面 + 细波纹。相量噪声在方向恒定时
	//    会生成无限长的直线，所以再叠中尺度摆动让脊线弯曲，并用低频场切出沙丘群与丘间平地。
	//    沙丘只在平坦低地成片堆积；台地 / 峡谷 / 荒地上的沙漠是石质戈壁，坡面上沙也留不住。
	//    按邻格沙海占比的衰减需要拓扑，只在 C++ 静态烘焙里做，本回退路径没有。
	float dune_amp = P.dune * k
			* (1.0 - smoothstep(TERRAIN_DUNE_SLOPE_LO, TERRAIN_DUNE_SLOPE_HI, slope))
			* (1.0 - TERRAIN_DUNE_ROCKY_CUT * max(lf_w.x, lf_w.y));
	if (dune_amp > 0.002) {
		float field_period;
		vec2 field_p = terrain_erosion_cell_coord(wp, TERRAIN_DUNE_FIELD_WL * scale, field_period);
		float field = terrain_erosion_value_noise(field_p + vec2(11.0, 53.0), field_period);
		dune_amp *= mix(TERRAIN_DUNE_INTERDUNE_FLOOR, 1.0, smoothstep(0.30, 0.72, field));
	}
	if (dune_amp > 0.002) {
		float wind_period;
		vec2 wind_p = terrain_erosion_cell_coord(wp, 900.0 * scale, wind_period);
		float bend_period;
		vec2 bend_p = terrain_erosion_cell_coord(wp, TERRAIN_DUNE_BEND_WL * scale, bend_period);
		float bend = terrain_erosion_value_noise(bend_p + vec2(31.0, 7.0), bend_period) - 0.5;
		float wa = 0.65 + (terrain_erosion_value_noise(wind_p, wind_period) - 0.5) * 2.2
				+ bend * TERRAIN_DUNE_BEND_RAD;
		vec2 wind = vec2(cos(wa), sin(wa));
		float wl = 44.0 * scale;
		float amp = 1.0;
		for (int o = 0; o < 2; o++) {
			float lod = terrain_detail_lod(wl);
			if (lod <= 0.0) {
				break;
			}
			float cells_x;
			vec2 p = terrain_erosion_cell_coord(wp, wl, cells_x);
			p += vec2(float(o * 23), float(o * 11));
			vec3 n = terrain_phasor_noise(p, wind, cells_x, (o == 0) ? 0.45 : 0.30);
			detail_grad += n.yz * amp * lod * dune_amp;
			amp *= 0.35;
			wl *= 0.28;
		}
	}

	// ④ 宽缓起伏 / ⑤ 丘状凹凸：各向同性 value noise，两层。
	float rolling_amp = P.rolling * k;
	if (rolling_amp > 0.002) {
		float wl = 150.0 * scale;
		float amp = 1.0;
		for (int o = 0; o < 2; o++) {
			float lod = terrain_detail_lod(wl);
			if (lod <= 0.0) {
				break;
			}
			float cells_x;
			vec2 p = terrain_erosion_cell_coord(wp, wl, cells_x);
			p += vec2(float(o * 31 + 5), float(o * 13 + 7));
			detail_grad += terrain_value_noise_d(p, cells_x).yz * amp * lod * rolling_amp;
			amp *= 0.5;
			wl *= 0.5;
		}
	}
	float hummock_amp = P.hummock * k;
	if (hummock_amp > 0.002) {
		float wl = 16.0 * scale;
		float amp = 1.0;
		for (int o = 0; o < 2; o++) {
			float lod = terrain_detail_lod(wl);
			if (lod <= 0.0) {
				break;
			}
			float cells_x;
			vec2 p = terrain_erosion_cell_coord(wp, wl, cells_x);
			p += vec2(float(o * 19 + 3), float(o * 37 + 1));
			vec3 n = terrain_value_noise_d(p, cells_x);
			// 平方把起伏收成圆顶小丘，丘间是宽缓的低地。
			detail_grad += 2.0 * max(n.x, 0.0) * n.yz * amp * lod * hummock_amp;
			amp *= 0.5;
			wl *= 0.5;
		}
	}

	vec3 Nn = normalize(N);
	vec3 out_n = normalize(vec3(Nn.xy / max(Nn.z, 0.2) - detail_grad, 1.0));
	return vec4(out_n, crease);
#endif
}

// 按 biome 查表粗糙度（需求 3.3）：雪/冰保持高反差、山地/丘陵/荒地更粗，避免像涂层
// [biome 材质全覆盖 2026-06-25] 补齐此前落到默认 0.55 的 11 种地形：湿地系略带含水反光、
// 岩石系接近全粗、灌丛/苔原干硬中粗、寒漠砾石中粗。纯 ALU 查表，零额外纹理采样。
float biome_roughness(int biome) {
	// 雪 / 冰川 / 海冰：高反差光滑面
	// [海冰反射 2026-06-25] 冰川/海冰是结晶冰，比积雪更镜面：从 0.22 降到 0.13；
	// 积雪是多重散射的哑光面，单独保留 0.30（略粗，避免与冰同质）。
	if (biome == B_GLACIER || biome == B_SEA_ICE) return 0.13;
	if (biome == B_SNOW) return 0.30;
	// 干燥沙 / 盐滩 / 寒漠：中粗砂砾
	if (biome == B_DESERT || biome == B_SALT_FLAT) return 0.58;
	if (biome == B_COLD_DESERT) return 0.62;
	// 密林：很粗（叶面多重漫反射）
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.88;
	// 草本：偏粗
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE) return 0.78;
	// 灌丛（含地中海硬叶）/ 苔原：干硬中粗
	if (biome == B_SHRUBLAND || biome == B_CHAPARRAL) return 0.76;
	if (biome == B_TUNDRA) return 0.72;
	// 裸岩碎石（山地/丘陵/荒地/方山）：接近全粗，消除低角度太阳下的"湿亮"高光
	if (biome == B_MOUNTAIN) return 0.96;
	if (biome == B_HILL) return 0.92;
	if (biome == B_BADLANDS || biome == B_MESA) return 0.92;
	// 湿地 / 水成地表：粗糙度压低 → 含水反光，与干燥地表区分（沼泽/泥炭最湿，冲积带次之）
	if (biome == B_SWAMP || biome == B_MOOR) return 0.52;
	if (biome == B_DELTA || biome == B_FLOODPLAIN) return 0.56;
	if (biome == B_OASIS) return 0.54;
	// 平原：中性偏粗
	if (biome == B_PLAIN) return 0.66;
	return 0.55;
}

// ─── [cylindrical-earth-daylight] 逐像素经纬度日照（晨昏线） ─────────────
// compute_solar_elevation / solar_day_factor / eval_earth_daylight / 昼夜色板
// 已统一下沉到 earth_daylight.gdshaderinc（单一真源，世界主 shader 在本文件之前
// include）。地形 brdf、水面 water_pipeline、植被 shrub_layer 全部调用同一份，
// 避免公式/色板各处复制后漂移。此处不再重复定义。

// 主入口：TOD 驱动的 PBR。is_water 时让上层直接跳过。
vec3 apply_tod_pbr(vec3 albedo, vec2 uv, int biome, int quality) {
	// 1. 法线
	vec3 N = compute_terrain_normal(uv, quality, biome);
	float slope_mag = length(vec2(N.x, N.y));

	vec3 L = normalize(tod_sun_dir);
	float ndotl = max(dot(N, L), 0.0);
	// [需求4 2026-06-19午] 解耦昼夜直射光强度：原 direct_amp = hillshade_strength+0.55，会随
	// hillshade_strength(为"山地层次"提到 0.74)线性放大到 1.29 → 昼夜模式向阳/背阴对比过强、着色失衡。
	// 改为弱耦合(0.60 + hs*0.40 ≈ 0.90)，保留山体立体感但不过曝；hillshade 调强只服务静态 hillshading 路径。
	float direct_amp = 0.60 + hillshade_strength * 0.40;
	vec3 diffuse = tod_sun_color * ndotl * direct_amp;

	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);
	float roughness = biome_roughness(biome);
	float shininess = mix(128.0, 4.0, roughness);
	float spec_amp = mix(0.25, 0.02, roughness);
	float ndoth = max(dot(N, H), 0.0);
	float spec = pow(ndoth, shininess) * spec_amp;
	vec3 specular = tod_sun_color * spec;

	vec3 ambient = tod_ambient_color;

	if (slope_mag < 0.015) {
		return albedo * (ambient + tod_sun_color * 0.3) * tod_exposure;
	}

	vec3 lit = albedo * (ambient + diffuse) + specular;

	// 7. 夜晚压暗
	float night_scale = mix(1.0, 0.55, tod_night_factor);
	lit *= night_scale;

	// 8. 曝光 + 艺术化 tonemap（简易 Reinhard）
	lit *= tod_exposure;
	lit = lit / (1.0 + lit * 0.35);
	return lit;
}
