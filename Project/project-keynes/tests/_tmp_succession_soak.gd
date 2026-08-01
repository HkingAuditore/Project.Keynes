extends SceneTree

# [zonal-envelope 2026-08-01] 临时 soak 探针：生产路径跑 N 天，取证植被演替迁移率、
# SAVANNA 门限诊断（哪个 gate 卡住升级）与瞬时湿度漂移归因数据。
# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/_tmp_succession_soak.gd -- days=730 seed=20260801 width=150 height=100

const MAX_BARRIER_PULSES_PER_DAY := 4096
const WATER_TERRAINS := [0, 1, 18, 19, 20, 21]
const FOREST := [5, 7, 8, 12, 14, 15, 24, 25]
const GRASSLAND := [9, 10, 13]
const DESERT := [1, 16, 17]


func _init() -> void:
	var code := await _run()
	quit(code)


func _run() -> int:
	var args := _arguments()
	var days := int(args.get("days", 730))
	var seed := int(args.get("seed", 20260801))
	var width := int(args.get("width", 150))
	var height := int(args.get("height", 100))
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[succession-soak] DCWorldExt unavailable")
		return 3
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 50.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.set_speed(50.0)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	host.generate_test_economy_data = false
	get_root().add_child(host)
	host.configure(null, null, clock)
	var t0 := Time.get_ticks_msec()
	await host.generate_world(seed)
	var gen_ms := Time.get_ticks_msec() - t0
	var map := host.get_current_map()
	if map == null:
		push_error("[succession-soak] generation failed")
		return 4
	print("[succession-soak] generated %dx%d seed=%d gen=%dms days=%d" % [
		width, height, seed, gen_ms, days])
	_report("day0", map)
	var veg0: PackedByteArray = map.vegetation_arr.duplicate()
	var moist0: PackedFloat32Array = map.moisture_arr.duplicate()
	var csv_path := "D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_zonal_fix_%d.csv" % seed
	var csv := FileAccess.open(csv_path, FileAccess.WRITE)
	if csv != null:
		csv.store_line("cell_index,tick_idx,terrain_arr,is_water_arr,vegetation_arr,base_vegetation_arr,temp_arr,temp_365d_arr,moisture_arr,base_moisture_arr,water_balance_30d_arr,soil_moisture_arr,cell_lat_norm_arr,elevation_arr,vegetation_vitality_arr")
		_csv_rows(csv, map, 0)

	var run0 := Time.get_ticks_msec()
	for day in range(1, days + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < MAX_BARRIER_PULSES_PER_DAY:
			clock.simulation_backpressure_pulse.emit(day)
			pulses += 1
		if pulses >= MAX_BARRIER_PULSES_PER_DAY:
			push_error("[succession-soak] barrier stuck day %d" % day)
			return 5
		if day % 91 == 0 or day == days:
			_drift_sample(day, map, moist0)
	print("[succession-soak] run_ms=%d" % [Time.get_ticks_msec() - run0])
	_report("day%d" % days, map)
	if csv != null:
		_csv_rows(csv, map, days)
		csv.close()
		print("[succession-soak] csv written: %s" % csv_path)
	_diff(map, veg0, moist0, days)
	host.free()
	clock.free()
	await process_frame
	return 0


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _drift_sample(day: int, map: MapData, moist0: PackedFloat32Array) -> void:
	var all_sum := 0.0
	var all_n := 0
	var f_sum := 0.0
	var f_n := 0
	var g_sum := 0.0
	var g_n := 0
	var d_sum := 0.0
	var d_n := 0
	for i in range(map.moisture_arr.size()):
		if int(map.terrain_arr[i]) in WATER_TERRAINS:
			continue
		var dm: float = map.moisture_arr[i] - moist0[i]
		all_sum += dm
		all_n += 1
		var v := int(map.vegetation_arr[i])
		if v in FOREST:
			f_sum += dm
			f_n += 1
		elif v in GRASSLAND:
			g_sum += dm
			g_n += 1
		elif v in DESERT:
			d_sum += dm
			d_n += 1
	print("[drift] day=%4d all=%+.4f forest=%+.4f grass=%+.4f desert=%+.4f" % [
		day, all_sum / maxf(1.0, all_n), f_sum / maxf(1.0, f_n),
		g_sum / maxf(1.0, g_n), d_sum / maxf(1.0, d_n)])


func _band(map: MapData, i: int) -> int:
	var eqd: float = absf(map.cell_lat_norm_arr[i] * 2.0 - 1.0) if i < map.cell_lat_norm_arr.size() else 1.0
	return 0 if eqd < 0.2 else (1 if eqd < 0.45 else (2 if eqd < 0.7 else 3))


func _report(tag: String, map: MapData) -> void:
	var land := 0
	var forest := 0
	var grass := 0
	var desert := 0
	var moist_sum := 0.0
	var sav := 0
	var sav_vit := 0.0
	var sav_compat := 0.0
	var sav_next := 0.0
	# 门限诊断计数（SAVANNA 升级 TROPICAL_DRY_FOREST 的四道 gate）
	var g_gain := 0   # next_score >= compat + 0.06
	var g_high := 0   # next_score >= 0.75
	var g_vit := 0    # vit > 0.30
	var g_all := 0
	for i in range(map.vegetation_arr.size()):
		if int(map.terrain_arr[i]) in WATER_TERRAINS:
			continue
		land += 1
		moist_sum += map.moisture_arr[i]
		var v := int(map.vegetation_arr[i])
		if v in FOREST:
			forest += 1
		elif v in GRASSLAND:
			grass += 1
		elif v in DESERT:
			desert += 1
		if v == VegetationType.VEG.SAVANNA:
			sav += 1
			var t: float = map.temp_30d_arr[i] if i < map.temp_30d_arr.size() else map.temp_arr[i]
			var pw: float = map.plant_available_water_arr[i] if i < map.plant_available_water_arr.size() else map.moisture_arr[i]
			var vit: float = map.vegetation_vitality_arr[i] if i < map.vegetation_vitality_arr.size() else 0.0
			var compat := VegetationType.climate_compat_score(VegetationType.VEG.SAVANNA, t, pw)
			var nxt := VegetationType.climate_compat_score(VegetationType.VEG.TROPICAL_DRY_FOREST, t, pw)
			sav_vit += vit
			sav_compat += compat
			sav_next += nxt
			var ok_gain: bool = nxt >= compat + 0.06
			var ok_high: bool = nxt >= 0.75
			var ok_vit: bool = vit > 0.30 and compat > 0.30
			if ok_gain: g_gain += 1
			if ok_high: g_high += 1
			if ok_vit: g_vit += 1
			if ok_gain and ok_high and ok_vit: g_all += 1
	print("[%s] land=%d forest=%.1f%% grass=%.1f%% desert=%.1f%% moist_mean=%.3f" % [
		tag, land, 100.0 * forest / land, 100.0 * grass / land,
		100.0 * desert / land, moist_sum / maxf(1.0, land)])
	print("[%s] savanna=%d vit=%.3f compat=%.3f next_dryforest=%.3f | gates gain=%.1f%% high=%.1f%% vit=%.1f%% all=%.1f%%" % [
		tag, sav, sav_vit / maxf(1.0, sav), sav_compat / maxf(1.0, sav), sav_next / maxf(1.0, sav),
		100.0 * g_gain / maxf(1.0, sav), 100.0 * g_high / maxf(1.0, sav),
		100.0 * g_vit / maxf(1.0, sav), 100.0 * g_all / maxf(1.0, sav)])


func _diff(map: MapData, veg0: PackedByteArray, moist0: PackedFloat32Array, days: int) -> void:
	var pairs := {}
	var band_moved := [0, 0, 0, 0]
	var band_land := [0, 0, 0, 0]
	var moved := 0
	var land := 0
	var dm_sum := 0.0
	var dm_abs := 0.0
	var band_names := ["eq", "subtrop", "midlat", "polar"]
	for i in range(map.vegetation_arr.size()):
		if int(map.terrain_arr[i]) in WATER_TERRAINS:
			continue
		land += 1
		var b := _band(map, i)
		band_land[b] += 1
		dm_sum += map.moisture_arr[i] - moist0[i]
		dm_abs += absf(map.moisture_arr[i] - moist0[i])
		if int(map.vegetation_arr[i]) != int(veg0[i]):
			moved += 1
			band_moved[b] += 1
			var key := "%d>%d" % [int(veg0[i]), int(map.vegetation_arr[i])]
			pairs[key] = int(pairs.get(key, 0)) + 1
	print("[diff] days=%d moved=%d/%d (%.2f%% land) moist_drift_mean=%.4f moist_abs_mean=%.4f" % [
		days, moved, land, 100.0 * moved / maxf(1.0, land),
		dm_sum / maxf(1.0, land), dm_abs / maxf(1.0, land)])
	for b in range(4):
		print("[diff] band %-7s moved=%d/%d (%.2f%%)" % [
			band_names[b], band_moved[b], band_land[b],
			100.0 * band_moved[b] / maxf(1.0, band_land[b])])
	var sorted_keys := pairs.keys()
	sorted_keys.sort_custom(func(a, b): return int(pairs[a]) > int(pairs[b]))
	var shown := 0
	for k in sorted_keys:
		if shown >= 12:
			break
		print("[diff] veg %s : %d cells" % [k, int(pairs[k])])
		shown += 1


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out


func _csv_rows(csv: FileAccess, map: MapData, tick: int) -> void:
	var n: int = map.terrain_arr.size()
	for i in range(n):
		var water := 1 if int(map.terrain_arr[i]) in WATER_TERRAINS else 0
		csv.store_line("%d,%d,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
			i, tick, int(map.terrain_arr[i]), water,
			int(map.vegetation_arr[i]),
			int(map.base_vegetation_arr[i]) if i < map.base_vegetation_arr.size() else int(map.vegetation_arr[i]),
			map.temp_arr[i] if i < map.temp_arr.size() else 0.0,
			map.temp_365d_arr[i] if i < map.temp_365d_arr.size() else 0.0,
			map.moisture_arr[i] if i < map.moisture_arr.size() else 0.0,
			map.base_moisture_arr[i] if i < map.base_moisture_arr.size() else 0.0,
			map.water_balance_30d_arr[i] if i < map.water_balance_30d_arr.size() else 0.0,
			map.soil_moisture_arr[i] if i < map.soil_moisture_arr.size() else 0.0,
			map.cell_lat_norm_arr[i] if i < map.cell_lat_norm_arr.size() else 0.0,
			map.elevation_arr[i] if i < map.elevation_arr.size() else 0.0,
			map.vegetation_vitality_arr[i] if i < map.vegetation_vitality_arr.size() else 0.0,
		])
