@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# 👉 RUN THIS FILE (and only this file) to execute the DOTS-A2 experiment.
#    The two siblings `demo_ecs_job.gd` / `demo_ecs_scheduler.gd` are
#    library classes (extends RefCounted) — they are loaded via preload
#    below and must NOT be Run directly from the editor.
# ════════════════════════════════════════════════════════════════════
#
# demo_ecs_run.gd — DOTS-A2 EXPERIMENT entry
# ════════════════════════════════════════════════════════════════════
#
# Wires three "jobs" through the demo ECS scheduler and proves:
#
#   * The scheduler's topo-sort produces a legal execution order based
#     ONLY on declared reads/writes (no hand-coded sequence).
#   * The result is bit-equal to a hand-coded sequential dispatch of the
#     same three C++ kernels, run in the same order.
#   * Cycle detection works: a deliberately broken job graph reports an
#     error and produces no output.
#
# Job graph (intentional, to exercise both write→read and write→write
# edges plus an unrelated parallel-eligible job):
#
#   J1  temp_drift            reads=[CELL_TEMP]                    writes=[CELL_TEMP]
#   J2  thermal_gradient_LAND reads=[CELL_TEMP, CELL_ELEVATION]    writes=[CELL_DEMO_THERMAL_GRADIENT]
#                             filter=LAND
#   J3  thermal_gradient_ALL  reads=[CELL_TEMP, CELL_ELEVATION]    writes=[CELL_DEMO_THERMAL_GRADIENT]
#                             filter=-1   (registered AFTER J2 to test write-after-write)
#
# Expected topo order: J1 → J2 → J3.
#   * J2 must be after J1 because J2 reads CELL_TEMP that J1 writes.
#   * J3 must be after J1 (same reason) AND after J2 (write-after-write
#     on CELL_DEMO_THERMAL_GRADIENT, broken by registration order).
#
# The final scoreable output is therefore "what J3 wrote", which is
# `run_demo_complex_pass_archetyped(..., target=-1)` applied AFTER
# CELL_TEMP got drifted. We compare that to a hand-coded
# (drift → archetyped vanilla) sequence using a fresh DCWorldExt.
# ════════════════════════════════════════════════════════════════════

const DemoEcsJobScript = preload("res://tmp/demo_ecs_job.gd")
const DemoEcsSchedulerScript = preload("res://tmp/demo_ecs_scheduler.gd")

const GRID_W: int = 32
const GRID_H: int = 32
const ITER: int = 4
const KR: int = 2
const CORIOLIS: float = 0.5
const DRAG: float = 0.6
const GAIN: float = 1.5
const K: float = 0.5
const DRIFT_AMOUNT: float = 0.1


