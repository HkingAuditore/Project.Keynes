@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# template_bench.gd — Migration Harness Template (B3)
# ════════════════════════════════════════════════════════════════════
#
# 复制这个文件到 `tmp/bench_<your_module>.gd`，按"⚙️ MODULE-CUSTOM" 注释
# 标注的 8 个位置改成你自己的模块名 / 公式 / 容差，30 分钟内即可跑出
# bit-equal + µs 度量两条核心结论。
#
# 本模板覆盖 dots-migration-roadmap §5 SOP Step 5 的全部"通过标准"：
#   - bit-equal: legacy vs dots_gdscript（容差按业务设定）
#   - micro-bench: legacy µs / dots µs / 加速比
#   - 输出格式与 performance-charter §12.6.6.b 实测表一致，可直接对比
#
# 参考实现：[`tmp/bench_temp_drift.gd`](../../tmp/bench_temp_drift.gd)
#         （performance-charter §12.3 标杆模板）
#
# Editor 中 File → Run 即可触发；headless 跑请改 `extends SceneTree`
# + `func _init()` 入口。
# ════════════════════════════════════════════════════════════════════

# ─── ⚙️ MODULE-CUSTOM 1：模块名 + 规模 ────────────────────────────
const MODULE_NAME: String = "your_module"     # ⚙️ 改成你的模块名
const N_CELLS: int = 2400                     # ⚙️ 标杆规模（与 ProjectKeynes 默认 60×40 对齐）
const WARMUP: int = 3                         # JIT / cache 预热次数
const MEASURE: int = 30                       # 采样次数（取均值 + p95）

# ─── ⚙️ MODULE-CUSTOM 2：bit-equal 容差 ───────────────────────────
# 计数 / 离散字段：用 0.0（要求 byte-equal）；
# 浮点累加 / sin/cos / sqrt：用 1e-6 ~ 1e-4 之间，按算法收敛性设置。
const TOLERANCE: float = 1e-6


func _run() -> void:
	print("=== bench_%s — module migration harness ===" % MODULE_NAME)
	print("N_CELLS=%d  WARMUP=%d  MEASURE=%d  TOLERANCE=%.1e" %
		[N_CELLS, WARMUP, MEASURE, TOLERANCE])
	print("")

	# ─── ⚙️ MODULE-CUSTOM 3：构造测试输入 ────────────────────────
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xCAFEBABE
	var input_a: PackedFloat32Array = _make_random_f32(N_CELLS, rng)
	var input_b: PackedFloat32Array = _make_random_f32(N_CELLS, rng)

	# ─── 跑两条路径：legacy vs dots_gdscript ──────────────────────
	# Step 1：bit-equal（验证算法等价）
	var out_legacy: PackedFloat32Array = run_legacy(input_a, input_b)
	var out_dots:   PackedFloat32Array = run_dots_gdscript(input_a, input_b)
	var bit_equal_ok: bool = _check_bit_equal(out_legacy, out_dots, TOLERANCE)
	print("  bit-equal (legacy vs dots_gdscript): %s" %
		("PASS" if bit_equal_ok else "FAIL"))

	# Step 2：micro-bench（验证性能）
	var legacy_us: int = _bench_us(WARMUP, MEASURE, run_legacy.bind(input_a, input_b))
	var dots_us:   int = _bench_us(WARMUP, MEASURE, run_dots_gdscript.bind(input_a, input_b))
	var ratio: float = float(legacy_us) / max(float(dots_us), 1.0)
	print("  legacy avg=%6d µs   dots avg=%6d µs   speedup=%.2fx" %
		[legacy_us, dots_us, ratio])

	# Step 3（可选）：dots_cpp 路径（仅 ClassDB.class_exists("DCWorldExt") 时跑）
	if ClassDB.class_exists("DCWorldExt"):
		# ⚙️ MODULE-CUSTOM 4：在这里跑你的 C++ pass，对比 bit-equal + speedup
		# var ext = ClassDB.instantiate("DCWorldExt")
		# ext.bind_map_data(map)
		# ext.run_<your_module>_pass(...)
		# var out_cpp = ext.snapshot_f32(ext.component_id(&"cell.your_field"))
		# 略
		print("  (dots_cpp benchmark — fill in MODULE-CUSTOM 4)")

	# Step 4：判决
	if bit_equal_ok and ratio >= 0.8:
		print("  RESULT: PASS — module migration is safe to land")
	elif not bit_equal_ok:
		push_error("  RESULT: FAIL — bit-equal mismatch; algorithm divergence")
	else:
		push_warning("  RESULT: WARN — dots_gdscript slower than legacy (ratio=%.2fx)" % ratio)


# ════════════════════════════════════════════════════════════════════
# ⚙️ MODULE-CUSTOM 5：legacy implementation（直读 cell.* / map.<field>_arr）
# ════════════════════════════════════════════════════════════════════
func run_legacy(in_a: PackedFloat32Array, in_b: PackedFloat32Array) -> PackedFloat32Array:
	var n: int = in_a.size()
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	# 示例：output[i] = a[i] + b[i] * 0.5
	# 真实模块在这里应该模拟"现有未迁移的实现"——例如 for c in cells: c.x = ...
	for i in range(n):
		out[i] = in_a[i] + in_b[i] * 0.5
	return out


# ════════════════════════════════════════════════════════════════════
# ⚙️ MODULE-CUSTOM 6：dots_gdscript implementation（走 DCViewAdapter / view_f32）
# ════════════════════════════════════════════════════════════════════
func run_dots_gdscript(in_a: PackedFloat32Array, in_b: PackedFloat32Array) -> PackedFloat32Array:
	var n: int = in_a.size()
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	# 真实模块在这里应该走 SoA / view_f32 风格 hot loop。
	# 即使本模板里这两条公式相同，写两份是为了让"路径切换"机制本身有
	# 端到端可执行的占位，避免后续模块改 legacy 时忘了同步 dots 实现。
	for i in range(n):
		out[i] = in_a[i] + in_b[i] * 0.5
	return out


# ─── helpers (no MODULE-CUSTOM here) ───────────────────────────────

func _make_random_f32(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(n)
	for i in range(n):
		arr[i] = rng.randf_range(-1.0, 1.0)
	return arr


func _check_bit_equal(a: PackedFloat32Array, b: PackedFloat32Array, tol: float) -> bool:
	if a.size() != b.size():
		push_error("[bench] size mismatch: %d vs %d" % [a.size(), b.size()])
		return false
	var max_diff: float = 0.0
	for i in range(a.size()):
		var d: float = abs(a[i] - b[i])
		if d > max_diff:
			max_diff = d
		if d > tol:
			push_error("[bench] bit-equal FAIL at idx=%d: a=%.9g b=%.9g (Δ=%.9g, tol=%.1e)"
				% [i, a[i], b[i], d, tol])
			return false
	print("    max_diff=%.9g (tol=%.1e)" % [max_diff, tol])
	return true


# 跑 fn 一次的耗时（µs）。测 MEASURE 次取平均，前 WARMUP 次丢弃。
func _bench_us(warmup: int, measure: int, fn: Callable) -> int:
	for _i in range(warmup):
		fn.call()
	var t0: int = Time.get_ticks_usec()
	for _i in range(measure):
		fn.call()
	var elapsed: int = Time.get_ticks_usec() - t0
	return int(elapsed / measure)
