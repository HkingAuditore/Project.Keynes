extends SceneTree

# Headless:
#   cd Project/project-keynes
#   godot --headless -s tests/world/hex_cell_field_parity_test.gd
#
# 守的契约：docs/plans/terrain-cell-field-contract.md §1（不变量）/ §5.2（CPU 镜像）/ §6
# 被测实现：scripts/geography/hex_cell_field.gd（DCHexCellField，shader 的 CPU 镜像）
# 参照实现：shaders/include/hex_cell_field.gdshaderinc（lead 独占，已落地）
#
# 断言分组：
#   1. parity      ：10 万随机点 dom_at == HexUtils.cube_to_offset(p + warp)，100% 一致
#   2. lattice     ：60×40 格中心处 dom == 本格、gap == 0、w ≈ (1,0,0)
#   3. tie-break   ：对偶三角边界（t.x+t.y == 1）上平局次序 0 > 1 > 2 确定且与 argmax 一致
#   4. wrap        ：东缘周期平移后 col 同余；col 恒在 [0, map_w)
#   5. warp decode ：RG8 编解码误差 ≤ 契约的 0.1 wu 预算
#   6. gap unit    ：相邻格中心连线上 gap(非主导) == 2·d/hex_size（钉死 √3 因子）
#
# 全部是纯数学，无场景、无纹理、不依赖 GDExtension。

const HexCellField = preload("res://scripts/geography/hex_cell_field.gd")

const HEX_SIZE := 22.0
const SQRT3 := 1.7320508075688772
## 地图宽：采样点 col 覆盖 [-5, 70]，留到 76 以便负列回绕后仍落在不同列。
const MAP_W := 76
const MAP_H := 41
const COL_MIN := -5
const COL_MAX := 70
const ROW_MIN := 0
const ROW_MAX := 40
## terrain_ecotone_width（shader pk_hex_cell_field_default 的 band）。
const BAND := 0.84
const PARITY_SAMPLES := 100000

var _checks := 0
var _failures := 0


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	_check_dom_parity()
	_check_pure_lattice()
	_check_mirror_helpers()
	_check_tie_break()
	_check_wrap()
	_check_decode_warp_roundtrip()
	_check_gap_unit()
	print("=== hex cell field parity: %d checks, %d failures ===" % [_checks, _failures])
	print("  elapsed %.2f s" % (float(Time.get_ticks_msec() - t0) / 1000.0))
	quit(0 if _failures == 0 else 1)


# ─────────────────────────────────────────────────────────────────────────
# 1. parity：dom_at 必须逐点等于 CPU cube_round(p + warp)
# ─────────────────────────────────────────────────────────────────────────

