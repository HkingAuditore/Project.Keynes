@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════════
# Bench: Pass-A optimisation methods comparison
# ════════════════════════════════════════════════════════════════════════
# Same 4 cases as bench_dots_vs_dict.gd, but compares 4 methods:
#   M0  Dict           — baseline (pure GDScript Dictionary)
#   M1  DOTS-Indexed   — write_f32_indexed + GDScript-side compute (current)
#   M2  CppPass-Scalar — bench_pass_a_*_scalar (one trans-boundary call,
#                        C++ scalar tight loop)
#   M3  CppPass-SIMD   — bench_pass_a_*_simd  (AVX2 explicit intrinsics)
#   M4  CppPass-Thread — bench_pass_a_*_thread (SIMD + WorkerThreadPool)
#
# Workload (matches real Pass-A more closely than the previous bench):
#   nb_sum  = Σ prev[neighbours[6*i + k]] for k in 0..5
#   new[i]  = base + lat[i]*k1 + nb_sum*k2 + season
#
# All methods produce the SAME math; we only swap the data-path. To verify,
# we checksum each result and print them side by side — small ULP-level
# diff is acceptable (different summation order in SIMD/Thread paths).
# ════════════════════════════════════════════════════════════════════════

const N_CELLS:        int   = 2400
const N_ITERS:        int   = 100
const N_TRIALS:       int   = 3
const DIRTY_RATIO:    float = 0.30
const NEIGHBOR_COUNT: int   = 6
const N_TASKS:        int   = 4    # WorkerThreadPool group size for M4

const K1:     float = 0.45
const K2:     float = 0.10
const BASE:   float = 12.0
const SEASON: float = 3.5

func _run() -> void:
	print("=== Bench: Pass-A optimisation methods (cells=%d iters=%d trials=%d dirty=%.0f%% n_tasks=%d) ===" \
		% [N_CELLS, N_ITERS, N_TRIALS, DIRTY_RATIO * 100.0, N_TASKS])
	print("")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt NOT registered — extension didn't load.")
		return

	# ── Pre-generate shared inputs (deterministic, same data for every method) ──
	var lat:       PackedFloat32Array = _make_lat()
	var prev:      PackedFloat32Array = _make_prev()
	var neighbors: PackedInt32Array   = _make_neighbor_table()
	var dirty:     PackedInt32Array   = _make_dirty_indices()
	var n_dirty:   int                = dirty.size()

	# Sanity probe: each method writes to a fresh world and we sum the result
	# for cross-check. Emit in a named row.
	var probe_results: Array[Dictionary] = []

	# ── Case 1: Full / linear (every cell rewritten every iter) ──────────
	print("─── Case 1: Full-write + Linear-read ───")
	var c1_m0: float = _bench_min(_bench_dict_full.bind(lat, prev, neighbors))
	var c1_m1: float = _bench_min(_bench_m1_full_indexed.bind(lat, prev, neighbors))
	var c1_m2: float = _bench_min(_bench_m2_full_scalar.bind(lat, prev, neighbors))
	var c1_m3: float = _bench_min(_bench_m3_full_simd.bind(lat, prev, neighbors))
	var c1_m4: float = _bench_min(_bench_m4_full_thread.bind(lat, prev, neighbors))
	# Probe (single iter checksum)
	probe_results.append(_probe_full(lat, prev, neighbors))

	# ── Case 2: Full / Neighbor-sample read (same compute as case 1) ─────
	# NOTE: in the new workload, "neighbour-sample read" is already part
	# of the kernel itself (Σ over 6 neighbours). We keep this case to
	# match the table layout of the old bench, but it's identical to
	# Case 1 in this workload model. Skipped to avoid noise.
	print("─── Case 2: (merged into Case 1 — neighbour read is part of compute) ───")
	print("")

	# ── Case 3: Incremental / linear (only 30% of cells rewritten) ───────
	print("─── Case 3: Incremental-write (dirty=%d) ───" % n_dirty)
	var c3_m0: float = _bench_min(_bench_dict_inc.bind(dirty, lat, prev, neighbors))
	var c3_m1: float = _bench_min(_bench_m1_inc_indexed.bind(dirty, lat, prev, neighbors))
	var c3_m2: float = _bench_min(_bench_m2_inc_scalar.bind(dirty, lat, prev, neighbors))
	var c3_m3: float = _bench_min(_bench_m3_inc_simd.bind(dirty, lat, prev, neighbors))
	var c3_m4: float = _bench_min(_bench_m4_inc_thread.bind(dirty, lat, prev, neighbors))
	probe_results.append(_probe_inc(dirty, lat, prev, neighbors))

	# ── Case 4: same as Case 3 (neighbour-read again merged into kernel) ─
	print("─── Case 4: (merged into Case 3) ───")
	print("")

	# ── Summary table ────────────────────────────────────────────────────
	print("=== Summary (total ms over %d iters; lower is better) ===" % N_ITERS)
	print("Case  | M0 Dict   | M1 Indexed | M2 Cpp-Scalar | M3 Cpp-SIMD | M4 Cpp-Thread")
	print("------+-----------+------------+---------------+-------------+--------------")
	_summary_row("Case 1", c1_m0, c1_m1, c1_m2, c1_m3, c1_m4)
	_summary_row("Case 3", c3_m0, c3_m1, c3_m2, c3_m3, c3_m4)
	print("")
	print("=== Speedup vs M0 Dict ===")
	print("Case  | M1     | M2     | M3     | M4")
	print("------+--------+--------+--------+--------")
	_speedup_row("Case 1", c1_m0, c1_m1, c1_m2, c1_m3, c1_m4)
	_speedup_row("Case 3", c3_m0, c3_m1, c3_m2, c3_m3, c3_m4)
	print("")
	print("=== Result checksum (single iter; method should agree to ~ULP) ===")
	for p: Dictionary in probe_results:
		print("  %s: M1=%.4f  M2=%.4f  M3=%.4f  M4=%.4f" % [
			p.label,
			float(p.m1),
			float(p.m2),
			float(p.m3),
			float(p.m4),
		])

