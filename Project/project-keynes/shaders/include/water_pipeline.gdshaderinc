// water_pipeline.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   水面渲染管线。按 PBR-ish SurfaceParams 组织：
//     base surface (12 阶段 helper) → overlay surface (shore halo + foam + ice)
//     → shade via evaluate_brdf (BRDF 共用) → apply_water_specials (caustics/sparkle/fresnel)
//
// 调用方（Who）
//   - world_map.gdshader fragment() 在 is_water 分支调用 render_water_pipeline。
//
// 依赖（Why）
//   uniforms / material_constants / common_noise / height / biome_color /
//   weather_front / water / hillshade_tod / surface_params / shore_common / brdf。
//
// 性能（Cost）
//   主要 fetch：5×5 邻域 (visual_quality≥1) 用于 offshore，水侧 biome_weights；
//   海冰来自 fragment 入口解码的 dyn_lut.a。BRDF 已抽到 brdf.gdshaderinc。
//   apply_water_specials 在 day_night_enabled 关时被旁路。
// ─────────────────────────────────────────────────────────────────────────


// ═══════════════════════════════════════════════════════════════════════
// SEA 0: 容器 struct —— 在 base surface 12 helper 之间携带状态
// ═══════════════════════════════════════════════════════════════════════
//   把 compute_water_base_surface 内部的 working state 显式化，避免每个 helper
//   传 10+ 参数。所有分量在调度器中只构造一次。
// ─────────────────────────────────────────────────────────────────────
struct WaterStageCtx {
	int   biome;
	float elev;
	vec2  wp;            // 原 world position（不带 warp）
	vec2  wpw;           // 经 water_domain_warp 后的 world position
	vec2  uv;
	vec4  scals;
	float lat_signed;
	float current_temp;
	vec2  ocean_current_v;
	vec2  wind_v;
	int   quality;
	int   detail_oct;
	float depth_t;       // 1 - elev/sea_level
	float offshore;      // 邻域离岸度 [0,1]
	float offshore_depth;// 综合离岸 + depth_t
	float deep_layer_w;
	float ice_frac;      // 海冰浓度（dyn_atlas_smooth.a；fragment 入口已采样，避免冗余 sample）
};

