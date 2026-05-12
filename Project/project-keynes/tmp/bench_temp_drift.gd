@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_temp_drift.gd — Mode-B 通信参考实现 (Reference Implementation)
# ════════════════════════════════════════════════════════════════════
#
# 这个脚本不是一个 game feature。它的唯一职责是：
# 在 Editor 中点 "Run" 跑一次，验证 "数据归 C++ 独占 + GDScript 拉只读快照"
# 这套通信契约从端到端真的能跑通，并产出 bit-精确一致的数值。
#
# 流程：
#   1. 实例化 DCWorldExt
#   2. 注册 cell_temp 组件并通过 create_pool 自动开容量 N
#   3. 路径 A (C++)：连续 3 次 _ext.run_temp_drift_pass(0.5)
#                    → flush_to_mapdata 把 C++ 端结果拉回 map.temp_arr
#   4. 路径 B (GDScript)：直接对 map.temp_arr 做 += 0.5 三次
#   5. 期望：路径 A 与 路径 B 的最终数组**逐元素 bit 精确相等**
#           且每个元素 == 1.5
#
# 这个脚本完成它的诊断使命后被 *永久保留* 为参考样板：
# 后续所有真实 hot-loop（climate / ocean / weather / economy / pop ...）
# 应直接复制这套结构。
#
# 阅读顺序：
#   _run() →  pass / fail 判定
#   path_cpp_full / path_gdscript_full → 两条路径的对照实现
#   temp_drift_pass_gdscript / flush_to_mapdata → 可复用的 GDScript helper
#
# 参见 docs/performance-charter.md §12。
# ════════════════════════════════════════════════════════════════════

const N_CELLS: int = 1024            # 标杆规模：足够大以触发 SIMD 路径，足够小以瞬时跑完
const N_PASSES: int = 3              # 连续调用次数 → 验证多次调用无状态错误
const DRIFT: float = 0.5             # drift_amount → 三次累加后期望值 = 1.5
const EXPECTED: float = DRIFT * float(N_PASSES)

# ────────────────────────────────────────────────────────────────────
# 极简 MapData 替身：仅持有 temp_arr 一个字段。
# 真正的项目 MapData 字段更多，但本标杆只关心通信契约本身，
# 不关心业务字段。
# ────────────────────────────────────────────────────────────────────
class MiniMap:
	var temp_arr: PackedFloat32Array = PackedFloat32Array()

	func _init(n: int) -> void:
		temp_arr.resize(n)
		# 初始全 0；resize() 默认零初始化 PackedFloat32Array

# ════════════════════════════════════════════════════════════════════
# 入口点：在 Editor 内 File → Run 即可触发。
# ════════════════════════════════════════════════════════════════════
func _run() -> void:
	print("=== bench_temp_drift — Mode-B reference implementation ===")
	print("N_CELLS=%d  N_PASSES=%d  DRIFT=%.3f  EXPECTED=%.3f" \
		% [N_CELLS, N_PASSES, DRIFT, EXPECTED])
	print("")

	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[bench_temp_drift] DCWorldExt NOT registered. Build the GDExtension first.")
		return

	# ─── 路径 A：C++ 端 run_temp_drift_pass + snapshot 回流 ─────────
	var map_a: MiniMap = MiniMap.new(N_CELLS)
	var ext: Object = _make_ext_with_cell_temp(N_CELLS)
	var t0_cpp: int = Time.get_ticks_usec()
	path_cpp_full(ext, map_a, DRIFT, N_PASSES)
	var cpp_us: int = Time.get_ticks_usec() - t0_cpp

	# ─── 路径 B：纯 GDScript 对照实现 ──────────────────
	var map_b: MiniMap = MiniMap.new(N_CELLS)
	var t0_gd: int = Time.get_ticks_usec()
	path_gdscript_full(map_b, DRIFT, N_PASSES)
	var gd_us: int = Time.get_ticks_usec() - t0_gd
	# ─── 一致性校验：bit 精确比对 + 期望值校验 ────────────────────────
	var ok_value: bool = _check_all_equal(map_a.temp_arr, EXPECTED)
	var ok_match: bool = _check_arrays_equal(map_a.temp_arr, map_b.temp_arr)

	# ─── 报告 ───────────────────────────────────────────────────────
	print("─── Timings ───")
	print("  C++ path     : %d µs" % cpp_us)
	print("  GDScript path: %d µs" % gd_us)
	if cpp_us > 1000:
		print("  ⚠️  C++ path > 1ms — investigate trans-boundary overhead")
	print("")
	print("─── Verification ───")
	print("  C++ result == %.3f for all cells       : %s" \
		% [EXPECTED, "PASS" if ok_value else "FAIL"])
	print("  C++ path bit-equal to GDScript path     : %s" \
		% ["PASS" if ok_match else "FAIL"])
	print("")

	if ok_value and ok_match:
		print("[bench_temp_drift] PASS — %d cells, %d passes, all values match" \
			% [N_CELLS, N_PASSES])
	else:
		print("[bench_temp_drift] FAIL — see details above")

