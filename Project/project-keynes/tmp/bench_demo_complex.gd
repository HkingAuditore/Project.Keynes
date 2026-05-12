@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_demo_complex.gd — Mode-B 通信参考实现 Pass #3
# ════════════════════════════════════════════════════════════════════
#
# Pass #2 (bench_thermal_gradient.gd) 把通信契约放大到"多输入 + 邻居 + 写新
# component + 接 overlay" 四条真实业务复杂度。Pass #3 在 Pass #2 全部基础设
# 施之上，仅替换内核算法为：
#   迭代式各向异性扩散 + Sobel 梯度 + 科氏旋转 + 地形阻尼 + 步长演化 + 末尾归一化。
# ops/cell 从 Pass #2 的 ~10 提升到 Pass #3 默认参数下的 ~2400（240×）。
#
# 验证流程：
#   1. 实例化 DCWorldExt，注册三个组件（沿用 Pass #2）。
#   2. 用与 Pass #2 完全一致的输入构造（线性温度梯度 + 余弦扰动 + 确定性 PCG 海拔）
#      保证多次运行可重复。
#   3. **bit-equal 验证组**：32×32, iter=4, kr=2, coriolis=0.5, drag=0.6,
#      gain=1.5, k=0.5；C++ run_demo_complex_pass 与 demo_complex_pass_gdscript
#      逐元素比对，差异 > 1e-6 视为 FAIL。
#   4. **性能对照组**：网格 ∈ {32×32, 64×64, 128×128} × iter ∈ {4, 16, 64}，
#      kr=2 固定；每组各跑 1 次 C++ + 1 次 GDScript，记录 µs 耗时。
#   5. 末尾打印 ASCII 表 + 60×40 / iter=16 外推估算行。
#
# 阅读顺序：
#   _run() → bit-equal 判定 → 9 组性能对照
#   demo_complex_pass_gdscript → §12.6.6 GDScript 模板
#
# 参见：
#   docs/performance-charter.md §12.6.6 (本 bench 的输出会粘到这里)
#   .codebuddy/plan/cpp-demo-complex-pass/ (本计划)
# ════════════════════════════════════════════════════════════════════

const TOLERANCE: float = 1.0e-6
const CPP_BUDGET_US: int = 50000  # 50 ms 单组上限（仅用于 push_warning，不中断）

# bit-equal 验证组的固定参数（最小档位，保证 < 1 秒跑完）
const BE_GRID_W: int = 32
const BE_GRID_H: int = 32
const BE_ITER: int = 4
const BE_KR: int = 2
const BE_CORIOLIS: float = 0.5
const BE_DRAG: float = 0.6
const BE_GAIN: float = 1.5
const BE_K: float = 0.5

# 9 组性能对照参数（外乘内变）
const PERF_GRID_DIMS: Array = [
	[32, 32],
	[64, 64],
	[128, 128],
]
const PERF_ITER_LIST: Array = [4, 16, 64]
const PERF_KR: int = 2
const PERF_CORIOLIS: float = 0.5
const PERF_DRAG: float = 0.6
const PERF_GAIN: float = 1.5
const PERF_K: float = 0.5


