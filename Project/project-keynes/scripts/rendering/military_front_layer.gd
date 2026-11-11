extends Node2D
class_name MilitaryFrontLayer

## z=8 战线层：接触边上的手绘锯齿带，颜色按推进进度渐变。
##
## 数据：get_military_render_snapshot 的 front_revision + front_edges
## （key = cell*6+dir，设计稿 §21.5 增量战线）。只有 front_revision 变化才重建。
##
## 几何：每条接触边生成一条**跨边**的 ribbon（两侧格各占一半），而不是
## CountryBorderLayer 那种单侧内缩梯形——战线是「两边都有的缝隙」，
## 跨边带才能在两侧都被迷雾/地形压住时仍然连续。ribbon 宽度按 hex_size 烘死，
## 实际线宽由 shader uniform 裁。
##
## 顶点属性：UV.x = 沿边世界距离，UV.y = 距中心线垂距，
## COLOR.rgb = 进度色（两端格的控制者色按进度混合），COLOR.a = per-edge 种子。

const SHADER_PATH: String = "res://shaders/military_front_ribbon.gdshader"
const FRONTIER_GRAIN: Texture2D = preload("res://assets/vfx/frontier_grain.png")
const Z_INDEX := 8
## 军务档案选中一条战线时的颜色（深朱砂）。线宽由 shader uniform 决定，
## per-edge 加宽会被裁掉，所以选中反馈走颜色通道。
const SELECTED_COLOR := Color(0.36, 0.11, 0.08)
const RIBBON_WIDTH_RATIO := 0.58
const OUTER_BLEED_RATIO := 0.22
const EDGE_CAP := 12288

var _mesh_inst: MeshInstance2D
var _material: ShaderMaterial
var _has_shader := false
var _enabled := true

