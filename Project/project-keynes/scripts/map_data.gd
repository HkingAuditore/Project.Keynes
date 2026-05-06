# map_data.gd
# 地图数据容器
# 存储所有 HexCell，以 Vector3i(q, r, s) 为键的 Dictionary

class_name MapData

var width:  int = 0
var height: int = 0

# 主存储：cube 坐标 → HexCell
var _cells: Dictionary = {}

# --- 初始化 ---
func _init(w: int, h: int) -> void:
	width  = w
	height = h

# --- 基础读写 ---

## 按 cube 坐标获取地块（不存在返回 null）
func get_cell(q: int, r: int) -> HexCell:
	return _cells.get(Vector3i(q, r, -q - r), null)

func get_cell_by_cube(coords: Vector3i) -> HexCell:
	return _cells.get(coords, null)

## 写入地块（自动以其 cube 坐标为键）
func set_cell(cell: HexCell) -> void:
	_cells[Vector3i(cell.q, cell.r, cell.s)] = cell

## 判断坐标是否在地图内（offset 行列）
func has_offset(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

## 遍历所有地块
func all_cells() -> Array:
	return _cells.values()

## 获取地块总数
func cell_count() -> int:
	return _cells.size()

# --- 邻居查询 ---

## 返回指定地块的所有存在邻居（最多 6 个）
func get_neighbors(cell: HexCell) -> Array:
	var result: Array = []
	for dir in HexUtils.CUBE_DIRECTIONS:
		var nc := Vector3i(cell.q + dir.x, cell.r + dir.y, cell.s + dir.z)
		var neighbor = _cells.get(nc, null)
		if neighbor != null:
			result.append(neighbor)
	return result

## 返回指定 cube 坐标的所有存在邻居
func get_neighbors_by_cube(coords: Vector3i) -> Array:
	var cell = get_cell_by_cube(coords)
	if cell == null:
		return []
	return get_neighbors(cell)

# --- 统计工具 ---

## 统计各地形数量，返回 Dictionary { TERRAIN: count }
func terrain_stats() -> Dictionary:
	var stats: Dictionary = {}
	for cell in _cells.values():
		var t = cell.terrain
		stats[t] = stats.get(t, 0) + 1
	return stats

## 按地形筛选地块列表
func cells_of_terrain(terrain: TerrainType.TERRAIN) -> Array:
	var result: Array = []
	for cell in _cells.values():
		if cell.terrain == terrain:
			result.append(cell)
	return result
