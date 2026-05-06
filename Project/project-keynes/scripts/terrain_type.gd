# terrain_type.gd
# 地形类型枚举及其属性定义
# 新增地形只需在 TERRAIN 枚举和 _DATA 字典中各添加一条

class_name TerrainType

enum TERRAIN {
	OCEAN,      # 深海
	COAST,      # 浅海 / 海岸
	PLAIN,      # 平原
	GRASSLAND,  # 草地
	FOREST,     # 森林
	HILL,       # 丘陵
	MOUNTAIN,   # 山地
	DESERT,     # 沙漠
	TUNDRA,     # 冻原
	SNOW,       # 雪地 / 极地
}

# 每种地形的静态属性
# passable_land  : 陆上单位（步兵、骑兵等）是否可进入
# passable_sea   : 海上单位（船只等）是否可进入
# move_cost      : 陆上单位进入该地块消耗的行动力（0 = 不可通行）
# color          : 调试/占位渲染颜色
const _DATA: Dictionary = {
	TERRAIN.OCEAN:     { "passable_land": false, "passable_sea": true,  "move_cost": 0, "color": Color(0.10, 0.20, 0.55) },
	TERRAIN.COAST:     { "passable_land": false, "passable_sea": true,  "move_cost": 0, "color": Color(0.25, 0.45, 0.80) },
	TERRAIN.PLAIN:     { "passable_land": true,  "passable_sea": false, "move_cost": 1, "color": Color(0.76, 0.85, 0.50) },
	TERRAIN.GRASSLAND: { "passable_land": true,  "passable_sea": false, "move_cost": 1, "color": Color(0.40, 0.72, 0.30) },
	TERRAIN.FOREST:    { "passable_land": true,  "passable_sea": false, "move_cost": 2, "color": Color(0.13, 0.45, 0.13) },
	TERRAIN.HILL:      { "passable_land": true,  "passable_sea": false, "move_cost": 2, "color": Color(0.60, 0.50, 0.30) },
	TERRAIN.MOUNTAIN:  { "passable_land": false, "passable_sea": false, "move_cost": 0, "color": Color(0.55, 0.55, 0.55) },
	TERRAIN.DESERT:    { "passable_land": true,  "passable_sea": false, "move_cost": 2, "color": Color(0.90, 0.80, 0.45) },
	TERRAIN.TUNDRA:    { "passable_land": true,  "passable_sea": false, "move_cost": 2, "color": Color(0.72, 0.80, 0.75) },
	TERRAIN.SNOW:      { "passable_land": false, "passable_sea": false, "move_cost": 0, "color": Color(0.95, 0.97, 1.00) },
}

# --- 静态查询方法 ---

static func get_data(terrain: TERRAIN) -> Dictionary:
	return _DATA[terrain]

static func is_passable_land(terrain: TERRAIN) -> bool:
	return _DATA[terrain]["passable_land"]

static func is_passable_sea(terrain: TERRAIN) -> bool:
	return _DATA[terrain]["passable_sea"]

static func get_move_cost(terrain: TERRAIN) -> int:
	return _DATA[terrain]["move_cost"]

static func get_color(terrain: TERRAIN) -> Color:
	return _DATA[terrain]["color"]

static func terrain_name(terrain: TERRAIN) -> String:
	return TERRAIN.keys()[terrain]
