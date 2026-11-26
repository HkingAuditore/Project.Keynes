# map_camera_convex_bounds.gd
# 基于已探索区域构建带外拓半径的凸形（凸包 + 圆角 Minkowski 和），
# 用于限制 MapCamera 的东西南北滚动上限，并支持圆柱地图东西环绕解环。

class_name MapCameraConvexBounds
extends RefCounted

const DEFAULT_MARGIN_HEX_RADII: float = 4.0
const EPSILON: float = 1e-5

var active: bool = false
var wraps_full_x: bool = false
var margin: float = 0.0
var wrap_period_x: float = 0.0
var unwrap_origin_x: float = 0.0
var hull: PackedVector2Array = PackedVector2Array()
var min_y: float = 0.0
var max_y: float = 0.0
var _center: Vector2 = Vector2.ZERO
var _bounds_size: Vector2 = Vector2.ZERO

# 最近一次 clamp_point 的结果诊断，供惯性滑行做切向投影（零额外分配）
var last_clamped: bool = false
var last_outward_normal: Vector2 = Vector2.ZERO


static func build_from_explored(
		map: MapData,
		hex_size: float,
		margin_hex_radii: float = DEFAULT_MARGIN_HEX_RADII,
		period_x: float = 0.0
) -> RefCounted:
	var result = new()
	if map == null or hex_size <= 0.0:
		return result
	var explored: PackedByteArray = map.explored_arr
	var pos_x: PackedFloat32Array = map.cell_pos_x_arr
	var pos_y: PackedFloat32Array = map.cell_pos_y_arr
	var count: int = mini(explored.size(), mini(pos_x.size(), pos_y.size()))
	var map_cells: int = map.cell_count()
	if map_cells > 0:
		count = mini(count, map_cells)
	if count <= 0:
		return result
	var points := PackedVector2Array()
	for i in count:
		if explored[i] != 0:
			points.append(Vector2(pos_x[i] * hex_size, pos_y[i] * hex_size))
	return build_from_points(points, maxf(0.0, margin_hex_radii * hex_size), period_x)


static func build_from_points(
		points: PackedVector2Array,
		margin_world: float,
		period_x: float = 0.0
) -> RefCounted:
	var result = new()
	if points.is_empty():
		return result
	var margin_val := maxf(0.0, margin_world)
	var period := maxf(0.0, period_x)
	result.margin = margin_val
	result.wrap_period_x = period
	result.active = true

	var y_min := INF
	var y_max := -INF
	for p in points:
		y_min = minf(y_min, p.y)
		y_max = maxf(y_max, p.y)
	result.min_y = y_min
	result.max_y = y_max

	var work_points: PackedVector2Array
	if period > EPSILON:
		var u_values: Array[float] = []
		u_values.resize(points.size())
		for i in points.size():
			u_values[i] = fposmod(points[i].x, period)
		u_values.sort()

		var max_gap := -1.0
		var gap_start := 0.0
		var n := u_values.size()
		for i in n:
			var a: float = u_values[i]
			var b: float = u_values[i + 1] if i + 1 < n else (u_values[0] + period)
			var gap: float = b - a
			if gap > max_gap:
				max_gap = gap
				gap_start = a

		# 最大未探索空隙 <= 2 * margin 时，左右外拓已首尾接通：东西自由环绕，仅限制南北
		if max_gap <= margin_val * 2.0 + EPSILON:
			result.wraps_full_x = true
			result._center = Vector2(period * 0.5, (y_min + y_max) * 0.5)
			result._bounds_size = Vector2(period, (y_max - y_min) + margin_val * 2.0)
			return result

		var unwrap_origin: float = fposmod(gap_start + max_gap * 0.5, period)
		result.unwrap_origin_x = unwrap_origin
		work_points = PackedVector2Array()
		work_points.resize(points.size())
		for i in points.size():
			var ux: float = unwrap_origin + fposmod(points[i].x - unwrap_origin, period)
			work_points[i] = Vector2(ux, points[i].y)
	else:
		work_points = points

	var computed_hull: PackedVector2Array = _compute_convex_hull(work_points)
	result.hull = computed_hull
	if computed_hull.is_empty():
		result.active = false
		return result

	var bx_min := INF
	var bx_max := -INF
	var by_min := INF
	var by_max := -INF
	for v in computed_hull:
		bx_min = minf(bx_min, v.x)
		bx_max = maxf(bx_max, v.x)
		by_min = minf(by_min, v.y)
		by_max = maxf(by_max, v.y)
	result._center = Vector2((bx_min + bx_max) * 0.5, (by_min + by_max) * 0.5)
	result._bounds_size = Vector2(
		(bx_max - bx_min) + margin_val * 2.0,
		(by_max - by_min) + margin_val * 2.0
	)
	return result


