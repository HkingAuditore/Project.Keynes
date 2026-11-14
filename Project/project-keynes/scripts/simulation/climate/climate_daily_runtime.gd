extends RefCounted

## ClimateDailySystem runtime helpers. The host owns all mutable state.

func _get_soak_dump_instance(host):
	if host._soak_dump_script == null:
		if not ResourceLoader.exists(host._SOAK_DUMP_SCRIPT_PATH):
			return null
		host._soak_dump_script = load(host._SOAK_DUMP_SCRIPT_PATH) as GDScript
	if host._soak_dump_script == null:
		return null
	return host._soak_dump_script.instance


# Sub-pass 编号常量（保持与 _PASS_NAMES 索引对齐，便于日志可读）

func _should_sync_runtime_terrain_views(host, reason: String) -> bool:
	if reason != "round_start":
		return true
	var cp = host.generator._c() if host.generator != null else null
	if not host._round_start_terrain_sync_bootstrap_done:
		host._round_start_terrain_sync_bootstrap_done = true
		return true
	if cp != null and cp.get("climate_round_start_terrain_sync_enabled") != null:
		return bool(cp.climate_round_start_terrain_sync_enabled)
	return host._diagnostics_enabled()


func _sync_runtime_terrain_views_for_reason(host, reason: String) -> Dictionary:
	if host._should_sync_runtime_terrain_views(reason):
		return host._sync_runtime_terrain_views(reason)
	return {
		"reason": reason,
		"skipped": true,
		"skip_reason": "round_start_terrain_sync_disabled",
	}


func _standalone_sea_ice_enabled(host) -> bool:
	var cp = host.generator._c() if host.generator != null else null
	return cp != null \
			and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled)


func _sync_runtime_terrain_views(host, reason: String) -> Dictionary:
	var diag: Dictionary = {}
	if host.map == null or not host.map.has_soa():
		return diag
	var n: int = mini(host.map.cell_count(), host.map.terrain_arr.size())
	if n <= 0:
		return diag
	var samples: PackedStringArray = PackedStringArray()
	var cell_terrain_mismatch: int = 0
	for i in range(n):
		var cell: HexCell = host.map.cell_at(i)
		if cell == null:
			continue
		var soa_terrain: int = int(host.map.terrain_arr[i]) & 0xFF
		if int(cell.terrain) != soa_terrain:
			cell_terrain_mismatch += 1
			if samples.size() < 3:
				samples.append("idx=%d q=%s r=%s cell=%d soa=%d" % [
					i, str(cell.q), str(cell.r), int(cell.terrain), soa_terrain
				])
	var facade_fixed: int = 0
	if host.map.has_method("sync_runtime_terrain_facade_from_soa"):
		facade_fixed = int(host.map.sync_runtime_terrain_facade_from_soa())

	var dc_terrain_mismatch_observed: int = 0
	var dc_iswater_mismatch_observed: int = 0
	if host._world != null and host._world.is_bound() and host._world.has_method("view_u8"):
		var cid_terrain: int = int(host._cid.get(DCComponentIds.CELL_TERRAIN, -1))
		if cid_terrain >= 0:
			var dc_terrain: PackedByteArray = host._world.view_u8(cid_terrain)
			for i in range(mini(n, mini(dc_terrain.size(), host.map.terrain_arr.size()))):
				if int(dc_terrain[i]) != int(host.map.terrain_arr[i]):
					dc_terrain_mismatch_observed += 1
		var cid_iswater: int = int(host._cid.get(DCComponentIds.CELL_IS_WATER, -1))
		if cid_iswater >= 0:
			var dc_iswater: PackedByteArray = host._world.view_u8(cid_iswater)
			for i in range(mini(n, mini(dc_iswater.size(), host.map.is_water_arr.size()))):
				if int(dc_iswater[i]) != int(host.map.is_water_arr[i]):
					dc_iswater_mismatch_observed += 1

	if cell_terrain_mismatch <= 0 and facade_fixed <= 0 \
			and dc_terrain_mismatch_observed <= 0 and dc_iswater_mismatch_observed <= 0:
		return diag

	diag = {
		"reason": reason,
		"cell_terr_mis_before": cell_terrain_mismatch,
		"facade_fixed": facade_fixed,
		"dc_terr_mis_observed": dc_terrain_mismatch_observed,
		"dc_isw_mis_observed": dc_iswater_mismatch_observed,
	}
	if host._diagnostics_enabled() or host._climate_terrain_view_sync_log_count < host._CLIMATE_TERRAIN_VIEW_SYNC_INITIAL_LOGS:
		host._climate_terrain_view_sync_log_count += 1
		var sample_text: String = ""
		if samples.size() > 0:
			sample_text = " samples=%s" % " | ".join(samples)
		print("[climate/terrain_sync] reason=%s phase=%.3f cell_terr_mis_before=%d facade_fixed=%d dc_terr_mis_observed=%d dc_isw_mis_observed=%d%s" % [
			reason, host._phase_locked, cell_terrain_mismatch, facade_fixed,
			dc_terrain_mismatch_observed, dc_iswater_mismatch_observed, sample_text,
		])
	return diag


static func _percentile_from_sorted(values, p: float) -> float:
	if values.is_empty():
		return 0.0
	var idx: int = clampi(int(floor(float(values.size() - 1) * clampf(p, 0.0, 1.0))), 0, values.size() - 1)
	return float(values[idx])


func _calendar_days_per_year(host) -> int:
	if host.generator != null and host.generator.has_method("_calendar_days_per_year"):
		return clampi(int(host.generator._calendar_days_per_year()), 1, 3660)
	return 365


func _is_annual_log_tick(host, counter: int) -> bool:
	var dpy: int = host._calendar_days_per_year()
	return counter == 1 or (counter > 0 and (counter % dpy) == 0)


# Stage 9 / Fix #11 (2026-06-16)：C++ worker 已跑 finalizer 时，把 poll_result 里
# fin_* 字段 平移到 GDScript 期望的 diag schema。返回字段必须 1:1 兼容
# _apply_daily_climate_finalizer() 的 return shape（main.gd / generator 解析这些字段）。
# 与 sync GDScript path 的区别：finalizer_total_ms / finalizer_cell_ms 用 worker 算的
# 整个 finalizer_us（一个数表示整个 kernel wall time），不细分。temperature/tta cell
# mirror 字段恒 false（C++ worker 不能碰 HexCell；GDScript facade 启用时 cell.temperature
# getter 直接走 SoA，所以 worker 写 slot 即等价）。

static func _build_finalizer_diag_from_worker(poll: Dictionary) -> Dictionary:
	var fin_us: float = float(poll.get("finalizer_us", 0))
	var fin_ms: float = fin_us / 1000.0
	return {
		"max_temp_delta":              float(poll.get("fin_max_temp_delta", 0.0)),
		"p95_temp_delta":              float(poll.get("fin_p95_temp_delta", 0.0)),
		"p99_temp_delta":              float(poll.get("fin_p99_temp_delta", 0.0)),
		"preclamp_max_temp_delta":     float(poll.get("fin_preclamp_max_temp_delta", 0.0)),
		"preclamp_p99_temp_delta":     float(poll.get("fin_preclamp_p99_temp_delta", 0.0)),
		"temp_delta_gt_005_count":     int(poll.get("fin_temp_delta_gt_005_count", 0)),
		"temp_delta_gt_010_count":     int(poll.get("fin_temp_delta_gt_010_count", 0)),
		"temp_delta_gt_020_count":     int(poll.get("fin_temp_delta_gt_020_count", 0)),
		"temp_delta_clamped_count":    int(poll.get("fin_temp_delta_clamped_count", 0)),
		"max_transport_anomaly":       float(poll.get("fin_max_transport_anomaly", 0.0)),
		"sea_ice_delta_max":           float(poll.get("fin_sea_ice_delta_max", 0.0)),
		"precip_p95":                  float(poll.get("fin_precip_p95", 0.0)),
		"thermal_finalizer_applied":   true,
		"finalizer_total_ms":          fin_ms,
		"finalizer_cell_ms":           fin_ms,  # worker kernel 不细分
		"finalizer_temp_ms":           0.0,
		"finalizer_tta_ms":            0.0,
		"finalizer_thermal_ms":        0.0,
		"finalizer_sort_ms":           0.0,
		"finalizer_sea_ice_ms":        0.0,
		"finalizer_precip_ms":         0.0,
		"finalizer_write_dense_ms":    0.0,  # worker 已 publish slot；main thread 不再 write_f32_dense
		"finalizer_cells_seen":        int(poll.get("fin_cells_seen", 0)),
		"finalizer_temperature_cell_mirror": false,
		"finalizer_tta_cell_mirror":         false,
		"finalizer_tta_cell_mirror_count":   0,
		"finalizer_tta_clamped_count":       int(poll.get("fin_tta_clamped_count", 0)),
		"finalizer_thermal_init_count":      int(poll.get("fin_thermal_init_count", 0)),
	}


func _async_finalizer_fallback_reason(host, poll: Dictionary) -> String:
	if poll.is_empty():
		return "sync_path_no_worker"
	if not poll.has("fin_applied"):
		return "missing_fin_applied"
	if bool(poll.get("fin_applied", false)):
		return ""
	var n_cells: int = int(poll.get("n_cells", host.map.cell_count() if host.map != null else 0))
	if n_cells <= 0:
		return "missing_sizes:n_cells"
	if host._temp_start_of_day_arr.size() != n_cells:
		return "missing_sizes:temp_start"
	if host._tta_start_of_day_arr.size() != n_cells:
		return "missing_sizes:tta_start"
	if host.map == null or host.map.temp_arr.size() != n_cells \
			or host.map.temperature_transport_anomaly_arr.size() != n_cells \
			or host.map.thermal_energy_arr.size() != n_cells:
		return "missing_sizes:map_arrays"
	return "fin_applied_false"


