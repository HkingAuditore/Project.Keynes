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

# Milestone: vegetation-survival-rebalance（方案 C）
# 查询指定植被对某种天气的抗性系数 ∈ [0, 1]。
# 未在 _WEATHER_RESISTANCE 中显式声明的组合统一返回 0.0（无抗性）。
# 调用方应用方式：penalty = base_penalty * weather_intensity * (1.0 - resistance)
static func weather_resistance(v: int, wt: int) -> float:
	if not _WEATHER_RESISTANCE.has(v):
		return 0.0
	var sub: Dictionary = _WEATHER_RESISTANCE[v]
	return float(sub.get(wt, 0.0))
