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

# ─── Phase 1.2 / dots-full-migration §F.6 SoA 化预备 ─────────────────────
#
# 静态 batch helpers：把 Array[WeatherFront] 与 SoA Dictionary 互相打包/解包。
# F.6 C++ 实装（run_weather_front_advect_pass）将复用本对模式，每 tick：
#   1. weather_system 调 pack_into_dict(_active_fronts) → batch
#   2. C++ pass(batch) 写 batch 内的 PackedArray
#   3. weather_system 调 apply_dict_to_fronts(batch, _active_fronts)
# 即等同于 F.4 / F.2 处理 SoA 镜像缺失字段的 batch 提取模式。
#
# Schema 单一源：`scripts/data_core/fronts_schema.gd`（FRONTS_SCHEMA）。
# 阶段 II 真正升权威时，本两个 helper 被 thin facade（getter 走 PackedArray,
# by world_idx）取代；首版仍保留 OOP 双轨（OOP 权威，SoA 镜像）。

## 把 `fronts` Array[WeatherFront] 打包成 Dictionary of PackedArrays。
##
## 输出 Dictionary key 命名约定（与 fronts_schema.gd FRONTS_SCHEMA cpp_name 一致）：
##   front_center_x / front_center_y : PackedFloat32Array (size = n)
##   front_velocity_x / ..._y       : PackedFloat32Array (size = n)
##   front_axis_x / ..._y           : PackedFloat32Array (size = n)
##   front_stable_axis_x / ..._y    : PackedFloat32Array (size = n)
##   front_radius / front_intensity : PackedFloat32Array (size = n)
##   front_major_scale / ..._minor_ : PackedFloat32Array (size = n)
##   front_edge_seed                : PackedFloat32Array (size = n)
##   front_decay_per_day            : PackedFloat32Array (size = n)
##   front_life_progress            : PackedFloat32Array (size = n)
##   front_cloud_amount             : PackedFloat32Array (size = n)
##   front_precip_amount            : PackedFloat32Array (size = n)
##   front_dissolve_amount          : PackedFloat32Array (size = n)
##   front_world_idx / type / ttl_days / age_days : PackedInt32Array (size = n)
##   front_alive                    : PackedByteArray (size = n; from is_alive())
##   n_fronts                       : int
##
## 性能：全部使用 typed PackedArray，无 Variant 装箱；单次 pack ~5µs / 16 fronts。
static func pack_into_dict(fronts: Array) -> Dictionary:
	var n: int = fronts.size()
	var center_x:        PackedFloat32Array = PackedFloat32Array(); center_x.resize(n)
	var center_y:        PackedFloat32Array = PackedFloat32Array(); center_y.resize(n)
	var velocity_x:      PackedFloat32Array = PackedFloat32Array(); velocity_x.resize(n)
	var velocity_y:      PackedFloat32Array = PackedFloat32Array(); velocity_y.resize(n)
	var axis_x:          PackedFloat32Array = PackedFloat32Array(); axis_x.resize(n)
	var axis_y:          PackedFloat32Array = PackedFloat32Array(); axis_y.resize(n)
	var stable_axis_x:   PackedFloat32Array = PackedFloat32Array(); stable_axis_x.resize(n)
	var stable_axis_y:   PackedFloat32Array = PackedFloat32Array(); stable_axis_y.resize(n)
	var radius_arr:      PackedFloat32Array = PackedFloat32Array(); radius_arr.resize(n)
	var intensity_arr:   PackedFloat32Array = PackedFloat32Array(); intensity_arr.resize(n)
	var major_scale_arr: PackedFloat32Array = PackedFloat32Array(); major_scale_arr.resize(n)
	var minor_scale_arr: PackedFloat32Array = PackedFloat32Array(); minor_scale_arr.resize(n)
	var edge_seed_arr:   PackedFloat32Array = PackedFloat32Array(); edge_seed_arr.resize(n)
	var decay_arr:       PackedFloat32Array = PackedFloat32Array(); decay_arr.resize(n)
	var life_progress_arr:    PackedFloat32Array = PackedFloat32Array(); life_progress_arr.resize(n)
	var cloud_amount_arr:     PackedFloat32Array = PackedFloat32Array(); cloud_amount_arr.resize(n)
	var precip_amount_arr:    PackedFloat32Array = PackedFloat32Array(); precip_amount_arr.resize(n)
	var dissolve_amount_arr:  PackedFloat32Array = PackedFloat32Array(); dissolve_amount_arr.resize(n)
	var world_idx_arr:        PackedInt32Array   = PackedInt32Array();   world_idx_arr.resize(n)
	var type_arr:             PackedInt32Array   = PackedInt32Array();   type_arr.resize(n)
	var ttl_days_arr:         PackedInt32Array   = PackedInt32Array();   ttl_days_arr.resize(n)
	var age_days_arr:         PackedInt32Array   = PackedInt32Array();   age_days_arr.resize(n)
	var alive_arr:            PackedByteArray    = PackedByteArray();    alive_arr.resize(n)

	for i in range(n):
		var f: WeatherFront = fronts[i]
		center_x[i]        = f.center.x
		center_y[i]        = f.center.y
		velocity_x[i]      = f.velocity.x
		velocity_y[i]      = f.velocity.y
		axis_x[i]          = f.axis.x
		axis_y[i]          = f.axis.y
		stable_axis_x[i]   = f.stable_axis.x
		stable_axis_y[i]   = f.stable_axis.y
		radius_arr[i]      = f.radius
		intensity_arr[i]   = f.intensity
		major_scale_arr[i] = f.major_scale
		minor_scale_arr[i] = f.minor_scale
		edge_seed_arr[i]   = f.edge_seed
		decay_arr[i]       = f.decay_per_day
		life_progress_arr[i]   = f.life_progress
		cloud_amount_arr[i]    = f.cloud_amount
		precip_amount_arr[i]   = f.precip_amount
		dissolve_amount_arr[i] = f.dissolve_amount
		world_idx_arr[i]   = f.world_idx
		type_arr[i]        = f.type
		ttl_days_arr[i]    = f.ttl_days
		age_days_arr[i]    = f.age_days
		alive_arr[i]       = 1 if f.is_alive() else 0

	return {
		"n_fronts": n,
		"front_center_x": center_x,
		"front_center_y": center_y,
		"front_velocity_x": velocity_x,
		"front_velocity_y": velocity_y,
		"front_axis_x": axis_x,
		"front_axis_y": axis_y,
		"front_stable_axis_x": stable_axis_x,
		"front_stable_axis_y": stable_axis_y,
		"front_radius": radius_arr,
		"front_intensity": intensity_arr,
		"front_major_scale": major_scale_arr,
		"front_minor_scale": minor_scale_arr,
		"front_edge_seed": edge_seed_arr,
		"front_decay_per_day": decay_arr,
		"front_life_progress": life_progress_arr,
		"front_cloud_amount": cloud_amount_arr,
		"front_precip_amount": precip_amount_arr,
		"front_dissolve_amount": dissolve_amount_arr,
		"front_world_idx": world_idx_arr,
		"front_type": type_arr,
		"front_ttl_days": ttl_days_arr,
		"front_age_days": age_days_arr,
		"front_alive": alive_arr,
	}

