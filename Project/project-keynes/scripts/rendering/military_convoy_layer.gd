extends Node2D
class_name MilitaryConvoyLayer

## z=9 军需车队层：补给车队在格间移动的俯视马车。
##
## 复用 TradeActivityLayer 的做法：一个 MultiMesh + 一个程序化车队 shader，
## CPU 只写实例自定义数据（国家、风险、种类、种子），本地推进完全在 GPU。
## 与贸易车队的区别：军需车队的目的地是明确的，因此额外画一条从当前位置到
## 目的地的虚线（同一个 MultiMesh 的车队实例 + 一个 Line2D 复用的路径段缓冲）。
##
## 迷雾：敌方车队只在 FOG_VISIBLE 格显示（设计稿 §8、§14.1）。
## 缩到 aggregate_zoom 以下整层隐藏（车队细节在远视角没有信息量）。

const SHADER_PATH: String = "res://shaders/military_convoy.gdshader"
const Z_INDEX := 9
const INSTANCE_CAP := 1024
const ROUTE_POINTS_CAP := 384

var _batch: MultiMeshInstance2D
var _material: ShaderMaterial
var _has_shader := false
var _enabled := true
var _map
var _camera: Camera2D
var _hex_size := 22.0
var _wrap := 0.0
var _player_slot := -1
var _camera_zoom := 1.0
var _aggregate_zoom := 0.30
var _wall_time := 0.0

var _count := 0
var _cur := PackedInt32Array()
var _dest := PackedInt32Array()
var _country := PackedInt32Array()
var _risk := PackedInt32Array()
var _visible_cells := PackedByteArray()
var _fog_active := false

var _routes: Line2D
var _route_points := PackedVector2Array()
var _stats := {"convoys": 0, "visible": 0}


func _ready() -> void:
	z_index = Z_INDEX
	top_level = true
	visible = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_ensure_nodes()
	set_process(true)


func _ensure_nodes() -> void:
	if _batch != null:
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("MilitaryConvoyLayer: missing shader %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = INSTANCE_CAP
	mm.visible_instance_count = 0
	_batch = MultiMeshInstance2D.new()
	_batch.name = "MilitaryConvoys"
	_batch.multimesh = mm
	_batch.texture = CountryBorderLayer.get_white_texture()
	_batch.material = _material
	add_child(_batch)
	# 路线虚线：车队 -> 目的地的一条短虚线，复用 Line2D 的轻量绘制。
	_routes = Line2D.new()
	_routes.name = "ConvoyRoutes"
	_routes.width = 1.6
	_routes.default_color = Color(0.80, 0.66, 0.34, 0.55)
	_routes.antialiased = true
	_routes.z_index = -1
	_routes.points = PackedVector2Array()
	add_child(_routes)
	_has_shader = true


func configure(map, camera: Camera2D, hex_size: float, wrap_period_x: float) -> void:
	_ensure_nodes()
	_map = map
	_camera = camera
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	if _material != null:
		_material.set_shader_parameter("wrap_period_x", _wrap)


func set_player_slot(slot: int) -> void:
	_player_slot = slot


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func clear() -> void:
	_count = 0
	if _batch != null:
		_batch.multimesh.visible_instance_count = 0
		_batch.visible = false
	if _routes != null:
		_routes.points = PackedVector2Array()


func set_convoys(current_cell: PackedInt32Array, dest_cell: PackedInt32Array,
		country_slot: PackedInt32Array, risk_q16: PackedInt32Array,
		visible_cells: PackedByteArray, fog_active: bool) -> void:
	_cur = current_cell
	_dest = dest_cell
	_country = country_slot
	_risk = risk_q16
	_visible_cells = visible_cells
	_fog_active = fog_active
	_count = mini(_cur.size(), INSTANCE_CAP)
	_refresh_instances()


func _visible(cell: int) -> bool:
	if not _fog_active or _visible_cells.is_empty():
		return true
	return cell >= 0 and cell < _visible_cells.size() and _visible_cells[cell] != 0


func _own(country_slot: int) -> bool:
	return _player_slot >= 0 and country_slot == _player_slot


func _cell_world(cell: int, ref_x: float) -> Vector2:
	var cell_obj = _map.cell_at(cell) if _map != null else null
	if cell_obj == null:
		return Vector2(NAN, NAN)
	var p := HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
	if _wrap > 0.0001 and not is_nan(ref_x):
		p = HexUtils.nearest_display_world(p, ref_x, _wrap)
	return p


func _refresh_instances() -> void:
	if _batch == null or _map == null:
		return
	var mm := _batch.multimesh
	var emitted := 0
	var ref_x := NAN
	if _camera != null and is_instance_valid(_camera):
		ref_x = _camera.global_position.x
	_route_points.clear()
	var size := _hex_size * 0.62
	for i in _count:
		var cur := _cur[i]
		if not _visible(cur):
			continue
		var pos := _cell_world(cur, ref_x)
		if is_nan(pos.x):
			continue
		var risk := 0.0
		if i < _risk.size():
			risk = clampf(float(_risk[i]) / 65536.0, 0.0, 1.0)
		var slot := _country[i] if i < _country.size() else -1
		var seed := float((cur * 2654435761 + i) & 0xFFFF) / 65535.0
		var tx := Transform2D(0.0, Vector2(size, size), 0.0, pos)
		mm.set_instance_transform_2d(emitted, tx)
		mm.set_instance_custom_data(emitted, Color(float(slot), risk, 0.0, seed))
		emitted += 1
		# 目的地虚线：车队 -> 目的地（只有两段，够读出行进方向）。
		if emitted <= ROUTE_POINTS_CAP / 2 and i < _dest.size() and _dest[i] >= 0 \
				and _visible(_dest[i]):
			var dst := _cell_world(_dest[i], pos.x)
			if not is_nan(dst.x):
				_route_points.append(pos)
				_route_points.append(dst)
	mm.visible_instance_count = emitted
	_routes.points = _route_points
	_routes.visible = not _route_points.is_empty()
	_stats["convoys"] = _count
	_stats["visible"] = emitted
	_update_visibility()


func _update_visibility() -> void:
	visible = _enabled and _has_shader and _batch != null and _batch.visible


func _process(delta: float) -> void:
	_wall_time += delta
	if _material == null:
		return
	var vp := get_viewport()
	if vp != null:
		_camera_zoom = maxf(0.0001, vp.get_canvas_transform().get_scale().x)
	if _camera_zoom < _aggregate_zoom:
		_batch.visible = false
		_routes.visible = false
		_update_visibility()
		return
	_batch.visible = _enabled
	_routes.visible = _enabled and not _route_points.is_empty()
	_material.set_shader_parameter("wall_seconds", _wall_time)
	_material.set_shader_parameter("reduced_motion", UIAnimation.reduced_motion())
	_material.set_shader_parameter("vehicle_world_size",
		minf(_hex_size * 0.62, 34.0 / maxf(0.01, _camera_zoom)))
	_material.set_shader_parameter("layer_alpha", smoothstep(_aggregate_zoom, 0.55, _camera_zoom))
	_update_visibility()


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visible_layer"] = visible
	out["camera_zoom"] = _camera_zoom
	return out