// 软权重 + 派生标量
struct WaterWeights {
	float w_lake;
	float w_reef;
	float w_kelp;
	float w_ice;
	float open_ocean_w;
};


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.0: SurfaceParams 构造器（材质参数装配）
// ═══════════════════════════════════════════════════════════════════════
//   把 base color + normal + biome 派生 roughness/metallic/ao。
//
//   注：相比 v9 关键改动 —— LAKE 不再 max(gloss_eff, 72.0) 绕过 roughness，
//   而是在 build_water_normal_and_calm 里直接给 LAKE 写入更小的 roughness
//   (~0.12)，让 BRDF 自然得到锐利高光，去掉 land/water spec 双路径分叉。
// ─────────────────────────────────────────────────────────────────────
SurfaceParams make_water_surface_params(
		vec3 base_color,
		vec3 normal,
		int biome,
		float w_ice,
		float w_lake,
		float w_kelp) {
	// [sea-ice-render-source-unify 阶段 A] 海冰 roughness 完全由 w_ice 连续驱动，
	// 不再依赖 biome == B_SEA_ICE 硬切换。w_ice 来自 dyn_atlas_smooth.a 的连续
	// sea_ice_fraction，与 UI/info_panel 同源；biome 仍按其他类型（lake/reef/kelp）
	// 决定基础粗糙度，海冰 mix 走 w_ice 路径。
	float roughness = 0.20;
	if (biome == B_LAKE) {
		roughness = 0.12;          // ⟵ 平静湖面：更光滑，BRDF 自动产生紧高光
	} else if (biome == B_REEF) {
		roughness = 0.30;
	} else if (biome == B_KELP) {
		roughness = 0.46;
	}
	roughness = mix(roughness, 0.34, clamp(w_ice, 0.0, 1.0));
	roughness = mix(roughness, 0.50, clamp(w_kelp * 0.35, 0.0, 1.0));
	float ao = mix(0.98, 1.0, clamp(normal.z, 0.0, 1.0));
	ao = mix(ao, 0.96, clamp(w_lake * 0.25 + w_ice * 0.35, 0.0, 1.0));

	// metallic：水默认非金属；冰盖区给一点金属感（菲涅尔更明显）。
	float metallic = mix(DEFAULT_METALLIC_WATER, DEFAULT_METALLIC_ICE, clamp(w_ice, 0.0, 1.0));
	return make_surface_params(base_color, normal, roughness, metallic, ao);
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.1: compute_offshore_depth ——离岸度 + 深度梯度准备
// ═══════════════════════════════════════════════════════════════════════
//   从 5×5（quality≥1）/ 3×3 邻域采高度图，统计 deep_cnt，得到 offshore；
//   并合并 depth_t = 1 - elev/sea_level，得到 offshore_depth。
// ─────────────────────────────────────────────────────────────────────
void compute_offshore_depth(inout WaterStageCtx ctx) {
	vec2 tx = 1.0 / hm_resolution;
	float deep_cnt = 0.0;
	// 60 FPS 优化（2026-06-15 三档变体）：mobile 三档分别走不同 sample 路径。
	// LOW (≤4 sample/像素)：直接用已有 ctx.elev 判断海陆，0 个额外 sample
	// MID (≤6)：center 1 个 sample（实际只用 ctx.elev，跟 LOW 等价但保留 hook）
	// HIGH (≤9)：plus pattern 4 个邻居 + center = 5 sample
	// Desktop：原 5×5 / 3×3 邻域 runtime if 路径不动
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	// LOW/MID：跳过邻域 sample，直接根据 ctx.elev 阈值估计 offshore
	// 视觉损失：offshore_depth 在 cell 边界有阶梯，看起来海岸线变硬切
	ctx.offshore = step(ctx.elev, sea_level - 0.02);
#elif defined(MOBILE_QUALITY_HIGH)
	// HIGH：plus pattern 5 sample（center + 4 邻居），无对角
	float c  = decode_height_rg8(ctx.uv);
	float l  = decode_height_rg8(ctx.uv + vec2(-tx.x, 0.0));
	float r  = decode_height_rg8(ctx.uv + vec2( tx.x, 0.0));
	float u  = decode_height_rg8(ctx.uv + vec2(0.0, -tx.y));
	float d  = decode_height_rg8(ctx.uv + vec2(0.0,  tx.y));
	deep_cnt = step(c, sea_level - 0.02) + step(l, sea_level - 0.02)
			+ step(r, sea_level - 0.02) + step(u, sea_level - 0.02)
			+ step(d, sea_level - 0.02);
	ctx.offshore = clamp(deep_cnt / 5.0, 0.0, 1.0);
#else
	// Desktop：q2 用 3x3，q1 用 plus pattern，q0 直接用中心高度。
	if (ctx.quality >= 2) {
		for (int oy = -1; oy <= 1; oy++) {
			for (int ox = -1; ox <= 1; ox++) {
				float eh = decode_height_rg8(ctx.uv + vec2(float(ox), float(oy)) * tx);
				deep_cnt += step(eh, sea_level - 0.02);
			}
		}
		ctx.offshore = clamp(deep_cnt / 9.0, 0.0, 1.0);
	} else if (ctx.quality >= 1) {
		float c = ctx.elev;
		float l = decode_height_rg8(ctx.uv + vec2(-tx.x, 0.0));
		float r = decode_height_rg8(ctx.uv + vec2( tx.x, 0.0));
		float u = decode_height_rg8(ctx.uv + vec2(0.0, -tx.y));
		float d = decode_height_rg8(ctx.uv + vec2(0.0,  tx.y));
		deep_cnt = step(c, sea_level - 0.02) + step(l, sea_level - 0.02)
				+ step(r, sea_level - 0.02) + step(u, sea_level - 0.02)
				+ step(d, sea_level - 0.02);
		ctx.offshore = clamp(deep_cnt / 5.0, 0.0, 1.0);
	} else {
		ctx.offshore = step(ctx.elev, sea_level - 0.02);
	}
#endif
	ctx.depth_t = 1.0 - clamp(ctx.elev / max(sea_level, 0.001), 0.0, 1.0);
	ctx.offshore_depth = clamp(ctx.offshore * 0.68 + smoothstep(0.00, 0.68, ctx.depth_t) * 0.32, 0.0, 1.0);
	ctx.deep_layer_w = smoothstep(0.36, 1.0, ctx.offshore_depth);
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.2: apply_water_depth_gradient —— 三段离岸色 + lagoon lift
// ═══════════════════════════════════════════════════════════════════════
//   用 water_depth_gradient 替换旧的三段 if，得到统一深浅梯度底色；
//   浅水区给 lagoon 偏青提亮。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_water_depth_gradient(vec3 col, WaterStageCtx ctx) {
	vec3 tier_color = water_depth_gradient(ctx.offshore_depth, ctx.elev);
	float water_fill_w = smoothstep(0.02, 0.82, 0.58 + ctx.offshore_depth * 0.34);
	col = mix(col, tier_color, water_fill_w);
	float lagoon_lift = 1.0 - smoothstep(0.10, 0.56, ctx.offshore_depth);
	col = mix(col, col * vec3(0.90, 1.07, 1.10), lagoon_lift * 0.14);
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.3: apply_global_water_ripple —— 全局低频水色起伏
// ═══════════════════════════════════════════════════════════════════════
//   所有水体共享同一层 ripple，边界无感；deep_layer_w 控制深海额外色温。
//   visual_quality≥1 时叠加慢速 color_block（cartoon 强调）。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_global_water_ripple(vec3 col, WaterStageCtx ctx) {
	// 60 FPS 优化（2026-06-15）：mobile 三档变体
	// LOW: 完全跳过（0 sample）→ 海面纯色
	// MID/HIGH: 跑 base_ripple fbm（1 sample）
	// Desktop: 跑 base_ripple + deep_ripple + color_block（3 sample）
#ifndef MOBILE_QUALITY_LOW
	float base_ripple = fbm(ctx.wpw * 0.008 + vec2(31.0, 7.0), 2);
	col *= 1.0 + (base_ripple - 0.5) * mix(0.050, 0.082, ctx.deep_layer_w);
#endif
	vec3 cartoon_chroma = mix(vec3(0.78, 1.20, 1.18), vec3(0.70, 0.96, 1.38),
								smoothstep(0.12, 1.0, ctx.offshore_depth));
	col *= mix(vec3(1.0), cartoon_chroma, water_cartoon_color_strength * 0.26);
	// deep_ripple + color_block 仅 desktop 跑
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
	float deep_ripple = fbm(ctx.wpw * 0.0038 + vec2(-47.0, 23.0), 2);
	vec3 deep_variation = mix(vec3(0.92, 1.03, 1.14), vec3(1.08, 0.94, 1.05), deep_ripple);
	col *= mix(vec3(1.0), deep_variation, ctx.deep_layer_w * 0.115);
	if (water_cartoon_color_strength > 0.001) {
		float color_block = fbm(ctx.wpw * 0.0048 + vec2(world_time * 0.010, -world_time * 0.006), 2);
		vec3 block_tint = mix(vec3(0.80, 1.16, 1.15), vec3(0.92, 0.93, 1.24), color_block);
		col *= mix(vec3(1.0), block_tint, water_cartoon_color_strength * mix(0.10, 0.18, ctx.deep_layer_w));
	}
#endif
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.4: compute_water_biome_weights —— biome 软权重
// ═══════════════════════════════════════════════════════════════════════
//   3×3 邻域 + radius-aware smoothstep + 海冰 atlas 滞后；special_sum 归一。
//   返回 WaterWeights：lake/reef/kelp/ice + open_ocean_w（深海占比）。
// ─────────────────────────────────────────────────────────────────────
WaterWeights compute_water_biome_weights(WaterStageCtx ctx) {
	WaterWeights ww;
	vec4 bw;
	float water_boundary_softness = clamp(water_biome_blend_radius / 2.2, 0.0, 1.0);
	// 60 FPS 优化（2026-06-15）：所有 mobile tier 都 hard-cut 跳过 3×3 邻域。
	// biome 软过渡只在桌面端有，移动端 biome 边界硬切（视觉损失小，性能省 9 sample）。
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID) || defined(MOBILE_QUALITY_HIGH)
	bw = vec4(
		ctx.biome == B_LAKE    ? 1.0 : 0.0,
		ctx.biome == B_REEF    ? 1.0 : 0.0,
		ctx.biome == B_KELP    ? 1.0 : 0.0,
		0.0  // ice 走 dyn_atlas_smooth.a，不读 bw.w
	);
#else
	// Desktop：保留 radius-aware 3×3 邻域采样
	if (water_biome_blend_radius > 0.001) {
		float blend_radius_eff = water_biome_blend_radius * mix(1.0, 1.45, water_transition_softness);
		bw = water_biome_weights(ctx.uv, 1.0 / hm_resolution, blend_radius_eff);
	} else {
		bw = vec4(
			ctx.biome == B_LAKE    ? 1.0 : 0.0,
			ctx.biome == B_REEF    ? 1.0 : 0.0,
			ctx.biome == B_KELP    ? 1.0 : 0.0,
			0.0
		);
	}
#endif
	float transition_soft = clamp(max(water_boundary_softness, water_transition_softness), 0.0, 1.0);
	float blend_entry = mix(0.28, 0.05, transition_soft);
	float blend_full  = mix(0.92, 0.56, transition_soft);
	ww.w_lake = smoothstep(blend_entry, blend_full, bw.x);
	ww.w_reef = smoothstep(blend_entry, blend_full, bw.y);
	ww.w_kelp = smoothstep(blend_entry, blend_full, bw.z);

	// [sea-ice-render-source-unify 阶段 A] 海冰单源化（治本方案）：
	//   - 数据源：dyn_atlas_smooth_atlas.a（box-blurred sea_ice_fraction），
	//     与 dynamic_cell_atlas.a 同 byte 量化，跨 cell 平滑无 hex 阶梯。
	//   - 与 UI/info_panel 完全同源（cell.sea_ice_fraction → q01_byte_ice）。
	//   - smoothstep(0.22, 0.72, frac)：低浓度薄冰保留为过渡，不提前刷成满白。
	//   - 不再读 ice_state_atlas（保留为调试通道，主路径不消费）。
	//   - 不再有 `if (biome == B_SEA_ICE) max(w_ice, 0.28)` 兜底——这是
	//     旧路径的根因 bug：当 fraction=0 但 terrain==SEA_ICE 时会强制冰；
	//     当 fraction=1 但 terrain==OCEAN 时却无冰。
	// 60 FPS 优化（2026-06-15）：从 ctx.ice_frac 取（fragment 入口 dyn_atlas_smooth.a 已采样），
	// 避免冗余 texture sample。之前 line 250 重复采一次 dyn_atlas_smooth.a 是 1 个白浪费 sample。
	float ice_frac = ctx.ice_frac;
	// 60 FPS 优化（2026-06-15）：mobile 三档全砍 ridge_n fbm（海冰边缘破碎扰动）。
	float ridge_offset = 0.0;
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
	float ridge_n = fbm(ctx.wpw * 0.045 + vec2(-71.0, 23.0), 2);
	ridge_offset = (ridge_n - 0.5) * 0.06;
#endif
	ww.w_ice = clamp(smoothstep(0.22, 0.72, ice_frac + ridge_offset), 0.0, 1.0);
	// 归一以避免叠加过曝
	float special_sum = max(ww.w_lake + ww.w_reef + ww.w_kelp + ww.w_ice, 1.0);
	ww.w_lake /= special_sum;
	ww.w_reef /= special_sum;
	ww.w_kelp /= special_sum;
	ww.w_ice  /= special_sum;

	ww.open_ocean_w = clamp(
		(1.0 - ww.w_lake - ww.w_reef * 0.62 - ww.w_kelp * 0.78 - ww.w_ice)
				* smoothstep(0.26, 0.92, ctx.offshore_depth),
		0.0, 1.0);
	return ww;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.5: apply_open_ocean_patch —— gyre 大色块
// ═══════════════════════════════════════════════════════════════════════
//   open ocean 中两层 fbm 相乘形成"云影感"色块拼贴；
//   patch_boost=deep_ocean_patch_boost*deep_ocean_color_richness。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_open_ocean_patch(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.open_ocean_w > 0.001 && water_cartoon_color_strength > 0.001)) return col;
	// 60 FPS 优化（2026-06-15）：mobile 三档全跳 gyre 大色块（2 fbm）。
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID) || defined(MOBILE_QUALITY_HIGH)
	return col;
#else
	int ocean_patch_oct = (ctx.quality >= 2) ? 3 : 2;
	float gyre_a = fbm(ctx.wpw * 0.0056 + vec2(13.0, -31.0), ocean_patch_oct);
	float gyre_b = fbm(ctx.wpw * 0.012  + vec2(-29.0, 47.0), 1);
	if (ctx.quality >= 1) {
		gyre_b = fbm(ctx.wpw * 0.012 + vec2(world_time * 0.012, -world_time * 0.007), 2);
	}
	float gyre_mix = smoothstep(0.20, 0.86, gyre_a * 0.72 + gyre_b * 0.28);
	float patch_boost = clamp(deep_ocean_patch_boost * deep_ocean_color_richness, 0.0, 1.0);
	vec3 cobalt_patch = vec3(0.10, 0.20, 0.40);
	vec3 teal_patch   = vec3(0.12, 0.32, 0.44);
	vec3 violet_patch = vec3(0.14, 0.16, 0.42);
	vec3 cobalt_boost = vec3(0.08, 0.16, 0.46);
	vec3 teal_boost   = vec3(0.10, 0.42, 0.42);
	vec3 violet_boost = vec3(0.16, 0.14, 0.46);
	cobalt_patch = mix(cobalt_patch, cobalt_boost, patch_boost);
	teal_patch   = mix(teal_patch,   teal_boost,   patch_boost);
	violet_patch = mix(violet_patch, violet_boost, patch_boost);
	vec3 ocean_patch = mix(cobalt_patch, teal_patch, gyre_mix);
	ocean_patch = mix(ocean_patch, violet_patch,
		smoothstep(0.70, 1.0, ctx.offshore_depth) * (1.0 - gyre_mix) * 0.55);
	float patch_w = ww.open_ocean_w * water_cartoon_color_strength * mix(0.42, 0.66, gyre_mix);
	col = mix(col, ocean_patch, patch_w);
	col *= 1.0 + (gyre_mix - 0.5) * ww.open_ocean_w * water_cartoon_color_strength * 0.18;
	return col;
#endif
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.6: apply_deep_ocean_layered_tint —— latitude / current / abyss 三层
// ═══════════════════════════════════════════════════════════════════════
//   仅在 open_ocean_w>0 时叠加；用 lat_signed/current_temp 决定色温带，
//   visual_quality≥1 才启用 current tint。叠加后 clamp ≤1.6 防过曝。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_deep_ocean_layered_tint(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.open_ocean_w > 0.001 && deep_ocean_color_richness > 0.001)) return col;

	vec3 lat_tint = deep_ocean_latitude_tint(ctx.lat_signed, ctx.current_temp);
	col *= mix(vec3(1.0), lat_tint, ww.open_ocean_w);

	if (ctx.quality >= 1) {
		float flow_mag = length(ctx.ocean_current_v);
		if (flow_mag > 0.05) {
			vec3 cur_tint = deep_ocean_current_tint(ctx.ocean_current_v, ctx.lat_signed, flow_mag);
			col *= mix(vec3(1.0), cur_tint, ww.open_ocean_w * ocean_current_strength);
		}
	}
	vec3 ab_tint = deep_ocean_abyss_tint(ctx.offshore_depth);
	col *= mix(vec3(1.0), ab_tint, ww.open_ocean_w);
	col = clamp(col, vec3(0.0), vec3(1.6));
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.7: apply_lake_features —— 平静低对比偏青绿湖水
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_lake_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_lake > 0.001)) return col;

	vec3 lake_cartoon = mix(lake_water_color, vec3(0.13, 0.66, 0.72), water_cartoon_color_strength * 0.55);
	vec3 lake_surface = mix(water_depth_gradient(ctx.offshore_depth * 0.72, ctx.elev), lake_cartoon, 0.66);
	float lake_depth_t = smoothstep(0.04, 0.46, ctx.depth_t);
	vec3 lake_deep = lake_cartoon * vec3(0.72, 0.90, 0.96);
	vec3 lake_col = mix(lake_surface, lake_deep, lake_depth_t * 0.42);
	float lake_ripple = fbm(ctx.wpw * 0.018 + vec2(7.0, -19.0), ctx.detail_oct);
	float lake_glass = 0.5;
	if (ctx.quality >= 1) {
		lake_glass = fbm(ctx.wpw * 0.006 + vec2(-23.0, 11.0), ctx.detail_oct);
	}
	lake_col *= 1.0 + (lake_ripple - 0.5) * 0.026 + (lake_glass - 0.5) * 0.016;
	lake_col = mix(lake_col, lake_surface, 0.18);
	col = mix(col, lake_col, ww.w_lake * 0.92);
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.8: apply_reef_features —— 浅青绿 + 大尺度珊瑚斑
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_reef_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_reef > 0.001)) return col;

	float reef_depth = clamp(ctx.offshore_depth * 0.36 + ctx.depth_t * 0.16, 0.0, 1.0);
	vec3 reef_lagoon = mix(vec3(0.38, 0.82, 0.78), vec3(0.32, 0.94, 0.84), water_cartoon_color_strength * 0.55);
	vec3 reef_outer = mix(water_depth_gradient(clamp(ctx.offshore_depth * 0.82, 0.0, 1.0), ctx.elev),
							vec3(0.14, 0.58, 0.68), 0.34);
	vec3 reef_base = mix(reef_lagoon, reef_outer, smoothstep(0.12, 0.88, reef_depth));
	float coral_soft = 0.5;
	float reef_sheen = 0.5;
	if (ctx.quality >= 1) {
		float coral_spots = voronoi_cell(ctx.wpw * 0.24);
		coral_soft = smoothstep(0.04, 0.74, coral_spots);
	}
	if (ctx.quality >= 2) {
		reef_sheen = fbm(ctx.wpw * 0.018 + vec2(17.0, 29.0), 2);
	}
	vec3 coral_tint = mix(vec3(0.32, 0.74, 0.67), vec3(0.22, 0.58, 0.60),
						   smoothstep(0.30, 0.88, ctx.offshore_depth));
	vec3 reef_col = mix(reef_base * 1.035, coral_tint, coral_soft * 0.16);
	reef_col *= 1.0 + (reef_sheen - 0.5) * 0.022;
	float reef_edge_feather = mix(0.66, 0.88, 1.0 - smoothstep(0.22, 0.92, ctx.offshore_depth));
	float reef_mix_w = ww.w_reef * reef_edge_feather;
	col = mix(col, reef_col, reef_mix_w);
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.9: apply_kelp_features —— 深绿 + 顺洋流的宽带状明暗
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_kelp_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_kelp > 0.001)) return col;

	vec3 kelp_base = mix(water_depth_gradient(ctx.offshore_depth, ctx.elev),
						  vec3(0.06, 0.36, 0.30), 0.62);
	vec2 oc_k = ctx.ocean_current_v;
	vec2 oc_norm = (length(oc_k) > 0.05) ? normalize(oc_k) : vec2(1.0, 0.0);
	vec2 perp_k = vec2(-oc_norm.y, oc_norm.x);
	float along_k = dot(ctx.wpw, oc_norm) * 0.030;
	float across_k = dot(ctx.wpw, perp_k) * 0.095;
	float kelp_streak = 0.5;
	if (ctx.quality >= 1) {
		kelp_streak = fbm(vec2(along_k + world_time * 0.035, across_k), ctx.detail_oct);
	}
	float kelp_patch = fbm(ctx.wpw * 0.018 + vec2(5.0, -41.0), ctx.detail_oct);
	vec3 kelp_col = mix(kelp_base, vec3(0.05, 0.28, 0.23), kelp_patch * 0.26);
	kelp_col *= mix(0.94, 1.045, kelp_streak);
	col = mix(col, kelp_col, ww.w_kelp * 0.86);
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.10: apply_sea_ice_features —— 冷蓝白冰盖 + 低对比裂纹
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_sea_ice_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_ice > 0.001)) return col;

	// [sea-ice-render-source-unify 阶段 A] 调试可观测性：
	// 打开 DEBUG_SEA_ICE 宏（在 world_map.gdshader 顶部 #define DEBUG_SEA_ICE）即可
	// 把 w_ice 强度用纯红覆盖在水面上，用于目视核验"shader 端 w_ice 与
	// dyn_atlas_smooth.A 是否吻合预期的海冰分布"。生产构建保持注释。
