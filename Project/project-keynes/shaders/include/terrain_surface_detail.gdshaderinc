// terrain_surface_detail.gdshaderinc
// Static terrain-edge antialiasing and one-sample world-space micro surface.
// Dynamic cell state always remains owned by map_index_atlas's hard primary cell.

struct TerrainStaticMaterial {
	vec3 color;
	float roughness;
	float micro_strength;
	vec2 material_normal_xy;
	float edge_factor;
	int secondary_biome;
};

int decode_edge_secondary_index(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(uv).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

bool terrain_static_biome_is_water(int biome) {
	return biome == B_OCEAN || biome == B_COAST || biome == B_LAKE
			|| biome == B_REEF || biome == B_KELP || biome == B_SEA_ICE;
}

float terrain_edge_screen_width_px() {
#if defined(PK_MOBILE_ANY)
	if (visual_quality >= 2) { return 1.25; }
	if (visual_quality >= 1) { return 1.00; }
	return 1.00;
#else
	if (visual_quality >= 2) { return 1.75; }
	if (visual_quality >= 1) { return 1.25; }
	return 1.00;
#endif
}

vec2 terrain_periodic_world_uv(vec2 wp, float tile_world_size) {
	float period = (wrap_period_x > 0.0001) ? wrap_period_x : max(world_size.x, 1.0);
	float repeat_count = max(1.0, floor(period / max(tile_world_size, 1.0) + 0.5));
	float wrapped_phase = (wrap_world_x(wp.x) - wrap_origin_x) / max(period, 0.0001);
	return vec2(wrapped_phase * repeat_count, wp.y / max(tile_world_size, 1.0));
}

// Mobile LOW/MID variants compile out the array path. Desktop and mobile HIGH
// still use the runtime switch so an allocation/import failure can fall back
// without selecting a different shader resource.
bool terrain_materials_active() {
#if defined(PK_QUALITY_LOW) || defined(PK_QUALITY_MID)
	return false;
#else
	return terrain_materials_enabled && terrain_material_tex_bound && visual_quality >= 2;
#endif
}

int terrain_material_layer(int biome) {
	if (biome == B_DESERT || biome == B_COLD_DESERT || biome == B_SALT_FLAT) {
		return 1;
	}
	if (biome == B_HILL || biome == B_MOUNTAIN || biome == B_BADLANDS || biome == B_MESA) {
		return 2;
	}
	if (biome == B_TUNDRA || biome == B_SNOW || biome == B_GLACIER
			|| biome == B_SWAMP || biome == B_MOOR) {
		return 3;
	}
	if (terrain_static_biome_is_water(biome)) {
		return -1;
	}
	// FOREST, GRASSLAND, PLAIN, JUNGLE, SAVANNA, TAIGA, STEPPE,
	// SHRUBLAND, OASIS, FLOODPLAIN, DELTA, MANGROVE and CHAPARRAL.
	return 0;
}

vec4 terrain_material_sample(int biome, vec2 wp) {
	int layer = terrain_material_layer(biome);
	if (layer < 0) {
		return vec4(1.0, 0.5, 0.5, 0.5);
	}
	vec2 material_uv = terrain_periodic_world_uv(wp, terrain_material_world_size);
	return texture(terrain_material_tex, vec3(material_uv, float(layer)));
}

vec3 terrain_material_albedo_detail(vec4 material) {
	return vec3(1.0 + (material.r - 0.5) * 2.0 * terrain_material_albedo_strength);
}

vec2 terrain_material_normal_detail(vec4 material) {
	return (material.gb * 2.0 - 1.0) * terrain_material_normal_strength;
}

float terrain_material_roughness(float base_roughness, vec4 material) {
	return mix(base_roughness, material.a, terrain_material_roughness_strength);
}

float terrain_bayer2_digit(vec2 bit_xy) {
	if (bit_xy.y < 0.5) {
		return (bit_xy.x < 0.5) ? 0.0 : 2.0;
	}
	return (bit_xy.x < 0.5) ? 3.0 : 1.0;
}

// A full [0, 1] Bayer rank contains a few near-zero samples. Across the broad
// terrain ecotone those samples survive almost the whole band and become long,
// one-texel "teeth". Compressing the rank tails preserves exactly 50% coverage
// at the cell boundary while keeping every Dither island compact.
const float TERRAIN_DITHER_THRESHOLD_MARGIN = 0.18;

// 移动端恢复 atlas-texel 锚定的 8x8 Bayer DitherUV。它只选择视觉主/副材质，
// 不改写 map_index_atlas.GB、CSR 或任何权威 cell 状态。
float terrain_mobile_dither_uv_threshold(vec2 uv, vec2 wp) {
	vec2 dither_dims = max(visual_reference_resolution, vec2(1.0));
	vec2 wrapped_uv = wrap_map_uv(uv);
	vec2 pixel_xy = floor(wrapped_uv * dither_dims);
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float period_px = max(
				8.0,
				round((dither_dims.x * wrap_period_x / world_size.x) / 8.0) * 8.0);
		float phase = (wrap_world_x(wp.x) - wrap_origin_x) / wrap_period_x;
		pixel_xy.x = floor(fract(phase) * period_px);
	}
	vec2 p = mod(pixel_xy, 8.0);
	float value = 16.0 * terrain_bayer2_digit(mod(p, 2.0))
			+ 4.0 * terrain_bayer2_digit(mod(floor(p * 0.5), 2.0))
			+ terrain_bayer2_digit(floor(p * 0.25));
	float raw_threshold = (value + 0.5) / 64.0;
	return mix(
			TERRAIN_DITHER_THRESHOLD_MARGIN,
			1.0 - TERRAIN_DITHER_THRESHOLD_MARGIN,
			raw_threshold);
}

