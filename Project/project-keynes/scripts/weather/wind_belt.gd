# wind_belt.gd
# 纬度风带模型：每个像素 / cell 根据自己的 ny 算自己的盛行风向。
#
# 现实地球的风带（北半球；南半球以赤道为轴 y 镜像）：
#   赤道无风带 ITCZ（abs_lat < 0.05）：弱风
#   信风带      Trade winds（abs_lat ∈ [0.05, 0.40)）：从东吹向西，向赤道偏
#   西风带      Westerlies（abs_lat ∈ [0.40, 0.70)）：从西吹向东，向极偏
#   极地东风带  Polar easterlies（abs_lat >= 0.70）：从东吹向西，向赤道偏
#
# 季风：低纬度（abs_lat < 0.40）的 y 分量随当地半球的"季节相位"反转，
# 模拟印度洋 / 东亚季风（夏季吹向陆地，冬季吹离陆地）。
#
# 坐标约定（与 map_generator 一致）：
#   ny = 0 → 北极（屏幕上方），ny = 1 → 南极（屏幕下方）
#   lat_signed = (ny - 0.5) × 2 → 北半球 -1..0，南半球 0..+1
#   sl = signf(lat_signed)：北半球 -1，南半球 +1
#
#   wind.x > 0 = 向东，wind.x < 0 = 向西
#   wind.y > 0 = 向南（屏幕下方），wind.y < 0 = 向北
#
# Plan B 日历对齐约定：
#   season_phase = 0 → 1 月 1 日（北半球冬至；南半球夏至）
#   season_phase = 2 → 7 月 1 日（北半球夏至；南半球冬至）
#   hemi_phase 定义为本地季节语义（本地春=0、本地夏=1、本地秋=2、本地冬=3）：
#     北半球 (lat_signed < 0): hemi_phase = fposmod(season_phase - 1, 4)
#     南半球 (lat_signed >= 0): hemi_phase = fposmod(season_phase + 1, 4)
#
# 推导：
#   北半球 (sl = -1) 信风：吹向 SW = (-1, +y)。y 应为正。-0.20 × sl = -0.20 × -1 = +0.20。✓
#   南半球 (sl = +1) 信风：吹向 NW = (-1, -y)。y 应为负。-0.20 × +1 = -0.20。✓
#
# 用法：
#   var wind: Vector2 = WindBelt.wind_at(ny, season_phase)
#   var wind: Vector2 = WindBelt.wind_at(ny, season_phase, lat_jitter)  # lat_jitter 让风带边界呈犬牙交错

class_name WindBelt

const ITCZ_HALF_WIDTH := 0.05      # 赤道无风带宽度
const TRADE_TOP := 0.40            # 信风带上界（abs_lat）
const WEST_TOP := 0.70             # 西风带上界（abs_lat）

const TRADE_X := -1.0
const TRADE_Y_AMP := 0.20          # 信风的 y 分量幅度
const WEST_X := 1.0
const WEST_Y_AMP := 0.10           # 西风的 y 分量幅度
const POLAR_X := -1.0
const POLAR_Y_AMP := 0.20          # 极地东风的 y 分量幅度
const ITCZ_X := -0.20              # ITCZ 弱东向漂移

# 季风强度：低纬度 y 分量在夏冬最多被加上 ±MONSOON_AMP
const MONSOON_AMP := 0.6

# 各风带的相对"强度系数"，仅供 wind_speed_at() 使用。
# 注意：wind_at() 总是 normalize 后输出（服务于风向场 / 云 advection），
# 所以"风速"语义不能从 wind_at() 反推。这里按照现实大气环流的相对量级硬编：
#   西风带 > 信风带 ≈ 极地东风带 > ITCZ
# 数值不是物理 m/s，只是相对量纲，配合 OverlayMode 的归一化色带显示。
const SPEED_ITCZ := 0.15
const SPEED_TRADE := 0.85
const SPEED_WEST := 1.10
const SPEED_POLAR := 0.65

