extends SceneTree

const SHADER_PATH := "res://shaders/world_map.gdshader"
const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
const TERRAIN_RELIEF_UNIFORMS := [
	"tod_terrain_relief_slope_gain",
	"terrain_erosion_strength",
	"terrain_erosion_world_size",
]

var _checks := 0
var _failures := 0


func _init() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	# 本机 core.autocrlf=true，工作树的文本文件可能是 CRLF，而
	# FileAccess.get_file_as_string() 会原样保留 \r。把换行统一成 \n，否则所有跨行
	# needle 断言都会随"文件是否被重新 checkout"而飘（本文件曾因此假失败）。
	source = source.replace("\r\n", "\n")
	_expect(not source.is_empty(), "world shader source loads")
	# [cell-field 2026-11-18] 两份**展开后**的源码，后面两组断言共用（只算一次）：
	#   cf_off_expanded = 关（只带 PK_LAND_ONLY，即桌面 / 移动的陆地 program，今日行为）
	#   cf_land_expanded = 开（+ PK_CELL_FIELD）
	# 展开细节见 _expand_shader() 的注释：旧路径与新路径在同一文件里由 #ifdef 二选一，
	# 只有展开后计数 / 缺席断言才是有意义的。
	var cf_off_expanded := _expand_shader(SHADER_PATH, {"PK_LAND_ONLY": true})
	var cf_land_expanded := _expand_shader(SHADER_PATH,
		{"PK_CELL_FIELD": true, "PK_LAND_ONLY": true})
	# 另外两份**不展开 include** 的（只有 world_map.gdshader 自己），给"setup 里只采一次"
	# 这类断言用：include 展开后别的模块的采样也会被数进来，口径就不对了。
	var cf_wm_off := _expand_shader(SHADER_PATH, {"PK_LAND_ONLY": true}, false)
	var cf_wm_on := _expand_shader(SHADER_PATH,
		{"PK_CELL_FIELD": true, "PK_LAND_ONLY": true}, false)
	_expect(cf_off_expanded.length() > 4000 and cf_land_expanded.length() > 4000
		and cf_off_expanded != cf_land_expanded,
		"shader preprocessor expands both variants and the define changes the token stream"
			+ " (%d vs %d chars)" % [cf_off_expanded.length(), cf_land_expanded.length()])
	var surface_source := FileAccess.get_file_as_string(
		"res://shaders/include/terrain_surface_detail.gdshaderinc")
	var uniforms_source := FileAccess.get_file_as_string(
		"res://shaders/include/uniforms.gdshaderinc")
	var water_source := FileAccess.get_file_as_string(
		"res://shaders/include/water_pipeline.gdshaderinc")
	var land_source := FileAccess.get_file_as_string(
		"res://shaders/include/land_pipeline.gdshaderinc")
	var material_constants_source := FileAccess.get_file_as_string(
		"res://shaders/include/material_constants.gdshaderinc")
	var hillshade_source := FileAccess.get_file_as_string(
		"res://shaders/include/hillshade_tod.gdshaderinc")
	_expect(surface_source.contains("terrain_static_biome_is_water"),
		"terrain edge blend contains an explicit coast-domain guard")
	_expect(surface_source.contains("terrain_hybrid_static_weight"),
		"desktop terrain combines distance-field blending with zoom-aware DitherUV")
	_expect(source.contains("water_static_edge_mix = edge_weight")
		and source.contains("water_edge = is_water && edge_weight > 0.0001;"),
		"MID/HIGH ocean forwards a continuous distance-field weight")
	_expect(source.contains("#if !defined(PK_QUALITY_LOW)\n\t\twater_edge ="),
		"LOW compiles out secondary water-cell lookup")
	_expect(source.contains("secondary_water = terrain_static_biome_is_water(secondary_biome)")
		and source.contains("if (water_edge && secondary_water)"),
		"continuous ocean blending cannot cross the land/water domain")
	_expect(source.count("water_edge =") == 2
		and source.contains("bool water_edge = false;"),
		"ocean no longer converts its distance field to binary DitherUV")
	_expect(source.count("decode_edge_secondary_index(uv)") == 1
		and land_source.contains("compute_terrain_static_material(biome, elev, wp, uv, terrain_edge)"),
		"land, water and fog share the fragment's secondary cell lookup")
	_expect(water_source.contains("water_ctx_special_weights"),
		"water categories consume continuous primary/secondary weights")
	_expect(water_source.contains("continuous_sea_depth"),
		"MID/HIGH ocean depth uses the continuous interpolated height field")
	_expect(land_source.contains("vec3 river_surface_normal = vec3(0.0, 0.0, 1.0)"),
		"river normal starts from an independent horizontal water surface")
	_expect(land_source.contains(
		"normal = normalize(mix(normal, river_surface_normal, river_normal_w))"),
		"river center replaces terrain normal through an explicit bank blend")
	_expect(not land_source.contains("mix(normal, river_wn, river_w"),
		"river wave normal no longer inherits terrain normal in its core")
	_expect(land_source.contains("vec3 N = normalize(surface.macro_normal)"),
		"tod aspect relief reads the macro normal, not material detail")
	_expect(land_source.contains("length(surface.macro_normal.xy)"),
		"relief tint slope reads the macro normal")
	_expect(land_source.contains("sp.macro_normal = normalize(macro_normal)"),
		"land base surface keeps material detail out of macro_normal")
	_expect(land_source.contains("float facing = dot(Nh, Ln) * tod_terrain_relief_slope_gain")
		and not land_source.contains("slope_face = Nh / slope"),
		"tod relief scales with slope instead of a normalized binary aspect")
	_expect(hillshade_source.contains("vec4 terrain_baked_normal(")
		and land_source.contains("terrain_baked_normal(uv, visual_quality"),
		"macro normal carries the baked per-terrain detail")
	_expect(hillshade_source.contains("terrain_baked_normal(")
		and hillshade_source.contains("visual_terrain_relief_tiles"),
		"baked relief keeps the wrapped terrain sampling contract")
	_expect(material_constants_source.contains("RIVER_NORMAL_WAVE_WEIGHT")
		and material_constants_source.contains("RIVER_NORMAL_BLEND_END"),
		"river normal separation uses centralized material constants")
	_expect(source.contains("visual_land_biome"),
		"full land material pipeline consumes a DitherUV-selected visual biome")
	_expect(source.contains("visual_land_veg") and source.contains("visual_land_cover"),
		"land DitherUV selects static biome/vegetation/cover axes together")
	_expect(source.contains("if (land_edge && !secondary_water)")
		and source.contains("if (land_material_edge && !secondary_water)"),
		"land DitherUV cannot cross the land/water domain")
	_expect(surface_source.contains("terrain_land_dither_zoom_strength"),
		"land DitherUV has an explicit close-view zoom fade")
	_expect(not surface_source.contains("near_floor"),
		"close land view has no non-zero DitherUV floor")
	_expect(surface_source.contains("TERRAIN_DITHER_THRESHOLD_MARGIN"),
		"terrain Bayer rank tails are compressed to prevent elongated teeth")
	_expect(source.contains("? edge_weight * terrain_land_dither_zoom_strength() : 0.0;")
		and source.contains("land_edge = land_edge && dither < land_probability"),
		"full land visual cell selection shares the close-view zoom fade")
	var biome_detail_source := FileAccess.get_file_as_string(
		"res://shaders/include/biome_detail.gdshaderinc")
	_expect(biome_detail_source.contains(
		"landform_visual(int landform, vec2 wp, vec3 col, float slope_mag, float flow)"),
		"landform material receives continuous river geometry")
	_expect(biome_detail_source.contains("float rock_mask")
		and biome_detail_source.contains("vec3 rgb = mix(col, warm_rock, rock_mask)"),
		"canyon material is masked by continuous geometry")
	_expect(not biome_detail_source.contains("vec3 shade = col * vec3(0.68, 0.64, 0.64)"),
		"canyon no longer darkens the entire categorical cell")
	var renderer_settings_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_scene_settings.gd")
	var renderer_material_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_material_publish.gd")
	var renderer_shader_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_shader_water.gd")
	var renderer_variant_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_shader_variants.gd")
	# 注意：渲染设置脚本可能是 CRLF，而 FileAccess.get_file_as_string() 保留 \r，
	# 所以跨行 needle 在 LF 写法下永远不匹配（本断言曾因此长期 FAIL）。只匹配单行。
	_expect(renderer_material_source.contains(
		"sm.set_shader_parameter(\"visual_reference_resolution\","),
		"tiled DitherUV follows the active visual resolution")
	var variants := {
		"desktop": "",
		"mobile_low": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
		"mobile_mid": "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
		"mobile_high": "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
	}
	for label in variants:
		for mode in ["PK_BAKE_LAND_COLOR", "PK_BAKE_LAND_NORMAL", "PK_READ_LAND_BASE"]:
			var land_cache_shader := Shader.new()
			land_cache_shader.code = "#define %s\n#define PK_LAND_ONLY\n#define PK_CELL_FIELD\n" % mode + String(variants[label]) + source
			var cache_uniforms := land_cache_shader.get_shader_uniform_list()
			_expect(not cache_uniforms.is_empty()
				and cache_uniforms.any(func(u): return u.name == &"land_base_color") == (mode == "PK_READ_LAND_BASE"),
				"%s %s compiles with the expected cache input" % [label, mode])
		var shader := Shader.new()
		shader.code = String(variants[label]) + source
		var uniforms: Array = shader.get_shader_uniform_list()
		var names := {}
		for entry in uniforms:
			names[String(entry.get("name", ""))] = true
		# [surface-array-edge 2026-11-02] 非 tiled 的 edge 数据改读 surface array 的
		# layer4/5：2D terrain_edge_*_tex 采样器不再出现在地形程序里（它们仍服务于
		# fog / 边线 / 天气等独立图层），contract 变成"一个 array + 层数门控"。
		_expect(not names.has("terrain_edge_neighbor_tex"),
			"%s omits the 2D edge neighbor sampler (surface array layer5)" % label)
		_expect(not names.has("terrain_edge_distance_tex"),
			"%s omits the 2D edge distance sampler (surface array layer4)" % label)
		_expect(names.has("terrain_surface_tex") and names.has("terrain_edge_layers_bound"),
			"%s reads edge layers from the packed surface array" % label)
		_expect(names.has("terrain_ecotone_width"), "%s exposes terrain ecotone width" % label)
		_expect(names.has("terrain_ecotone_noise"), "%s exposes terrain ecotone noise" % label)
		_expect(names.has("terrain_micro_tex"), "%s exposes terrain micro texture" % label)
		_expect(names.has("terrain_material_tex"), "%s exposes terrain material array" % label)
		_expect(names.has("terrain_material_tex_bound"), "%s exposes terrain material bound flag" % label)
		_expect(names.has("terrain_materials_enabled"), "%s exposes terrain material switch" % label)
		_expect(names.has("terrain_material_world_size"), "%s exposes terrain material world size" % label)
		for relief_uniform in TERRAIN_RELIEF_UNIFORMS:
			_expect(names.has(relief_uniform), "%s exposes %s" % [label, relief_uniform])
		_expect(names.has("camera_zoom"), "%s exposes camera zoom" % label)
	for label in variants:
		var shader := Shader.new()
		shader.code = "#define MAP_VISUAL_TILED\n" + String(variants[label]) + source
		var uniforms: Array = shader.get_shader_uniform_list()
		var names := {}
		for entry in uniforms:
			names[String(entry.get("name", ""))] = true
		_expect(not uniforms.is_empty(), "%s tiled variant compiles" % label)
		_expect(names.has("visual_height_tiles"), "%s tiled exposes height array" % label)
		_expect(names.has("visual_map_index_tiles"), "%s tiled exposes map-index array" % label)
		_expect(names.has("visual_horizon_tiles"), "%s tiled exposes horizon array" % label)
		_expect(not names.has("visual_flow_tiles"),
			"%s tiled omits retired visual_flow_tiles (height.B)" % label)
		_expect(not names.has("height_tex"), "%s tiled omits legacy height sampler" % label)
		_expect(not names.has("map_index_atlas"), "%s tiled omits legacy map-index sampler" % label)
		_expect(not names.has("terrain_horizon_tex"), "%s tiled omits legacy horizon sampler" % label)
		_expect(names.has("terrain_material_tex"), "%s tiled exposes terrain material array" % label)
		_expect(names.has("visual_terrain_relief_tiles") and names.has("terrain_static_baked"),
			"%s tiled exposes baked terrain relief + static-bake gate" % label)
	_expect(hillshade_source.contains("vec4 terrain_baked_normal(")
		and land_source.contains("terrain_baked_normal(uv, visual_quality"),
		"tiled land reads baked landform detail instead of per-pixel noise")
	var shore_source := FileAccess.get_file_as_string(
		"res://shaders/include/shore_common.gdshaderinc")
	_expect(shore_source.contains("shore_frac.x * 8.0")
		and not shore_source.contains("visual_sample_terrain_detail"),
		"shore neighbourhood reuses baked edge_distance.ba (no extra fetch)")
	var tile_sampling_source := FileAccess.get_file_as_string(
		"res://shaders/include/visual_tile_sampling.gdshaderinc")
	var horizon_source := FileAccess.get_file_as_string(
		"res://shaders/include/terrain_horizon.gdshaderinc")
	_expect(tile_sampling_source.count("textureGather(visual_horizon_tiles") == 2
		and tile_sampling_source.contains("CURRENT_RENDERER != RENDERER_COMPATIBILITY")
		and horizon_source.contains("visual_gather_horizon(uv, p00, p10, p01, p11, f)"),
		"tiled Vulkan horizon fetches its 2x2 footprint with two gathers")
	var snow_source := FileAccess.get_file_as_string(
		"res://shaders/include/snow_cover.gdshaderinc")
	_expect(snow_source.contains("float amount_n = pixel_noise.r * 0.5;")
		and not water_source.contains("water_fbm_cyl(ctx.wpw, 0.045"),
		"snow jitter and sea-ice edge reuse pixel_noise")
	var water_inc_source := FileAccess.get_file_as_string(
		"res://shaders/include/water.gdshaderinc")
	_expect(water_inc_source.contains("textureGather(noise_tex, nuv, 1)")
		and water_inc_source.contains("vec2 h_grad = water_surface_height_grad("),
		"water normal uses an analytic gradient (one gather) instead of 4 height taps")
	_expect(water_source.contains("bw = vec4(ctx.water_depth_px.gba, 0.0)")
		and water_source.count("visual_sample_water_depth(") == 1,
		"water pipeline fetches water_depth once (depth + baked 3x3 weights)")
	_expect(source.contains("vec4 height_px = visual_sample_height(uv)")
		and source.contains("vec4 map_px = visual_sample_map_index(uv)")
		and not source.contains("dyn_lut_nearest("),
		"fragment setup fetches height and map_index once")
	# [cell-field 2026-11-18] 这条改成按**展开后**的源码计数：edge_distance 在 PK / 非 PK
	# 两条互斥分支里各有一处（PK 分支 scals.r 改解析格距，scals.a 仍读烘焙沟谷 crease），
	# 输出段的 debug 视图（gap 差值）还会额外采一次做对照 —— 那是调试专用，不计入
	# 每像素采样预算。所以：关 = 全文 1 次；开 = SETUP 段（第一个 render_land_pipeline(
	# 之前）至多 1 次；land_pipeline 自己永不再采。
	var cell_field_setup_end := cf_wm_on.find("render_land_pipeline(")
	var cell_field_setup := cf_wm_on if cell_field_setup_end < 0 \
		else cf_wm_on.substr(0, cell_field_setup_end)
	_expect(cf_wm_off.count("visual_sample_edge_distance(") == 1
		and cell_field_setup.count("visual_sample_edge_distance(") <= 1
		and not land_source.contains("visual_sample_edge_distance(")
		and land_source.contains("terrain_baked_normal(uv, visual_quality, scals.a)"),
		"edge_distance fetched once per setup and reused via scals.r/.a"
			+ " (off=%d pk_setup=%d land=%d)" % [
				cf_wm_off.count("visual_sample_edge_distance("),
				cell_field_setup.count("visual_sample_edge_distance("),
				land_source.count("visual_sample_edge_distance(")])
	_expect(uniforms_source.contains("sampler2DArray terrain_material_tex"),
		"terrain material path uses sampler2DArray")
	_expect(surface_source.contains("float material_path_scale = terrain_materials_active() ? 0.72 : 1.0;"),
		"HIGH tiled material path keeps a restrained terrain_micro_tex layer")
	_expect(surface_source.contains("terrain_material_layer")
		and surface_source.contains("terrain_material_sample"),
		"biome-to-layer material sampling is present")
	_expect(not uniforms_source.contains("uniform sampler2D eco_lut"),
		"main terrain uniforms no longer declare eco_lut")
	var web_budget := Shader.new()
	web_budget.code = "#define PK_WEB_TEXTURE_BUDGET\n" + source
	var web_names := {}
	var web_sampler_count := 0
	for entry in web_budget.get_shader_uniform_list():
		web_names[String(entry.get("name", ""))] = true
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			web_sampler_count += 1
	# [cell-field-web 2026-11-18 / W6] 口径统一成**等值**（与后面四套前缀普查同一个判据）：
	# 这个 program 就是预算 OFF 变体自身，普查里它的 OFF 张数是 8。掉一张或长一张都说明
	# 声明区的宏门被动了（阈值会把这两种漂移静默吞掉）。W2 之后 PK 侧是 6，见 730 行那条。
	_expect(web_sampler_count == 8,
		"web budget keeps exactly 8 material samplers (got %d)" % web_sampler_count)
	_expect(not web_names.is_empty(), "web texture budget variant compiles")
	_expect(web_names.has("terrain_material_tex"),
		"web budget exposes terrain_material_tex after eco_lut retire")
	for relief_uniform in TERRAIN_RELIEF_UNIFORMS:
		_expect(web_names.has(relief_uniform), "web budget exposes %s" % relief_uniform)
	_expect(not web_names.has("eco_lut"),
		"web budget omits eco_lut from main terrain")
	_expect(not web_names.has("flow_tex"),
		"web budget omits retired legacy flow_tex (packed into height_tex.B)")
	_expect(web_names.has("has_flow_tex"),
		"web budget keeps has_flow_tex gate")
	_expect(not web_names.has("terrain_micro_tex"),
		"web budget still omits terrain_micro_tex")
	_expect(not web_names.has("visual_terrain_relief_tiles"),
		"web budget omits baked terrain relief sampler")
	_expect(web_names.has("terrain_surface_tex")
		and web_names.has("terrain_edge_layers_bound")
		and not web_names.has("terrain_edge_neighbor_tex"),
		"web budget restores edge blending from the surface array, not a new sampler")
	for label in variants:
		var shader := Shader.new()
		shader.code = String(variants[label]) + source
		var names := {}
		for entry in shader.get_shader_uniform_list():
			names[String(entry.get("name", ""))] = true
		_expect(not names.has("flow_tex"),
			"%s legacy omits flow_tex sampler (height_tex.B)" % label)
		_expect(names.has("height_tex") and names.has("has_flow_tex"),
			"%s legacy keeps height_tex + has_flow_tex" % label)
		# [surface-array-edge 2026-11-02] 非 tiled 打包路径现在也产出 edge 层，所以
		# 它同样带静态烘焙门（PK_TERRAIN_STATIC_PACKED）；门的值由运行期按
		# terrain_surface_layer_count>=6 推送。
		_expect(names.has("terrain_static_baked"),
			"%s legacy exposes the packed static-bake gate" % label)
	# ── [web-world-min] web/GLES3 的 world_map 裁剪变体 ───────────────────────
	# 这一组断言守的是三条不变量：
	#   ① 运行期（hex_renderer._apply_shader_variant_prefix）与菜单期预热
	#      （WebShaderWarmup）拼出的前缀必须逐字相同，差一个字节驱动就不认缓存；
	#   ② 该变体真的能在 Godot 的 shader 语言里编过（不是只靠注释骗过 grep）；
	#   ③ 宏链接错（有 PK_WEB_WORLD_MIN 却没有 PK_QUALITY_LOW）时必须炸，不能静默
	#      退化成"桌面版字节 + 一堆被删掉的符号"。
	var web_min_source := FileAccess.get_file_as_string(
		"res://shaders/include/world_map_web_min.gdshaderinc").replace("\r\n", "\n")
	var runtime_prefix := HexRenderer.QUALITY_PREFIX_LOW \
		+ HexRenderer.PK_WEB_TEXTURE_BUDGET_DEFINE \
		+ HexRenderer.WORLD_MAP_WEB_MIN_DEFINE \
		+ HexRenderer.WORLD_MAP_WEB_NO_MICRO_DEFINE \
		+ HexRenderer.WORLD_MAP_WEB_LAND_ONLY_DEFINE \
		+ HexRenderer.WORLD_MAP_WEB_HORIZON_DEFINE
	_expect(runtime_prefix == HexRenderer.WORLD_MAP_WEB_PREFIX,
		"runtime web-LOW prefix is byte-identical to WORLD_MAP_WEB_PREFIX")
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX
		== "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
			+ "#define PK_WEB_TEXTURE_BUDGET\n#define PK_WEB_WORLD_MIN\n"
			+ "#define PK_PROBE_NO_MICRO\n#define PK_WEB_LAND_ONLY\n"
			+ "#define PK_WEB_HORIZON\n",
		"web-LOW prefix keeps the current quality and land-pass define order")
	_expect(WebShaderWarmup.WORLD_MAP_PREFIX == HexRenderer.WORLD_MAP_WEB_PREFIX,
		"the warmup module's NO_MICRO constant is forwarded from the renderer"
			+ " (no second literal; it is the micro kill-switch, not the default)")
	# [cell-field-web 2026-11-18 / W6] 预热清单里 world_map / world_water_web 两条**故意
	# 不再自带 `prefix` 字段**：W6 之后它们的运行期前缀不再是一个常量（world_map 默认是
	# MICRO 变体、水面还要叠载荷宏），任何常量写法都会与真源分叉。真源是
	# `RendererShaderWater.web_warmup_program_prefixes()`，逐字节对账见下面 ④ 那组。
	_expect(not _shaders_entry_for(SHADER_PATH).has("prefix")
		and not _shaders_entry_for("res://shaders/world_water_web.gdshader").has("prefix")
		and WebShaderWarmup.SHADERS.size() > 2,
		"the warmup list declares no stale prefix for world_map / world_water_web"
			+ " (their bytes come from web_warmup_program_prefixes only)")
	_expect(not WebShaderWarmup.TIER_PREFIX.contains("PK_WEB_WORLD_MIN"),
		"TIER_PREFIX stays world-min free (weather_overlay shares it)")
	_expect(renderer_variant_source.contains("const QUALITY_PREFIX_LOW"),
		"LOW tier prefix is the shared QUALITY_PREFIX_LOW constant")
	_expect(source.contains("#include \"res://shaders/include/common_noise.gdshaderinc\""),
		"world_map keeps the shared noise include in every variant")
	_expect(source.contains("#ifndef PK_WEB_WORLD_MIN\n"
		+ "#include \"res://shaders/include/weather_front.gdshaderinc\"\n#endif"),
		"world_map guards weather fronts behind PK_WEB_WORLD_MIN")
	_expect(source.contains("#if !defined(PK_WEB_WORLD_MIN) && !defined(PK_WEB_LAND_ONLY)\n"
		+ "#include \"res://shaders/include/water.gdshaderinc\"\n#endif"),
		"world_map omits the water helper from the web land pass")
	_expect(source.contains("#include \"res://shaders/include/tonemap.gdshaderinc\""),
		"world_map keeps the shared tonemap include")
	_expect(source.contains("#ifndef PK_WEB_WORLD_MIN\n"
		+ "#include \"res://shaders/include/shore_common.gdshaderinc\"\n#endif"),
		"world_map guards shore helpers behind PK_WEB_WORLD_MIN")
	_expect(source.contains("#include \"res://shaders/include/terrain_horizon.gdshaderinc\""),
		"world_map keeps the shared baked horizon include")
	_expect(source.contains("#ifdef PK_WEB_WORLD_MIN\n"
		+ "#include \"res://shaders/include/world_map_web_min.gdshaderinc\"\n#else\n"
		+ "#include \"res://shaders/include/cell_indirect.gdshaderinc\"\n#endif"),
		"cell_indirect is replaced by the web-min leaf set before its first user")
	_expect(web_min_source.contains("#ifndef PK_QUALITY_LOW")
		and web_min_source.contains("#error"),
		"web-min include fails loudly when the tier macro is missing")
	_expect(horizon_source.contains("float terrain_horizon_apply_normal(")
		and horizon_source.contains("mix(gi_normal_floor, 1.0, align)"),
		"web-min keeps the shared horizon normal formula")
	_expect(web_min_source.contains("float water_periodic_wave_phase(")
		and web_min_source.contains("vec2 cell_lut_uv(")
		and not web_min_source.contains("vec3 tonemap_reinhard_legacy("),
		"web-min supplies only the surviving leaf helpers")
	var web_min := Shader.new()
	web_min.code = HexRenderer.WORLD_MAP_WEB_PREFIX + source
	var wm_names := {}
	var wm_samplers := 0
	for entry in web_min.get_shader_uniform_list():
		wm_names[String(entry.get("name", ""))] = true
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			wm_samplers += 1
	_expect(not wm_names.is_empty(),
		"web-world-min variant compiles in the shader language")
	# [cell-field-web 2026-11-18 / W6] 等值口径：这个 program = WORLD_MAP_WEB_PREFIX 的
	# OFF 变体，普查里它的 OFF 张数就是 8（同一批 OFF 名单）。W6 之后 PK 侧是 6，那条在
	# 下面 web_census_prefixes 的等值断言里。
	_expect(wm_samplers == 8,
		"web-world-min keeps exactly 8 material samplers (got %d)" % wm_samplers)
	_expect(wm_names.has("has_flow_tex") and wm_names.has("height_tex"),
		"web-world-min keeps the flow diagnostics keys")
	_expect(wm_names.has("weather_front_count") and wm_names.has("gi_normal_floor")
		and wm_names.has("terrain_horizon_tex") and wm_names.has("noise_tex"),
		"web-world-min keeps ABI parity for pushed-but-unused uniforms")
	_expect(wm_names.has("terrain_surface_tex") and wm_names.has("terrain_edge_layers_bound")
		and not wm_names.has("terrain_edge_neighbor_tex"),
		"web-world-min restores edge blending from the surface array, not a new sampler")
	_expect(not web_min_source.contains("uniform sampler"),
		"web-min leaf set declares no samplers of its own")
	# 宏链接错的负例：只给 PK_WEB_WORLD_MIN、不给档位宏时，预处理必须让它编不出来。
	var broken_macro := Shader.new()
	broken_macro.code = HexRenderer.WORLD_MAP_WEB_MIN_DEFINE + source
	_expect(broken_macro.get_shader_uniform_list().is_empty(),
		"PK_WEB_WORLD_MIN without PK_QUALITY_LOW does not compile (guard works)")
	# ── [web-water-pass] 水面拆成第二个 pass（结构性修复，不是裁剪）───────────
	# 这一组守三条不变量：
	#   ① world_map 在 PK_WEB_WORLD_MIN 下**不再有任何水面着色来源**（只出常量）。
	#      上一轮那个 25 行的"紧凑水面"实测仍要 17 264 ms，把它放回去等于把 20 秒
	#      悬崖一起放回来，而且再也看不出是谁干的；
	#   ② 新 pass 的解码 / 水格判定 / 迷雾口径 / 收口与 world_map **逐字同源**，
	#      不是"第二套约定"；
	#   ③ 运行期（HexRenderer）与菜单期预热（WebShaderWarmup）拼出的前缀逐字一致，
	#      且不含 PK_WEB_WORLD_MIN（那宏只对 world_map 的裁剪有意义）。
	var water_pass_source := FileAccess.get_file_as_string(
		"res://shaders/world_water_web.gdshader").replace("\r\n", "\n")
	_expect(not water_pass_source.is_empty(), "web water pass shader source loads")
	_expect(source.count("render_water_pipeline(") == 1,
		"world_map keeps exactly one water shading call (the desktop path)")
	_expect(not source.contains("render_water_pipeline_web_min"),
		"the compact web water function is gone, not merely unused")
	_expect(source.count("col = vec3(0.1, 0.2, 0.4);") == 2,
		"web-min water branch and the no-water probe both emit the placeholder constant")
	var water_variant := Shader.new()
	water_variant.code = HexRenderer.WATER_PASS_PREFIX + water_pass_source
	var water_uniform_list: Array = water_variant.get_shader_uniform_list()
	var water_names := {}
	var water_samplers := 0
	for entry in water_uniform_list:
		water_names[String(entry.get("name", ""))] = true
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			water_samplers += 1
	_expect(not water_names.is_empty(),
		"web water pass compiles in the shader language")
	_expect(water_names.has("enum_lut") and water_names.has("dyn_lut")
		and water_names.has("map_index_atlas") and water_names.has("height_tex"),
		"water pass decodes the same cell-index inputs as world_map")
	_expect(water_names.has("lut_dims") and water_names.has("wrap_period_x"),
		"water pass follows the shared cell-LUT grid + wrap convention")
	# [surface-array-edge 2026-11-02] compact 水面 5→6 槽：新增的唯一采样器是与陆地
	# 程序共用的 6 层 surface array（layer4/5 = edge_distance / edge_neighbor）。
	# 恢复 edge_mix / shore_frac / 次生水格**不得**再引入 2D edge sampler。
	# [cell-field-web 2026-11-18 / W6] 等值口径（与普查同一判据）：这份 program 是
	# `WATER_PASS_PREFIX + world_water_web.gdshader`，也就是**宏关**时的紧凑水面 pass。
	# 它的 7 张 = 普查里"water OFF"那份 8 张名单**减去 noise_tex**（本 pass 刻意不声明它，
	# 见下面 "does not inherit world_map uniforms" 那条），不是 6 —— 6 是
	# WATER_WEB_HIGH_PREFIX（走 world_map 源码）的 PK 侧张数，两个 program 别混。
	# 宏开（MATCHES_LAND）时这份会变成 6（enum/dyn/map_index 三槽让位给 cell_table），
	# 那一种是 web_water_pass_node_test 的 ⑦ 组在管。等值而不是阈值：多一张/少一张都是声明
	# 区被动过的信号，阈值（>=6 and <=8）恰好会把这两种漂移都吞掉。
	var water_off_samplers := PackedStringArray()
	for entry in water_uniform_list:
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			water_off_samplers.append(String(entry.get("name", "")))
	water_off_samplers.sort()
	var expected_water_off_samplers := PackedStringArray([
		"dyn_lut", "enum_lut", "height_tex", "map_index_atlas",
		"ocean_current_flow_tex", "terrain_surface_tex", "water_depth_tex",
	])
	expected_water_off_samplers.sort()
	_expect(water_samplers == expected_water_off_samplers.size()
		and water_off_samplers == expected_water_off_samplers,
		"compact water pass keeps exactly %d samplers, name for name (got %d: %s)"
			% [expected_water_off_samplers.size(), water_samplers,
				str(water_off_samplers)])
	_expect(water_names.has("terrain_surface_tex")
		and water_names.has("terrain_edge_layers_bound")
		and water_names.has("has_terrain_edge_data"),
		"water pass restores edge_mix/shore_frac from the surface array")
	_expect(not water_names.has("terrain_edge_neighbor_tex")
		and not water_names.has("terrain_edge_distance_tex"),
		"water pass does not reintroduce the 2D edge samplers")
	_expect(water_uniform_list.size() >= 16,
		"water pass stays a small uniform set, not world_map's 186 (got %d)"
			% water_uniform_list.size())
	_expect(not water_names.has("noise_tex") and not water_names.has("terrain_material_tex"),
		"water pass does not inherit world_map uniforms it cannot consume")
	var water_broken := Shader.new()
	water_broken.code = water_pass_source
	_expect(water_broken.get_shader_uniform_list().is_empty(),
		"water pass without MOBILE_QUALITY_LOW does not compile (guard works)")
	# ② 逐字同源：水格判定表达式、wrap helper、biome/cover id 常量。
	var water_predicate := "\tbool is_water = (biome == B_OCEAN) || (biome == B_COAST)" \
		+ " || (biome == B_LAKE)\n\t\t\t|| (biome == B_REEF) || (biome == B_KELP)" \
		+ " || (biome == B_SEA_ICE);"
	_expect(source.contains(water_predicate) and water_pass_source.contains(water_predicate),
		"water-cell predicate is byte-identical between pass 1 and pass 2")
	for signature in ["float wrap_world_x(", "vec2 wrap_map_uv("]:
		var block := _function_block(uniforms_source.replace("\r", ""), signature)
		_expect(not block.is_empty() and water_pass_source.contains(block),
			"water pass copies %s verbatim from uniforms.gdshaderinc" % signature)
	_expect(water_pass_source.contains(
		"#include \"res://shaders/include/cell_indirect.gdshaderinc\""),
		"water pass reuses cell_lut_uv instead of inventing a LUT grid")
	var flat_uniforms := _collapse_whitespace(uniforms_source.replace("\r", ""))
	var flat_water := _collapse_whitespace(water_pass_source)
	for pair in [["B_OCEAN", 0], ["B_COAST", 1], ["B_LAKE", 18], ["B_REEF", 19],
			["B_SEA_ICE", 20], ["B_KELP", 21], ["CV_SEA_ICE", 3]]:
		var declaration := "const int %s = %d;" % [String(pair[0]), int(pair[1])]
		_expect(flat_uniforms.contains(declaration) and flat_water.contains(declaration),
			"water pass re-declares %s with uniforms.gdshaderinc's value" % pair[0])
	# ③ 前缀真源 + 预热对账 + 渲染器接线（renderer 是 CRLF，只能单行 needle）。
	_expect(HexRenderer.WATER_PASS_PREFIX
		== "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
			+ "#define PK_WEB_TEXTURE_BUDGET\n",
		"water pass prefix is quality -> texture-budget (no world-min)")
	_expect(not HexRenderer.WATER_PASS_PREFIX.contains("PK_WEB_WORLD_MIN"),
		"water pass prefix stays world-min free")
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX
		== HexRenderer.WATER_PASS_PREFIX
			+ HexRenderer.WORLD_MAP_WEB_MIN_DEFINE
			+ HexRenderer.WORLD_MAP_WEB_NO_MICRO_DEFINE
			+ HexRenderer.WORLD_MAP_WEB_LAND_ONLY_DEFINE
			+ HexRenderer.WORLD_MAP_WEB_HORIZON_DEFINE,
		"the web land prefix adds the current world-min, micro, land and horizon defines")
	# [cell-field-web 2026-11-18 / W6] 水面 pass 的预热前缀**不再**是常量 WATER_PASS_PREFIX：
	# 开态下它前面还要叠载荷宏 PK_WATER_FIELD_MATCHES_LAND，所以这里只能断言"清单里没有
	# 会分叉的文档值"，真值逐字节对账交给下面 ④ 那组（预设 = 运行期拼装函数）。
	_expect(not _shaders_entry_for("res://shaders/world_water_web.gdshader").has("prefix"),
		"the warmup list keeps no stale water-pass prefix constant"
			+ " (bytes come from web_warmup_program_prefixes)")
	_expect(renderer_variant_source.contains("static func _water_pass_active(host)")
		and renderer_variant_source.contains("if OS.has_feature(\"web\")"),
		"water pass creation is gated on the web platform")
	var water_shader_preload := "preload(\"res://shaders/world_water_web.gdshader\")"
	_expect(not renderer_shader_source.contains(water_shader_preload)
		and not renderer_variant_source.contains(water_shader_preload),
		"water shader is loaded lazily, never preloaded on desktop")
	var draw_order := HexRenderer.new()
	draw_order._world_quad = MeshInstance2D.new()
	draw_order.add_child(draw_order._world_quad)
	var detail := Node2D.new()
	draw_order.add_child(detail)
	draw_order._water_quad = MeshInstance2D.new()
	draw_order._graphics_details.attach_water_surface(draw_order)
	_expect(renderer_shader_source.contains("_water_quad.z_index = 0")
		and draw_order._water_quad.get_index() == draw_order._world_quad.get_index() + 1
		and detail.get_index() > draw_order._water_quad.get_index(),
		"water quad sits right after the world quad (above land, below detail)")
	draw_order.free()
	_expect(renderer_shader_source.contains("static func _sync_water_quad(host)")
		and renderer_shader_source.contains("WebTelemetry.note_variant(\"world_water_web\""),
		"water pass is created by _apply_uniforms and reported to warmup reconciliation")
	# ══ [cell-field 2026-11-18] 解析格界（PK_CELL_FIELD）变体管线 ═══════════════
	# 这一组守四件事：
	#   ① 带宏的变体真的能在 Godot 的 shader 语言里编过（桌面 / 移动 / tiled / 陆 / 水）；
	#   ② **关的时候一个字节都不多加**，开的时候恰好是「原前缀 + 一个 define」——
	#      前缀字节身份是项目契约（方案 §3.10「关闭时与今日逐像素一致」）；
	#   ③ 陆地与水面两条拼装路径**同时**带宏（方案 §3.7：一边带一边不带 ⇒ 海岸出洞）；
	#   ④ 菜单期预热（WebShaderWarmup）登记的组合与运行期逐字节一致，且由同一个开关门控。
	var cell_field_define := HexRenderer.CELL_FIELD_DEFINE
	_expect(cell_field_define == "#define PK_CELL_FIELD\n",
		"PK_CELL_FIELD is one constant, not a literal at each call site")
	_expect(HexRenderer.CELL_FIELD_SETTING
		== "project_keynes/rendering/map_tiles/terrain_cell_field_enabled",
		"cell-field switch follows the project_keynes/rendering/<subsystem>/<key> convention")
	# [2026-11-18] 出货默认**开**：project.godot 里显式写了 true，代码 fallback 也是 true。
	_expect(HexRenderer.cell_field_setting_enabled(),
		"PK_CELL_FIELD ships enabled by default (project setting + code fallback both true)")
	_expect(renderer_shader_source.count("#define PK_CELL_FIELD")
		+ renderer_variant_source.count("#define PK_CELL_FIELD") == 1,
		"the define literal exists exactly once in the renderer module")
	# ② 前缀字节身份。假 host 只提供 RendererShaderWater 真正读到的字段（桌面 / 非 tiled /
	# 拆分开 / quality 0 ⇒ 云影走 composite），所以下面两条字面量就是**改动前**这条路径
	# 拼出来的全部字节：关的时候必须逐字节相同。
	var fake_cell_field_off := FakeShaderHost.new()
	fake_cell_field_off.terrain_cell_field_enabled = false
	var fake_cell_field_on := FakeShaderHost.new()
	fake_cell_field_on.terrain_cell_field_enabled = true
	# Compatibility waits for its startup capability check before enabling the field.
	RendererShaderWaterScript.reset_cell_field_boot_state()
	var budget_prefix := ""
	if DCFeatureFlags.is_compatibility_renderer():
		budget_prefix = "#define PK_WEB_TEXTURE_BUDGET\n"
		_expect(not _land_variant_prefix(fake_cell_field_on, SHADER_PATH).contains(cell_field_define),
			"Compatibility waits for the startup verdict")
	RendererShaderWaterScript.set_cell_field_boot_verdict(RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	var land_prefix_off := _land_variant_prefix(fake_cell_field_off, SHADER_PATH)
	var land_prefix_on := _land_variant_prefix(fake_cell_field_on, SHADER_PATH)
	var water_prefix_off := RendererShaderWaterScript._water_program_prefix(
		fake_cell_field_off, "split")
	var water_prefix_on := RendererShaderWaterScript._water_program_prefix(
		fake_cell_field_on, "split")
	_expect(land_prefix_off == budget_prefix + "#define PK_LAND_ONLY\n",
		"cell field off keeps the land prefix byte-identical (got %s)"
			% land_prefix_off.replace("\n", "|"))
	_expect(water_prefix_off == budget_prefix + "#define PK_WATER_ONLY\n",
		"cell field off keeps the water prefix byte-identical (got %s)"
			% water_prefix_off.replace("\n", "|"))
	_expect(land_prefix_on == land_prefix_off + cell_field_define,
		"cell field on prepends exactly one define to the land program (got %s)"
			% land_prefix_on.replace("\n", "|"))
	_expect(water_prefix_on == water_prefix_off + cell_field_define,
		"cell field on prepends exactly one define to the water program (got %s)"
			% water_prefix_on.replace("\n", "|"))
	_expect(land_prefix_on.ends_with(cell_field_define)
		and water_prefix_on.ends_with(cell_field_define),
		"land and water both carry the define last, so is_water agrees (no coast holes)")
	_expect(not _land_variant_prefix(fake_cell_field_on,
			"res://shaders/some_other_material.gdshader").contains("PK_CELL_FIELD"),
		"PK_CELL_FIELD never reaches a non-world_map material")
	_expect(not HexRenderer.WORLD_MAP_WEB_PREFIX.contains("PK_CELL_FIELD")
		and not HexRenderer.WORLD_MAP_WEB_PREFIX_MICRO.contains("PK_CELL_FIELD")
		and not HexRenderer.WATER_PASS_PREFIX.contains("PK_CELL_FIELD")
		and not HexRenderer.WORLD_MAP_WEB_HIGH_PREFIX.contains("PK_CELL_FIELD")
		and not HexRenderer.WATER_WEB_HIGH_PREFIX.contains("PK_CELL_FIELD"),
		"the frozen web prefix byte contracts gain no PK_CELL_FIELD bytes")
	# ══ [cell-field-web 2026-11-18 / W6] 预热 = 运行期（逐字节；pass / fail 两态）══════
	# 这条**取代**原来那条 "warmup 里一条 cell-field 变体都不许登记"（W6 前 Web 上确实
	# 没有合法组合）。现在要守的是另一条不变量：预热登记的那段前缀，必须与运行期在同一
	# boot 态下拼出来的**同一个字节串**——两态各验一次，因为「只预热一套」与「预热的是
	# 对的那一套」是两件事，缺一条就会出现"预热编了 OFF，进游戏再真编一次 PK"那种
	# 静默（首编时间翻倍，页面像卡死）。
	#
	# 运行期那一侧不抄任何字面量：
	#   · 水面第二 pass：`_water_program_prefix(host, "web_min")` + WATER_PASS_PREFIX ——
	#     正是 `_create_water_quad` 拼 `variant.code` 的顺序，而且**与平台无关**（web_min
	#     分支只读 `_cell_field_prefix`），所以这条在任何后端上都是严格逐字节等值；
	#   · 陆地 web-min：真拼装 `_apply_shader_variant_prefix` 只在 **web** 上才把这一份拼成
	#     与预热完全相同的字节串（桌面 Compatibility 末尾还会追加 PK_LAND_ONLY、桌面默认
	#     `uses_shader_quality_tier()` 也为假 ⇒ 根本不选 web-min 变体）。所以 web 上做完整
	#     字节等值；其它后端逐段对账：base 用运行期分支读的**同一个**函数
	#     `web_map_web_prefix_active()`，尾段用真拼装函数产出的场函数段。
	var warmup_had_setting := ProjectSettings.has_setting(
		RendererShaderWaterScript.CELL_FIELD_SETTING)
	var warmup_old_setting = ProjectSettings.get_setting(
		RendererShaderWaterScript.CELL_FIELD_SETTING, false)
	# 打开项目设置：这是「开关开」那一态；预热/运行期两侧都读同一个键。
	ProjectSettings.set_setting(RendererShaderWaterScript.CELL_FIELD_SETTING, true)
	var world_map_raw := FileAccess.get_file_as_string(SHADER_PATH)
	var water_web_raw := FileAccess.get_file_as_string(
		"res://shaders/world_water_web.gdshader")
	var fake_web_water := FakeShaderHost.new()
	fake_web_water.terrain_cell_field_enabled = true
	# web-min 变体的准入门之一就是档位宏（`_mobile_quality_tier_define == "MOBILE_QUALITY_LOW"`），
	# 所以 fake host 必须站在 LOW 档上，否则运行期根本不选这个变体。
	fake_web_water._mobile_quality_tier_define = "MOBILE_QUALITY_LOW"
	var warmup_land_bytes := {}
	var warmup_water_bytes := {}
	for boot_state in [RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS,
			RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL]:
		RendererShaderWaterScript.reset_cell_field_boot_state()
		RendererShaderWaterScript.set_cell_field_boot_verdict(boot_state)
		var warm_prefixes: Dictionary = RendererShaderWaterScript.web_warmup_program_prefixes()
		var warm_land := String(warm_prefixes.get("world_map", ""))
		var warm_water := String(warm_prefixes.get("world_water_web", ""))
		warmup_land_bytes[boot_state] = warm_land
		warmup_water_bytes[boot_state] = warm_water
		# ① 水面 pass：与平台无关，严格逐字节（含载荷宏的**位置**）。
		var runtime_water: String = RendererShaderWaterScript._water_program_prefix(
			fake_web_water, "web_min") + HexRenderer.WATER_PASS_PREFIX
		_expect(warm_water == runtime_water,
			("boot=%s: warmup water prefix == runtime web_min prefix + WATER_PASS_PREFIX"
				+ " (got %s / %s)") % [boot_state, warm_water.replace("\n", "|"),
					runtime_water.replace("\n", "|")])
		# ② 陆地 web-min：只有 **web** 上运行期才把这一份拼成与预热完全相同的字节串 ——
		#    桌面 Compatibility 会在 `_apply_shader_variant_prefix` 末尾再追加 PK_LAND_ONLY
		#    （web 用 PK_WEB_LAND_ONLY 代替），而且桌面默认
		#    `uses_shader_quality_tier()` 为假 ⇒ 根本不选 web-min 变体（那里也不存在这一份
		#    program，不是"不一致"）。所以 web 上做逐字节完整等值，其它后端做逐段等值：
		#    base 用运行期分支读的**同一个**函数 `web_map_web_prefix_active()`，尾段用真拼装
		#    函数产出的场函数段 —— 任何一侧单独漂移都会红。
		if OS.has_feature("web"):
			var runtime_land: String = _land_variant_prefix(fake_web_water, SHADER_PATH)
			_expect(warm_land == runtime_land,
				("boot=%s: warmup land prefix == the real assembly of the web-min variant"
					+ " (got %s / %s)") % [boot_state, warm_land.replace("\n", "|"),
						runtime_land.replace("\n", "|")])
		else:
			var expected_land: String = HexRenderer.web_map_web_prefix_active() \
				+ RendererShaderWaterScript._cell_field_prefix(fake_web_water)
			_expect(warm_land == expected_land,
				("boot=%s: warmup land prefix == the active web prefix + the runtime gate"
					+ " (got %s / %s)") % [boot_state, warm_land.replace("\n", "|"),
						expected_land.replace("\n", "|")])
		# ③ 真实清单（`_collect_codes()`）里的两条也逐字节等于「真源 + 源码」：
		#    预热编的就是运行期那份 program，不是"看起来差不多"的另一份。
		var plan_codes := {}
		for plan_entry in WebShaderWarmup._collect_codes():
			plan_codes[String(plan_entry.get("label", ""))] = String(
				plan_entry.get("code", ""))
		_expect(String(plan_codes.get("world_map", "")) == warm_land + world_map_raw,
			"boot=%s: the warmup plan compiles the runtime land program byte for byte"
				% boot_state)
		_expect(String(plan_codes.get("world_water_web", "")) == warm_water + water_web_raw,
			"boot=%s: the warmup plan compiles the runtime water program byte for byte"
				% boot_state)
	RendererShaderWaterScript.reset_cell_field_boot_state()
	# 两态必须**真的不同**：否则"只预热选中那一套"可以退化成"两态编同一份"还全绿。
	_expect(String(warmup_land_bytes[RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS])
			!= String(warmup_land_bytes[RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL])
		and String(warmup_water_bytes[RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS])
			!= String(warmup_water_bytes[RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL]),
		"the pass and fail warmup plans differ (the boot verdict really selects one set)")
	# ── 开关矩阵：四种真实前缀 × {关, 开+pass, 开+fail}（逐字节等值，非"包含"）──────
	# 四种 = 运行期真的会编的四份 program。base 全部取运行期常量/函数；载荷宏按 program
	# 各自的真源（水面第二 pass 是 MATCHES_LAND，其余三份是 CELL_FIELD）。
	# 断言三条：关态 == base（一字节不多）；开+pass == base + 恰好一个载荷宏；开+fail == base。
	var matrix_rows := [
		{"name": "world_map(LOW land)",
			"base": HexRenderer.web_map_web_prefix_active(),
			"assembler": "low_land", "payload_at": "end"},
		{"name": "world_water_web(LOW water)",
			"base": HexRenderer.WATER_PASS_PREFIX,
			"assembler": "low_water", "payload_at": "start"},
		{"name": "world_map_high(HIGH land)",
			"base": HexRenderer.WORLD_MAP_WEB_HIGH_PREFIX,
			"assembler": "high_land", "payload_at": "end"},
		{"name": "world_water_high(HIGH water)",
			"base": HexRenderer.WATER_WEB_HIGH_PREFIX,
			"assembler": "high_water", "payload_at": "end"},
	]
	var matrix_fake_on := FakeShaderHost.new()
	matrix_fake_on.terrain_cell_field_enabled = true
	var matrix_fake_off := FakeShaderHost.new()
	matrix_fake_off.terrain_cell_field_enabled = false
	for matrix_row in matrix_rows:
		var row_name := String(matrix_row["name"])
		var row_base := String(matrix_row["base"])
		var assembler := String(matrix_row["assembler"])
		var payload := RendererShaderWaterScript.WATER_FIELD_MATCHES_LAND_DEFINE \
			if assembler == "low_water" else cell_field_define
		# 载荷宏的位置**不是对称的**，必须按运行期拼装顺序写死：
		#   陆地：base（quality → budget → world_min → [no_micro] → land_only → horizon）
		#         之后**追加**场函数段（_apply_shader_variant_prefix 末尾那一行）；
		#   紧凑水面：`_create_water_quad` 拼的是 `prefix + WATER_PASS_PREFIX + source`，
		#         而场函数宏在 prefix 里 ⇒ 它落在 WATER_PASS_PREFIX **之前**。
		# 写反了就会得到"驱动缓存不命中、菜单期预热白做"的那种逐字节分叉。
		var expected_pass := row_base + payload if String(matrix_row["payload_at"]) == "end" \
			else payload + row_base
		var row_off: String = _matrix_prefix(matrix_fake_off, assembler, row_base)
		# 关态：逐字节等于 base（这就是"关 = 逐字节不变"在四个真实前缀上的体现）。
		_expect(row_off == row_base,
			"matrix %s: toggle off leaves the prefix byte-identical (got %s)"
				% [row_name, row_off.replace("\n", "|")])
		RendererShaderWaterScript.reset_cell_field_boot_state()
		RendererShaderWaterScript.set_cell_field_boot_verdict(
			RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
		var row_pass: String = _matrix_prefix(matrix_fake_on, assembler, row_base)
		_expect(row_pass == expected_pass,
			"matrix %s: toggle on + boot pass adds exactly one payload macro (got %s)"
				% [row_name, row_pass.replace("\n", "|")])
		RendererShaderWaterScript.reset_cell_field_boot_state()
		RendererShaderWaterScript.set_cell_field_boot_verdict(
			RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL)
		var row_fail: String = _matrix_prefix(matrix_fake_on, assembler, row_base)
		_expect(row_fail == row_base,
			"matrix %s: boot fail returns to the byte-identical off form (got %s)"
				% [row_name, row_fail.replace("\n", "|")])
		print("[cell-field-w6] matrix %s: off=%d bytes, pass=%d bytes, fail=%d bytes,"
			% [row_name, row_off.length(), row_pass.length(), row_fail.length()]
			+ " payload=%s" % String(payload).strip_edges())
	RendererShaderWaterScript.reset_cell_field_boot_state()
	# ② [W6] world-min 与场函数**正交**（源级 + 编译级两条）：
	#   源级 —— world_map 在 `#ifdef PK_CELL_FIELD` 下**无条件** include 场函数。断言对象是
	#   **剥注释后**的源码：文件头解释"为什么删掉归一化"的那段话里就写着 include 名，按全文
	#   断言会被注释蒙过去（恒真）。中间插任何 `#ifndef PK_WEB_WORLD_MIN` / 换写法都会断。
	var wm_stripped_source := _strip_shader_comments(source)
	var field_guard := "#ifdef PK_CELL_FIELD\n" \
		+ "#include \"res://shaders/include/hex_cell_field.gdshaderinc\"\n"
	_expect(wm_stripped_source.contains(field_guard),
		"world_map includes the field include directly under #ifdef PK_CELL_FIELD"
			+ " (no world-min / tier guard in between)")
	#   编译级 —— 这份变体真的编得出来（W6 的前提；编不过就是解禁当天炸在 Web LOW 的
	#   第一个像素上，而不是"少一个网格"）。
	var web_min_pk := Shader.new()
	web_min_pk.code = HexRenderer.WORLD_MAP_WEB_PREFIX + cell_field_define + source
	var web_min_pk_uniforms: Array = web_min_pk.get_shader_uniform_list()
	var web_min_pk_names := {}
	for web_min_pk_entry in web_min_pk_uniforms:
		web_min_pk_names[String(web_min_pk_entry.get("name", ""))] = true
	_expect(not web_min_pk_uniforms.is_empty()
		and web_min_pk_names.has("cell_table") and web_min_pk_names.has("terrain_warp_range"),
		"world-min + PK_CELL_FIELD compiles and exposes the field uniforms"
			+ " (field is orthogonal to world-min; %d uniforms)" % web_min_pk_uniforms.size())
	# ③ [W6] 变体真值表：原来的两条排除都已失效 ⇒ budget × world_min 四种组合
	#   **全为 true**，而且拿到的都是同一个非空前缀（不是"恰好 return true"）。
	#   [W6] 单独保留一条：`PK_WEB_WORLD_MIN` 变体仍把水面交给第二 pass。
	RendererShaderWaterScript.reset_cell_field_boot_state()
	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	for budget_variant in [false, true]:
		for world_min_variant in [false, true]:
			_expect(RendererShaderWaterScript.cell_field_variant_allowed(
					budget_variant, world_min_variant)
				and RendererShaderWaterScript.cell_field_prefix_for_variant(
					budget_variant, world_min_variant, true) == cell_field_define,
				("cell-field truth table after W6: budget=%s x world_min=%s is allowed and"
					+ " yields the same non-empty prefix") % [str(budget_variant),
						str(world_min_variant)])
	# 门还得有牙：关掉开关 / boot fail 两种情况下**四组**都必须是空串，否则上面那四条恒真。
	var toggle_off_all_empty := true
	for gate_budget in [false, true]:
		for gate_world_min in [false, true]:
			if RendererShaderWaterScript.cell_field_prefix_for_variant(
					gate_budget, gate_world_min, false) != "":
				toggle_off_all_empty = false
	_expect(toggle_off_all_empty,
		"all four combinations yield the empty string when the toggle is off")
	RendererShaderWaterScript.reset_cell_field_boot_state()
	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL)
	var boot_fail_all_empty := true
	for gate_budget in [false, true]:
		for gate_world_min in [false, true]:
			if RendererShaderWaterScript.cell_field_prefix_for_variant(
					gate_budget, gate_world_min, true) != "":
				boot_fail_all_empty = false
	_expect(boot_fail_all_empty,
		"a failed self-check still vetoes all four combinations (fallback has teeth)")
	# world-min 变体仍把水面交给第二 pass：陆地前缀字节带 world-min，水面 pass 前缀一个都
	# 没有 ⇒ 水面着色源仍在 pass 2（回到 pass 1 就是 FXC 那 20 秒悬崖）。
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX.contains("#define PK_WEB_WORLD_MIN\n")
		and not HexRenderer.WATER_PASS_PREFIX.contains("#define PK_WEB_WORLD_MIN\n")
		and source.count("render_water_pipeline(") == 1,
		"the world-min variant keeps the water source in pass 2 (world-min byte in the"
			+ " land prefix, absent from the water pass prefix)")
	# ④ [W6] 正向断言（**取代**原来那条"两种宏永不同时出现"——不变量已废除）：
	#   真实拼装函数在 budget 变体上**确实**注入了 PK_CELL_FIELD。这里用与平台无关的那条
	#   入口（`_water_program_prefix(host, "high")` = WATER_WEB_HIGH_PREFIX + 场函数段），
	#   任何后端都能跑；陆地变体的预算宏只在 Compatibility 上出现，那一半在 ⑤。
	RendererShaderWaterScript.reset_cell_field_boot_state()
	RendererShaderWaterScript.set_cell_field_boot_verdict(
		RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS)
	var high_water_on: String = RendererShaderWaterScript._water_program_prefix(
		fake_cell_field_on, "high")
	var high_water_off: String = RendererShaderWaterScript._water_program_prefix(
		fake_cell_field_off, "high")
	_expect(high_water_off == HexRenderer.WATER_WEB_HIGH_PREFIX
		and high_water_on == HexRenderer.WATER_WEB_HIGH_PREFIX + cell_field_define
		and high_water_on.contains("#define PK_WEB_TEXTURE_BUDGET\n")
		and high_water_on.contains("#define PK_CELL_FIELD\n"),
		"the real assembly injects PK_CELL_FIELD into the budget (PC-HIGH water) variant"
			+ " (on=%s)" % high_water_on.replace("\n", "|"))
	# ⑤ 同一条语义在 Compatibility 上必须**真的**体现为"两种宏同时出现、槽位仍够"：
	#   测试跑在哪种后端就断言哪种事实，永远有一条会真正执行（不会恒真）。
	if DCFeatureFlags.is_compatibility_renderer():
		var compat_land: String = _land_variant_prefix(fake_cell_field_on, SHADER_PATH)
		var compat_samplers := _count_samplers(compat_land + source)
		_expect(RendererShaderWaterScript._cell_field_active(fake_cell_field_on)
			and compat_land.contains("#define PK_WEB_TEXTURE_BUDGET\n")
			and compat_land.ends_with(cell_field_define)
			and compat_samplers == 6,
			("under a compatibility renderer cell field is admitted and the budget variant"
				+ " still fits (samplers=%d, prefix=%s)") % [compat_samplers,
					compat_land.replace("\n", "|")])
	else:
		_expect(not land_prefix_on.contains("PK_WEB_TEXTURE_BUDGET")
			and land_prefix_on.ends_with(cell_field_define),
			"on the desktop Vulkan path cell field is enabled exactly as specified"
				+ " (the compatibility branch runs in the opengl3 pass)")
	RendererShaderWaterScript.reset_cell_field_boot_state()
	# 还原项目设置（出货默认开；别的断言也依赖这个状态）。
	if warmup_had_setting:
		ProjectSettings.set_setting(
			RendererShaderWaterScript.CELL_FIELD_SETTING, warmup_old_setting)
	else:
		ProjectSettings.set_setting(RendererShaderWaterScript.CELL_FIELD_SETTING, null)
	_expect(HexRenderer.cell_field_setting_enabled(),
		"the project setting is back to the shipped default (enabled) after the matrix")
	# 既有结构不变量（与 W6 无关，保留）：两条 PC-HIGH 分支必须调同一个判定口。
	_expect(renderer_variant_source.contains(
			"+ WORLD_MAP_WEB_HIGH_PREFIX + high_cell_field + shader.code")
		and renderer_variant_source.contains(
			"return prefix + WATER_WEB_HIGH_PREFIX + _cell_field_prefix(host)"),
		"both PC-HIGH branches still consult the same predicate (no half-defined program)")
	# 关 = 空串这条不变量只能有一个实现口：_cell_field_prefix() 的三元式。
	_expect(renderer_variant_source.contains(
			"return CELL_FIELD_DEFINE if _cell_field_active(host) else \"\""),
		"the off path is literally the empty string (no bytes prepended when disabled)")
	# 判定口仍然把「同一个平台谓词」交给变体准入（W6 之后那两个参数被忽略，但调用形状
	# 必须还在：它是"哪套变体允许带宏"的唯一出口，将来再加排除不会分叉）。
	_expect(renderer_variant_source.contains("if DCFeatureFlags.is_compatibility_renderer():")
		and renderer_variant_source.contains(
			"DCFeatureFlags.is_compatibility_renderer(), _world_map_web_min_active(host)"),
		"the gate keeps a single exit that receives the same platform predicates as before")
	# 六个 debug 视图 id 的注册点（方案 §5 P1 的完成判据：4 个对照视图 + 2 个回读视图）。
	_expect(renderer_settings_source.contains("@export_range(0, 23, 1) var terrain_surface_debug_view"),
		"debug-view export range covers the six cell-field views (18..23)")
	_expect(renderer_settings_source.contains("clampi(value, 0, 23)"),
		"debug-view clamp matches the export range (else 22..23 would snap to 17)")
	var gm_capabilities := FileAccess.get_file_as_string(
		"res://scripts/game/world_runtime_gm_adapter_part1.gd").replace("\r\n", "\n")
	var gm_toggles := FileAccess.get_file_as_string(
		"res://scripts/game/world_runtime_gm_toggles.gd").replace("\r\n", "\n")
	for gm_pair in [["dom", 18], ["weights", 19], ["gap", 20], ["warp", 21],
			["dom_encode", 22], ["band", 23]]:
		var gm_toggle := "diagnostics.cell_field_%s_view" % String(gm_pair[0])
		_expect(gm_capabilities.count(gm_toggle) + gm_toggles.count(gm_toggle) >= 3,
			"GM panel registers %s in capabilities + get + set" % gm_toggle)
		_expect(gm_toggles.contains("terrain_surface_debug_view = %d if enabled else 0"
				% int(gm_pair[1])),
			"GM setter maps %s to debug view %d" % [gm_toggle, int(gm_pair[1])])
	# ① 五套前缀下都要编得出来（与临时探针 _tmp_cell_field_parse_probe.gd 同一口径）。
	var cell_field_variants := {
		"desktop": "#define PK_CELL_FIELD\n",
		"mobile_low": "#define PK_CELL_FIELD\n#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
		"tiled": "#define PK_CELL_FIELD\n#define MAP_VISUAL_TILED\n",
		"land_only": "#define PK_CELL_FIELD\n#define PK_LAND_ONLY\n",
		"water_only": "#define PK_CELL_FIELD\n#define PK_WATER_ONLY\n",
	}
	var cell_field_names := {}
	for cf_label in cell_field_variants:
		var cf_shader := Shader.new()
		cf_shader.code = String(cell_field_variants[cf_label]) + source
		var cf_uniforms: Array = cf_shader.get_shader_uniform_list()
		var cf_names := {}
		for cf_entry in cf_uniforms:
			cf_names[String(cf_entry.get("name", ""))] = true
		cell_field_names[cf_label] = cf_names
		_expect(not cf_uniforms.is_empty(),
			"PK_CELL_FIELD %s variant compiles in the shader language" % cf_label)
	# 新 uniform 到位（契约 §4.1）。
	var cell_field_land_names: Dictionary = cell_field_names["land_only"]
	# [cell-field-web 2026-11-18] cell_class_index_bound 是 cell_table layer3
	# （class_by_index）的门：brdf 的 gi_packed_bounce_color 靠它决定"读 layer3 还是返回
	# 无弹射"，漏暴露就是所有弹射色变黑（且没有任何编译错误）。
	for cell_uniform in ["cell_table", "cell_table_size", "cell_table_bound",
			"cell_class_index_bound"]:
		_expect(cell_field_land_names.has(cell_uniform),
			"PK_CELL_FIELD land program exposes %s" % cell_uniform)
	for warp_uniform in ["terrain_warp_range", "terrain_warp_amp", "terrain_warp_layer_bound"]:
		_expect(cell_field_land_names.has(warp_uniform),
			"PK_CELL_FIELD land program exposes %s" % warp_uniform)
	# 关的那一侧必须还在用旧采样器（define 真的在门控，不是"两边都换了"）。
	var cell_field_off_shader := Shader.new()
	cell_field_off_shader.code = "#define PK_LAND_ONLY\n" + source
	var cell_field_off_names := {}
	for cf_off_entry in cell_field_off_shader.get_shader_uniform_list():
		cell_field_off_names[String(cf_off_entry.get("name", ""))] = true
	_expect(cell_field_off_names.has("map_index_atlas")
		and cell_field_off_names.has("enum_lut") and cell_field_off_names.has("dyn_lut"),
		"cell field off keeps the legacy index/LUT samplers (off path untouched)")
	# 源码缺席断言（方案 §4.4 / §6）。断言对象是**测试内极简预处理器展开后**的源码
	# （cf_land_expanded / cf_off_expanded，见 _expand_shader 的注释）：递归替换 #include、
	# 求值 #ifdef/#ifndef/#if defined(...)、剥掉注释。不这么做就只能对文件全文断言，而旧
	# 路径与新路径在同一个文件里由 #ifdef 二选一 —— 全文里两边都在，`not contains` 必然
	# 恒假、`contains` 必然恒真，等于什么都没断言。
	# 分两组，因为两组符号的落地阶段不同：
	#   ① DitherUV 整族（§3.6）+ compute_lake_shore_proxy（§3.7）**今天就应该**已经在
	#      `#ifndef PK_CELL_FIELD` / 陆地 program 之外；
	#   ② 旧采样器的**声明与引用**（map_index_atlas / enum_lut / dyn_lut /
	#      decode_edge_secondary_index）在非预算变体里按设计保留，由四套前缀普查按名守。
	var cell_field_already_retired := [
		"compute_lake_shore_proxy",
		"terrain_mobile_dither_uv_threshold",
		"terrain_hybrid_static_weight",
		"terrain_land_dither_zoom_strength",
		"terrain_dither_subpixel_fade",
	]
	for retired_symbol in cell_field_already_retired:
		_expect(not cf_land_expanded.contains(retired_symbol),
			"PK_CELL_FIELD land program compiles out %s" % retired_symbol)
	# [cell-field-web 2026-11-18 / W6] 这里原来有一条 "P2 pending: the PK land program still
	# carries the legacy sampler declarations" 的**哨兵**，已删除。它永远不会武装：
	#   · 它查的是非预算的 `land_only` 变体，而旧三槽（map_index_atlas / enum_lut / dyn_lut）
	#     在那一档按设计**继续保留**（那里没有 8 槽压力，map_index_atlas 还服务 GI bounce），
	#     所以 `cell_field_land_names.has(...)` 恒为真、断言恒绿；
	#   · 它找的门名 `#ifndef VT_USE_CELL_TABLE` 在 uniforms / visual_tile_sampling 里
	#     **从来不存在**（真实门名是 `VT_USE_CELL_TABLE` 的正向定义 + PK_CELL_FIELD_NO_LEGACY_LUT），
	#     所以那条"退场后自动升级"的分支也永远不会走到。
	# 覆盖没有下降：同一件事现在由**四套 Web/Compat 前缀的 sampler 普查**（上面那组，逐名
	# 等值 + 类型等值 + `retired_uniform` 逐名缺席）与 `cf_budget_pk == 6` 的等值断言守着，
	# 那两条能真的失败（少一张、多一张、名单换一个都红），比这条恒绿的哨兵强。
	for kept_symbol in ["visual_sample_map_index", "enum_lut"]:
		_expect(cf_off_expanded.contains(kept_symbol),
			"cell field off still compiles %s (the define really gates the paths)" % kept_symbol)
	# 反向：新代码必须整段只在开的时候存在（方案 §3.10「关闭时预处理器剔除全部新代码」
	# = 逐像素一致的前提）。这两条同时证明上面的预处理器真的在按 define 求值 ——
	# 一个恒把两支都塞进去的假预处理器会在这里立刻暴露。
	_expect(cf_land_expanded.contains("pk_hex_cell_field_default")
		and not cf_off_expanded.contains("pk_hex_cell_field_default"),
		"the field function exists only in the PK_CELL_FIELD token stream")
	_expect(not cf_off_expanded.contains("cell_table")
		and not cf_off_expanded.contains("terrain_warp_range"),
		"cell field off compiles out every new uniform (no new bytes, no new sampler)")
	# ── 采样器预算（**严格**）：PK_CELL_FIELD 只作用于不带 PK_WEB_TEXTURE_BUDGET 的变体，
	# 所以按"每档实际增量"记账，而不是套 8 槽那条（8 槽只对预算变体成立）。记账规则：
	#   非 tiled：+1 = cell_table（旧的三张声明还在，P6 退役后这一档会变成 −2）；
	#   tiled：  +2 = cell_table + visual_warp_tiles（扭曲场在 tiled 路径要自己的 tile 数组）。
	# 任何"没人算过的第 N 张 sampler"都会打破等式 —— 这就是本轮 9 槽 bug 的同类护栏。
	# 三档之外的组合一律被 _cell_field_active() 排除（见上面 8 槽那组断言）。
	var cell_field_census := {
		"desktop": ["", 1],
		"mobile_low": ["#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n", 1],
		"desktop_tiled": ["#define MAP_VISUAL_TILED\n", 2],
		"mobile_low_tiled": ["#define MAP_VISUAL_TILED\n#define MOBILE_QUALITY_LOW\n"
			+ "#define PK_SHADER_TIER_LOW\n", 2],
		"land_only": ["#define PK_LAND_ONLY\n", 1],
		"water_only": ["#define PK_WATER_ONLY\n", 1],
	}
	for census_label in cell_field_census:
		var census_base := String(cell_field_census[census_label][0])
		var expected_delta := int(cell_field_census[census_label][1])
		var census_off := _count_samplers(census_base + source)
		var census_pk := _count_samplers("#define PK_CELL_FIELD\n" + census_base + source)
		_expect(census_pk == census_off + expected_delta,
			"PK_CELL_FIELD %s keeps the sampler accounting (+%d): off=%d pk=%d"
				% [census_label, expected_delta, census_off, census_pk])
	# [cell-field-web 2026-11-18] 8 槽预算下这个组合的**实测**（"必然溢出所以排除"的语义
	# 已被 W2 推翻）：旧三槽（map_index_atlas / enum_lut / dyn_lut）从**声明**里删掉 = −3，
	# cell_table 补 1 ⇒ OFF 8 / PK 6，还剩 2 槽余量。等值断言而不是阈值：OFF 掉了第 8 张、
	# 或 PK 又长回一张，都说明声明区的宏门被人动了，必须人来看（阈值会把这两种漂移静默吞掉）。
	var cf_budget_off := _count_samplers("#define PK_WEB_TEXTURE_BUDGET\n" + source)
	var cf_budget_pk := _count_samplers(
		"#define PK_CELL_FIELD\n#define PK_WEB_TEXTURE_BUDGET\n" + source)
	_expect(cf_budget_off == 8 and cf_budget_pk == 6,
		"budget variant: OFF stays 8, PK drops to 6 after retiring the legacy samplers"
			+ " (off=%d pk=%d)" % [cf_budget_off, cf_budget_pk])
	# ══ [cell-field-web 2026-11-18] 方案 §3.3：Web/Compatibility 前缀的 sampler 普查 ══
	# 8 槽是 GLES3 / WebGL2 的硬上限：第 9 张起每帧被引擎内建白纹理覆盖，**编译期不报错**，
	# 所以槽位只能在这里按「张数 + 名单」守。四套前缀 × {OFF, PK}，每份做三件事：
	#   ① ≤ 8（超了就把完整清单打出来，现场定位多出来的是谁）；
	#   ② 张数等值（OFF 8 / PK 6），不是阈值；
	#   ③ 名单逐项等值（排序后数组相等）—— 多一个、少一个都要人来确认。
	# 名单与类型都取自引擎的 uniform 反射（TYPE_OBJECT + hint_string），不猜名字后缀：
	# `cell_table` 既没有 `_tex` 后缀也看不出是 array，按后缀筛会直接漏掉它。
	var web_census_prefixes := {
		"WORLD_MAP_WEB_PREFIX": HexRenderer.WORLD_MAP_WEB_PREFIX,
		"WORLD_MAP_WEB_PREFIX_MICRO": HexRenderer.WORLD_MAP_WEB_PREFIX_MICRO,
		"WORLD_MAP_WEB_HIGH_PREFIX": HexRenderer.WORLD_MAP_WEB_HIGH_PREFIX,
		"WATER_WEB_HIGH_PREFIX": HexRenderer.WATER_WEB_HIGH_PREFIX,
	}
	# 陆地三套（LOW / LOW+MICRO / HIGH）共用同一份名单；水面第二 pass 没有材质 array，
	# 换成 water_depth + ocean_current_flow。两份清单的数字与 uniforms.gdshaderinc /
	# world_map.gdshader 里的权威注释同源（那边写明"数字以本测试为准"）。
	var web_land_off_samplers := PackedStringArray([
		"dyn_lut", "enum_lut", "height_tex", "map_index_atlas", "noise_tex",
		"terrain_horizon_tex", "terrain_material_tex", "terrain_surface_tex",
	])
	web_land_off_samplers.sort()
	var web_land_pk_samplers := PackedStringArray([
		"cell_table", "height_tex", "noise_tex", "terrain_horizon_tex",
		"terrain_material_tex", "terrain_surface_tex",
	])
	web_land_pk_samplers.sort()
	var web_water_off_samplers := PackedStringArray([
		"dyn_lut", "enum_lut", "height_tex", "map_index_atlas", "noise_tex",
		"ocean_current_flow_tex", "terrain_surface_tex", "water_depth_tex",
	])
	web_water_off_samplers.sort()
	var web_water_pk_samplers := PackedStringArray([
		"cell_table", "height_tex", "noise_tex", "ocean_current_flow_tex",
		"terrain_surface_tex", "water_depth_tex",
	])
	web_water_pk_samplers.sort()
	for census_prefix_label in web_census_prefixes:
		var census_prefix := String(web_census_prefixes[census_prefix_label])
		var water_pass: bool = String(census_prefix_label) == "WATER_WEB_HIGH_PREFIX"
		var expected_off: PackedStringArray = web_water_off_samplers if water_pass \
			else web_land_off_samplers
		var expected_pk: PackedStringArray = web_water_pk_samplers if water_pass \
			else web_land_pk_samplers
		var census_off := _sampler_census(census_prefix + source)
		var census_pk := _sampler_census(census_prefix + cell_field_define + source)
		var off_names: PackedStringArray = census_off["names"]
		var pk_names: PackedStringArray = census_pk["names"]
		# 编译失败时 get_shader_uniform_list() 返回空表，count 会是 0 —— 单独报一条，
		# 免得下面的等值断言把"编不过"误读成"少了一张 sampler"。
		_expect(not off_names.is_empty() and not pk_names.is_empty(),
			"%s OFF/PK variants both compile in the shader language (samplers=%d/%d)"
				% [census_prefix_label, off_names.size(), pk_names.size()])
		_expect(int(census_off["count"]) <= 8,
			"%s OFF stays inside the 8-slot budget (got %d: %s)"
				% [census_prefix_label, int(census_off["count"]), str(off_names)])
		_expect(int(census_pk["count"]) <= 8,
			"%s PK stays inside the 8-slot budget (got %d: %s)"
				% [census_prefix_label, int(census_pk["count"]), str(pk_names)])
		_expect(int(census_off["count"]) == expected_off.size(),
			"%s OFF keeps exactly %d samplers (got %d)"
				% [census_prefix_label, expected_off.size(), int(census_off["count"])])
		_expect(int(census_pk["count"]) == expected_pk.size(),
			"%s PK drops to %d samplers after the legacy LUT retirement (got %d)"
				% [census_prefix_label, expected_pk.size(), int(census_pk["count"])])
		_expect(off_names == expected_off,
			"%s OFF declares exactly %s (got %s)"
				% [census_prefix_label, str(expected_off), str(off_names)])
		_expect(pk_names == expected_pk,
			"%s PK declares exactly %s (got %s)"
				% [census_prefix_label, str(expected_pk), str(pk_names)])
		# 类型判据也必须真的分得开：array 与 2D 不能混。`cell_table` 必须是
		# sampler2DArray —— layer3 的 texelFetch 与 GLES3 越界层语义都依赖它。
		var pk_kinds: Dictionary = census_pk["kinds"]
		var off_kinds: Dictionary = census_off["kinds"]
		_expect(String(pk_kinds.get("cell_table", "")) == "sampler2DArray"
			and String(pk_kinds.get("terrain_surface_tex", "")) == "sampler2DArray"
			and String(off_kinds.get("height_tex", "")) == "sampler2D"
			and String(off_kinds.get("map_index_atlas", "")) == "sampler2D",
			("%s separates sampler2DArray from sampler2D (cell_table=%s surface=%s"
				+ " height=%s map_index=%s)") % [census_prefix_label,
					String(pk_kinds.get("cell_table", "<missing>")),
					String(pk_kinds.get("terrain_surface_tex", "<missing>")),
					String(off_kinds.get("height_tex", "<missing>")),
					String(off_kinds.get("map_index_atlas", "<missing>"))])
		# 旧三槽在 PK 变体里**连声明都不许剩**（方案 §3.2：留声明不调用，下一个误调就会
		# 落到第 7/8 槽的白纹理上，编译期不报错）。逐名断言；只有失败时才把 200+ 条的完整
		# uniform 清单打进 label（通过时打完整清单只会在 CI 日志里刷屏）。
		var pk_uniform_names: PackedStringArray = census_pk["uniforms"]
		for retired_uniform in ["map_index_atlas", "enum_lut", "dyn_lut"]:
			var has_retired_uniform: bool = pk_uniform_names.has(String(retired_uniform))
			var retired_label := "%s PK has no %s uniform any more" % [
				census_prefix_label, String(retired_uniform)]
			if has_retired_uniform:
				retired_label += " (uniforms=%d: %s)" % [pk_uniform_names.size(),
					str(pk_uniform_names)]
			_expect(not has_retired_uniform, retired_label)
	# ── 结构性不变量（W2 之后必须一直成立，且都能真的失败）────────────────────
	# ① world_map 里不许再有 `#undef PK_CELL_FIELD` 那类归一化：world-min 与场函数正交
	#    之后，谁把归一化加回来，Web LOW 就静默退回 legacy 索引图，而水面第二 pass 仍走场
	#    函数 ⇒ 海岸判定两套来源、错开 1~2 px。断言对象是**剥掉注释后**的源码：文件头解释
	#    "为什么删掉它"那段话里就写着这行字，按全文断言会恒假（等于什么都没断言）。
	var wm_code_only := _collapse_whitespace(_strip_shader_comments(source))
	# 反向自检（否则上面那条可能是"根本没扫到"的恒真）：同一个工具对真代码保留、对注释里
	# 的同名文本丢弃。用合成样本验，不动项目文件；剥注释实现被改坏时这条先红。
	_expect(_collapse_whitespace(_strip_shader_comments("#undef PK_CELL_FIELD\n")).contains(
			"#undef PK_CELL_FIELD")
		and not _collapse_whitespace(_strip_shader_comments(
			"// #undef PK_CELL_FIELD\n")).contains("#undef PK_CELL_FIELD"),
		"the comment stripper keeps a real #undef and ignores one mentioned in a comment")
	_expect(not wm_code_only.contains("#undef PK_CELL_FIELD"),
		"world_map never normalizes PK_CELL_FIELD away (field stays orthogonal to world-min)")
	# ② 水面着色源仍被搬到第二 pass：world-min 宏只对 world_map 的裁剪有意义，但两个 Web
	#    LOW 前缀必须继续带它，否则 water 分支回到 pass 1，FXC 20 秒悬崖跟着回来。
	#    用**字面量**而不是 WORLD_MAP_WEB_MIN_DEFINE：把常量改成空串时后者恒真。
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX.contains("#define PK_WEB_WORLD_MIN\n"),
		"WORLD_MAP_WEB_PREFIX still carries PK_WEB_WORLD_MIN (water stays in pass 2)")
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX_MICRO.contains("#define PK_WEB_WORLD_MIN\n"),
		"WORLD_MAP_WEB_PREFIX_MICRO still carries PK_WEB_WORLD_MIN"
			+ " (the micro toggle cannot move the water pass)")
	# ══ [cell-field 2026-11-18] 世界坐标系推送守卫 ═══════════════════════════════
	# 补的是 review 的第二半：「如果 world_origin、hex_size 这类 uniform 推错了 …
	# 整张地图会整体错位」。GPU↔CPU 的逐像素证据在
	# tests/world/cell_field_gpu_parity_probe.gd（必须带真后端）；这一组是**不需要 GPU**
	# 的那一半：把「世界帧」的唯一来源钉在源码层 —— 每条断言都写出期望表达式，所以
	# 「把 world_origin 换成某个常数」这类改法会直接失败，而不是被弱 grep 放过。
	var publish_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_material_publish.gd").replace("\r\n", "\n")
	var lighting_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_lighting_bindings.gd").replace("\r\n", "\n")
	_expect(publish_source.contains("var bounds = host._world.world_bounds"),
		"the published world frame is anchored to world_bounds, not to a local rect")
	for frame_push in [
			"sm.set_shader_parameter(\"world_origin\", bounds.position)",
			"sm.set_shader_parameter(\"world_size\", bounds.size)",
			"sm.set_shader_parameter(\"hex_size\", host.hex_size)",
			"sm.set_shader_parameter(\"wrap_period_x\", host._wrap_period_x())",
			"sm.set_shader_parameter(\"wrap_origin_x\", 0.0)",
			]:
		_expect(publish_source.contains(String(frame_push)),
			"world frame push reads live data (no literal): %s" % String(frame_push))
	# warp 解码的两个 uniform 必须来自它们各自的权威源，不能在 GDScript 侧写死：
	#   terrain_warp_range ← WorldData.boundary_warp_range（C++ PK_WARP_RANGE 的报告值）
	#   terrain_warp_amp   ← MapBaker.WARP_AMP（烘焙侧同一常量）
	var warp_range_push_main := \
		"set_shader_parameter(\"terrain_warp_range\", host._world.boundary_warp_range)"
	var warp_range_push_bind := \
		"set_shader_parameter(\"terrain_warp_range\", _world.boundary_warp_range)"
	var warp_amp_push := "set_shader_parameter(\"terrain_warp_amp\", MapBaker.WARP_AMP)"
	_expect(publish_source.contains("sm." + warp_range_push_main)
		and publish_source.contains("sm." + warp_amp_push),
		"world_map warp decode uniforms come from WorldData.boundary_warp_range"
			+ " + MapBaker.WARP_AMP (never a literal)")
	_expect(lighting_source.contains("sm." + warp_range_push_bind)
		and lighting_source.contains("sm." + warp_amp_push),
		"the water/horizon binding path pushes the same two warp uniforms from the same"
			+ " sources (land and water cannot disagree)")
	# 场函数侧的解码式必须乘这两个 uniform —— 写成 `* 1.6 * 0.4` 会让「改 C++ 不改
	# shader」这类漂移永远看不见。
	var field_include_source := FileAccess.get_file_as_string(
		"res://shaders/include/hex_cell_field.gdshaderinc").replace("\r\n", "\n")
	_expect(field_include_source.contains(
			"return (rg * 2.0 - 1.0) * (terrain_warp_range * hex_size * terrain_warp_amp);"),
		"warp decode multiplies terrain_warp_range * hex_size * terrain_warp_amp")
	# ══ [cell-field-overlays 2026-11-18 / O0] 核心拆分（`hex_cell_core.gdshaderinc`）════
	# 拆分的意义全在「共享」两个字上：包装层必须**真的** include 核心，而核心必须
	# **零 uniform**（天气 overlay 与战争迷雾都不 include `uniforms.gdshaderinc`，核心
	# 一旦声明 uniform，那两个 program 立刻重复声明 / 编不过 —— 这正是 O0 的存在理由）。
	# 断言对象是**剥注释后**的源码：两个文件的文件头都在解释拆分理由、会提到 include 名
	# 与"零 uniform"字样，按全文断言会被注释蒙过去（本文件已有同类先例）。
	# 两条都必须能真的失败：删掉那行 include、或往核心里加一个 uniform，立即变红。
	var field_code_only := _strip_shader_comments(field_include_source)
	var core_include_line := \
		"#include \"res://shaders/include/hex_cell_core.gdshaderinc\""
	var core_source := FileAccess.get_file_as_string(
		"res://shaders/include/hex_cell_core.gdshaderinc").replace("\r\n", "\n")
	var core_uniform_hits := 0
	for core_line in _strip_shader_comments(core_source).split("\n"):
		if String(core_line).strip_edges().begins_with("uniform"):
			core_uniform_hits += 1
	_expect(field_code_only.contains(core_include_line)
		and not core_source.is_empty() and core_uniform_hits == 0,
		"hex_cell_field is a pure wrapper over hex_cell_core: it includes the core and"
			+ " the core declares zero uniform (include=%s core_uniform=%d)"
				% [str(field_code_only.contains(core_include_line)), core_uniform_hits])
	# 最后一个不需要 GPU 的帧不变量：**像素中心的 +0.5 约定**必须三处一致 ——
	#   C++ 烘焙 world_ext_bake_section_terrain_index.inc
	#   `origin_x + (double(x) + 0.5) * step_x`；
	#   GPU 探针 `origin + (pixel + 0.5) * WORLD_PER_PIXEL`（Camera2D 对中 ⇒ 像素中心）。
	# 这条比"grep 一个 +0.5"严格：两侧都是完整表达式，任一侧改成 (pixel) 或
	# (pixel + 1) 都会失败。
	var cpp_bake_source := FileAccess.get_file_as_string(
		"../../gdext/src/world_ext_bake_section_terrain_index.inc").replace("\r\n", "\n")
	_expect(cpp_bake_source.contains(
			"const double wy_base = origin_y + (double(y) + 0.5) * step_y;")
		and cpp_bake_source.contains(
			"const double wx_base = origin_x + (double(x) + 0.5) * step_x;"),
		"the C++ bake samples at pixel centres: origin + (pixel + 0.5) * step")
	var gpu_probe_source := FileAccess.get_file_as_string(
		"res://tests/world/cell_field_gpu_parity_probe.gd").replace("\r\n", "\n")
	_expect(gpu_probe_source.contains(
			"Vector2(float(i) + 0.5, float(j) + 0.5) * WORLD_PER_PIXEL")
		and gpu_probe_source.contains("_camera.position = origin + size * 0.5"),
		"the GPU parity probe maps pixel centres with the same +0.5 convention")
	print("=== terrain shader variants: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## [cell-field-web 2026-11-18 / W6] 取 WebShaderWarmup.SHADERS 里某条 path 的条目。
## 找不到时返回空字典（调用方用 .has("prefix") 之类的断言就会失败，不会静默变绿）。
func _shaders_entry_for(path: String) -> Dictionary:
	for entry in WebShaderWarmup.SHADERS:
		if String(entry.get("path", "")) == path:
			return entry
	return {}


## [cell-field-web 2026-11-18 / W6] 开关矩阵的一行 = 某份 program 的**运行期拼装**。
## 四个 assembler 都走真实入口，不抄字面量：
##   low_land   —— 陆地 web-min 变体：`web_map_web_prefix_active()`（运行期分支读的同一个
##                 函数，含 micro 开关）+ 场函数段；
##   low_water  —— 紧凑水面 pass：`_water_program_prefix(host, "web_min")` + WATER_PASS_PREFIX
##                 （与 `_create_water_quad` 的 `variant.code = prefix + WATER_PASS_PREFIX`
##                 顺序一致）；
##   high_land  —— `_apply_shader_variant_prefix` 的 pc_high 分支的非 tiled 形态：
##                 WORLD_MAP_WEB_HIGH_PREFIX + 场函数段；
##   high_water —— `_water_program_prefix(host, "high")`（自带 WATER_WEB_HIGH_PREFIX）。
## base 参数只用于两个 land 行（它们的 base 由平台/档位选择，不由拼装函数返回）。
func _matrix_prefix(host, assembler: String, base: String) -> String:
	match assembler:
		"low_land", "high_land":
			return base + RendererShaderWaterScript._cell_field_prefix(host)
		"low_water":
			return RendererShaderWaterScript._water_program_prefix(host, "web_min") \
				+ HexRenderer.WATER_PASS_PREFIX
		"high_water":
			return RendererShaderWaterScript._water_program_prefix(host, "high")
	return "<unknown assembler: %s>" % assembler


## 取某个函数定义（从签名行到独立成行的 `}`）的完整文本，用于"逐字同源"断言。
func _function_block(text: String, signature_prefix: String) -> String:
	var lines := text.split("\n")
	var start := -1
	for i in range(lines.size()):
		if lines[i].begins_with(signature_prefix):
			start = i
			break
	if start < 0:
		return ""
	var end := -1
	for j in range(start, lines.size()):
		if lines[j] == "}":
			end = j
			break
	if end < 0:
		return ""
	var block := PackedStringArray()
	for k in range(start, end + 1):
		block.append(lines[k])
	return "\n".join(block)


## 把 tab 与连续空格压成单空格，用于忽略对齐空格的常量逐值比对。
func _collapse_whitespace(text: String) -> String:
	var out := text.replace("\t", " ")
	while out.contains("  "):
		out = out.replace("  ", " ")
	return out


## [cell-field-web 2026-11-18] 一次 program 的 sampler 普查（方案 §3.3 的唯一口径）。
## 返回 {"count": 张数, "names": 排序后的 sampler 名, "kinds": {名: sampler2D /
## sampler2DArray}, "uniforms": 排序后的**全部** uniform 名}。
## 判据是引擎的 uniform 反射：Godot 把每个 sampler uniform 报成 TYPE_OBJECT（这一组就是
## 运行期真正占纹理单元的那组，第 N 张 = 第 N 个单元），2D 与 array 的区别在 hint_string
## （Texture2D / TextureLayered）—— **不看名字后缀**：`cell_table` 没有 `_tex` 后缀，
## `map_index_atlas` 也没有，按后缀筛会漏，按"声明里出现过"数又会把整段被 #ifdef 剔除的
## 变体算进去。
func _sampler_census(code: String) -> Dictionary:
	var shader := Shader.new()
	shader.code = code
	var sampler_names := PackedStringArray()
	var uniform_names := PackedStringArray()
	var kinds := {}
	for entry in shader.get_shader_uniform_list():
		var entry_name := String(entry.get("name", ""))
		uniform_names.append(entry_name)
		if int(entry.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		sampler_names.append(entry_name)
		kinds[entry_name] = _sampler_kind(entry)
	sampler_names.sort()
	uniform_names.sort()
	return {
		"count": sampler_names.size(),
		"names": sampler_names,
		"kinds": kinds,
		"uniforms": uniform_names,
	}


## [cell-field-web 2026-11-18] sampler 的纹理形态。hint_string 是引擎按 uniform 的资源
## 类型给的类名：sampler2D → "Texture2D"；sampler2DArray / sampler3D 等分层纹理 →
## "TextureLayered"。本项目的 program 只声明过这两种形态；认不出的返回
## "unknown(<hint>)" 而不是猜一个 —— 用例会带着它失败，不会静默归类。
func _sampler_kind(entry: Dictionary) -> String:
	var hint_text := String(entry.get("hint_string", ""))
	if hint_text == "Texture2D":
		return "sampler2D"
	if hint_text == "TextureLayered":
		return "sampler2DArray"
	return "unknown(%s)" % hint_text


## 统计一个 program 的 sampler 数量：8 槽设备预算的 bug 只有在"数出来的张数"这一层才看得
## 见 —— 编译不会报错。实现统一走 _sampler_census()，避免出现第二套口径。
func _count_samplers(code: String) -> int:
	return int(_sampler_census(code)["count"])


## [cell-field 2026-11-18] 前缀拼装用的假 host：只提供
## RendererShaderWater._apply_shader_variant_prefix / _water_program_prefix 真正读到的
## 字段（字段名必须与 HexRenderer 一致，否则被测代码会在 null 上炸）。真 renderer 要拉
## 整棵场景树，这里只需要「桌面 / 非 tiled / 拆分开 / quality 0（云影走 composite）」
## 这一种可复现配置 —— 断言的是「关的时候字节不变」，不是"重现所有配置"。
class FakeShaderHost extends RefCounted:
	var _world = null
	var visual_quality: int = 0
	var _mobile_quality_tier_define: String = ""
	var split_land_water_passes: bool = true
	var _split_program_failed: bool = false
	var terrain_surface_debug_view: int = 0
	var terrain_cell_field_enabled: bool = false
	var shader_path: String = "res://shaders/world_map.gdshader"
	var WORLD_MAP_SHADER_PATH: String = "res://shaders/world_map.gdshader"
	var SPLIT_LAND_ONLY_DEFINE: String = ""
	var SPLIT_WATER_ONLY_DEFINE: String = ""
	var CloudShadowFieldScript = null

	func _init() -> void:
		var water_impl = preload("res://scripts/rendering/renderer_shader_water.gd")
		SPLIT_LAND_ONLY_DEFINE = water_impl.SPLIT_LAND_ONLY_DEFINE
		SPLIT_WATER_ONLY_DEFINE = water_impl.SPLIT_WATER_ONLY_DEFINE
		CloudShadowFieldScript = preload("res://scripts/rendering/cloud_shadow_field.gd")


## 跑一遍陆地变体前缀拼装并返回**前缀部分**（把探针源码切掉）。
## 直接调 RendererShaderWater 的静态实现而不是抄一份拼装逻辑：这条断言的全部意义就是
## 「被测代码在开关关着时不加任何字节」。
func _land_variant_prefix(host, path: String) -> String:
	var probe := Shader.new()
	probe.code = "PROBE_SOURCE"
	var variant: Shader = RendererShaderWaterScript._apply_shader_variant_prefix(host, probe, path)
	if variant == null:
		return "<null>"
	var code := String(variant.code)
	return code.substr(0, code.length() - "PROBE_SOURCE".length())


## [cell-field 2026-11-18] 极简 shader 预处理器，只服务于本文件的「源码缺席」断言。
## 为什么不能直接 grep 文件全文：旧采样路径与新场函数在**同一个文件里**由
## `#ifdef/#ifndef` 二选一，全文里两边都在 —— 按全文断言 `not contains "enum_lut"`
## 永远失败、按全文断言 `contains` 又永远成立（恒真），两者都没有守到任何东西。
## 能力边界（够用即可）：递归展开 `#include "res://..."`；求值
## `#ifdef / #ifndef / #if defined(X) && !defined(Y)`；剥掉 /* */ 与 // 注释；
## 记 `#define X`（值不展开 —— 断言对象是这些符号是否还被**引用**，不是宏别名）。
## 认不出的条件表达式（例如 `#if CURRENT_RENDERER != RENDERER_COMPATIBILITY`）按
## **两支都算**的保守并集处理：并集只会让文本更长，所以缺席断言不会被它蒙成恒真
## （最坏情况是偏严而失败，不会假绿）。
func _expand_shader(path: String, defines: Dictionary, follow_includes: bool = true) -> String:
	var out: Array = []
	_expand_into(path, defines.duplicate(), out, 0, follow_includes)
	return "\n".join(out)


func _expand_into(path: String, defines: Dictionary, out: Array, depth: int,
		follow_includes: bool) -> void:
	if depth > 16:
		return
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return
	var text := _strip_shader_comments(raw.replace("\r\n", "\n").replace("\r", "\n"))
	# 条件栈：parent = 父级是否可见；taken = 本链是否已命中；union = 表达式认不出（两支都算）。
	var stack: Array = []
	for line in text.split("\n"):
		var trimmed := String(line).strip_edges()
		var active := true
		if not stack.is_empty():
			active = bool(stack[stack.size() - 1]["active"])
		if not trimmed.begins_with("#"):
			if active:
				out.append(line)
			continue
		var body := trimmed.substr(1).strip_edges()
		var head := body
		var rest := ""
		var sep := body.find(" ")
		if sep >= 0:
			head = body.substr(0, sep)
			rest = body.substr(sep + 1).strip_edges()
		match head:
			"ifdef":
				_push_shader_cond(stack, active, defines.has(rest), false)
			"ifndef":
				_push_shader_cond(stack, active, not defines.has(rest), false)
			"if":
				var cond_value := _eval_shader_cond(rest, defines)
				_push_shader_cond(stack, active, cond_value != 0, cond_value < 0)
			"elif":
				if stack.is_empty():
					continue
				var elif_frame: Dictionary = stack[stack.size() - 1]
				if bool(elif_frame["union"]) or not bool(elif_frame["parent"]):
					continue
				if bool(elif_frame["taken"]):
					elif_frame["active"] = false
				var elif_value := _eval_shader_cond(rest, defines)
				if elif_value < 0:
					elif_frame["union"] = true
					elif_frame["active"] = true
				else:
					elif_frame["active"] = elif_value != 0
					elif_frame["taken"] = elif_value != 0
			"else":
				if stack.is_empty():
					continue
				var else_frame: Dictionary = stack[stack.size() - 1]
				if bool(else_frame["union"]):
					else_frame["active"] = bool(else_frame["parent"])
				elif bool(else_frame["taken"]):
					else_frame["active"] = false
				else:
					else_frame["active"] = bool(else_frame["parent"])
					else_frame["taken"] = true
			"endif":
				if not stack.is_empty():
					stack.pop_back()
			"include":
				if active and follow_includes:
					var inc := rest.trim_prefix("\"").trim_suffix("\"")
					if inc.begins_with("res://"):
						_expand_into(inc, defines, out, depth + 1, follow_includes)
			"define":
				if active and not rest.is_empty():
					defines[rest.split(" ")[0]] = true
			"undef":
				if active:
					defines.erase(rest)
			_:
				pass      # #error / #pragma / #version 等：不参与文本断言


func _push_shader_cond(stack: Array, parent_active: bool, taken: bool, unknown: bool) -> void:
	stack.append({
		"parent": parent_active,
		"taken": false if unknown else taken,
		"union": unknown,
		"active": parent_active if unknown else (parent_active and taken),
	})


## include 路径里的 `res://` 本身含 `//`，先挡掉，否则 `//` 注释规则会把
## `#include "res://shaders/..."` 的后半行吃掉（include 就永远展开不了）。
func _strip_shader_comments(text: String) -> String:
	var guarded := text.replace("res://", "res:\u0001~~")
	var block := RegEx.new()
	block.compile("(?s)/\\*.*?\\*/")
	var without_block: String = block.sub(guarded, "", true)
	var line_comment := RegEx.new()
	line_comment.compile("//[^\n]*")
	var stripped: String = line_comment.sub(without_block, "", true)
	return stripped.replace("res:\u0001~~", "res://")


## 求值 `#if` 表达式，返回 1 / 0 / -1（-1 = 认不出，调用方按「两支都算」处理）。
## 只认 defined(X) / ! / && / || / 括号 / 0 / 1 / 裸标识符（未定义按 C 语义 = 0）。
var _cond_text := ""
var _cond_pos := 0


func _eval_shader_cond(expr: String, defines: Dictionary) -> int:
	_cond_text = expr.replace(" ", "")
	_cond_pos = 0
	var value := _cond_or(defines)
	if value >= 0 and _cond_pos < _cond_text.length():
		return -1
	return value


func _cond_or(defines: Dictionary) -> int:
	var value := _cond_and(defines)
	while _cond_accept("||"):
		var right := _cond_and(defines)
		if value == 1 or right == 1:
			value = 1
		elif value < 0 or right < 0:
			value = -1
		else:
			value = 0
	return value


func _cond_and(defines: Dictionary) -> int:
	var value := _cond_unary(defines)
	while _cond_accept("&&"):
		var right := _cond_unary(defines)
		if value == 0 or right == 0:
			value = 0
		elif value < 0 or right < 0:
			value = -1
		else:
			value = 1
	return value


func _cond_unary(defines: Dictionary) -> int:
	if _cond_accept("!"):
		var inner := _cond_unary(defines)
		return -1 if inner < 0 else 1 - inner
	if _cond_accept("("):
		var grouped := _cond_or(defines)
		_cond_accept(")")
		return grouped
	if _cond_text.substr(_cond_pos).begins_with("defined"):
		_cond_pos += "defined".length()
		_cond_accept("(")
		var defined_name := _cond_ident()
		_cond_accept(")")
		return 1 if defines.has(defined_name) else 0
	var identifier := _cond_ident()
	if identifier.is_empty():
		return -1
	if identifier == "0":
		return 0
	if identifier == "1":
		return 1
	if defines.has(identifier):
		var known: Variant = defines[identifier]
		if known is bool:
			return 1
		var known_text := String(known)
		if known_text == "0":
			return 0
		if known_text == "1":
			return 1
		return -1
	return 0


func _cond_accept(token: String) -> bool:
	if _cond_text.substr(_cond_pos, token.length()) == token:
		_cond_pos += token.length()
		return true
	return false


func _cond_ident() -> String:
	var start := _cond_pos
	while _cond_pos < _cond_text.length():
		var ch := _cond_text[_cond_pos]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
				or (ch >= "0" and ch <= "9") or ch == "_":
			_cond_pos += 1
		else:
			break
	return _cond_text.substr(start, _cond_pos - start)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