func _check_dom_parity() -> void:
	# 三种 warp 量级：无扭曲（退化成直边六边形归属）/ 小扭曲 / 接近契约上界
	# （|warp| ≤ PK_WARP_RANGE · hex_size · WARP_AMP = 14.08 wu）。
	var warps := {
		"zero": Vector2.ZERO,
		"small": Vector2(3.5, -2.25),
		"large": Vector2(14.0, -13.5),
	}
	var keys := ["zero", "small", "large"]
	var per_config := int(PARITY_SAMPLES / keys.size())
	var total := 0
	var total_mismatch := 0
	var cover_col_min := 1 << 30
	var cover_col_max := -(1 << 30)
	var cover_row_min := 1 << 30
	var cover_row_max := -(1 << 30)
	for ki in range(keys.size()):
		var key: String = keys[ki]
		var warp: Vector2 = warps[key]
		# 余数补给第一组，保证总量精确等于 PARITY_SAMPLES。
		var samples_here: int = per_config + (PARITY_SAMPLES - per_config * keys.size() if ki == 0 else 0)
		var rng := RandomNumberGenerator.new()
		rng.seed = 20261118
		var mismatches := 0
		var first_bad := ""
		var col_min := 1 << 30
		var col_max := -(1 << 30)
		for i in range(samples_here):
			var p := _random_point_in_extent(rng)
			var cube := HexUtils.world_to_cube(p + warp, HEX_SIZE)
			var expected := HexUtils.cube_to_offset(cube.x, cube.y)
			var actual := HexCellField.dom_at(p, HEX_SIZE, warp, 0, MAP_W)
			col_min = mini(col_min, actual.x)
			col_max = maxi(col_max, actual.x)
			# 覆盖度按**未回绕**的 cube 列号统计（回绕后 col 恒在 [0, map_w)）。
			cover_col_min = mini(cover_col_min, expected.x)
			cover_col_max = maxi(cover_col_max, expected.x)
			cover_row_min = mini(cover_row_min, expected.y)
			cover_row_max = maxi(cover_row_max, expected.y)
			var expected_col := HexCellField.posmod_int(expected.x, MAP_W)
			if actual.x != expected_col or actual.y != expected.y:
				mismatches += 1
				if first_bad.is_empty():
					first_bad = "p=%s warp=%s dom_at=%s cube_round=%s" % [
						str(p), str(warp), str(actual), str(expected)]
		total += samples_here
		total_mismatch += mismatches
		_expect(mismatches == 0,
			"dom_at == cube_to_offset(p + warp) on %d points, warp=%s (mismatch=%d)%s" % [
				samples_here, key, mismatches,
				"" if first_bad.is_empty() else " first: " + first_bad])
		_expect(col_min >= 0 and col_max < MAP_W,
			"dom_at col stays wrapped in [0, map_w) for warp=%s (observed [%d, %d])" % [
				key, col_min, col_max])
	_expect(total == PARITY_SAMPLES and total_mismatch == 0,
		"100k-point parity: %d/%d mismatches (100%% agreement required)" % [
			total_mismatch, total])
	_expect(cover_col_min <= COL_MIN and cover_col_max >= COL_MAX
			and cover_row_min <= ROW_MIN and cover_row_max >= ROW_MAX,
		"sample extent covers col [%d, %d] x row [%d, %d]: observed col [%d, %d] row [%d, %d]" % [
			COL_MIN, COL_MAX, ROW_MIN, ROW_MAX,
			cover_col_min, cover_col_max, cover_row_min, cover_row_max])


## 在 col ∈ [COL_MIN, COL_MAX] / row ∈ [ROW_MIN, ROW_MAX] 的格内取抖动点。
func _random_point_in_extent(rng: RandomNumberGenerator) -> Vector2:
	var col := rng.randi_range(COL_MIN, COL_MAX)
	var row := rng.randi_range(ROW_MIN, ROW_MAX)
	var cube := HexUtils.offset_to_cube(col, row)
	var center := HexUtils.cube_to_world(cube.x, cube.y, HEX_SIZE)
	var jitter := Vector2(
		rng.randf_range(-0.45, 0.45) * SQRT3 * HEX_SIZE,
		rng.randf_range(-0.45, 0.45) * 1.5 * HEX_SIZE)
	return center + jitter


# ─────────────────────────────────────────────────────────────────────────
# 2. lattice：格中心必须选回自己
# ─────────────────────────────────────────────────────────────────────────

func _check_pure_lattice() -> void:
	var grid_cols := 60
	var grid_rows := 40
	var bad_dom := 0
	var bad_gap := 0
	var bad_weights := 0
	var first_bad := ""
	for row in range(grid_rows):
		for col in range(grid_cols):
			var cube := HexUtils.offset_to_cube(col, row)
			var center := HexUtils.cube_to_world(cube.x, cube.y, HEX_SIZE)
			var f := HexCellField.field_at(center, HEX_SIZE, Vector2.ZERO, BAND)
			var dom := int(f["dom"])
			var dom_off := HexCellField.cell_offset(f, dom)
			if dom_off != HexUtils.cube_to_offset(cube.x, cube.y):
				bad_dom += 1
				if first_bad.is_empty():
					first_bad = "cell(%d,%d) center -> dom offset %s" % [col, row, str(dom_off)]
			var gap: Vector3 = f["gap"]
			if _comp(gap, dom) != 0.0:
				bad_gap += 1
			var w: Vector3 = f["w"]
			var w_dom := _comp(w, dom)
			var others := 0.0
			for k in range(3):
				if k != dom:
					others = maxf(others, _comp(w, k))
			if absf(w_dom - 1.0) > 1e-9 or others > 1e-3 \
					or absf(w.x + w.y + w.z - 1.0) > 1e-9:
				bad_weights += 1
	_expect(bad_dom == 0,
		"60x40 cell centers: dom_at(center) == that cell's offset (%d bad)%s" % [
			bad_dom, "" if first_bad.is_empty() else " first: " + first_bad])
	_expect(bad_gap == 0, "60x40 cell centers: dominant gap == 0 (%d bad)" % bad_gap)
	_expect(bad_weights == 0,
		"60x40 cell centers: weights are a permutation of (1,0,0) (%d bad)" % bad_weights)


