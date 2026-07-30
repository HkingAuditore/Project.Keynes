# data_overlay_layer.gd
# 独立挂载在 WorldRoot 下的数据热力图节点，与 HexRenderer 的 WorldQuad 解耦：
#   - 自己维护一个 MeshInstance2D（四顶点 quad，尺寸与 world_bounds 一致）
#   - 自己维护一个 ShaderMaterial（shaders/data_overlay.gdshader）
#   - legacy 调试路径使用 set_data_texture；玩家路径使用 configure_cell_lut /
#     set_cell_lut_texture，以静态索引 atlas 间接读取动态 per-cell LUT
#   - overlay_mode == NONE 时整个节点 visible=false，0 shader 开销
#
# z_index:
#   WorldQuad             = 0
#   DataOverlayLayer      = 5  ← 本节点，覆盖在地形之上
#   CellHighlight         = 10
#   WeatherOverlay        = 15（若存在）
class_name DataOverlayLayer
extends Node2D

const SHADER_PATH: String = "res://shaders/data_overlay.gdshader"

var _mesh_inst: MeshInstance2D
var _shader_mat: ShaderMaterial
var _bounds: Rect2 = Rect2()
var _wrap_period_x: float = 0.0
var _mode: int = 0
var _alpha: float = 0.7
var _has_valid_shader: bool = false
var _has_valid_texture: bool = false
var _use_cell_lut: bool = false
var _transition: Tween
var _visual_tiles = null

func _ready() -> void:
	# z_index=5：盖在 WorldQuad（默认 0）之上，但低于 CellHighlight(10)。
	# top_level=true：与 HexRenderer / CellHighlight 一致——它们都使用
	# **绝对世界坐标**几何，由 Camera2D 全局变换。本节点的 quad 顶点也是
	# 世界坐标（来自 HexRenderer.get_world_bounds()），必须 top_level=true
	# 才能与地形重合，否则会被 WorldRoot 的二次变换错位。
	z_index = 5
	top_level = true
	visible = false
	_ensure_nodes()

func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "OverlayQuad"
	# 给 MeshInstance2D.texture 也绑一张占位贴图：MeshInstance2D 在没
	# texture 时 canvas_item 默认采样会回退为不透明白色（与 ShaderMaterial
	# 同时使用时，部分驱动会在 shader 输出与 albedo 之间相乘，导致整屏白）。
	_mesh_inst.texture = DataOverlayBaker.get_empty_texture()
	add_child(_mesh_inst)

	var sh: Shader = load(SHADER_PATH) as Shader
	if sh == null:
		push_warning("DataOverlayLayer: failed to load shader '%s'; overlay disabled" % SHADER_PATH)
		_has_valid_shader = false
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = sh
	_shader_mat.set_shader_parameter("overlay_mode", _mode)
	_shader_mat.set_shader_parameter("base_alpha", _alpha)
	_shader_mat.set_shader_parameter("wrap_origin_x", 0.0)
	_shader_mat.set_shader_parameter("wrap_period_x", _wrap_period_x)
	# 即使还没有纹理，提供一张 1×1 占位避免 null uniform 警告
	_shader_mat.set_shader_parameter("overlay_tex", DataOverlayBaker.get_empty_texture())
	_shader_mat.set_shader_parameter("map_index_atlas", DataOverlayBaker.get_empty_texture())
	_shader_mat.set_shader_parameter("overlay_lut", DataOverlayBaker.get_empty_texture())
	_shader_mat.set_shader_parameter("lut_dims", Vector2(1.0, 1.0))
	_shader_mat.set_shader_parameter("use_cell_lut", false)
	_mesh_inst.material = _shader_mat
	_has_valid_shader = true

# 设置世界坐标下的可见矩形（= HexRenderer.get_world_bounds()）。
# 调用方通常在首次生成地图与 regenerate 后调用一次。
func set_bounds(bounds: Rect2) -> void:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	_bounds = bounds
	_ensure_nodes()
	if _mesh_inst == null:
		return
	_mesh_inst.mesh = _build_quad_mesh(bounds, _wrap_period_x)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("world_origin", bounds.position)
		_shader_mat.set_shader_parameter("world_size", bounds.size)
		_shader_mat.set_shader_parameter("wrap_origin_x", 0.0)
		_shader_mat.set_shader_parameter("wrap_period_x", _wrap_period_x)
	_update_visibility()

func set_horizontal_wrap(period_x: float) -> void:
	_wrap_period_x = maxf(0.0, period_x)
	if _bounds.size.x > 0.0 and _mesh_inst != null:
		_mesh_inst.mesh = _build_quad_mesh(_bounds, _wrap_period_x)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("wrap_origin_x", 0.0)
		_shader_mat.set_shader_parameter("wrap_period_x", _wrap_period_x)

func set_mode(mode: int) -> void:
	_mode = mode
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("overlay_mode", mode)
	_update_visibility()

