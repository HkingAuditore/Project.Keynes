extends Node2D
class_name MilitaryAreaLayer

## z=6 军事控制区域层：选中部队的任务区外圈虚线带。
##
## 几何完全复用 CountryBorderLayer 的逐边 ribbon 算法：对每条
## 「在区域内 / 不在区域内」的 hex 边，由**在区域内**的一侧生成一条朝内的
## 内缩梯形（外侧两点落在 hex 角上、内侧两点按 d·tan30° 收短），相邻两条
## ribbon 在角点处顶点重合，围成的环没有缝也没有交叉。
##
## 差别只在材质：country_border 是实线国色，这里是铅笔虚线（military_area_dash）。
## ribbon 宽度按 hex_size 烘死，实际线宽由 shader uniform 裁，缩放只推 uniform。
##
## 区域来源：get_military_render_snapshot 的 selected_army 对应的 area_cells
## （设计稿 §6.3 的区域任务，上限 256 格）。区域变化才重建 mesh。

const SHADER_PATH: String = "res://shaders/military_area_dash.gdshader"
const Z_INDEX := 6
const RIBBON_WIDTH_RATIO := 0.62
const MITER_INSET_RATIO := 0.57735027
const OUTER_BLEED_RATIO := 0.18
const AREA_CAP := 256

var _mesh_inst: MeshInstance2D
var _material: ShaderMaterial
var _has_shader := false
var _enabled := true

var _map
var _hex_size := 22.0
var _wrap := 0.0
var _ribbon_width := 11.0
var _area_stamp := PackedInt32Array()
var _area_stamp_id := 0
var _area_cells := PackedInt32Array()
var _neighbors := PackedInt32Array()
var _cell_count := 0
var _corner_country: PackedInt32Array = PackedInt32Array()
var _dirty := true
var _player_slot := -1
var _last_pushed_world_width := -1.0
var _wall_time := 0.0
var _stats := {"edges": 0, "vertices": 0, "rebuilds": 0, "rebuild_usec": 0}
## 退化边计数（邻格索引越界 / 邻格无法反查时退回角点公式的出线数）。
var _degenerate_edges := 0
var _corners := PackedVector2Array()
var _edge_scratch := PackedVector2Array()
## 每格中心的规范世界坐标（x, y 交错）。区域重建时刷新一次，
## per-cell 循环里不再做 cube_to_world + cell_at 的重复开销。
var _center_cache := PackedFloat32Array()


func _ready() -> void:
	z_index = Z_INDEX
	top_level = true
	visible = false
	_ensure_nodes()
	set_process(true)


