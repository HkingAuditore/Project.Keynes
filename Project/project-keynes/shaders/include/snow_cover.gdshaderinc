// snow_cover.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：
//   1) apply_snow_cover —— 唯一雪盖入口。集中处理：dynamic atlas 真实
//      snow_cover、坡度削雪、生态遮雪/加雪、厚度色阶、边缘破碎、BLIZZARD 新雪。
//      （2026-05-19 起：不再在 shader 端用温度/海拔重算雪量；CPU SAME_SOURCE。）
//   2) cover_overlay —— 覆盖物轴叠加色（FLOODING / PERMAFROST / GLACIER /
//      PELAGIC_BLOOM 等"原系统没专门处理"的 CoverType 视觉）。
// 调用方：
//   - fragment() STAGE 8 只调用 apply_snow_cover 一次，不再在主 shader 分散计算雪量。
//   - fragment() STAGE 9 调用 cover_overlay，按 cov_axis_strength 与 fbm 抖动后 mix。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：sea_level / B_* / V_* / CV_* / WT_* / 雪与天气 uniform。
//   - common_noise.gdshaderinc：fbm（仅 ±10% cosmetic 抖动，1 次 fbm）。
//   - height.gdshaderinc：decode_height_rg8（坡度削雪）。
//   - weather_front.gdshaderinc：compute_extreme_weather_mask（BLIZZARD 新雪）。
// 性能（PERF）：1 次 fbm + 按需 4 次 height_tex 邻域采样；比旧版省 2 次 fbm。
// ─────────────────────────────────────────────────────────────────────────

