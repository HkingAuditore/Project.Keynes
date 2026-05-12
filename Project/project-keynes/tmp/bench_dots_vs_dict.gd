@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# Bench: DCWorldExt vs Dictionary — Climate Pass-A workload
# ════════════════════════════════════════════════════════════════════
# 决策门槛（在 Phase 3 接入前用本 bench 验证 ROI）：
#   speedup ≥ 5×  → 强烈推荐 Pass-A 接入 DCWorldExt
#   2× ~ 5×       → 值得做，权衡接入成本
#   < 2×          → 重新评估，可能要改用批量 API
#   < 1× (更慢)   → 排查 view 的 marshal 开销
#
# 4 case 工况（贴近真实 Pass-A）：
#   Case 1: 全量写  + 线性读        → Pass-A 主热路径
#   Case 2: 全量写  + 邻居采样读×6  → Pass-A → Pass-B 串联
#   Case 3: 增量写(30%) + 线性读    → 稀疏 Pass-A
#   Case 4: 增量写(30%) + 邻居采样   → 真·稀疏 Pass-B 工况
#
# 数据规模与日志一致：cells=2400, iters=100，每 case 取 3 轮最小值
# ════════════════════════════════════════════════════════════════════

const N_CELLS: int = 2400
const N_ITERS: int = 100
const N_TRIALS: int = 3
const DIRTY_RATIO: float = 0.30   # 30% cells dirty (incremental write)
const NEIGHBOR_COUNT: int = 6      # hex 6-邻居

func _run() -> void:
	print("=== Bench: DCWorldExt vs Dictionary (Climate Pass-A workload) ===")
	print("cells=%d iters=%d trials=%d dirty=%.0f%%" % [N_CELLS, N_ITERS, N_TRIALS, DIRTY_RATIO * 100.0])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt NOT registered.")
		return

	# 预生成测试数据（两边共用）
	var src_full := _make_full_src()
	var dirty_indices := _make_dirty_indices()
	var src_dirty := _make_dirty_src(dirty_indices.size())
	var neighbors := _make_neighbor_table()

	# ═══ Case 1: 全量写 + 线性读 ═══
	print("─── Case 1: Full-write + Linear-read ───")
	var c1_dict := _bench_min(N_TRIALS, _bench_dict_full_linear.bind(src_full))
	var c1_dots := _bench_min(N_TRIALS, _bench_dots_full_linear.bind(src_full))
	_report("Case 1", c1_dict, c1_dots)

	# ═══ Case 2: 全量写 + 邻居采样 ═══
	print("─── Case 2: Full-write + Neighbor-sample ───")
	var c2_dict := _bench_min(N_TRIALS, _bench_dict_full_neighbor.bind(src_full, neighbors))
	var c2_dots := _bench_min(N_TRIALS, _bench_dots_full_neighbor.bind(src_full, neighbors))
	_report("Case 2", c2_dict, c2_dots)

	# ═══ Case 3: 增量写 + 线性读 ═══
	print("─── Case 3: Incremental-write + Linear-read ───")
	var c3_dict := _bench_min(N_TRIALS, _bench_dict_inc_linear.bind(dirty_indices, src_dirty))
	var c3_dots := _bench_min(N_TRIALS, _bench_dots_inc_linear.bind(dirty_indices, src_dirty))
	_report("Case 3", c3_dict, c3_dots)

	# ═══ Case 4: 增量写 + 邻居采样 ═══
	print("─── Case 4: Incremental-write + Neighbor-sample ───")
	var c4_dict := _bench_min(N_TRIALS, _bench_dict_inc_neighbor.bind(dirty_indices, src_dirty, neighbors))
	var c4_dots := _bench_min(N_TRIALS, _bench_dots_inc_neighbor.bind(dirty_indices, src_dirty, neighbors))
	_report("Case 4", c4_dict, c4_dots)

	# ═══ Case 3+: 增量写(indexed API) + 线性读 ═══
	print("─── Case 3+: Incremental-write (INDEXED) + Linear-read ───")
	var c3p_dots := _bench_min(N_TRIALS, _bench_dots_inc_linear_indexed.bind(dirty_indices, src_dirty))
	_report("Case 3+", c3_dict, c3p_dots)

	# ═══ Case 4+: 增量写(indexed API) + 邻居采样 ═══
	print("─── Case 4+: Incremental-write (INDEXED) + Neighbor-sample ───")
	var c4p_dots := _bench_min(N_TRIALS, _bench_dots_inc_neighbor_indexed.bind(dirty_indices, src_dirty, neighbors))
	_report("Case 4+", c4_dict, c4p_dots)

	# ═══ 总结 ═══
	print("")
	print("=== Summary (total ms over %d iters; lower is better) ===" % N_ITERS)
	print("Case  | Dict (ms) | DOTS (ms) | Speedup")
	print("------+-----------+-----------+--------")
	_summary_row("Case 1 ", c1_dict, c1_dots)
	_summary_row("Case 2 ", c2_dict, c2_dots)
	_summary_row("Case 3 ", c3_dict, c3_dots)
	_summary_row("Case 4 ", c4_dict, c4_dots)
	_summary_row("Case 3+", c3_dict, c3p_dots)
	_summary_row("Case 4+", c4_dict, c4p_dots)
	print("")
	print("=== DECISION GATE ===")
	# 只用改进后的 Case 3+/4+ 计算平均 speedup（indexed API 才是最终接入形态）
	var avg_speedup: float = (
		(c1_dict / maxf(c1_dots, 0.001)) +
		(c2_dict / maxf(c2_dots, 0.001)) +
		(c3_dict / maxf(c3p_dots, 0.001)) +
		(c4_dict / maxf(c4p_dots, 0.001))
	) / 4.0
	print("Average speedup (using indexed API for 3/4): %.2fx" % avg_speedup)
	# 同时输出原始版本作参考
	var avg_speedup_orig: float = (
		(c1_dict / maxf(c1_dots, 0.001)) +
		(c2_dict / maxf(c2_dots, 0.001)) +
		(c3_dict / maxf(c3_dots, 0.001)) +
		(c4_dict / maxf(c4_dots, 0.001))
	) / 4.0
	print("Average speedup (using single-write API for 3/4): %.2fx" % avg_speedup_orig)
	if avg_speedup >= 5.0:
		print("  ✅ STRONG WIN — recommend Pass-A integration immediately")
	elif avg_speedup >= 2.0:
		print("  🟡 MODERATE WIN — worth doing, weigh integration cost")
	elif avg_speedup >= 1.0:
		print("  🟠 MARGINAL — investigate batch API or hot-spot only")
	else:
		print("  🔴 REGRESSION — DCWorldExt slower than Dictionary, investigate")

