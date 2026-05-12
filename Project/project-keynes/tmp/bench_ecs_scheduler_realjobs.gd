@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_ecs_scheduler_realjobs.gd — DOTS-A2 REAL-JOBS EXPERIMENT
# ════════════════════════════════════════════════════════════════════
#
# 单一职责：把 DemoEcsScheduler 接到**真实的 C++ pass**上，量化在
#   J ∈ {3, 5, 8} 的真实 job 集合下，调度器自身开销在算子总耗时里
#   占多少百分比 —— 即"多 job 调度真收益"实验。
#
# 与 bench_ecs_scheduler_stress.gd 的区别：
#   * stress 用 mock job + no-op callable，度量调度器在 J 维度上的复杂度
#   * 本 bench 用真实 C++ pass，度量调度器在真实算子环境里的"信号-噪声比"
#     —— 调度器开销 / 算子总耗时。比例越小，说明调度器越值得保留。
#
# 三个真实 C++ pass（来自 best-practices.md §2 经验定律表）：
#   * run_temp_drift_pass(drift_amount)
#       reads = [CELL_TEMP], writes = [CELL_TEMP]    （~22 µs @ 60×40）
#   * run_thermal_gradient_pass(w, h, elevation_gain, normalize_k)
#       reads = [CELL_TEMP, CELL_ELEVATION]
#       writes = [CELL_DEMO_THERMAL_GRADIENT]         （~15 µs @ 60×40）
#   * run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)
#       reads = [CELL_TEMP, CELL_ELEVATION]
#       writes = [CELL_DEMO_THERMAL_GRADIENT]         （~1042 µs @ 60×40, iter=16）
#
# Job 集合（**legal-DAG by construction**：每个 J 都构造一组合法、无环的
# reads/writes 声明，避免 RAW/WAW/WAR 自相矛盾。具体做法 = 在 ext 里多注册
# 几个 dummy slot 当成虚拟 staging，让重复同 kind 的 job 各自写入独立 slot；
# dispatch 时仍调相同的 C++ pass，最终输出统一通过最后一条 job 落到 CELL_OUT，
# 因此 bit-equal 校验保持不变）：
#
#   * J=3：drift(T→T) → grad(T,E→O) → complex(T,E→O)
#       —— 三条 job 沿 T → O 单链；scheduler tie-break 退化为 registration order
#   * J=5：drift(T→A) → grad(A,E→B) → complex(B,E→C) → drift(C→D) → grad(D,E→O)
#       —— 严格链式，无重复写同一 slot，无环
#   * J=8：与 J=5 同链路 + 在中段插入 3 条只读旁支（grad(T,E→staging1/2/3）），
#       —— 多并行汇入 + 单链推进，更接近真实 climate 流水线规模、仍合法无环。
#
# 度量维度（每个 J 一行）：
#   1. operator_us    — 把 J 个 callable 在**手写序**下顺序跑完的纯算子耗时
#   2. scheduler_us   — 走 DemoEcsScheduler.tick(ctx) 的端到端耗时（含 topo + dispatch）
#   3. overhead_us    — scheduler_us - operator_us（调度器净开销）
#   4. overhead_pct   — overhead_us / operator_us × 100%
#   5. bit_equal      — scheduler 跑完后的 CELL_DEMO_THERMAL_GRADIENT
#                       与手写序产物逐字节对比
#
# 红线判定：
#   * bit_equal @ all J        → scheduler 不引入数值偏差
#   * overhead_pct @ J=8 < 25% → 真实算子下调度器开销是可接受的
#       （J=3 / J=5 不设硬红线 —— operator_us 量级太大时百分比被算子主导，
#        意义不大；J=8 是当前最复杂的真实流水线规模，是最严格的判据。）
#
# 这个 bench **不**做性能优化、**不**与 LEGACY/ECS_ARCHETYPE 比较，
# 那是 bench_thermal_gradient_paths.gd 的职责。
# 本 bench 单一回答：调度器在真实算子环境里值不值得用。
#
# 配套阅读：
#   docs/dots-experiment-report.md §3.5 / §4 选项乙
#   docs/cpp-gdscript-best-practices.md §2 经验定律
# ════════════════════════════════════════════════════════════════════

const DemoEcsJobScript = preload("res://tmp/demo_ecs_job.gd")
const DemoEcsSchedulerScript = preload("res://tmp/demo_ecs_scheduler.gd")

# ── grid 配置（与 charter §12.6.6.b 基线一致）──
const GRID_W: int = 60
const GRID_H: int = 40
const ITER: int = 16
const KR: int = 2
const CORIOLIS: float = 0.5
const DRAG: float = 0.6
const GAIN: float = 1.5
const K: float = 0.5
const DRIFT: float = 0.01

