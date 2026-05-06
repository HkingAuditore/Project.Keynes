# hex_cell.gd
# 单个六边形地块的数据容器
# 使用 cube 坐标系（q, r, s），约束: q + r + s == 0

class_name HexCell

# --- Cube 坐标 ---
var q: int = 0
var r: int = 0
var s: int = 0  # 始终等于 -q - r，冗余存储以方便邻居计算

# --- 地形 ---
var terrain: TerrainType.TERRAIN = TerrainType.TERRAIN.OCEAN

# --- 地貌附加信息 ---
var has_river: bool = false        # 是否有河流流经
var elevation: float = 0.0        # 归一化高度 [0, 1]，用于生成时的中间量

# --- 通行性（由 terrain 决定，生成后缓存于此供外部快速读取）---
var passable_land: bool = false
var passable_sea: bool = false

# --- 构造 ---
func _init(p_q: int = 0, p_r: int = 0) -> void:
	q = p_q
	r = p_r
	s = -p_q - p_r

# --- 坐标工具 ---
func cube_coords() -> Vector3i:
	return Vector3i(q, r, s)

func set_from_cube(coords: Vector3i) -> void:
	q = coords.x
	r = coords.y
	s = coords.z

# --- 通行性更新（设置 terrain 后调用）---
func apply_terrain(t: TerrainType.TERRAIN) -> void:
	terrain = t
	passable_land = TerrainType.is_passable_land(t)
	passable_sea  = TerrainType.is_passable_sea(t)

# --- 调试输出 ---
# 注意：不要重写 Object.to_string()（GDScript 引擎的 _to_string 才是正确钩子）
func describe() -> String:
	return "HexCell(%d,%d,%d) terrain=%s river=%s" % [
		q, r, s,
		TerrainType.terrain_name(terrain),
		str(has_river)
	]

func _to_string() -> String:
	return describe()
