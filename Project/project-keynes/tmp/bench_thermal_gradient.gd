@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_thermal_gradient.gd — Mode-B 通信参考实现 Pass #2
# ════════════════════════════════════════════════════════════════════
#
# Pass #1 (bench_temp_drift.gd) 验证了"通信契约本身"：1 个输入 component +
# in-place 修改自身的最简路径。Pass #2 把同一套契约放大到接近真实业务的
# 复杂度——多输入 SoA + 邻居访问 + 写新 component。算法仍保持零发散风险，
# 完全可复制粘贴到下一个真实 PDE pass。
#
# 验证流程：
#   1. 实例化 DCWorldExt
#   2. 注册三个组件：cell_temp / cell_elevation / cell_demo_thermal_gradient
#   3. 用确定性输入填充 cell_temp（线性梯度 + 余弦扰动）和 cell_elevation
#      （确定性 PCG 伪随机），保证多次运行 bit-equal。
#   4. 路径 A (C++)  ：_ext.run_thermal_gradient_pass(W, H, gain, k)
#                     → snapshot_f32 拉回 demo_thermal_gradient_arr
#   5. 路径 B (GDScript)：thermal_gradient_pass_gdscript(...) 同公式 GDScript 实现
#   6. 期望：路径 A 与 B 逐元素 bit 精确相等（一阶差分 + sqrt 在 IEEE754 下
#      确定性。如果实测 bit-equal 不可达（罕见），降级判断 max_abs_diff ≤ 1e-6）。
#   7. 同时打印两条路径的耗时（μs），C++ 路径 > 2 ms 时 push_warning。
#
# 阅读顺序：
#   _run() →  pass / fail 判定
#   path_cpp_full / path_gdscript_full → 两条路径的对照实现
#   thermal_gradient_pass_gdscript → 可粘贴到 §12.6 GDScript 模板的实现
#
# 参见：
#   docs/performance-charter.md §12.6 (复制此处代码作为模板 #2)
#   .codebuddy/plan/cpp-thermal-gradient-pass/ (本计划)
# ════════════════════════════════════════════════════════════════════

const GRID_W: int = 60
const GRID_H: int = 40
const N_CELLS: int = GRID_W * GRID_H
const ELEVATION_GAIN: float = 1.5
const NORMALIZE_K: float = 0.5
# 当前规格：60×40 cells，C++ 路径目标 < 2 ms（含 snapshot 拉回）
const CPP_BUDGET_US: int = 2000
const TOLERANCE: float = 1.0e-6

# ────────────────────────────────────────────────────────────────────
# 极简 MapData 替身：仅持有 Pass #2 直接用到的三个 PackedFloat32Array。
# ────────────────────────────────────────────────────────────────────
class MiniMap:
	var temp_arr: PackedFloat32Array = PackedFloat32Array()
	var elevation_arr: PackedFloat32Array = PackedFloat32Array()
	var demo_thermal_gradient_arr: PackedFloat32Array = PackedFloat32Array()

	func _init(n: int) -> void:
		temp_arr.resize(n)
		elevation_arr.resize(n)
		demo_thermal_gradient_arr.resize(n)