# ────────────────────────────────────────────────────────────────────
# Bench harness
# ────────────────────────────────────────────────────────────────────
func _bench_min(trials: int, fn: Callable) -> float:
	var best: float = INF
	for _t in range(trials):
		var t0: int = Time.get_ticks_usec()
		fn.call()
		var dt: float = float(Time.get_ticks_usec() - t0) / 1000.0
		if dt < best:
			best = dt
	return best

func _report(label: String, dict_ms: float, dots_ms: float) -> void:
	var sp: float = dict_ms / maxf(dots_ms, 0.001)
	print("  %s: Dict=%.2fms  DOTS=%.2fms  speedup=%.2fx" % [label, dict_ms, dots_ms, sp])
	print("")

func _summary_row(label: String, d: float, x: float) -> void:
	var sp: float = d / maxf(x, 0.001)
	print("%s | %9.2f | %9.2f | %5.2fx" % [label, d, x, sp])

# ────────────────────────────────────────────────────────────────────
# Test data generators
# ────────────────────────────────────────────────────────────────────
func _make_full_src() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(N_CELLS)
	for i in range(N_CELLS):
		a[i] = sin(float(i) * 0.013) * 0.5 + 0.5  # 模拟温度 ∈ [0,1]
	return a

func _make_dirty_indices() -> PackedInt32Array:
	# 固定种子的 dirty cell 列表（不随机，保证两边公平）
	var n_dirty: int = int(N_CELLS * DIRTY_RATIO)
	var a := PackedInt32Array()
	a.resize(n_dirty)
	# 均匀间隔 + 偏移，模拟"散布的 dirty cells"
	var step: float = float(N_CELLS) / float(n_dirty)
	for i in range(n_dirty):
		a[i] = int(float(i) * step + 0.5) % N_CELLS
	return a