// Distance field and DitherUV are complementary: the distance field defines
// the broad ecotone probability, while DitherUV converts it into stable map-
// anchored coverage. Land Dither is strictly a distant-view aid and fades to
// zero before close zoom, where enlarged 8x8 atlas texels become visible.
float terrain_land_dither_zoom_strength() {
#if defined(PK_MOBILE_ANY)
	// Keep the inexpensive mobile treatment for longer, but never carry its
	// atlas-sized blocks into the closest camera range.
	return 1.0 - smoothstep(1.65, 2.45, camera_zoom);
#else
	return 1.0 - smoothstep(1.20, 2.05, camera_zoom);
#endif
}

float terrain_hybrid_static_weight(float edge_w, vec2 uv, vec2 wp) {
	float dither_w = (terrain_mobile_dither_uv_threshold(uv, wp) < edge_w) ? 1.0 : 0.0;
#if defined(PK_MOBILE_ANY)
	float dither_strength = terrain_land_dither_zoom_strength();
#else
	float far_strength = (visual_quality <= 0) ? 0.92
			: ((visual_quality == 1) ? 0.74 : 0.62);
	float dither_strength = terrain_land_dither_zoom_strength() * far_strength;
#endif
	return mix(edge_w, dither_w, dither_strength);
}

// The inner fwidth band removes raster stair-steps. A wider world-space ecotone
// provides a shared visual anchor for the final land pipeline; cell-owned
// weather, fog, ecology and interaction state remain hard-primary data.
float terrain_edge_secondary_weight(vec2 uv, vec2 wp) {
	if (!has_terrain_edge_data) {
		return 0.0;
	}
	float distance_to_edge = visual_sample_edge_distance(uv).r;
#if defined(PK_MOBILE_ANY)
	float mobile_quality_scale = (visual_quality <= 0) ? 0.58
			: ((visual_quality == 1) ? 0.82 : 0.94);
	float mobile_width = clamp(
			terrain_ecotone_width * mobile_quality_scale,
			1.0 / 255.0,
			0.98);
	return 0.5 * (1.0 - smoothstep(0.0, mobile_width, distance_to_edge));
#else
	float one_screen_pixel = max(fwidth(distance_to_edge), 1.0 / 255.0);
	float aa_band = one_screen_pixel * terrain_edge_screen_width_px();
	float aa_weight = 0.5 * (1.0 - smoothstep(0.0, aa_band, distance_to_edge));

	float quality_scale = 1.0;
	quality_scale = (visual_quality <= 0) ? 0.68 : ((visual_quality == 1) ? 0.92 : 1.0);
	float base_width = clamp(terrain_ecotone_width * quality_scale, 0.0, 0.96);
	float max_width = min(0.98, base_width * (1.0 + abs(terrain_ecotone_noise)));
	if (distance_to_edge >= max_width || base_width <= 0.0001) {
		return aa_weight;
	}
	float width_noise = texture(
			noise_tex,
			terrain_periodic_world_uv(wp, 96.0) + vec2(0.173, 0.491)).r * 2.0 - 1.0;
	float natural_width = clamp(
			base_width * (1.0 + width_noise * terrain_ecotone_noise),
			min(aa_band, 0.98),
			0.98);
	float ecotone_weight = 0.5 * (1.0 - smoothstep(
			0.0, max(natural_width, 0.0001), distance_to_edge));
	return max(aa_weight, ecotone_weight);
#endif
}

float terrain_biome_micro_strength(int biome) {
	// [micro-soften 2026-07-31] 全表下调：旧值在近距下把微法线叠到 BRDF 后，
	// 干燥/有机地表会读成"碎石点阵"，盖过宏观坡向。岩石保留相对层次，但不再顶满。
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS || biome == B_MESA) {
		return 0.70; // rock
	}
	if (biome == B_DESERT || biome == B_COLD_DESERT || biome == B_COAST || biome == B_SALT_FLAT) {
		return 0.48; // sand / dry soil
	}
	if (biome == B_SWAMP || biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_MANGROVE) {
		return 0.32; // wet soil
	}
	if (biome == B_SNOW || biome == B_GLACIER || biome == B_TUNDRA) {
		return 0.22; // snow / ice
	}
	return 0.40; // organic terrain
}

