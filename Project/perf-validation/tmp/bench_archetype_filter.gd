@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_archetype_filter.gd — DOTS-A1 EXPERIMENT
# ════════════════════════════════════════════════════════════════════
#
# Goal: empirically measure the cost / benefit of "archetype-as-logical-
# filter" on top of the canonical demo_complex pass.
#
# Three rows per (grid, iter, kr) configuration:
#   1. vanilla            — calls run_demo_complex_pass (no archetype branch
#                           in the hot loop). This is the reference number
#                           from performance-charter §12.6.6.
#   2. archetyped_all     — calls run_demo_complex_pass_archetyped with
#                           target_archetype=-1 (no filter). Same algorithm
#                           as vanilla; the only difference is one extra
#                           branch per cell in stages 6-8. Measures pure
#                           branch-overhead.
#   3. archetyped_land    — calls run_demo_complex_pass_archetyped with
#                           target_archetype=LAND_ARCH. Cells whose
#                           is_water mask is true get archetype=OCEAN,
#                           are skipped (OUT[i]=0.0f) in stages 6-8 but
#                           still participate as neighbours in 5.x.
#
# Bit-equal contract:
#   * vanilla vs archetyped_all  → STRICT bit-equal (tolerance=0). Filter
#     off must be byte-for-byte identical to the vanilla pass.
#   * archetyped_all vs archetyped_land → NOT bit-equal by design (the
#     latter zeros out OCEAN cells, and re-normalizes only over LAND).
#     We only assert the LAND-cell subset is "approximately" the same
#     ratio as the vanilla LAND values (sanity check, no hard assert).
#
# Reference for hand-off:
#   docs/cpp-gdscript-best-practices.md §3 (Mode-B), §4 (Step 6-8),
#   tmp/bench_demo_complex.gd (the file this is structurally cloned from).
# ════════════════════════════════════════════════════════════════════

const TOLERANCE: float = 1.0e-6

# Bit-equal verification group (small + fast)
const BE_GRID_W: int = 32
const BE_GRID_H: int = 32
const BE_ITER: int = 4
const BE_KR: int = 2
const BE_CORIOLIS: float = 0.5
const BE_DRAG: float = 0.6
const BE_GAIN: float = 1.5
const BE_K: float = 0.5

# Perf rows
const PERF_GRID_DIMS: Array = [
	[32, 32],
	[64, 64],
	[128, 128],
]
const PERF_ITER_LIST: Array = [4, 16]
const PERF_KR: int = 2
const PERF_CORIOLIS: float = 0.5
const PERF_DRAG: float = 0.6
const PERF_GAIN: float = 1.5
const PERF_K: float = 0.5

# Archetype IDs (assigned via create_archetype, ids returned by C++)
# We'll capture the actual ids at runtime; these consts are just for clarity.
const ARCH_NAME_LAND: StringName = &"LAND"
const ARCH_NAME_OCEAN: StringName = &"OCEAN"


