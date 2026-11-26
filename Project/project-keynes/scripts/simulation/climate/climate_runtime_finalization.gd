extends RefCounted

## Synchronizes terrain and climate outputs and records integrity diagnostics.

static func _get_soak_dump_instance(host):
	if host._soak_dump_script == null:
		if not ResourceLoader.exists(host._SOAK_DUMP_SCRIPT_PATH):
			return null
		host._soak_dump_script = load(host._SOAK_DUMP_SCRIPT_PATH) as GDScript
	if host._soak_dump_script == null:
		return null
	return host._soak_dump_script.instance


# Sub-pass 编号常量（保持与 _PASS_NAMES 索引对齐，便于日志可读）

static func _should_sync_runtime_terrain_views(host, reason: String) -> bool:
	if reason != "round_start":
		return true
	var cp = host.generator._c() if host.generator != null else null
	if not host._round_start_terrain_sync_bootstrap_done:
		host._round_start_terrain_sync_bootstrap_done = true
		return true
	if cp != null and cp.get("climate_round_start_terrain_sync_enabled") != null:
		return bool(cp.climate_round_start_terrain_sync_enabled)
	return host._diagnostics_enabled()


static func _sync_runtime_terrain_views_for_reason(host, reason: String) -> Dictionary:
	if host._should_sync_runtime_terrain_views(reason):
		return host._sync_runtime_terrain_views(reason)
	return {
		"reason": reason,
		"skipped": true,
		"skip_reason": "round_start_terrain_sync_disabled",
	}


static func _standalone_sea_ice_enabled(host) -> bool:
	var cp = host.generator._c() if host.generator != null else null
	return cp != null \
			and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled)


static func _sync_runtime_terrain_views(host, reason: String) -> Dictionary:
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


static func _calendar_days_per_year(host) -> int:
	if host.generator != null and host.generator.has_method("_calendar_days_per_year"):
		return clampi(int(host.generator._calendar_days_per_year()), 1, 3660)
	return 365


static func _is_annual_log_tick(host, counter: int) -> bool:
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


static func _async_finalizer_fallback_reason(host, poll: Dictionary) -> String:
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


static func _apply_daily_climate_finalizer(host) -> Dictionary:
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


static func _climate_diag_corr(host, a: PackedFloat32Array, b: PackedFloat32Array, limit: int) -> float:
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


static func _climate_diag_p95(host, arr: PackedFloat32Array, limit: int) -> float:
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


static func _debug_climate_integrity(host, stage_name: String, force: bool = false) -> void:
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