# ─────────────────────────────────────────────────────────────────────────
# 3'. 镜像工具：offset 换算必须与 HexUtils 逐格一致（含负 r 的二补码路径）
# ─────────────────────────────────────────────────────────────────────────

func _check_mirror_helpers() -> void:
	var offset_bad := 0
	var wrapped_bad := 0
	var first_bad := ""
	for q in range(-20, 21):
		for r in range(-20, 21):
			var want := HexUtils.cube_to_offset(q, r)
			var got := HexCellField.axial_to_offset(q, r)
			if got != want:
				offset_bad += 1
				if first_bad.is_empty():
					first_bad = "axial(%d,%d) -> %s want %s" % [q, r, str(got), str(want)]
			var wrap_map_w := 9
			var got_wrapped := HexCellField.axial_to_offset_wrapped(q, r, wrap_map_w)
			var want_wrapped := Vector2i(HexCellField.posmod_int(want.x, wrap_map_w), want.y)
			if got_wrapped != want_wrapped:
				wrapped_bad += 1
	_expect(offset_bad == 0,
		"axial_to_offset == HexUtils.cube_to_offset for q,r in [-20,20] (incl. negative r)"
		+ " (%d bad)%s" % [offset_bad, "" if first_bad.is_empty() else " first: " + first_bad])
	_expect(wrapped_bad == 0,
		"axial_to_offset_wrapped only posmods col, never row (%d bad)" % wrapped_bad)

	# fractional_axial（Vector2 / float32）与内部 float64 路径在 float32 预算内一致。
	var p := Vector2(123.5, -47.25)
	var a32 := HexCellField.fractional_axial(p, HEX_SIZE)
	var a64 := _fractional_axial_double(p)
	_expect(absf(a32.x - a64[0]) <= 1e-5 and absf(a32.y - a64[1]) <= 1e-5,
		"fractional_axial matches the float64 mirror within the float32 budget")

	# 便捷访问器与 field_at 的三个量必须同源。
	var center := HexUtils.cube_to_world(7, 11, HEX_SIZE)
	var f := HexCellField.field_at(center, HEX_SIZE, Vector2.ZERO, BAND)
	var w_at := HexCellField.weights_at(center, HEX_SIZE, Vector2.ZERO, BAND)
	var g_at := HexCellField.gap_at(center, HEX_SIZE, Vector2.ZERO)
	var w_in: Vector3 = f["w"]
	var g_in: Vector3 = f["gap"]
	var dom_i := HexCellField.dom_index_at(center, HEX_SIZE, Vector2.ZERO)
	_expect(w_at == w_in and g_at == g_in,
		"weights_at / gap_at return the same weights and gaps as field_at")
	_expect(dom_i == int(f["dom"]) and HexCellField.dom_weight(f) == _comp(w_in, dom_i),
		"dom_index_at and dom_weight agree with field_at's dom / w[dom]")
	_expect(HexCellField.cell_inside(f, 0) and HexCellField.cell_inside(f, 2),
		"map_h == 0 marks all three cells inside (no north/south test)")


# ─────────────────────────────────────────────────────────────────────────
# 3. tie-break：对偶三角边界与平局次序
# ─────────────────────────────────────────────────────────────────────────

