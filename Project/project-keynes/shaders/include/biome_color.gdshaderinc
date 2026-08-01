// biome_color.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：地表"基础设色"——海陆 hypsometric 色阶（水深 / 高程映射到 RGB）+ 深海
//        三层色调修饰（current / latitude / abyss）+ 按 biome 的色相调制。
//        这是 fragment 着色的第一阶段，所有后续 tint / 雪 / 天气都在 col 上叠加。
// 调用方：
//   - hypsometric_tint(elev, is_water) → fragment 顶部统一调用，生成 col 初始值。
//   - water_depth_gradient(offshore_t, elev) → 水面分支多处复用（LAKE/REEF/KELP/ICE
//     的基色，以及 estuary plume）。
//   - deep_ocean_current_tint / _latitude_tint / _abyss_tint → 水面"Deep Ocean
//     Layered Color 整合层"在 gyre patch 之后、LAKE/REEF/KELP/ICE 特征之前调用。
//   - biome_hue_modulate(col, biome) → 陆地分支在 hypsometric 之后立即调用。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：sea_level / color_* 色阶 / deep_ocean_* 修饰 /
//     ocean_current_enabled / B_* 常量
// 性能（PERF）：纯 ALU，无纹理 / 噪声采样。水面像素会调用 hypsometric_tint 一次 +
//                若 deep ocean tint 启用则三函数各一次，整体可忽略。
// ─────────────────────────────────────────────────────────────────────────

// ─── 等高线设色（hypsometric tint） ───────────────────────────────────────
// 注意：用 is_water (biome 决定) 而不是 elev 来分支海陆，否则会因为 height_tex
// 的 barycentric 平滑插值在 hex 边界处把"水 hex 但 elev 偶尔越过 sea_level"
// 的像素画成陆地——结果就是海岸完全脱离 hex 形状，永远平滑曲线。
vec3 water_depth_gradient(float offshore_t, float elev) {
	float offshore_s = smoothstep(0.00, 1.00, clamp(offshore_t, 0.0, 1.0));
	float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
	float near_surface = 1.0 - smoothstep(0.04, 0.78, depth_t);
	float contrast_t = clamp((deep_ocean_contrast - 0.5) / 2.5, 0.0, 1.0);

	// Depth bands: shore -> shelf -> mid sea -> basin -> abyss.
	// 让浅海、中海、深海在亮度和色温上各有一档，不再像单一蓝块。
	float shelf_t = smoothstep(0.04, 0.30, depth_t);
	float mid_t = smoothstep(0.18, 0.54, depth_t);
	float basin_t = smoothstep(0.42, 0.80, depth_t);
	float abyss_t = smoothstep(0.72, 1.00, depth_t);

	vec3 coast_col = mix(color_shallow, color_coast_water, 0.82) * vec3(1.00, 1.05, 1.03);
	vec3 shelf_col = mix(color_coast_water, color_mid_ocean, 0.30) * vec3(0.98, 1.04, 1.06);
	vec3 mid_col = mix(color_mid_ocean, color_deep_ocean, 0.34) * vec3(0.96, 1.02, 1.08);
	float richness_t = clamp(deep_ocean_color_richness, 0.0, 1.0);
	vec3 basin_tint = mix(vec3(0.94, 1.00, 1.08), vec3(0.86, 0.96, 1.14), richness_t);
	vec3 basin_col = mix(color_mid_ocean, color_deep_ocean, 0.68) * basin_tint;
	vec3 abyss_warm = color_deep_ocean * vec3(0.96, 0.99, 1.08);
	vec3 abyss_cool = color_deep_ocean * mix(vec3(0.88, 0.93, 1.08), vec3(0.82, 0.88, 1.12), richness_t);
	vec3 abyss_col = mix(abyss_warm, abyss_cool, contrast_t);

	vec3 ocean_col = coast_col;
	ocean_col = mix(ocean_col, shelf_col, shelf_t * 0.86);
	ocean_col = mix(ocean_col, mid_col, mid_t * 0.74);
	ocean_col = mix(ocean_col, basin_col, basin_t * 0.70);
	ocean_col = mix(ocean_col, abyss_col, abyss_t * 0.62);

	// 轻微色温漂移保留大尺度层次，但不把深水推成一整片纯蓝。
	vec3 blue_shift = mix(vec3(0.99, 1.02, 1.05), vec3(0.88, 0.95, 1.10), basin_t);
	vec3 violet_shift = mix(vec3(1.0), vec3(0.95, 0.92, 1.12), abyss_t);
	ocean_col *= mix(vec3(1.0), blue_shift, 0.10 * smoothstep(0.20, 1.0, offshore_s));
	ocean_col *= mix(vec3(1.0), violet_shift, 0.08 * abyss_t);

	vec3 shallow_lift = mix(shelf_col, coast_col, near_surface);
	vec3 result = mix(ocean_col, shallow_lift, (1.0 - smoothstep(0.10, 0.42, offshore_s)) * near_surface * 0.40);

	// Safety band: gently pull extreme results back toward the deep-ocean base
	// so newly-widened palette never drifts into a cartoony alien hue. Scales
	// with richness_t so richness==0 is a no-op (旧视觉完全保留).
	float pullback = 0.12 * richness_t * smoothstep(0.45, 1.0, offshore_s);
	result = mix(result, color_deep_ocean, pullback);
	return result;
}

