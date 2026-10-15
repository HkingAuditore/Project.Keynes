extends Control
class_name PaperAtlasStage

## Renders layered papercut islands with live shader effects (coastal ripples,
## river shimmer, mountain mist, and cartographic blueprint survey reveal).
## Interactive mouse parallax is disabled by default and enabled only on Home.
const ArtLayerShader = preload("res://shaders/paper_atlas_art_layer.gdshader")
const HeightShader = preload("res://shaders/paper_atlas_height.gdshader")
const LayerShader = preload("res://shaders/paper_atlas_layer.gdshader")
const Grain = preload("res://assets/ui/paper_aux_v1/torn_note_v1.png")
const CACHE_SIZE := Vector2i(768, 512)
const COLORS := [Color("ddccaa"), Color("bcbf88"), Color("8f9f78"), Color("b4a17d"), Color("8f826c"), Color("eee2c6")]
const LEVELS := [0.08, 0.13, 0.24, 0.37, 0.49, 0.61]

var hero := false
var interactive_parallax := false
var cache_size := CACHE_SIZE
var reveal := 1.0:
	set(value):
		reveal = clampf(value, 0.0, 1.0)
		_apply_reveal_and_motion()

var _state: Dictionary = {}
var _height_view: SubViewport
var _height_mat: ShaderMaterial
var _layers: Array[TextureRect] = []
var _layer_views: Array[SubViewport] = []
var _delay: Timer
var _generation := 0
var _parallax := Vector2.ZERO
var _hero_rect: TextureRect
var _hero_mat: ShaderMaterial
var _island_canvas: Control
var _piece_entries: Array[Dictionary] = []
var _ready_layers := false
var _authored := false
var _art_texture: Texture2D
var _art_nhao_texture: Texture2D
var _two_continent_texture: Texture2D
var _two_continent_nhao_texture: Texture2D
var _cloud_noise_texture: Texture2D


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_delay = Timer.new()
	_delay.one_shot = true
	_delay.wait_time = UITokens.MENU_PREVIEW_DEBOUNCE
	add_child(_delay)
	_delay.timeout.connect(_rebuild)
	resized.connect(_layout_layers)
	visibility_changed.connect(func() -> void:
		set_process(is_visible_in_tree())
		_apply_reveal_and_motion()
	)
	if ResourceLoader.exists("res://assets/ui/menu_atlas_v1/cloud_noise_v1.png"):
		_cloud_noise_texture = load("res://assets/ui/menu_atlas_v1/cloud_noise_v1.png")
	if hero and ResourceLoader.exists("res://assets/ui/menu_atlas_v1/hero_atlas_v1.png"):
		_hero_rect = TextureRect.new()
		_hero_rect.texture = load("res://assets/ui/menu_atlas_v1/hero_atlas_v1.png")
		_hero_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_hero_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_hero_rect.mouse_filter = MOUSE_FILTER_IGNORE
		_hero_mat = ShaderMaterial.new()
		_hero_mat.shader = ArtLayerShader
		_hero_mat.set_shader_parameter("layer_kind", 5)
		_hero_mat.set_shader_parameter("uv_inset", 1.03)
		if ResourceLoader.exists("res://assets/ui/menu_atlas_v1/hero_atlas_v1_nhao.png"):
			_hero_mat.set_shader_parameter("nhao_tex", load("res://assets/ui/menu_atlas_v1/hero_atlas_v1_nhao.png"))
			_hero_mat.set_shader_parameter("has_nhao", 1.0)
		if _cloud_noise_texture != null:
			_hero_mat.set_shader_parameter("cloud_noise_tex", _cloud_noise_texture)
		_hero_rect.material = _hero_mat
		add_child(_hero_rect)
		_ready_layers = true
	elif ResourceLoader.exists("res://assets/ui/menu_atlas_v1/land_paper_v1.png"):
		_authored = true
		_art_texture = load("res://assets/ui/menu_atlas_v1/land_paper_v1.png")
		if ResourceLoader.exists("res://assets/ui/menu_atlas_v1/land_paper_v1_nhao.png"):
			_art_nhao_texture = load("res://assets/ui/menu_atlas_v1/land_paper_v1_nhao.png")
		if ResourceLoader.exists("res://assets/ui/menu_atlas_v1/hero_atlas_v1.png"):
			_two_continent_texture = load("res://assets/ui/menu_atlas_v1/hero_atlas_v1.png")
		if ResourceLoader.exists("res://assets/ui/menu_atlas_v1/hero_atlas_v1_nhao.png"):
			_two_continent_nhao_texture = load("res://assets/ui/menu_atlas_v1/hero_atlas_v1_nhao.png")
		_build_art_nodes()
		_rebuild()
	else:
		_build_cache_nodes()
		_rebuild()
	_layout_layers()
	_apply_reveal_and_motion()


