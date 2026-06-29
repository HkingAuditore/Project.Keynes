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
	float l = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y));
	float dx = (r - l) * hillshade_slope_gain;
	float dy = (d - u) * hillshade_slope_gain;
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
	// 裸岩碎石：最需要细节凹凸（强调山脊/岩屑）
	if (biome == B_MOUNTAIN || biome == B_MESA) return 1.0;
	if (biome == B_HILL || biome == B_BADLANDS) return 0.80;
	// 苔原/寒漠/沙（沙丘有些起伏）：中低
	if (biome == B_TUNDRA) return 0.45;
	if (biome == B_DESERT || biome == B_SALT_FLAT || biome == B_COLD_DESERT) return 0.38;
	// 雪/冰：少量（雪被掩盖微地形）
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_SEA_ICE) return 0.35;
	// 林地：冠层掩盖微地形，给少量
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.45;
	// 草本/灌丛：低
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE
			|| biome == B_SHRUBLAND || biome == B_CHAPARRAL) return 0.30;
	// 平原 / 湿地 / 冲积 / 绿洲：趋零（真平）
	if (biome == B_PLAIN || biome == B_SWAMP || biome == B_MOOR
			|| biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_OASIS) return 0.12;
	return 0.30;
}

// 三层法线合成（需求：① 粗法线给走向、② 细节按地形叠、③ 低端机不上细节）：
//   1. 粗法线 N_coarse：优先用生成期烘焙的 terrain_normal_tex（1 fetch）拿宏观山脉走向；
//      未绑定（旧存档/未 rebake）时回退到运行期宽半径(hillshade_coarse_radius) 4-tap。
//   2. 细节法线：运行期 1-texel 中心差分（4 fetch），按 quality + biome 门控，叠到粗法线上。
//   3. 性能分档：MOBILE_QUALITY_LOW/MID、desktop visual_quality==0 → 仅粗法线，跳过细节。
vec3 compute_terrain_normal(vec2 uv, int quality, int biome) {
	vec2 texel = 1.0 / hm_resolution;

	// ── 1. 粗法线（宏观走向）──────────────────────────────────────────
	vec3 N_coarse;
	if (terrain_normal_tex_bound) {
		vec2 nxy = texture(terrain_normal_tex, wrap_map_uv(uv)).rg * 2.0 - 1.0;
		nxy *= hillshade_coarse_strength;                       // 运行期再缩放走向强度
		float nz = sqrt(max(1e-4, 1.0 - clamp(dot(nxy, nxy), 0.0, 0.998)));
		N_coarse = vec3(nxy, nz);
	} else {
		float cr = hillshade_coarse_radius;
		float lc = decode_height_rg8(uv - vec2(texel.x * cr, 0.0));
		float rc = decode_height_rg8(uv + vec2(texel.x * cr, 0.0));
		float uc = decode_height_rg8(uv - vec2(0.0, texel.y * cr));
		float dc = decode_height_rg8(uv + vec2(0.0, texel.y * cr));
		float g = hillshade_slope_gain / max(1.0, cr);           // 宽差分 → 单位坡度
		N_coarse = vec3(-(rc - lc) * g, -(dc - uc) * g, 1.0);
	}

	// ── 2. 细节量：性能分档 + biome 门控 ────────────────────────────────
	float detail_amt = 0.0;
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	detail_amt = 0.0;                                            // 低/中端机：仅粗法线
#else
	if (hillshade_detail_enabled && quality >= 1) {
		float qf = (quality >= 2) ? 1.0 : 0.5;                  // q==1 半量、q>=2 全量
		detail_amt = hillshade_detail_strength * terrain_detail_factor(biome) * qf;
		// [shore-normal 2026-06-25] 近岸滩坡：近海陆地(coast_sdf 窄带)单独解门控，让海岸读出滩坡起伏。
		//   biome 是 TerrainType id（B_COAST=1 是水体走 water_pipeline，不入此函数）；近岸陆地多为 B_PLAIN，
		//   其 terrain_detail_factor≈0.12 被压平 → 这里用高程贴海平面的程度补一份 detail，仅薄薄一带、不碰内陆平原。
		if (shore_detail_strength > 0.0) {
			float eh = decode_height_rg8(uv);                   // 1 fetch：本像素高程
			if (eh > sea_level) {
				float band = 1.0 - smoothstep(0.0, shore_band_height, eh - sea_level);  // 贴岸→1，内陆→0
				detail_amt = max(detail_amt, band * shore_detail_strength * qf);
			}
		}
	}
#endif
	if (detail_amt <= 0.0) {
		return normalize(N_coarse);
	}

	// ── 3. 细节法线（局部凹凸）：1-texel 中心差分，作切向扰动叠到粗法线上 ──
	float l1 = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r1 = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u1 = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d1 = decode_height_rg8(uv + vec2(0.0, texel.y));
	float dx = (r1 - l1) * hillshade_slope_gain;
	float dy = (d1 - u1) * hillshade_slope_gain;
	vec3 N = N_coarse + vec3(-dx, -dy, 0.0) * detail_amt;
	return normalize(N);
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