func _apply_daily_climate_finalizer(host) -> Dictionary:
	var t_total_us: int = Time.get_ticks_usec()
	var diag: Dictionary = {
		"max_temp_delta": 0.0,
		"p95_temp_delta": 0.0,
		"p99_temp_delta": 0.0,
		"preclamp_max_temp_delta": 0.0,
		"preclamp_p99_temp_delta": 0.0,
		"temp_delta_gt_005_count": 0,
		"temp_delta_gt_010_count": 0,
		"temp_delta_gt_020_count": 0,
		"temp_delta_clamped_count": 0,
		"max_transport_anomaly": 0.0,
		"sea_ice_delta_max": 0.0,
		"precip_p95": 0.0,
		"thermal_finalizer_applied": false,
		"finalizer_total_ms": 0.0,
		"finalizer_cell_ms": 0.0,
		"finalizer_temp_ms": 0.0,
		"finalizer_tta_ms": 0.0,
		"finalizer_thermal_ms": 0.0,
		"finalizer_sort_ms": 0.0,
		"finalizer_sea_ice_ms": 0.0,
		"finalizer_precip_ms": 0.0,
		"finalizer_write_dense_ms": 0.0,
		"finalizer_cells_seen": 0,
		"finalizer_temperature_cell_mirror": false,
		"finalizer_tta_cell_mirror": false,
		"finalizer_tta_cell_mirror_count": 0,
		"finalizer_tta_clamped_count": 0,
		"finalizer_thermal_init_count": 0,
	}
	if host.generator == null or host.map == null:
		host._last_finalizer_diag = diag
		return diag
	var cp = host.generator._c()
	var n: int = host.map.cell_count()
	if cp == null or n <= 0:
		host._last_finalizer_diag = diag
		return diag
	var temp_cap_enabled: bool = true
	if cp.get("thermal_final_delta_cap_enabled") != null:
		temp_cap_enabled = bool(cp.thermal_final_delta_cap_enabled)
	var temp_cap: float = float(cp.thermal_daily_delta_cap) if cp.get("thermal_daily_delta_cap") != null else 0.15
	var tta_cap: float = float(cp.temperature_transport_anomaly_daily_cap) if cp.get("temperature_transport_anomaly_daily_cap") != null else 0.12
	var temp_a: PackedFloat32Array = host.map.temp_arr
	var tta_a: PackedFloat32Array = host.map.temperature_transport_anomaly_arr
	var mirror_temperature_cells: bool = true
	if host.map.has_indices() and n > 0:
		var probe_cell: HexCell = host.map.cell_at(0)
		mirror_temperature_cells = probe_cell == null or not probe_cell.is_facade_enabled()
	diag["finalizer_temperature_cell_mirror"] = mirror_temperature_cells
	var mirror_tta_cells: bool = mirror_temperature_cells
	diag["finalizer_tta_cell_mirror"] = mirror_tta_cells
	var cells: Array = []
	if mirror_temperature_cells or mirror_tta_cells:
		cells = host.map.iter_cells() if host.map.has_indices() else host.map.all_cells()
	var has_temp_start: bool = host._temp_start_of_day_arr.size() == n
	var has_tta_start: bool = host._tta_start_of_day_arr.size() == n
	var t_cells_us: int = Time.get_ticks_usec()
	var t_part_us: int = t_cells_us
	var temp_limit: int = mini(n, temp_a.size())
	var temp_deltas: PackedFloat32Array = PackedFloat32Array()
	var preclamp_temp_deltas: PackedFloat32Array = PackedFloat32Array()
	temp_deltas.resize(temp_limit)
	preclamp_temp_deltas.resize(temp_limit)
	var max_temp_delta: float = 0.0
	var preclamp_max_temp_delta: float = 0.0
	var temp_delta_gt_005_count: int = 0
	var temp_delta_gt_010_count: int = 0
	var temp_delta_gt_020_count: int = 0
	var temp_delta_clamped_count: int = 0
	for i in range(temp_limit):
		var start_t: float = host._temp_start_of_day_arr[i] if has_temp_start else temp_a[i]
		var raw_final_t: float = temp_a[i]
		var final_t: float = raw_final_t
		var pre_abs_dt: float = absf(raw_final_t - start_t)
		preclamp_temp_deltas[i] = pre_abs_dt
		if pre_abs_dt > preclamp_max_temp_delta:
			preclamp_max_temp_delta = pre_abs_dt
		if temp_cap_enabled and has_temp_start:
			final_t = clampf(final_t, start_t - temp_cap, start_t + temp_cap)
			final_t = clampf(final_t, 0.0, 1.0)
			if absf(final_t - raw_final_t) > 0.000001:
				temp_delta_clamped_count += 1
			temp_a[i] = final_t
		var abs_dt: float = absf(final_t - start_t)
		temp_deltas[i] = abs_dt
		if abs_dt > 0.005:
			temp_delta_gt_005_count += 1
		if abs_dt > 0.010:
			temp_delta_gt_010_count += 1
		if abs_dt > 0.020:
			temp_delta_gt_020_count += 1
		if abs_dt > max_temp_delta:
			max_temp_delta = abs_dt
		if mirror_temperature_cells and i < cells.size() and cells[i] != null:
			cells[i].temperature = final_t
	diag["max_temp_delta"] = max_temp_delta
	diag["preclamp_max_temp_delta"] = preclamp_max_temp_delta
	diag["temp_delta_gt_005_count"] = temp_delta_gt_005_count
	diag["temp_delta_gt_010_count"] = temp_delta_gt_010_count
	diag["temp_delta_gt_020_count"] = temp_delta_gt_020_count
	diag["temp_delta_clamped_count"] = temp_delta_clamped_count
	diag["finalizer_temp_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	t_part_us = Time.get_ticks_usec()
	var tta_limit: int = mini(n, tta_a.size())
	var max_transport_anomaly: float = 0.0
	var finalizer_tta_clamped_count: int = 0
	var finalizer_tta_cell_mirror_count: int = 0
	for i in range(tta_limit):
		var start_tta: float = host._tta_start_of_day_arr[i] if has_tta_start else 0.0
		var raw_final_tta: float = tta_a[i]
		var final_tta: float = raw_final_tta
		var tta_clamped: bool = false
		if tta_cap > 0.0 and has_tta_start:
			final_tta = clampf(final_tta, start_tta - tta_cap, start_tta + tta_cap)
			if absf(final_tta - raw_final_tta) > 0.000001:
				tta_a[i] = final_tta
				tta_clamped = true
				finalizer_tta_clamped_count += 1
		var abs_tta: float = absf(final_tta)
		if abs_tta > max_transport_anomaly:
			max_transport_anomaly = abs_tta
		if mirror_tta_cells and tta_clamped and i < cells.size() and cells[i] != null:
			cells[i].temperature_transport_anomaly = final_tta
			finalizer_tta_cell_mirror_count += 1
	diag["max_transport_anomaly"] = max_transport_anomaly
	diag["finalizer_tta_clamped_count"] = finalizer_tta_clamped_count
	diag["finalizer_tta_cell_mirror_count"] = finalizer_tta_cell_mirror_count
	diag["finalizer_tta_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	t_part_us = Time.get_ticks_usec()
	var thermal_a: PackedFloat32Array = host.map.thermal_energy_arr
	var ema_a: PackedByteArray = host.map.ema_initialized_arr
	var thermal_limit: int = mini(n, thermal_a.size())
	var finalizer_thermal_init_count: int = 0
	for i in range(thermal_limit):
		var needs_init: bool = is_nan(thermal_a[i]) or is_inf(thermal_a[i])
		if i < ema_a.size() and ema_a[i] == 0:
			needs_init = true
		if needs_init and i < temp_a.size():
			thermal_a[i] = temp_a[i]
			finalizer_thermal_init_count += 1
	diag["finalizer_thermal_init_count"] = finalizer_thermal_init_count
	diag["finalizer_thermal_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	diag["finalizer_cell_ms"] = float(Time.get_ticks_usec() - t_cells_us) / 1000.0
	diag["finalizer_cells_seen"] = n
	var t_sort_us: int = Time.get_ticks_usec()
	temp_deltas.sort()
	preclamp_temp_deltas.sort()
	diag["p95_temp_delta"] = host._percentile_from_sorted(temp_deltas, 0.95)
	diag["p99_temp_delta"] = host._percentile_from_sorted(temp_deltas, 0.99)
	diag["preclamp_p99_temp_delta"] = host._percentile_from_sorted(preclamp_temp_deltas, 0.99)
	diag["finalizer_sort_ms"] = float(Time.get_ticks_usec() - t_sort_us) / 1000.0
	var t_sea_ice_us: int = Time.get_ticks_usec()
	if host.map.sea_ice_frac_arr.size() == n and host.map.sea_ice_frac_arr_prev.size() == n:
		for i in range(n):
			var ds: float = absf(host.map.sea_ice_frac_arr[i] - host.map.sea_ice_frac_arr_prev[i])
			if ds > float(diag["sea_ice_delta_max"]):
				diag["sea_ice_delta_max"] = ds
	diag["finalizer_sea_ice_ms"] = float(Time.get_ticks_usec() - t_sea_ice_us) / 1000.0
	var t_precip_us: int = Time.get_ticks_usec()
	if host.map.weather_precip_arr.size() == n:
		var precip_vals: PackedFloat32Array = host.map.weather_precip_arr.duplicate()
		precip_vals.sort()
		diag["precip_p95"] = host._percentile_from_sorted(precip_vals, 0.95)
	diag["finalizer_precip_ms"] = float(Time.get_ticks_usec() - t_precip_us) / 1000.0
	if host._world != null and host._world.is_bound():
		var t_write_us: int = Time.get_ticks_usec()
		var cid_temp: int = int(host._cid.get(DCComponentIds.CELL_TEMP, -1))
		if cid_temp >= 0 and host._world.has_method("write_f32_dense"):
			host._world.write_f32_dense(cid_temp, temp_a)
		var cid_tta: int = int(host._cid.get(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY, -1))
		if cid_tta >= 0 and host._world.has_method("write_f32_dense"):
			host._world.write_f32_dense(cid_tta, tta_a)
		var cid_heat: int = int(host._cid.get(DCComponentIds.CELL_THERMAL_ENERGY, -1))
		if cid_heat >= 0 and host._world.has_method("write_f32_dense"):
			host._world.write_f32_dense(cid_heat, thermal_a)
		diag["finalizer_write_dense_ms"] = float(Time.get_ticks_usec() - t_write_us) / 1000.0
	diag["thermal_finalizer_applied"] = true
	diag["finalizer_total_ms"] = float(Time.get_ticks_usec() - t_total_us) / 1000.0
	host._last_finalizer_diag = diag
	return diag


static func _climate_diag_terrain_water(t: int) -> bool:
	return t == int(TerrainType.TERRAIN.OCEAN) \
			or t == int(TerrainType.TERRAIN.COAST) \
			or t == int(TerrainType.TERRAIN.LAKE) \
			or t == int(TerrainType.TERRAIN.REEF) \
			or t == int(TerrainType.TERRAIN.KELP) \
			or t == int(TerrainType.TERRAIN.SEA_ICE)


static func _climate_diag_ocean_water(t: int) -> bool:
	return t == int(TerrainType.TERRAIN.OCEAN) \
			or t == int(TerrainType.TERRAIN.COAST) \
			or t == int(TerrainType.TERRAIN.REEF) \
			or t == int(TerrainType.TERRAIN.KELP)


func _climate_diag_corr(host, a: PackedFloat32Array, b: PackedFloat32Array, limit: int) -> float:
	var n: int = mini(limit, mini(a.size(), b.size()))
	if n <= 1:
		return 0.0
	var sum_a: float = 0.0
	var sum_b: float = 0.0
	var sum_ab: float = 0.0
	var sum_aa: float = 0.0
	var sum_bb: float = 0.0
	for i in range(n):
		var av: float = a[i]
		var bv: float = b[i]
		sum_a += av
		sum_b += bv
		sum_ab += av * bv
		sum_aa += av * av
		sum_bb += bv * bv
	var nf: float = float(n)
	var den_a: float = nf * sum_aa - sum_a * sum_a
	var den_b: float = nf * sum_bb - sum_b * sum_b
	if den_a <= host._CLIMATE_INTEGRITY_EPS or den_b <= host._CLIMATE_INTEGRITY_EPS:
		return 0.0
	return (nf * sum_ab - sum_a * sum_b) / sqrt(den_a * den_b)


func _climate_diag_p95(host, arr: PackedFloat32Array, limit: int) -> float:
	var n: int = mini(limit, arr.size())
	if n <= 0:
		return 0.0
	var vals: Array = []
	vals.resize(n)
	for i in range(n):
		vals[i] = float(arr[i])
	vals.sort()
	return host._percentile_from_sorted(vals, 0.95)


static func _climate_diag_push_sample(samples: PackedStringArray, text: String) -> void:
	if samples.size() < 6:
		samples.append(text)


func _debug_climate_integrity(host, stage_name: String, force: bool = false) -> void:
	# 移动端硬短路：诊断在 ARM 上跑 2400 cell × 17 PackedArray read × 8 pass / tick
	# ≈ 6ms 纯 GDScript 开销，吃掉 refresh_climate_daily 80% 的 SUS budget。无论
	# ClimateProfile.climate_pass_diagnostics_enabled 是不是被误设为 true，这里
	# 都不跑——避免移动端误开诊断后 fps 直接塌。force=true 也不破例。
	if OS.has_feature("mobile"):
		return
	if not host._diagnostics_enabled():
		return
	if host.map == null or not host.map.has_soa():
		return
	var n: int = host.map.cell_count()
	if n <= 0:
		return
	var now_msec: int = Time.get_ticks_msec()
	if not force \
			and host._climate_integrity_log_count >= host._CLIMATE_INTEGRITY_INITIAL_LOGS \
			and now_msec - host._climate_integrity_last_msec < host._CLIMATE_INTEGRITY_MIN_INTERVAL_MSEC:
		return
	host._climate_integrity_last_msec = now_msec

	var terrain_a: PackedByteArray = host.map.terrain_arr
	var base_terrain_a: PackedByteArray = host.map.base_terrain_arr
	var is_water_a: PackedByteArray = host.map.is_water_arr
	var temp_a: PackedFloat32Array = host.map.temp_arr
	var moisture_a: PackedFloat32Array = host.map.moisture_arr
	var base_moisture_a: PackedFloat32Array = host.map.base_moisture_arr
	var air_a: PackedFloat32Array = host.map.air_mass_temp_anomaly_arr
	var tta_a: PackedFloat32Array = host.map.temperature_transport_anomaly_arr
	var wind_x_a: PackedFloat32Array = host.map.wind_x_arr
	var wind_y_a: PackedFloat32Array = host.map.wind_y_arr
	var wind_speed_a: PackedFloat32Array = host.map.wind_speed_arr
	var ocean_x_a: PackedFloat32Array = host.map.ocean_current_x_arr
	var ocean_y_a: PackedFloat32Array = host.map.ocean_current_y_arr
	var sea_ice_a: PackedFloat32Array = host.map.sea_ice_frac_arr
	var precip_a: PackedFloat32Array = host.map.weather_precip_arr
	var vapor_a: PackedFloat32Array = host.map.weather_vapor_arr
	var cloud_a: PackedFloat32Array = host.map.weather_cloud_arr
	var instability_a: PackedFloat32Array = host.map.weather_instability_arr
	var lat_a: PackedFloat32Array = host.map.cell_lat_norm_arr
	var elev_a: PackedFloat32Array = host.map.elevation_arr
	var nb_a: PackedInt32Array = host.map.neighbor_indices_packed() if host.map.has_indices() else PackedInt32Array()
	var water_lut: PackedByteArray = MapData.is_water_lut()

	var terrain_iswater_mismatch: int = 0
	var terrain_lut_mismatch: int = 0
	var cell_terrain_mismatch: int = 0
	var cell_passable_mismatch: int = 0
	var cell_iswater_mismatch: int = 0
	var ocean_water_zero_current: int = 0
	var non_ocean_nonzero_current: int = 0
	var samples: PackedStringArray = PackedStringArray()
	for i in range(n):
		var t: int = int(terrain_a[i]) if i < terrain_a.size() else -1
		var terrain_water: bool = MapData.terrain_is_water(t)
		var ocean_water: bool = host._climate_diag_ocean_water(t)
		var iw_arr: int = int(is_water_a[i]) if i < is_water_a.size() else -1
		var lut_water: int = int(water_lut[t]) if t >= 0 and t < water_lut.size() else -1
		if iw_arr >= 0 and iw_arr != (1 if terrain_water else 0):
			terrain_iswater_mismatch += 1
			if terrain_iswater_mismatch <= 3:
				var c_m: HexCell = host.map.cell_at(i)
				host._climate_diag_push_sample(samples, "idx=%d q=%s r=%s terr=%d terrWater=%s isw=%d temp=%.3f oc=(%.3f,%.3f)" % [
					i,
					str(c_m.q) if c_m != null else "?",
					str(c_m.r) if c_m != null else "?",
					t, str(terrain_water), iw_arr,
					temp_a[i] if i < temp_a.size() else -1.0,
					ocean_x_a[i] if i < ocean_x_a.size() else 0.0,
					ocean_y_a[i] if i < ocean_y_a.size() else 0.0,
				])
		if iw_arr >= 0 and lut_water >= 0 and iw_arr != lut_water:
			terrain_lut_mismatch += 1
		var c: HexCell = host.map.cell_at(i)
		if c != null:
			var cell_terrain_water: bool = MapData.terrain_is_water(int(c.terrain))
			if int(c.terrain) != t:
				cell_terrain_mismatch += 1
				if cell_terrain_mismatch <= 3:
					host._climate_diag_push_sample(samples, "cellTerrMismatch idx=%d q=%s r=%s cellTerr=%d soaTerr=%d cellBase=%d soaBase=%d isw=%d seaIce=%.3f temp=%.3f" % [
						i,
						str(c.q),
						str(c.r),
						int(c.terrain),
						t,
						int(c.base_terrain),
						int(base_terrain_a[i]) if i < base_terrain_a.size() else -1,
						iw_arr,
						sea_ice_a[i] if i < sea_ice_a.size() else -1.0,
						temp_a[i] if i < temp_a.size() else -1.0,
					])
			if cell_terrain_water != terrain_water:
				cell_passable_mismatch += 1
			if iw_arr >= 0 and iw_arr != (1 if cell_terrain_water else 0):
				cell_iswater_mismatch += 1
		var ocx: float = ocean_x_a[i] if i < ocean_x_a.size() else 0.0
		var ocy: float = ocean_y_a[i] if i < ocean_y_a.size() else 0.0
		var oc_mag: float = sqrt(ocx * ocx + ocy * ocy)
		if ocean_water and oc_mag <= 0.001:
			ocean_water_zero_current += 1
		elif not ocean_water and oc_mag > 0.001:
			non_ocean_nonzero_current += 1

	var dc_terrain_mismatch: int = 0
	var dc_iswater_mismatch: int = 0
	if host._world != null and host._world.is_bound() and host._world.has_method("view_u8"):
		var cid_terrain: int = int(host._cid.get(DCComponentIds.CELL_TERRAIN, -1))
		if cid_terrain >= 0:
			var dc_terrain: PackedByteArray = host._world.view_u8(cid_terrain)
			for i in range(mini(n, mini(dc_terrain.size(), terrain_a.size()))):
				if int(dc_terrain[i]) != int(terrain_a[i]):
					dc_terrain_mismatch += 1
		var cid_iswater: int = int(host._cid.get(DCComponentIds.CELL_IS_WATER, -1))
		if cid_iswater >= 0:
			var dc_iswater: PackedByteArray = host._world.view_u8(cid_iswater)
			for i in range(mini(n, mini(dc_iswater.size(), is_water_a.size()))):
				if int(dc_iswater[i]) != int(is_water_a[i]):
					dc_iswater_mismatch += 1

	var temp_edge_max: float = 0.0
	var temp_edge_warn: int = 0
	var temp_edge_sample: String = ""
	var edge_vals: Array = []
	if temp_a.size() >= n and nb_a.size() >= n * 6:
		for i in range(n):
			for d in range(6):
				var ni: int = int(nb_a[i * 6 + d])
				if ni <= i or ni >= n:
					continue
				var dt_edge: float = absf(temp_a[i] - temp_a[ni])
				edge_vals.append(dt_edge)
				if dt_edge > host._CLIMATE_INTEGRITY_TEMP_EDGE_WARN:
					temp_edge_warn += 1
				if dt_edge > temp_edge_max:
					temp_edge_max = dt_edge
					var ci: HexCell = host.map.cell_at(i)
					var cn: HexCell = host.map.cell_at(ni)
					var ox_i: float = ocean_x_a[i] if i < ocean_x_a.size() else 0.0
					var oy_i: float = ocean_y_a[i] if i < ocean_y_a.size() else 0.0
					var ox_n: float = ocean_x_a[ni] if ni < ocean_x_a.size() else 0.0
					var oy_n: float = ocean_y_a[ni] if ni < ocean_y_a.size() else 0.0
					temp_edge_sample = "%d(%s,%s,t%d,iw%d,e%.3f,T%.3f,bm%.3f,si%.3f,tta%.3f,om%.3f)->%d(%s,%s,t%d,iw%d,e%.3f,T%.3f,bm%.3f,si%.3f,tta%.3f,om%.3f)" % [
						i, str(ci.q) if ci != null else "?", str(ci.r) if ci != null else "?",
						int(terrain_a[i]) if i < terrain_a.size() else -1,
						int(is_water_a[i]) if i < is_water_a.size() else -1,
						elev_a[i] if i < elev_a.size() else -1.0,
						temp_a[i] if i < temp_a.size() else -1.0,
						base_moisture_a[i] if i < base_moisture_a.size() else -1.0,
						sea_ice_a[i] if i < sea_ice_a.size() else -1.0,
						tta_a[i] if i < tta_a.size() else 0.0,
						sqrt(ox_i * ox_i + oy_i * oy_i),
						ni, str(cn.q) if cn != null else "?", str(cn.r) if cn != null else "?",
						int(terrain_a[ni]) if ni < terrain_a.size() else -1,
						int(is_water_a[ni]) if ni < is_water_a.size() else -1,
						elev_a[ni] if ni < elev_a.size() else -1.0,
						temp_a[ni] if ni < temp_a.size() else -1.0,
						base_moisture_a[ni] if ni < base_moisture_a.size() else -1.0,
						sea_ice_a[ni] if ni < sea_ice_a.size() else -1.0,
						tta_a[ni] if ni < tta_a.size() else 0.0,
						sqrt(ox_n * ox_n + oy_n * oy_n),
					]
	edge_vals.sort()
	var temp_edge_p99: float = host._percentile_from_sorted(edge_vals, 0.99)

	var lat_band_max: float = 0.0
	var lat_band_sample: String = ""
	if lat_a.size() >= n and temp_a.size() >= n:
		var bands: Dictionary = {}
		for i in range(n):
			var key: int = int(round(lat_a[i] * 1000000.0))
			var rec: Array = bands.get(key, [0.0, 0])
			rec[0] = float(rec[0]) + temp_a[i]
			rec[1] = int(rec[1]) + 1
			bands[key] = rec
		var keys: Array = bands.keys()
		keys.sort()
		for ki in range(1, keys.size()):
			var k0: int = int(keys[ki - 1])
			var k1: int = int(keys[ki])
			var r0: Array = bands[k0]
			var r1: Array = bands[k1]
			var m0: float = float(r0[0]) / maxf(1.0, float(r0[1]))
			var m1: float = float(r1[0]) / maxf(1.0, float(r1[1]))
			var dm: float = absf(m1 - m0)
			if dm > lat_band_max:
				lat_band_max = dm
				lat_band_sample = "%.6f->%.6f mean %.3f->%.3f" % [float(k0) / 1000000.0, float(k1) / 1000000.0, m0, m1]

	var air_nonzero: int = 0
	var air_abs_max: float = 0.0
	for i in range(mini(n, air_a.size())):
		var av_abs: float = absf(air_a[i])
		if av_abs > host._CLIMATE_INTEGRITY_EPS:
			air_nonzero += 1
		air_abs_max = maxf(air_abs_max, av_abs)
	var tta_abs_max: float = 0.0
	for i in range(mini(n, tta_a.size())):
		tta_abs_max = maxf(tta_abs_max, absf(tta_a[i]))

	var wind_mag_min: float = 999999.0
	var wind_mag_max: float = 0.0
	var wind_mag_sum: float = 0.0
	var wind_delta_vals: Array = []
	var wind_n: int = mini(n, mini(wind_x_a.size(), wind_y_a.size()))
	for i in range(wind_n):
		var wx: float = wind_x_a[i]
		var wy: float = wind_y_a[i]
		var wm: float = sqrt(wx * wx + wy * wy)
		wind_mag_min = minf(wind_mag_min, wm)
		wind_mag_max = maxf(wind_mag_max, wm)
		wind_mag_sum += wm
		if host._climate_integrity_prev_wind_x.size() == wind_x_a.size() and host._climate_integrity_prev_wind_y.size() == wind_y_a.size():
			var dwx: float = wx - host._climate_integrity_prev_wind_x[i]
			var dwy: float = wy - host._climate_integrity_prev_wind_y[i]
			wind_delta_vals.append(sqrt(dwx * dwx + dwy * dwy))
	wind_delta_vals.sort()
	if wind_n <= 0:
		wind_mag_min = 0.0
	var wind_mag_avg: float = wind_mag_sum / maxf(1.0, float(wind_n))
	var wind_delta_p95: float = host._percentile_from_sorted(wind_delta_vals, 0.95)

	var wind_speed_min: float = 999999.0
	var wind_speed_max: float = 0.0
	var wind_speed_sum: float = 0.0
	var wind_speed_delta_vals: Array = []
	var wind_speed_n: int = mini(n, wind_speed_a.size())
	for i in range(wind_speed_n):
		var wspd: float = wind_speed_a[i]
		wind_speed_min = minf(wind_speed_min, wspd)
		wind_speed_max = maxf(wind_speed_max, wspd)
		wind_speed_sum += wspd
		if host._climate_integrity_prev_wind_speed.size() == wind_speed_a.size():
			wind_speed_delta_vals.append(absf(wspd - host._climate_integrity_prev_wind_speed[i]))
	wind_speed_delta_vals.sort()
	if wind_speed_n <= 0:
		wind_speed_min = 0.0
	var wind_speed_avg: float = wind_speed_sum / maxf(1.0, float(wind_speed_n))
	var wind_speed_delta_p95: float = host._percentile_from_sorted(wind_speed_delta_vals, 0.95)

	var ocean_mag_max: float = 0.0
	var ocean_mag_sum: float = 0.0
	var ocean_delta_vals: Array = []
	var ocean_n: int = mini(n, mini(ocean_x_a.size(), ocean_y_a.size()))
	for i in range(ocean_n):
		var ox: float = ocean_x_a[i]
		var oy: float = ocean_y_a[i]
		var om: float = sqrt(ox * ox + oy * oy)
		ocean_mag_max = maxf(ocean_mag_max, om)
		ocean_mag_sum += om
		if host._climate_integrity_prev_ocean_x.size() == ocean_x_a.size() and host._climate_integrity_prev_ocean_y.size() == ocean_y_a.size():
			var dox: float = ox - host._climate_integrity_prev_ocean_x[i]
			var doy: float = oy - host._climate_integrity_prev_ocean_y[i]
			ocean_delta_vals.append(sqrt(dox * dox + doy * doy))
	ocean_delta_vals.sort()
	var ocean_mag_avg: float = ocean_mag_sum / maxf(1.0, float(ocean_n))
	var ocean_delta_p95: float = host._percentile_from_sorted(ocean_delta_vals, 0.95)

	var moisture_base_r: float = host._climate_diag_corr(moisture_a, base_moisture_a, n)
	var precip_vapor_r: float = host._climate_diag_corr(precip_a, vapor_a, n)
	var precip_cloud_r: float = host._climate_diag_corr(precip_a, cloud_a, n)
	var precip_instability_r: float = host._climate_diag_corr(precip_a, instability_a, n)
	var precip_p95: float = host._climate_diag_p95(precip_a, n)

	host._climate_integrity_log_count += 1
	print("[climate/integrity] #%d stage=%s phase=%.3f n=%d terr_isw_mis=%d terr_lut_mis=%d cell_terr_mis=%d cell_pass_mis=%d cell_isw_mis=%d dc_terr_mis=%d dc_isw_mis=%d temp_edge_max=%.3f temp_edge_p99=%.3f temp_edge_warn=%d lat_band_max=%.3f air_nonzero=%d air_abs_max=%.5f tta_abs_max=%.5f wind_dir_mag=%.3f/%.3f/%.3f wind_dir_delta_p95=%.6f wind_speed=%.3f/%.3f/%.3f wind_speed_delta_p95=%.6f ocean_mag_avg=%.3f ocean_mag_max=%.3f ocean_delta_p95=%.6f ocean_water_zero=%d non_ocean_nonzero=%d moisture_base_r=%.3f precip_vapor_r=%.3f precip_cloud_r=%.3f precip_instab_r=%.3f precip_p95=%.3f" % [
		host._climate_integrity_log_count, stage_name, host._phase_locked, n,
		terrain_iswater_mismatch, terrain_lut_mismatch, cell_terrain_mismatch,
		cell_passable_mismatch, cell_iswater_mismatch, dc_terrain_mismatch,
		dc_iswater_mismatch, temp_edge_max, temp_edge_p99, temp_edge_warn,
		lat_band_max, air_nonzero, air_abs_max, tta_abs_max,
		wind_mag_min, wind_mag_avg, wind_mag_max, wind_delta_p95,
		wind_speed_min, wind_speed_avg, wind_speed_max, wind_speed_delta_p95,
		ocean_mag_avg, ocean_mag_max, ocean_delta_p95,
		ocean_water_zero_current, non_ocean_nonzero_current,
		moisture_base_r, precip_vapor_r, precip_cloud_r, precip_instability_r,
		precip_p95,
	])
	if temp_edge_sample != "":
		print("  [climate/integrity edge] max=%.3f %s" % [temp_edge_max, temp_edge_sample])
	if lat_band_sample != "":
		print("  [climate/integrity lat] max=%.3f %s" % [lat_band_max, lat_band_sample])
	if samples.size() > 0:
		print("  [climate/integrity samples] %s" % " | ".join(samples))

	host._climate_integrity_prev_wind_x = wind_x_a.duplicate()
	host._climate_integrity_prev_wind_y = wind_y_a.duplicate()
	host._climate_integrity_prev_wind_speed = wind_speed_a.duplicate()
	host._climate_integrity_prev_ocean_x = ocean_x_a.duplicate()
	host._climate_integrity_prev_ocean_y = ocean_y_a.duplicate()


# ─── Async climate round helpers（plan §async-stage-3，2026-06-14） ─────
#
# 设计：当 cp.use_climate_round_async=true，sync sliced run_slice 路径完全短路。
# 代之以两阶段状态机：
#   _round_active=false, _async_round_kicked=false
#     → kick worker，置 _async_round_kicked=true，return partial (round 还没完)
#   _round_active=true, _async_round_kicked=true
#     → 调 poll；返空（worker 没完）→ return partial；返非空 → 同步回 _slots +
#       同步 sea_ice flip events + _finalize_round() 走原逻辑（埋点 / dirty mask）
#
# 主线程单帧开销：kick ~100us + memcpy 220 KB ≈ 0.5ms；poll busy 0；
# 完成 poll 那帧 ≈ memcpy 220 KB + flush_slots_to_map + dirty mark ≈ 2-5ms。
# x1 速度下每 game day = 每 ~1 sec 一次 round；worker 在后台跑 30-50ms 不阻塞主线程。
#
# Stage 3 不再用 _PASS_CURSOR / _pass_cursor 状态机推进（async path 一次性
# 跑完整 round）。breakdown 字段仍照 sync 路径填好以便 main.gd fast tick WARN
# 解析无差异。

static func _native_climate_lifecycle_state(ext: Object) -> Dictionary:
	if ext != null:
		var state: Dictionary = ext.get_native_climate_round_state_report()
		if str(state.get("lifecycle_owner", "")) == "native_probe_lifecycle":
			return state
	return {}


func _sync_async_lifecycle_from_native(host, state: Dictionary) -> void:
	if state.is_empty():
		return
	if state.has("lifecycle_round_active"):
		host._round_active = bool(state.get("lifecycle_round_active", host._round_active))
	if state.has("lifecycle_async_kicked"):
		host._async_round_kicked = bool(state.get("lifecycle_async_kicked", host._async_round_kicked))
	if state.has("lifecycle_pass_cursor"):
		host._pass_cursor = int(state.get("lifecycle_pass_cursor", host._pass_cursor))
	if state.has("lifecycle_poll_attempts"):
		host._async_round_poll_attempts = int(state.get("lifecycle_poll_attempts", host._async_round_poll_attempts))
	if state.has("lifecycle_tick_index"):
		host._async_round_kick_tick = int(state.get("lifecycle_tick_index", host._async_round_kick_tick))
	if state.has("phase_locked"):
		host._phase_locked = float(state.get("phase_locked", host._phase_locked))


static func _default_async_round_start_boundary_intents() -> Array:
	return [
		"sync_runtime_terrain_views",
		"begin_round_pass_state",
		"soa_begin_climate_transaction",
	]


func _execute_async_round_start_boundary_intents(host, intents: Array) -> Dictionary:
	var diag: Dictionary = {
		"round_start_terrain_sync_ms": 0.0,
		"round_start_terrain_sync_skipped": false,
		"round_start_state_ms": 0.0,
		"round_start_soa_begin_ms": 0.0,
		"round_start_boundary_intents": intents.duplicate(true),
		"round_start_boundary_intent_owner": "native_probe_lifecycle",
		"round_start_boundary_unknown_intents": [],
	}
	for raw_intent in intents:
		var intent: String = ""
		if typeof(raw_intent) == TYPE_DICTIONARY:
			intent = str(raw_intent.get("kind", ""))
		else:
			intent = str(raw_intent)
		var t_intent_us: int = Time.get_ticks_usec()
		match intent:
			"sync_runtime_terrain_views":
				var async_terrain_diag: Dictionary = host._sync_runtime_terrain_views_for_reason("round_start")
				diag["round_start_terrain_sync_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
				diag["round_start_terrain_sync_skipped"] = bool(async_terrain_diag.get("skipped", false))
				if not async_terrain_diag.is_empty():
					diag["round_start_terrain_sync_diag"] = async_terrain_diag.duplicate(true)
			"begin_round_pass_state":
				host._begin_round_pass_state()
				diag["round_start_state_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"soa_begin_climate_transaction":
				# Native declares this boundary, but MapData's PackedArray transaction is still a GDScript/Godot operation.
				if host.map != null and host.map.has_soa() and host.map.has_method("soa_begin_climate_transaction"):
					host.map.soa_begin_climate_transaction()
				diag["round_start_soa_begin_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			_:
				var unknown: Array = diag.get("round_start_boundary_unknown_intents", [])
				unknown.append(intent)
				diag["round_start_boundary_unknown_intents"] = unknown
	return diag


static func _default_async_round_finish_boundary_intents() -> Array:
	return [
		"apply_sea_ice_flips",
		"finalize_round",
		"finish_native_lifecycle",
	]


static func _default_finalize_tail_boundary_intents(async_poll_result: Dictionary = {}) -> Array:
	return [
		"use_worker_finalizer_diag" if bool(async_poll_result.get("fin_applied", false)) else "apply_gdscript_finalizer_fallback",
		"advance_full_sweep_counter",
		"publish_climate_breakdown",
		"annual_log",
		"soa_noop",
		"soak_dump",
		"integrity_check",
		"finish_active_pass",
		"reset_transpiration_state",
		"reset_round_local_state",
		"flush_pending_mark_dirty_all",
		"mark_round_slots_stale",
		"dump_round_slot_stats",
	]


func _execute_finalize_tail_boundary_intents(host,
		intents: Array,
		async_poll_result: Dictionary
) -> Dictionary:
	var normalized_intents: Array = intents.duplicate(true)
	var has_finalizer_source_intent: bool = false
	var has_full_sweep_intent: bool = false
	for raw_probe_intent in normalized_intents:
		var probe_intent: String = str(raw_probe_intent.get("kind", "")) if typeof(raw_probe_intent) == TYPE_DICTIONARY else str(raw_probe_intent)
		if probe_intent == "use_worker_finalizer_diag" or probe_intent == "apply_gdscript_finalizer_fallback":
			has_finalizer_source_intent = true
		elif probe_intent == "advance_full_sweep_counter":
			has_full_sweep_intent = true
	if not has_finalizer_source_intent:
		normalized_intents.insert(0, "use_worker_finalizer_diag" if bool(async_poll_result.get("fin_applied", false)) else "apply_gdscript_finalizer_fallback")
		host._last_finalize_diag["finalize_tail_missing_finalizer_source_intent"] = true
	if not has_full_sweep_intent:
		normalized_intents.insert(1 if normalized_intents.size() > 0 else 0, "advance_full_sweep_counter")
		host._last_finalize_diag["finalize_tail_missing_full_sweep_intent"] = true
	var finalizer_diag: Dictionary = {}
	var async_finalizer_used: bool = false
	var async_fin_fallback_reason: String = host._async_finalizer_fallback_reason(async_poll_result)
	host._last_finalize_diag["finalize_tail_boundary_intents"] = normalized_intents.duplicate(true)
	host._last_finalize_diag["finalize_tail_boundary_intent_owner"] = "native_probe_lifecycle"
	host._last_finalize_diag["finalize_tail_unknown_intents"] = []
	for raw_intent in normalized_intents:
		var intent: String = str(raw_intent.get("kind", "")) if typeof(raw_intent) == TYPE_DICTIONARY else str(raw_intent)
		var t_intent_us: int = Time.get_ticks_usec()
		match intent:
			"use_worker_finalizer_diag":
				finalizer_diag = host._build_finalizer_diag_from_worker(async_poll_result)
				host._last_finalizer_diag = finalizer_diag
				async_finalizer_used = true
				host._last_finalize_diag["finalize_finalizer_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
				host._last_finalize_diag["finalizer_cpp_worker"] = async_finalizer_used
				host._last_finalize_diag["finalizer_fallback_reason"] = async_fin_fallback_reason
			"apply_gdscript_finalizer_fallback":
				finalizer_diag = host._apply_daily_climate_finalizer()
				async_finalizer_used = false
				host._last_finalize_diag["finalize_finalizer_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
				host._last_finalize_diag["finalizer_cpp_worker"] = async_finalizer_used
				host._last_finalize_diag["finalizer_fallback_reason"] = async_fin_fallback_reason
			"advance_full_sweep_counter":
				host._full_sweep_counter += 1
				host._last_finalize_diag["finalize_counter_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"publish_climate_breakdown":
				if host.generator != null:
					var dirty_ratio_out: float = float(host.generator._last_climate_dirty_ratio) if "_last_climate_dirty_ratio" in host.generator else 1.0
					var visited_ratio_out: float = float(host.generator._last_climate_visited_ratio) if "_last_climate_visited_ratio" in host.generator else 1.0
					var pass_b_path_out: String = String(host.generator._last_climate_pass_b_path) if "_last_climate_pass_b_path" in host.generator else "full"
					if host.generator.has_method("increment_climate_diagnostic_call_count"):
						host.generator.increment_climate_diagnostic_call_count()
					var _pa_pushed_out: int = int(host.generator._pa_last_pushed_cells) if "_pa_last_pushed_cells" in host.generator else 0
					var _pa_total_out: int = int(host.generator._pa_last_total_cells) if "_pa_last_total_cells" in host.generator else 0
					var _pa_push_ratio_out: float = (float(_pa_pushed_out) / float(_pa_total_out)) if _pa_total_out > 0 else 1.0
					host.generator._last_climate_breakdown = {
						"pass_a_ms": host._round_t_pass_a_ms,
						"pass_b_ms": host._round_t_pass_b_ms,
						"ocean_ms": host._round_t_ocean_ms,
						"wind_ms": host._round_t_wind_ms,
						"sea_ice_ms": host._round_t_sea_ice_ms,
						"ice_bake_ms": 0.0,
						"transp_ms": host._round_t_transp_ms,
						"total_ms": float(Time.get_ticks_msec() - host._round_t_round_start_ms),
						"cells": host.map.cell_count(),
						"partial": false,
						"current_pass": "done",
						"processed_cells": 0,
						"cursor_start": -1,
						"cursor_end": -1,
						"progress_ratio": 1.0,
						"budget_interrupted": false,
						"pass_status": host._PASS_RESULT_DONE,
						"pass_token": host._active_pass_token,
						"pass_diag": host._last_pass_diag.duplicate(true),
						"transp_native_diag": host._last_transp_native_diag.duplicate(true),
						"dirty_ratio": dirty_ratio_out,
						"visited_ratio": visited_ratio_out,
						"pass_b_path": pass_b_path_out,
						"pa_pushed_cells": _pa_pushed_out,
						"pa_total_cells": _pa_total_out,
						"pa_push_ratio": _pa_push_ratio_out,
						"max_temp_delta": float(finalizer_diag.get("max_temp_delta", 0.0)),
						"p95_temp_delta": float(finalizer_diag.get("p95_temp_delta", 0.0)),
						"p99_temp_delta": float(finalizer_diag.get("p99_temp_delta", 0.0)),
						"preclamp_max_temp_delta": float(finalizer_diag.get("preclamp_max_temp_delta", 0.0)),
						"preclamp_p99_temp_delta": float(finalizer_diag.get("preclamp_p99_temp_delta", 0.0)),
						"temp_delta_gt_005_count": int(finalizer_diag.get("temp_delta_gt_005_count", 0)),
						"temp_delta_gt_010_count": int(finalizer_diag.get("temp_delta_gt_010_count", 0)),
						"temp_delta_gt_020_count": int(finalizer_diag.get("temp_delta_gt_020_count", 0)),
						"temp_delta_clamped_count": int(finalizer_diag.get("temp_delta_clamped_count", 0)),
						"max_transport_anomaly": float(finalizer_diag.get("max_transport_anomaly", 0.0)),
						"sea_ice_delta_max": float(finalizer_diag.get("sea_ice_delta_max", 0.0)),
						"precip_p95": float(finalizer_diag.get("precip_p95", 0.0)),
						"thermal_finalizer_applied": bool(finalizer_diag.get("thermal_finalizer_applied", false)),
						"finalizer_cpp_worker": async_finalizer_used,
						"finalizer_fallback_reason": async_fin_fallback_reason,
						"finalizer_total_ms": float(finalizer_diag.get("finalizer_total_ms", 0.0)),
						"finalizer_cell_ms": float(finalizer_diag.get("finalizer_cell_ms", 0.0)),
						"finalizer_temp_ms": float(finalizer_diag.get("finalizer_temp_ms", 0.0)),
						"finalizer_tta_ms": float(finalizer_diag.get("finalizer_tta_ms", 0.0)),
						"finalizer_thermal_ms": float(finalizer_diag.get("finalizer_thermal_ms", 0.0)),
						"finalizer_sort_ms": float(finalizer_diag.get("finalizer_sort_ms", 0.0)),
						"finalizer_sea_ice_ms": float(finalizer_diag.get("finalizer_sea_ice_ms", 0.0)),
						"finalizer_precip_ms": float(finalizer_diag.get("finalizer_precip_ms", 0.0)),
						"finalizer_write_dense_ms": float(finalizer_diag.get("finalizer_write_dense_ms", 0.0)),
						"finalizer_cells_seen": int(finalizer_diag.get("finalizer_cells_seen", 0)),
						"finalizer_temperature_cell_mirror": bool(finalizer_diag.get("finalizer_temperature_cell_mirror", false)),
						"finalizer_tta_cell_mirror": bool(finalizer_diag.get("finalizer_tta_cell_mirror", false)),
						"finalizer_tta_cell_mirror_count": int(finalizer_diag.get("finalizer_tta_cell_mirror_count", 0)),
						"finalizer_tta_clamped_count": int(finalizer_diag.get("finalizer_tta_clamped_count", 0)),
						"finalizer_thermal_init_count": int(finalizer_diag.get("finalizer_thermal_init_count", 0)),
						"_tick_idx": int(host.generator._current_fast_tick_idx) if "_current_fast_tick_idx" in host.generator else 0,
					}
					host._merge_climate_wrapper_diag(host.generator._last_climate_breakdown)
				host._last_finalize_diag["finalize_breakdown_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"annual_log":
				if host.generator != null and host.generator.has_method("climate_diagnostic_call_count"):
					var n: int = int(host.generator.climate_diagnostic_call_count())
					if host._is_annual_log_tick(n):
						var _path_str: String = "legacy"
						var _w = host.generator.get_data_core_world() if host.generator.has_method("get_data_core_world") else null
						if _w != null and _w.is_bound():
							_path_str = "data_core" if host.data_core_ready() else "data_core_cells_only"
						if host.generator.has_method("get_data_core_world_ext"):
							var _w_ext = host.generator.get_data_core_world_ext()
							if _w_ext != null:
								_path_str += "+cpp_ext"
						print("refresh_climate_daily(sliced) #%d: %dms across sub-ticks (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f wind=%.1f sea_ice=%.1f transp=%.1f path=%s" % [
							n,
							int(Time.get_ticks_msec() - host._round_t_round_start_ms),
							host.map.cell_count(),
							host._phase_locked,
							host._round_t_pass_a_ms, host._round_t_pass_b_ms, host._round_t_ocean_ms, host._round_t_wind_ms, host._round_t_sea_ice_ms, host._round_t_transp_ms,
							_path_str,
						])
				host._last_finalize_diag["finalize_annual_log_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"soa_noop":
				if host.generator != null:
					var cp_for_flush = host.generator._c()
					if cp_for_flush != null and bool(cp_for_flush.use_soa_pipeline) and host.map != null and host.map.has_soa():
						pass
				host._last_finalize_diag["finalize_soa_noop_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"soak_dump":
				var soak_dump = host._get_soak_dump_instance()
				if soak_dump != null and soak_dump.is_active():
					var sim_day: int = 0
					if host.generator != null and host.generator.has_method("climate_diagnostic_call_count"):
						sim_day = int(host.generator.climate_diagnostic_call_count())
					soak_dump.record_tick("climate", sim_day, host._phase_locked, host.map)
				host._last_finalize_diag["finalize_soak_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"integrity_check":
				host._debug_climate_integrity("round_done")
				host._last_finalize_diag["finalize_integrity_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"finish_active_pass":
				host._finish_active_pass()
				host._last_finalize_diag["finalize_finish_pass_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"reset_transpiration_state":
				host._reset_transpiration_slice_state()
				host._last_finalize_diag["finalize_reset_transp_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"reset_round_local_state":
				host._round_active = false
				host._pass_cursor = 0
			"flush_pending_mark_dirty_all":
				if host.generator != null and host.generator._data_core_world_ext != null :
					host.generator._data_core_world_ext.flush_pending_mark_dirty_all()
				host._last_finalize_diag["finalize_flush_dirty_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"mark_round_slots_stale":
				if host.generator != null and host.generator.has_method("_mark_climate_daily_round_slots_stale"):
					host.generator._mark_climate_daily_round_slots_stale()
				host._last_finalize_diag["finalize_mark_stale_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"dump_round_slot_stats":
				if host.generator != null and host.generator.has_method("dump_climate_daily_round_slots_stats"):
					var stats: Dictionary = host.generator.dump_climate_daily_round_slots_stats()
					# 每 20 round 打一次，避免刷屏
					if int(stats.get("refresh_count", 0)) > 0 \
							and host.generator.has_method("climate_diagnostic_call_count") \
							and int(host.generator.climate_diagnostic_call_count()) % 20 == 1:
						print("[climate/round] refresh_count=%d skip_count=%d (per round)" % [
							int(stats.get("refresh_count", 0)),
							int(stats.get("skip_count", 0)),
						])
				host._last_finalize_diag["finalize_dump_stats_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			_:
				var unknown: Array = host._last_finalize_diag.get("finalize_tail_unknown_intents", [])
				unknown.append(intent)
				host._last_finalize_diag["finalize_tail_unknown_intents"] = unknown
	return {
		"finalizer_diag": finalizer_diag,
		"finalizer_cpp_worker": async_finalizer_used,
		"finalizer_fallback_reason": async_fin_fallback_reason,
		"finalize_tail_boundary_intents": normalized_intents,
	}


func _execute_async_round_finish_boundary_intents(host, intents: Array, poll_result: Dictionary, ext: Object, finish_t0_us: int, native_poll_report: Dictionary = {}) -> Dictionary:
	var diag: Dictionary = {
		"flip_ms": 0.0,
		"finalize_ms": 0.0,
		"finish_ms": 0.0,
		"native_finish_report": {},
		"round_finish_boundary_intents": intents.duplicate(true),
		"round_finish_boundary_intent_owner": "native_probe_lifecycle",
		"round_finish_boundary_unknown_intents": [],
	}
	for raw_intent in intents:
		var intent: String = ""
		if typeof(raw_intent) == TYPE_DICTIONARY:
			intent = str(raw_intent.get("kind", ""))
		else:
			intent = str(raw_intent)
		var t_intent_us: int = Time.get_ticks_usec()
		match intent:
			"apply_sea_ice_flips":
				host._handle_async_sea_ice_flips(poll_result)
				diag["flip_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"finalize_round":
				host._pass_cursor = host._PASS_COUNT
				host._finalize_round(poll_result, native_poll_report.get("finalize_tail_boundary_intents", []))
				diag["finalize_ms"] = float(Time.get_ticks_usec() - t_intent_us) / 1000.0
			"finish_native_lifecycle":
				if ext != null:
					var native_finish_report: Dictionary = ext.native_climate_round_finish_round({
						"pass_cursor": host._PASS_COUNT,
						"stage": "round_done",
						"finalize_ms": float(diag.get("finalize_ms", 0.0)),
						"finish_ms": float(Time.get_ticks_usec() - finish_t0_us) / 1000.0,
					})
					diag["native_finish_report"] = native_finish_report
					host._sync_async_lifecycle_from_native(native_finish_report.get("state", {}))
			_:
				var unknown: Array = diag.get("round_finish_boundary_unknown_intents", [])
				unknown.append(intent)
				diag["round_finish_boundary_unknown_intents"] = unknown
	diag["finish_ms"] = float(Time.get_ticks_usec() - finish_t0_us) / 1000.0
	return diag


func _run_slice_async(host, ctx: SusTickContext) -> Dictionary:
	var ext = host.generator._data_core_world_ext
	if ext == null:
		return host._async_round_partial_report(0.0, "ext null")
	# Worker 没注册 → first time enter → register（幂等）。
	if not host._async_first_round_logged:
		host._async_first_round_logged = true
		# 静态 knobs 推一次（neighbor_indices + donor_table + foliage_table）
		var static_knobs: Dictionary = host._build_async_static_knobs()
		ext.native_climate_round_begin(static_knobs)
		print("[climate/async] worker registered + static knobs set (n_cells=%d)" % host.map.cell_count())

	var native_lifecycle_state: Dictionary = host._native_climate_lifecycle_state(ext)
	host._sync_async_lifecycle_from_native(native_lifecycle_state)

	# Round 启动：kick
	if not host._round_active:
		var t_round_start_us: int = Time.get_ticks_usec()
		var t_round_part_us: int = t_round_start_us
		host._last_round_start_diag = {
			"round_start_total_ms": 0.0,
			"round_start_phase_ms": 0.0,
			"round_start_terrain_sync_ms": 0.0,
			"round_start_terrain_sync_skipped": false,
			"capture_start_state_ms": 0.0,
			"round_start_state_ms": 0.0,
			"round_start_reset_transp_ms": 0.0,
			"round_start_mark_stale_ms": 0.0,
			"round_start_soa_begin_ms": 0.0,
			"round_start_dirty_ms": 0.0,
			"round_start_state_source": "gdscript_fallback",
		}
		var phase_candidate: float = ctx.season_phase
		if host.season_phase_getter.is_valid():
			phase_candidate = float(host.season_phase_getter.call())
		host._last_round_start_diag["round_start_phase_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		host._round_t_pass_a_ms = 0.0
		host._round_t_pass_b_ms = 0.0
		host._round_t_ocean_ms = 0.0
		host._round_t_wind_ms = 0.0
		host._round_t_sea_ice_ms = 0.0
		host._round_t_transp_ms = 0.0
		host._round_t_round_start_ms = Time.get_ticks_msec()
		var native_begin_round: Dictionary = ext.native_climate_round_begin_round({
			"phase_locked": phase_candidate,
			"tick_index": ctx.tick_index,
			"pass_cursor": 0,
			"mode": "async",
		})
		var native_begin_state: Dictionary = native_begin_round.get("state", {})
		host._sync_async_lifecycle_from_native(native_begin_state)
		native_lifecycle_state = native_begin_state
		host._last_round_start_diag["native_lifecycle_begin"] = native_begin_round
		host._last_round_start_diag["round_start_state_source"] = "native_probe_lifecycle"
		host._last_round_start_diag["round_start_state_intents"] = native_begin_round.get("start_state_intents", [])
		var boundary_intents: Array = []
		if not native_lifecycle_state.is_empty():
			boundary_intents = native_lifecycle_state.get("boundary_intents", [])
		if boundary_intents.is_empty():
			boundary_intents = host._default_async_round_start_boundary_intents()
		var boundary_diag: Dictionary = host._execute_async_round_start_boundary_intents(boundary_intents)
		for key in boundary_diag.keys():
			host._last_round_start_diag[key] = boundary_diag[key]
		host._last_round_start_diag["round_start_total_ms"] = float(Time.get_ticks_usec() - t_round_start_us) / 1000.0

	native_lifecycle_state = host._native_climate_lifecycle_state(ext)
	host._sync_async_lifecycle_from_native(native_lifecycle_state)

	# Worker pending 时不重复 kick（kick 返回 false → reused++）。
	if not host._async_round_kicked:
		var kick_t0: int = Time.get_ticks_usec()
		var input: Dictionary = host._build_async_kick_input(host._phase_locked)
		var kicked: bool = false
		var kick_report: Dictionary = {}
		kick_report = ext.native_climate_round_kick(input)
		kicked = bool(kick_report.get("kicked", false))
		host._sync_async_lifecycle_from_native(kick_report.get("state", {}))
		var kick_ms: float = (Time.get_ticks_usec() - kick_t0) / 1000.0
		if not kicked:
			# Worker busy 处理上一 round → 本 tick 继续等。下个 tick 还可以 poll。
			pass
		# 真异步关键：kick 完立刻让 SUS 把 budget 让给后续 jobs（atlas / weather / ocean）。
		# 报 done=true progress=1.0 → SUS 不会同 tick 内 re-entry。**下一个 tick** 才会
		# 再进 run_slice，那时 worker 已经在后台跑完，poll 直接拿结果。
		# bug 修复 2026-06-14（plan §async-stage-4 真机验证）：之前报 done=false
		# 导致 SUS 同 tick re-entry → busy-wait worker → 主线程 30+ms 全卡死，atlas / weather
		# 拿不到 budget → 视觉冻结。
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": kick_ms,
			"progress_ratio": 1.0,
			"stage_name": "async_round_kicked",
			"substage": "kicked" if kicked else "worker_busy",
			"path": "data_core_async",
			"native_lifecycle_state": kick_report.get("state", {}) if not kick_report.is_empty() else native_lifecycle_state,
		}

	# 已 kick → poll
	var poll_t0: int = Time.get_ticks_usec()
	var poll_result: Dictionary = {}
	var native_poll_report: Dictionary = {}
	native_poll_report = ext.native_climate_round_poll()
	host._sync_async_lifecycle_from_native(native_poll_report.get("state", {}))
	if bool(native_poll_report.get("done", false)):
		poll_result = native_poll_report.get("result", {})
	var poll_ms: float = (Time.get_ticks_usec() - poll_t0) / 1000.0
	if poll_result.is_empty():
		# Worker 还没完成 → 报 done=true 让出 budget。下一 tick 再 poll。
		# bug 修复 2026-06-14（同上）：之前报 done=false 导致 busy-wait。
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": poll_ms,
			"progress_ratio": 1.0,
			"stage_name": "async_round_poll_pending",
			"substage": "attempts=%d" % host._async_round_poll_attempts,
			"path": "data_core_async",
			"native_poll_report": native_poll_report,
		}

	# Worker 完成：poll 已经把 19 个 slot 写回 _slots + flush 到 MapData。
	var finish_t0: int = Time.get_ticks_usec()

	# 填充 per-pass breakdown 让 main.gd 日志解析无差异。新 native facade 直接
	# 返回 ms 级 breakdown；旧 DLL 继续从 *_us 字段换算。
	var native_breakdown: Dictionary = poll_result.get("breakdown", {})
	if not native_breakdown.is_empty():
		host._round_t_pass_a_ms     = float(native_breakdown.get("pass_a_ms", 0.0))
		host._round_t_pass_b_ms     = float(native_breakdown.get("pass_b_ms", 0.0))
		host._round_t_ocean_ms      = float(native_breakdown.get("ocean_ms", 0.0))
		host._round_t_wind_ms       = float(native_breakdown.get("wind_ms", 0.0))
		host._round_t_sea_ice_ms    = float(native_breakdown.get("sea_ice_ms", 0.0))
		host._round_t_transp_ms     = float(native_breakdown.get("transp_ms", 0.0))
	else:
		host._round_t_pass_a_ms     = float(poll_result.get("pass_a_us", 0)) / 1000.0
		host._round_t_pass_b_ms     = float(poll_result.get("pass_b_us", 0)) / 1000.0
		host._round_t_ocean_ms      = (float(poll_result.get("ocean_water_us", 0)) + float(poll_result.get("ocean_land_us", 0))) / 1000.0
		host._round_t_wind_ms       = (float(poll_result.get("wind_air_us", 0)) + float(poll_result.get("wind_surface_us", 0))) / 1000.0
		host._round_t_sea_ice_ms    = float(poll_result.get("sea_ice_us", 0)) / 1000.0
		host._round_t_transp_ms     = float(poll_result.get("transp_us", 0)) / 1000.0

	# Stage 4 真机诊断（前 5 round 打一次）：判断每个 pass 是否真的跑了。
	# 每个 pass kernel 守卫失败时 us=0，证明该 pass 因 input size mismatch 跳过。
	# Fix #11 second pass (2026-06-16)：原条件 `_async_round_poll_attempts <= 5`
	# 在 worker 完成快时（每 round 都只 1 个 attempt）变成每 round 都触发，
	# 50 lines/10s 污染 logcat。改为按 round 计数（_async_round_log_count）。
	host._async_round_log_count += 1
	if PKLog.enabled and (host._async_round_log_count <= 5 or (host._async_round_log_count % 60 == 0)):
		var sip: int = int(poll_result.get("sea_ice_us", 0))
		var pap: int = int(poll_result.get("pass_a_us", 0))
		var pbp: int = int(poll_result.get("pass_b_us", 0))
		var owp: int = int(poll_result.get("ocean_water_us", 0))
		var olp: int = int(poll_result.get("ocean_land_us", 0))
		var wap: int = int(poll_result.get("wind_air_us", 0))
		var wsp: int = int(poll_result.get("wind_surface_us", 0))
		var trp: int = int(poll_result.get("transp_us", 0))
		var fci: int = int(poll_result.get("flipped_cell_indices", PackedInt32Array()).size())
		print("[climate/async DIAG] round #%d: pa=%dus pb=%dus ow=%dus ol=%dus wa=%dus ws=%dus si=%dus tr=%dus | flipped=%d" % [
			host._async_round_log_count, pap, pbp, owp, olp, wap, wsp, sip, trp, fci])

	# Fix #6 async (2026-06-15 v3 已回退)：实测显示拆 slice 让 sus_ticks/120 从 61
	# 涨到 79（+30%），sus_frame_avg 28→36ms，FPS 66→29。每个 SUS slice 都有
	# scheduler 边界开销 + 让更多帧承担 SUS 工作。finalize 5-8ms 是确定性 cost
	# 不是随机 spike，拆 slice 反而恶化整体。保留代码作为 reference。
	# 直接走原行为：同 tick 跑完 finalize，return done=true。
	# Round 结束：native poll 声明 finish boundary intents；GDScript 执行仍必须留在脚本侧的动作。
	var finish_boundary_intents: Array = native_poll_report.get("finish_boundary_intents", [])
	if finish_boundary_intents.is_empty():
		finish_boundary_intents = host._default_async_round_finish_boundary_intents()
	var finish_diag: Dictionary = host._execute_async_round_finish_boundary_intents(finish_boundary_intents, poll_result, ext, finish_t0, native_poll_report)
	var flip_ms: float = float(finish_diag.get("flip_ms", 0.0))
	var finalize_ms: float = float(finish_diag.get("finalize_ms", 0.0))
	var finish_ms: float = float(finish_diag.get("finish_ms", 0.0))
	var native_finish_report: Dictionary = finish_diag.get("native_finish_report", {})
	if host.generator != null and "_last_climate_breakdown" in host.generator:
		host.generator._last_climate_breakdown["async_poll_ms"] = poll_ms
		host.generator._last_climate_breakdown["async_flip_ms"] = flip_ms
		host.generator._last_climate_breakdown["async_finalize_ms"] = finalize_ms
		host.generator._last_climate_breakdown["async_finish_ms"] = finish_ms
		host.generator._last_climate_breakdown["native_finish_boundary_intents"] = finish_boundary_intents
		host.generator._last_climate_breakdown["native_finish_boundary_diag"] = finish_diag
		if not native_finish_report.is_empty():
			host.generator._last_climate_breakdown["native_lifecycle_finish"] = native_finish_report

	if int(poll_result.get("worker_total_us", 0)) > 50_000:
		# Worker 跑超 50ms 偶尔可见，但不严重。可以提示。
		print("[climate/async] slow round worker_total_us=%d kick_to_poll_attempts=%d" % [
			int(poll_result.get("worker_total_us", 0)), host._async_round_poll_attempts,
		])

	return {
		"done": true,
		"work_done": host.map.cell_count(),
		"elapsed_ms": poll_ms,
		"progress_ratio": 1.0,
		"stage_name": "async_round_done",
		"substage": "pass_count=%d" % host._PASS_COUNT,
		"path": "data_core_async",
		"poll_ms": poll_ms,
		"flip_ms": flip_ms,
		"finalize_ms": finalize_ms,
		"finish_ms": finish_ms,
		"finalizer_cpp_worker": bool(poll_result.get("fin_applied", false)),
		"finalizer_fallback_reason": host._async_finalizer_fallback_reason(poll_result),
		"published_slots": poll_result.get("published_slots", []),
		"visual_dirty_intents": poll_result.get("visual_dirty_intents", []),
		"native_breakdown": native_breakdown,
		"native_poll_report": native_poll_report,
		"native_finish_report": native_finish_report,
		"native_finish_boundary_intents": finish_boundary_intents,
	}


# 返回 partial report 给 SUS scheduler（round 还没完）。

func _async_round_partial_report(host, slice_ms: float, stage_label: String) -> Dictionary:
	return {
		"done": false,
		"work_done": 0,
		"elapsed_ms": slice_ms,
		"progress_ratio": 0.0,
		"stage_name": "async_round_" + stage_label,
		"substage": "attempts=%d" % host._async_round_poll_attempts,
		"path": "data_core_async",
	}


# 构造 async kick 用的 input Dictionary（所有 climate pass 需要读的字段 + cp scalars）。
# 主线程跑一次 ~0.5ms（memcpy 220 KB），值得：worker 在后台 30-50ms 不阻塞主线程。

func _build_async_kick_input(host, season_phase: float) -> Dictionary:
	var cp: ClimateProfile = host.generator._c()
	var n_cells: int = host.map.cell_count()
	# 默认 mask = 0xFF（全开 round 模式）。Stage 3 把开关字段也放进来便于调试。
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0xFF,
		# pass_a 用
		"is_water": host.map.is_water_arr,
		"terrain": host.map.terrain_arr,
		"cover": host.map.cover_arr,
		"ema_initialized": host.map.ema_initialized_arr,
		"elevation": host.map.elevation_arr,
		"base_moisture": host.map.base_moisture_arr,
		"weather_vapor": host.map.weather_vapor_arr,
		"weather_precip": host.map.weather_precip_arr,
		"soil_moisture": host.map.soil_moisture_arr,
		"water_balance_30d": host.map.water_balance_30d_arr,
		"lat_norm": host.map.cell_lat_norm_arr,
		"temp_baseline_year": host.map.temp_baseline_year_arr,
		"temp": host.map.temp_arr,
		"temp_30d": host.map.temp_30d_arr,
		"temp_365d": host.map.temp_365d_arr,
		"thermal_energy": host.map.thermal_energy_arr,
		"snowpack": host.map.snowpack_arr,
		# pass_b 共享
		"landform": host.map.landform_arr,
		"vegetation": host.map.vegetation_arr,
		"moisture": host.map.moisture_arr,
		"pos_x": host.map.cell_pos_x_arr,
		"pos_y": host.map.cell_pos_y_arr,
		"insolation_dev": host.map.insolation_dev_arr,
		"temp_transport_anomaly": host.map.temperature_transport_anomaly_arr,
		"local_thermal_anomaly": host.map.local_thermal_anomaly_arr,
		"sea_ice_frac": host.map.sea_ice_frac_arr,
		"sea_ice_frac_inout": host.map.sea_ice_frac_arr,  # sea_ice 也用
		"base_terrain": host.map.base_terrain_arr,
		"upwelling_strength": host.map.upwelling_strength_arr,
		"insolation_now": host.map.insolation_now_arr,
		"cell_temperature_arr": host.map.temp_arr,  # sea_ice 期望 climate-adjusted T（round 内 wind_surface 写完更新）
		# ocean_water/land 共享
		"ocean_current_x": host.map.ocean_current_x_arr,
		"ocean_current_y": host.map.ocean_current_y_arr,
		"ocean_thermal_anomaly": host.map.ocean_thermal_anomaly_arr,
		# wind_air/surface 共享
		"wind_x": host.map.wind_x_arr,
		"wind_y": host.map.wind_y_arr,
		"wind_speed": host.map.wind_speed_arr,
		"temp_baseline": host.map.temp_baseline_arr,
		"air_mass_temp_anomaly": host.map.air_mass_temp_anomaly_arr,
		# water_terrain_ids LUT（与 sync run_sea_ice_daily_pass 同源）
		"water_terrain_ids": PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN) & 0xFF,
			int(TerrainType.TERRAIN.COAST) & 0xFF,
			int(TerrainType.TERRAIN.LAKE) & 0xFF,
			int(TerrainType.TERRAIN.REEF) & 0xFF,
			int(TerrainType.TERRAIN.KELP) & 0xFF,
			int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		]),
		# sea_ice 翻转用的 terrain enum ids
		"si_terrain_lake_id":    int(TerrainType.TERRAIN.LAKE) & 0xFF,
		"si_terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		"si_terrain_ocean_id":   int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		# round scalars
		"season_phase": season_phase,
		"axial_tilt_deg": float(cp.axial_tilt_deg) if "axial_tilt_deg" in cp else 23.5,
		"day_length_gain": float(cp.insolation_daylen_amp) if "insolation_daylen_amp" in cp else 0.35,
		"solar_gain": float(cp.solar_gain) if "solar_gain" in cp else 1.0,
		"insol_amp": float(cp.season_temp_amp) if "season_temp_amp" in cp else 0.20,
		"insol_gain": float(cp.insolation_season_gain) if "insolation_season_gain" in cp else 1.0,
		"moist_scale_now": 1.0,
		"runtime_moisture_base_relax_rate": float(cp.runtime_moisture_base_relax_rate) if "runtime_moisture_base_relax_rate" in cp else 0.24,
		"runtime_moisture_weather_vapor_weight": float(cp.runtime_moisture_weather_vapor_weight) if "runtime_moisture_weather_vapor_weight" in cp else 0.12,
		"runtime_moisture_precip_weight": float(cp.runtime_moisture_precip_weight) if "runtime_moisture_precip_weight" in cp else 0.78,
		"runtime_moisture_soil_weight": float(cp.runtime_moisture_soil_weight) if "runtime_moisture_soil_weight" in cp else 1.82,
		"runtime_moisture_soil_dry_weight": float(cp.runtime_moisture_soil_dry_weight) if "runtime_moisture_soil_dry_weight" in cp else 2.21,
		"runtime_moisture_water_balance_weight": float(cp.runtime_moisture_water_balance_weight) if "runtime_moisture_water_balance_weight" in cp else 1.04,
		"runtime_moisture_water_balance_dry_weight": float(cp.runtime_moisture_water_balance_dry_weight) if "runtime_moisture_water_balance_dry_weight" in cp else 1.30,
		"days_per_year": host.generator._calendar_days_per_year(),
		"sea_level": float(host.generator._last_cfg.sea_level) if host.generator._last_cfg != null else 0.5,
		# pass_a 扩展 scalars — mirror sync `_climate_pass_a` cp_struct。
		"thermal_inertia_land": float(cp.thermal_inertia_land) if "thermal_inertia_land" in cp else 0.35,
		"thermal_inertia_water": float(cp.thermal_inertia_water) if "thermal_inertia_water" in cp else 0.045,
		"thermal_inertia_snow": float(cp.thermal_inertia_snow) if "thermal_inertia_snow" in cp else 0.09,
		"thermal_inertia_high_mountain": float(cp.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp else 0.16,
		"thermal_daily_delta_cap": float(cp.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp else 0.15,
		"snowpack_cover_low": float(cp.snowpack_cover_low) if "snowpack_cover_low" in cp else 0.05,
		"snowpack_cover_full": float(cp.snowpack_cover_full) if "snowpack_cover_full" in cp else 0.32,
		"insol_dev_min": float(cp.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp else -1.0,
		"insol_dev_max": float(cp.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp else 1.0,
		# [climate-zone-fix P2] 沿海海洋性调温（与 sync _build_native_daily_climate_pass_a_struct mirror，
		# 同一 _ensure_maritime_factor 缓存→async/sync 逐位一致）
		"maritime_season_damp": float(cp.maritime_season_damp) if "maritime_season_damp" in cp else 0.0,
		"maritime_factor": host.generator._ensure_maritime_factor(host.map, float(cp.maritime_decay_cells) if "maritime_decay_cells" in cp else 4.0),
		# transp scalars
		"transp_outflow_rate": float(cp.transpiration_outflow_rate) if "transpiration_outflow_rate" in cp else 0.025,
		"transp_self_rate":    float(cp.transpiration_self_rate)    if "transpiration_self_rate"    in cp else 0.015,
	}
	# pass_b knobs（移植自 sync _build_native_daily_climate_pass_b_knobs，字段名必须 mirror）
	input["pb_winter_boost"]  = 1.0
	input["pb_snow_cool"]     = float(cp.snow_albedo_cooling) if "snow_albedo_cooling" in cp else 0.0
	input["pb_veg_cool"]      = float(cp.vegetation_cooling) if "vegetation_cooling" in cp else 0.0
	input["pb_diurnal_amp"]   = float(cp.landform_diurnal_amp) if "landform_diurnal_amp" in cp else 0.0
	input["pb_evap_gain"]     = float(cp.evaporation_gain) if "evaporation_gain" in cp else 0.0
	input["pb_rs_threshold"]  = float(cp.rain_shadow_threshold) if "rain_shadow_threshold" in cp else 0.0
	input["pb_rs_factor"]     = float(cp.rain_shadow_factor) if "rain_shadow_factor" in cp else 1.0
	input["pb_rs_lookback"]   = max(0, int(cp.rain_shadow_lookback)) if "rain_shadow_lookback" in cp else 0
	input["pb_t_freeze"]      = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.0
	input["pb_coupling_gain"] = float(cp.ocean_moisture_coupling_gain) if "ocean_moisture_coupling_gain" in cp else 0.0
	# coast_leak 来自 _last_cfg.COASTAL_HEAT_LEAK，不是 cp 字段
	input["pb_coast_leak"]    = float(host.generator._last_cfg.COASTAL_HEAT_LEAK) if host.generator._last_cfg != null else 0.0
	input["pb_sea_ice_albedo_cooling"] = float(cp.sea_ice_albedo_cooling) if "sea_ice_albedo_cooling" in cp else 0.01
	# ocean_water knobs — sync 用 _last_cfg.OCEAN_HEAT_* （map_generator.gd:9679-9680）
	input["ow_advect_steps"] = max(0, int(host.generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS)) if host.generator._last_cfg != null else 3
	input["ow_heat_mix"]     = clampf(float(host.generator._last_cfg.OCEAN_HEAT_MIX), 0.0, 1.0) if host.generator._last_cfg != null else 0.55
	# ocean TTA scalars — sync 用 _temperature_transport_anomaly_knobs (map_generator.gd:2083-2104)
	# 来源：cp.temperature_transport_anomaly_source_cap / blend_rate / decay_rate / zero_current_decay
	# 缺省值 mirror ClimateProfile / sync _temperature_transport_anomaly_knobs。
	var _tta_source_cap: float = 0.22
	var _tta_blend_rate: float = 0.70
	var _tta_decay_rate: float = 0.04
	var _tta_zero_curr_decay: float = 0.06
	if cp != null:
		if "temperature_transport_anomaly_source_cap" in cp:
			_tta_source_cap = clampf(float(cp.temperature_transport_anomaly_source_cap), 0.0, 0.5)
		if "temperature_transport_anomaly_blend_rate" in cp:
			_tta_blend_rate = clampf(float(cp.temperature_transport_anomaly_blend_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_decay_rate" in cp:
			_tta_decay_rate = clampf(float(cp.temperature_transport_anomaly_decay_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_zero_current_decay" in cp:
			_tta_zero_curr_decay = clampf(float(cp.temperature_transport_anomaly_zero_current_decay), 0.0, 1.0)
	# ocean_water 和 ocean_land 都需要这 4 个；C++ 端用 ow_tta_*/ol_tta_* 分别取
	input["ow_tta_source_cap"]          = _tta_source_cap
	input["ow_tta_blend_rate"]          = _tta_blend_rate
	input["ow_tta_zero_current_decay"]  = _tta_zero_curr_decay
	input["ol_tta_source_cap"]          = _tta_source_cap
	input["ol_tta_blend_rate"]          = _tta_blend_rate
	input["ol_tta_decay_rate"]          = _tta_decay_rate
	# ocean_land knobs — sync 用 _last_cfg.COASTAL_HEAT_LEAK * winter_boost(1.0)（map_generator.gd:9916-9917）
	input["ol_effective_leak"] = float(host.generator._last_cfg.COASTAL_HEAT_LEAK) if host.generator._last_cfg != null else 0.55
	# wind_air knobs — sync 用 _last_cfg.WIND_HEAT_*（map_generator.gd:12637-12638）
	input["wa_advect_steps"] = max(0, int(host.generator._last_cfg.WIND_HEAT_ADVECT_STEPS)) if host.generator._last_cfg != null else 3
	input["wa_heat_mix"]     = clampf(float(host.generator._last_cfg.WIND_HEAT_MIX), 0.0, 1.0) if host.generator._last_cfg != null else 0.25
	# wind_surface knobs — sync 用 _last_cfg.AIR_MASS_HEAT_LEAK（map_generator.gd:12672）
	input["ws_air_leak"]     = float(host.generator._last_cfg.AIR_MASS_HEAT_LEAK) if host.generator._last_cfg != null else 0.35
	input["ws_cold_transport_form"] = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.06
	input["ws_cold_transport_melt"] = float(cp.sea_ice_melt_threshold) if "sea_ice_melt_threshold" in cp else 0.11
	# sea_ice knobs — sync 用 cp.sea_ice_freeze_rate / sea_ice_melt_rate / sea_ice_form_threshold /
	#   sea_ice_melt_threshold / sea_ice_neighbor_contagion / sea_ice_terrain_threshold /
	#   sea_ice_terrain_hysteresis（_apply_sea_ice_daily_pass map_generator.gd:8020-8026）
	# 还有 sea_ice_freeze_insol_low/high / sea_ice_solar_melt_start/gain / sea_ice_daily_delta_cap /
	#   sea_ice_solar_gate_enabled / OCEAN_CURRENT_ICE_DELAY / enable_ocean_heat_transport
	input["si_k_freeze"]     = float(cp.sea_ice_freeze_rate) if "sea_ice_freeze_rate" in cp else 0.40
	input["si_k_melt"]       = float(cp.sea_ice_melt_rate)   if "sea_ice_melt_rate"   in cp else 1.45
	input["si_t_form"]       = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.06
	input["si_t_melt"]       = float(cp.sea_ice_melt_threshold) if "sea_ice_melt_threshold" in cp else 0.11
	input["si_contagion"]    = float(cp.sea_ice_neighbor_contagion) if "sea_ice_neighbor_contagion" in cp else 0.035
	input["si_threshold"]    = float(cp.sea_ice_terrain_threshold) if "sea_ice_terrain_threshold" in cp else 0.68
	input["si_hysteresis"]   = float(cp.sea_ice_terrain_hysteresis) if "sea_ice_terrain_hysteresis" in cp else 0.12
	input["si_ice_delay"]    = float(host.generator._last_cfg.OCEAN_CURRENT_ICE_DELAY) if host.generator._last_cfg != null else 1.0
	input["si_solar_gate_enabled"] = bool(cp.sea_ice_solar_gate_enabled) if "sea_ice_solar_gate_enabled" in cp else true
	input["si_freeze_insol_low"]  = float(cp.sea_ice_freeze_insol_low) if "sea_ice_freeze_insol_low" in cp else 0.22
	input["si_freeze_insol_high"] = float(cp.sea_ice_freeze_insol_high) if "sea_ice_freeze_insol_high" in cp else 0.45
	input["si_solar_melt_start"]  = float(cp.sea_ice_solar_melt_start) if "sea_ice_solar_melt_start" in cp else 0.28
	input["si_solar_melt_gain"]   = float(cp.sea_ice_solar_melt_gain) if "sea_ice_solar_melt_gain" in cp else 1.35
	input["si_min_thick_ice_solar_exposure"] = float(cp.sea_ice_min_thick_ice_solar_exposure) if "sea_ice_min_thick_ice_solar_exposure" in cp else 0.32
	input["si_daily_delta_cap"]   = float(cp.sea_ice_daily_delta_cap) if "sea_ice_daily_delta_cap" in cp else 0.070
	input["si_edge_mix_rate"]     = float(cp.sea_ice_edge_mix_rate) if "sea_ice_edge_mix_rate" in cp else 0.035
	input["si_enable_oht"]        = bool(host.generator._last_cfg.enable_ocean_heat_transport) if host.generator._last_cfg != null else true
	# climate_anomaly 阈值偏移（与 _apply_sea_ice_daily_pass map_generator.gd:8044-8046 同源）
	# sync 路径在调 C++ run_sea_ice_daily_pass 前已把 t_form/t_melt 减去 climate_anomaly_now * 0.10。
	# async 模式要 mirror 这个 shift —— worker 用相同 t_form/t_melt 才能 bit-equal。
	var _ca_now: float = 0.0
	if host.generator._world_clock_ref != null:
		var _ca_v = host.generator._world_clock_ref.get("climate_anomaly")
		if _ca_v != null:
			_ca_now = float(_ca_v)
	if not is_equal_approx(_ca_now, 0.0):
		var _ice_thr_shift: float = 0.10 * _ca_now
		input["si_t_form"] = clampf(float(input["si_t_form"]) - _ice_thr_shift, 0.0, 1.0)
		input["si_t_melt"] = clampf(float(input["si_t_melt"]) - _ice_thr_shift, 0.0, 1.0)
	# apply_terrain_flips：sync 路径里由 GDScript caller 处理翻转，async 模式建议
	# 让 C++ worker 写好 out.terrain（apply=true）→ poll 写回 _slots[cell_terrain]，
	# 减少主线程处理量。
	input["si_apply_terrain_flips"] = true
	# si_dt_days：sync 路径每次调 sea_ice 时从 generator consume（map_generator.gd:8011
	# `_apply_sea_ice_daily_pass` 调用 `_consume_sea_ice_dt_days()`）。async 模式在
	# kick 时 consume，传给 worker 用。
	if host.generator.has_method("_consume_sea_ice_dt_days"):
		input["si_dt_days"] = float(host.generator._consume_sea_ice_dt_days())
	else:
		input["si_dt_days"] = 1.0
	# thermal_dt_days：与 si_dt_days 同源。pass_a 热惯性松弛/delta_cap 按实际经过
	# 天数积分，否则加速档下海洋温度欠积分、滞后太阳直射点。worker 默认 1.0（缺键时）。
	if host.generator.has_method("_consume_climate_dt_days"):
		input["thermal_dt_days"] = float(host.generator._consume_climate_dt_days())
	else:
		input["thermal_dt_days"] = 1.0
	# ─── finalizer pass fields（Stage 9 / Fix #11, 2026-06-16） ─────────────
	# C++ worker 的 finalizer kernel 等价 _apply_daily_climate_finalizer，
	# 跳过 main thread 上 4 个 2400-loop + 2 个 sort + 3 个 write_f32_dense（实测 13-17ms）。
	# 关键输入：round-start snapshot（temp / TTA / sea_ice_prev / precip）。
	input["fin_temp_start_of_day"] = host._temp_start_of_day_arr
	input["fin_tta_start_of_day"]  = host._tta_start_of_day_arr
	input["fin_sea_ice_frac_prev"] = host.map.sea_ice_frac_arr_prev if host.map.sea_ice_frac_arr_prev.size() == n_cells else PackedFloat32Array()
	input["fin_weather_precip"]    = host.map.weather_precip_arr if host.map.weather_precip_arr.size() == n_cells else PackedFloat32Array()
	input["fin_temp_cap_enabled"]  = bool(cp.thermal_final_delta_cap_enabled) if cp != null and "thermal_final_delta_cap_enabled" in cp else true
	input["fin_temp_cap"]          = float(cp.thermal_daily_delta_cap) if cp != null and "thermal_daily_delta_cap" in cp else 0.15
	input["fin_tta_cap"]           = float(cp.temperature_transport_anomaly_daily_cap) if cp != null and "temperature_transport_anomaly_daily_cap" in cp else 0.12
	input["fin_has_temp_start"]    = host._temp_start_of_day_arr.size() == n_cells
	input["fin_has_tta_start"]     = host._tta_start_of_day_arr.size() == n_cells
	# passes_mask: 默认含 finalizer bit 8；风热输运关闭时 mirror sync/native daily gate。
	var passes_mask: int = 0x1FF
	var wind_heat_enabled: bool = true
	if cp != null and "enable_wind_heat_transport" in cp:
		wind_heat_enabled = bool(cp.enable_wind_heat_transport)
	if not wind_heat_enabled:
		passes_mask = passes_mask & ~0x30 # bit 4=wind_air, bit 5=wind_surface
	input["passes_mask"] = passes_mask
	return input


# 静态 knobs（round 间不变化）。register 后第一次 set，round 间复用。

func _build_async_static_knobs(host) -> Dictionary:
	var n_cells: int = host.map.cell_count()
	var nb_idx: PackedInt32Array = host.map.neighbor_indices_packed() if host.map.has_indices() else PackedInt32Array()
	var donor_table: PackedFloat32Array = host.generator._build_transpiration_donor_table()
	var foliage_table: PackedFloat32Array = host.generator._build_climate_b_foliage_table() if host.generator.has_method("_build_climate_b_foliage_table") else PackedFloat32Array()
	return {
		"n_cells": n_cells,
		"neighbor_indices": nb_idx,
		"donor_table": donor_table,
		"foliage_table": foliage_table,
	}


# Worker poll 完成时处理 sea_ice flip events。
# - 写 _slots[cell_terrain] 已由 C++ poll 完成（apply_terrain_flips=true）。
# - 这里只做 GDScript 端的：map.terrain_arr 已被 flush 同步过；
#   告诉 atlas pipeline / sea_ice atlas 把翻转 cell 标 dirty。

func _handle_async_sea_ice_flips(host, poll_result: Dictionary) -> void:
	if not poll_result.has("flipped_cell_indices"):
		return
	var indices: PackedInt32Array = poll_result["flipped_cell_indices"]
	if indices.size() <= 0:
		return
	var terrain_values: PackedByteArray = poll_result.get("flipped_new_terrain", PackedByteArray())
	var applied_indexed: bool = false
	if host.generator != null and host.generator.has_method("_apply_sea_ice_terrain_flips_indexed") \
			and terrain_values.size() >= indices.size():
		var diag: Dictionary = host.generator._apply_sea_ice_terrain_flips_indexed(host.map, indices, terrain_values, true)
		applied_indexed = bool(diag.get("applied", false))
	if not applied_indexed:
		for idx in indices:
			if host.map.has_method("mark_climate_dirty"):
				host.map.mark_climate_dirty(int(idx))
		if host._world != null and host._world.has_method("mark_dirty_indexed"):
			host._world.mark_dirty_indexed(indices)
