# vegetation_type.gd
# Milestone 1：植被（Vegetation）独立轴。
# 与 LandformType / CoverType 正交，可与多种地形组合：
# 例如 HILL + TEMPERATE_DECIDUOUS（丘陵阔叶林）、MOUNTAIN + ALPINE_MEADOW（高山草甸）。
#
# ─── 数据驱动说明（自世界系统重构起） ────────────────────────────
# 本文件现在是 **薄 Facade**：
#   - 枚举 VEG 保留不变（下标顺序被 baker / shader / MapGenerator 依赖）。
#   - 每种植被的数值（名称、蒸腾、反照率、eco_score、理想气候、演替链）都
#     存储在 res://data/vegetation/*.tres 中，由 VegetationProfileRegistry
#     懒加载。
#   - 下面的静态方法仅作为便捷访问入口，内部全部转发到 Registry。
#   - 新增植被：
#       1) 在 VEG 尾部添加枚举
#       2) 在 res://data/vegetation/ 创建对应 .tres
#       3) 在 VegetationProfileRegistry._PROFILE_PATHS 注册路径
#       4) 检查其 next_richer / next_harsher 是否闭合到现有链
#
# ─── 保留的设计语义 ───────────────────────────────────────────────
#   transpiration：蒸腾系数，驱动"植被 → 邻居 +moisture"反馈
#   albedo       ：反照率，驱动"植被 → 局地 ±temperature"反馈
#   eco_score    ：生态健康评分，驱动 Phase 8 base_moisture 长期漂移
#                  正值 → 健康林相；负值 → 荒漠化
#   climate_compat_score : 理想气候的高斯贴合度 [0, 1]
#   next_in_succession   : 长期气候偏离驱动的"升级 / 退化"查询

class_name VegetationType

# 显式 preload，保证 VegetationProfileRegistry 在本 Facade 被首次扫描前即已加载，
# 避免冷启动 / 首次导入时的 "Could not parse global class" 报错。
const _VegetationProfileRegistryScript = preload("res://scripts/data/vegetation_profile_registry.gd")

enum VEG {
	NONE,                  # 裸地（岩石、雪面、海面、盐滩）
	POLAR_DESERT,          # 极地荒漠（极冷 + 几乎无植被）
	TUNDRA,                # 苔原（地衣 + 矮灌木）
	ALPINE_TUNDRA,         # 高山苔原（HILL/MOUNTAIN + 寒冷）
	ALPINE_MEADOW,         # 高山草甸（HILL/MOUNTAIN + 凉爽湿润）
	TAIGA,                 # 北方针叶林（泰加林）
	BOREAL_SHRUB,          # 北方灌丛
	TEMPERATE_DECIDUOUS,   # 温带阔叶林
	TEMPERATE_CONIFER,     # 温带针叶林
	TEMPERATE_GRASSLAND,   # 温带草原
	TEMPERATE_STEPPE,      # 温带干草原（更干，比 GRASSLAND 草更稀）
	MEDITERRANEAN_SHRUB,   # 地中海灌丛
	SUBTROPICAL_FOREST,    # 亚热带森林
	SAVANNA,               # 稀树草原
	TROPICAL_RAINFOREST,   # 热带雨林
	TROPICAL_DRY_FOREST,   # 热带季雨林
	DESERT_SCRUB,          # 沙漠灌木（稀疏耐旱植被）
	XERIC_DESERT,          # 极旱沙漠（几乎无植被）
	OASIS_VEG,             # 绿洲植被（棕榈 + 草本）
	MANGROVE,              # 红树林
	SWAMP,                 # 沼泽（草本 + 灌木）
	MARSH,                 # 草本湿地
	KELP_FOREST,           # 海藻林（COAST + 凉温）
	CORAL_REEF,            # 珊瑚礁（COAST + 暖海）
	# ── terrain-overhaul 新增植被（id 24+，尾部追加保证旧下标稳定）──
	CLOUD_FOREST,          # 云雾林（热带 / 亚热带高山迎风坡 + 常年云雾高湿）
	MONSOON_FOREST,        # 季风林（热带季风带 + 干湿季分明的半落叶林）
	SEAGRASS,              # 海草床（COAST 浅海软底 + 暖凉过渡，区别于 KELP/REEF）
	PEAT_BOG,              # 泥炭沼（凉冷 + 极湿 + 厌氧泥炭积累的酸性沼泽）
}