func is_active() -> bool:
	return active


func center() -> Vector2:
	return _center


func bounds_size() -> Vector2:
	return _bounds_size


func clamp_point(p: Vector2) -> Vector2:
	last_clamped = false
	last_outward_normal = Vector2.ZERO
	if not active:
		return p

	if wraps_full_x:
		var lo_y := min_y - margin
		var hi_y := max_y + margin
		if p.y < lo_y:
			last_clamped = true
			last_outward_normal = Vector2(0.0, -1.0)
			return Vector2(p.x, lo_y)
		if p.y > hi_y:
			last_clamped = true
			last_outward_normal = Vector2(0.0, 1.0)
			return Vector2(p.x, hi_y)
		return p

	if hull.is_empty():
		return p

	var q := p
	var px := p.x
	if wrap_period_x > EPSILON:
		px = unwrap_origin_x + fposmod(p.x - unwrap_origin_x, wrap_period_x)
		q = Vector2(px, p.y)

	var closest := _closest_point_on_hull(q)
	var diff := q - closest
	var dist_sq := diff.length_squared()
	if dist_sq <= margin * margin + EPSILON:
		return p

	var dist := sqrt(dist_sq)
	var normal := diff / dist
	var clamped_q := closest + normal * margin
	last_clamped = true
	last_outward_normal = normal

	if wrap_period_x > EPSILON:
		return Vector2(p.x + (clamped_q.x - px), clamped_q.y)
	return clamped_q


func _closest_point_on_hull(q: Vector2) -> Vector2:
	var m := hull.size()
	if m == 1:
		return hull[0]
	if m == 2:
		return _closest_point_on_segment(q, hull[0], hull[1])

	# hull 为严格 CCW 凸多边形：若对所有有向边都在左侧（cross >= 0），点在凸包内
	var inside := true
	for i in m:
		var a := hull[i]
		var b := hull[(i + 1) % m]
		if (b - a).cross(q - a) < 0.0:
			inside = false
			break
	if inside:
		return q

	var best_pt := hull[0]
	var best_d2 := INF
	for i in m:
		var candidate := _closest_point_on_segment(q, hull[i], hull[(i + 1) % m])
		var d2 := q.distance_squared_to(candidate)
		if d2 < best_d2:
			best_d2 = d2
			best_pt = candidate
	return best_pt


static func _closest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= EPSILON * EPSILON:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


## Andrew's Monotone Chain：返回严格 CCW 的凸包顶点（剔除共线中间点与重复点）。
static func _compute_convex_hull(points: PackedVector2Array) -> PackedVector2Array:
	var sorted: Array[Vector2] = []
	sorted.resize(points.size())
	for i in points.size():
		sorted[i] = points[i]
	sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if not is_equal_approx(a.x, b.x):
			return a.x < b.x
		return a.y < b.y
	)

	var unique: Array[Vector2] = []
	for pt in sorted:
		if unique.is_empty() or unique[unique.size() - 1].distance_squared_to(pt) > EPSILON * EPSILON:
			unique.append(pt)

	var n := unique.size()
	if n <= 2:
		return PackedVector2Array(unique)

	var lower: Array[Vector2] = []
	for pt in unique:
		while lower.size() >= 2 and _cross(lower[lower.size() - 2], lower[lower.size() - 1], pt) <= 0.0:
			lower.pop_back()
		lower.append(pt)

	var upper: Array[Vector2] = []
	for i in range(n - 1, -1, -1):
		var pt := unique[i]
		while upper.size() >= 2 and _cross(upper[upper.size() - 2], upper[upper.size() - 1], pt) <= 0.0:
			upper.pop_back()
		upper.append(pt)

	lower.pop_back()
	upper.pop_back()
	lower.append_array(upper)
	if lower.is_empty():
		return PackedVector2Array([unique[0]])
	return PackedVector2Array(lower)


static func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