#ifdef DEBUG_SEA_ICE
	return mix(col, vec3(1.0, 0.0, 0.0), clamp(ww.w_ice, 0.0, 1.0));
#endif

	// [需求5 2026-06-19] 海冰转明显冰蓝青(原 0.88,0.94,0.97 近白，与陆地雪盖几乎同色难分)；
	// 降低 mix 比例让底层海水蓝透出更多。配合 snow_cover 那侧改暖白 → 海冰冷蓝 vs 雪暖白可区分。
	vec3 ice_base = mix(water_depth_gradient(ctx.offshore_depth * 0.65, ctx.elev),
						 vec3(0.66, 0.81, 0.95), 0.84);
	float crack_factor = 0.55;
	if (ctx.quality >= 1) {
		float crack = voronoi_cell(ctx.wpw * 0.34);
		crack_factor = smoothstep(0.02, 0.16, crack);
	}
	float ice_noise = fbm(ctx.wpw * 0.12 + vec2(-9.0, 31.0), ctx.detail_oct);
	vec3 ice_col = mix(ice_base * 0.76, ice_base * 1.08, crack_factor);
	ice_col *= mix(0.94, 1.055, ice_noise);
	float ice_edge = smoothstep(0.18, 0.82, ww.w_ice);
	col = mix(col, ice_col, clamp(ww.w_ice * 1.05 + ice_edge * 0.05, 0.0, 0.94));
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.11: apply_shallow_transparency —— 透底/浅水介质
// ═══════════════════════════════════════════════════════════════════════
//   修改水体 albedo（不作为最终覆盖或光照）；coastal+lake+reef 区显露
//   substrate_col。kelp/ice 抑制此层。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_shallow_transparency(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(shallow_transparency_enabled && ctx.quality >= 1)) return col;

	float depth_clarity = 1.0 - smoothstep(0.28, 0.86, ctx.offshore_depth);
	float coastal_clarity = (ctx.biome == B_COAST) ? 1.0 : 0.0;
	float lake_clarity = ww.w_lake * (1.0 - smoothstep(0.16, 0.62, ctx.depth_t));
	float reef_clarity = ww.w_reef * 0.42;
	float kelp_guard = 1.0 - ww.w_kelp * 0.70;
	float ice_guard = 1.0 - ww.w_ice;
	float clarity_w = clamp(
		(coastal_clarity * 0.62 + lake_clarity * 0.46 + reef_clarity) * depth_clarity,
		0.0, 0.72) * kelp_guard * ice_guard * shallow_transparency_factor;
	if (clarity_w > 0.001) {
		vec3 substrate_col = mix(color_lowland, color_beach,
								  coastal_clarity * 0.70 + reef_clarity * 0.35);
		substrate_col = mix(substrate_col, lake_water_color * 0.78, ww.w_lake * 0.55);
		vec3 clear_water_col = mix(col, substrate_col, 0.20 + depth_clarity * 0.18);
		clear_water_col = mix(clear_water_col, col * vec3(0.94, 1.02, 1.04), 0.35);
		col = mix(col, clear_water_col, clarity_w);
	}
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.12: apply_ocean_currents —— 数据驱动的洋流条纹 + debug
// ═══════════════════════════════════════════════════════════════════════
//   方向固定来自 vector_atlas.rg；ocean_current_debug 时彩色化方向并叠加
//   upwelling 黄/紫高亮。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_ocean_currents(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ocean_current_enabled && ctx.quality >= 1)) return col;

	vec2 oc = ctx.ocean_current_v;
	float flow_mag = clamp(length(oc), 0.0, 1.0);
	vec2 oc_dir = (flow_mag > 0.035) ? normalize(oc) : normalize(ctx.wind_v + vec2(0.0001, 0.0));
	vec2 oc_side = vec2(-oc_dir.y, oc_dir.x);
	float along = dot(ctx.wp, oc_dir) * mix(0.010, 0.024, water_cartoon_color_strength) + world_time * 0.035;
	float across = dot(ctx.wp, oc_side) * mix(0.060, 0.105, water_cartoon_color_strength);
	int current_oct = (ctx.quality >= 2) ? 2 : 1;
	float lane_low = fbm(vec2(along, across), current_oct);
	float lane_high = fbm(vec2(along * 2.8 + 17.0, across * 0.55 - 31.0), 1);
	float current_lane = smoothstep(0.38, 0.80, lane_low * 0.72 + lane_high * 0.28);
	float non_static = clamp(1.0 - ww.w_ice - ww.w_lake * 0.85, 0.0, 1.0);
	float current_w = ocean_current_strength * non_static
				   * mix(0.48, 1.0, smoothstep(0.08, 0.74, ctx.offshore_depth));
	current_w = clamp(current_w * mix(0.45, 1.0, flow_mag), 0.0, 1.0);
	float streak_amp = ocean_current_debug ? 0.82 : mix(0.24, 0.42, water_cartoon_color_strength);
	vec3 current_tint = mix(vec3(0.78, 1.08, 1.16), vec3(0.50, 0.76, 1.25),
							 smoothstep(0.34, 1.0, ctx.offshore_depth));
	vec3 current_shadow = mix(vec3(1.03, 0.99, 0.92), vec3(0.84, 0.94, 1.10),
							   smoothstep(0.20, 1.0, ctx.offshore_depth));
	col *= mix(1.0, 1.0 + (current_lane - 0.50) * streak_amp, current_w);
	col *= mix(vec3(1.0), mix(current_shadow, current_tint, current_lane), current_w * 0.20);
	if (ocean_current_debug) {
		vec3 dir_tint = vec3(0.5 + oc_dir.x * 0.5, 0.5 + oc_dir.y * 0.3, 0.5 - oc_dir.x * 0.5);
		col = mix(col, dir_tint, 0.28 * ocean_current_strength * non_static);
		float up_raw = texture(ocean_upwelling_tex, ctx.uv).r;
		float up_signed = up_raw * 2.0 - 1.0;
		float up_mag = abs(up_signed);
		if (up_mag > 0.1) {
			vec3 up_color = (up_signed > 0.0)
				? vec3(1.00, 0.90, 0.15)
				: vec3(0.62, 0.25, 0.85);
			col = mix(col, up_color, 0.55 * up_mag * non_static);
		}
	}
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.13: apply_estuary_plume —— 河口羽流
// ═══════════════════════════════════════════════════════════════════════
//   scalar_atlas 已退役，河口羽流只保留入口并自然退化为无效果。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_estuary_plume(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	float river_sdf_water = ctx.scals.g;
	if (!(estuary_plume_strength > 0.001 && river_sdf_water > river_threshold_low * 0.58)) return col;

	vec2 plume_vec = ctx.ocean_current_v + ctx.wind_v * 0.24;
	vec2 plume_dir = (length(plume_vec) > 0.05) ? normalize(plume_vec) : vec2(1.0, 0.0);
	vec2 plume_step = plume_dir * (1.0 / hm_resolution) * mix(3.0, 7.0, water_transition_softness);
	float tail_a = river_sdf_water;
	float tail_b = river_sdf_water;
	float plume_src = max(river_sdf_water, max(tail_a * 0.82, tail_b * 0.62));
	float plume_noise = 0.5;
	if (ctx.quality >= 1) {
		plume_noise = fbm(ctx.wpw * 0.055 + plume_dir * world_time * 0.065, ctx.detail_oct);
	}
	float plume = smoothstep(river_threshold_low * 0.72, river_threshold_high, plume_src);
	plume *= mix(0.88, 1.14, plume_noise);
	plume *= clamp(1.0 - ww.w_ice - ww.w_lake * 0.22, 0.0, 1.0);
	vec3 plume_col = mix(
		river_color * vec3(1.12, 1.10, 1.02),
		color_coast_water * vec3(0.84, 1.14, 1.20),
		smoothstep(0.12, 0.70, ctx.offshore_depth));
	col = mix(col, plume_col, clamp(plume * estuary_plume_strength * 0.55, 0.0, 0.55));
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.14: build_water_normal_and_calm —— 法线 + Water Calm Noise 调色
// ═══════════════════════════════════════════════════════════════════════
//   biome 选择波浪幅度档位 → sample_water_normal → near-shore 放大
//   → calm noise 亮度+色相微调。
//   返回最终 col；同时通过 inout vec3 N 输出水面法线。
// ─────────────────────────────────────────────────────────────────────
vec3 build_water_normal_and_calm(vec3 col, WaterStageCtx ctx, float w_ice, inout vec3 N_out) {
	float wave_amp_scale  = 1.0;
	float wave_freq_scale = 1.0;
	float current_align_w = 0.0;
	if (ctx.biome == B_LAKE) {
		wave_amp_scale = 0.22; wave_freq_scale = 0.82; current_align_w = 0.0;
	} else if (ctx.biome == B_REEF) {
		wave_amp_scale = 0.42; wave_freq_scale = 0.78; current_align_w = 0.36;
	} else if (ctx.biome == B_KELP) {
		wave_amp_scale = 0.36; wave_freq_scale = 0.70; current_align_w = 0.40;
	} else if (ctx.biome == B_OCEAN || ctx.biome == B_COAST) {
		wave_amp_scale = 0.72; wave_freq_scale = 0.76; current_align_w = 0.46;
	} else {
		wave_amp_scale = 0.0;
	}
	int wave_q = (ctx.quality >= 1) ? 1 : 0;
	vec2 wave_wp = ctx.wp;
	if (ocean_current_enabled && current_align_w > 0.001) {
		vec2 current_dir = (length(ctx.ocean_current_v) > 0.05) ? normalize(ctx.ocean_current_v) : vec2(1.0, 0.0);
		float current_push = current_align_w * mix(0.85, 1.45, ocean_current_strength);
		wave_wp = ctx.wp + current_dir * current_push + ctx.ocean_current_v * current_align_w * 0.80;
	}
	bool waves_on = water_waves_enabled && wave_amp_scale > 0.001;
	N_out = sample_water_normal(wave_wp, world_time, wave_amp_scale, wave_freq_scale, wave_q, waves_on);

	// 近岸法线放大
	float coast_sdf = abs(ctx.elev - sea_level);
	if (waves_on && coast_sdf < 0.05 && (ctx.biome == B_OCEAN || ctx.biome == B_COAST)) {
		float near_shore_boost = 1.0 + 0.12 * (1.0 - smoothstep(0.0, 0.05, coast_sdf));
		N_out.xy *= near_shore_boost;
		N_out = normalize(N_out);
	}

	// Water Calm Noise（仅作为材质亮度/色相柔噪声，不参与几何法线）
	if (water_wave_line_strength > 0.001 && waves_on && ctx.quality >= 1) {
		// [sea-ice-render-source-unify 阶段 A] 海冰处 calm noise 抑制由 w_ice 连续驱动，
		// 不再依赖 biome == B_SEA_ICE 硬切换。w_ice ≈ 1 时压到 0（与原 SEA_ICE 等价）；
		// 边界冰带 (0 < w_ice < 1) 平滑过渡而非直接断开。
		float calm_amp_mul = 1.0;
		if (ctx.biome == B_LAKE)         calm_amp_mul = 0.65;
		else if (ctx.biome == B_KELP)    calm_amp_mul = 0.28;
		calm_amp_mul = mix(calm_amp_mul, 0.0, clamp(w_ice, 0.0, 1.0));

		float calm = water_calm_brightness(wave_wp, world_time);
		float bright_amp = water_wave_line_strength * water_calm_noise_brightness * calm_amp_mul;
		col *= mix(1.0, 1.0 + calm * 0.045, clamp(bright_amp, 0.0, 1.0));

		int tint_oct = (ctx.quality >= 2) ? 3 : 2;
		float tint_mix = water_calm_tint(wave_wp, world_time, tint_oct);
		vec3 TINT_COLD = vec3(0.97, 0.99, 1.03);
		vec3 TINT_WARM = vec3(1.03, 1.015, 0.97);
		vec3 tint = mix(TINT_COLD, TINT_WARM, tint_mix);
		float tint_amp = water_wave_line_strength * water_calm_noise_tint_strength * calm_amp_mul;
		col *= mix(vec3(1.0), tint, 0.035 * clamp(tint_amp, 0.0, 1.0));
	}
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1: 调度器 compute_water_base_surface —— 线性串联 14 个 helper
// ═══════════════════════════════════════════════════════════════════════
//   注：拆分后函数本体仅作 ctx 构造 + 14 个 helper 顺序调用（≤80 行）。
//   每个 helper 自带 quality / biome 守卫，不需要外层重复判断。
// ─────────────────────────────────────────────────────────────────────
SurfaceParams compute_water_base_surface(
		int biome,
		float elev,
		vec2 wp,
		vec2 uv,
		vec4 scals,
		float lat_signed,
		float current_temp,
		vec2 ocean_current_v,
		vec2 wind_v,
		float dyn_ice_frac) {

	// ── 0. ctx 构造 ───────────────────────────────────────────────────
	WaterStageCtx ctx;
	ctx.biome = biome;
	ctx.elev = elev;
	ctx.wp = wp;
	ctx.uv = uv;
	ctx.scals = scals;
	ctx.lat_signed = lat_signed;
	ctx.current_temp = current_temp;
	ctx.ocean_current_v = ocean_current_v;
	ctx.wind_v = wind_v;
	ctx.quality = visual_quality;
	ctx.ice_frac = dyn_ice_frac;
	ctx.detail_oct = (visual_quality >= 2) ? 2 : 1;
	{
		float water_boundary_softness = clamp(water_biome_blend_radius / 2.2, 0.0, 1.0);
		float warp_for_water = water_domain_warp_strength * mix(0.45, 1.0, water_boundary_softness);
		ctx.wpw = water_domain_warp(wp, world_time, warp_for_water);
	}

	// ── SEA 1.1: 离岸度 + 深度梯度 ─────────────────────────────────────
	compute_offshore_depth(ctx);

	// ── SEA 1.2: basecolor —— hypsometric 起步 + 深浅梯度 ─────────────
	vec3 col = hypsometric_tint(elev, true);
	col = apply_water_depth_gradient(col, ctx);

	// ── SEA 1.3: 全局水色起伏 ──────────────────────────────────────────
	col = apply_global_water_ripple(col, ctx);

	// ── SEA 1.4: biome 软权重 ──────────────────────────────────────────
	WaterWeights ww = compute_water_biome_weights(ctx);

	// ── SEA 1.5–1.6: open ocean patch + 三层色温 ──────────────────────
	col = apply_open_ocean_patch(col, ctx, ww);
	col = apply_deep_ocean_layered_tint(col, ctx, ww);

	// ── SEA 1.7–1.10: biome 特征叠加 ──────────────────────────────────
	col = apply_lake_features(col, ctx, ww);
	col = apply_reef_features(col, ctx, ww);
	col = apply_kelp_features(col, ctx, ww);
	col = apply_sea_ice_features(col, ctx, ww);

	// ── SEA 1.11: 透底/浅水介质 ────────────────────────────────────────
	col = apply_shallow_transparency(col, ctx, ww);

	// ── SEA 1.12–1.13: 洋流条纹 + 河口羽流 ────────────────────────────
	col = apply_ocean_currents(col, ctx, ww);
	col = apply_estuary_plume(col, ctx, ww);

	// ── SEA 1.14: 法线 + calm noise ───────────────────────────────────
	vec3 N_water = vec3(0.0, 0.0, 1.0);
	col = build_water_normal_and_calm(col, ctx, ww.w_ice, N_water);

	// ── SEA 1.15: 装配 SurfaceParams ──────────────────────────────────
	return make_water_surface_params(col, N_water, biome, ww.w_ice, ww.w_lake, ww.w_kelp);
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 2: apply_water_overlay_surface —— 海岸 halo + 浪花 + 薄冰
// ═══════════════════════════════════════════════════════════════════════
//   覆盖层；shore halo 由 shore_common 共用，role=1 表示水面侧看陆地接触。
//   estuary_flow=0：water 路径不消费 flow_accum，避免双侧 halo 干扰。
// ─────────────────────────────────────────────────────────────────────
SurfaceParams apply_water_overlay_surface(
		SurfaceParams surface,
		int biome,
		float elev,
		vec2 wp,
		vec2 uv,
		vec2 wind_v) {
	vec3 col = surface.base_color;
	float coast_sdf = abs(elev - sea_level);

	// SEA 2.1：海岸 / 湖岸 halo ───────────────────────────────────────
	// 60 FPS 优化（2026-06-15）：mobile LOW/MID 跳过 shore_neighborhood 邻域 sample。
	// LOW (4 sample 上限) 完全无 halo；MID 跳过；HIGH 仅 q=0 4-tap = 4 sample。
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	// 无 halo —— 海面/陆面边界硬切（视觉上海岸线略硬，但不影响功能）
#else
	ShoreSamples shore_samp = sample_shore_neighborhood(uv);
	ShoreHaloResult shore_halo_r = compute_shore_halo(shore_samp, elev, 0.0, 1);
	col = mix(col, shore_halo_r.halo_color, shore_halo_r.halo_weight);
	surface.roughness = mix(surface.roughness, shore_halo_r.roughness_target,
							clamp(shore_halo_r.halo_weight, 0.0, 1.0));
#endif

	// SEA 2.2：海岸滚动浪花 ───────────────────────────────────────────
	if (biome == B_COAST || biome == B_OCEAN) {
		float foam_mask_raw = 1.0 - smoothstep(0.0, 0.045, coast_sdf);
		if (foam_mask_raw > 0.001) {
			float local_noise = 0.5;
			float sub_wave = 0.5;
			if (visual_quality >= 1) {
				int foam_oct = (visual_quality >= 2) ? 2 : 1;
				local_noise = fbm(wp * 0.10 + vec2(world_time * 0.08, -world_time * 0.06), foam_oct);
			}
			float main_phase = coast_sdf * 130.0 - world_time * 1.10 + local_noise * 1.20;
			float main_wave = sin(main_phase) * 0.5 + 0.5;
			if (visual_quality >= 1) {
				float sub_phase = coast_sdf * 240.0 - world_time * 1.65 + local_noise * 0.75;
				sub_wave = sin(sub_phase) * 0.5 + 0.5;
			}
			float wave_stack = main_wave * 0.82 + sub_wave * 0.18;
			float wind_mag = clamp(length(wind_v), 0.0, 1.4);
			float wind_widen = 1.0 + wind_mag * 0.18;
			float foam_mask = 1.0 - smoothstep(0.0, 0.045 * wind_widen, coast_sdf);
			float foam = smoothstep(0.70, 0.97, wave_stack) * foam_mask * 0.28;
			float crest = smoothstep(0.93, 1.0, main_wave) * foam_mask * 0.16;
			float foam_w = clamp(foam + crest, 0.0, 0.42);
			col = mix(col, vec3(0.90, 0.95, 0.98), foam_w);
			surface.roughness = mix(surface.roughness, 0.82, foam_w);
			surface.ao = mix(surface.ao, 1.0, foam_w);
		}
	}

	// SEA 2.3：BLIZZARD 薄冰 ──────────────────────────────────────────
	if (extreme_weather_ground_effect_enabled && weather_front_count > 0) {
		float ice_mask = compute_extreme_weather_mask(wp, WT_BLIZZARD);
		if (ice_mask > 0.001) {
			vec3 thin_ice = vec3(0.82, 0.88, 0.92);
			float thin_ice_w = clamp(ice_mask * 0.70, 0.0, 0.70);
			col = mix(col, thin_ice, thin_ice_w);
			surface.normal = normalize(mix(surface.normal, vec3(0.0, 0.0, 1.0), thin_ice_w * 0.55));
			surface.roughness = mix(surface.roughness, 0.28, thin_ice_w);
		}
	}
	surface.base_color = col;
	return surface;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 3: apply_water_specials —— caustics / sparkle / fresnel-water
// ═══════════════════════════════════════════════════════════════════════
//   把 v9 中混在 shade_water_surface 里的水面特殊效果（属于 stylized
//   modulator，不是 BRDF 主路径）抽出来。三段都在 BRDF 输出后 sRGB 域叠加：
//
//     - caustics    : 在 BRDF 之后，sparkle 之前；只在 REEF + day 触发。
//     - fresnel_sky : 用 sky_tint 模拟天空反射，与 BRDF 的 F_Schlick 不冲突
//                     （BRDF 给的是 albedo×F，这里给的是天空环境光反射）。
//     - sparkle     : 高频颗粒高光，纯 stylized 风味。
//
//   day_night_enabled=false 时整体旁路（hillshade-only 路径不该带这些）。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_water_specials(vec3 col, SurfaceParams surface, int biome, vec2 wp, int quality) {
	if (!day_night_enabled) return col;
	vec3 N = normalize(surface.normal);

	// SEA 3.1：水下光斑 caustics（仅 REEF + 白天 + 启用） ──────────────
	if (biome == B_REEF && caustics_enabled && quality >= 1 && tod_night_factor < 0.5) {
		int caustics_oct = (quality >= 2) ? 2 : 1;
		float caustics = fbm(wp * 0.35 + vec2(world_time * 0.08, -world_time * 0.12), caustics_oct);
		float caustics_mask = smoothstep(0.55, 0.75, caustics);
		float day_factor = 1.0 - tod_night_factor;
		vec3 caustic_col = tod_sun_color * 1.15;
		col = mix(col, col + caustic_col * 0.35, caustics_mask * caustics_strength * day_factor);
	}

	// SEA 3.2：菲涅尔天空反射（与 BRDF 的 F_Schlick 互补） ──────────────
	if (water_fresnel_enabled) {
		float F;
		if (quality <= 1) {
			F = 0.30;
		} else {
			F = pow(1.0 - clamp(N.z, 0.0, 1.0), 5.0);
		}
		vec3 sky_tint = tod_ambient_color * mix(1.15, 0.70, tod_night_factor);
		col = mix(col, sky_tint, F * water_reflection_strength);
	}

	// SEA 3.3：sparkle 高频颗粒高光 ────────────────────────────────────
	if (quality >= 1 && water_sparkle_enabled) {
		float sparkle_freq = 0.085;
		float sparkle_speed_day = 0.32;
		int sparkle_oct = (quality >= 2) ? 2 : 1;
		float sparkle = fbm(wp * sparkle_freq + vec2(world_time * sparkle_speed_day, -world_time * 0.20), sparkle_oct);
		float spark_mask = smoothstep(0.88, 0.985, sparkle);
		vec3 day_sparkle_col = vec3(1.03, 1.02, 0.96);
		vec3 night_sparkle_col = vec3(0.76, 0.86, 1.03);
		vec3 sparkle_col = mix(day_sparkle_col, night_sparkle_col, tod_night_factor);
		float base_intensity = 0.028;
		float intensity = mix(base_intensity, base_intensity * 0.45, tod_night_factor);
		float night_freq_scale = mix(1.0, 0.55, tod_night_factor);
		spark_mask *= night_freq_scale;
		col = mix(col, col * sparkle_col, spark_mask * intensity);
	}
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 4: shade_water_surface —— 主光照入口（BRDF + specials）
// ═══════════════════════════════════════════════════════════════════════
//   land/water 共用同一份 evaluate_brdf；spec_max/min legacy 仅在
//   USE_PBR_BRDF=0 时被使用。water 不再自己写 Blinn-Phong/Fresnel/spec 系数。
// ─────────────────────────────────────────────────────────────────────
vec3 shade_water_surface(SurfaceParams surface, int biome, vec2 wp, int quality) {
	LightingContext lc = make_lighting_context(AMBIENT_FLOOR_WATER);
	vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_WATER_LEGACY, SPEC_MIN_WATER_LEGACY);
	// stylized water specials —— 在 BRDF 之后叠加（caustics / fresnel-sky / sparkle）
	lit = apply_water_specials(lit, surface, biome, wp, quality);
	return lit;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 5: render_water_pipeline —— 顶层调度
// ═══════════════════════════════════════════════════════════════════════
//   base surface (12 helper) → overlay surface → shade。
// ─────────────────────────────────────────────────────────────────────
vec3 render_water_pipeline(
		int biome,
		float elev,
		vec2 wp,
		vec2 uv,
		vec4 scals,
		float lat_signed,
		float current_temp,
		vec2 ocean_current_v,
		vec2 wind_v,
		float dyn_ice_frac) {
	SurfaceParams surface = compute_water_base_surface(
		biome, elev, wp, uv, scals, lat_signed, current_temp, ocean_current_v, wind_v, dyn_ice_frac);
	surface = apply_water_overlay_surface(surface, biome, elev, wp, uv, wind_v);
	return shade_water_surface(surface, biome, wp, visual_quality);
}
