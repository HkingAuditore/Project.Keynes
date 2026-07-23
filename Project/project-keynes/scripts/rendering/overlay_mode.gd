# overlay_mode.gd
# Data Overlay 模式枚举与显示名/分类辅助常量。
#
# Overlay 系统让开发者在运行时把 HexCell 的底层数值场（温度/降水/气候带/
# 湿度/天气/植被健康度）以半透明热力图形式叠加在地图上，用于调参与可视化。
#
# 本文件是**纯数据**常量表，不持有任何节点/纹理引用；三方都依赖它：
#   - data_overlay_baker.gd  ：按 mode 决定采样哪个字段、如何写入数据纹理
#   - data_overlay.gdshader   ：按 mode uniform 选择色带 / palette
#   - ui/debug_console.gd     ：按 mode 生成下拉选项与 legend 标签
#
# 新增一个通道时只需：
#   1) 在 MODE 枚举末尾加一项
#   2) 在 DISPLAY_NAME / CATEGORY / SHORT_UNIT 里补三个条目
#   3) 在 data_overlay_baker.gd 加采样分支，在 shader 加色带分支
class_name OverlayMode

# 新增通道时只在枚举末尾追加；shader 端通过整数 uniform 比较分支，
# 值语义稳定，避免重排导致 shader/UI/baker 不同步。
enum MODE {
	NONE = 0,
	TEMPERATURE = 1,
	PRECIPITATION = 2,
	CLIMATE_ZONE = 3,
	HUMIDITY = 4,
	WEATHER = 5,
	VEGETATION_VITALITY = 6,
	OCEAN_CURRENT = 7,           # 洋流强度（连续，仅水域有效）
	OCEAN_HEAT_TRANSPORT = 8,    # 洋流热输运异常（连续，双向，0 = 中性）
	UPWELLING = 9,               # 上升流强度（连续，双向，0 = 中性）
	WIND_SPEED = 10,             # 当前物理风速（连续，全图）
	BIOME_GROUP = 11,            # 植被/Biome 分组（离散 10 档）
	LANDFORM = 12,               # 地形大类（离散 6 档）
	WIND_DIR = 13,               # 风向（地形扰动后；色相=方向，亮度=强度）
	OCEAN_CURRENT_DIR = 14,      # 洋流方向（色相=方向，亮度=强度；仅水域）
	# Physical Wind & Ocean Circulation 调试通道：仅在 ClimateProfile.physical_circulation_enabled
	# = true 时与资源字段同步填充；其余路径这三个 cell.* 字段保持 0。
	SLP = 15,                    # 海平面压力（双向，0=中性；高压为暖色 / 低压为冷色）
	WIND_STRESS_CURL = 16,       # 风应力旋度（双向，0=中性；正=逆时针 / 负=顺时针）
	OCEAN_PSI = 17,              # 流函数 ψ（双向，高低表示反气旋 / 气旋环流）
	# Reference-impl Pass #2 (demo-only, performance-charter §12.6)：
	#   仅在 ClimateProfile.demo_thermal_gradient_enabled = true 时由 main.gd
	#   主动注入到 UI 下拉菜单。开关关闭时 baker 仍然兼容（采样到 size=0 SoA
	#   时直接画零），但下拉菜单不应展示该项以避免误导。
	DEMO_THERMAL_GRADIENT = 18,  # 温度梯度热应力场（demo, 连续 [0,1]）
	ELEVATION = 19,              # 玩家地图：权威海拔
	VEGETATION_TYPE = 20,        # 玩家地图：当前植被类型
	RESOURCE_RESERVE = 21,       # 玩家地图：所选自然资源储量
}

# VECTOR 类通道：方向用色相、强度用亮度。它们既不是离散调色板（DISCRETE）
# 也不是单值色带（CONTINUOUS），baker 把 R=hue、G=value 编码进去，shader 用 hsv2rgb
# 还原。统计/图例/指针逻辑都按此分支单独处理。
enum VECTOR_KIND { NOT_VECTOR, WIND, OCEAN_CURRENT }

# 通道的渲染类别：
#   CONTINUOUS — shader 端用连续色带 ramp（按归一化 value 取色）
#   DISCRETE   — shader 端用离散 palette 数组（按整数类别查表）
enum CATEGORY_KIND {
	CONTINUOUS,
	DISCRETE,
}