func set_layout_state(state: Dictionary) -> void:
	var defaults := {
		"seed": 29,
		"num_continents": 2,
		"continent_size": 0.5,
		"sea_level": 0.5,
		"continent_spacing": 92,
		"island_amount": 38,
		"wetness": 55,
	}
	var geometry: Dictionary = {}
	for key in defaults:
		geometry[key] = state.get(key, defaults[key])
	if geometry == _state:
		return
	var first_build := _state.is_empty()
	_state = geometry
	if first_build or _delay == null or not is_inside_tree():
		_rebuild()
	else:
		_delay.start()


func _build_art_nodes() -> void:
	_island_canvas = Control.new()
	_island_canvas.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_island_canvas)


func _rebuild_art() -> void:
	if _island_canvas == null or _art_texture == null:
		return
	for child in _island_canvas.get_children():
		_island_canvas.remove_child(child)
		child.queue_free()
	_piece_entries.clear()

	var count := clampi(int(_state.get("num_continents", 2)), 1, 8)
	var seed_val := int(_state.get("seed", 29))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var spacing := clampf(float(_state.get("continent_spacing", 92)) * 0.01, 0.2, 1.0)
	var sea := clampf(float(_state.get("sea_level", 0.5)), 0.1, 0.8)
	var cont_size := clampf(float(_state.get("continent_size", 0.5)), 0.2, 0.9)
	var island_amt := clampf(float(_state.get("island_amount", 38)) * 0.01, 0.0, 1.0)
	var wetness := clampf(float(_state.get("wetness", 55)) * 0.01, 0.0, 1.0)

	var base_scale := clampf(0.92 - (sea - 0.5) * 0.36 + (cont_size - 0.5) * 0.24, 0.62, 1.06)
	var placements: Array[Dictionary] = []

	if count == 1:
		var main_sz := Vector2(0.82, 0.88) * base_scale
		placements.append({
			"center": Vector2(0.50 + rng.randf_range(-0.02, 0.02), 0.50 + rng.randf_range(-0.02, 0.02)),
			"size": main_sz,
			"rot": deg_to_rad(rng.randf_range(-5.0, 5.0)),
			"flip_h": seed_val % 2 == 0,
			"flip_v": false,
			"tint": Vector3(1.0, 1.0, 1.0),
			"time_ofs": 0.0,
		})
	elif count == 2 and _two_continent_texture != null:
		var spread_scale := lerpf(0.86, 1.04, spacing)
		var main_sz := Vector2(0.88 * spread_scale, 0.90) * base_scale
		placements.append({
			"tex": _two_continent_texture,
			"center": Vector2(0.50 + rng.randf_range(-0.015, 0.015), 0.50 + rng.randf_range(-0.015, 0.015)),
			"size": main_sz,
			"rot": deg_to_rad(rng.randf_range(-4.5, 4.5)),
			"flip_h": seed_val % 2 == 1,
			"flip_v": (seed_val / 3) % 2 == 1,
			"tint": Vector3(1.0, 1.0, 1.0),
			"time_ofs": 0.0,
		})
	elif count == 2:
		var spread_x := lerpf(0.21, 0.27, spacing)
		var spread_y := rng.randf_range(-0.03, 0.03)
		var left_sz := Vector2(0.49, 0.76) * base_scale
		var right_sz := Vector2(0.51, 0.78) * base_scale
		placements.append({
			"center": Vector2(0.50 - spread_x, 0.49 + spread_y),
			"size": left_sz,
			"rot": deg_to_rad(-8.0 + rng.randf_range(-4.0, 4.0)),
			"flip_h": seed_val % 2 == 0,
			"flip_v": false,
			"tint": Vector3(0.98, 1.02, 0.98),
			"time_ofs": 0.0,
		})
		placements.append({
			"center": Vector2(0.50 + spread_x, 0.51 - spread_y),
			"size": right_sz,
			"rot": deg_to_rad(9.0 + rng.randf_range(-4.0, 4.0)),
			"flip_h": seed_val % 2 != 0,
			"flip_v": (seed_val / 3) % 2 == 1,
			"tint": Vector3(1.03, 0.98, 0.95),
			"time_ofs": 2.3,
		})
	elif count <= 4:
		var anchors := [
			Vector2(0.28, 0.34),
			Vector2(0.73, 0.32),
			Vector2(0.27, 0.70),
			Vector2(0.72, 0.69),
		]
		if count == 3:
			anchors = [
				Vector2(0.27, 0.38),
				Vector2(0.74, 0.35),
				Vector2(0.51, 0.71),
			]
		for i in range(count):
			var anchor: Vector2 = anchors[i]
			var center := (anchor - Vector2(0.5, 0.5)) * lerpf(0.78, 1.04, spacing) + Vector2(0.5, 0.5)
			center += Vector2(rng.randf_range(-0.025, 0.025), rng.randf_range(-0.025, 0.025))
			var piece_sz := Vector2(0.39, 0.48) * base_scale * (0.94 + float(i % 2) * 0.08)
			placements.append({
				"center": center,
				"size": piece_sz,
				"rot": deg_to_rad(float(((seed_val + i * 11) % 29) - 14)),
				"flip_h": (seed_val + i) % 2 == 0,
				"flip_v": (seed_val + i) % 3 == 0,
				"tint": Vector3(0.97 + float(i % 2) * 0.05, 1.02 - float(i % 2) * 0.03, 0.97),
				"time_ofs": float(i) * 1.6,
			})
	else:
		# 群岛 / 多岛链布局：错落有致的主岛与星罗棋布的岛链
		var arch_anchors := [
			Vector2(0.23, 0.32), Vector2(0.52, 0.25), Vector2(0.79, 0.34),
			Vector2(0.35, 0.56), Vector2(0.65, 0.54),
			Vector2(0.22, 0.74), Vector2(0.50, 0.76), Vector2(0.78, 0.72),
		]
		var total_islands := clampi(count + int(round(island_amt * 2.0)), 6, 8)
		for i in range(total_islands):
			var anchor: Vector2 = arch_anchors[i % arch_anchors.size()]
			var center := (anchor - Vector2(0.5, 0.5)) * lerpf(0.80, 1.05, spacing) + Vector2(0.5, 0.5)
			center += Vector2(rng.randf_range(-0.03, 0.03), rng.randf_range(-0.03, 0.03))
			var size_mult := 0.85 if (i == 1 or i == 3 or i == 4) else 0.62
			var piece_sz := Vector2(0.32, 0.39) * base_scale * size_mult
			placements.append({
				"center": center,
				"size": piece_sz,
				"rot": deg_to_rad(float(((seed_val + i * 17) % 41) - 20)),
				"flip_h": (seed_val + i) % 2 == 0,
				"flip_v": (seed_val + i * 2) % 3 == 0,
				"tint": Vector3(0.96 + float(i % 3) * 0.03, 1.02 - float(i % 2) * 0.02, 0.98),
				"time_ofs": float(i) * 1.1,
			})

	var wet_tint := Vector3(lerpf(1.04, 0.96, wetness), lerpf(0.95, 1.04, wetness), 1.0)
	for entry in placements:
		var piece := TextureRect.new()
		piece.texture = entry.get("tex", _art_texture) as Texture2D
		piece.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		piece.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if entry.has("tex") else TextureRect.STRETCH_SCALE
		piece.mouse_filter = MOUSE_FILTER_IGNORE
		piece.flip_h = bool(entry.flip_h)
		piece.flip_v = bool(entry.flip_v)
		var mat := ShaderMaterial.new()
		mat.shader = ArtLayerShader
		mat.set_shader_parameter("layer_kind", 5)
		mat.set_shader_parameter("uv_inset", 1.06)
		var nhao_map: Texture2D = _two_continent_nhao_texture if entry.has("tex") else _art_nhao_texture
		if nhao_map != null:
			mat.set_shader_parameter("nhao_tex", nhao_map)
			mat.set_shader_parameter("has_nhao", 1.0)
		if _cloud_noise_texture != null:
			mat.set_shader_parameter("cloud_noise_tex", _cloud_noise_texture)
		mat.set_shader_parameter("flip_x_sign", -1.0 if piece.flip_h else 1.0)
		mat.set_shader_parameter("flip_y_sign", -1.0 if piece.flip_v else 1.0)
		var t_vec: Vector3 = entry.tint * wet_tint
		mat.set_shader_parameter("tint_shift", t_vec)
		mat.set_shader_parameter("time_offset", float(entry.time_ofs))
		piece.material = mat
		_island_canvas.add_child(piece)
		_piece_entries.append({
			"node": piece,
			"mat": mat,
			"center": entry.center,
			"size": entry.size,
			"rot": entry.rot,
		})

	_ready_layers = true
	_layout_layers()
	_apply_reveal_and_motion()


