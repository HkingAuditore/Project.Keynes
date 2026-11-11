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
## 跑法：
##   Godot --headless --path Project\project-keynes \
##       --script res://tests/world/web_water_pass_node_test.gd

const SHADER_PATH := "res://shaders/world_water_web.gdshader"

var _checks := 0
var _failures := 0


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
	var renderer = load("res://scripts/rendering/hex_renderer.gd").new()
	root.add_child(renderer)
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

	_finish(renderer)


func _finish(renderer) -> void:
	if is_instance_valid(renderer):
		renderer.queue_free()
	print("=== web water pass node: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


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
