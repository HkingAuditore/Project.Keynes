extends SceneTree

## web 水面第二 pass 的**节点级**冒烟测试（桌面 headless 可跑）。
##
## 为什么需要单独一份：`shaders/world_water_web.gdshader` + `_create_water_quad()` /
## `_apply_water_uniforms()` 这条路径只在「web + Compatibility + LOW 档」下才会被
## 执行，桌面 `--quit-after` 与 terrain_shader_variant_test（纯源码断言）都碰不到它。
## 那种"只在目标平台上才会炸"的 GDScript 错误（拼错方法名 / 属性为 null / 树序错）
## 只有把这条路径真的驱动一次才能暴露。
##
## 做法：`_water_pass_active()` 的平台判定是 `OS.has_feature("web")`（桌面恒 false），
## 所以这里绕开它，直接调与平台判定分离的 `_ensure_water_quad()`——同一个函数，
## 只是少一层守卫。用例覆盖 legacy（sampler2D）/ tiled（sampler2DArray）两种变体、
## 变体切换后的重编、以及拆节点。
##
## ── [cell-field-web 2026-11-18 / W3] 本轮的扩展 ─────────────────────────---
## 水面第二 pass 迁移到 `hex_cell_field.gdshaderinc` 的解析场。**开关是
## `PK_WATER_FIELD_MATCHES_LAND`**（= 本 pass 的水陆判据与陆地 program 同源），
## 两条路各有一组断言：
##   宏关 —— 与 W3 之前逐字节一致（今天的 Web LOW 就是这一档）；
##   宏开 —— 场函数路径：编译、采样槽普查、源码缺席、判别同源、ε 侧。
## 真后端断言（海岸两侧都 discard 的像素数 = 0）需要 `--rendering-driver`；
## headless 下打印 SKIPPED 并 exit 0（dummy 渲染器读不回像素，见契约 §6 的 headless 陷阱）。
##
## 跑法：
##   Godot --headless --path Project\project-keynes \
##       --script res://tests/world/web_water_pass_node_test.gd
##   Godot --path Project\project-keynes --rendering-driver opengl3 \
##       --script res://tests/world/web_water_pass_node_test.gd    # 含真后端 check

const SHADER_PATH := "res://shaders/world_water_web.gdshader"
const WORLD_MAP_PATH := "res://shaders/world_map.gdshader"
const RENDERER_SHADER_WATER_PATH := "res://scripts/rendering/renderer_shader_water.gd"
const RENDERER_GRAPHICS_SETTINGS_PATH := "res://scripts/rendering/renderer_graphics_settings.gd"
const RENDERER_SCENE_SERVICES_PATH := "res://scripts/rendering/renderer_scene_services.gd"

## [cell-field-web 2026-11-18 / W3] 水面 pass 的「判据与陆地同源」宏。
## 唯一真源是 `RendererShaderWater.WATER_FIELD_MATCHES_LAND_DEFINE`（由陆地那条
## `_cell_field_prefix()` 判定口驱动）；这里在常量落地前用同一个字面量，并在
## `_check_injection_point()` 里断言"两者一旦都存在就必须逐字节相同"。
const WATER_FIELD_MATCHES_LAND_DEFINE := "#define PK_WATER_FIELD_MATCHES_LAND\n"

var _checks := 0
var _failures := 0
## [2026-11-18] ②–④ 组要在「开关关掉」的状态下验 legacy 形态，故临时改项目设置；
## 这两个变量用于 `_finish()` 还原。
var _cell_field_had_setting := false
var _cell_field_old_setting = null


class FakeLayout:
	var mode := "tiled"
	var visual_domain := Rect2(0.0, 0.0, 100.0, 80.0)
	var grid_size := Vector2i(1, 1)
	var interior_size := Vector2i(100, 80)
	var layer_size := Vector2i(104, 84)
	var logical_size := Vector2i(100, 80)
	var gutter_px := 2


class FakeTiles:
	var ready := true
	var layout := FakeLayout.new()
	var height: Texture2D
	var map_index: Texture2D


func _init() -> void:
	# 延迟一帧：`root` 与节点 `_ready()` 都要等主循环起来才可靠。
	call_deferred("_run")


