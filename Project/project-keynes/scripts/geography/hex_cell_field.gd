# hex_cell_field.gd
# ═══════════════════════════════════════════════════════════════════════════
# [cell-field 2026-11-18] 解析格界（hex cell field）的 **CPU 镜像**。
#
# 这是 `shaders/include/hex_cell_field.gdshaderinc`（shader）与
# `gdext/src/world_ext_bake.cpp`（C++ 烘焙）之外的**第三种实现**，只给测试与
# debug / 探针用：**不得**出现在任何渲染或模拟热路径里，也**不得**依赖纹理
# （`cell_table` / warp 层一律由调用方解码成 Vector2 后传进来）。
#
# 三处实现（C++ / shader / GDScript）必须逐点一致的量：
#   1. 分数 axial：q = (√3/3·x − y/3)/s，r = (2/3·y)/s            （与 HexUtils.world_to_cube 同式）
#   2. 对偶三角：up = step(1, t.x+t.y)、t = fract(a)、o = floor(a)   （c0/c1/c2 的取法固定）
#   3. 归属 dom：argmax(w_raw)，**平局次序 0 > 1 > 2**（三处同一注释锚点；
#      parity 测试直接依赖它，见 docs/plans/terrain-cell-field-contract.md §1）
#   4. gap 单位：(w_dom − w_i)·√3，沿格中心连线等于 2·d/hex_size，与 C++ 的
#      `edge_distance_units = "normalized_hex_center_gap"` 同一单位。
#
# 契约与方案：
#   docs/plans/terrain-cell-field-contract.md §1 / §5.2 / §6
#   docs/plans/terrain-hex-mesh-implementation-plan.md §3.1–§3.3 / §4.4
#
# ── 精度与「镜像」的边界（读代码前先看）────────────────────────────────
#   * GDScript 的 float 是 64 位，shader 是 32 位。本文件追求的是**语义等价**
#     （同一点得到同一个 dom、gap 在 1e-6 内相同），不是 bit 级相同。
#     32 位精度下 `fract(axial)` 在 x≈2000 wu 处的抖动由 GPU 探针负责，不在本文件。
#   * shader 侧 `band` 会与**未回绕坐标**的屏幕导数 AA 下限取 max（近景保证带 ≥ 1 像素）
#     —— 导数必须取自未回绕的世界坐标，取自已回绕坐标会在经线接缝处爆掉
#     （review 2026-11-18 第 1 条：接缝处出现 1~2 px 混合拉满的竖线）。
#     **AA 项是 shader 专有的**：CPU 没有屏幕导数，所以这里只有
#     `band = clamp(band_gap, 1e-4, PK_FIELD_BAND_MAX)`。受影响的是锐化权重 `w`，
#     不影响 `w_raw` / `gap` / `dom` —— 也就是 parity 断言的三项与 AA 无关。
#   * shader 侧 `mix(a, b, up)` 的 up 恒为 0 或 1，这里直接选分支（数学等价，
#     且避免 a + (b−a) 的往返舍入）。
#   * **入参 wp 可以是已回绕或未回绕的世界坐标**：shader 现在自己先
#     `wrap_world_pos(world_pos)`，而 wrap 是幂等的，所以两边等价。本文件不持有地图
#     周期，故回绕只体现在「col 是否 posmod」（`map_w > 0` 时）；横向回绕**只对 offset
#     col 做 posmod**，不在 axial 空间取模。
# ═══════════════════════════════════════════════════════════════════════════
extends RefCounted
class_name DCHexCellField

## 带宽上限：对偶三角形切换时第三格在共享边上的 gap ≥ √3/2 ≈ 0.866，
## 带宽超过它会在穿过格中心的那条线上出现接缝（方案 §3.2）。
const PK_FIELD_BAND_MAX := 0.86
const PK_FIELD_SQRT3 := 1.7320508075688772
const WARP_RANGE := 1.6
const WARP_AMP := 0.4

## 默认带宽 = `terrain_ecotone_width`（方案 §3.2）。shader 的
## `pk_hex_cell_field_default()` 用同一个值；**改一侧必须改另一侧**。
const PK_FIELD_BAND_DEFAULT := 0.84

## k 归一化的下限，与 shader `max(k.x + k.y + k.z, 1e-5)` 同值。
const PK_FIELD_WEIGHT_EPS := 1e-5

## √3/3，与 shader 的 `0.5773502691896258` 同值；与 HexUtils.world_to_cube 同式。
const PK_AXIAL_Q_SCALE := 0.5773502691896258


