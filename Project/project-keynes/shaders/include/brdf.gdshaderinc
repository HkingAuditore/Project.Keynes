// brdf.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   Stylized 半 PBR 光照核心：
//     - LightingContext struct ：抽出 sun/ambient/exposure/hillshade/night 到一个容器
//     - 主路径 (USE_PBR_BRDF=1) ：Cook-Torrance 微表面（GGX D + Smith G + Schlick F）
//                                + 能量守恒 (kD = (1-F)·(1-metallic))
//                                + 线性空间运算 + ACES filmic tonemap
//     - Legacy 路径 (USE_PBR_BRDF=0) ：v9 Blinn-Phong + Reinhard，单点回退用
//     - hillshading 二光源旁路：保留为 legacy/debug fallback；昼夜关闭时仍走永昼 PBR
//
// 调用方（Who）
//   - land_pipeline.gdshaderinc::shade_land_surface
//   - water_pipeline.gdshaderinc::shade_water_surface
//   - 各自 caller 先构造 LightingContext，然后调 evaluate_brdf(s, lc)
//
// 依赖（Why）
//   - surface_params.gdshaderinc：SurfaceParams
//   - material_constants.gdshaderinc：USE_PBR_BRDF / VIEW_DIR_TOP_DOWN /
//       PI / F0_DIELECTRIC_DEFAULT / ROUGHNESS_MIN/MAX /
//       AMBIENT_FLOOR_LAND/WATER / HILLSHADE_BASE_LIFT / NIGHT_BRIGHTNESS_FLOOR /
//       SUN_INTENSITY_GAIN / GLOSS_*_LEGACY / SPEC_*_LEGACY
//   - tonemap.gdshaderinc：srgb_to_linear / linear_to_srgb / apply_tonemap
//   - uniforms.gdshaderinc：tod_sun_dir / tod_sun_color / tod_ambient_color /
//       tod_exposure / tod_night_factor / day_night_enabled / hillshade_*
//
// 性能（Cost）
//   evaluate_brdf 主路径：~32 ALU（D_GGX 6 + G_Smith 8 + F_Schlick 5 + 杂项 13）
//   evaluate_brdf_legacy：~14 ALU（与 v9 一致）
//   evaluate_hillshade_only：~10 ALU
//   全部纯 ALU，无纹理 fetch；编译器会按 USE_PBR_BRDF 死代码消除其中一条。
// ─────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════
// 一、LightingContext：所有 BRDF 输入收口
// ═══════════════════════════════════════════════════════════════════════
//   把 land/water 各自重复构造的 L/V/sun_color/ambient_color/exposure/...
//   收成统一的 struct，BRDF 内部不再直接访问 uniform，便于将来：
//     - 加 IBL：把 ibl_diffuse / ibl_specular 字段加入即可
//     - 多光源：扩展为数组（GLSL 支持固定大小数组）
//     - 阴影：加 shadow_factor 字段
// ─────────────────────────────────────────────────────────────────────
struct LightingContext {
	vec3 L;                  // 主光方向，世界空间，已归一化
	vec3 V;                  // 观察方向，2D top-down 默认 VIEW_DIR_TOP_DOWN
	vec3 sun_color_linear;   // 主光辐射度（已 srgb_to_linear）
	vec3 ambient_color_linear; // 环境光（已 srgb_to_linear）
	float exposure;          // tod_exposure
	float night_factor;      // tod_night_factor [0,1]
	float hillshade;         // hillshade_strength [0,1]，作为 stylized 乘子
	float ambient_floor;     // 环境光下限（land=AMBIENT_FLOOR_LAND, water=AMBIENT_FLOOR_WATER）
	// TODO[future-IBL]: vec3 ibl_diffuse; vec3 ibl_specular;
	// TODO[future-shadow]: float direct_shadow;
};

// ─── 构造：从 uniforms 与一个 ambient_floor 推导 LightingContext ────────
// [cylindrical-earth-daylight] 逐像素经纬度日照（晨昏线）驱动昼夜：昼夜系数 / 昼晨昏色
//   统一由 earth_daylight.eval_earth_daylight() 给出（与水面、植被同一真源），
//   tod_exposure 保留为全局曝光。直射光乘 local_day → 夜侧(太阳在地平线下)无方向光。
LightingContext make_lighting_context(float ambient_floor, vec2 uv, float lat_signed) {
	LightingContext lc;
	lc.L = normalize(tod_sun_dir);
	lc.V = VIEW_DIR_TOP_DOWN;

	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	if (USE_LINEAR_LIGHTING) {
		// 直射光乘 local_day：夜侧(太阳在地平线下)无方向光 → 杜绝"夜里还有阳面"。
		lc.sun_color_linear     = srgb_to_linear(ed.sun_col) * (SUN_INTENSITY_GAIN * ed.local_day);
		lc.ambient_color_linear = srgb_to_linear(ed.amb_col);
	} else {
		lc.sun_color_linear     = ed.sun_col * (SUN_INTENSITY_GAIN * ed.local_day);
		lc.ambient_color_linear = ed.amb_col;
	}
	lc.exposure = tod_exposure;
	lc.night_factor = ed.pixel_night;
	lc.hillshade = hillshade_strength;
	lc.ambient_floor = ambient_floor;
	return lc;
}

