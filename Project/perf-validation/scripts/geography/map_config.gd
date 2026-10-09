# map_config.gd
# 地图生成参数，作为 MapGenerator 的输入配置
# 可直接实例化后修改字段，或通过 MapConfig.new(...) 构造

class_name MapConfig

# 地图尺寸（单位：地块数量）
var width: int  = 80    # 横向地块数
var height: int = 60    # 纵向地块数

# 大陆生成参数
var num_continents: int   = 3      # 大陆核心数（影响大陆中心点数量）
var sea_level: float      = 0.64   # 高度图阈值；低于此值为海洋，调高→陆地增多
var continent_size: float = 0.9   # 大陆核心影响半径系数 [0.3, 0.8]

# 河流参数
# 注意：当前 native 生成不读取 river_count 作为输入；河流密度由
# ClimateProfile.river_flow_percentile 控制，此字段仅保留为生成结果统计/兼容。
var river_count: int = 5

# 随机种子（0 = 每次使用随机种子）
var seed: int = 0

# 地图来源：procedural 走 native full_pass；pkmap 读作者编译包并硬中止失败（无程序生成回退）
var map_source: String = "procedural"
var pkmap_path: String = ""

# --- Systemic Ocean Currents 开关 ──────────────────────────────────────
# 主开关：关闭时跳过 _apply_ocean_heat_transport_pass、海冰的洋流修正、
# 海洋生物的 upwelling 放宽、F7 调试层。仅保留视觉洋流（旧行为）。
var enable_ocean_heat_transport: bool = true

# 可选：天气事件瞬时涡旋扰动（台风尾迹）。默认关闭，排期紧张时不阻塞主需求。
var enable_cyclone_wake: bool = false

# --- Systemic Ocean Currents 常量 ──────────────────────────────────────
# 烘焙阶段的热盐驱动项权重：越大，南北经向分量越强（模拟 AMOC 趋势）。
var THERMOHALINE_WEIGHT: float = 0.25
# 高纬冷水下沉判定温度阈值（单位与 baked_temperature_buffer 一致）。
var COLD_SINK_TEMP: float = -0.05

# _apply_ocean_heat_transport_pass 参数：
# 沿 -ocean_current 回溯的最大 cell 数（越大传播越远，但耗时线性增长）。
var OCEAN_HEAT_ADVECT_STEPS: int = 3
# 每步与上游温度的混合系数。
var OCEAN_HEAT_MIX: float = 0.55
# 沿岸水→陆热量泄漏权重（基础）；不再叠加独立冬季倍率。
var COASTAL_HEAT_LEAK: float = 0.55

# 海冰修正：暖流输运异常×此系数后加到有效温度上用于与结冰阈值比较。
var OCEAN_CURRENT_ICE_DELAY: float = 1.0

# --- Wind Temperature Coupling：风温耦合配置（对称复刻洋流热输运） ---
# 沿 -wind_vector 回溯的最大 cell 数（越大传播越远，但耗时线性增长）。
var WIND_HEAT_ADVECT_STEPS: int = 3
# 每步与上游气团温度的混合系数。
var WIND_HEAT_MIX: float = 0.25
# 气团温度异常对下游气温的影响权重（基础）。
var AIR_MASS_HEAT_LEAK: float = 0.35
# 风温异常对海冰的影响系数。
var WIND_CURRENT_ICE_DELAY: float = 1.0

# 台风尾迹持续天数（仅当 enable_cyclone_wake = true 时生效）。
var CYCLONE_WAKE_DAYS: int = 3

# --- Physical Wind & Ocean Circulation：运行时引用（非持久化） ─────────
# 由 MapGenerator 在初始化时把当前激活的 ClimateProfile 引用注入进来，
# MapBaker / OceanCurrentsJob 等下游通过 cfg.climate_profile 读取
# physical_circulation_enabled / enable_terrain_aware_wind /
# enable_ocean_heat_transport 三个开关。不通过 @export 持久化——避免与
# MapGenerator 上的 @export var climate_profile 出现两份配置不一致。
# 默认 null 时下游走 ny-only 旧路径（最大化向后兼容）。
var climate_profile: ClimateProfile = null

# --- 便捷构造 ---
static func make(w: int, h: int) -> MapConfig:
	var cfg := MapConfig.new()
	cfg.width  = w
	cfg.height = h
	return cfg

# --- 验证并修正参数到合法范围 ---
func validate() -> void:
	width          = clampi(width,          10, 500)
	height         = clampi(height,         8,  400)
	num_continents = clampi(num_continents, 1,  8)
	sea_level      = clampf(sea_level,      0.1, 0.8)
	continent_size = clampf(continent_size, 0.2, 0.9)
	river_count    = clampi(river_count,    0,  30)