func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "AreaRibbon"
	_mesh_inst.texture = CountryBorderLayer.get_white_texture()
	add_child(_mesh_inst)
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("MilitaryAreaLayer: missing shader %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("ribbon_world_width", _ribbon_width)
	_material.set_shader_parameter("area_world_width", 3.0)
	_mesh_inst.material = _material
	_has_shader = true


func configure(map, hex_size: float, wrap_period_x: float) -> void:
	_ensure_nodes()
	_map = map
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	_ribbon_width = _hex_size * RIBBON_WIDTH_RATIO
	_cell_count = map.cell_count() if map != null else 0
	_neighbors = map.neighbor_indices_packed() if map != null else PackedInt32Array()
	_area_stamp.resize(_cell_count)
	_area_stamp.fill(0)
	_area_stamp_id = 0
	_degenerate_edges = 0
	if _material != null:
		_material.set_shader_parameter("ribbon_world_width", _ribbon_width)
		_material.set_shader_parameter("wrap_period_x", _wrap)
	_dirty = true


func set_player_slot(slot: int) -> void:
	_player_slot = slot


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func clear() -> void:
	_area_cells = PackedInt32Array()
	_area_stamp.fill(0)
	_area_stamp_id = 0
	if _mesh_inst != null:
		_mesh_inst.mesh = null
	_update_visibility()


## 来自 feed 的 selected_area_cells。只比较引用与长度，避免每帧深比较。
## 同一 Packed 引用（feed 未刷新）直接跳过，不需要逐元素比较。
func set_area(cells: PackedInt32Array) -> void:
	if cells == _area_cells:
		return
	if cells.size() == _area_cells.size():
		var same := true
		for i in cells.size():
			if cells[i] != _area_cells[i]:
				same = false
				break
		if same:
			_area_cells = cells
			return
	_area_cells = cells.duplicate()
	if _area_cells.size() > AREA_CAP:
		_area_cells.resize(AREA_CAP)
	_dirty = true


func has_area() -> bool:
	return _area_cells.size() > 0


func _process(delta: float) -> void:
	_wall_time += delta
	if _material == null:
		return
	# 第一帧就可能已经有区域（configure 后立刻 set_area）：不能等 _dirty 之外的东西。
	if _dirty or (_area_cells.size() > 0 and _mesh_inst.mesh == null):
		_rebuild()
	if not visible:
		return
	_material.set_shader_parameter("wall_seconds", _wall_time)
	_push_line_width()


func _push_line_width() -> void:
	if _material == null:
		return
	var zoom := 1.0
	var vp := get_viewport()
	if vp != null:
		zoom = maxf(0.0001, vp.get_canvas_transform().get_scale().x)
	var screen := 3.0 * pow(zoom, 0.36)
	screen = clampf(screen, 1.8, 7.0)
	var world_width := clampf(screen / zoom, 0.3, _ribbon_width)
	if absf(world_width - _last_pushed_world_width) < 0.001:
		return
	_last_pushed_world_width = world_width
	_material.set_shader_parameter("area_world_width", world_width)


func _rebuild() -> void:
	_dirty = false
	if _map == null or _mesh_inst == null or _area_cells.is_empty() or _cell_count <= 0:
		if _mesh_inst != null:
			_mesh_inst.mesh = null
		_update_visibility()
		return
	var started := Time.get_ticks_usec()
	# stamp 复用：不清空 packed array，只 bump 代数。
	_area_stamp_id += 1
	if _area_stamp_id == 0x7FFFFFFF:
		_area_stamp.fill(0)
		_area_stamp_id = 1
	for cell in _area_cells:
		if cell >= 0 and cell < _cell_count:
			_area_stamp[cell] = _area_stamp_id

	var corners := PackedVector2Array()
	corners.resize(6)
	for i in 6:
		var ang := deg_to_rad(60.0 * float(i) - 30.0)
		corners[i] = Vector2(cos(ang), sin(ang)) * _hex_size
	_corners = corners
	var offsets := PackedFloat32Array([0.0])
	if _wrap > 0.0001:
		offsets = PackedFloat32Array([-_wrap, 0.0, _wrap])
	var miter := _ribbon_width * MITER_INSET_RATIO
	var bleed := _ribbon_width * OUTER_BLEED_RATIO
	var bleed_miter := bleed * MITER_INSET_RATIO
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var owner_color := CountryBorderLayer.country_color(
		_player_slot, _player_slot, Color(0.90, 0.73, 0.38))
	var edges := 0
	var nb := _neighbors
	var stamp := _area_stamp_id
	_center_cache.resize(_cell_count * 2)
	for cell in _area_cells:
		if cell < 0 or cell >= _cell_count:
			continue
		var obj = _map.cell_at(cell)
		if obj != null:
			var c := HexUtils.cube_to_world(obj.q, obj.r, _hex_size)
			_center_cache[cell * 2] = c.x
			_center_cache[cell * 2 + 1] = c.y

	for ox in offsets:
		var shift := Vector2(float(ox), 0.0)
		for cell in _area_cells:
			if cell < 0 or cell >= _cell_count:
				continue
			var base_n := cell * 6
			var cell_obj = _map.cell_at(cell)
			if cell_obj == null:
				continue
			for d in 6:
				var neighbor: int = nb[base_n + d] if base_n + d < nb.size() else -1
				if neighbor >= 0 and neighbor < _cell_count \
						and _area_stamp[neighbor] == stamp:
					continue
				var edge := _hex_edge(cell_obj, neighbor, d)
				var p0: Vector2 = edge[0] + shift
				var p1: Vector2 = edge[1] + shift
				var mid: Vector2 = (p0 + p1) * 0.5
				var center: Vector2 = edge[2] + shift
				var edge_vec := p1 - p0
				var edge_len := edge_vec.length()
				if edge_len < 0.0001:
					continue
				var along := edge_vec / edge_len
				var inward := (center - mid).normalized()
				var inset := inward * _ribbon_width
				var out_off := inward * bleed
				var a0 := p0 - out_off - along * bleed_miter
				var a1 := p1 - out_off + along * bleed_miter
				var b0 := p0 + inset + along * miter
				var b1 := p1 + inset - along * miter
				var seed := _edge_seed(cell, d)
				var vcol := Color(owner_color.r, owner_color.g, owner_color.b, seed)
				var base_v := verts.size()
				verts.append(a0)
				verts.append(a1)
				verts.append(b1)
				verts.append(b0)
				uvs.append(Vector2(-bleed_miter, -bleed))
				uvs.append(Vector2(edge_len + bleed_miter, -bleed))
				uvs.append(Vector2(edge_len - miter, _ribbon_width))
				uvs.append(Vector2(miter, _ribbon_width))
				for _k in 4:
					colors.append(vcol)
				indices.append_array(PackedInt32Array([
					base_v, base_v + 1, base_v + 2,
					base_v, base_v + 2, base_v + 3,
				]))
				edges += 1

	var per_copy := maxi(1, offsets.size())
	if verts.is_empty():
		_mesh_inst.mesh = null
		_update_visibility()
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_inst.mesh = mesh
	_stats["edges"] = edges / per_copy
	_stats["vertices"] = verts.size()
	_stats["rebuilds"] = int(_stats["rebuilds"]) + 1
	_stats["rebuild_usec"] = Time.get_ticks_usec() - started
	_last_pushed_world_width = -1.0
	_update_visibility()


## 取本格朝 dir 方向那条 hex 边的两个世界端点 (p0, p1) 与本格中心。
## 方向枚举约定（HexUtils.CUBE_DIRECTIONS: E, NE, NW, W, SW, SE）与角点枚举
## 在历史上被混用过，所以这里**不用**索引公式，直接用邻格中心反查：
## 边端点 = 本格中心与邻格中心之间的两个角点（取距离相等且 < size 的两个）。
## 退化情况（越界邻格）退回角点公式，保证 wrap 接缝与图边也能出线。
func _hex_edge(cell_obj, neighbor: int, dir: int) -> PackedVector2Array:
	var center := HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
	var out := _edge_scratch
	out.resize(3)
	out[0] = Vector2(NAN, NAN)
	if neighbor >= 0 and neighbor < _cell_count:
		var nb_obj = _map.cell_at(neighbor)
		if nb_obj != null:
			# 邻格中心的规范坐标必须先折到本格最近镜像：wrap 接缝上邻格中心
			# 差了整整一个周期，直接用会把中点放到本格自己的一个角上。
			var n_center := HexUtils.cube_to_world(nb_obj.q, nb_obj.r, _hex_size)
			if _wrap > 0.0001:
				n_center = HexUtils.nearest_display_world(n_center, center.x, _wrap)
			var mid := (center + n_center) * 0.5
			var best0 := -1
			var best1 := -1
			var d0 := INF
			var d1 := INF
			for i in 6:
				var dist := ((center + _corners[i]) - mid).length()
				if dist < d0:
					d1 = d0
					best1 = best0
					d0 = dist
					best0 = i
				elif dist < d1:
					d1 = dist
					best1 = i
			# 两个端点与中点等距（容差覆盖浮点误差）即同一侧的边。
			if best0 >= 0 and best1 >= 0:
				if absf(d0 - d1) < _hex_size * 0.08:
					out[0] = center + _corners[best0]
					out[1] = center + _corners[best1]
					out[2] = center
					return out
				_degenerate_edges += 1
	# 退化：按 (6 - dir) % 6 的角点对出线。
	var va: int = (6 - dir) % 6
	out[0] = center + _corners[va]
	out[1] = center + _corners[(va + 1) % 6]
	out[2] = center
	return out


func _edge_seed(cell: int, dir: int) -> float:
	var h: int = (cell * 6 + dir) * 2654435761
	h = (h ^ (h >> 15)) & 0xFFFFFF
	return float(h) / 16777215.0


func _update_visibility() -> void:
	visible = _enabled and _has_shader and _area_cells.size() > 0 \
		and _mesh_inst != null and _mesh_inst.mesh != null


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visible"] = visible
	out["area_cells"] = _area_cells.size()
	out["degenerate_edges"] = _degenerate_edges
	return out
