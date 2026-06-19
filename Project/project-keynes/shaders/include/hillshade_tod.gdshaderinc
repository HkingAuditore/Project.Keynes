// hillshade_tod.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：地形光照的全部 helper。两条独立路径并存，由 caller 在 fragment 内按
//        day_night_enabled 选择：
//   【路径 A — 经典双光源 hillshading】
//     - hillshading_two_lights(uv) → key + fill 两方向漫反射近似，结果会被
//       fragment 直接乘到 col 上做"陆地阴影"。
//   【路径 B — 旧版风格化日夜（legacy，仅在 day_night_enabled=false 时用）】
//     - get_sun_dir / get_sky_tint / get_day_brightness / apply_day_night：
//       用 day_phase ∈ [0,1] 直接派生太阳位置 + 天色 tint + 整体亮度。
//   【路径 C — 任务 3 TOD 驱动的 PBR（主路径，day_night_enabled=true）】
//     - compute_terrain_normal(uv, quality)：从 height_tex Sobel/4-tap 算 N。
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
//   6. day_night_enabled=false 时 caller 跳过本函数，回退到 apply_day_night 路径
//
// 返回：PBR 染色后的 RGB（caller 负责 clamp）。
// 从 height_tex 采样得到 tangent-space 法线（Sobel 3x3 或 4-tap 中心差分）
vec3 compute_terrain_normal(vec2 uv, int quality) {
	vec2 texel = 1.0 / hm_resolution;
	// 60 FPS 优化（2026-06-15）：mobile 三档变体
	// LOW: 完全平面法线（0 sample）→ 无 hillshade 立体感
	// MID: 2-tap 水平 + 0 垂直简化法线（2 sample）→ 仅 X 方向阴影
	// HIGH: 4-tap 完整中心差分（4 sample）= 桌面 q=0 同
#ifdef MOBILE_QUALITY_LOW
	return vec3(0.0, 0.0, 1.0);
#elif defined(MOBILE_QUALITY_MID)
	float l0 = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r0 = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float dx0 = (r0 - l0) * hillshade_slope_gain;
	return normalize(vec3(-dx0, 0.0, 1.0));
#else
	if (quality <= 2) {
		// 默认桌面质量也走 4-tap。Sobel 8-tap 保留给未来更高质量档。
		float l0 = decode_height_rg8(uv - vec2(texel.x, 0.0));
		float r0 = decode_height_rg8(uv + vec2(texel.x, 0.0));
		float u0 = decode_height_rg8(uv - vec2(0.0, texel.y));
		float d0 = decode_height_rg8(uv + vec2(0.0, texel.y));
		float dx0 = (r0 - l0) * hillshade_slope_gain;
		float dy0 = (d0 - u0) * hillshade_slope_gain;
		return normalize(vec3(-dx0, -dy0, 1.0));
	}
	// 高质：Sobel 3x3（8 采样，方向性更稳）
	float hLU = decode_height_rg8(uv + vec2(-texel.x, -texel.y));
	float hU2 = decode_height_rg8(uv + vec2( 0.0,     -texel.y));
	float hRU = decode_height_rg8(uv + vec2( texel.x, -texel.y));
	float hL2 = decode_height_rg8(uv + vec2(-texel.x,  0.0));
	float hR2 = decode_height_rg8(uv + vec2( texel.x,  0.0));
	float hLD = decode_height_rg8(uv + vec2(-texel.x,  texel.y));
	float hD2 = decode_height_rg8(uv + vec2( 0.0,      texel.y));
	float hRD = decode_height_rg8(uv + vec2( texel.x,  texel.y));
	// Sobel X：[[-1,0,1],[-2,0,2],[-1,0,1]] / 8；Y 
	float gx = ((hRU + 2.0 * hR2 + hRD) - (hLU + 2.0 * hL2 + hLD)) * 0.125;
	float gy = ((hLD + 2.0 * hD2 + hRD) - (hLU + 2.0 * hU2 + hRU)) * 0.125;
	gx *= hillshade_slope_gain;
	gy *= hillshade_slope_gain;
	return normalize(vec3(-gx, -gy, 1.0));
#endif
}

// 按 biome 查表粗糙度（需求 3.3）：雪/冰光滑、沙中等、森林/草原粗糙
float biome_roughness(int biome) {
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_SEA_ICE) return 0.22;
	if (biome == B_DESERT || biome == B_SALT_FLAT) return 0.58;
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) return 0.88;
	if (biome == B_GRASSLAND || biome == B_SAVANNA || biome == B_STEPPE) return 0.78;
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS) return 0.65;
	return 0.55;
}

// ─── [cylindrical-earth-daylight] 逐像素经纬度日照（晨昏线） ─────────────
// 用球面天文公式算每个像素当前的太阳高度角 sin(h)：
//   sin(h) = sin(lat)·sin(δ) + cos(lat)·cos(δ)·cos(H)
//   H(时角) = 经度 − 正午经度(subsolar)；δ = 赤纬(季节)。
// 关键：lat_rad / decl 与 climate_season.compute_insolation_shader 完全同源，
//   所以"长昼半球"必然等于"高日照(暖)半球"，日照与气候自洽。
// 经度 lon=uv.x·TAU 是周期量 → cos(H) 在 uv.x=0 与 1 处相等 → 东西晨昏线无缝衔接
//   （这就是问题 3 的渲染层经度环绕）。|lat| 高且冬季 → sinh 恒负=极夜，夏季→极昼，自然涌现。
float compute_solar_elevation(vec2 uv, float lat_signed) {
	float TAU_ = 6.2831853;
	float year_progress = mod(season_phase, 4.0) * 0.25;
	// 与 compute_insolation_shader 的 subsolar 同式：phase=0 → +tilt。
	float decl = axial_tilt_rad * cos(TAU_ * year_progress);
	float lat_rad = lat_signed * 1.5707963;            // 与 insolation lat_rad 同源
	float lon = uv.x * TAU_;                            // 经度（周期）→ 东西无缝
	float subsolar_lon = day_phase * TAU_;             // 正午经度随视觉昼夜相位绕圈
	float H = lon - subsolar_lon;
	return sin(lat_rad) * sin(decl) + cos(lat_rad) * cos(decl) * cos(H);
}

// sinh → local_day ∈ [0,1]：1=白昼 0=夜晚 (0,1)=晨昏过渡带（band 控柔度）。
float solar_day_factor(float sinh) {
	return smoothstep(-0.14, 0.14, sinh);
}

// 主入口：TOD 驱动的 PBR。is_water 时让上层直接跳过。
vec3 apply_tod_pbr(vec3 albedo, vec2 uv, int biome, int quality) {
	// 1. 法线
	vec3 N = compute_terrain_normal(uv, quality);
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