## 把 SoA Dictionary 应用回 `fronts` Array[WeatherFront]（按 idx 1:1 写回）。
##
## C++ pass 修改完 batch 内 PackedArray 后，调本方法把数值写回 OOP fronts。
## 阶段 II OOP 退化为 facade 后本方法可删除（直接走 facade getter）。
##
## NOTE: alive=0 的 front 仍会被写回（未 pruning）；caller 应在调本方法
##       之后手动 prune `_active_fronts`：`fronts = fronts.filter(func(f): return f.is_alive())`
static func apply_dict_to_fronts(d: Dictionary, fronts: Array) -> void:
	var n: int = fronts.size()
	if d.get("n_fronts", -1) != n:
		push_warning("[WeatherFront] apply_dict_to_fronts: n_fronts mismatch (dict=%s, fronts=%d) — abort" % [str(d.get("n_fronts")), n])
		return
	var center_x:        PackedFloat32Array = d.get("front_center_x", PackedFloat32Array())
	var center_y:        PackedFloat32Array = d.get("front_center_y", PackedFloat32Array())
	var velocity_x:      PackedFloat32Array = d.get("front_velocity_x", PackedFloat32Array())
	var velocity_y:      PackedFloat32Array = d.get("front_velocity_y", PackedFloat32Array())
	var axis_x:          PackedFloat32Array = d.get("front_axis_x", PackedFloat32Array())
	var axis_y:          PackedFloat32Array = d.get("front_axis_y", PackedFloat32Array())
	var stable_axis_x:   PackedFloat32Array = d.get("front_stable_axis_x", PackedFloat32Array())
	var stable_axis_y:   PackedFloat32Array = d.get("front_stable_axis_y", PackedFloat32Array())
	var intensity_arr:   PackedFloat32Array = d.get("front_intensity", PackedFloat32Array())
	var life_progress_arr:    PackedFloat32Array = d.get("front_life_progress", PackedFloat32Array())
	var cloud_amount_arr:     PackedFloat32Array = d.get("front_cloud_amount", PackedFloat32Array())
	var precip_amount_arr:    PackedFloat32Array = d.get("front_precip_amount", PackedFloat32Array())
	var dissolve_amount_arr:  PackedFloat32Array = d.get("front_dissolve_amount", PackedFloat32Array())
	var age_days_arr:         PackedInt32Array   = d.get("front_age_days", PackedInt32Array())

	for i in range(n):
		var f: WeatherFront = fronts[i]
		if center_x.size() == n: f.center = Vector2(center_x[i], center_y[i])
		if velocity_x.size() == n: f.velocity = Vector2(velocity_x[i], velocity_y[i])
		if axis_x.size() == n: f.axis = Vector2(axis_x[i], axis_y[i])
		if stable_axis_x.size() == n: f.stable_axis = Vector2(stable_axis_x[i], stable_axis_y[i])
		if intensity_arr.size() == n: f.intensity = intensity_arr[i]
		if life_progress_arr.size() == n: f.life_progress = life_progress_arr[i]
		if cloud_amount_arr.size() == n: f.cloud_amount = cloud_amount_arr[i]
		if precip_amount_arr.size() == n: f.precip_amount = precip_amount_arr[i]
		if dissolve_amount_arr.size() == n: f.dissolve_amount = dissolve_amount_arr[i]
		if age_days_arr.size() == n: f.age_days = age_days_arr[i]
	# NOTE: type / ttl_days / radius / major_scale / ... 这些在 advect 期间不变，
	# 不需要写回。如果未来 C++ pass 改这些字段，把对应行加进上面的循环即可。