# ─────────────────────────────────────────────────────────────────────────
# 坐标工具（与 shader 的 pk_posmod / pk_axial_to_offset 逐行对应）
# ─────────────────────────────────────────────────────────────────────────

## 数学意义的取模。GLSL ES 3.00 对负操作数的 `%` 未定义、`/` 的取整方向在旧驱动
## 上也不可靠，故 shader 用 floor 实现；这里保持同一实现，避免两套负数语义。
## m <= 0 视为「不取模」，原样返回（shader 侧 map_w 恒 > 0，不会走到）。
static func posmod_int(a: int, m: int) -> int:
	if m <= 0:
		return a
	return a - m * int(floor(float(a) / float(m)))


## axial (q, r) → odd-r offset (col, row)：col = q + (r − (r & 1)) / 2，row = r。
## r 为负时 (r & 1) 走二补码；`r − (r & 1)` 恒为偶数，故 /2 是精确整除。
## **不做** map_w 取模：横向回绕只对 col 做 posmod（见 axial_to_offset_wrapped），
## 不能在 axial 空间取模 —— 同一行里 q 平移 map_w 才对应 col 平移 map_w。
static func axial_to_offset(q: int, r: int) -> Vector2i:
	return Vector2i(q + (r - (r & 1)) / 2, r)


## offset 列回绕版。map_w <= 0 时不取模（debug 用；此时 col 可能为负）。
static func axial_to_offset_wrapped(q: int, r: int, map_w: int) -> Vector2i:
	var off := axial_to_offset(q, r)
	if map_w > 0:
		off.x = posmod_int(off.x, map_w)
	return off


## 世界坐标 → 分数 axial（shader 第 2 步）。与 HexUtils.world_to_cube 同式。
## 注意返回值是 Vector2（Godot real_t = 32 位）：坐标量级几百 wu 时分数 axial 只有
## ~1e-6 精度。需要精确值（对偶三角边界 / 平局）时用 field_from_fractional_axial()
## 直给分数 axial，不要经过这里。
static func fractional_axial(wp: Vector2, hex_size: float) -> Vector2:
	return Vector2(
		(PK_AXIAL_Q_SCALE * wp.x - wp.y / 3.0) / hex_size,
		(2.0 / 3.0 * wp.y) / hex_size)


# ─────────────────────────────────────────────────────────────────────────
# 扭曲场解码（C++ 烘 RG8，shader 解码；这里只做解码，不做采样）
# ─────────────────────────────────────────────────────────────────────────

## RG8 → 世界单位的扭曲偏移。契约 §1「warp 解码」：
##   w = (rg·2 − 1) · warp_range · hex_size · warp_amp
## 0.1 wu 量化误差是**编码侧**（每通道 8 bit）造成的，解码本身是精确的。
static func decode_warp_byte(r: int, g: int, hex_size: float,
		warp_range: float = WARP_RANGE, warp_amp: float = WARP_AMP) -> Vector2:
	var scale: float = warp_range * hex_size * warp_amp
	return Vector2(
		(clampf(float(r), 0.0, 255.0) / 255.0 * 2.0 - 1.0) * scale,
		(clampf(float(g), 0.0, 255.0) / 255.0 * 2.0 - 1.0) * scale)


## decode_warp_byte 的逆：世界单位扭曲偏移 → RG8 字节（C++ 侧编码的镜像）。
##   v = clamp(w / (warp_range·hex_size·warp_amp), −1, 1)
##   byte = round((v·0.5 + 0.5)·255)
## clamp 掉的通道数应由调用方统计（C++ 报告键 boundary_warp_clamped，应为 0）。
static func encode_warp_world(warp_world: Vector2, hex_size: float,
		warp_range: float = WARP_RANGE, warp_amp: float = WARP_AMP) -> Vector2i:
	var scale: float = warp_range * hex_size * warp_amp
	var inv: float = 1.0 / scale if absf(scale) > 1e-9 else 0.0
	return Vector2i(
		int(round(clampf(warp_world.x * inv, -1.0, 1.0) * 0.5 * 255.0 + 127.5)),
		int(round(clampf(warp_world.y * inv, -1.0, 1.0) * 0.5 * 255.0 + 127.5)))


# ─────────────────────────────────────────────────────────────────────────
# 场函数（shader pk_hex_cell_field 的逐步镜像）
# ─────────────────────────────────────────────────────────────────────────