func _run() -> void:
	# [2026-11-18] 出货默认**开**（`project.godot` 的 terrain_cell_field_enabled=true）。
	# ②–④ 组验的是「**开关关掉时**水面 pass 的 legacy 形态必须逐字节不变」，所以先把
	# **项目设置**临时置 false 再建 renderer（`HexRenderer._init()` 读设置作初值）。
	# 走设置而不是走 export setter：setter 会立刻触发一次材质重建，而此时 renderer 还没
	# 进树、`_shader_mat` 是空的。`_finish()` 负责还原。
	var water_impl = load(RENDERER_SHADER_WATER_PATH)
	_cell_field_had_setting = ProjectSettings.has_setting(water_impl.CELL_FIELD_SETTING)
	_cell_field_old_setting = ProjectSettings.get_setting(
		water_impl.CELL_FIELD_SETTING, true)
	ProjectSettings.set_setting(water_impl.CELL_FIELD_SETTING, false)
	var renderer = load("res://scripts/rendering/hex_renderer.gd").new()
	# 出货默认值本身单独守着（上面已把设置改成 false，所以这里验的是「代码里的默认」）：
	_expect(bool(water_impl.cell_field_setting_enabled()) == false,
		"the project setting override really reaches the resolver (explicit false wins)")
	root.add_child(renderer)
	_expect(not renderer.terrain_cell_field_enabled,
		"the legacy groups below run with the cell-field switch OFF (byte identity)")
	# _ready() 已经建好 WorldQuad/_shader_mat；这里只补一个假世界。
	var world = load("res://scripts/geography/world_data.gd").new()
	world.world_bounds = Rect2(Vector2(10.0, 20.0), Vector2(100.0, 80.0))
	world.height_tex = _texture()
	world.enum_atlas_tex = _texture()
	world.enum_lut_tex = _texture()
	world.dyn_lut_tex = _texture()
	world.lut_dims = Vector2i(4, 2)
	renderer._world = world
	renderer.parchment_tint = Color(0.9, 0.8, 0.7)
	renderer.parchment_strength = 0.13

	# ① 平台守卫：[land-water-split 2026-11-02] 桌面也走拆分，水面 pass 由
	#    `_water_pass_active()` 决定；关掉拆分总闸时必须立刻不建节点。
	_expect(renderer._water_pass_active(),
		"desktop split keeps the water pass active (land_water_split 2026-11-02)")
	renderer.split_land_water_passes = false
	renderer._sync_water_quad()
	_expect(renderer._water_quad == null,
		"_sync_water_quad() creates nothing when the split gate is closed")
	renderer.split_land_water_passes = true
	# web 紧凑水面变体：生产路径下只有「web + Compatibility + LOW」才选中它，这里用
	# 测试开关固定，否则桌面会建 world_map 变体（那是另一份 program、另一套断言）。
	renderer._forced_water_program_kind = "web_min"

	# ② legacy（非 tiled）变体：6 sampler（height/map_index/enum/dyn/water_depth/
	#    surface array）—— [surface-array-edge 2026-11-02] 起比 C 回合多 1 张，
	#    用来恢复 edge_mix / shore_frac / 次生水格。
	renderer._ensure_water_quad()
	var quad = renderer._water_quad
	var material: ShaderMaterial = renderer._water_mat
	_expect(quad != null and is_instance_valid(quad) and material != null,
		"legacy variant creates the quad + material")
	if quad == null or material == null:
		_finish(renderer)
		return
	_expect(quad.material == material, "quad carries the water material")
	_expect(quad.z_index == renderer._world_quad.z_index,
		"water quad shares the world quad's z_index")
	_expect(quad.get_index() == renderer._world_quad.get_index() + 1,
		"water quad is the immediate next sibling of the world quad (draws above land)")
	_expect(quad.mesh == renderer._world_quad.mesh,
		"water quad reuses the world quad's mesh (identical v_world)")
	_expect(material.shader.code == "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
		+ "#define PK_WEB_TEXTURE_BUDGET\n" + FileAccess.get_file_as_string(SHADER_PATH),
		"legacy variant code == HexRenderer.WATER_PASS_PREFIX + shader source")
	var uniforms: Array = material.shader.get_shader_uniform_list()
	# Seven material samplers fit the Web texture budget. The ocean-current
	# texture and its controls are part of the compact water program's contract.
	_expect(uniforms.size() == 67,
		"legacy variant stays a compact uniform set (got %d)" % uniforms.size())
	var sampler_names := PackedStringArray()
	var legacy_samplers := 0
	for entry in uniforms:
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			legacy_samplers += 1
			sampler_names.append(String(entry.name))
	_expect(legacy_samplers == 7,
		"legacy variant declares 7 samplers incl. surface array and ocean flow (got %d)"
			% legacy_samplers)
	sampler_names.sort()
	var expected_samplers := PackedStringArray(["dyn_lut", "enum_lut", "height_tex",
		"map_index_atlas", "ocean_current_flow_tex", "terrain_surface_tex", "water_depth_tex"])
	expected_samplers.sort()
	_expect(sampler_names == expected_samplers, "compact water declares only its seven owned textures")
	_expect(_range(material, "lut_dims") == Vector2(4.0, 2.0),
		"lut_dims follows the world's cell LUT grid")
	_expect(_range(material, "world_size") == Vector2(100.0, 80.0),
		"world_size follows the world bounds")
	_expect(is_equal_approx(float(_range(material, "parchment_strength")), 0.13),
		"parchment_strength follows the renderer property")

	# ②b [surface-array-edge 2026-11-02] edge 层门控推送：没有 surface array 时必须
	#     是 false（水色退回 C 回合的硬边），换成 6 层 array 后必须整体翻到 true。
	_expect(bool(_range(material, "has_terrain_edge_data")) == false,
		"water pass disables edge blending when the surface array is missing")
	_expect(bool(_range(material, "terrain_edge_layers_bound")) == false,
		"water pass reports the edge layers as unbound without a surface array")
	var six_layer := _surface_array(6)
	world.terrain_surface_tex = six_layer
	renderer._apply_water_uniforms()
	_expect(_range(material, "terrain_surface_tex") == six_layer,
		"water pass binds the shared surface array")
	_expect(bool(_range(material, "terrain_edge_layers_bound"))
		and bool(_range(material, "has_terrain_edge_data"))
		and bool(_range(material, "terrain_static_baked")),
		"6-layer surface array turns on edge_mix / shore_frac / static-bake path")
	world.terrain_surface_tex = null
	renderer._apply_water_uniforms()

	# ③ tiled 变体：变体前缀变了必须重编，sampler 换成 sampler2DArray。
	var tiles := FakeTiles.new()
	tiles.height = _texture()
	tiles.map_index = _texture()
	world.visual_tiles = tiles
	renderer._ensure_water_quad()
	var tiled_material: ShaderMaterial = renderer._water_mat
	_expect(renderer._water_quad != quad,
		"switching to tiled rebuilds the quad instead of reusing a stale variant")
	_expect(tiled_material != null and tiled_material.shader.code.begins_with(
		"#define MAP_VISUAL_TILED\n"),
		"tiled variant prepends MAP_VISUAL_TILED")
	var tiled_uniforms: Array = tiled_material.shader.get_shader_uniform_list()
	_expect(tiled_uniforms.size() > uniforms.size(),
		"tiled variant adds the tile-array uniforms (got %d vs %d)"
			% [tiled_uniforms.size(), uniforms.size()])
	var tiled_names := {}
	for entry in tiled_uniforms:
		tiled_names[String(entry.get("name", ""))] = true
	_expect(tiled_names.has("visual_height_tiles") and tiled_names.has("visual_map_index_tiles")
		and not tiled_names.has("height_tex"),
		"tiled variant swaps legacy samplers for the tile arrays")
	_expect(tiled_names.has("visual_gutter_px"),
		"tiled variant receives the shared visual-tile layout uniforms")

	# ④ 拆节点：材质与节点一起清空，且拆分总闸关闭时下一次 _sync 保持为空。
	renderer._drop_water_quad()
	_expect(renderer._water_quad == null and renderer._water_mat == null,
		"_drop_water_quad() clears both the node and the material")
	renderer.split_land_water_passes = false
	renderer._sync_water_quad()
	_expect(renderer._water_quad == null,
		"after drop, the closed split gate keeps the pass absent")
	renderer.split_land_water_passes = true

	# ⑤ 常量与磁盘文件一致：WATER_SHADER_PATH 一旦改名/搬走，_create_water_quad
	# 只会 push_warning 然后静默不画水面（屏幕退化成占位色），必须在 CI 里拦住。
	_expect(FileAccess.file_exists(HexRenderer.WATER_SHADER_PATH),
		"HexRenderer.WATER_SHADER_PATH points at an existing file")
	_expect(HexRenderer.WATER_SHADER_PATH == SHADER_PATH,
		"the path this test reads is the one the renderer loads")
	_expect(HexRenderer.WATER_PASS_PREFIX
		== HexRenderer.QUALITY_PREFIX_LOW + HexRenderer.PK_WEB_TEXTURE_BUDGET_DEFINE,
		"water pass prefix is composed from the shared constants (no second literal)")

	# ⑥ 生产入口的接线在源码层断言（_apply_uniforms 末尾调用 _sync_water_quad），
	# 见 tests/world/terrain_shader_variant_test.gd —— 这里不驱动 _apply_uniforms：
	# 它要一整个 WorldData + VisualTileSet，用假对象驱动只会测到假对象本身。

	# ⑦ [cell-field-web 2026-11-18 / W3] 场函数路径（宏开）的离线断言。
	_check_cell_field_variant()

	# ⑧ 海岸两侧都 discard 的像素数 = 0（**必须真后端**；headless 打印 SKIPPED）。
	await _check_no_shore_holes_on_gpu()

	_finish(renderer)


