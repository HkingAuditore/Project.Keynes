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

# 计算给定纬度 ny 处的盛行风向（已归一化）
# season_phase ∈ [0, 4)：0=春 1=夏 2=秋 3=冬（北半球视角；南半球内部反相）
# lat_jitter：可选纬度扰动（+/- 0.05 量级），让风带边界不死板
static func wind_at(ny: float, season_phase: float, lat_jitter: float = 0.0) -> Vector2:
	var lat_signed: float = (ny - 0.5) * 2.0 + lat_jitter
	var abs_lat: float = absf(lat_signed)
	# sl: 半球符号；赤道附近用 +1 当默认避免 0 引发的方向歧义
	var sl: float = -1.0 if lat_signed < -0.001 else (1.0 if lat_signed > 0.001 else 1.0)

	var base: Vector2
	if abs_lat < ITCZ_HALF_WIDTH:
		base = Vector2(ITCZ_X, 0.0)
	elif abs_lat < TRADE_TOP:
		base = Vector2(TRADE_X, -TRADE_Y_AMP * sl)         # 信风：向赤道偏
	elif abs_lat < WEST_TOP:
		base = Vector2(WEST_X, +WEST_Y_AMP * sl)           # 西风：向极偏
	else:
		base = Vector2(POLAR_X, -POLAR_Y_AMP * sl)         # 极地东风：向赤道偏

	# 季风 y 偏置（仅低纬度）：summer 时 polar-ward，winter 时 equator-ward
	# 半球反相：与 shader hemi_phase 和 _season_temp_offset 保持同一约定
	#   south hemi (lat_signed >= 0) 直接用 phase
	#   north hemi (lat_signed < 0)  用 phase + 2
	var hemi_phase: float = season_phase
	if lat_signed < 0.0:
		hemi_phase = fposmod(season_phase + 2.0, 4.0)
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