// ─── Deep Ocean Layered Color 辅助函数 ──────────────────────────────────
// Current tint: warm/cool bias along ocean currents. UV.y points "down" while
// lat_signed is already oriented (north positive). A current flowing from low
// to high |latitude| (warm current) biases toward warm aqua; the reverse
// (cold current) biases toward cool cyan. Zero flow → identity.
vec3 deep_ocean_current_tint(vec2 oc, float lat_signed, float flow_mag) {
	if (!ocean_current_enabled) {
		return vec3(1.0);
	}
	if (flow_mag < 0.05) {
		return vec3(1.0);
	}
	// In Godot UV space y grows downward. North (lat_signed > 0) corresponds
	// to decreasing UV.y, hence a current whose UV.y component moves *against*
	// the hemisphere sign is heading poleward (warm current). The product
	// (-oc.y * lat_signed) captures this: positive → warm, negative → cold.
	float dir = clamp(-oc.y * lat_signed * 4.0, -1.0, 1.0);
	// Open Ocean Color Rebalance：暖/寒流 ±6% 的方向系数与新去饱和 base palette
	// 协同——在 strength 0.60 + cap 0.85 之下总幅度约 ±5%，flow_mag>0.2 区域仍
	// 落在需求饱和度区间 [0.40, 0.62] 内，无需调整 warm/cold 数值。
	vec3 warm = vec3(1.04, 1.02, 0.94);
	vec3 cold = vec3(0.94, 1.00, 1.08);
	vec3 tint = mix(vec3(1.0), (dir >= 0.0) ? warm : cold, abs(dir));
	float amp = clamp(deep_ocean_current_tint_strength * deep_ocean_color_richness, 0.0, 1.0);
	// Also scale by actual flow magnitude so weak eddies don't get loud tints.
	amp *= smoothstep(0.05, 0.45, flow_mag);
	// Cap overall excursion at ~±15%.
	return mix(vec3(1.0), tint, amp * 0.85);
}

// Latitude tint: tropical teal-green, temperate neutral, polar cool-cyan.
// current_temp (in [~0, ~1]) nudges the result slightly warmer when high so
// seasonal swings bleed into ocean color naturally.
vec3 deep_ocean_latitude_tint(float lat_signed, float current_temp) {
	float abs_lat = clamp(abs(lat_signed), 0.0, 1.0);
	float tropical_w = 1.0 - smoothstep(0.00, 0.35, abs_lat);
	float polar_w    = smoothstep(0.55, 0.95, abs_lat);
	// Open Ocean Color Rebalance：扩大热带 / 极地色相分离，让低纬偏青绿、
	// 高纬偏冷青在新去饱和 base 上仍达成 Δhue ≥ 8°。
	// 旧值 / 新值 / 视觉影响：
	//   tropical (0.92, 1.08, 1.04) → (0.88, 1.10, 1.00)  低纬更明显偏青绿
	//   polar    (0.96, 1.02, 1.12) → (0.96, 1.00, 1.16)  高纬更明显偏冷青
	vec3 tropical = vec3(0.88, 1.10, 1.00);
	vec3 polar    = vec3(0.96, 1.00, 1.16);
	vec3 tint = mix(vec3(1.0), tropical, tropical_w);
	tint = mix(tint, polar, polar_w);
	// Temperature second-order nudge: warmer → slightly warmer tint (up to ±3%).
	float temp_bias = clamp(current_temp - 0.5, -0.5, 0.5);
	vec3 temp_tint = vec3(1.0 + temp_bias * 0.06, 1.0, 1.0 - temp_bias * 0.06);
	tint *= temp_tint;
	float amp = clamp(deep_ocean_latitude_tint_strength * deep_ocean_color_richness, 0.0, 1.0);
	return mix(vec3(1.0), tint, amp);
}