# ────────────────────────────────────────────────────────────────────
# 极简 MapData 替身：与 Pass #2 bench 一致。
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
# 入口：在 Editor 内 File → Run 即可触发。
# ════════════════════════════════════════════════════════════════════
func _run() -> void:
	print("=== bench_demo_complex — Mode-B reference impl Pass #3 ===")
	print("Bit-equal group: %dx%d iter=%d kr=%d (cor=%.2f drag=%.2f gain=%.2f k=%.2f)" \
		% [BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR, BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K])
	print("Perf group: grids=%s × iters=%s, kr=%d" \
		% [str(PERF_GRID_DIMS), str(PERF_ITER_LIST), PERF_KR])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_demo_complex] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# ─── 1. bit-equal 验证组 ────────────────────────────────────
	var be_pass: bool = false
	var be_max_diff: float = INF
	var be_n: int = BE_GRID_W * BE_GRID_H
	var be_temp: PackedFloat32Array = _make_temp_input(BE_GRID_W, BE_GRID_H)
	var be_elev: PackedFloat32Array = _make_elevation_input(BE_GRID_W, BE_GRID_H)
	# C++ 路径
	var be_map_a: MiniMap = MiniMap.new(be_n)
	be_map_a.temp_arr = be_temp.duplicate()
	be_map_a.elevation_arr = be_elev.duplicate()
	var ext_be: Object = _make_ext_with_three_slots(be_n, be_map_a.temp_arr, be_map_a.elevation_arr)
	if not ext_be.has_method("run_demo_complex_pass"):
		push_error("[bench_demo_complex] DCWorldExt missing run_demo_complex_pass — rebuild gdext.")
		return
	ext_be.run_demo_complex_pass(BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K)
	be_map_a.demo_thermal_gradient_arr = ext_be.snapshot_f32(
		int(ext_be.component_id("cell_demo_thermal_gradient")))
	# GDScript 路径
	var be_map_b: MiniMap = MiniMap.new(be_n)
	be_map_b.temp_arr = be_temp.duplicate()
	be_map_b.elevation_arr = be_elev.duplicate()
	demo_complex_pass_gdscript(be_map_b, BE_GRID_W, BE_GRID_H, BE_ITER, BE_KR,
		BE_CORIOLIS, BE_DRAG, BE_GAIN, BE_K)
	# 比对
	be_max_diff = _max_abs_diff(be_map_a.demo_thermal_gradient_arr,
		be_map_b.demo_thermal_gradient_arr)
	var be_bit_equal: bool = _check_arrays_bit_equal(be_map_a.demo_thermal_gradient_arr,
		be_map_b.demo_thermal_gradient_arr)
	be_pass = be_bit_equal or (be_max_diff <= TOLERANCE)

	print("─── Bit-equal verification ───")
	print("  bit-equal     : " + ("PASS" if be_bit_equal else "FAIL"))
	print("  max_abs_diff  : " + String.num(be_max_diff, 9)
		+ " (tolerance " + String.num(TOLERANCE, 9) + ")")
	if be_pass:
		print("[bench_demo_complex] BIT-EQUAL PASS - "
			+ str(BE_GRID_W) + "x" + str(BE_GRID_H) + ", iter=" + str(BE_ITER)
			+ ", max_abs_diff=" + String.num(be_max_diff, 9))
	else:
		print("[bench_demo_complex] BIT-EQUAL FAIL - see details above")
	print("")

	# ─── 2. 9 组性能对照组 ──────────────────────────────────────
	print("─── Perf table (9 rows) ───")
	print("| grid       | iter | kr | C++ µs    | GDScript µs | speedup |")
	print("|------------|------|----|-----------|-------------|---------|")
	# 关键观察值：64×64 / iter=16 → 用作 60×40 / iter=16 的外推锚
	var anchor_64_iter16_us: int = -1
	for gd in PERF_GRID_DIMS:
		var w: int = int(gd[0])
		var h: int = int(gd[1])
		for iter in PERF_ITER_LIST:
			var n: int = w * h
			var temp_in: PackedFloat32Array = _make_temp_input(w, h)
			var elev_in: PackedFloat32Array = _make_elevation_input(w, h)
			# C++
			var map_c: MiniMap = MiniMap.new(n)
			map_c.temp_arr = temp_in.duplicate()
			map_c.elevation_arr = elev_in.duplicate()
			var ext: Object = _make_ext_with_three_slots(n, map_c.temp_arr, map_c.elevation_arr)
			var t0_c: int = Time.get_ticks_usec()
			ext.run_demo_complex_pass(w, h, iter, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K)
			map_c.demo_thermal_gradient_arr = ext.snapshot_f32(
				int(ext.component_id("cell_demo_thermal_gradient")))
			var cpp_us: int = Time.get_ticks_usec() - t0_c
			# GDScript
			var map_g: MiniMap = MiniMap.new(n)
			map_g.temp_arr = temp_in.duplicate()
			map_g.elevation_arr = elev_in.duplicate()
			var t0_g: int = Time.get_ticks_usec()
			demo_complex_pass_gdscript(map_g, w, h, iter, PERF_KR,
				PERF_CORIOLIS, PERF_DRAG, PERF_GAIN, PERF_K)
			var gd_us: int = Time.get_ticks_usec() - t0_g
			# 行打印
			var speedup: float = (float(gd_us) / float(cpp_us)) if cpp_us > 0 else INF
			var row: String = "| " + ("%-10s" % (str(w) + "x" + str(h)))
			row += " | " + ("%4d" % iter)
			row += " | " + ("%2d" % PERF_KR)
			row += " | " + ("%9d" % cpp_us)
			row += " | " + ("%11d" % gd_us)
			row += " | " + ("%6.1fx" % speedup)
			row += " |"
			if cpp_us > CPP_BUDGET_US:
				row += " ⚠ over budget"
				push_warning("[bench_demo_complex] " + str(w) + "x" + str(h)
					+ " iter=" + str(iter) + " cpp=" + str(cpp_us)
					+ " µs > " + str(CPP_BUDGET_US) + " µs budget")
			print(row)
			# 抓取外推锚点：64×64 / iter=16
			if w == 64 and h == 64 and iter == 16:
				anchor_64_iter16_us = cpp_us

	# 60×40 / iter=16 外推（按 cell 数线性，2400 / 4096 ≈ 0.586）
	if anchor_64_iter16_us > 0:
		var projected_us: float = float(anchor_64_iter16_us) * (2400.0 / 4096.0)
		print("→ projected at game-grid (60x40, iter=16, kr=2): C++ ~ "
			+ String.num(projected_us, 1) + " µs (interpolated)")
	print("")

	print("[bench_demo_complex] DONE - bit-equal="
		+ ("PASS" if be_pass else "FAIL")
		+ ", 9 perf rows logged")


