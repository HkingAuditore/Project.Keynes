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
//   apply_water_specials 在 day_night_enabled 关时保留全局平行光永昼。
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
	float lake_shore_w;  // shader 端湖岸近似 SDF：1=靠岸，0=湖心
	float lake_depth_proxy; // 湖泊没有海平面深度，使用湖岸距离近似深浅
	float ice_frac;      // 海冰浓度（dyn_atlas_smooth.a；fragment 入口已采样，避免冗余 sample）
	// [water-noise-reuse 2026-06-29] 共享低频 fbm：原 base_ripple/calm_brightness（~0.006~0.008）
	// 与 deep_ripple/calm_tint（~0.0038~0.0039）各自独立采样，频率几乎一致 → 合并成两层共享噪声，
	// 全 desktop 路径下省 2 个 fbm(2-oct)/像素。ctx 构造时算一次，多个 helper 复用。
	float macro_lf;      // 低频共享（base_ripple + calm_brightness）
	float macro_vlf;     // 极低频共享（deep_ripple + calm_tint）
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
		float w_reef,
		float w_kelp) {
	// [sea-ice-render-source-unify 阶段 A] 海冰 roughness 完全由 w_ice 连续驱动，
	// 不再依赖 biome == B_SEA_ICE 硬切换。w_ice 来自 dyn_atlas_smooth.a 的连续
	// sea_ice_fraction，与 UI/info_panel 同源；biome 仍按其他类型（lake/reef/kelp）
	// 决定基础粗糙度，海冰 mix 走 w_ice 路径。
	// [cylindrical-earth-daylight] 顶视正交相机下，所有平静水面共享法线 +Z、视线 +Z，
	// 太阳高悬时整片洋面同时命中 GGX 镜面峰值；roughness 过低 → D_GGX 爆炸 → 向阳侧海面
	// 整体过曝发白（也是此前"快进闪瞎眼"的同源现象）。这里抬高基础粗糙度，让顶视镜面退化为
	// 柔和高光、露出深海蓝；细碎波光由独立 sparkle special 负责，不依赖镜面尖峰。
	// [水面反射增强 2026-06-25] 整体下调水体粗糙度，让海面反射更强、细节更丰富（用户反馈
	// 水体表现偏弱）。配合 water.gdshaderinc 的法线去条纹 + fbm 碎波，低粗糙度产生的高光会
	// 被打散的法线散成粼粼波光而非一整片镜面发白；sparkle special 同步收敛防过曝。
	//   base 0.38→0.30 / lake 0.20→0.15 / reef 0.46→0.36 / kelp 0.56→0.48
	float roughness = 0.30;
	if (biome == B_LAKE) {
		roughness = 0.15;          // 平静湖面：清亮，靠波光层而不是整片镜面发白
	} else if (biome == B_REEF) {
		roughness = 0.36;          // 礁盘浅水更碎、更漫，避免像荧光贴片
	} else if (biome == B_KELP) {
		roughness = 0.48;
	}
	roughness = mix(roughness, 0.18, clamp(w_lake * 0.45, 0.0, 1.0));
	roughness = mix(roughness, 0.40, clamp(w_reef * 0.42, 0.0, 1.0));
	// [海冰反射 2026-06-25] 海冰是结晶冰面，应有明显镜面/菲涅尔反射：roughness 目标 0.34→0.15，
	// 让 GGX 高光与天空菲涅尔在冰面上聚出清亮反光，区别于哑光积雪。
	roughness = mix(roughness, 0.15, clamp(w_ice, 0.0, 1.0));
	roughness = mix(roughness, 0.50, clamp(w_kelp * 0.35, 0.0, 1.0));
	float ao = mix(0.98, 1.0, clamp(normal.z, 0.0, 1.0));
	ao = mix(ao, 0.96, clamp(w_lake * 0.25 + w_ice * 0.35, 0.0, 1.0));

	// metallic：水默认非金属；冰盖区给一点金属感（菲涅尔更明显）。
	// [海冰反射 2026-06-25] 冰的金属感系数略抬（DEFAULT_METALLIC_ICE 0.05），配合低 roughness
	// 让冰面 F0 上移、掠射反射更突出。
	float metallic = mix(DEFAULT_METALLIC_WATER, DEFAULT_METALLIC_ICE, clamp(w_ice, 0.0, 1.0));
	return make_surface_params(base_color, normal, roughness, metallic, ao);
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.0b: compute_lake_shore_proxy —— 基于 biome 邻域的湖岸近似 SDF
// ═══════════════════════════════════════════════════════════════════════
// 真正的 lake SDF 目前没有由 baker 输出。这里用 map_index_atlas 多半径采样估算：
// 当前湖像素附近若出现非湖 biome，则认为靠岸；越靠近岸边权重越高。
// 它只服务 LAKE 的颜色/透底/halo，避免继续把 sea_level 当湖泊水位线。
// ─────────────────────────────────────────────────────────────────────
float compute_lake_shore_proxy(vec2 uv, int quality) {
	vec2 tx = 1.0 / derived_resolution;
	float near_cnt = 0.0;
	float near_total = 0.0;
	float mid_cnt = 0.0;
	float mid_total = 0.0;
	float far_cnt = 0.0;
	float far_total = 0.0;

	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			bool is_diag = (ox != 0) && (oy != 0);
			if (quality <= 0 && is_diag) {
				continue;
			}
			vec2 o = vec2(float(ox), float(oy));
			int b = int(texture(map_index_atlas, wrap_map_uv(uv + o * tx)).r * 255.0 + 0.5);
			float edge = (b == B_LAKE) ? 0.0 : 1.0;
			float sw = 1.0 - 0.18 * clamp(length(o), 0.0, 1.41421356);
			near_cnt += edge * sw;
			near_total += sw;
		}
	}

	for (int i = 0; i < 4; i++) {
		vec2 o = vec2(0.0, -2.0);
		if (i == 0) {
			o = vec2(2.0, 0.0);
		} else if (i == 1) {
			o = vec2(-2.0, 0.0);
		} else if (i == 2) {
			o = vec2(0.0, 2.0);
		}
		int b = int(texture(map_index_atlas, wrap_map_uv(uv + o * tx)).r * 255.0 + 0.5);
		mid_cnt += (b == B_LAKE) ? 0.0 : 1.0;
		mid_total += 1.0;
	}

	if (quality >= 2) {
		for (int i = 0; i < 4; i++) {
			vec2 o = vec2(0.0, -3.0);
			if (i == 0) {
				o = vec2(3.0, 0.0);
			} else if (i == 1) {
				o = vec2(-3.0, 0.0);
			} else if (i == 2) {
				o = vec2(0.0, 3.0);
			}
			int b = int(texture(map_index_atlas, wrap_map_uv(uv + o * tx)).r * 255.0 + 0.5);
			far_cnt += (b == B_LAKE) ? 0.0 : 1.0;
			far_total += 1.0;
		}
	}

	float near_t = near_cnt / max(near_total, 1.0);
	float mid_t = mid_cnt / max(mid_total, 1.0);
	float far_t = far_cnt / max(far_total, 1.0);
	float shore = smoothstep(0.05, 0.34, near_t) * 0.78
			+ smoothstep(0.10, 0.42, mid_t) * 0.34
			+ smoothstep(0.12, 0.50, far_t) * 0.18;
	return clamp(shore, 0.0, 1.0);
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.1: compute_offshore_depth ——离岸度 + 深度梯度准备
// ═══════════════════════════════════════════════════════════════════════
//   从 5×5（quality≥1）/ 3×3 邻域采高度图，统计 deep_cnt，得到 offshore；
//   并合并 depth_t = 1 - elev/sea_level，得到 offshore_depth。
// ─────────────────────────────────────────────────────────────────────
void compute_offshore_depth(inout WaterStageCtx ctx) {
	// [water-depth-tex 2026-06-26] 快速路径：优先用 C++ 烘焙好的统一水深图（海/湖一张 R8）。
	// 每水像素仅 1 次采样，取代下方"海洋 5×5/plus height 邻域 + compute_lake_shore_proxy 的
	// 16× biome 多半径"两套估算。湖泊深浅、海洋大陆架→深渊全部来自 C++ 真实 per-cell 深度。
	if (has_water_depth_tex) {
		float wd = texture(water_depth_tex, ctx.uv).r;
		ctx.depth_t = wd;
		ctx.offshore = wd;
		ctx.offshore_depth = wd;
		ctx.deep_layer_w = smoothstep(0.36, 1.0, wd);
		// 湖岸近似（1=靠岸→0=湖心）由水深反推，免去多半径 biome 采样；非湖为 0。
		ctx.lake_shore_w = (ctx.biome == B_LAKE) ? clamp(1.0 - smoothstep(0.0, 0.45, wd), 0.0, 1.0) : 0.0;
		ctx.lake_depth_proxy = wd;
		return;
	}
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
	// [需求2 2026-06-25] 让真实海底高程（bathymetry）主导海洋深浅着色，避免开阔水域因
	// offshore 邻域计数饱和成 1.0 而整片均一。原 offshore*0.68 + depth_t*0.32 → 现在
	// 反过来以 depth_t 为主（0.66），offshore 仅作"是否远离海岸"的辅助门控（0.34）。
	ctx.offshore_depth = clamp(ctx.offshore * 0.34 + smoothstep(0.00, 0.95, ctx.depth_t) * 0.66, 0.0, 1.0);
	ctx.deep_layer_w = smoothstep(0.36, 1.0, ctx.offshore_depth);
	ctx.lake_shore_w = (ctx.biome == B_LAKE) ? compute_lake_shore_proxy(ctx.uv, ctx.quality) : 0.0;
	ctx.lake_depth_proxy = (ctx.biome == B_LAKE)
			? (1.0 - ctx.lake_shore_w)
			: ctx.offshore_depth;
	if (ctx.biome == B_LAKE) {
		// [需求2 2026-06-25] 湖泊深浅引入真实高程：湖盆海拔越低（低于参考水线越多）越深，
		// 与岸距代理(lake_shore_w)各占一半，让大湖中央不再均一色；高山湖(海拔偏高)自然
		// 退化为浅清色。lake_bathy ∈ [0,1]：sea_level+0.08 处为 0(浅)，低 0.42 处为 1(深)。
		float lake_bathy = clamp((sea_level + 0.08 - ctx.elev) / 0.42, 0.0, 1.0);
		float lake_depth_combined = clamp((1.0 - ctx.lake_shore_w) * 0.55 + lake_bathy * 0.45, 0.0, 1.0);
		ctx.lake_depth_proxy = lake_depth_combined;
		ctx.offshore_depth = mix(0.10, 0.80, smoothstep(0.0, 1.0, lake_depth_combined));
		ctx.deep_layer_w = smoothstep(0.36, 1.0, ctx.offshore_depth);
	}
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.2: apply_water_depth_gradient —— 三段离岸色 + lagoon lift
// ═══════════════════════════════════════════════════════════════════════
//   用 water_depth_gradient 替换旧的三段 if，得到统一深浅梯度底色；
//   浅水区给 lagoon 偏青提亮。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_water_depth_gradient(vec3 col, WaterStageCtx ctx) {
	vec3 tier_color = water_depth_gradient(ctx.offshore_depth, ctx.elev);
	float water_fill_w = smoothstep(0.02, 0.92, 0.42 + ctx.offshore_depth * 0.48);
	col = mix(col, tier_color, water_fill_w);
	float lagoon_lift = 1.0 - smoothstep(0.08, 0.56, ctx.offshore_depth);
	col = mix(col, col * vec3(0.91, 1.05, 1.08), lagoon_lift * 0.11);
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
	// [water-noise-reuse 2026-06-29] 复用 ctx.macro_lf（与 calm_brightness 同源），不再单独采样。
	col *= 1.0 + (ctx.macro_lf - 0.5) * mix(0.050, 0.082, ctx.deep_layer_w);
#endif
	vec3 cartoon_chroma = mix(vec3(0.78, 1.20, 1.18), vec3(0.70, 0.96, 1.38),
								smoothstep(0.12, 1.0, ctx.offshore_depth));
	col *= mix(vec3(1.0), cartoon_chroma, water_cartoon_color_strength * 0.26);
	// deep_ripple + color_block 仅 desktop 跑
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
	// [water-noise-reuse 2026-06-29] 复用 ctx.macro_vlf（与 calm_tint 同源）。
	vec3 deep_variation = mix(vec3(0.92, 1.03, 1.14), vec3(1.08, 0.94, 1.05), ctx.macro_vlf);
	col *= mix(vec3(1.0), deep_variation, ctx.deep_layer_w * 0.115);
	if (water_cartoon_color_strength > 0.001) {
		float color_block = water_fbm_cyl(ctx.wpw, 0.0048, vec2(world_time * 0.010, -world_time * 0.006), 2);
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
		bw = water_biome_weights(ctx.uv, 1.0 / derived_resolution, blend_radius_eff);
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
	float ridge_n = water_fbm_cyl(ctx.wpw, 0.045, vec2(-71.0, 23.0), 2);
	ridge_offset = (ridge_n - 0.5) * 0.06;
#endif
	float lake_freeze = ww.w_lake * (1.0 - smoothstep(0.24, 0.44, ctx.current_temp));
	ww.w_ice = clamp(max(
		smoothstep(0.22, 0.72, ice_frac + ridge_offset),
		lake_freeze
	), 0.0, 1.0);
	// 湖泊低温结冰是 shader 视觉兜底：保留少量湖底色，但让冰面材质/颜色成为主导。
	ww.w_lake *= 1.0 - ww.w_ice * 0.72;
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
	float gyre_a = water_fbm_cyl(ctx.wpw, 0.0056, vec2(13.0, -31.0), ocean_patch_oct);
	float gyre_b = water_fbm_cyl(ctx.wpw, 0.012, vec2(-29.0, 47.0), 1);
	if (ctx.quality >= 1) {
		gyre_b = water_fbm_cyl(ctx.wpw, 0.012, vec2(world_time * 0.012, -world_time * 0.007), 2);
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
// SEA 1.7: apply_lake_features —— 湖岸浅透、湖心深色、低对比水纹
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_lake_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_lake > 0.001)) return col;

	float lake_shallow_t = smoothstep(0.00, 0.30, ctx.lake_depth_proxy);
	float lake_mid_t = smoothstep(0.18, 0.60, ctx.lake_depth_proxy);
	float lake_deep_t = smoothstep(0.44, 0.84, ctx.lake_depth_proxy);
	float lake_abyss_t = smoothstep(0.70, 1.00, ctx.lake_depth_proxy);
	float lake_edge_t = ctx.lake_shore_w;
	vec3 lake_edge = mix(color_coast_water, lake_water_color, 0.52) * vec3(1.02, 1.05, 1.02);
	vec3 lake_shallow = mix(color_shallow, lake_water_color, 0.66) * vec3(1.03, 1.08, 1.02);
	vec3 lake_mid = mix(lake_water_color, color_mid_ocean, 0.38) * vec3(0.98, 1.02, 1.06);
	vec3 lake_deep = mix(color_mid_ocean, color_deep_ocean, 0.48) * vec3(0.96, 1.00, 1.08);
	vec3 lake_abyss = mix(color_deep_ocean, color_deep_ocean * vec3(0.88, 0.95, 1.10), 0.62);
	vec3 lake_col = lake_edge;
	lake_col = mix(lake_col, lake_shallow, lake_shallow_t);
	lake_col = mix(lake_col, lake_mid, lake_mid_t * 0.76);
	lake_col = mix(lake_col, lake_deep, lake_deep_t * 0.70);
	lake_col = mix(lake_col, lake_abyss, lake_abyss_t * 0.56);
	lake_col = mix(lake_col, lake_edge * vec3(1.05, 1.08, 1.03), lake_edge_t * 0.30);

	float lake_ripple = 0.5;
	float lake_mottle = 0.5;
	float lake_glass = 0.5;
	float lake_lines = 0.0;
	if (ctx.quality >= 1) {
		lake_ripple = water_fbm_cyl(ctx.wpw, 0.020, vec2(world_time * 0.012, -19.0), ctx.detail_oct);
		lake_mottle = water_fbm_cyl(ctx.wpw, 0.008, vec2(-23.0, 11.0), ctx.detail_oct);
		lake_lines = water_shade_lines(ctx.wpw + vec2(7.0, -5.0), world_time * 0.55, 0.58, 1);
		lake_glass = water_fbm_cyl(ctx.wpw, 0.0042, vec2(-world_time * 0.006, world_time * 0.004), ctx.detail_oct);
	}
	lake_col *= 1.0 + (lake_ripple - 0.5) * 0.050 + (lake_mottle - 0.5) * 0.032 + lake_lines * 0.055;
	vec3 cool_lift = mix(vec3(0.96, 1.02, 1.04), vec3(1.03, 1.02, 0.96), lake_glass);
	lake_col *= mix(vec3(1.0), cool_lift, 0.045);
	col = mix(col, lake_col, ww.w_lake * 0.94);
	return col;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 1.8: apply_reef_features —— 降饱和浅水礁盘 + 柔和珊瑚斑
// ═══════════════════════════════════════════════════════════════════════
vec3 apply_reef_features(vec3 col, WaterStageCtx ctx, WaterWeights ww) {
	if (!(ww.w_reef > 0.001)) return col;

	float reef_depth = clamp(ctx.offshore_depth * 0.48 + ctx.depth_t * 0.22, 0.0, 1.0);
	vec3 shallow_ref = mix(color_shallow, color_coast_water, 0.54);
	vec3 reef_lagoon = mix(shallow_ref, vec3(0.36, 0.64, 0.62), water_cartoon_color_strength * 0.34);
	vec3 reef_outer = mix(water_depth_gradient(clamp(ctx.offshore_depth * 0.92, 0.0, 1.0), ctx.elev),
							color_coast_water * vec3(0.90, 1.04, 1.05), 0.30);
	vec3 reef_base = mix(reef_lagoon, reef_outer, smoothstep(0.12, 0.88, reef_depth));
	float coral_soft = 0.5;
	float reef_sheen = 0.5;
	if (ctx.quality >= 1) {
		float coral_spots = voronoi_cell(water_cyl_noise_p(ctx.wpw, 0.24, vec2(0.0)));
		coral_soft = smoothstep(0.04, 0.74, coral_spots);
	}
	if (ctx.quality >= 2) {
		reef_sheen = water_fbm_cyl(ctx.wpw, 0.018, vec2(17.0, 29.0), 2);
	}
	vec3 coral_tint = mix(vec3(0.34, 0.56, 0.54), vec3(0.24, 0.46, 0.50),
						   smoothstep(0.30, 0.88, ctx.offshore_depth));
	vec3 reef_col = mix(reef_base, coral_tint, coral_soft * 0.12);
	reef_col = mix(reef_col, color_shallow, (1.0 - smoothstep(0.14, 0.72, ctx.offshore_depth)) * 0.13);
	reef_col *= 1.0 + (reef_sheen - 0.5) * 0.018;
	float reef_edge_feather = mix(0.50, 0.78, 1.0 - smoothstep(0.18, 0.94, ctx.offshore_depth));
	float reef_mix_w = ww.w_reef * reef_edge_feather * 0.86;
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
	float along_k = water_periodic_wave_phase(ctx.wpw, oc_norm, 0.030);
	float across_k = water_periodic_wave_phase(ctx.wpw, perp_k, 0.095);
	float kelp_streak = 0.5;
	if (ctx.quality >= 1) {
		kelp_streak = fbm(vec2(along_k + world_time * 0.035, across_k), ctx.detail_oct);
	}
	float kelp_patch = water_fbm_cyl(ctx.wpw, 0.018, vec2(5.0, -41.0), ctx.detail_oct);
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
		float crack = voronoi_cell(water_cyl_noise_p(ctx.wpw, 0.34, vec2(0.0)));
		crack_factor = smoothstep(0.02, 0.16, crack);
	}
	float ice_noise = water_fbm_cyl(ctx.wpw, 0.12, vec2(-9.0, 31.0), ctx.detail_oct);
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
	float lake_clarity = ww.w_lake * ctx.lake_shore_w;
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
	float along = water_periodic_wave_phase(ctx.wp, oc_dir, mix(0.010, 0.024, water_cartoon_color_strength)) + world_time * 0.035;
	float across = water_periodic_wave_phase(ctx.wp, oc_side, mix(0.060, 0.105, water_cartoon_color_strength));
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
		plume_noise = water_fbm_cyl(ctx.wpw, 0.055, plume_dir * world_time * 0.065, ctx.detail_oct);
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
		wave_amp_scale = 0.34; wave_freq_scale = 0.92; current_align_w = 0.0;
	} else if (ctx.biome == B_REEF) {
		wave_amp_scale = 0.50; wave_freq_scale = 0.84; current_align_w = 0.32;
	} else if (ctx.biome == B_KELP) {
		wave_amp_scale = 0.36; wave_freq_scale = 0.70; current_align_w = 0.40;
	} else if (ctx.biome == B_OCEAN || ctx.biome == B_COAST) {
		wave_amp_scale = 0.78; wave_freq_scale = 0.78; current_align_w = 0.46;
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

		// [water-noise-reuse 2026-06-29] 复用 ctx.macro_lf（与 base_ripple 同源），remap 到 [-1,1]，
		// 不再调用 water_calm_brightness 单独采样一次 fbm。
		float calm = clamp(ctx.macro_lf * 1.9 - 0.95, -1.0, 1.0);
		float bright_amp = water_wave_line_strength * water_calm_noise_brightness * calm_amp_mul;
		col *= mix(1.0, 1.0 + calm * 0.045, clamp(bright_amp, 0.0, 1.0));

		// [water-noise-reuse 2026-06-29] 复用 ctx.macro_vlf（与 deep_ripple 同源），remap 到 [0,1]。
		float tint_mix = clamp(ctx.macro_vlf * 1.15, 0.0, 1.0);
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
	// [water-noise-reuse 2026-06-29] 两层共享低频噪声只算一次（LOW 档两个消费者都不跑 → 跳过）。
	// 原 base_ripple 静态、calm_brightness 慢飘；合并后统一带极慢时间漂移（±5% 亮度下不可察）。
	ctx.macro_lf = 0.5;
	ctx.macro_vlf = 0.5;
#ifndef MOBILE_QUALITY_LOW
	ctx.macro_lf  = water_fbm_cyl(ctx.wpw, 0.0072, vec2(world_time * 0.012,  world_time * 0.007) + vec2(31.0, 7.0), 2);
	ctx.macro_vlf = water_fbm_cyl(ctx.wpw, 0.0039, vec2(-world_time * 0.008, world_time * 0.010) + vec2(-47.0, 23.0), 2);
#endif

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
	return make_water_surface_params(col, N_water, biome, ww.w_ice, ww.w_lake, ww.w_reef, ww.w_kelp);
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

	// 用现有 coast_sdf + 水体地形类型做近岸浅水过渡：B_COAST/KELP/REEF 本身就是近岸语义，
	// 不能只依赖 elev≈sea_level，否则部分岸边水格会完全没有过渡。
	if (biome == B_COAST || biome == B_REEF || biome == B_KELP) {
		float shore_dist_w = 1.0 - smoothstep(0.010, 0.075, coast_sdf);
		float coast_kind_w = 0.0;
		if (biome == B_COAST) {
			coast_kind_w = 0.46;
		} else if (biome == B_REEF) {
			coast_kind_w = 0.30;
		} else if (biome == B_KELP) {
			coast_kind_w = 0.22;
		}
		float shoal_w = clamp(max(shore_dist_w * 0.48, coast_kind_w), 0.0, 1.0);
		vec3 shoal_col = mix(color_coast_water, color_beach * vec3(0.78, 0.93, 1.02), 0.34);
		col = mix(col, shoal_col, shoal_w * 0.22);
		surface.roughness = mix(surface.roughness, 0.58, shoal_w * 0.18);
	}

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
	// [coast-smooth 2026-06-26] 海岸过渡带（水侧）：在贴陆的一圈把水色混向"水色与陆色的中间色"，与陆侧
	// 对称收敛成一条柔和过渡带。粗细 = shore_w(贴陆接触度)×coast_smooth_width；开阔水/浅湖内部 shore_w=0
	// 不染(不发灰)。颜色 = mix(color_coast_water, color_lowland, coast_shore_land_bias) → 水色+陆色混合。
	if (coast_smooth_strength > 0.001) {
		float band = smoothstep(0.0, 1.0, clamp(shore_halo_r.shore_w * coast_smooth_width, 0.0, 1.0));
		vec3 shore_mix = mix(color_coast_water, color_lowland, coast_shore_land_bias);
		col = mix(col, shore_mix, band * coast_smooth_strength);
	}
#endif

	// SEA 2.2：海岸滚动浪花 ───────────────────────────────────────────
	// [reef 浪花修复 2026-06-25] 把 B_REEF 纳入近岸浪花判断：珊瑚礁多贴岸，原来只覆盖
	// COAST/OCEAN 会在 reef 水格处出现浪花断裂空隙（用户截图红圈）。reef 浪花用稍弱权重
	// （礁盘消浪、白沫较碎），与 coast 自然衔接、消除空隙。
	if (biome == B_COAST || biome == B_OCEAN || biome == B_REEF || biome == B_KELP) {
		float reef_foam_scale = (biome == B_REEF) ? 0.72 : ((biome == B_KELP) ? 0.50 : 1.0);
		float foam_mask_raw = 1.0 - smoothstep(0.0, 0.045, coast_sdf);
		if (foam_mask_raw > 0.001) {
			float local_noise = 0.5;
			float sub_wave = 0.5;
			if (visual_quality >= 1) {
				int foam_oct = (visual_quality >= 2) ? 2 : 1;
				local_noise = water_fbm_cyl(wp, 0.10, vec2(world_time * 0.08, -world_time * 0.06), foam_oct);
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
			float foam = smoothstep(0.74, 0.98, wave_stack) * foam_mask * 0.16 * reef_foam_scale;
			float crest = smoothstep(0.95, 1.0, main_wave) * foam_mask * 0.07 * reef_foam_scale;
			float foam_w = clamp(foam + crest, 0.0, 0.24);
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
//   day_night_enabled=false 时保留全局平行光永昼：不再关闭波坡明暗 / 高光等方向性。
// ─────────────────────────────────────────────────────────────────────
vec3 apply_water_specials(vec3 col, SurfaceParams surface, int biome, vec2 wp, int quality, float pixel_night, vec3 sun_dir_px) {
	vec3 N = normalize(surface.normal);
	float day_factor = 1.0 - pixel_night;

	// SEA 3.1：水下光斑 caustics（仅 REEF + 白天 + 启用） ──────────────
	if (biome == B_REEF && caustics_enabled && quality >= 1 && pixel_night < 0.5) {
		int caustics_oct = (quality >= 2) ? 2 : 1;
		float caustics = water_fbm_cyl(wp, 0.35, vec2(world_time * 0.08, -world_time * 0.12), caustics_oct);
		float caustics_mask = smoothstep(0.55, 0.75, caustics);
		vec3 caustic_col = mix(tod_sun_color, color_shallow, 0.32) * 1.05;
		col = mix(col, col + caustic_col * 0.24, caustics_mask * caustics_strength * day_factor);
	}

	// SEA 3.15：波浪天光明暗（hillshade，不依赖直射高光）─────────────────────
	//   问题：顶视 + 低菲涅尔下，只有太阳直射的镜面 glint 处能看出波浪，背光/无直射水域
	//   一片死蓝。这里给波浪法线沿「太阳方位」做一层漫反射明暗：迎光波坡提亮、背光波坡压暗，
	//   全水面（含阴影侧）都显出起伏。平静/冰面 N≈+z → slope≈0 自动归零；夜侧整体减弱。
	if (water_wave_shade_strength > 0.001) {
		vec2 sun_h = sun_dir_px.xy;
		vec2 light_az = (length(sun_h) > 1e-4) ? normalize(sun_h) : vec2(0.0, 1.0);
		float slope_lit = dot(N.xy, light_az);  // 波坡沿光方位投影：迎光 + / 背光 −
		float shade = clamp(slope_lit * water_wave_shade_strength, -0.60, 0.60);
		float amp = mix(0.45, 1.0, day_factor);  // 夜侧仍留一点天光起伏
		col *= (1.0 + shade * amp);
	}

	// SEA 3.16：水体次表面散射（SSS，廉价近似）──────────────────────────────
	//   低太阳/逆光时阳光穿过薄波层 → 迎光波坡透出青绿透亮（前向散射）。无需厚度纹理：
	//   facing=波坡迎太阳方位，wave_act=(1-N.z) 波动强度（平静/冰面≈0 自动归零），
	//   low_sun=掠射加权（日出日落更明显）。叠的是颜色(青绿)而非亮度，与 hillshade 区分。
	//   mid+ 档(visual_quality>=1)启用。
	if (visual_quality >= 1 && water_sss_strength > 0.001) {
		vec2 sun_h = sun_dir_px.xy;
		vec2 light_az = (length(sun_h) > 1e-4) ? normalize(sun_h) : vec2(0.0, 1.0);
		// [sss-calibration-fix 2026-06-29] 波浪法线很缓（|N.xy|≈0.1），旧版 pow(facing,3)×(1-N.z)*2.5
		// 把信号压到 ~0.001 → 完全不可见。改：先用 gain 把迎光坡度放大到可用域再取幂；平静/冰面
		// N≈+z → facing≈0 自动归零，不再需要会把信号压没的 wave_act。
		float facing = clamp(dot(N.xy, light_az) * 5.0, 0.0, 1.0);
		float low_sun = 1.0 - clamp(sun_dir_px.z, 0.0, 1.0);
		float sss = pow(facing, water_sss_power) * water_sss_strength
				* day_factor * mix(0.55, 1.0, low_sun);
		col += water_sss_color * sss;
	}

	// SEA 3.2：菲涅尔天空反射（与 BRDF 的 F_Schlick 互补） ──────────────
	if (water_fresnel_enabled) {
		float F;
		if (quality <= 1) {
			// 顶视正交：视线近乎垂直水面，菲涅尔反射本应很弱。旧的 0.30 平值在快进/低画质下
			// 把整片洋面糊上一层天空色 → 偏白。降到 0.16 让深海蓝重新主导。
			F = 0.16;
		} else {
			F = pow(1.0 - clamp(N.z, 0.0, 1.0), 5.0);
		}
		// [sky-sh-ambient] 天空反射用方向化 L1 球谐天光（按波浪法线 N 取样）：波面朝天顶/朝太阳
		// 方位会反射不同天色 → 水面浮现随法线变化的光影（这才是球谐补光在水面的体现），
		// 而非平铺一层 tod_ambient_color。flat 水面(N≈+z)≈原值，故无回归；波纹处显出体积。
		vec3 sky_tint = earth_sky_sh(tod_ambient_color, tod_sun_color, sun_dir_px, 1.0 - pixel_night, N) * mix(1.0, 0.70, pixel_night);
		col = mix(col, sky_tint, F * water_reflection_strength);
	}

	// SEA 3.3：sparkle 高频颗粒高光 ────────────────────────────────────
	if (quality >= 1 && water_sparkle_enabled) {
		int sparkle_oct = (quality >= 2) ? 2 : 1;
		vec3 L = sun_dir_px;
		vec3 H = normalize(L + VIEW_DIR_TOP_DOWN);
		float NdotH = max(dot(N, H), 0.0);
		float rough = clamp(surface.roughness, 0.04, 1.0);
		float gloss_power = mix(18.0, 86.0, 1.0 - rough);
		float sun_glint = pow(NdotH, gloss_power);
		float glint_noise = water_fbm_cyl(wp, 0.055, vec2(world_time * 0.18, -world_time * 0.11), sparkle_oct);
		float glint_mask = smoothstep(0.58, 0.94, glint_noise);
		float rough_window = 1.0 - smoothstep(0.18, 0.68, rough);
		vec3 glint_col = mix(tod_sun_color, vec3(1.0, 1.0, 0.92), 0.22);
		// [水面反射增强 2026-06-25] 粗糙度整体下调后 GGX/glint 峰值更亮，这里把阳光 glint
		// 系数 0.42→0.32 并对单像素增量 clamp，避免向阳侧聚成一整片过曝白斑（法线去条纹后
		// 高光本已散成粼粼波光，glint 只作点缀）。
		vec3 glint_add = glint_col * sun_glint * glint_mask * rough_window * water_reflection_strength * day_factor * 0.32;
		col += min(glint_add, vec3(0.45));

		float sparkle_freq = 0.085;
		float sparkle_speed_day = 0.32;
		float sparkle = water_fbm_cyl(wp, sparkle_freq, vec2(world_time * sparkle_speed_day, -world_time * 0.20), sparkle_oct);
		float spark_mask = smoothstep(0.88, 0.985, sparkle);
		vec3 day_sparkle_col = vec3(1.03, 1.02, 0.96);
		vec3 night_sparkle_col = vec3(0.76, 0.86, 1.03);
		vec3 sparkle_col = mix(day_sparkle_col, night_sparkle_col, pixel_night);
		float base_intensity = 0.028;
		float intensity = mix(base_intensity, base_intensity * 0.45, pixel_night);
		float night_freq_scale = mix(1.0, 0.55, pixel_night);
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
vec3 shade_water_surface(SurfaceParams surface, int biome, vec2 wp, int quality, vec2 uv, float lat_signed) {
	// [cylindrical-earth-daylight] 逐像素经纬度日照：水体夜染/specials 同样改吃太阳高度角。
	float pixel_night = day_night_enabled ? (1.0 - solar_day_factor(compute_solar_elevation(uv, lat_signed))) : 0.0;
	// [tod-latitude-sun 2026-06-25] 波光 / 高光跟随太阳方向；
	// 昼夜关闭时使用全图一致的季节性平行光，避免关闭 TOD 后水面方向光一起消失。
	vec3 sun_dir_px = day_night_enabled
			? (tod_latitude_sun_enabled ? compute_sun_dir_enu(uv, lat_signed) : normalize(tod_sun_dir))
			: compute_global_parallel_sun_dir();
	LightingContext lc = make_lighting_context(AMBIENT_FLOOR_WATER, uv, lat_signed);
	// 当前 terrain_horizon_tex 以底部 height_buffer 烘焙。开放水面保留这种“海底投影”美术效果；
	// 海冰应表现为海平面/冰面接收光，不显示海底起伏阴影，因此在海冰 biome 上关闭底部 horizon。
	if (biome == B_SEA_ICE) {
		lc.direct_shadow = 1.0;
	}
	if (terrain_horizon_debug_view == 1) {
		return vec3(clamp((1.0 - lc.direct_shadow) * lc.local_day, 0.0, 1.0));
	}
	if (terrain_horizon_debug_view == 2) {
		return vec3(lc.direct_shadow);
	}
	vec3 lit = evaluate_brdf(surface, lc, SPEC_MAX_WATER_LEGACY, SPEC_MIN_WATER_LEGACY);
	// [terrain-horizon 2026-07-03] 水面阴影先压 BRDF 结果，再叠加 fresnel/caustics/sparkle，
	// 让高光与波浪可以覆盖在阴影之上；强度比陆地轻，避免水面变脏。
	float cast_shadow = clamp((1.0 - lc.direct_shadow) * lc.local_day, 0.0, 1.0);
	if (cast_shadow > 0.001) {
		float water_floor = mix(1.0, terrain_horizon_cast_floor, 0.38);
		lit *= mix(1.0, water_floor, cast_shadow);
	}
	// stylized water specials —— 在阴影之后叠加（caustics / fresnel-sky / sparkle 覆盖阴影）
	lit = apply_water_specials(lit, surface, biome, wp, quality, pixel_night, sun_dir_px);
	return lit;
}


// ═══════════════════════════════════════════════════════════════════════
// SEA 5: render_water_pipeline —— 顶层调度
// ═══════════════════════════════════════════════════════════════════════
//   base surface (12 helper) → overlay surface → shade。
// ─────────────────────────────────────────────────────────────────────
vec3 render_water_pipeline_raw(
		int biome,
		int cover,
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
	// [远洋华 2026-06-25] PELAGIC_BLOOM（浮游生物大量繁殖）：开阔海面叠加淡绿富营养 tint，
	// 带低频斑驳让"水华羽流"自然分布。此前 cover_overlay 定义了该色但只在陆地路径调用 → 海面从不显示，
	// 这里在水管线补回。
	if (cover == CV_PELAGIC_BLOOM) {
		float bloom = 0.5;
#ifndef MOBILE_QUALITY_LOW
		if (visual_quality >= 1) {
			bloom = water_fbm_cyl(wp, 0.014, vec2(world_time * 0.010, -7.0), 2);
		}
#endif
		vec3 bloom_col = vec3(0.18, 0.52, 0.40);
		surface.base_color = mix(surface.base_color, bloom_col,
			clamp(0.20 + (bloom - 0.5) * 0.14, 0.0, 0.34));
	}
	surface = apply_water_overlay_surface(surface, biome, elev, wp, uv, wind_v);
	return shade_water_surface(surface, biome, wp, visual_quality, uv, lat_signed);
}

vec3 render_water_pipeline(
		int biome,
		int cover,
		float elev,
		vec2 wp,
		vec2 uv,
		vec4 scals,
		float lat_signed,
		float current_temp,
		vec2 ocean_current_v,
		vec2 wind_v,
		float dyn_ice_frac) {
	return render_water_pipeline_raw(
		biome, cover, elev, wrap_world_pos(wp), uv, scals, lat_signed, current_temp, ocean_current_v, wind_v, dyn_ice_frac);
}