func _run() -> void:
	print("=== demo_ecs_run — DOTS-A2 EXPERIMENT ===")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[demo_ecs_run] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	var n: int = GRID_W * GRID_H
	var temp_input: PackedFloat32Array = _make_temp_input(GRID_W, GRID_H)
	var elev_input: PackedFloat32Array = _make_elevation_input(GRID_W, GRID_H)
	var water_mask: PackedByteArray = _make_is_water_mask(GRID_W, GRID_H)

	# ─── 1. Hand-coded reference path ──────────────────────────────
	# Same three kernels, fixed order: drift → archetyped LAND → archetyped ALL.
	# We only score the LAST write (archetyped ALL), since that's what J3 produces.
	var ext_ref: Object = _make_ext(n, temp_input.duplicate(), elev_input.duplicate())
	var land_id_ref: int = _assign_archetypes(ext_ref, n, water_mask)
	# step 1
	ext_ref.run_temp_drift_pass(DRIFT_AMOUNT)
	# step 2 — LAND filtered (writes will be partly overwritten by step 3)
	ext_ref.run_demo_complex_pass_archetyped(GRID_W, GRID_H, ITER, KR,
		CORIOLIS, DRAG, GAIN, K, land_id_ref)
	# step 3 — ALL (-1)
	ext_ref.run_demo_complex_pass_archetyped(GRID_W, GRID_H, ITER, KR,
		CORIOLIS, DRAG, GAIN, K, -1)
	var out_ref: PackedFloat32Array = ext_ref.snapshot_f32(
		int(ext_ref.component_id("cell_demo_thermal_gradient")))

	# ─── 2. Scheduler-driven path ──────────────────────────────────
	var ext_sch: Object = _make_ext(n, temp_input.duplicate(), elev_input.duplicate())
	var land_id_sch: int = _assign_archetypes(ext_sch, n, water_mask)

	var cid_temp: int = int(ext_sch.component_id("cell_temp"))
	var cid_elev: int = int(ext_sch.component_id("cell_elevation"))
	var cid_out: int = int(ext_sch.component_id("cell_demo_thermal_gradient"))

	var scheduler = DemoEcsSchedulerScript.new()

	# J1: temp_drift
	scheduler.add_job(DemoEcsJobScript.new(
		&"temp_drift",
		[cid_temp],
		[cid_temp],
		Callable(self, "_run_temp_drift"),
		-1,
		{"drift": DRIFT_AMOUNT}
	))
	# J2: thermal_gradient_LAND
	scheduler.add_job(DemoEcsJobScript.new(
		&"thermal_gradient_LAND",
		[cid_temp, cid_elev],
		[cid_out],
		Callable(self, "_run_demo_complex_archetyped"),
		land_id_sch,
		{}
	))
	# J3: thermal_gradient_ALL
	scheduler.add_job(DemoEcsJobScript.new(
		&"thermal_gradient_ALL",
		[cid_temp, cid_elev],
		[cid_out],
		Callable(self, "_run_demo_complex_archetyped"),
		-1,
		{}
	))

	# Print topo order before tick (visible diagnostic).
	var order: PackedInt32Array = scheduler.topo_sort()
	print("[demo_ecs_run] topo order:")
	for k in range(order.size()):
		var idx: int = order[k]
		var jb: DemoEcsJob = scheduler._jobs[idx]
		print("  %d. %s" % [k, jb.describe()])

	# Tick once.
	var ctx: Dictionary = {
		"ext": ext_sch,
		"w": GRID_W,
		"h": GRID_H,
		"iter": ITER,
		"kr": KR,
		"coriolis": CORIOLIS,
		"drag": DRAG,
		"gain": GAIN,
		"k": K,
	}
	scheduler.tick(ctx)
	var out_sch: PackedFloat32Array = ext_sch.snapshot_f32(cid_out)

	# ─── 3. Bit-equal compare ──────────────────────────────────────
	var max_diff: float = _max_abs_diff(out_ref, out_sch)
	var bit_equal: bool = _check_bit_equal(out_ref, out_sch)
	print("─── Bit-equal: hand-coded vs scheduler ───")
	print("  bit-equal     : " + ("PASS" if bit_equal else "FAIL"))
	print("  max_abs_diff  : " + String.num(max_diff, 9))

	# ─── 4. Cycle-detection guardrail test ─────────────────────────
	var cycle_sch = DemoEcsSchedulerScript.new()
	# Two jobs each declaring write+read on the same comp → mutual edge → cycle.
	cycle_sch.add_job(DemoEcsJobScript.new(&"X",
		[cid_temp], [cid_out], Callable(self, "_no_op"), -1, {}))
	cycle_sch.add_job(DemoEcsJobScript.new(&"Y",
		[cid_out], [cid_temp], Callable(self, "_no_op"), -1, {}))
	var cycle_order: PackedInt32Array = cycle_sch.topo_sort()
	var cycle_detected: bool = cycle_order.is_empty()
	print("─── Cycle-detection guardrail ───")
	print("  cycle_detected: " + ("PASS" if cycle_detected else "FAIL"))

	# ─── 5. Summary ────────────────────────────────────────────────
	var all_pass: bool = bit_equal and cycle_detected
	print("[demo_ecs_run] DONE - all=" + ("PASS" if all_pass else "FAIL"))


# ════════════════════════════════════════════════════════════════════
# Job runners (Callable targets). Signature: (ctx, job) -> void.
# ════════════════════════════════════════════════════════════════════
func _run_temp_drift(ctx: Dictionary, job: DemoEcsJob) -> void:
	var ext: Object = ctx["ext"]
	var drift: float = float(job.params.get("drift", 0.0))
	ext.run_temp_drift_pass(drift)


func _run_demo_complex_archetyped(ctx: Dictionary, job: DemoEcsJob) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass_archetyped(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]),
		job.archetype_filter)


func _no_op(_ctx: Dictionary, _job: DemoEcsJob) -> void:
	pass


# ════════════════════════════════════════════════════════════════════
# Helpers — same deterministic inputs as bench_archetype_filter.gd so
# results are cross-comparable.
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


func _assign_archetypes(ext: Object, n: int, is_water: PackedByteArray) -> int:
	var land_id: int = int(ext.create_archetype(&"LAND", []))
	var ocean_id: int = int(ext.create_archetype(&"OCEAN", []))
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
		return false
	var n: int = a.size()
	var fail_count: int = 0
	for i in range(n):
		if a[i] != b[i]:
			if fail_count < 5:
				print("    [%d] ref=%s sch=%s diff=%s" % [
					i, String.num(a[i], 9), String.num(b[i], 9),
					String.num(absf(a[i] - b[i]), 9)
				])
			fail_count += 1
	if fail_count > 0:
		print("    %d / %d cells diverge" % [fail_count, n])
		return false
	return true
