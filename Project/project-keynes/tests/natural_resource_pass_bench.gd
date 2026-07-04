extends SceneTree

# natural_resource_pass_bench.gd
# 自然资源 pass 的并行/向量化加速基准。隔离两个加速轴，在同一构建上对比：
#   scalar+1T  : 纯标量 + 单线程（基线）
#   scalar+MT  : 纯标量 + 多核（WorkerThreadPool）
#   SIMD+1T    : AVX2 SIMD + 单线程
#   SIMD+MT    : AVX2 SIMD + 生产自适应路径（小图保持 1T，大图才进 WorkerThreadPool）
# 通过 run_natural_resource_pass 的 bench_force_scalar / bench_force_seq 旁路开关切换
# （默认 false，生产路径不受影响）。报告各档 compute_ms（取多次最优）+ 相对基线加速比
# + 吞吐（M updates/s，update = cell × resource）。注意：MT 行表示未设置
# bench_force_seq 的生产路径请求；当前 C++ 会对小图自适应走 single-thread SIMD。
#
# 先做一次小图等价性交叉校验（四档结果必须一致），再做多尺寸计时。
#
# Headless:
#   godot --headless --path <proj> --script res://tests/natural_resource_pass_bench.gd --quit

var _ok: bool = true


func _init() -> void:
	_run()
	quit(0 if _ok else 1)


func _run() -> void:
	print("=== natural resource pass benchmark ===")
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt class not found (gdext not built)")
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("run_natural_resource_pass"):
		print("  [SKIP] run_natural_resource_pass not exported")
		return

	ResourceProfileRegistry.ensure_loaded()
	var profiles: Array = ResourceProfileRegistry.ordered()
	if profiles.size() < 2:
		print("  [SKIP] registry has <2 profiles")
		return
	print("  resources=%d  (AVX2 build expected for SIMD rows)" % profiles.size())

	var configs: Array = [
		{"name": "scalar+1T", "scalar": true, "seq": true},
		{"name": "scalar+MT", "scalar": true, "seq": false},
		{"name": "SIMD+1T", "scalar": false, "seq": true},
		{"name": "SIMD+MT", "scalar": false, "seq": false},
	]

	_verify_equivalence(ext, profiles, configs)

	for n in [2_400, 50_000, 250_000, 1_000_000]:
		_bench_size(ext, profiles, n, configs)

	print("=== benchmark done (%s) ===" % ("OK" if _ok else "EQUIV-CHECK FAILED"))


# ── 等价性交叉校验：四档从同一初值跑一 tick，结果数组必须逐 cell 一致 ──────────
func _verify_equivalence(ext, profiles: Array, configs: Array) -> void:
	var n: int = 1000
	var map := MapData.new(n, 1)
	_seed_climate(map, n)
	var ref_snapshots: Dictionary = {}   # field -> PackedFloat32Array（基线 scalar+1T 结果）
	var worst: float = 0.0
	for ci in range(configs.size()):
		var cfg: Dictionary = configs[ci]
		_seed_reserves(map, profiles, n)            # 每档从同一初值重置
		if not bool(ext.bind_map_data(map)):
			printerr("  [FAIL] bind_map_data (equiv)")
			_ok = false
			return
		var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
		knobs["n_cells"] = n
		knobs["bench_force_scalar"] = bool(cfg["scalar"])
		knobs["bench_force_seq"] = bool(cfg["seq"])
		ext.run_natural_resource_pass(knobs)
		for p in profiles:
			var field: String = ResourceProfileRegistry.reserve_map_field(p)
			var got: PackedFloat32Array = map.get(field)
			if ci == 0:
				ref_snapshots[field] = got.duplicate()
			else:
				var ref: PackedFloat32Array = ref_snapshots[field]
				var cap: float = float(p.capacity)
				var tol: float = maxf(1e-4, cap * 1e-3)
				for i in range(n):
					worst = maxf(worst, absf(got[i] - ref[i]))
					if absf(got[i] - ref[i]) > tol:
						printerr("  [FAIL] equiv %s: %s[%d]=%s vs base=%s (tol=%s)" % [
							String(cfg["name"]), String(p.id), i, str(got[i]), str(ref[i]), str(tol)])
						_ok = false
						return
	print("  [equiv] 4 configs agree across %d cells × %d resources (worst |Δ|=%s)" % [
		n, profiles.size(), String.num_scientific(worst)])


# ── 计时：单次 seed/bind，各档 warmup + 取最优 compute_ms ──────────────────────
func _bench_size(ext, profiles: Array, n: int, configs: Array) -> void:
	var map := MapData.new(n, 1)
	_seed_climate(map, n)
	_seed_reserves(map, profiles, n)
	if not bool(ext.bind_map_data(map)):
		printerr("  [FAIL] bind_map_data (n=%d)" % n)
		_ok = false
		return

	var updates: float = float(n) * float(profiles.size())
	print("  ── n_cells=%s  (%s updates/tick) ──" % [_commas(n), _commas(int(updates))])
	print("    %-10s %12s %10s %14s" % ["config", "compute_ms", "speedup", "M_upd/s"])

	const WARM: int = 3
	const MEAS: int = 10
	var baseline: float = 0.0
	for cfg in configs:
		var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
		knobs["n_cells"] = n
		knobs["bench_force_scalar"] = bool(cfg["scalar"])
		knobs["bench_force_seq"] = bool(cfg["seq"])
		var best: float = INF
		for it in range(WARM + MEAS):
			var res: Dictionary = ext.run_natural_resource_pass(knobs)
			if it >= WARM:
				best = minf(best, float(res.get("compute_ms", INF)))
		if String(cfg["name"]) == "scalar+1T":
			baseline = best
		var speedup: float = (baseline / best) if best > 0.0 else 0.0
		var mups: float = (updates / (best / 1000.0)) / 1.0e6 if best > 0.0 else 0.0
		print("    %-10s %12.4f %9.2fx %14.1f" % [String(cfg["name"]), best, speedup, mups])


# ── seed helpers ──────────────────────────────────────────────────────────────
func _seed_climate(map: MapData, n: int) -> void:
	var temp := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var water := PackedByteArray()
	temp.resize(n)
	moist.resize(n)
	water.resize(n)
	for i in range(n):
		temp[i] = -20.0 + 50.0 * (float(i % 97) / 96.0)     # -20 .. 30 °C
		moist[i] = float(i % 53) / 52.0                       # 0 .. 1
		water[i] = 1 if (i % 7 == 0) else 0                  # ~14% 水面格
	map.temp_arr = temp
	map.moisture_arr = moist
	map.is_water_arr = water


func _seed_reserves(map: MapData, profiles: Array, n: int) -> void:
	for p in profiles:
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var cap: float = float(p.capacity)
		var arr := PackedFloat32Array()
		arr.resize(n)
		for i in range(n):
			arr[i] = cap * (0.2 + 0.6 * (float(i % 5) / 4.0))
		map.set(field, arr)


func _commas(v: int) -> String:
	var s: String = str(v)
	var out: String = ""
	var c: int = 0
	for k in range(s.length() - 1, -1, -1):
		out = s[k] + out
		c += 1
		if c % 3 == 0 and k > 0:
			out = "," + out
	return out