func _check_tie_break() -> void:
	# 构造 t.x + t.y == 1 的点。0.25 / 0.5 / 0.75 / 0.125 / 0.875 在 float32/float64 里
	# 都精确可表示，所以走场函数的**分数 axial 入口**时 t 的和精确等于 1。
	# （世界坐标入口 wp 是 Vector2 = real_t 32 位，坐标量级几百 wu 时 t 只有 ~1e-6 精度，
	#   下面单独用 1e-5 的预算覆盖那条路径。）
	var fracs := [Vector2(0.25, 0.75), Vector2(0.5, 0.5), Vector2(0.75, 0.25),
			Vector2(0.125, 0.875), Vector2(0.875, 0.125)]
	var exact_points := 0
	var exact_tol_bad := 0
	var third_weight_bad := 0
	var exact_dom_bad := 0
	var world_dom_bad := 0
	var world_max_dev := 0.0
	var first_bad := ""
	for oq in range(-2, 3):
		for orow in range(-2, 3):
			for frac in fracs:
				var a := Vector2(float(oq) + frac.x, float(orow) + frac.y)
				var t_exact := a - a.floor()
				if absf(t_exact.x + t_exact.y - 1.0) > 1e-9:
					exact_tol_bad += 1
					continue
				exact_points += 1
				# 1) 精确入口：分数 axial 直给，t.x + t.y 精确为 1（up = step(1, 1) = 1）。
				var f := HexCellField.field_from_fractional_axial(a, BAND)
				if absf(f["w_raw"].x) > 1e-9:
					third_weight_bad += 1
				var expect := _expected_shared_cell(oq, orow, t_exact.x, t_exact.y)
				var dom_off := HexCellField.cell_offset(f, int(f["dom"]))
				if dom_off != expect:
					exact_dom_bad += 1
					if first_bad.is_empty():
						first_bad = "a=%s dom=%s want=%s" % [
							str(a), str(dom_off), str(expect)]
				# 2) 世界坐标入口：float32 入参，t 的和只有 ~1e-6 精度，断言放宽到 1e-5。
				var pw := _world_of_fractional_axial(a)
				var aq := _fractional_axial_double(pw)
				var tqx: float = aq[0] - floorf(aq[0])
				var tqy: float = aq[1] - floorf(aq[1])
				world_max_dev = maxf(world_max_dev, absf(tqx + tqy - 1.0))
				var fw := HexCellField.field_at(pw, HEX_SIZE, Vector2.ZERO, BAND)
				var expect_w := _expected_shared_cell(
						int(floorf(aq[0])), int(floorf(aq[1])), tqx, tqy)
				var dom_w := HexCellField.cell_offset(fw, int(fw["dom"]))
				if dom_w != expect_w:
					world_dom_bad += 1
					if first_bad.is_empty():
						first_bad = "world a=%s dom=%s want=%s" % [
							str(a), str(dom_w), str(expect_w)]
	_expect(exact_tol_bad == 0 and exact_points > 0,
		"constructed points land on the dual-triangle boundary: t.x+t.y == 1 within 1e-9 "
		+ "(%d points, %d off-boundary)" % [exact_points, exact_tol_bad])
	_expect(third_weight_bad == 0,
		"boundary points put all weight on the two shared cells (third barycentric == 0)")
	_expect(exact_dom_bad == 0,
		"boundary dom follows the documented 0>1>2 tie order on the shared edge"
		+ " (%d bad)%s" % [exact_dom_bad, "" if first_bad.is_empty() else " first: " + first_bad])
	_expect(world_max_dev <= 1e-5,
		"world-coordinate entry reconstructs the boundary within float32 budget 1e-5 (max dev %.9f)"
		% world_max_dev)
	_expect(world_dom_bad == 0,
		"boundary dom is consistent through the world-coordinate entry too (%d bad)" % world_dom_bad)

	# 2-way 精确平局：t = (0.5, 0.5)（两格权重相等）。documented 次序 ⇒ 下标 1 胜出：
	# up 三角的下标 1 是 o+(1,0)，down 三角的下标 1 是 o+(0,1)；这里 t.x+t.y == 1 取 down。
	var tie_a := Vector2(3.5, 7.5)
	var tie_f := HexCellField.field_from_fractional_axial(tie_a, BAND)
	var tie_dom := int(tie_f["dom"])
	var tie_w: Vector3 = tie_f["w_raw"]
	var tie_offset := HexCellField.cell_offset(tie_f, tie_dom)
	var tie_shared := [HexCellField.axial_to_offset(4, 7), HexCellField.axial_to_offset(3, 8)]
	_expect(tie_dom == 1 and absf(tie_w.y - tie_w.z) < 1e-12,
		"exact 2-way tie at t=(0.5, 0.5) resolves to index 1 by the documented 0>1>2 order")
	_expect(tie_offset == HexCellField.axial_to_offset(3, 8) and tie_offset in tie_shared,
		"exact 2-way tie picks the down-triangle index-1 cell o+(0,1) (%s)" % str(tie_offset))
	# 近邻两侧（各自不对称偏 ±1e-4：Vector2 是 real_t 32 位，1e-9 在 3.5 附近会被舍成 0）
	# 必须选到更重的那一格。
	var heavy_b := HexCellField.field_from_fractional_axial(Vector2(3.5 - 1e-4, 7.5 + 1e-4), BAND)
	var heavy_a := HexCellField.field_from_fractional_axial(Vector2(3.5 + 1e-4, 7.5 - 1e-4), BAND)
	_expect(HexCellField.cell_offset(heavy_b, int(heavy_b["dom"])) == HexCellField.axial_to_offset(3, 8) \
			and HexCellField.cell_offset(heavy_a, int(heavy_a["dom"])) == HexCellField.axial_to_offset(4, 7),
		"a 1e-4 perturbation around the tie flips dom to the strictly heavier shared cell")

	# dom 必须恒等于 w_raw 的 argmax（并列取最小下标）。
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var argmax_bad := 0
	var argmax_first := ""
	var probes := 20000
	for i in range(probes):
		var p := _random_point_in_extent(rng)
		var f := HexCellField.field_at(p, HEX_SIZE, Vector2.ZERO, BAND)
		var w_raw: Vector3 = f["w_raw"]
		var best := 0
		for k in range(1, 3):
			if _comp(w_raw, k) > _comp(w_raw, best):
				best = k
		if best != int(f["dom"]):
			argmax_bad += 1
			if argmax_first.is_empty():
				argmax_first = "p=%s w_raw=%s dom=%d argmax=%d" % [
					str(p), str(w_raw), int(f["dom"]), best]
	_expect(argmax_bad == 0,
		"dom == argmax(w_raw) with 0>1>2 order on %d points (%d bad)%s" % [
			probes, argmax_bad, "" if argmax_first.is_empty() else " first: " + argmax_first])