# 中文显示名（UI / Legend 标题共用，沿用 RightPanel 的语言风格）。
const DISPLAY_NAME: Dictionary = {
	MODE.NONE: "关闭",
	MODE.TEMPERATURE: "温度",
	MODE.PRECIPITATION: "实时降水",
	MODE.CLIMATE_ZONE: "气候带",
	MODE.HUMIDITY: "湿度",
	MODE.WEATHER: "天气",
	MODE.VEGETATION_VITALITY: "植被健康度",
	MODE.OCEAN_CURRENT: "洋流强度",
	MODE.OCEAN_HEAT_TRANSPORT: "洋流热输运",
	MODE.UPWELLING: "上升流",
	MODE.WIND_SPEED: "风速",
	MODE.BIOME_GROUP: "植被类型",
	MODE.LANDFORM: "地形大类",
	MODE.WIND_DIR: "风向",
	MODE.OCEAN_CURRENT_DIR: "洋流方向",
	MODE.SLP: "海平压力",
	MODE.WIND_STRESS_CURL: "风应力旋度",
	MODE.OCEAN_PSI: "流函数 ψ",
	MODE.DEMO_THERMAL_GRADIENT: "热梯度（demo）",
	MODE.ELEVATION: "海拔",
	MODE.VEGETATION_TYPE: "植被",
	MODE.RESOURCE_RESERVE: "自然资源",
}

# 连续通道的数值两端标签（Legend 显示用）。离散通道留空。
const RANGE_LABEL: Dictionary = {
	MODE.TEMPERATURE: ["0.00", "1.00"],
	MODE.PRECIPITATION: ["0.00", "1.00"],
	MODE.HUMIDITY: ["0.00", "1.00"],
	MODE.VEGETATION_VITALITY: ["0.00", "1.00"],
	MODE.OCEAN_CURRENT: ["0", "强"],         # 归一化模长：0 = 静水 / 陆地无效
	MODE.OCEAN_HEAT_TRANSPORT: ["冷输入", "暖输入"], # 双向：0.5 = 中性
	MODE.UPWELLING: ["下沉", "上升"],          # 双向：0.5 = 中性
	MODE.WIND_SPEED: ["0", "强"],            # 归一化合成模长
	MODE.WIND_DIR: ["弱", "强"],            # 亮度=强度；方向用色环单独图例
	MODE.OCEAN_CURRENT_DIR: ["弱", "强"],   # 同上
	MODE.SLP: ["低压", "高压"],
	MODE.WIND_STRESS_CURL: ["负涊", "正涊"],
	MODE.OCEAN_PSI: ["顺时针", "逆时针"],
	MODE.DEMO_THERMAL_GRADIENT: ["0.00", "1.00"],
	MODE.ELEVATION: ["深海", "高峰"],
	MODE.RESOURCE_RESERVE: ["稀少", "丰富"],
}

# 通道适用域 / 无效区域提示。DebugConsole 与 OverlayLegend 用它区分
# “没有数据”和“该地块类型不适用 / 强度太低无方向”。
const DOMAIN_HINT: Dictionary = {
	MODE.VEGETATION_VITALITY: "仅陆地有效；水域透明不是缺数据。",
	MODE.OCEAN_CURRENT: "仅水域有效；陆地透明，近零洋流会显示很暗。",
	MODE.OCEAN_HEAT_TRANSPORT: "仅水域有效；陆地透明，0.5 为中性热输运。",
	MODE.UPWELLING: "仅水域有效；陆地透明，0.5 为中性。",
	MODE.WIND_DIR: "风速接近 0 时方向无意义，会记为 invalid。",
	MODE.OCEAN_CURRENT_DIR: "仅水域有效；静水或陆地无方向，会记为 invalid。",
	MODE.WIND_STRESS_CURL: "仅水域有效；陆地透明，0.5 为中性。",
	MODE.OCEAN_PSI: "仅水域有效；陆地透明，0.5 为中性。",
	MODE.DEMO_THERMAL_GRADIENT: "仅 demo 数据存在时有效；数组为空会透明。",
	MODE.RESOURCE_RESERVE: "零储量、不适生或不适用地区保持透明。",
}


