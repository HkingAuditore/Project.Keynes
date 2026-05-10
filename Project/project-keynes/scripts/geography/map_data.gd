# map_data.gd
# 地图数据容器
# 存储所有 HexCell，以 Vector3i(q, r, s) 为键的 Dictionary

class_name MapData

var width:  int = 0
var height: int = 0

# 主存储：cube 坐标 → HexCell
var _cells: Dictionary = {}

# ─── Daily-Sim SoA Refactor 阶段 2：邻居索引 SoA ──────────────────────
# 由 _build_indices() 一次性预计算（在 MapGenerator.generate 完成所有 cell
# 入库 + terrain 定型后调用）。fast-tick 热路径（_apply_sea_ice_daily_pass /
# _apply_ocean_heat_transport_pass / _apply_local_climate_coupling_pass）
# 通过这些索引避开每帧创建 6-元 Array 的 GC 压力。
#
# 不变量：
#   - _cell_array.size() == _cells.size() == _cell_index.size()
#   - _neighbor_indices.size() == _cell_array.size() * 6
#   - _neighbor_indices[i*6 + dir] == -1 表示该方向没有邻居（地图边缘）
#   - 顺序与 HexUtils.CUBE_DIRECTIONS 一致：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
#   - regenerate 路径：MapData 实例本身被丢弃重建，无需手动失效；冷路径
#     （生成阶段、refresh_seasonal）继续使用 get_neighbors(cell)，不依赖索引
var _cell_array: Array[HexCell] = []
var _cell_index: Dictionary = {}            # HexCell → int (idx)
var _neighbor_indices: PackedInt32Array = PackedInt32Array()
var _indices_built: bool = false

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

# ─── Daily-Sim SoA Refactor 阶段 2：索引访问 API ────────────────────
# 仅 fast-tick 热路径使用；冷路径继续走 get_neighbors(cell)。

## 一次性构建（_cell_array / _cell_index / _neighbor_indices）。
## 必须在所有 cell 入库且 terrain 定型完成后调用一次；regenerate 时
## MapData 整体被替换，不需要重复调用。重复调用会先清空再重建。
func _build_indices() -> void:
	_cell_array.clear()
	_cell_index.clear()
	var n: int = _cells.size()
	_cell_array.resize(n)
	_neighbor_indices.resize(n * 6)
	# 第一遍：填 _cell_array / _cell_index
	var i: int = 0
	for key in _cells.keys():
		var cell: HexCell = _cells[key]
		_cell_array[i] = cell
		_cell_index[cell] = i
		i += 1
	# 第二遍：填 _neighbor_indices；HexUtils.CUBE_DIRECTIONS 顺序：
	# 0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
	var dirs: Array = HexUtils.CUBE_DIRECTIONS
	for j in range(n):
		var c: HexCell = _cell_array[j]
		var base: int = j * 6
		for d in range(6):
			var dv: Vector3i = dirs[d]
			var nb_key := Vector3i(c.q + dv.x, c.r + dv.y, c.s + dv.z)
			var nb = _cells.get(nb_key, null)
			if nb == null:
				_neighbor_indices[base + d] = -1
			else:
				# 邻居一定已在 _cell_index 内（因为 _cells 是同源）
				_neighbor_indices[base + d] = int(_cell_index.get(nb, -1))
	_indices_built = true

## 索引是否已构建（fast-tick 调用前断言用）。
func has_indices() -> bool:
	return _indices_built

## 根据 idx 取 cell；越界返回 null。
func cell_at(idx: int) -> HexCell:
	if idx < 0 or idx >= _cell_array.size():
		return null
	return _cell_array[idx]

## 根据 cell 取 idx；不存在返回 -1。
func index_of(cell: HexCell) -> int:
	return int(_cell_index.get(cell, -1))

## 取 idx 处 cell 的第 dir 方向邻居的 idx；无邻居返回 -1。
## dir ∈ [0, 5]，与 HexUtils.CUBE_DIRECTIONS 同序。
func neighbor_index(idx: int, dir: int) -> int:
	if idx < 0 or idx >= _cell_array.size() or dir < 0 or dir > 5:
		return -1
	return _neighbor_indices[idx * 6 + dir]

## 顺序遍历所有 cell（按 _cell_array 顺序，与 idx 对应）。
## 与 all_cells() 不同：all_cells() 走的是 Dictionary.values()，顺序不保证；
## 而 iter_cells() 顺序固定，因此当外部循环需要"已知 idx"时优先用此函数。
func iter_cells() -> Array[HexCell]:
	return _cell_array

## 直接拿底层 PackedInt32Array（fast-tick 极致内联用）。
## 调用方应自行确保 has_indices() == true，并按 idx*6+dir 索引。
func neighbor_indices_packed() -> PackedInt32Array:
	return _neighbor_indices

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

# --- Emergent Climate Coupling：慢层只读访问器 ──────────────────────────
# 天气 / 快层 pass 应通过该访问器读取慢层字段，而不是直接读 cell.base_* /
# cell.landform / cell.terrain / cell.cover / cell.elevation / cell.ocean_current 等。
# 这样日后如果把慢层数据迁移到独立容器或做并行化，调用方不需要修改。
#
# 参数：
#   qr     — 目标 cell 的 cube 坐标（Vector3i）
#   fields — 慢层字段名列表，允许值：
#              "elevation", "landform", "terrain", "cover",
#              "base_temperature", "base_moisture", "base_vegetation", "base_terrain",
#              "ocean_current", "upwelling_strength", "temperature_transport_anomaly",
#              "sea_ice_fraction", "soil_moisture", "vegetation_growth_pressure",
#              "has_river", "has_volcano"
# 返回：Dictionary，键为字段名、值为该字段当前值；cell 不存在时返回空字典。
#
# Debug 守卫：字段名拼写错误时在 OS.is_debug_build() 下 push_warning 一次。
# 快层 pass 禁止对返回的 Dictionary 写入后再回写 HexCell（本函数只读）。
const _SLOW_LAYER_FIELDS: Dictionary = {
	"elevation": true, "landform": true, "terrain": true, "cover": true,
	"base_temperature": true, "base_moisture": true,
	"base_vegetation": true, "base_terrain": true,
	"ocean_current": true, "upwelling_strength": true,
	"temperature_transport_anomaly": true,
	"sea_ice_fraction": true, "soil_moisture": true,
	"vegetation_growth_pressure": true,
	"has_river": true, "has_volcano": true,
}

func sample_slow_layer(qr: Vector3i, fields: Array) -> Dictionary:
	var cell: HexCell = _cells.get(qr, null)
	if cell == null:
		return {}
	var out: Dictionary = {}
	for f in fields:
		var key: String = str(f)
		if not _SLOW_LAYER_FIELDS.has(key):
			if OS.is_debug_build():
				push_warning("sample_slow_layer: unknown slow-layer field '%s'" % key)
			continue
		# 基础字段映射（GDScript 对 Object 可直接用字符串访问属性）
		match key:
			"base_temperature":
				# HexCell 上并没有 base_temperature（仅 base_moisture / base_terrain 等）；
				# Fast-tick perf opt (C)：temp_baseline 已升级为 HexCell 强类型成员，
				# 直接读，不再走 current_state["_temp_baseline"] 字典查找。
				out[key] = cell.temp_baseline
			_:
				out[key] = cell.get(key)
	return out