TerrainStaticMaterial compute_terrain_static_material(
		int primary_biome,
		float elev,
		vec2 wp,
		vec2 uv) {
	TerrainStaticMaterial out_mat;
	vec3 hyps = hypsometric_tint(elev, false);
	bool use_material_tiles = terrain_materials_active();
	vec4 primary_material = use_material_tiles
			? terrain_material_sample(primary_biome, wp)
			: vec4(1.0, 0.5, 0.5, 0.5);
	vec3 detail = use_material_tiles
			? terrain_material_albedo_detail(primary_material)
			: procedural_biome_detail(primary_biome, wp, uv);
	out_mat.color = biome_hue_modulate(hyps, primary_biome) * detail;
	out_mat.roughness = use_material_tiles
			? terrain_material_roughness(biome_roughness(primary_biome), primary_material)
			: biome_roughness(primary_biome);
	out_mat.micro_strength = terrain_biome_micro_strength(primary_biome);
	out_mat.material_normal_xy = use_material_tiles
			? terrain_material_normal_detail(primary_material)
			: vec2(0.0);
	out_mat.edge_factor = 0.0;
	out_mat.secondary_biome = -1;

	float edge_w = terrain_edge_secondary_weight(uv, wp);
	if (edge_w <= 0.0001) {
		return out_mat;
	}
	int secondary_id = decode_edge_secondary_index(uv);
	if (secondary_id < 0) {
		return out_mat;
	}
	int secondary_biome = int(texture(enum_lut, cell_lut_uv(secondary_id)).r * 255.0 + 0.5);
	// The shared edge field also serves fog and weather across coastlines. Terrain
	// alone keeps the land/water material topology hard to prevent color leakage.
	if (terrain_static_biome_is_water(secondary_biome)
			!= terrain_static_biome_is_water(primary_biome)) {
		return out_mat;
	}
	if (secondary_biome == primary_biome) {
		return out_mat;
	}
	out_mat.edge_factor = edge_w;
	out_mat.secondary_biome = secondary_biome;

	float static_w = terrain_hybrid_static_weight(edge_w, uv, wp);
	vec4 secondary_material = use_material_tiles
			? terrain_material_sample(secondary_biome, wp)
			: vec4(1.0, 0.5, 0.5, 0.5);
	vec3 secondary_detail = use_material_tiles
			? terrain_material_albedo_detail(secondary_material)
			: procedural_biome_detail(secondary_biome, wp, uv);
	vec3 secondary_color = biome_hue_modulate(hyps, secondary_biome) * secondary_detail;
	out_mat.color = mix(out_mat.color, secondary_color, static_w);
	float secondary_roughness = use_material_tiles
			? terrain_material_roughness(biome_roughness(secondary_biome), secondary_material)
			: biome_roughness(secondary_biome);
	out_mat.roughness = mix(out_mat.roughness, secondary_roughness, static_w);
	vec2 secondary_normal_xy = use_material_tiles
			? terrain_material_normal_detail(secondary_material)
			: vec2(0.0);
	out_mat.material_normal_xy = mix(
			out_mat.material_normal_xy, secondary_normal_xy, static_w);
	out_mat.micro_strength = mix(
			out_mat.micro_strength,
			terrain_biome_micro_strength(secondary_biome),
			static_w);
	return out_mat;
}

float terrain_micro_zoom_alpha() {
	float fade_start;
	float fade_end;
	// [micro-soften 2026-07-31] 整体推迟约 0.25 zoom：中距鸟瞰只看宏观坡向，
	// 微表面留给真正近距。否则中距就开始叠砂砾法线，全图发碎。
#if defined(PK_MOBILE_ANY)
	if (visual_quality >= 2) {
		fade_start = 1.55;
		fade_end = 2.20;
	} else if (visual_quality >= 1) {
		fade_start = 1.80;
		fade_end = 2.50;
	} else {
		fade_start = 2.35;
		fade_end = 2.95;
	}
#else
	if (visual_quality >= 2) {
		fade_start = 1.30;
		fade_end = 1.95;
	} else if (visual_quality >= 1) {
		fade_start = 1.50;
		fade_end = 2.15;
	} else {
		fade_start = 2.05;
		fade_end = 2.75;
	}
#endif
	return smoothstep(fade_start, fade_end, camera_zoom);
}