func set_alpha(v: float) -> void:
	_alpha = clampf(v, 0.0, 1.0)
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("base_alpha", _alpha)

func set_data_texture(tex: Texture2D) -> void:
	if _shader_mat == null:
		return
	if tex == null:
		_shader_mat.set_shader_parameter("overlay_tex", DataOverlayBaker.get_empty_texture())
		_has_valid_texture = false
	else:
		_shader_mat.set_shader_parameter("overlay_tex", tex)
		_has_valid_texture = true
	_update_visibility()

## Configures the player-facing indirect backend. The atlas is static for the
## world lifetime; only overlay_lut is subsequently updated.
func configure_cell_lut(map_index_atlas: Texture2D, lut_dims: Vector2i) -> void:
	_ensure_nodes()
	if _shader_mat == null:
		return
	if not _visual_tiles_active():
		_shader_mat.set_shader_parameter(
			"map_index_atlas",
			map_index_atlas if map_index_atlas != null else DataOverlayBaker.get_empty_texture()
		)
	_shader_mat.set_shader_parameter(
		"lut_dims",
		Vector2(maxi(1, lut_dims.x), maxi(1, lut_dims.y))
	)
	_use_cell_lut = (_visual_tiles_active() or map_index_atlas != null) \
		and lut_dims.x > 0 and lut_dims.y > 0
	_shader_mat.set_shader_parameter("use_cell_lut", _use_cell_lut)
	_update_visibility()


func configure_visual_tiles(tiles) -> void:
	var was_tiled := _visual_tiles_active()
	_visual_tiles = tiles
	var is_tiled := _visual_tiles_active()
	_ensure_nodes()
	if _shader_mat == null:
		return
	if was_tiled != is_tiled:
		var shader := ResourceLoader.load(SHADER_PATH, "Shader",
			ResourceLoader.CACHE_MODE_IGNORE) as Shader
		if shader != null:
			if is_tiled:
				shader = shader.duplicate() as Shader
				shader.code = "#define MAP_VISUAL_TILED\n" + shader.code
			_shader_mat.shader = shader
	_push_visual_tile_uniforms()


func _visual_tiles_active() -> bool:
	return _visual_tiles != null and bool(_visual_tiles.ready) \
		and String(_visual_tiles.layout.mode) == "tiled"


func _push_visual_tile_uniforms() -> void:
	if _shader_mat == null or not _visual_tiles_active():
		return
	var layout = _visual_tiles.layout
	_shader_mat.set_shader_parameter("visual_map_index_tiles", _visual_tiles.map_index)
	_shader_mat.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	_shader_mat.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	_shader_mat.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	_shader_mat.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	_shader_mat.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	_shader_mat.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	_shader_mat.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))

func set_cell_lut_texture(tex: Texture2D) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(
		"overlay_lut",
		tex if tex != null else DataOverlayBaker.get_empty_texture()
	)
	_has_valid_texture = tex != null
	_update_visibility()

func show_mode_animated(mode: int, duration: float = 0.15) -> void:
	if _transition != null and _transition.is_valid():
		_transition.kill()
	if _mode == mode and visible:
		modulate.a = 1.0
		return
	set_mode(mode)
	modulate.a = 0.0
	_transition = create_tween()
	_transition.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_transition.tween_property(self, "modulate:a", 1.0, maxf(0.01, duration))

func hide_animated(duration: float = 0.12) -> void:
	if _transition != null and _transition.is_valid():
		_transition.kill()
	_transition = create_tween()
	_transition.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_transition.tween_property(self, "modulate:a", 0.0, maxf(0.01, duration))
	_transition.tween_callback(force_disable)

func get_mode() -> int:
	return _mode

func get_alpha() -> float:
	return _alpha

# 让 main.gd 统计 overlay 帧开销时可以一键关掉。shader 错误回退也走这里。
func force_disable() -> void:
	_mode = 0
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("overlay_mode", 0)
	modulate.a = 1.0
	_update_visibility()

# --- 内部 -----------------------------------------------------

func _update_visibility() -> void:
	# NONE 或纹理无效 / shader 无效时，直接隐藏以省掉 fragment 计算。
	var should_show: bool = _has_valid_shader \
		and _mode != 0 \
		and _has_valid_texture \
		and _bounds.size.x > 0.0 \
		and _bounds.size.y > 0.0
	visible = should_show

func _build_quad_mesh(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	# 与 HexRenderer._build_world_quad_mesh 尺寸一致，但额外带 UV，
	# 方便 data_overlay.gdshader 直接通过 UV 采样数据纹理，避免每像素
	# 再算一次 (world_pos - origin) / size。
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var tile_offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for ox in tile_offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		uvs.append_array(PackedVector2Array([
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
			Vector2(1.0, 1.0),
			Vector2(0.0, 1.0),
		]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