# ─── 天气抗性表（Milestone: vegetation-survival-rebalance 方案 C） ────────
# 每种植被面对特定天气灾害的抗性系数 ∈ [0, 1]。
#   penalty_final = base_penalty * weather_intensity * (1.0 - resistance)
# 未在表中声明的 (VEG, WT) 组合默认 resistance = 0.0（完全无抗性）。
# 设计原则：
#   - 沙漠/干草原/地中海灌丛抗旱；雨林 / 沼泽 / 红树林怕旱。
#   - 寒带 / 极地植被抗暴风雪；热带植被完全扛不住暴风雪。
#   - 沙漠 / 稀树草原抗热浪；寒带植被最惧热浪。
#   - 雨林 / 红树林抗风暴（根系 / 树冠结构发达）；草原 / 沙漠灌木中等抗风。
const _WEATHER_RESISTANCE: Dictionary = {
	# --- DROUGHT ---
	VEG.XERIC_DESERT:         {WeatherType.WT.DROUGHT: 0.90, WeatherType.WT.HEATWAVE: 0.85},
	VEG.DESERT_SCRUB:         {WeatherType.WT.DROUGHT: 0.80, WeatherType.WT.HEATWAVE: 0.75, WeatherType.WT.STORM: 0.30, WeatherType.WT.MONSOON: 0.30},
	VEG.TEMPERATE_STEPPE:     {WeatherType.WT.DROUGHT: 0.55},
	VEG.SAVANNA:              {WeatherType.WT.DROUGHT: 0.50, WeatherType.WT.HEATWAVE: 0.65, WeatherType.WT.BLIZZARD: 0.10},
	VEG.MEDITERRANEAN_SHRUB:  {WeatherType.WT.DROUGHT: 0.55, WeatherType.WT.HEATWAVE: 0.55},
	VEG.TEMPERATE_GRASSLAND:  {WeatherType.WT.DROUGHT: 0.35, WeatherType.WT.STORM: 0.40, WeatherType.WT.MONSOON: 0.40},
	# --- 湿生植被：极度怕旱，但抗风 ---
	VEG.TROPICAL_RAINFOREST:  {WeatherType.WT.DROUGHT: 0.05, WeatherType.WT.BLIZZARD: 0.0, WeatherType.WT.HEATWAVE: 0.30, WeatherType.WT.STORM: 0.60, WeatherType.WT.MONSOON: 0.60},
	VEG.SWAMP:                {WeatherType.WT.DROUGHT: 0.10},
	VEG.MARSH:                {WeatherType.WT.DROUGHT: 0.10},
	VEG.MANGROVE:             {WeatherType.WT.DROUGHT: 0.10, WeatherType.WT.BLIZZARD: 0.0, WeatherType.WT.STORM: 0.70, WeatherType.WT.MONSOON: 0.70},
	VEG.TROPICAL_DRY_FOREST:  {WeatherType.WT.DROUGHT: 0.40, WeatherType.WT.HEATWAVE: 0.55},
	# --- 寒带植被：抗暴风雪，惧热浪 ---
	VEG.POLAR_DESERT:         {WeatherType.WT.BLIZZARD: 0.90, WeatherType.WT.HEATWAVE: 0.0},
	VEG.TUNDRA:               {WeatherType.WT.BLIZZARD: 0.85, WeatherType.WT.HEATWAVE: 0.0},
	VEG.ALPINE_TUNDRA:        {WeatherType.WT.BLIZZARD: 0.85, WeatherType.WT.HEATWAVE: 0.0},
	VEG.TAIGA:                {WeatherType.WT.BLIZZARD: 0.75, WeatherType.WT.HEATWAVE: 0.10},
	VEG.BOREAL_SHRUB:         {WeatherType.WT.BLIZZARD: 0.70, WeatherType.WT.HEATWAVE: 0.15},
	VEG.ALPINE_MEADOW:        {WeatherType.WT.BLIZZARD: 0.50},
}