# ════════════════════════════════════════════════════════════════════
# §12.6.6 GDScript 模板：迭代扩散 + Sobel + 科氏 + 阻尼。
# 浮点运算顺序与 C++ 端逐运算严格对齐，保证 IEEE754 下 bit-equal 可达。
# ════════════════════════════════════════════════════════════════════
func demo_complex_pass_gdscript(map: MiniMap, w: int, h: int,
		iterations: int, kernel_radius: int,
		coriolis: float, drag: float,
		elevation_gain: float, normalize_k: float) -> void:
	# 入口 clamp（与 C++ 端语义一致）
	if iterations < 1: iterations = 1
	if iterations > 64: iterations = 64
	if kernel_radius < 1: kernel_radius = 1
	if kernel_radius > 5: kernel_radius = 5
	if coriolis < -1.0: coriolis = -1.0
	if coriolis > 1.0: coriolis = 1.0
	if drag < 0.0: drag = 0.0
	if drag > 1.0: drag = 1.0

	var n: int = w * h
	var temp: PackedFloat32Array = map.temp_arr
	var elev: PackedFloat32Array = map.elevation_arr
	var out: PackedFloat32Array = map.demo_thermal_gradient_arr
	if temp.size() != n or elev.size() != n or out.size() != n:
		push_error("[bench_demo_complex] size mismatch: w*h=%d vs temp=%d / elev=%d / out=%d"
			% [n, temp.size(), elev.size(), out.size()])
		return

	# ─── 1. 预计算高斯权重表（与 C++ 端逐项对齐）─────────────────
	var kr: int = kernel_radius
	var ksz: int = 2 * kr + 1
	var klen: int = ksz * ksz
	var kernel: PackedFloat64Array = PackedFloat64Array()
	kernel.resize(klen)
	var kernel_sum: float = 0.0
	for dy in range(-kr, kr + 1):
		for dx in range(-kr, kr + 1):
			var weight: float = exp(-float(dx * dx + dy * dy) * 0.5)
			kernel[(dy + kr) * ksz + (dx + kr)] = weight
			kernel_sum += weight
	var kernel_inv_sum: float = (1.0 / kernel_sum) if kernel_sum > 0.0 else 0.0

	# ─── 2. 初始化乒乓 buffer（first src = temp 拷贝）──────────────
	var buf_a: PackedFloat64Array = PackedFloat64Array()
	var buf_b: PackedFloat64Array = PackedFloat64Array()
	buf_a.resize(n)
	buf_b.resize(n)
	for i in range(n):
		buf_a[i] = float(temp[i])

	var step_size: float = 0.05

	# ─── 3. iter 主循环（ping-pong）─────────────────────────────
	for it in range(iterations):
		var src: PackedFloat64Array = buf_b if (it & 1) else buf_a
		var dst: PackedFloat64Array = buf_a if (it & 1) else buf_b
		for y in range(h):
			# 半球符号（与 C++ 端一致：y < h/2 → -1，否则 +1）
			var cor_sign: float = -1.0 if y < (h / 2) else 1.0
			var rot_rad: float = coriolis * cor_sign * 1.5707963267948966  # π/2
			for x in range(w):
				var i: int = y * w + x

				# 3.1 高斯加权 smooth (2kr+1)² 邻居
				var accum: float = 0.0
				for dy in range(-kr, kr + 1):
					var ny: int = y + dy
					if ny < 0: ny = 0
					elif ny >= h: ny = h - 1
					var row: int = ny * w
					var krow: int = (dy + kr) * ksz
					for dx in range(-kr, kr + 1):
						var nx: int = x + dx
						if nx < 0: nx = 0
						elif nx >= w: nx = w - 1
						accum += src[row + nx] * kernel[krow + (dx + kr)]
				var smooth: float = accum * kernel_inv_sum

				# 3.2 Sobel 3×3 梯度（clamp-to-edge）
				var xw_: int = (x - 1) if x > 0 else x
				var xe: int = (x + 1) if x < w - 1 else x
				var yn: int = (y - 1) if y > 0 else y
				var ys_: int = (y + 1) if y < h - 1 else y
				var row_n: int = yn * w
				var row_c: int = y * w
				var row_s: int = ys_ * w
				var gx: float = (src[row_n + xe] + 2.0 * src[row_c + xe] + src[row_s + xe] \
								- src[row_n + xw_] - 2.0 * src[row_c + xw_] - src[row_s + xw_]) * 0.125
				var gy: float = (src[row_s + xw_] + 2.0 * src[row_s + x] + src[row_s + xe] \
								- src[row_n + xw_] - 2.0 * src[row_n + x] - src[row_n + xe]) * 0.125

				# 3.3 科氏旋转
				var cs: float = cos(rot_rad)
				var sn: float = sin(rot_rad)
				var gx_p: float = gx * cs - gy * sn
				var gy_p: float = gx * sn + gy * cs

				# 3.4 地形阻尼
				var damp: float = 1.0 - drag * float(elev[i])

				# 3.5 通量演化
				var flux: float = gx_p + gy_p
				dst[i] = smooth + flux * damp * step_size

	# ─── 4. 选最终 buffer ───────────────────────────────────────
	var last: PackedFloat64Array = buf_b if (iterations & 1) else buf_a

	# ─── 5. 归一化到 [0, 1] ─────────────────────────────────────
	var out_min: float = INF
	var out_max: float = -INF
	for i in range(n):
		var v: float = last[i]
		if v < out_min: out_min = v
		if v > out_max: out_max = v
	var denom: float = (out_max - out_min) if (out_max - out_min) > 1.0e-6 else 1.0e-6
	var inv_denom: float = 1.0 / denom

	# ─── 6. (1 + gain·elev) · k + clamp + narrow to float ──────
	for i in range(n):
		var norm: float = (last[i] - out_min) * inv_denom
		var amp: float = 1.0 + elevation_gain * float(elev[i])
		var v2: float = norm * amp * normalize_k
		if v2 < 0.0: v2 = 0.0
		elif v2 > 1.0: v2 = 1.0
		out[i] = v2

	map.demo_thermal_gradient_arr = out