# ════════════════════════════════════════════════════════════════════
# 路径 A：C++ 端跑 pass，GDScript 端 flush 拉快照
# ════════════════════════════════════════════════════════════════════
#
# 这是 Mode-B 的标准调用形态——也是 §12 模板中要复制粘贴的部分。
# 注意 4 个角色：
#   1. C++ writer  : ext.run_temp_drift_pass(drift)
#   2. snapshot API: ext.snapshot_f32(comp_id)（在 flush_to_mapdata 内）
#   3. GDScript reader / consumer: map.temp_arr （在 flush 之后才读）
#   4. flush point : flush_to_mapdata(ext, map) ← 显式同步契约
#
# 错误模式：在 run_temp_drift_pass 与 map.temp_arr 之间不调 flush，
# 直接读 map.temp_arr 拿到的将是旧数据（CoW 副本未刷新）。
func path_cpp_full(ext: Object, map: MiniMap, drift: float, n_passes: int) -> void:
	for k in range(n_passes):
		ext.run_temp_drift_pass(drift)
	# flush 是契约，不是优化——pass 跑完一定要拉快照回 GDScript 侧。
	flush_to_mapdata(ext, map)

# ════════════════════════════════════════════════════════════════════
# 路径 B：纯 GDScript 对照实现
# ════════════════════════════════════════════════════════════════════
#
# 加法是精确运算（float32 + float32，且数值范围远未触发非规格化），
# 所以 C++ 路径与 GDScript 路径产出的最终数组应当 bit 精确相等。
func path_gdscript_full(map: MiniMap, drift: float, n_passes: int) -> void:
	for k in range(n_passes):
		temp_drift_pass_gdscript(map, drift)

# ────────────────────────────────────────────────────────────────────
# GDScript 对照实现：把 map.temp_arr 每个元素 += drift。
# 用作两件事的 ground-truth：
#   1. 数值正确性：和 C++ 路径 bit-equal 比对
#   2. 性能 reference：让 C++ 路径的耗时有个对标值
# ────────────────────────────────────────────────────────────────────
func temp_drift_pass_gdscript(map: MiniMap, drift: float) -> void:
	var n: int = map.temp_arr.size()
	for i in range(n):
		map.temp_arr[i] += drift

# ────────────────────────────────────────────────────────────────────
# flush_to_mapdata: Mode-B 强制同步点。
#
# 契约：把 C++ 端 _slots[CELL_TEMP].arr_f32 的最新值，通过 snapshot_f32
# 拉回 GDScript 侧的 MapData 镜像字段。
#
# 这是契约，不是优化——Mode-B 禁止依赖 alias 自动同步，
# 任何 pass 跑完都必须显式 flush 才能让 UI / Baker / 调试看到新值。
#
# 后续真实代码可能升格为 WorldExtFlush.flush_climate(ext, map) 这种
# 按业务字段批量打包的 helper，本计划保持最小骨架。
# ────────────────────────────────────────────────────────────────────
func flush_to_mapdata(ext: Object, map: MiniMap) -> void:
	var cid: int = int(ext.component_id("cell_temp"))
	if cid < 0:
		push_error("[flush_to_mapdata] cell_temp not registered on ext")
		return
	# snapshot_f32 返回 PackedFloat32Array 值拷贝（COW），不会泄漏 C++ 内部裸指针
	map.temp_arr = ext.snapshot_f32(cid)

# ════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════
func _make_ext_with_cell_temp(n_cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# dtype=0 = F32, stride=1 (scalar), track_prev=false
	var _cid: int = int(ext.register_component("cell_temp", 0, 1, false))
	# create_pool(name, capacity) 内部会调 create_entities(capacity)
	# → 触发 _ensure_slot_capacity → arr_f32.resize(n_cells)，默认全 0
	ext.create_pool("cells", n_cells)
	return ext

func _check_all_equal(arr: PackedFloat32Array, expected: float) -> bool:
	var n: int = arr.size()
	if n == 0:
		print("  ✗ array empty — cannot verify")
		return false
	var fail_count: int = 0
	for i in range(n):
		if arr[i] != expected:
			if fail_count < 5:
				print("    [%d] = %.6f (expected %.6f)" % [i, arr[i], expected])
			fail_count += 1
	if fail_count > 0:
		print("    %d / %d cells differ from expected" % [fail_count, n])
		return false
	return true

func _check_arrays_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		print("    size mismatch: %d vs %d" % [a.size(), b.size()])
		return false
	var n: int = a.size()
	var fail_count: int = 0
	for i in range(n):
		if a[i] != b[i]:
			if fail_count < 5:
				print("    [%d] cpp=%.6f gd=%.6f" % [i, a[i], b[i]])
			fail_count += 1
	if fail_count > 0:
		print("    %d / %d cells diverge between paths" % [fail_count, n])
		return false
	return true