## 计算 wp 处的对偶三角形与三格权重。
##
## 返回字典（键与 shader 的 struct HexCellField 同名）：
##   c0/c1/c2 : Vector2i   offset 坐标；map_w > 0 时 col 已 posmod，否则原样（可为负）
##   w_raw    : Vector3    扭曲坐标上的重心坐标（连续量用，方案 §3.3）
##   w        : Vector3    锐化后权重，Σ=1（类别量用，方案 §3.3）
##   gap      : Vector3    (w_dom − w_i)·√3，dominant 分量恒为 0
##   dom      : int        argmax(w_raw)，平局次序 0 > 1 > 2
##   inside   : PackedByteArray  长度 3；map_h > 0 时 1 = 行在 [0, map_h) 内，
##              0 = padding（shader 侧 padding 的 class 按 B_SEA_ICE 处理）。
##              map_h <= 0 时恒为 [1,1,1]（不做南北边界判定）。
##
## band_gap 是 gap 单位的带宽；无 AA 项（见文件头）。band_gap 会被 clamp 到
## [1e-4, PK_FIELD_BAND_MAX]，与 shader 同区间（只是少了 fwidth 的 max）。
##
## 参数约定（与 shader 的入参约定一致）：
##   wp         必须是**已回绕**的世界坐标（调用方先过 wrap_world_pos()），保证浮点量级小。
##   map_h > 0  才做南北 padding 判定（写 inside）；0 = 不判定。
##   map_w > 0  才把 offset col posmod 到 [0, map_w)（shader 恒用 pk_cell_map_w）；
##              0 = 不回绕，c*.x 可为负 —— 只给 debug / 单元测试用。
static func field_at(wp: Vector2, hex_size: float, warp_world: Vector2, band_gap: float,
		map_h: int = 0, map_w: int = 0) -> Dictionary:
	var p: Vector2 = wp + warp_world
	# 注意：p.x / p.y 是 Godot 的 real_t（32 位），一旦进入这里就是 float64 标量运算。
	var aq: float = (PK_AXIAL_Q_SCALE * float(p.x) - float(p.y) / 3.0) / hex_size
	var ar: float = (2.0 / 3.0 * float(p.y)) / hex_size
	return _field_from_axial(aq, ar, band_gap, map_h, map_w)


## 分数 axial 直入的调试 / 测试入口：跳过世界坐标的 float32 往返。
## 世界坐标入口 field_at 的入参是 Vector2（Godot real_t = 32 位），坐标量级几百 wu 时
## 分数 axial 只有 ~1e-6 的精度；需要**精确**落在对偶三角边界上（t.x+t.y == 1）的
## 平局次序测试必须走这个入口（3.25 / 7.75 这类值在 float32 里是精确的）。
static func field_from_fractional_axial(a: Vector2, band_gap: float = PK_FIELD_BAND_DEFAULT,
		map_h: int = 0, map_w: int = 0) -> Dictionary:
	return _field_from_axial(float(a.x), float(a.y), band_gap, map_h, map_w)