# ═══════════════════════════════════════════════════════════════════════════
# ⑦ 场函数路径（PK_WATER_FIELD_MATCHES_LAND 开）的编译 / 采样槽 / 源码断言
# ═══════════════════════════════════════════════════════════════════════════

func _check_cell_field_variant() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH).replace("\r\n", "\n")
	var prefix := HexRenderer.WATER_PASS_PREFIX
	# ① 变体能编：`Shader.new().code = prefix + source` 之后
	#    `get_shader_uniform_list()` 非空（这两步与 _create_water_quad 的判据同源：
	#    编译失败时 Godot 返回空表，见 renderer_shader_water.gd 的编译自检）。
	var field_shader := Shader.new()
	field_shader.code = prefix + WATER_FIELD_MATCHES_LAND_DEFINE + source
	var field_uniforms: Array = field_shader.get_shader_uniform_list()
	_expect(not field_uniforms.is_empty(),
		"field variant compiles in the shader language (%d uniforms)"
			% field_uniforms.size())
	if field_uniforms.is_empty():
		return
	# ② 精简程序的 uniform 集合仍然很小（world_map 是 186+）。数值是**实测值**：宏开比
	#    宏关多 5 个（见下面的 set 断言），比世界地图小一个量级。
	_expect(field_uniforms.size() == 72,
		"field variant stays a compact uniform set (got %d)" % field_uniforms.size())

	# ③ 采样槽普查（方案 §3.3 第 2/3 条：等值断言，不是阈值）。
	var off_shader := Shader.new()
	off_shader.code = prefix + source
	var off_samplers := _sampler_names(off_shader.get_shader_uniform_list())
	var field_samplers := _sampler_names(field_uniforms)
	_expect(off_samplers.size() == 7,
		"macro off keeps today's 7 samplers (got %d)" % off_samplers.size())
	# 记账：OFF 7 张 → 场函数路径 4 张。
	#   −4 = enum_lut / dyn_lut / map_index_atlas / water_depth_tex（W3 全部退役）
	#   +1 = cell_table
	# 方案 §3.3 写的 "OFF − 2 + 1" 只算了 enum/dyn 两张；W3 的迁移同时让
	# map_index_atlas 与 water_depth_tex 失去全部读者（格界解析算、水深读 layer2.G），
	# 按 §3.2「删声明而不是保留声明不调用」一起删掉 —— 因此实测是 −4 + 1 = 4。
	# 数值按实测记（lead 指示：以实测为准并解释），等式本身仍然逐项可核对。
	_expect(field_samplers.size() == off_samplers.size() - 4 + 1,
		"field sampler accounting: off(%d) - 4 retired + 1 cell_table == %d (got %d)"
			% [off_samplers.size(), off_samplers.size() - 4 + 1, field_samplers.size()])
	var expected_field_samplers := PackedStringArray(["cell_table", "height_tex",
		"ocean_current_flow_tex", "terrain_surface_tex"])
	expected_field_samplers.sort()
	_expect(field_samplers == expected_field_samplers,
		"field variant declares exactly 4 textures: %s" % str(field_samplers))
	_expect(field_samplers.size() <= 8,
		"field variant stays inside the 8-slot Web device budget (%d/8, %d slots spare)"
			% [field_samplers.size(), 8 - field_samplers.size()])

	# ④ 旧三槽 + W3 追加退役的两张都不在变体里（方案 §3.3 第 4 条）。
	var field_names := {}
	for entry in field_uniforms:
		field_names[String(entry.get("name", ""))] = true
	for retired in ["enum_lut", "dyn_lut", "map_index_atlas", "water_depth_tex"]:
		_expect(not field_names.has(String(retired)),
			"field variant has no %s uniform any more" % String(retired))
	_expect(field_names.has("cell_table") and field_names.has("cell_table_size")
		and field_names.has("cell_table_bound") and field_names.has("terrain_warp_range"),
		"field variant exposes the cell-field uniforms (cell_table / size / bound / warp)")

	# ⑤ 源码缺席断言：断言对象是**展开后**的源码。全文 grep 必然是恒真/恒假 ——
	#    旧路径与新路径在同一个文件里由 #ifdef 二选一，两边都在全文里。
	#    展开器与 tests/world/terrain_shader_variant_test.gd 里那份同构（递归展开
	#    #include、求值 #ifdef/#ifndef/#if defined(...)、剥注释）。
	var pk_defines := _defines_from_prefix(prefix)
	pk_defines["MOBILE_QUALITY_LOW"] = true
	pk_defines["PK_SHADER_TIER_LOW"] = true
	pk_defines["PK_WEB_TEXTURE_BUDGET"] = true
	var off_expanded := _expand_shader(SHADER_PATH, pk_defines.duplicate())
	var field_defines := pk_defines.duplicate()
	field_defines["PK_WATER_FIELD_MATCHES_LAND"] = true
	var field_expanded := _expand_shader(SHADER_PATH, field_defines)
	_expect(off_expanded.length() > 4000 and field_expanded.length() > 4000,
		"the shader preprocessor expands both macro states (%d vs %d chars)"
			% [off_expanded.length(), field_expanded.length()])
	_expect(off_expanded != field_expanded,
		"the macro really changes the token stream (not a vacuous absence walk)")
	# 只在场函数路径里必须消失的符号（旧数据通道 + 环形邻域）。
	for retired_symbol in ["visual_sample_map_index(", "texture(enum_lut", "texture(dyn_lut",
			"visual_sample_water_depth(", "compute_lake_shore_proxy",
			"water_edge_secondary_index(", "visual_sample_edge_distance("]:
		_expect(not field_expanded.contains(String(retired_symbol)),
			"field variant compiles out %s" % String(retired_symbol))
	# 反向：宏关时必须**都还在**（否则上面的缺席断言可以靠"整段没展开"蒙过去）。
	for kept_symbol in ["visual_sample_map_index(", "texture(enum_lut", "texture(dyn_lut",
			"visual_sample_water_depth(", "visual_sample_edge_distance("]:
		_expect(off_expanded.contains(String(kept_symbol)),
			"macro off still compiles %s (the define really gates the paths)"
				% String(kept_symbol))
	# 新路径必须真的在宏开时才出现。
	_expect(field_expanded.contains("pk_hex_cell_field_default(")
		and not off_expanded.contains("pk_hex_cell_field_default("),
		"the field function exists only in the macro-on token stream")
	# 水深 / 海冰必须**三格按 w_raw 插值**（任务 W3 的四条改动之一）：三格 state 与
	# 三格 aux 都要有读者，否则就退化成"逐格常量"的旧数据通道。
	_expect(field_expanded.contains("pk_cell_field_classes(field, fe0, fe1, fe2);")
		and field_expanded.contains("pk_cell_state_at(field.c0)")
		and field_expanded.contains("pk_cell_state_at(field.c1)")
		and field_expanded.contains("pk_cell_state_at(field.c2)")
		and field_expanded.contains("pk_cell_aux_at(field.c0)")
		and field_expanded.contains("pk_cell_aux_at(field.c1)")
		and field_expanded.contains("pk_cell_aux_at(field.c2)"),
		"field variant interpolates state/aux over all three cells (w_raw), not one plateau")
	_expect(field_expanded.contains("pk_cell_field_ranked_weight_raw(")
		and field_expanded.contains("pk_cell_field_ranked_class("),
		"field variant takes the secondary water cell from pk_cell_field_rank(f, 1)")
	_expect(field_expanded.contains("shore_gap_from_field(")
		and field_expanded.contains("PK_SHORE_BAND_HEX"),
		"field variant derives the shore distance analytically (gap + PK_SHORE_BAND_HEX)")

	# ⑤b 逐字复制的小函数必须与源文件**逐个相同**（源文件改了而这里没跟 ⇒ 红）。
	#     为什么复制而不是 include：那四份 include 会把 biome_color / biome_detail /
	#     材质族 / noise_tex 一整条依赖拖进这个精简程序（实测直接 include
	#     terrain_surface_detail 会以 Unknown identifier 炸掉整份程序）。复制的前提就是
	#     这一组断言 —— 它把"照抄"从注释变成了可执行的契约。
	var flat_source := _collapse_ws(source)
	for copied in [
			["res://shaders/include/uniforms.gdshaderinc", "vec2 wrap_world_pos(vec2 wp)"],
			["res://shaders/include/terrain_surface_detail.gdshaderinc",
				"bool terrain_static_biome_is_water(int biome)"],
			["res://shaders/include/terrain_surface_detail.gdshaderinc",
				"float terrain_edge_screen_width_px()"],
			["res://shaders/include/shore_common.gdshaderinc",
				"float shore_gap_from_field(HexCellField f"],
			["res://shaders/include/shore_common.gdshaderinc",
				"float shore_distance_wu(float shore_gap)"],
			["res://shaders/include/shore_common.gdshaderinc",
				"float shore_contact_from_field(float shore_gap)"],
			["res://shaders/include/water.gdshaderinc",
				"vec4 water_biome_weights_field(vec3 weights"],
			]:
		var verbatim := _collapse_ws(_source_block(String(copied[0]), String(copied[1])))
		_expect(not verbatim.is_empty() and flat_source.contains(verbatim),
			"the compact pass copies %s verbatim from %s"
				% [String(copied[1]).split("(")[0], String(copied[0]).get_file()])
	_expect(flat_source.contains("const float PK_SHORE_BAND_HEX = 0.43;"),
		"PK_SHORE_BAND_HEX keeps shore_common's value 0.43 (hex units)")

	# ⑥ 水陆判定同源（方案 §3.7 第 1 条 / lead 裁决第 5 条）。这条**能真的失败**：
	#    函数名写错、或者把 legacy 谓词留在场函数路径里，下面都会红。
	var water_field_call := "= pk_cell_field_is_water_dom("
	_expect(field_expanded.count(water_field_call) == 1,
		"field variant decides is_water with exactly one call of pk_cell_field_is_water_dom")
	var legacy_predicate := "(biome == B_OCEAN) || (biome == B_COAST)"
	_expect(not field_expanded.contains(legacy_predicate),
		"field variant no longer carries the legacy enum_lut is_water predicate")
	_expect(off_expanded.contains(legacy_predicate),
		"macro off keeps the legacy is_water predicate (today's behaviour)")
	# 陆地 program 的那一侧：桌面 PK_LAND_ONLY 变体与 Web LOW 陆地变体。
	var land_pk_defines := {
		"MOBILE_QUALITY_LOW": true, "PK_SHADER_TIER_LOW": true,
		"PK_WEB_TEXTURE_BUDGET": true, "PK_CELL_FIELD": true, "PK_LAND_ONLY": true,
	}
	var land_pk := _expand_shader(WORLD_MAP_PATH, land_pk_defines)
	_expect(land_pk.contains(water_field_call),
		"the land program decides is_water with the same pk_cell_field_is_water_dom call")
	var land_web_min_defines := _defines_from_prefix(HexRenderer.WORLD_MAP_WEB_PREFIX)
	var land_web_min := _expand_shader(WORLD_MAP_PATH, land_web_min_defines)
	_expect(land_web_min.contains(legacy_predicate),
		"the Web LOW land prefix alone (no PK_CELL_FIELD) is the legacy path today")
	# 宏开那一侧的**同平台**对偶：Web LOW 陆地变体（world-min 前缀）一旦带 PK_CELL_FIELD，
	# 必须调同一个 pk_cell_field_is_water_dom —— 这正是 macro 打开的前提条件。
	var land_web_min_field_defines := land_web_min_defines.duplicate()
	land_web_min_field_defines["PK_CELL_FIELD"] = true
	var land_web_min_field := _expand_shader(WORLD_MAP_PATH, land_web_min_field_defines)
	_expect(land_web_min_field.contains(water_field_call),
		"Web-LOW land + PK_CELL_FIELD decides is_water with the same"
			+ " pk_cell_field_is_water_dom call as this pass")
	# 一致性：两片 program 的判据来源必须**同时**是 field 或**同时**是 legacy ——
	# 一 field 一 legacy 就是方案 §3.7 要防的"海岸判定两套来源"。
	var water_is_field := field_expanded.contains(water_field_call)
	var water_is_legacy := off_expanded.contains(legacy_predicate)
	_expect(water_is_field and water_is_legacy,
		"both sources are reachable and mutually exclusive (field on / legacy off)")
	_expect(land_web_min.contains(legacy_predicate) == water_is_legacy,
		"macro off: water and Web-LOW land share the legacy predicate")
	_expect(land_pk.contains(water_field_call) == water_is_field,
		"macro on: water and land share pk_cell_field_is_water_dom")
	# ⑦ ε 放宽只能在**下层**（方案 §3.7 末条）。绘制顺序证据见 shader 里的注释块：
	#    renderer_scene_services.gd:91-94 先建陆地 quad（z_index=0）；
	#    renderer_shader_water.gd:782/787 水面 quad z_index=0 + move_child 到陆地 +1
	#    （「水面盖住陆地」）⇒ 陆地在下、水面在上。
	_expect(land_pk.contains("is_water = is_water && (field_edge_gap >= PK_FIELD_SHORE_EPS)"),
		"the LOWER program (land) relaxes is_water by PK_FIELD_SHORE_EPS")
	var world_map_source := FileAccess.get_file_as_string(WORLD_MAP_PATH).replace("\r\n", "\n")
	_expect(world_map_source.contains("const float PK_FIELD_SHORE_EPS = 0.02;"),
		"PK_FIELD_SHORE_EPS keeps the documented value 0.02 (same constant, not a literal)")
	_expect(not field_expanded.contains("PK_FIELD_SHORE_EPS"),
		"the UPPER program (this water pass) stays strict — relaxing here would"
			+ " uncover the lower program's placeholder water colour in the tie band")
	var scene_services := FileAccess.get_file_as_string(RENDERER_SCENE_SERVICES_PATH)
	_expect(scene_services.contains("host._world_quad.z_index = 0"),
		"draw order evidence: the land quad is created first with z_index 0")
	var water_renderer := FileAccess.get_file_as_string(RENDERER_SHADER_WATER_PATH)
	# 水面 quad 的挂接与 move_child 定序现在集中在 renderer_graphics_settings.attach_water_surface
	# （画质缩放开启时挂到缩放子视口，否则挂在 host 下并紧跟陆地 quad）。
	var graphics_source := FileAccess.get_file_as_string(RENDERER_GRAPHICS_SETTINGS_PATH)
	var attach_a := graphics_source.find("func attach_water_surface")
	var attach_b := graphics_source.find("\nfunc ", attach_a + 1)
	var attach_block := graphics_source.substr(attach_a, attach_b - attach_a) \
		if attach_a >= 0 and attach_b > attach_a else ""
	var order_host := HexRenderer.new()
	order_host._world_quad = MeshInstance2D.new()
	order_host.add_child(order_host._world_quad)
	order_host.add_child(Node2D.new())
	order_host._water_quad = MeshInstance2D.new()
	order_host._graphics_details.attach_water_surface(order_host)
	_expect(water_renderer.contains("host._water_quad.z_index = 0")
			and water_renderer.contains("host._graphics_details.attach_water_surface(host)")
			and attach_block.contains("move_child(host._water_quad")
			and order_host._water_quad.get_index() == order_host._world_quad.get_index() + 1,
		"draw order evidence: the water quad is moved right after the land quad")
	order_host.free()
	# Web 与桌面共用同一段**定序**代码 ⇒ 绘制顺序相同（平台分支只允许出现在编译失败
	# 的回退里，不能出现在"谁盖谁"这段）。检查 z_index→挂接调用之间，以及挂接函数本身。
	var order_a := water_renderer.find("host._water_quad.z_index = 0")
	var order_b := water_renderer.find("host._graphics_details.attach_water_surface(host)", order_a)
	var order_block := water_renderer.substr(order_a, order_b - order_a) \
		if order_a >= 0 and order_b > order_a else ""
	_expect(not order_block.is_empty() and not order_block.contains("has_feature")
			and not attach_block.is_empty() and not attach_block.contains("has_feature"),
		"the draw-order statements carry no platform branch ⇒ Web draws in the same"
			+ " order as desktop (land below, water above)")

	# ⑧ 注入点：宏必须跟随**陆地 program 的数据源**，不能自己判平台/画质。
	var shader_variants := FileAccess.get_file_as_string(
		"res://scripts/rendering/renderer_shader_variants.gd")
	_check_injection_point(shader_variants, field_expanded)