# --- 静态查询（Facade：全部转发到 VegetationProfileRegistry） ---

static func name_cn(v: VEG) -> String:
	var p := VegetationProfileRegistry.get_profile(int(v))
	if p.display_name_cn != "":
		return p.display_name_cn
	return str(v)

static func transpiration(v: VEG) -> float:
	return VegetationProfileRegistry.get_profile(int(v)).transpiration

static var _foliage_biomass_table_cache: PackedFloat32Array = PackedFloat32Array()

# 绝对生物量 [0, 1]：表达"这种植被本身有多茂密"，与 climate_compat_score /
# vegetation_vitality 这类"相对自身类型的适应度"正交——健康的沙漠灌木和健康的雨林
# compat / vitality 都接近 1，只有本量能区分两者。雨林 1.0 → 极旱沙漠 0.02。
# 用 transpiration 作代理：蒸腾通量与叶面积指数高度相关，不额外维护第二张表。
static func foliage_biomass(v: VEG) -> float:
	return clampf(VegetationProfileRegistry.get_profile(int(v)).transpiration, 0.0, 1.0)

# 按 VEG enum 顺序的 foliage_biomass 表，供 C++ hot loop / 散布层一次性取用。
static func foliage_biomass_table() -> PackedFloat32Array:
	var n_veg: int = VEG.size()
	if _foliage_biomass_table_cache.size() == n_veg:
		return _foliage_biomass_table_cache
	var table := PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		table[v] = clampf(VegetationProfileRegistry.get_profile(v).transpiration, 0.0, 1.0)
	_foliage_biomass_table_cache = table
	return _foliage_biomass_table_cache

static func albedo(v: VEG) -> float:
	return VegetationProfileRegistry.get_profile(int(v)).albedo

static func eco_score(v: VEG) -> float:
	return VegetationProfileRegistry.get_profile(int(v)).eco_score

# Milestone 4：返回 [0, 1] 兼容度。1 = 当前 (temp, moist) 与该植被理想区间完全贴合。
# 用高斯衰减：score = exp(-0.5 × ((dt/tt)² + (dm/mt)²))
# 公式不变，只是 ideal / tolerance 来自 Profile 而非常量字典。
static func climate_compat_score(v: VEG, temp: float, moist: float) -> float:
	var p := VegetationProfileRegistry.get_profile(int(v))
	var dt: float = (temp - p.ideal_temp) / maxf(p.temp_tolerance, 0.01)
	var dm: float = (moist - p.ideal_moist) / maxf(p.moist_tolerance, 0.01)
	var k: float = 0.5 * (dt * dt + dm * dm)
	return exp(-k)

