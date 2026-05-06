# map_config.gd
# 地图生成参数，作为 MapGenerator 的输入配置
# 可直接实例化后修改字段，或通过 MapConfig.new(...) 构造

class_name MapConfig

# 地图尺寸（单位：地块数量）
var width: int  = 60    # 横向地块数
var height: int = 40    # 纵向地块数

# 大陆生成参数
var num_continents: int   = 2      # 大陆核心数（影响大陆中心点数量）
var sea_level: float      = 0.42   # 高度图阈值；低于此值为海洋，调高→陆地增多
var continent_size: float = 0.55   # 大陆核心影响半径系数 [0.3, 0.8]

# 气候参数
var polar_ratio: float = 0.15   # 极地占地图高度的比例（两端各占 polar_ratio）

# 河流参数
var river_count: int = 5   # 尝试生成的河流数量

# 随机种子（0 = 每次使用随机种子）
var seed: int = 0

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
	polar_ratio    = clampf(polar_ratio,    0.0, 0.4)
	river_count    = clampi(river_count,    0,  30)
