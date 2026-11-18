// terrain_cell_field_detail.gdshaderinc
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field 2026-11-18] PK_CELL_FIELD 下的静态地表材质（3-way 版本）。
//
// 只在 world_map.gdshader 的 `#ifdef PK_CELL_FIELD` 段 include，依赖：
//   terrain_surface_detail.gdshaderinc  —— TerrainStaticMaterial / biome_hue_modulate /
//                                          procedural_biome_detail / terrain_material_* /
//                                          terrain_periodic_world_uv
//   hex_cell_field.gdshaderinc          —— HexCellField / cell_table 查表
//
// 职责：替换 compute_terrain_static_material() 在 PK_CELL_FIELD 下的实现。
//   方案 §3.6：「静态材质只采前两名」——底色（biome_hue_modulate，纯 ALU）做完整
//   3-way；terrain_material_tex 的 albedo detail / 法线 / 粗糙度只对权重前两名的
//   biome 采样，第三名的权重并入第二名。LOW 档只采视觉主格一份。
//
// 采样账（方案 §3.8 / §3.9，按「分支全部展平」的最坏情况）：
//   MID/HIGH：terrain_material_tex 恰好 **2** 次（rank0 + rank1），无条件执行；
//   LOW（PK_QUALITY_LOW）：恰好 **1** 次（视觉主格）。
//   本文件不含循环、不把 texture() 放进权重门控的 if、名次选择全是三元选择。
//   唯一的三元门控 `use_material_tiles` 与今日 compute_terrain_static_material 同源
//   （只读 uniform：enabled / tex_bound / visual_quality）⇒ warp 一致，不违反 §3.9。
// ═══════════════════════════════════════════════════════════════════════════

// 水面 program（PK_WATER_ONLY）不 include land_pipeline，且 uniforms.gdshaderinc:111
// 在这个 define 下**不声明** terrain_material_tex ⇒ 整段实现必须编译掉：GLSL 即使
// 函数无人调用也会做语义分析，引用未知采样器直接编译失败。
#ifndef PK_WATER_ONLY

// 材质贴图的无条件采样（方案 §3.9 第 2 / 3 条）。
// 不调 terrain_material_sample()：它内部有 `if (layer < 0) return` 早退，等价于把
// 带隐式导数的 texture() 放进非一致控制流（FXC 会强制展平或报 X3570）。
// 这里把 layer 无条件钳到 ≥ 0：水格/未知 biome 多付一次采样，但权重恒为 0，结果不变。
vec4 terrain_cell_field_material_sample(int biome, vec2 wp) {
	vec2 material_uv = terrain_periodic_world_uv(wp, terrain_material_world_size);
	int layer = max(terrain_material_layer(biome), 0);
	return texture(terrain_material_tex, vec3(material_uv, float(layer)));
}

