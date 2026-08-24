extends SceneTree

# climate_pass_bench.gd
# 气候 stencil 加速 Phase 0 基线测量（仿 tests/natural_resource_pass_bench.gd）。
#
# 目的：量化 climate pass_a / pass_b 在不同执行轴下的 compute 成本，作为
#   "融合 + SFC + SIMD" 加速计划的 go/no-go 数据地基。隔离两个加速轴：
#     pass_a:  scalar-1T (= 当前 native daily 图实际调用的 run_climate_pass_a)
#              scalar-MT (run_climate_pass_a_thread, 自适应多核 — 已实现但未接入图)
#     pass_b:  scalar-1T (= 当前 native daily 图实际调用的 run_climate_pass_b)
#              autovec-1T (run_climate_pass_b_simd, land_idx 预筛 + 编译器自动向量化)
#              autovec-MT (run_climate_pass_b_thread, 多核)
#
# 关键事实（system_schedule.cpp）：native daily 图的 exec 节点目前调用的是
#   **单线程标量** run_climate_pass_a / run_climate_pass_b —— 已实现并 A/B 验证过的
#   _thread / _simd 变体已绑定但未接入图。本基线量化"接入多核/SIMD 能省多少"。
#
# 测量方法：墙钟（Time.get_ticks_usec），warmup + 取多次最优。pass 函数返回
#   0.0(成功)/-1.0(回退) 而非耗时，故用墙钟；Dictionary/数组按引用传递（CoW，
#   无每次拷贝），大图上墙钟≈纯计算。另给出极粗的内存流量估算判定 memory-bound。
#
# Headless:
#   godot --headless --path <proj> --script res://tests/climate_pass_bench.gd --quit

var _ok: bool = true


func _init() -> void:
	_run()
	quit(0 if _ok else 1)


func _run() -> void:
	print("=== climate pass benchmark (Phase 0 baseline) ===")
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt class not found (gdext not built)")
		return

	var nt_mt: int = clampi(OS.get_processor_count(), 2, 16)
	print("  cores=%d  MT task count=%d  (AVX2/autovec build expected)" % [OS.get_processor_count(), nt_mt])

	# 多尺寸：通过真实 MapGenerator 生成（保证全部 SoA slot + neighbor_indices 绑定正确）。
	# 生成成本随 N 增长，故每尺寸单独打印生成耗时；如过慢可下调列表。
	var sizes: Array = [
		Vector2i(96, 72),    # 6,912
		Vector2i(160, 120),  # 19,200
		Vector2i(256, 192),  # 49,152
		Vector2i(384, 288),  # 110,592 — 检查大图是否转入 memory-bound
	]
	for wh in sizes:
		_bench_size(wh.x, wh.y, nt_mt)

	print("=== climate bench done (%s) ===" % ("OK" if _ok else "ISSUES"))


