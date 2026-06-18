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
		float elev,
		vec2 wp,
		vec2 uv,
		vec4 scals) {
	vec3 col;

	// LAND 1.1：底色 = hypsometric × biome hue × procedural detail
	col = hypsometric_tint(elev, false);
	col = biome_hue_modulate(col, biome);
	col *= procedural_biome_detail(biome, wp);

	// [river-render-restore 2026-06-19] 河流 SDF 视觉层重新接回：flow 来自 flow_tex（scals.g）。
	float flow = scals.g;
	float river_t_raw = smoothstep(river_threshold_low, river_threshold_high, flow);
	float river_t = river_t_raw;
	float outline_t = smoothstep(river_threshold_low * 0.78, river_threshold_low, flow)
			* (1.0 - smoothstep(river_threshold_high, min(river_threshold_high + 0.22, 1.0), flow));
	if (river_t > 0.001 && river_flow_enabled && river_flow_speed > 0.001 && visual_quality >= 1) {
		float pulse = 1.0 + 0.055 * sin(dot(wp, vec2(0.35, 0.42)) - world_time * 0.55);
		river_t = clamp(river_t * pulse, 0.0, 1.0);
	}
	float river_depth_w = smoothstep(0.18, 1.0, river_t_raw);
	vec3 river_surface = mix(river_color * vec3(1.10, 1.08, 1.02), color_mid_ocean, 0.18);
	vec3 river_deep = mix(river_color * vec3(0.72, 0.84, 0.98), color_deep_ocean, 0.20);
	vec3 river_body = mix(river_surface, river_deep, river_depth_w * 0.42);
	vec3 river_edge_col = mix(river_outline_color, river_color * vec3(0.82, 0.95, 1.05), 0.32);
	col = mix(col, river_edge_col, outline_t * 0.50 * river_strength);
	col = mix(col, river_body, river_t * river_strength);

	// LAND 1.3：河流顺坡流动明暗（Water Visual Overhaul）
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

	// LAND 1.4：等高线 basecolor（仅 contour_enabled）
	if (contour_enabled) {
		float contour_phase = fract(elev / max(contour_step, 0.001));
		float dist = abs(contour_phase - 0.5);
		float contour_t = smoothstep(0.50, 0.42, dist);
		col = mix(col, contour_color, contour_t * contour_strength);
	}

	// LAND 1.5：Normal / roughness / AO / metallic
	vec3 normal = compute_terrain_normal(uv, visual_quality);
	float roughness = biome_roughness(biome);
	float ao = mix(0.92, DEFAULT_AO_LAND, clamp(normal.z, 0.0, 1.0));
	return make_surface_params(col, normal, roughness, DEFAULT_METALLIC_LAND, ao);
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 2：变色层（material modifiers）—— 4 个独立 helper
// ───────────────────────────────────────────────────────────────────────
//   旧的 13 参 / 130 行单函数被拆为 4 个职责清晰的 stage helper：
//     2.1 apply_seasonal_vegetation_tint  季节性植被色
//     2.2 apply_moisture_tint             动态湿度调制
//     2.3 apply_vegetation_axis_tint      植被轴 tint
//     2.4 apply_ecology_tint              生态可视化
//   新增 stage 只需追加一个 helper + 在 apply_land_material_modifiers 中加一行。
// ═══════════════════════════════════════════════════════════════════════

// ─── LAND 2.1：季节性植被色（南北半球软混 + 物候相位扰动） ─────────────
SurfaceParams apply_seasonal_vegetation_tint(SurfaceParams surface, LandModInputs i) {
	int biome = i.biome;
	if (!(biome == B_FOREST || biome == B_GRASSLAND || biome == B_HILL || biome == B_PLAIN
			|| biome == B_TAIGA || biome == B_SAVANNA || biome == B_STEPPE)) {
		return surface;
	}
	vec3 col = surface.base_color;

	// 让真实 vegetation_vitality 调制季节振幅。dyn_valid=0 时取中性 1.0。
	// P0-A：vitality_amp 下限抬到 0.85，让低 vitality 像素仍保留可见的换季。
	float vitality_w = mix(1.0, i.dyn_vitality, i.dyn_valid);
	float vitality_amp = mix(0.85, 1.20, smoothstep(0.20, 0.95, vitality_w));

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

// ─── LAND 2.2：动态湿度调制（dyn_valid 真值为前提） ─────────────────────
SurfaceParams apply_moisture_tint(SurfaceParams surface, LandModInputs i) {
	if (i.dyn_valid <= 0.5) {
		return surface;
	}
	// P0-B：把调制强度从 0.18 抬到 0.55，让暴雨/干旱期颜色变化成为可一眼看到的视觉反馈。
	// N2: 让"干湿边界"破碎成斑驳而非整片渐变。
	float moist_jitter = (i.pixel_noise.b - 0.5) * 0.30;
	float wet_mix = clamp(smoothstep(0.10, 0.90, i.moist) + moist_jitter, 0.0, 1.0);
	vec3 dry_tint   = vec3(1.18, 0.92, 0.62);   // 干旱：明显黄褐
	vec3 wet_tint_v = vec3(0.78, 1.08, 0.82);   // 湿润：明显深墨绿
	vec3 wet_tint = mix(dry_tint, wet_tint_v, wet_mix);
	float wet_amp = mix(0.70, 1.20, i.pixel_noise.r);
	// |moist - 0.5| ∈ [0, 0.5]，× 1.1 后 ∈ [0, 0.55]
	surface.base_color *= mix(vec3(1.0), wet_tint,
			clamp(abs(i.moist - 0.5) * 1.1 * wet_amp, 0.0, 0.55));
	return surface;
}

// ─── LAND 2.3：植被轴 tint（vegetation_axis_strength） ─────────────────
// LAND 2.3: climate / altitude / wind tint; pure ALU, no extra texture fetch.
SurfaceParams apply_climate_relief_tint(SurfaceParams surface, LandModInputs i) {
	float temp_w = clamp((i.current_temp - 0.5) * 2.0, -1.0, 1.0);
	vec3 cool_tint = vec3(0.84, 0.93, 1.08);
	vec3 warm_tint = vec3(1.12, 0.94, 0.78);
	float temp_amp = mix(0.055, 0.125, abs(temp_w));
	surface.base_color *= mix(
			vec3(1.0),
			(temp_w >= 0.0) ? warm_tint : cool_tint,
			temp_amp);

	float land_h = clamp((i.elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	float alpine_w = smoothstep(0.46, 0.96, land_h);
	surface.base_color *= mix(vec3(1.0), vec3(0.88, 0.92, 0.96), alpine_w * 0.18);

	float wind_mag = clamp(length(i.wind_v), 0.0, 1.4);
	float wind_dry = wind_mag * (1.0 - smoothstep(0.36, 0.84, i.moist));
	surface.base_color *= mix(vec3(1.0), vec3(1.10, 0.98, 0.86), wind_dry * 0.10);
	return surface;
}

// LAND 2.4: vegetation axis tint.
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

// ─── LAND 2.4：生态可视化层（foliage / stress / growth / transition） ─
SurfaceParams apply_ecology_tint(SurfaceParams surface, LandModInputs i) {
	if (ecology_visual_strength <= 0.001
			|| i.eco_valid <= 0.5
			|| i.veg == V_NONE) {
		return surface;
	}
	float eco_q = float(min(ecology_visual_quality, visual_quality));
	float foliage_noise = (eco_q >= 1.0) ? i.pixel_noise.g : 0.5;
	float patch_noise   = (eco_q >= 2.0) ? i.pixel_noise.a : 0.5;

	float foliage = clamp(i.eco_foliage + (foliage_noise - 0.5) * 0.22
			+ (patch_noise - 0.5) * 0.12, 0.0, 1.0);
	float stress = clamp(i.eco_stress + (patch_noise - 0.5) * 0.18, 0.0, 1.0);
	float transition_w = smoothstep(0.02, 0.75, i.eco_transition);

	vec3 live_tint = mix(vec3(0.88, 1.04, 0.82), vec3(0.70, 1.12, 0.72), foliage);
	vec3 dry_tint  = mix(vec3(1.10, 0.96, 0.70), vec3(1.23, 0.86, 0.56), stress);
	float density_w = foliage_density_strength * ecology_visual_strength
			* smoothstep(0.10, 0.85, foliage);

	vec3 col = surface.base_color;
	col *= mix(vec3(1.0), live_tint, density_w * (1.0 - stress * 0.55));
	col *= mix(vec3(1.0), dry_tint,
			ecology_visual_strength * smoothstep(0.22, 0.95, stress) * 0.62);
	vec3 new_growth_tint = mix(vec3(1.0), vec3(0.82, 1.12, 0.78),
			smoothstep(0.56, 0.82, i.eco_growth));
	col *= mix(vec3(1.0), new_growth_tint,
			transition_w * ecology_visual_strength * 0.28);
	col = mix(col, col * vec3(0.93, 0.98, 0.88),
			transition_w * (1.0 - foliage) * ecology_visual_strength * 0.35);
	surface.base_color = col;
	return surface;
}

// ─── LAND 2：调度器（顺序固定，新增 stage 在此处加一行即可） ────────────
SurfaceParams apply_land_material_modifiers(SurfaceParams surface, LandModInputs i) {
	surface = apply_seasonal_vegetation_tint(surface, i);
	surface = apply_moisture_tint(surface, i);
	surface = apply_climate_relief_tint(surface, i);
	surface = apply_vegetation_axis_tint(surface, i);
	surface = apply_ecology_tint(surface, i);
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
	// 60 FPS 优化（2026-06-15）：mobile LOW/MID 跳过 shore neighborhood 邻域 sample
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	// 无 halo
#else
	ShoreSamples shore_samp = sample_shore_neighborhood(uv);
	ShoreHaloResult shore_halo_r = compute_shore_halo(shore_samp, elev, scals.g, 0);
	col = mix(col, shore_halo_r.halo_color, shore_halo_r.halo_weight);
#endif

	// LAND 3.1.b：统一雪盖色（季节性雪线 / 真实积雪 / BLIZZARD 新雪）
	col = apply_snow_cover(
		col, biome, veg, current_temp, elev, false, moist, wp, uv,
		dyn_snow, dyn_valid, eco_valid, eco_stress, eco_foliage, pixel_noise);

	// LAND 3.1.c：覆盖物轴（FLOODING / PERMAFROST / GLACIER）
	// SNOW / SEA_ICE 已由雪盖 / 海面主路径处理，cover_overlay 内部返回 0 跳过。
	// N5: 加噪声扰动让冰川/永冻土/洪水都呈\"斑驳大块\"而非均匀贴片。
	if (cover_axis_strength > 0.001) {
		vec4 ov = cover_overlay(cover);
		if (ov.a > 0.001) {
			float cov_low = fbm(wp * 0.055 + vec2(-13.0, 41.0), 2);
			float cov_hi  = fbm(wp * 0.26  + vec2(73.0, -19.0), 1);
			float cov_amp = mix(0.55, 1.20, cov_low);
			vec3  cov_rgb = ov.rgb * mix(0.94, 1.06, cov_hi);
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
		float dyn_valid) {
	float snow_w = estimate_land_snow_material_weight(biome, current_temp, elev, moist, dyn_snow, dyn_valid);
	if (snow_w > 0.001) {
		surface.normal    = normalize(mix(surface.normal, vec3(0.0, 0.0, 1.0), snow_w * 0.35));
		surface.roughness = mix(surface.roughness, 0.34, snow_w);
		surface.ao        = mix(surface.ao, 0.96, snow_w);
		surface.metallic  = mix(surface.metallic, DEFAULT_METALLIC_SNOW, snow_w);
	}
	if (cover == CV_GLACIER) {
		surface.roughness = min(surface.roughness, 0.26);
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
vec3 shade_land_surface(SurfaceParams surface) {
	LightingContext lc = make_lighting_context(AMBIENT_FLOOR_LAND);
	return evaluate_brdf(surface, lc, SPEC_MAX_LAND_LEGACY, SPEC_MIN_LAND_LEGACY);
}

// ═══════════════════════════════════════════════════════════════════════
// LAND 5：顶层调度
// ═══════════════════════════════════════════════════════════════════════
vec3 render_land_pipeline(
		int biome,
		int veg,
		int cover,
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
	SurfaceParams surface = compute_land_base_surface(biome, elev, wp, uv, scals);

	LandModInputs mi;
	mi.biome = biome;
	mi.veg = veg;
	mi.elev = elev;
	mi.moist = moist;
	mi.lat_signed = lat_signed;
	mi.current_temp = current_temp;
	mi.wind_v = wind_v;
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
		surface, biome, cover, current_temp, elev, moist, dyn_snow, dyn_valid);

	return shade_land_surface(surface);
}
