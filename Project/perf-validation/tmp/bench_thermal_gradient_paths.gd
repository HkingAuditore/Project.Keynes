@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_thermal_gradient_paths.gd — DOTS production-path comparison
# ════════════════════════════════════════════════════════════════════
#
# Validates the three dispatch paths now wired through main.gd:
#   * LEGACY        — direct ext.run_demo_complex_pass (pre-DOTS baseline)
#   * ECS           — DCEcsScheduler with one job (same kernel)
#   * ECS_ARCHETYPE — DCEcsScheduler + run_demo_complex_pass_archetyped
#                     with target_archetype = LAND
#
# Goals:
#   1. Bit-equal: LEGACY ≡ ECS  (max_abs_diff = 0.0). The ECS path is just
#      a topological-sort shim around the same kernel, so any divergence
#      means the scheduler wrapper itself perturbed the call.
#   2. Sanity:   ECS_ARCHETYPE writes 0.0 to every OCEAN cell.
#   3. Perf:     Three rows per (grid × iter) showing the *added*
#      scheduler / archetype-filter overhead vs the LEGACY baseline.
#
# Inputs are deterministic (cloned from bench_archetype_filter.gd) so
# results are cross-comparable with the A1 sandbox.
#
# This bench loads the production library classes from
# `res://scripts/ecs/`, NOT the tmp sandbox copies. That's the whole
# point of the DOTS-A2 promotion.
# ════════════════════════════════════════════════════════════════════

const DCEcsJobScript = preload("res://scripts/ecs/dc_ecs_job.gd")
const DCEcsSchedulerScript = preload("res://scripts/ecs/dc_ecs_scheduler.gd")

# Bit-equal verification group (small + fast)
const BE_GRID_W: int = 32
const BE_GRID_H: int = 32
const BE_ITER: int = 4
const BE_KR: int = 2

# Perf rows — same shape as bench_archetype_filter so apples-to-apples.
const PERF_GRID_DIMS: Array = [
	[32, 32],
	[60, 40],   # production default (main map size)
	[128, 128],
]
const PERF_ITER_LIST: Array = [4, 16]

const PERF_KR: int = 2
const PERF_CORIOLIS: float = 0.5
const PERF_DRAG: float = 0.6
const PERF_GAIN: float = 1.5
const PERF_K: float = 0.5

const ARCH_NAME_LAND: StringName = &"LAND"
const ARCH_NAME_OCEAN: StringName = &"OCEAN"


