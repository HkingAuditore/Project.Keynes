// global_adjustments.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   分支后全局视觉调整。
//     1. 羊皮纸 tint + paper grain（sRGB 域 stylized）
//     2. 半 PBR 后期：linear → ACES filmic tonemap → linear_to_srgb
//        （PBR 输出为 linear-HDR；与昼夜开关无关）
//     3. 季节过渡 dissolve alpha
//
// 调用方（Who）
//   - world_map.gdshader fragment() 的最后一步：
//       COLOR = apply_global_adjustments(col, wp, pixel_noise, dyn_snow,
//           current_temp, moist, dyn_vitality, dyn_valid, cover,
//           land_mask, vegetation_mask);
//
// 依赖（Why）
//   - uniforms.gdshaderinc：parchment_* / paper_grain_strength / season_*
//   - common_noise.gdshaderinc：pixel_noise 来源（caller 已在 SETUP 阶段采样）
//   - tonemap.gdshaderinc / material_constants.gdshaderinc：apply_tonemap /
//     linear_to_srgb / USE_LINEAR_LIGHTING
//
// 性能（Cost）
//   - paper grain 复用 pixel_noise.b，无额外 fetch
//   - dissolve overlay 现在用 pixel_noise.a 派生（旧实现用一次 fbm，节省 1 次 fetch）
//   - tonemap 仅在 USE_LINEAR_LIGHTING=true 时启用（约 6 ALU）
// ─────────────────────────────────────────────────────────────────────────

vec4 apply_global_adjustments(
		vec3 col,
		vec2 wp,
		vec4 pixel_noise,
		float dyn_snow,
		float current_temp,
		float moisture,
		float vitality,
		float dyn_valid,
		int cover,
		float land_mask,
		float vegetation_mask) {
	// ═══════════════════════════════════════════════════════════════════════
	// GLOBAL 1：半 PBR 后期 —— Tonemap + linear→sRGB
	// ───────────────────────────────────────────────────────────────────────
	// land/water pipeline 在 USE_LINEAR_LIGHTING=true 时输出 linear-HDR 域；
	// 这里统一收口做 tonemap + linear→sRGB，避免羊皮纸 / paper grain 再被
	// gamma 二次扭曲。day_night_enabled=false 只是把 earth_daylight 退化为永昼；
	// PBR 输出仍是 linear-HDR，必须继续 tonemap，避免关闭昼夜后整图过曝。
	// ═══════════════════════════════════════════════════════════════════════
	if (USE_LINEAR_LIGHTING && USE_PBR_BRDF) {
		col = apply_tonemap(col);   // apply_tonemap 内部已乘 TONEMAP_EXPOSURE_BIAS
		col = linear_to_srgb(col);
	}

	// GLOBAL 1.5：tonemap 后的气候语义分级，确保常见区间不会被 BRDF/ACES 压平。
	if (land_mask > 0.5 && dyn_valid > 0.5) {
		float grade_visibility = 1.0 - smoothstep(0.08, 0.42, dyn_snow);
		if (cover == CV_GLACIER || cover == CV_PERMAFROST) {
			grade_visibility *= 0.18;
		}
		float temp_axis = clamp((current_temp - 0.50) * 4.0, -1.0, 1.0);
		float temp_w = pow(abs(temp_axis), 0.72)
				* 0.46 * temperature_visual_strength * grade_visibility;
		vec3 cold_grade = vec3(0.72, 0.87, 1.24);
		vec3 warm_grade = vec3(1.24, 0.88, 0.58);
		col *= mix(vec3(1.0), (temp_axis < 0.0) ? cold_grade : warm_grade,
				clamp(temp_w, 0.0, 0.72));

		float moist_axis = clamp((moisture - 0.48) * 3.8, -1.0, 1.0);
		float moist_w = pow(abs(moist_axis), 0.76)
				* 0.28 * moisture_visual_strength * grade_visibility;
		vec3 dry_grade = vec3(1.20, 0.94, 0.62);
		vec3 wet_grade = vec3(0.80, 1.06, 0.88);
		col *= mix(vec3(1.0), (moist_axis < 0.0) ? dry_grade : wet_grade,
				clamp(moist_w, 0.0, 0.70));

		if (vegetation_mask > 0.5) {
			float decline_w = 1.0 - smoothstep(0.62, 0.88, vitality);
			float healthy_w = smoothstep(0.82, 0.98, vitality);
			float dieback_w = 1.0 - smoothstep(0.12, 0.46, vitality);
			float patch_amp = mix(0.86, 1.14, pixel_noise.g);
			col *= mix(vec3(1.0), vec3(1.24, 0.78, 0.42),
					clamp(decline_w * 0.50 * vitality_visual_strength * patch_amp
					* grade_visibility, 0.0, 0.72));
			col *= mix(vec3(1.0), vec3(0.84, 1.06, 0.82),
					clamp(healthy_w * 0.12 * vitality_visual_strength * patch_amp
					* grade_visibility, 0.0, 0.20));
			float gray = dot(col, vec3(0.299, 0.587, 0.114));
			col = mix(col, vec3(gray) * vec3(0.78, 0.75, 0.66),
					clamp(dieback_w * 0.46 * vitality_visual_strength
					* grade_visibility, 0.0, 0.62));
		}
	}

	// ═══════════════════════════════════════════════════════════════════════
	// GLOBAL 2：羊皮纸 tint + paper grain（sRGB 域）
	// ───────────────────────────────────────────────────────────────────────
	// 在 tonemap 之后做，确保 stylized overlay 不被 BRDF 的曝光放大。
	// paper grain 直接复用 pixel_noise.b（v10.noise-pack：3-octave fBM）。
	// ═══════════════════════════════════════════════════════════════════════
	col = mix(col, col * parchment_tint, parchment_strength);
	float grain = pixel_noise.b;
	col *= mix(1.0 - paper_grain_strength, 1.0 + paper_grain_strength, grain);

	// ═══════════════════════════════════════════════════════════════════════
	// GLOBAL 3：季节过渡 dissolve alpha
	// ───────────────────────────────────────────────────────────────────────
	// 旧实现：fbm(wp * 0.035 + ...) ——每像素再做一次纹理 fetch。
	// 新实现：直接用 pixel_noise.a（4-octave fBM 预积分）作为 dissolve_noise。
	// 频域和相位与原 fbm 不完全相同，但 dissolve 是 stylized 视觉过渡，本身就
	// 不要求"每个相邻季节都是同一种 fbm"——分辨率与 pattern 风味基本一致，
	// 节省 1 次 fetch / 像素。
	// ═══════════════════════════════════════════════════════════════════════
	float alpha = 1.0;
	if (season_transition_overlay) {
		float dissolve_noise = pixel_noise.a;
		float edge = clamp(season_transition_progress, 0.0, 1.0);
		float soft = max(season_transition_softness, 0.001);
		float threshold = 1.0 - edge;
		alpha = 1.0 - smoothstep(threshold - soft, threshold + soft, dissolve_noise);
		alpha *= 1.0 - smoothstep(0.88, 1.0, edge);
		// 过渡层只负责旧地表颜色；当前雪盖由主层 dyn_lut.B 绘制，雪区不叠旧层。
		alpha *= 1.0 - smoothstep(0.08, 0.22, dyn_snow);
	}

	return vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
}