var _map
var _hex_size := 22.0
var _wrap := 0.0
var _ribbon_width := 12.7
var _neighbors := PackedInt32Array()
var _cell_count := 0
var _owner_slot := PackedInt32Array()
var _player_slot := -1
var _edges := PackedInt32Array()
var _progress := PackedByteArray()
## key -> 在 _edges 里的下标。只在前线变化时重建；点击拾取与选中态共用。
var _edge_lookup: Dictionary = {}
## 军务档案选中的那条边（-1 = 无）。重新着色而不是加宽：shader 的线宽是
## uniform，per-edge 加宽会被裁掉，颜色是唯一诚实的通道。
var _selected_edge := -1
var _dirty := true
var _last_pushed_world_width := -1.0
var _wall_time := 0.0
var _stats := {"edges": 0, "vertices": 0, "rebuilds": 0, "rebuild_usec": 0}
var _corners := PackedVector2Array()


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
	_mesh_inst.name = "FrontRibbon"
	_mesh_inst.texture = CountryBorderLayer.get_white_texture()
	add_child(_mesh_inst)
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("MilitaryFrontLayer: missing shader %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("frontier_grain", FRONTIER_GRAIN)
	_material.set_shader_parameter("front_world_width", 4.2)
	_mesh_inst.material = _material
	_has_shader = true


func configure(map, hex_size: float, wrap_period_x: float, owner_slots: PackedInt32Array) -> void:
	_ensure_nodes()
	_map = map
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	_ribbon_width = _hex_size * RIBBON_WIDTH_RATIO
	_cell_count = map.cell_count() if map != null else 0
	_neighbors = map.neighbor_indices_packed() if map != null else PackedInt32Array()
	_owner_slot = owner_slots
	if _material != null:
		_material.set_shader_parameter("wrap_period_x", _wrap)
	_dirty = true


func set_owner_slots(owner_slots: PackedInt32Array) -> void:
	_owner_slot = owner_slots
	_dirty = true


func set_player_slot(slot: int) -> void:
	_player_slot = slot


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func clear() -> void:
	_edges = PackedInt32Array()
	_progress = PackedByteArray()
	_edge_lookup.clear()
	_selected_edge = -1
	if _mesh_inst != null:
		_mesh_inst.mesh = null
	_update_visibility()


## 来自 feed：只在 front_revision 变化时由 manager 调用。
func set_front_edges(keys: PackedInt32Array, progress: PackedByteArray) -> void:
	_edges = keys
	_progress = progress
	_edge_lookup.clear()
	var count := mini(keys.size(), EDGE_CAP)
	for i in count:
		_edge_lookup[int(keys[i])] = i
	if _selected_edge >= 0 and not _edge_lookup.has(_selected_edge):
		_selected_edge = -1
	_dirty = true


## 军务档案选中一条战线：只改颜色，不重建几何以外的东西。
func set_selected_edge(key: int) -> void:
	if key == _selected_edge:
		return
	_selected_edge = key
	_dirty = true


func selected_edge() -> int:
	return _selected_edge


## ── 点击拾取 ────────────────────────────────────────────────────────────
## 命中半径内最近的一条战线边（key = cell*6+dir，已规范化到较小格）；
## -1 = 未命中。只在点击时调用：候选是本格 + 6 邻格的 42 条边。
func pick_edge_at(world: Vector2, tolerance: float) -> int:
	if _map == null or _edge_lookup.is_empty() or world.x != world.x:
		return -1
	var cell_obj = HexUtils.world_to_wrapped_cell(_map, world, _hex_size)
	if cell_obj == null:
		return -1
	var origin := int(cell_obj.index)
	var cells := PackedInt32Array([origin])
	for dir in 6:
		var neighbor := _neighbor_of(origin, dir)
		if neighbor >= 0 and neighbor != origin:
			cells.append(neighbor)
	var best := -1
	var best_distance := maxf(tolerance, 0.0)
	var seen := {}
	for cell in cells:
		for dir in 6:
			var key := _canonical_edge_key(cell, dir)
			if key < 0 or seen.has(key) or not _edge_lookup.has(key):
				continue
			seen[key] = true
			var mid := edge_world_midpoint(key)
			if is_nan(mid.x):
				continue
			var distance := mid.distance_to(world)
			if distance <= best_distance:
				best_distance = distance
				best = key
	return best


## 一条战线边的世界中点（跨 wrap 时用最近镜像）。NaN = 该边不可定位。
func edge_world_midpoint(key: int) -> Vector2:
	if _map == null or key < 0:
		return Vector2(NAN, NAN)
	var cell: int = key / 6
	var dir: int = key % 6
	var neighbor := _neighbor_of(cell, dir)
	if neighbor < 0 or neighbor >= _cell_count:
		return Vector2(NAN, NAN)
	var cell_obj = _map.cell_at(cell)
	var nb_obj = _map.cell_at(neighbor)
	if cell_obj == null or nb_obj == null:
		return Vector2(NAN, NAN)
	var center: Vector2 = HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
	var n_center: Vector2 = HexUtils.cube_to_world(nb_obj.q, nb_obj.r, _hex_size)
	if _wrap > 0.0001:
		n_center = HexUtils.nearest_display_world(n_center, center.x, _wrap)
	return (center + n_center) * 0.5


func _neighbor_of(cell: int, dir: int) -> int:
	if cell < 0 or dir < 0 or dir > 5:
		return -1
	var index := cell * 6 + dir
	if index >= _neighbors.size():
		return -1
	return int(_neighbors[index])


## 同一条物理边只认「较小格持有」的那把 key，两侧点击得到同一个值。
func _canonical_edge_key(cell: int, dir: int) -> int:
	var neighbor := _neighbor_of(cell, dir)
	if neighbor < 0 or neighbor == cell or neighbor >= _cell_count:
		return -1
	if neighbor > cell:
		return cell * 6 + dir
	for back in 6:
		if _neighbor_of(neighbor, back) == cell:
			return neighbor * 6 + back
	return -1


func _process(delta: float) -> void:
	_wall_time += delta
	if _material == null:
		return
	if _dirty:
		_rebuild()
	if not visible:
		return
	_material.set_shader_parameter("wall_seconds", _wall_time)
	_push_line_width()


func _push_line_width() -> void:
	var zoom := 1.0
	var vp := get_viewport()
	if vp != null:
		zoom = maxf(0.0001, vp.get_canvas_transform().get_scale().x)
	var screen := 4.4 * pow(zoom, 0.40)
	screen = clampf(screen, 2.2, 9.0)
	var world_width := clampf(screen / zoom, 0.3, _ribbon_width * 0.92)
	if absf(world_width - _last_pushed_world_width) < 0.001:
		return
	_last_pushed_world_width = world_width
	_material.set_shader_parameter("front_world_width", world_width)


func _owner_color(slot: int) -> Color:
	return CountryBorderLayer.country_color(slot, _player_slot, Color(0.90, 0.73, 0.38))


func _rebuild() -> void:
	_dirty = false
	if _map == null or _mesh_inst == null or _cell_count <= 0:
		if _mesh_inst != null:
			_mesh_inst.mesh = null
		_update_visibility()
		return
	var started := Time.get_ticks_usec()
	var corners := PackedVector2Array()
	corners.resize(6)
	for i in 6:
		var ang := deg_to_rad(60.0 * float(i) - 30.0)
		corners[i] = Vector2(cos(ang), sin(ang)) * _hex_size
	_corners = corners
	var offsets := PackedFloat32Array([0.0])
	if _wrap > 0.0001:
		offsets = PackedFloat32Array([-_wrap, 0.0, _wrap])
	var bleed := _ribbon_width * OUTER_BLEED_RATIO
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var nb := _neighbors
	var drawn := 0
	# 国色按 slot 缓存，进度色按 (slot, 进度) 缓存：接触边成百上千条，
	# 每帧重建也不该在热路径上重复算色相。
	var color_cache := {}
	var count := mini(_edges.size(), EDGE_CAP)
	for i in count:
		var key: int = _edges[i]
		var cell: int = key / 6
		var dir: int = key % 6
		if cell < 0 or cell >= _cell_count:
			continue
		var neighbor: int = nb[cell * 6 + dir] if cell * 6 + dir < nb.size() else -1
		if neighbor < 0 or neighbor >= _cell_count:
			continue
		# 同一条物理边只画一次（cell 较小的一侧持有）。
		if neighbor < cell:
			continue
		var progress_q := 128
		if i < _progress.size():
			progress_q = _progress[i]
		var p := float(progress_q) / 255.0
		var attacker_slot := _owner_slot[cell] if cell < _owner_slot.size() else -1
		var defender_slot := _owner_slot[neighbor] if neighbor < _owner_slot.size() else -1
		var bucket := (attacker_slot * 131 + defender_slot * 7) * 16 + int(p * 15.0)
		var col: Color
		if color_cache.has(bucket):
			col = color_cache[bucket]
		else:
			var a_col := _owner_color(attacker_slot)
			var d_col := _owner_color(defender_slot)
			var neutral := Color(0.58, 0.38, 0.22)
			var mixed := neutral.lerp(d_col, clampf((0.5 - p) * 2.0, 0.0, 1.0))
			mixed = mixed.lerp(a_col, clampf((p - 0.5) * 2.0, 0.0, 1.0))
			col = Color(mixed.r, mixed.g, mixed.b, p)
			color_cache[bucket] = col
		# 选中边：深朱砂覆盖进度色，alpha 位仍是 per-edge 种子（shader 用它抖动）。
		if key == _selected_edge:
			col = Color(SELECTED_COLOR.r, SELECTED_COLOR.g, SELECTED_COLOR.b, p)
		var cell_obj = _map.cell_at(cell)
		var nb_obj = _map.cell_at(neighbor)
		if cell_obj == null or nb_obj == null:
			continue
		var c_center: Vector2 = HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
		var n_center: Vector2 = HexUtils.cube_to_world(nb_obj.q, nb_obj.r, _hex_size)
		var edge := _hex_edge(cell_obj, nb_obj)
		var p0: Vector2 = edge[0]
		var p1: Vector2 = edge[1]
		var edge_vec := p1 - p0
		var edge_len := edge_vec.length()
		if edge_len < 0.0001:
			continue
		var along := edge_vec / edge_len
		# 跨边方向 = 从本格指向邻格（已经包含 wrap 时的最短镜像）。
		var across := (n_center - c_center).normalized()
		var half_w := _ribbon_width * 0.5
		for ox in offsets:
			var shift := Vector2(float(ox), 0.0)
			var a0: Vector2 = p0 - across * (half_w + bleed) - along * bleed * 0.5773 + shift
			var a1: Vector2 = p1 - across * (half_w + bleed) + along * bleed * 0.5773 + shift
			var b1: Vector2 = p1 + across * half_w + shift
			var b0: Vector2 = p0 + across * half_w + shift
			var base_v := verts.size()
			verts.append(a0)
			verts.append(a1)
			verts.append(b1)
			verts.append(b0)
			uvs.append(Vector2(0.0, -(half_w + bleed)))
			uvs.append(Vector2(edge_len, -(half_w + bleed)))
			uvs.append(Vector2(edge_len, half_w))
			uvs.append(Vector2(0.0, half_w))
			for _k in 4:
				colors.append(col)
			indices.append_array(PackedInt32Array([
				base_v, base_v + 1, base_v + 2,
				base_v, base_v + 2, base_v + 3,
			]))
		drawn += 1
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
	_stats["edges"] = drawn
	_stats["vertices"] = verts.size()
	_stats["rebuilds"] = int(_stats["rebuilds"]) + 1
	_stats["rebuild_usec"] = Time.get_ticks_usec() - started
	_last_pushed_world_width = -1.0
	_update_visibility()


func _edge_seed(cell: int, dir: int) -> float:
	var h: int = (cell * 6 + dir) * 2654435761
	h = (h ^ (h >> 15)) & 0xFFFFFF
	return float(h) / 16777215.0


## 边端点由两个 hex 中心的等距角点反查（见 military_area_layer._hex_edge 的注释：
## 方向枚举与角点枚举在历史上被混用过，索引公式不可靠）。
func _hex_edge(cell_obj, nb_obj) -> PackedVector2Array:
	var center := HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
	var n_center := HexUtils.cube_to_world(nb_obj.q, nb_obj.r, _hex_size)
	# wrap 接缝：邻格中心折到本格最近镜像后再求中点。
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
	var out := PackedVector2Array()
	if best0 >= 0 and best1 >= 0 and absf(d0 - d1) < _hex_size * 0.08:
		out.append(center + _corners[best0])
		out.append(center + _corners[best1])
		return out
	out.append(center)
	out.append(center + Vector2(_hex_size, 0.0))
	return out


func _update_visibility() -> void:
	visible = _enabled and _has_shader and _mesh_inst != null and _mesh_inst.mesh != null \
		and int(_stats["edges"]) > 0


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visible"] = visible
	return out