# Climate biomes are long-lived envelopes, while vegetation is the faster
# ecological response.  Keep the distinction, but make a vegetation type that
# is far outside its biome a poor candidate instead of an equally valid one.
static func biome_envelope_weight(terrain: int, v: VEG) -> float:
	match terrain:
		TerrainType.TERRAIN.OCEAN:
			if v == VEG.NONE: return 1.0
			if v in [VEG.KELP_FOREST, VEG.CORAL_REEF, VEG.SEAGRASS]: return 0.30
			return 0.18
		TerrainType.TERRAIN.COAST:
			if v == VEG.SEAGRASS: return 1.0
			if v == VEG.NONE: return 0.90
			if v == VEG.KELP_FOREST: return 0.70
			if v == VEG.CORAL_REEF: return 0.65
			if v == VEG.MANGROVE: return 0.45
			return 0.18
		TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.HILL, TerrainType.TERRAIN.MOUNTAIN:
			# These are climate-agnostic substrates; temperature/moisture chooses
			# the vegetation, while landform_soft_weight handles elevation.
			return 1.0
		TerrainType.TERRAIN.FOREST:
			if v in [VEG.TEMPERATE_DECIDUOUS, VEG.SUBTROPICAL_FOREST]: return 1.0
			if v == VEG.TEMPERATE_CONIFER: return 0.90
			if v == VEG.CLOUD_FOREST: return 0.88
			if v == VEG.TROPICAL_DRY_FOREST: return 0.72
			if v == VEG.MONSOON_FOREST: return 0.55
			if v == VEG.TROPICAL_RAINFOREST: return 0.28
			if v == VEG.SAVANNA: return 0.65
			if v == VEG.TEMPERATE_GRASSLAND: return 0.76
			return 0.70
		TerrainType.TERRAIN.JUNGLE:
			if v == VEG.TROPICAL_RAINFOREST: return 1.0
			if v == VEG.CLOUD_FOREST: return 0.95
			if v == VEG.MONSOON_FOREST: return 0.90
			if v == VEG.TROPICAL_DRY_FOREST: return 0.82
			if v == VEG.SUBTROPICAL_FOREST: return 0.72
			if v == VEG.SAVANNA: return 0.58
			if v == VEG.TEMPERATE_GRASSLAND: return 0.50
			return 0.28
		TerrainType.TERRAIN.SAVANNA:
			if v == VEG.SAVANNA: return 1.0
			if v == VEG.TROPICAL_DRY_FOREST: return 0.82
			if v == VEG.TEMPERATE_GRASSLAND: return 0.72
			if v == VEG.TEMPERATE_STEPPE: return 0.64
			if v == VEG.DESERT_SCRUB: return 0.55
			if v == VEG.MONSOON_FOREST: return 0.45
			if v == VEG.TROPICAL_RAINFOREST: return 0.25
			return 0.55
		TerrainType.TERRAIN.GRASSLAND:
			if v == VEG.TEMPERATE_GRASSLAND: return 1.0
			if v == VEG.TEMPERATE_STEPPE: return 0.88
			if v == VEG.SAVANNA: return 0.72
			if v in [VEG.ALPINE_MEADOW, VEG.BOREAL_SHRUB]: return 0.75
			if v == VEG.TROPICAL_DRY_FOREST: return 0.55
			if v == VEG.MONSOON_FOREST: return 0.38
			if v == VEG.TROPICAL_RAINFOREST: return 0.25
			return 0.65
		TerrainType.TERRAIN.STEPPE:
			if v == VEG.TEMPERATE_STEPPE: return 1.0
			if v == VEG.TEMPERATE_GRASSLAND: return 0.82
			if v in [VEG.DESERT_SCRUB, VEG.MEDITERRANEAN_SHRUB, VEG.SAVANNA]: return 0.72
			if v == VEG.TROPICAL_DRY_FOREST: return 0.52
			if v == VEG.MONSOON_FOREST: return 0.25
			if v == VEG.TROPICAL_RAINFOREST: return 0.18
			return 0.65
		TerrainType.TERRAIN.DESERT:
			if v in [VEG.XERIC_DESERT, VEG.DESERT_SCRUB]: return 1.0
			if v in [VEG.TEMPERATE_STEPPE, VEG.SAVANNA]: return 0.68
			if v == VEG.MEDITERRANEAN_SHRUB: return 0.62
			if v == VEG.TROPICAL_DRY_FOREST: return 0.35
			if v in [VEG.MONSOON_FOREST, VEG.TROPICAL_RAINFOREST]: return 0.18
			return 0.55
		TerrainType.TERRAIN.TUNDRA:
			if v in [VEG.TUNDRA, VEG.POLAR_DESERT, VEG.ALPINE_TUNDRA]: return 1.0
			if v in [VEG.BOREAL_SHRUB, VEG.TAIGA]: return 0.78
			if v == VEG.ALPINE_MEADOW: return 0.70
			return 0.18
		TerrainType.TERRAIN.TAIGA:
			if v in [VEG.TAIGA, VEG.TEMPERATE_CONIFER]: return 1.0
			if v == VEG.BOREAL_SHRUB: return 0.90
			if v in [VEG.TUNDRA, VEG.ALPINE_TUNDRA]: return 0.72
			if v == VEG.TEMPERATE_DECIDUOUS: return 0.65
			return 0.18
		TerrainType.TERRAIN.COLD_DESERT:
			if v in [VEG.XERIC_DESERT, VEG.DESERT_SCRUB]: return 0.95
			if v in [VEG.POLAR_DESERT, VEG.TEMPERATE_STEPPE]: return 0.78
			if v == VEG.TUNDRA: return 0.68
			return 0.18
		TerrainType.TERRAIN.CHAPARRAL:
			if v == VEG.MEDITERRANEAN_SHRUB: return 1.0
			if v in [VEG.DESERT_SCRUB, VEG.TEMPERATE_STEPPE]: return 0.74
			if v == VEG.SAVANNA: return 0.60
			if v in [VEG.MONSOON_FOREST, VEG.TROPICAL_RAINFOREST]: return 0.30
			return 0.65
		TerrainType.TERRAIN.SHRUBLAND:
			if v == VEG.MEDITERRANEAN_SHRUB: return 0.95
			if v in [VEG.DESERT_SCRUB, VEG.TEMPERATE_STEPPE]: return 0.78
			if v == VEG.SAVANNA: return 0.62
			if v in [VEG.MONSOON_FOREST, VEG.TROPICAL_RAINFOREST]: return 0.25
			return 0.65
		TerrainType.TERRAIN.SNOW:
			if v == VEG.POLAR_DESERT: return 1.0
			if v == VEG.ALPINE_TUNDRA: return 0.95
			if v == VEG.TUNDRA: return 0.90
			if v == VEG.ALPINE_MEADOW: return 0.70
			if v in [VEG.TAIGA, VEG.TEMPERATE_CONIFER]: return 0.45
			if v == VEG.NONE: return 0.80
			return 0.18
		TerrainType.TERRAIN.SWAMP:
			if v == VEG.SWAMP: return 1.0
			if v == VEG.PEAT_BOG: return 0.95
			if v == VEG.MARSH: return 0.90
			if v in [VEG.TROPICAL_RAINFOREST, VEG.MONSOON_FOREST]: return 0.65
			if v == VEG.MANGROVE: return 0.45
			if v == VEG.NONE: return 0.75
			return 0.18
		TerrainType.TERRAIN.MANGROVE:
			if v == VEG.MANGROVE: return 1.0
			if v in [VEG.MARSH, VEG.SWAMP]: return 0.80
			if v in [VEG.TROPICAL_RAINFOREST, VEG.MONSOON_FOREST]: return 0.55
			if v == VEG.NONE: return 0.70
			return 0.18
		TerrainType.TERRAIN.GLACIER:
			if v == VEG.NONE: return 1.0
			if v == VEG.POLAR_DESERT: return 0.80
			if v == VEG.ALPINE_TUNDRA: return 0.75
			return 0.18
		TerrainType.TERRAIN.LAKE:
			return 1.0 if v == VEG.NONE else 0.18
		TerrainType.TERRAIN.REEF:
			if v == VEG.CORAL_REEF: return 1.0
			if v == VEG.NONE: return 0.80
			if v == VEG.SEAGRASS: return 0.65
			return 0.18
		TerrainType.TERRAIN.SEA_ICE:
			if v == VEG.NONE: return 1.0
			if v == VEG.POLAR_DESERT: return 0.55
			return 0.18
		TerrainType.TERRAIN.KELP:
			if v == VEG.KELP_FOREST: return 1.0
			if v == VEG.NONE: return 0.80
			if v == VEG.SEAGRASS: return 0.65
			return 0.18
		TerrainType.TERRAIN.DELTA:
			if v == VEG.MARSH: return 0.98
			if v == VEG.MANGROVE: return 0.90
			if v == VEG.SWAMP: return 0.85
			if v == VEG.NONE: return 0.85
			if v in [VEG.MONSOON_FOREST, VEG.SAVANNA]: return 0.80
			if v == VEG.TROPICAL_RAINFOREST: return 0.72
			if v == VEG.TROPICAL_DRY_FOREST: return 0.65
			if v in [VEG.TEMPERATE_GRASSLAND, VEG.TEMPERATE_DECIDUOUS]: return 0.78
			if v in [VEG.TAIGA, VEG.BOREAL_SHRUB, VEG.TEMPERATE_CONIFER]: return 0.50
			return 0.18
		TerrainType.TERRAIN.OASIS:
			if v == VEG.OASIS_VEG: return 1.0
			if v == VEG.NONE: return 0.80
			if v in [VEG.DESERT_SCRUB, VEG.XERIC_DESERT, VEG.SAVANNA]: return 0.60
			if v == VEG.TEMPERATE_GRASSLAND: return 0.55
			return 0.18
		TerrainType.TERRAIN.SALT_FLAT:
			if v == VEG.NONE: return 1.0
			if v in [VEG.XERIC_DESERT, VEG.DESERT_SCRUB]: return 0.45
			return 0.18
		TerrainType.TERRAIN.BADLANDS:
			if v == VEG.DESERT_SCRUB: return 1.0
			if v == VEG.XERIC_DESERT: return 0.85
			if v in [VEG.TEMPERATE_STEPPE, VEG.MEDITERRANEAN_SHRUB]: return 0.70
			if v == VEG.SAVANNA: return 0.50
			if v == VEG.NONE: return 0.80
			return 0.18
		TerrainType.TERRAIN.MOOR:
			if v == VEG.PEAT_BOG: return 1.0
			if v in [VEG.MARSH, VEG.SWAMP]: return 0.90
			if v in [VEG.TAIGA, VEG.BOREAL_SHRUB]: return 0.65
			if v == VEG.ALPINE_MEADOW: return 0.55
			if v == VEG.TEMPERATE_GRASSLAND: return 0.75
			return 0.18
		TerrainType.TERRAIN.FLOODPLAIN:
			if v == VEG.MARSH: return 0.98
			if v == VEG.SWAMP: return 0.90
			if v == VEG.MANGROVE: return 0.80
			if v in [VEG.MONSOON_FOREST, VEG.SAVANNA]: return 0.80
			if v == VEG.TROPICAL_RAINFOREST: return 0.72
			if v == VEG.TROPICAL_DRY_FOREST: return 0.65
			if v in [VEG.TEMPERATE_GRASSLAND, VEG.TEMPERATE_DECIDUOUS]: return 0.90
			if v in [VEG.TAIGA, VEG.BOREAL_SHRUB, VEG.TEMPERATE_CONIFER]: return 0.60
			if v == VEG.NONE: return 0.85
			return 0.45
		TerrainType.TERRAIN.MESA:
			if v == VEG.DESERT_SCRUB: return 1.0
			if v == VEG.XERIC_DESERT: return 0.85
			if v == VEG.TEMPERATE_STEPPE: return 0.65
			if v == VEG.MEDITERRANEAN_SHRUB: return 0.60
			if v == VEG.SAVANNA: return 0.55
			if v == VEG.NONE: return 0.80
			return 0.18
		_:
			return 1.0

