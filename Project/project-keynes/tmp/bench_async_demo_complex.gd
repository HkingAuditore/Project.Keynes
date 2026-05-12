@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_async_demo_complex.gd — D 方案（async worker thread）实验 bench
# ════════════════════════════════════════════════════════════════════
#
# 实验目标（详见 .codebuddy/plan/cpp-async-experiment/requirements.md）：
#   1. 验证主线程 dispatch + poll 总耗时 ≤ 50 µs / tick
#   2. 验证异步 vs 同步 bit-equivalent（容差 1e-6）
#   3. 测量 N=1/2/4/8 并发任务的 worker_total / 主线程总开销曲线
#   4. ROBUST：100 次 register/shutdown 循环不死锁 / 不 crash
#
# 输出：5 维度耗时表 + 并发开销表 + 等价性结论 + 鲁棒性结论
# ════════════════════════════════════════════════════════════════════

const CELL_F32: int = 0
const TOLERANCE: float = 1.0e-6

# Bit-equal 等价性测试（小网格 + 少 iter，跑得快）
const EQ_GRID_W: int = 32
const EQ_GRID_H: int = 32
const EQ_ITER: int = 4
const EQ_KR: int = 2
const EQ_CORIOLIS: float = 0.5
const EQ_DRAG: float = 0.6
const EQ_GAIN: float = 1.5
const EQ_K: float = 0.5

# 性能矩阵（与游戏内同样 60×40，iter 用 16）
const PERF_GRID_W: int = 60
const PERF_GRID_H: int = 40
const PERF_ITER: int = 16
const PERF_KR: int = 2
const PERF_WARMUP: int = 30
const PERF_MEASURE: int = 100

const N_TASKS_LIST: Array = [1, 2, 4, 8]


# ── 入口 ─────────────────────────────────────────────────────────────
func _run() -> void:
	print("=== bench_async_demo_complex — D-async experiment ===")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_async] DCWorldExt NOT registered — rebuild gdext first.")
		return

	var ext_probe: Object = ClassDB.instantiate("DCWorldExt")
	if not ext_probe.has_method("async_climate_register_task"):
		push_error("[bench_async] async API not bound — rebuild gdext.")
		return

	# ─── 1. 等价性测试 ──────────────────────────────────────
	_run_equivalence_test()

	# ─── 2. 5 维耗时全景 + 并发开销表 ───────────────────────
	_run_perf_matrix()

	# ─── 3. 鲁棒性测试 ──────────────────────────────────────
	_run_robust_test()

	print("[bench_async] DONE")