func _make_dirty_src(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	for i in range(n):
		a[i] = cos(float(i) * 0.017) * 0.5 + 0.5
	return a

func _make_neighbor_table() -> PackedInt32Array:
	# 6 邻居索引（环形偏移模拟，不需要真 hex 拓扑）
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

# ════════════════════════════════════════════════════════════════════
# Dictionary path (legacy simulation)
# ════════════════════════════════════════════════════════════════════
func _bench_dict_full_linear(src: PackedFloat32Array) -> void:
	var d: Dictionary = {}
	for k in range(N_ITERS):
		# Full write
		for i in range(N_CELLS):
			d[i] = src[i]
		# Linear read + sum
		var s: float = 0.0
		for i in range(N_CELLS):
			s += d[i]
		# 防优化掉
		if s < -1e9:
			print(s)

func _bench_dict_full_neighbor(src: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var d: Dictionary = {}
	for k in range(N_ITERS):
		for i in range(N_CELLS):
			d[i] = src[i]
		var s: float = 0.0
		for i in range(N_CELLS):
			var base: int = i * NEIGHBOR_COUNT
			s += float(d[nb[base + 0]]) + float(d[nb[base + 1]]) + float(d[nb[base + 2]]) \
				+ float(d[nb[base + 3]]) + float(d[nb[base + 4]]) + float(d[nb[base + 5]])
		if s < -1e9:
			print(s)

func _bench_dict_inc_linear(dirty: PackedInt32Array, src: PackedFloat32Array) -> void:
	# 先初始化为完整字典
	var d: Dictionary = {}
	for i in range(N_CELLS):
		d[i] = 0.0
	var n_dirty: int = dirty.size()
	for k in range(N_ITERS):
		for j in range(n_dirty):
			d[dirty[j]] = src[j]
		var s: float = 0.0
		for i in range(N_CELLS):
			s += d[i]
		if s < -1e9:
			print(s)

func _bench_dict_inc_neighbor(dirty: PackedInt32Array, src: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var d: Dictionary = {}
	for i in range(N_CELLS):
		d[i] = 0.0
	var n_dirty: int = dirty.size()
	for k in range(N_ITERS):
		for j in range(n_dirty):
			d[dirty[j]] = src[j]
		var s: float = 0.0
		for i in range(N_CELLS):
			var base: int = i * NEIGHBOR_COUNT
			s += float(d[nb[base + 0]]) + float(d[nb[base + 1]]) + float(d[nb[base + 2]]) \
				+ float(d[nb[base + 3]]) + float(d[nb[base + 4]]) + float(d[nb[base + 5]])
		if s < -1e9:
			print(s)

# ════════════════════════════════════════════════════════════════════
# DCWorldExt path (DOTS)
# ════════════════════════════════════════════════════════════════════
func _make_world() -> Object:
	var w: Object = ClassDB.instantiate("DCWorldExt")
	var cid := int(w.register_component("bench_temp", 0, 1, false))  # F32, 1 elem, not double-buffered
	w.create_pool("cells", N_CELLS)
	# 预热 view 缓存
	var _v: PackedFloat32Array = w.view_f32(cid)
	# 把 cid 存到 metadata 方便取出
	w.set_meta("bench_cid", cid)
	return w

func _bench_dots_full_linear(src: PackedFloat32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		# Full write via batch range
		w.write_f32_range(cid, 0, src)
		# Linear read via view (零拷贝引用)
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			s += v[i]
		if s < -1e9:
			print(s)

func _bench_dots_full_neighbor(src: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.write_f32_range(cid, 0, src)
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			var base: int = i * NEIGHBOR_COUNT
			s += v[nb[base + 0]] + v[nb[base + 1]] + v[nb[base + 2]] \
				+ v[nb[base + 3]] + v[nb[base + 4]] + v[nb[base + 5]]
		if s < -1e9:
			print(s)

func _bench_dots_inc_linear(dirty: PackedInt32Array, src: PackedFloat32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var n_dirty: int = dirty.size()
	for k in range(N_ITERS):
		# Incremental write via single-cell write_f32
		for j in range(n_dirty):
			w.write_f32(cid, dirty[j], src[j])
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			s += v[i]
		if s < -1e9:
			print(s)

func _bench_dots_inc_neighbor(dirty: PackedInt32Array, src: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	var n_dirty: int = dirty.size()
	for k in range(N_ITERS):
		for j in range(n_dirty):
			w.write_f32(cid, dirty[j], src[j])
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			var base: int = i * NEIGHBOR_COUNT
			s += v[nb[base + 0]] + v[nb[base + 1]] + v[nb[base + 2]] \
				+ v[nb[base + 3]] + v[nb[base + 4]] + v[nb[base + 5]]
		if s < -1e9:
			print(s)

# ─── NEW: indexed-write API path (one trans-boundary call) ──────────────────────────
func _bench_dots_inc_linear_indexed(dirty: PackedInt32Array, src: PackedFloat32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	# values 需要与 dirty 索引一一对应，src[j] 已是该布局
	for k in range(N_ITERS):
		# Single trans-boundary call: writes all dirty cells in C++ loop
		w.write_f32_indexed(cid, dirty, src)
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			s += v[i]
		if s < -1e9:
			print(s)

func _bench_dots_inc_neighbor_indexed(dirty: PackedInt32Array, src: PackedFloat32Array, nb: PackedInt32Array) -> void:
	var w: Object = _make_world()
	var cid: int = int(w.get_meta("bench_cid"))
	for k in range(N_ITERS):
		w.write_f32_indexed(cid, dirty, src)
		var v: PackedFloat32Array = w.view_f32(cid)
		var s: float = 0.0
		for i in range(N_CELLS):
			var base: int = i * NEIGHBOR_COUNT
			s += v[nb[base + 0]] + v[nb[base + 1]] + v[nb[base + 2]] \
				+ v[nb[base + 3]] + v[nb[base + 4]] + v[nb[base + 5]]
		if s < -1e9:
			print(s)