func _apply_reveal_and_motion() -> void:
	var motion := 0.0 if UIAnimation.reduced_motion() else 1.0
	if _hero_mat != null:
		_hero_mat.set_shader_parameter("reveal_progress", reveal)
		_hero_mat.set_shader_parameter("motion_scale", motion)
	if _hero_rect != null:
		_hero_rect.modulate.a = clampf(0.35 + reveal * 0.65, 0.0, 1.0)
	for item in _piece_entries:
		var mat := item.get("mat") as ShaderMaterial
		var node := item.get("node") as TextureRect
		if mat != null:
			mat.set_shader_parameter("reveal_progress", reveal)
			mat.set_shader_parameter("motion_scale", motion)
		if node != null:
			node.modulate.a = clampf(0.40 + reveal * 0.60, 0.0, 1.0)


func _build_cache_nodes() -> void:
	_height_view = _make_view()
	_height_mat = ShaderMaterial.new()
	_height_mat.shader = HeightShader
	var canvas := ColorRect.new()
	canvas.size = Vector2(cache_size)
	canvas.material = _height_mat
	_height_view.add_child(canvas)
	for i in LEVELS.size():
		var view := _make_view()
		var material_layer := ShaderMaterial.new()
		material_layer.shader = LayerShader
		material_layer.set_shader_parameter("height_map", _height_view.get_texture())
		material_layer.set_shader_parameter("paper_grain", Grain)
		material_layer.set_shader_parameter("threshold", LEVELS[i])
		material_layer.set_shader_parameter("paper_color", COLORS[i])
		material_layer.set_shader_parameter("pixel", Vector2.ONE / Vector2(cache_size))
		var surface := ColorRect.new()
		surface.size = Vector2(cache_size)
		surface.material = material_layer
		view.add_child(surface)
		_layer_views.append(view)
		var layer := TextureRect.new()
		var cropped := AtlasTexture.new()
		cropped.atlas = view.get_texture()
		cropped.region = Rect2(Vector2.ZERO, Vector2(cache_size))
		cropped.filter_clip = true
		layer.texture = cropped
		layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		layer.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(layer)
		_layers.append(layer)


