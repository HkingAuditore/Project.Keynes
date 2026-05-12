# weather_front.gd
class_name WeatherFront
extends RefCounted

const _MAX_AXIS_TURN_RADIANS: float = 0.383972  # 22 degrees per simulation day

# I2.A.5（DataCore ECB pool-aware）：world_idx 是 WeatherFront 在 DCWorld
# entity 池中的绝对 idx；由 weather_refresh_job 在 sync 阶段通过
# CommandBuffer.create_in_pool 申请并写回。
#
# 【框架内部字段，业务代码禁止读】
#   - 仅 weather_refresh_job 的 sync 路径（与未来的 query 消费者）允许读；
#   - weather_system 的 spawn / advance / decay / coverage_at 等业务逻辑
#     绝不许出现 `front.world_idx`；
#   - 该字段在 P1-⑤ "WeatherFront 数据 SoA 化"阶段会升级为"瘦句柄"（届
#     时业务代码会经由 world.view_*(comp)[front.world_idx] 合法引用），
#     现在加这条纪律是为了避免未来反向 grep 出大量"业务代码污染"。
#   - -1 表示尚未被 ECB 分配（首版只有 sync 函数会赋非 -1 值）。
var world_idx: int = -1
var center: Vector2 = Vector2.ZERO
var radius: float = 200.0
var velocity: Vector2 = Vector2.ZERO
var axis: Vector2 = Vector2.RIGHT
var stable_axis: Vector2 = Vector2.RIGHT
var major_scale: float = 1.0
var minor_scale: float = 1.0
var edge_seed: float = 0.0

var type: int = WeatherType.WT.CLEAR
var intensity: float = 1.0

var ttl_days: int = 6
var age_days: int = 0
var decay_per_day: float = 0.12

var life_progress: float = 0.0
var cloud_amount: float = 1.0
var precip_amount: float = 1.0
var dissolve_amount: float = 0.0

func coverage_at(world_pos: Vector2) -> float:
	if intensity <= 0.001 or radius <= 0.001:
		return 0.0
	var local := world_pos - center
	var ax := normalized_axis()
	var ay := Vector2(-ax.y, ax.x)
	var major := maxf(radius * major_scale, 0.001)
	var minor := maxf(radius * minor_scale, 0.001)
	var x := local.dot(ax) / major
	var y := local.dot(ay) / minor
	var ellipse_dist := sqrt(x * x + y * y)
	if ellipse_dist > 1.6:
		return 0.0

	var k: float = ellipse_dist / 0.5
	var falloff: float = exp(-0.5 * k * k)
	if ellipse_dist > 0.62:
		var edge_t: float = smoothstep(0.62, 1.38, ellipse_dist)
		var n: float = _edge_noise(world_pos)
		var edge_break: float = lerpf(1.0, lerpf(0.58, 1.0, n), edge_t)
		falloff *= edge_break
	return clampf(intensity * falloff, 0.0, intensity)

func normalized_axis() -> Vector2:
	var ax := stable_axis if stable_axis.length_squared() > 0.0001 else axis
	if ax.length_squared() <= 0.0001:
		return Vector2.RIGHT
	return ax.normalized()

func bounding_radius() -> float:
	var dissolve_expand: float = 1.0 + dissolve_amount * 0.28
	return radius * maxf(maxf(major_scale, minor_scale), 1.0) * dissolve_expand

func advance_one_day(wind_sample_fn: Callable) -> void:
	if wind_sample_fn.is_valid():
		var wind := wind_sample_fn.call(center) as Vector2
		if wind.length() > 0.05:
			var wind_axis := wind.normalized()
			stable_axis = _rotate_axis_toward(normalized_axis(), wind_axis, _MAX_AXIS_TURN_RADIANS)
			axis = stable_axis
			velocity = stable_axis * (radius * 0.4)
	center += velocity
	intensity = maxf(intensity - decay_per_day, 0.0)
	age_days += 1
	refresh_visual_lifecycle()

