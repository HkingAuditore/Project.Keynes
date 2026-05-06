# hex_renderer.gd
# 2D 六边形地图渲染器（Node2D + _draw 直绘，无需 TileSet 资源）
# 用法：
#   var renderer := HexRenderer.new()
#   add_child(renderer)
#   renderer.set_map(map_data)        # 喂入数据后自动重绘
#   renderer.hex_size = 18.0          # 可选：调整地块半径
#
# 设计：纯绘制层，不处理输入；坐标由 HexUtils.cube_to_world 决定（pointy-top + odd-r）

class_name HexRenderer
extends Node2D

# ─── 渲染参数（可外部设置） ───────────────────────────────────────────
@export var hex_size: float = 20.0:                  # 六边形外接圆半径
	set(v):
		hex_size = maxf(2.0, v)
		_rebuild_geometry_cache()
		queue_redraw()

@export var draw_grid_lines: bool = true             # 是否绘制地块边线
@export var grid_line_color: Color = Color(0, 0, 0, 0.25)
@export var grid_line_width: float = 1.0

@export var draw_river: bool = true                  # 是否绘制河流
@export var river_color: Color = Color(0.20, 0.55, 0.95, 0.95)
@export var river_width: float = 3.0

@export var draw_coords_debug: bool = false          # 调试：在每格显示 (col,row)
@export var coord_label_color: Color = Color(0, 0, 0, 0.7)

# ─── 内部状态 ─────────────────────────────────────────────────────────
var _map: MapData = null
var _hex_polygon: PackedVector2Array = PackedVector2Array()   # 单格六边形顶点（相对中心）
var _font: Font = null

# ─── 生命周期 ────────────────────────────────────────────────────────
func _ready() -> void:
	_rebuild_geometry_cache()
	# 默认字体（用于调试坐标显示）
	_font = ThemeDB.fallback_font

# ─── 公开 API ────────────────────────────────────────────────────────

## 设置地图数据并触发重绘
func set_map(map: MapData) -> void:
	_map = map
	queue_redraw()

## 返回当前地图世界坐标包围盒（含一个边距），用于摄像机限制范围
func get_world_bounds() -> Rect2:
	if _map == null or _map.cell_count() == 0:
		return Rect2()
	var w := float(_map.width)
	var h := float(_map.height)
	# pointy-top + odd-r：
	# 总宽 ≈ sqrt(3) * size * (w + 0.5)
	# 总高 ≈ 1.5 * size * h + 0.5 * size
	var px := sqrt(3.0) * hex_size * (w + 0.5)
	var py := 1.5 * hex_size * h + 0.5 * hex_size
	return Rect2(Vector2(-hex_size, -hex_size), Vector2(px + hex_size, py + hex_size))

# ─── 几何缓存 ────────────────────────────────────────────────────────

func _rebuild_geometry_cache() -> void:
	_hex_polygon.resize(6)
	# pointy-top：从顶点 (0, -size) 开始，每 60° 一个顶点
	for i in range(6):
		var angle: float = deg_to_rad(60.0 * float(i) - 90.0)
		_hex_polygon[i] = Vector2(cos(angle), sin(angle)) * hex_size

# ─── 绘制 ────────────────────────────────────────────────────────────

func _draw() -> void:
	if _map == null:
		return

	# 第一遍：填色
	for cell in _map.all_cells():
		var center := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		var verts := _translated_polygon(center)
		var col := TerrainType.get_color(cell.terrain)
		# 河流流经的陆地略微提亮以暗示湿润
		if cell.has_river and TerrainType.is_passable_land(cell.terrain):
			col = col.lerp(Color(0.50, 0.75, 1.0), 0.18)
		draw_colored_polygon(verts, col)

	# 第二遍：边线
	if draw_grid_lines:
		for cell in _map.all_cells():
			var center := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
			var verts := _translated_polygon(center)
			# 闭合：把第一点再追加到末尾
			var closed := PackedVector2Array(verts)
			closed.append(verts[0])
			draw_polyline(closed, grid_line_color, grid_line_width, true)

	# 第三遍：河流
	if draw_river:
		_draw_rivers()

	# 调试：坐标
	if draw_coords_debug and _font != null:
		for cell in _map.all_cells():
			var off := HexUtils.cube_to_offset(cell.q, cell.r)
			var center := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
			var txt := "%d,%d" % [off.x, off.y]
			draw_string(_font, center + Vector2(-hex_size * 0.5, hex_size * 0.2),
				txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, coord_label_color)

# 河流绘制：把 has_river 的格之间相连接的中心点连线
func _draw_rivers() -> void:
	if _map == null:
		return
	var drawn_edges: Dictionary = {}
	for cell in _map.all_cells():
		if not cell.has_river:
			continue
		var c1 := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		for nb in _map.get_neighbors(cell):
			if not nb.has_river:
				continue
			# 用排序后的 (cube_a, cube_b) 作为唯一边键，避免重复绘制
			var key := _edge_key(cell, nb)
			if drawn_edges.has(key):
				continue
			drawn_edges[key] = true
			var c2 := HexUtils.cube_to_world(nb.q, nb.r, hex_size)
			draw_line(c1, c2, river_color, river_width, true)

# ─── 工具 ────────────────────────────────────────────────────────────

func _translated_polygon(center: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(6)
	for i in range(6):
		result[i] = _hex_polygon[i] + center
	return result

func _edge_key(a: HexCell, b: HexCell) -> String:
	# 规范化方向（小坐标在前），保证 a-b 与 b-a 得到相同 key
	var ka := Vector3i(a.q, a.r, a.s)
	var kb := Vector3i(b.q, b.r, b.s)
	if _cube_less(ka, kb):
		return "%d,%d,%d|%d,%d,%d" % [ka.x, ka.y, ka.z, kb.x, kb.y, kb.z]
	return "%d,%d,%d|%d,%d,%d" % [kb.x, kb.y, kb.z, ka.x, ka.y, ka.z]

func _cube_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z
