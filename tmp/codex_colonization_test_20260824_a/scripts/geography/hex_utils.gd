# hex_utils.gd
# 六边形工具类（全静态方法，无状态）
# 坐标系约定：
#   Cube 坐标 (q, r, s)，约束 q + r + s = 0
#   Offset 坐标 (col, row)，使用"奇数行右移"（odd-r）布局
#   屏幕坐标以 flat-top（尖顶朝上）六边形为准

class_name HexUtils

# 六个方向的 cube 坐标增量（E, NE, NW, W, SW, SE）
const CUBE_DIRECTIONS: Array[Vector3i] = [
	Vector3i( 1,  0, -1),  # 0: East
	Vector3i( 1, -1,  0),  # 1: NE
	Vector3i( 0, -1,  1),  # 2: NW
	Vector3i(-1,  0,  1),  # 3: West
	Vector3i(-1,  1,  0),  # 4: SW
	Vector3i( 0,  1, -1),  # 5: SE
]

# ─── Cube ↔ Offset 转换（odd-r 偏移布局）─────────────────────────────────

## Cube (q, r) → Offset (col, row)
static func cube_to_offset(q: int, r: int) -> Vector2i:
	var col: int = q + (r - (r & 1)) / 2
	var row: int = r
	return Vector2i(col, row)

## Offset (col, row) → Cube (q, r, s)
static func offset_to_cube(col: int, row: int) -> Vector3i:
	var q: int = col - (row - (row & 1)) / 2
	var r: int = row
	var s: int = -q - r
	return Vector3i(q, r, s)

## Vector3i cube → Vector2i offset
static func v3_to_offset(cube: Vector3i) -> Vector2i:
	return cube_to_offset(cube.x, cube.y)

# ─── 邻居 ────────────────────────────────────────────────────────────────

## 返回指定 cube 坐标的第 i 个方向邻居坐标
static func cube_neighbor(q: int, r: int, s: int, direction: int) -> Vector3i:
	var d := CUBE_DIRECTIONS[direction]
	return Vector3i(q + d.x, r + d.y, s + d.z)

## 返回给定 cube 坐标的全部 6 个邻居坐标数组
static func cube_all_neighbors(q: int, r: int, s: int) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for d in CUBE_DIRECTIONS:
		result.append(Vector3i(q + d.x, r + d.y, s + d.z))
	return result

# ─── 距离 ────────────────────────────────────────────────────────────────

## Cube 坐标曼哈顿距离
static func cube_distance(a: Vector3i, b: Vector3i) -> int:
	return (abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)) / 2

# ─── 屏幕坐标（pointy-top 六边形，配合 odd-r 偏移布局）─────────────────
# 六边形朝向：尖顶朝上 / 平边在左右
# size 含义：六边形外接圆半径（中心→顶点距离）
# 单格宽度  = sqrt(3) * size
# 单格高度  = 2 * size
# 行间垂直步长 = 1.5 * size

## 给定六边形外接圆半径 size，将 cube 坐标转换为屏幕中心像素坐标
static func cube_to_world(q: int, r: int, size: float) -> Vector2:
	var x: float = size * sqrt(3.0) * (float(q) + float(r) / 2.0)
	var y: float = size * 1.5 * float(r)
	return Vector2(x, y)

## 屏幕坐标反查最近 cube 坐标（pointy-top）
static func world_to_cube(pos: Vector2, size: float) -> Vector3i:
	var q_f: float = (sqrt(3.0) / 3.0 * pos.x - 1.0 / 3.0 * pos.y) / size
	var r_f: float = (2.0 / 3.0 * pos.y) / size
	return _cube_round(q_f, r_f, -q_f - r_f)

## 圆柱地图一圈的水平世界距离。注意这不是 world_bounds.size.x：
## world_bounds 含烘焙 padding，真正经度周期只由 offset 列宽决定。
static func wrap_period_x(map_width: int, size: float) -> float:
	return maxf(0.0, float(map_width) * sqrt(3.0) * size)

## cell_pos_x / cell_pos_y SoA 空间（size=1.0 单位六边形）的经度环绕周期。
##
## 凡是要和 `cell_pos_x_arr` 做比较/取模的 C++ pass knob（物理 SLP/wind 的
## `wrap_period_x`、climate/weather 平流内核的最小映像折叠）**必须**用这个，
## 不能用世界单位的 `wrap_period_x(map_width, hex_size)`：`map_data.gd` 是用
## `cube_to_world(q, r, 1.0)` 填 `cell_pos_x_arr` 的，列距恒为 √3/2 与 hex_size 无关。
## 传成世界单位会让归一化经度只覆盖整周期的 `1/hex_size`，永远不环绕 —— 接缝退化成
## 一堵"墙"（synoptic 波硬跳 → 伪 ∇SLP → 风/洋流被钉死在一条经线上）。
##
## 反之，像素/世界空间的消费者（horizon marching、visual tiles、_cyl_noise、
## river SDF）要继续用 `wrap_period_x(map_width, hex_size)`。
static func wrap_period_cell_pos_x(map_width: int) -> float:
	return wrap_period_x(map_width, 1.0)