// ═══════════════════════════════════════════════════════════════════════
// 二、Cook-Torrance 微表面 BRDF 组件
// ═══════════════════════════════════════════════════════════════════════

// ─── D：GGX / Trowbridge-Reitz Normal Distribution Function ────────────
float D_GGX(float NdotH, float roughness) {
	float a = roughness * roughness;
	float a2 = a * a;
	float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
	return a2 / max(PI * denom * denom, 1e-7);
}

// ─── G：Smith joint masking-shadowing（Schlick-GGX 简化版） ────────────
float G_SchlickGGX(float NdotX, float k) {
	return NdotX / max(NdotX * (1.0 - k) + k, 1e-7);
}

float G_SmithGGX(float NdotL, float NdotV, float roughness) {
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;  // 直接光照常用 k
	return G_SchlickGGX(NdotL, k) * G_SchlickGGX(NdotV, k);
}

// ─── F：Schlick Fresnel ─────────────────────────────────────────────────
vec3 F_Schlick(vec3 F0, float VdotH) {
	float t = pow(clamp(1.0 - VdotH, 0.0, 1.0), 5.0);
	return F0 + (vec3(1.0) - F0) * t;
}

// ═══════════════════════════════════════════════════════════════════════
// 三、Hillshade-Only 旁路（legacy/debug fallback）
// ═══════════════════════════════════════════════════════════════════════
//   保留 v9 的 key+fill 双光源 hillshading 行为，供将来 debug fallback 使用。
//   注意：day_night_enabled=false 只表示"永昼 / 不跑晨昏线"，不再切到这条
//   未 tonemap 的 sRGB 旁路，否则高 hillshade_strength 会把雪地/浅色地表打爆。
// ─────────────────────────────────────────────────────────────────────
vec3 evaluate_hillshade_only(SurfaceParams s) {
	vec3 N = normalize(s.normal);
	vec3 key_dir  = normalize(vec3(hillshade_dir.x,      hillshade_dir.y,      0.65));
	vec3 fill_dir = normalize(vec3(hillshade_fill_dir.x, hillshade_fill_dir.y, 0.50));
	float light = max(dot(N, key_dir), 0.0) + max(dot(N, fill_dir), 0.0) * 0.40;
	light = clamp(light, 0.0, 1.0);
	vec3 lit = s.base_color
			 * mix(1.0 - hillshade_strength, 1.0 + hillshade_strength, light)
			 * s.ao;
	return lit + s.emission;
}

// ═══════════════════════════════════════════════════════════════════════
// 四、主 BRDF 入口：根据 USE_PBR_BRDF 分派
// ═══════════════════════════════════════════════════════════════════════
//   说明：
//     - 输出仍在 linear-HDR 域；最终的 linear→sRGB + filmic tonemap 由
//       global_adjustments.gdshaderinc 末端统一处理。这样 land/water 的
//       hillshade / 风格化 modulator 在 sRGB 域叠加时仍能保持一致基准。
//     - emission 在 BRDF 输出后直接相加，不参与 BRDF 计算。
//     - night_factor 作为整体亮度衰减统一应用（消除 v9 中 land/water 不一致）。
// ─────────────────────────────────────────────────────────────────────