# ════════════════════════════════════════════════════════════════════
# Inputs — 与 Pass #2 bench 完全一致的确定性构造（保证可重复）。
# ════════════════════════════════════════════════════════════════════
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


# ════════════════════════════════════════════════════════════════════
# Helpers — ext 实例 + 比对工具（与 Pass #2 bench 同款）。
# ════════════════════════════════════════════════════════════════════
func _make_ext_with_three_slots(n: int, temp_input: PackedFloat32Array,
		elev_input: PackedFloat32Array) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var cid_temp: int = int(ext.register_component("cell_temp", 0, 1, false))
	var cid_elev: int = int(ext.register_component("cell_elevation", 0, 1, false))
	var cid_out: int = int(ext.register_component("cell_demo_thermal_gradient", 0, 1, false))
	ext.create_pool("cells", n)
	ext.write_f32_range(cid_temp, 0, temp_input)
	ext.write_f32_range(cid_elev, 0, elev_input)
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
				print("    [" + str(i) + "] cpp=" + String.num(a[i], 9)
					+ " gd=" + String.num(b[i], 9)
					+ " abs_diff=" + String.num(absf(a[i] - b[i]), 9))
			fail_count += 1
	if fail_count > 0:
		print("    " + str(fail_count) + " / " + str(n)
			+ " cells diverge between paths (bit comparison)")
		return false
	return true
