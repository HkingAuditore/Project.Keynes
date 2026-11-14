extends "res://scripts/simulation/generator_context.gd"

## Native daily graph result synchronization and publish. Mutable state remains on MapGenerator.

func _publish_native_daily_temperature_transport_anomaly(
		map: MapData, bundle: Dictionary, breakdown: Dictionary = {}, result: Dictionary = {},
		skip_dense_write: bool = false) -> void:
	# skip_dense_write: on the round-complete tick the finalizer runs immediately after
	# this publish and re-writes the *clamped* TTA to the DataCore slot. Writing the raw
	# (pre-clamp) anomaly here would just be overwritten — so the caller passes true on the
	# done path to drop the redundant 2464-float dense write. The map.tta_arr assignment
	# below is still required so the finalizer can read + clamp the raw anomaly.
	if map == null:
		return
	var anomaly: PackedFloat32Array = result.get("temperature_transport_anomaly_out", PackedFloat32Array())
	if anomaly.is_empty() and not bundle.is_empty() and bundle.has("ocean_land_knobs"):
		var land_knobs: Dictionary = bundle.get("ocean_land_knobs", {})
		if land_knobs.has("anomaly_inout"):
			anomaly = land_knobs.get("anomaly_inout", PackedFloat32Array())
	var n: int = map.soa_size()
	if n <= 0 or anomaly.size() != n:
		return
	map.temperature_transport_anomaly_arr = anomaly
	if not skip_dense_write and _generator._data_core_world != null:
		var cid_tta: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if cid_tta >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
			_generator._data_core_world.write_f32_dense(cid_tta, anomaly)
	var cells: Array = map.iter_cells()
	var facade_on: bool = n > 0 and cells.size() > 0 and cells[0] != null \
			and (cells[0] as HexCell).is_facade_enabled()
	if not facade_on:
		for i in range(mini(n, cells.size())):
			if cells[i] != null:
				(cells[i] as HexCell).temperature_transport_anomaly = anomaly[i]
	_generator._gdext_ocean_anomaly_buf_cached = anomaly
	if breakdown != null:
		breakdown["native_daily_tta_published"] = true

func _native_daily_capture_finalizer_start_state(map: MapData) -> void:
	_generator._native_daily_slice_temp_start_arr = PackedFloat32Array()
	_generator._native_daily_slice_tta_start_arr = PackedFloat32Array()
	_generator._native_daily_slice_thermal_start_arr = PackedFloat32Array()
	if map == null:
		return
	var n: int = map.soa_size()
	if n <= 0:
		return
	if map.temp_arr.size() == n:
		_generator._native_daily_slice_temp_start_arr = map.temp_arr.duplicate()
	if map.temperature_transport_anomaly_arr.size() == n:
		_generator._native_daily_slice_tta_start_arr = map.temperature_transport_anomaly_arr.duplicate()
	if map.thermal_energy_arr.size() == n:
		_generator._native_daily_slice_thermal_start_arr = map.thermal_energy_arr.duplicate()

func _native_daily_collect_f32_dirty(current: PackedFloat32Array, values: PackedFloat32Array,
		n: int, epsilon: float) -> Dictionary:
	var indices: PackedInt32Array = PackedInt32Array()
	var dirty_values: PackedFloat32Array = PackedFloat32Array()
	if current.size() < n or values.size() < n:
		return {
			"indices": indices,
			"values": dirty_values,
			"count": -1,
		}
	var eps: float = maxf(0.0, epsilon)
	for i in range(n):
		if absf(values[i] - current[i]) > eps:
			indices.append(i)
			dirty_values.append(values[i])
	return {
		"indices": indices,
		"values": dirty_values,
		"count": indices.size(),
	}