const CATEGORY: Dictionary = {
	MODE.NONE: CATEGORY_KIND.CONTINUOUS,
	MODE.TEMPERATURE: CATEGORY_KIND.CONTINUOUS,
	MODE.PRECIPITATION: CATEGORY_KIND.CONTINUOUS,
	MODE.CLIMATE_ZONE: CATEGORY_KIND.DISCRETE,
	MODE.HUMIDITY: CATEGORY_KIND.CONTINUOUS,
	MODE.WEATHER: CATEGORY_KIND.DISCRETE,
	MODE.VEGETATION_VITALITY: CATEGORY_KIND.CONTINUOUS,
	MODE.OCEAN_CURRENT: CATEGORY_KIND.CONTINUOUS,
	MODE.OCEAN_HEAT_TRANSPORT: CATEGORY_KIND.CONTINUOUS,
	MODE.UPWELLING: CATEGORY_KIND.CONTINUOUS,
	MODE.WIND_SPEED: CATEGORY_KIND.CONTINUOUS,
	MODE.BIOME_GROUP: CATEGORY_KIND.DISCRETE,
	MODE.LANDFORM: CATEGORY_KIND.DISCRETE,
	# WIND_DIR / OCEAN_CURRENT_DIR 用 VECTOR 编码（hue=方向、value=强度）；
	# 在分类上仍归 CONTINUOUS，避免 baker / legend 走离散桶分支；is_vector(m)
	# 判定它们的特殊渲染方式。
	MODE.WIND_DIR: CATEGORY_KIND.CONTINUOUS,
	MODE.OCEAN_CURRENT_DIR: CATEGORY_KIND.CONTINUOUS,
	MODE.SLP: CATEGORY_KIND.CONTINUOUS,
	MODE.WIND_STRESS_CURL: CATEGORY_KIND.CONTINUOUS,
	MODE.OCEAN_PSI: CATEGORY_KIND.CONTINUOUS,
	MODE.DEMO_THERMAL_GRADIENT: CATEGORY_KIND.CONTINUOUS,
	MODE.ELEVATION: CATEGORY_KIND.CONTINUOUS,
	MODE.VEGETATION_TYPE: CATEGORY_KIND.DISCRETE,
	MODE.RESOURCE_RESERVE: CATEGORY_KIND.CONTINUOUS,
}

# 气候带离散档位（与 main.gd 的 _climate_zone_name 同口径：按 |ny-0.5| 分 5 档）。
# 阈值对应 |ny - 0.5|：0.0 开始 → 热带；0.5 末端 → 极地。
const CLIMATE_ZONE_NAMES: Array = [
	"热带", "副热带", "温带", "副极地", "极地",
]

# WeatherType.WT 的展示名（CLEAR 透明处理，不在图例列出）。
const WEATHER_NAMES: Array = [
	"晴朗", "雨", "雷暴", "暴风雪", "干旱", "雾", "热浪", "热带暴雨",
]

# BIOME_GROUP 通道：把 TerrainType.TERRAIN 的 27 种细粒度地形聚合成 10 类
# 大类，避免离散调色板膨胀到难以辨认。索引 = bucket id（与 baker 写入 R 通
# 道的整数一致，与 shader 的 BIOME_GROUP_COLORS[10] 一一对应）。
const BIOME_GROUP_NAMES: Array = [
	"深海/远海",       # 0  OCEAN
	"海冰",           # 1  SEA_ICE / GLACIER
	"海岸礁滩",        # 2  COAST / REEF / KELP / MANGROVE / DELTA
	"内陆水",          # 3  LAKE / OASIS
	"开阔陆面",        # 4  PLAIN / GRASSLAND / STEPPE
	"林地",           # 5  FOREST / TAIGA / JUNGLE / SHRUBLAND / SWAMP / SAVANNA
	"高地/山岭",       # 6  HILL / MOUNTAIN
	"干旱荒漠",        # 7  DESERT / SALT_FLAT / BADLANDS
	"寒带/冰雪",       # 8  TUNDRA / SNOW
	"未分类",         # 9  fallback
]

# LANDFORM 通道：当前权威 LandformType.LF 的稳定顺序，不回退到 legacy terrain。
const LANDFORM_NAMES: Array = [
	"深海", "海洋", "海岸", "湖泊", "平原", "低地", "丘陵", "山地",
	"高峰", "三角洲", "荒原", "盐滩", "火山", "高原", "裂谷", "峡谷",
]