## 宏的注入点契约。renderer 侧那一行由并行任务落地（本文件不拥有那个文件）：
## 落地之后这里变成硬断言，落地之前只打印 PENDING 并说明"本测试靠什么兜着"。
func _check_injection_point(water_renderer: String, field_expanded: String) -> void:
	var impl = load(RENDERER_SHADER_WATER_PATH)
	var constant_map: Dictionary = impl.get_script_constant_map()
	if constant_map.has("WATER_FIELD_MATCHES_LAND_DEFINE"):
		_expect(String(constant_map["WATER_FIELD_MATCHES_LAND_DEFINE"])
			== WATER_FIELD_MATCHES_LAND_DEFINE,
			"renderer constant WATER_FIELD_MATCHES_LAND_DEFINE matches the macro used here")
		_expect(water_renderer.contains("_cell_field_prefix(host)"),
			"the injection point follows the land program's data source"
				+ " (_cell_field_prefix), not a platform/quality test of its own")
	else:
		print("[web-water-pass] PENDING: renderer_shader_water.gd 还没有 "
			+ "WATER_FIELD_MATCHES_LAND_DEFINE。落地所需的**唯一**一行见本文件顶部注释"
			+ "与任务报告；在那之前宏开路径由本测试手工注入前缀覆盖。")
	# 无论注入点是否落地，shader 侧都不能自己判平台/画质来决定走哪条路：
	_expect(not field_expanded.contains("terrain_cell_field_enabled"),
		"the shader never reads the feature flag itself (the macro is the only switch)")