const BIOME_RECONCILE_WEIGHT_THRESHOLD: float = 0.58

static func needs_biome_reconciliation(terrain: int, v: VEG) -> bool:
	return int(v) != int(VEG.NONE) \
			and biome_envelope_weight(terrain, v) <= BIOME_RECONCILE_WEIGHT_THRESHOLD

# Generation and runtime share the same bounded terrain/landform prior.  These
# are soft ecological priors; climate fit remains the dominant signal and only
# physical substrate rules may hard-reject a vegetation type.
static func terrain_soft_weight(terrain: int, landform: int, v: VEG, moist: float) -> float:
	var wet: bool = v in [VEG.SAVANNA, VEG.TAIGA, VEG.TEMPERATE_STEPPE, VEG.MEDITERRANEAN_SHRUB,
		VEG.MANGROVE, VEG.SWAMP, VEG.MARSH, VEG.CLOUD_FOREST, VEG.MONSOON_FOREST,
		VEG.PEAT_BOG]
	var arid: bool = v in [VEG.TEMPERATE_STEPPE, VEG.MEDITERRANEAN_SHRUB,
		VEG.DESERT_SCRUB, VEG.XERIC_DESERT]
	var alpine: bool = v in [VEG.ALPINE_TUNDRA, VEG.ALPINE_MEADOW, VEG.TAIGA,
		VEG.BOREAL_SHRUB, VEG.TEMPERATE_CONIFER, VEG.PEAT_BOG]
	var w: float = 1.0
	match terrain:
		25: # BADLANDS
			w *= 1.10 if arid else 0.84
		28: # MOOR
			w *= 1.20 if v == VEG.PEAT_BOG else (1.08 if wet else 0.62)
		29: # FLOODPLAIN
			w *= 1.16 if wet else (0.68 if arid else 1.02)
		30: # MESA
			w *= 1.08 if arid else 0.90
		10: # SWAMP
			w *= 1.15 if wet else 0.65
		16: # MANGROVE terrain
			w *= 1.20 if v == VEG.MANGROVE else (1.05 if wet else 0.58)
		15: # SHRUBLAND terrain
			w *= 1.14 if v == VEG.MEDITERRANEAN_SHRUB else 0.92
		_:
			pass
	if landform == 7 or landform == 8: # MOUNTAIN / PEAK
		w *= 1.16 if alpine else (0.58 if arid and moist > 0.45 else 0.90)
	elif landform == 6: # HILL
		w *= 1.06 if alpine else 1.0
	return clampf(w * biome_envelope_weight(terrain, v), 0.18, 1.25)