func refresh_visual_lifecycle() -> void:
	life_progress = clampf(float(age_days) / maxf(float(ttl_days), 1.0), 0.0, 1.0)
	dissolve_amount = smoothstep(0.58, 1.0, life_progress)

	var visual_i: float = _visual_intensity(intensity)
	# Phase C 替代方案：把 birth 渐入区间从前 18% 拉宽到前 32% 寿命。
	# 原值在 ttl=6 的 RAIN 上意味着第 1 天云量就跳到 ~0.85（肉眼上是"突现"）；
	# 0.32 后第 1 天约 ~0.40，第 2 天 ~0.85，配合 0.18s 表现层 blend 与
	# Phase B advection，新 front 看起来像"从远处飘进来"而非"原地空降"。
	# 这是换季时位置不连续观感的主要修复点。
	var birth: float = smoothstep(0.0, 0.32, life_progress)
	var cloud_retire: float = 1.0 - smoothstep(0.78, 1.0, life_progress)
	var precip_retire: float = 1.0 - smoothstep(0.56, 0.88, life_progress)

	var cloud_mul: float = 1.0
	var precip_mul: float = 1.0
	match type:
		WeatherType.WT.STORM:
			cloud_mul = 1.22
			precip_mul = 1.32
			precip_retire = 1.0 - smoothstep(0.46, 0.80, life_progress)
		WeatherType.WT.MONSOON:
			cloud_mul = 1.18
			precip_mul = 1.22
			precip_retire = 1.0 - smoothstep(0.70, 0.96, life_progress)
		WeatherType.WT.BLIZZARD:
			cloud_mul = 1.10
			precip_mul = 1.18
		WeatherType.WT.FOG:
			cloud_mul = 1.28
			precip_mul = 0.0
			cloud_retire = 1.0 - smoothstep(0.62, 1.0, life_progress)
		WeatherType.WT.DROUGHT, WeatherType.WT.HEATWAVE:
			cloud_mul = 0.24
			precip_mul = 0.0
		WeatherType.WT.CLEAR:
			cloud_mul = 0.0
			precip_mul = 0.0

	cloud_amount = clampf(visual_i * birth * cloud_retire * cloud_mul, 0.0, 1.0)
	precip_amount = clampf(visual_i * birth * precip_retire * precip_mul, 0.0, 1.0)

func is_alive() -> bool:
	return intensity > 0.01 and age_days < ttl_days

func _rotate_axis_toward(from_axis: Vector2, to_axis: Vector2, max_angle: float) -> Vector2:
	var from := from_axis.normalized() if from_axis.length_squared() > 0.0001 else Vector2.RIGHT
	var to := to_axis.normalized() if to_axis.length_squared() > 0.0001 else from
	var delta := from.angle_to(to)
	delta = clampf(delta, -max_angle, max_angle)
	var out := from.rotated(delta)
	if out.length_squared() <= 0.0001:
		return from
	return out.normalized()

func _visual_intensity(raw_intensity: float) -> float:
	var i := clampf(raw_intensity, 0.0, 1.0)
	if i <= 0.0:
		return 0.0
	return clampf(pow(i, 0.55) * smoothstep(0.0, 0.08, i), 0.0, 1.0)

func _edge_noise(world_pos: Vector2) -> float:
	var p := world_pos * 0.025 + Vector2(edge_seed * 1.37, edge_seed * -0.73)
	var ix := floori(p.x)
	var iy := floori(p.y)
	var fx := p.x - float(ix)
	var fy := p.y - float(iy)
	var ux := fx * fx * (3.0 - 2.0 * fx)
	var uy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash_noise_2d(ix, iy)
	var b := _hash_noise_2d(ix + 1, iy)
	var c := _hash_noise_2d(ix, iy + 1)
	var d := _hash_noise_2d(ix + 1, iy + 1)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)

func _hash_noise_2d(ix: int, iy: int) -> float:
	var n: int = ix * 374761393 + iy * 668265263 + int(edge_seed * 1009.0)
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0