# ─────────────────────────────────────────────────────────────────────────
# 4. wrapping：只对 offset col 取模，且 col 恒非负
# ─────────────────────────────────────────────────────────────────────────

func _check_wrap() -> void:
	var period := HexUtils.wrap_period_x(MAP_W, HEX_SIZE)
	_expect(period > 0.0, "wrap period for map_w=%d / hex_size=%.1f is %.4f wu" % [
		MAP_W, HEX_SIZE, period])
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var bad_period := 0
	var bad_col := 0
	var first_bad := ""
	for i in range(2000):
		var col := rng.randi_range(MAP_W - 3, MAP_W - 1)   # 东缘三列
		var row := rng.randi_range(0, MAP_H - 1)
		var warp := Vector2.ZERO if (i & 1) == 0 else Vector2(5.0, -3.0)
		var cube := HexUtils.offset_to_cube(col, row)
		var p := HexUtils.cube_to_world(cube.x, cube.y, HEX_SIZE) \
			+ Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		var a := HexCellField.dom_at(p, HEX_SIZE, warp, 0, MAP_W)
		var b := HexCellField.dom_at(p + Vector2(period, 0.0), HEX_SIZE, warp, 0, MAP_W)
		if a != b:
			bad_period += 1
			if first_bad.is_empty():
				first_bad = "p=%s a=%s b=%s" % [str(p), str(a), str(b)]
		if a.x < 0 or a.x >= MAP_W:
			bad_col += 1
	_expect(bad_period == 0,
		"dom_at(p) == dom_at(p + wrap_period_x) in offset space (%d bad)%s" % [
			bad_period, "" if first_bad.is_empty() else " first: " + first_bad])
	_expect(bad_col == 0, "wrapped dom col is never outside [0, map_w) (%d bad)" % bad_col)

	# 地图西侧（未回绕 col 为负）必须折到东侧列。
	var west_bad := 0
	var west_first := ""
	for row in range(0, MAP_H, 5):
		for neg_col in [-1, -2, -3]:
			var cube := HexUtils.offset_to_cube(neg_col, row)
			var p := HexUtils.cube_to_world(cube.x, cube.y, HEX_SIZE)
			var off := HexCellField.dom_at(p, HEX_SIZE, Vector2.ZERO, 0, MAP_W)
			var want := HexCellField.posmod_int(neg_col, MAP_W)
			if off != Vector2i(want, row):
				west_bad += 1
				if west_first.is_empty():
					west_first = "neg_col=%d row=%d -> %s (want %s)" % [
						neg_col, row, str(off), str(Vector2i(want, row))]
	_expect(west_bad == 0,
		"west-of-map points wrap onto the east columns by posmod(col, map_w) (%d bad)%s" % [
			west_bad, "" if west_first.is_empty() else " first: " + west_first])

	# map_h > 0 时南北越界必须标成 padding，且 map_h == 0 时不判定。
	var north := HexUtils.offset_to_cube(4, -1)
	var north_p := HexUtils.cube_to_world(north.x, north.y, HEX_SIZE)
	var north_pad := HexCellField.field_at(north_p, HEX_SIZE, Vector2.ZERO, BAND, MAP_H, MAP_W)
	var inside := PackedByteArray()
	inside.resize(3)
	var pad_count := 0
	for k in range(3):
		inside[k] = 1 if HexCellField.cell_inside(north_pad, k) else 0
		if inside[k] == 0:
			pad_count += 1
	_expect(pad_count > 0, "row -1 marks at least one cell as out-of-map padding")
	var no_pad := HexCellField.field_at(north_p, HEX_SIZE, Vector2.ZERO, BAND, 0, MAP_W)
	_expect(HexCellField.cell_inside(no_pad, 0) and HexCellField.cell_inside(no_pad, 1) \
			and HexCellField.cell_inside(no_pad, 2),
		"map_h == 0 disables the north/south padding test")