# ═══════════════════════════════════════════════════════════════════════════
# ⑧ 海岸两侧都 discard 的像素数 = 0（真后端）
# ═══════════════════════════════════════════════════════════════════════════
## 为什么需要真后端：`--headless` 是 dummy 渲染器，`get_texture().get_image()` 返回
## null / 全零，**任何"GPU 到底画了什么"的断言在 headless 下都不成立**（契约 §6）。
##
## 判据（照 lead 裁决第 4 条，两种宏状态都要 0）：
##   · 宏关：两片 program 的判据逐字同源（都是 enum_lut 的那个 6 位谓词），上半条
##     ⑦ 已用展开源码断言；运行期不需要 GPU 也成立。
##   · 宏开：本 pass 的 discard 集合必须**恰好**等于 CPU 场函数判出的"非水"集合，
##     且与陆地 program 的规则（`is_water && gap >= PK_FIELD_SHORE_EPS` 才放弃）互补。
##     这里把真实的场函数变体渲进一个最小 SubViewport，回读每一个像素：
##       water_draws = 回读 alpha > 0.5（本 pass 没 discard）
##       land_draws  = !(is_water_cpu && edge_gap >= EPS)   ← world_map 的 PK_LAND_ONLY 规则
##     断言 ①water_draws == is_water_cpu 100%（GPU ↔ CPU 同一个场）
##          ②**两边都不画**的像素数 == 0（把 ε 搬到上层、或判据不同源，这条立刻红）
##          ③两个集合都非空（否则断言 vacuous）
## 陆地 program 的真实回读不在本测试范围：它需要 world_map 的整套 uniform / sampler，
## 由 cell_field_gpu_parity_probe.gd 覆盖坐标与场本身。
const GPU_VIEW_W := 160
const GPU_VIEW_H := 120
const GPU_HEX_SIZE := 22.0
const GPU_ORIGIN := Vector2(-41.37, -30.11)
## cell_table 只有 6×6 格：视口（160×120 + hex 22）覆盖 col ≈ −3.4…4.6、row ≈ −1…2.7，
## 于是**同屏同时**包含 posmod 回绕（col −1 → 5）、padding 行（row < 0）与海岸线
## （col 2/3 之间），三种边界都在一次回读里被测到。
const GPU_MAP_W := 6
const GPU_MAP_H := 6
const GPU_ECOTONE := 0.84          # = uniforms.gdshaderinc 的 terrain_ecotone_width 默认值
const GPU_SHORE_EPS := 0.02        # = world_map.gdshader 的 PK_FIELD_SHORE_EPS
const GPU_B_SEA_ICE := 20          # 与 shader 的 B_SEA_ICE 同值
const GPU_B_OCEAN := 0
const GPU_B_GRASSLAND := 2         # 任意非水 biome（land 侧）

