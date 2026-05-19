// tonemap.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   颜色空间转换 + tonemap：
//     - srgb_to_linear / linear_to_srgb：BRDF 输入输出的 gamma 处理
//     - tonemap_filmic（ACES Narkowicz 2015 近似）：默认主路径
//     - tonemap_reinhard_legacy：保留旧 x/(1+k·x) 用于 USE_PBR_BRDF=0 回滚
//
// 调用方（Who）
//   - global_adjustments.gdshaderinc 末端：apply_global_adjustments 把 BRDF 输出
//     从 linear-HDR 压回 sRGB-LDR
//   - land_pipeline / water_pipeline 进入 evaluate_brdf 前：base_color srgb→linear
//
// 依赖（Why）
//   仅依赖 material_constants（USE_FILMIC_TONEMAP / ACES_* / REINHARD_K_LEGACY）。
//
// 性能（Cost）
//   srgb↔linear 是 fast pow approx（mix branch），约 5 ALU/调用。
//   tonemap_filmic 是 6 mul/add，1 div，1 saturate；tonemap_reinhard 是 1 div。
//   全部纯 ALU，无纹理 fetch。
// ─────────────────────────────────────────────────────────────────────────

// ─── srgb ↔ linear（fast approx，pow(x, 2.2) 与其逆） ───────────────────
// 精确版用 GL_SRGB texture 即可避免；这里给出 ALU 版本供手写颜色字面量使用。
vec3 srgb_to_linear(vec3 c) {
	// pow(c, 2.2) 的 fast 近似（最大误差 0.4%，足够风格化使用）
	return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

vec3 linear_to_srgb(vec3 c) {
	// 反向近似
	c = max(c, vec3(0.0));
	vec3 s1 = sqrt(c);
	vec3 s2 = sqrt(s1);
	vec3 s3 = sqrt(s2);
	return 0.662002687 * s1 + 0.684122060 * s2 - 0.323583601 * s3 - 0.0225411470 * c;
}

// ─── ACES Approximation（Narkowicz 2015） ──────────────────────────────
// fit: (x*(A*x + B)) / (x*(C*x + D) + E)
vec3 tonemap_filmic_aces(vec3 x) {
	return clamp(
		(x * (ACES_A * x + ACES_B)) / (x * (ACES_C * x + ACES_D) + ACES_E),
		vec3(0.0), vec3(1.0));
}

// ─── Reinhard Legacy（v9 行为兼容） ────────────────────────────────────
// 旧 land/water 都是 x / (1 + 0.35*x)
vec3 tonemap_reinhard_legacy(vec3 x) {
	return x / (1.0 + x * REINHARD_K_LEGACY);
}

// ─── 主入口：根据 material_constants 开关分派 ──────────────────────────
vec3 apply_tonemap(vec3 hdr) {
	hdr *= TONEMAP_EXPOSURE_BIAS;
	if (USE_FILMIC_TONEMAP) {
		return tonemap_filmic_aces(hdr);
	}
	return tonemap_reinhard_legacy(hdr);
}
