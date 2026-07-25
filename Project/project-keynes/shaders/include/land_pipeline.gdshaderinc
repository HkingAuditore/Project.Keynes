// land_pipeline.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   陆地渲染管线。按 Stylized 半 PBR SurfaceParams 组织：
//     base surface → modifier (4 stage) → color overlay → material overlay → BRDF
//
// 调用方（Who）
//   - world_map.gdshader::fragment 在 !is_water 分支调用 render_land_pipeline
//
// 依赖（Why）
//   uniforms / common_noise / height / biome_color / vegetation / weather_front /
//   snow_cover / biome_detail / hillshade_tod / surface_params / shore_common /
//   brdf / material_constants
//
// 性能（Cost）
//   集中陆地侧 basecolor / 海岸邻域 / 雪盖 / cover / TOD 的全部计算。
//   shore 邻域采样已抽到 shore_common（一次 8-fetch / 4-fetch）；BRDF 走单点
//   evaluate_brdf 调度，按 USE_PBR_BRDF 编译期分支。
// ─────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════
// LAND 0：变色层输入容器（取代旧 13 参函数签名）
// ═══════════════════════════════════════════════════════════════════════
struct LandModInputs {
	int biome;
	int veg;
	float elev;
	float moist;
	float lat_signed;
	float current_temp;
	vec2 wind_v;
	float dyn_snow;
	float dyn_valid;
	float dyn_vitality;
	float eco_foliage;
	float eco_stress;
	float eco_transition;
	float eco_growth;
	float eco_valid;
	vec4 pixel_noise;
	vec2 wp;
};