func _native_daily_percentile_from_sorted(values: PackedFloat32Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var q: float = clampf(p, 0.0, 1.0)
	var idx: int = clampi(int(floor(q * float(values.size() - 1))), 0, values.size() - 1)
	return float(values[idx])

func _native_daily_apply_finalizer(map: MapData) -> Dictionary:
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
		"finalizer_write_mode": "dense",
		"finalizer_dirty_collect_ms": 0.0,
		"finalizer_sparse_components": PackedStringArray(),
		"finalizer_dense_components": PackedStringArray(),
		"finalizer_dirty_count_temp": 0,
		"finalizer_dirty_count_tta": 0,
		"finalizer_dirty_count_thermal": 0,
		"finalizer_dirty_ratio": 0.0,
		"finalizer_dirty_collect_skipped": false,
		"finalizer_dirty_collect_skip_components": PackedStringArray(),
		"finalizer_sparse_write_ms": 0.0,
		"finalizer_native_publish_requested": false,
		"finalizer_native_published": false,
		"finalizer_native_publish_fail_reason": "",
		"finalizer_native_published_slots": [],
		"finalizer_native_write_ms": 0.0,
		"finalizer_native_dirty_mark_ms": 0.0,
		"finalizer_cells_seen": 0,
		"finalizer_temperature_cell_mirror": false,
		"finalizer_tta_cell_mirror": false,
		"finalizer_tta_cell_mirror_count": 0,
		"finalizer_tta_clamped_count": 0,
		"finalizer_thermal_init_count": 0,
	}
	if map == null:
		return diag
	var cp_now = _generator._c()
	var n: int = map.soa_size()
	if cp_now == null or n <= 0:
		return diag
	var temp_a: PackedFloat32Array = map.temp_arr
	var tta_a: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if temp_a.size() != n or tta_a.size() != n:
		return diag
	var temp_cap_enabled: bool = true
	if cp_now.get("thermal_final_delta_cap_enabled") != null:
		temp_cap_enabled = bool(cp_now.thermal_final_delta_cap_enabled)
	var temp_cap: float = float(cp_now.thermal_daily_delta_cap) if cp_now.get("thermal_daily_delta_cap") != null else 0.15
	var tta_cap: float = float(cp_now.temperature_transport_anomaly_daily_cap) if cp_now.get("temperature_transport_anomaly_daily_cap") != null else 0.12
	var mirror_temperature_cells: bool = true
	if map.has_indices() and n > 0:
		var probe_cell: HexCell = map.cell_at(0)
		mirror_temperature_cells = probe_cell == null or not probe_cell.is_facade_enabled()
	diag["finalizer_temperature_cell_mirror"] = mirror_temperature_cells
	var mirror_tta_cells: bool = mirror_temperature_cells
	diag["finalizer_tta_cell_mirror"] = mirror_tta_cells
	var cells: Array = []
	if mirror_temperature_cells or mirror_tta_cells:
		cells = map.iter_cells() if map.has_indices() else map.all_cells()
	var has_temp_start: bool = _generator._native_daily_slice_temp_start_arr.size() == n
	var has_tta_start: bool = _generator._native_daily_slice_tta_start_arr.size() == n
	var thermal_a: PackedFloat32Array = map.thermal_energy_arr
	var ema_a: PackedByteArray = map.ema_initialized_arr
	var t_cells_us: int = Time.get_ticks_usec()
	var t_part_us: int = t_cells_us
	# heavy_diag gates the percentile machinery (per-cell delta arrays + sorts). The cheap
	# running max / gt-counts below stay accurate regardless; only p95/p99 go stale when off.
	var heavy_diag: bool = _generator._native_daily_finalizer_heavy_diag
	# Declared at function scope so the heavy_diag sort block below stays in scope on both paths.
	var temp_deltas: PackedFloat32Array = PackedFloat32Array()
	var preclamp_temp_deltas: PackedFloat32Array = PackedFloat32Array()
	# ② Native finalizer fast path: production hot path = facade ON (no HexCell mirror) +
	# heavy_diag OFF. The C++ kernel runs the same delta-cap + thermal-init math on the same
	# buffers, so it is bit-equal to the GDScript loops below; it returns fresh clamped arrays
	# (temp_a/tta_a/thermal_a stay CoW-decoupled from map.* exactly as the in-place loops left
	# them) plus the diag scalars. Falls back to GDScript on rc!=0 or method-missing.
	var native_publish_enabled: bool = bool(cp_now.native_daily_finalizer_native_publish_enabled) \
			if cp_now.get("native_daily_finalizer_native_publish_enabled") != null else false
	var use_native_finalizer: bool = _generator.native_daily_finalizer_native_enabled \
			and not heavy_diag and not mirror_temperature_cells and not mirror_tta_cells \
			and _generator._data_core_world_ext != null
	if use_native_finalizer:
		var fr: Dictionary = _generator._data_core_world_ext.run_native_daily_finalizer({
			"cell_count": n,
			"temp": temp_a,
			"tta": tta_a,
			"thermal": thermal_a,
			"ema": ema_a,
			"temp_start": _generator._native_daily_slice_temp_start_arr if has_temp_start else PackedFloat32Array(),
			"tta_start": _generator._native_daily_slice_tta_start_arr if has_tta_start else PackedFloat32Array(),
			"temp_cap_enabled": temp_cap_enabled,
			"temp_cap": temp_cap,
			"tta_cap": tta_cap,
			"native_publish": native_publish_enabled,
		})
		if int(fr.get("rc", -1)) == 0:
			# Adopt each C++ buffer ONLY when it was actually written, to preserve the
			# GDScript CoW fork-on-write aliasing (tta_a stays aliased to map.tta_arr on
			# 0-clamp rounds, which the next round reads via the ocean-anomaly cache).
			if bool(fr.get("temp_written", false)):
				temp_a = fr.get("temp_out", temp_a)
			if bool(fr.get("tta_written", false)):
				tta_a = fr.get("tta_out", tta_a)
			if bool(fr.get("thermal_written", false)):
				thermal_a = fr.get("thermal_out", thermal_a)
			diag["max_temp_delta"] = float(fr.get("max_temp_delta", 0.0))
			diag["preclamp_max_temp_delta"] = float(fr.get("preclamp_max_temp_delta", 0.0))
			diag["temp_delta_gt_005_count"] = int(fr.get("temp_delta_gt_005_count", 0))
			diag["temp_delta_gt_010_count"] = int(fr.get("temp_delta_gt_010_count", 0))
			diag["temp_delta_gt_020_count"] = int(fr.get("temp_delta_gt_020_count", 0))
			diag["temp_delta_clamped_count"] = int(fr.get("temp_delta_clamped_count", 0))
			diag["max_transport_anomaly"] = float(fr.get("max_transport_anomaly", 0.0))
			diag["finalizer_tta_clamped_count"] = int(fr.get("finalizer_tta_clamped_count", 0))
			diag["finalizer_tta_cell_mirror_count"] = 0
			diag["finalizer_thermal_init_count"] = int(fr.get("finalizer_thermal_init_count", 0))
			diag["finalizer_path"] = "native"
			diag["finalizer_native_publish_requested"] = bool(fr.get("native_publish_requested", false))
			diag["finalizer_native_published"] = bool(fr.get("native_published", false))
			diag["finalizer_native_publish_fail_reason"] = str(fr.get("native_publish_fail_reason", ""))
			diag["finalizer_native_published_slots"] = fr.get("native_published_slots", [])
			diag["finalizer_native_write_ms"] = float(fr.get("finalizer_native_write_ms", 0.0))
		else:
			use_native_finalizer = false
	if not use_native_finalizer:
		diag["finalizer_path"] = "gdscript"
		if heavy_diag:
			temp_deltas.resize(n)
			preclamp_temp_deltas.resize(n)
		var max_temp_delta: float = 0.0
		var preclamp_max_temp_delta: float = 0.0
		var temp_delta_gt_005_count: int = 0
		var temp_delta_gt_010_count: int = 0
		var temp_delta_gt_020_count: int = 0
		var temp_delta_clamped_count: int = 0
		for i in range(n):
			var start_t: float = _generator._native_daily_slice_temp_start_arr[i] if has_temp_start else temp_a[i]
			var raw_final_t: float = temp_a[i]
			var final_t: float = raw_final_t
			var pre_abs_dt: float = absf(raw_final_t - start_t)
			if heavy_diag:
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
			if heavy_diag:
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
				(cells[i] as HexCell).temperature = final_t
		diag["max_temp_delta"] = max_temp_delta
		diag["preclamp_max_temp_delta"] = preclamp_max_temp_delta
		diag["temp_delta_gt_005_count"] = temp_delta_gt_005_count
		diag["temp_delta_gt_010_count"] = temp_delta_gt_010_count
		diag["temp_delta_gt_020_count"] = temp_delta_gt_020_count
		diag["temp_delta_clamped_count"] = temp_delta_clamped_count
		diag["finalizer_temp_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
		t_part_us = Time.get_ticks_usec()
		var max_transport_anomaly: float = 0.0
		var finalizer_tta_clamped_count: int = 0
		var finalizer_tta_cell_mirror_count: int = 0
		for i in range(n):
			var start_tta: float = _generator._native_daily_slice_tta_start_arr[i] if has_tta_start else 0.0
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
				(cells[i] as HexCell).temperature_transport_anomaly = final_tta
				finalizer_tta_cell_mirror_count += 1
		diag["max_transport_anomaly"] = max_transport_anomaly
		diag["finalizer_tta_clamped_count"] = finalizer_tta_clamped_count
		diag["finalizer_tta_cell_mirror_count"] = finalizer_tta_cell_mirror_count
		diag["finalizer_tta_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
		t_part_us = Time.get_ticks_usec()
		var finalizer_thermal_init_count: int = 0
		if thermal_a.size() == n:
			for i in range(n):
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
	if heavy_diag:
		temp_deltas.sort()
		preclamp_temp_deltas.sort()
		diag["p95_temp_delta"] = _native_daily_percentile_from_sorted(temp_deltas, 0.95)
		diag["p99_temp_delta"] = _native_daily_percentile_from_sorted(temp_deltas, 0.99)
		diag["preclamp_p99_temp_delta"] = _native_daily_percentile_from_sorted(preclamp_temp_deltas, 0.99)
	diag["finalizer_sort_ms"] = float(Time.get_ticks_usec() - t_sort_us) / 1000.0
	var t_sea_ice_us: int = Time.get_ticks_usec()
	if heavy_diag and map.sea_ice_frac_arr.size() == n and map.sea_ice_frac_arr_prev.size() == n:
		for i in range(n):
			var ds: float = absf(map.sea_ice_frac_arr[i] - map.sea_ice_frac_arr_prev[i])
			if ds > float(diag["sea_ice_delta_max"]):
				diag["sea_ice_delta_max"] = ds
	diag["finalizer_sea_ice_ms"] = float(Time.get_ticks_usec() - t_sea_ice_us) / 1000.0
	var t_precip_us: int = Time.get_ticks_usec()
	if heavy_diag and map.weather_precip_arr.size() == n:
		var precip_vals: PackedFloat32Array = map.weather_precip_arr.duplicate()
		precip_vals.sort()
		diag["precip_p95"] = _native_daily_percentile_from_sorted(precip_vals, 0.95)
	diag["finalizer_precip_ms"] = float(Time.get_ticks_usec() - t_precip_us) / 1000.0
	var finalizer_native_published: bool = bool(diag.get("finalizer_native_published", false))
	if finalizer_native_published:
		diag["finalizer_write_mode"] = "native_publish"
		diag["finalizer_write_dense_ms"] = 0.0
		diag["finalizer_sparse_write_ms"] = 0.0
		diag["finalizer_dirty_collect_ms"] = 0.0
		diag["finalizer_dirty_collect_skipped"] = true
		diag["finalizer_dirty_collect_skip_components"] = PackedStringArray(["temp", "tta", "thermal"])
		diag["finalizer_dense_components"] = PackedStringArray()
		diag["finalizer_sparse_components"] = PackedStringArray()
		var t_native_mark_us: int = Time.get_ticks_usec()
		if _generator._data_core_world_ext != null:
			_generator._data_core_world_ext.flush_pending_mark_dirty_all()
		diag["finalizer_native_dirty_mark_ms"] = float(Time.get_ticks_usec() - t_native_mark_us) / 1000.0
	elif _generator._data_core_world != null:
		var cid_temp: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMP)
		var cid_tta: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		var cid_heat: int = _generator._data_core_world.component_id(DCComponentIds.CELL_THERMAL_ENERGY)
		var requested_write_mode: String = str(cp_now.native_daily_finalizer_write_mode) \
				if cp_now.get("native_daily_finalizer_write_mode") != null else "dense"
		var write_mode: String = requested_write_mode
		var can_sparse: bool = write_mode != "dense" \
				and str(diag.get("finalizer_path", "")) == "native" \
				and _generator._data_core_world.has_method("write_f32_indexed") \
				and _generator._data_core_world.has_method("write_f32_dense") \
				and _generator._data_core_world.has_method("view_f32") \
				and cid_temp >= 0 and cid_tta >= 0 and cid_heat >= 0 \
				and thermal_a.size() == n
		var temp_eps: float = float(cp_now.native_daily_finalizer_temp_epsilon) \
				if cp_now.get("native_daily_finalizer_temp_epsilon") != null else 0.0005
		var tta_eps: float = float(cp_now.native_daily_finalizer_tta_epsilon) \
				if cp_now.get("native_daily_finalizer_tta_epsilon") != null else 0.0005
		var thermal_eps: float = float(cp_now.native_daily_finalizer_thermal_epsilon) \
				if cp_now.get("native_daily_finalizer_thermal_epsilon") != null else 0.0005
		var max_dirty_ratio: float = float(cp_now.native_daily_finalizer_sparse_max_dirty_ratio) \
				if cp_now.get("native_daily_finalizer_sparse_max_dirty_ratio") != null else 0.45
		max_dirty_ratio = clampf(max_dirty_ratio, 0.0, 1.0)
		var sparse_components: PackedStringArray = PackedStringArray()
		var dense_components: PackedStringArray = PackedStringArray()
		var dense_write_ms: float = 0.0
		var sparse_write_ms: float = 0.0
		if can_sparse:
			var temp_cur: PackedFloat32Array = _generator._data_core_world.view_f32(cid_temp)
			var tta_cur: PackedFloat32Array = _generator._data_core_world.view_f32(cid_tta)
			var heat_cur: PackedFloat32Array = _generator._data_core_world.view_f32(cid_heat)
			if _generator._native_daily_slice_temp_start_arr.size() == n:
				temp_cur = _generator._native_daily_slice_temp_start_arr
			if _generator._native_daily_slice_tta_start_arr.size() == n:
				tta_cur = _generator._native_daily_slice_tta_start_arr
			if _generator._native_daily_slice_thermal_start_arr.size() == n:
				heat_cur = _generator._native_daily_slice_thermal_start_arr
			var dense_hint_enabled: bool = requested_write_mode == "sparse_perf"
			var dense_hint_sample_round: bool = false
			if _generator._NATIVE_DAILY_FINALIZER_DENSE_HINT_SAMPLE_PERIOD > 0:
				dense_hint_sample_round = (_generator._native_daily_finalizer_dense_hint_round % _generator._NATIVE_DAILY_FINALIZER_DENSE_HINT_SAMPLE_PERIOD) == 0
			_generator._native_daily_finalizer_dense_hint_round += 1
			var dense_hint_threshold: float = clampf(
				max_dirty_ratio + _generator._NATIVE_DAILY_FINALIZER_DENSE_HINT_MARGIN,
				0.0,
				1.0
			)
			var skip_components: PackedStringArray = PackedStringArray()
			var skip_temp_collect: bool = dense_hint_enabled \
					and not dense_hint_sample_round \
					and _generator._native_daily_finalizer_prev_dirty_ratio_temp >= dense_hint_threshold
			var skip_tta_collect: bool = dense_hint_enabled \
					and not dense_hint_sample_round \
					and _generator._native_daily_finalizer_prev_dirty_ratio_tta >= dense_hint_threshold
			var skip_heat_collect: bool = dense_hint_enabled \
					and not dense_hint_sample_round \
					and _generator._native_daily_finalizer_prev_dirty_ratio_thermal >= dense_hint_threshold
			var t_collect_us: int = Time.get_ticks_usec()
			var temp_dirty: Dictionary = {}
			var tta_dirty: Dictionary = {}
			var heat_dirty: Dictionary = {}
			if skip_temp_collect:
				skip_components.append("temp")
			else:
				temp_dirty = _native_daily_collect_f32_dirty(temp_cur, temp_a, n, temp_eps)
			if skip_tta_collect:
				skip_components.append("tta")
			else:
				tta_dirty = _native_daily_collect_f32_dirty(tta_cur, tta_a, n, tta_eps)
			if skip_heat_collect:
				skip_components.append("thermal")
			else:
				heat_dirty = _native_daily_collect_f32_dirty(heat_cur, thermal_a, n, thermal_eps)
			diag["finalizer_dirty_collect_ms"] = float(Time.get_ticks_usec() - t_collect_us) / 1000.0
			diag["finalizer_dirty_collect_skipped"] = skip_components.size() > 0
			diag["finalizer_dirty_collect_skip_components"] = skip_components
			var temp_count: int = n if skip_temp_collect else int(temp_dirty.get("count", -1))
			var tta_count: int = n if skip_tta_collect else int(tta_dirty.get("count", -1))
			var heat_count: int = n if skip_heat_collect else int(heat_dirty.get("count", -1))
			can_sparse = temp_count >= 0 and tta_count >= 0 and heat_count >= 0
			if can_sparse:
				var temp_ratio: float = float(temp_count) / float(maxi(1, n))
				var tta_ratio: float = float(tta_count) / float(maxi(1, n))
				var heat_ratio: float = float(heat_count) / float(maxi(1, n))
				if not skip_temp_collect:
					_generator._native_daily_finalizer_prev_dirty_ratio_temp = temp_ratio
				if not skip_tta_collect:
					_generator._native_daily_finalizer_prev_dirty_ratio_tta = tta_ratio
				if not skip_heat_collect:
					_generator._native_daily_finalizer_prev_dirty_ratio_thermal = heat_ratio
				var dirty_max: int = maxi(temp_count, maxi(tta_count, heat_count))
				var dirty_ratio: float = float(dirty_max) / float(maxi(1, n))
				diag["finalizer_dirty_count_temp"] = temp_count
				diag["finalizer_dirty_count_tta"] = tta_count
				diag["finalizer_dirty_count_thermal"] = heat_count
				diag["finalizer_dirty_ratio"] = dirty_ratio
				var temp_sparse_ok: bool = not skip_temp_collect and temp_ratio <= max_dirty_ratio
				var tta_sparse_ok: bool = not skip_tta_collect and tta_ratio <= max_dirty_ratio
				var heat_sparse_ok: bool = not skip_heat_collect and heat_ratio <= max_dirty_ratio
				if temp_sparse_ok:
					if temp_count > 0:
						var t_sparse_us: int = Time.get_ticks_usec()
						_generator._data_core_world.write_f32_indexed(cid_temp,
							temp_dirty.get("indices", PackedInt32Array()),
							temp_dirty.get("values", PackedFloat32Array()))
						sparse_write_ms += float(Time.get_ticks_usec() - t_sparse_us) / 1000.0
						sparse_components.append("temp")
				else:
					var t_dense_us: int = Time.get_ticks_usec()
					_generator._data_core_world.write_f32_dense(cid_temp, temp_a)
					dense_write_ms += float(Time.get_ticks_usec() - t_dense_us) / 1000.0
					dense_components.append("temp")
				if tta_sparse_ok:
					if tta_count > 0:
						var t_sparse_us: int = Time.get_ticks_usec()
						_generator._data_core_world.write_f32_indexed(cid_tta,
							tta_dirty.get("indices", PackedInt32Array()),
							tta_dirty.get("values", PackedFloat32Array()))
						sparse_write_ms += float(Time.get_ticks_usec() - t_sparse_us) / 1000.0
						sparse_components.append("tta")
				else:
					var t_dense_us: int = Time.get_ticks_usec()
					_generator._data_core_world.write_f32_dense(cid_tta, tta_a)
					dense_write_ms += float(Time.get_ticks_usec() - t_dense_us) / 1000.0
					dense_components.append("tta")
				if heat_sparse_ok:
					if heat_count > 0:
						var t_sparse_us: int = Time.get_ticks_usec()
						_generator._data_core_world.write_f32_indexed(cid_heat,
							heat_dirty.get("indices", PackedInt32Array()),
							heat_dirty.get("values", PackedFloat32Array()))
						sparse_write_ms += float(Time.get_ticks_usec() - t_sparse_us) / 1000.0
						sparse_components.append("thermal")
				else:
					var t_dense_us: int = Time.get_ticks_usec()
					_generator._data_core_world.write_f32_dense(cid_heat, thermal_a)
					dense_write_ms += float(Time.get_ticks_usec() - t_dense_us) / 1000.0
					dense_components.append("thermal")
				if dense_components.size() > 0 and sparse_components.size() > 0:
					write_mode = "mixed_sparse_dense"
				elif dense_components.size() > 0:
					write_mode = "dense_fallback_dirty_ratio"
				elif sparse_components.size() > 0:
					write_mode = requested_write_mode
				else:
					write_mode = "sparse_noop"
				diag["finalizer_sparse_write_ms"] = sparse_write_ms
				diag["finalizer_write_dense_ms"] = dense_write_ms
		if not can_sparse:
			if requested_write_mode != "dense" and write_mode == requested_write_mode:
				write_mode = "dense_fallback_unavailable"
			var t_dense_us: int = Time.get_ticks_usec()
			if cid_temp >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
				_generator._data_core_world.write_f32_dense(cid_temp, temp_a)
			if cid_tta >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
				_generator._data_core_world.write_f32_dense(cid_tta, tta_a)
			if cid_heat >= 0 and thermal_a.size() == n and _generator._data_core_world.has_method("write_f32_dense"):
				_generator._data_core_world.write_f32_dense(cid_heat, thermal_a)
			dense_write_ms = float(Time.get_ticks_usec() - t_dense_us) / 1000.0
			diag["finalizer_write_dense_ms"] = dense_write_ms
			dense_components.append("temp")
			dense_components.append("tta")
			dense_components.append("thermal")
		diag["finalizer_write_mode"] = write_mode
		diag["finalizer_sparse_components"] = sparse_components
		diag["finalizer_dense_components"] = dense_components
	_generator._gdext_ocean_anomaly_buf_cached = tta_a
	diag["thermal_finalizer_applied"] = true
	var moisture_commit_t0: int = Time.get_ticks_usec()
	var moisture_committed: bool = false
	var moisture_commit_path: String = "unavailable"
	var moisture_commit_slot_size: int = 0
	if _generator._data_core_world_ext != null:
		var moisture_sid: int = int(_generator._data_core_world_ext.component_id("cell_moisture"))
		if moisture_sid >= 0:
			var moisture_snapshot: PackedFloat32Array = _generator._data_core_world_ext.snapshot_f32(moisture_sid)
			moisture_commit_slot_size = moisture_snapshot.size()
			if moisture_snapshot.size() == n:
				# Commit to the exact MapData instance owned by this scheduler round.
				map.moisture_arr = moisture_snapshot
				moisture_committed = true
				moisture_commit_path = "slot_snapshot_to_round_map"
	if not moisture_committed and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("flush_slots_to_map_keys"):
		_generator._data_core_world_ext.flush_slots_to_map_keys(PackedStringArray(["cell_moisture"]))
		moisture_committed = true
		moisture_commit_path = "bound_map_flush_fallback"
	# Release the visual snapshot transaction only after the completed values are visible.
	if _generator._data_core_world_ext != null:
		_generator._data_core_world_ext.complete_native_daily_visual_commit()
	diag["moisture_committed"] = moisture_committed
	diag["moisture_commit_path"] = moisture_commit_path
	diag["moisture_commit_slot_size"] = moisture_commit_slot_size
	diag["moisture_commit_flush_ms"] = float(Time.get_ticks_usec() - moisture_commit_t0) / 1000.0
	diag["finalizer_total_ms"] = float(Time.get_ticks_usec() - t_total_us) / 1000.0
	return diag

func _merge_native_daily_finalizer_diag(target: Dictionary, diag: Dictionary) -> void:
	for key in diag.keys():
		target[key] = diag[key]

func _native_daily_add_complete_apply_ms(diag: Dictionary, key: String, elapsed_us: int) -> void:
	diag[key] = float(diag.get(key, 0.0)) + float(elapsed_us) / 1000.0

func _native_daily_install_complete_apply_diag(
		res: Dictionary,
		breakdown: Dictionary,
		diag: Dictionary,
		apply_ms: float) -> void:
	if diag.is_empty():
		return
	var observed_keys: Array[String] = [
		"complete_apply_publish_tta_ms",
		"complete_apply_weather_result_ms",
		"complete_apply_visual_intents_ms",
		"complete_apply_finalizer_ms",
		"complete_apply_finalizer_merge_ms",
		"complete_apply_result_patch_ms",
	]
	var observed_ms: float = 0.0
	for key in observed_keys:
		observed_ms += float(diag.get(key, 0.0))
	diag["complete_apply_observed_ms"] = observed_ms
	diag["complete_apply_total_ms"] = apply_ms
	diag["complete_apply_other_ms"] = maxf(0.0, apply_ms - observed_ms)
	for key in diag.keys():
		res[key] = diag[key]
		breakdown[key] = diag[key]

func _native_daily_make_front_signature(front: WeatherFront) -> String:
	if front == null:
		return "null"
	var axis_v: Vector2 = front.normalized_axis()
	return "%d:%d:%d:%d:%d:%d:%d:%d" % [
		int(front.type),
		roundi(front.center.x / 8.0),
		roundi(front.center.y / 8.0),
		roundi(axis_v.angle() / 0.0872665),
		roundi(front.radius / 8.0),
		roundi(clampf(front.intensity, 0.0, 1.0) * 100.0),
		roundi(clampf(front.precip_amount, 0.0, 1.0) * 100.0),
		roundi(clampf(front.cloud_amount, 0.0, 1.0) * 100.0),
	]

func _native_daily_front_slot_signatures(fronts: Array) -> PackedStringArray:
	var parts := PackedStringArray()
	parts.resize(fronts.size())
	for front_index in range(fronts.size()):
		parts[front_index] = _native_daily_make_front_signature(fronts[front_index])
	return parts

func _native_daily_fronts_signature_diff(prev: PackedStringArray, next: PackedStringArray) -> Dictionary:
	var changed_slots := PackedInt32Array()
	var unchanged: int = 0
	var changed: int = 0
	var added: int = 0
	var removed: int = 0
	var max_n: int = maxi(prev.size(), next.size())
	for i in range(max_n):
		var old_sig: String = prev[i] if i < prev.size() else ""
		var new_sig: String = next[i] if i < next.size() else ""
		if old_sig == new_sig:
			unchanged += 1
		else:
			changed_slots.append(i)
			if i >= prev.size():
				added += 1
			elif i >= next.size():
				removed += 1
			else:
				changed += 1
	return {
		"changed_slots": changed_slots,
		"changed_slots_count": changed_slots.size(),
		"unchanged_slots": unchanged,
		"changed_slots_existing": changed,
		"added_slots": added,
		"removed_slots": removed,
	}

func _apply_vegetation_succession_candidates(map: MapData,
		indices: PackedInt32Array, to_vegetation: PackedByteArray, cp_now) -> int:
	if map == null or cp_now == null:
		return 0
	var candidate_count: int = mini(indices.size(), to_vegetation.size())
	if candidate_count <= 0:
		return 0
	_generator._ensure_vegdyn_lut()
	var applied_indices := PackedInt32Array()
	var applied_vegetation := PackedByteArray()
	applied_indices.resize(candidate_count)
	applied_vegetation.resize(candidate_count)
	var applied_count: int = 0
	var cooldown_days: int = int(cp_now.vegetation_succession_cooldown_days) \
			if cp_now.get("vegetation_succession_cooldown_days") != null else 30
	var degrade_reset_target: float = float(cp_now.vegetation_degrade_reset_target) \
			if cp_now.get("vegetation_degrade_reset_target") != null else 0.75
	var sparse_visual_publish: bool = cp_now.get(
			"native_daily_sparse_visual_publish_enabled") != null \
			and bool(cp_now.native_daily_sparse_visual_publish_enabled)
	for k in range(candidate_count):
		var idx: int = indices[k]
		if idx < 0 or idx >= map.cell_count():
			continue
		var cell: HexCell = map.cell_at(idx)
		if cell == null:
			continue
		var previous_vegetation: int = int(cell.vegetation)
		var next_vegetation: int = int(to_vegetation[k])
		if next_vegetation == previous_vegetation:
			continue
		var is_degrade: bool = previous_vegetation < _generator._gdext_vegdyn_next_down_cached.size() \
				and int(_generator._gdext_vegdyn_next_down_cached[previous_vegetation]) == next_vegetation
		cell.vegetation = next_vegetation
		cell.base_vegetation = next_vegetation
		var target_vitality: float = degrade_reset_target if is_degrade else 0.7
		cell.vegetation_vitality = (cell.vegetation_vitality + target_vitality) * 0.5
		if cooldown_days > 0:
			cell._vitality_low_streak = -cooldown_days
			cell._vitality_high_streak = -cooldown_days
		cell.current_state["vegetation"] = next_vegetation
		if idx < map.vegetation_arr.size():
			map.vegetation_arr[idx] = next_vegetation & 0xFF
		if idx < map.base_vegetation_arr.size():
			map.base_vegetation_arr[idx] = next_vegetation & 0xFF
		if idx < map.vegetation_vitality_arr.size():
			map.vegetation_vitality_arr[idx] = cell.vegetation_vitality
		if idx < map.vitality_low_streak_arr.size():
			map.vitality_low_streak_arr[idx] = cell._vitality_low_streak
		if idx < map.vitality_high_streak_arr.size():
			map.vitality_high_streak_arr[idx] = cell._vitality_high_streak
		if not sparse_visual_publish and map.has_method("mark_climate_dirty"):
			map.mark_climate_dirty(idx)
		applied_indices[applied_count] = idx
		applied_vegetation[applied_count] = next_vegetation & 0xFF
		applied_count += 1
	if applied_count <= 0:
		return 0
	applied_indices.resize(applied_count)
	applied_vegetation.resize(applied_count)
	if sparse_visual_publish and map.has_method("mark_climate_dirty_indexed"):
		map.mark_climate_dirty_indexed(applied_indices)
	# vegetation/base_vegetation 不是 HexCell facade 字段；显式发布到两侧权威槽位。
	if _generator._data_core_world != null and _generator._data_core_world.has_method("write_u8_indexed"):
		var vegetation_cid: int = _generator._data_core_world.component_id(DCComponentIds.CELL_VEGETATION)
		if vegetation_cid >= 0:
			_generator._data_core_world.write_u8_indexed(vegetation_cid, applied_indices, applied_vegetation)
		var base_vegetation_cid: int = _generator._data_core_world.component_id(DCComponentIds.CELL_BASE_VEGETATION)
		if base_vegetation_cid >= 0:
			_generator._data_core_world.write_u8_indexed(base_vegetation_cid, applied_indices, applied_vegetation)
		if _generator._data_core_world.has_method("mark_dirty_indexed"):
			_generator._data_core_world.mark_dirty_indexed(applied_indices)
	# The native vegetation pass already owns DCWorldExt slots. The indexed
	# DCWorld write above is the single retained mirror update.
	if not sparse_visual_publish and _generator._data_core_world_ext != null :
		var vegetation_ext_cid: int = _generator._world_ext_u8_component_id(DCComponentIds.CELL_VEGETATION)
		if vegetation_ext_cid >= 0:
			_generator._data_core_world_ext.write_u8_indexed(vegetation_ext_cid, applied_indices, applied_vegetation)
		var base_vegetation_ext_cid: int = _generator._world_ext_u8_component_id(DCComponentIds.CELL_BASE_VEGETATION)
		if base_vegetation_ext_cid >= 0:
			_generator._data_core_world_ext.write_u8_indexed(base_vegetation_ext_cid, applied_indices, applied_vegetation)
	_generator.queue_detail_scatter_refresh(applied_indices)
	return applied_count

func _apply_native_daily_visual_intents(res: Dictionary, breakdown: Dictionary,
		fronts_out: Array, map: MapData, world: WorldData) -> void:
	var slot_sigs: PackedStringArray = _native_daily_front_slot_signatures(fronts_out)
	var signature: String = "n=%d|%s" % [fronts_out.size(), "|".join(slot_sigs)]
	var fronts_diff: Dictionary = _native_daily_fronts_signature_diff(_generator._native_daily_front_slot_sigs, slot_sigs)
	var fronts_changed: bool = signature != _generator._native_daily_front_signature
	fronts_diff["changed"] = fronts_changed
	fronts_diff["signature"] = signature
	fronts_diff["fronts"] = fronts_out.size()
	_generator._native_daily_front_signature = signature
	_generator._native_daily_front_slot_sigs = slot_sigs
	_generator._last_active_fronts = fronts_out
	_generator._weather_round_fronts = fronts_out
	res["fronts"] = fronts_out
	res["fronts_changed"] = fronts_changed
	res["fronts_diff"] = fronts_diff
	res["fronts_signature"] = signature
	res["fronts_changed_reason"] = "signature_changed" if fronts_changed else "signature_unchanged"

	var intents: Array = res.get("visual_dirty_intents", breakdown.get("visual_dirty_intents", []))
	var native_lut: PackedByteArray = breakdown.get("weather_lut", PackedByteArray())
	if (intents.has("weather_lut") or not native_lut.is_empty()) \
			and _generator.has_method("publish_weather_lut_after_weather_commit"):
		var lut_report: Dictionary = _generator.publish_weather_lut_after_weather_commit(
			map,
			world,
			native_lut,
			bool(breakdown.get("weather_lut_changed", false))
		)
		res["weather_lut_publish_report"] = lut_report
		res["weather_lut_published"] = bool(lut_report.get("weather_lut_published", false))
		res["weather_lut_publish_path"] = str(lut_report.get("path", "weather_lut_inline"))
		res["weather_lut_changed"] = bool(lut_report.get("weather_lut_changed", false))
	else:
		res["weather_lut_published"] = false
		res["weather_lut_publish_path"] = "not_requested"

	var succession_indices: PackedInt32Array = breakdown.get(
		"succession_indices", PackedInt32Array())
	var succession_to_vegetation: PackedByteArray = breakdown.get(
		"succession_to_veg", PackedByteArray())
	var succession_applied: int = _apply_vegetation_succession_candidates(
		map, succession_indices, succession_to_vegetation, _generator._c())
	res["succession_applied_count"] = succession_applied

	if _generator._baker != null:
		if _generator._data_core_world_ext != null \
				and world != null and world.visual_tiles != null \
				and world.visual_tiles.ready:
			var canal_dirty: PackedInt32Array = \
				_generator._consume_native_daily_canal_visual_dirty_cells()
			if not canal_dirty.is_empty():
				res["canal_visual_refresh"] = _generator._baker.queue_canal_visual_refresh(
					map, world, canal_dirty)
		var cover_dirty: bool = _generator._weather_system != null \
				and _generator._weather_system.has_method("has_cover_dirty") \
				and bool(_generator._weather_system.has_cover_dirty())
		if cover_dirty:
			_generator._mark_enum_atlas_dirty(true, false)
		var veg_dirty: bool = succession_applied > 0
		if veg_dirty or intents.has("detail_scatter"):
			_generator._mark_enum_atlas_dirty(false, true)
		if intents.has("enum_atlas") and not (cover_dirty or veg_dirty):
			_generator._mark_enum_atlas_dirty(true, true)

func _record_native_daily_slice_climate_breakdown(res: Dictionary, breakdown: Dictionary, map: MapData, done: bool, rc_int: int) -> void:
	# Shallow copy: this is a per-slice diagnostic snapshot. We only add TOP-LEVEL
	# keys below, and nested PackedArrays are copy-on-write, so sharing them by ref
	# avoids byte-copying thousands of floats per slice (was deep `duplicate(true)`).
	var diag: Dictionary = breakdown.duplicate()
	diag["_tick_idx"] = _generator._current_fast_tick_idx
	diag["cells"] = map.soa_size() if map != null else 0
	diag["partial"] = rc_int == 0 and not done
	diag["current_pass"] = "done" if rc_int == 0 and done else str(res.get("stage_name", res.get("fail_stage", "native_daily_slice")))
	diag["progress_ratio"] = float(res.get("progress_ratio", breakdown.get("progress_ratio", 0.0)))
	diag["processed_cells"] = int(res.get("processed_cells", breakdown.get("processed_cells", 0)))
	diag["cursor_start"] = int(res.get("cursor_start", breakdown.get("cursor_start", -1)))
	diag["cursor_end"] = int(res.get("cursor_end", breakdown.get("cursor_end", -1)))
	diag["round_id"] = int(res.get("round_id", breakdown.get("round_id", 0)))
	diag["node_index"] = int(res.get("node_index", breakdown.get("node_index", -1)))
	diag["next_node_index"] = int(res.get("next_node_index", breakdown.get("next_node_index", -1)))
	diag["last_completed_node"] = str(res.get("last_completed_node", breakdown.get("last_completed_node", "")))
	diag["processed_nodes"] = int(res.get("processed_nodes", breakdown.get("processed_nodes", 0)))
	diag["deferred_wait_node"] = str(res.get("deferred_wait_node", breakdown.get("deferred_wait_node", "")))
	diag["deferred_wait_key"] = str(res.get("deferred_wait_key", breakdown.get("deferred_wait_key", "")))
	diag["node_range_enabled"] = bool(res.get("node_range_enabled", breakdown.get("node_range_enabled", false)))
	diag["node_range_active"] = bool(res.get("node_range_active", breakdown.get("node_range_active", false)))
	diag["node_range_done"] = bool(res.get("node_range_done", breakdown.get("node_range_done", true)))
	diag["node_range_budget"] = int(res.get("node_range_budget", breakdown.get("node_range_budget", 0)))
	diag["node_range_node"] = str(res.get("node_range_node", breakdown.get("node_range_node", "")))
	diag["node_cell_cursor_start"] = int(res.get("node_cell_cursor_start", breakdown.get("node_cell_cursor_start", -1)))
	diag["node_cell_cursor_end"] = int(res.get("node_cell_cursor_end", breakdown.get("node_cell_cursor_end", -1)))
	diag["node_cell_count"] = int(res.get("node_cell_count", breakdown.get("node_cell_count", 0)))
	diag["node_cell_processed"] = int(res.get("node_cell_processed", breakdown.get("node_cell_processed", 0)))
	diag["contract_catchup_active"] = bool(res.get("contract_catchup_active", breakdown.get("contract_catchup_active", false)))
	diag["contract_catchup_reason"] = str(res.get("contract_catchup_reason", breakdown.get("contract_catchup_reason", "")))
	diag["contract_range_base_cells"] = int(res.get("contract_range_base_cells", breakdown.get("contract_range_base_cells", 0)))
	diag["contract_range_effective_cells"] = int(res.get("contract_range_effective_cells", breakdown.get("contract_range_effective_cells", 0)))
	diag["contract_estimated_slices"] = int(res.get("contract_estimated_slices", breakdown.get("contract_estimated_slices", 0)))
	diag["pass_status"] = "done" if rc_int == 0 and done else ("partial" if rc_int == 0 else "failed")
	diag["path"] = str(res.get("path", breakdown.get("path", "gdext_native_daily_slice")))
	if not done:
		diag["thermal_finalizer_applied"] = false
	var pass_diag: Dictionary = {}
	var node_report_var = res.get("node_report", {})
	if typeof(node_report_var) == TYPE_DICTIONARY:
		pass_diag = (node_report_var as Dictionary).duplicate()
	if pass_diag.is_empty():
		pass_diag = {
			"stage": diag["current_pass"],
			"substage": str(res.get("substage", "")),
			"path": diag["path"],
		}
	else:
		if not pass_diag.has("stage"):
			pass_diag["stage"] = diag["current_pass"]
		if not pass_diag.has("substage"):
			pass_diag["substage"] = str(res.get("substage", ""))
		if not pass_diag.has("path"):
			pass_diag["path"] = diag["path"]
	diag["pass_diag"] = pass_diag
	# This record is overwriting, not merging, so it must carry the authority
	# state itself. Without it the key set by the schedule path disappears here
	# and readers see a suppressed main thread as having resumed (or vice versa).
	if _generator._data_core_world_ext != null :
		diag["climate_authority_suppressed"] = _generator.native_daily_climate_suppressed()
	_generator._diagnostics_bus.record_climate_breakdown(diag)