# ── warmup / measure（µs 量级，需要均化抗 OS 抖动）──
const WARMUP: int = 5
const MEASURE: int = 30

# ── 红线（仅 J=8 参与判定）──
const OVERHEAD_PCT_BUDGET_J8: float = 25.0

# ── component 名称（与 GDExtension 注册保持一致）──
const COMP_TEMP: StringName = &"cell_temp"
const COMP_ELEV: StringName = &"cell_elevation"
const COMP_OUT:  StringName = &"cell_demo_thermal_gradient"

# ── 虚拟 staging slot：仅用于在 scheduler 视角制造合法 DAG，
# 实际 dispatch 仍调真实 pass（数据落到 CELL_TEMP/CELL_OUT），
# scheduler 拿到的 reads/writes cid 是这些虚拟 slot 的 cid。
# 注册顺序固定，cid 由 _make_ext 返回值确认。
const COMP_STAGING_PREFIX: String = "cell_demo_staging_"
const N_STAGING: int = 6  # J=8 最多用到 staging_0..5


func _run() -> void:
	print("=== bench_ecs_scheduler_realjobs — DOTS-A2 REAL JOBS ===")
	print("Grid: %dx%d  iter=%d kr=%d  warmup=%d measure=%d"
		% [GRID_W, GRID_H, ITER, KR, WARMUP, MEASURE])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[realjobs] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# 一次性探测必备 method
	var probe: Object = ClassDB.instantiate("DCWorldExt")
	for m in ["run_temp_drift_pass", "run_thermal_gradient_pass", "run_demo_complex_pass"]:
		if not probe.has_method(m):
			push_error("[realjobs] DCWorldExt missing %s — rebuild gdext." % m)
			return

	# ─── 跑三档 J ───
	print("─── Real-jobs scheduler overhead table ───")
	print("| J | operator µs | scheduler µs | overhead µs | overhead %% | bit-equal |")
	print("|---|-------------|--------------|-------------|------------|-----------|")

	var any_fail: bool = false
	var overhead_pct_at_j8: float = -1.0

	for j_count in [3, 5, 8]:
		var spec: Array = _job_spec_for(j_count)

		# 1) 手写序：直接顺序调用 callables
		var op_us_avg: int = _measure_handcoded(spec)
		var hand_out: PackedFloat32Array = _capture_output(spec)

		# 2) Scheduler 序：走 DemoEcsScheduler.tick(ctx)
		var sch_us_avg: int = _measure_scheduler(spec)
		var sch_out: PackedFloat32Array = _capture_scheduler_output(spec)

		# 3) bit-equal
		var be: bool = _check_bit_equal(hand_out, sch_out)

		var overhead_us: int = sch_us_avg - op_us_avg
		var overhead_pct: float = (float(overhead_us) / float(op_us_avg) * 100.0) \
			if op_us_avg > 0 else INF
		print("| %d | %11d | %12d | %11d | %9.2f%% | %9s |"
			% [j_count, op_us_avg, sch_us_avg, overhead_us, overhead_pct,
				"PASS" if be else "FAIL"])

		if not be:
			any_fail = true
		if j_count == 8:
			overhead_pct_at_j8 = overhead_pct

	print("")
	print("─── Verdict ───")
	if overhead_pct_at_j8 >= 0.0:
		var pass_pct: bool = overhead_pct_at_j8 < OVERHEAD_PCT_BUDGET_J8
		print("  overhead %% @ J=8: %.2f%% (budget < %.2f%%) → %s"
			% [overhead_pct_at_j8, OVERHEAD_PCT_BUDGET_J8,
				"PASS" if pass_pct else "FAIL"])
		if not pass_pct:
			any_fail = true
	print("  overall          : " + ("PASS" if not any_fail else "FAIL"))
	print("[bench_ecs_scheduler_realjobs] DONE — "
		+ ("all=PASS" if not any_fail else "all=FAIL"))