# ════════════════════════════════════════════════════════════════════
# 入口点：在 Editor 内 File → Run 即可触发。
# ════════════════════════════════════════════════════════════════════
func _run() -> void:
	print("=== bench_thermal_gradient — Mode-B reference impl Pass #2 ===")
	print("GRID=%dx%d (N=%d)  ELEVATION_GAIN=%.3f  NORMALIZE_K=%.3f" \
		% [GRID_W, GRID_H, N_CELLS, ELEVATION_GAIN, NORMALIZE_K])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_thermal_gradient] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# ─── 共用确定性输入 ─────────────────────────────────────────
	var temp_input: PackedFloat32Array = _make_temp_input(GRID_W, GRID_H)
	var elev_input: PackedFloat32Array = _make_elevation_input(GRID_W, GRID_H)

	# ─── 路径 A：C++ 端 run_thermal_gradient_pass + snapshot 回流 ─
	var map_a: MiniMap = MiniMap.new(N_CELLS)
	map_a.temp_arr = temp_input.duplicate()
	map_a.elevation_arr = elev_input.duplicate()
	var ext: Object = _make_ext_with_three_slots(N_CELLS, map_a.temp_arr, map_a.elevation_arr)
	var t0_cpp: int = Time.get_ticks_usec()
	path_cpp_full(ext, map_a, GRID_W, GRID_H, ELEVATION_GAIN, NORMALIZE_K)
	var cpp_us: int = Time.get_ticks_usec() - t0_cpp

	# ─── 路径 B：纯 GDScript 对照实现 ─────────────────────────────
	var map_b: MiniMap = MiniMap.new(N_CELLS)
	map_b.temp_arr = temp_input.duplicate()
	map_b.elevation_arr = elev_input.duplicate()
	var t0_gd: int = Time.get_ticks_usec()
	path_gdscript_full(map_b, GRID_W, GRID_H, ELEVATION_GAIN, NORMALIZE_K)
	var gd_us: int = Time.get_ticks_usec() - t0_gd

	# ─── 一致性校验：先尝试 bit-equal，fallback 到 |Δ| ≤ TOLERANCE ─
	var max_abs_diff: float = _max_abs_diff(map_a.demo_thermal_gradient_arr,
											map_b.demo_thermal_gradient_arr)
	var bit_equal: bool = _check_arrays_bit_equal(map_a.demo_thermal_gradient_arr,
												  map_b.demo_thermal_gradient_arr)
	var ok_match: bool = bit_equal or (max_abs_diff <= TOLERANCE)
	# 同步检查 C++ 输出确实落在 [0, 1] 范围内
	var ok_range: bool = _check_in_unit_range(map_a.demo_thermal_gradient_arr)

	# ─── 报告 ────────────────────────────────────────────────────
	print("─── Timings ───")
	print("  C++ path     : %d µs" % cpp_us)
	print("  GDScript path: %d µs" % gd_us)
	if cpp_us > CPP_BUDGET_US:
		push_warning("[bench_thermal_gradient] C++ path %d µs > budget %d µs" % [cpp_us, CPP_BUDGET_US])
	print("")
	print("─── Verification ───")
	print("  bit-equal             : %s" % ("PASS" if bit_equal else "FAIL"))
	# Use plain concatenation rather than `%.3e / %.0e` formatters — those
	# specifiers are honoured fine by Godot's `%` operator, but mixing them
	# with non-ASCII characters elsewhere on the same line has been observed
	# to trip the parser on Godot 4.6. Stick to ASCII + String.num.
	print("  max_abs_diff          : " + String.num(max_abs_diff, 9)
		+ " (tolerance " + String.num(TOLERANCE, 9) + ")")
	print("  C++ output in [0,1]   : %s" % ("PASS" if ok_range else "FAIL"))
	print("")

	if ok_match and ok_range:
		# Same rationale as above: avoid mixing `—` (em-dash) with `%` formatters
		# inside one literal on Godot 4.6.
		print("[bench_thermal_gradient] PASS - " + str(GRID_W) + "x" + str(GRID_H)
			+ " cells, max_abs_diff=" + String.num(max_abs_diff, 9))
	else:
		print("[bench_thermal_gradient] FAIL - see details above")


# ════════════════════════════════════════════════════════════════════
# 路径 A：C++ 跑 pass，GDScript 端 flush 拉快照。
# 这是 §12.6 模板 #2 的标准调用形态——可直接复制到下一个邻居访问 pass。
# ════════════════════════════════════════════════════════════════════
func path_cpp_full(ext: Object, map: MiniMap, w: int, h: int,
		elevation_gain: float, normalize_k: float) -> void:
	# 1. 在调用 pass 之前把 GDScript 侧的输入推进 C++ slot（write_f32 全量同步）
	#    bench 中我们直接把数组挂在 ext 上，所以这里只需要触发 snapshot 即可。
	#    在真实 main.gd 里，输入字段早已在 bind_map_data 阶段挂入，无需额外 push。
	# 2. 调 C++ pass：写到 cell_demo_thermal_gradient slot。
	ext.run_thermal_gradient_pass(w, h, elevation_gain, normalize_k)
	# 3. flush 是契约——pass 跑完一定要拉快照回 GDScript 侧。
	flush_demo_thermal_gradient(ext, map)


# ════════════════════════════════════════════════════════════════════
# 路径 B：纯 GDScript 对照实现。
# ════════════════════════════════════════════════════════════════════
func path_gdscript_full(map: MiniMap, w: int, h: int,
		elevation_gain: float, normalize_k: float) -> void:
	thermal_gradient_pass_gdscript(map, w, h, elevation_gain, normalize_k)


# ────────────────────────────────────────────────────────────────────
# §12.6 GDScript 模板：4-邻 clamp-to-edge 一阶差分 + elevation 放大。
# 公式与 C++ 端完全对齐：sqrt 走 double 路径以保证 bit-equal。
# ────────────────────────────────────────────────────────────────────
func thermal_gradient_pass_gdscript(map: MiniMap, w: int, h: int,
		elevation_gain: float, normalize_k: float) -> void:
	var n: int = w * h
	var temp: PackedFloat32Array = map.temp_arr
	var elev: PackedFloat32Array = map.elevation_arr
	var out: PackedFloat32Array = map.demo_thermal_gradient_arr
	if temp.size() != n or elev.size() != n or out.size() != n:
		push_error("[bench_thermal_gradient] size mismatch: w*h=%d vs temp=%d / elev=%d / out=%d"
			% [n, temp.size(), elev.size(), out.size()])
		return
	for y in range(h):
		var row: int = y * w
		var row_n: int = (row - w) if y > 0 else row
		var row_s: int = (row + w) if y < h - 1 else row
		for x in range(w):
			var i: int = row + x
			var iw: int = (i - 1) if x > 0 else i
			var ie: int = (i + 1) if x < w - 1 else i
			var in_: int = row_n + x
			var is_: int = row_s + x
			var gx: float = (temp[ie] - temp[iw]) * 0.5
			var gy: float = (temp[is_] - temp[in_]) * 0.5
			var gmag: float = sqrt(gx * gx + gy * gy)
			var amp: float = 1.0 + elevation_gain * elev[i]
			var v: float = gmag * amp * normalize_k
			if v < 0.0:
				v = 0.0
			elif v > 1.0:
				v = 1.0
			out[i] = v
	map.demo_thermal_gradient_arr = out