# 计算给定纬度 ny 处的盛行风向（已归一化）
# season_phase ∈ [0, 4)：0=1月 1=4月 2=7月 3=10月（Plan B 日历约定；北半球冬至在 phase=0）
# lat_jitter：可选纬度扰动（+/- 0.05 量级），让风带边界不死板
static func wind_at(ny: float, season_phase: float, lat_jitter: float = 0.0) -> Vector2:
	var lat_signed: float = (ny - 0.5) * 2.0 + lat_jitter
	var abs_lat: float = absf(lat_signed)
	# sl: 半球符号；赤道附近用 +1 当默认避免 0 引发的方向歧义
	var sl: float = -1.0 if lat_signed < -0.001 else (1.0 if lat_signed > 0.001 else 1.0)

	# 2026-05 重构：把硬分段切换替换为 smoothstep 加权混合，让风带边界
	# 不再"刀切"。过渡半宽 ~ 0.06 ny，比原 wind_speed_at 的 0.03~0.04 略宽，
	# 避免方向场出现锯齿带；同时仍然能在 overlay 上看到清晰的"信风/西风/极地"
	# 主带颜色。
	var bbh: float = 0.06   # _BAND_BLEND_HALF
	var w_itcz_b: float = 1.0 - smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat)
	var w_trade_b: float = smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat) \
		* (1.0 - smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat))
	var w_west_b: float = smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat) \
		* (1.0 - smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat))
	var w_polar_b: float = smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat)
	var v_itcz: Vector2 = Vector2(ITCZ_X, 0.0)
	var v_trade: Vector2 = Vector2(TRADE_X, -TRADE_Y_AMP * sl)
	var v_west: Vector2 = Vector2(WEST_X, +WEST_Y_AMP * sl)
	var v_polar: Vector2 = Vector2(POLAR_X, -POLAR_Y_AMP * sl)
	var base: Vector2 = w_itcz_b * v_itcz + w_trade_b * v_trade + w_west_b * v_west + w_polar_b * v_polar

	# 季风 y 偏置（仅低纬度）：summer 时 polar-ward，winter 时 equator-ward
	# Plan B：hemi_phase 表示本地季节语义（本地春=0、本地夏=1、本地秋=2、本地冬=3）：
	#   北半球 (lat_signed < 0): hemi_phase = fposmod(season_phase - 1, 4)
	#   南半球 (lat_signed >= 0): hemi_phase = fposmod(season_phase + 1, 4)
	var hemi_phase: float
	if lat_signed < 0.0:
		hemi_phase = fposmod(season_phase - 1.0, 4.0)
	else:
		hemi_phase = fposmod(season_phase + 1.0, 4.0)
	# 季风极性：sin(hemi_phase × π/2)
	#   spring(0) → 0, summer(1) → +1, autumn(2) → 0, winter(3) → -1
	# +1 = local summer → polar-ward；-1 = local winter → equator-ward
	var monsoon_polarity: float = sin(hemi_phase * 0.5 * PI)
	# tropical_w：abs_lat 越小（越靠赤道）权重越大
	var tropical_w: float = smoothstep(TRADE_TOP, ITCZ_HALF_WIDTH, abs_lat)
	# 在 Godot 屏幕坐标里 +y = 下 = 南。
	# polar_y_unit：
	#   北半球 (sl = -1)：北极在屏幕上方 → polar_y = -1 = sl
	#   南半球 (sl = +1)：南极在屏幕下方 → polar_y = +1 = sl
	# y_offset = monsoon × tropical_w × MONSOON_AMP × sl
	#   NH summer (monsoon=+1, sl=-1) → -0.6w（向北 = polar-ward）✓
	#   NH winter (monsoon=-1, sl=-1) → +0.6w（向南 = equator-ward）✓
	#   SH summer (monsoon=+1, sl=+1) → +0.6w（向南 = polar-ward）✓
	var y_offset: float = monsoon_polarity * tropical_w * MONSOON_AMP * sl

	var w: Vector2 = base + Vector2(0.0, y_offset)
	if w.length_squared() < 0.0001:
		return Vector2(1.0, 0.0)
	return w.normalized()