# ─────────────────────────────────────────────────────────────────────────
# 5. warp RG8 编解码：误差 ≤ 契约的 0.1 wu
# ─────────────────────────────────────────────────────────────────────────

func _check_decode_warp_roundtrip() -> void:
	var scale: float = HexCellField.WARP_RANGE * HEX_SIZE * HexCellField.WARP_AMP
	_expect(absf(scale - 14.08) < 1e-9,
		"warp world scale = range*hex_size*amp = %.4f wu (1.6*22*0.4)" % scale)
	var half_step := scale / 255.0
	_expect(half_step <= 0.1,
		"RG8 half-step %.4f wu is inside the contract's 0.1 wu quantization budget at hex_size=22"
			% half_step)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20261119
	var max_err := 0.0
	var err_bad := 0
	for i in range(5000):
		var norm := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		var warp := norm * scale
		var rg := HexCellField.encode_warp_world(warp, HEX_SIZE)
		var back := HexCellField.decode_warp_byte(rg.x, rg.y, HEX_SIZE)
		var err := maxf(absf(back.x - warp.x), absf(back.y - warp.y))
		max_err = maxf(max_err, err)
		if err > 0.1:
			err_bad += 1
	_expect(err_bad == 0, "5000 warp round-trips stay within 0.1 wu (max error %.5f wu)" % max_err)

	# 端点与中点：clamp 到 ±scale，128/127 夹住 0。
	var plus := HexCellField.encode_warp_world(Vector2(scale, scale), HEX_SIZE)
	var minus := HexCellField.encode_warp_world(Vector2(-scale, -scale), HEX_SIZE)
	var clamp_hi := HexCellField.encode_warp_world(Vector2(10.0 * scale, -10.0 * scale), HEX_SIZE)
	_expect(plus == Vector2i(255, 255) and minus == Vector2i(0, 0),
		"full-scale warp encodes to RG8 endpoints (255/255 and 0/0)")
	_expect(clamp_hi == Vector2i(255, 0),
		"out-of-range warp is clamped to [0, 255] like the C++ encoder")
	var back_plus := HexCellField.decode_warp_byte(255, 255, HEX_SIZE)
	_expect(absf(back_plus.x - scale) < 1e-5 and absf(back_plus.y - scale) < 1e-5,
		"decoding 255/255 returns +warp_range*hex_size*warp_amp")
	# decode 的返回类型是 Vector2（real_t = 32 位），端点断言留 1e-5 的打包余量。
	var mid_lo := HexCellField.decode_warp_byte(127, 127, HEX_SIZE)
	var mid_hi := HexCellField.decode_warp_byte(128, 128, HEX_SIZE)
	_expect(mid_lo.x < 0.0 and mid_hi.x > 0.0 and absf(mid_lo.x) <= half_step + 1e-6 \
			and absf(mid_hi.x) <= half_step + 1e-6,
		"bytes 127/128 straddle zero within half a quantization step")
	var custom := HexCellField.decode_warp_byte(255, 0, HEX_SIZE, 2.0, 0.5)
	_expect(absf(custom.x - 2.0 * HEX_SIZE * 0.5) < 1e-5 \
			and absf(custom.y + 2.0 * HEX_SIZE * 0.5) < 1e-5,
		"decode honours explicit warp_range / warp_amp arguments")


