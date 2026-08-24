// global_adjustments.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   分支后全局视觉调整。
//     1. 羊皮纸 tint + paper grain（sRGB 域 stylized）
//     2. 半 PBR 后期：linear → ACES filmic tonemap → linear_to_srgb
//        （PBR 输出为 linear-HDR；与昼夜开关无关）
//   气候/生态颜色必须在 land pipeline 的 albedo 阶段完成；这里禁止再次乘色，
//   否则会把已经计算完的太阳光与环境光一起染成橙色或绿色。
//
// 调用方（Who）
//   - world_map.gdshader fragment() 的最后一步：
//       COLOR = apply_global_adjustments(
//           col, wp, pixel_noise, dyn_snow, current_temp, moist,
//           dyn_vitality, dyn_valid, cover, land_mask, vegetation_mask);
//   后 7 个参数保留旧热重载 ABI；不得在此重新用于气候乘色。
//
// 依赖（Why）
//   - uniforms.gdshaderinc：parchment_* / paper_grain_strength
//   - common_noise.gdshaderinc：pixel_noise 来源（caller 已在 SETUP 阶段采样）
//   - tonemap.gdshaderinc / material_constants.gdshaderinc：apply_tonemap /
//     linear_to_srgb / USE_LINEAR_LIGHTING
//
// 性能（Cost）
//   - paper grain 复用 pixel_noise.b，无额外 fetch
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

	// ═══════════════════════════════════════════════════════════════════════
	// GLOBAL 2：羊皮纸 tint + paper grain（sRGB 域）
	// ───────────────────────────────────────────────────────────────────────
	// 在 tonemap 之后做，确保 stylized overlay 不被 BRDF 的曝光放大。
	// paper grain 直接复用 pixel_noise.b（v10.noise-pack：3-octave fBM）。
	// ═══════════════════════════════════════════════════════════════════════
	col = mix(col, col * parchment_tint, parchment_strength);
	float grain = pixel_noise.b;
	col *= mix(1.0 - paper_grain_strength, 1.0 + paper_grain_strength, grain);

	return vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