## 圆柱地球最小映像修正（seam-advection-fix 2026-08-03）。
## 六邻居表东西方向用 posmod 环绕，最左列与最右列互为邻居，但 cell_pos_x 是不环绕的
## 规范坐标 —— 接缝邻居的裸差分等于 ±(period − 列距)：符号与真实位移相反、量级放大约
## map_width 倍。凡是拿裸差分当方向向量的平流/上风探测都会在接缝两列判反上下游，并因
## |dx| >> |dy| 退化成纯东西向，形成方向恒定的经线伪影。这里折回半周期取最近映像。
## y 方向是两极硬边界、不环绕，故只处理 x。period <= 0 时退化为原始差分。
## 与 C++ `pk_wrap_min_image_dx`（world_ext_internal.h）逐行同语义，改一侧须同步另一侧。
static func wrap_min_image_dx(dx: float, period: float) -> float:
	if period <= 0.0:
		return dx
	var half: float = period * 0.5
	if dx > half:
		return dx - period
	if dx < -half:
		return dx + period
	return dx

## 将任意世界坐标折回圆柱地图的 offset 列域；南北越界仍保持硬边界。
static func world_to_wrapped_cube(pos: Vector2, size: float, map_width: int, map_height: int) -> Vector3i:
	if map_width <= 0 or map_height <= 0:
		return Vector3i(2147483647, 0, -2147483647)
	var cube := world_to_cube(pos, size)
	var off := cube_to_offset(cube.x, cube.y)
	if off.y < 0 or off.y >= map_height:
		return Vector3i(2147483647, 0, -2147483647)
	return offset_to_cube(posmod(off.x, map_width), off.y)

## 直接按世界坐标取圆柱地图 cell。调用方不必重复 cube→offset→posmod 规则。
static func world_to_wrapped_cell(map, pos: Vector2, size: float):
	if map == null:
		return null
	var cube := world_to_wrapped_cube(pos, size, int(map.width), int(map.height))
	if cube.x == 2147483647:
		return null
	var off := cube_to_offset(cube.x, cube.y)
	if off.y < 0 or off.y >= int(map.height):
		return null
	return map.get_cell_by_cube(cube)

## 把 canonical 世界点移动到离参考 x 最近的水平副本上。
static func nearest_display_world(canonical_pos: Vector2, reference_x: float, period_x: float) -> Vector2:
	if period_x <= 0.0001:
		return canonical_pos
	var k := roundi((reference_x - canonical_pos.x) / period_x)
	return canonical_pos + Vector2(float(k) * period_x, 0.0)

## 浮点 cube 坐标四舍五入为整数（保持 q+r+s=0）
static func _cube_round(q_f: float, r_f: float, s_f: float) -> Vector3i:
	var rq: int = roundi(q_f)
	var rr: int = roundi(r_f)
	var rs: int = roundi(s_f)
	var dq: float = abs(float(rq) - q_f)
	var dr: float = abs(float(rr) - r_f)
	var ds: float = abs(float(rs) - s_f)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	else:
		rs = -rq - rr
	return Vector3i(rq, rr, rs)

# ─── 范围 ────────────────────────────────────────────────────────────────

## 返回以 center 为圆心、半径 radius 以内所有 cube 坐标
static func cube_range(center: Vector3i, radius: int) -> Array[Vector3i]:
	var results: Array[Vector3i] = []
	for dq in range(-radius, radius + 1):
		var r_min := maxi(-radius, -dq - radius)
		var r_max := mini( radius, -dq + radius)
		for dr in range(r_min, r_max + 1):
			results.append(Vector3i(center.x + dq, center.y + dr, center.z - dq - dr))
	return results

# ─── Offset 行列 → cube 快捷封装 ─────────────────────────────────────────

## 给定 offset (col, row) 返回在地图边界内的所有 cube 邻居坐标
## map_width / map_height 用于边界裁剪
static func offset_neighbors_in_bounds(col: int, row: int, map_width: int, map_height: int) -> Array[Vector2i]:
	var cube := offset_to_cube(col, row)
	var result: Array[Vector2i] = []
	for d in CUBE_DIRECTIONS:
		var nc := Vector3i(cube.x + d.x, cube.y + d.y, cube.z + d.z)
		var off := cube_to_offset(nc.x, nc.y)
		if off.x >= 0 and off.x < map_width and off.y >= 0 and off.y < map_height:
			result.append(off)
	return result
