extends SceneTree

# NS 化四方向深化 · 气候功能探针（Phase 2/3 验证用）。
# 与 headless_perf_record.gd 同 harness（WorldRuntimeHost + WorldClock 硬屏障），
# 但输出紧凑功能 CSV 而不是性能分解：降水 p95/max/总量、雨带纬度质心、
# 水汽/云总量（SL 平流守恒观测）。ns_gates=ON|WIND 与 perf_record 同语义，
# 进程内改 earth_like.tres 读数，退出恢复，不落盘。
#
# 用法:
#   godot --headless --path Project/project-keynes -s tests/headless_ns_climate_probe.gd -- days=120 seed=20260718 label=probe_wind ns_gates=WIND

const DEFAULT_DAYS := 120
const DEFAULT_SPEED := 50.0
const DEFAULT_SEED := 20260718
const DEFAULT_MAP_WIDTH := 60
const DEFAULT_MAP_HEIGHT := 40
const MAX_BARRIER_PULSES_PER_DAY := 400


func _init() -> void:
	var exit_code := await _run()
	quit(exit_code)


func _run() -> int:
	var args := _arguments()
	var days := int(args.get("days", DEFAULT_DAYS))
	var speed := float(args.get("speed", DEFAULT_SPEED))
	var seed := int(args.get("seed", DEFAULT_SEED))
	var map_width := int(args.get("width", DEFAULT_MAP_WIDTH))
	var map_height := int(args.get("height", DEFAULT_MAP_HEIGHT))
	var label := str(args.get("label", "probe"))
	var ns_gates := str(args.get("ns_gates", "")).to_upper()
	if days <= 0 or speed <= 0.0:
		push_error("[ns-probe] bad days/speed")
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[ns-probe] DCWorldExt unavailable; rebuild and restart Godot")
		return 3

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = speed
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.set_speed(speed)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = map_width
	host.map_height = map_height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	get_root().add_child(host)
	host.configure(null, null, clock)

	var climate_profile_res: Resource = null
	var ns_prev_values: Dictionary = {}
	if ns_gates in ["ON", "WIND", "ALL", "DIV"]:
		var gate_knobs: Dictionary = {}
		if ns_gates == "DIV":
			# Phase 3 L1 隔离 A/B：只开散度阻尼，不动量、不轨迹表。
			gate_knobs["wind_div_damp_alpha"] = 0.2
		else:
			gate_knobs = {
				"wind_traj_table_enabled": true,
				"wind_traj_weather_share": true,
				"wind_momentum_advect_w": 0.3,
				"wind_momentum_diffuse_w_daily": 0.08,
				"wind_div_damp_alpha": 0.2,
			}
			if ns_gates in ["ON", "ALL"]:
				gate_knobs["ocean_topo_steer_w"] = 0.15
				gate_knobs["ocean_depth_curl_damp"] = 0.5
		climate_profile_res = ResourceLoader.load("res://data/world/earth_like.tres", "Resource")
		if climate_profile_res == null:
			push_error("[ns-probe] ns_gates requested but earth_like.tres missing")
			return 2
		for k in gate_knobs:
			ns_prev_values[k] = climate_profile_res.get(k)
			climate_profile_res.set(k, gate_knobs[k])
		print("[ns-probe] ns_gates=%s applied: %s" % [ns_gates, str(gate_knobs)])

	await host.generate_world(seed)
	var map: MapData = host.get_current_map()
	if map == null:
		push_error("[ns-probe] world generation failed")
		return 4

	var out_path := "d:/Godot/ProjectKeynes/Project.Keynes/tmp/ns_climate_probe_%s.csv" % label
	var csv := FileAccess.open(out_path, FileAccess.WRITE)
	if csv == null:
		push_error("[ns-probe] cannot open output " + out_path)
		return 5
	csv.store_line("day,season_phase,precip_mean,precip_p95,precip_max,precip_sum,rain_band_lat,vapor_sum,cloud_sum,precip_cells,div_mean_abs,div_p95,div_max,wind_speed_mean")

	var fatal := false
	for day in range(1, days + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})
		var drained := _drain_hard_barrier(clock, day)
		if not bool(drained.get("ok", false)):
			push_error("[ns-probe] hard barrier did not drain at day %d" % day)
			fatal = true
			break
		var m := _sample_day(map, day, phase)
		csv.store_line(m)

	csv.flush()
	csv.close()
	host.free()
	clock.free()
	if climate_profile_res != null:
		for k in ns_prev_values:
			climate_profile_res.set(k, ns_prev_values[k])
	await process_frame
	print("[ns-probe/result] label=%s days=%d seed=%d fatal=%s path=%s" % [
		label, days, seed, str(fatal), out_path])
	return 7 if fatal else 0