// Abyss tint: darken + subtle blue/violet bias on the deepest water.
vec3 deep_ocean_abyss_tint(float offshore_depth) {
	float abyss_w = smoothstep(0.72, 1.00, clamp(offshore_depth, 0.0, 1.0));
	// Open Ocean Color Rebalance：把外层 *0.90 抬到 *0.96，避免 abyss 段
	// 在与 water_depth_gradient 内的 abyss_col + blue_shift 叠乘后变成"灰蓝压抑"。
	// 旧值 / 新值 / 视觉影响：vec3(0.82,0.90,1.08)*0.90 → vec3(0.82,0.90,1.08)*0.96
	// abyss 段相对 basin 仍下降但 ΔV 由 ~22% 收敛到 ~12%，保留冷偏方向不变。
	vec3 base_abyss_tint = vec3(0.82, 0.90, 1.08) * 0.96;
	vec3 tint = mix(vec3(1.0), base_abyss_tint, abyss_w);
	float contrast_scale = clamp(deep_ocean_contrast / 0.96, 0.6, 1.4);
	float amp = clamp(deep_ocean_abyss_tint_strength * deep_ocean_color_richness * contrast_scale, 0.0, 1.2);
	return mix(vec3(1.0), tint, clamp(amp, 0.0, 1.0));
}

vec3 hypsometric_tint(float elev, bool is_water) {
	if (is_water) {
		float depth_t = 1.0 - clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		float offshore_t = smoothstep(0.0, 1.0, depth_t);
		return water_depth_gradient(offshore_t, elev);
	}
	float t = clamp((elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	if (t < 0.10) return mix(color_beach, color_lowland, t / 0.10);
	// v10.2：低地→丘陵→山地段全部扩宽，让更多 cell 落在"中等海拔"色阶
	// 而不是被推到 mountain/peak/snow 顶端
	if (t < 0.55) return mix(color_lowland, color_hill, (t - 0.10) / 0.45);
	if (t < 0.85) return mix(color_hill, color_mountain, (t - 0.55) / 0.30);
	// 最高海拔只给冷岩底色；真正积雪由动态 snow_factor 叠加，避免高山底图终年锁白。
	if (t < 0.985) return mix(color_mountain, color_peak, (t - 0.85) / 0.135);
	return color_peak * vec3(1.04, 1.05, 1.06);
}

// ─── biome 色相调制（高度负责亮度，biome 负责色相） ──────────────────────

vec3 biome_hue_modulate(vec3 base, int biome) {
	// 少一点统一绿，多一点橄榄、金黄、冷青和岩灰。
	if (biome == B_FOREST)    return base * vec3(0.74, 0.96, 0.68);
	if (biome == B_GRASSLAND) return base * vec3(0.95, 1.02, 0.78);
	if (biome == B_DESERT)    return base * vec3(1.30, 0.96, 0.58);
	if (biome == B_TUNDRA)    return base * vec3(0.88, 0.96, 1.05);
	if (biome == B_SNOW)      return base * vec3(0.88, 0.92, 0.98);
	if (biome == B_MOUNTAIN)  return base * vec3(1.00, 0.96, 0.96);
	if (biome == B_HILL)      return base * vec3(1.06, 1.00, 0.92);
	if (biome == B_SWAMP)     return base * vec3(0.64, 0.86, 0.72);
	// Phase 10：Whittaker 4
	// JUNGLE：极深饱和绿（雨林郁闭）
	if (biome == B_JUNGLE)    return base * vec3(0.55, 0.93, 0.64);
	if (biome == B_SAVANNA)   return base * vec3(1.12, 1.04, 0.60);
	if (biome == B_TAIGA)     return base * vec3(0.64, 0.91, 0.81);
	if (biome == B_STEPPE)    return base * vec3(1.00, 1.06, 0.76);
	// Phase 11
	// SHRUBLAND：灰绿带土黄（地中海干性灌丛）
	if (biome == B_SHRUBLAND) return base * vec3(1.04, 0.98, 0.82);
	if (biome == B_MANGROVE)  return base * vec3(0.63, 0.89, 0.77);
	if (biome == B_GLACIER)   return base * vec3(0.94, 0.99, 1.04);
	if (biome == B_DELTA)     return base * vec3(0.85, 0.98, 0.76);
	if (biome == B_OASIS)     return base * vec3(0.69, 1.01, 0.69);
	if (biome == B_SALT_FLAT) return base * vec3(1.16, 1.14, 0.94);
	if (biome == B_BADLANDS)  return base * vec3(1.26, 0.84, 0.58);
	// terrain-overhaul 新增地形配色
	// COLD_DESERT：冷灰黄（寒漠，比热沙漠更灰、偏冷）
	if (biome == B_COLD_DESERT) return base * vec3(1.10, 1.00, 0.84);
	if (biome == B_CHAPARRAL)   return base * vec3(1.04, 1.02, 0.76);
	if (biome == B_MOOR)        return base * vec3(0.84, 0.94, 0.72);
	if (biome == B_FLOODPLAIN)  return base * vec3(0.84, 0.99, 0.75);
	if (biome == B_MESA)        return base * vec3(1.28, 0.90, 0.62);
	return base;
}