# ────────────────────────────────────────────────────────────────────
# 1. 等价性：对同一输入，async 路径与同步 run_demo_complex_pass 应 max_diff ≤ 1e-6
# ────────────────────────────────────────────────────────────────────
func _run_equivalence_test() -> void:
	print("")
	print("─── [1] Equivalence test (async vs sync) ───")
	var n: int = EQ_GRID_W * EQ_GRID_H
	var temp: PackedFloat32Array = _make_temp_input(EQ_GRID_W, EQ_GRID_H)
	var elev: PackedFloat32Array = _make_elev_input(EQ_GRID_W, EQ_GRID_H)

	# 同步路径
	var ext_sync: Object = _make_ext(n, temp, elev)
	ext_sync.run_demo_complex_pass(EQ_GRID_W, EQ_GRID_H, EQ_ITER, EQ_KR,
		EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
	var out_sync: PackedFloat32Array = ext_sync.snapshot_f32(
		int(ext_sync.component_id("cell_demo_thermal_gradient")))

	# 异步路径
	var ext_async: Object = _make_ext(n, temp, elev)
	ext_async.async_climate_register_task(0, 1)
	ext_async.async_climate_set_inputs(0, temp, elev)
	ext_async.async_climate_request(0, EQ_GRID_W, EQ_GRID_H, EQ_ITER, EQ_KR,
		EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
	# 等 worker 完成 — 最多等 1 秒
	var deadline_us: int = Time.get_ticks_usec() + 1_000_000
	var ready: bool = false
	while Time.get_ticks_usec() < deadline_us:
		if ext_async.async_climate_poll(0):
			ready = true
			break
		OS.delay_usec(100)
	ext_async.async_climate_shutdown_task(0)

	if not ready:
		push_error("[bench_async] equivalence: async never returned ready")
		return
	var out_async: PackedFloat32Array = ext_async.snapshot_f32(
		int(ext_async.component_id("cell_demo_thermal_gradient")))

	var max_diff: float = _max_abs_diff(out_sync, out_async)
	var pass_eq: bool = max_diff <= TOLERANCE
	print("  grid=%dx%d iter=%d  max_abs_diff=%s  result=%s" % [
		EQ_GRID_W, EQ_GRID_H, EQ_ITER,
		String.num(max_diff, 9),
		"PASS" if pass_eq else "FAIL"])


# ────────────────────────────────────────────────────────────────────
# 2. 性能矩阵：N=1/2/4/8 并发任务，每任务 60x40/iter=16
#    PERF_WARMUP+PERF_MEASURE 帧后报 5 维度耗时
# ────────────────────────────────────────────────────────────────────
func _run_perf_matrix() -> void:
	print("")
	print("─── [2] Perf matrix (grid=%dx%d iter=%d, %d warmup + %d measure ticks) ───" \
		% [PERF_GRID_W, PERF_GRID_H, PERF_ITER, PERF_WARMUP, PERF_MEASURE])
	print("| N | main_dispatch µs | main_poll µs | worker_compute µs | worker_total µs | reused/100 | main_total µs |")
	print("|---|------------------|--------------|-------------------|------------------|------------|---------------|")

	# 同步参考行（用作 "C++ 同步" 基线对比）
	var sync_us: int = _measure_sync_baseline()
	print("| sync(ref) | n/a | n/a | %17d | n/a              | n/a        | %13d |" % [sync_us, sync_us])

	for n_tasks in N_TASKS_LIST:
		_run_one_perf_case(n_tasks)


func _measure_sync_baseline() -> int:
	# 主线程跑 PERF_MEASURE 次 run_demo_complex_pass，取均值。
	var n: int = PERF_GRID_W * PERF_GRID_H
	var temp: PackedFloat32Array = _make_temp_input(PERF_GRID_W, PERF_GRID_H)
	var elev: PackedFloat32Array = _make_elev_input(PERF_GRID_W, PERF_GRID_H)
	var ext: Object = _make_ext(n, temp, elev)
	# warmup
	for i in range(10):
		ext.run_demo_complex_pass(PERF_GRID_W, PERF_GRID_H, PERF_ITER, PERF_KR,
			EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
	var t0: int = Time.get_ticks_usec()
	for i in range(PERF_MEASURE):
		ext.run_demo_complex_pass(PERF_GRID_W, PERF_GRID_H, PERF_ITER, PERF_KR,
			EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
	var elapsed: int = Time.get_ticks_usec() - t0
	return int(elapsed / PERF_MEASURE)


func _run_one_perf_case(n_tasks: int) -> void:
	var n: int = PERF_GRID_W * PERF_GRID_H
	var temp: PackedFloat32Array = _make_temp_input(PERF_GRID_W, PERF_GRID_H)
	var elev: PackedFloat32Array = _make_elev_input(PERF_GRID_W, PERF_GRID_H)

	# 每任务一个 ext 实例，更接近"独立子系统"语义
	var exts: Array = []
	for tid in range(n_tasks):
		var ext: Object = _make_ext(n, temp, elev)
		ext.async_climate_register_task(tid, 1)
		ext.async_climate_set_inputs(tid, temp, elev)
		exts.append(ext)

	# warmup（先发请求，等所有任务返回过至少一次）
	for k in range(PERF_WARMUP):
		for tid in range(n_tasks):
			(exts[tid] as Object).async_climate_request(tid,
				PERF_GRID_W, PERF_GRID_H, PERF_ITER, PERF_KR,
				EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
		# 等所有任务的本帧 result_ready
		for tid in range(n_tasks):
			var deadline: int = Time.get_ticks_usec() + 200_000
			while Time.get_ticks_usec() < deadline:
				if (exts[tid] as Object).async_climate_poll(tid):
					break
				OS.delay_usec(50)

	# measure：每帧记 dispatch / poll 时间
	var sum_dispatch_us: int = 0
	var sum_poll_us: int = 0
	var reused_count: int = 0
	for k in range(PERF_MEASURE):
		# dispatch
		var t_d0: int = Time.get_ticks_usec()
		for tid in range(n_tasks):
			(exts[tid] as Object).async_climate_request(tid,
				PERF_GRID_W, PERF_GRID_H, PERF_ITER, PERF_KR,
				EQ_CORIOLIS, EQ_DRAG, EQ_GAIN, EQ_K)
		sum_dispatch_us += Time.get_ticks_usec() - t_d0
		# 等所有任务返回（不计入 main_poll，因为这部分是模拟"其它逻辑"完成后才轮询）
		for tid in range(n_tasks):
			var deadline: int = Time.get_ticks_usec() + 200_000
			while Time.get_ticks_usec() < deadline:
				var stats: Dictionary = (exts[tid] as Object).async_climate_stats(tid)
				if bool(stats.get("result_ready", false)):
					break
				OS.delay_usec(50)
		# poll
		var t_p0: int = Time.get_ticks_usec()
		for tid in range(n_tasks):
			var got: bool = (exts[tid] as Object).async_climate_poll(tid)
			if not got:
				reused_count += 1
		sum_poll_us += Time.get_ticks_usec() - t_p0

	# 取 stats 均值（worker_compute / worker_total 由 worker 自报）
	var avg_compute_us: int = 0
	var avg_total_us: int = 0
	var total_reused: int = 0
	for tid in range(n_tasks):
		var st: Dictionary = (exts[tid] as Object).async_climate_stats(tid)
		avg_compute_us += int(st.get("worker_compute_us", 0))
		avg_total_us += int(st.get("worker_total_us", 0))
		total_reused += int(st.get("total_reused", 0))
	avg_compute_us = int(avg_compute_us / n_tasks)
	avg_total_us = int(avg_total_us / n_tasks)

	# 关闭
	for tid in range(n_tasks):
		(exts[tid] as Object).async_climate_shutdown_task(tid)

	var avg_dispatch: float = float(sum_dispatch_us) / float(PERF_MEASURE)
	var avg_poll: float = float(sum_poll_us) / float(PERF_MEASURE)
	var avg_main_total: float = avg_dispatch + avg_poll
	print("| %d | %16.1f | %12.1f | %17d | %16d | %10d | %13.1f |" % [
		n_tasks, avg_dispatch, avg_poll,
		avg_compute_us, avg_total_us,
		reused_count, avg_main_total])


# ────────────────────────────────────────────────────────────────────
# 3. ROBUST：100 次 register/shutdown 循环
# ────────────────────────────────────────────────────────────────────
func _run_robust_test() -> void:
	print("")
	print("─── [3] Robust test (100 register/shutdown cycles) ───")
	var n: int = 32 * 32
	var temp: PackedFloat32Array = _make_temp_input(32, 32)
	var elev: PackedFloat32Array = _make_elev_input(32, 32)
	var t0: int = Time.get_ticks_usec()
	for cycle in range(100):
		var ext: Object = _make_ext(n, temp, elev)
		ext.async_climate_register_task(0, 1)
		ext.async_climate_set_inputs(0, temp, elev)
		ext.async_climate_request(0, 32, 32, 4, 2, 0.5, 0.6, 1.5, 0.5)
		# 不等待结果 — 故意立即 shutdown 测试中途取消的鲁棒性
		ext.async_climate_shutdown_task(0)
		# ext 离开作用域 → ~DCWorldExt 也会调 shutdown_all 兜底
	var elapsed_us: int = Time.get_ticks_usec() - t0
	print("  100 cycles done in %d µs (avg %.1f µs/cycle)" % [
		elapsed_us, float(elapsed_us) / 100.0])
	print("  result: PASS (no crash, no hang)")


# ── helpers ──────────────────────────────────────────────────────────
func _make_ext(n: int, temp: PackedFloat32Array, elev: PackedFloat32Array) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var cid_temp: int = int(ext.register_component("cell_temp", CELL_F32, 1, false))
	var cid_elev: int = int(ext.register_component("cell_elevation", CELL_F32, 1, false))
	var cid_out: int = int(ext.register_component("cell_demo_thermal_gradient", CELL_F32, 1, false))
	ext.create_pool("cells", n)
	ext.write_f32_range(cid_temp, 0, temp)
	ext.write_f32_range(cid_elev, 0, elev)
	return ext


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


func _make_elev_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	var seed_v: int = 0x9E3779B1
	for i in range(w * h):
		seed_v = (seed_v * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = float(seed_v % 10000) / 10000.0
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
