# terrain_type.gd
# 地形类型枚举及其属性定义
#
# ─── 数据驱动说明（自世界系统重构起） ────────────────────────────
# 本文件现在是 **薄 Facade**：
#   - 枚举 TERRAIN 仍然是"渲染/玩法兼容枚举"，被 baker、world_map.gdshader、
#     MapGenerator._apply_*_pass 等模块消费（下标必须保持稳定顺序）。
#   - 每个地形的属性（passable、move_cost、color、中文名）都存储在
#     res://data/terrain/*.tres 中，由 TerrainProfileRegistry 懒加载。
#   - 下面的静态方法仅作为便捷访问入口，内部全部转发到 Registry。
#   - 新增地形：
#       1) 在 TERRAIN 尾部添加枚举
#       2) 在 res://data/terrain/ 创建对应 .tres
#       3) 在 TerrainProfileRegistry._PROFILE_PATHS 注册路径
#
# ─── 三轴语义（保留，与 M1 设计一致） ────────────────────────────
# 语义上 TERRAIN 已被 LandformType + VegetationType + CoverType 三轴取代：
#   - LandformType ：地块的几何 / 海拔 / 海陆性质（PLAIN/HILL/MOUNTAIN/COAST/...）
#   - VegetationType：植被身份（HILL 上面可以是 TEMPERATE_DECIDUOUS）
#   - CoverType   ：临时/永久覆盖物（SNOW/GLACIER/SEA_ICE/PERMAFROST/FLOODING）
# 新代码（UI / 玩法层 / 经济模型）请直接读 cell.landform / cell.vegetation /
# cell.cover，不要再读 cell.terrain（除非确实需要兼容渲染层）。

class_name TerrainType

# 显式 preload，保证 TerrainProfileRegistry 在本 Facade 被首次扫描前即已加载，
# 避免冷启动 / 首次导入时的 "Could not parse global class" 报错。
const _TerrainProfileRegistryScript = preload("res://scripts/data/terrain_profile_registry.gd")

enum TERRAIN {
	OCEAN,      # 深海
	COAST,      # 浅海 / 海岸
	PLAIN,      # 平原
	GRASSLAND,  # 草地
	FOREST,     # 森林（温带阔叶）
	HILL,       # 丘陵
	MOUNTAIN,   # 山地
	DESERT,     # 沙漠
	TUNDRA,     # 冻原
	SNOW,       # 雪地 / 极地
	SWAMP,      # 沼泽 / 湿地（低海拔 + 极湿 + 暖温，靠近水体）
	JUNGLE,     # 热带雨林（高温 + 高湿）
	SAVANNA,    # 热带稀树草原（高温 + 中湿，干湿季分明）
	TAIGA,      # 针叶林 / 泰加林（凉温 + 中高湿）
	STEPPE,     # 温带草原 / 草原（温带 + 干旱，比 GRASSLAND 更干）
	SHRUBLAND,  # 灌丛 / 地中海植被（暖 + 中干 + 沿海）
	MANGROVE,   # 红树林（热带 + 极低海拔 + 紧邻 COAST）
	GLACIER,    # 冰川（极冷 + 低海拔沿海冰舌 / 高海拔冰川）
	LAKE,       # 内陆湖（不与 OCEAN 连通的水体）
	REEF,       # 珊瑚礁（COAST 上面叠加层 + 暖海）
	SEA_ICE,    # 海冰（OCEAN/COAST 上面叠加层 + 极冷，季节性）
	KELP,       # 海藻林（COAST 上面叠加层 + 凉温带 + 大陆架）
	DELTA,      # 三角洲（河流入海前的最末几格）
	OASIS,      # 绿洲（DESERT 中的水源点）
	SALT_FLAT,  # 盐沼 / 盐滩（干旱内陆盆地）
	BADLANDS,   # 荒原 / 恶地（干旱软岩片状侵蚀的破碎台地；峡谷由 LandformType.CANYON 表达）
	# ── terrain-overhaul 新增地形（id 26+，尾部追加保证旧下标稳定）──
	COLD_DESERT,  # 寒漠（冷 + 极旱，区别于热沙漠：中高纬大陆内部 / 雨影背风）
	CHAPARRAL,    # 硬叶灌丛（暖 + 夏旱冬湿，比 SHRUBLAND 更偏地中海硬叶）
	MOOR,         # 泥炭湿原（凉冷 + 极湿 + 排水不畅的酸性高地 / 低地）
	FLOODPLAIN,   # 泛滥平原（大河沿岸低海拔 + 周期性泛滥的肥沃冲积带）
	MESA,         # 方山（干旱 + 高差台地 + 顶部平坦的侵蚀残丘）
}

# --- 静态查询方法（Facade：全部转发到 TerrainProfileRegistry） ---
#
# passable_land  : 陆上单位（步兵、骑兵等）是否可进入
# passable_sea   : 海上单位（船只等）是否可进入
# move_cost      : 陆上单位进入该地块消耗的行动力（0 = 不可通行）
# color          : 调试/占位渲染颜色

static func get_data(terrain: TERRAIN) -> Dictionary:
	var p := TerrainProfileRegistry.get_profile(int(terrain))
	return {
		"passable_land": p.passable_land,
		"passable_sea":  p.passable_sea,
		"move_cost":     p.move_cost,
		"trade_passable": p.trade_passable,
		"trade_move_cost": p.trade_move_cost,
		"color":         p.base_color,
	}

static func is_passable_land(terrain: TERRAIN) -> bool:
	return TerrainProfileRegistry.get_profile(int(terrain)).passable_land

static func is_passable_sea(terrain: TERRAIN) -> bool:
	return TerrainProfileRegistry.get_profile(int(terrain)).passable_sea

static func get_move_cost(terrain: TERRAIN) -> int:
	return TerrainProfileRegistry.get_profile(int(terrain)).move_cost

static func is_trade_passable(terrain: TERRAIN) -> bool:
	return TerrainProfileRegistry.get_profile(int(terrain)).trade_passable

static func get_trade_move_cost(terrain: TERRAIN) -> int:
	return TerrainProfileRegistry.get_profile(int(terrain)).trade_move_cost

static func get_color(terrain: TERRAIN) -> Color:
	return TerrainProfileRegistry.get_profile(int(terrain)).base_color

static func terrain_name(terrain: TERRAIN) -> String:
	return TERRAIN.keys()[terrain]

static func terrain_name_cn(terrain: TERRAIN) -> String:
	var p := TerrainProfileRegistry.get_profile(int(terrain))
	if p.display_name_cn != "":
		return p.display_name_cn
	return terrain_name(terrain)