# Phase D：单独提取"季节性季风偏置向量"（不含 base wind，未归一化）。
# 给 weather_system 在 CPU 端动态融合 wind_field_buffer（夏季基线静态烘焙）+
# 当前季节的 monsoon offset 用，让季风方向真正随季节切换。
#
# 同时把 monsoon_polarity 从单纯 sin(hemi*π/2) 升级为 cubic ease-in-out，
# 在 spring/autumn 等分点附近梯度更平缓，让"夏 → 秋 → 冬"过渡看起来不像
# 中间停顿一下又突然反向，而是连续渐变。
#
# 数学上：sin 在 hemi=0/2/4 处导数最大，肉眼上"过零点"瞬间方向变化最快；
# 用 sin(x) * smoothstep(0, 1, |sin(x)|) 等价于 sin³ 形态——零附近更平、
# 极点附近更稳。
static func monsoon_offset_at(ny: float, season_phase: float) -> Vector2:
	var lat_signed: float = (ny - 0.5) * 2.0
	var abs_lat: float = absf(lat_signed)
	if abs_lat >= TRADE_TOP:
		return Vector2.ZERO  # 仅低纬度有季风
	var sl: float = -1.0 if lat_signed < -0.001 else (1.0 if lat_signed > 0.001 else 1.0)
	# Plan B：hemi_phase 为本地季节语义，与 wind_at() 同源。
	var hemi_phase: float
	if lat_signed < 0.0:
		hemi_phase = fposmod(season_phase - 1.0, 4.0)
	else:
		hemi_phase = fposmod(season_phase + 1.0, 4.0)
	var raw_sin: float = sin(hemi_phase * 0.5 * PI)
	# Cubic ease：保留 sign，但在中段 plateau，零附近更平。
	var monsoon_polarity: float = raw_sin * raw_sin * raw_sin * 1.0 + raw_sin * 0.0
	# 注意：raw_sin³ 已经是 [-1, 1]，比 raw_sin 在极点附近更平、零附近更平。
	# 实际幅度比 sin 略小（max=1, mean 偏小），用 1.18 系数补偿。
	monsoon_polarity = clampf(monsoon_polarity * 1.18, -1.0, 1.0)
	var tropical_w: float = smoothstep(TRADE_TOP, ITCZ_HALF_WIDTH, abs_lat)
	var y_offset: float = monsoon_polarity * tropical_w * MONSOON_AMP * sl
	return Vector2(0.0, y_offset)

# Phase F：给 WIND_SPEED Overlay 用的"物理量级"风速场。
#
# wind_at() 始终 normalize（服务于 advection），不能反推风速；这里直接基于
# 风带分类输出相对强度，再在带边界做平滑过渡，并叠加 monsoon 的 y 分量幅度。
# 返回值未归一化，调用方按需 / WIND_SPEED_NORM_MAX 钳到 [0, 1]。
#
# 经验值域：约 [0.15, 1.7]（夏季信风+季风峰值最大）。
static func wind_speed_at(ny: float, season_phase: float) -> float:
	var lat_signed: float = (ny - 0.5) * 2.0
	var abs_lat: float = absf(lat_signed)
	# 风带基础强度（带边界用 smoothstep 平滑，避免硬条纹）。
	# 用 0.04 半带宽过渡，比硬阈值好看，但带本身仍清晰可辨。
	var w_itcz: float = 1.0 - smoothstep(ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat)
	var w_trade: float = smoothstep(ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat) \
		* (1.0 - smoothstep(TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat))
	var w_west: float = smoothstep(TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat) \
		* (1.0 - smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat))
	var w_polar: float = smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat)
	var base_speed: float = (
		w_itcz * SPEED_ITCZ
		+ w_trade * SPEED_TRADE
		+ w_west * SPEED_WEST
		+ w_polar * SPEED_POLAR
	)
	# 叠加季风 y 偏置幅度（只在低纬度有，最大 ≈ MONSOON_AMP * tropical_w）。
	var monsoon: Vector2 = monsoon_offset_at(ny, season_phase)
	# 现实里季风期会强化总风速；这里简单合成"基础速 + |季风分量|"。
	return base_speed + absf(monsoon.y)

# 给一个 Vector2 wind 找最接近的 hex 邻居方向（cube 坐标），用于雨影 lookback。
# pointy-top hex：x = sqrt(3)·size·(q + r/2)，y = 1.5·size·r
# 取 wind 的反方向当 upwind direction，然后在 6 个 cube 方向里找夹角最小的。
static func upwind_hex_dir(wind: Vector2) -> Vector3i:
	var wind_norm: Vector2 = wind.normalized()
	# 把 wind 转到 cube 浮点
	var wind_q: float = sqrt(3.0) / 3.0 * wind_norm.x - wind_norm.y / 3.0
	var wind_r: float = 2.0 / 3.0 * wind_norm.y
	var wind_cube_v3 := Vector3(wind_q, wind_r, -wind_q - wind_r)
	if wind_cube_v3.length() < 0.0001:
		return HexUtils.CUBE_DIRECTIONS[0]
	var upwind_cube := -wind_cube_v3.normalized()
	var best_dir: Vector3i = HexUtils.CUBE_DIRECTIONS[0]
	var best_dot: float = -INF
	for dir: Vector3i in HexUtils.CUBE_DIRECTIONS:
		var d_norm := Vector3(float(dir.x), float(dir.y), float(dir.z)).normalized()
		var dot: float = upwind_cube.dot(d_norm)
		if dot > best_dot:
			best_dot = dot
			best_dir = dir
	return best_dir
