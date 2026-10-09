# wind_belt.gd
# 纬度风带模型：每个像素 / cell 根据自己的 ny 算盛行风向。
#
# 这里提供的是三圈环流背景风带：ITCZ 弱风、信风、西风带、极地东风。
# `season_phase` 只为旧调用签名保留；直接季节风向偏置已移除。季节性风场变化
# 由太阳直射点 -> 日照/热惯性 -> SLP 压力梯度 -> 科氏偏转链条产生。

class_name WindBelt

const ITCZ_HALF_WIDTH := 0.05
const TRADE_TOP := 0.40
const WEST_TOP := 0.70

const TRADE_X := -1.0
const TRADE_Y_AMP := 0.20
const WEST_X := 1.0
const WEST_Y_AMP := 0.10
const POLAR_X := -1.0
const POLAR_Y_AMP := 0.20
const ITCZ_X := -0.20

const SPEED_ITCZ := 0.15
const SPEED_TRADE := 0.85
const SPEED_WEST := 1.10
const SPEED_POLAR := 0.65


static func wind_at(ny: float, season_phase: float, lat_jitter: float = 0.0) -> Vector2:
	var _unused_phase: float = season_phase
	var lat_signed: float = (ny - 0.5) * 2.0 + lat_jitter
	var abs_lat: float = absf(lat_signed)
	var sl: float = -1.0 if lat_signed < -0.001 else (1.0 if lat_signed > 0.001 else 1.0)

	var bbh: float = 0.06
	var w_itcz_b: float = 1.0 - smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat)
	var w_trade_b: float = smoothstep(ITCZ_HALF_WIDTH - bbh, ITCZ_HALF_WIDTH + bbh, abs_lat) \
			* (1.0 - smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat))
	var w_west_b: float = smoothstep(TRADE_TOP - bbh, TRADE_TOP + bbh, abs_lat) \
			* (1.0 - smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat))
	var w_polar_b: float = smoothstep(WEST_TOP - bbh, WEST_TOP + bbh, abs_lat)
	var base: Vector2 = w_itcz_b * Vector2(ITCZ_X, 0.0) \
			+ w_trade_b * Vector2(TRADE_X, -TRADE_Y_AMP * sl) \
			+ w_west_b * Vector2(WEST_X, WEST_Y_AMP * sl) \
			+ w_polar_b * Vector2(POLAR_X, -POLAR_Y_AMP * sl)
	if base.length_squared() < 0.0001:
		return Vector2(1.0, 0.0)
	return base.normalized()


static func monsoon_offset_at(ny: float, season_phase: float) -> Vector2:
	var _unused_ny: float = ny
	var _unused_phase: float = season_phase
	return Vector2.ZERO


static func wind_speed_at(ny: float, season_phase: float) -> float:
	var _unused_phase: float = season_phase
	var lat_signed: float = (ny - 0.5) * 2.0
	var abs_lat: float = absf(lat_signed)
	var w_itcz: float = 1.0 - smoothstep(ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat)
	var w_trade: float = smoothstep(ITCZ_HALF_WIDTH - 0.03, ITCZ_HALF_WIDTH + 0.03, abs_lat) \
			* (1.0 - smoothstep(TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat))
	var w_west: float = smoothstep(TRADE_TOP - 0.04, TRADE_TOP + 0.04, abs_lat) \
			* (1.0 - smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat))
	var w_polar: float = smoothstep(WEST_TOP - 0.04, WEST_TOP + 0.04, abs_lat)
	return w_itcz * SPEED_ITCZ + w_trade * SPEED_TRADE + w_west * SPEED_WEST + w_polar * SPEED_POLAR


static func upwind_hex_dir(wind: Vector2) -> Vector3i:
	var wind_norm: Vector2 = wind.normalized()
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