# ────────────────────────────────────────────────────────────────────
# Entry
# ────────────────────────────────────────────────────────────────────
func _run() -> void:
	print("=== bench_archetype_filter — DOTS-A1 EXPERIMENT ===")
	print("Bit-equal group: %dx%d iter=%d kr=%d" \
		% [BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR])
	print("Perf group: grids=%s × iters=%s, kr=%d" \
		% [str(PERF_GRID_DIMS), str(PERF_ITER_LIST), PERF_KR])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_archetype_filter] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# ─── 1. Bit-equal: vanilla vs archetyped_all ───────────────────
	var be_n: int = BE_GRID_W * BE_GRID_H
	var be_temp: PackedFloat32Array = _make_temp_input(BE_GRID_W, BE_GRID_H)
	var be_elev: PackedFloat32Array = _make_elevation_input(BE_GRID_W, BE_GRID_H)
	var be_water: PackedByteArray   = _make_is_water_mask(BE_GRID_W, BE_GRID_H)

	# vanilla
	var ext_v: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	var probe_v: Object = ext_v
	if not probe_v.has_method("run_demo_complex_pass_archetyped"):
		push_error("[bench_archetype_filter] DCWorldExt missing run_demo_complex_pass_archetyped — rebuild gdext.")
		return
	ext_v.run_demo_complex_pass(BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K)
	var out_v: PackedFloat32Array = ext_v.snapshot_f32(
		int(ext_v.component_id("cell_demo_thermal_gradient")))

	# archetyped_all (no filter)
	var ext_a: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	_assign_archetypes(ext_a, be_n, be_water)
	ext_a.run_demo_complex_pass_archetyped(BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K, -1)
	var out_a: PackedFloat32Array = ext_a.snapshot_f32(
		int(ext_a.component_id("cell_demo_thermal_gradient")))

	# archetyped_land (filter LAND only)
	var ext_l: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	var land_id: int = _assign_archetypes(ext_l, be_n, be_water)
	ext_l.run_demo_complex_pass_archetyped(BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K, land_id)
	var out_l: PackedFloat32Array = ext_l.snapshot_f32(
		int(ext_l.component_id("cell_demo_thermal_gradient")))

	# Compare
	var be_max_diff_va: float = _max_abs_diff(out_v, out_a)
	var be_bit_equal_va: bool = _check_arrays_bit_equal(out_v, out_a)
	print("─── Bit-equal: vanilla vs archetyped_all ───")
	print("  bit-equal     : " + ("PASS" if be_bit_equal_va else "FAIL"))
	print("  max_abs_diff  : " + String.num(be_max_diff_va, 9))

	# Sanity: archetyped_land must zero out OCEAN cells
	var ocean_zeroed: bool = true
	var land_count: int = 0
	var ocean_count: int = 0
	for i in range(be_n):
		if be_water[i] != 0:
			ocean_count += 1
			if out_l[i] != 0.0:
				ocean_zeroed = false
		else:
			land_count += 1
	print("─── Sanity: archetyped_land OCEAN-cells-zeroed ───")
	print("  land=" + str(land_count) + " ocean=" + str(ocean_count)
		+ " ocean_all_zero=" + ("YES" if ocean_zeroed else "NO"))
	print("")

	# ─── 2. Perf table ─────────────────────────────────────────────
	print("─── Perf table (grid × iter × 3 modes) ───")
	print("| grid       | iter | mode             | µs        | vs vanilla |")
	print("|------------|------|------------------|-----------|------------|")
	for gd in PERF_GRID_DIMS:
		var w: int = int(gd[0])
		var h: int = int(gd[1])
		for iter in PERF_ITER_LIST:
			var n: int = w * h
			var temp_in: PackedFloat32Array = _make_temp_input(w, h)
			var elev_in: PackedFloat32Array = _make_elevation_input(w, h)
			var water_mask: PackedByteArray = _make_is_water_mask(w, h)

			# vanilla
			var ext_p1: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			var t0_v: int = Time.get_ticks_usec()
			ext_p1.run_demo_complex_pass(w, h, iter, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K)
			var us_v: int = Time.get_ticks_usec() - t0_v

			# archetyped_all
			var ext_p2: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			_assign_archetypes(ext_p2, n, water_mask)
			var t0_a: int = Time.get_ticks_usec()
			ext_p2.run_demo_complex_pass_archetyped(w, h, iter, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, -1)
			var us_a: int = Time.get_ticks_usec() - t0_a

			# archetyped_land
			var ext_p3: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			var land_id_p: int = _assign_archetypes(ext_p3, n, water_mask)
			var t0_l: int = Time.get_ticks_usec()
			ext_p3.run_demo_complex_pass_archetyped(w, h, iter, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, land_id_p)
			var us_l: int = Time.get_ticks_usec() - t0_l

			var grid_str: String = str(w) + "x" + str(h)
			var ratio_a: String = ("%5.2fx" % (float(us_a) / float(us_v))) if us_v > 0 else "  n/a"
			var ratio_l: String = ("%5.2fx" % (float(us_l) / float(us_v))) if us_v > 0 else "  n/a"
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter)
				+ " | vanilla          | " + ("%9d" % us_v) + " |     1.00x  |")
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter)
				+ " | archetyped_all   | " + ("%9d" % us_a) + " |    " + ratio_a + "  |")
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter)
				+ " | archetyped_land  | " + ("%9d" % us_l) + " |    " + ratio_l + "  |")
	print("")
	print("[bench_archetype_filter] DONE - vanilla≡archetyped_all bit-equal="
		+ ("PASS" if be_bit_equal_va else "FAIL")
		+ ", ocean-zeroed=" + ("PASS" if ocean_zeroed else "FAIL"))


