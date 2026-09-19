extends RefCounted
class_name DCTerrainGeometryUtils

## Shared, stateless geometry helpers for terrain baking and raster rebakes.
##
## This module owns coordinate conversion, cylindrical noise seam handling,
## wrapped cell lookup, barycentric interpolation, and the hypsometric curve.
## It deliberately has no MapBaker or WorldData state.

const HYPSO_XS: Array[float] = [0.0, 0.32, 0.52, 0.70, 1.0]
const HYPSO_YS: Array[float] = [0.0, 0.34, 0.54, 0.70, 1.0]

static func get_wrapped_cell_by_cube(map: MapData, cube: Vector3i) -> HexCell:
	if map == null:
		return null
	var off := HexUtils.cube_to_offset(cube.x, cube.y)
	if off.y < 0 or off.y >= map.height:
		return null
	var wrapped := HexUtils.offset_to_cube(posmod(off.x, map.width), off.y)
	return map.get_cell_by_cube(wrapped)


static func cyl_noise(noise: FastNoiseLite, x: float, y: float, period_x: float,
		hex_size: float, period_scale: float = 1.0, phase_origin_x: float = 0.0) -> float:
	if noise == null:
		return 0.0
	var period := period_x * maxf(period_scale, 0.0001)
	if period <= 0.0001:
		return noise.get_noise_2d(x, y)
	var phase := fposmod(x - phase_origin_x, period)
	var xw := phase_origin_x + phase
	var base := noise.get_noise_2d(xw, y)
	var band := minf(maxf(hex_size * 8.0 * maxf(period_scale, 0.0001), 1.0), period * 0.12)
	if band <= 0.0001:
		return base
	var left := noise.get_noise_2d(phase_origin_x, y)
	var right := noise.get_noise_2d(phase_origin_x + period, y)
	var seam_avg := (left + right) * 0.5
	if phase < band:
		var t_left := smoothstep(0.0, band, phase)
		return lerpf(seam_avg, base, t_left)
	if phase > period - band:
		var t_right := smoothstep(0.0, band, period - phase)
		return lerpf(seam_avg, base, t_right)
	return base


static func world_to_cube_f(pos: Vector2, size: float) -> Vector3:
	var q_f := (sqrt(3.0) / 3.0 * pos.x - (1.0 / 3.0) * pos.y) / size
	var r_f := (2.0 / 3.0 * pos.y) / size
	return Vector3(q_f, r_f, -q_f - r_f)


static func cube_round(c: Vector3) -> Vector3i:
	var rq: float = round(c.x)
	var rr: float = round(c.y)
	var rs: float = round(c.z)
	var dq: float = absf(rq - c.x)
	var dr: float = absf(rr - c.y)
	var ds: float = absf(rs - c.z)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	else:
		rs = -rq - rr
	return Vector3i(int(rq), int(rr), int(rs))


static func neighbor_dir(sextant: int) -> Vector3i:
	# Raster sextants use 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE.
	match sextant:
		0: return Vector3i(1, 0, -1)
		1: return Vector3i(0, 1, -1)
		2: return Vector3i(-1, 1, 0)
		3: return Vector3i(-1, 0, 1)
		4: return Vector3i(0, -1, 1)
		_: return Vector3i(1, -1, 0)


static func barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 0.000001:
		return Vector3(1.0, 0.0, 0.0)
	var inv := 1.0 / denom
	var v_b := (d11 * d20 - d01 * d21) * inv
	var v_c := (d00 * d21 - d01 * d20) * inv
	var v_a := 1.0 - v_b - v_c
	v_a = maxf(v_a, 0.0)
	v_b = maxf(v_b, 0.0)
	v_c = maxf(v_c, 0.0)
	var sum := v_a + v_b + v_c
	if sum < 0.0001:
		return Vector3(1.0, 0.0, 0.0)
	return Vector3(v_a / sum, v_b / sum, v_c / sum)


static func hypso_make_tangents() -> Array:
	var np := HYPSO_XS.size()
	var d: Array = []
	d.resize(np - 1)
	for i in range(np - 1):
		d[i] = (HYPSO_YS[i + 1] - HYPSO_YS[i]) / (HYPSO_XS[i + 1] - HYPSO_XS[i])
	var m: Array = []
	m.resize(np)
	m[0] = d[0]
	m[np - 1] = d[np - 2]
	for i in range(1, np - 1):
		m[i] = 0.0 if d[i - 1] * d[i] <= 0.0 else (d[i - 1] + d[i]) * 0.5
	for i in range(np - 1):
		if d[i] == 0.0:
			m[i] = 0.0
			m[i + 1] = 0.0
			continue
		var a: float = m[i] / d[i]
		var b: float = m[i + 1] / d[i]
		var s := a * a + b * b
		if s > 9.0:
			var tau := 3.0 / sqrt(s)
			m[i] = tau * a * d[i]
			m[i + 1] = tau * b * d[i]
	return m


static func hypso_eval(x: float, m: Array) -> float:
	var np := HYPSO_XS.size()
	if x <= HYPSO_XS[0]:
		return HYPSO_YS[0]
	if x >= HYPSO_XS[np - 1]:
		return HYPSO_YS[np - 1]
	var k := 0
	while k < np - 2 and x >= HYPSO_XS[k + 1]:
		k += 1
	var h: float = HYPSO_XS[k + 1] - HYPSO_XS[k]
	var t: float = (x - HYPSO_XS[k]) / h
	var t2 := t * t
	var t3 := t2 * t
	var h00 := 2.0 * t3 - 3.0 * t2 + 1.0
	var h10 := t3 - 2.0 * t2 + t
	var h01 := -2.0 * t3 + 3.0 * t2
	var h11 := t3 - t2
	return h00 * HYPSO_YS[k] + h10 * h * m[k] + h01 * HYPSO_YS[k + 1] + h11 * h * m[k + 1]


static func hypso_remap_elev(e: float, sea: float, inv_above: float, above: float,
		mix: float, m: Array) -> float:
	if e <= sea or inv_above <= 0.0:
		return e
	var lh := (e - sea) * inv_above
	var lhr := hypso_eval(lh, m)
	var mixed: float = lhr if mix >= 1.0 else (lh + (lhr - lh) * mix)
	return sea + mixed * above