# ────────────────────────────────────────────────────────────────────
# flush_demo_thermal_gradient: Mode-B 强制同步点（写新 component 的版本）。
# ────────────────────────────────────────────────────────────────────
func flush_demo_thermal_gradient(ext: Object, map: MiniMap) -> void:
	var cid: int = int(ext.component_id("cell_demo_thermal_gradient"))
	if cid < 0:
		push_error("[flush_demo_thermal_gradient] cell_demo_thermal_gradient not registered on ext")
		return
	map.demo_thermal_gradient_arr = ext.snapshot_f32(cid)


# ════════════════════════════════════════════════════════════════════
# Inputs — 确定性构造，多次运行结果一致。
# ════════════════════════════════════════════════════════════════════
# 温度输入：水平方向线性 0→1 + 一个余弦扰动让梯度分布有非平凡结构。
func _make_temp_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	for y in range(h):
		var ny: float = (float(y) + 0.5) / float(h)  # [0, 1)
		for x in range(w):
			var nx: float = (float(x) + 0.5) / float(w)
			# 基础线性梯度 + 经度方向余弦波，让温度场出现锋面
			var base: float = nx
			var wave: float = 0.15 * cos(nx * TAU * 2.0) * sin(ny * PI)
			arr[y * w + x] = base + wave
	return arr


# 海拔输入：确定性 PCG 伪随机 [0, 1]。不依赖 Godot RNG state，避免被外部影响。
func _make_elevation_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	var seed: int = 0x9E3779B1  # 黄金比例近似 32 bit；任何确定性常量都行
	for i in range(w * h):
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = float(seed % 10000) / 10000.0
	return arr


# ════════════════════════════════════════════════════════════════════
# Helpers — 构造 ext 实例 + 比对工具。
# ════════════════════════════════════════════════════════════════════
func _make_ext_with_three_slots(n: int, temp_input: PackedFloat32Array,
		elev_input: PackedFloat32Array) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# dtype=0 = F32, stride=1, track_prev=false
	var cid_temp: int = int(ext.register_component("cell_temp", 0, 1, false))
	var cid_elev: int = int(ext.register_component("cell_elevation", 0, 1, false))
	var cid_out: int = int(ext.register_component("cell_demo_thermal_gradient", 0, 1, false))
	# create_pool 会把 _entity_count 拉到 n，并 ensure 各 slot.arr_f32.resize(n)
	ext.create_pool("cells", n)
	# 把输入数据通过 write_f32_range 批量推到 C++ slot（一次性 memcpy 等价）。
	#   write_f32_range(comp_id, start_idx, src_PackedFloat32Array)
	# 这是把 GDScript-side 数据推过 boundary 的 canonical helper（charter §11）。
	ext.write_f32_range(cid_temp, 0, temp_input)
	ext.write_f32_range(cid_elev, 0, elev_input)
	# cid_out 留作 0 即可（pass 会覆盖每个 cell）
	return ext


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
				# NOTE: avoid the `"... %s ... %s" % [...]` form here — GDScript
				# 4.6's format-string parser sometimes mis-handles non-ASCII
				# bytes that precede `%` (e.g. an em-dash or Greek delta in
				# the same literal). Use plain concatenation + String.num to
				# stay strictly within ASCII and side-step that bug.
				print("    [" + str(i) + "] cpp=" + String.num(a[i], 9)
					+ " gd=" + String.num(b[i], 9)
					+ " abs_diff=" + String.num(absf(a[i] - b[i]), 9))
			fail_count += 1
	if fail_count > 0:
		print("    %d / %d cells diverge between paths (bit comparison)" % [fail_count, n])
		return false
	return true


func _check_in_unit_range(arr: PackedFloat32Array) -> bool:
	var n: int = arr.size()
	for i in range(n):
		var v: float = arr[i]
		if v < 0.0 or v > 1.0 or is_nan(v):
			print("    out-of-range at [%d] = %.6f" % [i, v])
			return false
	return true