// 静态地表材质（3-way 版）。入参：
//   f            —— SETUP 算一次的解析格界（world_map.gdshader）；
//   e0/e1/e2     —— 三格 class（biome/veg/cover/landform，与 f.c0/c1/c2 同序）；
//   primary_biome—— 视觉主 biome（门控阶段选出的那一格，land program 里恒为陆地）；
//   elev/wp/uv   —— 与 compute_terrain_static_material 同义。
TerrainStaticMaterial compute_terrain_static_material_field(
		HexCellField f, vec4 e0, vec4 e1, vec4 e2,
		int primary_biome, float elev, vec2 wp, vec2 uv) {
	TerrainStaticMaterial out_mat;
	vec3 hyps = hypsometric_tint(elev, false);
	bool use_material_tiles = terrain_materials_active();

	// ── 1. 三格 biome + 水陆同域过滤（方案 §3.7 / terrain_surface_detail:336）──
	// 陆地 program 只在陆地格之间混合、水面 program 只在水格之间混合；与主格**不同域**
	// 的格权重置 0 后重新归一。海陆过渡交给 shore 管线，颜色不跨水陆。
	int b0 = pk_byte_of(e0.r);
	int b1 = pk_byte_of(e1.r);
	int b2 = pk_byte_of(e2.r);
	bool ref_is_water = terrain_static_biome_is_water(primary_biome);
	vec3 w = f.w * vec3(
			(terrain_static_biome_is_water(b0) == ref_is_water) ? 1.0 : 0.0,
			(terrain_static_biome_is_water(b1) == ref_is_water) ? 1.0 : 0.0,
			(terrain_static_biome_is_water(b2) == ref_is_water) ? 1.0 : 0.0);
	float wsum = w.x + w.y + w.z;
	// 三格全被过滤掉（只在主格是异域、且另两格同域权重恰为 0 时出现）时的兜底：
	// 先退回「与 primary_biome 同 biome 的格」，再不行退回主导格。纯 ALU 三元选择，
	// 不采纹理；`max()` 兜住除零，不依赖 ?: 的短路求值。
	vec3 same_biome = vec3(
			(b0 == primary_biome) ? 1.0 : 0.0,
			(b1 == primary_biome) ? 1.0 : 0.0,
			(b2 == primary_biome) ? 1.0 : 0.0);
	float sb = same_biome.x + same_biome.y + same_biome.z;
	vec3 dom_onehot = (f.dom == 0) ? vec3(1.0, 0.0, 0.0)
			: ((f.dom == 1) ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
	vec3 fallback_w = (sb > 0.5) ? same_biome * (1.0 / max(sb, 1.0)) : dom_onehot;
	w = (wsum > 1e-4) ? w * (1.0 / max(wsum, 1e-4)) : fallback_w;
	// 过滤后 Σw == 1（或退化成一格独占 1）⇒ 下面所有 mix 的权重都是凸组合。

	// ── 2. 名次：按**过滤后**权重从高到低（平局次序 0 > 1 > 2，与场函数同序）───
	// 必须排过滤后的 w 而不是 f.w：海岸像素可能是「陆地 0.5 / 水 0.3 / 陆地 0.2」，
	// 按 f.w 排会拿到水格当第二名，把 water 的材质细节（layer 被钳到 0）混进陆地底色。
	// 全 == 0 只可能出现在上面的兜底之后，那时 w 是 onehot，名次恒定。
	int i_r0 = (w.x >= w.y && w.x >= w.z) ? 0 : ((w.y >= w.z) ? 1 : 2);
	// 第二名：在剩下的两格里取较大者；平局仍取下标小者。
	float cand_a = (i_r0 == 0) ? w.y : w.x;
	int   idx_a  = (i_r0 == 0) ? 1   : 0;
	float cand_b = (i_r0 == 2) ? w.y : w.z;
	int   idx_b  = (i_r0 == 2) ? 1   : 2;
	int i_r1 = (cand_a >= cand_b) ? idx_a : idx_b;
	int b_r0 = (i_r0 == 0) ? b0 : ((i_r0 == 1) ? b1 : b2);
	int b_r1 = (i_r1 == 0) ? b0 : ((i_r1 == 1) ? b1 : b2);
	float w_r0 = (i_r0 == 0) ? w.x : ((i_r0 == 1) ? w.y : w.z);
	float w_r1 = (i_r1 == 0) ? w.x : ((i_r1 == 1) ? w.y : w.z);

	// ── 3. 材质细节：只采前两名（方案 §3.6）───────────────────────────────
	// 第三名权重并入第二名：w1' = w1 + w2 = 1 - w0（Σw == 1）。
#ifdef PK_QUALITY_LOW
	// LOW：方案 §3.8 静态材质预算 = 1，只采视觉主格一份，不做名次折叠。
	int detail_biome0 = primary_biome;
	int detail_biome1 = primary_biome;
	float detail_mix = 0.0;
#else
	int detail_biome0 = b_r0;
	int detail_biome1 = b_r1;
	float detail_mix = 1.0 - w_r0;
#endif
	// 采样点**无条件执行**：rank1 权重为 0 时照采照乘（§3.9 第 2 条）。门控只读
	// uniform（warp 一致），与今日 compute_terrain_static_material 的写法同源。
	vec4 material0 = use_material_tiles
			? terrain_cell_field_material_sample(detail_biome0, wp)
			: vec4(1.0, 0.5, 0.5, 0.5);
	vec3 detail0 = use_material_tiles
			? terrain_material_albedo_detail(material0)
			: procedural_biome_detail(detail_biome0, wp, uv);
	vec4 material1 = material0;
	vec3 detail1 = detail0;
#ifndef PK_QUALITY_LOW
	// 第二份采样：MID/HIGH 无条件再采一次（采样数是编译期常数 2）。
	material1 = use_material_tiles
			? terrain_cell_field_material_sample(detail_biome1, wp)
			: vec4(1.0, 0.5, 0.5, 0.5);
	detail1 = use_material_tiles
			? terrain_material_albedo_detail(material1)
			: procedural_biome_detail(detail_biome1, wp, uv);
#endif
	// [web-high-features 2026-11-01 / 方案 B] 预算后端在材质族激活时也把烘焙 detail
	// 乘进 albedo（理由见 compute_terrain_static_material 的同段注释）：两名各乘一次，
	// LOW 只有一份 ⇒ 不会重复乘。
#if defined(PK_WEB_TEXTURE_BUDGET) && defined(VT_USE_TERRAIN_DETAIL)
	if (use_material_tiles && visual_quality >= 1 && terrain_detail_available()) {
		detail0 *= baked_biome_detail(detail_biome0, uv);
#ifndef PK_QUALITY_LOW
		detail1 *= baked_biome_detail(detail_biome1, uv);
#endif
	}
#endif

	// ── 4. 底色：色调走完整 3-way（纯 ALU），细节走 2-way ─────────────────
	// hue = Σ w_i · biome_hue_modulate(hyps, biome_i)，Σw == 1 ⇒ 凸组合，等价于
	// hyps × Σ w_i·mult_i。第三格（角点处）仍有色调贡献，肉眼看不出细节纹理的 2-way。
	vec3 detail = mix(detail0, detail1, detail_mix);
	vec3 hue = biome_hue_modulate(hyps, b0) * w.x
			+ biome_hue_modulate(hyps, b1) * w.y
			+ biome_hue_modulate(hyps, b2) * w.z;
	out_mat.color = hue * detail;

	float rough0 = use_material_tiles
			? terrain_material_roughness(biome_roughness(detail_biome0), material0)
			: biome_roughness(detail_biome0);
	vec2 normal0 = use_material_tiles
			? terrain_material_normal_detail(material0)
			: vec2(0.0);
	float micro0 = terrain_biome_micro_strength(detail_biome0);
	float rough1 = rough0;
	vec2 normal1 = normal0;
	float micro1 = micro0;
#ifndef PK_QUALITY_LOW
	rough1 = use_material_tiles
			? terrain_material_roughness(biome_roughness(detail_biome1), material1)
			: biome_roughness(detail_biome1);
	normal1 = use_material_tiles
			? terrain_material_normal_detail(material1)
			: vec2(0.0);
	micro1 = terrain_biome_micro_strength(detail_biome1);
#endif
	out_mat.roughness = mix(rough0, rough1, detail_mix);
	out_mat.material_normal_xy = mix(normal0, normal1, detail_mix);
	out_mat.micro_strength = mix(micro0, micro1, detail_mix);

	// ── 5. 接口字段（land_pipeline 暂只读 color / micro_strength，这里保持与非 PK
	//    路径同语义，避免以后接回时口径漂移）─────────────────────────────
	out_mat.edge_factor = 1.0 - w_r0;                        // 次生占比 = 非主导格权重和
	out_mat.secondary_biome = (w_r1 > 1e-4) ? b_r1 : -1;     // 次名权重为 0 时无次生
	return out_mat;
}

#endif // PK_WATER_ONLY