# ════════════════════════════════════════════════════════════════════════
# Bench harness
# ════════════════════════════════════════════════════════════════════════
func _bench_min(fn: Callable) -> float:
	var best: float = INF
	for _t in range(N_TRIALS):
		var t0: int = Time.get_ticks_usec()
		fn.call()
		var dt: float = float(Time.get_ticks_usec() - t0) / 1000.0
		if dt < best:
			best = dt
	return best

func _summary_row(label: String, m0: float, m1: float, m2: float, m3: float, m4: float) -> void:
	print("%-6s | %9.2f | %10.2f | %13.2f | %11.2f | %12.2f" % [label, m0, m1, m2, m3, m4])

func _speedup_row(label: String, m0: float, m1: float, m2: float, m3: float, m4: float) -> void:
	print("%-6s | %5.2fx | %5.2fx | %5.2fx | %5.2fx" % [
		label,
		m0 / maxf(m1, 0.001),
		m0 / maxf(m2, 0.001),
		m0 / maxf(m3, 0.001),
		m0 / maxf(m4, 0.001),
	])

# ════════════════════════════════════════════════════════════════════════
# Test data generators
# ════════════════════════════════════════════════════════════════════════
func _make_lat() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(N_CELLS)
	for i in range(N_CELLS):
		a[i] = sin(float(i) * 0.013) * 30.0   # latitude-like ∈ [-30, 30]
	return a

func _make_prev() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(N_CELLS)
	for i in range(N_CELLS):
		a[i] = cos(float(i) * 0.017) * 5.0 + 10.0
	return a

func _make_dirty_indices() -> PackedInt32Array:
	var n_dirty: int = int(N_CELLS * DIRTY_RATIO)
	var a := PackedInt32Array()
	a.resize(n_dirty)
	var step: float = float(N_CELLS) / float(n_dirty)
	for i in range(n_dirty):
		a[i] = int(float(i) * step + 0.5) % N_CELLS
	return a

func _make_neighbor_table() -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(N_CELLS * NEIGHBOR_COUNT)
	for i in range(N_CELLS):
		a[i * NEIGHBOR_COUNT + 0] = (i + 1) % N_CELLS
		a[i * NEIGHBOR_COUNT + 1] = (i + N_CELLS - 1) % N_CELLS
		a[i * NEIGHBOR_COUNT + 2] = (i + 50) % N_CELLS
		a[i * NEIGHBOR_COUNT + 3] = (i + N_CELLS - 50) % N_CELLS
		a[i * NEIGHBOR_COUNT + 4] = (i + 51) % N_CELLS
		a[i * NEIGHBOR_COUNT + 5] = (i + N_CELLS - 49) % N_CELLS
	return a

