# landform_type.gd
# Milestone 1：把单轴 TerrainType 拆成三轴中的"地形（Landform）"轴。
# 仅描述地块的几何/海拔/水体性质，与温度湿度无关。
# 与 VegetationType / CoverType 正交：HILL 上面可以是 TEMPERATE_DECIDUOUS
# 植被 + SNOW 季节性覆盖，三者各自独立。

class_name LandformType

enum LF {
	DEEP_OCEAN,   # 深海（land_h 远低于 sea level）
	OCEAN,        # 中海
	COAST,        # 浅海 / 海岸
	LAKE,         # 内陆湖
	PLAIN,        # 平原（land_h ≤ 0.05）
	LOWLAND,      # 低地丘谷（0.05 < land_h ≤ 0.22）
	HILL,         # 丘陵（0.22 < land_h ≤ 0.62）
	MOUNTAIN,     # 山地（0.62 < land_h ≤ 0.82）
	PEAK,         # 高峰（land_h > 0.82）
	DELTA,        # 三角洲
	BADLANDS,     # 荒原峡谷
	SALT_FLAT,    # 盐沼盆地
	VOLCANO,      # 火山
	# ── terrain-overhaul 新增地貌（id 13+，尾部追加）──
	PLATEAU,      # 高原（大面积抬升 + 顶部平坦的高海拔台地）
	RIFT_VALLEY,  # 裂谷（离散板块边界下陷的线状峡谷洼地）
}

# 静态属性表
# passable_land : 陆上单位是否可进入
# passable_sea  : 海上单位是否可进入
# move_cost     : 陆上单位行动力消耗（0 = 不可通行，沿 TerrainType 同口径）
# is_water      : 是否为水体（OCEAN/COAST/LAKE）
const _DATA: Dictionary = {
	LF.DEEP_OCEAN: { "passable_land": false, "passable_sea": true,  "move_cost": 0, "is_water": true },
	LF.OCEAN:      { "passable_land": false, "passable_sea": true,  "move_cost": 0, "is_water": true },
	LF.COAST:      { "passable_land": false, "passable_sea": true,  "move_cost": 0, "is_water": true },
	LF.LAKE:       { "passable_land": false, "passable_sea": true,  "move_cost": 0, "is_water": true },
	LF.PLAIN:      { "passable_land": true,  "passable_sea": false, "move_cost": 1, "is_water": false },
	LF.LOWLAND:    { "passable_land": true,  "passable_sea": false, "move_cost": 1, "is_water": false },
	LF.HILL:       { "passable_land": true,  "passable_sea": false, "move_cost": 2, "is_water": false },
	LF.MOUNTAIN:   { "passable_land": false, "passable_sea": false, "move_cost": 0, "is_water": false },
	LF.PEAK:       { "passable_land": false, "passable_sea": false, "move_cost": 0, "is_water": false },
	LF.DELTA:      { "passable_land": true,  "passable_sea": false, "move_cost": 2, "is_water": false },
	LF.BADLANDS:   { "passable_land": true,  "passable_sea": false, "move_cost": 3, "is_water": false },
	LF.SALT_FLAT:  { "passable_land": true,  "passable_sea": false, "move_cost": 2, "is_water": false },
	LF.VOLCANO:    { "passable_land": false, "passable_sea": false, "move_cost": 0, "is_water": false },
	LF.PLATEAU:    { "passable_land": true,  "passable_sea": false, "move_cost": 2, "is_water": false },
	LF.RIFT_VALLEY:{ "passable_land": true,  "passable_sea": false, "move_cost": 2, "is_water": false },
}

const _NAME_CN: Dictionary = {
	LF.DEEP_OCEAN: "深海",
	LF.OCEAN:      "海洋",
	LF.COAST:      "海岸",
	LF.LAKE:       "湖泊",
	LF.PLAIN:      "平原",
	LF.LOWLAND:    "低地",
	LF.HILL:       "丘陵",
	LF.MOUNTAIN:   "山地",
	LF.PEAK:       "高峰",
	LF.DELTA:      "三角洲",
	LF.BADLANDS:   "荒原峡谷",
	LF.SALT_FLAT:  "盐沼地形",
	LF.VOLCANO:    "火山",
	LF.PLATEAU:    "高原",
	LF.RIFT_VALLEY:"裂谷",
}

# --- 静态查询 ---

static func name_cn(lf: LF) -> String:
	return _NAME_CN.get(lf, str(lf))

static func is_water(lf: LF) -> bool:
	return _DATA[lf]["is_water"]

static func is_passable(lf: LF) -> bool:
	return _DATA[lf]["passable_land"]

static func is_passable_sea(lf: LF) -> bool:
	return _DATA[lf]["passable_sea"]

static func move_cost(lf: LF) -> int:
	return _DATA[lf]["move_cost"]