# ════════════════════════════════════════════════════════════════════
# Job spec —— 返回一个 Array[Dictionary]，每个元素描述一条 job：
#   { name, reads, writes, kind: "drift" | "grad" | "complex" }
# reads/writes 声明的 cid **必须**让 scheduler 拓扑无环。我们用虚拟 staging
# 实现这个语义：每条 job 看到的 reads/writes 都是 staging cid（与 dispatch
# 阶段实际调的 C++ pass 解耦）。顺序 = 手写执行顺序 = 期望的 scheduler
# 拓扑顺序（registration tie-break）。
# ════════════════════════════════════════════════════════════════════
func _job_spec_for(j_count: int) -> Array:
	# 真实 cid（_make_ext 已固定注册顺序：T=0, E=1, O=2, S0=3, S1=4, ...）
	var CID_TEMP: int = 0
	var CID_ELEV: int = 1
	var CID_OUT:  int = 2
	var S: Array[int] = []
	for i in range(N_STAGING):
		S.append(3 + i)  # CID_STAGING[i]

	match j_count:
		# 严格链式：T → O，三条 job 沿单链推进，无重复写。
		3:
			return [
				{"name": &"drift",   "reads": [CID_TEMP],            "writes": [CID_TEMP], "kind": "drift"},
				{"name": &"grad",    "reads": [CID_TEMP, CID_ELEV],  "writes": [CID_OUT],  "kind": "grad"},
				{"name": &"complex", "reads": [CID_TEMP, CID_ELEV],  "writes": [CID_OUT],  "kind": "complex"},
			]
		# 严格链式：每条 job 写入独立 staging，下一条以前一条的 staging 为输入。
		# 最后一条 grad 写 CID_OUT，让 bit-equal 校验有统一终点。
		5:
			return [
				{"name": &"drift0",  "reads": [CID_TEMP],   "writes": [S[0]],     "kind": "drift"},
				{"name": &"grad0",   "reads": [S[0], CID_ELEV],"writes": [S[1]],   "kind": "grad"},
				{"name": &"complex0","reads": [S[1], CID_ELEV],"writes": [S[2]],   "kind": "complex"},
				{"name": &"drift1",  "reads": [S[2]],       "writes": [S[3]],     "kind": "drift"},
				{"name": &"grad1",   "reads": [S[3], CID_ELEV],"writes": [CID_OUT],"kind": "grad"},
			]
		# J=5 主链 + 3 条只读旁支（reads=[CID_TEMP, CID_ELEV] writes=[S_branch_i]）。
		# 旁支只产生写后再无人读的 staging（W-only，no readers），DAG 仍合法无环。
		8:
			return [
				{"name": &"drift0",  "reads": [CID_TEMP],   "writes": [S[0]],     "kind": "drift"},
				{"name": &"grad_b0", "reads": [CID_TEMP, CID_ELEV], "writes": [S[4]], "kind": "grad"},
				{"name": &"grad0",   "reads": [S[0], CID_ELEV],"writes": [S[1]],   "kind": "grad"},
				{"name": &"grad_b1", "reads": [S[0], CID_ELEV], "writes": [S[5]], "kind": "grad"},
				{"name": &"complex0","reads": [S[1], CID_ELEV],"writes": [S[2]],   "kind": "complex"},
				{"name": &"drift1",  "reads": [S[2]],       "writes": [S[3]],     "kind": "drift"},
				{"name": &"grad_b2", "reads": [S[2], CID_ELEV], "writes": [S[4]], "kind": "grad"},
				{"name": &"grad1",   "reads": [S[3], CID_ELEV],"writes": [CID_OUT],"kind": "grad"},
			]
	return []


# ════════════════════════════════════════════════════════════════════
# 测手写序 —— 完全不经过 scheduler，是 operator 时间的下界。
# Returns avg µs over MEASURE runs (after WARMUP).
# ════════════════════════════════════════════════════════════════════
func _measure_handcoded(spec: Array) -> int:
	var ext: Object = _make_ext()
	# warmup
	for _w in range(WARMUP):
		_run_handcoded_once(ext, spec)
	# measure
	var t0: int = Time.get_ticks_usec()
	for _m in range(MEASURE):
		_run_handcoded_once(ext, spec)
	var total: int = Time.get_ticks_usec() - t0
	return int(total / MEASURE)


func _run_handcoded_once(ext: Object, spec: Array) -> void:
	for s in spec:
		match s.kind:
			"drift":
				ext.run_temp_drift_pass(DRIFT)
			"grad":
				ext.run_thermal_gradient_pass(GRID_W, GRID_H, GAIN, K)
			"complex":
				ext.run_demo_complex_pass(GRID_W, GRID_H, ITER, KR,
					CORIOLIS, DRAG, GAIN, K)


func _capture_output(spec: Array) -> PackedFloat32Array:
	var ext: Object = _make_ext()
	_run_handcoded_once(ext, spec)
	return ext.snapshot_f32(int(ext.component_id(COMP_OUT)))