// ═══════════════════════════════════════════════════════════════════════
// LAND 1：Base Surface（basecolor / normal / roughness / AO / metallic）
// ═══════════════════════════════════════════════════════════════════════
SurfaceParams compute_land_base_surface(
		int biome,
		int landform,
		float elev,
		vec2 wp,
		vec2 uv,
		vec4 scals) {
	vec3 col;

	// LAND 1.1：底色 = hypsometric × biome hue × procedural detail
	vec3 hyps = hypsometric_tint(elev, false);
	col = biome_hue_modulate(hyps, biome) * procedural_biome_detail(biome, wp, uv);

	// [river-render-restore 2026-06-19] 河流 SDF 视觉层重新接回：flow 来自 flow_tex（scals.g）。
	float flow = scals.g;
	float river_t_raw = smoothstep(river_threshold_low, river_threshold_high, flow);
	float river_t = river_t_raw;
	float outline_t = smoothstep(river_threshold_low * 0.78, river_threshold_low, flow)
			* (1.0 - smoothstep(river_threshold_high, min(river_threshold_high + 0.22, 1.0), flow));
#if !defined(PK_MOBILE_ANY)
	if (river_t > 0.001 && river_flow_enabled && river_flow_speed > 0.001 && visual_quality >= 1) {
		float pulse = 1.0 + 0.055 * sin(dot(wp, vec2(0.35, 0.42)) - world_time * 0.55);
		river_t = clamp(river_t * pulse, 0.0, 1.0);
	}
#endif
	// [需求1 2026-06-19] 增强径流量视觉差：深浅系数 0.42→0.60、深水段更接近深海色 → 宽阔干流呈
	// 深蓝厚重、细窄支流浅青，配合烘焙端幂律宽度对比，让"大河 vs 小河"在视觉上拉开。
	float river_depth_w = smoothstep(0.18, 1.0, river_t_raw);
	vec3 river_surface = mix(river_color * vec3(1.10, 1.08, 1.02), color_mid_ocean, 0.18);
	vec3 river_deep = mix(river_color * vec3(0.66, 0.80, 0.98), color_deep_ocean, 0.30);
	vec3 river_body = mix(river_surface, river_deep, river_depth_w * 0.60);
	vec3 river_edge_col = mix(river_outline_color, river_color * vec3(0.82, 0.95, 1.05), 0.32);
	col = mix(col, river_edge_col, outline_t * 0.50 * river_strength);
	col = mix(col, river_body, river_t * river_strength);

	// LAND 1.3：河流顺坡流动明暗（Water Visual Overhaul）
#if !defined(PK_MOBILE_ANY)
	if (river_t > 0.001
			&& river_flow_enabled
			&& river_flow_speed > 0.001
			&& visual_quality >= 1) {
		vec2 texel = 1.0 / hm_resolution;
		float hl = decode_height_rg8(uv - vec2(texel.x, 0.0));
		float hr = decode_height_rg8(uv + vec2(texel.x, 0.0));
		float hu = decode_height_rg8(uv - vec2(0.0, texel.y));
		float hd = decode_height_rg8(uv + vec2(0.0, texel.y));
		vec2 grad = vec2(hr - hl, hd - hu);
		float slope_mag = length(grad);
		if (slope_mag > 0.002) {
			vec2 fbm_smooth = vec2(
				fbm(wp * 0.045, 1) - 0.5,
				fbm(wp * 0.045 + vec2(21.0, -13.0), 1) - 0.5
			) * 0.11;
			vec2 flow_dir = normalize(-grad + fbm_smooth);
			vec2 flow_perp = vec2(-flow_dir.y, flow_dir.x);
			float along = dot(wp, flow_dir) * river_flow_freq;
			float across = dot(wp, flow_perp) * river_flow_freq * 0.42;
			vec2 flow_uv = vec2(along + world_time * river_flow_speed * 0.42, across);
			int river_flow_oct = (visual_quality >= 2) ? 2 : 1;
			float flow_streak = fbm(flow_uv, river_flow_oct);
			vec3 flow_tint = river_body * mix(0.92, 1.09, flow_streak);
			col = mix(col, flow_tint, river_t * river_strength * 0.28);
		}
	}
#endif

	// LAND 1.4：等高线 basecolor（仅 contour_enabled）
	if (contour_enabled) {
		float contour_phase = fract(elev / max(contour_step, 0.001));
		float dist = abs(contour_phase - 0.5);
		float contour_t = smoothstep(0.50, 0.42, dist);
		col = mix(col, contour_color, contour_t * contour_strength);
	}

	// LAND 1.5：Normal / roughness / AO / metallic
	vec3 normal = compute_terrain_normal(uv, visual_quality, biome);
	float roughness = biome_roughness(biome);
	float ao = mix(0.92, DEFAULT_AO_LAND, clamp(normal.z, 0.0, 1.0));
	float metallic = DEFAULT_METALLIC_LAND;

	// LAND 1.5b：[河流高光 2026-06-25] 把河道当作水面而非平面蓝覆盖：降低 roughness、混入轻微
	// 水波法线、给一点非金属菲涅尔，让河流经统一 BRDF 得到顺光高光与反射。高光强度绑定 river_t
	// （细河道权重小但仍可读），不会让所有 flow 边缘发白。桌面走水波法线，低画质退化为平滑水面。
	if (river_t > 0.001) {
		float river_w = clamp(river_t * river_strength, 0.0, 1.0);
#if defined(PK_MOBILE_ANY)
		normal = normalize(mix(normal, vec3(0.0, 0.0, 1.0), river_w * 0.60));
#else
		if (visual_quality >= 1 && water_waves_enabled) {
			vec3 river_wn = sample_water_normal(wp, world_time, 0.40, 1.15, 1, true);
			normal = normalize(mix(normal, river_wn, river_w * 0.70));
		} else {
			normal = normalize(mix(normal, vec3(0.0, 0.0, 1.0), river_w * 0.60));
		}
#endif
		roughness = mix(roughness, 0.16, river_w);
		metallic = mix(metallic, DEFAULT_METALLIC_WATER, river_w);
		ao = mix(ao, 0.98, river_w * 0.5);
	}

	// LAND 1.6：[landform 轴可视化] 给 terrain 表达不了的地貌（火山/高原/峡谷/裂谷/高峰）
	// 叠加专属着色。火山已改为生成期高度场环形山 + hillshade 表现，不再发光（lf_vis.a 恒 0）；
	// emission 通道保留作为未来地貌发光的通用接口。
	float slope_mag = clamp(length(normal.xy), 0.0, 1.0);
	vec4 lf_vis = landform_visual(landform, wp, col, slope_mag);
	col = lf_vis.rgb;
	SurfaceParams sp = make_surface_params(col, normal, roughness, metallic, ao);
	sp.emission = vec3(1.30, 0.42, 0.10) * lf_vis.a;
	return sp;
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 2：变色层（material modifiers）
// ───────────────────────────────────────────────────────────────────────
//   季节与静态植被轴先建立底色；温度、湿度、生态和活力随后进入同一个
//   归一化环境调色器，避免多个乘性色层把中间色域压灰。海拔与坡度仍独立
//   塑形，积雪和 cover 在 LAND 3 最后覆盖。
// ═══════════════════════════════════════════════════════════════════════

// ─── LAND 2.1：季节性植被色（南北半球软混 + 物候相位扰动） ─────────────
SurfaceParams apply_seasonal_vegetation_tint(SurfaceParams surface, LandModInputs i) {
	int biome = i.biome;
	if (!(biome == B_FOREST || biome == B_GRASSLAND || biome == B_HILL || biome == B_PLAIN
			|| biome == B_TAIGA || biome == B_SAVANNA || biome == B_STEPPE)) {
		return surface;
	}
	vec3 col = surface.base_color;

	// 低活力植被不应像健康植被一样保持完整换季色。
	float vitality_w = mix(1.0, i.dyn_vitality, i.dyn_valid);
	float vitality_amp = mix(0.35, 1.25, smoothstep(0.12, 0.92, vitality_w));

	// N1: 季节 tint 噪声扰动 —— 复用 SETUP 0 的 pixel_noise
	//   ① phase_jitter → 局部物候差异
	//   ② amp_jitter   → 同 biome 内的明灭斑驳
	float phase_jitter = (i.pixel_noise.r - 0.5) * 0.36;
	float amp_jitter   = mix(0.75, 1.18, i.pixel_noise.g);

	// N7: 赤道半球相位硬切修复 —— 分别按南/北半球各算一次植被 tint，
	// 然后用 lat_signed 经 smoothstep 软混合两个颜色。
	float eq_half_width = 0.30 + (i.pixel_noise.b - 0.5) * 0.20; // [0.20, 0.40]
	float north_w_raw = smoothstep(-eq_half_width, eq_half_width, i.lat_signed);
	float north_w = clamp(north_w_raw + (i.pixel_noise.a - 0.5) * 0.55, 0.0, 1.0);
	float north_phase = mod(hemi_phase(season_phase, -1.0) + phase_jitter + 4.0, 4.0);
	float south_phase = mod(hemi_phase(season_phase, +1.0) + phase_jitter + 4.0, 4.0);
	vec3 north_tint = vegetation_seasonal_tint_lut(i.veg, north_phase, i.wp);
	vec3 south_tint = vegetation_seasonal_tint_lut(i.veg, south_phase, i.wp);
	vec3 veg_tint = mix(south_tint, north_tint, north_w);

	float strength = vegetation_season_strength * vitality_amp * amp_jitter;
	if (biome == B_SAVANNA || biome == B_STEPPE) {
		// 草原 / 稀树草原：振幅减半（干湿季对比远不如温带森林明显）
		strength *= 0.5;
	}
	col = mix(col, col * veg_tint, strength);
	surface.base_color = col;
	return surface;
}

// ─── LAND 2.2：海拔 / 坡度 / 风塑形；纯 ALU，无额外纹理采样 ────────────
SurfaceParams apply_relief_tint(SurfaceParams surface, LandModInputs i) {
	float land_h = clamp((i.elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	float slope_mag = clamp(length(surface.normal.xy), 0.0, 1.0);
	float foothill_w = smoothstep(0.10, 0.38, land_h);
	float highland_w = smoothstep(0.34, 0.78, land_h);
	float alpine_w = smoothstep(0.66, 0.96, land_h);
	float ridge_w = smoothstep(0.10, 0.48, slope_mag);
	float basin_w = 1.0 - ridge_w;

	// [需求3 2026-06-25] 海拔不只改色相，也顺着坡度把山肩 / 山脊 / 谷地分出来，避免整片
	// 高地像一块硬贴上去。本轮把幅度整体提高（让连续高程起伏在地图上"读得出"，山脚丘陵
	// 不再像平原；山体周围有渐变的明暗过渡而非硬边界）。
	surface.base_color *= mix(vec3(1.0), vec3(1.05, 1.01, 0.93), foothill_w * 0.14);
	surface.base_color *= mix(vec3(1.0), vec3(0.92, 0.96, 1.03), highland_w * (0.14 + ridge_w * 0.18));
	surface.base_color *= mix(vec3(1.0), vec3(1.08, 1.04, 0.99), alpine_w * basin_w * 0.13);
	surface.base_color *= mix(vec3(1.0), vec3(0.84, 0.88, 0.94), alpine_w * ridge_w * 0.26);
	// 广域起伏：低/中海拔也按坡度做轻微明暗，让平原—丘陵—山脚的地形呼吸感连续过渡。
	float relief_shade = (ridge_w - basin_w) * smoothstep(0.04, 0.50, land_h) * 0.10;
	surface.base_color *= clamp(1.0 - relief_shade, 0.85, 1.12);

	float wind_mag = clamp(length(i.wind_v), 0.0, 1.4);
	float wind_dry = wind_mag * (1.0 - smoothstep(0.36, 0.84, i.moist));
	surface.base_color *= mix(vec3(1.0), vec3(1.10, 0.98, 0.86), wind_dry * 0.10);
	return surface;
}

// ─── LAND 2.3：植被轴 tint ──────────────────────────────────────────────
SurfaceParams apply_vegetation_axis_tint(SurfaceParams surface, LandModInputs i) {
	if (vegetation_axis_strength <= 0.001
			|| i.veg == V_NONE
			|| !biome_accepts_vegetation_tint(i.biome)) {
		return surface;
	}
	vec3 v_tint = vegetation_tint(i.veg);
	surface.base_color = mix(surface.base_color, surface.base_color * v_tint, vegetation_axis_strength);
	return surface;
}

// ─── LAND 2.4：统一环境调色 ────────────────────────────────────────────
// 温度、湿度、生态与活力先求权重，再一次性混合色相。干热、湿润和衰退
// 因而可以拉开战略辨识度，同时不会因连续乘色丢失饱和度与明度。
SurfaceParams apply_environment_color_grade(SurfaceParams surface, LandModInputs i) {
	if (i.dyn_valid <= 0.5) {
		return surface;
	}

	float temp_cold_n = 1.0 - smoothstep(0.32, 0.58, i.current_temp);
	float snow_cold_n = smoothstep(0.04, 0.42, i.dyn_snow * i.dyn_valid) * 0.88;
	float cold_n = max(temp_cold_n, snow_cold_n);
	float cold_w = cold_n * temperature_visual_strength;
	float hot_n = smoothstep(0.55, 0.78, i.current_temp);
	float hot_w = hot_n * temperature_visual_strength;
	float dry_n = 1.0 - smoothstep(0.22, 0.52, i.moist);
	float dry_w = dry_n * moisture_visual_strength;
	float wet_n = smoothstep(0.55, 0.82, i.moist);
	float wet_w = wet_n * moisture_visual_strength;

	float healthy_w = 0.0;
	float decline_w = 0.0;
	float dieback_w = 0.0;
	float foliage_w = 0.0;
	float stress_w = 0.0;
	if (i.veg != V_NONE) {
		float vitality = clamp(i.dyn_vitality, 0.0, 1.0);
		healthy_w = smoothstep(0.60, 0.90, vitality) * vitality_visual_strength;
		decline_w = (1.0 - smoothstep(0.35, 0.70, vitality)) * vitality_visual_strength;
		dieback_w = (1.0 - smoothstep(0.10, 0.35, vitality)) * vitality_visual_strength;
	}
	if (i.eco_valid > 0.5 && i.veg != V_NONE) {
		float eco_q = float(min(ecology_visual_quality, visual_quality));
		float foliage_noise = (eco_q >= 1.0) ? i.pixel_noise.g : 0.5;
		float patch_noise = (eco_q >= 2.0) ? i.pixel_noise.a : 0.5;
		float foliage = clamp(i.eco_foliage + (foliage_noise - 0.5) * 0.22
				+ (patch_noise - 0.5) * 0.12, 0.0, 1.0);
		float stress = clamp(i.eco_stress + (patch_noise - 0.5) * 0.18, 0.0, 1.0);
		foliage_w = smoothstep(0.10, 0.85, foliage) * foliage_density_strength
				* ecology_visual_strength * (1.0 - stress * 0.55);
		stress_w = smoothstep(0.22, 0.95, stress) * ecology_visual_strength;
		float transition_w = smoothstep(0.02, 0.75, i.eco_transition);
		foliage_w += transition_w * smoothstep(0.56, 0.82, i.eco_growth)
				* ecology_visual_strength * 0.22;
		decline_w += transition_w * (1.0 - foliage) * ecology_visual_strength * 0.28;
	}
	// 活力表示生态状态良好，不等于地表必然翠绿。健康绿必须同时获得水分支持；
	// 荒漠、盐碱地、寒漠和旱生植被始终保留沙黄/赭褐的生态身份。
	bool arid_identity = i.biome == B_DESERT || i.biome == B_SALT_FLAT
			|| i.biome == B_COLD_DESERT || i.veg == V_DESERT_SCRUB
			|| i.veg == V_XERIC_DESERT || i.veg == V_POLAR_DESERT;
	float green_water_support = smoothstep(0.30, 0.62, i.moist)
			* (arid_identity ? 0.0 : 1.0);
	wet_w *= green_water_support;
	healthy_w *= green_water_support;
	foliage_w *= mix(0.04, 1.0, green_water_support);
	// 冻原与林线不能被湿润、高活力和高叶量重新推回鲜绿。温度约 0.2 时
	// 这些绿色权重几乎退出，只留下地形纹理与后续雪盖。
	float cold_green_retention = mix(1.0, 0.08, cold_n);
	wet_w *= mix(1.0, 0.12, cold_n);
	healthy_w *= cold_green_retention;
	foliage_w *= cold_green_retention;

	dry_w *= mix(0.84, 1.16, i.pixel_noise.r);
	wet_w *= mix(0.86, 1.14, i.pixel_noise.b);
	healthy_w *= mix(0.88, 1.12, i.pixel_noise.g);
	decline_w += stress_w * 0.82;
	dieback_w += stress_w * decline_w * 0.24;

	vec3 weighted_tint =
			vec3(0.96, 1.00, 1.04) * cold_w
			+ vec3(1.10, 0.92, 0.78) * hot_w
			+ vec3(1.12, 1.04, 0.74) * dry_w
			+ vec3(0.82, 1.05, 0.88) * wet_w
			+ vec3(0.82, 1.07, 0.78) * (healthy_w + foliage_w)
			+ vec3(1.10, 0.90, 0.68) * decline_w
			+ vec3(0.56, 0.50, 0.42) * dieback_w;
	float total_w = cold_w + hot_w + dry_w + wet_w + healthy_w + foliage_w
			+ decline_w + dieback_w;
	if (total_w <= 0.001) {
		return surface;
	}

	weighted_tint /= total_w;
	float dominant_w = max(max(max(cold_w, hot_w), max(dry_w, wet_w)),
			max(max(healthy_w + foliage_w, decline_w), dieback_w));
	// 热旱同时拉满时保留更多地形底色，避免高温、干旱和衰退叠成整片橙红。
	float hot_dry_n = hot_n * dry_n;
	float coverage_cap = mix(0.85, 0.66, hot_dry_n);
	float coverage = min(clamp(dominant_w * 0.64, 0.0, 0.85), coverage_cap);
	vec3 graded = surface.base_color * mix(vec3(1.0), weighted_tint, coverage);

	// 色相强、明度稳：常温区展开色度，严寒区则转为灰蓝白。
	float value_shift = dry_w * 0.03 + hot_w * 0.01 + wet_w * 0.02
			+ (healthy_w + foliage_w) * 0.03 - cold_w * 0.03
			- decline_w * 0.04 - dieback_w * 0.12;
	value_shift = clamp(value_shift / max(total_w, 0.001), -0.12, 0.12) * coverage;
	float luma = dot(graded, vec3(0.299, 0.587, 0.114));
	float saturation_gain = 1.0 + 0.14 * coverage;
	float warm_chroma_control = clamp(hot_n * 0.85 + dry_n * 0.20, 0.0, 1.0);
	saturation_gain = mix(saturation_gain, 0.98, warm_chroma_control * 0.78);
	saturation_gain = mix(saturation_gain, 0.30, cold_n * 0.96);
	// 高活力和高湿度可以保持绿色语义，但禁止绿色通道获得额外的荧光式展开。
	// 该限制只收敛绿色主导色，不影响金黄、赭褐、岩灰和雪色。
	float green_axis = max(graded.g - max(graded.r, graded.b), 0.0);
	float green_chroma_w = smoothstep(0.08, 0.28, green_axis)
			* clamp((wet_w + healthy_w + foliage_w) / max(total_w, 0.001), 0.0, 1.0);
	saturation_gain = mix(saturation_gain, min(saturation_gain, 1.02),
			green_chroma_w * 0.88);
	graded = mix(vec3(luma), graded, saturation_gain);
	graded *= 1.0 + value_shift;
	// 乘性色无法从高饱和草地中真正移除绿色，因此极冷区再做一次受控的
	// 绝对中性色混合。目标仍由当前明度派生，山脊、坡面和地形类型不会被抹平。
	float frost_neutral_w = smoothstep(0.62, 0.96, cold_n)
			* mix(0.58, 0.70, snow_cold_n);
	float cold_luma = dot(graded, vec3(0.299, 0.587, 0.114));
	vec3 cold_neutral = mix(
			vec3(cold_luma) * vec3(0.96, 1.0, 1.04),
			vec3(0.70, 0.76, 0.80), 0.48);
	graded = mix(graded, cold_neutral, frost_neutral_w);
	surface.base_color = clamp(graded, vec3(0.0), vec3(1.0));
	surface.roughness = mix(surface.roughness, 0.92,
			clamp(dieback_w / max(total_w, 0.001), 0.0, 1.0) * 0.55);
	return surface;
}

// ─── LAND 2：调度器 ────────────────────────────────────────────────────
SurfaceParams apply_land_material_modifiers(SurfaceParams surface, LandModInputs i) {
	surface = apply_seasonal_vegetation_tint(surface, i);
	surface = apply_vegetation_axis_tint(surface, i);
	surface = apply_environment_color_grade(surface, i);
	surface = apply_relief_tint(surface, i);
	return surface;
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 3：覆盖层 —— 拆为 color overlay 与 material overlay 两个语义清晰的函数
// ───────────────────────────────────────────────────────────────────────
//   3.1  apply_land_color_overlays    仅修改 base_color：海岸 halo / 雪盖色 / cover 色
//   3.2  apply_land_material_overlays 仅修改 N/R/AO/metallic：雪 / 冰川 / 永冻土 / 洪水
// ═══════════════════════════════════════════════════════════════════════

// ─── LAND 3.0：积雪权重估算（color/material overlay 共享） ─────────────
float estimate_land_snow_material_weight(
		int biome,
		float current_temp,
		float elev,
		float moisture,
		float dyn_snow,
		float dyn_valid) {
	float snow_w = dyn_snow * dyn_valid;
	if (biome == B_SNOW) {
		snow_w = max(snow_w, (1.0 - smoothstep(0.28, 0.58, current_temp)) * 0.70);
	}
	if (biome == B_GLACIER) {
		snow_w = max(snow_w, 0.80);
	}
	float wet_snow = mix(0.55, 1.0, smoothstep(0.18, 0.72, moisture));
	snow_w = max(snow_w, (1.0 - smoothstep(0.26, 0.52, current_temp)) * 0.50 * wet_snow);
	float land_h = (elev - sea_level) / max(1.0 - sea_level, 0.001);
	float altitude_w = smoothstep(0.22, 0.90, land_h);
	float alpine_temp_w = 1.0 - smoothstep(0.28, 0.72, current_temp);
	snow_w = max(snow_w, altitude_w * alpine_temp_w * 0.92);
	return clamp(snow_w * dynamic_snow_strength, 0.0, 1.0);
}

// ─── LAND 3.1：颜色覆盖层（base_color 修改） ────────────────────────────
SurfaceParams apply_land_color_overlays(
		SurfaceParams surface,
		int biome,
		int veg,
		int cover,
		float elev,
		float moist,
		vec2 wp,
		vec2 uv,
		vec4 scals,
		float current_temp,
		float dyn_snow,
		float dyn_valid,
		float eco_foliage,
		float eco_stress,
		float eco_valid,
		vec4 pixel_noise) {
	vec3 col = surface.base_color;

	// LAND 3.1.a：海岸 / 湖岸 / 河口柔和过渡（shore_common 共享）
	// 60 FPS 优化：mobile 全档位跳过 shore neighborhood 邻域 sample
#if defined(PK_MOBILE_ANY)
	// 无 halo
#else
	ShoreSamples shore_samp = sample_shore_neighborhood(uv);
	ShoreHaloResult shore_halo_r = compute_shore_halo(shore_samp, elev, scals.g, 0);
	col = mix(col, shore_halo_r.halo_color, shore_halo_r.halo_weight);
	// [coast-smooth 2026-06-26] 海岸过渡带（陆侧）：在贴水的一圈把陆色混向"水色与陆色的中间色"，柔化
	// 六边形硬边。粗细 = shore_w(贴水接触度,已 smoothstep)×coast_smooth_width；内陆/远岸 shore_w=0 不染。
	// 颜色 = mix(color_coast_water, color_lowland, coast_shore_land_bias) → 水色+陆色混合(非灰褐)。
	if (coast_smooth_strength > 0.001) {
		float band = smoothstep(0.0, 1.0, clamp(shore_halo_r.shore_w * coast_smooth_width, 0.0, 1.0));
		vec3 shore_mix = mix(color_coast_water, color_lowland, coast_shore_land_bias);
		col = mix(col, shore_mix, band * coast_smooth_strength);
	}
#endif

	// LAND 3.1.b：统一雪盖色（季节性雪线 / 真实积雪 / BLIZZARD 新雪）
	col = apply_snow_cover(
		col, biome, veg, current_temp, elev, false, moist, wp, uv,
		dyn_snow, dyn_valid, eco_valid, eco_stress, eco_foliage, scals.g, pixel_noise);

	// LAND 3.1.c：覆盖物轴（FLOODING / PERMAFROST / GLACIER）
	// SNOW / SEA_ICE 已由雪盖 / 海面主路径处理，cover_overlay 内部返回 0 跳过。
	// N5: 加噪声扰动让冰川/永冻土/洪水都呈\"斑驳大块\"而非均匀贴片。
	if (cover_axis_strength > 0.001) {
		vec4 ov = cover_overlay(cover);
		if (ov.a > 0.001) {
#ifdef PK_MOBILE_ANY
			float cov_amp = 1.0;
			vec3  cov_rgb = ov.rgb;
#else
			float cov_low = fbm(wp * 0.055 + vec2(-13.0, 41.0), 2);
			float cov_hi  = fbm(wp * 0.26  + vec2(73.0, -19.0), 1);
			float cov_amp = mix(0.55, 1.20, cov_low);
			vec3  cov_rgb = ov.rgb * mix(0.94, 1.06, cov_hi);
#endif
			float cov_a   = clamp(ov.a * cov_amp, 0.0, 1.0);
			col = mix(col, cov_rgb, cov_a * cover_axis_strength);
		}
	}
	surface.base_color = col;
	return surface;
}

// ─── LAND 3.2：材质覆盖层（N/R/AO/metallic 修改） ──────────────────────
SurfaceParams apply_land_material_overlays(
		SurfaceParams surface,
		int biome,
		int cover,
		float current_temp,
		float elev,
		float moist,
		float dyn_snow,
		float dyn_valid,
		float river_flow) {
	float snow_w = estimate_land_snow_material_weight(biome, current_temp, elev, moist, dyn_snow, dyn_valid);
	float river_mask = smoothstep(river_threshold_low * 0.84, river_threshold_high, river_flow);
	float river_freeze_w = river_mask * clamp(max(snow_w, (1.0 - smoothstep(0.24, 0.46, current_temp)) * dyn_valid * 0.55), 0.0, 1.0);
	if (snow_w > 0.001) {
		// [岩石去高光 2026-06-25] 岩石型山地（MOUNTAIN/HILL/BADLANDS）即便覆雪也应保留岩面
		// 粗糙与起伏：法线压平减半（0.35→0.18），雪面粗糙目标从 0.52 抬到 0.74，避免覆雪山脊
		// 在低角度太阳下变成湿滑反光面。平坦地表的雪仍走原来的较光滑值。
		// [海冰反射 2026-06-25] 冰川 biome 是结晶冰，覆雪权重不应把它磨成哑光雪：单独走 0.14 冰目标。
		bool rocky = (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS);
		bool icy = (biome == B_GLACIER);
		float snow_normal_flatten = rocky ? 0.18 : 0.35;
		float snow_material_w = snow_w * (1.0 - river_freeze_w * 0.82);
		surface.normal    = normalize(mix(surface.normal, vec3(0.0, 0.0, 1.0), snow_material_w * snow_normal_flatten));
		float snow_rough_target = rocky ? 0.74 : (icy ? 0.14 : 0.34);
		surface.roughness = mix(surface.roughness, snow_rough_target, snow_material_w);
		surface.ao        = mix(surface.ao, 0.96, snow_material_w);
		// 岩石覆雪不给金属感；冰川覆雪保留冰的微金属菲涅尔；平坦雪面给微镜面。
		float snow_metal_target = rocky ? 0.0 : (icy ? DEFAULT_METALLIC_ICE : DEFAULT_METALLIC_SNOW);
		surface.metallic  = mix(surface.metallic, snow_metal_target, snow_material_w);
	}
	if (river_freeze_w > 0.001) {
		surface.normal = normalize(mix(surface.normal, vec3(0.0, 0.0, 1.0), river_freeze_w * 0.55));
		surface.roughness = mix(surface.roughness, 0.18, river_freeze_w);
		surface.metallic = mix(surface.metallic, DEFAULT_METALLIC_ICE, river_freeze_w * 0.65);
		surface.ao = mix(surface.ao, 0.99, river_freeze_w * 0.55);
	}
	if (cover == CV_GLACIER) {
		// [海冰反射 2026-06-25] 冰川覆盖压到更低粗糙（0.26→0.14）+ 抬金属感，体现冰面镜面/菲涅尔反射。
		surface.roughness = min(surface.roughness, 0.14);
		surface.ao        = min(surface.ao, 0.98);
		surface.metallic  = max(surface.metallic, DEFAULT_METALLIC_ICE * cover_axis_strength);
	} else if (cover == CV_FLOODING) {
		surface.roughness = mix(surface.roughness, 0.18, cover_axis_strength);
	} else if (cover == CV_PERMAFROST) {
		surface.roughness = mix(surface.roughness, 0.48, cover_axis_strength * 0.5);
	}
	return surface;
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 4：BRDF Shading —— 走 brdf.gdshaderinc 的统一 evaluate_brdf
// ═══════════════════════════════════════════════════════════════════════
vec3 shade_land_surface(SurfaceParams surface, vec2 uv, float lat_signed) {
	// [cylindrical-earth-daylight] 传 uv+lat_signed 进光照上下文 → 逐像素经纬度日照。
	LightingContext lc = make_lighting_context(AMBIENT_FLOOR_LAND, uv, lat_signed);
	if (terrain_horizon_debug_view == 1) {
		return vec3(clamp((1.0 - lc.direct_shadow) * lc.local_day, 0.0, 1.0));
	}
	if (terrain_horizon_debug_view == 2) {
		return vec3(lc.direct_shadow);
	}
	vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_LAND_LEGACY, SPEC_MIN_LAND_LEGACY);

	// [tod 地形方向性 2026-06-25 / 加强 2026-06-25b] 在 BRDF 之上叠一层 terrain-only 的方向性
	// 明暗，让"太阳南北移动"在地形起伏上清晰可读。仅陆地调用，不污染水面反射；夜侧按昼夜系数淡出。
	//
	// ⚠ 旧实现 bug：直接用原始 N.xy 的【量级】(slope_dir = dot(N.xy, Ln))。RG8 高度图跨单 texel
	//   的梯度极小，典型缓坡 N.xy≈0.05 → relief≈0.05*0.35≈0.017（仅 1.7% 亮度差）→ 肉眼几乎
	//   看不出太阳移动的影响，正是用户反馈的现象。
	// ✅ 新实现（经典 hillshade aspect）：把水平法线【归一化成坡向】aspect = dot(slope_face, Ln)
	//   ∈[-1,1]，与坡陡无关——朝阳坡满量程提亮、背阳坡满量程压暗；坡度量级只作"有没有起伏"的
	//   软遮罩(slope_mask)，缓坡也响应、平地不响应（不引入噪声）。太阳水平方向 Ln 随时角/纬度/
	//   季节旋转（含南北分量）→ aspect 符号随之翻转 → 光源移动一眼可见。
	if (tod_terrain_relief_strength > 0.001) {
		vec3 N = normalize(surface.normal);
		vec2 Nh = N.xy;
		float slope = length(Nh);
		vec2 Lh = lc.L.xy;
		float Lh_len = length(Lh);
		if (Lh_len > 1e-3 && slope > 1e-4) {
			vec2 Ln = Lh / Lh_len;
			vec2 slope_face = Nh / slope;               // 归一化坡向（与坡陡解耦）
			float aspect = dot(slope_face, Ln);          // +1 正朝阳, -1 正背阳
			// 只要有可辨识的起伏就给足方向性；平地(slope→0)平滑淡出，避免高度图量化噪声闪烁。
			float slope_mask = smoothstep(0.006, 0.05, slope);
			float day_w = lc.local_day;                 // 昼夜开启时夜侧淡出；关闭时永昼=1
			// 永昼没有晨昏线作为运动参照，因此适度加强坡向明暗，让全局光方位旋转可被玩家识别。
			// 只放大已有 terrain relief，不新增光照通路；上限避免山地出现过曝/死黑翻转。
			float eternal_relief_gain = day_night_enabled ? 1.0 : 1.45;
			float relief_strength = min(tod_terrain_relief_strength * eternal_relief_gain, 0.55);
			// 永昼使用不对称坡向塑形：迎光面保留强响应，背光面限制在约 70% 以上，
			// 避免低角度平行光与环境 AO / horizon shadow 叠乘成死黑。
			float back_strength = day_night_enabled
				? relief_strength
				: min(tod_terrain_relief_strength * 0.85, 0.30);
			float signed_strength = (aspect >= 0.0) ? relief_strength : back_strength;
			float relief = aspect * slope_mask * signed_strength * day_w;
			float relief_floor = day_night_enabled ? 0.58 : 0.70;
			lit *= clamp(1.0 + relief, relief_floor, 1.50);
		}
	}
	// [terrain-horizon 2026-07-03] BRDF 内只遮蔽 direct lighting，物理上正确但在当前强环境光/
	// 方向性 relief 叠层下肉眼偏弱；这里给陆地追加一层温和的 cartographic cast-shadow，仍按
	// lc.direct_shadow 与 local_day 门控，不影响水面和 emission，保证“投影”可读。
	float cast_shadow = clamp((1.0 - lc.direct_shadow) * lc.local_day, 0.0, 1.0);
	if (cast_shadow > 0.001) {
		float cast_floor = day_night_enabled
			? terrain_horizon_cast_floor
			: max(terrain_horizon_cast_floor, 0.90);
		lit *= mix(1.0, cast_floor, cast_shadow);
	}
	return lit;
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 5：顶层调度
// ═══════════════════════════════════════════════════════════════════════
vec3 render_land_pipeline(
		int biome,
		int veg,
		int cover,
		int landform,
		float elev,
		float moist,
		vec2 wp,
		vec2 uv,
		vec4 scals,
		float lat_signed,
		float current_temp,
		vec2 wind_v,
		float dyn_snow,
		float dyn_valid,
		float dyn_vitality,
		float eco_foliage,
		float eco_stress,
		float eco_transition,
		float eco_growth,
		float eco_valid,
		vec4 pixel_noise) {
	SurfaceParams surface = compute_land_base_surface(biome, landform, elev, wp, uv, scals);

	LandModInputs mi;
	mi.biome = biome;
	mi.veg = veg;
	mi.elev = elev;
	mi.moist = moist;
	mi.lat_signed = lat_signed;
	mi.current_temp = current_temp;
	mi.wind_v = wind_v;
	mi.dyn_snow = dyn_snow;
	mi.dyn_valid = dyn_valid;
	mi.dyn_vitality = dyn_vitality;
	mi.eco_foliage = eco_foliage;
	mi.eco_stress = eco_stress;
	mi.eco_transition = eco_transition;
	mi.eco_growth = eco_growth;
	mi.eco_valid = eco_valid;
	mi.pixel_noise = pixel_noise;
	mi.wp = wp;
	surface = apply_land_material_modifiers(surface, mi);

	surface = apply_land_color_overlays(
		surface, biome, veg, cover, elev, moist, wp, uv, scals, current_temp,
		dyn_snow, dyn_valid, eco_foliage, eco_stress, eco_valid, pixel_noise);
	surface = apply_land_material_overlays(
		surface, biome, cover, current_temp, elev, moist, dyn_snow, dyn_valid, scals.g);

	return shade_land_surface(surface, uv, lat_signed);
}