func _bench_size(w: int, h: int, nt_mt: int) -> void:
	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(w, h)
	cfg.seed = 424242
	cfg.num_continents = 2
	cfg.sea_level = 0.50
	cfg.continent_size = 0.78
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile

	var gen_t0: int = Time.get_ticks_usec()
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var gen_ms: float = float(Time.get_ticks_usec() - gen_t0) / 1000.0
	var map: MapData = generated.get("map", null) as MapData
	if map == null:
		printerr("  [FAIL] map generation returned null (n=%dx%d)" % [w, h])
		_ok = false
		return
	var n: int = map.cell_count()

	# 推进数日让 climate slot 进入稳定态（避免首日初始化分支扰动计时）。
	for day in range(1, 4):
		generator.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var ext = generator.get_data_core_world_ext()
	if ext == null or not ext.has_method("run_climate_pass_a"):
		printerr("  [SKIP] DCWorldExt not bound / methods missing (n=%d)" % n)
		return

	var sp: float = 0.30
	var pa_struct: Dictionary = generator._build_native_daily_climate_pass_a_struct(map, profile, sp)
	var pb_knobs: Dictionary = generator._build_native_daily_climate_pass_b_knobs(map, profile, sp)

	print("  ── n_cells=%s  (%dx%d, gen=%.0fms) ──" % [_commas(n), w, h, gen_ms])
	print("    %-16s %12s %10s %12s %12s" % ["config", "compute_ms", "speedup", "M_cell/s", "~GB/s"])

	# ── pass_a ────────────────────────────────────────────────────────────────
	if pa_struct.is_empty():
		print("    pass_a: [SKIP] struct builder returned empty")
	elif float(ext.run_climate_pass_a(pa_struct, sp, sp)) < 0.0:
		print("    pass_a: [SKIP] run_climate_pass_a fell back (rc<0)")
	else:
		# pass_a 内存流量估算：~17 读 + ~15 写 f32 slot ≈ 32 * 4B / cell（粗略）。
		var bytes_a: float = float(n) * 32.0 * 4.0
		var base_a: float = _best_ms(func(): ext.run_climate_pass_a(pa_struct, sp, sp))
		_report_row("pass_a scalar-1T", base_a, base_a, n, bytes_a)
		var mt_a: float = _best_ms(func(): ext.run_climate_pass_a_thread(pa_struct, sp, sp, nt_mt))
		_report_row("pass_a scalar-MT", mt_a, base_a, n, bytes_a)

	# ── pass_b ────────────────────────────────────────────────────────────────
	if pb_knobs.is_empty():
		print("    pass_b: [SKIP] knobs builder returned empty (enable_local_climate_coupling?)")
	elif float(ext.run_climate_pass_b(pb_knobs)) < 0.0:
		print("    pass_b: [SKIP] run_climate_pass_b fell back (rc<0)")
	else:
		# pass_b 内存流量估算：~12 直读写 + 6 邻居 gather × ~3 数组 ≈ (12 + 18) * 4B / cell。
		var bytes_b: float = float(n) * 30.0 * 4.0
		var base_b: float = _best_ms(func(): ext.run_climate_pass_b(pb_knobs))
		_report_row("pass_b scalar-1T", base_b, base_b, n, bytes_b)
		if ext.has_method("run_climate_pass_b_simd"):
			var simd_b: float = _best_ms(func(): ext.run_climate_pass_b_simd(pb_knobs))
			_report_row("pass_b autovec-1T", simd_b, base_b, n, bytes_b)
		if ext.has_method("run_climate_pass_b_thread"):
			var mt_b: float = _best_ms(func(): ext.run_climate_pass_b_thread(pb_knobs, nt_mt))
			_report_row("pass_b autovec-MT", mt_b, base_b, n, bytes_b)


# 墙钟最优：warmup 后取多次 min，过滤调度抖动。
func _best_ms(fn: Callable, warm: int = 4, meas: int = 16) -> float:
	for i in range(warm):
		fn.call()
	var best: float = INF
	for i in range(meas):
		var t0: int = Time.get_ticks_usec()
		fn.call()
		best = minf(best, float(Time.get_ticks_usec() - t0) / 1000.0)
	return best


func _report_row(label: String, ms: float, baseline_ms: float, n: int, bytes_est: float) -> void:
	var speedup: float = (baseline_ms / ms) if ms > 0.0 else 0.0
	var mcps: float = (float(n) / (ms / 1000.0)) / 1.0e6 if ms > 0.0 else 0.0
	var gbps: float = (bytes_est / (ms / 1000.0)) / 1.0e9 if ms > 0.0 else 0.0
	print("    %-16s %12.4f %9.2fx %12.1f %12.1f" % [label, ms, speedup, mcps, gbps])


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = false
	profile.runtime_hydrology_enabled = false
	profile.native_environment_runtime_enabled = false
	# pass_b knobs builder 要求 local climate coupling 打开。
	if profile.get("enable_local_climate_coupling") != null:
		profile.enable_local_climate_coupling = true
	return profile


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