## 场函数本体（shader pk_hex_cell_field 第 3 步之后）。全部用 float64 标量算，
## 只在返回时打包成 Vector3（Vector3 的 real_t 是 32 位）。
static func _field_from_axial(aq: float, ar: float, band_gap: float,
		map_h: int, map_w: int) -> Dictionary:
	# floor / fract 锁定一个对偶三角形；fract 直接就是重心坐标。
	var oq: float = floorf(aq)
	var orow: float = floorf(ar)
	var tx: float = aq - oq
	var ty: float = ar - orow
	var ox: int = int(oq)
	var oy: int = int(orow)

	# 上 / 下三角用 step 选择：GLSL step(1, x) = x >= 1 ? 1 : 0。
	var up := 1 if tx + ty >= 1.0 else 0
	var q0 := Vector2i(ox + up, oy + up)          # (0,0) 或 (1,1)
	var q1 := Vector2i(ox + 1 - up, oy + up)      # (1,0) 或 (0,1)
	var q2 := Vector2i(ox + up, oy + 1 - up)      # (0,1) 或 (1,0)

	# 上下三角的重心坐标互为镜像表达式；顺序固定 c0, c1, c2。
	var w0: float
	var w1: float
	var w2: float
	if up == 0:
		w0 = 1.0 - tx - ty
		w1 = tx
		w2 = ty
	else:
		w0 = tx + ty - 1.0
		w1 = 1.0 - tx
		w2 = 1.0 - ty

	var c0 := axial_to_offset_wrapped(q0.x, q0.y, map_w)
	var c1 := axial_to_offset_wrapped(q1.x, q1.y, map_w)
	var c2 := axial_to_offset_wrapped(q2.x, q2.y, map_w)

	# gap 与主导格。dominant 分量 (wm − wm) 恒为 0。
	var wm: float = maxf(w0, maxf(w1, w2))
	var g0: float = (wm - w0) * PK_FIELD_SQRT3
	var g1: float = (wm - w1) * PK_FIELD_SQRT3
	var g2: float = (wm - w2) * PK_FIELD_SQRT3

	# 锐化：k = 1 − smoothstep(0, band, gap)；w = k / max(Σk, 1e-5)。
	# 注意 shader 的 band 还会与 fwidth 的 AA 下限取 max —— AA 项是 shader 专有的。
	var band: float = clampf(band_gap, 1e-4, PK_FIELD_BAND_MAX)
	var k0: float = 1.0 - smoothstep(0.0, band, g0)
	var k1: float = 1.0 - smoothstep(0.0, band, g1)
	var k2: float = 1.0 - smoothstep(0.0, band, g2)
	var denom: float = maxf(k0 + k1 + k2, PK_FIELD_WEIGHT_EPS)

	# 平局次序写死 0 > 1 > 2（三处同一注释锚点；parity 测试依赖它）。
	var dom := 0
	if not (w0 >= w1 and w0 >= w2):
		dom = 1 if w1 >= w2 else 2

	var inside := PackedByteArray()
	inside.resize(3)
	if map_h > 0:
		inside[0] = 1 if c0.y >= 0 and c0.y < map_h else 0
		inside[1] = 1 if c1.y >= 0 and c1.y < map_h else 0
		inside[2] = 1 if c2.y >= 0 and c2.y < map_h else 0
	else:
		inside.fill(1)

	return {
		"c0": c0,
		"c1": c1,
		"c2": c2,
		"w_raw": Vector3(w0, w1, w2),
		"w": Vector3(k0 / denom, k1 / denom, k2 / denom),
		"gap": Vector3(g0, g1, g2),
		"dom": dom,
		"inside": inside,
	}


## 主导格的 offset（= `HexUtils.cube_to_offset(cube.x, cube.y)` 的回绕版）。
## map_w > 0 时 col ∈ [0, map_w)；map_w <= 0 时不回绕（col 可为负，debug 用）。
static func dom_at(wp: Vector2, hex_size: float, warp_world: Vector2,
		map_h: int = 0, map_w: int = 0) -> Vector2i:
	var f := field_at(wp, hex_size, warp_world, PK_FIELD_BAND_DEFAULT, map_h, map_w)
	return cell_offset(f, int(f["dom"]))


## 主导格在 c0/c1/c2 里的下标（0/1/2），测试用。
static func dom_index_at(wp: Vector2, hex_size: float, warp_world: Vector2,
		map_h: int = 0, map_w: int = 0) -> int:
	return int(field_at(wp, hex_size, warp_world, PK_FIELD_BAND_DEFAULT, map_h, map_w)["dom"])


## 锐化权重（Σ=1）。band_gap 默认 = terrain_ecotone_width。
static func weights_at(wp: Vector2, hex_size: float, warp_world: Vector2,
		band_gap: float = PK_FIELD_BAND_DEFAULT, map_h: int = 0, map_w: int = 0) -> Vector3:
	return field_at(wp, hex_size, warp_world, band_gap, map_h, map_w)["w"]


## 三格 gap（dominant 分量为 0）。gap 只由分数 axial 决定，与 offset 回绕无关。
static func gap_at(wp: Vector2, hex_size: float, warp_world: Vector2) -> Vector3:
	return field_at(wp, hex_size, warp_world, PK_FIELD_BAND_DEFAULT)["gap"]


# ─────────────────────────────────────────────────────────────────────────
# HexCellField struct 的取值 helper（对应 shader pk_cell_field_offset 等）
# ─────────────────────────────────────────────────────────────────────────

## 第 i 格（0/1/2）的 offset 坐标。
static func cell_offset(f: Dictionary, i: int) -> Vector2i:
	if i == 0:
		return f["c0"]
	if i == 1:
		return f["c1"]
	return f["c2"]


## 第 i 格是否需要按 padding 处理（row 越界）。map_h <= 0 时恒为 false。
static func cell_inside(f: Dictionary, i: int) -> bool:
	var flags: PackedByteArray = f["inside"]
	if i < 0 or i >= flags.size():
		return true
	return flags[i] != 0


## 主导格的锐化权重（= max(w)），shader `pk_cell_field_dom_weight` 的镜像。
static func dom_weight(f: Dictionary) -> float:
	var w: Vector3 = f["w"]
	return maxf(w.x, maxf(w.y, w.z))