var _gpu_viewport: SubViewport
var _gpu_quad: MeshInstance2D
var _gpu_material: ShaderMaterial


func _real_backend_available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not String(RenderingServer.get_video_adapter_name()).is_empty()


func _check_no_shore_holes_on_gpu() -> void:
	if not _real_backend_available():
		print("[web-water-pass] SKIPPED: 海岸两侧 discard = 0 需要真实渲染后端"
			+ "（headless 用 dummy 渲染器，读不回像素）。请改用：")
		print("[web-water-pass]   Godot --path . --rendering-driver opengl3 "
			+ "-s res://tests/world/web_water_pass_node_test.gd")
		return
	var source := FileAccess.get_file_as_string(SHADER_PATH).replace("\r\n", "\n")
	var shader := Shader.new()
	shader.code = HexRenderer.WATER_PASS_PREFIX + WATER_FIELD_MATCHES_LAND_DEFINE + source
	if shader.get_shader_uniform_list().is_empty():
		_expect(false, "field variant compiles on the real backend before drawing")
		return
	var cell_table := _gpu_cell_table()
	var surface := _gpu_surface_array()
	var built: bool = await _gpu_build_scene(shader, cell_table, surface)
	if not built:
		return
	var image: Image = await _gpu_render()
	if image == null:
		_expect(false, "GPU readback returns an image")
		return
	_gpu_compare(image)


func _biome_at_offset(offset: Vector2i) -> int:
	# 合成地图：左半海洋、右半陆地，海岸线随行摆动 1 格（让海岸线不是轴对齐的直线）；
	# 南北越界行返回 padding 哨兵 B_SEA_ICE（与 pk_cell_table_fetch 的 pad 同值）。
	var row := offset.y
	if row < 0 or row >= GPU_MAP_H:
		return GPU_B_SEA_ICE
	var col := posmod(offset.x, GPU_MAP_W)
	var wave := 1 if row % 2 == 1 else 0
	return GPU_B_OCEAN if col + wave < GPU_MAP_W / 2 else GPU_B_GRASSLAND

func _gpu_cell_table() -> Texture2DArray:
	var layers: Array[Image] = []
	for _layer in 3:
		var img := Image.create_empty(GPU_MAP_W, GPU_MAP_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		layers.append(img)
	var cls: Image = layers[0]
	var state: Image = layers[1]
	var aux: Image = layers[2]
	for row in GPU_MAP_H:
		for col in GPU_MAP_W:
			var biome := _biome_at_offset(Vector2i(col, row))
			cls.set_pixel(col, row, Color(float(biome) / 255.0, 0.0, 0.0, 0.0))
			# state.A = 海冰比例 0（水像素不是冰），aux.R = fog_k 1.0（可见）、
			# aux.G = water_depth 0.5（湖泊深度走它）。
			state.set_pixel(col, row, Color(0.0, 0.0, 0.0, 0.0))
			aux.set_pixel(col, row, Color(1.0, 0.5, 0.0, 0.0))
	var array := Texture2DArray.new()
	array.create_from_images(layers)
	return array


func _gpu_surface_array() -> Texture2DArray:
	# 7 层（layer6 = boundary_warp）。全中性 + terrain_warp_layer_bound=false ⇒ 场函数
	# 走"无扭曲"分支，CPU 侧同样传 Vector2.ZERO。
	var layers: Array[Image] = []
	for _layer in 7:
		var img := Image.create_empty(GPU_VIEW_W, GPU_VIEW_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5, 0.0, 1.0))
		layers.append(img)
	var array := Texture2DArray.new()
	array.create_from_images(layers)
	return array