// 唯一雪盖入口：返回已叠加雪色后的颜色。
// CPU/GPU SAME_SOURCE：温度/海拔阈值与 map_generator._derived_snow_cover 保持一致。
vec3 apply_snow_cover(
		vec3 base_col,
		int biome,
		int veg,
		float current_temp,
		float elev,
		bool is_water,
		float moisture,
		vec2 wp,
		vec2 uv,
		float dyn_snow,
		float dyn_valid,
		float eco_valid,
		float eco_stress,
		float eco_foliage,
		float river_flow,
		vec4 pixel_noise) {
	if (is_water) return base_col;

	// ─────────────────────────────────────────────────────────────────────
	// 2026-05-19 保守派重构：主体雪量改为完全相信 CPU 写入的 dyn_snow（=
	// cell.snow_cover 经 dyn_atlas_smooth box-blur 后的版本），不再在 shader
	// 端重算 cold_snow / alt_snow / B_SNOW / B_GLACIER 兜底。fbm 仅作为 ±10%
	// 的 cosmetic 抖动，且乘以 dyn_snow 自身——避免在没雪的地方凭空生雪。
	//
	// 修复的病：旧版 `factor = max(cold_snow, alt_snow, biome_fallback)` 后
	// `raw = max(factor, dyn_snow*dyn_valid)` 让 derived 公式压住 CPU 真值，
	// info_panel 显示 cell.snow_cover 但屏幕几乎不响应。
	//
	// SAME_SOURCE：唯一雪量来源是 cell.snow_cover（由 ClimateDailySystem 经
	// map_generator._derived_snow_cover 写入），shader 端不再有"自给自足"路径。
	// 调试入口：debug_force_dyn_snow_only=true 时跳过下面的 fbm 抖动，直接拿
	// dyn_snow 上屏，用于 A/B 验证 CPU 链路是否健康。
	// ─────────────────────────────────────────────────────────────────────

	// 仅作 cosmetic 边缘破碎用——基础雪量来自 CPU dyn_snow。
#ifdef PK_QUALITY_LOW
	float amount_jitter = 1.0;
#else
	float amount_n = fbm(wp * 0.18 + vec2(63.0, -29.0), 1);
	float amount_jitter = mix(0.90, 1.10, amount_n);  // ±10%
#endif

	float dyn_signal = dyn_snow * dyn_valid;
	float raw_snow_signal;
	if (debug_force_dyn_snow_only) {
		// 调试模式：跳过抖动，直接拿 dyn_snow 上屏；和 info_panel 数值严格一致。
		raw_snow_signal = dyn_signal;
	} else {
		// 正常路径：±10% cosmetic jitter，无雪处 dyn_signal=0 自然不出雪。
		raw_snow_signal = clamp(dyn_signal * amount_jitter, 0.0, 1.0);
	}

	// 4) 坡度/生态修正。
	float snow_slope_mag = 0.0;
	bool slope_ready = false;
	float slope_shed = 0.0;
	if (raw_snow_signal > 0.01 && ecology_visual_quality >= 2 && snowline_visual_strength > 0.001) {
		vec2 snow_texel = 1.0 / hm_resolution;
		float sl = decode_height_rg8(uv - vec2(snow_texel.x, 0.0));
		float sr = decode_height_rg8(uv + vec2(snow_texel.x, 0.0));
		float su = decode_height_rg8(uv - vec2(0.0, snow_texel.y));
		float sd = decode_height_rg8(uv + vec2(0.0, snow_texel.y));
		snow_slope_mag = length(vec2(sr - sl, sd - su)) * hillshade_slope_gain;
		slope_ready = true;
		slope_shed = smoothstep(0.42, 1.10, snow_slope_mag) * 0.16;
	}
	float snow_signal = raw_snow_signal;
	snow_signal += eco_valid * eco_stress * smoothstep(0.12, 0.38, raw_snow_signal) * 0.10;
	snow_signal -= eco_valid * eco_foliage * 0.16;
	snow_signal -= slope_shed;
	snow_signal = clamp(snow_signal, 0.0, 1.0);
	float snow_factor = mix(raw_snow_signal, snow_signal, snowline_visual_strength) * dynamic_snow_strength;
	snow_factor = clamp(snow_factor, 0.0, 1.0);
	float river_mask = smoothstep(river_threshold_low * 0.84, river_threshold_high, river_flow);
	float cold_freeze = 1.0 - smoothstep(0.24, 0.46, current_temp);
	float river_freeze_w = river_mask * clamp(max(snow_factor, cold_freeze * dyn_valid * 0.55), 0.0, 1.0);

	// 5) 厚度色阶 + 边缘破碎。
	// 2026-05-21 调整：阈值从 (0.10, 0.85) → (0.05, 0.60)。
	// 原阈值在 dynamic_snow_strength=0.85、eco_foliage 扣减、box blur 稀释三档
	// 软衰减叠加下，会把 cell.snow_cover 真值 ~0.95 的弱雪压成不可见
	// (smoothstep(0.10, 0.85, ~0.40) ≈ 0.36)。降低高门槛让 0.4~0.6 的弱雪
	// 也能形成可见的薄雪覆盖；下限维持低水位（0.05）防止无雪格泛白。
	float thick_low = pixel_noise.g;
	float thick_hi = pixel_noise.r;
	float thickness = clamp(smoothstep(0.05, 0.60, snow_factor) + (thick_low - 0.5) * 0.44, 0.0, 1.0);
	// [需求5 2026-06-19] 雪盖转暖白(原偏冷蓝白 0.82~0.96，与海冰冰蓝白难分)：
	// thin 暖灰白、thick 暖白 → 陆地雪暖白 vs 海面冰冷蓝，二者拉开。
	vec3 thin_snow  = vec3(0.90, 0.89, 0.86);
	vec3 thick_snow = vec3(0.99, 0.985, 0.96);
	vec3 snow_color = mix(thin_snow, thick_snow, thickness);
	snow_color *= mix(0.94, 1.06, thick_hi);
	float edge_noise = pixel_noise.a;
	float edge_lo = mix(0.80, 0.66, snowline_visual_strength);
	float edge_hi = mix(1.18, 1.34, snowline_visual_strength);
	float snow_mix = clamp(snow_factor * mix(edge_lo, edge_hi, edge_noise), 0.0, 1.0);
	snow_mix *= 1.0 - river_freeze_w * 0.86;
	vec3 col = mix(base_col, snow_color, snow_mix);

	// 6) BLIZZARD 新雪增强也收敛在雪函数内，主 shader 不再另起分支。
#ifndef PK_QUALITY_LOW
	if (extreme_weather_ground_effect_enabled && weather_front_count > 0) {
		float blizz_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
		if (blizz_mask > 0.001) {
			if (!slope_ready) {
				vec2 texel = 1.0 / hm_resolution;
				float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
				float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
				float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
				float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
				snow_slope_mag = length(vec2(hr - hl, hd - hu)) * hillshade_slope_gain;
			}
			float slope_w = 1.0 - smoothstep(0.35, 0.85, snow_slope_mag);
			float veg_w = 1.0;
			if (veg == V_TAIGA
					|| veg == V_TEMPERATE_DECIDUOUS
					|| veg == V_TEMPERATE_CONIFER
					|| veg == V_TROPICAL_RAINFOREST
					|| veg == V_SUBTROPICAL_FOREST) {
				veg_w = 0.35;
			} else if (veg == V_BOREAL_SHRUB
					|| veg == V_MEDITERRANEAN_SHRUB
					|| veg == V_TROPICAL_DRY_FOREST) {
				veg_w = 0.65;
			}
			float w = blizz_mask * slope_w * veg_w;
			col = mix(col, vec3(0.97, 0.98, 1.00), clamp(w, 0.0, 0.92));
		}
	}
	if (river_freeze_w > 0.001) {
		vec3 river_ice = mix(vec3(0.58, 0.76, 0.88), vec3(0.84, 0.93, 0.98), clamp(snow_factor + pixel_noise.r * 0.18, 0.0, 1.0));
		col = mix(col, river_ice, clamp(river_freeze_w * 0.88, 0.0, 0.92));
	}
#endif
	return col;
}


// ─── Milestone 2：覆盖物轴叠加 ──────────────────────────────────────────
// SNOW/SEA_ICE/GLACIER 已经被 dynamic_snow / biome 主路径处理，这里只补
// "原系统没专门处理"的两个：FLOODING（水蓝叠加）+ PERMAFROST（灰青微暗）。
// 2026-05-18 P2-A：PERMAFROST 从 0.10 → 0.40（让"永冻土"可见）；
// GLACIER 从 0.20 → 0.50（让冰川覆盖明显厚重）；
// FLOODING 从 0.45 → 0.58（让洪水淹没区在 saturate 后更接近"水蓝"而不是被冲淡）。
vec4 cover_overlay(int cover) {
	if (cover == CV_FLOODING)   return vec4(0.30, 0.45, 0.62, 0.58);
	if (cover == CV_PERMAFROST) return vec4(0.74, 0.78, 0.82, 0.40);
	if (cover == CV_GLACIER)    return vec4(0.86, 0.92, 0.96, 0.50);
	// Systemic Ocean Currents：远洋华深海富营养标记——淡绿 tint，表示浮游生物繁殖。
	// 不覆盖流纹动画，仅在最后混色中加一层成环境光影响。
	if (cover == CV_PELAGIC_BLOOM) return vec4(0.28, 0.58, 0.42, 0.22);
	return vec4(0.0);
}