# ─────────────────────────────────────────────────────────────────────────
# 6. gap 单位：沿相邻格中心连线 gap = 2·d/hex_size
# ─────────────────────────────────────────────────────────────────────────

func _check_gap_unit() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var bad := 0
	var first_bad := ""
	var samples := 0
	var max_err := 0.0
	var max_third_err := 0.0
	var third_bad := 0
	for i in range(300):
		var col := rng.randi_range(1, 24)
		var row := rng.randi_range(1, 12)
		var warp := Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
		var off_a := Vector2i(col, row)
		var off_b := Vector2i(col + 1, row)   # odd-r 同行东邻 = cube 邻居
		var cube_a := HexUtils.offset_to_cube(col, row)
		var cube_b := HexUtils.offset_to_cube(col + 1, row)
		# 中心用 float64 算（HexUtils.cube_to_world 返回 Vector2 = real_t 32 位，量级 1e3 时
		# 绝对误差 ~1e-4 wu，会把 1e-6 的 gap 断言吃掉）。
		var center_a_x: float = HEX_SIZE * SQRT3 * (float(cube_a.x) + float(cube_a.y) * 0.5)
		var center_a_y: float = HEX_SIZE * 1.5 * float(cube_a.y)
		var center_b_x: float = HEX_SIZE * SQRT3 * (float(cube_b.x) + float(cube_b.y) * 0.5)
		var center_b_y: float = HEX_SIZE * 1.5 * float(cube_b.y)
		# |pb − pa| = √3·hex_size。
		var dx := center_b_x - center_a_x
		var dy := center_b_y - center_a_y
		var span := sqrt(dx * dx + dy * dy)
		var ux := dx / span
		var uy := dy / span
		var mid_x := (center_a_x + center_b_x) * 0.5
		var mid_y := (center_a_y + center_b_y) * 0.5
		var dist := rng.randf_range(0.5, 9.0)   # wu，远小于 √3/2·s ≈ 19.05
		for sign_dir in [1.0, -1.0]:
			var signed: float = dist * float(sign_dir)
			var target_x: float = mid_x + ux * signed
			var target_y: float = mid_y + uy * signed
			# field_at 内部的扭曲坐标是 wp + warp（都是 Vector2 / float32），故反推 wp，
			# 再按同一套 float32 加法还原出它真正用的 p，用它量 d 才是严格可比的。
			var wpt := Vector2(target_x - float(warp.x), target_y - float(warp.y))
			var p_used: Vector2 = wpt + warp
			var f := HexCellField.field_at(wpt, HEX_SIZE, warp, BAND)
			var d_actual: float = \
				(float(p_used.x) - mid_x) * ux + (float(p_used.y) - mid_y) * uy
			var i_a := -1
			var i_b := -1
			for k in range(3):
				var off := HexCellField.cell_offset(f, k)
				if off == off_a:
					i_a = k
				elif off == off_b:
					i_b = k
			if i_a < 0 or i_b < 0:
				bad += 1
				if first_bad.is_empty():
					first_bad = "pair %s/%s not both in triangle (a=%d b=%d)" % [
						str(off_a), str(off_b), i_a, i_b]
				continue
			samples += 1
			# 沿 A→B 方向偏离中点 d>0 ⇒ 离 B 更近；d<0 ⇒ 离 A 更近。
			var near := i_b if d_actual > 0.0 else i_a
			var far := i_a if d_actual > 0.0 else i_b
			var gap: Vector3 = f["gap"]
			# 契约：沿格中心连线 gap = 2·|d| / hex_size（这就是 √3 因子被钉死的地方）。
			var want := 2.0 * absf(d_actual) / HEX_SIZE
			var err := absf(_comp(gap, far) - want)
			max_err = maxf(max_err, err)
			if int(f["dom"]) != near or _comp(gap, near) != 0.0 or err > 1e-6:
				bad += 1
				if first_bad.is_empty():
					first_bad = "off=%s d=%.6f gap_far=%.9f want=%.9f dom=%d near=%d" % [
						str(off_a), d_actual, _comp(gap, far), want, int(f["dom"]), near]
			# 共享边上的第三格权重恒为 0，故 gap_third = w_dom·√3；而 gap_far = (2·w_dom − 1)·√3，
			# 两者闭合于 gap_third = (gap_far + √3)/2。同时这是方案 §3.2 的带宽上限依据：
			# 第三格在共享边上的 gap ≥ √3/2 ≈ 0.866 > PK_FIELD_BAND_MAX = 0.86。
			for k in range(3):
				if k != i_a and k != i_b:
					var gap_third := _comp(gap, k)
					max_third_err = maxf(max_third_err,
						absf(gap_third - (_comp(gap, far) + SQRT3) * 0.5))
					if gap_third < SQRT3 * 0.5 - 1e-6:
						third_bad += 1
						if first_bad.is_empty():
							first_bad = "third gap %.9f below sqrt3/2 at off=%s" % [
								gap_third, str(off_a)]
	_expect(samples > 0, "adjacent-center gap samples were exercised (%d)" % samples)
	_expect(bad == 0,
		"gap(non-dominant) == 2*d/hex_size along adjacent cell centers within 1e-6 "
		+ "(max error %.9f)%s" % [max_err, "" if first_bad.is_empty() else " first: " + first_bad])
	_expect(third_bad == 0,
		"third-cell gap stays >= sqrt3/2 = 0.866 (the PK_FIELD_BAND_MAX = 0.86 bound)")
	_expect(max_third_err < 1e-5,
		"third cell on the shared edge: gap == (gap_far + sqrt3)/2 == w_dom*sqrt3 "
		+ "(max error %.9f)" % max_third_err)