func _gpu_world_rect_mesh() -> Mesh:
	var origin := GPU_ORIGIN
	var size := Vector2(float(GPU_VIEW_W), float(GPU_VIEW_H))
	var verts := PackedVector2Array([
		origin, origin + Vector2(size.x, 0.0), origin + size, origin + Vector2(0.0, size.y)])
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _gpu_build_scene(shader: Shader, cell_table: Texture2DArray,
		surface: Texture2DArray) -> bool:
	_gpu_material = ShaderMaterial.new()
	_gpu_material.shader = shader
	_gpu_viewport = SubViewport.new()
	_gpu_viewport.size = Vector2i(GPU_VIEW_W, GPU_VIEW_H)
	# transparent_bg ⇒ 没画到的像素 alpha = 0，正好用来判"这一侧 discard 了"。
	_gpu_viewport.transparent_bg = true
	_gpu_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_gpu_viewport)
	var camera := Camera2D.new()
	_gpu_viewport.add_child(camera)
	_gpu_quad = MeshInstance2D.new()
	_gpu_quad.mesh = _gpu_world_rect_mesh()
	_gpu_quad.material = _gpu_material
	_gpu_viewport.add_child(_gpu_quad)
	camera.position = GPU_ORIGIN + Vector2(float(GPU_VIEW_W), float(GPU_VIEW_H)) * 0.5
	camera.force_update_scroll()
	# 与生产同源的一组 push（renderer_lighting_bindings.gd:116-128 推的就是这些）。
	_gpu_material.set_shader_parameter("world_origin", GPU_ORIGIN)
	_gpu_material.set_shader_parameter("world_size", Vector2(float(GPU_VIEW_W), float(GPU_VIEW_H)))
	_gpu_material.set_shader_parameter("hex_size", GPU_HEX_SIZE)
	_gpu_material.set_shader_parameter("pixel_world_size", 1.0)
	_gpu_material.set_shader_parameter("wrap_origin_x", 0.0)
	_gpu_material.set_shader_parameter("wrap_period_x", 0.0)
	_gpu_material.set_shader_parameter("terrain_ecotone_width", GPU_ECOTONE)
	_gpu_material.set_shader_parameter("terrain_surface_debug_view", 0)
	_gpu_material.set_shader_parameter("cell_table", cell_table)
	_gpu_material.set_shader_parameter("cell_table_size",
		Vector2(float(GPU_MAP_W), float(GPU_MAP_H)))
	_gpu_material.set_shader_parameter("cell_table_bound", true)
	_gpu_material.set_shader_parameter("terrain_surface_tex", surface)
	_gpu_material.set_shader_parameter("terrain_surface_layer_count", 7)
	_gpu_material.set_shader_parameter("terrain_warp_layer_bound", false)
	_gpu_material.set_shader_parameter("terrain_warp_range", 1.6)
	_gpu_material.set_shader_parameter("terrain_warp_amp", 0.4)
	_gpu_material.set_shader_parameter("visual_quality", 0)
	_gpu_material.set_shader_parameter("fog_early_out_enabled", false)
	_gpu_material.set_shader_parameter("fog_gray_enabled", false)
	_gpu_material.set_shader_parameter("ocean_current_enabled", false)
	_gpu_material.set_shader_parameter("water_effect_enabled", false)
	_gpu_material.set_shader_parameter("day_night_enabled", false)
	var img := Image.create_empty(GPU_VIEW_W, GPU_VIEW_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	_gpu_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(img))
	await process_frame
	await process_frame
	return true


func _gpu_render() -> Image:
	for _frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := _gpu_viewport.get_texture().get_image()
	if image == null:
		return null
	_expect(image.get_width() == GPU_VIEW_W and image.get_height() == GPU_VIEW_H,
		"GPU readback is %dx%d (got %dx%d)" % [GPU_VIEW_W, GPU_VIEW_H,
			image.get_width(), image.get_height()])
	return image


func _gpu_compare(image: Image) -> void:
	var field_script = load("res://scripts/geography/hex_cell_field.gd")
	var total := GPU_VIEW_W * GPU_VIEW_H
	var water_drawn := 0
	var land_drawn := 0
	var hole := 0
	var hard := 0
	var tie := 0
	var first_bad := ""
	var distinct_dom := {}
	for j in GPU_VIEW_H:
		for i in GPU_VIEW_W:
			var water_draws := image.get_pixel(i, j).a > 0.5
			if water_draws:
				water_drawn += 1
			# 像素中心 = origin + (i+0.5, j+0.5)·1wu（与 cell_field_gpu_parity_probe 同一约定）。
			var wp := GPU_ORIGIN + Vector2(float(i) + 0.5, float(j) + 0.5)
			var field: Dictionary = field_script.field_at(
				wp, GPU_HEX_SIZE, Vector2.ZERO, GPU_ECOTONE, GPU_MAP_H, GPU_MAP_W)
			var dom := int(field["dom"])
			var offset: Vector2i = field_script.cell_offset(field, dom)
			distinct_dom[offset] = true
			var is_water_cpu := _is_water_biome(_biome_at_offset(offset))
			# 陆地 program 的规则（world_map.gdshader 的 PK_LAND_ONLY 分支）：
			# 岸带 gap < EPS 内即使判成水也照常画陆地；其余位置只有非水才画。
			var gap: Vector3 = field["gap"]
			var edge_gap := 1e9
			if dom != 0:
				edge_gap = minf(edge_gap, gap.x)
			if dom != 1:
				edge_gap = minf(edge_gap, gap.y)
			if dom != 2:
				edge_gap = minf(edge_gap, gap.z)
			var land_draws := not (is_water_cpu and edge_gap >= GPU_SHORE_EPS)
			if land_draws:
				land_drawn += 1
			if not land_draws and not water_draws:
				hole += 1
			if water_draws != is_water_cpu:
				var w: Vector3 = field["w_raw"]
				var hi := maxf(w.x, maxf(w.y, w.z))
				var lo := minf(w.x, minf(w.y, w.z))
				var mid := w.x + w.y + w.z - hi - lo
				if hi - mid < 1e-3:
					tie += 1
				else:
					hard += 1
					if first_bad.is_empty():
						first_bad = "pixel(%d,%d) world=(%.3f,%.3f) gpu_water=%s cpu_water=%s gap=%.4f" % [
							i, j, wp.x, wp.y, str(water_draws), str(is_water_cpu), edge_gap]
	_expect(water_drawn > total / 8 and land_drawn > total / 8,
		"the GPU probe really covers both sides of the coast (water %d / land %d of %d)"
			% [water_drawn, land_drawn, total])
	_expect(distinct_dom.size() >= 20,
		"the probe lattice spans real cells (%d distinct dominant offsets)"
			% distinct_dom.size())
	_expect(hard == 0 and tie == 0,
		"the water pass draws exactly the CPU field's water set on 100%% of %d pixels"
			% total + " (%d hard, %d tie-band mismatch; first: %s)" % [
				hard, tie, "none" if first_bad.is_empty() else first_bad])
	_expect(hole == 0,
		"pixels discarded by BOTH programs == 0 (water draws %d, land rule draws %d)"
			% [water_drawn, land_drawn])
	if is_instance_valid(_gpu_viewport):
		_gpu_viewport.queue_free()