# ════════════════════════════════════════════════════════════════════════
# World factory (one fresh world per bench fn call to clear state)
# ════════════════════════════════════════════════════════════════════════
func _make_world() -> Object:
	var w: Object = ClassDB.instantiate("DCWorldExt")
	var cid := int(w.register_component("bench_temp", 0, 1, false))
	w.create_pool("cells", N_CELLS)
	w.set_meta("bench_cid", cid)
	return w

# ════════════════════════════════════════════════════════════════════════
# M0: Dictionary baseline (pure GDScript)
# ════════════════════════════════════════════════════════════════════════
func _bench_dict_full(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var d: Dictionary = {}
	for i in range(N_CELLS):
		d[i] = 0.0
	for k in range(N_ITERS):
		for i in range(N_CELLS):
			var base_i: int = i * NEIGHBOR_COUNT
			var nb_sum: float = float(prev[nb[base_i + 0]]) + float(prev[nb[base_i + 1]]) \
				+ float(prev[nb[base_i + 2]]) + float(prev[nb[base_i + 3]]) \
				+ float(prev[nb[base_i + 4]]) + float(prev[nb[base_i + 5]])
			d[i] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON

func _bench_dict_inc(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var d: Dictionary = {}
	for i in range(N_CELLS):
		d[i] = 0.0
	var n_dirty: int = dirty.size()
	for k in range(N_ITERS):
		for j in range(n_dirty):
			var i: int = dirty[j]
			var base_i: int = i * NEIGHBOR_COUNT
			var nb_sum: float = float(prev[nb[base_i + 0]]) + float(prev[nb[base_i + 1]]) \
				+ float(prev[nb[base_i + 2]]) + float(prev[nb[base_i + 3]]) \
				+ float(prev[nb[base_i + 4]]) + float(prev[nb[base_i + 5]])
			d[i] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON

# ════════════════════════════════════════════════════════════════════════
# M1: DOTS Indexed API — GDScript computes, write_f32_indexed pushes back
# (mirrors the "current best" path from the previous bench)
# ════════════════════════════════════════════════════════════════════════
func _bench_m1_full_indexed(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var all_idx := PackedInt32Array()
	all_idx.resize(N_CELLS)
	for i in range(N_CELLS):
		all_idx[i] = i
	var vals := PackedFloat32Array()
	vals.resize(N_CELLS)
	for k in range(N_ITERS):
		for i in range(N_CELLS):
			var base_i: int = i * NEIGHBOR_COUNT
			var nb_sum: float = prev[nb[base_i + 0]] + prev[nb[base_i + 1]] \
				+ prev[nb[base_i + 2]] + prev[nb[base_i + 3]] \
				+ prev[nb[base_i + 4]] + prev[nb[base_i + 5]]
			vals[i] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON
		w.write_f32_indexed(cid, all_idx, vals)

func _bench_m1_inc_indexed(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var n_dirty: int = dirty.size()
	var vals := PackedFloat32Array()
	vals.resize(n_dirty)
	for k in range(N_ITERS):
		for j in range(n_dirty):
			var i: int = dirty[j]
			var base_i: int = i * NEIGHBOR_COUNT
			var nb_sum: float = prev[nb[base_i + 0]] + prev[nb[base_i + 1]] \
				+ prev[nb[base_i + 2]] + prev[nb[base_i + 3]] \
				+ prev[nb[base_i + 4]] + prev[nb[base_i + 5]]
			vals[j] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON
		w.write_f32_indexed(cid, dirty, vals)

# ════════════════════════════════════════════════════════════════════════
# M2: C++ scalar tight loop
# ════════════════════════════════════════════════════════════════════════
func _bench_m2_full_scalar(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_full_scalar(cid, lat, prev, nb, K1, K2, BASE, SEASON)

func _bench_m2_inc_scalar(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_indexed_scalar(cid, dirty, lat, prev, nb, K1, K2, BASE, SEASON)

# ════════════════════════════════════════════════════════════════════════
# M3: C++ AVX2 SIMD
# ════════════════════════════════════════════════════════════════════════
func _bench_m3_full_simd(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_full_simd(cid, lat, prev, nb, K1, K2, BASE, SEASON)

func _bench_m3_inc_simd(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_indexed_simd(cid, dirty, lat, prev, nb, K1, K2, BASE, SEASON)

# ════════════════════════════════════════════════════════════════════════
# M4: C++ SIMD + WorkerThreadPool (n_tasks parallel chunks)
# ════════════════════════════════════════════════════════════════════════
func _bench_m4_full_thread(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_full_thread(cid, lat, prev, nb, K1, K2, BASE, SEASON, N_TASKS)

func _bench_m4_inc_thread(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.bench_pass_a_indexed_thread(cid, dirty, lat, prev, nb, K1, K2, BASE, SEASON, N_TASKS)

# ════════════════════════════════════════════════════════════════════════
# Result-checksum probes (1 iter, for cross-method numerical agreement)
# ════════════════════════════════════════════════════════════════════════
func _probe_full(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> Dictionary:
	return {
		"label": "Case 1 sum",
		"m1": _probe_run_full_indexed(lat, prev, nb),
		"m2": _probe_run_full_method(lat, prev, nb, "bench_pass_a_full_scalar"),
		"m3": _probe_run_full_method(lat, prev, nb, "bench_pass_a_full_simd"),
		"m4": _probe_run_full_thread(lat, prev, nb),
	}

func _probe_run_full_indexed(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var all_idx := PackedInt32Array()
	all_idx.resize(N_CELLS)
	for i in range(N_CELLS):
		all_idx[i] = i
	var vals := PackedFloat32Array()
	vals.resize(N_CELLS)
	for i in range(N_CELLS):
		var base_i: int = i * NEIGHBOR_COUNT
		var nb_sum: float = prev[nb[base_i + 0]] + prev[nb[base_i + 1]] \
			+ prev[nb[base_i + 2]] + prev[nb[base_i + 3]] \
			+ prev[nb[base_i + 4]] + prev[nb[base_i + 5]]
		vals[i] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON
	w.write_f32_indexed(cid, all_idx, vals)
	return _checksum(w, cid)

func _probe_run_full_method(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array, method: String) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	w.call(method, cid, lat, prev, nb, K1, K2, BASE, SEASON)
	return _checksum(w, cid)

func _probe_run_full_thread(lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	w.bench_pass_a_full_thread(cid, lat, prev, nb, K1, K2, BASE, SEASON, N_TASKS)
	return _checksum(w, cid)

func _probe_inc(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> Dictionary:
	return {
		"label": "Case 3 sum",
		"m1": _probe_run_inc_indexed(dirty, lat, prev, nb),
		"m2": _probe_run_inc_method(dirty, lat, prev, nb, "bench_pass_a_indexed_scalar"),
		"m3": _probe_run_inc_method(dirty, lat, prev, nb, "bench_pass_a_indexed_simd"),
		"m4": _probe_run_inc_thread(dirty, lat, prev, nb),
	}

func _probe_run_inc_indexed(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var n_dirty: int = dirty.size()
	var vals := PackedFloat32Array()
	vals.resize(n_dirty)
	for j in range(n_dirty):
		var i: int = dirty[j]
		var base_i: int = i * NEIGHBOR_COUNT
		var nb_sum: float = prev[nb[base_i + 0]] + prev[nb[base_i + 1]] \
			+ prev[nb[base_i + 2]] + prev[nb[base_i + 3]] \
			+ prev[nb[base_i + 4]] + prev[nb[base_i + 5]]
		vals[j] = BASE + lat[i] * K1 + nb_sum * K2 + SEASON
	w.write_f32_indexed(cid, dirty, vals)
	return _checksum(w, cid)

func _probe_run_inc_method(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array, method: String) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	w.call(method, cid, dirty, lat, prev, nb, K1, K2, BASE, SEASON)
	return _checksum(w, cid)

func _probe_run_inc_thread(dirty: PackedInt32Array, lat: PackedFloat32Array, prev: PackedFloat32Array, nb: PackedInt32Array) -> float:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	w.bench_pass_a_indexed_thread(cid, dirty, lat, prev, nb, K1, K2, BASE, SEASON, N_TASKS)
	return _checksum(w, cid)

func _checksum(w: Object, cid: int) -> float:
	var v: PackedFloat32Array = w.view_f32(cid)
	var s: float = 0.0
	for i in range(v.size()):
		s += v[i]
	return s