float terrain_micro_normal_quality() {
	if (visual_quality <= 0) {
		return 0.0;
	}
#if defined(PK_MOBILE_ANY)
	return (visual_quality >= 2) ? 0.75 : 0.45;
#else
	return (visual_quality >= 2) ? 1.00 : 0.55;
#endif
}

vec2 terrain_micro_uv(vec2 wp) {
	// 64→110：同一张微纹理铺得更稀，凹凸特征从"砂砾点"变成更可读的地面起伏。
	return terrain_periodic_world_uv(wp, 110.0);
}

SurfaceParams apply_terrain_micro_surface(
		SurfaceParams surface,
		int biome,
		float mixed_micro_strength,
		vec2 wp,
		float moist,
		float vitality,
		float snow_amount) {
	// HIGH tiled materials already provide albedo, tangent normal and roughness;
	// keep the old micro texture completely out of that path.
	if (terrain_materials_active() || !has_terrain_micro_tex) {
		return surface;
	}
	float zoom_alpha = terrain_micro_zoom_alpha();
	if (zoom_alpha <= 0.0001) {
		return surface;
	}

	vec4 micro = texture(terrain_micro_tex, terrain_micro_uv(wp));
	vec2 micro_xy = micro.rg * 2.0 - 1.0;
	float organic = (biome == B_GRASSLAND || biome == B_FOREST || biome == B_PLAIN
			|| biome == B_JUNGLE || biome == B_TAIGA || biome == B_SAVANNA
			|| biome == B_STEPPE || biome == B_SHRUBLAND) ? 1.0 : 0.0;
	float wet_suppress = mix(1.0, 0.58, smoothstep(0.55, 0.95, moist));
	float vitality_gain = mix(1.0, mix(0.58, 1.08, clamp(vitality, 0.0, 1.0)), organic);
	float snow_flatten = 1.0 - smoothstep(0.08, 0.88, snow_amount) * 0.88;
	float strength = zoom_alpha * mixed_micro_strength * wet_suppress * vitality_gain;

	// [normal-soften 2026-07-31] 再降到 0.045：近距碎感的另一半来自微表面法线。
	// albedo 微粒（grain）保留更多，让"纹理感"走颜色而非法线噪声。
	float normal_strength = strength * terrain_micro_normal_quality() * snow_flatten * 0.045;
	surface.normal = normalize(vec3(
			surface.normal.xy + micro_xy * normal_strength,
			max(surface.normal.z, 0.12)));

	float rough_delta = (micro.b * 2.0 - 1.0) * 0.055 * strength;
	surface.roughness = clamp(
			surface.roughness + rough_delta - smoothstep(0.58, 0.98, moist) * 0.10,
			0.08,
			0.98);

	float grain = (micro.a * 2.0 - 1.0) * 0.028 * strength * snow_flatten;
	surface.base_color *= 1.0 + grain;
	return surface;
}

vec3 terrain_index_debug_color(int cid) {
	if (cid < 0) {
		return vec3(0.0);
	}
	float f = float(cid);
	return fract(vec3(0.1031, 0.11369, 0.13787) * f + vec3(0.17, 0.43, 0.71));
}

vec3 terrain_surface_debug_color(vec2 uv, vec2 wp, int primary_id) {
	if (terrain_surface_debug_view == 1) {
		return terrain_index_debug_color(primary_id);
	}
	if (terrain_surface_debug_view == 2) {
		return terrain_index_debug_color(
				has_terrain_edge_data ? decode_edge_secondary_index(uv) : -1);
	}
	if (terrain_surface_debug_view == 3) {
		float d = has_terrain_edge_data
				? visual_sample_edge_distance(uv).r
				: 1.0;
		return vec3(d);
	}
	if (terrain_surface_debug_view == 4) {
		return vec3(terrain_edge_secondary_weight(uv, wp) * 2.0);
	}
	if (terrain_surface_debug_view == 5) {
		vec2 n = !terrain_materials_active() && has_terrain_micro_tex
				? texture(terrain_micro_tex, terrain_micro_uv(wp)).rg
				: vec2(0.5);
		return vec3(n, terrain_micro_zoom_alpha());
	}
	// [terrain-material-tiles 诊断] 7 = 材质路径门禁可视化：
	// 绿=ACTIVE；蓝=tex 未绑定；品红=enabled=false；橙=其余情况（quality<2 / 编译裁剪）。
	// （6 已分配给植被层 LOD 调试，见 hex_renderer.terrain_surface_debug_view setter。）
	if (terrain_surface_debug_view == 7) {
		if (!terrain_materials_enabled) { return vec3(1.0, 0.0, 1.0); }
		if (!terrain_material_tex_bound) { return vec3(0.0, 0.0, 1.0); }
		if (!terrain_materials_active()) { return vec3(1.0, 0.5, 0.0); }
		return vec3(0.0, 1.0, 0.0);
	}
	return vec3(terrain_micro_zoom_alpha());
}