# TERRAIN id → BIOME_GROUP bucket。新增地形需要补一项；漏项 fallback 到 9。
# 顺序与 TerrainType.TERRAIN 一一对应（OCEAN=0 ... BADLANDS=25 ... MESA=30）。
# 注：这里不用 PackedByteArray——GDScript 静态类型检查在跨脚本访问时无法
# 解析以构造函数赋值的 const 成员（报 "Could not resolve external
# class member"），改用普通 Array 字面量。
const TERRAIN_TO_BIOME_GROUP: Array = [
	0,  # OCEAN
	2,  # COAST
	4,  # PLAIN
	4,  # GRASSLAND
	5,  # FOREST
	6,  # HILL
	6,  # MOUNTAIN
	7,  # DESERT
	8,  # TUNDRA
	8,  # SNOW
	5,  # SWAMP
	5,  # JUNGLE
	5,  # SAVANNA
	5,  # TAIGA
	4,  # STEPPE
	5,  # SHRUBLAND
	2,  # MANGROVE
	1,  # GLACIER
	3,  # LAKE
	2,  # REEF
	1,  # SEA_ICE
	2,  # KELP
	2,  # DELTA
	3,  # OASIS
	7,  # SALT_FLAT
	7,  # BADLANDS
	7,  # COLD_DESERT（干旱组）
	5,  # CHAPARRAL（硬叶灌丛 → 林灌组）
	5,  # MOOR（泥炭湿原 → 湿生组）
	4,  # FLOODPLAIN（冲积平原 → 平原组）
	7,  # MESA（方山 → 干旱组）
]

# TERRAIN id → LANDFORM bucket（同上，漏项 fallback 到 2 = 平原）。
const TERRAIN_TO_LANDFORM: Array = [
	0,  # OCEAN
	1,  # COAST
	2,  # PLAIN
	2,  # GRASSLAND
	2,  # FOREST
	3,  # HILL
	4,  # MOUNTAIN
	2,  # DESERT
	5,  # TUNDRA
	5,  # SNOW
	2,  # SWAMP
	2,  # JUNGLE
	2,  # SAVANNA
	2,  # TAIGA
	2,  # STEPPE
	2,  # SHRUBLAND
	1,  # MANGROVE
	5,  # GLACIER
	1,  # LAKE
	1,  # REEF
	5,  # SEA_ICE
	1,  # KELP
	1,  # DELTA
	1,  # OASIS
	2,  # SALT_FLAT
	3,  # BADLANDS
	2,  # COLD_DESERT（平原台地）
	2,  # CHAPARRAL（平原/丘缓坡）
	2,  # MOOR（低地湿原）
	2,  # FLOODPLAIN（冲积平原）
	3,  # MESA（高差台地 → 丘陵）
]

# 工具：返回有序的 mode 列表（供 UI 下拉按此顺序生成）。
static func ordered_modes() -> Array:
	return [
		MODE.NONE,
		MODE.TEMPERATURE,
		MODE.PRECIPITATION,
		MODE.CLIMATE_ZONE,
		MODE.HUMIDITY,
		MODE.WEATHER,
		MODE.VEGETATION_VITALITY,
		MODE.OCEAN_CURRENT,
		MODE.OCEAN_HEAT_TRANSPORT,
		MODE.UPWELLING,
		MODE.WIND_SPEED,
		MODE.BIOME_GROUP,
		MODE.LANDFORM,
		MODE.WIND_DIR,
		MODE.OCEAN_CURRENT_DIR,
		MODE.SLP,
		MODE.WIND_STRESS_CURL,
		MODE.OCEAN_PSI,
		MODE.DEMO_THERMAL_GRADIENT,
		MODE.ELEVATION,
		MODE.VEGETATION_TYPE,
	]

static func display_name(m: int) -> String:
	return DISPLAY_NAME.get(m, "未知")

static func domain_hint(m: int) -> String:
	return DOMAIN_HINT.get(m, "")

static func is_discrete(m: int) -> bool:

	return int(CATEGORY.get(m, CATEGORY_KIND.CONTINUOUS)) == CATEGORY_KIND.DISCRETE

# 是否为方向型（色相=方向、亮度=强度）通道。
# baker 走 hue/value 编码分支；shader 走 hsv2rgb 分支；legend 显示色环图例。
static func vector_kind(m: int) -> int:
	match m:
		MODE.WIND_DIR:
			return VECTOR_KIND.WIND
		MODE.OCEAN_CURRENT_DIR:
			return VECTOR_KIND.OCEAN_CURRENT
		_:
			return VECTOR_KIND.NOT_VECTOR

static func is_vector(m: int) -> bool:
	return vector_kind(m) != VECTOR_KIND.NOT_VECTOR