func _run() -> void:
	print("=== bench_thermal_gradient_paths — DOTS production paths ===")
	print("Bit-equal group: %dx%d iter=%d kr=%d" % [BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR])
	print("Perf group: grids=%s × iters=%s, kr=%d" % [str(PERF_GRID_DIMS), str(PERF_ITER_LIST), PERF_KR])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_thermal_gradient_paths] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# ─── 1. Bit-equal: LEGACY vs ECS ──────────────────────────────
	var be_n: int = BE_GRID_W * BE_GRID_H
	var be_temp: PackedFloat32Array = _make_temp_input(BE_GRID_W, BE_GRID_H)
	var be_elev: PackedFloat32Array = _make_elevation_input(BE_GRID_W, BE_GRID_H)
	var be_water: PackedByteArray   = _make_is_water_mask(BE_GRID_W, BE_GRID_H)

	var ext_legacy: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	ext_legacy.run_demo_complex_pass(BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K)
	var out_legacy: PackedFloat32Array = ext_legacy.snapshot_f32(
		int(ext_legacy.component_id("cell_demo_thermal_gradient")))

	var ext_ecs: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	_run_ecs_path(ext_ecs, BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, -1)
	var out_ecs: PackedFloat32Array = ext_ecs.snapshot_f32(
		int(ext_ecs.component_id("cell_demo_thermal_gradient")))

	var max_diff_le: float = _max_abs_diff(out_legacy, out_ecs)
	var bit_equal_le: bool = _check_bit_equal(out_legacy, out_ecs)
	print("─── Bit-equal: LEGACY vs ECS ───")
	print("  bit-equal     : " + ("PASS" if bit_equal_le else "FAIL"))
	print("  max_abs_diff  : " + String.num(max_diff_le, 9))

	# ─── 2. Sanity: ECS_ARCHETYPE zeros ocean cells ───────────────
	var ext_arch: Object = _make_ext(be_n, be_temp.duplicate(), be_elev.duplicate())
	var land_id: int = _assign_archetypes(ext_arch, be_n, be_water)
	_run_ecs_path(ext_arch, BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, land_id)
	var out_arch: PackedFloat32Array = ext_arch.snapshot_f32(
		int(ext_arch.component_id("cell_demo_thermal_gradient")))

	var ocean_zeroed: bool = true
	var land_count: int = 0
	var ocean_count: int = 0
	for i in range(be_n):
		if be_water[i] != 0:
			ocean_count += 1
			if out_arch[i] != 0.0:
				ocean_zeroed = false
		else:
			land_count += 1
	print("─── Sanity: ECS_ARCHETYPE OCEAN-cells-zeroed ───")
	print("  land=%d ocean=%d ocean_all_zero=%s"
		% [land_count, ocean_count, "YES" if ocean_zeroed else "NO"])
	print("")

	# ─── 3. Perf table ────────────────────────────────────────────
	print("─── Perf table (grid × iter × 3 paths) ───")
	print("| grid       | iter | path             | µs        | vs legacy  |")
	print("|------------|------|------------------|-----------|------------|")
	for gd in PERF_GRID_DIMS:
		var w: int = int(gd[0])
		var h: int = int(gd[1])
		for iter_count in PERF_ITER_LIST:
			var n: int = w * h
			var temp_in: PackedFloat32Array = _make_temp_input(w, h)
			var elev_in: PackedFloat32Array = _make_elevation_input(w, h)
			var water_mask: PackedByteArray = _make_is_water_mask(w, h)

			# LEGACY
			var ext_p1: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			var t0_l: int = Time.get_ticks_usec()
			ext_p1.run_demo_complex_pass(w, h, iter_count, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K)
			var us_l: int = Time.get_ticks_usec() - t0_l

			# ECS
			var ext_p2: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			var t0_e: int = Time.get_ticks_usec()
			_run_ecs_path(ext_p2, w, h, iter_count, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, -1)
			var us_e: int = Time.get_ticks_usec() - t0_e

			# ECS_ARCHETYPE
			var ext_p3: Object = _make_ext(n, temp_in.duplicate(), elev_in.duplicate())
			var land_id_p: int = _assign_archetypes(ext_p3, n, water_mask)
			var t0_a: int = Time.get_ticks_usec()
			_run_ecs_path(ext_p3, w, h, iter_count, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K, land_id_p)
			var us_a: int = Time.get_ticks_usec() - t0_a

			var grid_str: String = str(w) + "x" + str(h)
			var ratio_e: String = ("%5.2fx" % (float(us_e) / float(us_l))) if us_l > 0 else "  n/a"
			var ratio_a: String = ("%5.2fx" % (float(us_a) / float(us_l))) if us_l > 0 else "  n/a"
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter_count)
				+ " | LEGACY           | " + ("%9d" % us_l) + " |     1.00x  |")
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter_count)
				+ " | ECS              | " + ("%9d" % us_e) + " |    " + ratio_e + "  |")
			print("| " + ("%-10s" % grid_str) + " | " + ("%4d" % iter_count)
				+ " | ECS_ARCHETYPE    | " + ("%9d" % us_a) + " |    " + ratio_a + "  |")
	print("")
	var all_pass: bool = bit_equal_le and ocean_zeroed
	print("[bench_thermal_gradient_paths] DONE — bit_equal(LEGACY≡ECS)="
		+ ("PASS" if bit_equal_le else "FAIL")
		+ ", ocean_zeroed=" + ("PASS" if ocean_zeroed else "FAIL")
		+ ", overall=" + ("PASS" if all_pass else "FAIL"))


# ────────────────────────────────────────────────────────────────────
# ECS dispatch — mirrors main.gd::_run_demo_tg_via_ecs but standalone
# so the bench doesn't depend on a running scene.
# ────────────────────────────────────────────────────────────────────
func _run_ecs_path(ext: Object, w: int, h: int, iter_count: int, kr: int,
		coriolis: float, drag: float, gain: float, k: float,
		archetype_filter: int) -> void:
	var sched = DCEcsSchedulerScript.new()
	var cid_temp: int = int(ext.component_id("cell_temp"))
	var cid_elev: int = int(ext.component_id("cell_elevation"))
	var cid_out: int = int(ext.component_id("cell_demo_thermal_gradient"))

	var runner: Callable
	if archetype_filter >= 0:
		runner = Callable(self, "_run_demo_complex_archetyped")
	else:
		runner = Callable(self, "_run_demo_complex")

	sched.add_job(DCEcsJobScript.new(
		&"demo_thermal_gradient",
		[cid_temp, cid_elev],
		[cid_out],
		runner,
		archetype_filter,
		{}
	))
	var ctx: Dictionary = {
		"ext": ext,
		"w": w, "h": h,
		"iter": iter_count, "kr": kr,
		"coriolis": coriolis, "drag": drag,
		"gain": gain, "k": k,
	}
	sched.tick(ctx)


func _run_demo_complex(ctx: Dictionary, _job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]))


func _run_demo_complex_archetyped(ctx: Dictionary, job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass_archetyped(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]),
		int(job.archetype_filter))


# ────────────────────────────────────────────────────────────────────
# Helpers — deterministic inputs (kept identical to bench_archetype_filter
# so cross-bench comparisons are valid).
# ────────────────────────────────────────────────────────────────────
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


func _assign_archetypes(ext: Object, n: int, is_water: PackedByteArray) -> int:
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


func _check_bit_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		print("    size mismatch: %d vs %d" % [a.size(), b.size()])
		return false
	var n: int = a.size()
	var fail_count: int = 0
	for i in range(n):
		if a[i] != b[i]:
			if fail_count < 5:
				print("    [%d] legacy=%s ecs=%s diff=%s" % [
					i, String.num(a[i], 9), String.num(b[i], 9),
					String.num(absf(a[i] - b[i]), 9)
				])
			fail_count += 1
	if fail_count > 0:
		print("    %d / %d cells diverge" % [fail_count, n])
		return false
	return true