// ─── 主 PBR 路径：Cook-Torrance + 能量守恒 ──────────────────────────────
vec3 evaluate_brdf_pbr(SurfaceParams s, LightingContext lc) {
	vec3 N = normalize(s.normal);
	vec3 V = normalize(lc.V);
	vec3 L = normalize(lc.L);
	vec3 H = normalize(L + V);

	float NdotL = max(dot(N, L), NDOTL_BIAS);
	float NdotV = max(dot(N, V), NDOTL_BIAS);
	float NdotH = max(dot(N, H), 0.0);
	float VdotH = max(dot(V, H), 0.0);

	float roughness = clamp(s.roughness, ROUGHNESS_MIN, ROUGHNESS_MAX);

	// ── albedo 进入 BRDF 前转线性空间 ──────────────────────────────────
	vec3 albedo = USE_LINEAR_LIGHTING ? srgb_to_linear(s.base_color) : s.base_color;

	// ── F0：dielectric 默认 0.04，metal 用 albedo 替代 ─────────────────
	vec3 F0 = mix(F0_DIELECTRIC_DEFAULT, albedo, s.metallic);

	// ── Cook-Torrance specular 项 ─────────────────────────────────────
	float D = D_GGX(NdotH, roughness);
	float G = G_SmithGGX(NdotL, NdotV, roughness);
	vec3  F = F_Schlick(F0, VdotH);
	vec3  spec = (D * G) * F / (4.0 * NdotL * NdotV);

	// ── diffuse 项（能量守恒：metal 没有 diffuse；非金属 = (1-F) · 1） ─
	vec3 kD = (vec3(1.0) - F) * (1.0 - s.metallic);
	vec3 diffuse = kD * albedo * INV_PI;

	// ── Direct lighting：(diffuse + spec) · NdotL · sun_color ─────────
	// Stylized 加成：hillshade 作为 direct 项的乘子（保留 v9 风味，让陡坡更暗）
	float hill_lift = lc.hillshade + HILLSHADE_BASE_LIFT;
	vec3 direct = (diffuse + spec) * NdotL * lc.sun_color_linear * hill_lift;

	// ── Ambient：环境光 · ao（带 ambient_floor 防止死黑） ───────────────
	vec3 ambient = max(lc.ambient_color_linear, vec3(lc.ambient_floor)) * albedo * s.ao;

	// ── Night atten + exposure ────────────────────────────────────────
	vec3 lit = direct + ambient;
	lit *= mix(1.0, NIGHT_BRIGHTNESS_FLOOR, lc.night_factor);
	lit *= lc.exposure;

	// ── emission：BRDF 输出后直接相加（火山/闪电/夜景灯光接入点） ───────
	lit += s.emission;
	return lit;
}

// ─── Legacy Blinn-Phong 路径（与 v9 视觉等价；USE_PBR_BRDF=0 时使用） ───
//   保留 land 与 water 分别用的 spec_amp 系数；caller 用 spec_max/spec_min 区分。
vec3 evaluate_brdf_blinn_phong_legacy(
		SurfaceParams s, LightingContext lc,
		float spec_max, float spec_min,
		float ambient_factor, float diffuse_factor) {
	vec3 N = normalize(s.normal);
	vec3 V = normalize(lc.V);
	vec3 L = normalize(lc.L);
	vec3 H = normalize(L + V);
	float NdotL = max(dot(N, L), 0.0);
	float NdotH = max(dot(N, H), 0.0);

	float roughness = clamp(s.roughness, ROUGHNESS_MIN, ROUGHNESS_MAX);
	float shininess = mix(GLOSS_MAX_LEGACY, GLOSS_MIN_LEGACY, roughness);
	float spec_amp = mix(spec_max, spec_min, roughness) * (1.0 - s.metallic);

	vec3 col = s.base_color;
	vec3 diffuse = col * (lc.ambient_color_linear * s.ao * ambient_factor
						+ lc.sun_color_linear * NdotL * (lc.hillshade + diffuse_factor));
	vec3 specular = lc.sun_color_linear * pow(NdotH, shininess) * spec_amp;
	vec3 lit = diffuse + specular + s.emission;
	lit *= mix(1.0, NIGHT_BRIGHTNESS_FLOOR, lc.night_factor);
	lit *= lc.exposure;
	// v9 末端 Reinhard，BRDF 主路径不做（main 路径由 global_adjustments 统一 tonemap）
	lit = tonemap_reinhard_legacy(lit);
	return lit;
}

// ─── 主入口：根据 USE_PBR_BRDF / day_night_enabled 分派 ────────────────
//   land/water 共用此入口，唯一差异是 caller 提供的 ambient_floor 与 spec 参数。
//   spec_max / spec_min 仅在 USE_PBR_BRDF=0 的 legacy 路径生效。
vec3 evaluate_brdf(
		SurfaceParams s, LightingContext lc,
		float spec_max_legacy, float spec_min_legacy) {
	if (USE_PBR_BRDF) {
		return evaluate_brdf_pbr(s, lc);
	}
	// Legacy: 与 v9 等价（HILLSHADE_BASE_LIFT=0.55, ambient_factor=1.0）
	return evaluate_brdf_blinn_phong_legacy(
		s, lc, spec_max_legacy, spec_min_legacy,
		1.0, HILLSHADE_BASE_LIFT);
}