# ─────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────

## 分数 axial → 世界坐标（HexUtils.cube_to_world 的连续版，用于反推测试点）。
func _world_of_fractional_axial(a: Vector2) -> Vector2:
	return Vector2(
		HEX_SIZE * SQRT3 * (a.x + a.y * 0.5),
		HEX_SIZE * 1.5 * a.y)


## 与 field_at 内部同式的 **float64** 分数 axial，返回 [q, r]。
## 不能用 HexCellField.fractional_axial()：它返回 Vector2（real_t 32 位），
## 分数坐标量级 ~100 时会被舍到 ~1e-5，不足以判断 t.x+t.y 落在对偶边界的哪一侧。
func _fractional_axial_double(p: Vector2) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.append((0.5773502691896258 * float(p.x) - float(p.y) / 3.0) / HEX_SIZE)
	out.append((2.0 / 3.0 * float(p.y)) / HEX_SIZE)
	return out


## 共享边（t.x + t.y == 1）上按 documented 0>1>2 次序应有的主导格。
##   up 三角（t.x+t.y < 1）：权重 (1−tx−ty, tx, ty)，下标 1 是 o+(1,0)、下标 2 是 o+(0,1)；
##   down 三角（t.x+t.y ≥ 1）：权重 (tx+ty−1, 1−tx, 1−ty)，下标 1 是 o+(0,1)、下标 2 是 o+(1,0)；
##   两格严格相等时下标 1 胜出（这就是平局次序 0 > 1 > 2 的可观测后果）。
func _expected_shared_cell(ox: int, oy: int, tx: float, ty: float) -> Vector2i:
	var cell_10 := HexCellField.axial_to_offset(ox + 1, oy)
	var cell_01 := HexCellField.axial_to_offset(ox, oy + 1)
	if tx + ty >= 1.0:
		if tx > ty:
			return cell_10
		return cell_01
	if ty > tx:
		return cell_01
	return cell_10


func _comp(v: Vector3, i: int) -> float:
	if i == 0:
		return v.x
	if i == 1:
		return v.y
	return v.z


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
