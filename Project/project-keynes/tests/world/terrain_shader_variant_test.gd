extends SceneTree

const SHADER_PATH := "res://shaders/world_map.gdshader"
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
	_expect(source.contains("water_static_edge_mix = water_edge_w"),
		"MID/HIGH ocean forwards a continuous distance-field weight")
	_expect(source.contains("#if !defined(PK_QUALITY_LOW)"),
		"LOW compiles out secondary water-cell lookup")
	_expect(source.contains("terrain_static_biome_is_water(candidate_biome)"),
		"continuous ocean blending cannot cross the land/water domain")
	_expect(not source.contains(
		"terrain_mobile_dither_uv_threshold(uv, wp) < water_edge_w"),
		"ocean no longer converts its distance field to binary DitherUV")
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
	_expect(land_source.contains("terrain_apply_landform_detail(")
		and hillshade_source.contains("vec4 terrain_apply_landform_detail(")
		and hillshade_source.contains("TerrainDetailProfile terrain_detail_profile(int biome)")
		and hillshade_source.contains("terrain_detail_landform_boost("),
		"macro normal carries per-terrain landform detail")
	_expect(hillshade_source.contains("terrain_erosion_cell_coord")
		and hillshade_source.contains("wrap_period_x"),
		"erosion noise stays periodic across the world X wrap")
	_expect(material_constants_source.contains("RIVER_NORMAL_WAVE_WEIGHT")
		and material_constants_source.contains("RIVER_NORMAL_BLEND_END"),
		"river normal separation uses centralized material constants")
	_expect(source.contains("visual_land_biome"),
		"full land material pipeline consumes a DitherUV-selected visual biome")
	_expect(source.contains("visual_land_veg") and source.contains("visual_land_cover"),
		"land DitherUV selects static biome/vegetation/cover axes together")
	_expect(source.contains("!terrain_static_biome_is_water(land_secondary_biome)"),
		"land DitherUV cannot cross the land/water domain")
	_expect(surface_source.contains("terrain_land_dither_zoom_strength"),
		"land DitherUV has an explicit close-view zoom fade")
	_expect(not surface_source.contains("near_floor"),
		"close land view has no non-zero DitherUV floor")
	_expect(surface_source.contains("TERRAIN_DITHER_THRESHOLD_MARGIN"),
		"terrain Bayer rank tails are compressed to prevent elongated teeth")
	_expect(source.contains("land_dither_probability"),
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
	var renderer_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/hex_renderer.gd")
	# 注意：hex_renderer.gd 是 CRLF，而 FileAccess.get_file_as_string() 保留 \r，
	# 所以跨行 needle 在 LF 写法下永远不匹配（本断言曾因此长期 FAIL）。只匹配单行。
	_expect(renderer_source.contains(
		"sm.set_shader_parameter(\"visual_reference_resolution\","),
		"tiled DitherUV follows the active visual resolution")
	var variants := {
		"desktop": "",
		"mobile_low": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
		"mobile_mid": "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
		"mobile_high": "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
	}
	for label in variants:
		var shader := Shader.new()
		shader.code = String(variants[label]) + source
		var uniforms: Array = shader.get_shader_uniform_list()
		var names := {}
		for entry in uniforms:
			names[String(entry.get("name", ""))] = true
		_expect(names.has("terrain_edge_neighbor_tex"), "%s exposes terrain edge neighbor" % label)
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
	_expect(source.count("visual_sample_edge_distance(") == 1
		and not land_source.contains("visual_sample_edge_distance(")
		and land_source.contains("terrain_baked_normal(uv, visual_quality, scals.a)"),
		"edge_distance fetched once in setup and reused via scals.r/.a")
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
	_expect(web_sampler_count <= 8,
		"web budget keeps material samplers within 8 units (got %d)" % web_sampler_count)
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
		_expect(not names.has("terrain_static_baked"),
			"%s legacy keeps the runtime fallback (no static-bake gate)" % label)
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
		+ HexRenderer.WORLD_MAP_WEB_NO_MICRO_DEFINE
	_expect(runtime_prefix == HexRenderer.WORLD_MAP_WEB_PREFIX,
		"runtime web-LOW prefix is byte-identical to WORLD_MAP_WEB_PREFIX")
	_expect(HexRenderer.WORLD_MAP_WEB_PREFIX
		== "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
			+ "#define PK_WEB_TEXTURE_BUDGET\n#define PK_WEB_WORLD_MIN\n"
			+ "#define PK_PROBE_NO_MICRO\n",
		"web-LOW prefix keeps quality -> texture-budget -> world-min -> no-micro order")
	_expect(WebShaderWarmup.WORLD_MAP_PREFIX == HexRenderer.WORLD_MAP_WEB_PREFIX,
		"warmup world_map prefix is the renderer constant (single source of truth)")
	var warm_map_prefix := ""
	for warm_entry in WebShaderWarmup.SHADERS:
		if String(warm_entry.get("path", "")) == SHADER_PATH:
			warm_map_prefix = String(warm_entry.get("prefix", ""))
	_expect(warm_map_prefix == HexRenderer.WORLD_MAP_WEB_PREFIX,
		"warmup list compiles the exact same world_map variant as runtime")
	_expect(not WebShaderWarmup.TIER_PREFIX.contains("PK_WEB_WORLD_MIN"),
		"TIER_PREFIX stays world-min free (weather_overlay shares it)")
	_expect(renderer_source.contains("return QUALITY_PREFIX_LOW"),
		"LOW tier prefix is the shared QUALITY_PREFIX_LOW constant")
	for include_name in ["common_noise", "weather_front", "water", "tonemap",
			"shore_common", "terrain_horizon"]:
		_expect(source.contains("#ifndef PK_WEB_WORLD_MIN\n"
			+ "#include \"res://shaders/include/%s.gdshaderinc\"\n#endif" % include_name),
			"world_map guards the %s include behind PK_WEB_WORLD_MIN" % include_name)
	_expect(source.contains("#ifdef PK_WEB_WORLD_MIN\n"
		+ "#include \"res://shaders/include/world_map_web_min.gdshaderinc\"\n#else\n"
		+ "#include \"res://shaders/include/cell_indirect.gdshaderinc\"\n#endif"),
		"cell_indirect is replaced by the web-min leaf set before its first user")
	_expect(web_min_source.contains("#ifndef PK_QUALITY_LOW")
		and web_min_source.contains("#error"),
		"web-min include fails loudly when the tier macro is missing")
	_expect(web_min_source.contains("float terrain_horizon_apply_normal(")
		and web_min_source.contains("mix(gi_normal_floor, 1.0, align)"),
		"web-min keeps the verbatim horizon normal formula (not a 1.0 shortcut)")
	_expect(web_min_source.contains("float water_periodic_wave_phase(")
		and web_min_source.contains("vec3 tonemap_reinhard_legacy(")
		and web_min_source.contains("vec2 cell_lut_uv("),
		"web-min supplies the three leaf helpers the surviving includes still call")
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
	_expect(wm_samplers <= 8,
		"web-world-min keeps material samplers within 8 units (got %d)" % wm_samplers)
	_expect(wm_names.has("has_flow_tex") and wm_names.has("height_tex"),
		"web-world-min keeps the flow diagnostics keys")
	_expect(wm_names.has("weather_front_count") and wm_names.has("gi_normal_floor")
		and wm_names.has("terrain_horizon_tex") and wm_names.has("noise_tex"),
		"web-world-min keeps ABI parity for pushed-but-unused uniforms")
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
	_expect(water_samplers == 4,
		"water pass declares exactly 4 samplers (got %d)" % water_samplers)
	_expect(water_uniform_list.size() == 16,
		"water pass declares exactly 16 uniforms, not world_map's 186 (got %d)"
			% water_uniform_list.size())
	_expect(not water_names.has("noise_tex") and not water_names.has("season_phase")
		and not water_names.has("terrain_material_tex")
		and not water_names.has("fog_unexplored_color"),
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
			+ HexRenderer.WORLD_MAP_WEB_NO_MICRO_DEFINE,
		"the two web-LOW prefixes differ only by the world-min + no-micro defines")
	var warm_water_prefix := ""
	for warm_entry in WebShaderWarmup.SHADERS:
		if String(warm_entry.get("path", "")) == "res://shaders/world_water_web.gdshader":
			warm_water_prefix = String(warm_entry.get("prefix", ""))
	_expect(warm_water_prefix == HexRenderer.WATER_PASS_PREFIX,
		"warmup compiles the exact same water variant as runtime")
	_expect(renderer_source.contains("return OS.has_feature(\"web\") \\")
		and renderer_source.contains("_water_pass_active()"),
		"water pass creation is gated on the web platform")
	_expect(not renderer_source.contains(
		"preload(\"res://shaders/world_water_web.gdshader\")"),
		"water shader is loaded lazily, never preloaded on desktop")
	_expect(renderer_source.contains("_water_quad.z_index = 0")
		and renderer_source.contains("move_child(_water_quad"),
		"water quad sits right after the world quad (above land, below detail)")
	_expect(renderer_source.contains("_sync_water_quad()")
		and renderer_source.contains("WebTelemetry.note_variant(\"world_water_web\""),
		"water pass is created by _apply_uniforms and reported to warmup reconciliation")
	print("=== terrain shader variants: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


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


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