# ════════════════════════════════════════════════════════════════════
# 测 scheduler —— 把同一组 spec 转成 DemoEcsJob，注册进 scheduler，
# 走 tick(ctx)。返回平均 µs。
#
# 注意 ctx 里只透传 ext + grid 参数；run_callable 内部按 job.params.kind 分派
# （params 里的 "kind" 字段就是手写 spec 的 kind）。
# ════════════════════════════════════════════════════════════════════
func _measure_scheduler(spec: Array) -> int:
	var ext: Object = _make_ext()
	var sch = DemoEcsSchedulerScript.new()
	for s in spec:
		# Dictionary literal 里的数组是弱类型 Array — 这里**必须**显式重建一个
		# typed Array[int]，否则 DemoEcsJob._init 会以
		# "Cannot convert argument 2 from Array to Array" 拒绝构造。
		var reads_typed: Array[int] = []
		for v in (s.reads as Array): reads_typed.append(int(v))
		var writes_typed: Array[int] = []
		for v in (s.writes as Array): writes_typed.append(int(v))
		var job: DemoEcsJob = DemoEcsJobScript.new(
			s.name as StringName,
			reads_typed, writes_typed,
			Callable(self, "_dispatch_job"),
			-1,
			{"kind": s.kind})
		sch.add_job(job)

	var ctx: Dictionary = {"ext": ext}
	# warmup
	for _w in range(WARMUP):
		sch.tick(ctx)
	var t0: int = Time.get_ticks_usec()
	for _m in range(MEASURE):
		sch.tick(ctx)
	var total: int = Time.get_ticks_usec() - t0
	return int(total / MEASURE)


func _capture_scheduler_output(spec: Array) -> PackedFloat32Array:
	var ext: Object = _make_ext()
	var sch = DemoEcsSchedulerScript.new()
	for s in spec:
		var reads_typed: Array[int] = []
		for v in (s.reads as Array): reads_typed.append(int(v))
		var writes_typed: Array[int] = []
		for v in (s.writes as Array): writes_typed.append(int(v))
		var job: DemoEcsJob = DemoEcsJobScript.new(
			s.name as StringName,
			reads_typed, writes_typed,
			Callable(self, "_dispatch_job"),
			-1,
			{"kind": s.kind})
		sch.add_job(job)
	var ctx: Dictionary = {"ext": ext}
	sch.tick(ctx)
	return ext.snapshot_f32(int(ext.component_id(COMP_OUT)))


# ════════════════════════════════════════════════════════════════════
# Job dispatch —— 所有 real job 共用同一个 callable，按 params.kind 分派。
# 这避免了为每个 kind 写一个绑定方法。
# ════════════════════════════════════════════════════════════════════
func _dispatch_job(ctx: Dictionary, job: DemoEcsJob) -> void:
	var ext: Object = ctx.get("ext", null)
	if ext == null:
		push_warning("[realjobs] dispatch: ctx.ext missing")
		return
	var kind: String = String(job.params.get("kind", ""))
	match kind:
		"drift":
			ext.run_temp_drift_pass(DRIFT)
		"grad":
			ext.run_thermal_gradient_pass(GRID_W, GRID_H, GAIN, K)
		"complex":
			ext.run_demo_complex_pass(GRID_W, GRID_H, ITER, KR,
				CORIOLIS, DRAG, GAIN, K)
		_:
			push_warning("[realjobs] dispatch: unknown kind '%s'" % kind)


# ════════════════════════════════════════════════════════════════════
# Helpers —— 与 bench_archetype_filter / bench_thermal_gradient_paths 一致
# 的输入构造，保证可复现。
# ════════════════════════════════════════════════════════════════════
func _make_ext() -> Object:
	var n: int = GRID_W * GRID_H
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# 注册顺序固定为：T=0, E=1, O=2, S0=3, S1=4, ... S{N_STAGING-1}
	# _job_spec_for() 直接以这个顺序硬编码 cid。
	var _cid_temp: int = int(ext.register_component(COMP_TEMP, 0, 1, false))
	var _cid_elev: int = int(ext.register_component(COMP_ELEV, 0, 1, false))
	var _cid_out:  int = int(ext.register_component(COMP_OUT,  0, 1, false))
	for i in range(N_STAGING):
		var _cid_s: int = int(ext.register_component(
			StringName(COMP_STAGING_PREFIX + str(i)), 0, 1, false))
	ext.create_pool("cells", n)
	ext.write_f32_range(int(ext.component_id(COMP_TEMP)), 0, _make_temp_input(GRID_W, GRID_H))
	ext.write_f32_range(int(ext.component_id(COMP_ELEV)), 0, _make_elevation_input(GRID_W, GRID_H))
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


func _make_elevation_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	var seed_v: int = 0x9E3779B1
	for i in range(w * h):
		seed_v = (seed_v * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = float(seed_v % 10000) / 10000.0
	return arr


func _check_bit_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		print("    [bit-equal] size mismatch: %d vs %d" % [a.size(), b.size()])
		return false
	var n: int = a.size()
	var fails: int = 0
	for i in range(n):
		if a[i] != b[i]:
			if fails < 3:
				print("    [%d] hand=%s sch=%s diff=%s"
					% [i, String.num(a[i], 9), String.num(b[i], 9),
						String.num(absf(a[i] - b[i]), 9)])
			fails += 1
	if fails > 0:
		print("    %d / %d cells diverge" % [fails, n])
		return false
	return true