static func suitability_score(v: VEG, temp: float, moist: float, terrain: int, landform: int) -> float:
	return climate_compat_score(v, temp, moist) * terrain_soft_weight(terrain, landform, v, moist)

# Milestone 4：演替查询。direction = +1 升级（更丰富），-1 退化（更荒凉）
# 没有下家（next == -1）或下家等于自身（自环）时返回原 v（链尾语义）。
static func next_in_succession(v: VEG, direction: int) -> VEG:
	var p := VegetationProfileRegistry.get_profile(int(v))
	var next: int = -1
	if direction > 0:
		next = p.next_richer
	elif direction < 0:
		next = p.next_harsher
	else:
		return v
	if next < 0 or next == int(v):
		return v
	return next as VEG

# climate-loop-closure Phase 3.2：气候导向退化目标。
# 退化触发时(vitality 长期偏低)，不再无脑走 next_harsher(更干/更荒)，而是在
# {next_harsher, next_richer} 两个图邻居里挑选与当前 (temp, moist) 兼容度更高者。
# 这样长期过湿压垮的喜旱植被会向 next_richer(湿生：雨林/沼泽方向)迁移，而非一路
# 退化到 NONE 后永久死亡；长期过旱则仍向 next_harsher(荒漠方向)迁移。
# 实现植被"随气候迁移"而非"单向死亡"。
static func best_degrade_target(v: VEG, temp: float, moist: float) -> VEG:
	var harsher: VEG = next_in_succession(v, -1)
	var richer: VEG = next_in_succession(v, 1)
	var best: VEG = v
	var best_score: float = -1.0
	if harsher != v:
		best = harsher
		best_score = climate_compat_score(harsher, temp, moist)
	if richer != v:
		var rs: float = climate_compat_score(richer, temp, moist)
		if rs > best_score:
			best = richer
			best_score = rs
	return best

static func best_suitability_target(v: VEG, temp: float, moist: float, terrain: int, landform: int) -> VEG:
	var harsher: VEG = next_in_succession(v, -1)
	var richer: VEG = next_in_succession(v, 1)
	var best: VEG = v
	var best_score: float = -1.0
	if harsher != v:
		best = harsher
		best_score = suitability_score(harsher, temp, moist, terrain, landform)
	if richer != v:
		var rs: float = suitability_score(richer, temp, moist, terrain, landform)
		if rs > best_score:
			best = richer
	return best

# Milestone: vegetation-survival-rebalance（方案 C）
# 查询指定植被对某种天气的抗性系数 ∈ [0, 1]。
# 未在 _WEATHER_RESISTANCE 中显式声明的组合统一返回 0.0（无抗性）。
# 调用方应用方式：penalty = base_penalty * weather_intensity * (1.0 - resistance)
static func weather_resistance(v: int, wt: int) -> float:
	if not _WEATHER_RESISTANCE.has(v):
		return 0.0
	var sub: Dictionary = _WEATHER_RESISTANCE[v]
	return float(sub.get(wt, 0.0))