func _make_view() -> SubViewport:
	var view := SubViewport.new()
	view.size = cache_size
	view.transparent_bg = true
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(view)
	return view


func _rebuild() -> void:
	if _authored:
		_rebuild_art()
		return
	if _height_mat == null:
		return
	_generation += 1
	var generation := _generation
	_height_mat.set_shader_parameter("seed_val", float(int(_state.get("seed", 29)) % 10000))
	_height_mat.set_shader_parameter("num_continents", int(_state.get("num_continents", 2)))
	for key in ["continent_size", "sea_level"]:
		_height_mat.set_shader_parameter(key, float(_state.get(key, 0.5)))
	for key in ["continent_spacing", "island_amount"]:
		_height_mat.set_shader_parameter(key, float(_state.get(key, 50)) / 100.0)
	_height_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	if generation != _generation:
		return
	for view in _layer_views:
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_ready_layers = true


func _layout_layers() -> void:
	var target_aspect := 1.52
	var canvas_size := Vector2(minf(size.x, size.y * target_aspect), minf(size.y, size.x / target_aspect))
	var origin := (size - canvas_size) * 0.5
	if _island_canvas != null:
		_island_canvas.size = canvas_size
		_island_canvas.position = origin
		for item in _piece_entries:
			var piece := item.get("node") as TextureRect
			if piece == null:
				continue
			var rel_size: Vector2 = item.get("size", Vector2(0.5, 0.5))
			var rel_center: Vector2 = item.get("center", Vector2(0.5, 0.5))
			var px_size := Vector2(canvas_size.x * rel_size.x, canvas_size.y * rel_size.y)
			var px_center := Vector2(canvas_size.x * rel_center.x, canvas_size.y * rel_center.y)
			piece.size = px_size
			piece.pivot_offset = px_size * 0.5
			piece.position = px_center - px_size * 0.5
			piece.rotation = float(item.get("rot", 0.0))
	for layer in _layers:
		layer.size = canvas_size
		layer.position = origin
	if _hero_rect != null:
		_hero_rect.size = size
		_hero_rect.position = Vector2.ZERO


func _process(delta: float) -> void:
	var reduced := UIAnimation.reduced_motion()
	var allow_parallax := interactive_parallax and not reduced
	var target := Vector2.ZERO
	if allow_parallax and size.x > 1.0 and size.y > 1.0:
		target = (get_local_mouse_position() / size - Vector2(0.5, 0.5)).clamp(Vector2(-0.5, -0.5), Vector2(0.5, 0.5)) * 2.0
	_parallax = _parallax.lerp(target, minf(delta * 4.5, 1.0))

	var target_aspect := 1.52
	var canvas_size := Vector2(minf(size.x, size.y * target_aspect), minf(size.y, size.x / target_aspect))
	var origin := (size - canvas_size) * 0.5
	if _island_canvas != null:
		_island_canvas.position = origin + _parallax * 4.0
	for i in _layers.size():
		_layers[i].position = origin + _parallax * float(i + 1) * 1.5
		_layers[i].modulate.a = clampf(reveal * float(LEVELS.size() + 1) - float(i), 0.0, 1.0) if _ready_layers else 0.0
	if _hero_rect != null:
		_hero_rect.position = _parallax * 5.0