func _is_water_biome(biome: int) -> bool:
	# 与 shader 的 terrain_static_biome_is_water 同一组 biome id（0=OCEAN / 1=COAST /
	# 18=LAKE / 19=REEF / 20=SEA_ICE / 21=KELP）。
	return biome == 0 or biome == 1 or biome == 18 or biome == 19 or biome == 20 or biome == 21


# ═══════════════════════════════════════════════════════════════════════════
# 极简 shader 预处理器（与 tests/world/terrain_shader_variant_test.gd 里那份同构）
# ═══════════════════════════════════════════════════════════════════════════
## 为什么必须展开而不能 grep 全文：旧路径与新路径在**同一个文件里**由 `#ifdef`
## 二选一，全文里两边都在 —— 按全文断言 `not contains "enum_lut"` 永远失败、
## 按全文断言 `contains` 又永远成立（恒真），两者都没有守到任何东西。
## 能力边界（够用即可）：递归展开 `#include "res://..."`；求值
## `#ifdef / #ifndef / #if defined(X) && !defined(Y)`；剥掉 /* */ 与 // 注释；
## 记 `#define X`（值不展开 —— 断言对象是这些符号是否还被**引用**）。
## 认不出的条件表达式按**两支都算**的保守并集处理：并集只会让文本更长，所以缺席
## 断言不会被它蒙成恒真（最坏情况是偏严而失败，不会假绿）。
func _expand_shader(path: String, defines: Dictionary) -> String:
	var out: Array = []
	_expand_into(path, defines.duplicate(), out, 0)
	return "\n".join(out)


func _expand_into(path: String, defines: Dictionary, out: Array, depth: int) -> void:
	if depth > 16:
		return
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return
	var text := _strip_shader_comments(raw.replace("\r\n", "\n").replace("\r", "\n"))
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
				if active:
					var inc := rest.trim_prefix("\"").trim_suffix("\"")
					if inc.begins_with("res://"):
						_expand_into(inc, defines, out, depth + 1)
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


# ═══════════════════════════════════════════════════════════════════════════
# 收尾 / 小工具
# ═══════════════════════════════════════════════════════════════════════════

func _finish(renderer) -> void:
	if is_instance_valid(renderer):
		renderer.queue_free()
	if is_instance_valid(_gpu_viewport):
		_gpu_viewport.queue_free()
	# [2026-11-18] 还原项目设置（出货默认开），否则同进程里后续断言会看到被改过的状态。
	var water_impl = load(RENDERER_SHADER_WATER_PATH)
	if _cell_field_had_setting:
		ProjectSettings.set_setting(water_impl.CELL_FIELD_SETTING, _cell_field_old_setting)
	else:
		ProjectSettings.set_setting(water_impl.CELL_FIELD_SETTING, null)
	_expect(bool(water_impl.cell_field_setting_enabled()),
		"the project setting is back to the shipped default (enabled) after the run")
	print("=== web water pass node: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从一个真实前缀常量里取回它注入的 define 集合（不在测试里手抄一份）。
func _defines_from_prefix(prefix: String) -> Dictionary:
	var out := {}
	for raw_line in prefix.replace("\r\n", "\n").split("\n"):
		var line := String(raw_line).strip_edges()
		if not line.begins_with("#define"):
			continue
		var body := line.substr("#define".length()).strip_edges()
		var name := body.split(" ")[0]
		if not name.is_empty():
			out[name] = true
	return out


func _sampler_names(uniform_list: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for entry in uniform_list:
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			names.append(String(entry.name))
	names.sort()
	return names


## 从源文件里取出以 signature 开头、到下一个顶格 `}` 为止的函数块（源文件的函数都在
## 第 0 列，所以顶格 `}` 就是函数结束）。取不到返回空串 —— 调用方必须据此失败，
## 不能把"源文件里找不到"当成"两边一致"。
func _source_block(path: String, signature: String) -> String:
	var lines := FileAccess.get_file_as_string(path).replace("\r\n", "\n").split("\n")
	var start := -1
	for i in lines.size():
		if String(lines[i]).begins_with(signature):
			start = i
			break
	if start < 0:
		return ""
	var out := PackedStringArray()
	for i in range(start, lines.size()):
		var line := String(lines[i])
		out.append(line)
		if line == "}":
			break
	return "\n".join(out)


## 折叠全部空白（含换行）为一个空格：逐字复制比对只关心 token 序列，不关心断行位置。
func _collapse_ws(text: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\s+")
	return regex.sub(text, " ", true).strip_edges()


func _texture() -> Texture2D:
	var image := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.1, 0.2, 0.3, 0.4))
	return ImageTexture.create_from_image(image)


## [surface-array-edge 2026-11-02] 合成 N 层同尺寸 RGBA8 array（层数门控用）。
func _surface_array(layers: int) -> Texture2DArray:
	var images: Array = []
	for _i in range(layers):
		var image := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.5, 0.5, 0.5, 1.0))
		images.append(image)
	var array := Texture2DArray.new()
	array.create_from_images(images)
	return array


func _range(material: ShaderMaterial, key: String):
	return material.get_shader_parameter(key)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
