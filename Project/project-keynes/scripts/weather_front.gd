# weather_front.gd
# Milestone 3：天气锋面（一个移动的圆形天气事件实例）。
#
# 单个 front 表示一个"局地天气系统"——例如一团雷暴云、一道冷锋。
# 由 WeatherSystem 集中管理，每天 tick 一次：
#   - center 沿 wind_field 方向移动 velocity * 1day
#   - intensity 按指数衰减（lifecycle）
#   - age_days 累加，age >= ttl_days 时由 WeatherSystem 回收
#
# 一个 cell 可能同时被多个 front 影响（如冷锋叠加海风），
# 由 WeatherSystem.query_at 做 max-merge（不做线性叠加，避免数值爆炸）。

class_name WeatherFront
extends RefCounted

# --- 形态与位置 ---
var center: Vector2 = Vector2.ZERO
var radius: float = 200.0          # 影响半径（世界坐标，等价于 ~10 hex）
var velocity: Vector2 = Vector2.ZERO  # 每天移动多少世界坐标

# --- 类型与强度 ---
var type: int = WeatherType.WT.CLEAR  # WeatherType.WT
var intensity: float = 1.0            # 当前强度 [0, 1]，影响 cell.weather_intensity 上限

# --- 生命周期 ---
var ttl_days: int = 6                # 总寿命（天）
var age_days: int = 0                # 已存在天数
var decay_per_day: float = 0.12      # 每天 intensity 衰减（线性，到 0 自然死亡）

# 高斯式覆盖：中心强度 = intensity，边缘 ≈ 0。
# sigma = radius / 2，3-sigma 包络内 99% 像素被覆盖。
func coverage_at(world_pos: Vector2) -> float:
	if intensity <= 0.001 or radius <= 0.001:
		return 0.0
	var dist := world_pos.distance_to(center)
	if dist > radius * 1.6:  # 包络外完全无影响（性能优化）
		return 0.0
	var sigma := radius * 0.5
	var k : float = dist / max(sigma, 0.001)
	var falloff: float = exp(-0.5 * k * k)
	return clampf(intensity * falloff, 0.0, intensity)

# 每天推进一次（由 WeatherSystem.tick_one_day 调用）。
# wind_sample_fn(center) -> Vector2  ：从风场采样当前位置盛行风向（已归一化或近似单位向量）。
func advance_one_day(wind_sample_fn: Callable) -> void:
	# 沿盛行风方向漂移（如果给了 wind 函数；否则用初始 velocity）
	if wind_sample_fn.is_valid():
		var wind := wind_sample_fn.call(center) as Vector2
		# 锋面速度 = 风向 × 基础步长（每天大致漂 0.4×radius，确保几天内能扫过中等区域）
		if wind.length() > 0.05:
			velocity = wind.normalized() * (radius * 0.4)
	center += velocity
	# 强度线性衰减；接近末期时加速衰减
	intensity = maxf(intensity - decay_per_day, 0.0)
	age_days += 1

# 是否仍然存活（intensity 跌到 0 或寿命到期都算死亡）
func is_alive() -> bool:
	return intensity > 0.01 and age_days < ttl_days