func _sample_day(map: MapData, day: int, phase: float) -> String:
	var precip: PackedFloat32Array = map.weather_precip_arr
	var vapor: PackedFloat32Array = map.weather_vapor_arr
	var cloud: PackedFloat32Array = map.weather_cloud_arr
	var lat: PackedFloat32Array = map.cell_lat_norm_arr
	var n: int = precip.size()
	if n == 0:
		return "%d,%.4f,0,0,0,0,0,0,0,0" % [day, phase]
	var sorted := precip.duplicate()
	sorted.sort()
	var sum := 0.0
	var vapor_sum := 0.0
	var cloud_sum := 0.0
	var w_lat := 0.0
	var w_sum := 0.0
	var cells_with_rain := 0
	for i in range(n):
		var p: float = precip[i]
		sum += p
		if i < vapor.size():
			vapor_sum += vapor[i]
		if i < cloud.size():
			cloud_sum += cloud[i]
		if p > 0.001:
			cells_with_rain += 1
			if i < lat.size():
				w_lat += p * lat[i]
				w_sum += p
	var p95: float = sorted[maxi(0, int(n * 0.95) - 1)]
	var band_lat: float = w_lat / w_sum if w_sum > 0.0 else 0.0
	var div := _wind_divergence_stats(map)
	return "%d,%.4f,%.6f,%.6f,%.6f,%.4f,%.5f,%.3f,%.3f,%d,%.6f,%.6f,%.6f,%.5f" % [
		day, phase, sum / n, p95, sorted[n - 1], sum, band_lat,
		vapor_sum, cloud_sum, cells_with_rain,
		div[0], div[1], div[2], div[3]]


# 风通量散度统计：fx/fy = 单位风向 × 风速；每 cell 用 6 邻居最小二乘梯度
# （与 C++ _wf_nb_dx/dy/invd 同范式的轴解耦近似），wrap 用最小映像。
# 返回 [|div| mean, |div| p95, |div| max, speed mean]。仅供 A/B 相对比较，
# 绝对量纲不与 C++ 内部 div 诊断对齐。
func _wind_divergence_stats(map: MapData) -> Array:
	var wx: PackedFloat32Array = map.wind_x_arr
	var wy: PackedFloat32Array = map.wind_y_arr
	var sp: PackedFloat32Array = map.wind_speed_arr
	var px: PackedFloat32Array = map.cell_pos_x_arr
	var py: PackedFloat32Array = map.cell_pos_y_arr
	var nb: PackedInt32Array = map.neighbor_indices_packed()
	var n: int = sp.size()
	var out := [0.0, 0.0, 0.0, 0.0]
	if n == 0 or px.size() != n or nb.size() != n * 6:
		return out
	var period_x: float = map.width * sqrt(3.0)
	var fx := PackedFloat32Array()
	var fy := PackedFloat32Array()
	fx.resize(n)
	fy.resize(n)
	var sp_sum := 0.0
	for i in range(n):
		fx[i] = wx[i] * sp[i]
		fy[i] = wy[i] * sp[i]
		sp_sum += sp[i]
	var abs_div := PackedFloat32Array()
	abs_div.resize(n)
	var div_sum := 0.0
	for i in range(n):
		var sxx := 0.0
		var syy := 0.0
		var gfx := 0.0
		var gfy := 0.0
		for d in range(6):
			var j: int = nb[i * 6 + d]
			if j < 0:
				continue
			var dx: float = px[j] - px[i]
			if period_x > 0.0:
				dx -= period_x * floor(dx / period_x + 0.5)
			var dy: float = py[j] - py[i]
			sxx += dx * dx
			syy += dy * dy
			gfx += (fx[j] - fx[i]) * dx
			gfy += (fy[j] - fy[i]) * dy
		var div := 0.0
		if sxx > 0.0:
			div += gfx / sxx
		if syy > 0.0:
			div += gfy / syy
		abs_div[i] = absf(div)
		div_sum += abs_div[i]
	var sorted := abs_div.duplicate()
	sorted.sort()
	out[0] = div_sum / n
	out[1] = sorted[maxi(0, int(n * 0.95) - 1)]
	out[2] = sorted[n - 1]
	out[3] = sp_sum / n
	return out


func _drain_hard_barrier(clock: WorldClock, day: int) -> Dictionary:
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < MAX_BARRIER_PULSES_PER_DAY:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	return {"ok": not _has_hard_barrier(clock), "pulses": pulses}


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out