# ════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════
func _make_ext(n: int, temp_input: PackedFloat32Array,
		elev_input: PackedFloat32Array) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var cid_temp: int = int(ext.register_component("cell_temp", 0, 1, false))
	var cid_elev: int = int(ext.register_component("cell_elevation", 0, 1, false))
	var _cid_out: int = int(ext.register_component("cell_demo_thermal_gradient", 0, 1, false))
	ext.create_pool("cells", n)
	ext.write_f32_range(cid_temp, 0, temp_input)
	ext.write_f32_range(cid_elev, 0, elev_input)
	return ext


# Returns the LAND archetype id (callers use it as target_archetype).
func _assign_archetypes(ext: Object, n: int, is_water: PackedByteArray) -> int:
	# create_archetype returns existing id on duplicate, so calling twice
	# inside the same ext instance is safe.
	var land_id: int = int(ext.create_archetype(ARCH_NAME_LAND, []))
	var ocean_id: int = int(ext.create_archetype(ARCH_NAME_OCEAN, []))
	for i in range(n):
		if is_water[i] != 0:
			ext.assign_archetype(i, ocean_id)
		else:
			ext.assign_archetype(i, land_id)
	return land_id


func _make_temp_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	for y in range(h):
		var ny: float = (float(y) + 0.5) / float(h)
		for x in range(w):
			var nx: float = (float(x) + 0.5) / float(w)
			var base: float = nx
			var wave: float = 0.15 * cos(nx * TAU * 2.0) * sin(ny * PI)
			arr[y * w + x] = base + wave
	return arr


func _make_elevation_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	var seed_v: int = 0x9E3779B1
	for i in range(w * h):
		seed_v = (seed_v * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = float(seed_v % 10000) / 10000.0
	return arr


# Deterministic land/ocean mask (~30% ocean) using a separate PCG seed
# from the elevation generator so the two masks are uncorrelated.
func _make_is_water_mask(w: int, h: int) -> PackedByteArray:
	var arr: PackedByteArray = PackedByteArray()
	arr.resize(w * h)
	var seed_v: int = 0x6789ABCD
	for i in range(w * h):
		seed_v = (seed_v * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = 1 if ((seed_v % 100) < 30) else 0
	return arr


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var n: int = a.size()
	var m: float = 0.0
	for i in range(n):
		var d: float = absf(a[i] - b[i])
		if d > m:
			m = d
	return m


func _check_arrays_bit_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		print("    size mismatch: %d vs %d" % [a.size(), b.size()])
		return false
	var n: int = a.size()
	var fail_count: int = 0
	for i in range(n):
		if a[i] != b[i]:
			if fail_count < 5:
				print("    [" + str(i) + "] cpp=" + String.num(a[i], 9)
					+ " arch_all=" + String.num(b[i], 9)
					+ " abs_diff=" + String.num(absf(a[i] - b[i]), 9))
			fail_count += 1
	if fail_count > 0:
		print("    " + str(fail_count) + " / " + str(n)
			+ " cells diverge between paths (bit comparison)")
		return false
	return true
